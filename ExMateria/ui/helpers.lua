-- ui/helpers.lua
-- ImGui helper functions for slider layouts

local M = {}

--------------------------------------------------------------------------------
-- Slider Width Constants
--------------------------------------------------------------------------------

M.SLIDER_WIDTH_SINGLE = -1      -- Full width (default)
M.SLIDER_WIDTH_PAIR = 350       -- For 2 sliders side-by-side
M.SLIDER_WIDTH_TRIPLE = 230     -- For 3 sliders side-by-side (X/Y/Z)

--------------------------------------------------------------------------------
-- Basic Slider Helper
--------------------------------------------------------------------------------

-- Helper to create input slider for int16 value
function M.slider_int16(label, value, min, max, width)
    min = min or -32768
    max = max or 32767
    if width then imgui.PushItemWidth(width) end
    local changed, new_val = imgui.SliderInt(label, value, min, max)
    if width then imgui.PopItemWidth() end
    return changed, new_val
end

--------------------------------------------------------------------------------
-- Compound Slider Helpers
--------------------------------------------------------------------------------

-- Helper to draw a group of 6 sliders for start/end XYZ
function M.draw_xyz_start_end(label, e, prefix, min_val, max_val)
    min_val = min_val or -200
    max_val = max_val or 200
    local changed = false
    local c, v

    imgui.TextUnformatted(label .. ":")
    imgui.Indent()

    -- Start values (3 across)
    c, v = M.slider_int16("Start X##" .. prefix, e[prefix .. "_x_start"], min_val, max_val, M.SLIDER_WIDTH_TRIPLE)
    if c then e[prefix .. "_x_start"] = v; changed = true end
    imgui.SameLine()
    c, v = M.slider_int16("Y##s" .. prefix, e[prefix .. "_y_start"], min_val, max_val, M.SLIDER_WIDTH_TRIPLE)
    if c then e[prefix .. "_y_start"] = v; changed = true end
    imgui.SameLine()
    c, v = M.slider_int16("Z##s" .. prefix, e[prefix .. "_z_start"], min_val, max_val, M.SLIDER_WIDTH_TRIPLE)
    if c then e[prefix .. "_z_start"] = v; changed = true end

    -- End values (3 across)
    c, v = M.slider_int16("End X##" .. prefix, e[prefix .. "_x_end"], min_val, max_val, M.SLIDER_WIDTH_TRIPLE)
    if c then e[prefix .. "_x_end"] = v; changed = true end
    imgui.SameLine()
    c, v = M.slider_int16("Y##e" .. prefix, e[prefix .. "_y_end"], min_val, max_val, M.SLIDER_WIDTH_TRIPLE)
    if c then e[prefix .. "_y_end"] = v; changed = true end
    imgui.SameLine()
    c, v = M.slider_int16("Z##e" .. prefix, e[prefix .. "_z_end"], min_val, max_val, M.SLIDER_WIDTH_TRIPLE)
    if c then e[prefix .. "_z_end"] = v; changed = true end

    imgui.Unindent()
    return changed
end

-- Helper to draw min/max start/end values (4 sliders, 2 per row)
function M.draw_minmax_start_end(label, e, prefix, min, max)
    min = min or -32768
    max = max or 32767
    local changed = false
    local c, v

    imgui.TextUnformatted(label .. ":")
    imgui.Indent()

    c, v = M.slider_int16("Min Start##" .. prefix, e[prefix .. "_min_start"], min, max, M.SLIDER_WIDTH_PAIR)
    if c then e[prefix .. "_min_start"] = v; changed = true end
    imgui.SameLine()
    c, v = M.slider_int16("Max Start##" .. prefix, e[prefix .. "_max_start"], min, max, M.SLIDER_WIDTH_PAIR)
    if c then e[prefix .. "_max_start"] = v; changed = true end

    c, v = M.slider_int16("Min End##" .. prefix, e[prefix .. "_min_end"], min, max, M.SLIDER_WIDTH_PAIR)
    if c then e[prefix .. "_min_end"] = v; changed = true end
    imgui.SameLine()
    c, v = M.slider_int16("Max End##" .. prefix, e[prefix .. "_max_end"], min, max, M.SLIDER_WIDTH_PAIR)
    if c then e[prefix .. "_max_end"] = v; changed = true end

    imgui.Unindent()
    return changed
end

-- Helper for start/end pair (2 sliders on one row)
function M.draw_start_end(label, e, prefix, min, max)
    min = min or 0
    max = max or 1000
    local changed = false
    local c, v

    c, v = M.slider_int16(label .. " Start##" .. prefix, e[prefix .. "_start"], min, max, M.SLIDER_WIDTH_PAIR)
    if c then e[prefix .. "_start"] = v; changed = true end
    imgui.SameLine()
    c, v = M.slider_int16("End##" .. prefix, e[prefix .. "_end"], min, max, M.SLIDER_WIDTH_PAIR)
    if c then e[prefix .. "_end"] = v; changed = true end

    return changed
end

return M
