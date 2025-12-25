-- memory_ops.lua
-- File loading and memory write operations

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local MemUtils = nil
local Parser = nil
local config = nil
local log = function(msg) print("[EE] " .. msg) end
local log_verbose = function(msg) end
local log_error = function(msg) print("[EE ERROR] " .. msg) end
local StructureManager = nil

function M.set_dependencies(mem_utils, parser, cfg, log_fn, verbose_fn, error_fn, struct_mgr)
    MemUtils = mem_utils
    Parser = parser
    config = cfg
    log = log_fn
    log_verbose = verbose_fn
    log_error = error_fn
    StructureManager = struct_mgr
end

-- Handle structure changes (emitter count changed)
-- Returns true if structure was modified and sections were shifted
-- silent: if true, suppress status logging
--
-- REFACTORED: Now uses StructureManager for memory shifting and pointer cascade
local function handle_structure_change(silent)
    log_verbose("  [DEBUG] handle_structure_change called")
    log_verbose(string.format("  [DEBUG] #emitters = %d", EFFECT_EDITOR.emitters and #EFFECT_EDITOR.emitters or 0))

    local base = EFFECT_EDITOR.memory_base
    local header = EFFECT_EDITOR.header

    -- Calculate emitter delta using StructureManager
    local delta = StructureManager.calculate_emitter_delta(base)

    if delta == 0 then
        log_verbose("  [DEBUG] No emitter structure change needed")
        return false
    end

    -- Calculate counts for logging
    local mem_effect_data_ptr = MemUtils.read32(base + 0x0C)
    local mem_anim_table_ptr = MemUtils.read32(base + 0x10)
    local particle_section_size = mem_anim_table_ptr - mem_effect_data_ptr
    local mem_emitter_count = math.floor((particle_section_size - 0x14) / 0xC4)
    local current_count = #EFFECT_EDITOR.emitters

    if not silent then
        log(string.format("  Structure change: %d -> %d emitters (delta=%d bytes)",
            mem_emitter_count, current_count, delta))
    end

    -- Use StructureManager to apply the structure change
    -- This handles memory shifting and ALL downstream pointer updates
    -- When effect_data grows/shrinks, everything from anim_table onwards shifts
    -- NOTE: Optional sections (timing_curve) are only updated if they exist in memory
    local changes = {effect_data = delta}
    StructureManager.apply_structure_changes(base, changes, header, silent)

    -- Update particle_header.emitter_count in memory
    MemUtils.write16(base + mem_effect_data_ptr + 0x02, current_count)

    -- Update Lua tracking state
    EFFECT_EDITOR.emitter_count = current_count
    EFFECT_EDITOR.particle_header.emitter_count = current_count

    -- Recalculate sections
    EFFECT_EDITOR.sections = Parser.calculate_sections(header)

    log_verbose(string.format("  [DEBUG] Updated header pointers. New anim_table_ptr=0x%X", header.anim_table_ptr))
    log_verbose("  [DEBUG] Structure change complete")

    return true
end

--------------------------------------------------------------------------------
-- Timing Curve Structure Change (Add/Remove 600-byte section)
--------------------------------------------------------------------------------

local TIMING_SECTION_SIZE = 600  -- 0x258 bytes

-- Handle timing curve section addition/removal
-- Returns true if structure was modified
-- action: "add" or "remove"
local function handle_timing_curve_structure_change(action, silent)
    local base = EFFECT_EDITOR.memory_base
    local header = EFFECT_EDITOR.header

    if not base or base < 0x80000000 then
        log_error("No valid memory base address set")
        return false
    end

    -- Read current memory state
    local mem_timing_curve_ptr = MemUtils.read32(base + 0x14)
    local mem_effect_flags_ptr = MemUtils.read32(base + 0x18)
    local mem_timeline_section_ptr = MemUtils.read32(base + 0x1C)
    local mem_sound_def_ptr = MemUtils.read32(base + 0x20)
    local mem_texture_ptr = MemUtils.read32(base + 0x24)

    if action == "add" then
        -- Can only add if currently no timing curves
        if mem_timing_curve_ptr ~= 0 then
            if not silent then log("Timing curves section already exists") end
            return false
        end

        if not silent then
            log("Adding timing curves section (600 bytes)...")
            log(string.format("  Insert point: 0x%X (current effect_flags_ptr)", mem_effect_flags_ptr))
        end

        -- Insertion point: right after anim_curves (where effect_flags currently is)
        local insert_point = mem_effect_flags_ptr
        local shift_start = base + insert_point
        local shift_end = shift_start + 0x10000  -- Shift 64KB to be safe

        -- Shift memory forward by 600 bytes (use StructureManager for consistency)
        if not silent then
            log(string.format("  Shifting memory from 0x%08X forward by %d bytes", shift_start, TIMING_SECTION_SIZE))
        end
        StructureManager.shift_memory_region(shift_start, shift_end, TIMING_SECTION_SIZE)

        -- Update header pointers
        header.timing_curve_ptr = insert_point  -- New section goes here
        header.effect_flags_ptr = mem_effect_flags_ptr + TIMING_SECTION_SIZE
        header.timeline_section_ptr = mem_timeline_section_ptr + TIMING_SECTION_SIZE
        header.sound_def_ptr = mem_sound_def_ptr + TIMING_SECTION_SIZE
        header.texture_ptr = mem_texture_ptr + TIMING_SECTION_SIZE

        -- Write updated header to memory
        MemUtils.write32(base + 0x14, header.timing_curve_ptr)
        MemUtils.write32(base + 0x18, header.effect_flags_ptr)
        MemUtils.write32(base + 0x1C, header.timeline_section_ptr)
        MemUtils.write32(base + 0x20, header.sound_def_ptr)
        MemUtils.write32(base + 0x24, header.texture_ptr)

        -- Initialize new section with default values (0x22 = value 2 for both nibbles = normal speed)
        -- This will be overwritten by user's timing curve data if it exists
        local timing_addr = base + header.timing_curve_ptr
        for i = 0, TIMING_SECTION_SIZE - 1 do
            MemUtils.write8(timing_addr + i, 0x22)
        end

        -- Only create default timing_curves data if it doesn't already exist
        -- (preserves user's edits when re-adding section during apply_all_edits)
        if not EFFECT_EDITOR.timing_curves then
            EFFECT_EDITOR.timing_curves = {
                process_timeline = {},
                animate_tick = {}
            }
            for i = 1, 600 do
                EFFECT_EDITOR.timing_curves.process_timeline[i] = 2
                EFFECT_EDITOR.timing_curves.animate_tick[i] = 2
            end
            EFFECT_EDITOR.original_timing_curves = Parser.copy_timing_curves(EFFECT_EDITOR.timing_curves)
        end

        if not silent then
            log(string.format("  New timing_curve_ptr: 0x%X", header.timing_curve_ptr))
            log(string.format("  New effect_flags_ptr: 0x%X", header.effect_flags_ptr))
            log(string.format("  New timeline_section_ptr: 0x%X", header.timeline_section_ptr))
            log("  Timing curves section added successfully")
        end

        return true

    elseif action == "remove" then
        -- Can only remove if timing curves exist
        if mem_timing_curve_ptr == 0 then
            if not silent then log("No timing curves section to remove") end
            return false
        end

        if not silent then
            log("Removing timing curves section (600 bytes)...")
            log(string.format("  Remove point: 0x%X (current timing_curve_ptr)", mem_timing_curve_ptr))
        end

        -- Shift memory backward by 600 bytes (use StructureManager for consistency)
        local shift_start = base + mem_effect_flags_ptr
        local shift_end = shift_start + 0x10000
        if not silent then
            log(string.format("  Shifting memory from 0x%08X backward by %d bytes", shift_start, TIMING_SECTION_SIZE))
        end
        StructureManager.shift_memory_region(shift_start, shift_end, -TIMING_SECTION_SIZE)

        -- Update header pointers
        header.timing_curve_ptr = 0  -- No more timing curves
        header.effect_flags_ptr = mem_effect_flags_ptr - TIMING_SECTION_SIZE
        header.timeline_section_ptr = mem_timeline_section_ptr - TIMING_SECTION_SIZE
        header.sound_def_ptr = mem_sound_def_ptr - TIMING_SECTION_SIZE
        header.texture_ptr = mem_texture_ptr - TIMING_SECTION_SIZE

        -- Write updated header
        MemUtils.write32(base + 0x14, 0)
        MemUtils.write32(base + 0x18, header.effect_flags_ptr)
        MemUtils.write32(base + 0x1C, header.timeline_section_ptr)
        MemUtils.write32(base + 0x20, header.sound_def_ptr)
        MemUtils.write32(base + 0x24, header.texture_ptr)

        -- Clear timing curves data
        EFFECT_EDITOR.timing_curves = nil
        EFFECT_EDITOR.original_timing_curves = nil

        -- Clear timing enable flags from effect_flags
        if EFFECT_EDITOR.effect_flags then
            -- Clear bits 0x20 (process_timeline) and 0x40 (animate_tick)
            EFFECT_EDITOR.effect_flags.flags_byte = bit.band(EFFECT_EDITOR.effect_flags.flags_byte, bit.bnot(0x60))
            -- Write updated flags to memory
            Parser.write_effect_flags_to_memory(base, header.effect_flags_ptr, EFFECT_EDITOR.effect_flags)
        end

        if not silent then
            log(string.format("  New timing_curve_ptr: 0x%X (disabled)", header.timing_curve_ptr))
            log(string.format("  New effect_flags_ptr: 0x%X", header.effect_flags_ptr))
            log(string.format("  New timeline_section_ptr: 0x%X", header.timeline_section_ptr))
            log("  Timing curves section removed successfully")
        end

        return true
    end

    return false
end

-- Public function to add timing curves section (for UI)
function M.add_timing_curve_section()
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        log_error("No valid memory base address set. Load from memory first.")
        return false
    end

    PCSX.pauseEmulator()
    MemUtils.refresh_mem()

    local success = handle_timing_curve_structure_change("add", false)
    if success then
        EFFECT_EDITOR.sections = Parser.calculate_sections(EFFECT_EDITOR.header)
        print("")
        print("Added timing curves section (600 bytes). Emulator is PAUSED.")
        print("All downstream sections shifted. Resume with F5/F6.")
        print("")
    end
    return success
end

-- Public function to remove timing curves section (for UI)
function M.remove_timing_curve_section()
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        log_error("No valid memory base address set. Load from memory first.")
        return false
    end

    PCSX.pauseEmulator()
    MemUtils.refresh_mem()

    local success = handle_timing_curve_structure_change("remove", false)
    if success then
        EFFECT_EDITOR.sections = Parser.calculate_sections(EFFECT_EDITOR.header)
        print("")
        print("Removed timing curves section. Emulator is PAUSED.")
        print("All downstream sections shifted back. Resume with F5/F6.")
        print("")
    end
    return success
end

--------------------------------------------------------------------------------
-- Apply All Edits to Memory (PRIMARY FUNCTION)
--------------------------------------------------------------------------------

-- Helper: Handle structure changes (script + emitter count + timing curve add/remove)
-- Returns list of structure changes applied
local function apply_structure_changes(base, silent)
    local applied = {}
    local header = EFFECT_EDITOR.header

    -- DEBUG: Log initial state
    print(string.format("[DEBUG] === apply_structure_changes START ==="))
    print(string.format("[DEBUG] Lua header.texture_ptr = 0x%X", EFFECT_EDITOR.header.texture_ptr or 0))
    print(string.format("[DEBUG] Memory texture_ptr = 0x%X", MemUtils.read32(base + 0x24)))

    -- Handle script structure changes FIRST (script comes before effect_data)
    local script_delta = StructureManager.calculate_script_delta(base)
    if script_delta ~= 0 then
        print(string.format("[DEBUG] Script delta = %d", script_delta))
        if not silent then log(string.format("  Script structure change: %+d bytes", script_delta)) end
        StructureManager.apply_structure_changes(base, {script = script_delta}, header, silent)
        table.insert(applied, "script structure")
        -- DEBUG: Log state after script structure change
        print(string.format("[DEBUG] After script structure change:"))
        print(string.format("[DEBUG]   Lua header.texture_ptr = 0x%X", EFFECT_EDITOR.header.texture_ptr or 0))
        print(string.format("[DEBUG]   Memory texture_ptr = 0x%X", MemUtils.read32(base + 0x24)))
        -- Recalculate sections after script shift
        EFFECT_EDITOR.sections = Parser.calculate_sections(header)
        -- Update original to match current (prevents double-shifting on next apply)
        EFFECT_EDITOR.original_script_instructions = Parser.copy_script_instructions(EFFECT_EDITOR.script_instructions)
    end

    -- Handle emitter structure changes
    local structure_changed = handle_structure_change(silent)
    if structure_changed then
        table.insert(applied, "structure")
        -- DEBUG: Log state after emitter structure change
        print(string.format("[DEBUG] After emitter structure change:"))
        print(string.format("[DEBUG]   Lua header.texture_ptr = 0x%X", EFFECT_EDITOR.header.texture_ptr or 0))
        print(string.format("[DEBUG]   Memory texture_ptr = 0x%X", MemUtils.read32(base + 0x24)))
    end

    -- Handle timing curve structure changes (add/remove 600-byte section)
    local mem_timing_curve_ptr = MemUtils.read32(base + 0x14)
    local lua_timing_curve_ptr = EFFECT_EDITOR.header.timing_curve_ptr
    -- DEBUG: Log timing curve check
    print(string.format("[DEBUG] Timing curve check:"))
    print(string.format("[DEBUG]   lua_timing_curve_ptr = 0x%X", lua_timing_curve_ptr or 0))
    print(string.format("[DEBUG]   mem_timing_curve_ptr = 0x%X", mem_timing_curve_ptr or 0))

    if lua_timing_curve_ptr ~= 0 and mem_timing_curve_ptr == 0 then
        if not silent then log("  Timing curve structure change: ADDING 600-byte section") end
        if handle_timing_curve_structure_change("add", silent) then
            table.insert(applied, "timing structure (add)")
        end
    elseif lua_timing_curve_ptr == 0 and mem_timing_curve_ptr ~= 0 then
        if not silent then log("  Timing curve structure change: REMOVING section") end
        if handle_timing_curve_structure_change("remove", silent) then
            table.insert(applied, "timing structure (remove)")
        end
    end

    -- DEBUG: Log final state
    print(string.format("[DEBUG] === apply_structure_changes END ==="))
    print(string.format("[DEBUG] Final Lua header.texture_ptr = 0x%X", EFFECT_EDITOR.header.texture_ptr or 0))
    print(string.format("[DEBUG] Final Memory texture_ptr = 0x%X", MemUtils.read32(base + 0x24)))

    return applied
end

-- Helper: Write particle system data (header + emitters)
local function write_particle_system(base, header, silent)
    local applied = {}

    -- Write particle header (gravity, inertia)
    if EFFECT_EDITOR.particle_header then
        local particle_base = base + header.effect_data_ptr
        local ph = EFFECT_EDITOR.particle_header
        MemUtils.write32(particle_base + 0x04, ph.gravity_x)
        MemUtils.write32(particle_base + 0x08, ph.gravity_y)
        MemUtils.write32(particle_base + 0x0C, ph.gravity_z)
        MemUtils.write32(particle_base + 0x10, ph.inertia_threshold)
        table.insert(applied, "header")
        if not silent then log(string.format("  Header: gravity=(%d,%d,%d) inertia=%d",
            ph.gravity_x, ph.gravity_y, ph.gravity_z, ph.inertia_threshold)) end
    end

    -- Write emitters
    if EFFECT_EDITOR.emitters and #EFFECT_EDITOR.emitters > 0 then
        local particle_base = base + header.effect_data_ptr
        for _, e in ipairs(EFFECT_EDITOR.emitters) do
            Parser.write_emitter_to_memory(particle_base, e.index, e)
        end
        table.insert(applied, string.format("%d emitters", #EFFECT_EDITOR.emitters))
        if not silent then log(string.format("  Wrote %d emitters", #EFFECT_EDITOR.emitters)) end
    end

    return applied
end

-- Helper: Write animation curves
local function write_curves(base, header, silent)
    if not EFFECT_EDITOR.curves or #EFFECT_EDITOR.curves == 0 then return {} end

    local anim_table_addr = base + header.anim_table_ptr
    Parser.write_all_curves_to_memory(anim_table_addr, EFFECT_EDITOR.curves)
    if not silent then log(string.format("  Wrote %d curves", #EFFECT_EDITOR.curves)) end
    return {string.format("%d curves", #EFFECT_EDITOR.curves)}
end

-- Helper: Write timeline data (header + channels + camera + color tracks)
local function write_timeline_data(base, header, silent)
    local applied = {}

    -- Timeline header and channels
    if EFFECT_EDITOR.timeline_header and EFFECT_EDITOR.timeline_channels then
        local timeline_addr = base + header.timeline_section_ptr
        Parser.write_timeline_header_to_memory(timeline_addr, EFFECT_EDITOR.timeline_header)
        Parser.write_all_timeline_channels_to_memory(base, header.timeline_section_ptr, EFFECT_EDITOR.timeline_channels)
        table.insert(applied, string.format("%d timeline channels", #EFFECT_EDITOR.timeline_channels))
        if not silent then log(string.format("  Wrote timeline header and %d channels", #EFFECT_EDITOR.timeline_channels)) end
    end

    -- Camera tables
    if EFFECT_EDITOR.camera_tables and #EFFECT_EDITOR.camera_tables > 0 then
        Parser.write_all_camera_tables_to_memory(base, header.timeline_section_ptr, EFFECT_EDITOR.camera_tables)
        table.insert(applied, string.format("%d camera tables", #EFFECT_EDITOR.camera_tables))
        if not silent then log(string.format("  Wrote %d camera tables", #EFFECT_EDITOR.camera_tables)) end
    end

    -- Color tracks
    if EFFECT_EDITOR.color_tracks and #EFFECT_EDITOR.color_tracks > 0 then
        Parser.write_all_color_tracks_to_memory(base, header.timeline_section_ptr, EFFECT_EDITOR.color_tracks)
        table.insert(applied, string.format("%d color tracks", #EFFECT_EDITOR.color_tracks))
        if not silent then log(string.format("  Wrote %d color tracks", #EFFECT_EDITOR.color_tracks)) end
    end

    return applied
end

-- Helper: Write timing curves
local function write_timing_curves(base, header, silent)
    if not EFFECT_EDITOR.timing_curves or header.timing_curve_ptr == 0 then return {} end

    Parser.write_timing_curves_to_memory(base, header.timing_curve_ptr, EFFECT_EDITOR.timing_curves)
    if not silent then log(string.format("  Wrote timing curves at 0x%X", header.timing_curve_ptr)) end
    return {"timing curves"}
end

-- Helper: Write flags (effect + sound)
local function write_flags(base, header, silent)
    local applied = {}

    -- Effect flags
    if EFFECT_EDITOR.effect_flags then
        Parser.write_effect_flags_to_memory(base, header.effect_flags_ptr, EFFECT_EDITOR.effect_flags)
        table.insert(applied, "effect flags")
        if not silent then
            local flags = EFFECT_EDITOR.effect_flags.flags_byte
            log(string.format("  Wrote effect flags: 0x%02X", flags))
        end
    end

    -- Sound flags
    if EFFECT_EDITOR.sound_flags then
        Parser.write_sound_flags_to_memory(base, header.effect_flags_ptr, EFFECT_EDITOR.sound_flags)
        table.insert(applied, "sound flags")
        if not silent then log("  Wrote 4 sound config channels") end
    end

    return applied
end

-- Helper: Write sound definition (feds section)
local function write_sound_definition(base, header, silent)
    if not EFFECT_EDITOR.sound_definition then return {} end

    local old_size = header.texture_ptr - header.sound_def_ptr
    local new_bytes, new_size = Parser.serialize_sound_definition(EFFECT_EDITOR.sound_definition)

    if not new_bytes then return {} end

    local sound_addr = base + header.sound_def_ptr

    if new_size == old_size then
        for i = 1, #new_bytes do
            MemUtils.write8(sound_addr + i - 1, new_bytes:byte(i))
        end
        if not silent then log(string.format("  Wrote feds section (%d bytes)", new_size)) end
        return {"sound definition"}
    elseif new_size < old_size then
        for i = 1, #new_bytes do
            MemUtils.write8(sound_addr + i - 1, new_bytes:byte(i))
        end
        for i = new_size + 1, old_size do
            MemUtils.write8(sound_addr + i - 1, 0)
        end
        if not silent then log(string.format("  Wrote feds section (%d->%d bytes, padded)", new_size, old_size)) end
        return {"sound definition (shrunk)"}
    else
        log(string.format("  WARNING: Sound section grew (%d->%d bytes) - NOT WRITTEN", old_size, new_size))
        return {}
    end
end

-- Helper: Write script bytecode to memory
local function write_script(base, header, silent)
    if not EFFECT_EDITOR.script_instructions or #EFFECT_EDITOR.script_instructions == 0 then
        return {}
    end

    Parser.write_script_to_memory(base, header.script_data_ptr, EFFECT_EDITOR.script_instructions)
    if not silent then
        log(string.format("  Wrote %d script instructions", #EFFECT_EDITOR.script_instructions))
    end
    return {string.format("%d script ops", #EFFECT_EDITOR.script_instructions)}
end

-- Apply ALL edits (particle header + emitters + curves) to memory
-- This is THE function to use when applying changes - ensures everything is in sync
-- silent: if true, skip user-facing prints (used during automated operations)
function M.apply_all_edits_to_memory(silent)
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        log_error("No valid memory base address set. Load from memory first or set address.")
        return false
    end

    PCSX.pauseEmulator()
    if not silent then log("Applying all edits to memory...") end
    MemUtils.refresh_mem()

    local base = EFFECT_EDITOR.memory_base
    local header = EFFECT_EDITOR.header
    local applied = {}

    -- Phase 1: Structure changes (shifts memory, updates pointers)
    for _, item in ipairs(apply_structure_changes(base, silent)) do
        table.insert(applied, item)
    end

    -- Phase 2: Write all data sections
    -- Script bytecode (before particle system in file order)
    for _, item in ipairs(write_script(base, header, silent)) do
        table.insert(applied, item)
    end
    for _, item in ipairs(write_particle_system(base, header, silent)) do
        table.insert(applied, item)
    end
    for _, item in ipairs(write_curves(base, header, silent)) do
        table.insert(applied, item)
    end
    for _, item in ipairs(write_timeline_data(base, header, silent)) do
        table.insert(applied, item)
    end
    for _, item in ipairs(write_timing_curves(base, header, silent)) do
        table.insert(applied, item)
    end
    for _, item in ipairs(write_flags(base, header, silent)) do
        table.insert(applied, item)
    end
    for _, item in ipairs(write_sound_definition(base, header, silent)) do
        table.insert(applied, item)
    end

    local applied_str = table.concat(applied, ", ")
    EFFECT_EDITOR.status_msg = "Applied: " .. applied_str

    if not silent then
        print("")
        print(string.format("Applied to memory: %s. Emulator is PAUSED.", applied_str))
        print("Resume with F5/F6 to see changes!")
        print("")
    end

    return true
end

--------------------------------------------------------------------------------
-- Apply Single Curve to Memory (for quick curve testing)
--------------------------------------------------------------------------------

-- Write a single curve to memory without affecting emitters
-- Useful for rapid curve iteration in the curves tab
function M.apply_single_curve_to_memory(curve_index)
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        log_error("No valid memory base address set.")
        return false
    end

    if not EFFECT_EDITOR.curves or not EFFECT_EDITOR.curves[curve_index + 1] then
        log_error(string.format("Curve %d not loaded", curve_index + 1))
        return false
    end

    PCSX.pauseEmulator()
    MemUtils.refresh_mem()

    local anim_table_addr = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.anim_table_ptr
    Parser.write_curve_to_memory(anim_table_addr, curve_index, EFFECT_EDITOR.curves[curve_index + 1])

    log(string.format("Wrote curve %d to memory", curve_index + 1))
    EFFECT_EDITOR.status_msg = string.format("Applied curve %d", curve_index + 1)

    print("")
    print(string.format("Curve %d applied. Emulator is PAUSED.", curve_index + 1))
    print("Resume with F5/F6 to see changes!")
    print("")

    return true
end

--------------------------------------------------------------------------------
-- File Loading
--------------------------------------------------------------------------------

function M.load_effect_file(effect_num)
    local filename = string.format("E%s.BIN", effect_num)
    local path = config.EFFECT_FILES_PATH .. filename

    log(string.format("Loading %s", path))
    EFFECT_EDITOR.status_msg = "Loading " .. filename .. "..."

    local data, err = MemUtils.load_file(path)
    if not data then
        log_error(err or "Unknown error loading file")
        EFFECT_EDITOR.status_msg = "ERROR: " .. (err or "Unknown error")
        return false
    end

    log_verbose(string.format("File loaded: %d bytes", #data))

    EFFECT_EDITOR.file_data = data
    EFFECT_EDITOR.file_path = path
    EFFECT_EDITOR.file_name = filename

    -- Parse header
    log_verbose("Parsing header...")
    EFFECT_EDITOR.header = Parser.parse_header_from_data(data)
    EFFECT_EDITOR.sections = Parser.calculate_sections(EFFECT_EDITOR.header)

    -- Parse script bytecode
    log_verbose("Parsing script bytecode...")
    local script_size = EFFECT_EDITOR.header.effect_data_ptr - EFFECT_EDITOR.header.script_data_ptr
    EFFECT_EDITOR.script_instructions = Parser.parse_script_from_data(data, EFFECT_EDITOR.header.script_data_ptr, script_size)
    EFFECT_EDITOR.original_script_instructions = Parser.copy_script_instructions(EFFECT_EDITOR.script_instructions)
    log_verbose(string.format("  Loaded %d script instructions (%d bytes)", #EFFECT_EDITOR.script_instructions, script_size))

    -- Calculate emitter count
    local particle_size = EFFECT_EDITOR.header.anim_table_ptr - EFFECT_EDITOR.header.effect_data_ptr
    EFFECT_EDITOR.emitter_count = Parser.calc_emitter_count(particle_size)

    -- Parse particle system header and emitters
    log_verbose("Parsing particle system...")
    EFFECT_EDITOR.particle_header = Parser.parse_particle_header_from_data(data, EFFECT_EDITOR.header.effect_data_ptr)
    EFFECT_EDITOR.emitters = Parser.parse_all_emitters(data, EFFECT_EDITOR.header.effect_data_ptr, EFFECT_EDITOR.emitter_count)

    log_verbose(string.format("  Particle header: constant=%d, emitter_count=%d",
        EFFECT_EDITOR.particle_header.constant, EFFECT_EDITOR.particle_header.emitter_count))
    log_verbose(string.format("  Gravity: (%d, %d, %d)",
        EFFECT_EDITOR.particle_header.gravity_x, EFFECT_EDITOR.particle_header.gravity_y, EFFECT_EDITOR.particle_header.gravity_z))

    -- Parse animation curves
    log_verbose("Parsing animation curves...")
    EFFECT_EDITOR.curves, EFFECT_EDITOR.curve_count = Parser.parse_curves_from_data(data, EFFECT_EDITOR.header.anim_table_ptr)
    EFFECT_EDITOR.original_curves = Parser.copy_curves(EFFECT_EDITOR.curves)
    log_verbose(string.format("  Loaded %d animation curves", EFFECT_EDITOR.curve_count))

    -- Parse timeline section
    log_verbose("Parsing timeline section...")
    EFFECT_EDITOR.timeline_header = Parser.parse_timeline_header_from_data(data, EFFECT_EDITOR.header.timeline_section_ptr)
    EFFECT_EDITOR.timeline_channels = Parser.parse_all_timeline_channels(data, EFFECT_EDITOR.header.timeline_section_ptr)
    EFFECT_EDITOR.original_timeline_header = Parser.copy_timeline_header(EFFECT_EDITOR.timeline_header)
    EFFECT_EDITOR.original_timeline_channels = Parser.copy_timeline_channels(EFFECT_EDITOR.timeline_channels)
    log_verbose(string.format("  Loaded timeline header and %d particle channels", #EFFECT_EDITOR.timeline_channels))

    -- Parse camera timeline tables
    log_verbose("Parsing camera timeline...")
    EFFECT_EDITOR.camera_tables = Parser.parse_all_camera_tables(data, EFFECT_EDITOR.header.timeline_section_ptr)
    EFFECT_EDITOR.original_camera_tables = Parser.copy_camera_tables(EFFECT_EDITOR.camera_tables)
    log_verbose(string.format("  Loaded %d camera tables", #EFFECT_EDITOR.camera_tables))

    -- Parse color tracks
    log_verbose("Parsing color tracks...")
    EFFECT_EDITOR.color_tracks = Parser.parse_all_color_tracks(data, EFFECT_EDITOR.header.timeline_section_ptr)
    EFFECT_EDITOR.original_color_tracks = Parser.copy_color_tracks(EFFECT_EDITOR.color_tracks)
    log_verbose(string.format("  Loaded %d color tracks", #EFFECT_EDITOR.color_tracks))

    -- Parse timing curves (may be nil if timing_curve_ptr is 0)
    log_verbose("Parsing timing curves...")
    EFFECT_EDITOR.timing_curves = Parser.parse_timing_curves_from_data(data, EFFECT_EDITOR.header.timing_curve_ptr)
    EFFECT_EDITOR.original_timing_curves = Parser.copy_timing_curves(EFFECT_EDITOR.timing_curves)
    if EFFECT_EDITOR.timing_curves then
        log_verbose("  Loaded timing curves (600 frames per region)")
    else
        log_verbose("  No timing curves (timing_curve_ptr = 0)")
    end

    -- Parse effect flags
    log_verbose("Parsing effect flags...")
    EFFECT_EDITOR.effect_flags = Parser.parse_effect_flags_from_data(data, EFFECT_EDITOR.header.effect_flags_ptr)
    EFFECT_EDITOR.original_effect_flags = Parser.copy_effect_flags(EFFECT_EDITOR.effect_flags)
    log_verbose(string.format("  Loaded effect flags: 0x%02X", EFFECT_EDITOR.effect_flags.flags_byte))

    -- Parse sound flags from file data (effect_flags section bytes 0x08-0x17)
    log_verbose("Parsing sound flags...")
    EFFECT_EDITOR.sound_flags = Parser.parse_sound_flags_from_data(data, EFFECT_EDITOR.header.effect_flags_ptr)
    EFFECT_EDITOR.original_sound_flags = Parser.copy_sound_flags(EFFECT_EDITOR.sound_flags)
    log_verbose("  Loaded 4 sound config channels")

    -- Parse sound definition (feds section) from file data
    log_verbose("Parsing sound definition...")
    local sound_section_size = EFFECT_EDITOR.header.texture_ptr - EFFECT_EDITOR.header.sound_def_ptr
    if sound_section_size > 0 then
        EFFECT_EDITOR.sound_definition = Parser.parse_sound_definition_from_data(data, EFFECT_EDITOR.header.sound_def_ptr, sound_section_size)
        EFFECT_EDITOR.original_sound_definition = Parser.copy_sound_definition(EFFECT_EDITOR.sound_definition)
        if EFFECT_EDITOR.sound_definition then
            log_verbose(string.format("  Loaded feds section: %d channels, resource_id=%d",
                EFFECT_EDITOR.sound_definition.num_channels, EFFECT_EDITOR.sound_definition.resource_id))
        else
            log_verbose("  No valid feds section found")
        end
    else
        EFFECT_EDITOR.sound_definition = nil
        EFFECT_EDITOR.original_sound_definition = nil
        log_verbose("  No sound definition section (size=0)")
    end

    -- Store original state for structure change detection
    EFFECT_EDITOR.original_emitter_count = EFFECT_EDITOR.emitter_count
    EFFECT_EDITOR.original_header = {
        anim_table_ptr = EFFECT_EDITOR.header.anim_table_ptr,
        timing_curve_ptr = EFFECT_EDITOR.header.timing_curve_ptr,
        effect_flags_ptr = EFFECT_EDITOR.header.effect_flags_ptr,
        timeline_section_ptr = EFFECT_EDITOR.header.timeline_section_ptr,
        sound_def_ptr = EFFECT_EDITOR.header.sound_def_ptr,
        texture_ptr = EFFECT_EDITOR.header.texture_ptr,
    }

    local msg = string.format("Loaded %s (%d bytes, %s format, %d emitters, %d curves)",
        filename, #data, EFFECT_EDITOR.header.format, EFFECT_EDITOR.emitter_count, EFFECT_EDITOR.curve_count)
    log(msg)
    EFFECT_EDITOR.status_msg = msg

    log_verbose(string.format("  frames_ptr: 0x%X", EFFECT_EDITOR.header.frames_ptr))
    log_verbose(string.format("  effect_data_ptr: 0x%X", EFFECT_EDITOR.header.effect_data_ptr))
    log_verbose(string.format("  anim_table_ptr: 0x%X", EFFECT_EDITOR.header.anim_table_ptr))

    return true
end

--------------------------------------------------------------------------------
-- Memory Loading
--------------------------------------------------------------------------------

-- Internal version - assumes emulator is already paused
function M.load_from_memory_internal(base_addr)
    log(string.format("Loading from memory at 0x%08X", base_addr))
    MemUtils.refresh_mem()

    -- Lookup table stores HEADER address directly (NOT size prefix address)
    -- Header pointer VALUES are offsets from header start (same as file offsets)
    local header_location = base_addr  -- No +4, lookup table already points to header
    log(string.format("  Header at 0x%08X", header_location))

    EFFECT_EDITOR.memory_base = base_addr
    EFFECT_EDITOR.header = Parser.parse_header_from_memory(header_location)
    EFFECT_EDITOR.sections = Parser.calculate_sections(EFFECT_EDITOR.header)

    -- Parse script bytecode from memory
    local script_size = EFFECT_EDITOR.header.effect_data_ptr - EFFECT_EDITOR.header.script_data_ptr
    EFFECT_EDITOR.script_instructions = Parser.parse_script_from_memory(base_addr, EFFECT_EDITOR.header.script_data_ptr, script_size)
    EFFECT_EDITOR.original_script_instructions = Parser.copy_script_instructions(EFFECT_EDITOR.script_instructions)
    log(string.format("  Loaded %d script instructions (%d bytes) from memory", #EFFECT_EDITOR.script_instructions, script_size))

    local particle_size = EFFECT_EDITOR.header.anim_table_ptr - EFFECT_EDITOR.header.effect_data_ptr
    EFFECT_EDITOR.emitter_count = Parser.calc_emitter_count(particle_size)

    -- Parse particle system and emitters from memory
    -- Header pointer values are relative to base_addr (NOT header_location)
    local particle_addr = base_addr + EFFECT_EDITOR.header.effect_data_ptr
    EFFECT_EDITOR.particle_header = {
        constant = MemUtils.read16(particle_addr + 0x00),
        emitter_count = MemUtils.read16(particle_addr + 0x02),
        gravity_x = MemUtils.read32(particle_addr + 0x04),
        gravity_y = MemUtils.read32(particle_addr + 0x08),
        gravity_z = MemUtils.read32(particle_addr + 0x0C),
        inertia_threshold = MemUtils.read32(particle_addr + 0x10)
    }

    -- Parse emitters from memory
    EFFECT_EDITOR.emitters = Parser.parse_all_emitters_from_memory(
        particle_addr,
        EFFECT_EDITOR.emitter_count
    )

    -- Parse animation curves from memory
    local anim_table_addr = base_addr + EFFECT_EDITOR.header.anim_table_ptr
    EFFECT_EDITOR.curves, EFFECT_EDITOR.curve_count = Parser.parse_curves_from_memory(anim_table_addr)
    EFFECT_EDITOR.original_curves = Parser.copy_curves(EFFECT_EDITOR.curves)
    log(string.format("  Loaded %d animation curves from memory", EFFECT_EDITOR.curve_count))

    -- Parse timeline section from memory
    local timeline_addr = base_addr + EFFECT_EDITOR.header.timeline_section_ptr
    EFFECT_EDITOR.timeline_header = Parser.parse_timeline_header_from_memory(timeline_addr)
    EFFECT_EDITOR.timeline_channels = Parser.parse_all_timeline_channels_from_memory(base_addr, EFFECT_EDITOR.header.timeline_section_ptr)
    EFFECT_EDITOR.original_timeline_header = Parser.copy_timeline_header(EFFECT_EDITOR.timeline_header)
    EFFECT_EDITOR.original_timeline_channels = Parser.copy_timeline_channels(EFFECT_EDITOR.timeline_channels)
    log(string.format("  Loaded timeline header and %d particle channels from memory", #EFFECT_EDITOR.timeline_channels))

    -- Parse camera timeline tables from memory
    EFFECT_EDITOR.camera_tables = Parser.parse_all_camera_tables_from_memory(base_addr, EFFECT_EDITOR.header.timeline_section_ptr)
    EFFECT_EDITOR.original_camera_tables = Parser.copy_camera_tables(EFFECT_EDITOR.camera_tables)
    log(string.format("  Loaded %d camera tables from memory", #EFFECT_EDITOR.camera_tables))

    -- Parse color tracks from memory
    EFFECT_EDITOR.color_tracks = Parser.parse_all_color_tracks_from_memory(base_addr, EFFECT_EDITOR.header.timeline_section_ptr)
    EFFECT_EDITOR.original_color_tracks = Parser.copy_color_tracks(EFFECT_EDITOR.color_tracks)
    log(string.format("  Loaded %d color tracks from memory", #EFFECT_EDITOR.color_tracks))

    -- Parse timing curves from memory
    EFFECT_EDITOR.timing_curves = Parser.parse_timing_curves_from_memory(base_addr, EFFECT_EDITOR.header.timing_curve_ptr)
    EFFECT_EDITOR.original_timing_curves = Parser.copy_timing_curves(EFFECT_EDITOR.timing_curves)
    if EFFECT_EDITOR.timing_curves then
        log("  Loaded timing curves from memory")
    else
        log("  No timing curves (timing_curve_ptr = 0)")
    end

    -- Parse effect flags from memory
    EFFECT_EDITOR.effect_flags = Parser.parse_effect_flags_from_memory(base_addr, EFFECT_EDITOR.header.effect_flags_ptr)
    EFFECT_EDITOR.original_effect_flags = Parser.copy_effect_flags(EFFECT_EDITOR.effect_flags)
    log(string.format("  Loaded effect flags from memory: 0x%02X", EFFECT_EDITOR.effect_flags.flags_byte))

    -- Parse sound flags from memory (effect_flags section bytes 0x08-0x17)
    EFFECT_EDITOR.sound_flags = Parser.parse_sound_flags_from_memory(base_addr, EFFECT_EDITOR.header.effect_flags_ptr)
    EFFECT_EDITOR.original_sound_flags = Parser.copy_sound_flags(EFFECT_EDITOR.sound_flags)
    log("  Loaded 4 sound config channels from memory")

    -- Parse sound definition (feds section) from memory
    local sound_section_size = EFFECT_EDITOR.header.texture_ptr - EFFECT_EDITOR.header.sound_def_ptr
    if sound_section_size > 0 then
        EFFECT_EDITOR.sound_definition = Parser.parse_sound_definition_from_memory(base_addr, EFFECT_EDITOR.header.sound_def_ptr, sound_section_size)
        EFFECT_EDITOR.original_sound_definition = Parser.copy_sound_definition(EFFECT_EDITOR.sound_definition)
        if EFFECT_EDITOR.sound_definition then
            log(string.format("  Loaded feds section: %d channels, resource_id=%d",
                EFFECT_EDITOR.sound_definition.num_channels, EFFECT_EDITOR.sound_definition.resource_id))
        else
            log("  No valid feds section found")
        end
    else
        EFFECT_EDITOR.sound_definition = nil
        EFFECT_EDITOR.original_sound_definition = nil
        log("  No sound definition section (size=0)")
    end

    -- Store original state for structure change detection
    EFFECT_EDITOR.original_emitter_count = EFFECT_EDITOR.emitter_count
    EFFECT_EDITOR.original_header = {
        anim_table_ptr = EFFECT_EDITOR.header.anim_table_ptr,
        timing_curve_ptr = EFFECT_EDITOR.header.timing_curve_ptr,
        effect_flags_ptr = EFFECT_EDITOR.header.effect_flags_ptr,
        timeline_section_ptr = EFFECT_EDITOR.header.timeline_section_ptr,
        sound_def_ptr = EFFECT_EDITOR.header.sound_def_ptr,
        texture_ptr = EFFECT_EDITOR.header.texture_ptr,
    }

    EFFECT_EDITOR.file_name = string.format("Memory @ 0x%08X", base_addr)
    EFFECT_EDITOR.status_msg = string.format("Loaded from memory at 0x%08X (%d emitters, %d curves)",
        base_addr, EFFECT_EDITOR.emitter_count, EFFECT_EDITOR.curve_count)
end

-- Public version - pauses emulator first for safety
function M.load_from_memory(base_addr)
    -- SAFETY: Pause emulator before reading memory
    PCSX.pauseEmulator()
    log("Emulator paused for memory read")

    M.load_from_memory_internal(base_addr)

    print("")
    print("Effect loaded from memory. Emulator is PAUSED.")
    print("Resume with F5/F6 when ready.")
    print("")
end

return M
