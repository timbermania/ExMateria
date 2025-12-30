-- ui/time_scale_tab.lua
-- Time Scale / Timing Curves Editor Tab
-- Edits playback speed curves for dramatic slow-motion effects

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local add_timing_section_fn = nil
local remove_timing_section_fn = nil

function M.set_dependencies(add_timing_section, remove_timing_section)
    add_timing_section_fn = add_timing_section
    remove_timing_section_fn = remove_timing_section
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local TIME_SCALE_LENGTH = 600

-- Generator types (subset suitable for time scale)
local GENERATOR_TYPES = {
    "Constant",
    "Linear",
    "Ease In",
    "Ease Out",
    "S-Curve",
    "Sine Wave",
    "Triangle Wave",
    "Sawtooth",
    "Pulse"
}

-- FPS reference for time scale values
local VALUE_FPS = {
    [0] = "No effect",
    [1] = "60 FPS (fastest)",
    [2] = "30 FPS (normal)",
    [3] = "20 FPS",
    [4] = "15 FPS",
    [5] = "12 FPS",
    [6] = "10 FPS",
    [7] = "8.6 FPS",
    [8] = "7.5 FPS",
    [9] = "6.7 FPS (slowest)",
}

-- Flag masks
local FLAG_TIMING_PROCESS_TIMELINE = 0x20
local FLAG_TIMING_ANIMATE_TICK = 0x40

--------------------------------------------------------------------------------
-- UI State (per-session, not saved)
--------------------------------------------------------------------------------

local ui_state = {
    selected_region = 0,         -- 0 = process_timeline, 1 = animate_tick
    generator_type = 0,          -- Index into GENERATOR_TYPES

    -- Timing parameters
    gen_start_frame = 0,
    gen_end_frame = 600,

    -- Print truncation options
    print_truncate_enabled = false,
    print_truncate_frame = 600,

    -- Value range (0-9 for time scale, but allow decimals for generation)
    gen_val_start = 2.0,         -- Normal speed (start)
    gen_val_end = 2.0,           -- Normal speed (end) - effects should return to normal

    -- Curve parameters
    gen_power = 2.0,
    gen_cycles = 1.0,
    gen_phase = 0.0,
    gen_teeth = 1,
    gen_pulses = 1,
    gen_duty = 0.5,
}

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Get the current region key
local function get_region_key()
    return ui_state.selected_region == 0 and "process_timeline" or "animate_tick"
end

-- Get the current region curve
local function get_current_curve()
    if not EFFECT_EDITOR.timing_curves then return nil end
    return EFFECT_EDITOR.timing_curves[get_region_key()]
end

-- Set the current region curve
local function set_current_curve(curve_data)
    if not EFFECT_EDITOR.timing_curves then return end
    EFFECT_EDITOR.timing_curves[get_region_key()] = curve_data
end

-- Build region items for combo
local function build_region_items()
    return "Process Timeline (opcode 41)\0Animate Tick (opcode 40)\0"
end

-- Build generator type items string
local function build_generator_items()
    return table.concat(GENERATOR_TYPES, "\0") .. "\0"
end

--------------------------------------------------------------------------------
-- Curve Generation (adapted for 600 frames, 0-9 range)
--------------------------------------------------------------------------------

local function generate_time_scale_curve()
    local gen_type = GENERATOR_TYPES[ui_state.generator_type + 1]
    local sf = ui_state.gen_start_frame
    local ef = ui_state.gen_end_frame
    local v1 = ui_state.gen_val_start
    local v2 = ui_state.gen_val_end

    local curve = {}

    for i = 1, TIME_SCALE_LENGTH do
        local frame = i - 1  -- 0-indexed frame
        local value

        if frame < sf then
            value = v1
        elseif frame >= ef then
            value = v1  -- Return to start value (normal speed) after effect range
        else
            -- Calculate normalized t (0-1)
            local t = (frame - sf) / (ef - sf)

            -- Apply curve type
            if gen_type == "Constant" then
                value = v1
            elseif gen_type == "Linear" then
                value = v1 + (v2 - v1) * t
            elseif gen_type == "Ease In" then
                value = v1 + (v2 - v1) * (t ^ ui_state.gen_power)
            elseif gen_type == "Ease Out" then
                value = v1 + (v2 - v1) * (1 - (1 - t) ^ ui_state.gen_power)
            elseif gen_type == "S-Curve" then
                local eased
                if t < 0.5 then
                    eased = (2 ^ (ui_state.gen_power - 1)) * (t ^ ui_state.gen_power)
                else
                    eased = 1 - (((-2 * t + 2) ^ ui_state.gen_power) / 2)
                end
                value = v1 + (v2 - v1) * eased
            elseif gen_type == "Sine Wave" then
                local wave_t = t * ui_state.gen_cycles + ui_state.gen_phase
                local amplitude = (v2 - v1) / 2
                local offset = (v2 + v1) / 2
                value = offset + amplitude * math.sin(wave_t * 2 * math.pi)
            elseif gen_type == "Triangle Wave" then
                -- Triangle: starts at v1, peaks at v2 in middle, returns to v1
                local cycle_t = (t * ui_state.gen_cycles + ui_state.gen_phase) % 1
                local wave_val
                if cycle_t < 0.5 then
                    wave_val = cycle_t * 2  -- 0 to 1 in first half
                else
                    wave_val = 1 - (cycle_t - 0.5) * 2  -- 1 to 0 in second half
                end
                value = v1 + (v2 - v1) * wave_val
            elseif gen_type == "Sawtooth" then
                local tooth_pos = (t * ui_state.gen_teeth) % 1
                value = v1 + (v2 - v1) * tooth_pos
            elseif gen_type == "Pulse" then
                local pulse_pos = (t * ui_state.gen_pulses) % 1
                value = pulse_pos < ui_state.gen_duty and v2 or v1
            else
                value = v1
            end
        end

        -- Round and clamp to 0-9
        curve[i] = math.max(0, math.min(9, math.floor(value + 0.5)))
    end

    return curve
end

--------------------------------------------------------------------------------
-- Statistics Display
--------------------------------------------------------------------------------

local function draw_stats(curve)
    if not curve or #curve == 0 then
        imgui.TextUnformatted("No curve data")
        return
    end

    local min_val, max_val = 9, 0
    local sum = 0
    for i = 1, #curve do
        local v = curve[i]
        if v < min_val then min_val = v end
        if v > max_val then max_val = v end
        sum = sum + v
    end
    local avg = sum / #curve

    imgui.TextUnformatted(string.format("Stats: min=%d max=%d avg=%.1f  |  First=%d Last=%d",
        min_val, max_val, avg, curve[1], curve[#curve]))
end

--------------------------------------------------------------------------------
-- Enable Flags Controls
--------------------------------------------------------------------------------

local function draw_enable_flags()
    if not EFFECT_EDITOR.effect_flags then
        imgui.TextUnformatted("Enable Timing: (effect flags not loaded)")
        return
    end

    local flags = EFFECT_EDITOR.effect_flags.flags_byte
    local pt_enabled = (math.floor(flags / FLAG_TIMING_PROCESS_TIMELINE) % 2) == 1
    local at_enabled = (math.floor(flags / FLAG_TIMING_ANIMATE_TICK) % 2) == 1

    imgui.TextUnformatted("Enable Timing:")
    imgui.SameLine()

    -- Process Timeline checkbox
    local c, v = imgui.Checkbox("Process Timeline (0x20)##pt_enable", pt_enabled)
    if c then
        if v and not pt_enabled then
            EFFECT_EDITOR.effect_flags.flags_byte = flags + FLAG_TIMING_PROCESS_TIMELINE
        elseif not v and pt_enabled then
            EFFECT_EDITOR.effect_flags.flags_byte = flags - FLAG_TIMING_PROCESS_TIMELINE
        end
        flags = EFFECT_EDITOR.effect_flags.flags_byte
    end

    imgui.SameLine()

    -- Animate Tick checkbox
    c, v = imgui.Checkbox("Animate Tick (0x40)##at_enable", at_enabled)
    if c then
        if v and not at_enabled then
            EFFECT_EDITOR.effect_flags.flags_byte = flags + FLAG_TIMING_ANIMATE_TICK
        elseif not v and at_enabled then
            EFFECT_EDITOR.effect_flags.flags_byte = flags - FLAG_TIMING_ANIMATE_TICK
        end
    end

    imgui.SameLine()
    imgui.TextUnformatted(string.format("(flags: 0x%02X)", EFFECT_EDITOR.effect_flags.flags_byte))
end

--------------------------------------------------------------------------------
-- Print to Console
-- end_frame: controls ASCII visual truncation (default 600)
-- truncate_bytes: if true, also truncate byte output to end_frame
--------------------------------------------------------------------------------

local function print_curve_to_console(curve, region_name, end_frame, truncate_bytes)
    end_frame = end_frame or 600
    if end_frame < 1 then end_frame = 1 end
    if end_frame > 600 then end_frame = 600 end
    truncate_bytes = truncate_bytes or false

    local byte_end = truncate_bytes and end_frame or 600

    print("")
    print(string.format("========== TIME SCALE: %s (frames 0-%d) ==========", region_name, byte_end - 1))
    print("Values (0-9, where 2=normal, 9=slowest)")
    print("")

    -- Print bytes (all 600 or truncated to end_frame)
    local vals_per_row = 60
    local num_rows = math.ceil(byte_end / vals_per_row)

    for row = 0, num_rows - 1 do
        local start_idx = row * vals_per_row
        local vals = {}
        for col = 0, vals_per_row - 1 do
            local frame = start_idx + col + 1
            if frame <= byte_end then
                table.insert(vals, tostring(curve[frame]))
            end
        end
        if #vals > 0 then
            print(string.format("%3d: %s", start_idx, table.concat(vals, "")))
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

    -- Draw ASCII chart (9 rows for values 1-9)
    for row = 9, 1, -1 do
        local line = ""
        for _, val in ipairs(samples) do
            if val >= row then
                line = line .. "#"
            elseif val == row - 1 then
                line = line .. "."
            else
                line = line .. " "
            end
        end
        local fps = VALUE_FPS[row] or ""
        print(string.format("%d|%s| %s", row, line, fps))
    end
    print(" +" .. string.rep("-", #samples) .. "+")
    -- Show frame labels at start and end
    local end_label = tostring(end_frame - 1)
    local padding = #samples - #end_label - 1
    print("  0" .. string.rep(" ", padding) .. end_label)
    print("=======================================================")
end

--------------------------------------------------------------------------------
-- Generator Controls
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
        set_current_curve(generate_time_scale_curve())
    end

    local gen_type = GENERATOR_TYPES[ui_state.generator_type + 1]

    -- Timing controls (all types except Constant)
    if gen_type ~= "Constant" then
        imgui.TextUnformatted("Timing:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Start##frame", ui_state.gen_start_frame, 0, 599)
        if c then
            ui_state.gen_start_frame = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("End##frame", ui_state.gen_end_frame, 1, 600)
        if c then
            ui_state.gen_end_frame = v
            set_current_curve(generate_time_scale_curve())
        end
    end

    -- Type-specific value controls (using float sliders for 0-9 range with decimals)
    if gen_type == "Linear" or gen_type == "Ease In" or gen_type == "Ease Out" or
       gen_type == "S-Curve" then
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Start##val", ui_state.gen_val_start, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("End##val", ui_state.gen_val_end, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_time_scale_curve())
        end

        -- Power control for easing curves
        if gen_type ~= "Linear" then
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderFloat("Power##curve", ui_state.gen_power, 1.0, 5.0, "%.1f")
            if c then
                ui_state.gen_power = v
                set_current_curve(generate_time_scale_curve())
            end
        end

    elseif gen_type == "Sine Wave" or gen_type == "Triangle Wave" then
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Min##val", ui_state.gen_val_start, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Max##val", ui_state.gen_val_end, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.TextUnformatted("Wave:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Cycles##wave", ui_state.gen_cycles, 0.5, 10.0, "%.1f")
        if c then
            ui_state.gen_cycles = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Phase##wave", ui_state.gen_phase, 0.0, 1.0, "%.2f")
        if c then
            ui_state.gen_phase = v
            set_current_curve(generate_time_scale_curve())
        end

    elseif gen_type == "Sawtooth" then
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Min##val", ui_state.gen_val_start, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Max##val", ui_state.gen_val_end, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Teeth##saw", ui_state.gen_teeth, 1, 20)
        if c then
            ui_state.gen_teeth = v
            set_current_curve(generate_time_scale_curve())
        end

    elseif gen_type == "Pulse" then
        imgui.TextUnformatted("Values:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Low##val", ui_state.gen_val_start, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("High##val", ui_state.gen_val_end, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_end = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.TextUnformatted("Pulse:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Count##pulse", ui_state.gen_pulses, 1, 20)
        if c then
            ui_state.gen_pulses = v
            set_current_curve(generate_time_scale_curve())
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("Duty##pulse", ui_state.gen_duty, 0.0, 1.0, "%.2f")
        if c then
            ui_state.gen_duty = v
            set_current_curve(generate_time_scale_curve())
        end

    elseif gen_type == "Constant" then
        imgui.TextUnformatted("Value:")
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderFloat("##const_val", ui_state.gen_val_start, 0.0, 9.0, "%.1f")
        if c then
            ui_state.gen_val_start = v
            set_current_curve(generate_time_scale_curve())
        end
    end

    -- Generate button
    if imgui.Button("Generate##btn") then
        local curve = generate_time_scale_curve()
        if curve then
            set_current_curve(curve)
            print_curve_to_console(curve, get_region_key():upper():gsub("_", " "), ui_state.gen_end_frame)
        end
    end
end

--------------------------------------------------------------------------------
-- Preset Buttons
--------------------------------------------------------------------------------

local function draw_preset_buttons()
    imgui.TextUnformatted("Presets:")

    -- Row 1: Most useful patterns for time scale
    if imgui.Button("Normal (2)") then
        ui_state.generator_type = 0  -- Constant
        ui_state.gen_val_start = 2.0
        set_current_curve(generate_time_scale_curve())
    end
    imgui.SameLine()
    -- Climax Peak: normal -> slow -> normal (most common time scale pattern)
    if imgui.Button("Climax Peak") then
        ui_state.generator_type = 5  -- Sine Wave
        ui_state.gen_val_start = 2.0  -- min (normal)
        ui_state.gen_val_end = 9.0    -- max (slow)
        ui_state.gen_cycles = 1.0
        ui_state.gen_phase = 0.75     -- start at min, peak in middle, end at min
        set_current_curve(generate_time_scale_curve())
    end
    imgui.SameLine()
    -- Early Peak: peaks early then returns to normal (good for impact effects)
    if imgui.Button("Early Peak") then
        ui_state.generator_type = 5  -- Sine Wave
        ui_state.gen_val_start = 2.0
        ui_state.gen_val_end = 9.0
        ui_state.gen_cycles = 0.5
        ui_state.gen_phase = 0.0      -- peak at 1/4, back to normal at 1/2
        ui_state.gen_start_frame = 0
        ui_state.gen_end_frame = 200  -- only first 200 frames, rest stays normal
        set_current_curve(generate_time_scale_curve())
    end
    imgui.SameLine()
    if imgui.Button("Slow Start") then
        ui_state.generator_type = 3  -- Ease Out
        ui_state.gen_val_start = 9.0
        ui_state.gen_val_end = 2.0
        ui_state.gen_power = 2.0
        set_current_curve(generate_time_scale_curve())
    end
    imgui.SameLine()
    if imgui.Button("Slow End") then
        ui_state.generator_type = 2  -- Ease In
        ui_state.gen_val_start = 2.0
        ui_state.gen_val_end = 9.0
        ui_state.gen_power = 2.0
        set_current_curve(generate_time_scale_curve())
    end

    -- Row 2: More patterns
    if imgui.Button("Pulse Slow") then
        ui_state.generator_type = 8  -- Pulse
        ui_state.gen_val_start = 2.0
        ui_state.gen_val_end = 7.0
        ui_state.gen_pulses = 3
        ui_state.gen_duty = 0.3
        set_current_curve(generate_time_scale_curve())
    end
    imgui.SameLine()
    if imgui.Button("Wave") then
        ui_state.generator_type = 5  -- Sine Wave
        ui_state.gen_val_start = 2.0
        ui_state.gen_val_end = 6.0
        ui_state.gen_cycles = 2.0
        ui_state.gen_phase = 0.75     -- start and end at normal
        set_current_curve(generate_time_scale_curve())
    end
    imgui.SameLine()
    if imgui.Button("Max Slow (9)") then
        ui_state.generator_type = 0  -- Constant
        ui_state.gen_val_start = 9.0
        set_current_curve(generate_time_scale_curve())
    end
end

--------------------------------------------------------------------------------
-- Action Buttons
--------------------------------------------------------------------------------

local function draw_action_buttons()
    -- Reset to original
    if imgui.Button("Reset to Original##time_scale") then
        if EFFECT_EDITOR.original_timing_curves then
            local region_key = get_region_key()
            local original = EFFECT_EDITOR.original_timing_curves[region_key]
            if original then
                local copy = {}
                for i = 1, TIME_SCALE_LENGTH do
                    copy[i] = original[i] or 0
                end
                set_current_curve(copy)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Help Section
--------------------------------------------------------------------------------

local function draw_help_section()
    if imgui.CollapsingHeader("Help: Time Scale Curves") then
        imgui.Indent()

        imgui.TextUnformatted("Time scale curves control effect playback speed.")
        imgui.TextUnformatted("Higher values = slower playback (dramatic slow-motion).")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("VALUE REFERENCE:")
        imgui.TextUnformatted("  0: No effect (value ignored)")
        imgui.TextUnformatted("  1: 60 FPS (fastest, rarely used)")
        imgui.TextUnformatted("  2: 30 FPS (NORMAL speed)")
        imgui.TextUnformatted("  3: 20 FPS (slight slow)")
        imgui.TextUnformatted("  4: 15 FPS (moderate slow)")
        imgui.TextUnformatted("  5: 12 FPS (medium slow)")
        imgui.TextUnformatted("  6: 10 FPS (heavy slow)")
        imgui.TextUnformatted("  7: 8.6 FPS (very slow)")
        imgui.TextUnformatted("  8: 7.5 FPS (dramatic)")
        imgui.TextUnformatted("  9: 6.7 FPS (MAXIMUM slow)")
        imgui.TextUnformatted("  10-15: INVALID (ignored)")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("REGIONS:")
        imgui.TextUnformatted("  Process Timeline: Used by op_process_timeline_frame")
        imgui.TextUnformatted("    (opcode 41) for parent effect's main animation")
        imgui.TextUnformatted("  Animate Tick: Used by op_animate_tick")
        imgui.TextUnformatted("    (opcode 40) for child effects and Pattern 2 scripts")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("ENABLE FLAGS:")
        imgui.TextUnformatted("  Both timing_curve_ptr != 0 AND the enable bit must be set.")
        imgui.TextUnformatted("  Process Timeline: bit 5 (0x20) in effect_flags")
        imgui.TextUnformatted("  Animate Tick: bit 6 (0x40) in effect_flags")

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    -- Safety check
    if not EFFECT_EDITOR.header then
        imgui.TextUnformatted("No effect loaded.")
        return
    end

    -- Check if timing curves DATA exists (timing_curve_ptr != 0)
    local has_timing_curves = EFFECT_EDITOR.header.timing_curve_ptr ~= 0

    -- Show timing curve pointer status
    imgui.TextUnformatted(string.format("timing_curve_ptr: 0x%X", EFFECT_EDITOR.header.timing_curve_ptr or 0))
    imgui.SameLine()
    if has_timing_curves then
        imgui.TextUnformatted("(section exists)")
    else
        imgui.TextUnformatted("(no section)")
    end

    -- Always show enable flags section (even without data)
    draw_enable_flags()

    -- Show warning if data section doesn't exist
    if not has_timing_curves then
        imgui.Separator()
        imgui.TextUnformatted("WARNING: No timing curve DATA section exists.")
        imgui.TextUnformatted("(header[0x14] timing_curve_ptr = 0)")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("The enable flags above have NO EFFECT without data.")
        imgui.TextUnformatted("")

        -- Create section button
        local can_create = EFFECT_EDITOR.memory_base and EFFECT_EDITOR.memory_base >= 0x80000000
        if can_create then
            if imgui.Button("Create Timing Curves Section##create_timing") then
                if add_timing_section_fn then
                    add_timing_section_fn()
                end
            end
            imgui.SameLine()
            imgui.TextUnformatted("(Inserts 600 bytes, shifts all downstream sections)")
        else
            imgui.TextUnformatted("(Create Timing Curves Section - no memory target)")
        end

        imgui.Separator()
        imgui.TextUnformatted("This effect uses constant playback speed.")
        return
    end

    if not EFFECT_EDITOR.timing_curves then
        imgui.TextUnformatted("Timing curves not loaded. Load an effect first.")
        return
    end

    imgui.Separator()

    -- Region selector
    imgui.TextUnformatted("Region:")
    imgui.SameLine()
    local c, v = imgui.Combo("##region_select", ui_state.selected_region, build_region_items())
    if c then ui_state.selected_region = v end

    -- Get current region curve
    local current_curve = get_current_curve()

    imgui.Separator()

    -- Statistics display
    draw_stats(current_curve)

    -- Print to console with optional truncation
    imgui.SameLine()
    local c, v = imgui.Checkbox("##print_truncate_ts", ui_state.print_truncate_enabled)
    if c then ui_state.print_truncate_enabled = v end
    imgui.SameLine()

    if ui_state.print_truncate_enabled then
        imgui.SetNextItemWidth(60)
        c, v = imgui.SliderInt("End##print_ts", ui_state.print_truncate_frame, 1, 600)
        if c then ui_state.print_truncate_frame = v end
        imgui.SameLine()
    end

    if imgui.Button("Print to Console##time_scale") then
        if current_curve then
            if ui_state.print_truncate_enabled then
                print_curve_to_console(current_curve, get_region_key():upper():gsub("_", " "), ui_state.print_truncate_frame, true)
            else
                print_curve_to_console(current_curve, get_region_key():upper():gsub("_", " "), ui_state.gen_end_frame)
            end
        end
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

    imgui.Separator()

    -- Remove section option
    imgui.TextUnformatted("Structure:")
    imgui.SameLine()
    local can_remove = EFFECT_EDITOR.memory_base and EFFECT_EDITOR.memory_base >= 0x80000000
    if can_remove then
        if imgui.Button("Remove Timing Curves Section##remove_timing") then
            if remove_timing_section_fn then
                remove_timing_section_fn()
            end
        end
        imgui.SameLine()
        imgui.TextUnformatted("(Shifts sections back 600 bytes, clears enable flags)")
    else
        imgui.TextUnformatted("(Remove Timing Curves Section - no memory target)")
    end

    imgui.Separator()

    -- Help section
    draw_help_section()
end

return M
