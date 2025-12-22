-- capture.lua
-- Effect capture system using PCSX-Redux breakpoints
--
-- CRITICAL INSIGHT (2024-12): We capture at the START of caseD_3 (0x801a1964)
-- which is BEFORE any header-based globals are set. This means:
-- 1. The effect file IS loaded in memory (lookup table has base address)
-- 2. But NO globals have been initialized from the header yet
--
-- When we reload the savestate and apply edits (which modify header offsets),
-- the game's own initialization code will set ALL globals correctly from our
-- modified header. This eliminates the need to manually track and update
-- every global variable.
--
-- Previously we captured when effect_data_ptr was written (DURING init), which
-- meant some globals were set, others not yet - and we had to manually update
-- them all (missing some, causing the emitter append bug).

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected to avoid circular deps)
--------------------------------------------------------------------------------

local MemUtils = nil
local log = function(msg) print("[EE] " .. msg) end
local log_error = function(msg) print("[EE ERROR] " .. msg) end

function M.set_dependencies(mem_utils, log_fn, error_fn)
    MemUtils = mem_utils
    log = log_fn
    log_error = error_fn
end

-- Callback for loading from memory (set by main to avoid circular dep)
M.on_capture_callback = nil

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- EXECUTION breakpoint: Start of caseD_3 in effect_system_main_loop
-- At this point: effect file loaded, but NO globals initialized from header yet
M.CASED3_START_ADDRESS = 0x801a1964

-- For reference (old approach - no longer used as primary):
M.EFFECT_DATA_PTR_GLOBAL = 0x801BBF88   -- Written during caseD_3 init sequence

M.EFFECT_BASE_LOOKUP_TABLE = 0x801B48D0 -- Array of effect base addresses
M.CURRENT_EFFECT_INDEX = 0x801C24D0     -- Current effect index

--------------------------------------------------------------------------------
-- Internal Callback
--------------------------------------------------------------------------------

-- Called when execution reaches start of caseD_3 (BEFORE globals are set)
local function on_effect_init_start(addr, width, cause)
    if not EFFECT_EDITOR.capture_armed then
        return true  -- Keep breakpoint but don't act
    end

    -- CRITICAL: Pause emulator FIRST before any memory operations
    PCSX.pauseEmulator()
    log("Emulator paused for capture")

    MemUtils.refresh_mem()

    -- Read the effect index and base address
    local effect_idx = MemUtils.read16(M.CURRENT_EFFECT_INDEX)
    local effect_base = MemUtils.read32(M.EFFECT_BASE_LOOKUP_TABLE + effect_idx * 4)

    -- Validate
    if effect_base < 0x80000000 or effect_base > 0x801FFFFF then
        log_error(string.format("Invalid effect base: 0x%08X", effect_base))
        return true
    end

    -- Success! Capture the base address
    EFFECT_EDITOR.memory_base = effect_base
    EFFECT_EDITOR.last_captured_effect_id = effect_idx
    EFFECT_EDITOR.effect_id = effect_idx  -- Sync effect_id for save/load UI
    EFFECT_EDITOR.capture_armed = false  -- Disarm after capture

    local msg = string.format("CAPTURED! E%03d @ 0x%08X", effect_idx, effect_base)
    log(msg)
    EFFECT_EDITOR.status_msg = msg

    -- Parse from memory (already paused, safe to read)
    log("Parsing effect from memory...")
    if M.on_capture_callback then
        M.on_capture_callback(effect_base)
    end

    print("")
    print("=== EFFECT CAPTURED - EMULATOR PAUSED ===")
    print(string.format("Effect E%03d loaded at 0x%08X", effect_idx, effect_base))
    print("")
    print("Next steps:")
    print("  1. Enter a session name in GUI")
    print("  2. Click 'Save' to create session")
    print("  3. Edit parameters, Save again to update")
    print("  4. Resume (F5/F6) to see changes")
    print("")

    return true  -- Keep breakpoint alive
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Arm the capture system
function M.arm_capture()
    -- Clear any existing breakpoint
    if EFFECT_CAPTURE_BP then
        pcall(function() EFFECT_CAPTURE_BP:disable() end)
    end

    -- Create EXECUTION breakpoint at start of caseD_3 (effect_system_main_loop)
    -- This triggers BEFORE any header-based globals are set, so when we modify
    -- the header offsets and resume, the game sets all globals correctly.
    EFFECT_CAPTURE_BP = PCSX.addBreakpoint(
        M.CASED3_START_ADDRESS,  -- 0x801a1964
        'Exec',                   -- Execution breakpoint, not Write!
        4,
        'EffectCapture',
        on_effect_init_start
    )

    EFFECT_EDITOR.capture_armed = true
    local msg = "Capture ARMED - cast a spell to capture!"
    log(msg)
    EFFECT_EDITOR.status_msg = msg

    print("")
    print("=== CAPTURE ARMED (Early Capture Mode) ===")
    print("Cast a spell in battle - the effect will be captured BEFORE")
    print("globals are initialized. This allows clean header modification.")
    print("The emulator will pause automatically.")
    print("")
end

-- Disarm capture
function M.disarm_capture()
    EFFECT_EDITOR.capture_armed = false
    log("Capture disarmed")
    EFFECT_EDITOR.status_msg = "Capture disarmed"
end

-- Clean up breakpoints
function M.cleanup_capture()
    if EFFECT_CAPTURE_BP then
        pcall(function() EFFECT_CAPTURE_BP:disable() end)
        EFFECT_CAPTURE_BP = nil
    end
    EFFECT_EDITOR.capture_armed = false
    log("Capture breakpoint removed")
end

return M
