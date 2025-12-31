-- ui/color_tracks_tab.lua
-- Color Tracks Timeline Editor Tab
-- Displays and edits color/palette keyframes for all 12 tracks (4 per context, 3 contexts)

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local helpers = nil

function M.set_dependencies(helpers_mod)
    helpers = helpers_mod
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local MAX_COLOR_KEYFRAMES = 33

-- Track names by index (0-indexed in data, but displayed 1-indexed for users)
local TRACK_NAMES = {
    [0] = "Affected Units",
    [1] = "Caster",
    [2] = "Target",
    [3] = "Screen Effect",
}

-- Context display names (nomenclature: phase-1, for-each, phase-2)
local CONTEXT_NAMES = {
    animate_tick = "For-Each Phase",
    phase1 = "Phase-1",
    phase2 = "Phase-2",
}

-- Context descriptions for help section
local CONTEXT_DESCRIPTIONS = {
    animate_tick = "Used by for-each instances and 1-phase effects. Called via for_each_phase_timeline_tick (opcode 40).",
    phase1 = "Used by 3-phase effects before for-each spawning. Called via outer_phases_timeline_tick (opcode 41).",
    phase2 = "Used by 3-phase effects after phase2_delay. Called via outer_phases_timeline_tick (opcode 41).",
}

-- Track descriptions
local TRACK_DESCRIPTIONS = {
    [0] = "Affects all units on the battlefield (including caster/target).",
    [1] = "Affects only the caster unit.",
    [2] = "Affects only the target unit(s).",
    [3] = "Screen-wide effect: Gradient (Top/Bottom RGB) or Tint (additive overlay).",
}

-- Palette mode descriptions (modes 0-10 are valid)
local PALETTE_MODE_NAMES = {
    [0] = "Add RGB (full)",
    [1] = "Add RGB/2 (half)",
    [2] = "Luma blend (2R+3G+B)/6",
    [3] = "Luma blend alt",
    [4] = "Set from table (full)",
    [5] = "Set from table (half)",
    [6] = "Table luma blend",
    [7] = "Table luma blend alt",
    [8] = "Replace palette",
    [9] = "Pulsing/Flash",
    [10] = "Clear/Reset",
}

--------------------------------------------------------------------------------
-- Helper: Decode/Encode control flags
--------------------------------------------------------------------------------

-- Ctrl byte: bit 7 = enable, bits 0-6 = mode
-- For screen tracks: bit 7 = 0 means Fade mode, bit 7 = 1 means Tint mode
local function decode_ctrl_flags(ctrl, is_screen)
    if is_screen then
        return {
            is_tint = (ctrl >= 128),  -- bit 7 set = Tint mode
            mode = ctrl % 128,        -- bits 0-6
        }
    else
        return {
            enabled = (ctrl >= 128),  -- bit 7 set = enabled
            mode = ctrl % 128,        -- bits 0-6
        }
    end
end

local function encode_ctrl_flags(decoded, is_screen)
    if is_screen then
        local base = decoded.mode % 128
        if decoded.is_tint then
            return base + 128
        else
            return base
        end
    else
        local base = decoded.mode % 128
        if decoded.enabled then
            return base + 128
        else
            return base
        end
    end
end

--------------------------------------------------------------------------------
-- Helper: Calculate duration from time value
--------------------------------------------------------------------------------

local function calc_duration(time_value)
    if time_value == 0 then
        return 1
    else
        return time_value * 8  -- Left shift by 3 = multiply by 8
    end
end

--------------------------------------------------------------------------------
-- Helper: Byte <-> Signed conversion for Tint mode
-- In Tint mode, RGB bytes are read as SIGNED chars (-128 to +127) then doubled.
-- byte 0-127 -> signed 0 to +127 (brighten)
-- byte 128-255 -> signed -128 to -1 (darken)
--------------------------------------------------------------------------------

local function byte_to_signed(b)
    if b > 127 then
        return b - 256
    else
        return b
    end
end

local function signed_to_byte(s)
    if s < 0 then
        return s + 256
    else
        return s
    end
end

--------------------------------------------------------------------------------
-- Draw Single Keyframe (Palette Track)
--------------------------------------------------------------------------------

local function draw_palette_keyframe(track, kf_index, uid)
    local kf = track.keyframes[kf_index]
    if not kf then return end

    local is_active = kf_index <= track.max_keyframe + 1
    local decoded = decode_ctrl_flags(kf.ctrl, false)

    -- Build summary line
    local dur = calc_duration(kf.time)
    local mode_name = PALETTE_MODE_NAMES[decoded.mode] or "?"
    local enabled_str = decoded.enabled and "[ON]" or "[off]"
    local summary = string.format("Time:%d (dur:%d)  RGB:(%d,%d,%d)  Mode:%d (%s) %s",
        kf.time, dur, kf.r, kf.g, kf.b, decoded.mode, mode_name, enabled_str)

    -- Dim inactive keyframes
    if not is_active then
        imgui.PushStyleColor(0, 0xFF888888)  -- Gray text for inactive
    end

    local node_label = string.format("KF[%d]##%s", kf_index - 1, uid)
    local is_open = imgui.TreeNode(node_label)
    imgui.SameLine()
    imgui.TextUnformatted(summary)

    if not is_active then
        imgui.PopStyleColor()
    end

    if is_open then
        imgui.Indent()

        local c, v

        -- Time value
        imgui.SetNextItemWidth(150)
        c, v = imgui.SliderInt("Time##" .. uid, kf.time, 0, 255)
        if c then kf.time = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("(duration: %d frames)", calc_duration(kf.time)))

        -- RGB values on one line
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("R##" .. uid, kf.r, 0, 255)
        if c then kf.r = v end
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("G##" .. uid, kf.g, 0, 255)
        if c then kf.g = v end
        imgui.SameLine()
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("B##" .. uid, kf.b, 0, 255)
        if c then kf.b = v end

        -- Color preview (RGBA floats 0-1 for ImGui)
        imgui.SameLine()
        imgui.ColorButton("##preview" .. uid, kf.r / 255.0, kf.g / 255.0, kf.b / 255.0, 1.0)

        -- Control flags
        imgui.SetNextItemWidth(80)
        c, v = imgui.SliderInt("Mode##" .. uid, decoded.mode, 0, 10)
        if c then
            decoded.mode = v
            kf.ctrl = encode_ctrl_flags(decoded, false)
        end
        imgui.SameLine()
        local mode_name = PALETTE_MODE_NAMES[decoded.mode] or "Unknown"
        imgui.TextUnformatted(string.format("(%s)", mode_name))
        imgui.SameLine()
        c, v = imgui.Checkbox("Enabled##" .. uid, decoded.enabled)
        if c then
            decoded.enabled = v
            kf.ctrl = encode_ctrl_flags(decoded, false)
        end

        imgui.Unindent()
        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Draw Single Keyframe (Screen Track)
--------------------------------------------------------------------------------

local function draw_screen_keyframe(track, kf_index, uid)
    local kf = track.keyframes[kf_index]
    if not kf then return end

    local is_active = kf_index <= track.max_keyframe + 1
    local decoded = decode_ctrl_flags(kf.ctrl, true)

    -- Build summary line
    local dur = calc_duration(kf.time)
    local mode_str
    local summary
    if decoded.is_tint then
        local blend_name = PALETTE_MODE_NAMES[decoded.mode] or "?"
        mode_str = string.format("Tint:%d (%s)", decoded.mode, blend_name)
        -- Show signed RGB values for tint mode (semantic values)
        local sr, sg, sb = byte_to_signed(kf.r), byte_to_signed(kf.g), byte_to_signed(kf.b)
        summary = string.format("Time:%d (dur:%d)  Tint:(%+d,%+d,%+d)  [%s]",
            kf.time, dur, sr, sg, sb, mode_str)
    else
        mode_str = "Gradient"
        summary = string.format("Time:%d (dur:%d)  Top:(%d,%d,%d) Bot:(%d,%d,%d)  [%s]",
            kf.time, dur, kf.r, kf.g, kf.b, kf.end_r, kf.end_g, kf.end_b, mode_str)
    end

    -- Dim inactive keyframes
    if not is_active then
        imgui.PushStyleColor(0, 0xFF888888)
    end

    local node_label = string.format("KF[%d]##%s", kf_index - 1, uid)
    local is_open = imgui.TreeNode(node_label)
    imgui.SameLine()
    imgui.TextUnformatted(summary)

    if not is_active then
        imgui.PopStyleColor()
    end

    if is_open then
        imgui.Indent()

        local c, v

        -- Time value
        imgui.SetNextItemWidth(150)
        c, v = imgui.SliderInt("Time##" .. uid, kf.time, 0, 255)
        if c then kf.time = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("(duration: %d frames)", calc_duration(kf.time)))

        -- Start RGB / Tint RGB
        if decoded.is_tint then
            -- Tint mode: show signed sliders (-128 to +127) with raw byte for reference
            imgui.TextUnformatted("Tint RGB: ")
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            local sr = byte_to_signed(kf.r)
            c, v = imgui.SliderInt("R##start" .. uid, sr, -128, 127)
            if c then kf.r = signed_to_byte(v) end
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            local sg = byte_to_signed(kf.g)
            c, v = imgui.SliderInt("G##start" .. uid, sg, -128, 127)
            if c then kf.g = signed_to_byte(v) end
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            local sb = byte_to_signed(kf.b)
            c, v = imgui.SliderInt("B##start" .. uid, sb, -128, 127)
            if c then kf.b = signed_to_byte(v) end
            imgui.SameLine()
            imgui.TextUnformatted(string.format("[raw:%d,%d,%d]", kf.r, kf.g, kf.b))
        else
            -- Gradient mode: Top RGB (top of screen)
            imgui.TextUnformatted("Top RGB:  ")
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("R##start" .. uid, kf.r, 0, 255)
            if c then kf.r = v end
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("G##start" .. uid, kf.g, 0, 255)
            if c then kf.g = v end
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("B##start" .. uid, kf.b, 0, 255)
            if c then kf.b = v end
            imgui.SameLine()
            imgui.ColorButton("##startpreview" .. uid, kf.r / 255.0, kf.g / 255.0, kf.b / 255.0, 1.0)
        end

        -- Bottom RGB (only used in Gradient mode)
        if decoded.is_tint then
            imgui.TextUnformatted("Bottom:   ")
            imgui.SameLine()
            imgui.TextUnformatted(string.format("(%d,%d,%d) - ignored in Tint", kf.end_r, kf.end_g, kf.end_b))
        else
            imgui.TextUnformatted("Bottom RGB:")
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("R##end" .. uid, kf.end_r, 0, 255)
            if c then kf.end_r = v end
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("G##end" .. uid, kf.end_g, 0, 255)
            if c then kf.end_g = v end
            imgui.SameLine()
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("B##end" .. uid, kf.end_b, 0, 255)
            if c then kf.end_b = v end
            imgui.SameLine()
            imgui.ColorButton("##endpreview" .. uid, kf.end_r / 255.0, kf.end_g / 255.0, kf.end_b / 255.0, 1.0)
        end

        -- Mode toggle: Fade vs Tint
        c, v = imgui.Checkbox("Tint Mode##" .. uid, decoded.is_tint)
        if c then
            decoded.is_tint = v
            kf.ctrl = encode_ctrl_flags(decoded, true)
        end
        imgui.SameLine()
        if decoded.is_tint then
            -- In Tint mode, bits 0-6 specify the blend mode (same as palette modes)
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("Blend##" .. uid, decoded.mode, 0, 10)
            if c then
                decoded.mode = v
                kf.ctrl = encode_ctrl_flags(decoded, true)
            end
            imgui.SameLine()
            local mode_name = PALETTE_MODE_NAMES[decoded.mode] or "?"
            imgui.TextUnformatted(string.format("(%s, +bright/-dark, x2)", mode_name))
        else
            -- In Gradient mode, bits 0-6 are ignored - vertical screen gradient
            imgui.TextUnformatted("(vertical gradient: Top->Bottom)")
        end

        imgui.Unindent()
        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Draw Single Color Track
--------------------------------------------------------------------------------

local function draw_color_track(track, context_key, track_order)
    local track_name = TRACK_NAMES[track.track_index] or string.format("Track %d", track.track_index)
    local uid = string.format("%s_t%d", context_key, track.track_index)
    local is_screen = (track.track_type == "screen")

    -- Collapsible header for the track
    local header_label = string.format("%s (Track %d)##%s", track_name, track.track_index, uid)
    local header_flags = (track_order == 1) and 32 or 0  -- 32 = DefaultOpen for first track

    if imgui.CollapsingHeader(header_label, header_flags) then
        imgui.Indent()

        local c, v

        -- Track description
        imgui.TextUnformatted(TRACK_DESCRIPTIONS[track.track_index] or "")

        -- Max keyframe slider
        imgui.SetNextItemWidth(200)
        c, v = imgui.SliderInt("Max Keyframe##" .. uid, track.max_keyframe, -1, MAX_COLOR_KEYFRAMES - 1)
        if c then track.max_keyframe = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("(%d keyframes active)", track.max_keyframe + 1))

        imgui.Separator()

        -- Draw keyframes
        for kf_idx = 1, MAX_COLOR_KEYFRAMES do
            local kf_uid = string.format("%s_kf%d", uid, kf_idx)
            if is_screen then
                draw_screen_keyframe(track, kf_idx, kf_uid)
            else
                draw_palette_keyframe(track, kf_idx, kf_uid)
            end
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Draw Context Section (for-each, phase-1, or phase-2)
--------------------------------------------------------------------------------

local function draw_context_section(context_key, tracks, is_first)
    local context_name = CONTEXT_NAMES[context_key] or context_key
    local header_flags = is_first and 32 or 0  -- 32 = DefaultOpen

    local header_label = string.format("%s##%s_section", context_name, context_key)

    if imgui.CollapsingHeader(header_label, header_flags) then
        imgui.Indent()

        -- Context description
        imgui.TextUnformatted(CONTEXT_DESCRIPTIONS[context_key] or "")
        imgui.Separator()

        -- Draw tracks for this context (there are 4 tracks per context)
        local track_order = 0
        for _, track in ipairs(tracks) do
            if track.context == context_key then
                track_order = track_order + 1
                draw_color_track(track, context_key, track_order)
            end
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Draw Help Section
--------------------------------------------------------------------------------

local function draw_help_section()
    if imgui.CollapsingHeader("Help: Color Tracks") then
        imgui.Indent()

        imgui.TextUnformatted("Color tracks apply palette/color effects to units and the screen.")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("PALETTE TRACKS (0-2):")
        imgui.TextUnformatted("  - Modify unit sprite palettes during the effect")
        imgui.TextUnformatted("  - RGB values are added/subtracted from palette colors")
        imgui.TextUnformatted("  - 'Enabled' flag (bit 7) must be set for keyframe to apply")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("  PALETTE MODES (0-10):")
        imgui.TextUnformatted("    0: Add RGB at full strength")
        imgui.TextUnformatted("    1: Add RGB at half strength (RGB/2)")
        imgui.TextUnformatted("    2: Luminance blend - (2R+3G+B)/6 added to all channels")
        imgui.TextUnformatted("    3: Luminance blend (alternate formula)")
        imgui.TextUnformatted("    4: Set from color table (full strength)")
        imgui.TextUnformatted("    5: Set from color table (half strength)")
        imgui.TextUnformatted("    6: Color table with luminance average")
        imgui.TextUnformatted("    7: Color table with luminance average (alt)")
        imgui.TextUnformatted("    8: Replace palette directly (not additive)")
        imgui.TextUnformatted("    9: Pulsing/Flash (rapid oscillation)")
        imgui.TextUnformatted("   10: Clear/Reset palette effect")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("SCREEN TRACK (3):")
        imgui.TextUnformatted("  - Applies screen-wide color effects")
        imgui.TextUnformatted("  - GRADIENT mode (bit 7=0): vertical screen gradient")
        imgui.TextUnformatted("      Top RGB = top of screen, Bottom RGB = bottom of screen")
        imgui.TextUnformatted("      Bits 0-6 are IGNORED in gradient mode")
        imgui.TextUnformatted("  - TINT mode (bit 7=1): additive overlay")
        imgui.TextUnformatted("      RGB values are SIGNED (-128 to +127) and DOUBLED")
        imgui.TextUnformatted("      Bits 0-6 = blend mode (same as palette modes 0-10)")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("INTERPOLATION:")
        imgui.TextUnformatted("  - Keyframe transitions use hardcoded ROM curves (not editable)")
        imgui.TextUnformatted("  - Smooth fades happen automatically based on color delta")
        imgui.TextUnformatted("  - See COLOR_TRACK_INTERPOLATION.md for details")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("TIME VALUES:")
        imgui.TextUnformatted("  - Duration = time_value * 8 (or 1 if time_value is 0)")
        imgui.TextUnformatted("  - Keyframes up to max_keyframe are active")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("CONTEXTS:")
        imgui.TextUnformatted("  - For-Each: used by for-each instances and 1-phase effects")
        imgui.TextUnformatted("  - Phase-1: before for-each spawning (3-phase effects)")
        imgui.TextUnformatted("  - Phase-2: after phase2_delay (3-phase effects)")

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.color_tracks or #EFFECT_EDITOR.color_tracks == 0 then
        imgui.TextUnformatted("No color tracks loaded. Load an effect first.")
        return
    end

    imgui.TextUnformatted(string.format("%d tracks loaded", #EFFECT_EDITOR.color_tracks))

    -- Help section (collapsed by default)
    draw_help_section()

    imgui.Separator()

    -- Draw each context section
    -- Order: for-each (default open), phase-1, phase-2
    draw_context_section("animate_tick", EFFECT_EDITOR.color_tracks, true)
    draw_context_section("phase1", EFFECT_EDITOR.color_tracks, false)
    draw_context_section("phase2", EFFECT_EDITOR.color_tracks, false)
end

return M
