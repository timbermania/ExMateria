-- opcode_capture.lua
-- Records SMD opcode execution from ONLY the effect file's feds section
-- Filters by reading stored config_value from channel structure
--
-- Key insight: SMD data gets COPIED, so $a0 is NOT in feds range.
-- Each config triggers 2 parallel channel slots, so we can't reverse-calculate
-- config from slot index. Instead, read the stored config_value that
-- feds_channel_resolver saved in the channel structure (at puVar7[-0xb]).
--
-- Hook points:
--   Instrument handler (0x80015dd0): $a0=param, $a2=channel_ptr
--   Octave handler (0x800159f0): $a0=param, $a2=channel_ptr
--   Dynamics handler (0x80016614): $a0=param, $a2=channel_ptr
--   Note handler (0x80015428): $a1=velocity, $s0=channel_ptr+0x12E
--   update_all_particles (0x801A2EB4): Frame counting ($a0 = EffectState*)

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

-- SMD opcode handler addresses (from jump table at 0x80028b0c)
-- Existing handlers (need verification)
M.INSTRUMENT_HANDLER_ADDR = 0x80015dd0  -- Opcode 0xAC (or 0xA9? - see Task 0 debug)
M.OCTAVE_HANDLER_ADDR = 0x800159f0      -- Opcode 0x94
M.DYNAMICS_HANDLER_ADDR = 0x80016614    -- Opcode 0xE0
M.NOTE_HANDLER_ADDR = 0x80015428        -- Note (0x00-0x7F): $a1=velocity, $a0=stream ptr

-- New timing-related opcode handlers (verified from jump table)
M.REST_HANDLER_ADDR = 0x80015874        -- Opcode 0x80: $a0=param, $a2=channel_ptr
M.FERMATA_HANDLER_ADDR = 0x8001589c     -- Opcode 0x81: $a0=param, $a2=channel_ptr
M.ENDBAR_HANDLER_ADDR = 0x800158f8      -- Opcode 0x90: $a2=channel_ptr (no param)
M.REPEAT_HANDLER_ADDR = 0x80015ab8      -- Opcode 0x98: $a0=param, $a2=channel_ptr
M.CODA_HANDLER_ADDR = 0x80015b00        -- Opcode 0x99: $a2=channel_ptr (no param)
M.TEMPO_HANDLER_ADDR = 0x80015cb0       -- Opcode 0xA0: $a0=param, $a2=channel_ptr

-- Frame counting
M.UPDATE_PARTICLES_ADDR = 0x801A2EB4    -- $a0 = EffectState*
M.FRAME_COUNTER_OFFSET = 0x20           -- Offset to frame_counter in EffectState

-- Global pointer to loaded feds section
M.G_SOUND_SECTION_PTR = 0x801BBF74

-- feds header offsets
M.FEDS_DATA_SIZE_OFFSET = 0x04          -- uint32: total size of section
M.FEDS_DATA_OFFSET_OFFSET = 0x0C        -- uint32: offset to SMD data start

--------------------------------------------------------------------------------
-- State (stored in global to avoid GC)
--------------------------------------------------------------------------------

if not OPCODE_CAPTURE then
    OPCODE_CAPTURE = {
        recording = false,
        opcodes = {},
        opcode_count = 0,
        frame_count = 0,
        current_effect_frame = 0,
        -- Cached feds address range (updated when capture starts)
        feds_data_start = 0,
        feds_data_end = 0,
        -- Per-channel timing state for predicted frame calculation
        -- Key: file_channel (0-7), Value: {tempo, cumulative_ticks, start_frame, predicted_frame}
        channel_timing = {},
        -- Global/default tempo (used if channel hasn't set one)
        global_tempo = 102,  -- Default FFT tempo
    }
end

--------------------------------------------------------------------------------
-- Timing Model Constants (from FFHacktics wiki)
--------------------------------------------------------------------------------

-- Wiki: "Tempo 0x66 (102) appears to be 120 bpm. Exact tempo is 17.188% faster"
local TEMPO_MULTIPLIER = 1.17188

-- PSX internal tick rate for sound processing (empirically validated)
-- At 30Hz: tempo 102 → 119.5 BPM → 15 frames/beat → 3.2 ticks/frame
local INTERNAL_FPS = 30

-- Musical constants
local TICKS_PER_QUARTER_NOTE = 48  -- 192 / 4 = 48 ticks per beat
local TICKS_PER_WHOLE_NOTE = 192

--------------------------------------------------------------------------------
-- Channel pointer constants
--------------------------------------------------------------------------------

M.CHANNEL_BASE_PTR = 0x80032a60       -- DAT_80032a60 holds sound channel array base
M.CHANNEL_STRIDE = 0x160              -- Size of each channel structure
M.CHANNEL_OFFSET = 0xEC               -- Offset within structure (puVar7 in feds_channel_resolver)
M.NOTE_CHPTR_OFFSET = 0x12E           -- Additional offset for note handler's $s0

-- Stored param offsets - feds_channel_resolver stores param_2 (sound_data_addr) in channel
-- param_2 = (resource_id << 16) | config_value
-- Stored at puVar7[-0xb] = puVar7 - 0x2C
M.STORED_PARAM_OFFSET_FROM_A2 = 0x2C  -- From $a2 (channel_ptr at 0xEC offset)
M.STORED_PARAM_OFFSET_FROM_S0 = 0x15A -- From $s0 (channel_ptr + 0x12E): 0x2C + 0x12E = 0x15A

-- Channel timing offsets - from $s0 (channel_ptr + 0x12E)
-- All are SUBTRACTED from $s0 to get the actual address
M.TICK_COUNTER_OFFSET_FROM_S0 = 0xC0   -- 0x6E: tick counter (0x12E - 0x6E = 0xC0)
M.NOTE_DURATION_OFFSET_FROM_S0 = 0xBC  -- 0x72: note duration counter (0x12E - 0x72 = 0xBC)
M.REST_DURATION_OFFSET_FROM_S0 = 0xBA  -- 0x74: rest/fermata duration (0x12E - 0x74 = 0xBA)
M.COMBINED_DUR_OFFSET_FROM_S0 = 0xB8   -- 0x76: combined duration for calculation (0x12E - 0x76 = 0xB8)
M.TEMPO_OFFSET_FROM_S0 = 0xA4          -- 0x8A: tempo value (0x12E - 0x8A = 0xA4)

--------------------------------------------------------------------------------
-- Helper: Get config, pair, and file_channel from channel structure pointer
--------------------------------------------------------------------------------

-- Read the stored config_value from channel structure and calculate file channel
-- feds_channel_resolver stores param_2 (sound_data_addr) which contains config in low 16 bits
-- Each config uses 2 consecutive runtime slots:
--   Even slot → first channel of pair (file channel 0, 2, 4, 6)
--   Odd slot → second channel of pair (file channel 1, 3, 5, 7)
-- Formula: file_channel = (config - 1) * 2 + (slot % 2)
--
-- For opcode handlers ($a2): extra_offset = 0
-- For note handler ($s0): extra_offset = 0x12E
--
-- Returns: config, pair, file_channel (or nil if not an effect channel)
local function get_channel_info(ptr, extra_offset)
    if not MemUtils then return nil end

    -- Sanity check pointer
    if ptr < 0x80000000 then return nil end

    -- Calculate offset to stored param_2 based on which register we have
    local param_offset
    local structure_offset  -- Offset from base+slot*stride to ptr
    if extra_offset == M.NOTE_CHPTR_OFFSET then
        param_offset = M.STORED_PARAM_OFFSET_FROM_S0
        structure_offset = M.CHANNEL_OFFSET + M.NOTE_CHPTR_OFFSET  -- 0xEC + 0x12E = 0x21A
    else
        param_offset = M.STORED_PARAM_OFFSET_FROM_A2
        structure_offset = M.CHANNEL_OFFSET  -- 0xEC
    end

    -- Read stored param_2 (sound_data_addr) from channel structure
    -- param_2 = (resource_id << 16) | config_value
    local stored_param = MemUtils.read32(ptr - param_offset)

    -- Extract config_value from low 16 bits
    local config_value = stored_param % 0x10000

    -- Validate it's an effect sound config (1-4)
    if config_value < 1 or config_value > 4 then return nil end

    -- Calculate slot index to determine which channel within the pair
    -- ptr = base + slot * 0x160 + structure_offset
    local base = MemUtils.read32(M.CHANNEL_BASE_PTR)
    if base < 0x80000000 then return nil end

    local adjusted = ptr - base - structure_offset
    if adjusted < 0 or adjusted % M.CHANNEL_STRIDE ~= 0 then
        -- Fallback: can't determine slot, just return config/pair without file_channel
        return config_value, config_value - 1, nil
    end

    local slot = adjusted / M.CHANNEL_STRIDE

    -- Calculate file channel: (config - 1) * 2 + (slot % 2)
    local pair = config_value - 1
    local file_channel = pair * 2 + (slot % 2)

    return config_value, pair, file_channel
end

-- Backwards compatibility wrapper
local function get_config_from_channel_ptr(ptr, extra_offset)
    local config = get_channel_info(ptr, extra_offset)
    return config
end

--------------------------------------------------------------------------------
-- Helper: Read channel timing state from $s0 pointer
--------------------------------------------------------------------------------

-- Read the current timing state from channel structure
-- Returns table with: tick_counter, note_duration, rest_duration, combined_duration, tempo
-- All values are raw from memory (before our scaling)
local function get_channel_timing_state(s0_ptr)
    if not MemUtils or s0_ptr < 0x80000000 then
        return nil
    end

    return {
        tick_counter = MemUtils.read16(s0_ptr - M.TICK_COUNTER_OFFSET_FROM_S0),      -- 0x6E
        note_duration = MemUtils.read16(s0_ptr - M.NOTE_DURATION_OFFSET_FROM_S0),    -- 0x72
        rest_duration = MemUtils.read16(s0_ptr - M.REST_DURATION_OFFSET_FROM_S0),    -- 0x74
        combined_duration = MemUtils.read16(s0_ptr - M.COMBINED_DUR_OFFSET_FROM_S0), -- 0x76
        tempo = MemUtils.read16(s0_ptr - M.TEMPO_OFFSET_FROM_S0),                    -- 0x8A
    }
end

--------------------------------------------------------------------------------
-- Helper: Check if address is within feds section (for legacy/debugging)
--------------------------------------------------------------------------------

local function is_in_feds_range(addr)
    return addr >= OPCODE_CAPTURE.feds_data_start and addr < OPCODE_CAPTURE.feds_data_end
end

local function update_feds_range()
    if not MemUtils then return false end

    local feds_ptr = MemUtils.read32(M.G_SOUND_SECTION_PTR)
    if feds_ptr < 0x80000000 then
        -- No feds section loaded
        OPCODE_CAPTURE.feds_data_start = 0
        OPCODE_CAPTURE.feds_data_end = 0
        return false
    end

    local data_size = MemUtils.read32(feds_ptr + M.FEDS_DATA_SIZE_OFFSET)
    local data_offset = MemUtils.read32(feds_ptr + M.FEDS_DATA_OFFSET_OFFSET)

    -- feds data range: from data_offset to end of section
    OPCODE_CAPTURE.feds_data_start = feds_ptr + data_offset
    OPCODE_CAPTURE.feds_data_end = feds_ptr + data_size

    return true
end

--------------------------------------------------------------------------------
-- Opcode name lookup
--------------------------------------------------------------------------------

local OPCODE_NAMES = {
    [0x80] = "Rest",
    [0x81] = "Fermata",
    [0x90] = "EndBar",
    [0x91] = "Loop",
    [0x94] = "Octave",
    [0x95] = "RaiseOctave",
    [0x96] = "LowerOctave",
    [0x98] = "Repeat",
    [0x99] = "Coda",
    [0xA0] = "Tempo",
    [0xAC] = "Instrument",
    [0xB0] = "Flag_0x800",
    [0xBA] = "ReverbOn",
    [0xBB] = "ReverbOff",
    [0xC4] = "Release",
    [0xD0] = "SetPitchBend",
    [0xD1] = "AddPitchBend",
    [0xE0] = "Dynamics",
    [0xE2] = "Expression",
}

local function get_opcode_name(opcode)
    if opcode < 0x80 then
        return "Note"
    end
    return OPCODE_NAMES[opcode] or string.format("Op_%02X", opcode)
end

-- Duration table at 0x80028d8c (256 bytes)
-- Index 0 is special (0x00), then indices 1-255 cycle through a 19-byte pattern
-- When table[param] == 0, a third byte is read as raw duration
-- The 19-byte cycle (starting at index 1): [C0, 90, 60, 48, 40, 30, 24, 20, 18, 12, 10, 0C, 09, 08, 06, 04, 03, 02, 00]
local DURATION_CYCLE = {
    [0]=0xC0, 0x90, 0x60, 0x48, 0x40, 0x30, 0x24, 0x20, 0x18, 0x12, 0x10, 0x0C, 0x09, 0x08, 0x06, 0x04, 0x03, 0x02, 0x00
}

-- Musical note type names mapped from duration table values
-- Standard musical notation: whole=4 beats, half=2, quarter=1, etc.
-- Dotted notes (d.) = 1.5x, Triplets (2/3) = 2/3 of next longer note
local NOTE_TYPES = {
    [192] = "whole",    -- 0xC0: 4 beats
    [144] = "d.half",   -- 0x90: 3 beats (dotted half)
    [96]  = "half",     -- 0x60: 2 beats
    [72]  = "d.qtr",    -- 0x48: 1.5 beats (dotted quarter)
    [64]  = "2/3h",     -- 0x40: triplet half
    [48]  = "qtr",      -- 0x30: 1 beat
    [36]  = "d.8th",    -- 0x24: dotted eighth
    [32]  = "2/3q",     -- 0x20: triplet quarter
    [24]  = "8th",      -- 0x18: 0.5 beats
    [18]  = "d.16",     -- 0x12: dotted 16th
    [16]  = "2/3e",     -- 0x10: triplet eighth
    [12]  = "16th",     -- 0x0C: 0.25 beats
    [9]   = "d.32",     -- 0x09: dotted 32nd
    [8]   = "2/3s",     -- 0x08: triplet 16th
    [6]   = "32nd",     -- 0x06
    [4]   = "2/3t",     -- 0x04: triplet 32nd
    [3]   = "d.64",     -- 0x03: dotted 64th
    [2]   = "64th",     -- 0x02
    [0]   = "cust",     -- Custom: third byte has raw duration
}

local function get_note_type(duration)
    return NOTE_TYPES[duration]
end

-- Lookup duration from the game's duration table
local function lookup_duration_table(param)
    if param == 0 then
        return 0  -- Index 0 is special
    end
    local cycle_index = (param - 1) % 19  -- Indices 1-255 cycle every 19 bytes
    return DURATION_CYCLE[cycle_index] or 0
end

--------------------------------------------------------------------------------
-- Tempo-Based Timing Calculation (derived from FFHacktics wiki)
--------------------------------------------------------------------------------

-- Calculate frames from duration using tempo-based formula
-- Formula derivation:
--   actual_bpm = tempo * 1.17188
--   frames_per_beat = (INTERNAL_FPS * 60) / actual_bpm
--   ticks_per_frame = TICKS_PER_QUARTER_NOTE / frames_per_beat
--   frames = duration / ticks_per_frame
--
-- Simplified: frames = duration * INTERNAL_FPS * 60 / (TICKS_PER_QUARTER_NOTE * tempo * TEMPO_MULTIPLIER)
--           = duration * 1800 / (48 * tempo * 1.17188)
--           = duration * 32.01 / tempo
--
-- At tempo 102: frames = duration * 0.3138 (validated: rest 96 → 30.1 frames)
local function calculate_frames_from_tempo(duration_192nds, tempo)
    if duration_192nds == 0 or tempo == 0 then return 0 end
    local actual_bpm = tempo * TEMPO_MULTIPLIER
    local frames_per_minute = INTERNAL_FPS * 60  -- 1800
    local frames = duration_192nds * frames_per_minute / (TICKS_PER_QUARTER_NOTE * actual_bpm)
    return frames
end

-- Get or initialize channel timing state
local function get_channel_timing(file_channel)
    if not file_channel then return nil end

    if not OPCODE_CAPTURE.channel_timing[file_channel] then
        OPCODE_CAPTURE.channel_timing[file_channel] = {
            tempo = OPCODE_CAPTURE.global_tempo,
            cumulative_ticks = 0,      -- Blocking ticks accumulated
            start_frame = OPCODE_CAPTURE.current_effect_frame,
            predicted_frame = OPCODE_CAPTURE.current_effect_frame,
        }
    end
    return OPCODE_CAPTURE.channel_timing[file_channel]
end

-- Update channel timing after a blocking opcode (Rest/Fermata)
local function add_blocking_ticks(file_channel, ticks)
    local ch = get_channel_timing(file_channel)
    if not ch then return end

    ch.cumulative_ticks = ch.cumulative_ticks + ticks
    ch.predicted_frame = ch.start_frame + calculate_frames_from_tempo(ch.cumulative_ticks, ch.tempo)
end

-- Update channel tempo
local function set_channel_tempo(file_channel, new_tempo)
    local ch = get_channel_timing(file_channel)
    if not ch then return end

    -- Recalculate predicted frame with new tempo
    ch.tempo = new_tempo
    ch.predicted_frame = ch.start_frame + calculate_frames_from_tempo(ch.cumulative_ticks, ch.tempo)

    -- Also update global tempo (tempo often set on channel 0 for all)
    OPCODE_CAPTURE.global_tempo = new_tempo
end

-- Get current predicted frame for a channel
local function get_predicted_frame(file_channel)
    local ch = get_channel_timing(file_channel)
    if not ch then return OPCODE_CAPTURE.current_effect_frame end
    return ch.predicted_frame
end

-- Get current tempo for a channel
local function get_channel_tempo(file_channel)
    local ch = get_channel_timing(file_channel)
    if not ch then return OPCODE_CAPTURE.global_tempo end
    return ch.tempo
end

-- Timing behavior classification
-- "blocking" = opcode causes channel to wait before reading next opcode
-- "trigger" = opcode fires immediately, channel continues to next opcode
-- "control" = changes state but doesn't affect timing directly
local TIMING_BEHAVIOR = {
    [0x80] = "blocking",  -- Rest: wait for duration
    [0x81] = "blocking",  -- Fermata: extend and wait
    [0x90] = "control",   -- EndBar: stop channel
    [0x91] = "control",   -- Loop: loop indefinitely
    [0x94] = "control",   -- Octave: set octave
    [0x95] = "control",   -- RaiseOctave
    [0x96] = "control",   -- LowerOctave
    [0x98] = "control",   -- Repeat: begin loop
    [0x99] = "control",   -- Coda: end loop
    [0xA0] = "control",   -- Tempo: set tempo
    [0xAC] = "control",   -- Instrument: set instrument
    [0xE0] = "control",   -- Dynamics: set volume
    -- Notes (0x00-0x7F) are "trigger" - they play but processing continues
}

local function get_timing_behavior(opcode)
    if opcode < 0x80 then
        return "trigger"  -- Notes are triggers, not blocking
    end
    return TIMING_BEHAVIOR[opcode] or "control"
end

-- Get duration from opcode - returns (duration_ticks, has_extra_byte, timing_type)
-- timing_type: "blocking", "trigger", or nil
local function get_duration_from_param(opcode, param)
    if opcode == 0x80 then  -- Rest
        return param, false, "blocking"
    elseif opcode == 0x81 then  -- Fermata
        return param, false, "blocking"
    elseif opcode < 0x80 then  -- Note (0x00-0x7F)
        local table_val = lookup_duration_table(param)
        if table_val == 0 then
            return 0, true, "trigger"  -- Duration in third byte
        else
            return table_val, false, "trigger"  -- Musical timing (how long note sounds)
        end
    else
        return 0, false, nil  -- No duration for other opcodes
    end
end

-- Calculate frames for display (uses channel tempo)
local function estimate_frames_for_display(duration, timing_type, file_channel)
    if duration == 0 or not timing_type then return 0 end
    local tempo = get_channel_tempo(file_channel)
    return calculate_frames_from_tempo(duration, tempo)
end

--------------------------------------------------------------------------------
-- Breakpoint Callbacks
--------------------------------------------------------------------------------

-- Frame update - fires when effect processes particles
local function on_frame_update(addr, width, cause)
    if not OPCODE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local effect_state_ptr = regs.GPR.n.a0

    -- Read actual frame counter from EffectState at $a0 + 0x20
    if MemUtils and effect_state_ptr >= 0x80000000 then
        OPCODE_CAPTURE.current_effect_frame = MemUtils.read32(effect_state_ptr + M.FRAME_COUNTER_OFFSET)
    end

    -- Update feds range in case effect changed
    update_feds_range()

    OPCODE_CAPTURE.frame_count = OPCODE_CAPTURE.frame_count + 1
    return true
end

-- Generic opcode handler callback - filters by $s0 (channel state pointer, same as Note handler)
-- Key insight: $a2 points to a different offset than $s0. The Note handler uses $s0 and works,
-- so we must use $s0 for all handlers to get consistent filtering.
local function on_opcode(opcode_byte, description_fn)
    return function(addr, width, cause)
        if not OPCODE_CAPTURE.recording then
            return true
        end

        local regs = PCSX.getRegisters()
        local s0 = regs.GPR.n.s0           -- Channel state pointer (= channel_ptr + 0x12E), same as Note handler
        local smd_ptr = regs.GPR.n.a0      -- SMD param pointer (for reading value)

        -- Filter: only log if $s0 matches an effect file channel (using same method as Note handler)
        local config, pair, file_channel = get_channel_info(s0, M.NOTE_CHPTR_OFFSET)
        if not config then
            return true  -- Not an effect file channel
        end

        -- Read the parameter byte at $a0
        local param = 0
        if MemUtils and smd_ptr >= 0x80000000 then
            param = MemUtils.read8(smd_ptr)
        end

        -- Get duration info (non-Note opcodes don't have extra byte)
        local duration, has_extra_byte, timing_type = get_duration_from_param(opcode_byte, param)

        -- Get timing info BEFORE updating state
        local predicted_frame = get_predicted_frame(file_channel)
        local tempo = get_channel_tempo(file_channel)
        local timing_behavior = get_timing_behavior(opcode_byte)

        -- Calculate estimated frames using tempo-based formula
        local est_frames = estimate_frames_for_display(duration, timing_type, file_channel)

        -- Update channel timing based on opcode behavior
        if timing_behavior == "blocking" and duration > 0 then
            add_blocking_ticks(file_channel, duration)
        end

        -- Read channel timing state for debugging
        local timing_state = get_channel_timing_state(s0)

        OPCODE_CAPTURE.opcode_count = OPCODE_CAPTURE.opcode_count + 1

        local entry = {
            seq = OPCODE_CAPTURE.opcode_count,
            frame = OPCODE_CAPTURE.current_effect_frame,
            predicted_frame = predicted_frame,
            system_time = os.clock(),
            opcode = opcode_byte,
            opcode_name = get_opcode_name(opcode_byte),
            param = param,
            duration = duration,
            est_frames = est_frames,
            timing_type = timing_type,
            timing_behavior = timing_behavior,
            note_type = get_note_type(duration),
            tempo = tempo,
            pair = pair,
            config = config,
            file_channel = file_channel,
            description = description_fn(param),
            smd_ptr = smd_ptr,
            -- Channel timing state (raw from memory, for debugging)
            timing_state = timing_state,
        }
        table.insert(OPCODE_CAPTURE.opcodes, entry)

        return true
    end
end

-- Instrument handler (0xAC)
local function on_instrument(addr, width, cause)
    return on_opcode(0xAC, function(param)
        return string.format("Instrument %d", param)
    end)(addr, width, cause)
end

-- Octave handler (0x94)
local function on_octave(addr, width, cause)
    return on_opcode(0x94, function(param)
        return string.format("Octave %d", param)
    end)(addr, width, cause)
end

-- Note handler (0x00-0x7F) - filter by channel state pointer ($s0)
-- Uses unified get_config_from_channel_ptr with offset = 0x12E
-- Notes are TRIGGER opcodes - they fire immediately without blocking

local function on_note(addr, width, cause)
    if not OPCODE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local s0 = regs.GPR.n.s0  -- Channel state pointer (= channel_ptr + 0x12E)
    local velocity = regs.GPR.n.a1 % 128  -- Velocity is opcode byte (0x00-0x7F)

    -- Filter: only log if $s0 matches an effect file channel
    local config, pair, file_channel = get_channel_info(s0, M.NOTE_CHPTR_OFFSET)
    if not config then
        return true  -- Not an effect file channel
    end

    -- Read pitch/duration byte from $a2 (SMD stream pointer)
    local pitch_dur = 0
    local smd_ptr = regs.GPR.n.a2
    if MemUtils and smd_ptr >= 0x80000000 then
        pitch_dur = MemUtils.read8(smd_ptr)
    end

    -- Look up duration from table
    local duration, has_extra_byte, timing_type = get_duration_from_param(velocity, pitch_dur)

    -- If table returned 0, read the third byte as raw duration
    local extra_byte = nil
    if has_extra_byte and MemUtils and smd_ptr >= 0x80000000 then
        extra_byte = MemUtils.read8(smd_ptr + 1)
        duration = extra_byte
        timing_type = "trigger"  -- Third-byte durations still trigger behavior
    end

    -- Get timing info (notes are triggers, so predicted frame = current predicted)
    local predicted_frame = get_predicted_frame(file_channel)
    local tempo = get_channel_tempo(file_channel)

    -- Calculate estimated frames (how long the note SOUNDS, not timing gap)
    local est_frames = estimate_frames_for_display(duration, timing_type, file_channel)

    -- Notes are triggers - they do NOT add blocking ticks
    -- The note plays for its duration but opcode processing continues immediately

    -- Read channel timing state for debugging
    local timing_state = get_channel_timing_state(s0)

    OPCODE_CAPTURE.opcode_count = OPCODE_CAPTURE.opcode_count + 1

    -- Build description
    local desc
    if extra_byte then
        desc = string.format("vel=%d pitch=0x%02X dur3=%d", velocity, pitch_dur, extra_byte)
    else
        desc = string.format("vel=%d pitch=0x%02X", velocity, pitch_dur)
    end

    local entry = {
        seq = OPCODE_CAPTURE.opcode_count,
        frame = OPCODE_CAPTURE.current_effect_frame,
        predicted_frame = predicted_frame,
        system_time = os.clock(),
        opcode = velocity,  -- The velocity IS the opcode for notes
        opcode_name = "Note",
        param = pitch_dur,
        duration = duration,
        est_frames = est_frames,
        timing_type = timing_type,
        timing_behavior = "trigger",  -- Notes are always triggers
        note_type = get_note_type(duration),
        tempo = tempo,
        pair = pair,
        config = config,
        file_channel = file_channel,
        description = desc,
        smd_ptr = smd_ptr,
        -- Channel timing state (raw from memory, for debugging)
        timing_state = timing_state,
    }
    table.insert(OPCODE_CAPTURE.opcodes, entry)

    return true
end

-- Dynamics handler (0xE0)
local function on_dynamics(addr, width, cause)
    return on_opcode(0xE0, function(param)
        return string.format("Volume %d", param)
    end)(addr, width, cause)
end

-- Rest handler (0x80) - duration in SMD ticks
local function on_rest(addr, width, cause)
    return on_opcode(0x80, function(param)
        return string.format("Duration %d", param)
    end)(addr, width, cause)
end

-- Fermata handler (0x81) - extend previous note
local function on_fermata(addr, width, cause)
    return on_opcode(0x81, function(param)
        return string.format("Extend %d", param)
    end)(addr, width, cause)
end

-- Repeat handler (0x98) - begin loop N times
local function on_repeat(addr, width, cause)
    return on_opcode(0x98, function(param)
        return string.format("Loop %d times", param)
    end)(addr, width, cause)
end

-- Tempo handler (0xA0) - set tempo
-- Special handling: updates channel tempo for future timing calculations
local function on_tempo(addr, width, cause)
    if not OPCODE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local s0 = regs.GPR.n.s0
    local smd_ptr = regs.GPR.n.a0

    local config, pair, file_channel = get_channel_info(s0, M.NOTE_CHPTR_OFFSET)
    if not config then
        return true
    end

    -- Read tempo parameter
    local param = 0
    if MemUtils and smd_ptr >= 0x80000000 then
        param = MemUtils.read8(smd_ptr)
    end

    -- Get timing info BEFORE updating tempo
    local predicted_frame = get_predicted_frame(file_channel)
    local old_tempo = get_channel_tempo(file_channel)

    -- Update channel tempo (this affects all future timing calculations)
    if param > 0 then
        set_channel_tempo(file_channel, param)
    end

    -- Calculate actual BPM for display
    local actual_bpm = param * TEMPO_MULTIPLIER

    local timing_state = get_channel_timing_state(s0)

    OPCODE_CAPTURE.opcode_count = OPCODE_CAPTURE.opcode_count + 1

    local entry = {
        seq = OPCODE_CAPTURE.opcode_count,
        frame = OPCODE_CAPTURE.current_effect_frame,
        predicted_frame = predicted_frame,
        system_time = os.clock(),
        opcode = 0xA0,
        opcode_name = "Tempo",
        param = param,
        duration = 0,
        est_frames = 0,
        timing_type = nil,
        timing_behavior = "control",
        note_type = nil,
        tempo = param,  -- Store new tempo
        pair = pair,
        config = config,
        file_channel = file_channel,
        description = string.format("Tempo %d (%.1f BPM)", param, actual_bpm),
        smd_ptr = smd_ptr,
        timing_state = timing_state,
    }
    table.insert(OPCODE_CAPTURE.opcodes, entry)

    return true
end

-- EndBar handler (0x90) - no parameter, needs special handling
local function on_endbar(addr, width, cause)
    if not OPCODE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local s0 = regs.GPR.n.s0  -- Channel state pointer (same as Note handler)

    -- Filter: only log if $s0 matches effect file channel
    local config, pair, file_channel = get_channel_info(s0, M.NOTE_CHPTR_OFFSET)
    if not config then
        return true  -- Not an effect file channel
    end

    local predicted_frame = get_predicted_frame(file_channel)
    local tempo = get_channel_tempo(file_channel)
    local timing_state = get_channel_timing_state(s0)

    OPCODE_CAPTURE.opcode_count = OPCODE_CAPTURE.opcode_count + 1

    local entry = {
        seq = OPCODE_CAPTURE.opcode_count,
        frame = OPCODE_CAPTURE.current_effect_frame,
        predicted_frame = predicted_frame,
        system_time = os.clock(),
        opcode = 0x90,
        opcode_name = "EndBar",
        param = 0,  -- No parameter
        duration = 0,
        est_frames = 0,
        timing_type = nil,
        timing_behavior = "control",
        note_type = nil,
        tempo = tempo,
        pair = pair,
        config = config,
        file_channel = file_channel,
        description = "End channel",
        smd_ptr = 0,
        timing_state = timing_state,
    }
    table.insert(OPCODE_CAPTURE.opcodes, entry)

    return true
end

-- Coda handler (0x99) - no parameter, marks end of loop
local function on_coda(addr, width, cause)
    if not OPCODE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local s0 = regs.GPR.n.s0  -- Channel state pointer (same as Note handler)

    -- Filter: only log if $s0 matches effect file channel
    local config, pair, file_channel = get_channel_info(s0, M.NOTE_CHPTR_OFFSET)
    if not config then
        return true  -- Not an effect file channel
    end

    local predicted_frame = get_predicted_frame(file_channel)
    local tempo = get_channel_tempo(file_channel)
    local timing_state = get_channel_timing_state(s0)

    OPCODE_CAPTURE.opcode_count = OPCODE_CAPTURE.opcode_count + 1

    local entry = {
        seq = OPCODE_CAPTURE.opcode_count,
        frame = OPCODE_CAPTURE.current_effect_frame,
        predicted_frame = predicted_frame,
        system_time = os.clock(),
        opcode = 0x99,
        opcode_name = "Coda",
        param = 0,  -- No parameter
        duration = 0,
        est_frames = 0,
        timing_type = nil,
        timing_behavior = "control",
        note_type = nil,
        tempo = tempo,
        pair = pair,
        config = config,
        file_channel = file_channel,
        description = "End loop",
        smd_ptr = 0,
        timing_state = timing_state,
    }
    table.insert(OPCODE_CAPTURE.opcodes, entry)

    return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.start_capture()
    -- Clear any existing breakpoints
    if OPCODE_CAPTURE_INSTRUMENT_BP then
        pcall(function() OPCODE_CAPTURE_INSTRUMENT_BP:disable() end)
    end
    if OPCODE_CAPTURE_OCTAVE_BP then
        pcall(function() OPCODE_CAPTURE_OCTAVE_BP:disable() end)
    end
    if OPCODE_CAPTURE_DYNAMICS_BP then
        pcall(function() OPCODE_CAPTURE_DYNAMICS_BP:disable() end)
    end
    if OPCODE_CAPTURE_NOTE_BP then
        pcall(function() OPCODE_CAPTURE_NOTE_BP:disable() end)
    end
    if OPCODE_CAPTURE_FRAME_BP then
        pcall(function() OPCODE_CAPTURE_FRAME_BP:disable() end)
    end
    -- New timing opcode breakpoints
    if OPCODE_CAPTURE_REST_BP then
        pcall(function() OPCODE_CAPTURE_REST_BP:disable() end)
    end
    if OPCODE_CAPTURE_FERMATA_BP then
        pcall(function() OPCODE_CAPTURE_FERMATA_BP:disable() end)
    end
    if OPCODE_CAPTURE_ENDBAR_BP then
        pcall(function() OPCODE_CAPTURE_ENDBAR_BP:disable() end)
    end
    if OPCODE_CAPTURE_REPEAT_BP then
        pcall(function() OPCODE_CAPTURE_REPEAT_BP:disable() end)
    end
    if OPCODE_CAPTURE_CODA_BP then
        pcall(function() OPCODE_CAPTURE_CODA_BP:disable() end)
    end
    if OPCODE_CAPTURE_TEMPO_BP then
        pcall(function() OPCODE_CAPTURE_TEMPO_BP:disable() end)
    end

    -- Reset state
    OPCODE_CAPTURE.recording = true
    OPCODE_CAPTURE.opcodes = {}
    OPCODE_CAPTURE.opcode_count = 0
    OPCODE_CAPTURE.frame_count = 0
    OPCODE_CAPTURE.current_effect_frame = 0
    OPCODE_CAPTURE.channel_timing = {}  -- Reset per-channel timing state
    OPCODE_CAPTURE.global_tempo = 102   -- Reset to default FFT tempo

    -- Update feds address range
    if not update_feds_range() then
        print("[OpcodeCapture] WARNING: No feds section loaded")
    else
        print(string.format("[OpcodeCapture] feds range: %08X - %08X",
            OPCODE_CAPTURE.feds_data_start, OPCODE_CAPTURE.feds_data_end))
    end

    -- Create frame update breakpoint
    OPCODE_CAPTURE_FRAME_BP = PCSX.addBreakpoint(
        M.UPDATE_PARTICLES_ADDR, 'Exec', 4, 'OpcodeFrameUpdate', on_frame_update
    )

    -- Create opcode handler breakpoints
    print(string.format("[OpcodeCapture] Setting breakpoints: Instrument=%08X, Octave=%08X, Dynamics=%08X, Note=%08X",
        M.INSTRUMENT_HANDLER_ADDR, M.OCTAVE_HANDLER_ADDR, M.DYNAMICS_HANDLER_ADDR, M.NOTE_HANDLER_ADDR))

    OPCODE_CAPTURE_INSTRUMENT_BP = PCSX.addBreakpoint(
        M.INSTRUMENT_HANDLER_ADDR, 'Exec', 4, 'OpcodeInstrument', on_instrument
    )

    OPCODE_CAPTURE_OCTAVE_BP = PCSX.addBreakpoint(
        M.OCTAVE_HANDLER_ADDR, 'Exec', 4, 'OpcodeOctave', on_octave
    )

    OPCODE_CAPTURE_DYNAMICS_BP = PCSX.addBreakpoint(
        M.DYNAMICS_HANDLER_ADDR, 'Exec', 4, 'OpcodeDynamics', on_dynamics
    )

    OPCODE_CAPTURE_NOTE_BP = PCSX.addBreakpoint(
        M.NOTE_HANDLER_ADDR, 'Exec', 4, 'OpcodeNote', on_note
    )

    -- New timing-related opcode breakpoints
    print(string.format("[OpcodeCapture] Setting timing breakpoints: Rest=%08X, Fermata=%08X, EndBar=%08X, Repeat=%08X, Coda=%08X, Tempo=%08X",
        M.REST_HANDLER_ADDR, M.FERMATA_HANDLER_ADDR, M.ENDBAR_HANDLER_ADDR, M.REPEAT_HANDLER_ADDR, M.CODA_HANDLER_ADDR, M.TEMPO_HANDLER_ADDR))

    OPCODE_CAPTURE_REST_BP = PCSX.addBreakpoint(
        M.REST_HANDLER_ADDR, 'Exec', 4, 'OpcodeRest', on_rest
    )

    OPCODE_CAPTURE_FERMATA_BP = PCSX.addBreakpoint(
        M.FERMATA_HANDLER_ADDR, 'Exec', 4, 'OpcodeFermata', on_fermata
    )

    OPCODE_CAPTURE_ENDBAR_BP = PCSX.addBreakpoint(
        M.ENDBAR_HANDLER_ADDR, 'Exec', 4, 'OpcodeEndBar', on_endbar
    )

    OPCODE_CAPTURE_REPEAT_BP = PCSX.addBreakpoint(
        M.REPEAT_HANDLER_ADDR, 'Exec', 4, 'OpcodeRepeat', on_repeat
    )

    OPCODE_CAPTURE_CODA_BP = PCSX.addBreakpoint(
        M.CODA_HANDLER_ADDR, 'Exec', 4, 'OpcodeCoda', on_coda
    )

    OPCODE_CAPTURE_TEMPO_BP = PCSX.addBreakpoint(
        M.TEMPO_HANDLER_ADDR, 'Exec', 4, 'OpcodeTempo', on_tempo
    )

    print("[OpcodeCapture] Recording started (effect-scoped) - all breakpoints active")
end

function M.stop_capture()
    OPCODE_CAPTURE.recording = false
    print(string.format("[OpcodeCapture] Stopped: %d opcodes over %d frames",
        OPCODE_CAPTURE.opcode_count, OPCODE_CAPTURE.frame_count))
end

function M.is_capturing()
    return OPCODE_CAPTURE.recording
end

function M.get_count()
    return OPCODE_CAPTURE.opcode_count
end

function M.print_log(filter_slot, filter_subslot)
    local opcodes = OPCODE_CAPTURE.opcodes

    if #opcodes == 0 then
        print("[OpcodeCapture] No opcodes recorded")
        return
    end

    -- Filter opcodes if filters provided
    local filtered = {}
    for _, op in ipairs(opcodes) do
        local slot_match = (filter_slot == nil or filter_slot < 0) or (op.pair == filter_slot)
        local subslot_match = (filter_subslot == nil or filter_subslot < 0) or (op.file_channel == filter_subslot)
        if slot_match and subslot_match then
            table.insert(filtered, op)
        end
    end

    -- Build filter info string
    local filter_info = ""
    if (filter_slot and filter_slot >= 0) or (filter_subslot and filter_subslot >= 0) then
        local parts = {}
        if filter_slot and filter_slot >= 0 then
            table.insert(parts, string.format("Slot=%d", filter_slot))
        end
        if filter_subslot and filter_subslot >= 0 then
            table.insert(parts, string.format("SubSlot=%d", filter_subslot))
        end
        filter_info = string.format(" [%s, filtered from %d]", table.concat(parts, ", "), #opcodes)
    end

    print("")
    print(string.format("=== Effect SMD Opcodes (%d total%s, %d frames) ===",
        #filtered, filter_info, OPCODE_CAPTURE.frame_count))
    print(string.format("feds range: %08X - %08X",
        OPCODE_CAPTURE.feds_data_start, OPCODE_CAPTURE.feds_data_end))
    print("")
    print("Timing Model (from FFHacktics wiki):")
    print("  - Formula: frames = duration * 1800 / (48 * tempo * 1.17188)")
    print("  - At tempo 102: ~3.19 ticks/frame (rest 96 → 30 frames)")
    print("  - Rest/Fermata: BLOCKING - adds to cumulative timing")
    print("  - Notes: TRIGGER - fire immediately, don't block")
    print("  - Pred.F = predicted frame based on cumulative Rest/Fermata timing")
    print("")
    print("Seq | Frame |Pred.F| Δ  |Tempo| Ch | Behav   | Op   | Dur |Est.F| Type     | Opcode     | Description")
    print("----|-------|------|----|----|----|---------|----- |-----|-----|----------|------------|------------------------")

    for _, op in ipairs(filtered) do
        local ch_str = op.file_channel ~= nil and string.format("%2d", op.file_channel) or " ?"

        -- Format predicted frame
        local pred_str = op.predicted_frame and string.format("%5.1f", op.predicted_frame) or "    -"

        -- Calculate delta between actual and predicted
        local delta_str = "   "
        if op.predicted_frame and op.frame then
            local delta = op.frame - op.predicted_frame
            if math.abs(delta) < 0.5 then
                delta_str = "  ="  -- Match
            elseif delta > 0 then
                delta_str = string.format("+%2d", math.floor(delta + 0.5))
            else
                delta_str = string.format("%3d", math.floor(delta + 0.5))
            end
        end

        -- Format tempo
        local tempo_str = op.tempo and string.format("%3d", op.tempo) or "  -"

        -- Format timing behavior (block/trig/ctrl)
        local behav_str = "-"
        if op.timing_behavior == "blocking" then
            behav_str = "BLOCK"
        elseif op.timing_behavior == "trigger" then
            behav_str = "trig"
        elseif op.timing_behavior == "control" then
            behav_str = "ctrl"
        end

        -- Format estimated frames and note type
        local est_str = op.est_frames and op.est_frames > 0 and string.format("%4.1f", op.est_frames) or "   -"
        local type_str = op.note_type or op.timing_type or "-"

        print(string.format("%3d | %5d |%s|%s| %s | %s | %-7s | 0x%02X | %3d | %s | %-8s | %-10s | %s",
            op.seq, op.frame, pred_str, delta_str, tempo_str, ch_str,
            behav_str, op.opcode, op.duration or 0, est_str, type_str,
            op.opcode_name, op.description))
    end

    print("")
    print("Legend: Δ = actual_frame - predicted_frame (= means match, +N means late, -N means early)")
    print("=== End Opcodes ===")
    print("")
end

-- Print timing accuracy summary
function M.print_timing_summary()
    local opcodes = OPCODE_CAPTURE.opcodes

    if #opcodes == 0 then
        print("[OpcodeCapture] No opcodes to summarize")
        return
    end

    -- Collect statistics
    local total_blocking = 0
    local total_triggers = 0
    local total_control = 0
    local deltas = {}
    local blocking_deltas = {}
    local trigger_deltas = {}
    local channels_seen = {}
    local tempos_seen = {}

    for _, op in ipairs(opcodes) do
        -- Count behavior types
        if op.timing_behavior == "blocking" then
            total_blocking = total_blocking + 1
        elseif op.timing_behavior == "trigger" then
            total_triggers = total_triggers + 1
        else
            total_control = total_control + 1
        end

        -- Collect deltas
        if op.predicted_frame and op.frame then
            local delta = op.frame - op.predicted_frame
            table.insert(deltas, delta)

            if op.timing_behavior == "blocking" then
                table.insert(blocking_deltas, delta)
            elseif op.timing_behavior == "trigger" then
                table.insert(trigger_deltas, delta)
            end
        end

        -- Track channels and tempos
        if op.file_channel then
            channels_seen[op.file_channel] = true
        end
        if op.tempo then
            tempos_seen[op.tempo] = (tempos_seen[op.tempo] or 0) + 1
        end
    end

    -- Calculate statistics
    local function calc_stats(arr)
        if #arr == 0 then return nil end
        local sum = 0
        local min_val = arr[1]
        local max_val = arr[1]
        for _, v in ipairs(arr) do
            sum = sum + v
            if v < min_val then min_val = v end
            if v > max_val then max_val = v end
        end
        local mean = sum / #arr

        -- Calculate standard deviation
        local sq_diff_sum = 0
        for _, v in ipairs(arr) do
            sq_diff_sum = sq_diff_sum + (v - mean)^2
        end
        local std_dev = math.sqrt(sq_diff_sum / #arr)

        return {
            count = #arr,
            mean = mean,
            min = min_val,
            max = max_val,
            std_dev = std_dev,
        }
    end

    local all_stats = calc_stats(deltas)
    local blocking_stats = calc_stats(blocking_deltas)
    local trigger_stats = calc_stats(trigger_deltas)

    -- Count channels
    local channel_count = 0
    local channel_list = {}
    for ch in pairs(channels_seen) do
        channel_count = channel_count + 1
        table.insert(channel_list, ch)
    end
    table.sort(channel_list)

    -- Format tempo info
    local tempo_info = {}
    for tempo, count in pairs(tempos_seen) do
        local bpm = tempo * TEMPO_MULTIPLIER
        table.insert(tempo_info, string.format("%d (%.1f BPM, n=%d)", tempo, bpm, count))
    end

    print("")
    print("=== Timing Accuracy Summary ===")
    print("")
    print(string.format("Total opcodes: %d (blocking=%d, trigger=%d, control=%d)",
        #opcodes, total_blocking, total_triggers, total_control))
    print(string.format("Channels active: %d (%s)", channel_count, table.concat(channel_list, ", ")))
    print(string.format("Tempos used: %s", table.concat(tempo_info, ", ")))
    print("")

    if all_stats then
        print("Prediction Accuracy (Δ = actual - predicted):")
        print(string.format("  All opcodes:     mean=%.2f, std=%.2f, range=[%.1f, %.1f], n=%d",
            all_stats.mean, all_stats.std_dev, all_stats.min, all_stats.max, all_stats.count))
    end
    if blocking_stats then
        print(string.format("  Blocking only:   mean=%.2f, std=%.2f, range=[%.1f, %.1f], n=%d",
            blocking_stats.mean, blocking_stats.std_dev, blocking_stats.min, blocking_stats.max, blocking_stats.count))
    end
    if trigger_stats then
        print(string.format("  Triggers only:   mean=%.2f, std=%.2f, range=[%.1f, %.1f], n=%d",
            trigger_stats.mean, trigger_stats.std_dev, trigger_stats.min, trigger_stats.max, trigger_stats.count))
    end

    print("")
    if all_stats and math.abs(all_stats.mean) < 2 and all_stats.std_dev < 3 then
        print("Timing model appears ACCURATE (mean delta < 2, std < 3)")
    elseif all_stats and math.abs(all_stats.mean) < 5 then
        print("Timing model is APPROXIMATE (mean delta < 5)")
    elseif all_stats then
        print("Timing model may need CALIBRATION (mean delta >= 5)")
    end
    print("=== End Summary ===")
    print("")
end

function M.cleanup()
    if OPCODE_CAPTURE_INSTRUMENT_BP then
        pcall(function() OPCODE_CAPTURE_INSTRUMENT_BP:disable() end)
        OPCODE_CAPTURE_INSTRUMENT_BP = nil
    end
    if OPCODE_CAPTURE_OCTAVE_BP then
        pcall(function() OPCODE_CAPTURE_OCTAVE_BP:disable() end)
        OPCODE_CAPTURE_OCTAVE_BP = nil
    end
    if OPCODE_CAPTURE_DYNAMICS_BP then
        pcall(function() OPCODE_CAPTURE_DYNAMICS_BP:disable() end)
        OPCODE_CAPTURE_DYNAMICS_BP = nil
    end
    if OPCODE_CAPTURE_NOTE_BP then
        pcall(function() OPCODE_CAPTURE_NOTE_BP:disable() end)
        OPCODE_CAPTURE_NOTE_BP = nil
    end
    if OPCODE_CAPTURE_FRAME_BP then
        pcall(function() OPCODE_CAPTURE_FRAME_BP:disable() end)
        OPCODE_CAPTURE_FRAME_BP = nil
    end
    -- New timing opcode breakpoints
    if OPCODE_CAPTURE_REST_BP then
        pcall(function() OPCODE_CAPTURE_REST_BP:disable() end)
        OPCODE_CAPTURE_REST_BP = nil
    end
    if OPCODE_CAPTURE_FERMATA_BP then
        pcall(function() OPCODE_CAPTURE_FERMATA_BP:disable() end)
        OPCODE_CAPTURE_FERMATA_BP = nil
    end
    if OPCODE_CAPTURE_ENDBAR_BP then
        pcall(function() OPCODE_CAPTURE_ENDBAR_BP:disable() end)
        OPCODE_CAPTURE_ENDBAR_BP = nil
    end
    if OPCODE_CAPTURE_REPEAT_BP then
        pcall(function() OPCODE_CAPTURE_REPEAT_BP:disable() end)
        OPCODE_CAPTURE_REPEAT_BP = nil
    end
    if OPCODE_CAPTURE_CODA_BP then
        pcall(function() OPCODE_CAPTURE_CODA_BP:disable() end)
        OPCODE_CAPTURE_CODA_BP = nil
    end
    if OPCODE_CAPTURE_TEMPO_BP then
        pcall(function() OPCODE_CAPTURE_TEMPO_BP:disable() end)
        OPCODE_CAPTURE_TEMPO_BP = nil
    end
    OPCODE_CAPTURE.recording = false
end

return M
