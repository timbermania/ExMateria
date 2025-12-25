-- field_schema.lua
-- Schema-based parsing to eliminate duplication between _from_data and _from_memory functions
--
-- Instead of writing the same field-by-field code twice (once for buffer, once for memory),
-- we define schemas and use generic read/write functions.

local mem = require("memory_utils")

local M = {}

--------------------------------------------------------------------------------
-- Type Readers
--------------------------------------------------------------------------------

-- Read a field from a buffer (file data)
local function read_buffer(data, offset, field_type)
    if field_type == "u8" then
        return mem.buf_read8(data, offset)
    elseif field_type == "s16" then
        return mem.buf_read16s(data, offset)
    elseif field_type == "u16" then
        return mem.buf_read16(data, offset)
    elseif field_type == "s32" or field_type == "u32" then
        -- Note: buf_read32s doesn't exist, use unsigned for both
        return mem.buf_read32(data, offset)
    else
        error("Unknown field type: " .. tostring(field_type))
    end
end

-- Read a field from PSX memory
local function read_memory(addr, field_type)
    if field_type == "u8" then
        return mem.read8(addr)
    elseif field_type == "s16" then
        return mem.read16s(addr)
    elseif field_type == "u16" then
        return mem.read16(addr)
    elseif field_type == "s32" or field_type == "u32" then
        -- Note: read32s doesn't exist, use unsigned for both
        return mem.read32(addr)
    else
        error("Unknown field type: " .. tostring(field_type))
    end
end

-- Write a field to PSX memory
local function write_memory(addr, value, field_type)
    if field_type == "u8" then
        mem.write8(addr, value)
    elseif field_type == "s16" or field_type == "u16" then
        mem.write16(addr, value)
    elseif field_type == "s32" or field_type == "u32" then
        mem.write32(addr, value)
    else
        error("Unknown field type: " .. tostring(field_type))
    end
end

--------------------------------------------------------------------------------
-- Generic Schema Functions
--------------------------------------------------------------------------------

-- Parse an object from buffer data using a schema
function M.parse_from_buffer(schema, data, offset)
    local obj = {}
    for _, field in ipairs(schema) do
        obj[field.name] = read_buffer(data, offset + field.offset, field.type)
    end
    return obj
end

-- Parse an object from PSX memory using a schema
function M.parse_from_memory(schema, addr)
    local obj = {}
    for _, field in ipairs(schema) do
        obj[field.name] = read_memory(addr + field.offset, field.type)
    end
    return obj
end

-- Write an object to PSX memory using a schema
function M.write_to_memory(schema, addr, obj)
    for _, field in ipairs(schema) do
        if obj[field.name] ~= nil then
            write_memory(addr + field.offset, obj[field.name], field.type)
        end
    end
end

-- Deep copy an object using a schema (only copies schema fields)
function M.copy(schema, obj)
    local copy = {}
    for _, field in ipairs(schema) do
        copy[field.name] = obj[field.name]
    end
    return copy
end

--------------------------------------------------------------------------------
-- Emitter Schema (196 bytes = 0xC4)
--------------------------------------------------------------------------------

M.EMITTER_SCHEMA = {
    -- Core Control Bytes (0x00-0x0F)
    {name = "byte_00", offset = 0x00, type = "u8"},
    {name = "anim_index", offset = 0x01, type = "u8"},
    {name = "motion_type_flag", offset = 0x02, type = "u8"},
    {name = "animation_target_flag", offset = 0x03, type = "u8"},
    {name = "anim_param", offset = 0x04, type = "u8"},
    {name = "byte_05", offset = 0x05, type = "u8"},
    {name = "emitter_flags_lo", offset = 0x06, type = "u8"},
    {name = "emitter_flags_hi", offset = 0x07, type = "u8"},

    -- Curve indices (0x08-0x0F)
    {name = "curve_indices_08", offset = 0x08, type = "u8"},
    {name = "curve_indices_09", offset = 0x09, type = "u8"},
    {name = "curve_indices_0A", offset = 0x0A, type = "u8"},
    {name = "curve_indices_0B", offset = 0x0B, type = "u8"},
    {name = "curve_indices_0C", offset = 0x0C, type = "u8"},
    {name = "curve_indices_0D", offset = 0x0D, type = "u8"},
    {name = "curve_indices_0E", offset = 0x0E, type = "u8"},
    {name = "curve_indices_0F", offset = 0x0F, type = "u8"},

    -- Color Curves (0x10-0x11)
    {name = "color_curves_rg", offset = 0x10, type = "u8"},
    {name = "color_curves_b", offset = 0x11, type = "u8"},

    -- Position (0x14-0x1F)
    {name = "start_position_x", offset = 0x14, type = "s16"},
    {name = "start_position_y", offset = 0x16, type = "s16"},
    {name = "start_position_z", offset = 0x18, type = "s16"},
    {name = "end_position_x", offset = 0x1A, type = "s16"},
    {name = "end_position_y", offset = 0x1C, type = "s16"},
    {name = "end_position_z", offset = 0x1E, type = "s16"},

    -- Particle Spread (0x20-0x2B)
    {name = "spread_x_start", offset = 0x20, type = "s16"},
    {name = "spread_y_start", offset = 0x22, type = "s16"},
    {name = "spread_z_start", offset = 0x24, type = "s16"},
    {name = "spread_x_end", offset = 0x26, type = "s16"},
    {name = "spread_y_end", offset = 0x28, type = "s16"},
    {name = "spread_z_end", offset = 0x2A, type = "s16"},

    -- Velocity Base Angles (0x2C-0x37)
    {name = "velocity_base_angle_x_start", offset = 0x2C, type = "s16"},
    {name = "velocity_base_angle_y_start", offset = 0x2E, type = "s16"},
    {name = "velocity_base_angle_z_start", offset = 0x30, type = "s16"},
    {name = "velocity_base_angle_x_end", offset = 0x32, type = "s16"},
    {name = "velocity_base_angle_y_end", offset = 0x34, type = "s16"},
    {name = "velocity_base_angle_z_end", offset = 0x36, type = "s16"},

    -- Velocity Direction Spread (0x38-0x43)
    {name = "velocity_direction_spread_x_start", offset = 0x38, type = "s16"},
    {name = "velocity_direction_spread_y_start", offset = 0x3A, type = "s16"},
    {name = "velocity_direction_spread_z_start", offset = 0x3C, type = "s16"},
    {name = "velocity_direction_spread_x_end", offset = 0x3E, type = "s16"},
    {name = "velocity_direction_spread_y_end", offset = 0x40, type = "s16"},
    {name = "velocity_direction_spread_z_end", offset = 0x42, type = "s16"},

    -- Physics: Inertia (0x44-0x4B)
    {name = "inertia_min_start", offset = 0x44, type = "s16"},
    {name = "inertia_max_start", offset = 0x46, type = "s16"},
    {name = "inertia_min_end", offset = 0x48, type = "s16"},
    {name = "inertia_max_end", offset = 0x4A, type = "s16"},

    -- Physics: Weight (0x54-0x5B) - note: 0x4C-0x53 is dead code
    {name = "weight_min_start", offset = 0x54, type = "s16"},
    {name = "weight_max_start", offset = 0x56, type = "s16"},
    {name = "weight_min_end", offset = 0x58, type = "s16"},
    {name = "weight_max_end", offset = 0x5A, type = "s16"},

    -- Radial Velocity (0x5C-0x63)
    {name = "radial_velocity_min_start", offset = 0x5C, type = "s16"},
    {name = "radial_velocity_max_start", offset = 0x5E, type = "s16"},
    {name = "radial_velocity_min_end", offset = 0x60, type = "s16"},
    {name = "radial_velocity_max_end", offset = 0x62, type = "s16"},

    -- Acceleration (0x64-0x7B)
    {name = "acceleration_x_min_start", offset = 0x64, type = "s16"},
    {name = "acceleration_x_max_start", offset = 0x66, type = "s16"},
    {name = "acceleration_y_min_start", offset = 0x68, type = "s16"},
    {name = "acceleration_y_max_start", offset = 0x6A, type = "s16"},
    {name = "acceleration_z_min_start", offset = 0x6C, type = "s16"},
    {name = "acceleration_z_max_start", offset = 0x6E, type = "s16"},
    {name = "acceleration_x_min_end", offset = 0x70, type = "s16"},
    {name = "acceleration_x_max_end", offset = 0x72, type = "s16"},
    {name = "acceleration_y_min_end", offset = 0x74, type = "s16"},
    {name = "acceleration_y_max_end", offset = 0x76, type = "s16"},
    {name = "acceleration_z_min_end", offset = 0x78, type = "s16"},
    {name = "acceleration_z_max_end", offset = 0x7A, type = "s16"},

    -- Drag (0x7C-0x93)
    {name = "drag_x_min_start", offset = 0x7C, type = "s16"},
    {name = "drag_x_max_start", offset = 0x7E, type = "s16"},
    {name = "drag_y_min_start", offset = 0x80, type = "s16"},
    {name = "drag_y_max_start", offset = 0x82, type = "s16"},
    {name = "drag_z_min_start", offset = 0x84, type = "s16"},
    {name = "drag_z_max_start", offset = 0x86, type = "s16"},
    {name = "drag_x_min_end", offset = 0x88, type = "s16"},
    {name = "drag_x_max_end", offset = 0x8A, type = "s16"},
    {name = "drag_y_min_end", offset = 0x8C, type = "s16"},
    {name = "drag_y_max_end", offset = 0x8E, type = "s16"},
    {name = "drag_z_min_end", offset = 0x90, type = "s16"},
    {name = "drag_z_max_end", offset = 0x92, type = "s16"},

    -- Lifetime (0x94-0x9B)
    {name = "lifetime_min_start", offset = 0x94, type = "s16"},
    {name = "lifetime_max_start", offset = 0x96, type = "s16"},
    {name = "lifetime_min_end", offset = 0x98, type = "s16"},
    {name = "lifetime_max_end", offset = 0x9A, type = "s16"},

    -- Target Offset (0x9C-0xA7)
    {name = "target_offset_x_start", offset = 0x9C, type = "s16"},
    {name = "target_offset_y_start", offset = 0x9E, type = "s16"},
    {name = "target_offset_z_start", offset = 0xA0, type = "s16"},
    {name = "target_offset_x_end", offset = 0xA2, type = "s16"},
    {name = "target_offset_y_end", offset = 0xA4, type = "s16"},
    {name = "target_offset_z_end", offset = 0xA6, type = "s16"},

    -- Spawn Control (0xB0-0xB7)
    {name = "particle_count_start", offset = 0xB0, type = "s16"},
    {name = "particle_count_end", offset = 0xB2, type = "s16"},
    {name = "spawn_interval_start", offset = 0xB4, type = "s16"},
    {name = "spawn_interval_end", offset = 0xB6, type = "s16"},

    -- Homing (0xB8-0xBF)
    {name = "homing_strength_min_start", offset = 0xB8, type = "s16"},
    {name = "homing_strength_max_start", offset = 0xBA, type = "s16"},
    {name = "homing_strength_min_end", offset = 0xBC, type = "s16"},
    {name = "homing_strength_max_end", offset = 0xBE, type = "s16"},

    -- Child Emitters (0xC0-0xC1)
    {name = "child_emitter_on_death", offset = 0xC0, type = "u8"},
    {name = "child_emitter_mid_life", offset = 0xC1, type = "u8"},
}

--------------------------------------------------------------------------------
-- Particle Header Schema (20 bytes = 0x14)
--------------------------------------------------------------------------------

M.PARTICLE_HEADER_SCHEMA = {
    {name = "constant", offset = 0x00, type = "u16"},
    {name = "emitter_count", offset = 0x02, type = "u16"},
    {name = "gravity_x", offset = 0x04, type = "u32"},
    {name = "gravity_y", offset = 0x08, type = "u32"},
    {name = "gravity_z", offset = 0x0C, type = "u32"},
    {name = "inertia_threshold", offset = 0x10, type = "u32"},
}

--------------------------------------------------------------------------------
-- Effect Header Schema (40 bytes = 0x28)
--------------------------------------------------------------------------------

M.EFFECT_HEADER_SCHEMA = {
    {name = "frames_ptr", offset = 0x00, type = "u32"},
    {name = "animation_ptr", offset = 0x04, type = "u32"},
    {name = "script_data_ptr", offset = 0x08, type = "u32"},
    {name = "effect_data_ptr", offset = 0x0C, type = "u32"},
    {name = "anim_table_ptr", offset = 0x10, type = "u32"},
    {name = "timing_curve_ptr", offset = 0x14, type = "u32"},
    {name = "effect_flags_ptr", offset = 0x18, type = "u32"},
    {name = "timeline_section_ptr", offset = 0x1C, type = "u32"},
    {name = "sound_def_ptr", offset = 0x20, type = "u32"},
    {name = "texture_ptr", offset = 0x24, type = "u32"},
}

--------------------------------------------------------------------------------
-- Timeline Header Schema (20 bytes)
--------------------------------------------------------------------------------

M.TIMELINE_HEADER_SCHEMA = {
    {name = "particle_channels_ptr", offset = 0x00, type = "u32"},
    {name = "phase1_duration", offset = 0x04, type = "u16"},
    {name = "spawn_delay", offset = 0x06, type = "u16"},
    {name = "unknown_08", offset = 0x08, type = "u16"},
    {name = "phase2_delay", offset = 0x0A, type = "u16"},
    {name = "unknown_0C", offset = 0x0C, type = "u16"},
    {name = "unknown_0E", offset = 0x0E, type = "u16"},
    {name = "camera_tables_ptr", offset = 0x10, type = "u32"},
}

--------------------------------------------------------------------------------
-- Effect Flags Schema (8 bytes for main flags)
--------------------------------------------------------------------------------

M.EFFECT_FLAGS_SCHEMA = {
    {name = "flags_byte", offset = 0x00, type = "u8"},
    {name = "byte_01", offset = 0x01, type = "u8"},
    {name = "byte_02", offset = 0x02, type = "u8"},
    {name = "byte_03", offset = 0x03, type = "u8"},
    {name = "byte_04", offset = 0x04, type = "u8"},
    {name = "byte_05", offset = 0x05, type = "u8"},
    {name = "byte_06", offset = 0x06, type = "u8"},
    {name = "byte_07", offset = 0x07, type = "u8"},
}

return M
