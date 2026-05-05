-- particle_reader.lua
-- Memory reading utilities for runtime particle structs
-- Used by Debug tab to display live particle data

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (injected)
--------------------------------------------------------------------------------

local MemUtils = nil

function M.set_dependencies(mem_utils)
    MemUtils = mem_utils
end

--------------------------------------------------------------------------------
-- Memory Constants
--------------------------------------------------------------------------------

-- EffectState array location and size
M.EFFECT_STATE_ARRAY_BASE = 0x801BF02C
M.EFFECT_STATE_SIZE = 0xF8  -- 248 bytes per EffectState

-- Active effect list head - gives the effect index with actual particles
-- (0x801C24D0 was wrong - it returns parent effect which has 0 particles)
M.ACTIVE_EFFECT_LIST_HEAD_ADDR = 0x801BBF90

-- Offset within EffectState to particle_list_head pointer
M.PARTICLE_LIST_HEAD_OFFSET = 0xD0

-- Runtime Particle struct size
M.PARTICLE_SIZE = 0x58  -- 88 bytes

-- Runtime Particle struct field offsets
M.PARTICLE = {
    prev = 0x00,              -- Particle* (4 bytes)
    next = 0x04,              -- Particle* (4 bytes)
    inertia = 0x08,           -- int16
    weight = 0x0A,            -- int16
    position_x = 0x0C,        -- int32 (12.12 fixed-point)
    position_y = 0x10,        -- int32
    position_z = 0x14,        -- int32
    velocity_x = 0x18,        -- int32
    velocity_y = 0x1C,        -- int32
    velocity_z = 0x20,        -- int32
    acceleration_x = 0x24,    -- int32
    acceleration_y = 0x28,    -- int32
    acceleration_z = 0x2C,    -- int32
    drag_x = 0x30,            -- int32
    drag_y = 0x34,            -- int32
    drag_z = 0x38,            -- int32
    target_x = 0x3C,          -- int16
    target_y = 0x3E,          -- int16
    target_z = 0x40,          -- int16
    lifetime_counter = 0x42,  -- int16 (-1 = animation-driven)
    unknown_44 = 0x44,        -- uint8
    homing_curve_index = 0x45,-- uint8
    color_r_curve = 0x46,     -- uint8
    color_g_curve = 0x47,     -- uint8
    color_b_curve = 0x48,     -- uint8
    unknown_49 = 0x49,        -- uint8
    homing_strength = 0x4A,   -- int16
    motion_flags = 0x4C,      -- uint16
    behavior_flags = 0x4E,    -- uint16
    anim_frame_counter = 0x50,-- uint16
    child_emitter_on_death = 0x52, -- uint8
    child_emitter_mid_life = 0x53, -- uint8
    anim_state = 0x54,        -- ParticleAnimState* (4 bytes)
}

-- ParticleAnimState struct offsets (36 bytes / 0x24)
M.ANIM_STATE = {
    pool_prev_index = 0x00,       -- uint16
    pool_next_index = 0x02,       -- uint16
    reserved_04 = 0x04,           -- uint16
    flags = 0x06,                 -- uint16
    sprite_offset_x = 0x08,       -- int16
    sprite_offset_y = 0x0A,       -- int16
    render_position_x = 0x0C,     -- int16
    render_position_y = 0x0E,     -- int16
    render_position_z = 0x10,     -- int16
    screen_rotation_angle = 0x12, -- int16
    depth_mode = 0x14,            -- uint8
    padding_15 = 0x15,            -- uint8
    frame_timer = 0x16,           -- uint16
    sequence_data_ptr = 0x18,     -- int32*
    frame_counter = 0x1C,         -- uint16
    sprite_variant_offset = 0x1E, -- uint8
    sprite_frame_index = 0x1F,    -- uint8
    sprite_data_ptr = 0x20,       -- void*
}

--------------------------------------------------------------------------------
-- Fixed-Point Conversion
--------------------------------------------------------------------------------

-- Convert signed 32-bit from memory read (Lua reads as unsigned)
local function to_signed32(value)
    if value >= 0x80000000 then
        return value - 0x100000000
    end
    return value
end

-- Convert 12.12 fixed-point to float
function M.fixed_to_float(value)
    return to_signed32(value) / 4096.0
end

-- Convert 12.12 fixed-point to integer world units
function M.fixed_to_int(value)
    return math.floor(to_signed32(value) / 4096)
end

--------------------------------------------------------------------------------
-- Memory Access Helpers
--------------------------------------------------------------------------------

-- Check if address is valid PSX RAM
local function is_valid_addr(addr)
    return addr ~= 0 and addr >= 0x80000000 and addr < 0x80200000
end

-- Get current effect index from active effect list head
function M.get_current_effect_index()
    if not MemUtils then return 0 end
    return MemUtils.read16(M.ACTIVE_EFFECT_LIST_HEAD_ADDR)
end

-- Get EffectState address for given effect index
function M.get_effect_state_addr(effect_index)
    return M.EFFECT_STATE_ARRAY_BASE + (effect_index * M.EFFECT_STATE_SIZE)
end

-- Get particle list head pointer for effect
function M.get_particle_list_head(effect_index)
    if not MemUtils then return 0 end
    local es_addr = M.get_effect_state_addr(effect_index)
    return MemUtils.read32(es_addr + M.PARTICLE_LIST_HEAD_OFFSET)
end

--------------------------------------------------------------------------------
-- Particle Reading
--------------------------------------------------------------------------------

-- Read a single particle struct into a Lua table
-- Returns nil if addr is 0 or invalid
function M.read_particle(addr)
    if not MemUtils then return nil end
    if not is_valid_addr(addr) then return nil end

    local p = {}
    local P = M.PARTICLE

    -- Address
    p.addr = addr

    -- Linked list pointers
    p.prev = MemUtils.read32(addr + P.prev)
    p.next = MemUtils.read32(addr + P.next)

    -- Physics constants
    p.inertia = MemUtils.read16s(addr + P.inertia)
    p.weight = MemUtils.read16s(addr + P.weight)

    -- Position (12.12 fixed-point, signed int32)
    p.position_x_raw = to_signed32(MemUtils.read32(addr + P.position_x))
    p.position_y_raw = to_signed32(MemUtils.read32(addr + P.position_y))
    p.position_z_raw = to_signed32(MemUtils.read32(addr + P.position_z))
    p.position_x = p.position_x_raw / 4096.0
    p.position_y = p.position_y_raw / 4096.0
    p.position_z = p.position_z_raw / 4096.0

    -- Velocity (12.12 fixed-point, signed int32)
    p.velocity_x_raw = to_signed32(MemUtils.read32(addr + P.velocity_x))
    p.velocity_y_raw = to_signed32(MemUtils.read32(addr + P.velocity_y))
    p.velocity_z_raw = to_signed32(MemUtils.read32(addr + P.velocity_z))
    p.velocity_x = p.velocity_x_raw / 4096.0
    p.velocity_y = p.velocity_y_raw / 4096.0
    p.velocity_z = p.velocity_z_raw / 4096.0

    -- Calculate velocity magnitude for summary display
    p.velocity_magnitude = math.sqrt(
        p.velocity_x * p.velocity_x +
        p.velocity_y * p.velocity_y +
        p.velocity_z * p.velocity_z
    )

    -- Acceleration (12.12 fixed-point, signed int32)
    p.acceleration_x_raw = to_signed32(MemUtils.read32(addr + P.acceleration_x))
    p.acceleration_y_raw = to_signed32(MemUtils.read32(addr + P.acceleration_y))
    p.acceleration_z_raw = to_signed32(MemUtils.read32(addr + P.acceleration_z))
    p.acceleration_x = p.acceleration_x_raw / 4096.0
    p.acceleration_y = p.acceleration_y_raw / 4096.0
    p.acceleration_z = p.acceleration_z_raw / 4096.0

    -- Drag (12.12 fixed-point, signed int32)
    p.drag_x_raw = to_signed32(MemUtils.read32(addr + P.drag_x))
    p.drag_y_raw = to_signed32(MemUtils.read32(addr + P.drag_y))
    p.drag_z_raw = to_signed32(MemUtils.read32(addr + P.drag_z))
    p.drag_x = p.drag_x_raw / 4096.0
    p.drag_y = p.drag_y_raw / 4096.0
    p.drag_z = p.drag_z_raw / 4096.0

    -- Target position (world units, not fixed-point)
    p.target_x = MemUtils.read16s(addr + P.target_x)
    p.target_y = MemUtils.read16s(addr + P.target_y)
    p.target_z = MemUtils.read16s(addr + P.target_z)

    -- Lifetime
    p.lifetime_counter = MemUtils.read16s(addr + P.lifetime_counter)

    -- Curve indices
    p.homing_curve_index = MemUtils.read8(addr + P.homing_curve_index)
    p.color_r_curve = MemUtils.read8(addr + P.color_r_curve)
    p.color_g_curve = MemUtils.read8(addr + P.color_g_curve)
    p.color_b_curve = MemUtils.read8(addr + P.color_b_curve)

    -- Homing strength
    p.homing_strength = MemUtils.read16s(addr + P.homing_strength)

    -- Flags
    p.motion_flags = MemUtils.read16(addr + P.motion_flags)
    p.behavior_flags = MemUtils.read16(addr + P.behavior_flags)

    -- Animation
    p.anim_frame_counter = MemUtils.read16(addr + P.anim_frame_counter)

    -- Child emitters
    p.child_emitter_on_death = MemUtils.read8(addr + P.child_emitter_on_death)
    p.child_emitter_mid_life = MemUtils.read8(addr + P.child_emitter_mid_life)

    -- AnimState pointer
    p.anim_state_ptr = MemUtils.read32(addr + P.anim_state)

    return p
end

-- Read ParticleAnimState if pointer is valid
function M.read_anim_state(anim_state_ptr)
    if not MemUtils then return nil end
    if not is_valid_addr(anim_state_ptr) then return nil end

    local a = {}
    local A = M.ANIM_STATE

    a.addr = anim_state_ptr
    a.flags = MemUtils.read16(anim_state_ptr + A.flags)
    a.sprite_offset_x = MemUtils.read16s(anim_state_ptr + A.sprite_offset_x)
    a.sprite_offset_y = MemUtils.read16s(anim_state_ptr + A.sprite_offset_y)
    a.render_position_x = MemUtils.read16s(anim_state_ptr + A.render_position_x)
    a.render_position_y = MemUtils.read16s(anim_state_ptr + A.render_position_y)
    a.render_position_z = MemUtils.read16s(anim_state_ptr + A.render_position_z)
    a.screen_rotation_angle = MemUtils.read16s(anim_state_ptr + A.screen_rotation_angle)
    a.depth_mode = MemUtils.read8(anim_state_ptr + A.depth_mode)
    a.frame_timer = MemUtils.read16(anim_state_ptr + A.frame_timer)
    a.sequence_data_ptr = MemUtils.read32(anim_state_ptr + A.sequence_data_ptr)
    a.frame_counter = MemUtils.read16(anim_state_ptr + A.frame_counter)
    a.sprite_variant_offset = MemUtils.read8(anim_state_ptr + A.sprite_variant_offset)
    a.sprite_frame_index = MemUtils.read8(anim_state_ptr + A.sprite_frame_index)

    return a
end

-- Traverse linked list and return array of particles
-- max_count prevents infinite loop on corrupt data
function M.read_all_particles(effect_index, max_count)
    if not MemUtils then return {} end
    max_count = max_count or 256

    local particles = {}
    local head = M.get_particle_list_head(effect_index)
    local current = head
    local count = 0
    local visited = {}  -- Track visited addresses to detect loops

    while is_valid_addr(current) and count < max_count do
        -- Detect loop
        if visited[current] then
            break
        end
        visited[current] = true

        local p = M.read_particle(current)
        if not p then break end

        table.insert(particles, p)
        current = p.next
        count = count + 1
    end

    return particles
end

return M
