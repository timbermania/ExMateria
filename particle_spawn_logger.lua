-- particle_spawn_logger.lua
-- Records particle spawn events by breakpointing emitter_control_routine
--
-- Usage:
--   1. Arm recording with arm_recording() or UI button
--   2. Let effect play (emulator running)
--   3. Stop recording with disarm_recording() or UI button
--   4. Print log with print_log() or UI button

local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- emitter_control: Main particle spawning routine entry point
-- Signature: void emitter_control(s16 effect_idx, s32 frame_counter, s16 emitter_idx, void* parent)
-- At entry: $a0 = effect_idx, $a1 = frame_counter, $a2 = emitter_idx, $a3 = parent
M.EMITTER_CONTROL_ENTRY = 0x801A60AC

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = {
    recording = false,
    spawn_log = {},      -- Array of spawn records
    start_time = 0,      -- os.clock() when recording started
}

--------------------------------------------------------------------------------
-- Breakpoint Callback
--------------------------------------------------------------------------------

local function on_spawn(addr, width, cause)
    if not state.recording then
        return true  -- Keep breakpoint but don't log
    end

    -- Read registers (per STRUCTURE_DEFINITIONS.md signature)
    -- $a0 = effect_idx, $a1 = frame_counter, $a2 = emitter_idx, $a3 = parent
    local regs = PCSX.getRegisters()
    local effect_idx = regs.GPR.n.a0
    local frame = regs.GPR.n.a1
    local emitter_idx = regs.GPR.n.a2
    local parent_ptr = regs.GPR.n.a3

    -- Record spawn event
    local record = {
        effect_idx = effect_idx,
        frame = frame,
        emitter_idx = emitter_idx,
        parent_ptr = parent_ptr,
        elapsed = os.clock() - state.start_time,
    }
    table.insert(state.spawn_log, record)

    return true  -- Keep breakpoint alive
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Start recording spawn events
function M.arm_recording()
    -- Clear any existing breakpoint
    if PARTICLE_SPAWN_LOG_BP then
        pcall(function() PARTICLE_SPAWN_LOG_BP:disable() end)
    end

    -- Clear log and start fresh
    state.spawn_log = {}
    state.start_time = os.clock()
    state.recording = true

    -- Create execution breakpoint at emitter_control entry
    PARTICLE_SPAWN_LOG_BP = PCSX.addBreakpoint(
        M.EMITTER_CONTROL_ENTRY,
        'Exec',
        4,
        'SpawnLog',
        on_spawn
    )

    print("[SpawnLog] Recording started")
end

-- Stop recording (keep breakpoint for potential re-arm)
function M.disarm_recording()
    state.recording = false
    print(string.format("[SpawnLog] Recording stopped (%d spawns logged)", #state.spawn_log))
end

-- Clear the log
function M.clear_log()
    state.spawn_log = {}
    print("[SpawnLog] Log cleared")
end

-- Check if currently recording
function M.is_recording()
    return state.recording
end

-- Get spawn count
function M.get_spawn_count()
    return #state.spawn_log
end

-- Print log as CSV to console
function M.print_log()
    if #state.spawn_log == 0 then
        print("[SpawnLog] No spawns recorded")
        return
    end

    print("")
    print(string.format("=== Particle Spawn Log (%d events) ===", #state.spawn_log))
    print("")
    print("  #, Emu, Frame, ParentPtr,  Elapsed(s), EffIdx")
    print("------------------------------------------------")

    for i, rec in ipairs(state.spawn_log) do
        print(string.format("%3d, %3d, %5d, 0x%08X, %10.3f, %6d",
            i,
            rec.emitter_idx,
            rec.frame,
            rec.parent_ptr,
            rec.elapsed,
            rec.effect_idx
        ))
    end

    print("")
    print("=== End Spawn Log ===")
    print("")
end

-- Get raw log data (for UI or further processing)
function M.get_log()
    return state.spawn_log
end

-- Cleanup breakpoint
function M.cleanup()
    if PARTICLE_SPAWN_LOG_BP then
        pcall(function() PARTICLE_SPAWN_LOG_BP:disable() end)
        PARTICLE_SPAWN_LOG_BP = nil
    end
    state.recording = false
    print("[SpawnLog] Cleanup complete")
end

return M
