-- ui/curve_canvas.lua
-- Text-based curve visualization for ImGui

local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local CURVE_LENGTH = 160

-- ASCII height characters (8 levels, from low to high)
local HEIGHT_CHARS = { " ", ".", ":", "-", "=", "+", "#", "@" }

--------------------------------------------------------------------------------
-- Text-Based Canvas Drawing
--------------------------------------------------------------------------------

-- Draw curve info (no ASCII art - use Print to Console for that)
function M.draw_curve_canvas(curve_data, width, height, uid)
    if not curve_data or #curve_data < CURVE_LENGTH then
        imgui.TextUnformatted("No curve data")
        return false, nil, nil
    end

    imgui.TextUnformatted("Use 'Print Curve to Console' for ASCII visualization")

    return false, nil, nil
end

--------------------------------------------------------------------------------
-- Compact Single-Line Preview
--------------------------------------------------------------------------------

-- Draw a compact sparkline-style preview
function M.draw_mini_preview(curve_data, width, height, uid)
    if not curve_data or #curve_data < CURVE_LENGTH then
        imgui.TextUnformatted("[no data]")
        return
    end

    -- Sample to ~40 characters
    local sample_step = 4
    local line = ""

    for i = 1, CURVE_LENGTH, sample_step do
        local val = curve_data[i]
        local level = math.floor(val / 32) + 1  -- 0-255 -> 1-8
        level = math.min(level, 8)
        line = line .. HEIGHT_CHARS[level]
    end

    imgui.TextUnformatted("[" .. line .. "]")
end

--------------------------------------------------------------------------------
-- Value Table Display
--------------------------------------------------------------------------------

-- Show curve values in a table format (for detailed inspection)
function M.draw_value_table(curve_data, uid)
    if not curve_data or #curve_data < CURVE_LENGTH then
        imgui.TextUnformatted("No curve data")
        return
    end

    imgui.TextUnformatted("Frame values (16 per row):")

    for row = 0, 9 do
        local start_frame = row * 16
        local line = string.format("%3d: ", start_frame)

        for col = 0, 15 do
            local frame = start_frame + col + 1
            if frame <= CURVE_LENGTH then
                line = line .. string.format("%3d ", curve_data[frame])
            end
        end

        imgui.TextUnformatted(line)
    end
end

--------------------------------------------------------------------------------
-- Statistics Display
--------------------------------------------------------------------------------

function M.draw_stats(curve_data, uid)
    if not curve_data or #curve_data < CURVE_LENGTH then
        return
    end

    local min_val, max_val = 255, 0
    local sum = 0

    for i = 1, CURVE_LENGTH do
        local v = curve_data[i]
        if v < min_val then min_val = v end
        if v > max_val then max_val = v end
        sum = sum + v
    end

    local avg = sum / CURVE_LENGTH

    imgui.TextUnformatted(string.format(
        "Stats: min=%d  max=%d  avg=%.1f  range=%d  start=%d  end=%d",
        min_val, max_val, avg, max_val - min_val,
        curve_data[1], curve_data[CURVE_LENGTH]
    ))
end

--------------------------------------------------------------------------------
-- Combined Display (for curve editor tab)
--------------------------------------------------------------------------------

function M.draw_curve_editor(curve_data, width, height, uid)
    M.draw_curve_canvas(curve_data, 60, nil, uid)
    M.draw_stats(curve_data, uid)
    return false, curve_data
end

return M
