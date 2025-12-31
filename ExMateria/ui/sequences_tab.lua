-- ui/sequences_tab.lua
-- Animation Sequences Tab for FFT Effect Editor
-- Edits sprite animation sequences (which frameset to display, for how long)

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local helpers = nil
local Parser = nil
local ee_test_fn = nil
local reload_session_fn = nil  -- ee_load_session - reloads savestate AND re-parses from .bin
local apply_all_edits_fn = nil  -- Kept for preview mode exit

function M.set_dependencies(helpers_module, parser_module, test_fn, reload_session, apply_all_edits)
    helpers = helpers_module
    Parser = parser_module
    ee_test_fn = test_fn
    reload_session_fn = reload_session
    apply_all_edits_fn = apply_all_edits
end

--------------------------------------------------------------------------------
-- UI State (persists across frames)
--------------------------------------------------------------------------------

local ui_state = {
    selected_seq = 0,           -- Currently selected sequence index (0-indexed)
    selected_instr = -1,        -- Currently selected instruction (-1 = none)
    insert_opcode_type = 1,     -- 1=FRAME, 2=LOOP, 3=SET_OFFSET, 4=ADD_OFFSET
    show_reference = false,     -- Toggle reference panel
    preview_active = false,     -- Whether preview mode is active
    exiting_preview = false,    -- True during exit_preview_mode to prevent callback interference
    -- Backups for preserving work during preview
    preview_backup_sequences = nil,   -- Original sequences before preview
    preview_backup_framesets = nil,   -- Original framesets before preview
    preview_backup_group_count = nil, -- Original frames_group_count
    -- Preview slot configuration (4 slots, each can be enabled/disabled and assigned a sequence)
    preview_slots = {
        {enabled = true, seq_index = 0},
        {enabled = true, seq_index = 1},
        {enabled = true, seq_index = 2},
        {enabled = true, seq_index = 3},
    },
    -- Screen effect track kf[0] time value (0-255)
    screen_kf0_time = 0,
}

-- Expose ui_state for external access (e.g., clearing preview on reload)
M.ui_state = ui_state

--------------------------------------------------------------------------------
-- Opcode Type Definitions
--------------------------------------------------------------------------------

local OPCODE_TYPES = {
    {id = "FRAME", display = "FRAME", description = "Display frameset for duration ticks"},
    {id = "LOOP", display = "LOOP", description = "Restart sequence from beginning"},
    {id = "SET_OFFSET", display = "SET_OFFSET", description = "Set sprite offset absolutely"},
    {id = "ADD_OFFSET", display = "ADD_OFFSET", description = "Add to sprite offset"},
}

local DEPTH_MODE_OPTIONS = {
    "0: Standard (Z>>2)",
    "1: Forward 8",
    "2: Fixed Front (8)",
    "3: Fixed Back (0x17E)",
    "4: Fixed 16 (0x10)",
    "5: Forward 16",
}

--------------------------------------------------------------------------------
-- Instruction Parameter Editing
--------------------------------------------------------------------------------

local function draw_instruction_params(seq, instr_idx)
    local instr = seq.instructions[instr_idx]
    if not instr then return false end

    local changed = false

    if instr.name == "FRAME" then
        -- FRAME has 3 params: frameset_index, duration, depth_mode
        imgui.TextUnformatted("Frameset Index:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        local c, v = imgui.InputInt("##frameset_idx", instr.params[1] or 0)
        if c then
            instr.params[1] = math.max(0, math.min(127, v))
            instr.opcode = instr.params[1]  -- opcode IS the frameset index for FRAME
            changed = true
        end

        imgui.SameLine()
        imgui.TextUnformatted("Duration:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.InputInt("##duration", instr.params[2] or 0)
        if c then
            instr.params[2] = math.max(0, math.min(255, v))
            changed = true
        end

        imgui.TextUnformatted("Depth Mode:")
        imgui.SameLine()
        imgui.SetNextItemWidth(200)
        local current_mode = instr.params[3] or 0
        if current_mode < 0 or current_mode > 5 then current_mode = 0 end
        local combo_str = table.concat(DEPTH_MODE_OPTIONS, "\0") .. "\0"
        c, v = imgui.Combo("##depth_mode", current_mode, combo_str)
        if c then
            instr.params[3] = v
            changed = true
        end

    elseif instr.name == "SET_OFFSET" then
        -- SET_OFFSET has 2 params: offset_x(s16), offset_y(s16)
        imgui.TextUnformatted("Offset X:")
        imgui.SameLine()
        imgui.SetNextItemWidth(100)
        local c, v = imgui.InputInt("##offset_x", instr.params[1] or 0)
        if c then
            instr.params[1] = math.max(-32768, math.min(32767, v))
            changed = true
        end

        imgui.SameLine()
        imgui.TextUnformatted("Offset Y:")
        imgui.SameLine()
        imgui.SetNextItemWidth(100)
        c, v = imgui.InputInt("##offset_y", instr.params[2] or 0)
        if c then
            instr.params[2] = math.max(-32768, math.min(32767, v))
            changed = true
        end

    elseif instr.name == "ADD_OFFSET" then
        -- ADD_OFFSET has 2 params: delta_x(s8), delta_y(s8)
        imgui.TextUnformatted("Delta X:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        local c, v = imgui.InputInt("##delta_x", instr.params[1] or 0)
        if c then
            instr.params[1] = math.max(-128, math.min(127, v))
            changed = true
        end

        imgui.SameLine()
        imgui.TextUnformatted("Delta Y:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.InputInt("##delta_y", instr.params[2] or 0)
        if c then
            instr.params[2] = math.max(-128, math.min(127, v))
            changed = true
        end

    elseif instr.name == "LOOP" then
        imgui.TextUnformatted("(no parameters - restarts sequence)")
    else
        imgui.TextUnformatted(string.format("Unknown opcode: 0x%02X", instr.opcode))
    end

    return changed
end

--------------------------------------------------------------------------------
-- Reference Panel
--------------------------------------------------------------------------------

local function draw_reference_panel()
    imgui.TextUnformatted("=== Sequence Opcode Reference ===")
    imgui.Separator()

    imgui.TextUnformatted("FRAME (0x00-0x7F) - 3 bytes")
    imgui.TextUnformatted("  [frameset_idx] [duration] [depth_mode]")
    imgui.TextUnformatted("  Display frameset for 'duration' ticks")
    imgui.TextUnformatted("  duration=0 terminates sequence")
    imgui.Spacing()

    imgui.TextUnformatted("LOOP (0x81) - 1 byte")
    imgui.TextUnformatted("  Restart sequence from beginning")
    imgui.TextUnformatted("  (resets frame_counter to 0)")
    imgui.Spacing()

    imgui.TextUnformatted("SET_OFFSET (0x82) - 5 bytes")
    imgui.TextUnformatted("  [opcode] [x_lo] [x_hi] [y_lo] [y_hi]")
    imgui.TextUnformatted("  Set sprite offset absolutely (s16)")
    imgui.Spacing()

    imgui.TextUnformatted("ADD_OFFSET (0x83) - 3 bytes")
    imgui.TextUnformatted("  [opcode] [dx] [dy]")
    imgui.TextUnformatted("  Add to sprite offset (s8)")
    imgui.Spacing()

    imgui.Separator()
    imgui.TextUnformatted("=== Depth Modes ===")
    for i, mode in ipairs(DEPTH_MODE_OPTIONS) do
        imgui.TextUnformatted("  " .. mode)
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.sequences then
        imgui.TextUnformatted("No sequences loaded. Load an effect first.")
        return
    end

    local sequences = EFFECT_EDITOR.sequences
    if #sequences == 0 then
        imgui.TextUnformatted("Effect has no sequences.")
        return
    end

    -- Top row: Sequence selector + Add/Delete buttons
    imgui.TextUnformatted("Sequence:")
    imgui.SameLine()
    imgui.SetNextItemWidth(150)

    -- Build sequence combo string
    local seq_items = ""
    for i, seq in ipairs(sequences) do
        local instr_count = #seq.instructions
        seq_items = seq_items .. string.format("Seq %d (%d ops)\0", i - 1, instr_count)
    end
    seq_items = seq_items .. "\0"

    local c, v = imgui.Combo("##seq_select", ui_state.selected_seq, seq_items)
    if c then
        ui_state.selected_seq = v
        ui_state.selected_instr = -1  -- Reset instruction selection
    end

    imgui.SameLine()
    if imgui.Button("Add Seq") then
        local new_seq = Parser.create_sequence(#sequences)
        table.insert(sequences, new_seq)
        EFFECT_EDITOR.sequence_count = #sequences
        ui_state.selected_seq = #sequences - 1
        ui_state.selected_instr = -1
    end

    imgui.SameLine()
    if #sequences > 1 then
        if imgui.Button("Delete Seq") then
            table.remove(sequences, ui_state.selected_seq + 1)
            EFFECT_EDITOR.sequence_count = #sequences
            if ui_state.selected_seq >= #sequences then
                ui_state.selected_seq = #sequences - 1
            end
            ui_state.selected_instr = -1
            -- Reindex sequences
            for i, seq in ipairs(sequences) do
                seq.index = i - 1
            end
        end
    else
        imgui.BeginDisabled()
        imgui.Button("Delete Seq")
        imgui.EndDisabled()
    end

    imgui.SameLine()
    local ref_c, ref_v = imgui.Checkbox("Reference", ui_state.show_reference)
    if ref_c then ui_state.show_reference = ref_v end

    imgui.Separator()

    -- Get current sequence
    local seq = sequences[ui_state.selected_seq + 1]
    if not seq then return end

    -- Reference panel (right side)
    if ui_state.show_reference then
        imgui.Columns(2, "##seq_columns", true)
        imgui.SetColumnWidth(0, 450)
    end

    -- Instructions list
    imgui.TextUnformatted(string.format("Instructions (%d):", #seq.instructions))

    imgui.BeginChild("##instr_list", 0, 200, true)
    for i, instr in ipairs(seq.instructions) do
        local label
        if instr.name == "FRAME" then
            label = string.format("%2d: FRAME fs=%d dur=%d depth=%d",
                i - 1, instr.params[1] or 0, instr.params[2] or 0, instr.params[3] or 0)
        elseif instr.name == "SET_OFFSET" then
            label = string.format("%2d: SET_OFFSET x=%d y=%d",
                i - 1, instr.params[1] or 0, instr.params[2] or 0)
        elseif instr.name == "ADD_OFFSET" then
            label = string.format("%2d: ADD_OFFSET dx=%d dy=%d",
                i - 1, instr.params[1] or 0, instr.params[2] or 0)
        elseif instr.name == "LOOP" then
            label = string.format("%2d: LOOP", i - 1)
        else
            label = string.format("%2d: %s (0x%02X)", i - 1, instr.name, instr.opcode)
        end

        local is_selected = (ui_state.selected_instr == i - 1)
        if imgui.Selectable(label, is_selected) then
            ui_state.selected_instr = i - 1
        end
    end
    imgui.EndChild()

    -- Insert/Delete controls
    imgui.TextUnformatted("Insert:")
    imgui.SameLine()
    imgui.SetNextItemWidth(150)

    local opcode_items = ""
    for _, op in ipairs(OPCODE_TYPES) do
        opcode_items = opcode_items .. op.display .. "\0"
    end
    opcode_items = opcode_items .. "\0"

    c, v = imgui.Combo("##insert_type", ui_state.insert_opcode_type - 1, opcode_items)
    if c then ui_state.insert_opcode_type = v + 1 end

    imgui.SameLine()
    if imgui.Button("Above") then
        local op_type = OPCODE_TYPES[ui_state.insert_opcode_type].id
        local new_instr = Parser.create_sequence_instruction(op_type)
        local insert_pos = ui_state.selected_instr >= 0 and ui_state.selected_instr + 1 or 1
        table.insert(seq.instructions, insert_pos, new_instr)
        ui_state.selected_instr = insert_pos - 1
    end

    imgui.SameLine()
    if imgui.Button("Below") then
        local op_type = OPCODE_TYPES[ui_state.insert_opcode_type].id
        local new_instr = Parser.create_sequence_instruction(op_type)
        local insert_pos = ui_state.selected_instr >= 0 and ui_state.selected_instr + 2 or #seq.instructions + 1
        table.insert(seq.instructions, insert_pos, new_instr)
        ui_state.selected_instr = insert_pos - 1
    end

    imgui.SameLine()
    if ui_state.selected_instr >= 0 and #seq.instructions > 1 then
        if imgui.Button("Delete") then
            table.remove(seq.instructions, ui_state.selected_instr + 1)
            if ui_state.selected_instr >= #seq.instructions then
                ui_state.selected_instr = #seq.instructions - 1
            end
        end
    else
        imgui.BeginDisabled()
        imgui.Button("Delete")
        imgui.EndDisabled()
    end

    imgui.Separator()

    -- Parameter editor for selected instruction
    if ui_state.selected_instr >= 0 and ui_state.selected_instr < #seq.instructions then
        imgui.TextUnformatted("Edit Instruction:")
        draw_instruction_params(seq, ui_state.selected_instr + 1)
    else
        imgui.TextUnformatted("Select an instruction to edit parameters.")
    end

    -- Reference panel
    if ui_state.show_reference then
        imgui.NextColumn()
        draw_reference_panel()
        imgui.Columns(1)
    end

    imgui.Separator()

    imgui.TextUnformatted(string.format("Total: %d sequences, %d bytes",
        #sequences,
        Parser.calculate_animation_section_size(sequences)))

    -- Preview section
    imgui.Separator()
    M.draw_preview_section(sequences)
end

--------------------------------------------------------------------------------
-- Preview Mode Functions
--------------------------------------------------------------------------------

-- Restore end markers: convert dur=1 back to dur=0 for FRAME instructions
-- followed by LOOP (the pattern used for looping animations)
local function restore_end_markers(sequences)
    for _, seq in ipairs(sequences) do
        for i, instr in ipairs(seq.instructions) do
            local next_instr = seq.instructions[i + 1]
            -- Pattern: FRAME with dur=1 followed by LOOP → restore to dur=0
            if instr.name == "FRAME" and instr.params[2] == 1
               and next_instr and next_instr.name == "LOOP" then
                instr.params[2] = 0  -- dur=1 → dur=0
            end
        end
    end
end

-- Exit preview mode: save → fix dur → reload → patch back
function M.exit_preview_mode()
    print("[SEQ_TAB] exit_preview_mode called, preview_active=" .. tostring(ui_state.preview_active))

    if not ui_state.preview_active then
        EFFECT_EDITOR.status_msg = "Not in preview mode"
        return
    end

    -- 1. Make DEEP COPIES of current sequences/framesets (with user's edits)
    -- Must be deep copies because we modify them and ee_test might affect originals
    local saved_sequences = Parser.copy_sequences(EFFECT_EDITOR.sequences)
    local saved_framesets = Parser.copy_framesets(EFFECT_EDITOR.framesets)
    local saved_group_count = EFFECT_EDITOR.frames_group_count

    print("[SEQ_TAB] Saved " .. #saved_sequences .. " sequences")

    -- 2. Fix dur=1 → dur=0 (restore end markers) on the copies
    restore_end_markers(saved_sequences)
    print("[SEQ_TAB] Restored end markers (dur=1 → dur=0)")

    -- 3. Clear preview state BEFORE reload
    ui_state.preview_active = false
    ui_state.exiting_preview = true
    print("[SEQ_TAB] Cleared preview_active, set exiting_preview")

    -- 4. Trigger full session reload (like Reload button)
    -- This reloads savestate AND re-parses from .bin, restoring original emitters/script/timeline
    local session_name = EFFECT_EDITOR.session_name
    print("[SEQ_TAB] Calling reload_session_fn('" .. tostring(session_name) .. "')...")
    if reload_session_fn and session_name then
        reload_session_fn(session_name)
    else
        print("[SEQ_TAB] ERROR: reload_session_fn or session_name not available!")
        ui_state.exiting_preview = false
        return
    end

    -- 5. After reload completes, patch back fixed sequences/framesets
    -- ee_load_session's nextTick runs first (parses .bin, applies, resumes)
    -- Our nextTick runs after - we pause, patch, re-apply, resume
    print("[SEQ_TAB] Queueing patch callback...")
    PCSX.nextTick(function()
        print("[SEQ_TAB] Patch callback fired")
        local success, err = pcall(function()
            -- Emulator is running - pause it for safe patching
            PCSX.pauseEmulator()
            print("[SEQ_TAB] Paused emulator")

            -- Patch EFFECT_EDITOR with our saved data
            print("[SEQ_TAB] Patching " .. #saved_sequences .. " sequences, " .. #saved_framesets .. " framesets")
            EFFECT_EDITOR.sequences = saved_sequences
            EFFECT_EDITOR.framesets = saved_framesets
            EFFECT_EDITOR.frames_group_count = saved_group_count

            -- Re-apply edits to write patched sequences/frames to memory
            print("[SEQ_TAB] Re-applying edits to memory...")
            if apply_all_edits_fn then
                apply_all_edits_fn(true)  -- silent mode
            end

            -- Clear exiting flag
            ui_state.exiting_preview = false

            EFFECT_EDITOR.status_msg = "Exited preview. Sequences/frames preserved with dur=0 restored."
            print("[SEQ_TAB] Exit complete, resuming...")
            PCSX.resumeEmulator()
        end)
        if not success then
            print("[SEQ_TAB] ERROR in patch callback: " .. tostring(err))
            PCSX.resumeEmulator()  -- Make sure we resume even on error
        end
    end)
end

-- Draw preview section UI
function M.draw_preview_section(sequences)
    local num_sequences = #sequences

    if num_sequences == 0 then
        return
    end

    -- Build sequence combo items string
    local seq_items = ""
    for i = 0, num_sequences - 1 do
        seq_items = seq_items .. string.format("Seq %d\0", i)
    end
    seq_items = seq_items .. "\0"

    -- Preview slot configuration (4 slots with checkbox + dropdown)
    imgui.TextUnformatted("Preview Slots:")
    for slot_idx = 1, 4 do
        local slot = ui_state.preview_slots[slot_idx]
        local slot_label = string.format("Slot %d", slot_idx - 1)

        -- Checkbox for enable/disable
        local c, v = imgui.Checkbox("##slot_en_" .. slot_idx, slot.enabled)
        if c then slot.enabled = v end

        imgui.SameLine()
        imgui.TextUnformatted(slot_label .. ":")
        imgui.SameLine()

        -- Dropdown for sequence selection
        imgui.SetNextItemWidth(80)
        -- Clamp seq_index to valid range
        local current_idx = math.min(slot.seq_index, num_sequences - 1)
        c, v = imgui.Combo("##slot_seq_" .. slot_idx, current_idx, seq_items)
        if c then
            slot.seq_index = v
        end

        -- Show 4 slots in 2 rows (2 per row)
        if slot_idx == 1 or slot_idx == 3 then
            imgui.SameLine()
            imgui.TextUnformatted("   ")
            imgui.SameLine()
        end
    end

    -- Screen effect kf[1] RGB slider (sets all RGB channels)
    imgui.TextUnformatted("Screen RGB:")
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    local c, v = imgui.SliderInt("##screen_rgb", ui_state.screen_kf0_time, 0, 255, "%d")
    if c then
        ui_state.screen_kf0_time = v
    end

    -- Count enabled slots
    local enabled_count = 0
    for _, slot in ipairs(ui_state.preview_slots) do
        if slot.enabled then enabled_count = enabled_count + 1 end
    end

    if not ui_state.preview_active then
        -- Not in preview mode - show enter button
        if enabled_count > 0 then
            if imgui.Button("Enter Preview Mode", 150, 25) then
                M.enter_preview_mode(sequences)
            end
            imgui.SameLine()
            imgui.TextUnformatted("(" .. enabled_count .. " slots enabled)")
        else
            imgui.BeginDisabled()
            imgui.Button("Enter Preview Mode", 150, 25)
            imgui.EndDisabled()
            imgui.SameLine()
            imgui.TextUnformatted("(enable at least 1 slot)")
        end
    else
        -- In preview mode - show exit button and status
        if imgui.Button("Exit Preview", 120, 25) then
            M.exit_preview_mode()
        end
        imgui.SameLine()
        imgui.TextUnformatted("Preview ACTIVE - click 'Test Effect' to view, 'Exit Preview' to restore normal mode")
    end

    -- Restore original button (available if we have a backup from entering preview)
    if ui_state.preview_backup_sequences then
        imgui.SameLine()
        if imgui.Button("Restore Original", 130, 25) then
            EFFECT_EDITOR.sequences = Parser.copy_sequences(ui_state.preview_backup_sequences)
            EFFECT_EDITOR.framesets = Parser.copy_framesets(ui_state.preview_backup_framesets)
            EFFECT_EDITOR.frames_group_count = ui_state.preview_backup_group_count
            EFFECT_EDITOR.status_msg = "Restored sequences/frames from pre-preview backup"
        end
    end
end

-- Calculate current script size in bytes
local function get_current_script_size()
    local insts = EFFECT_EDITOR.script_instructions
    if not insts or #insts == 0 then return 0 end

    local size = 0
    for _, inst in ipairs(insts) do
        size = size + (inst.size or 2)
    end
    return size
end

-- Generate 1-phase script padded to target size with NOPs
-- This avoids structure changes when converting from 3-phase
local function generate_padded_1phase_script(target_size)
    -- 1-phase base script (30 bytes)
    local insts = {}

    -- 0x00: set_texture_page (2 bytes)
    table.insert(insts, Parser.create_script_instruction(5))
    -- 0x02: init_physics_params (2 bytes)
    table.insert(insts, Parser.create_script_instruction(39))
    -- 0x04: branch_anim_done → 0x10 (4 bytes)
    local branch1 = Parser.create_script_instruction(29)
    branch1.params.target = 0x10
    table.insert(insts, branch1)
    -- 0x08: for_each_phase_timeline_tick (2 bytes)
    table.insert(insts, Parser.create_script_instruction(40))
    -- 0x0A: update_all_particles (2 bytes)
    table.insert(insts, Parser.create_script_instruction(37))
    -- 0x0C: goto_yield → 0x04 (4 bytes)
    local goto1 = Parser.create_script_instruction(0)
    goto1.params.target = 0x04
    table.insert(insts, goto1)
    -- 0x10: update_all_particles (2 bytes)
    table.insert(insts, Parser.create_script_instruction(37))
    -- 0x12: branch_count_eq 0 → target (6 bytes)
    local branch2 = Parser.create_script_instruction(22)
    branch2.params.value = 0
    -- Target will be set after we know final size
    table.insert(insts, branch2)
    -- 0x18: goto_yield → 0x10 (4 bytes)
    local goto2 = Parser.create_script_instruction(0)
    goto2.params.target = 0x10
    table.insert(insts, goto2)

    -- Calculate current size (before end instruction)
    local current_size = 0
    for _, inst in ipairs(insts) do
        current_size = current_size + (inst.size or 2)
    end
    -- current_size = 28 bytes

    -- Add NOPs to pad to target_size - 2 (leaving room for end instruction)
    local nop_opcode = 45  -- nop instruction, 2 bytes
    while current_size < target_size - 2 do
        table.insert(insts, Parser.create_script_instruction(nop_opcode))
        current_size = current_size + 2
    end

    -- end instruction (2 bytes)
    table.insert(insts, Parser.create_script_instruction(4))
    current_size = current_size + 2

    -- Update branch target to point to end instruction
    branch2.params.target = current_size - 2  -- offset of end instruction

    -- Recalculate offsets
    Parser.recalculate_script_offsets(insts)

    return insts
end

-- Enter preview mode: configure emitters, timeline, and script for sequence viewing
-- NOTE: This only configures EFFECT_EDITOR state - user must click "Test Effect" to apply
function M.enter_preview_mode(sequences)
    print("[SEQ_TAB] enter_preview_mode called with " .. #sequences .. " sequences")

    if not Parser then
        EFFECT_EDITOR.status_msg = "Error: Parser not available"
        return
    end

    local num_sequences = #sequences
    if num_sequences == 0 then
        EFFECT_EDITOR.status_msg = "No sequences to preview"
        return
    end

    -- Gather enabled slots and their sequence indices
    local enabled_slots = {}
    for slot_idx, slot in ipairs(ui_state.preview_slots) do
        if slot.enabled then
            -- Clamp sequence index to valid range
            local seq_idx = math.min(slot.seq_index, num_sequences - 1)
            table.insert(enabled_slots, {
                slot_idx = slot_idx,
                seq_index = seq_idx,  -- 0-indexed
            })
        end
    end

    local num_enabled = #enabled_slots
    if num_enabled == 0 then
        EFFECT_EDITOR.status_msg = "No slots enabled for preview"
        return
    end

    print(string.format("[SEQ_TAB] %d slots enabled", num_enabled))

    -- Store backups BEFORE any modifications (for restore button)
    ui_state.preview_backup_sequences = Parser.copy_sequences(EFFECT_EDITOR.sequences)
    ui_state.preview_backup_framesets = Parser.copy_framesets(EFFECT_EDITOR.framesets)
    ui_state.preview_backup_group_count = EFFECT_EDITOR.frames_group_count
    print("[SEQ_TAB] Stored backups")

    ui_state.preview_active = true
    print("[SEQ_TAB] Set preview_active = true")

    -- 1. Modify sequences that are used in enabled slots: replace dur=0 frames with dur=1
    local modified_seqs = {}  -- track which sequences we've already modified
    for _, slot_info in ipairs(enabled_slots) do
        local seq_idx = slot_info.seq_index + 1  -- Lua 1-indexed
        if not modified_seqs[seq_idx] then
            local seq = EFFECT_EDITOR.sequences[seq_idx]
            if seq then
                local old_instr_count = #seq.instructions
                seq.instructions = Parser.modify_sequence_for_preview(seq)
                print(string.format("[SEQ_TAB] Seq %d: %d → %d instructions", seq_idx-1, old_instr_count, #seq.instructions))
                modified_seqs[seq_idx] = true
            end
        end
    end

    -- 2. Configure emitters based on enabled slots
    -- Calculate X positions dynamically - centered and evenly spaced
    local x_positions = {}
    local total_span = 160  -- from -80 to +80
    if num_enabled == 1 then
        x_positions[1] = 0  -- single emitter centered
    else
        local spacing = total_span / (num_enabled - 1)
        for i = 1, num_enabled do
            x_positions[i] = math.floor(-80 + (i - 1) * spacing)
        end
    end
    local y_offset = -450

    EFFECT_EDITOR.emitters = {}
    for i, slot_info in ipairs(enabled_slots) do
        local seq_idx = slot_info.seq_index  -- 0-indexed for emitter
        local x_pos = x_positions[i] or 0
        local e = Parser.create_preview_emitter(seq_idx, x_pos, y_offset)
        e.index = i - 1  -- emitter index (0-indexed)
        print(string.format("[SEQ_TAB] Emitter %d: seq_index=%d, x=%d", i-1, seq_idx, x_pos))
        table.insert(EFFECT_EDITOR.emitters, e)
    end
    EFFECT_EDITOR.emitter_count = num_enabled

    -- Also update particle header emitter count
    if EFFECT_EDITOR.particle_header then
        EFFECT_EDITOR.particle_header.emitter_count = num_enabled
    end

    -- 3. Convert to 1-phase script (PADDED to avoid structure change)
    local original_script_size = get_current_script_size()
    local new_script = generate_padded_1phase_script(original_script_size)
    EFFECT_EDITOR.script_instructions = new_script

    -- 4. Configure for-each timeline channels (1-phase uses these)
    Parser.configure_preview_timeline(num_enabled, EFFECT_EDITOR.timeline_channels, "1phase")

    -- 5. Configure for-each screen effect track (neutral: no tint, no gradient)
    Parser.configure_preview_screen_track(EFFECT_EDITOR.color_tracks)

    -- Set custom RGB for both kf[0] and kf[1] from UI slider
    -- Durations stay as configured (kf[0]=0, kf[1]=255), but all RGB channels get the slider value
    if EFFECT_EDITOR.color_tracks and EFFECT_EDITOR.color_tracks[4] then
        local screen_track = EFFECT_EDITOR.color_tracks[4]
        local rgb_val = ui_state.screen_kf0_time

        -- kf[0] (keyframes[1] in Lua)
        if screen_track.keyframes and screen_track.keyframes[1] then
            screen_track.keyframes[1].r = rgb_val
            screen_track.keyframes[1].g = rgb_val
            screen_track.keyframes[1].b = rgb_val
            screen_track.keyframes[1].end_r = rgb_val
            screen_track.keyframes[1].end_g = rgb_val
            screen_track.keyframes[1].end_b = rgb_val
        end

        -- kf[1] (keyframes[2] in Lua)
        if screen_track.keyframes and screen_track.keyframes[2] then
            screen_track.keyframes[2].r = rgb_val
            screen_track.keyframes[2].g = rgb_val
            screen_track.keyframes[2].b = rgb_val
            screen_track.keyframes[2].end_r = rgb_val
            screen_track.keyframes[2].end_g = rgb_val
            screen_track.keyframes[2].end_b = rgb_val
        end

        print(string.format("[SEQ_TAB] Set screen kf[0] and kf[1] RGB = %d", rgb_val))
    end

    -- 6. Configure "For Each Target" camera table for stable overhead view
    -- Table index 2 = FOR-EACH-TARGET (active during spawn window)
    if EFFECT_EDITOR.camera_tables and EFFECT_EDITOR.camera_tables[2] then
        local cam_table = EFFECT_EDITOR.camera_tables[2]
        cam_table.max_keyframe = 1  -- Use keyframes 0 and 1

        -- Configure keyframe 1 (index 2 in Lua 1-indexed array)
        local kf = cam_table.keyframes[2]
        if kf then
            kf.end_frame = 2
            -- Angles: pitch=0, yaw=0, roll=0
            kf.pitch = 0
            kf.yaw = 0
            kf.roll = 0
            -- Position: X=0, Y=-425, Z=0
            kf.pos_x = 0
            kf.pos_y = -425
            kf.pos_z = 0
            -- Command: Pos Source = Direct (0x040), Interpolation = Immediate (0x0200)
            -- track_angle = true (+1), track_position = true (+2)
            -- command = 1 + 2 + 0x040 + 0x0200 = 0x243
            kf.command = 0x243
            print(string.format("[SEQ_TAB] Configured camera FOR-EACH-TARGET kf[1]: end=%d pos=(%d,%d,%d) cmd=0x%04X",
                kf.end_frame, kf.pos_x, kf.pos_y, kf.pos_z, kf.command))
        end
    end

    -- Automatically trigger Test Effect to apply preview configuration
    print("[SEQ_TAB] Auto-triggering Test Effect...")
    if ee_test_fn then
        ee_test_fn()
    end

    EFFECT_EDITOR.status_msg = "Preview mode active. Use 'Exit Preview' to restore normal mode."
end

-- Clear preview state (called when reload happens via callback)
-- This is now a NO-OP during normal preview operation.
-- The only way to exit preview is via the explicit "Exit Preview" button.
-- ee_test does NOT re-parse from .bin, so EFFECT_EDITOR.sequences survives reload.
function M.clear_preview_state()
    -- This callback is registered but intentionally does nothing.
    -- Preview mode is only exited via exit_preview_mode().
    -- Debug: print("[SEQ_TAB] clear_preview_state called, preview_active=" .. tostring(ui_state.preview_active))
end

return M
