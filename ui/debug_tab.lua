-- debug_tab.lua
-- Debug tab for particle inspection and spawn logging
-- Simple flat panel with just the essential buttons

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (injected)
--------------------------------------------------------------------------------

local particle_reader = nil
local spawn_logger = nil
local helpers = nil
local lifecycle_capture = nil
local emitter_capture = nil
local sound_capture = nil
local note_capture = nil
local opcode_capture = nil

-- Opcode capture filter state
local opcode_filter_slot = -1      -- -1 = All slots
local opcode_filter_subslot = -1   -- -1 = All subslots

function M.set_dependencies(pr_module, spawn_logger_module, helpers_module, lifecycle_module, emitter_module, sound_module, note_module, opcode_module)
    particle_reader = pr_module
    spawn_logger = spawn_logger_module
    helpers = helpers_module
    lifecycle_capture = lifecycle_module
    emitter_capture = emitter_module
    sound_capture = sound_module
    note_capture = note_module
    opcode_capture = opcode_module
end

--------------------------------------------------------------------------------
-- Particle Dump (prints to console)
--------------------------------------------------------------------------------

local function dump_particles()
    if not particle_reader then
        print("particle_reader not initialized")
        return
    end

    -- Auto-detect effect index
    local effect_idx = particle_reader.get_current_effect_index()

    -- Calculate addresses
    local es_addr = particle_reader.get_effect_state_addr(effect_idx)
    local list_head = particle_reader.get_particle_list_head(effect_idx)

    -- Read particles
    local particles = particle_reader.read_all_particles(effect_idx, 256)

    if #particles == 0 then
        print(string.format("No particles found (effect %d, list_head=0x%08X)", effect_idx, list_head))
        return
    end

    -- Build emitter fingerprint map from definitions: flag_key -> emitter index
    local emitter_by_flags = {}
    if EFFECT_EDITOR and EFFECT_EDITOR.emitters then
        for _, em in ipairs(EFFECT_EDITOR.emitters) do
            local mo = (em.motion_type_flag or 0) + ((em.animation_target_flag or 0) * 256)
            local be = (em.emitter_flags_lo or 0) + ((em.emitter_flags_hi or 0) * 256)
            local key = string.format("0x%04X:0x%04X", mo, be)
            emitter_by_flags[key] = em.index
        end
    end

    -- Build runtime fingerprint mapping from particles
    local fingerprints = {}
    local fingerprint_order = {}
    local next_id = 1

    for _, p in ipairs(particles) do
        local key = string.format("0x%04X:0x%04X", p.motion_flags, p.behavior_flags)
        if not fingerprints[key] then
            local id_letter = string.char(64 + next_id)
            local real_idx = emitter_by_flags[key]
            fingerprints[key] = {
                id = id_letter,
                mo = p.motion_flags,
                be = p.behavior_flags,
                count = 0,
                real_idx = real_idx
            }
            table.insert(fingerprint_order, key)
            next_id = next_id + 1
        end
        fingerprints[key].count = fingerprints[key].count + 1
    end

    -- Helper to get emitter ID for a particle
    local function get_emu_id(p)
        local key = string.format("0x%04X:0x%04X", p.motion_flags, p.behavior_flags)
        local fp = fingerprints[key]
        if fp and fp.real_idx then
            return tostring(fp.real_idx)
        elseif fp then
            return fp.id
        end
        return "?"
    end

    print("")
    print(string.format("=== Particle Dump (Effect %d, %d particles) ===", effect_idx, #particles))

    -- Emitter Definition Fingerprints
    print("")
    print("--- Emitter Definition Fingerprints (from EFFECT_EDITOR.emitters) ---")
    print("Idx | MoFlg  | BeFlg  | ChD | ChM |")
    print("----|--------|--------|-----|-----|")
    if EFFECT_EDITOR and EFFECT_EDITOR.emitters then
        for _, em in ipairs(EFFECT_EDITOR.emitters) do
            local mo = (em.motion_type_flag or 0) + ((em.animation_target_flag or 0) * 256)
            local be = (em.emitter_flags_lo or 0) + ((em.emitter_flags_hi or 0) * 256)
            local chd = em.child_emitter_on_death or 0
            local chm = em.child_emitter_mid_life or 0
            print(string.format("%3d | 0x%04X | 0x%04X | %3d | %3d |", em.index, mo, be, chd, chm))
        end
    else
        print("(no emitter definitions loaded)")
    end

    -- Runtime Particle Mapping
    print("")
    print("--- Runtime Particle Mapping ---")
    print("ID  | Emu | MoFlg  | BeFlg  | Count | Notes")
    print("----|-----|--------|--------|-------|------")
    for _, key in ipairs(fingerprint_order) do
        local fp = fingerprints[key]
        local emu_str = fp.real_idx and tostring(fp.real_idx) or "?"
        local notes = fp.real_idx and "" or "NO MATCH"
        print(string.format(" %s  | %3s | 0x%04X | 0x%04X | %5d | %s",
            fp.id, emu_str, fp.mo, fp.be, fp.count, notes))
    end

    -- Field Definitions
    print("")
    print("--- Field Definitions ---")
    print("Field       | Type   | Conversion")
    print("------------|--------|---------------------------")
    print("Emu         | -      | emitter index (0-based) or ?X if no match")
    print("PosX/Y/Z    | int32  | /4096 -> world units")
    print("VelX/Y/Z    | int32  | /4096 -> world units")
    print("AccX/Y/Z    | int32  | /4096 -> world units")
    print("DragX/Y/Z   | int32  | /4096 -> world units")
    print("TgtX/Y/Z    | int16  | none (world units)")
    print("Life        | int16  | none (-1 = anim-driven)")
    print("Inertia     | int16  | none")
    print("Weight      | int16  | none")
    print("HomStr      | int16  | none")
    print("HCrv        | uint8  | curve index")
    print("AnimF       | uint16 | frame counter")
    print("ChDth/ChMid | uint8  | emitter index")
    print("ColR/G/B    | uint8  | curve index")

    -- Raw Values Table
    print("")
    print("--- Raw Values (no conversion) ---")
    local raw_header = string.format(
        "%3s, %3s, %8s, %11s, %11s, %11s, %11s, %11s, %11s, %11s, %11s, %11s, %11s, %11s, %11s, %6s, %6s, %6s, %6s, %6s, %6s, %6s, %5s, %6s, %6s, %5s, %5s, %4s, %4s, %4s, %4s",
        "#", "Emu", "Addr", "PosX", "PosY", "PosZ", "VelX", "VelY", "VelZ",
        "AccX", "AccY", "AccZ", "DragX", "DragY", "DragZ",
        "TgtX", "TgtY", "TgtZ", "Life", "Inert", "Weight", "HomStr", "HCrv",
        "MoFlg", "BeFlg", "AnimF", "ChDth", "ChMid", "ColR", "ColG", "ColB"
    )
    print(raw_header)
    print(string.rep("-", #raw_header))

    for i, p in ipairs(particles) do
        local row = string.format(
            "%3d, %3s, %08X, %11d, %11d, %11d, %11d, %11d, %11d, %11d, %11d, %11d, %11d, %11d, %11d, %6d, %6d, %6d, %6d, %6d, %6d, %6d, %5d, 0x%04X, 0x%04X, %5d, %5d, %4d, %4d, %4d, %4d",
            i, get_emu_id(p), p.addr,
            p.position_x_raw, p.position_y_raw, p.position_z_raw,
            p.velocity_x_raw, p.velocity_y_raw, p.velocity_z_raw,
            p.acceleration_x_raw, p.acceleration_y_raw, p.acceleration_z_raw,
            p.drag_x_raw, p.drag_y_raw, p.drag_z_raw,
            p.target_x, p.target_y, p.target_z,
            p.lifetime_counter, p.inertia, p.weight,
            p.homing_strength, p.homing_curve_index,
            p.motion_flags, p.behavior_flags,
            p.anim_frame_counter,
            p.child_emitter_on_death, p.child_emitter_mid_life,
            p.color_r_curve, p.color_g_curve, p.color_b_curve
        )
        print(row)
    end

    -- Pretty Print Table (world units)
    print("")
    print("--- Pretty Print (world units) ---")
    local pretty_header = string.format(
        "%3s, %3s, %8s, %7s, %7s, %7s, %7s, %7s, %7s, %7s, %7s, %7s, %6s, %6s, %6s, %6s, %6s, %6s, %6s, %5s, %6s, %6s, %5s, %5s, %4s, %4s, %4s, %4s",
        "#", "Emu", "Addr", "PosX", "PosY", "PosZ", "VelX", "VelY", "VelZ",
        "AccX", "AccY", "AccZ",
        "TgtX", "TgtY", "TgtZ", "Life", "Inert", "Weight", "HomStr", "HCrv",
        "MoFlg", "BeFlg", "AnimF", "ChDth", "ChMid", "ColR", "ColG", "ColB"
    )
    print(pretty_header)
    print(string.rep("-", #pretty_header))

    for i, p in ipairs(particles) do
        local row = string.format(
            "%3d, %3s, %08X, %7.1f, %7.1f, %7.1f, %7.2f, %7.2f, %7.2f, %7.2f, %7.2f, %7.2f, %6d, %6d, %6d, %6d, %6d, %6d, %6d, %5d, 0x%04X, 0x%04X, %5d, %5d, %4d, %4d, %4d, %4d",
            i, get_emu_id(p), p.addr,
            p.position_x, p.position_y, p.position_z,
            p.velocity_x, p.velocity_y, p.velocity_z,
            p.acceleration_x, p.acceleration_y, p.acceleration_z,
            p.target_x, p.target_y, p.target_z,
            p.lifetime_counter, p.inertia, p.weight,
            p.homing_strength, p.homing_curve_index,
            p.motion_flags, p.behavior_flags,
            p.anim_frame_counter,
            p.child_emitter_on_death, p.child_emitter_mid_life,
            p.color_r_curve, p.color_g_curve, p.color_b_curve
        )
        print(row)
    end

    print("")
    print("=== End Particle Dump ===")
    print("")
end

--------------------------------------------------------------------------------
-- Main Draw (flat panel)
--------------------------------------------------------------------------------

function M.draw()
    if not particle_reader then
        imgui.TextUnformatted("Error: particle_reader not initialized")
        return
    end

    -- Particle snapshot button
    if imgui.Button("Dump Particles", 120, 0) then
        dump_particles()
    end
    imgui.SameLine()
    imgui.TextUnformatted("Pause (F6) first, prints to console")

    imgui.Spacing()

    -- Spawn logger controls
    if spawn_logger then
        local is_recording = spawn_logger.is_recording()
        local spawn_count = spawn_logger.get_spawn_count()

        if is_recording then
            if imgui.Button("Stop Recording", 120, 0) then
                spawn_logger.disarm_recording()
            end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("Recording... (%d spawns)", spawn_count))
        else
            if imgui.Button("Record Spawns", 120, 0) then
                spawn_logger.arm_recording()
            end
            imgui.SameLine()
            if spawn_count > 0 then
                imgui.TextUnformatted(string.format("Stopped (%d spawns)", spawn_count))
            else
                imgui.TextUnformatted("Records emitter_control calls")
            end
        end

        if spawn_count > 0 then
            if imgui.Button("Print Log", 80, 0) then
                spawn_logger.print_log()
            end
            imgui.SameLine()
            if imgui.Button("Clear", 60, 0) then
                spawn_logger.clear_log()
            end
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Lifecycle capture controls
    if lifecycle_capture then
        imgui.TextUnformatted("Lifecycle Capture (all particles, all frames)")

        local is_capturing = lifecycle_capture.is_capturing()
        local stats = lifecycle_capture.get_stats()

        if is_capturing then
            if imgui.Button("Stop Capture", 120, 0) then
                lifecycle_capture.stop_capture()
            end
            imgui.SameLine()
            if stats.effect_idx >= 0 then
                imgui.TextUnformatted(string.format("Recording E%d... (%d frames, %d snapshots)",
                    stats.effect_idx, stats.frame_count, stats.total_snapshots))
            else
                imgui.TextUnformatted("Waiting for effect to start...")
            end
        else
            if imgui.Button("Start Capture", 120, 0) then
                lifecycle_capture.start_capture()
            end
            imgui.SameLine()
            if stats.frame_count > 0 then
                imgui.TextUnformatted(string.format("Stopped (%d frames, %d particles)",
                    stats.frame_count, stats.unique_particles))
            else
                imgui.TextUnformatted("Records every particle field every frame")
            end
        end

        -- Export button (only if we have data)
        if stats.frame_count > 0 and not is_capturing then
            if imgui.Button("Export CSV", 100, 0) then
                lifecycle_capture.export_csv()
            end
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Emitter invocation capture controls
    if emitter_capture then
        imgui.TextUnformatted("Emitter Invocation Capture")

        local is_capturing = emitter_capture.is_capturing()
        local count = emitter_capture.get_count()

        if is_capturing then
            if imgui.Button("Stop Emitter Capture", 140, 0) then
                emitter_capture.stop_capture()
            end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("Recording... (%d invocations)", count))
        else
            if imgui.Button("Start Emitter Capture", 140, 0) then
                emitter_capture.start_capture()
            end
            imgui.SameLine()
            if count > 0 then
                imgui.TextUnformatted(string.format("Stopped (%d invocations)", count))
            else
                imgui.TextUnformatted("Records emitter_control calls")
            end
        end

        -- Export/Print buttons (only if we have data)
        if count > 0 and not is_capturing then
            if imgui.Button("Export Emitter CSV", 120, 0) then
                emitter_capture.export_csv()
            end
            imgui.SameLine()
            if imgui.Button("Print Log", 80, 0) then
                emitter_capture.print_log()
            end
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Sound capture controls
    if sound_capture then
        imgui.TextUnformatted("Sound Capture")

        local is_capturing = sound_capture.is_capturing()
        local count = sound_capture.get_count()

        if is_capturing then
            if imgui.Button("Stop Sound Capture", 140, 0) then
                sound_capture.stop_capture()
            end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("Recording... (%d triggers)", count))
        else
            if imgui.Button("Start Sound Capture", 140, 0) then
                sound_capture.start_capture()
            end
            imgui.SameLine()
            if count > 0 then
                imgui.TextUnformatted(string.format("Stopped (%d triggers)", count))
            else
                imgui.TextUnformatted("Records play_sound calls")
            end
        end

        -- Print button (only if we have data)
        if count > 0 and not is_capturing then
            if imgui.Button("Print Sound Log", 120, 0) then
                sound_capture.print_log()
            end
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Note capture controls (individual SMD notes)
    if note_capture then
        imgui.TextUnformatted("Note Capture (individual SMD notes)")

        local is_capturing = note_capture.is_capturing()
        local count = note_capture.get_count()

        if is_capturing then
            if imgui.Button("Stop Note Capture", 140, 0) then
                note_capture.stop_capture()
            end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("Recording... (%d notes)", count))
        else
            if imgui.Button("Start Note Capture", 140, 0) then
                note_capture.start_capture()
            end
            imgui.SameLine()
            if count > 0 then
                imgui.TextUnformatted(string.format("Stopped (%d notes)", count))
            else
                imgui.TextUnformatted("Records note events (opcodes < 0x80)")
            end
        end

        -- Print buttons (only if we have data)
        if count > 0 and not is_capturing then
            if imgui.Button("Print Note Log", 120, 0) then
                note_capture.print_log()
            end
            -- Filtered print (only if sound_capture has data)
            if sound_capture and sound_capture.get_count() > 0 then
                imgui.SameLine()
                if imgui.Button("Print Filtered", 100, 0) then
                    local filter_ptrs = sound_capture.get_channel_ptrs()
                    note_capture.print_log(filter_ptrs)
                end
            end
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Opcode capture controls (effect-scoped SMD opcodes)
    if opcode_capture then
        imgui.TextUnformatted("Opcode Capture (effect-scoped SMD)")

        local is_capturing = opcode_capture.is_capturing()
        local count = opcode_capture.get_count()

        if is_capturing then
            if imgui.Button("Stop Opcode Capture", 140, 0) then
                opcode_capture.stop_capture()
            end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("Recording... (%d opcodes)", count))
        else
            if imgui.Button("Start Opcode Capture", 140, 0) then
                opcode_capture.start_capture()
            end
            imgui.SameLine()
            if count > 0 then
                imgui.TextUnformatted(string.format("Stopped (%d opcodes)", count))
            else
                imgui.TextUnformatted("Effect file SMD only (filtered)")
            end
        end

        -- Filter dropdowns and Print button (only if we have data and not recording)
        if count > 0 and not is_capturing then
            imgui.SetNextItemWidth(60)
            local slot_items = "All\0000\0001\0002\0003\0"
            local c, v = imgui.Combo("Slot##opcode_slot", opcode_filter_slot + 1, slot_items)
            if c then opcode_filter_slot = v - 1 end

            imgui.SameLine()
            imgui.SetNextItemWidth(60)
            local subslot_items = "All\0000\0001\0002\0003\0004\0005\0006\0007\0"
            c, v = imgui.Combo("SubSlot##opcode_subslot", opcode_filter_subslot + 1, subslot_items)
            if c then opcode_filter_subslot = v - 1 end

            imgui.SameLine()
            if imgui.Button("Print Opcode Log", 120, 0) then
                opcode_capture.print_log(opcode_filter_slot, opcode_filter_subslot)
            end
        end
    end
end

return M
