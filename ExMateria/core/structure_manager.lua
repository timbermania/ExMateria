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
--   0x00: frames_ptr (sprite/frame definitions)
--   0x04: animation_ptr (sprite animation sequences)
--   0x08: script_data_ptr (script section start)
--   0x0C: effect_data_ptr (emitters section start)
--   0x10: anim_table_ptr (curves section start)
--   0x14: time_scale_ptr (optional, 0 if not present)
--   0x18: effect_flags_ptr
--   0x1C: timeline_section_ptr
--   0x20: sound_def_ptr
--   0x24: texture_ptr

M.SECTION_SCHEMA = {
    -- {name, header_offset, is_optional}
    -- Listed in order from start to end of file
    {name = "frames",        offset = 0x00, optional = false},  -- sprite/frame definitions
    {name = "animation",     offset = 0x04, optional = false},  -- sprite animation sequences
    {name = "script",        offset = 0x08, optional = false},
    {name = "effect_data",   offset = 0x0C, optional = false},  -- particle header + emitters
    {name = "anim_table",    offset = 0x10, optional = false},  -- animation curves
    {name = "time_scale",  offset = 0x14, optional = true},   -- 0 if not present
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
--          e.g., {time_scale = 600} means adding 600-byte time scale section
--          e.g., {time_scale = -600} means removing time scale section
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

            local current_ptr = mem_layout[section.name]
            if not current_ptr or current_ptr == 0 then
                log("WARNING: Section '" .. section.name .. "' has no valid pointer, skipping shift")
                goto continue_section
            end

            -- Find the section with the SMALLEST pointer that's > current_ptr
            -- This handles cases where sections are in different order in memory vs SECTION_SCHEMA
            local shift_start_ptr = nil
            for _, other_section in ipairs(M.SECTION_SCHEMA) do
                local other_ptr = mem_layout[other_section.name]
                if other_ptr and other_ptr ~= 0 and other_ptr > current_ptr then
                    if not shift_start_ptr or other_ptr < shift_start_ptr then
                        shift_start_ptr = other_ptr
                    end
                end
            end

            if shift_start_ptr then
                local shift_start = base + shift_start_ptr
                local shift_end = shift_start + 0x20000  -- 128KB margin for large effects like E066 (82KB)

                log_verbose(string.format("  Section '%s': shifting from 0x%08X by %d",
                    section.name, shift_start, delta))

                M.shift_memory_region(shift_start, shift_end, delta)

                -- Update ALL sections whose pointers are >= shift_start_ptr
                -- This handles memory order correctly regardless of SECTION_SCHEMA order
                for _, downstream in ipairs(M.SECTION_SCHEMA) do
                    local old_ptr = mem_layout[downstream.name]
                    if old_ptr and old_ptr ~= 0 and old_ptr >= shift_start_ptr then
                        mem_layout[downstream.name] = old_ptr + delta
                    end
                end
            end
            ::continue_section::
        end
    end

    if not made_changes then
        return false
    end

    -- Update header with new pointer values
    -- For optional sections (like time_scale): only update if memory had a non-zero value
    -- This preserves header values from .bin when memory doesn't have the optional section
    for _, section in ipairs(M.SECTION_SCHEMA) do
        local new_ptr = mem_layout[section.name]
        local should_update = new_ptr and (not section.optional or new_ptr ~= 0)
        if should_update then
            -- Update Lua header
            local header_field = section.name .. "_ptr"
            if header[header_field] ~= nil then
                header[header_field] = new_ptr
            elseif section.name == "script" then
                header.script_data_ptr = new_ptr
            elseif section.name == "timeline" then
                header.timeline_section_ptr = new_ptr
            elseif section.name == "anim_table" then
                header.anim_table_ptr = new_ptr
            end
        end
    end

    -- Write updated pointers to memory
    -- For optional sections (like time_scale): only write if memory had a non-zero value
    -- This preserves the "not present" state (ptr=0) for optional sections
    -- The time scale handler is responsible for adding/removing optional sections
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
        log("Structure changes applied")
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

-- Calculate time scale structure change
-- Returns: delta (600 for add, -600 for remove, 0 for no change)
function M.calculate_time_scale_delta(base)
    local mem_time_scale_ptr = MemUtils.read32(base + 0x14)
    local has_time_scale_in_memory = (mem_time_scale_ptr ~= 0)
    local wants_time_scale = (EFFECT_EDITOR.time_scales ~= nil)

    if wants_time_scale and not has_time_scale_in_memory then
        return 600  -- Add time scale section
    elseif not wants_time_scale and has_time_scale_in_memory then
        return -600  -- Remove time scale section
    end

    return 0
end

-- Calculate script section structure change
-- Returns: delta in bytes (positive = grew, negative = shrank, 0 = no change)
-- Works like calculate_emitter_delta: directly compare memory vs Lua state
function M.calculate_script_delta(base, silent)
    if not silent then
        print(string.format("[SCRIPT_DELTA] === calculate_script_delta(0x%08X) ===", base))
    end

    if not EFFECT_EDITOR.script_instructions then
        if not silent then print("[SCRIPT_DELTA] No script_instructions in Lua state") end
        return 0
    end

    -- Calculate Lua script size (what we want)
    local lua_size = Parser.calculate_script_size(EFFECT_EDITOR.script_instructions)
    local lua_count = #EFFECT_EDITOR.script_instructions
    if not silent then
        print(string.format("[SCRIPT_DELTA] Lua: %d instructions, %d bytes", lua_count, lua_size))
        -- Show first few Lua instructions
        for i = 1, math.min(3, lua_count) do
            local inst = EFFECT_EDITOR.script_instructions[i]
            print(string.format("[SCRIPT_DELTA]   Lua[%d]: opcode=%d (%s) size=%d",
                i, inst.opcode_id, inst.name or "?", inst.size))
        end
    end

    -- Parse script from memory and calculate its size
    -- This avoids phantom deltas from section padding (we parse actual instructions, not raw section)
    local mem_script_ptr = MemUtils.read32(base + 0x08)
    local mem_effect_data_ptr = MemUtils.read32(base + 0x0C)
    local section_size = mem_effect_data_ptr - mem_script_ptr
    if not silent then
        print(string.format("[SCRIPT_DELTA] Memory pointers: script=0x%X, effect_data=0x%X, section_size=%d",
            mem_script_ptr, mem_effect_data_ptr, section_size))
    end

    local mem_script = Parser.parse_script_from_memory(base, mem_script_ptr, section_size)
    if not mem_script then
        if not silent then print("[SCRIPT_DELTA] ERROR: parse_script_from_memory returned nil!") end
        return 0
    end

    local mem_size = Parser.calculate_script_size(mem_script)
    local mem_count = #mem_script
    if not silent then
        print(string.format("[SCRIPT_DELTA] Memory: %d instructions, %d bytes", mem_count, mem_size))
        -- Show first few memory instructions
        for i = 1, math.min(3, mem_count) do
            local inst = mem_script[i]
            print(string.format("[SCRIPT_DELTA]   Mem[%d]: opcode=%d (%s) size=%d",
                i, inst.opcode_id, inst.name or "?", inst.size))
        end
    end

    if lua_size == mem_size then
        if not silent then
            print(string.format("[SCRIPT_DELTA] MATCH: lua_size=%d == mem_size=%d, delta=0", lua_size, mem_size))
        end
        return 0
    end

    local delta = lua_size - mem_size
    if not silent then
        print(string.format("[SCRIPT_DELTA] MISMATCH: lua_size=%d, mem_size=%d, delta=%d", lua_size, mem_size, delta))
    end

    return delta
end

-- Calculate animation section structure change
-- Returns: delta in bytes (positive = grew, negative = shrank, 0 = no change)
-- Animation section is at header[0x04], between frames and script
function M.calculate_animation_delta(base, silent)
    if not silent then
        print(string.format("[ANIM_DELTA] === calculate_animation_delta(0x%08X) ===", base))
    end

    if not EFFECT_EDITOR.sequences then
        if not silent then print("[ANIM_DELTA] No sequences in Lua state") end
        return 0
    end

    -- Get current memory section size
    local mem_anim_ptr = MemUtils.read32(base + 0x04)
    local mem_script_ptr = MemUtils.read32(base + 0x08)
    local mem_section_size = mem_script_ptr - mem_anim_ptr

    if not silent then
        print(string.format("[ANIM_DELTA] Memory: anim_ptr=0x%X, script_ptr=0x%X, section_size=%d",
            mem_anim_ptr, mem_script_ptr, mem_section_size))
    end

    -- Calculate Lua animation section size
    local lua_size = Parser.calculate_animation_section_size(EFFECT_EDITOR.sequences)
    if not silent then
        print(string.format("[ANIM_DELTA] Lua section size: %d bytes (%d sequences)",
            lua_size, #EFFECT_EDITOR.sequences))
    end

    if lua_size == mem_section_size then
        -- No shift needed - use existing memory section size for padding
        EFFECT_EDITOR.animation_section_target_size = mem_section_size
        if not silent then
            print(string.format("[ANIM_DELTA] MATCH: lua_size=%d == mem_size=%d, delta=0", lua_size, mem_section_size))
        end
        return 0
    end

    local delta = lua_size - mem_section_size

    -- For small negative deltas (lost padding, typically 1-4 bytes), don't shift.
    -- Instead, we'll pad during write to fill the original section size.
    -- This prevents off-by-one corruptions from propagating through all downstream sections.
    if delta >= -4 and delta < 0 then
        -- No shift - pad to original memory size
        EFFECT_EDITOR.animation_section_target_size = mem_section_size
        if not silent then
            print(string.format("[ANIM_DELTA] SMALL PADDING GAP: lua_size=%d, mem_size=%d, delta=%d -> will pad instead of shift",
                lua_size, mem_section_size, delta))
        end
        return 0  -- Don't shift; write_animation_section will pad
    end

    -- Shift happening - target size is now the new aligned lua_size
    EFFECT_EDITOR.animation_section_target_size = lua_size
    if not silent then
        print(string.format("[ANIM_DELTA] MISMATCH: lua_size=%d, mem_size=%d, delta=%d", lua_size, mem_section_size, delta))
    end

    return delta
end

-- Calculate frames section structure change
-- Returns: delta in bytes (positive = grew, negative = shrank, 0 = no change)
-- Works like calculate_script_delta: directly compare memory vs Lua state
function M.calculate_frames_delta(base, silent)
    if not silent then
        print(string.format("[FRAMES_DELTA] === calculate_frames_delta(0x%08X) ===", base))
    end

    if not EFFECT_EDITOR.framesets then
        if not silent then print("[FRAMES_DELTA] No framesets in Lua state") end
        return 0
    end

    -- Get current memory section size
    local mem_frames_ptr = MemUtils.read32(base + 0x00)
    local mem_animation_ptr = MemUtils.read32(base + 0x04)
    local mem_section_size = mem_animation_ptr - mem_frames_ptr

    if not silent then
        print(string.format("[FRAMES_DELTA] Memory: frames_ptr=0x%X, animation_ptr=0x%X, section_size=%d",
            mem_frames_ptr, mem_animation_ptr, mem_section_size))
    end

    -- Calculate Lua frames section size (requires Parser.calculate_frames_section_size)
    if not Parser.calculate_frames_section_size then
        if not silent then print("[FRAMES_DELTA] Parser.calculate_frames_section_size not available yet") end
        return 0
    end

    -- Pass the physical offset_table_count to get accurate size (includes null terminator if present)
    local lua_size = Parser.calculate_frames_section_size(EFFECT_EDITOR.framesets, EFFECT_EDITOR.frames_group_count, EFFECT_EDITOR.frames_offset_table_count)
    if not silent then
        print(string.format("[FRAMES_DELTA] Lua section size: %d bytes (offset_table_count=%d)", lua_size, EFFECT_EDITOR.frames_offset_table_count or 0))
    end

    if lua_size == mem_section_size then
        if not silent then
            print(string.format("[FRAMES_DELTA] MATCH: lua_size=%d == mem_size=%d, delta=0", lua_size, mem_section_size))
        end
        return 0
    end

    local delta = lua_size - mem_section_size
    if not silent then
        print(string.format("[FRAMES_DELTA] MISMATCH: lua_size=%d, mem_size=%d, delta=%d", lua_size, mem_section_size, delta))
    end

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
