-- ui/sound_tab.lua
-- Sound Definitions Tab for FFT Effect Editor
-- Edits Effect Flags sound channels (mode/ids) and "feds" section SMD opcodes

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local helpers = nil
local Parser = nil

function M.set_dependencies(helpers_module, parser_module)
    helpers = helpers_module
    Parser = parser_module
end

--------------------------------------------------------------------------------
-- UI State (persists across frames)
--------------------------------------------------------------------------------

local ui_state = {
    selected_feds_channel = 0,      -- 0-based index into feds channels
    selected_opcode_index = -1,     -- -1 = none selected, 0+ = selected opcode
    insert_opcode_type = 0xAC,      -- Default: Instrument
    insert_param1 = 1,              -- Default parameter value
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Sound channel modes for dropdown
local MODE_ITEMS = "DIRECT_A\0PARITY_AB\0FIRST_A_THEN_B\0FIRST_A_THEN_BC\0CYCLE_ABC\0"

local MODE_HELP = {
    [0] = "Always returns id_a",
    [1] = "Alternates: id_a, id_b, id_a, id_b...",
    [2] = "First call: id_a, then always id_b",
    [3] = "First: id_a, then alternates id_b/id_c",
    [4] = "Cycles: id_a, id_b, id_c, id_a...",
}

-- Opcode dropdown items (grouped by function)
local OPCODE_LIST = {
    -- {opcode, name, category}
    {0xAC, "Instrument", "Sound"},
    {0xE0, "Dynamics", "Sound"},
    {0xE2, "Expression", "Sound"},
    {0x94, "Octave", "Pitch"},
    {0x95, "RaiseOctave", "Pitch"},
    {0x96, "LowerOctave", "Pitch"},
    {0xD0, "SetPitchBend", "Pitch"},
    {0xD1, "AddPitchBend", "Pitch"},
    {0x80, "Rest", "Timing"},
    {0x81, "Fermata", "Timing"},
    {0xA0, "Tempo", "Timing"},
    {0x90, "EndBar", "Control"},
    {0x91, "Loop", "Control"},
    {0x98, "Repeat", "Control"},
    {0x99, "Coda", "Control"},
    {0xBA, "ReverbOn", "Effects"},
    {0xBB, "ReverbOff", "Effects"},
    {0xB0, "Flag_0x800", "Effects"},
    {0xC4, "Release", "Effects"},
    {0x40, "Note (vol=64)", "Notes"},
}

-- Build dropdown string
local OPCODE_ITEMS = ""
for _, op in ipairs(OPCODE_LIST) do
    OPCODE_ITEMS = OPCODE_ITEMS .. string.format("0x%02X %s\0", op[1], op[2])
end

-- Note decoding tables (for Note opcodes 0x00-0x7F)
local SEMITONES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
local DURATIONS = {"cust", "whole", "d.half", "half", "d.qtr", "2/3h", "qtr",
                   "d.8th", "2/3q", "8th", "d.16", "2/3e", "16th",
                   "d.32", "2/3s", "32nd", "2/3t", "d.64", "64th"}

-- Decode Note param byte to "C qtr" style string
local function decode_note_param(param)
    local semitone = math.floor(param / 19)
    local dur_idx = param % 19
    local note = SEMITONES[(semitone % 12) + 1]
    local dur = DURATIONS[dur_idx + 1] or "?"
    -- Add octave offset if semitone >= 12
    if semitone >= 12 then
        note = note .. "+" .. math.floor(semitone / 12)
    end
    return note .. " " .. dur
end

--------------------------------------------------------------------------------
-- Sound Flags Section (Effect Flags bytes 0x08-0x17)
--------------------------------------------------------------------------------

local function draw_sound_flags_section()
    local flags = EFFECT_EDITOR.sound_flags
    if not flags then
        imgui.TextUnformatted("Sound flags not loaded")
        return
    end

    if imgui.CollapsingHeader("Sound Config Channels (Effect Flags)", 32) then
        imgui.Indent()

        imgui.TextUnformatted("(These 4 channels control which sound ID is selected at runtime)")
        imgui.Spacing()

        for i = 1, 4 do
            local ch = flags[i]
            local label = string.format("Config Channel %d", i - 1)

            if imgui.TreeNode(label .. "###snd_ch" .. i) then
                local c, v

                -- Mode dropdown
                imgui.SetNextItemWidth(150)
                c, v = imgui.Combo("Mode##snd" .. i, ch.mode, MODE_ITEMS)
                if c then ch.mode = v end

                imgui.SameLine()
                imgui.TextUnformatted("  " .. (MODE_HELP[ch.mode] or ""))

                -- ID sliders on same line
                imgui.SetNextItemWidth(80)
                c, v = imgui.SliderInt("id_a##snd" .. i, ch.id_a, 0, 15)
                if c then ch.id_a = v end

                imgui.SameLine()
                imgui.SetNextItemWidth(80)
                c, v = imgui.SliderInt("id_b##snd" .. i, ch.id_b, 0, 15)
                if c then ch.id_b = v end

                imgui.SameLine()
                imgui.SetNextItemWidth(80)
                c, v = imgui.SliderInt("id_c##snd" .. i, ch.id_c, 0, 15)
                if c then ch.id_c = v end

                -- Raw bytes display
                imgui.TextUnformatted(string.format("  Raw: %02X %02X %02X %02X",
                    ch.mode, ch.id_a, ch.id_b, ch.id_c))

                imgui.TreePop()
            end
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- feds Header Section
--------------------------------------------------------------------------------

local function draw_feds_header_section()
    local def = EFFECT_EDITOR.sound_definition
    if not def then
        imgui.TextUnformatted("No feds section loaded")
        return
    end

    if imgui.CollapsingHeader("feds Section Header", 32) then
        imgui.Indent()

        imgui.TextUnformatted(string.format("Magic: \"%s\"", def.magic))
        imgui.TextUnformatted(string.format("Data Size: %d bytes", def.data_size))

        -- Channel count (calculated from pair_count_plus1)
        local num_pairs = def.pair_count_plus1 - 1
        imgui.TextUnformatted(string.format("Channels: %d (%d pairs)  [pair_count_plus1 = %d]",
            def.num_channels, num_pairs, def.pair_count_plus1))

        -- Resource ID (editable)
        local c, v
        imgui.SetNextItemWidth(100)
        c, v = imgui.SliderInt("Resource ID##feds", def.resource_id, 0, 255)
        if c then def.resource_id = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("  (SPU bank: 0x%04X0000)", def.resource_id))

        -- Data offset
        imgui.TextUnformatted(string.format("Data Offset: 0x%04X", def.data_offset))

        -- Channel offset table (collapsible)
        if imgui.TreeNode("Channel Offsets##feds_offsets") then
            for i = 1, def.num_channels do
                local ch = def.channels[i]
                local ch_size = ch and #Parser.serialize_smd_opcodes(ch.opcodes) or 0
                imgui.TextUnformatted(string.format("  [%d] offset=0x%04X, %d opcodes, %d bytes",
                    i - 1, def.channel_offsets[i] or 0, ch and #ch.opcodes or 0, ch_size))
            end
            imgui.TreePop()
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- SMD Opcode Editor Helpers
--------------------------------------------------------------------------------

local function get_opcode_list_index(opcode_byte)
    for i, op in ipairs(OPCODE_LIST) do
        if op[1] == opcode_byte then
            return i - 1  -- 0-based for imgui
        end
    end
    -- Default to first item if not found
    return 0
end

local function draw_opcode_param_editor(op, idx)
    local c, v
    local changed = false

    if op.opcode < 0x80 then
        -- Note: volume in opcode (0-127), pitch/duration in param
        imgui.SetNextItemWidth(60)
        c, v = imgui.SliderInt("Vol##op" .. idx, op.opcode, 0, 127)
        if c then op.opcode = v; changed = true end

        imgui.SameLine()
        imgui.SetNextItemWidth(60)
        c, v = imgui.SliderInt("Pitch##op" .. idx, op.params[1] or 0, 0, 255)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "Octave" then
        imgui.SetNextItemWidth(60)
        c, v = imgui.SliderInt("Octave##op" .. idx, op.params[1] or 0, 0, 7)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "Instrument" then
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Sample##op" .. idx, op.params[1] or 0, 0, 127)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "Dynamics" or op.name == "Expression" then
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Level##op" .. idx, op.params[1] or 0, 0, 127)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "Rest" or op.name == "Fermata" then
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Duration##op" .. idx, op.params[1] or 0, 0, 255)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "Tempo" then
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Tempo##op" .. idx, op.params[1] or 0, 0, 255)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "Repeat" then
        imgui.SetNextItemWidth(60)
        c, v = imgui.SliderInt("Count##op" .. idx, op.params[1] or 0, 0, 255)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "SetPitchBend" or op.name == "AddPitchBend" then
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Bend##op" .. idx, op.params[1] or 0, 0, 255)
        if c then op.params[1] = v; changed = true end

    elseif op.name == "Release" then
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Release##op" .. idx, op.params[1] or 0, 0, 255)
        if c then op.params[1] = v; changed = true end

    elseif #op.params > 0 then
        -- Generic 1-param opcode
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Param##op" .. idx, op.params[1] or 0, 0, 255)
        if c then op.params[1] = v; changed = true end
    else
        -- No params (EndBar, Loop, etc.)
        imgui.TextUnformatted("(no params)")
    end

    return changed
end

--------------------------------------------------------------------------------
-- SMD Instruction Streams Section
--------------------------------------------------------------------------------

local function draw_smd_channels_section()
    local def = EFFECT_EDITOR.sound_definition
    if not def or not def.channels or def.num_channels == 0 then
        imgui.TextUnformatted("No SMD channels loaded")
        return
    end

    if imgui.CollapsingHeader("SMD Instruction Streams", 32) then
        imgui.Indent()

        -- Channel selector
        local channel_items = ""
        for i = 1, def.num_channels do
            local pair_idx = math.floor((i - 1) / 2)
            local side = ((i - 1) % 2 == 0) and "L" or "R"
            channel_items = channel_items .. string.format("Ch %d (Pair %d %s)\0", i - 1, pair_idx, side)
        end

        imgui.SetNextItemWidth(180)
        local c, v = imgui.Combo("Channel##smd_ch", ui_state.selected_feds_channel, channel_items)
        if c then
            ui_state.selected_feds_channel = v
            ui_state.selected_opcode_index = -1  -- Reset selection on channel change
        end

        local ch = def.channels[ui_state.selected_feds_channel + 1]
        if not ch then
            imgui.TextUnformatted("No channel data")
            imgui.Unindent()
            return
        end

        local raw_size = #Parser.serialize_smd_opcodes(ch.opcodes)
        imgui.SameLine()
        imgui.TextUnformatted(string.format("(%d opcodes, %d bytes)", #ch.opcodes, raw_size))

        imgui.Separator()

        -- Insert controls row
        imgui.TextUnformatted("Insert:")
        imgui.SameLine()

        -- Opcode type dropdown
        local insert_idx = get_opcode_list_index(ui_state.insert_opcode_type)
        imgui.SetNextItemWidth(150)
        c, v = imgui.Combo("##insert_op", insert_idx, OPCODE_ITEMS)
        if c then
            ui_state.insert_opcode_type = OPCODE_LIST[v + 1][1]
        end

        -- Parameter for insert (if applicable)
        local insert_name, insert_param_count = Parser.get_opcode_info(ui_state.insert_opcode_type)
        if insert_param_count > 0 then
            imgui.SameLine()
            imgui.SetNextItemWidth(60)
            c, v = imgui.SliderInt("##insert_param", ui_state.insert_param1, 0, 127)
            if c then ui_state.insert_param1 = v end
        end

        -- Insert buttons
        imgui.SameLine()
        local cursor = ui_state.selected_opcode_index
        local can_insert = true

        if imgui.Button("+ Above##insert") then
            local new_op = Parser.create_opcode(ui_state.insert_opcode_type)
            if #new_op.params > 0 then
                new_op.params[1] = ui_state.insert_param1
            end
            if cursor >= 0 then
                table.insert(ch.opcodes, cursor + 1, new_op)
                ui_state.selected_opcode_index = cursor + 1
            else
                table.insert(ch.opcodes, 1, new_op)
                ui_state.selected_opcode_index = 0
            end
        end

        imgui.SameLine()
        if imgui.Button("+ Below##insert") then
            local new_op = Parser.create_opcode(ui_state.insert_opcode_type)
            if #new_op.params > 0 then
                new_op.params[1] = ui_state.insert_param1
            end
            if cursor >= 0 then
                table.insert(ch.opcodes, cursor + 2, new_op)
                ui_state.selected_opcode_index = cursor + 1
            else
                table.insert(ch.opcodes, new_op)
                ui_state.selected_opcode_index = #ch.opcodes - 1
            end
        end

        imgui.SameLine()
        if #ch.opcodes > 0 and cursor >= 0 then
            if imgui.Button("Delete##del_op") then
                table.remove(ch.opcodes, cursor + 1)
                if ui_state.selected_opcode_index >= #ch.opcodes then
                    ui_state.selected_opcode_index = #ch.opcodes - 1
                end
            end
        end
        -- Note: Delete button only shown when selection is valid (above)

        imgui.Separator()

        -- Opcode list (scrollable) - use remaining height, minimum 150px
        local avail_y = imgui.GetContentRegionAvail()
        local list_height = math.max(150, avail_y - 10)  -- Leave small margin
        imgui.BeginChild("##opcode_list", 0, list_height, true)

        for i, op in ipairs(ch.opcodes) do
            local idx = i - 1  -- 0-based for display
            local is_selected = (idx == ui_state.selected_opcode_index)

            -- Build display string
            local param_str = ""
            if #op.params > 0 then
                local parts = {}
                for _, p in ipairs(op.params) do
                    table.insert(parts, string.format("%02X", p))
                end
                param_str = " [" .. table.concat(parts, " ") .. "]"
            end

            -- For Note opcodes (0x00-0x7F), add decoded pitch/duration info
            local note_info = ""
            if op.opcode < 0x80 and #op.params >= 1 then
                note_info = " " .. decode_note_param(op.params[1])
            end

            local label = string.format("%3d: %02X %-14s%s%s###op_%d",
                idx, op.opcode, op.name, param_str, note_info, i)

            -- Selectable row
            if imgui.Selectable(label, is_selected) then
                if is_selected then
                    ui_state.selected_opcode_index = -1  -- Deselect on second click
                else
                    ui_state.selected_opcode_index = idx
                end
            end

            -- If selected, show inline editor below
            if is_selected then
                imgui.Indent()
                draw_opcode_param_editor(op, i)
                imgui.Unindent()
            end
        end

        if #ch.opcodes == 0 then
            imgui.TextUnformatted("(empty channel - use Insert to add opcodes)")
        end

        imgui.EndChild()

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Reference Section (with complete opcode table)
--------------------------------------------------------------------------------

local function draw_reference_section()
    if imgui.CollapsingHeader("SMD Opcode Reference") then
        imgui.Indent()

        -- Four-column layout for opcode reference
        -- ImGuiTableFlags_SizingFixedFit = 1 << 13 = 8192
        -- ImGuiTableFlags_RowBg = 1 << 6 = 64
        local table_flags = 8192 + 64  -- SizingFixedFit + RowBg
        if imgui.BeginTable("##opcode_ref", 4, table_flags) then
            imgui.TableSetupColumn("Opcode", 0, 55)
            imgui.TableSetupColumn("Name", 0, 95)
            imgui.TableSetupColumn("Params", 0, 45)
            imgui.TableSetupColumn("Description", 0, 250)
            imgui.TableHeadersRow()

            -- Sound/Instrument opcodes
            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("00-7F"); imgui.TableNextColumn()
            imgui.TextUnformatted("Note"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Play note (vol in opcode, pitch/dur in param)")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("AC"); imgui.TableNextColumn()
            imgui.TextUnformatted("Instrument"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Select VAG sample from WAVESET")

            -- Timing/Control
            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("80"); imgui.TableNextColumn()
            imgui.TextUnformatted("Rest"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Wait N ticks")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("81"); imgui.TableNextColumn()
            imgui.TextUnformatted("Fermata"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Extend previous note")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("90"); imgui.TableNextColumn()
            imgui.TextUnformatted("EndBar"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("End channel playback")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("91"); imgui.TableNextColumn()
            imgui.TextUnformatted("Loop"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Loop from current position")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("98"); imgui.TableNextColumn()
            imgui.TextUnformatted("Repeat"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Begin loop N times")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("99"); imgui.TableNextColumn()
            imgui.TextUnformatted("Coda"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("End loop / loop target")

            -- Pitch opcodes
            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("94"); imgui.TableNextColumn()
            imgui.TextUnformatted("Octave"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Set octave (0-7)")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("95"); imgui.TableNextColumn()
            imgui.TextUnformatted("RaiseOctave"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Increment octave")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("96"); imgui.TableNextColumn()
            imgui.TextUnformatted("LowerOctave"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Decrement octave")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("D0"); imgui.TableNextColumn()
            imgui.TextUnformatted("SetPitchBend"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Set pitch bend value")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("D1"); imgui.TableNextColumn()
            imgui.TextUnformatted("AddPitchBend"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Add to pitch bend")

            -- Volume/Expression
            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("A0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Tempo"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Set tempo")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("E0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Dynamics"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Set volume (0-127)")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("E2"); imgui.TableNextColumn()
            imgui.TextUnformatted("Expression"); imgui.TableNextColumn()
            imgui.TextUnformatted("2"); imgui.TableNextColumn()
            imgui.TextUnformatted("Set expression/modulation")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("C4"); imgui.TableNextColumn()
            imgui.TextUnformatted("Release"); imgui.TableNextColumn()
            imgui.TextUnformatted("1"); imgui.TableNextColumn()
            imgui.TextUnformatted("Set note release/decay")

            -- Effects
            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("BA"); imgui.TableNextColumn()
            imgui.TextUnformatted("ReverbOn"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Enable reverb")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("BB"); imgui.TableNextColumn()
            imgui.TextUnformatted("ReverbOff"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Disable reverb")

            imgui.TableNextRow(); imgui.TableNextColumn()
            imgui.TextUnformatted("B0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Flag_0x800"); imgui.TableNextColumn()
            imgui.TextUnformatted("0"); imgui.TableNextColumn()
            imgui.TextUnformatted("Set channel flag bit")

            imgui.EndTable()
        end

        imgui.Spacing()
        imgui.TextUnformatted("Undocumented Opcodes (by param count):")
        imgui.TextUnformatted("  3-param: 8E 9C 9E B8 C1 D8 D9 E4 E5 EC ED F0")
        imgui.TextUnformatted("  2-param: 97 9D A2 A7 C7 D3 D4 EA F1 F2")
        imgui.TextUnformatted("  1-param: A1 A4 A5 A6 A9 AA AD B4 B5 C0 C2 C3 C5 C6 C8 C9 CA D2 D6 D7 E1 E8 E9 F5 F6 F7")
        imgui.TextUnformatted("  0-param: 8A 8D 8F 9A AE AF B1 B2 B3 B6 B7 D5 DA DB DC E3 E6 E7 EB EE EF")
        imgui.Spacing()
        imgui.TextUnformatted("NOP opcodes: 82-89, 8B-8C, 92-93, 9B, 9F, A3, A8, AB, B9, BC-BF, CB-CF, DD-DF, F3-F4, F8-FF")

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Note Opcode Reference (0x00-0x7F)
--------------------------------------------------------------------------------

local function draw_note_reference_section()
    if imgui.CollapsingHeader("Note Opcode Reference (0x00-0x7F)") then
        imgui.Indent()

        imgui.TextUnformatted("FORMAT: [velocity byte 0x00-0x7F] [param byte]")
        imgui.TextUnformatted("  Velocity = opcode byte (0x00=silent, 0x7F=loudest)")
        imgui.TextUnformatted("  Param encodes pitch + duration:")
        imgui.TextUnformatted("    Semitone = param / 19  (0=C, 1=C#, 2=D, ... 11=B)")
        imgui.TextUnformatted("    Duration = param % 19  (index into table below)")
        imgui.Spacing()

        -- Duration table
        imgui.TextUnformatted("DURATION TABLE (param % 19):")
        local dur_flags = 8192 + 64  -- SizingFixedFit + RowBg
        if imgui.BeginTable("##duration_ref", 4, dur_flags) then
            imgui.TableSetupColumn("Idx", 0, 30)
            imgui.TableSetupColumn("Ticks", 0, 45)
            imgui.TableSetupColumn("Name", 0, 100)
            imgui.TableSetupColumn("Note", 0, 120)
            imgui.TableHeadersRow()

            local durations = {
                {0, 0x00, "Custom", "Read next byte for raw ticks"},
                {1, 0xC0, "Whole", "192 ticks (4 beats)"},
                {2, 0x90, "Dotted Half", "144 ticks (3 beats)"},
                {3, 0x60, "Half", "96 ticks (2 beats)"},
                {4, 0x48, "Dotted Qtr", "72 ticks (1.5 beats)"},
                {5, 0x40, "2/3 Half", "64 ticks (triplet)"},
                {6, 0x30, "Quarter", "48 ticks (1 beat)"},
                {7, 0x24, "Dotted 8th", "36 ticks"},
                {8, 0x20, "2/3 Qtr", "32 ticks (triplet)"},
                {9, 0x18, "Eighth", "24 ticks (1/2 beat)"},
                {10, 0x12, "Dotted 16th", "18 ticks"},
                {11, 0x10, "2/3 8th", "16 ticks (triplet)"},
                {12, 0x0C, "16th", "12 ticks (1/4 beat)"},
                {13, 0x09, "Dotted 32nd", "9 ticks"},
                {14, 0x08, "2/3 16th", "8 ticks (triplet)"},
                {15, 0x06, "32nd", "6 ticks (1/8 beat)"},
                {16, 0x04, "2/3 32nd", "4 ticks (triplet)"},
                {17, 0x03, "Dotted 64th", "3 ticks"},
                {18, 0x02, "64th", "2 ticks"},
            }

            for _, d in ipairs(durations) do
                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.TextUnformatted(tostring(d[1]))
                imgui.TableNextColumn()
                imgui.TextUnformatted(string.format("0x%02X", d[2]))
                imgui.TableNextColumn()
                imgui.TextUnformatted(d[3])
                imgui.TableNextColumn()
                imgui.TextUnformatted(d[4])
            end

            imgui.EndTable()
        end

        imgui.Spacing()
        imgui.TextUnformatted("SEMITONE MAPPING (param / 19):")
        imgui.TextUnformatted("  0=C  1=C#  2=D  3=D#  4=E  5=F  6=F#  7=G  8=G#  9=A  10=A#  11=B")
        imgui.Spacing()

        imgui.TextUnformatted("PARAM EXAMPLES:")
        imgui.TextUnformatted("  0x00 = C custom    0x06 = C quarter    0x09 = C eighth")
        imgui.TextUnformatted("  0x13 = C# custom   0x19 = C# quarter   0x1C = C# 16th")
        imgui.TextUnformatted("  0x26 = D custom    0x2C = D quarter    0x2F = D eighth")
        imgui.Spacing()

        imgui.TextUnformatted("OCTAVE: Set with 0x94 (param 0-7). Middle C = octave 4.")
        imgui.TextUnformatted("  Adjust with 0x95 (raise) / 0x96 (lower)")

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.header then
        imgui.TextUnformatted("No effect loaded.")
        return
    end

    -- Section 1: Opcode Reference (collapsed by default, at top for quick access)
    draw_reference_section()

    -- Section 2: Note Opcode Reference (collapsed by default)
    draw_note_reference_section()

    -- Section 3: Effect Flags Sound Channels (collapsible)
    draw_sound_flags_section()

    -- Section 4: feds Header (collapsible)
    draw_feds_header_section()

    imgui.Separator()

    -- Section 5: SMD Instruction Streams (at bottom - expands to fill remaining space)
    draw_smd_channels_section()
end

return M
