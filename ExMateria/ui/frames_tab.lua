-- ui/frames_tab.lua
-- Frames tab with frame/frameset editing UI

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local helpers = nil
local apply_all_edits_fn = nil
local Parser = nil
local bmp = nil
local config = nil

function M.set_dependencies(helpers_module, apply_all_edits, parser_module, bmp_module, config_module)
    helpers = helpers_module
    apply_all_edits_fn = apply_all_edits
    Parser = parser_module
    bmp = bmp_module
    config = config_module
end

--------------------------------------------------------------------------------
-- UI State
--------------------------------------------------------------------------------

local ui_state = {
    selected_group = 0,          -- 0-indexed group
    selected_frameset = 0,       -- 0-indexed frameset within group
    selected_frame = 0,          -- 0-indexed frame within frameset
    clone_frameset_source = 0,   -- Source frameset for cloning
    preview_mode = 0,            -- 0 = single frame, 1 = frameset
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local SEMI_TRANS_MODES = "Mode 0 (BLEND)\0Mode 1 (ADD)\0Mode 2 (SUB)\0Mode 3 (ADD25)\0"
local COLOR_DEPTH_ITEMS = "4-bit (16 colors)\0008-bit (256 colors)\0"
local TPAGE_COLOR_DEPTH_ITEMS = "0: 4-bit\0001: 8-bit\0002: 15-bit\0003: Reserved\0"

--------------------------------------------------------------------------------
-- Local Helpers
--------------------------------------------------------------------------------

local function slider_int16(label, value, min, max, width)
    return helpers.slider_int16(label, value, min, max, width)
end

local function slider_u8(label, value, min, max, width)
    if width then imgui.SetNextItemWidth(width) end
    local c, v = imgui.SliderInt(label, value, min, max)
    return c, v
end

local function slider_s8(label, value, min, max, width)
    if width then imgui.SetNextItemWidth(width) end
    local c, v = imgui.SliderInt(label, value, min, max)
    return c, v
end

--------------------------------------------------------------------------------
-- Get Currently Selected Frame
--------------------------------------------------------------------------------

local function get_selected_frame()
    if not EFFECT_EDITOR.framesets or #EFFECT_EDITOR.framesets == 0 then
        return nil
    end

    local frameset_idx = ui_state.selected_frameset + 1
    if frameset_idx > #EFFECT_EDITOR.framesets then
        ui_state.selected_frameset = #EFFECT_EDITOR.framesets - 1
        frameset_idx = #EFFECT_EDITOR.framesets
    end

    local frameset = EFFECT_EDITOR.framesets[frameset_idx]
    if not frameset or not frameset.frames or #frameset.frames == 0 then
        return nil
    end

    local frame_idx = ui_state.selected_frame + 1
    if frame_idx > #frameset.frames then
        ui_state.selected_frame = #frameset.frames - 1
        frame_idx = #frameset.frames
    end

    return frameset.frames[frame_idx]
end

local function get_selected_frameset()
    if not EFFECT_EDITOR.framesets or #EFFECT_EDITOR.framesets == 0 then
        return nil
    end

    local frameset_idx = ui_state.selected_frameset + 1
    if frameset_idx > #EFFECT_EDITOR.framesets then
        ui_state.selected_frameset = #EFFECT_EDITOR.framesets - 1
        frameset_idx = #EFFECT_EDITOR.framesets
    end

    return EFFECT_EDITOR.framesets[frameset_idx]
end

--------------------------------------------------------------------------------
-- Draw Frame Editor
--------------------------------------------------------------------------------

local function draw_frame_editor(frame)
    if not frame then
        imgui.TextUnformatted("No frame selected")
        return
    end

    local changed = false

    -- Flags Section
    if imgui.TreeNode("Flags") then
        -- Palette ID (0-15)
        imgui.SetNextItemWidth(100)
        local c, v = imgui.SliderInt("Palette ID##frame", frame.palette_id, 0, 15)
        if c then frame.palette_id = v; changed = true end

        -- Semi-Trans Mode (0-3)
        imgui.SetNextItemWidth(150)
        c, v = imgui.Combo("Semi-Trans Mode##frame", frame.semi_trans_mode, SEMI_TRANS_MODES)
        if c then frame.semi_trans_mode = v; changed = true end

        -- Color Depth
        local color_idx = frame.is_8bpp and 1 or 0
        imgui.SetNextItemWidth(150)
        c, v = imgui.Combo("Color Depth##frame", color_idx, COLOR_DEPTH_ITEMS)
        if c then frame.is_8bpp = (v == 1); changed = true end

        -- Semi-Trans On
        c, v = imgui.Checkbox("Semi-Trans Enabled##frame", frame.semi_trans_on)
        if c then frame.semi_trans_on = v; changed = true end

        -- Width/Height Signed
        c, v = imgui.Checkbox("Width Signed##frame", frame.width_signed)
        if c then frame.width_signed = v; changed = true end
        imgui.SameLine()
        c, v = imgui.Checkbox("Height Signed##frame", frame.height_signed)
        if c then frame.height_signed = v; changed = true end

        imgui.TreePop()
    end

    -- Texture Page Section (decoded TPAGE)
    if imgui.TreeNode("Texture Page") then
        -- X Base (0-15, VRAM X / 64)
        imgui.SetNextItemWidth(100)
        local c, v = imgui.SliderInt("X Base (VRAM X/64)##tpage", frame.tpage_x_base, 0, 15)
        if c then frame.tpage_x_base = v; changed = true end

        -- Y Base (0-1, VRAM Y / 256)
        imgui.SetNextItemWidth(100)
        c, v = imgui.SliderInt("Y Base (VRAM Y/256)##tpage", frame.tpage_y_base, 0, 1)
        if c then frame.tpage_y_base = v; changed = true end

        -- Blend Mode (from TPAGE)
        imgui.SetNextItemWidth(150)
        c, v = imgui.Combo("Blend Mode##tpage", frame.tpage_blend, SEMI_TRANS_MODES)
        if c then frame.tpage_blend = v; changed = true end

        -- Color Depth (from TPAGE)
        imgui.SetNextItemWidth(150)
        c, v = imgui.Combo("TPAGE Color Depth##tpage", frame.tpage_color_depth, TPAGE_COLOR_DEPTH_ITEMS)
        if c then frame.tpage_color_depth = v; changed = true end

        imgui.TreePop()
    end

    -- UV Coordinates Section
    if imgui.TreeNode("UV Coordinates") then
        imgui.SetNextItemWidth(100)
        local c, v = imgui.SliderInt("U (X)##uv", frame.uv_x, 0, 255)
        if c then frame.uv_x = v; changed = true end

        imgui.SameLine()
        imgui.SetNextItemWidth(100)
        c, v = imgui.SliderInt("V (Y)##uv", frame.uv_y, 0, 255)
        if c then frame.uv_y = v; changed = true end

        -- Width (can be signed)
        local w_min, w_max = 0, 255
        if frame.width_signed then
            w_min, w_max = -128, 127
        end
        imgui.SetNextItemWidth(100)
        c, v = imgui.SliderInt("Width##uv", frame.uv_width, w_min, w_max)
        if c then frame.uv_width = v; changed = true end

        imgui.SameLine()
        -- Height (can be signed)
        local h_min, h_max = 0, 255
        if frame.height_signed then
            h_min, h_max = -128, 127
        end
        imgui.SetNextItemWidth(100)
        c, v = imgui.SliderInt("Height##uv", frame.uv_height, h_min, h_max)
        if c then frame.uv_height = v; changed = true end

        imgui.TreePop()
    end

    -- Vertices Section
    if imgui.TreeNode("Vertices (local space)") then
        imgui.TextUnformatted("Top-Left:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        local c, v = imgui.SliderInt("X##vtx_tl", frame.vtx_tl_x, -256, 256)
        if c then frame.vtx_tl_x = v; changed = true end
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Y##vtx_tl", frame.vtx_tl_y, -256, 256)
        if c then frame.vtx_tl_y = v; changed = true end

        imgui.TextUnformatted("Top-Right:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("X##vtx_tr", frame.vtx_tr_x, -256, 256)
        if c then frame.vtx_tr_x = v; changed = true end
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Y##vtx_tr", frame.vtx_tr_y, -256, 256)
        if c then frame.vtx_tr_y = v; changed = true end

        imgui.TextUnformatted("Bottom-Left:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("X##vtx_bl", frame.vtx_bl_x, -256, 256)
        if c then frame.vtx_bl_x = v; changed = true end
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Y##vtx_bl", frame.vtx_bl_y, -256, 256)
        if c then frame.vtx_bl_y = v; changed = true end

        imgui.TextUnformatted("Bottom-Right:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("X##vtx_br", frame.vtx_br_x, -256, 256)
        if c then frame.vtx_br_x = v; changed = true end
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Y##vtx_br", frame.vtx_br_y, -256, 256)
        if c then frame.vtx_br_y = v; changed = true end

        imgui.TreePop()
    end

    return changed
end

--------------------------------------------------------------------------------
-- Draw Preview Section
--------------------------------------------------------------------------------

local function draw_preview_section()
    if not config or not EFFECT_EDITOR.session_name or EFFECT_EDITOR.session_name == "" then
        imgui.TextUnformatted("Export texture first to enable preview")
        return
    end

    local tga_path = config.TEXTURES_PATH .. EFFECT_EDITOR.session_name .. ".tga"

    -- Check if TGA exists
    local f = io.open(tga_path, "rb")
    if not f then
        imgui.TextUnformatted("Export texture first to enable preview")
        imgui.TextUnformatted("(TGA file not found)")
        return
    end
    f:close()

    local frame = get_selected_frame()
    if not frame then
        imgui.TextUnformatted("No frame selected for preview")
        return
    end

    -- Show UV region info
    imgui.TextUnformatted(string.format("UV Region: (%d, %d) size %dx%d",
        frame.uv_x, frame.uv_y, math.abs(frame.uv_width), math.abs(frame.uv_height)))

    -- Vertex bounds
    local min_x = math.min(frame.vtx_tl_x, frame.vtx_tr_x, frame.vtx_bl_x, frame.vtx_br_x)
    local max_x = math.max(frame.vtx_tl_x, frame.vtx_tr_x, frame.vtx_bl_x, frame.vtx_br_x)
    local min_y = math.min(frame.vtx_tl_y, frame.vtx_tr_y, frame.vtx_bl_y, frame.vtx_br_y)
    local max_y = math.max(frame.vtx_tl_y, frame.vtx_tr_y, frame.vtx_bl_y, frame.vtx_br_y)
    imgui.TextUnformatted(string.format("Vertex Bounds: X[%d,%d] Y[%d,%d]", min_x, max_x, min_y, max_y))
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.framesets then
        imgui.TextUnformatted("No frames data loaded")
        return
    end

    -- Apply to Memory button at top
    if EFFECT_EDITOR.memory_base >= 0x80000000 then
        if imgui.Button("Apply All to Memory") then
            if apply_all_edits_fn then
                apply_all_edits_fn()
            end
        end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("(Target: 0x%08X)", EFFECT_EDITOR.memory_base))
    else
        imgui.TextUnformatted("Set memory base address to enable Apply to Memory")
    end

    -- Structure change warning
    if EFFECT_EDITOR.original_framesets and
       #EFFECT_EDITOR.framesets ~= #EFFECT_EDITOR.original_framesets then
        imgui.Separator()
        imgui.TextUnformatted(string.format("** STRUCTURE MODIFIED: %d -> %d framesets **",
            #EFFECT_EDITOR.original_framesets, #EFFECT_EDITOR.framesets))
        imgui.TextUnformatted("Click 'Apply All to Memory' to commit changes")
    end

    imgui.Separator()

    -- Selector Row
    imgui.TextUnformatted(string.format("Groups: %d  Framesets: %d",
        EFFECT_EDITOR.frames_group_count, #EFFECT_EDITOR.framesets))

    -- Group selector (if multiple groups)
    if EFFECT_EDITOR.frames_group_count > 1 then
        imgui.SetNextItemWidth(80)
        local group_items = ""
        for g = 0, EFFECT_EDITOR.frames_group_count - 1 do
            group_items = group_items .. tostring(g) .. "\0"
        end
        local c, v = imgui.Combo("Group##frames", ui_state.selected_group, group_items)
        if c then ui_state.selected_group = v end
        imgui.SameLine()
    end

    -- Frameset selector
    if #EFFECT_EDITOR.framesets > 0 then
        imgui.SetNextItemWidth(100)
        local fs_items = ""
        for fs_idx, fs in ipairs(EFFECT_EDITOR.framesets) do
            fs_items = fs_items .. string.format("%d (%d frm)", fs.index, #fs.frames) .. "\0"
        end

        -- Clamp selection
        if ui_state.selected_frameset >= #EFFECT_EDITOR.framesets then
            ui_state.selected_frameset = #EFFECT_EDITOR.framesets - 1
        end

        local c, v = imgui.Combo("Frameset##frames", ui_state.selected_frameset, fs_items)
        if c then
            ui_state.selected_frameset = v
            ui_state.selected_frame = 0  -- Reset frame selection
        end
        imgui.SameLine()
    end

    -- Frame selector
    local frameset = get_selected_frameset()
    if frameset and #frameset.frames > 0 then
        imgui.SetNextItemWidth(80)
        local frm_items = ""
        for frm_idx = 0, #frameset.frames - 1 do
            frm_items = frm_items .. tostring(frm_idx) .. "\0"
        end

        -- Clamp selection
        if ui_state.selected_frame >= #frameset.frames then
            ui_state.selected_frame = #frameset.frames - 1
        end

        local c, v = imgui.Combo("Frame##frames", ui_state.selected_frame, frm_items)
        if c then ui_state.selected_frame = v end
    end

    imgui.Separator()

    -- Add/Delete controls
    if Parser then
        -- Add Frame
        if frameset and #frameset.frames > 0 then
            if imgui.Button("Add Frame##frames") then
                -- Clone the currently selected frame
                local source_frame = frameset.frames[ui_state.selected_frame + 1]
                local new_frame = Parser.copy_frame(source_frame)
                new_frame.index = #frameset.frames
                table.insert(frameset.frames, new_frame)
            end
            imgui.SameLine()
        end

        -- Delete Frame
        if frameset and #frameset.frames > 1 then
            if imgui.Button("Delete Frame##frames") then
                table.remove(frameset.frames, ui_state.selected_frame + 1)
                -- Reindex remaining frames
                for i, frm in ipairs(frameset.frames) do
                    frm.index = i - 1
                end
                -- Adjust selection
                if ui_state.selected_frame >= #frameset.frames then
                    ui_state.selected_frame = #frameset.frames - 1
                end
            end
            imgui.SameLine()
        end

        -- Add Frameset
        if #EFFECT_EDITOR.framesets > 0 then
            if imgui.Button("Add Frameset##frames") then
                -- Clone the currently selected frameset
                local source_fs = EFFECT_EDITOR.framesets[ui_state.selected_frameset + 1]
                local new_fs = Parser.copy_frameset(source_fs)
                new_fs.index = #EFFECT_EDITOR.framesets
                table.insert(EFFECT_EDITOR.framesets, new_fs)
            end
            imgui.SameLine()
        end

        -- Delete Frameset
        if #EFFECT_EDITOR.framesets > 1 then
            if imgui.Button("Delete Frameset##frames") then
                table.remove(EFFECT_EDITOR.framesets, ui_state.selected_frameset + 1)
                -- Reindex remaining framesets
                for i, fs in ipairs(EFFECT_EDITOR.framesets) do
                    fs.index = i - 1
                end
                -- Adjust selection
                if ui_state.selected_frameset >= #EFFECT_EDITOR.framesets then
                    ui_state.selected_frameset = #EFFECT_EDITOR.framesets - 1
                end
                ui_state.selected_frame = 0
            end
        end
    end

    imgui.Separator()

    -- Frame Editor
    local frame = get_selected_frame()
    if frame then
        draw_frame_editor(frame)
    else
        imgui.TextUnformatted("No frame data available")
    end

    imgui.Separator()

    -- Preview Section
    if imgui.TreeNode("Preview") then
        draw_preview_section()
        imgui.TreePop()
    end
end

return M
