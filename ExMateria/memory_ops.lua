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

function M.set_dependencies(mem_utils, parser, cfg, log_fn, verbose_fn, error_fn)
    MemUtils = mem_utils
    Parser = parser
    config = cfg
    log = log_fn
    log_verbose = verbose_fn
    log_error = error_fn
end

--------------------------------------------------------------------------------
-- Memory Region Shifting (for structure changes)
--------------------------------------------------------------------------------

-- Shift a region of memory by delta bytes
-- Handles overlap correctly: forward shifts copy end-to-start, backward copy start-to-end
local function shift_memory_region(src_start, src_end, delta)
    if delta == 0 then return end

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

-- Handle structure changes (emitter count changed)
-- Returns true if structure was modified and sections were shifted
-- silent: if true, suppress status logging
local function handle_structure_change(silent)
    log_verbose("  [DEBUG] handle_structure_change called")
    log_verbose(string.format("  [DEBUG] #emitters = %d", EFFECT_EDITOR.emitters and #EFFECT_EDITOR.emitters or 0))

    -- ALWAYS read current memory layout - this correctly detects changes after savestate reload
    -- (Previously we cached original_emitter_count which became stale after savestate reload)
    local base = EFFECT_EDITOR.memory_base
    local mem_effect_data_ptr = MemUtils.read32(base + 0x0C)
    local mem_anim_table_ptr = MemUtils.read32(base + 0x10)

    -- Calculate emitter count from memory layout (space available for emitters)
    local particle_section_size = mem_anim_table_ptr - mem_effect_data_ptr
    local mem_emitter_count = math.floor((particle_section_size - 0x14) / 0xC4)

    log_verbose(string.format("  [DEBUG] Memory layout: effect_data=0x%X, anim_table=0x%X", mem_effect_data_ptr, mem_anim_table_ptr))
    log_verbose(string.format("  [DEBUG] Memory has room for %d emitters", mem_emitter_count))

    -- Store current memory header pointers (needed for shifting)
    local memory_header = {
        anim_table_ptr = mem_anim_table_ptr,
        timing_curve_ptr = MemUtils.read32(base + 0x14),
        effect_flags_ptr = MemUtils.read32(base + 0x18),
        timeline_section_ptr = MemUtils.read32(base + 0x1C),
        sound_def_ptr = MemUtils.read32(base + 0x20),
        texture_ptr = MemUtils.read32(base + 0x24),
    }

    local current_count = #EFFECT_EDITOR.emitters
    local original_count = mem_emitter_count  -- Use ACTUAL memory layout, not cached value

    log_verbose(string.format("  [DEBUG] Comparing: Lua has %d emitters vs memory has room for %d", current_count, original_count))

    if current_count == original_count then
        log_verbose("  [DEBUG] Counts match - no structure change needed")
        return false
    end

    log_verbose(string.format("  [DEBUG] STRUCTURE CHANGE DETECTED: %d -> %d", original_count, current_count))

    local delta = (current_count - original_count) * 0xC4  -- 196 bytes per emitter
    local header = EFFECT_EDITOR.header

    if not silent then log(string.format("  Structure change: %d -> %d emitters (delta=%d bytes)",
        original_count, current_count, delta)) end

    -- Debug: show memory vs Lua header pointers
    log_verbose(string.format("  [DEBUG] memory anim_table_ptr = 0x%X", memory_header.anim_table_ptr))
    log_verbose(string.format("  [DEBUG] Lua header.anim_table_ptr = 0x%X", header.anim_table_ptr))
    log_verbose(string.format("  [DEBUG] effect_data_ptr = 0x%X", mem_effect_data_ptr))

    -- Calculate the region to shift: from current memory anim_table_ptr to a safe end
    -- Use memory_header (actual PSX memory state) for shift source
    local shift_start = base + memory_header.anim_table_ptr
    local shift_end = base + memory_header.anim_table_ptr + 0x10000  -- Shift 64KB to be safe

    log_verbose(string.format("  [DEBUG] Shifting memory from 0x%08X to 0x%08X by %d bytes",
        shift_start, shift_end, delta))
    log_verbose(string.format("  [DEBUG] This is %d bytes to shift", shift_end - shift_start))

    -- Shift the memory region
    shift_memory_region(shift_start, shift_end, delta)

    -- Update Lua header pointers to match new memory layout
    header.anim_table_ptr = memory_header.anim_table_ptr + delta
    if memory_header.timing_curve_ptr ~= 0 then
        header.timing_curve_ptr = memory_header.timing_curve_ptr + delta
    end
    header.effect_flags_ptr = memory_header.effect_flags_ptr + delta
    header.timeline_section_ptr = memory_header.timeline_section_ptr + delta
    header.sound_def_ptr = memory_header.sound_def_ptr + delta
    header.texture_ptr = memory_header.texture_ptr + delta

    -- Write updated header pointers to the FILE DATA in memory
    -- (The game's init code will set globals from these when it runs caseD_3)
    MemUtils.write32(base + 0x10, header.anim_table_ptr)
    -- Only write timing_curve_ptr if it existed in memory (let timing curve handler manage add/remove)
    if memory_header.timing_curve_ptr ~= 0 then
        MemUtils.write32(base + 0x14, header.timing_curve_ptr)
    end
    MemUtils.write32(base + 0x18, header.effect_flags_ptr)
    MemUtils.write32(base + 0x1C, header.timeline_section_ptr)
    MemUtils.write32(base + 0x20, header.sound_def_ptr)
    MemUtils.write32(base + 0x24, header.texture_ptr)

    -- EARLY CAPTURE STRATEGY (2024-12):
    -- We now capture at the START of caseD_3 (0x801a1964), BEFORE the game
    -- sets up any header-based globals. When we reload the savestate and apply
    -- edits, we're back at that point - the game hasn't read the header yet.
    --
    -- By modifying the HEADER VALUES in the file data (above), when the game
    -- resumes and executes caseD_3, it will read our modified header and set
    -- ALL globals correctly. This is cleaner than manually updating globals
    -- because:
    --   1. We don't need to track every global variable
    --   2. We can't miss any globals (game handles all of them)
    --   3. Works correctly for any effect file
    --
    -- The old approach captured DURING caseD_3 (when effect_data_ptr was written),
    -- which meant some globals were already set. We had to manually update them
    -- all, and we missed some (causing the emitter append particle spawn bug).
    --
    -- NO MANUAL GLOBAL UPDATES NEEDED - the game does this automatically!

    -- DEBUG: Verify timeline header values at the new location (verbose only)
    local new_timeline_section = base + header.timeline_section_ptr
    log_verbose("  [DEBUG] Timeline header verification at new location:")
    log_verbose(string.format("    phase1_duration (timeline+4): %d", MemUtils.read16(new_timeline_section + 4)))
    log_verbose(string.format("    spawn_delay (timeline+6): %d", MemUtils.read16(new_timeline_section + 6)))
    log_verbose(string.format("    unknown_08 (timeline+8): %d", MemUtils.read16(new_timeline_section + 8)))
    log_verbose(string.format("    phase2_delay (timeline+10): %d", MemUtils.read16(new_timeline_section + 10)))

    -- Update particle_header.emitter_count in memory
    local particle_base = base + mem_effect_data_ptr
    MemUtils.write16(particle_base + 0x02, current_count)

    -- Update Lua tracking state
    EFFECT_EDITOR.emitter_count = current_count
    EFFECT_EDITOR.particle_header.emitter_count = current_count

    -- Recalculate sections
    EFFECT_EDITOR.sections = Parser.calculate_sections(header)

    log_verbose(string.format("  [DEBUG] Updated header pointers. New anim_table_ptr=0x%X", header.anim_table_ptr))
    log_verbose(string.format("  [DEBUG] New timeline_section_ptr=0x%X", header.timeline_section_ptr))
    log_verbose("  [DEBUG] Structure change complete - shift done")

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

        -- Shift memory forward by 600 bytes
        if not silent then
            log(string.format("  Shifting memory from 0x%08X forward by %d bytes", shift_start, TIMING_SECTION_SIZE))
        end
        shift_memory_region(shift_start, shift_end, TIMING_SECTION_SIZE)

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

        -- Shift memory backward by 600 bytes (starting from effect_flags)
        local shift_start = base + mem_effect_flags_ptr
        local shift_end = shift_start + 0x10000
        if not silent then
            log(string.format("  Shifting memory from 0x%08X backward by %d bytes", shift_start, TIMING_SECTION_SIZE))
        end
        shift_memory_region(shift_start, shift_end, -TIMING_SECTION_SIZE)

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

-- Apply ALL edits (particle header + emitters + curves) to memory
-- This is THE function to use when applying changes - ensures everything is in sync
-- silent: if true, skip user-facing prints (used during automated operations)
function M.apply_all_edits_to_memory(silent)
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        log_error("No valid memory base address set. Load from memory first or set address.")
        return false
    end

    -- SAFETY: Pause emulator before writing memory
    PCSX.pauseEmulator()
    if not silent then log("Applying all edits to memory...") end

    MemUtils.refresh_mem()

    local applied = {}

    -- Debug: Show actual memory layout BEFORE any modifications
    local base = EFFECT_EDITOR.memory_base
    local mem_effect_data_ptr = MemUtils.read32(base + 0x0C)
    local mem_anim_table_ptr = MemUtils.read32(base + 0x10)
    local mem_emitter_count = MemUtils.read16(base + mem_effect_data_ptr + 0x02)
    local space_for_emitters = mem_anim_table_ptr - mem_effect_data_ptr - 0x14
    local max_emitters_that_fit = math.floor(space_for_emitters / 0xC4)

    -- Debug: memory layout (verbose only)
    log_verbose("  [DEBUG] === MEMORY LAYOUT BEFORE MODIFICATIONS ===")
    log_verbose(string.format("  [DEBUG] effect_data_ptr in memory: 0x%X", mem_effect_data_ptr))
    log_verbose(string.format("  [DEBUG] anim_table_ptr in memory: 0x%X", mem_anim_table_ptr))
    log_verbose(string.format("  [DEBUG] emitter_count in memory (at effect_data_ptr+0x02): %d", mem_emitter_count))
    log_verbose(string.format("  [DEBUG] Space between effect_data+0x14 and anim_table: 0x%X bytes", space_for_emitters))
    log_verbose(string.format("  [DEBUG] Max emitters that fit in this space: %d", max_emitters_that_fit))
    log_verbose(string.format("  [DEBUG] Lua has %d emitters", #EFFECT_EDITOR.emitters))

    if #EFFECT_EDITOR.emitters > max_emitters_that_fit then
        log_verbose(string.format("  [DEBUG] !!! NEED TO SHIFT: Lua has %d emitters but only room for %d !!!",
            #EFFECT_EDITOR.emitters, max_emitters_that_fit))
    else
        log_verbose(string.format("  [DEBUG] OK: Lua has %d emitters, room for %d - NO SHIFT NEEDED",
            #EFFECT_EDITOR.emitters, max_emitters_that_fit))
    end

    -- Handle structure changes (emitter count changed) FIRST
    -- This shifts sections and updates header pointers before we write data
    local structure_changed = handle_structure_change(silent)
    if structure_changed then
        table.insert(applied, "structure")
    end

    -- Handle timing curve structure changes (add/remove 600-byte section)
    -- Must happen AFTER emitter structure changes but BEFORE writing data
    local mem_timing_curve_ptr = MemUtils.read32(base + 0x14)
    local lua_timing_curve_ptr = EFFECT_EDITOR.header.timing_curve_ptr

    -- Log timing curve state (verbose only)
    log_verbose(string.format("  Timing: lua_ptr=0x%X, mem_ptr=0x%X, has_data=%s",
        lua_timing_curve_ptr or 0, mem_timing_curve_ptr or 0,
        EFFECT_EDITOR.timing_curves and "yes" or "no"))

    if lua_timing_curve_ptr ~= 0 and mem_timing_curve_ptr == 0 then
        -- Lua wants timing curves but memory doesn't have them - add section
        if not silent then log("  Timing curve structure change: ADDING 600-byte section") end
        local timing_changed = handle_timing_curve_structure_change("add", silent)
        if timing_changed then
            table.insert(applied, "timing structure (add)")
            if not silent then log(string.format("  New timing_curve_ptr: 0x%X", EFFECT_EDITOR.header.timing_curve_ptr)) end
        end
    elseif lua_timing_curve_ptr == 0 and mem_timing_curve_ptr ~= 0 then
        -- Lua doesn't want timing curves but memory has them - remove section
        if not silent then log("  Timing curve structure change: REMOVING section") end
        local timing_changed = handle_timing_curve_structure_change("remove", silent)
        if timing_changed then
            table.insert(applied, "timing structure (remove)")
        end
    end

    -- Apply particle header (gravity, inertia threshold)
    if EFFECT_EDITOR.particle_header then
        local particle_base = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.effect_data_ptr
        local ph = EFFECT_EDITOR.particle_header
        MemUtils.write32(particle_base + 0x04, ph.gravity_x)
        MemUtils.write32(particle_base + 0x08, ph.gravity_y)
        MemUtils.write32(particle_base + 0x0C, ph.gravity_z)
        MemUtils.write32(particle_base + 0x10, ph.inertia_threshold)
        table.insert(applied, "header")
        if not silent then log(string.format("  Header: gravity=(%d,%d,%d) inertia=%d",
            ph.gravity_x, ph.gravity_y, ph.gravity_z, ph.inertia_threshold)) end
    end

    -- Apply emitters
    if EFFECT_EDITOR.emitters and #EFFECT_EDITOR.emitters > 0 then
        local particle_base = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.effect_data_ptr
        local last_emitter_end = particle_base + 0x14 + (#EFFECT_EDITOR.emitters * 0xC4)
        local anim_table_addr = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.anim_table_ptr

        -- Debug: emitter write info (verbose only)
        log_verbose(string.format("  [DEBUG] particle_base = 0x%08X (effect_data_ptr = 0x%X)",
            particle_base, EFFECT_EDITOR.header.effect_data_ptr))
        log_verbose(string.format("  [DEBUG] Writing emitters to 0x%08X - 0x%08X",
            particle_base + 0x14, last_emitter_end))
        log_verbose(string.format("  [DEBUG] anim_table_ptr is at 0x%08X", anim_table_addr))

        if last_emitter_end > anim_table_addr then
            log_error(string.format("  [DEBUG] WARNING: Emitters would overwrite curves! End=0x%08X, Curves=0x%08X",
                last_emitter_end, anim_table_addr))
        end

        -- Debug: Log each emitter's index and write position (verbose only)
        log_verbose("  [DEBUG] Emitter write positions:")
        for i, e in ipairs(EFFECT_EDITOR.emitters) do
            local emitter_addr = particle_base + 0x14 + (e.index * 0xC4)
            log_verbose(string.format("    [%d] Lua array pos=%d, emitter.index=%d, write_addr=0x%08X, anim_index=%d",
                i, i, e.index, emitter_addr, e.anim_index or -1))
        end

        for _, e in ipairs(EFFECT_EDITOR.emitters) do
            Parser.write_emitter_to_memory(particle_base, e.index, e)
        end
        table.insert(applied, string.format("%d emitters", #EFFECT_EDITOR.emitters))
        if not silent then log(string.format("  Wrote %d emitters", #EFFECT_EDITOR.emitters)) end

        -- Verify writes by reading back anim_index (verbose only)
        log_verbose("  [DEBUG] Verification - reading back anim_index from each emitter:")
        for i = 0, #EFFECT_EDITOR.emitters - 1 do
            local emitter_addr = particle_base + 0x14 + (i * 0xC4)
            local anim_index = MemUtils.read8(emitter_addr + 0x01)
            local expected = EFFECT_EDITOR.emitters[i + 1].anim_index
            local match = (anim_index == expected) and "OK" or "MISMATCH!"
            log_verbose(string.format("    Emitter %d @ 0x%08X: anim_index=%d (expected %d) %s",
                i, emitter_addr, anim_index, expected or -1, match))
        end
    end

    -- Apply curves
    if EFFECT_EDITOR.curves and #EFFECT_EDITOR.curves > 0 then
        local anim_table_addr = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.anim_table_ptr
        Parser.write_all_curves_to_memory(anim_table_addr, EFFECT_EDITOR.curves)
        table.insert(applied, string.format("%d curves", #EFFECT_EDITOR.curves))
        if not silent then log(string.format("  Wrote %d curves to 0x%08X", #EFFECT_EDITOR.curves, anim_table_addr)) end
    end

    -- Apply timeline header and channels
    if EFFECT_EDITOR.timeline_header and EFFECT_EDITOR.timeline_channels then
        local timeline_addr = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.timeline_section_ptr
        -- Debug: timeline info (verbose only)
        log_verbose(string.format("  [DEBUG] timeline_section_ptr = 0x%X, timeline_addr = 0x%08X",
            EFFECT_EDITOR.header.timeline_section_ptr, timeline_addr))

        -- Debug: Log which emitters each active timeline channel references
        log_verbose("  [DEBUG] Timeline channel emitter references:")
        for i, ch in ipairs(EFFECT_EDITOR.timeline_channels) do
            -- Find first active keyframe emitter_id
            local active_emitters = {}
            if ch.keyframes then
                for k = 1, ch.max_keyframe + 1 do
                    local kf = ch.keyframes[k]
                    if kf and kf.emitter_id and kf.emitter_id > 0 then
                        active_emitters[kf.emitter_id] = true
                    end
                end
            end
            local emitter_list = ""
            for eid, _ in pairs(active_emitters) do
                emitter_list = emitter_list .. tostring(eid) .. " "
            end
            if emitter_list ~= "" then
                log_verbose(string.format("    Channel %d (%s[%d]): max_kf=%d, emitters=[%s]",
                    i, ch.context or "?", ch.channel_index or 0, ch.max_keyframe or 0, emitter_list))
            end
        end

        Parser.write_timeline_header_to_memory(timeline_addr, EFFECT_EDITOR.timeline_header)
        Parser.write_all_timeline_channels_to_memory(EFFECT_EDITOR.memory_base, EFFECT_EDITOR.header.timeline_section_ptr, EFFECT_EDITOR.timeline_channels)
        table.insert(applied, string.format("%d timeline channels", #EFFECT_EDITOR.timeline_channels))
        if not silent then log(string.format("  Wrote timeline header and %d channels", #EFFECT_EDITOR.timeline_channels)) end
    end

    -- Apply camera timeline tables
    if EFFECT_EDITOR.camera_tables and #EFFECT_EDITOR.camera_tables > 0 then
        Parser.write_all_camera_tables_to_memory(EFFECT_EDITOR.memory_base, EFFECT_EDITOR.header.timeline_section_ptr, EFFECT_EDITOR.camera_tables)
        table.insert(applied, string.format("%d camera tables", #EFFECT_EDITOR.camera_tables))
        if not silent then log(string.format("  Wrote %d camera tables", #EFFECT_EDITOR.camera_tables)) end
    end

    -- Apply color tracks
    if EFFECT_EDITOR.color_tracks and #EFFECT_EDITOR.color_tracks > 0 then
        Parser.write_all_color_tracks_to_memory(EFFECT_EDITOR.memory_base, EFFECT_EDITOR.header.timeline_section_ptr, EFFECT_EDITOR.color_tracks)
        table.insert(applied, string.format("%d color tracks", #EFFECT_EDITOR.color_tracks))
        if not silent then log(string.format("  Wrote %d color tracks", #EFFECT_EDITOR.color_tracks)) end
    end

    -- Apply timing curves
    if EFFECT_EDITOR.timing_curves and EFFECT_EDITOR.header.timing_curve_ptr ~= 0 then
        Parser.write_timing_curves_to_memory(EFFECT_EDITOR.memory_base, EFFECT_EDITOR.header.timing_curve_ptr, EFFECT_EDITOR.timing_curves)
        table.insert(applied, "timing curves")
        if not silent then
            local pt_first = EFFECT_EDITOR.timing_curves.process_timeline[1] or 0
            local pt_last = EFFECT_EDITOR.timing_curves.process_timeline[600] or 0
            log(string.format("  Wrote timing curves at 0x%X (pt: %d..%d)",
                EFFECT_EDITOR.header.timing_curve_ptr, pt_first, pt_last))
        end
    else
        log_verbose(string.format("  Timing curves NOT written: data=%s, ptr=0x%X",
            EFFECT_EDITOR.timing_curves and "yes" or "no",
            EFFECT_EDITOR.header.timing_curve_ptr or 0))
    end

    -- Apply effect flags
    if EFFECT_EDITOR.effect_flags then
        Parser.write_effect_flags_to_memory(EFFECT_EDITOR.memory_base, EFFECT_EDITOR.header.effect_flags_ptr, EFFECT_EDITOR.effect_flags)
        table.insert(applied, "effect flags")
        if not silent then
            local flags = EFFECT_EDITOR.effect_flags.flags_byte
            local pt_enabled = (flags % 64) >= 32  -- bit 5 (0x20)
            local at_enabled = (flags % 128) >= 64  -- bit 6 (0x40)
            log(string.format("  Wrote effect flags: 0x%02X (timing: pt=%s, at=%s)",
                flags, pt_enabled and "ON" or "off", at_enabled and "ON" or "off"))
        end
    end

    -- Apply sound flags (effect_flags section bytes 0x08-0x17)
    if EFFECT_EDITOR.sound_flags then
        Parser.write_sound_flags_to_memory(EFFECT_EDITOR.memory_base, EFFECT_EDITOR.header.effect_flags_ptr, EFFECT_EDITOR.sound_flags)
        table.insert(applied, "sound flags")
        if not silent then log("  Wrote 4 sound config channels") end
    end

    -- Apply sound definition (feds section)
    -- Note: For now, we only write if section size hasn't changed
    -- Size changes require shifting texture section (complex, future enhancement)
    if EFFECT_EDITOR.sound_definition then
        local old_size = EFFECT_EDITOR.header.texture_ptr - EFFECT_EDITOR.header.sound_def_ptr
        local new_bytes, new_size = Parser.serialize_sound_definition(EFFECT_EDITOR.sound_definition)

        if new_bytes then
            if new_size == old_size then
                -- Same size - safe to write directly
                local sound_addr = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.sound_def_ptr
                for i = 1, #new_bytes do
                    MemUtils.write8(sound_addr + i - 1, new_bytes:byte(i))
                end
                table.insert(applied, "sound definition")
                if not silent then log(string.format("  Wrote feds section (%d bytes)", new_size)) end
            elseif new_size < old_size then
                -- New size smaller - write and pad with zeros
                local sound_addr = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.sound_def_ptr
                for i = 1, #new_bytes do
                    MemUtils.write8(sound_addr + i - 1, new_bytes:byte(i))
                end
                -- Pad remaining bytes with zeros
                for i = new_size + 1, old_size do
                    MemUtils.write8(sound_addr + i - 1, 0)
                end
                table.insert(applied, "sound definition (shrunk)")
                if not silent then log(string.format("  Wrote feds section (%d->%d bytes, padded)", new_size, old_size)) end
            else
                -- New size larger - would need to shift texture section
                -- For now, log warning and skip
                log(string.format("  WARNING: Sound section grew (%d->%d bytes) - NOT WRITTEN (would overwrite texture)",
                    old_size, new_size))
                log("  Remove some opcodes or save to file instead")
            end
        end
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
