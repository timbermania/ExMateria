-- parser.lua
-- Parse E###.BIN effect file headers, sections, and emitters

local mem = require("memory_utils")
local FieldSchema = require("field_schema")

local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Section names in order
M.SECTION_NAMES = {
    "frames",
    "animation",
    "script",
    "particle_system",
    "anim_curves",
    "timing_curves",
    "effect_flags",
    "timeline",
    "sound_def",
    "texture"
}

-- Header pointer offsets
M.HEADER_OFFSETS = {
    frames_ptr = 0x00,
    animation_ptr = 0x04,
    script_data_ptr = 0x08,
    effect_data_ptr = 0x0C,
    anim_table_ptr = 0x10,
    timing_curve_ptr = 0x14,
    effect_flags_ptr = 0x18,
    timeline_section_ptr = 0x1C,
    sound_def_ptr = 0x20,
    texture_ptr = 0x24
}

--------------------------------------------------------------------------------
-- Format Detection
--------------------------------------------------------------------------------

-- Detect if file is CODE (MIPS executable) or DATA format
function M.detect_format(data)
    local first_word = mem.buf_read32(data, 0x00)

    -- CODE format: first instruction is addiu sp, sp, -X (0x27BDXXXX)
    if first_word >= 0x27BD0000 and first_word < 0x27BE0000 then
        return "CODE"
    end

    -- DATA format: first value is small pointer (frames_ptr, typically 0x28)
    if first_word < 0x1000 then
        return "DATA"
    end

    return "UNKNOWN"
end

--------------------------------------------------------------------------------
-- Header Parsing
--------------------------------------------------------------------------------

-- Parse 40-byte header from file data
function M.parse_header_from_data(data)
    return {
        frames_ptr = mem.buf_read32(data, 0x00),
        animation_ptr = mem.buf_read32(data, 0x04),
        script_data_ptr = mem.buf_read32(data, 0x08),
        effect_data_ptr = mem.buf_read32(data, 0x0C),
        anim_table_ptr = mem.buf_read32(data, 0x10),
        timing_curve_ptr = mem.buf_read32(data, 0x14),
        effect_flags_ptr = mem.buf_read32(data, 0x18),
        timeline_section_ptr = mem.buf_read32(data, 0x1C),
        sound_def_ptr = mem.buf_read32(data, 0x20),
        texture_ptr = mem.buf_read32(data, 0x24),
        file_size = #data,
        format = M.detect_format(data),
        source = "file"
    }
end

-- Parse header from PSX memory at given base address
function M.parse_header_from_memory(base_addr)
    return {
        frames_ptr = mem.read32(base_addr + 0x00),
        animation_ptr = mem.read32(base_addr + 0x04),
        script_data_ptr = mem.read32(base_addr + 0x08),
        effect_data_ptr = mem.read32(base_addr + 0x0C),
        anim_table_ptr = mem.read32(base_addr + 0x10),
        timing_curve_ptr = mem.read32(base_addr + 0x14),
        effect_flags_ptr = mem.read32(base_addr + 0x18),
        timeline_section_ptr = mem.read32(base_addr + 0x1C),
        sound_def_ptr = mem.read32(base_addr + 0x20),
        texture_ptr = mem.read32(base_addr + 0x24),
        base_addr = base_addr,
        source = "memory"
    }
end

--------------------------------------------------------------------------------
-- Section Info Calculation (returns array for ipairs compatibility)
--------------------------------------------------------------------------------

function M.calculate_sections(header)
    local sections = {}

    sections[1] = {
        name = "Frames",
        offset = header.frames_ptr,
        size = header.animation_ptr - header.frames_ptr
    }
    sections[2] = {
        name = "Animation",
        offset = header.animation_ptr,
        size = header.script_data_ptr - header.animation_ptr
    }
    sections[3] = {
        name = "Script",
        offset = header.script_data_ptr,
        size = header.effect_data_ptr - header.script_data_ptr
    }
    sections[4] = {
        name = "Particle System",
        offset = header.effect_data_ptr,
        size = header.anim_table_ptr - header.effect_data_ptr
    }

    if header.timing_curve_ptr ~= 0 then
        sections[5] = {
            name = "Anim Curves",
            offset = header.anim_table_ptr,
            size = header.timing_curve_ptr - header.anim_table_ptr
        }
        sections[6] = {
            name = "Timing Curves",
            offset = header.timing_curve_ptr,
            size = header.effect_flags_ptr - header.timing_curve_ptr
        }
    else
        sections[5] = {
            name = "Anim Curves",
            offset = header.anim_table_ptr,
            size = header.effect_flags_ptr - header.anim_table_ptr
        }
    end

    local idx = header.timing_curve_ptr ~= 0 and 7 or 6
    sections[idx] = {
        name = "Effect Flags",
        offset = header.effect_flags_ptr,
        size = header.timeline_section_ptr - header.effect_flags_ptr
    }
    sections[idx + 1] = {
        name = "Timeline",
        offset = header.timeline_section_ptr,
        size = header.sound_def_ptr - header.timeline_section_ptr
    }
    sections[idx + 2] = {
        name = "Sound Def",
        offset = header.sound_def_ptr,
        size = header.texture_ptr - header.sound_def_ptr
    }

    local texture_size = 0
    if header.file_size then
        texture_size = header.file_size - header.texture_ptr
    end
    sections[idx + 3] = {
        name = "Texture",
        offset = header.texture_ptr,
        size = texture_size
    }

    return sections
end

--------------------------------------------------------------------------------
-- Particle System Header
--------------------------------------------------------------------------------

function M.calc_emitter_count(particle_section_size)
    return math.floor((particle_section_size - 0x14) / 0xC4)
end

-- Parse particle system header (20 bytes at effect_data_ptr)
function M.parse_particle_header_from_data(data, offset)
    return FieldSchema.parse_from_buffer(FieldSchema.PARTICLE_HEADER_SCHEMA, data, offset)
end

--------------------------------------------------------------------------------
-- Emitter Parsing (from file data)
--------------------------------------------------------------------------------

-- Parse single emitter (196 bytes) from file data
function M.parse_emitter_from_data(data, offset)
    return FieldSchema.parse_from_buffer(FieldSchema.EMITTER_SCHEMA, data, offset)
end

-- Parse all emitters from file data
function M.parse_all_emitters(data, effect_data_ptr, emitter_count)
    local emitters = {}
    for i = 0, emitter_count - 1 do
        local offset = effect_data_ptr + 0x14 + (i * 0xC4)
        emitters[i + 1] = M.parse_emitter_from_data(data, offset)
        emitters[i + 1].index = i
        emitters[i + 1].offset = offset
    end
    return emitters
end

--------------------------------------------------------------------------------
-- Emitter Parsing (from PSX memory)
--------------------------------------------------------------------------------

-- Parse single emitter from PSX memory (not file buffer)
function M.parse_emitter_from_memory(base_addr)
    return FieldSchema.parse_from_memory(FieldSchema.EMITTER_SCHEMA, base_addr)
end

-- Parse all emitters from PSX memory
function M.parse_all_emitters_from_memory(effect_data_base, emitter_count)
    local emitters = {}
    for i = 0, emitter_count - 1 do
        local addr = effect_data_base + 0x14 + (i * 0xC4)
        emitters[i + 1] = M.parse_emitter_from_memory(addr)
        emitters[i + 1].index = i
        emitters[i + 1].offset = addr - effect_data_base
    end
    return emitters
end

--------------------------------------------------------------------------------
-- Emitter Writing (to PSX memory)
--------------------------------------------------------------------------------

-- Write single emitter to PSX memory
function M.write_emitter_to_memory(base_addr, emitter_index, e)
    local addr = base_addr + 0x14 + (emitter_index * 0xC4)
    FieldSchema.write_to_memory(FieldSchema.EMITTER_SCHEMA, addr, e)
    return addr
end

-- Deep copy an emitter table with a new index
function M.copy_emitter(source, new_index)
    local e = FieldSchema.copy(FieldSchema.EMITTER_SCHEMA, source)
    e.index = new_index
    e.offset = nil  -- Will be calculated on write
    return e
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

-- Validate header pointers are in ascending order
function M.validate_header(header)
    local errors = {}

    -- Check frames_ptr is at expected location (0x28 for DATA format)
    if header.format == "DATA" and header.frames_ptr ~= 0x28 then
        table.insert(errors, string.format("frames_ptr = 0x%X (expected 0x28)", header.frames_ptr))
    end

    -- Check pointers are in ascending order
    local order = {
        {"frames_ptr", header.frames_ptr},
        {"animation_ptr", header.animation_ptr},
        {"script_data_ptr", header.script_data_ptr},
        {"effect_data_ptr", header.effect_data_ptr},
        {"anim_table_ptr", header.anim_table_ptr},
    }

    -- timing_curve_ptr may be 0 (unused)
    if header.timing_curve_ptr ~= 0 then
        table.insert(order, {"timing_curve_ptr", header.timing_curve_ptr})
    end

    table.insert(order, {"effect_flags_ptr", header.effect_flags_ptr})
    table.insert(order, {"timeline_section_ptr", header.timeline_section_ptr})
    table.insert(order, {"sound_def_ptr", header.sound_def_ptr})
    table.insert(order, {"texture_ptr", header.texture_ptr})

    for i = 2, #order do
        if order[i][2] < order[i-1][2] then
            table.insert(errors, string.format("%s (0x%X) < %s (0x%X)",
                order[i][1], order[i][2], order[i-1][1], order[i-1][2]))
        end
    end

    return #errors == 0, errors
end

--------------------------------------------------------------------------------
-- Animation Curve Parsing/Writing
--------------------------------------------------------------------------------

local CURVE_LENGTH = 160

-- Parse all curves from file data
-- Returns: curves table (1-indexed, each is table of 160 values), curve_count
function M.parse_curves_from_data(data, anim_table_ptr)
    if not data or not anim_table_ptr then
        return {}, 0
    end

    local curve_count = mem.buf_read32(data, anim_table_ptr)
    local curves = {}

    for c = 0, curve_count - 1 do
        local curve = {}
        local base = anim_table_ptr + 4 + (c * CURVE_LENGTH)
        for i = 0, CURVE_LENGTH - 1 do
            curve[i + 1] = mem.buf_read8(data, base + i)
        end
        curves[c + 1] = curve
    end

    return curves, curve_count
end

-- Parse all curves from PSX memory
function M.parse_curves_from_memory(anim_table_addr)
    if not anim_table_addr then
        return {}, 0
    end

    local curve_count = mem.read32(anim_table_addr)
    local curves = {}

    for c = 0, curve_count - 1 do
        local curve = {}
        local base = anim_table_addr + 4 + (c * CURVE_LENGTH)
        for i = 0, CURVE_LENGTH - 1 do
            curve[i + 1] = mem.read8(base + i)
        end
        curves[c + 1] = curve
    end

    return curves, curve_count
end

-- Write single curve to PSX memory
-- curve_index is 0-based
function M.write_curve_to_memory(anim_table_addr, curve_index, curve_data)
    local base = anim_table_addr + 4 + (curve_index * CURVE_LENGTH)
    for i = 0, CURVE_LENGTH - 1 do
        mem.write8(base + i, curve_data[i + 1] or 0)
    end
end

-- Write all curves to PSX memory
function M.write_all_curves_to_memory(anim_table_addr, curves)
    for c = 1, #curves do
        M.write_curve_to_memory(anim_table_addr, c - 1, curves[c])
    end
end

-- Deep copy curves table
function M.copy_curves(curves)
    if not curves then return nil end
    local copy = {}
    for c = 1, #curves do
        copy[c] = {}
        for i = 1, CURVE_LENGTH do
            copy[c][i] = curves[c][i]
        end
    end
    return copy
end

--------------------------------------------------------------------------------
-- Timeline Section Parsing/Writing
--------------------------------------------------------------------------------

-- Timeline section offsets (relative to timeline_section_ptr)
-- Particle channel is 128 bytes each, 25 keyframes max
M.TIMELINE_OFFSETS = {
    -- Timeline header (12 bytes)
    header = 0x00,
    -- Animate tick channels (relative to timeline_section_ptr + 8)
    -- These are at timeline_channel_base + offset
    animate_tick = { 0x0004, 0x0084, 0x0104, 0x0184, 0x0204 },
    -- Process timeline phase 1 channels (relative to timeline_section_ptr)
    phase1 = { 0x082A, 0x08AA, 0x092A, 0x09AA, 0x0A2A },
    -- Process timeline phase 2 channels (relative to timeline_section_ptr)
    phase2 = { 0x0AAA, 0x0B2A, 0x0BAA, 0x0C2A, 0x0CAA },
}

local CHANNEL_SIZE = 128
local MAX_KEYFRAMES = 25

-- Parse timeline header (12 bytes at timeline_section_ptr)
function M.parse_timeline_header_from_data(data, timeline_section_ptr)
    return {
        unknown_00 = mem.buf_read16s(data, timeline_section_ptr + 0x00),
        unknown_02 = mem.buf_read16s(data, timeline_section_ptr + 0x02),
        phase1_duration = mem.buf_read16s(data, timeline_section_ptr + 0x04),
        spawn_delay = mem.buf_read16s(data, timeline_section_ptr + 0x06),
        unknown_08 = mem.buf_read16s(data, timeline_section_ptr + 0x08),
        phase2_delay = mem.buf_read16s(data, timeline_section_ptr + 0x0A),
    }
end

function M.parse_timeline_header_from_memory(timeline_section_addr)
    return {
        unknown_00 = mem.read16s(timeline_section_addr + 0x00),
        unknown_02 = mem.read16s(timeline_section_addr + 0x02),
        phase1_duration = mem.read16s(timeline_section_addr + 0x04),
        spawn_delay = mem.read16s(timeline_section_addr + 0x06),
        unknown_08 = mem.read16s(timeline_section_addr + 0x08),
        phase2_delay = mem.read16s(timeline_section_addr + 0x0A),
    }
end

-- Parse single particle channel (128 bytes) from file data
-- Returns channel table with keyframes array
function M.parse_particle_channel_from_data(data, offset, context, channel_index)
    local channel = {
        context = context,           -- "animate_tick", "phase1", or "phase2"
        channel_index = channel_index,
        offset = offset,
        keyframes = {}
    }

    -- Read max_keyframe from 0x7E-0x7F
    channel.max_keyframe = mem.buf_read16s(data, offset + 0x7E)

    -- DEBUG: Log parsing for Channel 1 (animate_tick index 1)
    local is_channel_1 = (context == "animate_tick" and channel_index == 1)
    if is_channel_1 then
        print(string.format("[DEBUG PARSE] Channel 1 @ file offset 0x%X, max_kf=%d",
            offset, channel.max_keyframe))
        -- Show raw hex of first 16 bytes
        local hex = ""
        for i = 0, 15 do
            hex = hex .. string.format("%02X ", string.byte(data, offset + 1 + i) or 0)
        end
        print(string.format("  Raw hex: %s", hex))
    end

    -- Parse keyframes (up to max_keyframe + 1, but cap at 25)
    local num_keyframes = math.min(channel.max_keyframe + 1, MAX_KEYFRAMES)

    for i = 0, MAX_KEYFRAMES - 1 do
        local kf = {}

        -- time_marker at offset + i*2 (int16)
        kf.time = mem.buf_read16s(data, offset + (i * 2))

        -- DEBUG: Log first 5 keyframe times for Channel 1
        if is_channel_1 and i < 5 then
            print(string.format("  Parsed kf[%d].time = %d from offset 0x%X",
                i, kf.time, offset + (i * 2)))
        end

        -- emitter_id at offset + 0x31 + i (byte)
        -- Note: emitter_ids start at 0x31, but index 0 overlaps with time_marker[24] high byte
        -- The game increments keyframe index BEFORE reading emitter_id, so we read at i+1 position
        -- But for parsing, we'll read at the direct offset and handle the overlap
        if i < MAX_KEYFRAMES then
            kf.emitter_id = mem.buf_read8(data, offset + 0x31 + i)
        else
            kf.emitter_id = 0
        end

        -- action_flags at offset + 0x4A + i*2 (uint16)
        kf.action_flags = mem.buf_read16(data, offset + 0x4A + (i * 2))

        channel.keyframes[i + 1] = kf
    end

    return channel
end

-- Parse single particle channel from PSX memory
function M.parse_particle_channel_from_memory(addr, context, channel_index)
    local channel = {
        context = context,
        channel_index = channel_index,
        offset = addr,  -- This is the memory address
        keyframes = {}
    }

    -- Read max_keyframe from 0x7E-0x7F
    channel.max_keyframe = mem.read16s(addr + 0x7E)

    -- Parse all 25 keyframes
    for i = 0, MAX_KEYFRAMES - 1 do
        local kf = {}

        -- time_marker at offset + i*2 (int16)
        kf.time = mem.read16s(addr + (i * 2))

        -- emitter_id at offset + 0x31 + i (byte)
        kf.emitter_id = mem.read8(addr + 0x31 + i)

        -- action_flags at offset + 0x4A + i*2 (uint16)
        kf.action_flags = mem.read16(addr + 0x4A + (i * 2))

        channel.keyframes[i + 1] = kf
    end

    return channel
end

-- Parse all 15 timeline particle channels from file data
function M.parse_all_timeline_channels(data, timeline_section_ptr)
    local channels = {}
    local offsets = M.TIMELINE_OFFSETS

    -- Animate tick channels (5 channels)
    -- Base is timeline_section_ptr + 8, then add channel offset
    local animate_tick_base = timeline_section_ptr + 8
    for i, channel_offset in ipairs(offsets.animate_tick) do
        local offset = animate_tick_base + channel_offset
        channels[#channels + 1] = M.parse_particle_channel_from_data(data, offset, "animate_tick", i - 1)
    end

    -- Phase 1 channels (5 channels)
    for i, channel_offset in ipairs(offsets.phase1) do
        local offset = timeline_section_ptr + channel_offset
        channels[#channels + 1] = M.parse_particle_channel_from_data(data, offset, "phase1", i - 1)
    end

    -- Phase 2 channels (5 channels)
    for i, channel_offset in ipairs(offsets.phase2) do
        local offset = timeline_section_ptr + channel_offset
        channels[#channels + 1] = M.parse_particle_channel_from_data(data, offset, "phase2", i - 1)
    end

    return channels
end

-- Parse all 15 timeline particle channels from PSX memory
function M.parse_all_timeline_channels_from_memory(base_addr, timeline_section_ptr)
    local channels = {}
    local offsets = M.TIMELINE_OFFSETS
    local timeline_addr = base_addr + timeline_section_ptr

    -- Animate tick channels (5 channels)
    local animate_tick_base = timeline_addr + 8
    for i, channel_offset in ipairs(offsets.animate_tick) do
        local addr = animate_tick_base + channel_offset
        channels[#channels + 1] = M.parse_particle_channel_from_memory(addr, "animate_tick", i - 1)
    end

    -- Phase 1 channels (5 channels)
    for i, channel_offset in ipairs(offsets.phase1) do
        local addr = timeline_addr + channel_offset
        channels[#channels + 1] = M.parse_particle_channel_from_memory(addr, "phase1", i - 1)
    end

    -- Phase 2 channels (5 channels)
    for i, channel_offset in ipairs(offsets.phase2) do
        local addr = timeline_addr + channel_offset
        channels[#channels + 1] = M.parse_particle_channel_from_memory(addr, "phase2", i - 1)
    end

    return channels
end

-- Write timeline header to PSX memory
function M.write_timeline_header_to_memory(timeline_addr, header)
    mem.write16(timeline_addr + 0x00, header.unknown_00)
    mem.write16(timeline_addr + 0x02, header.unknown_02)
    mem.write16(timeline_addr + 0x04, header.phase1_duration)
    mem.write16(timeline_addr + 0x06, header.spawn_delay)
    mem.write16(timeline_addr + 0x08, header.unknown_08)
    mem.write16(timeline_addr + 0x0A, header.phase2_delay)
end

-- Write single particle channel to PSX memory
function M.write_particle_channel_to_memory(addr, channel)
    -- DEBUG: Log first few keyframe writes for Channel 1 (0x8C offset from animate_tick_base)
    local is_channel_1 = (addr % 0x1000 == 0x824) or (addr % 0x1000 == 0x324)  -- Check for Channel 1 pattern
    if is_channel_1 then
        print(string.format("[DEBUG] write_particle_channel addr=0x%08X context=%s ch_idx=%d",
            addr, channel.context or "?", channel.channel_index or -1))
    end

    -- Write all 25 keyframes
    for i = 0, MAX_KEYFRAMES - 1 do
        local kf = channel.keyframes[i + 1]
        if kf then
            -- time_marker at offset + i*2
            local write_offset = i * 2
            local write_addr = addr + write_offset
            mem.write16(write_addr, kf.time)

            -- DEBUG: Log first 5 keyframes for Channel 1
            if is_channel_1 and i < 5 then
                print(string.format("  kf[%d] time=%d offset=0x%02X addr=0x%08X",
                    i, kf.time, write_offset, write_addr))
            end

            -- emitter_id at offset + 0x31 + i
            mem.write8(addr + 0x31 + i, kf.emitter_id)

            -- action_flags at offset + 0x4A + i*2
            mem.write16(addr + 0x4A + (i * 2), kf.action_flags)
        end
    end

    -- Write max_keyframe at 0x7E
    mem.write16(addr + 0x7E, channel.max_keyframe)

    -- DEBUG: Read back and verify for Channel 1
    if is_channel_1 then
        print("[DEBUG] Read back verification:")
        for i = 0, 4 do
            local read_addr = addr + (i * 2)
            local val = mem.read16(read_addr)
            print(string.format("  offset=0x%02X read=0x%04X", i * 2, val))
        end
    end
end

-- Write all timeline channels to PSX memory
function M.write_all_timeline_channels_to_memory(base_addr, timeline_section_ptr, channels)
    local offsets = M.TIMELINE_OFFSETS
    local timeline_addr = base_addr + timeline_section_ptr
    local channel_idx = 1

    -- Animate tick channels
    local animate_tick_base = timeline_addr + 8
    for i, channel_offset in ipairs(offsets.animate_tick) do
        local addr = animate_tick_base + channel_offset
        M.write_particle_channel_to_memory(addr, channels[channel_idx])
        channel_idx = channel_idx + 1
    end

    -- Phase 1 channels
    for i, channel_offset in ipairs(offsets.phase1) do
        local addr = timeline_addr + channel_offset
        M.write_particle_channel_to_memory(addr, channels[channel_idx])
        channel_idx = channel_idx + 1
    end

    -- Phase 2 channels
    for i, channel_offset in ipairs(offsets.phase2) do
        local addr = timeline_addr + channel_offset
        M.write_particle_channel_to_memory(addr, channels[channel_idx])
        channel_idx = channel_idx + 1
    end
end

-- Deep copy timeline header
function M.copy_timeline_header(header)
    if not header then return nil end
    return {
        unknown_00 = header.unknown_00,
        unknown_02 = header.unknown_02,
        phase1_duration = header.phase1_duration,
        spawn_delay = header.spawn_delay,
        unknown_08 = header.unknown_08,
        phase2_delay = header.phase2_delay,
    }
end

-- Deep copy timeline channels
function M.copy_timeline_channels(channels)
    if not channels then return nil end
    local copy = {}

    for c = 1, #channels do
        local src = channels[c]
        local dst = {
            context = src.context,
            channel_index = src.channel_index,
            offset = src.offset,
            max_keyframe = src.max_keyframe,
            keyframes = {}
        }

        for k = 1, MAX_KEYFRAMES do
            local src_kf = src.keyframes[k]
            if src_kf then
                dst.keyframes[k] = {
                    time = src_kf.time,
                    emitter_id = src_kf.emitter_id,
                    action_flags = src_kf.action_flags,
                }
            end
        end

        copy[c] = dst
    end

    return copy
end

--------------------------------------------------------------------------------
-- Camera Timeline Parsing/Writing
--------------------------------------------------------------------------------

-- Camera table offsets (relative to timeline_section_ptr)
-- Each table has: end_frame, angles, position, zoom, command, max_keyframe
M.CAMERA_TABLE_OFFSETS = {
    [1] = {  -- Table 0: MAIN
        end_frame = 0x14E6,
        angles = 0x1510,
        position = 0x158E,
        zoom = 0x160C,
        command = 0x168A,
        max_keyframe = 0x16B4,
    },
    [2] = {  -- Table 1: FOR-EACH-TARGET
        end_frame = 0x06B2,
        angles = 0x06D4,
        position = 0x073A,
        zoom = 0x07A0,
        command = 0x0806,
        max_keyframe = 0x0828,
    },
    [3] = {  -- Table 2: CLEANUP
        end_frame = 0x16B6,
        angles = 0x16E0,
        position = 0x175E,
        zoom = 0x17DC,
        command = 0x185A,
        max_keyframe = 0x1884,
    },
}

local MAX_CAMERA_KEYFRAMES = 17

-- Parse single camera table from file data
function M.parse_camera_table_from_data(data, timeline_section_ptr, table_index)
    local offsets = M.CAMERA_TABLE_OFFSETS[table_index]
    if not offsets then return nil end

    local table_data = {
        table_index = table_index - 1,  -- 0-indexed for display
        max_keyframe = mem.buf_read16s(data, timeline_section_ptr + offsets.max_keyframe),
        keyframes = {}
    }

    for i = 0, MAX_CAMERA_KEYFRAMES - 1 do
        local kf = {}

        -- end_frame at offset + i*2 (int16)
        kf.end_frame = mem.buf_read16s(data, timeline_section_ptr + offsets.end_frame + i * 2)

        -- angles at offset + i*6 (3 x int16: pitch, yaw, roll)
        kf.pitch = mem.buf_read16s(data, timeline_section_ptr + offsets.angles + i * 6)
        kf.yaw = mem.buf_read16s(data, timeline_section_ptr + offsets.angles + i * 6 + 2)
        kf.roll = mem.buf_read16s(data, timeline_section_ptr + offsets.angles + i * 6 + 4)

        -- position at offset + i*6 (3 x int16: X, Y, Z)
        kf.pos_x = mem.buf_read16s(data, timeline_section_ptr + offsets.position + i * 6)
        kf.pos_y = mem.buf_read16s(data, timeline_section_ptr + offsets.position + i * 6 + 2)
        kf.pos_z = mem.buf_read16s(data, timeline_section_ptr + offsets.position + i * 6 + 4)

        -- zoom at offset + i*6 (first int16 is zoom, other 2 are padding/unused)
        kf.zoom = mem.buf_read16s(data, timeline_section_ptr + offsets.zoom + i * 6)

        -- command at offset + i*2 (uint16)
        kf.command = mem.buf_read16(data, timeline_section_ptr + offsets.command + i * 2)

        table_data.keyframes[i + 1] = kf
    end

    return table_data
end

-- Parse single camera table from PSX memory
function M.parse_camera_table_from_memory(timeline_addr, table_index)
    local offsets = M.CAMERA_TABLE_OFFSETS[table_index]
    if not offsets then return nil end

    local table_data = {
        table_index = table_index - 1,
        max_keyframe = mem.read16s(timeline_addr + offsets.max_keyframe),
        keyframes = {}
    }

    for i = 0, MAX_CAMERA_KEYFRAMES - 1 do
        local kf = {}

        kf.end_frame = mem.read16s(timeline_addr + offsets.end_frame + i * 2)
        kf.pitch = mem.read16s(timeline_addr + offsets.angles + i * 6)
        kf.yaw = mem.read16s(timeline_addr + offsets.angles + i * 6 + 2)
        kf.roll = mem.read16s(timeline_addr + offsets.angles + i * 6 + 4)
        kf.pos_x = mem.read16s(timeline_addr + offsets.position + i * 6)
        kf.pos_y = mem.read16s(timeline_addr + offsets.position + i * 6 + 2)
        kf.pos_z = mem.read16s(timeline_addr + offsets.position + i * 6 + 4)
        kf.zoom = mem.read16s(timeline_addr + offsets.zoom + i * 6)
        kf.command = mem.read16(timeline_addr + offsets.command + i * 2)

        table_data.keyframes[i + 1] = kf
    end

    return table_data
end

-- Parse all 3 camera tables from file data
function M.parse_all_camera_tables(data, timeline_section_ptr)
    local tables = {}
    for i = 1, 3 do
        tables[i] = M.parse_camera_table_from_data(data, timeline_section_ptr, i)
    end
    return tables
end

-- Parse all 3 camera tables from PSX memory
function M.parse_all_camera_tables_from_memory(base_addr, timeline_section_ptr)
    local timeline_addr = base_addr + timeline_section_ptr
    local tables = {}
    for i = 1, 3 do
        tables[i] = M.parse_camera_table_from_memory(timeline_addr, i)
    end
    return tables
end

-- Write single camera table to PSX memory
function M.write_camera_table_to_memory(timeline_addr, table_index, table_data)
    local offsets = M.CAMERA_TABLE_OFFSETS[table_index]
    if not offsets or not table_data then return end

    -- Write max_keyframe
    mem.write16(timeline_addr + offsets.max_keyframe, table_data.max_keyframe)

    -- Write keyframes
    for i = 0, MAX_CAMERA_KEYFRAMES - 1 do
        local kf = table_data.keyframes[i + 1]
        if kf then
            mem.write16(timeline_addr + offsets.end_frame + i * 2, kf.end_frame)
            mem.write16(timeline_addr + offsets.angles + i * 6, kf.pitch)
            mem.write16(timeline_addr + offsets.angles + i * 6 + 2, kf.yaw)
            mem.write16(timeline_addr + offsets.angles + i * 6 + 4, kf.roll)
            mem.write16(timeline_addr + offsets.position + i * 6, kf.pos_x)
            mem.write16(timeline_addr + offsets.position + i * 6 + 2, kf.pos_y)
            mem.write16(timeline_addr + offsets.position + i * 6 + 4, kf.pos_z)
            mem.write16(timeline_addr + offsets.zoom + i * 6, kf.zoom)
            mem.write16(timeline_addr + offsets.command + i * 2, kf.command)
        end
    end
end

-- Write all camera tables to PSX memory
function M.write_all_camera_tables_to_memory(base_addr, timeline_section_ptr, tables)
    local timeline_addr = base_addr + timeline_section_ptr
    for i = 1, 3 do
        if tables[i] then
            M.write_camera_table_to_memory(timeline_addr, i, tables[i])
        end
    end
end

-- Deep copy camera tables
function M.copy_camera_tables(tables)
    if not tables then return nil end
    local copy = {}

    for t = 1, #tables do
        local src = tables[t]
        local dst = {
            table_index = src.table_index,
            max_keyframe = src.max_keyframe,
            keyframes = {}
        }

        for k = 1, MAX_CAMERA_KEYFRAMES do
            local src_kf = src.keyframes[k]
            if src_kf then
                dst.keyframes[k] = {
                    end_frame = src_kf.end_frame,
                    pitch = src_kf.pitch,
                    yaw = src_kf.yaw,
                    roll = src_kf.roll,
                    pos_x = src_kf.pos_x,
                    pos_y = src_kf.pos_y,
                    pos_z = src_kf.pos_z,
                    zoom = src_kf.zoom,
                    command = src_kf.command,
                }
            end
        end

        copy[t] = dst
    end

    return copy
end

--------------------------------------------------------------------------------
-- Color Track Parsing/Writing
--------------------------------------------------------------------------------

-- Color track offsets (relative to timeline_section_ptr or timeline_channel_base)
-- animate_tick offsets are relative to timeline_channel_base (= timeline_section_ptr + 8)
-- phase1/phase2 offsets are relative to timeline_section_ptr
M.COLOR_TRACK_OFFSETS = {
    animate_tick = {
        [1] = { data = 0x0326, max_keyframe = 0x03EC, size = 198, track_type = "palette" },  -- Affected Units
        [2] = { data = 0x03EE, max_keyframe = 0x04B4, size = 198, track_type = "palette" },  -- Caster
        [3] = { data = 0x04B6, max_keyframe = 0x057C, size = 198, track_type = "palette" },  -- Target
        [4] = { data = 0x057E, max_keyframe = 0x06A8, size = 298, track_type = "screen" },   -- Screen
    },
    phase1 = {
        [1] = { data = 0x0DDE, size = 200, track_type = "palette" },  -- Affected Units (198 + 2 max_kf)
        [2] = { data = 0x0EA6, size = 200, track_type = "palette" },  -- Caster
        [3] = { data = 0x0F6E, size = 200, track_type = "palette" },  -- Target
        [4] = { data = 0x1036, size = 300, track_type = "screen" },   -- Screen (298 + 2 max_kf)
    },
    phase2 = {
        [1] = { data = 0x1162, size = 200, track_type = "palette" },
        [2] = { data = 0x122A, size = 200, track_type = "palette" },
        [3] = { data = 0x12F2, size = 200, track_type = "palette" },
        [4] = { data = 0x13BA, size = 300, track_type = "screen" },
    },
}

local MAX_COLOR_KEYFRAMES = 33

-- Parse single palette track (tracks 0-2) from file data
-- Palette track: 198 bytes (time_values[33] + rgb_triplets[33] + ctrl_flags[33])
-- For phase1/phase2, max_keyframe is at the END of the track (offset 198)
local function parse_palette_track_from_data(data, offset, context, track_index, max_kf_offset)
    local track = {
        context = context,
        track_index = track_index - 1,  -- 0-indexed for display
        track_type = "palette",
        keyframes = {}
    }

    -- Read max_keyframe
    if max_kf_offset then
        -- animate_tick: max_keyframe stored at separate offset
        track.max_keyframe = mem.buf_read16s(data, max_kf_offset)
    else
        -- phase1/phase2: max_keyframe at offset + 198 (end of 198-byte track)
        track.max_keyframe = mem.buf_read16s(data, offset + 198)
    end

    -- Parse all 33 keyframes
    for i = 0, MAX_COLOR_KEYFRAMES - 1 do
        local kf = {}

        -- time_value at offset + i*2 (int16)
        kf.time = mem.buf_read16s(data, offset + (i * 2))

        -- RGB at offset + 0x42 + i*3 (interleaved triplets)
        kf.r = mem.buf_read8(data, offset + 0x42 + (i * 3))
        kf.g = mem.buf_read8(data, offset + 0x43 + (i * 3))
        kf.b = mem.buf_read8(data, offset + 0x44 + (i * 3))

        -- ctrl_flags at offset + 0xA5 + i (byte)
        kf.ctrl = mem.buf_read8(data, offset + 0xA5 + i)

        track.keyframes[i + 1] = kf
    end

    return track
end

-- Parse single screen track (track 3) from file data
-- Screen track: 298 bytes (time_values[33] + start_rgb[33] + end_rgb[33] + ctrl_flags[33])
-- For phase1/phase2, max_keyframe is at the END of the track (offset 298)
local function parse_screen_track_from_data(data, offset, context, track_index, max_kf_offset)
    local track = {
        context = context,
        track_index = track_index - 1,  -- 0-indexed for display
        track_type = "screen",
        keyframes = {}
    }

    -- Read max_keyframe
    if max_kf_offset then
        -- animate_tick: max_keyframe stored at separate offset
        track.max_keyframe = mem.buf_read16s(data, max_kf_offset)
    else
        -- phase1/phase2: max_keyframe at offset + 298 (end of 298-byte track)
        track.max_keyframe = mem.buf_read16s(data, offset + 298)
    end

    -- Parse all 33 keyframes
    for i = 0, MAX_COLOR_KEYFRAMES - 1 do
        local kf = {}

        -- time_value at offset + i*2 (int16)
        kf.time = mem.buf_read16s(data, offset + (i * 2))

        -- start_rgb at offset + 0x42 + i*3 (interleaved triplets)
        kf.r = mem.buf_read8(data, offset + 0x42 + (i * 3))
        kf.g = mem.buf_read8(data, offset + 0x43 + (i * 3))
        kf.b = mem.buf_read8(data, offset + 0x44 + (i * 3))

        -- end_rgb at offset + 0xA5 + i*3 (interleaved triplets)
        kf.end_r = mem.buf_read8(data, offset + 0xA5 + (i * 3))
        kf.end_g = mem.buf_read8(data, offset + 0xA6 + (i * 3))
        kf.end_b = mem.buf_read8(data, offset + 0xA7 + (i * 3))

        -- ctrl_flags at offset + 0x108 + i (byte)
        kf.ctrl = mem.buf_read8(data, offset + 0x108 + i)

        track.keyframes[i + 1] = kf
    end

    return track
end

-- Parse single palette track from PSX memory
local function parse_palette_track_from_memory(addr, context, track_index, max_kf_addr)
    local track = {
        context = context,
        track_index = track_index - 1,
        track_type = "palette",
        keyframes = {}
    }

    -- Read max_keyframe
    if max_kf_addr then
        track.max_keyframe = mem.read16s(max_kf_addr)
    else
        track.max_keyframe = mem.read16s(addr + 198)
    end

    -- Parse all 33 keyframes
    for i = 0, MAX_COLOR_KEYFRAMES - 1 do
        local kf = {}
        kf.time = mem.read16s(addr + (i * 2))
        kf.r = mem.read8(addr + 0x42 + (i * 3))
        kf.g = mem.read8(addr + 0x43 + (i * 3))
        kf.b = mem.read8(addr + 0x44 + (i * 3))
        kf.ctrl = mem.read8(addr + 0xA5 + i)
        track.keyframes[i + 1] = kf
    end

    return track
end

-- Parse single screen track from PSX memory
local function parse_screen_track_from_memory(addr, context, track_index, max_kf_addr)
    local track = {
        context = context,
        track_index = track_index - 1,
        track_type = "screen",
        keyframes = {}
    }

    -- Read max_keyframe
    if max_kf_addr then
        track.max_keyframe = mem.read16s(max_kf_addr)
    else
        track.max_keyframe = mem.read16s(addr + 298)
    end

    -- Parse all 33 keyframes
    for i = 0, MAX_COLOR_KEYFRAMES - 1 do
        local kf = {}
        kf.time = mem.read16s(addr + (i * 2))
        kf.r = mem.read8(addr + 0x42 + (i * 3))
        kf.g = mem.read8(addr + 0x43 + (i * 3))
        kf.b = mem.read8(addr + 0x44 + (i * 3))
        kf.end_r = mem.read8(addr + 0xA5 + (i * 3))
        kf.end_g = mem.read8(addr + 0xA6 + (i * 3))
        kf.end_b = mem.read8(addr + 0xA7 + (i * 3))
        kf.ctrl = mem.read8(addr + 0x108 + i)
        track.keyframes[i + 1] = kf
    end

    return track
end

-- Parse all 12 color tracks from file data (4 tracks x 3 contexts)
function M.parse_all_color_tracks(data, timeline_section_ptr)
    local tracks = {}
    local offsets = M.COLOR_TRACK_OFFSETS
    local timeline_channel_base = timeline_section_ptr + 8

    -- animate_tick tracks (base is timeline_channel_base)
    for i = 1, 4 do
        local track_offsets = offsets.animate_tick[i]
        local data_offset = timeline_channel_base + track_offsets.data
        local max_kf_offset = timeline_channel_base + track_offsets.max_keyframe

        if track_offsets.track_type == "palette" then
            tracks[#tracks + 1] = parse_palette_track_from_data(data, data_offset, "animate_tick", i, max_kf_offset)
        else
            tracks[#tracks + 1] = parse_screen_track_from_data(data, data_offset, "animate_tick", i, max_kf_offset)
        end
    end

    -- phase1 tracks (base is timeline_section_ptr)
    for i = 1, 4 do
        local track_offsets = offsets.phase1[i]
        local data_offset = timeline_section_ptr + track_offsets.data

        if track_offsets.track_type == "palette" then
            tracks[#tracks + 1] = parse_palette_track_from_data(data, data_offset, "phase1", i, nil)
        else
            tracks[#tracks + 1] = parse_screen_track_from_data(data, data_offset, "phase1", i, nil)
        end
    end

    -- phase2 tracks (base is timeline_section_ptr)
    for i = 1, 4 do
        local track_offsets = offsets.phase2[i]
        local data_offset = timeline_section_ptr + track_offsets.data

        if track_offsets.track_type == "palette" then
            tracks[#tracks + 1] = parse_palette_track_from_data(data, data_offset, "phase2", i, nil)
        else
            tracks[#tracks + 1] = parse_screen_track_from_data(data, data_offset, "phase2", i, nil)
        end
    end

    return tracks
end

-- Parse all 12 color tracks from PSX memory
function M.parse_all_color_tracks_from_memory(base_addr, timeline_section_ptr)
    local tracks = {}
    local offsets = M.COLOR_TRACK_OFFSETS
    local timeline_addr = base_addr + timeline_section_ptr
    local timeline_channel_base = timeline_addr + 8

    -- animate_tick tracks
    for i = 1, 4 do
        local track_offsets = offsets.animate_tick[i]
        local data_addr = timeline_channel_base + track_offsets.data
        local max_kf_addr = timeline_channel_base + track_offsets.max_keyframe

        if track_offsets.track_type == "palette" then
            tracks[#tracks + 1] = parse_palette_track_from_memory(data_addr, "animate_tick", i, max_kf_addr)
        else
            tracks[#tracks + 1] = parse_screen_track_from_memory(data_addr, "animate_tick", i, max_kf_addr)
        end
    end

    -- phase1 tracks
    for i = 1, 4 do
        local track_offsets = offsets.phase1[i]
        local data_addr = timeline_addr + track_offsets.data

        if track_offsets.track_type == "palette" then
            tracks[#tracks + 1] = parse_palette_track_from_memory(data_addr, "phase1", i, nil)
        else
            tracks[#tracks + 1] = parse_screen_track_from_memory(data_addr, "phase1", i, nil)
        end
    end

    -- phase2 tracks
    for i = 1, 4 do
        local track_offsets = offsets.phase2[i]
        local data_addr = timeline_addr + track_offsets.data

        if track_offsets.track_type == "palette" then
            tracks[#tracks + 1] = parse_palette_track_from_memory(data_addr, "phase2", i, nil)
        else
            tracks[#tracks + 1] = parse_screen_track_from_memory(data_addr, "phase2", i, nil)
        end
    end

    return tracks
end

-- Write single palette track to PSX memory
local function write_palette_track_to_memory(addr, track, max_kf_addr)
    -- Write all 33 keyframes
    for i = 0, MAX_COLOR_KEYFRAMES - 1 do
        local kf = track.keyframes[i + 1]
        if kf then
            mem.write16(addr + (i * 2), kf.time)
            mem.write8(addr + 0x42 + (i * 3), kf.r)
            mem.write8(addr + 0x43 + (i * 3), kf.g)
            mem.write8(addr + 0x44 + (i * 3), kf.b)
            mem.write8(addr + 0xA5 + i, kf.ctrl)
        end
    end

    -- Write max_keyframe
    if max_kf_addr then
        mem.write16(max_kf_addr, track.max_keyframe)
    else
        mem.write16(addr + 198, track.max_keyframe)
    end
end

-- Write single screen track to PSX memory
local function write_screen_track_to_memory(addr, track, max_kf_addr)
    -- Write all 33 keyframes
    for i = 0, MAX_COLOR_KEYFRAMES - 1 do
        local kf = track.keyframes[i + 1]
        if kf then
            mem.write16(addr + (i * 2), kf.time)
            mem.write8(addr + 0x42 + (i * 3), kf.r)
            mem.write8(addr + 0x43 + (i * 3), kf.g)
            mem.write8(addr + 0x44 + (i * 3), kf.b)
            mem.write8(addr + 0xA5 + (i * 3), kf.end_r)
            mem.write8(addr + 0xA6 + (i * 3), kf.end_g)
            mem.write8(addr + 0xA7 + (i * 3), kf.end_b)
            mem.write8(addr + 0x108 + i, kf.ctrl)
        end
    end

    -- Write max_keyframe
    if max_kf_addr then
        mem.write16(max_kf_addr, track.max_keyframe)
    else
        mem.write16(addr + 298, track.max_keyframe)
    end
end

-- Write all color tracks to PSX memory
function M.write_all_color_tracks_to_memory(base_addr, timeline_section_ptr, tracks)
    local offsets = M.COLOR_TRACK_OFFSETS
    local timeline_addr = base_addr + timeline_section_ptr
    local timeline_channel_base = timeline_addr + 8
    local track_idx = 1

    -- animate_tick tracks
    for i = 1, 4 do
        local track_offsets = offsets.animate_tick[i]
        local data_addr = timeline_channel_base + track_offsets.data
        local max_kf_addr = timeline_channel_base + track_offsets.max_keyframe
        local track = tracks[track_idx]
        track_idx = track_idx + 1

        if track then
            if track_offsets.track_type == "palette" then
                write_palette_track_to_memory(data_addr, track, max_kf_addr)
            else
                write_screen_track_to_memory(data_addr, track, max_kf_addr)
            end
        end
    end

    -- phase1 tracks
    for i = 1, 4 do
        local track_offsets = offsets.phase1[i]
        local data_addr = timeline_addr + track_offsets.data
        local track = tracks[track_idx]
        track_idx = track_idx + 1

        if track then
            if track_offsets.track_type == "palette" then
                write_palette_track_to_memory(data_addr, track, nil)
            else
                write_screen_track_to_memory(data_addr, track, nil)
            end
        end
    end

    -- phase2 tracks
    for i = 1, 4 do
        local track_offsets = offsets.phase2[i]
        local data_addr = timeline_addr + track_offsets.data
        local track = tracks[track_idx]
        track_idx = track_idx + 1

        if track then
            if track_offsets.track_type == "palette" then
                write_palette_track_to_memory(data_addr, track, nil)
            else
                write_screen_track_to_memory(data_addr, track, nil)
            end
        end
    end
end

-- Deep copy color tracks
function M.copy_color_tracks(tracks)
    if not tracks then return nil end
    local copy = {}

    for t = 1, #tracks do
        local src = tracks[t]
        local dst = {
            context = src.context,
            track_index = src.track_index,
            track_type = src.track_type,
            max_keyframe = src.max_keyframe,
            keyframes = {}
        }

        for k = 1, MAX_COLOR_KEYFRAMES do
            local src_kf = src.keyframes[k]
            if src_kf then
                dst.keyframes[k] = {
                    time = src_kf.time,
                    r = src_kf.r,
                    g = src_kf.g,
                    b = src_kf.b,
                    ctrl = src_kf.ctrl,
                }
                -- Copy screen track fields if present
                if src_kf.end_r then
                    dst.keyframes[k].end_r = src_kf.end_r
                    dst.keyframes[k].end_g = src_kf.end_g
                    dst.keyframes[k].end_b = src_kf.end_b
                end
            end
        end

        copy[t] = dst
    end

    return copy
end

--------------------------------------------------------------------------------
-- Timing Curves (Time Scale) Section
-- 600 bytes total: 300 bytes process_timeline + 300 bytes animate_tick
-- Nibble-packed: each byte = 2 frame values (low nibble = even, high nibble = odd)
--------------------------------------------------------------------------------

local TIME_SCALE_LENGTH = 600           -- Frames per region
local TIME_SCALE_BYTE_COUNT = 300       -- Bytes per region (nibble-packed)
local ANIMATE_TICK_BYTE_OFFSET = 300    -- Byte offset for animate_tick region (0x12C)

-- Unpack 300 bytes of nibble-packed data into 600 values
-- Each byte: low nibble = even frame, high nibble = odd frame
function M.unpack_nibbles(packed_bytes)
    local values = {}
    for i = 1, #packed_bytes do
        local byte = packed_bytes[i]
        -- Even frame index (2*i - 1)
        values[2 * i - 1] = byte % 16         -- Low nibble
        -- Odd frame index (2*i)
        values[2 * i] = math.floor(byte / 16) -- High nibble
    end
    return values
end

-- Pack 600 values into 300 bytes of nibble-packed data
-- Clamps values to 0-15 range (though 0-9 are the valid timing values)
function M.pack_nibbles(values)
    local packed = {}
    for i = 1, 300 do
        local even_idx = 2 * i - 1
        local odd_idx = 2 * i
        local low = math.max(0, math.min(15, values[even_idx] or 0))
        local high = math.max(0, math.min(15, values[odd_idx] or 0))
        packed[i] = low + (high * 16)
    end
    return packed
end

-- Parse timing curves from file data
-- Returns nil if timing_curve_ptr is 0 (no timing curves)
function M.parse_timing_curves_from_data(data, timing_curve_ptr)
    if not data or timing_curve_ptr == 0 then
        return nil
    end

    -- Read process_timeline region (bytes 0-299)
    local pt_bytes = {}
    for i = 0, TIME_SCALE_BYTE_COUNT - 1 do
        pt_bytes[i + 1] = mem.buf_read8(data, timing_curve_ptr + i)
    end

    -- Read animate_tick region (bytes 300-599)
    local at_bytes = {}
    for i = 0, TIME_SCALE_BYTE_COUNT - 1 do
        at_bytes[i + 1] = mem.buf_read8(data, timing_curve_ptr + ANIMATE_TICK_BYTE_OFFSET + i)
    end

    return {
        process_timeline = M.unpack_nibbles(pt_bytes),
        animate_tick = M.unpack_nibbles(at_bytes)
    }
end

-- Parse timing curves from PSX memory
function M.parse_timing_curves_from_memory(base_addr, timing_curve_ptr)
    if timing_curve_ptr == 0 then
        return nil
    end

    local addr = base_addr + timing_curve_ptr

    -- Read process_timeline region
    local pt_bytes = {}
    for i = 0, TIME_SCALE_BYTE_COUNT - 1 do
        pt_bytes[i + 1] = mem.read8(addr + i)
    end

    -- Read animate_tick region
    local at_bytes = {}
    for i = 0, TIME_SCALE_BYTE_COUNT - 1 do
        at_bytes[i + 1] = mem.read8(addr + ANIMATE_TICK_BYTE_OFFSET + i)
    end

    return {
        process_timeline = M.unpack_nibbles(pt_bytes),
        animate_tick = M.unpack_nibbles(at_bytes)
    }
end

-- Write timing curves to PSX memory
function M.write_timing_curves_to_memory(base_addr, timing_curve_ptr, curves)
    if timing_curve_ptr == 0 or not curves then
        return
    end

    local addr = base_addr + timing_curve_ptr

    -- Write process_timeline region
    local pt_packed = M.pack_nibbles(curves.process_timeline)
    for i = 1, TIME_SCALE_BYTE_COUNT do
        mem.write8(addr + i - 1, pt_packed[i])
    end

    -- Write animate_tick region
    local at_packed = M.pack_nibbles(curves.animate_tick)
    for i = 1, TIME_SCALE_BYTE_COUNT do
        mem.write8(addr + ANIMATE_TICK_BYTE_OFFSET + i - 1, at_packed[i])
    end
end

-- Deep copy timing curves for reset functionality
function M.copy_timing_curves(curves)
    if not curves then return nil end
    local copy = {
        process_timeline = {},
        animate_tick = {}
    }
    for i = 1, TIME_SCALE_LENGTH do
        copy.process_timeline[i] = curves.process_timeline[i] or 0
        copy.animate_tick[i] = curves.animate_tick[i] or 0
    end
    return copy
end

--------------------------------------------------------------------------------
-- Effect Flags Section
-- First byte (offset 0x00) contains behavior flags including timing curve enables
--------------------------------------------------------------------------------

-- Parse effect flags from file data
function M.parse_effect_flags_from_data(data, effect_flags_ptr)
    if not data or not effect_flags_ptr then
        return nil
    end
    return {
        flags_byte = mem.buf_read8(data, effect_flags_ptr)
    }
end

-- Parse effect flags from PSX memory
function M.parse_effect_flags_from_memory(base_addr, effect_flags_ptr)
    return {
        flags_byte = mem.read8(base_addr + effect_flags_ptr)
    }
end

-- Write effect flags to PSX memory (only flags_byte for now)
function M.write_effect_flags_to_memory(base_addr, effect_flags_ptr, flags)
    if not flags then return end
    mem.write8(base_addr + effect_flags_ptr, flags.flags_byte)
end

-- Deep copy effect flags
function M.copy_effect_flags(flags)
    if not flags then return nil end
    return { flags_byte = flags.flags_byte }
end

--------------------------------------------------------------------------------
-- Script Bytecode Opcodes (46 opcodes, sizes 2/4/6/8 bytes)
-- Instruction format: [opcode_word:16][params...]
-- opcode_word bits 0-8 = handler ID (mask 0x1FF), bits 9-15 = flags
--------------------------------------------------------------------------------

-- Script opcode definitions: id -> {name, size, params}
-- params is array of {name, type} where type is "offset", "s16", or "ptr"
M.SCRIPT_OPCODES = {
    [0]  = {name = "goto_yield",           size = 4, params = {{name = "target", type = "offset"}}},
    [1]  = {name = "goto",                 size = 4, params = {{name = "target", type = "offset"}}},
    [2]  = {name = "spawn_child_effect",   size = 4, params = {{name = "child_entry", type = "offset"}}},
    [3]  = {name = "terminate_child",      size = 2, params = {}},
    [4]  = {name = "end",                  size = 2, params = {}},
    [5]  = {name = "set_texture_page",     size = 2, params = {}},
    [6]  = {name = "load_callback",        size = 4, params = {{name = "callback_ptr", type = "ptr"}}},
    [7]  = {name = "invoke_callback",      size = 4, params = {{name = "callback_arg", type = "s16"}}},
    [8]  = {name = "load_position",        size = 8, params = {{name = "x", type = "s16"}, {name = "y", type = "s16"}, {name = "z", type = "s16"}}},
    [9]  = {name = "store_pos_to_origin",  size = 2, params = {}},
    [10] = {name = "load_pos_from_origin", size = 2, params = {}},
    [11] = {name = "set_rotation",         size = 8, params = {{name = "rx", type = "s16"}, {name = "ry", type = "s16"}, {name = "rz", type = "s16"}}},
    [12] = {name = "apply_camera_rotation",size = 2, params = {}},
    [13] = {name = "load_camera_rotation", size = 2, params = {}},
    [14] = {name = "set_sprite_scale",     size = 8, params = {{name = "sx", type = "s16"}, {name = "sy", type = "s16"}, {name = "sz", type = "s16"}}},
    [15] = {name = "apply_sprite_scale",   size = 2, params = {}},
    [16] = {name = "set_script_reg",       size = 4, params = {{name = "value", type = "s16"}}},
    [17] = {name = "branch_reg_eq",        size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [18] = {name = "branch_reg_ge",        size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [19] = {name = "branch_reg_gt",        size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [20] = {name = "branch_reg_le",        size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [21] = {name = "branch_reg_lt",        size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [22] = {name = "branch_count_eq",      size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [23] = {name = "branch_count_gt",      size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [24] = {name = "branch_count_lt",      size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [25] = {name = "branch_child_count_eq",size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [26] = {name = "branch_child_active",  size = 4, params = {{name = "target", type = "offset"}}},
    [27] = {name = "branch_child_inactive",size = 4, params = {{name = "target", type = "offset"}}},
    [28] = {name = "branch_reg_ne",        size = 6, params = {{name = "value", type = "s16"}, {name = "target", type = "offset"}}},
    [29] = {name = "branch_anim_done",     size = 4, params = {{name = "target", type = "offset"}}},
    [30] = {name = "branch_anim_done_cplx",size = 4, params = {{name = "target", type = "offset"}}},
    [31] = {name = "branch_target_type",   size = 4, params = {{name = "target", type = "offset"}}},
    [32] = {name = "inc_script_reg",       size = 2, params = {}},
    [33] = {name = "dec_script_reg",       size = 2, params = {}},
    [34] = {name = "add_script_reg",       size = 4, params = {{name = "value", type = "s16"}}},
    [35] = {name = "sub_script_reg",       size = 4, params = {{name = "value", type = "s16"}}},
    [36] = {name = "reset_sprite_scale",   size = 2, params = {}},
    [37] = {name = "update_all_particles", size = 2, params = {}},
    [38] = {name = "spawn_emitter",        size = 2, params = {}},
    [39] = {name = "init_physics_params",  size = 2, params = {}},
    [40] = {name = "animate_tick",         size = 2, params = {}},
    [41] = {name = "process_timeline",     size = 4, params = {{name = "phase", type = "s16"}}},
    [42] = {name = "clear_timeline_a",     size = 2, params = {}},
    [43] = {name = "clear_timeline_b",     size = 2, params = {}},
    [44] = {name = "nop_44",               size = 2, params = {}},
    [45] = {name = "nop_45",               size = 2, params = {}},
}

-- Get script opcode info by ID
function M.get_script_opcode_info(opcode_id)
    return M.SCRIPT_OPCODES[opcode_id] or {name = string.format("unknown_%02X", opcode_id), size = 2, params = {}}
end

-- Parse script instructions from file data buffer
-- Returns array of instruction objects
function M.parse_script_from_data(data, script_ptr, section_size)
    local instructions = {}
    local offset = 0

    while offset < section_size do
        -- Read opcode word (2 bytes) - always safe if offset < section_size
        local opcode_word = mem.buf_read16(data, script_ptr + offset)
        local opcode_id = opcode_word % 512  -- bits 0-8 (0x1FF mask)
        local flags = math.floor(opcode_word / 512)  -- bits 9-15

        local info = M.get_script_opcode_info(opcode_id)

        -- CRITICAL: Check if full instruction fits within section bounds
        -- If not, the opcode word we read is actually from the next section
        if offset + info.size > section_size then
            break
        end

        local inst = {
            offset = offset,
            opcode_id = opcode_id,
            opcode_word = opcode_word,
            flags = flags,
            name = info.name,
            size = info.size,
            params = {}
        }

        -- Parse parameters based on size and param definitions
        local param_offset = 2  -- Start after opcode word
        for i, param_def in ipairs(info.params) do
            local val = mem.buf_read16s(data, script_ptr + offset + param_offset)
            inst.params[param_def.name] = val
            param_offset = param_offset + 2
        end

        table.insert(instructions, inst)
        offset = offset + info.size

        -- Safety: prevent infinite loop on unknown opcodes
        if info.size == 0 then
            break
        end
    end

    return instructions
end

-- Parse script instructions from PSX memory
function M.parse_script_from_memory(base_addr, script_ptr, section_size)
    local instructions = {}
    local offset = 0
    local addr = base_addr + script_ptr

    while offset < section_size do
        -- Read opcode word (2 bytes)
        local opcode_word = mem.read16(addr + offset)
        local opcode_id = opcode_word % 512  -- bits 0-8
        local flags = math.floor(opcode_word / 512)  -- bits 9-15

        local info = M.get_script_opcode_info(opcode_id)

        -- CRITICAL: Check if full instruction fits within section bounds
        if offset + info.size > section_size then
            break
        end

        local inst = {
            offset = offset,
            opcode_id = opcode_id,
            opcode_word = opcode_word,
            flags = flags,
            name = info.name,
            size = info.size,
            params = {}
        }

        -- Parse parameters
        local param_offset = 2
        for i, param_def in ipairs(info.params) do
            local val = mem.read16s(addr + offset + param_offset)
            inst.params[param_def.name] = val
            param_offset = param_offset + 2
        end

        table.insert(instructions, inst)
        offset = offset + info.size

        if info.size == 0 then
            break
        end
    end

    return instructions
end

-- Calculate total byte size of script instructions
function M.calculate_script_size(instructions)
    local size = 0
    for _, inst in ipairs(instructions) do
        local info = M.SCRIPT_OPCODES[inst.opcode_id] or {size = 2}
        size = size + info.size
    end
    return size
end

-- Serialize script instructions to byte string
function M.serialize_script_instructions(instructions)
    local bytes = {}

    for _, inst in ipairs(instructions) do
        local info = M.SCRIPT_OPCODES[inst.opcode_id] or {size = 2, params = {}}

        -- Reconstruct opcode word with flags
        local opcode_word = inst.opcode_id + (inst.flags * 512)

        -- Write opcode word (little-endian)
        table.insert(bytes, string.char(opcode_word % 256))
        table.insert(bytes, string.char(math.floor(opcode_word / 256) % 256))

        -- Write parameter bytes
        for _, param_def in ipairs(info.params) do
            local val = inst.params[param_def.name] or 0
            -- Handle signed values for serialization
            if val < 0 then
                val = val + 65536
            end
            table.insert(bytes, string.char(val % 256))
            table.insert(bytes, string.char(math.floor(val / 256) % 256))
        end
    end

    return table.concat(bytes)
end

-- Write script instructions to PSX memory
function M.write_script_to_memory(base_addr, script_ptr, instructions)
    local offset = 0
    local addr = base_addr + script_ptr

    for _, inst in ipairs(instructions) do
        local info = M.SCRIPT_OPCODES[inst.opcode_id] or {size = 2, params = {}}

        -- Reconstruct and write opcode word
        local opcode_word = inst.opcode_id + (inst.flags * 512)
        mem.write16(addr + offset, opcode_word)

        -- Write parameters
        local param_offset = 2
        for _, param_def in ipairs(info.params) do
            local val = inst.params[param_def.name] or 0
            mem.write16(addr + offset + param_offset, val)
            param_offset = param_offset + 2
        end

        offset = offset + info.size
    end
end

-- Deep copy script instructions
function M.copy_script_instructions(instructions)
    if not instructions then return nil end

    local copy = {}
    for _, inst in ipairs(instructions) do
        local new_inst = {
            offset = inst.offset,
            opcode_id = inst.opcode_id,
            opcode_word = inst.opcode_word,
            flags = inst.flags,
            name = inst.name,
            size = inst.size,
            params = {}
        }
        for k, v in pairs(inst.params) do
            new_inst.params[k] = v
        end
        table.insert(copy, new_inst)
    end
    return copy
end

-- Create a new script instruction with default parameters
function M.create_script_instruction(opcode_id)
    local info = M.SCRIPT_OPCODES[opcode_id] or {name = "unknown", size = 2, params = {}}

    local inst = {
        offset = 0,  -- Will be recalculated on write
        opcode_id = opcode_id,
        opcode_word = opcode_id,  -- No flags by default
        flags = 0,
        name = info.name,
        size = info.size,
        params = {}
    }

    -- Initialize all params to 0
    for _, param_def in ipairs(info.params) do
        inst.params[param_def.name] = 0
    end

    return inst
end

-- Recalculate offsets for all instructions (after insert/delete)
function M.recalculate_script_offsets(instructions)
    local offset = 0
    for _, inst in ipairs(instructions) do
        inst.offset = offset
        local info = M.SCRIPT_OPCODES[inst.opcode_id] or {size = 2}
        offset = offset + info.size
    end
end

--------------------------------------------------------------------------------
-- Sound Flags Parsing/Writing (effect_flags section bytes 0x08-0x17)
--------------------------------------------------------------------------------

-- Sound channel mode names for UI
M.SOUND_MODE_NAMES = {
    [0] = "DIRECT_A",
    [1] = "PARITY_AB",
    [2] = "FIRST_A_THEN_B",
    [3] = "FIRST_A_THEN_BC",
    [4] = "CYCLE_ABC",
}

-- Parse sound flags from file data (4 channels at effect_flags +0x08)
function M.parse_sound_flags_from_data(data, effect_flags_ptr)
    local flags = {}
    for i = 0, 3 do
        local offset = effect_flags_ptr + 0x08 + (i * 4)
        flags[i + 1] = {
            mode = mem.buf_read8(data, offset + 0),
            id_a = mem.buf_read8(data, offset + 1),
            id_b = mem.buf_read8(data, offset + 2),
            id_c = mem.buf_read8(data, offset + 3),
        }
    end
    return flags
end

-- Parse sound flags from PSX memory
function M.parse_sound_flags_from_memory(base_addr, effect_flags_ptr)
    local flags = {}
    for i = 0, 3 do
        local addr = base_addr + effect_flags_ptr + 0x08 + (i * 4)
        flags[i + 1] = {
            mode = mem.read8(addr + 0),
            id_a = mem.read8(addr + 1),
            id_b = mem.read8(addr + 2),
            id_c = mem.read8(addr + 3),
        }
    end
    return flags
end

-- Write sound flags to PSX memory
function M.write_sound_flags_to_memory(base_addr, effect_flags_ptr, flags)
    if not flags then return end
    for i = 0, 3 do
        local addr = base_addr + effect_flags_ptr + 0x08 + (i * 4)
        local ch = flags[i + 1]
        if ch then
            mem.write8(addr + 0, ch.mode or 0)
            mem.write8(addr + 1, ch.id_a or 0)
            mem.write8(addr + 2, ch.id_b or 0)
            mem.write8(addr + 3, ch.id_c or 0)
        end
    end
end

-- Deep copy sound flags
function M.copy_sound_flags(flags)
    if not flags then return nil end
    local copy = {}
    for i = 1, 4 do
        if flags[i] then
            copy[i] = {
                mode = flags[i].mode,
                id_a = flags[i].id_a,
                id_b = flags[i].id_b,
                id_c = flags[i].id_c,
            }
        end
    end
    return copy
end

--------------------------------------------------------------------------------
-- SMD Opcode Definitions (for feds section)
--------------------------------------------------------------------------------

-- SMD opcode definitions: opcode -> {name, param_count}
-- Complete table verified from disassembly jump table at 0x80028b0c
-- Handler receives a0 = ptr to first byte AFTER opcode; returns v0 = new position
M.SMD_OPCODES = {
    -- 0x80-0x9F
    [0x80] = {"Rest", 1},
    [0x81] = {"Fermata", 1},
    [0x8A] = {"Unk_8A", 0},
    [0x8D] = {"Unk_8D", 0},
    [0x8E] = {"Unk_8E", 3},
    [0x8F] = {"Unk_8F", 0},
    [0x90] = {"EndBar", 0},
    [0x91] = {"Loop", 0},
    [0x94] = {"Octave", 1},
    [0x95] = {"RaiseOctave", 0},
    [0x96] = {"LowerOctave", 0},
    [0x97] = {"Unk_97", 2},
    [0x98] = {"Repeat", 1},
    [0x99] = {"Coda", 0},
    [0x9A] = {"Unk_9A", 0},
    [0x9C] = {"Unk_9C", 3},
    [0x9D] = {"Unk_9D", 2},
    [0x9E] = {"Unk_9E", 3},
    -- 0xA0-0xBF
    [0xA0] = {"Tempo", 1},
    [0xA1] = {"Unk_A1", 1},
    [0xA2] = {"Unk_A2", 2},
    [0xA4] = {"Unk_A4", 1},
    [0xA5] = {"Unk_A5", 1},
    [0xA6] = {"Unk_A6", 1},
    [0xA7] = {"Unk_A7", 2},
    [0xA9] = {"Unk_A9", 1},
    [0xAA] = {"Unk_AA", 1},
    [0xAC] = {"Instrument", 1},
    [0xAD] = {"Unk_AD", 1},
    [0xAE] = {"Unk_AE", 0},
    [0xAF] = {"Unk_AF", 0},
    [0xB0] = {"Flag_0x800", 0},
    [0xB1] = {"Unk_B1", 0},
    [0xB2] = {"Unk_B2", 0},
    [0xB3] = {"Unk_B3", 0},
    [0xB4] = {"Unk_B4", 1},
    [0xB5] = {"Unk_B5", 1},
    [0xB6] = {"Unk_B6", 0},
    [0xB7] = {"Unk_B7", 0},
    [0xB8] = {"Unk_B8", 3},
    [0xBA] = {"ReverbOn", 0},
    [0xBB] = {"ReverbOff", 0},
    -- 0xC0-0xDF
    [0xC0] = {"Unk_C0", 1},
    [0xC1] = {"Unk_C1", 3},
    [0xC2] = {"Unk_C2", 1},
    [0xC3] = {"Unk_C3", 1},
    [0xC4] = {"Release", 1},
    [0xC5] = {"Unk_C5", 1},
    [0xC6] = {"Unk_C6", 1},
    [0xC7] = {"Unk_C7", 2},
    [0xC8] = {"Unk_C8", 1},
    [0xC9] = {"Unk_C9", 1},
    [0xCA] = {"Unk_CA", 1},
    [0xD0] = {"SetPitchBend", 1},
    [0xD1] = {"AddPitchBend", 1},
    [0xD2] = {"Unk_D2", 1},
    [0xD3] = {"Unk_D3", 2},
    [0xD4] = {"Unk_D4", 2},
    [0xD5] = {"Unk_D5", 0},
    [0xD6] = {"Unk_D6", 1},  -- Variable, default 1
    [0xD7] = {"Unk_D7", 1},  -- Variable, default 1
    [0xD8] = {"Unk_D8", 3},
    [0xD9] = {"Unk_D9", 3},  -- CRITICAL: Was defaulting to 0, broke Cure parsing
    [0xDA] = {"Unk_DA", 0},
    [0xDB] = {"Unk_DB", 0},
    [0xDC] = {"Unk_DC", 0},
    -- 0xE0-0xFF
    [0xE0] = {"Dynamics", 1},
    [0xE1] = {"Unk_E1", 1},
    [0xE2] = {"Expression", 2},  -- FIXED: Was 1, actually 2
    [0xE3] = {"Unk_E3", 0},
    [0xE4] = {"Unk_E4", 3},
    [0xE5] = {"Unk_E5", 3},
    [0xE6] = {"Unk_E6", 0},
    [0xE7] = {"Unk_E7", 0},
    [0xE8] = {"Unk_E8", 1},
    [0xE9] = {"Unk_E9", 1},
    [0xEA] = {"Unk_EA", 2},
    [0xEB] = {"Unk_EB", 0},
    [0xEC] = {"Unk_EC", 3},
    [0xED] = {"Unk_ED", 3},
    [0xEE] = {"Unk_EE", 0},
    [0xEF] = {"Unk_EF", 0},
    [0xF0] = {"Unk_F0", 3},
    [0xF1] = {"Unk_F1", 2},  -- Variable, default 2
    [0xF2] = {"Unk_F2", 2},
    [0xF5] = {"Unk_F5", 1},  -- Variable, default 1
    [0xF6] = {"Unk_F6", 1},
    [0xF7] = {"Unk_F7", 1},
}

-- Get opcode info: name and param count
function M.get_opcode_info(opcode)
    if opcode < 0x80 then
        -- Note: volume encoded in opcode, 1 param for pitch/duration
        return "Note", 1
    elseif M.SMD_OPCODES[opcode] then
        local def = M.SMD_OPCODES[opcode]
        return def[1], def[2]
    else
        return string.format("Unk_%02X", opcode), 0
    end
end

-- Parse SMD opcodes from raw byte string
function M.parse_smd_opcodes(raw_bytes)
    local opcodes = {}
    local i = 1
    local len = #raw_bytes

    while i <= len do
        local opcode = raw_bytes:byte(i)
        local name, param_count = M.get_opcode_info(opcode)

        local op = {
            opcode = opcode,
            name = name,
            params = {},
            byte_length = 1 + param_count,
        }

        for p = 1, param_count do
            if i + p <= len then
                op.params[p] = raw_bytes:byte(i + p)
            else
                op.params[p] = 0
            end
        end

        table.insert(opcodes, op)
        i = i + op.byte_length
    end

    return opcodes
end

-- Serialize opcodes back to raw bytes string
function M.serialize_smd_opcodes(opcodes)
    local bytes = {}
    for _, op in ipairs(opcodes) do
        table.insert(bytes, string.char(op.opcode))
        for _, param in ipairs(op.params) do
            table.insert(bytes, string.char(param))
        end
    end
    return table.concat(bytes)
end

-- Create a new opcode with default parameters
function M.create_opcode(opcode_byte)
    local name, param_count = M.get_opcode_info(opcode_byte)
    local op = {
        opcode = opcode_byte,
        name = name,
        params = {},
        byte_length = 1 + param_count,
    }
    -- Initialize params with zeros
    for p = 1, param_count do
        op.params[p] = 0
    end
    return op
end

--------------------------------------------------------------------------------
-- Sound Definition ("feds" section) Parsing/Writing
--------------------------------------------------------------------------------

-- Parse feds section from file data
function M.parse_sound_definition_from_data(data, sound_def_ptr, section_size)
    if section_size < 24 then return nil end

    local magic = data:sub(sound_def_ptr + 1, sound_def_ptr + 4)
    if magic ~= "feds" then return nil end

    local def = {
        magic = magic,
        data_size = mem.buf_read32(data, sound_def_ptr + 0x04),
        pair_count_plus1 = mem.buf_read16(data, sound_def_ptr + 0x08),
        resource_id = mem.buf_read16(data, sound_def_ptr + 0x0A),
        data_offset = mem.buf_read32(data, sound_def_ptr + 0x0C),
        reserved = {},
        channel_offsets = {},
        channels = {},
    }

    -- Read reserved bytes
    for i = 0, 7 do
        def.reserved[i + 1] = mem.buf_read8(data, sound_def_ptr + 0x10 + i)
    end

    -- Calculate channel count: (pair_count_plus1 - 1) * 2
    def.num_channels = (def.pair_count_plus1 - 1) * 2
    if def.num_channels < 0 or def.num_channels > 16 then
        def.num_channels = 0
    end

    -- Read channel offsets
    for i = 0, def.num_channels - 1 do
        def.channel_offsets[i + 1] = mem.buf_read16(data, sound_def_ptr + 0x18 + (i * 2))
    end

    -- Parse each channel's SMD data
    for i = 1, def.num_channels do
        local ch_start = def.channel_offsets[i]
        local ch_end
        if i < def.num_channels then
            ch_end = def.channel_offsets[i + 1]
        else
            ch_end = def.data_size
        end
        local ch_size = ch_end - ch_start

        local raw_bytes = ""
        if ch_size > 0 then
            raw_bytes = data:sub(sound_def_ptr + ch_start + 1, sound_def_ptr + ch_end)
        end

        def.channels[i] = {
            offset = ch_start,
            size = ch_size,
            raw_bytes = raw_bytes,
            opcodes = M.parse_smd_opcodes(raw_bytes),
        }
    end

    return def
end

-- Parse feds section from PSX memory
function M.parse_sound_definition_from_memory(base_addr, sound_def_ptr, section_size)
    if section_size < 24 then return nil end

    local addr = base_addr + sound_def_ptr

    -- Check magic
    local magic_bytes = {}
    for i = 0, 3 do
        magic_bytes[i + 1] = string.char(mem.read8(addr + i))
    end
    local magic = table.concat(magic_bytes)
    if magic ~= "feds" then return nil end

    local def = {
        magic = magic,
        data_size = mem.read32(addr + 0x04),
        pair_count_plus1 = mem.read16(addr + 0x08),
        resource_id = mem.read16(addr + 0x0A),
        data_offset = mem.read32(addr + 0x0C),
        reserved = {},
        channel_offsets = {},
        channels = {},
    }

    -- Read reserved bytes
    for i = 0, 7 do
        def.reserved[i + 1] = mem.read8(addr + 0x10 + i)
    end

    -- Calculate channel count
    def.num_channels = (def.pair_count_plus1 - 1) * 2
    if def.num_channels < 0 or def.num_channels > 16 then
        def.num_channels = 0
    end

    -- Read channel offsets
    for i = 0, def.num_channels - 1 do
        def.channel_offsets[i + 1] = mem.read16(addr + 0x18 + (i * 2))
    end

    -- Parse each channel's SMD data
    for i = 1, def.num_channels do
        local ch_start = def.channel_offsets[i]
        local ch_end
        if i < def.num_channels then
            ch_end = def.channel_offsets[i + 1]
        else
            ch_end = def.data_size
        end
        local ch_size = ch_end - ch_start

        -- Read raw bytes from memory
        local raw_bytes_table = {}
        for j = 0, ch_size - 1 do
            raw_bytes_table[j + 1] = string.char(mem.read8(addr + ch_start + j))
        end
        local raw_bytes = table.concat(raw_bytes_table)

        def.channels[i] = {
            offset = ch_start,
            size = ch_size,
            raw_bytes = raw_bytes,
            opcodes = M.parse_smd_opcodes(raw_bytes),
        }
    end

    return def
end

-- Serialize sound definition to bytes (returns byte string and new data_size)
function M.serialize_sound_definition(def)
    if not def then return nil, 0 end

    local result = {}

    -- Serialize all channels first to calculate new offsets
    local channel_bytes = {}
    local new_offsets = {}

    -- Header is 0x18 bytes + (num_channels * 2) for offset table
    local header_size = 0x18 + (def.num_channels * 2)
    -- Align data_offset to typical value (round up to multiple of 4)
    local new_data_offset = math.ceil(header_size / 4) * 4
    local current_offset = new_data_offset

    for i, ch in ipairs(def.channels) do
        local ch_raw = M.serialize_smd_opcodes(ch.opcodes)
        channel_bytes[i] = ch_raw
        new_offsets[i] = current_offset
        current_offset = current_offset + #ch_raw
    end

    local new_data_size = current_offset

    -- Write header (24 bytes minimum)
    -- Magic "feds"
    for i = 1, 4 do
        table.insert(result, def.magic:byte(i))
    end

    -- data_size (4 bytes, little-endian)
    table.insert(result, new_data_size % 256)
    table.insert(result, math.floor(new_data_size / 256) % 256)
    table.insert(result, math.floor(new_data_size / 65536) % 256)
    table.insert(result, math.floor(new_data_size / 16777216) % 256)

    -- pair_count_plus1 (2 bytes, little-endian)
    table.insert(result, def.pair_count_plus1 % 256)
    table.insert(result, math.floor(def.pair_count_plus1 / 256) % 256)

    -- resource_id (2 bytes, little-endian)
    table.insert(result, def.resource_id % 256)
    table.insert(result, math.floor(def.resource_id / 256) % 256)

    -- data_offset (4 bytes, little-endian)
    table.insert(result, new_data_offset % 256)
    table.insert(result, math.floor(new_data_offset / 256) % 256)
    table.insert(result, math.floor(new_data_offset / 65536) % 256)
    table.insert(result, math.floor(new_data_offset / 16777216) % 256)

    -- reserved (8 bytes)
    for i = 1, 8 do
        table.insert(result, def.reserved[i] or 0)
    end

    -- channel_offsets (num_channels * 2 bytes)
    for i = 1, def.num_channels do
        local off = new_offsets[i] or 0
        table.insert(result, off % 256)
        table.insert(result, math.floor(off / 256) % 256)
    end

    -- Pad to data_offset if needed
    while #result < new_data_offset do
        table.insert(result, 0)
    end

    -- Channel data
    for i = 1, def.num_channels do
        local ch_raw = channel_bytes[i]
        for j = 1, #ch_raw do
            table.insert(result, ch_raw:byte(j))
        end
    end

    -- Convert to byte string
    local byte_chars = {}
    for i, b in ipairs(result) do
        byte_chars[i] = string.char(b)
    end

    return table.concat(byte_chars), new_data_size
end

-- Deep copy sound definition
function M.copy_sound_definition(def)
    if not def then return nil end

    local copy = {
        magic = def.magic,
        data_size = def.data_size,
        pair_count_plus1 = def.pair_count_plus1,
        resource_id = def.resource_id,
        data_offset = def.data_offset,
        num_channels = def.num_channels,
        reserved = {},
        channel_offsets = {},
        channels = {},
    }

    -- Copy reserved
    for i = 1, 8 do
        copy.reserved[i] = def.reserved[i]
    end

    -- Copy channel offsets
    for i = 1, def.num_channels do
        copy.channel_offsets[i] = def.channel_offsets[i]
    end

    -- Copy channels with deep copy of opcodes
    for i = 1, def.num_channels do
        local ch = def.channels[i]
        local ch_copy = {
            offset = ch.offset,
            size = ch.size,
            raw_bytes = ch.raw_bytes,
            opcodes = {},
        }
        for j, op in ipairs(ch.opcodes) do
            local op_copy = {
                opcode = op.opcode,
                name = op.name,
                byte_length = op.byte_length,
                params = {},
            }
            for k, p in ipairs(op.params) do
                op_copy.params[k] = p
            end
            ch_copy.opcodes[j] = op_copy
        end
        copy.channels[i] = ch_copy
    end

    return copy
end

--------------------------------------------------------------------------------
-- Frames Section Parsing
-- Frame = 24 bytes: flags, texture_page, UV, 4 vertices
-- Frameset = header (4 bytes) + N frames
-- Section = group_count + group entries + offset tables + frameset data
--------------------------------------------------------------------------------

local FRAME_SIZE = 24
local FRAMESET_HEADER_SIZE = 4

-- Decode flags_byte0 (palette, semi_trans_mode, is_8bpp)
local function decode_frame_flags_byte0(byte0)
    return {
        palette_id = byte0 % 16,                        -- bits 0-3
        semi_trans_mode = math.floor(byte0 / 32) % 4,   -- bits 5-6
        is_8bpp = math.floor(byte0 / 128) >= 1,         -- bit 7
    }
end

-- Decode flags_byte1 (semi_trans_on, width_signed, height_signed)
local function decode_frame_flags_byte1(byte1)
    return {
        semi_trans_on = math.floor(byte1 / 2) % 2 == 1,    -- bit 1
        width_signed = math.floor(byte1 / 16) % 2 == 1,    -- bit 4
        height_signed = math.floor(byte1 / 32) % 2 == 1,   -- bit 5
    }
end

-- Encode flags_byte0 from decoded values
local function encode_frame_flags_byte0(palette_id, semi_trans_mode, is_8bpp)
    return (palette_id % 16) + (semi_trans_mode % 4) * 32 + (is_8bpp and 128 or 0)
end

-- Encode flags_byte1 from decoded values
local function encode_frame_flags_byte1(semi_trans_on, width_signed, height_signed)
    return (semi_trans_on and 2 or 0) + (width_signed and 16 or 0) + (height_signed and 32 or 0)
end

-- Decode texture_page (TPAGE register)
local function decode_texture_page(tpage)
    return {
        x_base = tpage % 16,                             -- bits 0-3 (VRAM X / 64)
        y_base = math.floor(tpage / 16) % 2,             -- bit 4 (VRAM Y / 256)
        semi_trans_mode = math.floor(tpage / 32) % 4,    -- bits 5-6
        color_depth = math.floor(tpage / 128) % 4,       -- bits 7-8 (0=4bit, 1=8bit, 2=15bit)
    }
end

-- Encode texture_page from decoded values
local function encode_texture_page(x_base, y_base, semi_trans_mode, color_depth)
    return (x_base % 16) + (y_base % 2) * 16 + (semi_trans_mode % 4) * 32 + (color_depth % 4) * 128
end

-- Parse a single frame (24 bytes) from buffer
local function parse_frame_from_buffer(data, offset, frame_index)
    local flags_byte0 = mem.buf_read8(data, offset)
    local flags_byte1 = mem.buf_read8(data, offset + 1)
    local texture_page = mem.buf_read16(data, offset + 2)

    local uv_x = mem.buf_read8(data, offset + 4)
    local uv_y = mem.buf_read8(data, offset + 5)

    -- UV width/height can be signed
    local flags1 = decode_frame_flags_byte1(flags_byte1)
    local uv_width, uv_height
    if flags1.width_signed then
        uv_width = mem.buf_read8(data, offset + 6)
        if uv_width > 127 then uv_width = uv_width - 256 end
    else
        uv_width = mem.buf_read8(data, offset + 6)
    end
    if flags1.height_signed then
        uv_height = mem.buf_read8(data, offset + 7)
        if uv_height > 127 then uv_height = uv_height - 256 end
    else
        uv_height = mem.buf_read8(data, offset + 7)
    end

    -- Vertices (signed 16-bit)
    local vtx_tl_x = mem.buf_read16s(data, offset + 8)
    local vtx_tl_y = mem.buf_read16s(data, offset + 10)
    local vtx_tr_x = mem.buf_read16s(data, offset + 12)
    local vtx_tr_y = mem.buf_read16s(data, offset + 14)
    local vtx_bl_x = mem.buf_read16s(data, offset + 16)
    local vtx_bl_y = mem.buf_read16s(data, offset + 18)
    local vtx_br_x = mem.buf_read16s(data, offset + 20)
    local vtx_br_y = mem.buf_read16s(data, offset + 22)

    local flags0 = decode_frame_flags_byte0(flags_byte0)
    local tpage = decode_texture_page(texture_page)

    return {
        index = frame_index,
        offset = offset,
        -- Raw bytes for flags
        flags_byte0 = flags_byte0,
        flags_byte1 = flags_byte1,
        texture_page_raw = texture_page,
        -- Decoded flags
        palette_id = flags0.palette_id,
        semi_trans_mode = flags0.semi_trans_mode,
        is_8bpp = flags0.is_8bpp,
        semi_trans_on = flags1.semi_trans_on,
        width_signed = flags1.width_signed,
        height_signed = flags1.height_signed,
        -- Decoded texture page
        tpage_x_base = tpage.x_base,
        tpage_y_base = tpage.y_base,
        tpage_blend = tpage.semi_trans_mode,
        tpage_color_depth = tpage.color_depth,
        -- UV coordinates
        uv_x = uv_x,
        uv_y = uv_y,
        uv_width = uv_width,
        uv_height = uv_height,
        -- Vertices
        vtx_tl_x = vtx_tl_x,
        vtx_tl_y = vtx_tl_y,
        vtx_tr_x = vtx_tr_x,
        vtx_tr_y = vtx_tr_y,
        vtx_bl_x = vtx_bl_x,
        vtx_bl_y = vtx_bl_y,
        vtx_br_x = vtx_br_x,
        vtx_br_y = vtx_br_y,
    }
end

-- Parse a single frame (24 bytes) from memory
local function parse_frame_from_memory(addr, frame_index)
    local flags_byte0 = mem.read8(addr)
    local flags_byte1 = mem.read8(addr + 1)
    local texture_page = mem.read16(addr + 2)

    local uv_x = mem.read8(addr + 4)
    local uv_y = mem.read8(addr + 5)

    local flags1 = decode_frame_flags_byte1(flags_byte1)
    local uv_width, uv_height
    if flags1.width_signed then
        uv_width = mem.read8(addr + 6)
        if uv_width > 127 then uv_width = uv_width - 256 end
    else
        uv_width = mem.read8(addr + 6)
    end
    if flags1.height_signed then
        uv_height = mem.read8(addr + 7)
        if uv_height > 127 then uv_height = uv_height - 256 end
    else
        uv_height = mem.read8(addr + 7)
    end

    -- Vertices (signed 16-bit)
    local vtx_tl_x = mem.read16s(addr + 8)
    local vtx_tl_y = mem.read16s(addr + 10)
    local vtx_tr_x = mem.read16s(addr + 12)
    local vtx_tr_y = mem.read16s(addr + 14)
    local vtx_bl_x = mem.read16s(addr + 16)
    local vtx_bl_y = mem.read16s(addr + 18)
    local vtx_br_x = mem.read16s(addr + 20)
    local vtx_br_y = mem.read16s(addr + 22)

    local flags0 = decode_frame_flags_byte0(flags_byte0)
    local tpage = decode_texture_page(texture_page)

    return {
        index = frame_index,
        offset = nil,  -- Not meaningful for memory reads
        flags_byte0 = flags_byte0,
        flags_byte1 = flags_byte1,
        texture_page_raw = texture_page,
        palette_id = flags0.palette_id,
        semi_trans_mode = flags0.semi_trans_mode,
        is_8bpp = flags0.is_8bpp,
        semi_trans_on = flags1.semi_trans_on,
        width_signed = flags1.width_signed,
        height_signed = flags1.height_signed,
        tpage_x_base = tpage.x_base,
        tpage_y_base = tpage.y_base,
        tpage_blend = tpage.semi_trans_mode,
        tpage_color_depth = tpage.color_depth,
        uv_x = uv_x,
        uv_y = uv_y,
        uv_width = uv_width,
        uv_height = uv_height,
        vtx_tl_x = vtx_tl_x,
        vtx_tl_y = vtx_tl_y,
        vtx_tr_x = vtx_tr_x,
        vtx_tr_y = vtx_tr_y,
        vtx_bl_x = vtx_bl_x,
        vtx_bl_y = vtx_bl_y,
        vtx_br_x = vtx_br_x,
        vtx_br_y = vtx_br_y,
    }
end

-- Parse frames section from file data
-- Returns: framesets (array), group_count (number)
function M.parse_frames_section_from_data(data, frames_ptr, section_size)
    local framesets = {}

    if section_size < 8 then
        return framesets, 0
    end

    -- Header: byte 0 = group_count
    local group_count = mem.buf_read8(data, frames_ptr)
    local group_entries_end = 4 + group_count * 2  -- offset table starts after group entries

    if group_entries_end >= section_size then
        return framesets, group_count
    end

    -- First frameset offset tells us where frame data starts
    local first_offset = mem.buf_read16(data, frames_ptr + group_entries_end)
    local frame_sets_data_start = first_offset + 4
    local max_frame_sets = math.floor((frame_sets_data_start - group_entries_end) / 2)

    if max_frame_sets <= 0 or max_frame_sets > 500 then
        return framesets, group_count
    end

    -- Count actual valid entries in offset table
    local num_frame_sets = 0
    for i = 0, max_frame_sets - 1 do
        local offset_pos = group_entries_end + i * 2
        if offset_pos + 2 > section_size then break end
        local raw_offset = mem.buf_read16(data, frames_ptr + offset_pos)
        if raw_offset < first_offset then break end
        num_frame_sets = num_frame_sets + 1
    end

    if num_frame_sets <= 0 then
        return framesets, group_count
    end

    -- Parse each frameset
    for fs_idx = 0, num_frame_sets - 1 do
        local offset_pos = group_entries_end + fs_idx * 2
        if offset_pos + 2 > section_size then break end

        local raw_offset = mem.buf_read16(data, frames_ptr + offset_pos)
        local fs_section_offset = raw_offset + 4

        if fs_section_offset + FRAMESET_HEADER_SIZE > section_size then break end

        -- Frameset header
        local header_flags = mem.buf_read16(data, frames_ptr + fs_section_offset)
        local frame_count = mem.buf_read16(data, frames_ptr + fs_section_offset + 2)

        if frame_count <= 0 or frame_count > 100 then
            goto continue
        end

        local frames = {}

        -- Parse each frame (24 bytes each)
        for frame_idx = 0, frame_count - 1 do
            local frame_offset = fs_section_offset + FRAMESET_HEADER_SIZE + frame_idx * FRAME_SIZE

            if frame_offset + FRAME_SIZE > section_size then break end

            local frame = parse_frame_from_buffer(data, frames_ptr + frame_offset, frame_idx)
            frames[#frames + 1] = frame
        end

        framesets[#framesets + 1] = {
            index = fs_idx,
            file_offset = frames_ptr + fs_section_offset,
            header_flags = header_flags,
            frames = frames,
        }

        ::continue::
    end

    return framesets, group_count
end

-- Parse frames section from PSX memory
function M.parse_frames_section_from_memory(base_addr, frames_ptr, section_size)
    local addr = base_addr + frames_ptr
    local framesets = {}

    if section_size < 8 then
        return framesets, 0
    end

    local group_count = mem.read8(addr)
    local group_entries_end = 4 + group_count * 2

    if group_entries_end >= section_size then
        return framesets, group_count
    end

    local first_offset = mem.read16(addr + group_entries_end)
    local frame_sets_data_start = first_offset + 4
    local max_frame_sets = math.floor((frame_sets_data_start - group_entries_end) / 2)

    if max_frame_sets <= 0 or max_frame_sets > 500 then
        return framesets, group_count
    end

    local num_frame_sets = 0
    for i = 0, max_frame_sets - 1 do
        local offset_pos = group_entries_end + i * 2
        if offset_pos + 2 > section_size then break end
        local raw_offset = mem.read16(addr + offset_pos)
        if raw_offset < first_offset then break end
        num_frame_sets = num_frame_sets + 1
    end

    if num_frame_sets <= 0 then
        return framesets, group_count
    end

    for fs_idx = 0, num_frame_sets - 1 do
        local offset_pos = group_entries_end + fs_idx * 2
        if offset_pos + 2 > section_size then break end

        local raw_offset = mem.read16(addr + offset_pos)
        local fs_section_offset = raw_offset + 4

        if fs_section_offset + FRAMESET_HEADER_SIZE > section_size then break end

        local header_flags = mem.read16(addr + fs_section_offset)
        local frame_count = mem.read16(addr + fs_section_offset + 2)

        if frame_count <= 0 or frame_count > 100 then
            goto continue
        end

        local frames = {}

        for frame_idx = 0, frame_count - 1 do
            local frame_offset = fs_section_offset + FRAMESET_HEADER_SIZE + frame_idx * FRAME_SIZE
            if frame_offset + FRAME_SIZE > section_size then break end

            local frame = parse_frame_from_memory(addr + frame_offset, frame_idx)
            frames[#frames + 1] = frame
        end

        framesets[#framesets + 1] = {
            index = fs_idx,
            file_offset = nil,
            header_flags = header_flags,
            frames = frames,
        }

        ::continue::
    end

    return framesets, group_count
end

-- Write a single frame to memory
local function write_frame_to_memory(addr, frame)
    -- Reconstruct flags bytes from decoded values
    local flags_byte0 = encode_frame_flags_byte0(frame.palette_id, frame.semi_trans_mode, frame.is_8bpp)
    local flags_byte1 = encode_frame_flags_byte1(frame.semi_trans_on, frame.width_signed, frame.height_signed)
    local texture_page = encode_texture_page(frame.tpage_x_base, frame.tpage_y_base, frame.tpage_blend, frame.tpage_color_depth)

    mem.write8(addr, flags_byte0)
    mem.write8(addr + 1, flags_byte1)
    mem.write16(addr + 2, texture_page)

    mem.write8(addr + 4, frame.uv_x)
    mem.write8(addr + 5, frame.uv_y)

    -- Handle signed width/height
    local uv_width = frame.uv_width
    local uv_height = frame.uv_height
    if uv_width < 0 then uv_width = uv_width + 256 end
    if uv_height < 0 then uv_height = uv_height + 256 end
    mem.write8(addr + 6, uv_width)
    mem.write8(addr + 7, uv_height)

    -- Vertices (signed 16-bit) - convert negative to unsigned for write
    local function s16_to_u16(val)
        if val < 0 then return val + 65536 end
        return val
    end
    mem.write16(addr + 8, s16_to_u16(frame.vtx_tl_x))
    mem.write16(addr + 10, s16_to_u16(frame.vtx_tl_y))
    mem.write16(addr + 12, s16_to_u16(frame.vtx_tr_x))
    mem.write16(addr + 14, s16_to_u16(frame.vtx_tr_y))
    mem.write16(addr + 16, s16_to_u16(frame.vtx_bl_x))
    mem.write16(addr + 18, s16_to_u16(frame.vtx_bl_y))
    mem.write16(addr + 20, s16_to_u16(frame.vtx_br_x))
    mem.write16(addr + 22, s16_to_u16(frame.vtx_br_y))
end

-- Calculate total frames section size for given framesets and group count
function M.calculate_frames_section_size(framesets, group_count)
    if not framesets or #framesets == 0 then
        return 4  -- Minimum header
    end

    -- Header: 4 bytes (group_count + padding)
    -- Group entries: group_count * 2 bytes
    -- Frameset offset table: num_framesets * 2 bytes
    -- Frameset data: sum of (4 + frame_count * 24) for each frameset

    local header_size = 4
    local group_entries_size = group_count * 2
    local offset_table_size = #framesets * 2
    local framesets_data_size = 0

    for _, fs in ipairs(framesets) do
        framesets_data_size = framesets_data_size + FRAMESET_HEADER_SIZE + #fs.frames * FRAME_SIZE
    end

    return header_size + group_entries_size + offset_table_size + framesets_data_size
end

-- Write frames section to memory
function M.write_frames_section_to_memory(base_addr, frames_ptr, framesets, group_count)
    if not framesets or #framesets == 0 then return end

    local addr = base_addr + frames_ptr

    -- Write header: group_count and padding
    mem.write8(addr, group_count)
    mem.write8(addr + 1, 0)
    mem.write8(addr + 2, 0)
    mem.write8(addr + 3, 0)

    -- Calculate offsets
    local group_entries_end = 4 + group_count * 2
    local offset_table_size = #framesets * 2
    local frameset_data_start = group_entries_end + offset_table_size

    -- Write group entries
    -- Each group entry is RELATIVE to sprite_def_table_ptr (which is frames_ptr + 4)
    -- For group 0: offset table is at byte 6, relative to byte 4 = offset 2
    -- For group N: entry at (4 + N*2), points to that group's offset table relative to byte 4
    for g = 0, group_count - 1 do
        -- Group entry position: byte (4 + g*2)
        -- Value: offset to this group's offset table, relative to byte 4
        -- For single group, offset table starts at group_entries_end, relative to byte 4 = group_entries_end - 4
        local group_entry_value = group_entries_end - 4  -- Relative to sprite_def_table_ptr
        mem.write16(addr + 4 + g * 2, group_entry_value)
    end

    -- Write frameset offset table and data
    local current_data_offset = frameset_data_start
    for fs_idx, fs in ipairs(framesets) do
        -- Write offset table entry (relative to after the +4 in parsing logic)
        local offset_table_entry_addr = addr + group_entries_end + (fs_idx - 1) * 2
        mem.write16(offset_table_entry_addr, current_data_offset - 4)

        -- Write frameset header
        local fs_addr = addr + current_data_offset
        mem.write16(fs_addr, fs.header_flags or 0)
        mem.write16(fs_addr + 2, #fs.frames)

        -- Write frames
        for frame_idx, frame in ipairs(fs.frames) do
            local frame_addr = fs_addr + FRAMESET_HEADER_SIZE + (frame_idx - 1) * FRAME_SIZE
            write_frame_to_memory(frame_addr, frame)
        end

        current_data_offset = current_data_offset + FRAMESET_HEADER_SIZE + #fs.frames * FRAME_SIZE
    end
end

-- Serialize frames section to byte string (for .bin saving)
function M.serialize_frames_section(framesets, group_count)
    if not framesets or #framesets == 0 then
        return string.char(0, 0, 0, 0), 4
    end

    local bytes = {}

    -- Header: group_count + padding
    bytes[#bytes + 1] = string.char(group_count, 0, 0, 0)

    -- Calculate structure
    local group_entries_end = 4 + group_count * 2
    local offset_table_size = #framesets * 2
    local frameset_data_start = group_entries_end + offset_table_size

    -- Group entries (relative to sprite_def_table_ptr which is at byte 4)
    -- For single group: offset table starts at group_entries_end, relative to byte 4 = group_entries_end - 4
    for g = 1, group_count do
        local group_entry_value = group_entries_end - 4  -- Relative to sprite_def_table_ptr
        bytes[#bytes + 1] = string.char(group_entry_value % 256, math.floor(group_entry_value / 256))
    end

    -- Frameset offset table
    local current_data_offset = frameset_data_start
    for _, fs in ipairs(framesets) do
        local entry = current_data_offset - 4
        bytes[#bytes + 1] = string.char(entry % 256, math.floor(entry / 256))
        current_data_offset = current_data_offset + FRAMESET_HEADER_SIZE + #fs.frames * FRAME_SIZE
    end

    -- Frameset data
    for _, fs in ipairs(framesets) do
        -- Frameset header
        local hf = fs.header_flags or 0
        local fc = #fs.frames
        bytes[#bytes + 1] = string.char(hf % 256, math.floor(hf / 256), fc % 256, math.floor(fc / 256))

        -- Frames
        for _, frame in ipairs(fs.frames) do
            local flags_byte0 = encode_frame_flags_byte0(frame.palette_id, frame.semi_trans_mode, frame.is_8bpp)
            local flags_byte1 = encode_frame_flags_byte1(frame.semi_trans_on, frame.width_signed, frame.height_signed)
            local texture_page = encode_texture_page(frame.tpage_x_base, frame.tpage_y_base, frame.tpage_blend, frame.tpage_color_depth)

            local uv_width = frame.uv_width
            local uv_height = frame.uv_height
            if uv_width < 0 then uv_width = uv_width + 256 end
            if uv_height < 0 then uv_height = uv_height + 256 end

            -- Pack all 24 bytes
            bytes[#bytes + 1] = string.char(flags_byte0, flags_byte1)
            bytes[#bytes + 1] = string.char(texture_page % 256, math.floor(texture_page / 256))
            bytes[#bytes + 1] = string.char(frame.uv_x, frame.uv_y, uv_width, uv_height)

            -- Vertices (signed 16-bit, need to handle negative values)
            local function s16_to_bytes(val)
                if val < 0 then val = val + 65536 end
                return string.char(val % 256, math.floor(val / 256))
            end
            bytes[#bytes + 1] = s16_to_bytes(frame.vtx_tl_x) .. s16_to_bytes(frame.vtx_tl_y)
            bytes[#bytes + 1] = s16_to_bytes(frame.vtx_tr_x) .. s16_to_bytes(frame.vtx_tr_y)
            bytes[#bytes + 1] = s16_to_bytes(frame.vtx_bl_x) .. s16_to_bytes(frame.vtx_bl_y)
            bytes[#bytes + 1] = s16_to_bytes(frame.vtx_br_x) .. s16_to_bytes(frame.vtx_br_y)
        end
    end

    local result = table.concat(bytes)
    return result, #result
end

-- Deep copy a single frame
function M.copy_frame(frame)
    if not frame then return nil end
    return {
        index = frame.index,
        offset = frame.offset,
        flags_byte0 = frame.flags_byte0,
        flags_byte1 = frame.flags_byte1,
        texture_page_raw = frame.texture_page_raw,
        palette_id = frame.palette_id,
        semi_trans_mode = frame.semi_trans_mode,
        is_8bpp = frame.is_8bpp,
        semi_trans_on = frame.semi_trans_on,
        width_signed = frame.width_signed,
        height_signed = frame.height_signed,
        tpage_x_base = frame.tpage_x_base,
        tpage_y_base = frame.tpage_y_base,
        tpage_blend = frame.tpage_blend,
        tpage_color_depth = frame.tpage_color_depth,
        uv_x = frame.uv_x,
        uv_y = frame.uv_y,
        uv_width = frame.uv_width,
        uv_height = frame.uv_height,
        vtx_tl_x = frame.vtx_tl_x,
        vtx_tl_y = frame.vtx_tl_y,
        vtx_tr_x = frame.vtx_tr_x,
        vtx_tr_y = frame.vtx_tr_y,
        vtx_bl_x = frame.vtx_bl_x,
        vtx_bl_y = frame.vtx_bl_y,
        vtx_br_x = frame.vtx_br_x,
        vtx_br_y = frame.vtx_br_y,
    }
end

-- Deep copy a frameset
function M.copy_frameset(frameset)
    if not frameset then return nil end
    local copy = {
        index = frameset.index,
        file_offset = frameset.file_offset,
        header_flags = frameset.header_flags,
        frames = {},
    }
    for _, frame in ipairs(frameset.frames) do
        copy.frames[#copy.frames + 1] = M.copy_frame(frame)
    end
    return copy
end

-- Deep copy all framesets
function M.copy_framesets(framesets)
    if not framesets then return nil end
    local copy = {}
    for _, fs in ipairs(framesets) do
        copy[#copy + 1] = M.copy_frameset(fs)
    end
    return copy
end

--------------------------------------------------------------------------------
-- Animation Sequence Parsing/Writing
-- Sequences control sprite animation (which frameset to display, for how long)
-- Animation section at header[0x04]: 4-byte count, offset table, bytecode
--------------------------------------------------------------------------------

-- Sequence opcode definitions
-- Validated from wiki_articles/effect_animation_section.txt and disassembly
M.SEQUENCE_OPCODES = {
    -- FRAME entries: 0x00-0x7F = frameset_index (3 bytes total)
    -- Control opcodes: 0x80+ have variable sizes
    [0x81] = {name = "LOOP", size = 1, params = {}},
    [0x82] = {name = "SET_OFFSET", size = 5, params = {"offset_x", "offset_y"}},
    [0x83] = {name = "ADD_OFFSET", size = 3, params = {"delta_x", "delta_y"}},
}

-- Depth mode names for UI display
M.DEPTH_MODE_NAMES = {
    [0] = "Standard (Z>>2)",
    [1] = "Forward 8 (Z>>2 - 8)",
    [2] = "Fixed Front (8)",
    [3] = "Fixed Back (0x17E)",
    [4] = "Fixed 16 (0x10)",
    [5] = "Forward 16 (Z>>2 - 16)",
}

-- Parse single sequence instruction from bytes
-- Returns instruction table and byte size consumed
function M.parse_sequence_instruction(data, pos)
    local byte0 = data:byte(pos)

    if byte0 < 0x80 then
        -- FRAME entry (3 bytes): frameset_idx, duration, depth_mode
        return {
            opcode = byte0,
            name = "FRAME",
            params = {
                byte0,                    -- frameset_index
                data:byte(pos + 1) or 0,  -- duration
                data:byte(pos + 2) or 0   -- depth_mode
            }
        }, 3
    elseif byte0 == 0x81 then
        -- LOOP (1 byte): restart sequence
        return { opcode = 0x81, name = "LOOP", params = {} }, 1
    elseif byte0 == 0x82 then
        -- SET_OFFSET (5 bytes): opcode, offset_x(s16), offset_y(s16)
        local ox = (data:byte(pos + 1) or 0) + (data:byte(pos + 2) or 0) * 256
        local oy = (data:byte(pos + 3) or 0) + (data:byte(pos + 4) or 0) * 256
        -- Convert to signed
        if ox >= 32768 then ox = ox - 65536 end
        if oy >= 32768 then oy = oy - 65536 end
        return { opcode = 0x82, name = "SET_OFFSET", params = {ox, oy} }, 5
    elseif byte0 == 0x83 then
        -- ADD_OFFSET (3 bytes): opcode, delta_x(s8), delta_y(s8)
        local dx = data:byte(pos + 1) or 0
        local dy = data:byte(pos + 2) or 0
        -- Convert to signed
        if dx >= 128 then dx = dx - 256 end
        if dy >= 128 then dy = dy - 256 end
        return { opcode = 0x83, name = "ADD_OFFSET", params = {dx, dy} }, 3
    else
        -- Unknown opcode, skip 1 byte
        return { opcode = byte0, name = string.format("UNKNOWN_%02X", byte0), params = {} }, 1
    end
end

-- Parse full sequence from byte string
-- start_pos and end_pos are 1-indexed Lua positions
-- NOTE: Sequences typically end with a duration=0 FRAME followed by a LOOP.
-- The duration=0 FRAME stops execution at runtime, so the LOOP is never reached,
-- but we MUST parse both instructions to preserve the original byte layout.
function M.parse_sequence(data, start_pos, end_pos)
    local instructions = {}
    local pos = start_pos

    while pos <= end_pos do
        local instr, size = M.parse_sequence_instruction(data, pos)
        table.insert(instructions, instr)
        pos = pos + size

        -- Stop ONLY at LOOP (which is the actual terminator in file data)
        -- Do NOT stop at duration=0 FRAME because a LOOP often follows it
        if instr.opcode == 0x81 then break end
    end

    return instructions
end

-- Parse entire animation section from file data
-- anim_ptr is 0-indexed file offset
-- section_size is bytes from animation_ptr to script_ptr
function M.parse_animation_section_from_data(data, anim_ptr, section_size)
    local base = anim_ptr + 1  -- Lua 1-indexed

    -- Read animation count (4-byte LE)
    local count = (data:byte(base) or 0) +
                  (data:byte(base + 1) or 0) * 256 +
                  (data:byte(base + 2) or 0) * 65536 +
                  (data:byte(base + 3) or 0) * 16777216

    if count == 0 or count > 1000 then
        return {}, 0
    end

    local sequences = {}
    for i = 0, count - 1 do
        -- Offset table at base + 4 + i*2 (u16 offsets, relative to byte 4)
        local offset_pos = base + 4 + i * 2
        local offset = (data:byte(offset_pos) or 0) + (data:byte(offset_pos + 1) or 0) * 256
        local seq_start = base + 4 + offset

        -- Find end (next offset or section end)
        local seq_end
        if i < count - 1 then
            local next_offset = (data:byte(offset_pos + 2) or 0) + (data:byte(offset_pos + 3) or 0) * 256
            seq_end = base + 4 + next_offset - 1
        else
            seq_end = base + section_size - 1
        end

        local instructions = M.parse_sequence(data, seq_start, seq_end)
        table.insert(sequences, {
            index = i,
            instructions = instructions
        })
    end

    return sequences, count
end

-- Parse animation section from PSX memory
function M.parse_animation_section_from_memory(base_addr, anim_ptr, section_size)
    local addr = base_addr + anim_ptr

    -- Read animation count (4-byte LE)
    local count = mem.read32(addr)

    if count == 0 or count > 1000 then
        return {}, 0
    end

    local sequences = {}
    for i = 0, count - 1 do
        -- Offset table at addr + 4 + i*2
        local offset = mem.read16(addr + 4 + i * 2)
        local seq_addr = addr + 4 + offset

        -- Find end (next offset or section end)
        local seq_size
        if i < count - 1 then
            local next_offset = mem.read16(addr + 4 + (i + 1) * 2)
            seq_size = next_offset - offset
        else
            -- Last sequence: goes to section end
            seq_size = section_size - 4 - offset
        end

        -- Read sequence bytes into string
        local seq_bytes = {}
        for j = 0, seq_size - 1 do
            seq_bytes[j + 1] = string.char(mem.read8(seq_addr + j))
        end
        local seq_data = table.concat(seq_bytes)

        local instructions = M.parse_sequence(seq_data, 1, seq_size)
        table.insert(sequences, {
            index = i,
            instructions = instructions
        })
    end

    return sequences, count
end

-- Calculate size of a single sequence in bytes
function M.calculate_sequence_size(instructions)
    local size = 0
    for _, instr in ipairs(instructions) do
        if instr.opcode < 0x80 then
            size = size + 3  -- FRAME entry
        elseif instr.opcode == 0x81 then
            size = size + 1  -- LOOP
        elseif instr.opcode == 0x82 then
            size = size + 5  -- SET_OFFSET
        elseif instr.opcode == 0x83 then
            size = size + 3  -- ADD_OFFSET
        else
            size = size + 1  -- Unknown, assume 1 byte
        end
    end
    return size
end

-- Calculate total animation section size in bytes
function M.calculate_animation_section_size(sequences)
    if not sequences or #sequences == 0 then
        return 4  -- Just the header (count = 0)
    end

    local size = 4  -- Header: animation_count (u32)
    size = size + (#sequences * 2)  -- Offset table

    for _, seq in ipairs(sequences) do
        size = size + M.calculate_sequence_size(seq.instructions)
    end

    return size
end

-- Serialize single sequence instruction to bytes
function M.serialize_sequence_instruction(instr)
    local bytes = {}

    if instr.opcode < 0x80 then
        -- FRAME: frameset_index, duration, depth_mode
        bytes[1] = instr.params[1] or 0  -- frameset_index
        bytes[2] = instr.params[2] or 0  -- duration
        bytes[3] = instr.params[3] or 0  -- depth_mode
    elseif instr.opcode == 0x81 then
        -- LOOP
        bytes[1] = 0x81
    elseif instr.opcode == 0x82 then
        -- SET_OFFSET: opcode, offset_x(s16), offset_y(s16)
        bytes[1] = 0x82
        local ox = instr.params[1] or 0
        local oy = instr.params[2] or 0
        if ox < 0 then ox = ox + 65536 end
        if oy < 0 then oy = oy + 65536 end
        bytes[2] = ox % 256
        bytes[3] = math.floor(ox / 256)
        bytes[4] = oy % 256
        bytes[5] = math.floor(oy / 256)
    elseif instr.opcode == 0x83 then
        -- ADD_OFFSET: opcode, delta_x(s8), delta_y(s8)
        bytes[1] = 0x83
        local dx = instr.params[1] or 0
        local dy = instr.params[2] or 0
        if dx < 0 then dx = dx + 256 end
        if dy < 0 then dy = dy + 256 end
        bytes[2] = dx
        bytes[3] = dy
    else
        -- Unknown, just write opcode
        bytes[1] = instr.opcode
    end

    return bytes
end

-- Serialize entire animation section to byte string
function M.serialize_animation_section(sequences)
    if not sequences or #sequences == 0 then
        return string.char(0, 0, 0, 0)  -- Count = 0
    end

    local count = #sequences
    local result = {}

    -- Header (4 bytes): animation_count as u32 LE
    result[#result + 1] = string.char(count % 256, math.floor(count / 256) % 256, 0, 0)

    -- Calculate offsets and serialize sequences
    local offset_table_size = count * 2
    local current_offset = offset_table_size
    local seq_data = {}
    local offsets = {}

    for _, seq in ipairs(sequences) do
        offsets[#offsets + 1] = current_offset
        local seq_bytes = {}
        for _, instr in ipairs(seq.instructions) do
            local bytes = M.serialize_sequence_instruction(instr)
            for _, b in ipairs(bytes) do
                seq_bytes[#seq_bytes + 1] = b
            end
        end
        if #seq_bytes > 0 then
            seq_data[#seq_data + 1] = string.char(table.unpack(seq_bytes))
        else
            seq_data[#seq_data + 1] = ""
        end
        current_offset = current_offset + #seq_bytes
    end

    -- Offset table
    for _, off in ipairs(offsets) do
        result[#result + 1] = string.char(off % 256, math.floor(off / 256))
    end

    -- Sequence data
    for _, sd in ipairs(seq_data) do
        result[#result + 1] = sd
    end

    return table.concat(result)
end

-- Write animation section to PSX memory
function M.write_animation_section_to_memory(base_addr, anim_ptr, sequences)
    if not sequences then return end

    local serialized = M.serialize_animation_section(sequences)
    local addr = base_addr + anim_ptr

    for i = 1, #serialized do
        mem.write8(addr + i - 1, serialized:byte(i))
    end
end

-- Create a new sequence instruction with default parameters
function M.create_sequence_instruction(opcode_type)
    if opcode_type == "FRAME" then
        return { opcode = 0, name = "FRAME", params = {0, 4, 1} }
    elseif opcode_type == "LOOP" then
        return { opcode = 0x81, name = "LOOP", params = {} }
    elseif opcode_type == "SET_OFFSET" then
        return { opcode = 0x82, name = "SET_OFFSET", params = {0, 0} }
    elseif opcode_type == "ADD_OFFSET" then
        return { opcode = 0x83, name = "ADD_OFFSET", params = {0, 0} }
    else
        return { opcode = 0, name = "FRAME", params = {0, 4, 1} }
    end
end

-- Deep copy a single sequence
function M.copy_sequence(seq)
    if not seq then return nil end

    local copy = { index = seq.index, instructions = {} }
    for _, instr in ipairs(seq.instructions) do
        local instr_copy = {
            opcode = instr.opcode,
            name = instr.name,
            params = {}
        }
        for i, p in ipairs(instr.params) do
            instr_copy.params[i] = p
        end
        table.insert(copy.instructions, instr_copy)
    end
    return copy
end

-- Deep copy all sequences
function M.copy_sequences(sequences)
    if not sequences then return nil end

    local copy = {}
    for _, seq in ipairs(sequences) do
        copy[#copy + 1] = M.copy_sequence(seq)
    end
    return copy
end

-- Create a new empty sequence
function M.create_sequence(index)
    return {
        index = index or 0,
        instructions = {
            { opcode = 0, name = "FRAME", params = {0, 4, 1} },
            { opcode = 0x81, name = "LOOP", params = {} }
        }
    }
end

return M
