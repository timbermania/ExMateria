-- ui/sequences_tab.lua
-- Animation Sequences Tab for FFT Effect Editor
-- Edits sprite animation sequences (which frameset to display, for how long)

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local helpers = nil
local apply_all_edits_fn = nil
local Parser = nil

function M.set_dependencies(helpers_module, apply_all_edits, parser_module)
    helpers = helpers_module
    apply_all_edits_fn = apply_all_edits
    Parser = parser_module
end

--------------------------------------------------------------------------------
-- UI State (persists across frames)
--------------------------------------------------------------------------------

local ui_state = {
    selected_seq = 0,           -- Currently selected sequence index (0-indexed)
    selected_instr = -1,        -- Currently selected instruction (-1 = none)
    insert_opcode_type = 1,     -- 1=FRAME, 2=LOOP, 3=SET_OFFSET, 4=ADD_OFFSET
    show_reference = false,     -- Toggle reference panel
}

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

    -- Apply button
    if imgui.Button("Apply Changes", 150, 30) then
        if apply_all_edits_fn then
            apply_all_edits_fn()
        end
    end

    imgui.SameLine()
    imgui.TextUnformatted(string.format("Total: %d sequences, %d bytes",
        #sequences,
        Parser.calculate_animation_section_size(sequences)))
end

return M
