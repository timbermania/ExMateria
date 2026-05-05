-- sound_capture.lua
-- Records every play_sound call with runtime metadata
-- Tracks frame via update_all_particles breakpoint (reads actual effect frame counter)
--
-- Hook points:
--   play_sound (0x800125a8) - sound trigger
--   update_all_particles (0x801A2EB4) - frame counting ($a0 = EffectState*)
--
-- $a0 = sound_data_address = (resource_id << 16) | config_value

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

M.PLAY_SOUND_ADDR = 0x800125a8
M.UPDATE_PARTICLES_ADDR = 0x801A2EB4  -- $a0 = EffectState*, frame counter valid here
M.LOOKUP_SOUND_EFFECT_ADDR = 0x801A32E8  -- $a0 = timeline channel index (0-3)
M.FRAME_COUNTER_OFFSET = 0x20         -- Offset to frame_counter in EffectState
M.CHANNEL_BASE_PTR = 0x80032a60       -- DAT_80032a60 holds sound channel array base
M.NOTE_CHPTR_OFFSET = 0x12E           -- Offset from sound instance to note handler's $s0

--------------------------------------------------------------------------------
-- State (stored in global to avoid GC)
--------------------------------------------------------------------------------

if not SOUND_CAPTURE then
    SOUND_CAPTURE = {
        recording = false,
        triggers = {},
        trigger_count = 0,
        frame_count = 0,
        current_effect_frame = 0,  -- actual effect frame from EffectState
        pending_timeline_channel = nil,  -- captured from lookup_sound_effect
    }
end

--------------------------------------------------------------------------------
-- Breakpoint Callbacks
--------------------------------------------------------------------------------

-- Lookup sound effect - captures timeline channel index from $a0
local function on_lookup_sound(addr, width, cause)
    if not SOUND_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    -- $a0 = timeline channel index (0-3)
    SOUND_CAPTURE.pending_timeline_channel = regs.GPR.n.a0 % 4
    return true
end

-- Frame update - fires when effect processes particles (reads actual frame from EffectState)
local function on_frame_update(addr, width, cause)
    if not SOUND_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local effect_state_ptr = regs.GPR.n.a0

    -- Read actual frame counter from EffectState at $a0 + 0x20
    if MemUtils and effect_state_ptr >= 0x80000000 then
        SOUND_CAPTURE.current_effect_frame = MemUtils.read32(effect_state_ptr + M.FRAME_COUNTER_OFFSET)
    end

    SOUND_CAPTURE.frame_count = SOUND_CAPTURE.frame_count + 1
    return true
end

-- Sound trigger
local function on_play_sound(addr, width, cause)
    if not SOUND_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local sound_data_addr = regs.GPR.n.a0

    -- Extract config value (low 16 bits) and resource ID (high 16 bits)
    local config_value = sound_data_addr % 0x10000
    local resource_id = math.floor(sound_data_addr / 0x10000)

    -- Calculate file channels from config
    -- config 1 -> pair 0 -> [0,1], config 2 -> [2,3], etc.
    local pair_index = config_value - 1
    local channel_even = pair_index * 2
    local channel_odd = channel_even + 1

    -- Calculate channel_ptr from config value
    -- Formula derived from feds_channel_resolver disassembly:
    -- channel_ptr = base + (config * 0x160) + 0xEC
    local channel_ptr = 0
    local note_channel_ptr = 0
    if MemUtils then
        local base = MemUtils.read32(M.CHANNEL_BASE_PTR)
        channel_ptr = base + (config_value * 0x160) + 0xEC
        -- note_channel_ptr is what note_capture sees in $s0 (offset by 0x12E)
        note_channel_ptr = channel_ptr + M.NOTE_CHPTR_OFFSET
    end

    SOUND_CAPTURE.trigger_count = SOUND_CAPTURE.trigger_count + 1

    -- Get timeline channel from lookup_sound_effect (captured just before play_sound)
    local timeline_channel = SOUND_CAPTURE.pending_timeline_channel or -1
    SOUND_CAPTURE.pending_timeline_channel = nil  -- Clear after use

    local trigger = {
        seq = SOUND_CAPTURE.trigger_count,
        frame = SOUND_CAPTURE.current_effect_frame,  -- actual effect frame from EffectState
        system_time = os.clock(),                    -- wall clock for timing analysis
        timeline_channel = timeline_channel,         -- actual timeline channel (0-3)
        config_value = config_value,                 -- feds pair selector (1-4)
        resource_id = resource_id,
        file_channels = {channel_even, channel_odd},
        channel_ptr = channel_ptr,
        note_channel_ptr = note_channel_ptr,         -- for joining with note_capture
    }
    table.insert(SOUND_CAPTURE.triggers, trigger)

    return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.start_capture()
    -- Clear any existing breakpoints
    if SOUND_CAPTURE_BP then
        pcall(function() SOUND_CAPTURE_BP:disable() end)
    end
    if SOUND_CAPTURE_FRAME_BP then
        pcall(function() SOUND_CAPTURE_FRAME_BP:disable() end)
    end
    if SOUND_CAPTURE_LOOKUP_BP then
        pcall(function() SOUND_CAPTURE_LOOKUP_BP:disable() end)
    end

    -- Reset state
    SOUND_CAPTURE.recording = true
    SOUND_CAPTURE.triggers = {}
    SOUND_CAPTURE.trigger_count = 0
    SOUND_CAPTURE.frame_count = 0
    SOUND_CAPTURE.current_effect_frame = 0
    SOUND_CAPTURE.pending_timeline_channel = nil

    -- Create frame update breakpoint (reads actual effect frame from EffectState)
    SOUND_CAPTURE_FRAME_BP = PCSX.addBreakpoint(
        M.UPDATE_PARTICLES_ADDR, 'Exec', 4, 'SoundFrameUpdate', on_frame_update
    )

    -- Create lookup_sound_effect breakpoint (captures timeline channel from $a0)
    SOUND_CAPTURE_LOOKUP_BP = PCSX.addBreakpoint(
        M.LOOKUP_SOUND_EFFECT_ADDR, 'Exec', 4, 'SoundLookup', on_lookup_sound
    )

    -- Create sound trigger breakpoint
    SOUND_CAPTURE_BP = PCSX.addBreakpoint(
        M.PLAY_SOUND_ADDR, 'Exec', 4, 'SoundCapture', on_play_sound
    )

    print("[SoundCapture] Recording started")
end

function M.stop_capture()
    SOUND_CAPTURE.recording = false
    print(string.format("[SoundCapture] Stopped: %d triggers over %d frames",
        SOUND_CAPTURE.trigger_count, SOUND_CAPTURE.frame_count))
end

function M.is_capturing()
    return SOUND_CAPTURE.recording
end

function M.get_count()
    return SOUND_CAPTURE.trigger_count
end

function M.print_log()
    local triggers = SOUND_CAPTURE.triggers

    if #triggers == 0 then
        print("[SoundCapture] No triggers recorded")
        return
    end

    print("")
    print(string.format("=== Sound Triggers (%d total, %d frames) ===",
        #triggers, SOUND_CAPTURE.frame_count))
    print("")
    print("Seq | Frame | Time(s) | Chan | Pair | ResID | FileCh | NoteChPtr")
    print("----|-------|---------|------|------|-------|--------|----------")

    -- Calculate base time for relative display
    local base_time = triggers[1] and triggers[1].system_time or 0

    for _, t in ipairs(triggers) do
        local rel_time = (t.system_time or 0) - base_time
        -- Display timeline_channel and config_value (pair selector)
        print(string.format("%3d | %5d | %7.3f | %4d | %4d | %5d | [%d, %d] | %08X",
            t.seq, t.frame, rel_time, t.timeline_channel, t.config_value, t.resource_id,
            t.file_channels[1], t.file_channels[2], t.note_channel_ptr or 0))
    end

    print("")
    print("=== End Sound Triggers ===")
    print("")
end

-- Get note_channel_ptrs with their trigger frames (for filtering note_capture)
-- Returns {[note_chptr] = trigger_frame, ...} for frame-aware filtering
function M.get_channel_ptrs()
    local ptrs = {}
    for _, t in ipairs(SOUND_CAPTURE.triggers) do
        if t.note_channel_ptr and t.note_channel_ptr > 0 then
            -- Store the frame when this channel was triggered
            -- Only keep earliest trigger frame if same channel triggered multiple times
            if not ptrs[t.note_channel_ptr] or t.frame < ptrs[t.note_channel_ptr] then
                ptrs[t.note_channel_ptr] = t.frame
            end
        end
    end
    return ptrs
end

function M.cleanup()
    if SOUND_CAPTURE_BP then
        pcall(function() SOUND_CAPTURE_BP:disable() end)
        SOUND_CAPTURE_BP = nil
    end
    if SOUND_CAPTURE_FRAME_BP then
        pcall(function() SOUND_CAPTURE_FRAME_BP:disable() end)
        SOUND_CAPTURE_FRAME_BP = nil
    end
    if SOUND_CAPTURE_LOOKUP_BP then
        pcall(function() SOUND_CAPTURE_LOOKUP_BP:disable() end)
        SOUND_CAPTURE_LOOKUP_BP = nil
    end
    SOUND_CAPTURE.recording = false
end

return M
