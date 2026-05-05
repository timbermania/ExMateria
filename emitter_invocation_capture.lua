-- emitter_invocation_capture.lua
-- Records every emitter invocation with runtime metadata
-- Static emitter data can be looked up by emitter_idx post facto
--
-- Captures:
--   seq, frame, effect_idx, emitter_idx, parent_ptr, is_child_spawn, anchor, pos, spawned
--
-- Dual breakpoints: ENTRY (0x801A60AC) and EXIT (0x801A7F54)
-- Position is read from newly spawned particles at EXIT

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (injected)
--------------------------------------------------------------------------------

local MemUtils = nil
local config = nil

function M.set_dependencies(mem_utils, config_module)
    MemUtils = mem_utils
    config = config_module
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

M.EMITTER_CONTROL_ENTRY = 0x801A60AC
M.EMITTER_CONTROL_EXIT = 0x801A7F54

-- Effect state array base and size (from wiki_articles/effect_state.txt)
local EFFECT_STATE_BASE = 0x801BF02C
local EFFECT_STATE_SIZE = 0xF8
local EFFECT_STATE_PARTICLE_COUNT = 0x1C
local EFFECT_STATE_PARTICLE_LIST_HEAD = 0xD0

--------------------------------------------------------------------------------
-- State (stored in global to avoid GC)
--------------------------------------------------------------------------------

if not EMITTER_INVOCATION_CAPTURE then
    EMITTER_INVOCATION_CAPTURE = {
        recording = false,
        invocations = {},
        pending = nil,  -- Holds ENTRY data until EXIT completes
    }
end

--------------------------------------------------------------------------------
-- Constants for reading parent particle position
--------------------------------------------------------------------------------

-- Particle struct offsets (12.12 fixed-point positions)
local PARTICLE_POS_X = 0x0C
local PARTICLE_POS_Y = 0x10
local PARTICLE_POS_Z = 0x14

-- Anchor mode names (bits 1-3 of animation_target_flag)
-- Values from scripts/check_e001_anchors.py (0x0E00 mask on packed 16-bit)
local ANCHOR_NAMES = {
    [0] = "WORLD",      -- 0x0000: World Space (absolute coordinates)
    [1] = "CURSOR",     -- 0x0200: Cursor position (targeting reticle)
    [2] = "ORIGIN",     -- 0x0400: Origin (caster position)
    [3] = "TARGET",     -- 0x0600: Target (target unit position)
    [4] = "PARENT",     -- 0x0800: Parent Particle (for child spawns)
    [5] = "CAMERA",     -- 0x0A00: Camera-relative
    [6] = "TRACKED",    -- 0x0C00: Tracked Entity
    [7] = "UNK7",       -- Unknown
}

-- Convert signed 32-bit from memory read
local function to_signed32(value)
    if value >= 0x80000000 then
        return value - 0x100000000
    end
    return value
end

-- Check if address is valid PSX RAM
local function is_valid_addr(addr)
    return addr ~= 0 and addr >= 0x80000000 and addr < 0x80200000
end

--------------------------------------------------------------------------------
-- Breakpoint Callbacks (ENTRY + EXIT)
--------------------------------------------------------------------------------

-- Look up anchor mode from loaded emitter definitions
local function get_anchor_mode(emitter_idx)
    if not EFFECT_EDITOR or not EFFECT_EDITOR.emitters then
        return -1, "?"
    end
    -- emitters are 0-indexed, but Lua table is 1-indexed
    local emitter = EFFECT_EDITOR.emitters[emitter_idx + 1]
    if not emitter then
        return -1, "?"
    end
    -- animation_target_flag bits 1-3 = anchor mode
    local anchor_bits = math.floor((emitter.animation_target_flag or 0) / 2) % 8
    return anchor_bits, ANCHOR_NAMES[anchor_bits] or "?"
end

-- ENTRY callback: capture registers and particle count BEFORE spawning
local function on_emitter_entry(addr, width, cause)
    if not EMITTER_INVOCATION_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local effect_idx = regs.GPR.n.a0
    local frame = regs.GPR.n.a1
    local emitter_idx = regs.GPR.n.a2
    local parent_ptr = regs.GPR.n.a3

    -- Calculate effect state address
    local effect_state = EFFECT_STATE_BASE + (effect_idx * EFFECT_STATE_SIZE)

    -- Read particle count BEFORE spawning
    local old_count = 0
    if MemUtils then
        old_count = MemUtils.read16(effect_state + EFFECT_STATE_PARTICLE_COUNT)
    end

    -- Look up anchor mode from emitter definition
    local anchor_bits, anchor_name = get_anchor_mode(emitter_idx)

    -- Store pending invocation (will be completed at EXIT)
    EMITTER_INVOCATION_CAPTURE.pending = {
        seq = #EMITTER_INVOCATION_CAPTURE.invocations + 1,
        frame = frame,
        effect_idx = effect_idx,
        emitter_idx = emitter_idx,
        parent_ptr = parent_ptr,
        is_child_spawn = parent_ptr ~= 0,
        anchor_mode = anchor_bits,
        anchor_name = anchor_name,
        effect_state = effect_state,
        old_particle_count = old_count,
    }

    return true
end

-- EXIT callback: read spawn position from newly created particles
local function on_emitter_exit(addr, width, cause)
    if not EMITTER_INVOCATION_CAPTURE.recording then
        return true
    end

    local pending = EMITTER_INVOCATION_CAPTURE.pending
    if not pending then
        return true
    end

    local pos_x, pos_y, pos_z = 0, 0, 0
    local spawned = 0

    if MemUtils then
        -- Read new particle count
        local new_count = MemUtils.read16(pending.effect_state + EFFECT_STATE_PARTICLE_COUNT)
        spawned = new_count - pending.old_particle_count

        -- Read position from first new particle (list head)
        if spawned > 0 then
            local list_head = MemUtils.read32(pending.effect_state + EFFECT_STATE_PARTICLE_LIST_HEAD)
            if is_valid_addr(list_head) then
                pos_x = to_signed32(MemUtils.read32(list_head + PARTICLE_POS_X)) / 4096
                pos_y = to_signed32(MemUtils.read32(list_head + PARTICLE_POS_Y)) / 4096
                pos_z = to_signed32(MemUtils.read32(list_head + PARTICLE_POS_Z)) / 4096
            end
        end
    end

    -- Complete the invocation record
    pending.pos_x = pos_x
    pending.pos_y = pos_y
    pending.pos_z = pos_z
    pending.particles_spawned = spawned

    -- Remove internal tracking fields before storing
    pending.effect_state = nil
    pending.old_particle_count = nil

    table.insert(EMITTER_INVOCATION_CAPTURE.invocations, pending)
    EMITTER_INVOCATION_CAPTURE.pending = nil

    return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.start_capture()
    -- Clear any existing breakpoints
    if EMITTER_INVOCATION_BP then
        pcall(function() EMITTER_INVOCATION_BP:disable() end)
    end
    if EMITTER_INVOCATION_BP_EXIT then
        pcall(function() EMITTER_INVOCATION_BP_EXIT:disable() end)
    end

    -- Reset state
    EMITTER_INVOCATION_CAPTURE.recording = true
    EMITTER_INVOCATION_CAPTURE.invocations = {}
    EMITTER_INVOCATION_CAPTURE.pending = nil

    -- Create ENTRY breakpoint (stored in global to prevent GC)
    EMITTER_INVOCATION_BP = PCSX.addBreakpoint(
        M.EMITTER_CONTROL_ENTRY, 'Exec', 4, 'EmitterEntry', on_emitter_entry
    )

    -- Create EXIT breakpoint
    EMITTER_INVOCATION_BP_EXIT = PCSX.addBreakpoint(
        M.EMITTER_CONTROL_EXIT, 'Exec', 4, 'EmitterExit', on_emitter_exit
    )

    print("[EmitterCapture] Recording started (dual breakpoint)")
end

function M.stop_capture()
    EMITTER_INVOCATION_CAPTURE.recording = false

    local count = #EMITTER_INVOCATION_CAPTURE.invocations
    print(string.format("[EmitterCapture] Recording stopped: %d invocations", count))
end

function M.is_capturing()
    return EMITTER_INVOCATION_CAPTURE.recording
end

function M.get_count()
    return #EMITTER_INVOCATION_CAPTURE.invocations
end

function M.export_csv(filename)
    local invocations = EMITTER_INVOCATION_CAPTURE.invocations

    if #invocations == 0 then
        print("[EmitterCapture] No data to export")
        return false
    end

    -- Default filename
    if not filename then
        if config and config.SAVESTATE_PATH and EFFECT_EDITOR and EFFECT_EDITOR.session_name ~= "" then
            filename = config.SAVESTATE_PATH .. EFFECT_EDITOR.session_name .. "_emitter_invocations.csv"
        elseif config and config.SAVESTATE_PATH then
            filename = config.SAVESTATE_PATH .. "emitter_invocations.csv"
        else
            filename = "emitter_invocations.csv"
        end
    end

    local file = io.open(filename, "w")
    if not file then
        print("[EmitterCapture] Failed to open file: " .. filename)
        return false
    end

    -- Write header
    file:write("Seq,Frame,EffIdx,EmuIdx,Anchor,Spawned,ParentPtr,IsChild,PosX,PosY,PosZ\n")

    -- Write data rows
    for _, inv in ipairs(invocations) do
        file:write(string.format("%d,%d,%d,%d,%s,%d,%08X,%s,%.1f,%.1f,%.1f\n",
            inv.seq,
            inv.frame,
            inv.effect_idx,
            inv.emitter_idx,
            inv.anchor_name or "?",
            inv.particles_spawned or 0,
            inv.parent_ptr,
            inv.is_child_spawn and "true" or "false",
            inv.pos_x or 0,
            inv.pos_y or 0,
            inv.pos_z or 0
        ))
    end

    file:close()
    print(string.format("[EmitterCapture] Exported to: %s", filename))
    return true
end

function M.print_log()
    local invocations = EMITTER_INVOCATION_CAPTURE.invocations

    if #invocations == 0 then
        print("[EmitterCapture] No invocations recorded")
        return
    end

    print("")
    print(string.format("=== Emitter Invocations (%d total) ===", #invocations))
    print("")
    print("Seq | Frame | EffIdx | EmuIdx | Anchor  | Spwnd | PosX    | PosY    | PosZ")
    print("----|-------|--------|--------|---------|-------|---------|---------|--------")

    for _, inv in ipairs(invocations) do
        print(string.format("%3d | %5d | %6d | %6d | %-7s | %5d | %7.1f | %7.1f | %7.1f",
            inv.seq,
            inv.frame,
            inv.effect_idx,
            inv.emitter_idx,
            inv.anchor_name or "?",
            inv.particles_spawned or 0,
            inv.pos_x or 0,
            inv.pos_y or 0,
            inv.pos_z or 0
        ))
    end

    print("")
    print("=== End Emitter Invocations ===")
    print("")
end

function M.cleanup()
    if EMITTER_INVOCATION_BP then
        pcall(function() EMITTER_INVOCATION_BP:disable() end)
        EMITTER_INVOCATION_BP = nil
    end
    if EMITTER_INVOCATION_BP_EXIT then
        pcall(function() EMITTER_INVOCATION_BP_EXIT:disable() end)
        EMITTER_INVOCATION_BP_EXIT = nil
    end
    EMITTER_INVOCATION_CAPTURE.recording = false
    EMITTER_INVOCATION_CAPTURE.pending = nil
    print("[EmitterCapture] Cleanup complete")
end

return M
