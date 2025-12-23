-- parser.lua
-- Parse E###.BIN effect file headers, sections, and emitters

local mem = require("memory_utils")

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
    return {
        constant = mem.buf_read16(data, offset + 0x00),
        emitter_count = mem.buf_read16(data, offset + 0x02),
        gravity_x = mem.buf_read32(data, offset + 0x04),
        gravity_y = mem.buf_read32(data, offset + 0x08),
        gravity_z = mem.buf_read32(data, offset + 0x0C),
        inertia_threshold = mem.buf_read32(data, offset + 0x10)
    }
end

--------------------------------------------------------------------------------
-- Emitter Parsing (from file data)
--------------------------------------------------------------------------------

-- Parse single emitter (196 bytes) from file data
function M.parse_emitter_from_data(data, offset)
    local e = {}

    -- Core Control Bytes (0x00-0x0F)
    e.byte_00 = mem.buf_read8(data, offset + 0x00)
    e.anim_index = mem.buf_read8(data, offset + 0x01)
    e.motion_type_flag = mem.buf_read8(data, offset + 0x02)
    e.animation_target_flag = mem.buf_read8(data, offset + 0x03)
    e.anim_param = mem.buf_read8(data, offset + 0x04)
    e.byte_05 = mem.buf_read8(data, offset + 0x05)
    e.emitter_flags_lo = mem.buf_read8(data, offset + 0x06)
    e.emitter_flags_hi = mem.buf_read8(data, offset + 0x07)

    -- Curve indices (0x08-0x0F)
    e.curve_indices_08 = mem.buf_read8(data, offset + 0x08)
    e.curve_indices_09 = mem.buf_read8(data, offset + 0x09)
    e.curve_indices_0A = mem.buf_read8(data, offset + 0x0A)
    e.curve_indices_0B = mem.buf_read8(data, offset + 0x0B)
    e.curve_indices_0C = mem.buf_read8(data, offset + 0x0C)
    e.curve_indices_0D = mem.buf_read8(data, offset + 0x0D)
    e.curve_indices_0E = mem.buf_read8(data, offset + 0x0E)
    e.curve_indices_0F = mem.buf_read8(data, offset + 0x0F)

    -- Color Curves (0x10-0x13)
    e.color_curves_rg = mem.buf_read8(data, offset + 0x10)
    e.color_curves_b = mem.buf_read8(data, offset + 0x11)

    -- Position (0x14-0x1F) - 16-bit signed
    e.start_position_x = mem.buf_read16s(data, offset + 0x14)
    e.start_position_y = mem.buf_read16s(data, offset + 0x16)
    e.start_position_z = mem.buf_read16s(data, offset + 0x18)
    e.end_position_x = mem.buf_read16s(data, offset + 0x1A)
    e.end_position_y = mem.buf_read16s(data, offset + 0x1C)
    e.end_position_z = mem.buf_read16s(data, offset + 0x1E)

    -- Particle Spread (0x20-0x2B)
    e.spread_x_start = mem.buf_read16s(data, offset + 0x20)
    e.spread_y_start = mem.buf_read16s(data, offset + 0x22)
    e.spread_z_start = mem.buf_read16s(data, offset + 0x24)
    e.spread_x_end = mem.buf_read16s(data, offset + 0x26)
    e.spread_y_end = mem.buf_read16s(data, offset + 0x28)
    e.spread_z_end = mem.buf_read16s(data, offset + 0x2A)

    -- Velocity Base Angles (0x2C-0x37)
    e.velocity_base_angle_x_start = mem.buf_read16s(data, offset + 0x2C)
    e.velocity_base_angle_y_start = mem.buf_read16s(data, offset + 0x2E)
    e.velocity_base_angle_z_start = mem.buf_read16s(data, offset + 0x30)
    e.velocity_base_angle_x_end = mem.buf_read16s(data, offset + 0x32)
    e.velocity_base_angle_y_end = mem.buf_read16s(data, offset + 0x34)
    e.velocity_base_angle_z_end = mem.buf_read16s(data, offset + 0x36)

    -- Velocity Direction Spread (0x38-0x43)
    e.velocity_direction_spread_x_start = mem.buf_read16s(data, offset + 0x38)
    e.velocity_direction_spread_y_start = mem.buf_read16s(data, offset + 0x3A)
    e.velocity_direction_spread_z_start = mem.buf_read16s(data, offset + 0x3C)
    e.velocity_direction_spread_x_end = mem.buf_read16s(data, offset + 0x3E)
    e.velocity_direction_spread_y_end = mem.buf_read16s(data, offset + 0x40)
    e.velocity_direction_spread_z_end = mem.buf_read16s(data, offset + 0x42)

    -- Physics: Inertia (0x44-0x4B)
    e.inertia_min_start = mem.buf_read16s(data, offset + 0x44)
    e.inertia_max_start = mem.buf_read16s(data, offset + 0x46)
    e.inertia_min_end = mem.buf_read16s(data, offset + 0x48)
    e.inertia_max_end = mem.buf_read16s(data, offset + 0x4A)

    -- Physics: Weight (0x54-0x5B) - skip dead code 0x4C-0x53
    e.weight_min_start = mem.buf_read16s(data, offset + 0x54)
    e.weight_max_start = mem.buf_read16s(data, offset + 0x56)
    e.weight_min_end = mem.buf_read16s(data, offset + 0x58)
    e.weight_max_end = mem.buf_read16s(data, offset + 0x5A)

    -- Radial Velocity (0x5C-0x63)
    e.radial_velocity_min_start = mem.buf_read16s(data, offset + 0x5C)
    e.radial_velocity_max_start = mem.buf_read16s(data, offset + 0x5E)
    e.radial_velocity_min_end = mem.buf_read16s(data, offset + 0x60)
    e.radial_velocity_max_end = mem.buf_read16s(data, offset + 0x62)

    -- Acceleration (0x64-0x7B)
    e.acceleration_x_min_start = mem.buf_read16s(data, offset + 0x64)
    e.acceleration_x_max_start = mem.buf_read16s(data, offset + 0x66)
    e.acceleration_y_min_start = mem.buf_read16s(data, offset + 0x68)
    e.acceleration_y_max_start = mem.buf_read16s(data, offset + 0x6A)
    e.acceleration_z_min_start = mem.buf_read16s(data, offset + 0x6C)
    e.acceleration_z_max_start = mem.buf_read16s(data, offset + 0x6E)
    e.acceleration_x_min_end = mem.buf_read16s(data, offset + 0x70)
    e.acceleration_x_max_end = mem.buf_read16s(data, offset + 0x72)
    e.acceleration_y_min_end = mem.buf_read16s(data, offset + 0x74)
    e.acceleration_y_max_end = mem.buf_read16s(data, offset + 0x76)
    e.acceleration_z_min_end = mem.buf_read16s(data, offset + 0x78)
    e.acceleration_z_max_end = mem.buf_read16s(data, offset + 0x7A)

    -- Drag (0x7C-0x93)
    e.drag_x_min_start = mem.buf_read16s(data, offset + 0x7C)
    e.drag_x_max_start = mem.buf_read16s(data, offset + 0x7E)
    e.drag_y_min_start = mem.buf_read16s(data, offset + 0x80)
    e.drag_y_max_start = mem.buf_read16s(data, offset + 0x82)
    e.drag_z_min_start = mem.buf_read16s(data, offset + 0x84)
    e.drag_z_max_start = mem.buf_read16s(data, offset + 0x86)
    e.drag_x_min_end = mem.buf_read16s(data, offset + 0x88)
    e.drag_x_max_end = mem.buf_read16s(data, offset + 0x8A)
    e.drag_y_min_end = mem.buf_read16s(data, offset + 0x8C)
    e.drag_y_max_end = mem.buf_read16s(data, offset + 0x8E)
    e.drag_z_min_end = mem.buf_read16s(data, offset + 0x90)
    e.drag_z_max_end = mem.buf_read16s(data, offset + 0x92)

    -- Lifetime (0x94-0x9B)
    e.lifetime_min_start = mem.buf_read16s(data, offset + 0x94)
    e.lifetime_max_start = mem.buf_read16s(data, offset + 0x96)
    e.lifetime_min_end = mem.buf_read16s(data, offset + 0x98)
    e.lifetime_max_end = mem.buf_read16s(data, offset + 0x9A)

    -- Target Offset (0x9C-0xA7)
    e.target_offset_x_start = mem.buf_read16s(data, offset + 0x9C)
    e.target_offset_y_start = mem.buf_read16s(data, offset + 0x9E)
    e.target_offset_z_start = mem.buf_read16s(data, offset + 0xA0)
    e.target_offset_x_end = mem.buf_read16s(data, offset + 0xA2)
    e.target_offset_y_end = mem.buf_read16s(data, offset + 0xA4)
    e.target_offset_z_end = mem.buf_read16s(data, offset + 0xA6)

    -- Spawn Control (0xB0-0xB7)
    e.particle_count_start = mem.buf_read16s(data, offset + 0xB0)
    e.particle_count_end = mem.buf_read16s(data, offset + 0xB2)
    e.spawn_interval_start = mem.buf_read16s(data, offset + 0xB4)
    e.spawn_interval_end = mem.buf_read16s(data, offset + 0xB6)

    -- Homing (0xB8-0xBF)
    e.homing_strength_min_start = mem.buf_read16s(data, offset + 0xB8)
    e.homing_strength_max_start = mem.buf_read16s(data, offset + 0xBA)
    e.homing_strength_min_end = mem.buf_read16s(data, offset + 0xBC)
    e.homing_strength_max_end = mem.buf_read16s(data, offset + 0xBE)

    -- Child Emitters (0xC0-0xC1)
    e.child_emitter_on_death = mem.buf_read8(data, offset + 0xC0)
    e.child_emitter_mid_life = mem.buf_read8(data, offset + 0xC1)

    return e
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
    local e = {}

    -- Core Control Bytes (0x00-0x0F)
    e.byte_00 = mem.read8(base_addr + 0x00)
    e.anim_index = mem.read8(base_addr + 0x01)
    e.motion_type_flag = mem.read8(base_addr + 0x02)
    e.animation_target_flag = mem.read8(base_addr + 0x03)
    e.anim_param = mem.read8(base_addr + 0x04)
    e.byte_05 = mem.read8(base_addr + 0x05)
    e.emitter_flags_lo = mem.read8(base_addr + 0x06)
    e.emitter_flags_hi = mem.read8(base_addr + 0x07)

    -- Curve indices
    e.curve_indices_08 = mem.read8(base_addr + 0x08)
    e.curve_indices_09 = mem.read8(base_addr + 0x09)
    e.curve_indices_0A = mem.read8(base_addr + 0x0A)
    e.curve_indices_0B = mem.read8(base_addr + 0x0B)
    e.curve_indices_0C = mem.read8(base_addr + 0x0C)
    e.curve_indices_0D = mem.read8(base_addr + 0x0D)
    e.curve_indices_0E = mem.read8(base_addr + 0x0E)
    e.curve_indices_0F = mem.read8(base_addr + 0x0F)

    -- Color Curves
    e.color_curves_rg = mem.read8(base_addr + 0x10)
    e.color_curves_b = mem.read8(base_addr + 0x11)

    -- Position (signed 16-bit)
    e.start_position_x = mem.read16s(base_addr + 0x14)
    e.start_position_y = mem.read16s(base_addr + 0x16)
    e.start_position_z = mem.read16s(base_addr + 0x18)
    e.end_position_x = mem.read16s(base_addr + 0x1A)
    e.end_position_y = mem.read16s(base_addr + 0x1C)
    e.end_position_z = mem.read16s(base_addr + 0x1E)

    -- Spread
    e.spread_x_start = mem.read16s(base_addr + 0x20)
    e.spread_y_start = mem.read16s(base_addr + 0x22)
    e.spread_z_start = mem.read16s(base_addr + 0x24)
    e.spread_x_end = mem.read16s(base_addr + 0x26)
    e.spread_y_end = mem.read16s(base_addr + 0x28)
    e.spread_z_end = mem.read16s(base_addr + 0x2A)

    -- Velocity Base Angles
    e.velocity_base_angle_x_start = mem.read16s(base_addr + 0x2C)
    e.velocity_base_angle_y_start = mem.read16s(base_addr + 0x2E)
    e.velocity_base_angle_z_start = mem.read16s(base_addr + 0x30)
    e.velocity_base_angle_x_end = mem.read16s(base_addr + 0x32)
    e.velocity_base_angle_y_end = mem.read16s(base_addr + 0x34)
    e.velocity_base_angle_z_end = mem.read16s(base_addr + 0x36)

    -- Velocity Direction Spread
    e.velocity_direction_spread_x_start = mem.read16s(base_addr + 0x38)
    e.velocity_direction_spread_y_start = mem.read16s(base_addr + 0x3A)
    e.velocity_direction_spread_z_start = mem.read16s(base_addr + 0x3C)
    e.velocity_direction_spread_x_end = mem.read16s(base_addr + 0x3E)
    e.velocity_direction_spread_y_end = mem.read16s(base_addr + 0x40)
    e.velocity_direction_spread_z_end = mem.read16s(base_addr + 0x42)

    -- Inertia
    e.inertia_min_start = mem.read16s(base_addr + 0x44)
    e.inertia_max_start = mem.read16s(base_addr + 0x46)
    e.inertia_min_end = mem.read16s(base_addr + 0x48)
    e.inertia_max_end = mem.read16s(base_addr + 0x4A)

    -- Weight
    e.weight_min_start = mem.read16s(base_addr + 0x54)
    e.weight_max_start = mem.read16s(base_addr + 0x56)
    e.weight_min_end = mem.read16s(base_addr + 0x58)
    e.weight_max_end = mem.read16s(base_addr + 0x5A)

    -- Radial Velocity
    e.radial_velocity_min_start = mem.read16s(base_addr + 0x5C)
    e.radial_velocity_max_start = mem.read16s(base_addr + 0x5E)
    e.radial_velocity_min_end = mem.read16s(base_addr + 0x60)
    e.radial_velocity_max_end = mem.read16s(base_addr + 0x62)

    -- Acceleration
    e.acceleration_x_min_start = mem.read16s(base_addr + 0x64)
    e.acceleration_x_max_start = mem.read16s(base_addr + 0x66)
    e.acceleration_y_min_start = mem.read16s(base_addr + 0x68)
    e.acceleration_y_max_start = mem.read16s(base_addr + 0x6A)
    e.acceleration_z_min_start = mem.read16s(base_addr + 0x6C)
    e.acceleration_z_max_start = mem.read16s(base_addr + 0x6E)
    e.acceleration_x_min_end = mem.read16s(base_addr + 0x70)
    e.acceleration_x_max_end = mem.read16s(base_addr + 0x72)
    e.acceleration_y_min_end = mem.read16s(base_addr + 0x74)
    e.acceleration_y_max_end = mem.read16s(base_addr + 0x76)
    e.acceleration_z_min_end = mem.read16s(base_addr + 0x78)
    e.acceleration_z_max_end = mem.read16s(base_addr + 0x7A)

    -- Drag
    e.drag_x_min_start = mem.read16s(base_addr + 0x7C)
    e.drag_x_max_start = mem.read16s(base_addr + 0x7E)
    e.drag_y_min_start = mem.read16s(base_addr + 0x80)
    e.drag_y_max_start = mem.read16s(base_addr + 0x82)
    e.drag_z_min_start = mem.read16s(base_addr + 0x84)
    e.drag_z_max_start = mem.read16s(base_addr + 0x86)
    e.drag_x_min_end = mem.read16s(base_addr + 0x88)
    e.drag_x_max_end = mem.read16s(base_addr + 0x8A)
    e.drag_y_min_end = mem.read16s(base_addr + 0x8C)
    e.drag_y_max_end = mem.read16s(base_addr + 0x8E)
    e.drag_z_min_end = mem.read16s(base_addr + 0x90)
    e.drag_z_max_end = mem.read16s(base_addr + 0x92)

    -- Lifetime
    e.lifetime_min_start = mem.read16s(base_addr + 0x94)
    e.lifetime_max_start = mem.read16s(base_addr + 0x96)
    e.lifetime_min_end = mem.read16s(base_addr + 0x98)
    e.lifetime_max_end = mem.read16s(base_addr + 0x9A)

    -- Target Offset
    e.target_offset_x_start = mem.read16s(base_addr + 0x9C)
    e.target_offset_y_start = mem.read16s(base_addr + 0x9E)
    e.target_offset_z_start = mem.read16s(base_addr + 0xA0)
    e.target_offset_x_end = mem.read16s(base_addr + 0xA2)
    e.target_offset_y_end = mem.read16s(base_addr + 0xA4)
    e.target_offset_z_end = mem.read16s(base_addr + 0xA6)

    -- Spawn Control
    e.particle_count_start = mem.read16s(base_addr + 0xB0)
    e.particle_count_end = mem.read16s(base_addr + 0xB2)
    e.spawn_interval_start = mem.read16s(base_addr + 0xB4)
    e.spawn_interval_end = mem.read16s(base_addr + 0xB6)

    -- Homing
    e.homing_strength_min_start = mem.read16s(base_addr + 0xB8)
    e.homing_strength_max_start = mem.read16s(base_addr + 0xBA)
    e.homing_strength_min_end = mem.read16s(base_addr + 0xBC)
    e.homing_strength_max_end = mem.read16s(base_addr + 0xBE)

    -- Child Emitters
    e.child_emitter_on_death = mem.read8(base_addr + 0xC0)
    e.child_emitter_mid_life = mem.read8(base_addr + 0xC1)

    return e
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

    -- Core Control Bytes (0x00-0x0F)
    mem.write8(addr + 0x00, e.byte_00)
    mem.write8(addr + 0x01, e.anim_index)
    mem.write8(addr + 0x02, e.motion_type_flag)
    mem.write8(addr + 0x03, e.animation_target_flag)
    mem.write8(addr + 0x04, e.anim_param)
    mem.write8(addr + 0x05, e.byte_05)
    mem.write8(addr + 0x06, e.emitter_flags_lo)
    mem.write8(addr + 0x07, e.emitter_flags_hi)

    -- Curve indices
    mem.write8(addr + 0x08, e.curve_indices_08)
    mem.write8(addr + 0x09, e.curve_indices_09)
    mem.write8(addr + 0x0A, e.curve_indices_0A)
    mem.write8(addr + 0x0B, e.curve_indices_0B)
    mem.write8(addr + 0x0C, e.curve_indices_0C)
    mem.write8(addr + 0x0D, e.curve_indices_0D)
    mem.write8(addr + 0x0E, e.curve_indices_0E)
    mem.write8(addr + 0x0F, e.curve_indices_0F)

    -- Color Curves
    mem.write8(addr + 0x10, e.color_curves_rg)
    mem.write8(addr + 0x11, e.color_curves_b)

    -- Position (0x14-0x1F)
    mem.write16(addr + 0x14, e.start_position_x)
    mem.write16(addr + 0x16, e.start_position_y)
    mem.write16(addr + 0x18, e.start_position_z)
    mem.write16(addr + 0x1A, e.end_position_x)
    mem.write16(addr + 0x1C, e.end_position_y)
    mem.write16(addr + 0x1E, e.end_position_z)

    -- Spread (0x20-0x2B)
    mem.write16(addr + 0x20, e.spread_x_start)
    mem.write16(addr + 0x22, e.spread_y_start)
    mem.write16(addr + 0x24, e.spread_z_start)
    mem.write16(addr + 0x26, e.spread_x_end)
    mem.write16(addr + 0x28, e.spread_y_end)
    mem.write16(addr + 0x2A, e.spread_z_end)

    -- Velocity Base Angles (0x2C-0x37)
    mem.write16(addr + 0x2C, e.velocity_base_angle_x_start)
    mem.write16(addr + 0x2E, e.velocity_base_angle_y_start)
    mem.write16(addr + 0x30, e.velocity_base_angle_z_start)
    mem.write16(addr + 0x32, e.velocity_base_angle_x_end)
    mem.write16(addr + 0x34, e.velocity_base_angle_y_end)
    mem.write16(addr + 0x36, e.velocity_base_angle_z_end)

    -- Velocity Direction Spread (0x38-0x43)
    mem.write16(addr + 0x38, e.velocity_direction_spread_x_start)
    mem.write16(addr + 0x3A, e.velocity_direction_spread_y_start)
    mem.write16(addr + 0x3C, e.velocity_direction_spread_z_start)
    mem.write16(addr + 0x3E, e.velocity_direction_spread_x_end)
    mem.write16(addr + 0x40, e.velocity_direction_spread_y_end)
    mem.write16(addr + 0x42, e.velocity_direction_spread_z_end)

    -- Inertia (0x44-0x4B)
    mem.write16(addr + 0x44, e.inertia_min_start)
    mem.write16(addr + 0x46, e.inertia_max_start)
    mem.write16(addr + 0x48, e.inertia_min_end)
    mem.write16(addr + 0x4A, e.inertia_max_end)

    -- Weight (0x54-0x5B)
    mem.write16(addr + 0x54, e.weight_min_start)
    mem.write16(addr + 0x56, e.weight_max_start)
    mem.write16(addr + 0x58, e.weight_min_end)
    mem.write16(addr + 0x5A, e.weight_max_end)

    -- Radial Velocity (0x5C-0x63)
    mem.write16(addr + 0x5C, e.radial_velocity_min_start)
    mem.write16(addr + 0x5E, e.radial_velocity_max_start)
    mem.write16(addr + 0x60, e.radial_velocity_min_end)
    mem.write16(addr + 0x62, e.radial_velocity_max_end)

    -- Acceleration (0x64-0x7B)
    mem.write16(addr + 0x64, e.acceleration_x_min_start)
    mem.write16(addr + 0x66, e.acceleration_x_max_start)
    mem.write16(addr + 0x68, e.acceleration_y_min_start)
    mem.write16(addr + 0x6A, e.acceleration_y_max_start)
    mem.write16(addr + 0x6C, e.acceleration_z_min_start)
    mem.write16(addr + 0x6E, e.acceleration_z_max_start)
    mem.write16(addr + 0x70, e.acceleration_x_min_end)
    mem.write16(addr + 0x72, e.acceleration_x_max_end)
    mem.write16(addr + 0x74, e.acceleration_y_min_end)
    mem.write16(addr + 0x76, e.acceleration_y_max_end)
    mem.write16(addr + 0x78, e.acceleration_z_min_end)
    mem.write16(addr + 0x7A, e.acceleration_z_max_end)

    -- Drag (0x7C-0x93)
    mem.write16(addr + 0x7C, e.drag_x_min_start)
    mem.write16(addr + 0x7E, e.drag_x_max_start)
    mem.write16(addr + 0x80, e.drag_y_min_start)
    mem.write16(addr + 0x82, e.drag_y_max_start)
    mem.write16(addr + 0x84, e.drag_z_min_start)
    mem.write16(addr + 0x86, e.drag_z_max_start)
    mem.write16(addr + 0x88, e.drag_x_min_end)
    mem.write16(addr + 0x8A, e.drag_x_max_end)
    mem.write16(addr + 0x8C, e.drag_y_min_end)
    mem.write16(addr + 0x8E, e.drag_y_max_end)
    mem.write16(addr + 0x90, e.drag_z_min_end)
    mem.write16(addr + 0x92, e.drag_z_max_end)

    -- Lifetime (0x94-0x9B)
    mem.write16(addr + 0x94, e.lifetime_min_start)
    mem.write16(addr + 0x96, e.lifetime_max_start)
    mem.write16(addr + 0x98, e.lifetime_min_end)
    mem.write16(addr + 0x9A, e.lifetime_max_end)

    -- Target Offset (0x9C-0xA7)
    mem.write16(addr + 0x9C, e.target_offset_x_start)
    mem.write16(addr + 0x9E, e.target_offset_y_start)
    mem.write16(addr + 0xA0, e.target_offset_z_start)
    mem.write16(addr + 0xA2, e.target_offset_x_end)
    mem.write16(addr + 0xA4, e.target_offset_y_end)
    mem.write16(addr + 0xA6, e.target_offset_z_end)

    -- Spawn Control (0xB0-0xB7)
    mem.write16(addr + 0xB0, e.particle_count_start)
    mem.write16(addr + 0xB2, e.particle_count_end)
    mem.write16(addr + 0xB4, e.spawn_interval_start)
    mem.write16(addr + 0xB6, e.spawn_interval_end)

    -- Homing (0xB8-0xBF)
    mem.write16(addr + 0xB8, e.homing_strength_min_start)
    mem.write16(addr + 0xBA, e.homing_strength_max_start)
    mem.write16(addr + 0xBC, e.homing_strength_min_end)
    mem.write16(addr + 0xBE, e.homing_strength_max_end)

    -- Child Emitters (0xC0-0xC1)
    mem.write8(addr + 0xC0, e.child_emitter_on_death)
    mem.write8(addr + 0xC1, e.child_emitter_mid_life)

    return addr
end

-- Deep copy an emitter table with a new index
function M.copy_emitter(source, new_index)
    local e = {}

    -- Core Control Bytes
    e.byte_00 = source.byte_00
    e.anim_index = source.anim_index
    e.motion_type_flag = source.motion_type_flag
    e.animation_target_flag = source.animation_target_flag
    e.anim_param = source.anim_param
    e.byte_05 = source.byte_05
    e.emitter_flags_lo = source.emitter_flags_lo
    e.emitter_flags_hi = source.emitter_flags_hi

    -- Curve indices
    e.curve_indices_08 = source.curve_indices_08
    e.curve_indices_09 = source.curve_indices_09
    e.curve_indices_0A = source.curve_indices_0A
    e.curve_indices_0B = source.curve_indices_0B
    e.curve_indices_0C = source.curve_indices_0C
    e.curve_indices_0D = source.curve_indices_0D
    e.curve_indices_0E = source.curve_indices_0E
    e.curve_indices_0F = source.curve_indices_0F

    -- Color Curves
    e.color_curves_rg = source.color_curves_rg
    e.color_curves_b = source.color_curves_b

    -- Position
    e.start_position_x = source.start_position_x
    e.start_position_y = source.start_position_y
    e.start_position_z = source.start_position_z
    e.end_position_x = source.end_position_x
    e.end_position_y = source.end_position_y
    e.end_position_z = source.end_position_z

    -- Spread
    e.spread_x_start = source.spread_x_start
    e.spread_y_start = source.spread_y_start
    e.spread_z_start = source.spread_z_start
    e.spread_x_end = source.spread_x_end
    e.spread_y_end = source.spread_y_end
    e.spread_z_end = source.spread_z_end

    -- Velocity Base Angles
    e.velocity_base_angle_x_start = source.velocity_base_angle_x_start
    e.velocity_base_angle_y_start = source.velocity_base_angle_y_start
    e.velocity_base_angle_z_start = source.velocity_base_angle_z_start
    e.velocity_base_angle_x_end = source.velocity_base_angle_x_end
    e.velocity_base_angle_y_end = source.velocity_base_angle_y_end
    e.velocity_base_angle_z_end = source.velocity_base_angle_z_end

    -- Velocity Direction Spread
    e.velocity_direction_spread_x_start = source.velocity_direction_spread_x_start
    e.velocity_direction_spread_y_start = source.velocity_direction_spread_y_start
    e.velocity_direction_spread_z_start = source.velocity_direction_spread_z_start
    e.velocity_direction_spread_x_end = source.velocity_direction_spread_x_end
    e.velocity_direction_spread_y_end = source.velocity_direction_spread_y_end
    e.velocity_direction_spread_z_end = source.velocity_direction_spread_z_end

    -- Inertia
    e.inertia_min_start = source.inertia_min_start
    e.inertia_max_start = source.inertia_max_start
    e.inertia_min_end = source.inertia_min_end
    e.inertia_max_end = source.inertia_max_end

    -- Weight
    e.weight_min_start = source.weight_min_start
    e.weight_max_start = source.weight_max_start
    e.weight_min_end = source.weight_min_end
    e.weight_max_end = source.weight_max_end

    -- Radial Velocity
    e.radial_velocity_min_start = source.radial_velocity_min_start
    e.radial_velocity_max_start = source.radial_velocity_max_start
    e.radial_velocity_min_end = source.radial_velocity_min_end
    e.radial_velocity_max_end = source.radial_velocity_max_end

    -- Acceleration
    e.acceleration_x_min_start = source.acceleration_x_min_start
    e.acceleration_x_max_start = source.acceleration_x_max_start
    e.acceleration_y_min_start = source.acceleration_y_min_start
    e.acceleration_y_max_start = source.acceleration_y_max_start
    e.acceleration_z_min_start = source.acceleration_z_min_start
    e.acceleration_z_max_start = source.acceleration_z_max_start
    e.acceleration_x_min_end = source.acceleration_x_min_end
    e.acceleration_x_max_end = source.acceleration_x_max_end
    e.acceleration_y_min_end = source.acceleration_y_min_end
    e.acceleration_y_max_end = source.acceleration_y_max_end
    e.acceleration_z_min_end = source.acceleration_z_min_end
    e.acceleration_z_max_end = source.acceleration_z_max_end

    -- Drag
    e.drag_x_min_start = source.drag_x_min_start
    e.drag_x_max_start = source.drag_x_max_start
    e.drag_y_min_start = source.drag_y_min_start
    e.drag_y_max_start = source.drag_y_max_start
    e.drag_z_min_start = source.drag_z_min_start
    e.drag_z_max_start = source.drag_z_max_start
    e.drag_x_min_end = source.drag_x_min_end
    e.drag_x_max_end = source.drag_x_max_end
    e.drag_y_min_end = source.drag_y_min_end
    e.drag_y_max_end = source.drag_y_max_end
    e.drag_z_min_end = source.drag_z_min_end
    e.drag_z_max_end = source.drag_z_max_end

    -- Lifetime
    e.lifetime_min_start = source.lifetime_min_start
    e.lifetime_max_start = source.lifetime_max_start
    e.lifetime_min_end = source.lifetime_min_end
    e.lifetime_max_end = source.lifetime_max_end

    -- Target Offset
    e.target_offset_x_start = source.target_offset_x_start
    e.target_offset_y_start = source.target_offset_y_start
    e.target_offset_z_start = source.target_offset_z_start
    e.target_offset_x_end = source.target_offset_x_end
    e.target_offset_y_end = source.target_offset_y_end
    e.target_offset_z_end = source.target_offset_z_end

    -- Spawn Control
    e.particle_count_start = source.particle_count_start
    e.particle_count_end = source.particle_count_end
    e.spawn_interval_start = source.spawn_interval_start
    e.spawn_interval_end = source.spawn_interval_end

    -- Homing
    e.homing_strength_min_start = source.homing_strength_min_start
    e.homing_strength_max_start = source.homing_strength_max_start
    e.homing_strength_min_end = source.homing_strength_min_end
    e.homing_strength_max_end = source.homing_strength_max_end

    -- Child Emitters
    e.child_emitter_on_death = source.child_emitter_on_death
    e.child_emitter_mid_life = source.child_emitter_mid_life

    -- Metadata
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

return M
