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

    if not silent then
        print(string.format("[STRUCT_CHANGE] === apply_structure_changes(0x%08X) ===", base))
        print(string.format("[STRUCT_CHANGE] BEFORE: header.frames=0x%X, animation=0x%X, script=0x%X, effect_data=0x%X",
            header.frames_ptr, header.animation_ptr, header.script_data_ptr, header.effect_data_ptr))
    end

    -- Handle frames structure changes FIRST (frames is at offset 0x00, before everything)
    local frames_delta = StructureManager.calculate_frames_delta(base, silent)
    if frames_delta ~= 0 then
        if not silent then log(string.format("  Frames structure change: %+d bytes", frames_delta)) end
        if not silent then print(string.format("[STRUCT_CHANGE] Applying frames delta: %d bytes", frames_delta)) end
        StructureManager.apply_structure_changes(base, {frames = frames_delta}, header, silent)
        table.insert(applied, "frames structure")
        -- Recalculate sections after frames shift
        EFFECT_EDITOR.sections = Parser.calculate_sections(header)
        if not silent then
            print(string.format("[STRUCT_CHANGE] AFTER frames shift: animation=0x%X, script=0x%X, effect_data=0x%X",
                header.animation_ptr, header.script_data_ptr, header.effect_data_ptr))
        end
    else
        if not silent then print("[STRUCT_CHANGE] No frames structure change needed (delta=0)") end
    end

    -- Handle animation (sequences) structure changes (animation is at offset 0x04, after frames)
    -- DEBUG: Show current memory animation section
    if not silent then
        local mem_anim_ptr = MemUtils.read32(base + 0x04)
        local mem_script_ptr = MemUtils.read32(base + 0x08)
        local mem_section_size = mem_script_ptr - mem_anim_ptr
        local lua_section_size = Parser.calculate_animation_section_size(EFFECT_EDITOR.sequences)
        print(string.format("[STRUCT_CHANGE] Animation section: mem_size=%d, lua_size=%d, delta=%d",
            mem_section_size, lua_section_size, lua_section_size - mem_section_size))
        -- Show original bytes from memory
        local hex_bytes = {}
        for i = 0, math.min(15, mem_section_size - 1) do
            hex_bytes[#hex_bytes + 1] = string.format("%02X", MemUtils.read8(base + mem_anim_ptr + i))
        end
        print(string.format("[STRUCT_CHANGE] Memory anim bytes: %s%s",
            table.concat(hex_bytes, " "), mem_section_size > 16 and " ..." or ""))
    end
    local anim_delta = StructureManager.calculate_animation_delta(base, silent)
    if anim_delta ~= 0 then
        if not silent then log(string.format("  Animation structure change: %+d bytes", anim_delta)) end
        if not silent then print(string.format("[STRUCT_CHANGE] Applying animation delta: %d bytes", anim_delta)) end
        StructureManager.apply_structure_changes(base, {animation = anim_delta}, header, silent)
        table.insert(applied, "animation structure")
        -- Recalculate sections after animation shift
        EFFECT_EDITOR.sections = Parser.calculate_sections(header)
        if not silent then
            print(string.format("[STRUCT_CHANGE] AFTER animation shift: script=0x%X, effect_data=0x%X, anim_table=0x%X",
                header.script_data_ptr, header.effect_data_ptr, header.anim_table_ptr))
        end
    else
        if not silent then print("[STRUCT_CHANGE] No animation structure change needed (delta=0)") end
    end

    -- Handle script structure changes (script comes before effect_data)
    -- Works like emitters: compare memory vs Lua directly, no original tracking needed
    local script_delta = StructureManager.calculate_script_delta(base, silent)
    if script_delta ~= 0 then
        if not silent then log(string.format("  Script structure change: %+d bytes", script_delta)) end
        if not silent then print(string.format("[STRUCT_CHANGE] Applying script delta: %d bytes", script_delta)) end
        StructureManager.apply_structure_changes(base, {script = script_delta}, header, silent)
        table.insert(applied, "script structure")
        -- Recalculate sections after script shift
        EFFECT_EDITOR.sections = Parser.calculate_sections(header)
        if not silent then
            print(string.format("[STRUCT_CHANGE] AFTER: header.script=0x%X, effect_data=0x%X, anim_table=0x%X",
                header.script_data_ptr, header.effect_data_ptr, header.anim_table_ptr))
        end
    else
        if not silent then print("[STRUCT_CHANGE] No script structure change needed (delta=0)") end
    end

    -- Handle emitter structure changes
    local structure_changed = handle_structure_change(silent)
    if structure_changed then
        table.insert(applied, "structure")
    end

    -- Handle timing curve structure changes (add/remove 600-byte section)
    local mem_timing_curve_ptr = MemUtils.read32(base + 0x14)
    local lua_timing_curve_ptr = EFFECT_EDITOR.header.timing_curve_ptr

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

    return applied
end

-- Helper: Write frames section to memory
local function write_frames_section(base, header, silent)
    if not EFFECT_EDITOR.framesets or #EFFECT_EDITOR.framesets == 0 then return {} end

    -- Pass offset_table_count to preserve original layout (including null terminator if present)
    Parser.write_frames_section_to_memory(base, header.frames_ptr, EFFECT_EDITOR.framesets, EFFECT_EDITOR.frames_group_count, EFFECT_EDITOR.frames_offset_table_count)
    local total_frames = 0
    for _, fs in ipairs(EFFECT_EDITOR.framesets) do
        total_frames = total_frames + #fs.frames
    end
    if not silent then log(string.format("  Wrote %d framesets (%d frames), offset_table_count=%d", #EFFECT_EDITOR.framesets, total_frames, EFFECT_EDITOR.frames_offset_table_count or 0)) end
    return {string.format("%d framesets", #EFFECT_EDITOR.framesets)}
end

-- Helper: Write animation (sequences) section to memory
local function write_animation_section(base, header, silent)
    if not EFFECT_EDITOR.sequences or #EFFECT_EDITOR.sequences == 0 then return {} end

    local serialized = Parser.serialize_animation_section(EFFECT_EDITOR.sequences)
    local addr = base + header.animation_ptr

    -- Get target size (set by calculate_animation_delta to handle padding gaps)
    local target_size = EFFECT_EDITOR.animation_section_target_size or #serialized
    local padding_needed = target_size - #serialized

    if not silent then
        print(string.format("[ANIM_WRITE] Writing %d bytes to 0x%08X (animation_ptr=0x%X)",
            #serialized, addr, header.animation_ptr))
        if padding_needed > 0 then
            print(string.format("[ANIM_WRITE] Padding with %d zeros to reach target size %d",
                padding_needed, target_size))
        end
        -- Show first 20 bytes of serialized data
        local hex_preview = {}
        for i = 1, math.min(20, #serialized) do
            hex_preview[i] = string.format("%02X", serialized:byte(i))
        end
        print(string.format("[ANIM_WRITE] First bytes: %s%s",
            table.concat(hex_preview, " "),
            #serialized > 20 and " ..." or ""))
    end

    -- Write serialized data byte by byte
    for i = 1, #serialized do
        MemUtils.write8(addr + i - 1, serialized:byte(i))
    end

    -- Pad with zeros if needed (to fill original section size)
    if padding_needed > 0 then
        for i = 1, padding_needed do
            MemUtils.write8(addr + #serialized + i - 1, 0)
        end
    end

    local total_instructions = 0
    for _, seq in ipairs(EFFECT_EDITOR.sequences) do
        total_instructions = total_instructions + #seq.instructions
    end
    if not silent then log(string.format("  Wrote %d sequences (%d instructions)%s",
        #EFFECT_EDITOR.sequences, total_instructions,
        padding_needed > 0 and string.format(" + %d bytes padding", padding_needed) or "")) end
    return {string.format("%d sequences", #EFFECT_EDITOR.sequences)}
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

    local script_size = Parser.calculate_script_size(EFFECT_EDITOR.script_instructions)
    local section_size = header.effect_data_ptr - header.script_data_ptr

    -- DEBUG: Check for overflow BEFORE writing
    if script_size > section_size then
        print(string.format("[WRITE_SCRIPT] !!! OVERFLOW DETECTED !!! script_size=%d > section_size=%d (overflow by %d bytes)",
            script_size, section_size, script_size - section_size))
        print(string.format("[WRITE_SCRIPT] This will corrupt effect_data! script_ptr=0x%X, effect_data_ptr=0x%X",
            header.script_data_ptr, header.effect_data_ptr))
    end

    if not silent then
        print(string.format("[WRITE_SCRIPT] Writing %d instructions (%d bytes) to base=0x%08X + script_ptr=0x%X = 0x%08X",
            #EFFECT_EDITOR.script_instructions, script_size, base, header.script_data_ptr, base + header.script_data_ptr))
        print(string.format("[WRITE_SCRIPT] Header: script=0x%X, effect_data=0x%X, section_size=%d",
            header.script_data_ptr, header.effect_data_ptr, section_size))
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

    -- CRITICAL: Refresh header pointers from memory before applying changes
    -- After savestate reload, memory has original layout but EFFECT_EDITOR.header
    -- may have stale shifted values from a previous test cycle
    local mem_header = Parser.parse_header_from_memory(base)
    if mem_header then
        -- Update section pointers from memory (these may have been shifted in a previous cycle)
        EFFECT_EDITOR.header.frames_ptr = mem_header.frames_ptr
        EFFECT_EDITOR.header.animation_ptr = mem_header.animation_ptr
        EFFECT_EDITOR.header.script_data_ptr = mem_header.script_data_ptr
        EFFECT_EDITOR.header.effect_data_ptr = mem_header.effect_data_ptr
        EFFECT_EDITOR.header.anim_table_ptr = mem_header.anim_table_ptr
        -- NOTE: timing_curve_ptr is intentionally NOT refreshed from memory
        -- The Lua header value represents user intent (wanting timing curves)
        -- Memory value after savestate reload is 0 (original state without timing curves)
        -- The timing curve handler will add the section if lua_ptr != 0 && mem_ptr == 0
        EFFECT_EDITOR.header.effect_flags_ptr = mem_header.effect_flags_ptr
        EFFECT_EDITOR.header.timeline_section_ptr = mem_header.timeline_section_ptr
        EFFECT_EDITOR.header.sound_def_ptr = mem_header.sound_def_ptr
        EFFECT_EDITOR.header.texture_ptr = mem_header.texture_ptr
        if not silent then
            print(string.format("[APPLY_EDITS] Refreshed header from memory: frames=0x%X, animation=0x%X, effect_data=0x%X (timing_curve_ptr preserved: 0x%X)",
                EFFECT_EDITOR.header.frames_ptr, EFFECT_EDITOR.header.animation_ptr, EFFECT_EDITOR.header.effect_data_ptr, EFFECT_EDITOR.header.timing_curve_ptr))
        end
    end

    local header = EFFECT_EDITOR.header
    local applied = {}

    -- Phase 1: Structure changes (shifts memory, updates pointers)
    for _, item in ipairs(apply_structure_changes(base, silent)) do
        table.insert(applied, item)
    end

    -- Phase 2: Write all data sections
    -- Frames section (first in file order)
    for _, item in ipairs(write_frames_section(base, header, silent)) do
        table.insert(applied, item)
    end

    -- Animation (sequences) section (after frames, before script)
    for _, item in ipairs(write_animation_section(base, header, silent)) do
        table.insert(applied, item)
    end
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
-- Unified Loader Infrastructure
--------------------------------------------------------------------------------

-- Create dispatch table for parser functions
-- source_type: "file" or "memory"
-- source: file data string (file) or base address (memory)
local function get_parser_dispatch(source_type, source)
    if source_type == "file" then
        return {
            parse_header = function()
                return Parser.parse_header_from_data(source)
            end,
            parse_frames = function(offset, size)
                return Parser.parse_frames_section_from_data(source, offset, size)
            end,
            parse_animation = function(offset, size)
                return Parser.parse_animation_section_from_data(source, offset, size)
            end,
            parse_script = function(offset, size)
                return Parser.parse_script_from_data(source, offset, size)
            end,
            parse_particle_header = function(offset)
                return Parser.parse_particle_header_from_data(source, offset)
            end,
            parse_all_emitters = function(offset, count)
                return Parser.parse_all_emitters(source, offset, count)
            end,
            parse_curves = function(offset)
                return Parser.parse_curves_from_data(source, offset)
            end,
            parse_timeline_header = function(offset)
                return Parser.parse_timeline_header_from_data(source, offset)
            end,
            parse_all_timeline_channels = function(offset)
                return Parser.parse_all_timeline_channels(source, offset)
            end,
            parse_all_camera_tables = function(offset)
                return Parser.parse_all_camera_tables(source, offset)
            end,
            parse_all_color_tracks = function(offset)
                return Parser.parse_all_color_tracks(source, offset)
            end,
            parse_timing_curves = function(offset)
                return Parser.parse_timing_curves_from_data(source, offset)
            end,
            parse_effect_flags = function(offset)
                return Parser.parse_effect_flags_from_data(source, offset)
            end,
            parse_sound_flags = function(offset)
                return Parser.parse_sound_flags_from_data(source, offset)
            end,
            parse_sound_definition = function(offset, size)
                return Parser.parse_sound_definition_from_data(source, offset, size)
            end,
        }
    else
        -- Memory source
        return {
            parse_header = function()
                return Parser.parse_header_from_memory(source)
            end,
            parse_frames = function(offset, size)
                return Parser.parse_frames_section_from_memory(source, offset, size)
            end,
            parse_animation = function(offset, size)
                return Parser.parse_animation_section_from_memory(source, offset, size)
            end,
            parse_script = function(offset, size)
                return Parser.parse_script_from_memory(source, offset, size)
            end,
            parse_particle_header = function(offset)
                -- No Parser function for memory - inline read
                local addr = source + offset
                return {
                    constant = MemUtils.read16(addr + 0x00),
                    emitter_count = MemUtils.read16(addr + 0x02),
                    gravity_x = MemUtils.read32(addr + 0x04),
                    gravity_y = MemUtils.read32(addr + 0x08),
                    gravity_z = MemUtils.read32(addr + 0x0C),
                    inertia_threshold = MemUtils.read32(addr + 0x10)
                }
            end,
            parse_all_emitters = function(offset, count)
                return Parser.parse_all_emitters_from_memory(source + offset, count)
            end,
            parse_curves = function(offset)
                return Parser.parse_curves_from_memory(source + offset)
            end,
            parse_timeline_header = function(offset)
                return Parser.parse_timeline_header_from_memory(source + offset)
            end,
            parse_all_timeline_channels = function(offset)
                return Parser.parse_all_timeline_channels_from_memory(source, offset)
            end,
            parse_all_camera_tables = function(offset)
                return Parser.parse_all_camera_tables_from_memory(source, offset)
            end,
            parse_all_color_tracks = function(offset)
                return Parser.parse_all_color_tracks_from_memory(source, offset)
            end,
            parse_timing_curves = function(offset)
                return Parser.parse_timing_curves_from_memory(source, offset)
            end,
            parse_effect_flags = function(offset)
                return Parser.parse_effect_flags_from_memory(source, offset)
            end,
            parse_sound_flags = function(offset)
                return Parser.parse_sound_flags_from_memory(source, offset)
            end,
            parse_sound_definition = function(offset, size)
                return Parser.parse_sound_definition_from_memory(source, offset, size)
            end,
        }
    end
end

-- Parse all effect sections using dispatch table
-- parsers: dispatch table from get_parser_dispatch
-- log_fn: logging function to use
local function parse_all_sections(parsers, log_fn)
    local header = EFFECT_EDITOR.header

    -- Frames section
    local frames_size = header.animation_ptr - header.frames_ptr
    EFFECT_EDITOR.framesets, EFFECT_EDITOR.frames_group_count, EFFECT_EDITOR.frames_offset_table_count =
        parsers.parse_frames(header.frames_ptr, frames_size)
    EFFECT_EDITOR.original_framesets = Parser.copy_framesets(EFFECT_EDITOR.framesets)
    local total_frames = 0
    for _, fs in ipairs(EFFECT_EDITOR.framesets) do total_frames = total_frames + #fs.frames end
    log_fn(string.format("  Loaded %d framesets (%d frames), %d groups",
        #EFFECT_EDITOR.framesets, total_frames, EFFECT_EDITOR.frames_group_count))

    -- Animation (sequences) section
    local anim_size = header.script_data_ptr - header.animation_ptr
    EFFECT_EDITOR.sequences, EFFECT_EDITOR.sequence_count = parsers.parse_animation(header.animation_ptr, anim_size)
    EFFECT_EDITOR.original_sequences = Parser.copy_sequences(EFFECT_EDITOR.sequences)
    local total_instr = 0
    for _, seq in ipairs(EFFECT_EDITOR.sequences) do total_instr = total_instr + #seq.instructions end
    log_fn(string.format("  Loaded %d sequences (%d instructions)", #EFFECT_EDITOR.sequences, total_instr))

    -- Script bytecode
    local script_size = header.effect_data_ptr - header.script_data_ptr
    EFFECT_EDITOR.script_instructions = parsers.parse_script(header.script_data_ptr, script_size)
    EFFECT_EDITOR.original_script_instructions = Parser.copy_script_instructions(EFFECT_EDITOR.script_instructions)
    log_fn(string.format("  Loaded %d script instructions (%d bytes)", #EFFECT_EDITOR.script_instructions, script_size))

    -- Particle system (header + emitters)
    local particle_size = header.anim_table_ptr - header.effect_data_ptr
    EFFECT_EDITOR.emitter_count = Parser.calc_emitter_count(particle_size)
    EFFECT_EDITOR.particle_header = parsers.parse_particle_header(header.effect_data_ptr)
    EFFECT_EDITOR.emitters = parsers.parse_all_emitters(header.effect_data_ptr, EFFECT_EDITOR.emitter_count)
    log_fn(string.format("  Loaded particle header + %d emitters", EFFECT_EDITOR.emitter_count))

    -- Animation curves
    EFFECT_EDITOR.curves, EFFECT_EDITOR.curve_count = parsers.parse_curves(header.anim_table_ptr)
    EFFECT_EDITOR.original_curves = Parser.copy_curves(EFFECT_EDITOR.curves)
    log_fn(string.format("  Loaded %d animation curves", EFFECT_EDITOR.curve_count))

    -- Timeline section (header + channels)
    EFFECT_EDITOR.timeline_header = parsers.parse_timeline_header(header.timeline_section_ptr)
    EFFECT_EDITOR.timeline_channels = parsers.parse_all_timeline_channels(header.timeline_section_ptr)
    EFFECT_EDITOR.original_timeline_header = Parser.copy_timeline_header(EFFECT_EDITOR.timeline_header)
    EFFECT_EDITOR.original_timeline_channels = Parser.copy_timeline_channels(EFFECT_EDITOR.timeline_channels)
    log_fn(string.format("  Loaded timeline header + %d channels", #EFFECT_EDITOR.timeline_channels))

    -- Camera tables
    EFFECT_EDITOR.camera_tables = parsers.parse_all_camera_tables(header.timeline_section_ptr)
    EFFECT_EDITOR.original_camera_tables = Parser.copy_camera_tables(EFFECT_EDITOR.camera_tables)
    log_fn(string.format("  Loaded %d camera tables", #EFFECT_EDITOR.camera_tables))

    -- Color tracks
    EFFECT_EDITOR.color_tracks = parsers.parse_all_color_tracks(header.timeline_section_ptr)
    EFFECT_EDITOR.original_color_tracks = Parser.copy_color_tracks(EFFECT_EDITOR.color_tracks)
    log_fn(string.format("  Loaded %d color tracks", #EFFECT_EDITOR.color_tracks))

    -- Timing curves (may be nil)
    EFFECT_EDITOR.timing_curves = parsers.parse_timing_curves(header.timing_curve_ptr)
    EFFECT_EDITOR.original_timing_curves = Parser.copy_timing_curves(EFFECT_EDITOR.timing_curves)
    if EFFECT_EDITOR.timing_curves then
        log_fn("  Loaded timing curves")
    else
        log_fn("  No timing curves (ptr=0)")
    end

    -- Effect flags
    EFFECT_EDITOR.effect_flags = parsers.parse_effect_flags(header.effect_flags_ptr)
    EFFECT_EDITOR.original_effect_flags = Parser.copy_effect_flags(EFFECT_EDITOR.effect_flags)
    log_fn(string.format("  Loaded effect flags: 0x%02X", EFFECT_EDITOR.effect_flags.flags_byte))

    -- Sound flags
    EFFECT_EDITOR.sound_flags = parsers.parse_sound_flags(header.effect_flags_ptr)
    EFFECT_EDITOR.original_sound_flags = Parser.copy_sound_flags(EFFECT_EDITOR.sound_flags)
    log_fn("  Loaded 4 sound config channels")

    -- Sound definition (feds section)
    local sound_size = header.texture_ptr - header.sound_def_ptr
    if sound_size > 0 then
        EFFECT_EDITOR.sound_definition = parsers.parse_sound_definition(header.sound_def_ptr, sound_size)
        EFFECT_EDITOR.original_sound_definition = Parser.copy_sound_definition(EFFECT_EDITOR.sound_definition)
        if EFFECT_EDITOR.sound_definition then
            log_fn(string.format("  Loaded feds: %d channels, resource_id=%d",
                EFFECT_EDITOR.sound_definition.num_channels, EFFECT_EDITOR.sound_definition.resource_id))
        else
            log_fn("  No valid feds section")
        end
    else
        EFFECT_EDITOR.sound_definition = nil
        EFFECT_EDITOR.original_sound_definition = nil
        log_fn("  No sound definition (size=0)")
    end

    -- Store original state for structure change detection
    EFFECT_EDITOR.original_emitter_count = EFFECT_EDITOR.emitter_count
    EFFECT_EDITOR.original_header = {
        anim_table_ptr = header.anim_table_ptr,
        timing_curve_ptr = header.timing_curve_ptr,
        effect_flags_ptr = header.effect_flags_ptr,
        timeline_section_ptr = header.timeline_section_ptr,
        sound_def_ptr = header.sound_def_ptr,
        texture_ptr = header.texture_ptr,
    }
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

    -- Parse header and all sections using dispatch
    local parsers = get_parser_dispatch("file", data)
    EFFECT_EDITOR.header = parsers.parse_header()
    EFFECT_EDITOR.sections = Parser.calculate_sections(EFFECT_EDITOR.header)
    parse_all_sections(parsers, log_verbose)

    local msg = string.format("Loaded %s (%d bytes, %s format, %d emitters, %d curves)",
        filename, #data, EFFECT_EDITOR.header.format, EFFECT_EDITOR.emitter_count, EFFECT_EDITOR.curve_count)
    log(msg)
    EFFECT_EDITOR.status_msg = msg

    log_verbose(string.format("  frames_ptr: 0x%X, effect_data_ptr: 0x%X, anim_table_ptr: 0x%X",
        EFFECT_EDITOR.header.frames_ptr, EFFECT_EDITOR.header.effect_data_ptr, EFFECT_EDITOR.header.anim_table_ptr))

    return true
end

--------------------------------------------------------------------------------
-- Memory Loading
--------------------------------------------------------------------------------

-- Internal version - assumes emulator is already paused
function M.load_from_memory_internal(base_addr)
    log(string.format("Loading from memory at 0x%08X", base_addr))
    MemUtils.refresh_mem()

    EFFECT_EDITOR.memory_base = base_addr

    -- Parse header and all sections using dispatch
    local parsers = get_parser_dispatch("memory", base_addr)
    EFFECT_EDITOR.header = parsers.parse_header()
    EFFECT_EDITOR.sections = Parser.calculate_sections(EFFECT_EDITOR.header)
    parse_all_sections(parsers, log)

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

--------------------------------------------------------------------------------
-- Debug: Dump section boundaries and sizes
--------------------------------------------------------------------------------
function M.debug_sections()
    local base = EFFECT_EDITOR.memory_base
    local header = EFFECT_EDITOR.header

    if not base or base < 0x80000000 then
        print("[DEBUG] No valid memory base")
        return
    end

    print("=== SECTION BOUNDARIES (Lua header) ===")
    print(string.format("Base: 0x%08X", base))
    print("")

    local sections = {
        {name = "frames",      ptr = header.frames_ptr},
        {name = "animation",   ptr = header.animation_ptr},
        {name = "script",      ptr = header.script_data_ptr},
        {name = "effect_data", ptr = header.effect_data_ptr},
        {name = "anim_table",  ptr = header.anim_table_ptr},
        {name = "timing",      ptr = header.timing_curve_ptr},
        {name = "flags",       ptr = header.effect_flags_ptr},
        {name = "timeline",    ptr = header.timeline_section_ptr},
        {name = "sound_def",   ptr = header.sound_def_ptr},
        {name = "texture",     ptr = header.texture_ptr},
    }

    for i, sec in ipairs(sections) do
        local next_ptr = sections[i + 1] and sections[i + 1].ptr or nil
        local size_str = ""
        if next_ptr and next_ptr > 0 and sec.ptr > 0 then
            size_str = string.format(" (size=%d)", next_ptr - sec.ptr)
        end
        print(string.format("  %-12s: 0x%04X%s", sec.name, sec.ptr or 0, size_str))
    end

    -- Check Lua data sizes vs section sizes
    print("")
    print("=== LUA DATA SIZES vs SECTION SIZES ===")

    if EFFECT_EDITOR.sequences then
        local lua_anim_size = Parser.calculate_animation_section_size(EFFECT_EDITOR.sequences)
        local section_size = header.script_data_ptr - header.animation_ptr
        local status = lua_anim_size <= section_size and "OK" or "OVERFLOW!"
        print(string.format("  animation: lua=%d, section=%d [%s]", lua_anim_size, section_size, status))
    end

    if EFFECT_EDITOR.script_instructions then
        local lua_script_size = Parser.calculate_script_size(EFFECT_EDITOR.script_instructions)
        local section_size = header.effect_data_ptr - header.script_data_ptr
        local status = lua_script_size <= section_size and "OK" or "OVERFLOW!"
        print(string.format("  script:    lua=%d, section=%d [%s]", lua_script_size, section_size, status))
    end

    if EFFECT_EDITOR.emitters then
        local lua_effect_size = 0x14 + #EFFECT_EDITOR.emitters * 0xC4
        local section_size = header.anim_table_ptr - header.effect_data_ptr
        local status = lua_effect_size <= section_size and "OK" or "OVERFLOW!"
        print(string.format("  effect:    lua=%d, section=%d [%s]", lua_effect_size, section_size, status))
    end

    -- Dump first 16 bytes of effect_data from memory
    print("")
    print("=== EFFECT_DATA HEADER (first 20 bytes from memory) ===")
    local effect_addr = base + header.effect_data_ptr
    local hex = {}
    for i = 0, 19 do
        hex[#hex + 1] = string.format("%02X", MemUtils.read8(effect_addr + i))
    end
    print(string.format("  0x%08X: %s", effect_addr, table.concat(hex, " ")))
    print(string.format("  constant:      0x%04X", MemUtils.read16(effect_addr + 0)))
    print(string.format("  emitter_count: %d", MemUtils.read16(effect_addr + 2)))
end

return M
