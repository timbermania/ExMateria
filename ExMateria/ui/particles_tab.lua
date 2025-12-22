-- ui/particles_tab.lua
-- Particles tab with emitter editing UI

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
-- Add/Delete Emitter State
--------------------------------------------------------------------------------

local clone_source_index = 0  -- 0-indexed emitter to clone when adding

--------------------------------------------------------------------------------
-- Local Helper (uses injected helpers module)
--------------------------------------------------------------------------------

local function slider_int16(label, value, min, max, width)
    return helpers.slider_int16(label, value, min, max, width)
end

--------------------------------------------------------------------------------
-- Nibble Helpers for Curve Indices
--------------------------------------------------------------------------------

-- Extract low nibble (bits 0-3) from byte
local function get_low_nibble(byte)
    return byte % 16
end

-- Extract high nibble (bits 4-7) from byte
local function get_high_nibble(byte)
    return math.floor(byte / 16)
end

-- Pack two nibbles into one byte
local function pack_nibbles(low, high)
    return (low % 16) + (high % 16) * 16
end

--------------------------------------------------------------------------------
-- Curve Selector Widget
--------------------------------------------------------------------------------

-- Combo items for curve selection (indices 0-14 = curves 1-15, index 15 = none)
-- Labels are 1-based to match the Curves tab display
local CURVE_ITEMS = "1\0002\0003\0004\0005\0006\0007\0008\0009\00010\00011\00012\00013\00014\00015\0None\0"
local HOMING_CURVE_ITEMS = "1\0002\0003\0004\0"

-- Reusable curve selector combo
-- label: display name
-- emitter: emitter table
-- byte_field: field name like "curve_indices_08"
-- is_high_nibble: true for high nibble (bits 4-7), false for low (bits 0-3)
-- uid: unique id suffix for imgui
local function curve_selector(label, emitter, byte_field, is_high_nibble, uid)
    local byte_val = emitter[byte_field]
    local current = is_high_nibble and get_high_nibble(byte_val) or get_low_nibble(byte_val)

    imgui.SetNextItemWidth(60)
    local changed, new_val = imgui.Combo(label .. "##curve" .. uid, current, CURVE_ITEMS)
    if changed then
        if is_high_nibble then
            emitter[byte_field] = pack_nibbles(get_low_nibble(byte_val), new_val)
        else
            emitter[byte_field] = pack_nibbles(new_val, get_high_nibble(byte_val))
        end
    end
    return changed
end

--------------------------------------------------------------------------------
-- Particles Tab Drawing
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.particle_header or not EFFECT_EDITOR.emitters then
        imgui.TextUnformatted("No particle data loaded")
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
        imgui.SameLine()
        local changed, new_val = imgui.extra.InputText("##mem_base", string.format("%08X", EFFECT_EDITOR.memory_base))
        if changed then
            EFFECT_EDITOR.memory_base = tonumber(new_val, 16) or 0
        end
    end

    -- Structure change warning
    if EFFECT_EDITOR.original_emitter_count and
       #EFFECT_EDITOR.emitters ~= EFFECT_EDITOR.original_emitter_count then
        imgui.Separator()
        imgui.TextUnformatted(string.format("** STRUCTURE MODIFIED: %d -> %d emitters **",
            EFFECT_EDITOR.original_emitter_count, #EFFECT_EDITOR.emitters))
        imgui.TextUnformatted("Click 'Apply All to Memory' to commit changes")
    end

    imgui.Separator()

    -- Add Emitter controls
    if Parser and #EFFECT_EDITOR.emitters > 0 then
        imgui.TextUnformatted("Add Emitter:")
        imgui.SameLine()

        -- Build emitter dropdown items
        local emitter_items = ""
        for idx, em in ipairs(EFFECT_EDITOR.emitters) do
            emitter_items = emitter_items .. tostring(em.index) .. "\0"
        end

        -- Clamp clone_source_index to valid range
        if clone_source_index >= #EFFECT_EDITOR.emitters then
            clone_source_index = #EFFECT_EDITOR.emitters - 1
        end

        imgui.SetNextItemWidth(60)
        local c, v = imgui.Combo("Clone from##add_emitter", clone_source_index, emitter_items)
        if c then clone_source_index = v end

        imgui.SameLine()
        if imgui.Button("Add##add_emitter") then
            -- Clone the selected emitter
            local source = EFFECT_EDITOR.emitters[clone_source_index + 1]
            local new_index = #EFFECT_EDITOR.emitters  -- 0-indexed, so this is next available
            local new_emitter = Parser.copy_emitter(source, new_index)
            table.insert(EFFECT_EDITOR.emitters, new_emitter)
            EFFECT_EDITOR.emitter_count = #EFFECT_EDITOR.emitters
        end

        imgui.SameLine()
        imgui.TextUnformatted(string.format("(%d emitters)", #EFFECT_EDITOR.emitters))
    end

    imgui.Separator()

    local ph = EFFECT_EDITOR.particle_header

    -- Particle System Header
    if imgui.CollapsingHeader("System Header", 32) then  -- 32 = DefaultOpen
        imgui.TextUnformatted(string.format("Constant: %d", ph.constant))
        imgui.TextUnformatted(string.format("Emitter Count: %d (embedded), %d (calculated)",
            ph.emitter_count, EFFECT_EDITOR.emitter_count))

        imgui.Separator()
        imgui.TextUnformatted("Global Physics:")
        imgui.Indent()

        -- Gravity sliders (32-bit signed, 4096 = normal gravity)
        local c, v
        imgui.TextUnformatted("Gravity (4096 = normal, negative = upward):")
        c, v = imgui.SliderInt("X##gravity", ph.gravity_x, -8192, 8192)
        if c then ph.gravity_x = v end
        c, v = imgui.SliderInt("Y##gravity", ph.gravity_y, -8192, 8192)
        if c then ph.gravity_y = v end
        c, v = imgui.SliderInt("Z##gravity", ph.gravity_z, -8192, 8192)
        if c then ph.gravity_z = v end

        imgui.Separator()
        imgui.TextUnformatted("Inertia Threshold (damping cutoff):")
        c, v = imgui.SliderInt("##inertia_thresh", ph.inertia_threshold, 0, 8000)
        if c then ph.inertia_threshold = v end
        imgui.SameLine()
        imgui.TextUnformatted("(typical: 32-512)")

        imgui.Unindent()
    end

    imgui.Separator()

    -- Emitter list
    local emitter_to_delete = nil
    for i, e in ipairs(EFFECT_EDITOR.emitters) do
        local emitter_label = string.format("Emitter %d (anim=%d)", e.index, e.anim_index)

        -- Delete button (only show if more than 1 emitter)
        if #EFFECT_EDITOR.emitters > 1 then
            if imgui.Button("X##del_emitter" .. i) then
                emitter_to_delete = i
            end
            imgui.SameLine()
        end

        if imgui.CollapsingHeader(emitter_label .. "###emitter" .. i) then
            imgui.Indent()

            M.draw_control_bytes(e, i)
            M.draw_position(e, i)
            M.draw_spread(e, i)
            M.draw_velocity(e, i)
            M.draw_physics(e, i)
            M.draw_lifetime(e, i)
            M.draw_spawn(e, i)
            M.draw_homing(e, i)
            M.draw_child_emitters(e, i)

            imgui.Unindent()
        end
    end

    -- Handle deletion after iteration (to avoid modifying table while iterating)
    if emitter_to_delete then
        table.remove(EFFECT_EDITOR.emitters, emitter_to_delete)
        -- Re-index remaining emitters
        for idx, em in ipairs(EFFECT_EDITOR.emitters) do
            em.index = idx - 1  -- 0-indexed
        end
        EFFECT_EDITOR.emitter_count = #EFFECT_EDITOR.emitters
    end
end

--------------------------------------------------------------------------------
-- Control Bytes Section
--------------------------------------------------------------------------------

function M.draw_control_bytes(e, i)
    if imgui.TreeNode("Control Bytes##" .. i) then
        local c, v

        -- Combo items as null-separated strings (PCSX-Redux imgui binding format)
        local ANCHOR_ITEMS = "WORLD\0CURSOR\0ORIGIN\0TARGET\0PARENT\0CAMERA\0TRACKED\0"
        local SPREAD_ITEMS = "Sphere\0Box\0"
        local CHILD_ITEMS = "Disabled\0Mode 1\0Mode 2\0Disabled(3)\0"
        local HOMING_ITEMS = "Disabled\00016 units\00032 units\00048 units\0"

        -- Animation indices (sliders)
        c, v = imgui.SliderInt("Anim Index##cb" .. i, e.anim_index, 0, 14)
        if c then e.anim_index = v end
        c, v = imgui.SliderInt("Anim Param##cb" .. i, e.anim_param, 0, 2)
        if c then e.anim_param = v end

        imgui.Separator()
        imgui.TextUnformatted("Spawn Anchor (where particles spawn):")

        -- Decode emitter_anchor_mode from animation_target_flag bits 1-3
        local emitter_anchor = math.floor(e.animation_target_flag / 2) % 8
        c, v = imgui.Combo("Emitter Anchor##cb" .. i, emitter_anchor, ANCHOR_ITEMS)
        if c then
            -- Clear bits 1-3, set new value
            e.animation_target_flag = (e.animation_target_flag % 2) + (v * 2) + (math.floor(e.animation_target_flag / 16) * 16)
        end

        -- Decode spread_mode from animation_target_flag bit 0
        local spread_mode = e.animation_target_flag % 2
        c, v = imgui.Combo("Spread Mode##cb" .. i, spread_mode, SPREAD_ITEMS)
        if c then
            e.animation_target_flag = v + (math.floor(e.animation_target_flag / 2) * 2)
        end

        imgui.Separator()
        imgui.TextUnformatted("Target Anchor (where particles home toward):")

        -- Decode target_anchor_mode from motion_type_flag bits 5-7
        local target_anchor = math.floor(e.motion_type_flag / 32) % 8
        c, v = imgui.Combo("Target Anchor##cb" .. i, target_anchor, ANCHOR_ITEMS)
        if c then
            -- Clear bits 5-7, set new value
            e.motion_type_flag = (e.motion_type_flag % 32) + (v * 32)
        end

        imgui.Separator()
        imgui.TextUnformatted("Velocity Flags:")

        -- align_to_velocity: motion_type_flag bit 1
        local align_vel = (math.floor(e.motion_type_flag / 2) % 2) == 1
        c, v = imgui.Checkbox("Align to Velocity##cb" .. i, align_vel)
        if c then
            if v then
                e.motion_type_flag = e.motion_type_flag + 2 - (e.motion_type_flag % 4 >= 2 and 2 or 0)
            else
                e.motion_type_flag = e.motion_type_flag - (e.motion_type_flag % 4 >= 2 and 2 or 0)
            end
        end

        -- velocity_inward: emitter_flags_lo bit 4
        local vel_inward = (math.floor(e.emitter_flags_lo / 16) % 2) == 1
        c, v = imgui.Checkbox("Velocity Inward##cb" .. i, vel_inward)
        if c then
            if v then
                e.emitter_flags_lo = e.emitter_flags_lo + 16 - (math.floor(e.emitter_flags_lo / 16) % 2 == 1 and 16 or 0)
            else
                e.emitter_flags_lo = e.emitter_flags_lo - (math.floor(e.emitter_flags_lo / 16) % 2 == 1 and 16 or 0)
            end
        end

        -- align_to_unit_facing: emitter_flags_hi bit 2
        local align_facing = (math.floor(e.emitter_flags_hi / 4) % 2) == 1
        c, v = imgui.Checkbox("Align to Unit Facing##cb" .. i, align_facing)
        if c then
            if v then
                e.emitter_flags_hi = e.emitter_flags_hi + 4 - (math.floor(e.emitter_flags_hi / 4) % 2 == 1 and 4 or 0)
            else
                e.emitter_flags_hi = e.emitter_flags_hi - (math.floor(e.emitter_flags_hi / 4) % 2 == 1 and 4 or 0)
            end
        end

        imgui.Separator()
        imgui.TextUnformatted("Child Emitters:")

        -- child_death_mode: emitter_flags_lo bits 0-1
        local child_death = e.emitter_flags_lo % 4
        c, v = imgui.Combo("On Death##cb" .. i, child_death, CHILD_ITEMS)
        if c then
            e.emitter_flags_lo = (math.floor(e.emitter_flags_lo / 4) * 4) + v
        end

        -- child_midlife_mode: emitter_flags_lo bits 2-3
        local child_mid = math.floor(e.emitter_flags_lo / 4) % 4
        c, v = imgui.Combo("Mid-Life##cb" .. i, child_mid, CHILD_ITEMS)
        if c then
            local base = e.emitter_flags_lo % 4
            local upper = math.floor(e.emitter_flags_lo / 16) * 16
            e.emitter_flags_lo = base + (v * 4) + upper
        end

        -- Child emitter indices (read from bytes 0xC0-0xC1)
        c, v = imgui.SliderInt("Death Emitter##cb" .. i, e.child_emitter_on_death, 0, 15)
        if c then e.child_emitter_on_death = v end
        c, v = imgui.SliderInt("Mid-Life Emitter##cb" .. i, e.child_emitter_mid_life, 0, 15)
        if c then e.child_emitter_mid_life = v end

        imgui.Separator()
        imgui.TextUnformatted("Homing:")

        -- homing_arrival_threshold: emitter_flags_hi bits 0-1
        local homing_thresh = e.emitter_flags_hi % 4
        c, v = imgui.Combo("Arrival Threshold##cb" .. i, homing_thresh, HOMING_ITEMS)
        if c then
            e.emitter_flags_hi = (math.floor(e.emitter_flags_hi / 4) * 4) + v
        end

        imgui.Separator()
        imgui.TextUnformatted("Color:")

        -- Color curve selectors (R/G/B) - shown first
        imgui.TextUnformatted("Color Curves (R/G/B):")
        imgui.SameLine()
        curve_selector("R", e, "color_curves_rg", false, "colr" .. i)
        imgui.SameLine()
        curve_selector("G", e, "color_curves_rg", true, "colg" .. i)
        imgui.SameLine()
        curve_selector("B", e, "color_curves_b", false, "colb" .. i)

        -- color_curve_enable: emitter_flags_lo bit 6
        local color_curve = (math.floor(e.emitter_flags_lo / 64) % 2) == 1
        c, v = imgui.Checkbox("Enable Color Curves##cb" .. i, color_curve)
        if c then
            if v then
                e.emitter_flags_lo = e.emitter_flags_lo + 64 - (math.floor(e.emitter_flags_lo / 64) % 2 == 1 and 64 or 0)
            else
                e.emitter_flags_lo = e.emitter_flags_lo - (math.floor(e.emitter_flags_lo / 64) % 2 == 1 and 64 or 0)
            end
        end

        imgui.Separator()
        imgui.TextUnformatted(string.format("Raw: motion=0x%02X target=0x%02X flags_lo=0x%02X flags_hi=0x%02X",
            e.motion_type_flag, e.animation_target_flag, e.emitter_flags_lo, e.emitter_flags_hi))

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Position Section
--------------------------------------------------------------------------------

function M.draw_position(e, i)
    if imgui.TreeNode("Position##" .. i) then
        -- Curve selector for emitter position interpolation
        imgui.TextUnformatted("Curve:")
        imgui.SameLine()
        curve_selector("Position", e, "curve_indices_08", false, "pos" .. i)

        imgui.Separator()
        imgui.TextUnformatted(string.format("Start: (%d, %d, %d)",
            e.start_position_x, e.start_position_y, e.start_position_z))
        imgui.TextUnformatted(string.format("End: (%d, %d, %d)",
            e.end_position_x, e.end_position_y, e.end_position_z))

        imgui.Separator()
        local c, v
        c, v = slider_int16("Start X##pos" .. i, e.start_position_x, -200, 200)
        if c then e.start_position_x = v end
        c, v = slider_int16("Start Y##pos" .. i, e.start_position_y, -200, 200)
        if c then e.start_position_y = v end
        c, v = slider_int16("Start Z##pos" .. i, e.start_position_z, -200, 200)
        if c then e.start_position_z = v end

        c, v = slider_int16("End X##pos" .. i, e.end_position_x, -200, 200)
        if c then e.end_position_x = v end
        c, v = slider_int16("End Y##pos" .. i, e.end_position_y, -200, 200)
        if c then e.end_position_y = v end
        c, v = slider_int16("End Z##pos" .. i, e.end_position_z, -200, 200)
        if c then e.end_position_z = v end

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Spread Section
--------------------------------------------------------------------------------

function M.draw_spread(e, i)
    if imgui.TreeNode("Spread##" .. i) then
        -- Curve selector for particle spread interpolation
        imgui.TextUnformatted("Curve:")
        imgui.SameLine()
        curve_selector("Spread", e, "curve_indices_08", true, "spread" .. i)

        imgui.Separator()
        imgui.TextUnformatted(string.format("Start: (%d, %d, %d)",
            e.spread_x_start, e.spread_y_start, e.spread_z_start))
        imgui.TextUnformatted(string.format("End: (%d, %d, %d)",
            e.spread_x_end, e.spread_y_end, e.spread_z_end))

        imgui.Separator()
        local c, v
        c, v = slider_int16("Start X##spread" .. i, e.spread_x_start, 0, 200)
        if c then e.spread_x_start = v end
        c, v = slider_int16("Start Y##spread" .. i, e.spread_y_start, 0, 200)
        if c then e.spread_y_start = v end
        c, v = slider_int16("Start Z##spread" .. i, e.spread_z_start, 0, 200)
        if c then e.spread_z_start = v end

        c, v = slider_int16("End X##spread" .. i, e.spread_x_end, 0, 200)
        if c then e.spread_x_end = v end
        c, v = slider_int16("End Y##spread" .. i, e.spread_y_end, 0, 200)
        if c then e.spread_y_end = v end
        c, v = slider_int16("End Z##spread" .. i, e.spread_z_end, 0, 200)
        if c then e.spread_z_end = v end

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Velocity Section
--------------------------------------------------------------------------------

function M.draw_velocity(e, i)
    if imgui.TreeNode("Velocity##" .. i) then
        -- Curve selectors for velocity interpolation
        imgui.TextUnformatted("Curves:")
        imgui.SameLine()
        curve_selector("Base Angle", e, "curve_indices_09", false, "vba" .. i)
        imgui.SameLine()
        curve_selector("Dir Spread", e, "curve_indices_09", true, "vds" .. i)
        imgui.SameLine()
        curve_selector("Radial Vel", e, "curve_indices_0B", true, "radvel" .. i)

        imgui.Separator()
        imgui.TextUnformatted("Base Angles (Start): (4096 = 360°)")
        imgui.TextUnformatted(string.format("  (%d, %d, %d)",
            e.velocity_base_angle_x_start, e.velocity_base_angle_y_start, e.velocity_base_angle_z_start))
        imgui.TextUnformatted("Base Angles (End):")
        imgui.TextUnformatted(string.format("  (%d, %d, %d)",
            e.velocity_base_angle_x_end, e.velocity_base_angle_y_end, e.velocity_base_angle_z_end))
        imgui.TextUnformatted("Direction Spread (cone angle):")
        imgui.TextUnformatted(string.format("  Start: (%d, %d, %d)  End: (%d, %d, %d)",
            e.velocity_direction_spread_x_start, e.velocity_direction_spread_y_start, e.velocity_direction_spread_z_start,
            e.velocity_direction_spread_x_end, e.velocity_direction_spread_y_end, e.velocity_direction_spread_z_end))

        imgui.Separator()
        local c, v
        imgui.TextUnformatted("Base Angles (±7 rotations):")
        c, v = slider_int16("X Start##vba" .. i, e.velocity_base_angle_x_start, -28672, 28672)
        if c then e.velocity_base_angle_x_start = v end
        c, v = slider_int16("Y Start##vba" .. i, e.velocity_base_angle_y_start, -28672, 28672)
        if c then e.velocity_base_angle_y_start = v end
        c, v = slider_int16("Z Start##vba" .. i, e.velocity_base_angle_z_start, -28672, 28672)
        if c then e.velocity_base_angle_z_start = v end

        c, v = slider_int16("X End##vba" .. i, e.velocity_base_angle_x_end, -28672, 28672)
        if c then e.velocity_base_angle_x_end = v end
        c, v = slider_int16("Y End##vba" .. i, e.velocity_base_angle_y_end, -28672, 28672)
        if c then e.velocity_base_angle_y_end = v end
        c, v = slider_int16("Z End##vba" .. i, e.velocity_base_angle_z_end, -28672, 28672)
        if c then e.velocity_base_angle_z_end = v end

        imgui.TextUnformatted("Direction Spread (cone 0-360°):")
        c, v = slider_int16("X Start##vds" .. i, e.velocity_direction_spread_x_start, 0, 4096)
        if c then e.velocity_direction_spread_x_start = v end
        c, v = slider_int16("Y Start##vds" .. i, e.velocity_direction_spread_y_start, 0, 4096)
        if c then e.velocity_direction_spread_y_start = v end
        c, v = slider_int16("Z Start##vds" .. i, e.velocity_direction_spread_z_start, 0, 4096)
        if c then e.velocity_direction_spread_z_start = v end

        c, v = slider_int16("X End##vds" .. i, e.velocity_direction_spread_x_end, 0, 4096)
        if c then e.velocity_direction_spread_x_end = v end
        c, v = slider_int16("Y End##vds" .. i, e.velocity_direction_spread_y_end, 0, 4096)
        if c then e.velocity_direction_spread_y_end = v end
        c, v = slider_int16("Z End##vds" .. i, e.velocity_direction_spread_z_end, 0, 4096)
        if c then e.velocity_direction_spread_z_end = v end

        -- Radial Velocity (moved from Physics)
        local SLIDER_WIDTH_PAIR = helpers.SLIDER_WIDTH_PAIR
        imgui.TextUnformatted("Radial Velocity (-1=MAX):")
        -- Convert 65535 to -1 for display, -1 back to 65535 for storage
        local rv_min_start_disp = e.radial_velocity_min_start == 65535 and -1 or e.radial_velocity_min_start
        local rv_max_start_disp = e.radial_velocity_max_start == 65535 and -1 or e.radial_velocity_max_start
        local rv_min_end_disp = e.radial_velocity_min_end == 65535 and -1 or e.radial_velocity_min_end
        local rv_max_end_disp = e.radial_velocity_max_end == 65535 and -1 or e.radial_velocity_max_end

        c, v = slider_int16("Min Start##radvel" .. i, rv_min_start_disp, -1, 5000, SLIDER_WIDTH_PAIR)
        if c then e.radial_velocity_min_start = (v == -1) and 65535 or v end
        imgui.SameLine()
        c, v = slider_int16("Max Start##radvel" .. i, rv_max_start_disp, -1, 5000, SLIDER_WIDTH_PAIR)
        if c then e.radial_velocity_max_start = (v == -1) and 65535 or v end
        c, v = slider_int16("Min End##radvel" .. i, rv_min_end_disp, -1, 5000, SLIDER_WIDTH_PAIR)
        if c then e.radial_velocity_min_end = (v == -1) and 65535 or v end
        imgui.SameLine()
        c, v = slider_int16("Max End##radvel" .. i, rv_max_end_disp, -1, 5000, SLIDER_WIDTH_PAIR)
        if c then e.radial_velocity_max_end = (v == -1) and 65535 or v end

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Physics Section
--------------------------------------------------------------------------------

function M.draw_physics(e, i)
    if imgui.TreeNode("Physics##" .. i) then
        -- Curve selectors for physics parameters
        imgui.TextUnformatted("Curves:")
        imgui.SameLine()
        curve_selector("Inertia", e, "curve_indices_0A", false, "inertia" .. i)
        imgui.SameLine()
        curve_selector("Weight", e, "curve_indices_0B", false, "weight" .. i)
        imgui.TextUnformatted("Accel/Drag:")
        imgui.SameLine()
        curve_selector("Accel", e, "curve_indices_0C", false, "accel" .. i)
        imgui.SameLine()
        curve_selector("Drag", e, "curve_indices_0C", true, "drag" .. i)

        imgui.Separator()
        imgui.TextUnformatted(string.format("Inertia: %d-%d (start) -> %d-%d (end)",
            e.inertia_min_start, e.inertia_max_start, e.inertia_min_end, e.inertia_max_end))
        imgui.TextUnformatted(string.format("Weight: %d-%d (start) -> %d-%d (end)",
            e.weight_min_start, e.weight_max_start, e.weight_min_end, e.weight_max_end))

        imgui.Separator()
        local c, v

        helpers.draw_minmax_start_end("Inertia", e, "inertia", 256, 15000)
        helpers.draw_minmax_start_end("Weight (Gravity)", e, "weight", -2500, 2500)

        imgui.Separator()

        helpers.draw_minmax_start_end("Acceleration X", e, "acceleration_x", -2048, 2048)
        helpers.draw_minmax_start_end("Acceleration Y", e, "acceleration_y", -2048, 2048)
        helpers.draw_minmax_start_end("Acceleration Z", e, "acceleration_z", -2048, 2048)

        imgui.Separator()

        helpers.draw_minmax_start_end("Drag X", e, "drag_x", -2048, 2048)
        helpers.draw_minmax_start_end("Drag Y", e, "drag_y", -2048, 2048)
        helpers.draw_minmax_start_end("Drag Z", e, "drag_z", -2048, 2048)

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Lifetime Section
--------------------------------------------------------------------------------

function M.draw_lifetime(e, i)
    if imgui.TreeNode("Lifetime##" .. i) then
        -- Curve selector for lifetime interpolation
        imgui.TextUnformatted("Curve:")
        imgui.SameLine()
        curve_selector("Lifetime", e, "curve_indices_0D", false, "life" .. i)

        imgui.Separator()
        imgui.TextUnformatted(string.format("Lifetime: %d-%d (start) -> %d-%d (end)",
            e.lifetime_min_start, e.lifetime_max_start, e.lifetime_min_end, e.lifetime_max_end))
        if e.lifetime_min_start == -1 or e.lifetime_max_start == -1 then
            imgui.TextUnformatted("(Using animation-driven lifetime)")
        end

        imgui.Separator()
        helpers.draw_minmax_start_end("Lifetime", e, "lifetime", -1, 500)

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Spawn Section
--------------------------------------------------------------------------------

function M.draw_spawn(e, i)
    local SLIDER_WIDTH_PAIR = helpers.SLIDER_WIDTH_PAIR

    if imgui.TreeNode("Spawn##" .. i) then
        -- Curve selectors for spawn parameters
        imgui.TextUnformatted("Curves:")
        imgui.SameLine()
        curve_selector("Count", e, "curve_indices_0E", true, "count" .. i)
        imgui.SameLine()
        -- spawn_interval uses bits 0-3 of byte 0x0F (low nibble)
        curve_selector("Interval", e, "curve_indices_0F", false, "interval" .. i)

        imgui.Separator()
        imgui.TextUnformatted(string.format("Particle Count: %d (start) -> %d (end)",
            e.particle_count_start, e.particle_count_end))
        imgui.TextUnformatted(string.format("Spawn Interval: %d (start) -> %d (end)",
            e.spawn_interval_start, e.spawn_interval_end))

        imgui.Separator()
        local c, v
        c, v = slider_int16("Count Start##spawn" .. i, e.particle_count_start, 0, 30, SLIDER_WIDTH_PAIR)
        if c then e.particle_count_start = v end
        imgui.SameLine()
        c, v = slider_int16("Count End##spawn" .. i, e.particle_count_end, 0, 30, SLIDER_WIDTH_PAIR)
        if c then e.particle_count_end = v end

        c, v = slider_int16("Interval Start##spawn" .. i, e.spawn_interval_start, 0, 100, SLIDER_WIDTH_PAIR)
        if c then e.spawn_interval_start = v end
        imgui.SameLine()
        c, v = slider_int16("Interval End##spawn" .. i, e.spawn_interval_end, 0, 100, SLIDER_WIDTH_PAIR)
        if c then e.spawn_interval_end = v end

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Homing Section
--------------------------------------------------------------------------------

function M.draw_homing(e, i)
    if imgui.TreeNode("Homing##" .. i) then
        -- Curve selectors for homing parameters
        imgui.TextUnformatted("Curves:")
        imgui.SameLine()
        curve_selector("Target Offset", e, "curve_indices_0D", true, "tgtoff" .. i)
        imgui.SameLine()
        -- homing_strength uses bits 4-5 of byte 0x0F (only 0-3 range)
        local hs_curve = math.floor(e.curve_indices_0F / 16) % 4
        imgui.SetNextItemWidth(60)
        local c, v = imgui.Combo("Strength##curve_hom" .. i, hs_curve, HOMING_CURVE_ITEMS)
        if c then
            local low = e.curve_indices_0F % 16
            local adj = math.floor(e.curve_indices_0F / 64)
            e.curve_indices_0F = low + (v * 16) + (adj * 64)
        end
        imgui.SameLine()
        -- homing_adjustment uses bits 6-7 (only 0-3 range)
        local adj_curve = math.floor(e.curve_indices_0F / 64)
        imgui.SetNextItemWidth(60)
        local c2, v2 = imgui.Combo("Adjust##curve_adj" .. i, adj_curve, HOMING_CURVE_ITEMS)
        if c2 then
            e.curve_indices_0F = (e.curve_indices_0F % 64) + (v2 * 64)
        end

        imgui.Separator()
        -- Display homing strength (0 = disabled/simple physics)
        imgui.TextUnformatted(string.format("Strength: %d-%d (start) -> %d-%d (end)  [0=simple physics]",
            e.homing_strength_min_start, e.homing_strength_max_start,
            e.homing_strength_min_end, e.homing_strength_max_end))

        imgui.TextUnformatted("Target Offset (Start):")
        imgui.TextUnformatted(string.format("  (%d, %d, %d)",
            e.target_offset_x_start, e.target_offset_y_start, e.target_offset_z_start))
        imgui.TextUnformatted("Target Offset (End):")
        imgui.TextUnformatted(string.format("  (%d, %d, %d)",
            e.target_offset_x_end, e.target_offset_y_end, e.target_offset_z_end))

        imgui.Separator()
        helpers.draw_minmax_start_end("Homing Strength (0=simple physics)", e, "homing_strength", 0, 1000)
        helpers.draw_xyz_start_end("Target Offset", e, "target_offset", -200, 200)

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Child Emitters Section
--------------------------------------------------------------------------------

function M.draw_child_emitters(e, i)
    if imgui.TreeNode("Child Emitters##" .. i) then
        imgui.TextUnformatted(string.format("On Death: %d", e.child_emitter_on_death))
        imgui.TextUnformatted(string.format("Mid-Life: %d", e.child_emitter_mid_life))

        imgui.Separator()
        local c, v
        c, v = slider_int16("On Death##child" .. i, e.child_emitter_on_death, 0, 15)
        if c then e.child_emitter_on_death = v end
        c, v = slider_int16("Mid-Life##child" .. i, e.child_emitter_mid_life, 0, 15)
        if c then e.child_emitter_mid_life = v end

        imgui.TreePop()
    end
end

return M
