-- note_capture.lua
-- Records individual SMD note events (opcodes 0x00-0x7F) during sound playback
-- Deeper than sound_capture which only logs play_sound calls
--
-- Hook points:
--   Note handler (0x80015428) - Inside SMD interpreter (FUN_80015324)
--   update_all_particles (0x801A2EB4) - frame counting ($a0 = EffectState*)
--
-- Available data:
--   $a1 = velocity (low byte, 0x00-0x7F)
--   $s0 = channel voice state pointer
--   $s0+0x7a = instrument (byte, set by AC opcode)
--   $s0+0x7c = key/base note (byte, MIDI-like)
--   $s0+0x7e = octave×12 (16-bit, e.g., 36=oct3, 48=oct4, 60=oct5)
--   $s0+0x86 = pitch_bend (16-bit signed)

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

M.NOTE_HANDLER_ADDR = 0x80015428
M.UPDATE_PARTICLES_ADDR = 0x801A2EB4  -- $a0 = EffectState*, frame counter valid here
M.FRAME_COUNTER_OFFSET = 0x20         -- Offset to frame_counter in EffectState

--------------------------------------------------------------------------------
-- State (stored in global to avoid GC)
--------------------------------------------------------------------------------

if not NOTE_CAPTURE then
    NOTE_CAPTURE = {
        recording = false,
        notes = {},
        note_count = 0,
        frame_count = 0,
        current_effect_frame = 0,  -- actual effect frame from EffectState
    }
end

--------------------------------------------------------------------------------
-- Breakpoint Callbacks
--------------------------------------------------------------------------------

-- Frame update - fires when effect processes particles (reads actual frame from EffectState)
local function on_frame_update(addr, width, cause)
    if not NOTE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local effect_state_ptr = regs.GPR.n.a0

    -- Read actual frame counter from EffectState at $a0 + 0x20
    if MemUtils and effect_state_ptr >= 0x80000000 then
        NOTE_CAPTURE.current_effect_frame = MemUtils.read32(effect_state_ptr + M.FRAME_COUNTER_OFFSET)
    end

    NOTE_CAPTURE.frame_count = NOTE_CAPTURE.frame_count + 1
    return true
end

-- Note trigger - fires when SMD interpreter processes a note (opcode < 0x80)
local function on_note_trigger(addr, width, cause)
    if not NOTE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()

    -- $a1 = velocity (masked to byte)
    local velocity = regs.GPR.n.a1 % 256

    -- $s0 = channel voice state pointer
    local channel_ptr = regs.GPR.n.s0

    -- Read channel data from memory
    local instrument = 0
    local octave = 0
    local key = 0
    local pitch_bend = 0
    if MemUtils and channel_ptr >= 0x80000000 then
        -- Read instrument (byte at +0x7a, set by AC opcode)
        instrument = MemUtils.read8(channel_ptr + 0x7a)

        -- Read key/base note (byte at +0x7c)
        key = MemUtils.read8(channel_ptr + 0x7c)

        -- Read octave×12 (16-bit at +0x7e), divide by 12 for display
        local octave_raw = MemUtils.read16(channel_ptr + 0x7e)
        octave = math.floor(octave_raw / 12)

        -- Read pitch bend (16-bit signed at +0x86)
        pitch_bend = MemUtils.read16s(channel_ptr + 0x86)
    end

    NOTE_CAPTURE.note_count = NOTE_CAPTURE.note_count + 1

    local note = {
        seq = NOTE_CAPTURE.note_count,
        frame = NOTE_CAPTURE.current_effect_frame,  -- actual effect frame from EffectState
        system_time = os.clock(),                   -- wall clock for timing analysis
        velocity = velocity,
        instrument = instrument,
        octave = octave,
        key = key,
        pitch_bend = pitch_bend,
        channel_ptr = channel_ptr,
    }
    table.insert(NOTE_CAPTURE.notes, note)

    return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.start_capture()
    -- Clear any existing breakpoints
    if NOTE_CAPTURE_BP then
        pcall(function() NOTE_CAPTURE_BP:disable() end)
    end
    if NOTE_CAPTURE_FRAME_BP then
        pcall(function() NOTE_CAPTURE_FRAME_BP:disable() end)
    end

    -- Reset state
    NOTE_CAPTURE.recording = true
    NOTE_CAPTURE.notes = {}
    NOTE_CAPTURE.note_count = 0
    NOTE_CAPTURE.frame_count = 0
    NOTE_CAPTURE.current_effect_frame = 0

    -- Create frame update breakpoint (reads actual effect frame from EffectState)
    NOTE_CAPTURE_FRAME_BP = PCSX.addBreakpoint(
        M.UPDATE_PARTICLES_ADDR, 'Exec', 4, 'NoteFrameUpdate', on_frame_update
    )

    -- Create note trigger breakpoint
    NOTE_CAPTURE_BP = PCSX.addBreakpoint(
        M.NOTE_HANDLER_ADDR, 'Exec', 4, 'NoteCapture', on_note_trigger
    )

    print("[NoteCapture] Recording started")
end

function M.stop_capture()
    NOTE_CAPTURE.recording = false
    print(string.format("[NoteCapture] Stopped: %d notes over %d frames",
        NOTE_CAPTURE.note_count, NOTE_CAPTURE.frame_count))
end

function M.is_capturing()
    return NOTE_CAPTURE.recording
end

function M.get_count()
    return NOTE_CAPTURE.note_count
end

function M.print_log(filter_ptrs)
    local notes = NOTE_CAPTURE.notes

    if #notes == 0 then
        print("[NoteCapture] No notes recorded")
        return
    end

    -- Filter notes if filter_ptrs provided
    -- filter_ptrs format: {[note_channel_ptr] = trigger_frame, ...}
    -- Only include notes where: ChPtr matches AND frame >= trigger_frame
    local filtered_notes = {}
    if filter_ptrs then
        for _, n in ipairs(notes) do
            local trigger_frame = filter_ptrs[n.channel_ptr]
            if trigger_frame and n.frame >= trigger_frame then
                table.insert(filtered_notes, n)
            end
        end
    else
        filtered_notes = notes
    end

    local filter_info = ""
    if filter_ptrs then
        filter_info = string.format(" (filtered from %d)", #notes)
    end

    print("")
    print(string.format("=== Notes (%d total%s, %d frames) ===",
        #filtered_notes, filter_info, NOTE_CAPTURE.frame_count))
    print("")
    print("Seq | Frame | Time(s) | Inst | Oct | Key | Vel | PBend | ChPtr")
    print("----|-------|---------|------|-----|-----|-----|-------|----------")

    -- Calculate base time for relative display
    local base_time = filtered_notes[1] and filtered_notes[1].system_time or 0

    for _, n in ipairs(filtered_notes) do
        local rel_time = (n.system_time or 0) - base_time
        print(string.format("%3d | %5d | %7.3f | %4d | %3d | %3d | %3d | %5d | %08X",
            n.seq, n.frame, rel_time, n.instrument or 0, n.octave, n.key or 0, n.velocity, n.pitch_bend, n.channel_ptr))
    end

    print("")
    print("=== End Notes ===")
    print("")
end

function M.cleanup()
    if NOTE_CAPTURE_BP then
        pcall(function() NOTE_CAPTURE_BP:disable() end)
        NOTE_CAPTURE_BP = nil
    end
    if NOTE_CAPTURE_FRAME_BP then
        pcall(function() NOTE_CAPTURE_FRAME_BP:disable() end)
        NOTE_CAPTURE_FRAME_BP = nil
    end
    NOTE_CAPTURE.recording = false
end

return M
