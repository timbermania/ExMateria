-- ui/curves_tab.lua
-- Animation Curves Editor Tab

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local canvas = nil
local generators = nil
local MemUtils = nil
local Parser = nil
local memory_ops = nil

function M.set_dependencies(canvas_mod, gen_mod, mem_utils, parser, mem_ops)
    canvas = canvas_mod
    generators = gen_mod
    MemUtils = mem_utils
    Parser = parser
    memory_ops = mem_ops
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local CURVE_LENGTH = 160

-- Generator types (simplified list)
local GENERATOR_TYPES = {
    "Linear",
    "Ease In",
    "Ease Out",
    "S-Curve",
    "Exponential In",
    "Exponential Out",
    "Sine Wave",
    "Triangle Wave",
    "Sawtooth",
    "Pulse",
    "Constant"
}

--------------------------------------------------------------------------------
-- UI State (per-session, not saved)
--------------------------------------------------------------------------------

local ui_state = {
    selected_curve = 0,          -- 0-indexed curve selection
    generator_type = 0,          -- Index into GENERATOR_TYPES

    -- Common timing (all types)
    gen_start_frame = 0,         -- Frame where curve begins (0-159)
    gen_end_frame = 160,         -- Frame where curve ends (1-160)

    -- Print truncation options
    print_truncate_enabled = false,
    print_truncate_frame = 160,

    -- Value range (meaning depends on type)
    gen_val_start = 0,           -- Start value (or Min for waves)
    gen_val_end = 255,           -- End value (or Max for waves)

    -- Curve-specific parameters
    gen_power = 2.0,             -- For ease/exp curves (1=linear, 2=quad, 3=cubic)
    gen_cycles = 1.0,            -- For waves (sine, triangle)
    gen_phase = 0.0,             -- For waves (0-1)
    gen_teeth = 1,               -- For sawtooth
    gen_pulses = 1,              -- For pulse
    gen_duty = 0.5,              -- For pulse (duty cycle)
}

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Build curve items string for combo (null-separated)
-- Uses 1-based numbering to match how emitters reference curves
-- (emitter curve index 1 = first curve, index 2 = second curve, etc.)
local function build_curve_items()
    if not EFFECT_EDITOR.curve_count or EFFECT_EDITOR.curve_count == 0 then
        return "No curves\0"
    end

    local items = {}
    for i = 1, EFFECT_EDITOR.curve_count do
        table.insert(items, tostring(i))
    end
    return table.concat(items, "\0") .. "\0"
end

-- Build generator type items string
local function build_generator_items()
    return table.concat(GENERATOR_TYPES, "\0") .. "\0"
end

-- Get current curve data
local function get_current_curve()
    if not EFFECT_EDITOR.curves then return nil end
    return EFFECT_EDITOR.curves[ui_state.selected_curve + 1]
end

-- Set current curve data
local function set_current_curve(curve_data)
    if not EFFECT_EDITOR.curves then return end
    EFFECT_EDITOR.curves[ui_state.selected_curve + 1] = curve_data
end

-- Generate curve based on current ui_state
local function generate_current_curve()
    local gen_type = GENERATOR_TYPES[ui_state.generator_type + 1]
    local sf = ui_state.gen_start_frame
    local ef = ui_state.gen_end_frame
    local v1 = ui_state.gen_val_start
    local v2 = ui_state.gen_val_end

    local curve = nil

    if gen_type == "Linear" then
        curve = generators.linear(sf, ef, v1, v2)
    elseif gen_type == "Ease In" then
        curve = generators.ease_in(sf, ef, v1, v2, ui_state.gen_power)
    elseif gen_type == "Ease Out" then
        curve = generators.ease_out(sf, ef, v1, v2, ui_state.gen_power)
    elseif gen_type == "S-Curve" then
        curve = generators.s_curve(sf, ef, v1, v2, ui_state.gen_power)
    elseif gen_type == "Exponential In" then
        curve = generators.exponential_in(sf, ef, v1, v2, ui_state.gen_power)
    elseif gen_type == "Exponential Out" then
        curve = generators.exponential_out(sf, ef, v1, v2, ui_state.gen_power)
    elseif gen_type == "Sine Wave" then
        curve = generators.sine_wave(sf, ef, v1, v2, ui_state.gen_cycles, ui_state.gen_phase)
    elseif gen_type == "Triangle Wave" then
        curve = generators.triangle_wave(sf, ef, v1, v2, ui_state.gen_cycles, ui_state.gen_phase)
    elseif gen_type == "Sawtooth" then
        curve = generators.sawtooth(sf, ef, v1, v2, ui_state.gen_teeth)
    elseif gen_type == "Pulse" then
        curve = generators.pulse(sf, ef, v1, v2, ui_state.gen_pulses, ui_state.gen_duty)
    elseif gen_type == "Constant" then
        curve = generators.constant(v1)
    end

    return curve
end

--------------------------------------------------------------------------------
-- Print Curve to Console
-- end_frame: controls ASCII visual truncation (default 160)
-- truncate_bytes: if true, also truncate byte output to end_frame
--------------------------------------------------------------------------------

local function print_curve_to_console(curve, curve_num, end_frame, suffix, truncate_bytes)
    suffix = suffix or ""
    end_frame = end_frame or 160
    if end_frame < 1 then end_frame = 1 end
    if end_frame > 160 then end_frame = 160 end
    truncate_bytes = truncate_bytes or false

    local byte_end = truncate_bytes and end_frame or 160

    print("")
    print(string.format("========== CURVE %d %s (frames 0-%d) ==========", curve_num, suffix, byte_end - 1))

    -- Print bytes (all 160 or truncated to end_frame)
    local vals_per_row = 16
    local num_rows = math.ceil(byte_end / vals_per_row)

    for row = 0, num_rows - 1 do
        local start_idx = row * vals_per_row
        local vals = {}
        for col = 0, vals_per_row - 1 do
            local frame = start_idx + col + 1
            if frame <= byte_end then
                table.insert(vals, string.format("%3d", curve[frame]))
            end
        end
        if #vals > 0 then
            print(string.format("  %3d: %s", start_idx, table.concat(vals, " ")))
        end
    end

    print("")
    print("ASCII visualization:")

    -- Sample to get ~80 columns max (good terminal width)
    local target_cols = math.min(80, end_frame)
    local sample_step = math.max(1, math.floor(end_frame / target_cols))
    local samples = {}
    for i = 1, end_frame, sample_step do
        table.insert(samples, curve[i])
    end

    for row = 8, 1, -1 do
        local row_min = (row - 1) * 32
        local row_max = row * 32
        local line = ""
        for _, val in ipairs(samples) do
            if val >= row_max then
                line = line .. "#"
            elseif val >= row_min then
                local within = val - row_min
                local level = math.floor(within / 8) + 1
                level = math.min(level, 4)
                local chars = { ".", ":", "=", "#" }
                line = line .. chars[level]
            else
                line = line .. " "
            end
        end
        print(string.format("%3d|%s|", row_max, line))
    end
    print("   +" .. string.rep("-", #samples) .. "+")
    -- Show frame labels at start and end
    local end_label = tostring(end_frame - 1)
    local padding = math.max(0, #samples - #end_label - 1)
    print("    0" .. string.rep(" ", padding) .. end_label)
    print("=================================")
end

--------------------------------------------------------------------------------
-- Generator UI
--------------------------------------------------------------------------------

local function draw_generator_controls()
    local c, v

    -- Type selector
    imgui.TextUnformatted("Type:")
    imgui.SameLine()
    imgui.SetNextItemWidth(150)
    c, v = imgui.Combo("##gen_type", ui_state.generator_type, build_generator_items())
    if c then
        ui_state.generator_type = v
        set_current_curve(generate_current_curve())
    end

    local gen_type = GENERATOR_TYPES[ui_state.generator_type + 1]

    -- Timing controls (all types except Constant)
    if gen_type ~= "Constant" then
        imgui.TextUnformatted("Timing:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Start##frame", ui_state.gen_start_frame, 0, 159)
        if c then
            ui_state.gen_start_frame = v
            set_current_curve(generate_current_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("End##frame", ui_state.gen_end_frame, 1, 160)
        if c then
            ui_state.gen_end_frame = v
            set_current_curve(generate_current_curve())
        end
    end

    -- Type-specific value controls
    if gen_type == "Linear" or gen_type == "Ease In" or gen_type == "Ease Out" or
       gen_type == "S-Curve" or gen_type == "Exponential In" or gen_type == "Exponential Out" then
        -- Start/End value
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Start##val", ui_state.gen_val_start, 0, 255)
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_current_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("End##val", ui_state.gen_val_end, 0, 255)
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_current_curve())
        end

        -- Power control for easing curves
        if gen_type ~= "Linear" then
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderFloat("Power##curve", ui_state.gen_power, 1.0, 5.0, "%.1f")
            if c then
                ui_state.gen_power = v
                set_current_curve(generate_current_curve())
            end
        end

    elseif gen_type == "Sine Wave" or gen_type == "Triangle Wave" then
        -- Min/Max value
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Min##val", ui_state.gen_val_start, 0, 255)
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_current_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Max##val", ui_state.gen_val_end, 0, 255)
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_current_curve())
        end

        -- Wave parameters
        imgui.TextUnformatted("Wave:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Cycles##wave", ui_state.gen_cycles, 0.5, 10.0, "%.1f")
        if c then
            ui_state.gen_cycles = v
            set_current_curve(generate_current_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Phase##wave", ui_state.gen_phase, 0.0, 1.0, "%.2f")
        if c then
            ui_state.gen_phase = v
            set_current_curve(generate_current_curve())
        end

    elseif gen_type == "Sawtooth" then
        -- Min/Max value
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Min##val", ui_state.gen_val_start, 0, 255)
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_current_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Max##val", ui_state.gen_val_end, 0, 255)
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_current_curve())
        end

        -- Teeth parameter
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Teeth##saw", ui_state.gen_teeth, 1, 20)
        if c then
            ui_state.gen_teeth = v
            set_current_curve(generate_current_curve())
        end

    elseif gen_type == "Pulse" then
        -- Low/High value
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Low##val", ui_state.gen_val_start, 0, 255)
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_current_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("High##val", ui_state.gen_val_end, 0, 255)
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_current_curve())
        end

        -- Pulse parameters
        imgui.TextUnformatted("Pulse:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Count##pulse", ui_state.gen_pulses, 1, 20)
        if c then
            ui_state.gen_pulses = v
            set_current_curve(generate_current_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Duty##pulse", ui_state.gen_duty, 0.0, 1.0, "%.2f")
        if c then
            ui_state.gen_duty = v
            set_current_curve(generate_current_curve())
        end

    elseif gen_type == "Constant" then
        imgui.TextUnformatted("Value:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("##const_val", ui_state.gen_val_start, 0, 255)
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_current_curve())
        end
    end

    -- Generate button
    if imgui.Button("Generate##btn") then
        local curve = generate_current_curve()
        if curve then
            set_current_curve(curve)
            print_curve_to_console(curve, ui_state.selected_curve + 1, ui_state.gen_end_frame, "(Generated)")
        end
    end
end

--------------------------------------------------------------------------------
-- Preset Buttons
--------------------------------------------------------------------------------

local function draw_preset_buttons()
    imgui.TextUnformatted("Presets (use current timing):")

    -- Row 1: Basic ramps and easing
    if imgui.Button("Ramp Up") then
        ui_state.generator_type = 0  -- Linear
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Ramp Down") then
        ui_state.generator_type = 0  -- Linear
        ui_state.gen_val_start = 255
        ui_state.gen_val_end = 0
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Ease In") then
        ui_state.generator_type = 1  -- Ease In
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        ui_state.gen_power = 2.0
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Ease Out") then
        ui_state.generator_type = 2  -- Ease Out
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        ui_state.gen_power = 2.0
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("S-Curve") then
        ui_state.generator_type = 3  -- S-Curve
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        ui_state.gen_power = 2.0
        set_current_curve(generate_current_curve())
    end

    -- Row 2: Waves and constants
    if imgui.Button("Sine") then
        ui_state.generator_type = 6  -- Sine Wave
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        ui_state.gen_cycles = 1.0
        ui_state.gen_phase = 0.0
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Triangle") then
        ui_state.generator_type = 7  -- Triangle Wave
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        ui_state.gen_cycles = 1.0
        ui_state.gen_phase = 0.0
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Sawtooth") then
        ui_state.generator_type = 8  -- Sawtooth
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        ui_state.gen_teeth = 1
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Pulse") then
        ui_state.generator_type = 9  -- Pulse
        ui_state.gen_val_start = 0
        ui_state.gen_val_end = 255
        ui_state.gen_pulses = 1
        ui_state.gen_duty = 0.5
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Flat 0") then
        ui_state.generator_type = 10  -- Constant
        ui_state.gen_val_start = 0
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Flat 128") then
        ui_state.generator_type = 10  -- Constant
        ui_state.gen_val_start = 128
        set_current_curve(generate_current_curve())
    end
    imgui.SameLine()
    if imgui.Button("Flat 255") then
        ui_state.generator_type = 10  -- Constant
        ui_state.gen_val_start = 255
        set_current_curve(generate_current_curve())
    end
end

--------------------------------------------------------------------------------
-- Action Buttons
--------------------------------------------------------------------------------

local function draw_action_buttons()
    -- Apply single curve to memory (quick iteration on one curve)
    local can_apply = EFFECT_EDITOR.memory_base and EFFECT_EDITOR.memory_base >= 0x80000000

    if can_apply then
        if imgui.Button("Apply This Curve##curve") then
            memory_ops.apply_single_curve_to_memory(ui_state.selected_curve)
        end
    else
        imgui.TextUnformatted("(Apply to Memory - no target)")
    end

    imgui.SameLine()

    -- Curve manipulation
    if imgui.Button("Invert") then
        local curve = get_current_curve()
        if curve then
            set_current_curve(generators.invert(curve))
        end
    end

    imgui.SameLine()
    if imgui.Button("Reverse") then
        local curve = get_current_curve()
        if curve then
            set_current_curve(generators.reverse(curve))
        end
    end

    imgui.SameLine()

    -- Reset to original
    if imgui.Button("Reset to Original##curve") then
        if EFFECT_EDITOR.original_curves and EFFECT_EDITOR.original_curves[ui_state.selected_curve + 1] then
            set_current_curve(generators.copy(EFFECT_EDITOR.original_curves[ui_state.selected_curve + 1]))
        end
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    -- Check if we have curve data
    if not EFFECT_EDITOR.curves or EFFECT_EDITOR.curve_count == 0 then
        imgui.TextUnformatted("No curve data loaded.")
        imgui.TextUnformatted("Load an effect file or capture from memory to edit curves.")
        return
    end

    -- Curve selector
    imgui.SetNextItemWidth(80)
    local c, v = imgui.Combo("Curve##select", ui_state.selected_curve, build_curve_items())
    if c then
        ui_state.selected_curve = v
    end

    imgui.SameLine()
    imgui.TextUnformatted(string.format("(%d curves: 1-%d)", EFFECT_EDITOR.curve_count, EFFECT_EDITOR.curve_count))

    imgui.Separator()

    -- Curve stats and print button
    local curve_data = get_current_curve()
    if curve_data and canvas then
        canvas.draw_curve_canvas(curve_data, 60, nil, "main_curve")
        canvas.draw_stats(curve_data, "main_stats")

        -- Print to console with optional truncation
        local c, v = imgui.Checkbox("##print_truncate", ui_state.print_truncate_enabled)
        if c then ui_state.print_truncate_enabled = v end
        imgui.SameLine()

        if ui_state.print_truncate_enabled then
            imgui.SetNextItemWidth(60)
            c, v = imgui.SliderInt("End##print", ui_state.print_truncate_frame, 1, 160)
            if c then ui_state.print_truncate_frame = v end
            imgui.SameLine()
        end

        if imgui.Button("Print Curve to Console") then
            if ui_state.print_truncate_enabled then
                print_curve_to_console(curve_data, ui_state.selected_curve + 1, ui_state.print_truncate_frame, "", true)
            else
                print_curve_to_console(curve_data, ui_state.selected_curve + 1, ui_state.gen_end_frame)
            end
        end
    else
        imgui.TextUnformatted("No curve data to display")
    end

    imgui.Separator()

    -- Generator controls
    draw_generator_controls()

    imgui.Separator()

    -- Preset buttons
    draw_preset_buttons()

    imgui.Separator()

    -- Action buttons
    draw_action_buttons()
end

return M
