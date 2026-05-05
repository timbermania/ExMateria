-- audio_record.lua
-- Reliable music muting for audio capture
-- Uses MIPS hook to mute music while preserving effect sounds

local M = {}

-- Dependencies (injected)
local MemUtils = nil

-- MIPS hook addresses
local MUTE_CODE_ADDR = 0x80150AB0   -- Unused BATTLE.BIN padding for hook code
local MUTE_HOOK_ADDR = 0x80015428   -- Note handler address to patch
local EFFECT_SEQ_ADDR = 0x800370E0  -- Effect seq player - ONLY allow this address

-- Saved state for restoration
local mute_original_instr = nil

function M.set_dependencies(mem_utils, cfg)
    MemUtils = mem_utils
end

--------------------------------------------------------------------------------
-- Music Muting via MIPS Hook
--------------------------------------------------------------------------------

-- Install MIPS hook that mutes music but preserves effect sounds
-- Hook checks if $s3 >= MUSIC_SEQ_ADDR (music) and zeros volume if so
function M.mute_music()
    if not MemUtils then return false end
    MemUtils.refresh_mem()

    -- Save original instruction at hook point
    mute_original_instr = MemUtils.read32(MUTE_HOOK_ADDR)

    -- Hook code: Allow sounds from effect seq player EXCEPT blacklisted resource_ids
    -- Blacklist: 0 (unknown), 283 (casting sounds)
    -- NOTE: MIPS R3000 has load delay slots - must have nop after lhu before using $t0!
    --
    --   [0] lui $t0, 0x8003          # $t0 = 0x80030000
    --   [1] ori $t0, $t0, 0x70E0     # $t0 = 0x800370E0 (effect seq player)
    --   [2] xor $t0, $s3, $t0        # $t0 = 0 if $s3 == effect addr
    --   [3] bne $t0, $zero, +11      # if NOT effect addr, goto mute [15]
    --   [4] nop
    --   [5] lhu $t0, -0x158($s0)     # load sound's resource_id
    --   [6] nop                      # LOAD DELAY SLOT - required!
    --   [7] beq $t0, $zero, +7       # if resource == 0, goto mute [15]
    --   [8] nop
    --   [9] ori $t1, $zero, 283      # blacklist: 283 (casting sounds)
    --  [10] beq $t0, $t1, +4         # if resource == 283, goto mute [15]
    --  [11] nop
    --  [12] nop                      # <-- ALLOWED ONLY (breakpoint target!)
    --  [13] j 0x80150AF0 [16]         # skip mute
    --  [14] nop
    --  [15] sh $zero, 0x92($s0)      # do_mute: MUTE
    --  [16] lhu $v1, 0x2c($s0)       # after_mute: original instruction
    --  [17] j 0x80015430             # continue after hook
    --  [18] nop
    local code = {
        0x3C088003,  -- [0] lui $t0, 0x8003
        0x350870E0,  -- [1] ori $t0, $t0, 0x70E0 (= 0x800370E0)
        0x02684026,  -- [2] xor $t0, $s3, $t0
        0x1500000B,  -- [3] bne $t0, $zero, +11 (to [15] do_mute)
        0x00000000,  -- [4] nop
        0x9608FEA8,  -- [5] lhu $t0, -0x158($s0) - load sound's resource_id
        0x00000000,  -- [6] nop - LOAD DELAY SLOT
        0x11000007,  -- [7] beq $t0, $zero, +7 (to [15] do_mute) - mute if res=0
        0x00000000,  -- [8] nop
        0x3409011B,  -- [9] ori $t1, $zero, 283 (0x11B) - blacklist casting
        0x11090004,  -- [10] beq $t0, $t1, +4 (to [15] do_mute) - mute if res=283
        0x00000000,  -- [11] nop
        0x00000000,  -- [12] nop  <-- ALLOWED ONLY
        0x080542BC,  -- [13] j 0x80150AF0 (to [16] after_mute)
        0x00000000,  -- [14] nop
        0xA6000092,  -- [15] sh $zero, 0x92($s0)  do_mute: MUTE
        0x9603002C,  -- [16] lhu $v1, 0x2c($s0)  after_mute: original
        0x0800550C,  -- [17] j 0x80015430
        0x00000000,  -- [18] nop
    }

    -- Write hook code to memory
    for i, instr in ipairs(code) do
        MemUtils.write32(MUTE_CODE_ADDR + (i - 1) * 4, instr)
    end

    -- Patch note handler to jump to our hook
    local jump_instr = 0x08000000 + math.floor((MUTE_CODE_ADDR - 0x80000000) / 4)
    MemUtils.write32(MUTE_HOOK_ADDR, jump_instr)

    EFFECT_EDITOR.audio_music_muted = true
    -- Note: removed verbose print to avoid spam during capture loops
    return true
end

-- Remove MIPS hook and restore original instruction
function M.unmute_music()
    if not MemUtils then return false end
    MemUtils.refresh_mem()

    if mute_original_instr then
        MemUtils.write32(MUTE_HOOK_ADDR, mute_original_instr)
    end

    mute_original_instr = nil
    EFFECT_EDITOR.audio_music_muted = false
    return true
end

-- Check if music is currently muted
function M.is_muted()
    return EFFECT_EDITOR.audio_music_muted == true
end

--------------------------------------------------------------------------------
-- Debug: EXEC Breakpoints Inside the Hook
--------------------------------------------------------------------------------

-- Global breakpoint handles (MUST be global to prevent GC)
HOOK_DEBUG_BP_ENTRY = nil
HOOK_DEBUG_BP_MUTE = nil

-- Counters
local hook_entry_count = 0
local hook_mute_count = 0

-- Instruction addresses in hook layout (blacklist: res=0, res=283, with load delay):
-- [5] lhu $t0, -0x158($s0) = EFFECT_SEQ (after s3 check, before blacklist checks)
-- [12] nop = ALLOWED ONLY (0x80150AE0)
-- [15] sh $zero, 0x92($s0) = MUTE (0x80150AEC)
local EFFECT_SEQ_INSTR_ADDR = MUTE_CODE_ADDR + 5 * 4   -- 0x80150AC4
local ALLOWED_INSTR_ADDR = MUTE_CODE_ADDR + 12 * 4     -- 0x80150AE0
local MUTE_INSTR_ADDR = MUTE_CODE_ADDR + 15 * 4        -- 0x80150AEC

-- Mode: "count" (just count), "break" (pause on allowed), "log" (log resource_ids)
local debug_mode = "count"

-- Global for allowed breakpoint
HOOK_DEBUG_BP_ALLOWED = nil
local hook_allowed_count = 0

-- Global for effect seq breakpoint (after s3 check, all effect seq player sounds)
HOOK_DEBUG_BP_EFFECT_SEQ = nil
local hook_effect_seq_count = 0
local effect_seq_resource_ids = {}  -- track unique resource_ids seen

-- Helper to read resource_id from current sound (reads $s0 register, then memory)
local function get_current_resource_id()
    local regs = PCSX.getRegisters()
    local s0 = regs.GPR.n.s0
    if s0 and s0 >= 0x80000000 then
        MemUtils.refresh_mem()
        return MemUtils.read16(s0 - 0x158)
    end
    return nil
end

-- Start debug breakpoints
-- mode: "count" = just count, "break" = pause on allowed sounds
function M.start_hook_debug(mode)
    debug_mode = mode or "count"

    -- Clear any existing breakpoints
    M.stop_hook_debug()
    hook_entry_count = 0
    hook_mute_count = 0
    hook_allowed_count = 0
    hook_effect_seq_count = 0
    effect_seq_resource_ids = {}

    print(string.format("[AudioRecord] Breakpoints: entry=0x%08X, effect_seq=0x%08X, allowed=0x%08X, mute=0x%08X, mode=%s",
        MUTE_CODE_ADDR, EFFECT_SEQ_INSTR_ADDR, ALLOWED_INSTR_ADDR, MUTE_INSTR_ADDR, debug_mode))

    -- Entry breakpoint - ALL sounds
    HOOK_DEBUG_BP_ENTRY = PCSX.addBreakpoint(
        MUTE_CODE_ADDR, "Exec", 4, "HookEntry",
        function()
            hook_entry_count = hook_entry_count + 1
            return true
        end
    )

    -- Effect seq breakpoint - ALL sounds from effect seq player (casting + effect)
    -- Fires after s3 check passes, before resource_id check
    HOOK_DEBUG_BP_EFFECT_SEQ = PCSX.addBreakpoint(
        EFFECT_SEQ_INSTR_ADDR, "Exec", 4, "HookEffectSeq",
        function()
            hook_effect_seq_count = hook_effect_seq_count + 1
            local res_id = get_current_resource_id()
            if res_id then
                effect_seq_resource_ids[res_id] = (effect_seq_resource_ids[res_id] or 0) + 1
            end

            if debug_mode == "break" then
                print(string.format("[AudioRecord] EFFECT_SEQ #%d res=%s - PAUSING",
                    hook_effect_seq_count, tostring(res_id)))
                PCSX.pauseEmulator()
            elseif debug_mode == "log" then
                print(string.format("[AudioRecord] EFFECT_SEQ #%d res=%s",
                    hook_effect_seq_count, tostring(res_id)))
            end

            return true
        end
    )

    -- Allowed breakpoint - ONLY allowed sounds (s3 == effect addr AND resource matches)
    HOOK_DEBUG_BP_ALLOWED = PCSX.addBreakpoint(
        ALLOWED_INSTR_ADDR, "Exec", 4, "HookAllowed",
        function()
            hook_allowed_count = hook_allowed_count + 1

            if debug_mode == "break" then
                print(string.format("[AudioRecord] ALLOWED #%d - PAUSING", hook_allowed_count))
                PCSX.pauseEmulator()
            end

            return true
        end
    )

    -- Mute breakpoint - only sounds being MUTED (no pause - too noisy from music)
    HOOK_DEBUG_BP_MUTE = PCSX.addBreakpoint(
        MUTE_INSTR_ADDR, "Exec", 4, "HookMute",
        function()
            hook_mute_count = hook_mute_count + 1
            return true
        end
    )

    return true
end

-- Get the current counts
function M.get_hook_count()
    print(string.format("[AudioRecord] entry=%d, allowed=%d, muted=%d",
        hook_entry_count, hook_allowed_count, hook_mute_count))
    return hook_entry_count, hook_allowed_count, hook_mute_count
end

-- Response file for bridge communication
local BRIDGE_RESPONSE_FILE = (os.getenv("APPDATA") or os.getenv("HOME") or ".") .. "/pcsx-redux/bridge_response.txt"

-- Get counts AND write to response file (for Python bridge)
function M.get_hook_count_response()
    local response = string.format("COUNTS:{entry=%d,allowed=%d,muted=%d}",
        hook_entry_count, hook_allowed_count, hook_mute_count)

    print("[AudioRecord] " .. response)

    local f = io.open(BRIDGE_RESPONSE_FILE, "w")
    if f then
        f:write(response)
        f:close()
    end

    return hook_entry_count, hook_allowed_count, hook_mute_count
end

-- Get resource_id breakdown from effect seq player sounds
function M.get_resource_id_breakdown()
    print(string.format("[AudioRecord] Effect seq player sounds: %d total", hook_effect_seq_count))
    print("[AudioRecord] Resource IDs seen:")

    local parts = {}
    for res_id, count in pairs(effect_seq_resource_ids) do
        print(string.format("  resource_id=%d: %d sounds", res_id, count))
        table.insert(parts, string.format("%d=%d", res_id, count))
    end

    -- Write to response file for bridge
    local response = string.format("RESOURCE_IDS:{total=%d,%s}",
        hook_effect_seq_count, table.concat(parts, ","))
    local f = io.open(BRIDGE_RESPONSE_FILE, "w")
    if f then
        f:write(response)
        f:close()
    end

    return effect_seq_resource_ids
end

-- Stop debug breakpoints
function M.stop_hook_debug()
    if HOOK_DEBUG_BP_ENTRY then
        pcall(function() HOOK_DEBUG_BP_ENTRY:disable() end)
        HOOK_DEBUG_BP_ENTRY = nil
    end
    if HOOK_DEBUG_BP_EFFECT_SEQ then
        pcall(function() HOOK_DEBUG_BP_EFFECT_SEQ:disable() end)
        HOOK_DEBUG_BP_EFFECT_SEQ = nil
    end
    if HOOK_DEBUG_BP_ALLOWED then
        pcall(function() HOOK_DEBUG_BP_ALLOWED:disable() end)
        HOOK_DEBUG_BP_ALLOWED = nil
    end
    if HOOK_DEBUG_BP_MUTE then
        pcall(function() HOOK_DEBUG_BP_MUTE:disable() end)
        HOOK_DEBUG_BP_MUTE = nil
    end
end

return M
