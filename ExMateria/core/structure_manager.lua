-- structure_manager.lua
-- Centralized management of all structure changes (memory shifting + pointer cascades)
--
-- When any section size changes, this module:
-- 1. Shifts memory regions in correct order
-- 2. Updates ALL downstream header pointers automatically
-- 3. Writes updated pointers to memory
--
-- This eliminates the need for each structure handler to know about every downstream pointer.

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local MemUtils = nil
local Parser = nil
local log = function(msg) print("[STRUCT] " .. msg) end
local log_verbose = function(msg) end

function M.set_dependencies(mem_utils, parser, log_fn, verbose_fn)
    MemUtils = mem_utils
    Parser = parser
    log = log_fn or log
    log_verbose = verbose_fn or log_verbose
end

--------------------------------------------------------------------------------
-- Section Schema
--------------------------------------------------------------------------------

-- Define ALL sections in order, with their header offsets
-- Each section knows which pointer marks its START
-- When a section grows/shrinks, ALL downstream pointers must be updated
--
-- Header layout:
--   0x00: frames_ptr (fixed, not affected by structure changes)
--   0x04: animation_ptr (fixed)
--   0x08: script_data_ptr (script section start)
--   0x0C: effect_data_ptr (emitters section start)
--   0x10: anim_table_ptr (curves section start)
--   0x14: timing_curve_ptr (optional, 0 if not present)
--   0x18: effect_flags_ptr
--   0x1C: timeline_section_ptr
--   0x20: sound_def_ptr
--   0x24: texture_ptr

M.SECTION_SCHEMA = {
    -- {name, header_offset, is_optional}
    -- Listed in order from start to end of file
    {name = "script",        offset = 0x08, optional = false},
    {name = "effect_data",   offset = 0x0C, optional = false},  -- particle header + emitters
    {name = "anim_table",    offset = 0x10, optional = false},  -- animation curves
    {name = "timing_curve",  offset = 0x14, optional = true},   -- 0 if not present
    {name = "effect_flags",  offset = 0x18, optional = false},
    {name = "timeline",      offset = 0x1C, optional = false},
    {name = "sound_def",     offset = 0x20, optional = false},
    {name = "texture",       offset = 0x24, optional = false},
}

-- Quick lookup by name
M.SECTION_BY_NAME = {}
for i, section in ipairs(M.SECTION_SCHEMA) do
    M.SECTION_BY_NAME[section.name] = {index = i, offset = section.offset, optional = section.optional}
end

--------------------------------------------------------------------------------
-- Memory Shifting
--------------------------------------------------------------------------------

-- Shift a region of memory by delta bytes
-- Handles overlap correctly: forward shifts copy end-to-start, backward copy start-to-end
function M.shift_memory_region(src_start, src_end, delta)
    if delta == 0 then return end

    log_verbose(string.format("  Shifting memory 0x%08X-0x%08X by %d bytes", src_start, src_end, delta))

    if delta > 0 then
        -- Shifting forward: copy from end to start to avoid overwriting
        for i = src_end, src_start, -1 do
            local byte = MemUtils.read8(i)
            MemUtils.write8(i + delta, byte)
        end
    else
        -- Shifting backward: copy from start to end
        for i = src_start, src_end do
            local byte = MemUtils.read8(i)
            MemUtils.write8(i + delta, byte)
        end
    end
end

--------------------------------------------------------------------------------
-- Read Current Memory Layout
--------------------------------------------------------------------------------

-- Read all section pointers from memory
-- Returns a table mapping section_name -> current_ptr_value
function M.read_memory_layout(base)
    local layout = {}
    for _, section in ipairs(M.SECTION_SCHEMA) do
        layout[section.name] = MemUtils.read32(base + section.offset)
    end
    return layout
end

--------------------------------------------------------------------------------
-- Apply Structure Changes
--------------------------------------------------------------------------------

-- Apply one or more structure changes with automatic pointer cascade
--
-- base: PSX memory base address (e.g., 0x801C2500)
-- changes: table mapping section_name -> size_delta
--          e.g., {effect_data = 196} means emitter section grew by 196 bytes
--          e.g., {timing_curve = 600} means adding 600-byte timing section
--          e.g., {timing_curve = -600} means removing timing section
-- header: EFFECT_EDITOR.header (will be updated in place)
-- silent: suppress logging
--
-- Returns: true if any changes were made
function M.apply_structure_changes(base, changes, header, silent)
    if not changes or not next(changes) then
        return false
    end

    -- Read current memory layout
    local mem_layout = M.read_memory_layout(base)

    if not silent then
        log("Applying structure changes:")
        for name, delta in pairs(changes) do
            log(string.format("  %s: %+d bytes", name, delta))
        end
    end

    -- Process changes in section order (earliest sections first)
    -- This ensures we shift memory correctly without overwriting
    local made_changes = false

    for i, section in ipairs(M.SECTION_SCHEMA) do
        local delta = changes[section.name]
        if delta and delta ~= 0 then
            made_changes = true

            -- Find the NEXT section's current pointer (this is where we start shifting)
            local shift_start_ptr = nil
            for j = i + 1, #M.SECTION_SCHEMA do
                local next_ptr = mem_layout[M.SECTION_SCHEMA[j].name]
                if next_ptr and next_ptr ~= 0 then
                    shift_start_ptr = next_ptr
                    break
                end
            end

            if shift_start_ptr then
                local shift_start = base + shift_start_ptr
                local shift_end = shift_start + 0x10000  -- 64KB safe margin

                log_verbose(string.format("  Section '%s': shifting from 0x%08X by %d",
                    section.name, shift_start, delta))

                M.shift_memory_region(shift_start, shift_end, delta)

                -- Update ALL downstream pointers in mem_layout (for subsequent shifts)
                for j = i + 1, #M.SECTION_SCHEMA do
                    local downstream = M.SECTION_SCHEMA[j]
                    local old_ptr = mem_layout[downstream.name]
                    if old_ptr and old_ptr ~= 0 then
                        mem_layout[downstream.name] = old_ptr + delta
                    end
                end
            end
        end
    end

    if not made_changes then
        return false
    end

    -- Update header with new pointer values
    -- For optional sections (like timing_curve): only update if memory had a non-zero value
    -- This preserves header values from .bin when memory doesn't have the optional section
    -- The timing curve handler is responsible for adding/removing optional sections
    for _, section in ipairs(M.SECTION_SCHEMA) do
        local new_ptr = mem_layout[section.name]
        -- Skip optional sections if their pointer is 0 (not present in memory)
        -- Note: In Lua, 0 is truthy, so we need explicit != 0 check for optional sections
        local should_update = new_ptr and (not section.optional or new_ptr ~= 0)
        if should_update then
            -- Update Lua header
            local header_field = section.name .. "_ptr"
            if header[header_field] ~= nil then
                header[header_field] = new_ptr
            elseif section.name == "timeline" then
                header.timeline_section_ptr = new_ptr
            elseif section.name == "anim_table" then
                header.anim_table_ptr = new_ptr
            end
        end
    end

    -- Write updated pointers to memory
    -- For optional sections (like timing_curve): only write if memory had a non-zero value
    -- This preserves the "not present" state (ptr=0) for optional sections
    -- The timing curve handler is responsible for adding/removing optional sections
    for _, section in ipairs(M.SECTION_SCHEMA) do
        local new_ptr = mem_layout[section.name]
        -- For optional sections, only write if non-zero (section exists in memory)
        local should_write = new_ptr and (not section.optional or new_ptr ~= 0)
        if should_write then
            MemUtils.write32(base + section.offset, new_ptr)
        end
    end

    -- Force refresh memory pointer
    MemUtils.refresh_mem()

    if not silent then
        log("Structure changes applied. New layout:")
        for _, section in ipairs(M.SECTION_SCHEMA) do
            if mem_layout[section.name] ~= 0 then
                log(string.format("  %s: 0x%X", section.name, mem_layout[section.name]))
            end
        end
    end

    return true
end

--------------------------------------------------------------------------------
-- Convenience Functions for Common Structure Changes
--------------------------------------------------------------------------------

-- Calculate emitter structure change delta
-- Returns: delta in bytes, or 0 if no change needed
function M.calculate_emitter_delta(base)
    local mem_effect_data_ptr = MemUtils.read32(base + 0x0C)
    local mem_anim_table_ptr = MemUtils.read32(base + 0x10)

    -- Calculate current memory layout capacity
    local particle_section_size = mem_anim_table_ptr - mem_effect_data_ptr
    local mem_emitter_count = math.floor((particle_section_size - 0x14) / 0xC4)

    -- Compare with Lua state
    local lua_emitter_count = EFFECT_EDITOR.emitters and #EFFECT_EDITOR.emitters or 0

    if lua_emitter_count == mem_emitter_count then
        return 0
    end

    local delta = (lua_emitter_count - mem_emitter_count) * 0xC4
    log_verbose(string.format("  Emitter change: %d -> %d (delta=%d bytes)",
        mem_emitter_count, lua_emitter_count, delta))

    return delta
end

-- Calculate timing curve structure change
-- Returns: delta (600 for add, -600 for remove, 0 for no change)
function M.calculate_timing_curve_delta(base)
    local mem_timing_curve_ptr = MemUtils.read32(base + 0x14)
    local has_timing_in_memory = (mem_timing_curve_ptr ~= 0)
    local wants_timing = (EFFECT_EDITOR.timing_curves ~= nil)

    if wants_timing and not has_timing_in_memory then
        return 600  -- Add timing section
    elseif not wants_timing and has_timing_in_memory then
        return -600  -- Remove timing section
    end

    return 0
end

-- Calculate script section structure change
-- Returns: delta in bytes (positive = grew, negative = shrank, 0 = no change)
function M.calculate_script_delta(base)
    if not EFFECT_EDITOR.script_instructions then
        return 0
    end
    if not EFFECT_EDITOR.original_script_instructions then
        return 0
    end

    -- Compare current Lua state against ORIGINAL Lua state (not memory)
    -- This avoids phantom deltas from section padding that gets lost during parsing
    local current_size = Parser.calculate_script_size(EFFECT_EDITOR.script_instructions)
    local original_size = Parser.calculate_script_size(EFFECT_EDITOR.original_script_instructions)

    if current_size == original_size then
        return 0
    end

    local delta = current_size - original_size
    log_verbose(string.format("  Script change: %d -> %d (delta=%d bytes)",
        original_size, current_size, delta))

    return delta
end

--------------------------------------------------------------------------------
-- Debug/Info Functions
--------------------------------------------------------------------------------

function M.dump_layout(base)
    print("=== Memory Layout ===")
    print(string.format("Base: 0x%08X", base))
    local layout = M.read_memory_layout(base)
    for _, section in ipairs(M.SECTION_SCHEMA) do
        local ptr = layout[section.name]
        if ptr == 0 then
            print(string.format("  [0x%02X] %s: (not present)", section.offset, section.name))
        else
            print(string.format("  [0x%02X] %s: 0x%X", section.offset, section.name, ptr))
        end
    end
end

return M
