-- ui/script_tab.lua
-- Script Bytecode Tab for FFT Effect Editor
-- Edits effect script instructions (dynamic section size)

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
    selected_index = -1,        -- -1 = none selected, 0+ = selected instruction
    insert_opcode = 0,          -- Default: goto_yield
    show_reference = false,     -- Toggle reference panel
}

--------------------------------------------------------------------------------
-- Script Templates
--------------------------------------------------------------------------------

-- Pattern 2: Single animation script (30 bytes)
-- Uses animate_tick (opcode 40) for single-phase timeline
local function generate_pattern2_script()
    local insts = {}

    -- 0x00: set_texture_page
    table.insert(insts, {opcode_id = 5, flags = 0, params = {}})
    -- 0x02: init_physics_params
    table.insert(insts, {opcode_id = 39, flags = 0, params = {}})
    -- 0x04: branch_anim_done → 0x10
    table.insert(insts, {opcode_id = 29, flags = 0, params = {target = 0x10}})
    -- 0x08: animate_tick
    table.insert(insts, {opcode_id = 40, flags = 0, params = {}})
    -- 0x0A: update_all_particles
    table.insert(insts, {opcode_id = 37, flags = 0, params = {}})
    -- 0x0C: goto_yield → 0x04
    table.insert(insts, {opcode_id = 0, flags = 0, params = {target = 0x04}})
    -- 0x10: update_all_particles (wait loop)
    table.insert(insts, {opcode_id = 37, flags = 0, params = {}})
    -- 0x12: branch_count_eq 0 → 0x1C
    table.insert(insts, {opcode_id = 22, flags = 0, params = {value = 0, target = 0x1C}})
    -- 0x18: goto_yield → 0x10
    table.insert(insts, {opcode_id = 0, flags = 0, params = {target = 0x10}})
    -- 0x1C: end
    table.insert(insts, {opcode_id = 4, flags = 0, params = {}})

    -- Fill in names and sizes from opcode table
    for _, inst in ipairs(insts) do
        local info = Parser.SCRIPT_OPCODES[inst.opcode_id]
        inst.name = info.name
        inst.size = info.size
        inst.opcode_word = inst.opcode_id
    end

    return insts
end

-- Pattern 1: Multi-target script with child spawning (62 bytes)
-- Uses process_timeline_frame (opcode 41) for two-phase timeline
local function generate_pattern1_script()
    local insts = {}

    -- ROOT SCRIPT (0x00-0x22)
    -- 0x00: set_texture_page
    table.insert(insts, {opcode_id = 5, flags = 0, params = {}})
    -- 0x02: init_physics_params
    table.insert(insts, {opcode_id = 39, flags = 0, params = {}})
    -- 0x04: branch_target_type → 0x22 (skip to end if single target)
    table.insert(insts, {opcode_id = 31, flags = 0, params = {target = 0x22}})
    -- 0x08: branch_anim_done_cplx → 0x16
    table.insert(insts, {opcode_id = 30, flags = 0, params = {target = 0x16}})
    -- 0x0C: process_timeline_frame child=0x24
    table.insert(insts, {opcode_id = 41, flags = 0, params = {phase = 0x24}})
    -- 0x10: update_all_particles
    table.insert(insts, {opcode_id = 37, flags = 0, params = {}})
    -- 0x12: goto_yield → 0x08
    table.insert(insts, {opcode_id = 0, flags = 0, params = {target = 0x08}})
    -- 0x16: update_all_particles (wait loop)
    table.insert(insts, {opcode_id = 37, flags = 0, params = {}})
    -- 0x18: branch_count_eq 0 → 0x22
    table.insert(insts, {opcode_id = 22, flags = 0, params = {value = 0, target = 0x22}})
    -- 0x1E: goto_yield → 0x16
    table.insert(insts, {opcode_id = 0, flags = 0, params = {target = 0x16}})
    -- 0x22: end
    table.insert(insts, {opcode_id = 4, flags = 0, params = {}})

    -- CHILD SCRIPT (0x24-0x3C)
    -- 0x24: branch_anim_done → 0x30
    table.insert(insts, {opcode_id = 29, flags = 0, params = {target = 0x30}})
    -- 0x28: animate_tick
    table.insert(insts, {opcode_id = 40, flags = 0, params = {}})
    -- 0x2A: update_all_particles
    table.insert(insts, {opcode_id = 37, flags = 0, params = {}})
    -- 0x2C: goto_yield → 0x24
    table.insert(insts, {opcode_id = 0, flags = 0, params = {target = 0x24}})
    -- 0x30: update_all_particles (wait loop)
    table.insert(insts, {opcode_id = 37, flags = 0, params = {}})
    -- 0x32: branch_count_eq 0 → 0x3C
    table.insert(insts, {opcode_id = 22, flags = 0, params = {value = 0, target = 0x3C}})
    -- 0x38: goto_yield → 0x30
    table.insert(insts, {opcode_id = 0, flags = 0, params = {target = 0x30}})
    -- 0x3C: end
    table.insert(insts, {opcode_id = 4, flags = 0, params = {}})

    -- Fill in names and sizes from opcode table
    for _, inst in ipairs(insts) do
        local info = Parser.SCRIPT_OPCODES[inst.opcode_id]
        inst.name = info.name
        inst.size = info.size
        inst.opcode_word = inst.opcode_id
    end

    return insts
end

-- Detect current script pattern
local function detect_script_pattern()
    local insts = EFFECT_EDITOR.script_instructions
    if not insts or #insts == 0 then return "unknown" end

    -- Look for key opcodes
    local has_process_timeline = false
    local has_animate_tick = false
    local has_branch_target_type = false

    for _, inst in ipairs(insts) do
        if inst.opcode_id == 41 then has_process_timeline = true end
        if inst.opcode_id == 40 then has_animate_tick = true end
        if inst.opcode_id == 31 then has_branch_target_type = true end
    end

    if has_process_timeline and has_branch_target_type then
        return "Pattern 1"
    elseif has_animate_tick and not has_process_timeline then
        return "Pattern 2"
    else
        return "Custom"
    end
end

--------------------------------------------------------------------------------
-- Opcode Categories for Reference
--------------------------------------------------------------------------------

local OPCODE_CATEGORIES = {
    {name = "Control Flow", ids = {0, 1, 2, 3, 4}},
    {name = "Setup", ids = {5, 6, 7}},
    {name = "Position/Transform", ids = {8, 9, 10, 11, 12, 13, 14, 15, 36}},
    {name = "Script Register", ids = {16, 32, 33, 34, 35}},
    {name = "Branch (Register)", ids = {17, 18, 19, 20, 21, 28}},
    {name = "Branch (Count)", ids = {22, 23, 24, 25}},
    {name = "Branch (Child)", ids = {26, 27}},
    {name = "Branch (Animation)", ids = {29, 30, 31}},
    {name = "Animation/Particles", ids = {37, 38, 39, 40, 41, 42, 43}},
    {name = "No Operation", ids = {44, 45}},
}

--------------------------------------------------------------------------------
-- Build Opcode Dropdown Items
--------------------------------------------------------------------------------

local OPCODE_ITEMS = nil  -- Will be built on first use

local function build_opcode_items()
    if OPCODE_ITEMS then return OPCODE_ITEMS end

    local items = ""
    for id = 0, 45 do
        local info = Parser.SCRIPT_OPCODES[id]
        if info then
            items = items .. string.format("%02d %-22s\0", id, info.name)
        end
    end
    OPCODE_ITEMS = items
    return items
end

--------------------------------------------------------------------------------
-- Parameter Editor for Selected Instruction
--------------------------------------------------------------------------------

local function draw_instruction_params(inst, idx)
    local info = Parser.SCRIPT_OPCODES[inst.opcode_id]
    if not info or #info.params == 0 then
        imgui.TextUnformatted("(no parameters)")
        return false
    end

    local changed = false
    local c, v

    for _, param in ipairs(info.params) do
        local val = inst.params[param.name] or 0

        imgui.PushItemWidth(100)

        if param.type == "offset" then
            -- Offset parameters: show as hex with decimal input
            c, v = imgui.InputInt(param.name .. "##" .. idx, val, 2, 16)
            if c then
                inst.params[param.name] = v
                changed = true
            end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("(0x%04X)", val >= 0 and val or (val + 65536)))

        elseif param.type == "s16" then
            -- Signed 16-bit: slider for common range, allow overflow
            c, v = imgui.SliderInt(param.name .. "##" .. idx, val, -32768, 32767)
            if c then
                inst.params[param.name] = v
                changed = true
            end

        elseif param.type == "ptr" then
            -- Pointer: show as hex
            c, v = imgui.InputInt(param.name .. "##" .. idx, val, 1, 16)
            if c then
                inst.params[param.name] = v
                changed = true
            end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("(0x%04X)", val >= 0 and val or (val + 65536)))

        else
            -- Generic fallback
            c, v = imgui.InputInt(param.name .. "##" .. idx, val, 1, 16)
            if c then
                inst.params[param.name] = v
                changed = true
            end
        end

        imgui.PopItemWidth()
    end

    -- Flags editor (bits 9-15 of opcode word)
    if inst.flags and inst.flags ~= 0 then
        imgui.PushItemWidth(60)
        c, v = imgui.InputInt("flags##" .. idx, inst.flags, 1, 1)
        if c then
            inst.flags = math.max(0, math.min(127, v))
            inst.opcode_word = inst.opcode_id + (inst.flags * 512)
            changed = true
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        imgui.TextUnformatted("(bits 9-15)")
    end

    return changed
end

--------------------------------------------------------------------------------
-- Format Instruction for Display
--------------------------------------------------------------------------------

local function format_instruction(inst)
    local info = Parser.SCRIPT_OPCODES[inst.opcode_id]
    if not info then
        return string.format("[%02d] unknown", inst.opcode_id)
    end

    -- Build parameter string
    local param_str = ""
    if #info.params > 0 then
        local parts = {}
        for _, p in ipairs(info.params) do
            local val = inst.params[p.name] or 0
            if p.type == "offset" then
                table.insert(parts, string.format("->0x%04X", val >= 0 and val or (val + 65536)))
            else
                table.insert(parts, string.format("%d", val))
            end
        end
        param_str = " " .. table.concat(parts, ", ")
    end

    -- Flags indicator
    local flags_str = ""
    if inst.flags and inst.flags ~= 0 then
        flags_str = string.format(" [f=%d]", inst.flags)
    end

    return string.format("%-22s%s%s", info.name, param_str, flags_str)
end

--------------------------------------------------------------------------------
-- Instruction List Section
--------------------------------------------------------------------------------

local function draw_instruction_list()
    local insts = EFFECT_EDITOR.script_instructions
    if not insts or #insts == 0 then
        imgui.TextUnformatted("No script instructions loaded")
        return
    end

    -- Header info
    local total_size = Parser.calculate_script_size(insts)
    imgui.TextUnformatted(string.format("Instructions: %d  Size: %d bytes", #insts, total_size))

    -- Recalculate offsets for display
    Parser.recalculate_script_offsets(insts)

    imgui.Separator()

    -- Insert controls
    imgui.TextUnformatted("Insert:")
    imgui.SameLine()

    -- Opcode dropdown
    imgui.PushItemWidth(200)
    local items = build_opcode_items()
    local c, v = imgui.Combo("##insert_op", ui_state.insert_opcode, items)
    if c then ui_state.insert_opcode = v end
    imgui.PopItemWidth()

    imgui.SameLine()
    if imgui.Button("+ Above##script") then
        local new_inst = Parser.create_script_instruction(ui_state.insert_opcode)
        local pos = ui_state.selected_index >= 0 and (ui_state.selected_index + 1) or 1
        table.insert(insts, pos, new_inst)
        Parser.recalculate_script_offsets(insts)
        ui_state.selected_index = pos - 1
    end

    imgui.SameLine()
    if imgui.Button("+ Below##script") then
        local new_inst = Parser.create_script_instruction(ui_state.insert_opcode)
        local pos = ui_state.selected_index >= 0 and (ui_state.selected_index + 2) or (#insts + 1)
        table.insert(insts, pos, new_inst)
        Parser.recalculate_script_offsets(insts)
        ui_state.selected_index = pos - 1
    end

    -- Delete button (only when selection valid)
    if ui_state.selected_index >= 0 and ui_state.selected_index < #insts then
        imgui.SameLine()
        if imgui.Button("Delete##script") then
            table.remove(insts, ui_state.selected_index + 1)
            Parser.recalculate_script_offsets(insts)
            if ui_state.selected_index >= #insts then
                ui_state.selected_index = #insts - 1
            end
        end
    end

    -- Duplicate button
    if ui_state.selected_index >= 0 and ui_state.selected_index < #insts then
        imgui.SameLine()
        if imgui.Button("Dup##script") then
            local orig = insts[ui_state.selected_index + 1]
            local new_inst = Parser.create_script_instruction(orig.opcode_id)
            new_inst.flags = orig.flags
            for k, val in pairs(orig.params) do
                new_inst.params[k] = val
            end
            table.insert(insts, ui_state.selected_index + 2, new_inst)
            Parser.recalculate_script_offsets(insts)
            ui_state.selected_index = ui_state.selected_index + 1
        end
    end

    imgui.Separator()

    -- Instruction list (scrollable)
    local avail_y = imgui.GetContentRegionAvail()
    local list_height = math.max(200, avail_y - 10)
    imgui.BeginChild("##script_list", 0, list_height, true)

    for i, inst in ipairs(insts) do
        local idx = i - 1  -- 0-based for display
        local is_selected = (idx == ui_state.selected_index)

        -- Format: OFFSET: [ID] name params
        local display_str = format_instruction(inst)
        local label = string.format("%04X: [%02d] %s###inst_%d",
            inst.offset, inst.opcode_id, display_str, i)

        -- Selectable row
        if imgui.Selectable(label, is_selected) then
            if is_selected then
                ui_state.selected_index = -1  -- Deselect on second click
            else
                ui_state.selected_index = idx
            end
        end

        -- If selected, show inline parameter editor
        if is_selected then
            imgui.Indent()
            draw_instruction_params(inst, i)
            imgui.Unindent()
        end
    end

    imgui.EndChild()
end

--------------------------------------------------------------------------------
-- Opcode Reference Section
--------------------------------------------------------------------------------

local function draw_reference_section()
    if imgui.CollapsingHeader("Script Opcode Reference") then
        imgui.Indent()

        -- Table with opcode info
        local table_flags = 8192 + 64  -- SizingFixedFit + RowBg
        if imgui.BeginTable("##script_ref", 4, table_flags) then
            imgui.TableSetupColumn("ID", 0, 30)
            imgui.TableSetupColumn("Name", 0, 150)
            imgui.TableSetupColumn("Size", 0, 35)
            imgui.TableSetupColumn("Parameters", 0, 200)
            imgui.TableHeadersRow()

            for id = 0, 45 do
                local info = Parser.SCRIPT_OPCODES[id]
                if info then
                    imgui.TableNextRow()
                    imgui.TableNextColumn()
                    imgui.TextUnformatted(string.format("%02d", id))
                    imgui.TableNextColumn()
                    imgui.TextUnformatted(info.name)
                    imgui.TableNextColumn()
                    imgui.TextUnformatted(tostring(info.size))
                    imgui.TableNextColumn()

                    if #info.params > 0 then
                        local param_names = {}
                        for _, p in ipairs(info.params) do
                            table.insert(param_names, p.name .. ":" .. p.type)
                        end
                        imgui.TextUnformatted(table.concat(param_names, ", "))
                    else
                        imgui.TextUnformatted("(none)")
                    end
                end
            end

            imgui.EndTable()
        end

        imgui.Spacing()
        imgui.TextUnformatted("Opcode Categories:")
        for _, cat in ipairs(OPCODE_CATEGORIES) do
            local id_strs = {}
            for _, id in ipairs(cat.ids) do
                table.insert(id_strs, tostring(id))
            end
            imgui.TextUnformatted(string.format("  %s: %s", cat.name, table.concat(id_strs, ", ")))
        end

        imgui.Spacing()
        imgui.TextUnformatted("Script Entry Points:")
        imgui.TextUnformatted("  0x00: Main effect entry (root script)")
        imgui.TextUnformatted("  0x24: Common child entry (Pattern 1 scripts)")
        imgui.Spacing()
        imgui.TextUnformatted("Pattern 1: 64 bytes (root + child scripts)")
        imgui.TextUnformatted("Pattern 2: 36 bytes (single script)")

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Branch Target Reference Section
--------------------------------------------------------------------------------

local function draw_branch_reference()
    if not EFFECT_EDITOR.script_instructions then return end

    if imgui.CollapsingHeader("Branch Target Analysis") then
        imgui.Indent()

        local insts = EFFECT_EDITOR.script_instructions

        -- Build offset -> instruction index map
        local offset_map = {}
        for i, inst in ipairs(insts) do
            offset_map[inst.offset] = i
        end

        -- Find all branch instructions and their targets
        local branches = {}
        for i, inst in ipairs(insts) do
            local info = Parser.SCRIPT_OPCODES[inst.opcode_id]
            if info then
                for _, p in ipairs(info.params) do
                    if p.type == "offset" and p.name == "target" then
                        local target = inst.params.target or 0
                        local target_idx = offset_map[target]
                        table.insert(branches, {
                            from_idx = i,
                            from_offset = inst.offset,
                            opcode = inst.name,
                            target_offset = target,
                            target_idx = target_idx,
                            valid = target_idx ~= nil
                        })
                    end
                end
            end
        end

        if #branches == 0 then
            imgui.TextUnformatted("No branch instructions found")
        else
            imgui.TextUnformatted(string.format("Found %d branch instructions:", #branches))
            imgui.Spacing()

            for _, b in ipairs(branches) do
                local status = b.valid and "" or " [INVALID TARGET]"
                local target_str = b.target_idx and string.format("inst #%d", b.target_idx) or "???"
                imgui.TextUnformatted(string.format("  #%d (0x%04X) %s -> 0x%04X (%s)%s",
                    b.from_idx, b.from_offset, b.opcode, b.target_offset, target_str, status))
            end
        end

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

    -- Script Templates section
    if imgui.CollapsingHeader("Script Templates") then
        imgui.Indent()

        local current_pattern = detect_script_pattern()
        local current_size = Parser.calculate_script_size(EFFECT_EDITOR.script_instructions or {})
        imgui.TextUnformatted(string.format("Current: %s (%d bytes)", current_pattern, current_size))
        imgui.Spacing()

        -- Pattern 2 button
        if imgui.Button("Convert to Pattern 2 (30 bytes)##p2") then
            local new_script = generate_pattern2_script()
            Parser.recalculate_script_offsets(new_script)
            EFFECT_EDITOR.script_instructions = new_script
            ui_state.selected_index = -1
            EFFECT_EDITOR.status_msg = "Converted to Pattern 2 (30 bytes). Click Apply to write to memory."
        end
        imgui.SameLine()
        imgui.TextUnformatted("Single animation, animate_tick")

        -- Pattern 1 button
        if imgui.Button("Convert to Pattern 1 (62 bytes)##p1") then
            local new_script = generate_pattern1_script()
            Parser.recalculate_script_offsets(new_script)
            EFFECT_EDITOR.script_instructions = new_script
            ui_state.selected_index = -1
            EFFECT_EDITOR.status_msg = "Converted to Pattern 1 (62 bytes). Click Apply to write to memory."
        end
        imgui.SameLine()
        imgui.TextUnformatted("Multi-target, process_timeline_frame")

        imgui.Spacing()
        imgui.TextUnformatted("WARNING: Timeline data format differs between patterns!")
        imgui.TextUnformatted("Pattern 1 expects phase1/phase2 channels.")
        imgui.TextUnformatted("Pattern 2 expects single-phase channels.")
        imgui.TextUnformatted("Mixing may produce unexpected results.")

        imgui.Unindent()
    end

    -- Reference sections (collapsed by default)
    draw_reference_section()
    draw_branch_reference()

    imgui.Separator()

    -- Main instruction list
    draw_instruction_list()
end

return M
