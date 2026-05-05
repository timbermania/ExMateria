-- ui/sound_timeline_tab.lua
-- Sound Timeline Tab - TIER 1 of the 3-tier sound system
-- Controls WHEN sounds play during effect execution

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

local MAX_KEYFRAMES_FOREACH = 17
local MAX_KEYFRAMES_OUTER = 9

-- Context display names
local CONTEXT_NAMES = {
    animate_tick = "For-Each Phase",
    phase1 = "Phase-1",
    phase2 = "Phase-2",
}

-- Context descriptions
local CONTEXT_DESCRIPTIONS = {
    animate_tick = "3 channels x 17 keyframes. Used by for-each instances and 1-phase effects.",
    phase1 = "3 tracks x 9 keyframes. Pre-spawn phase for 3-phase effects.",
    phase2 = "3 tracks x 9 keyframes. Post-spawn phase for 3-phase effects.",
}

-- Sound ID display names (0-1 = none, 2+ = config channel)
local function get_sound_id_name(sound_id)
    if sound_id <= 1 then
        return "None"
    else
        return string.format("Config Ch%d", sound_id - 2)
    end
end

-- Build sound ID dropdown items
local function build_sound_id_items()
    return "None (0)\0None (1)\0Config Ch0 (2)\0Config Ch1 (3)\0Config Ch2 (4)\0Config Ch3 (5)\0"
end

--------------------------------------------------------------------------------
-- Calculate Cumulative Time
--------------------------------------------------------------------------------

-- Calculate cumulative time (sum of all previous durations)
local function calc_cumulative_time(track, kf_index)
    local total = 0
    for i = 1, kf_index - 1 do
        local kf = track.keyframes[i]
        if kf then
            total = total + (kf.duration or 0)
        end
    end
    return total
end

--------------------------------------------------------------------------------
-- Draw Single Keyframe
--------------------------------------------------------------------------------

local function draw_keyframe(track, kf_index, uid, max_kf_count)
    local kf = track.keyframes[kf_index]
    if not kf then return end

    local is_active = kf_index <= track.max_keyframe + 1
    local cumulative = calc_cumulative_time(track, kf_index)
    local sound_name = get_sound_id_name(kf.sound_id)

    -- Build summary line
    local summary
    if kf.sound_id <= 1 then
        summary = string.format("Dur:%d  (cumulative: %df)", kf.duration, cumulative)
    else
        summary = string.format("Dur:%d  -> %s  (cumulative: %df)", kf.duration, sound_name, cumulative)
    end

    -- Dim inactive keyframes
    if not is_active then
        imgui.PushStyleColor(0, 0xFF888888)  -- Gray text for inactive
    end

    local node_label = string.format("[%d]##%s", kf_index - 1, uid)
    local is_open = imgui.TreeNode(node_label)
    imgui.SameLine()
    imgui.TextUnformatted(summary)

    if not is_active then
        imgui.PopStyleColor()
    end

    if is_open then
        imgui.Indent()

        local c, v

        -- Duration (frames until next keyframe)
        imgui.SetNextItemWidth(150)
        c, v = imgui.DragInt("Duration##" .. uid, kf.duration, 1, 0, 9999)
        if c then kf.duration = v end
        imgui.SameLine()
        imgui.TextUnformatted("frames until next keyframe")

        -- Sound ID dropdown
        imgui.SetNextItemWidth(150)
        c, v = imgui.Combo("Sound##" .. uid, kf.sound_id, build_sound_id_items())
        if c then kf.sound_id = v end

        -- Show what this means
        if kf.sound_id >= 2 then
            local config_idx = kf.sound_id - 2
            imgui.SameLine()
            imgui.TextUnformatted(string.format("(uses effect_flags config channel %d)", config_idx))
        end

        imgui.Unindent()
        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Draw Single Sound Track
--------------------------------------------------------------------------------

local function draw_sound_track(track, context_key, track_order)
    local uid = string.format("%s_t%d", context_key, track.track_index)
    local max_kf_count = track.is_foreach and MAX_KEYFRAMES_FOREACH or MAX_KEYFRAMES_OUTER

    -- Count active sounds in this track
    local active_sounds = 0
    for i = 1, track.max_keyframe + 1 do
        local kf = track.keyframes[i]
        if kf and kf.sound_id >= 2 then
            active_sounds = active_sounds + 1
        end
    end

    -- Collapsible header for the track
    local header_label = string.format("Channel %d [%d sounds]##%s", track.track_index - 1, active_sounds, uid)
    local header_flags = (track_order == 1) and 32 or 0  -- 32 = DefaultOpen for first track

    if imgui.CollapsingHeader(header_label, header_flags) then
        imgui.Indent()

        local c, v

        -- Max keyframe slider
        imgui.SetNextItemWidth(200)
        c, v = imgui.SliderInt("Max Keyframe##" .. uid, track.max_keyframe, -1, max_kf_count - 1)
        if c then track.max_keyframe = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("(%d keyframes active)", track.max_keyframe + 1))

        imgui.Separator()

        -- Draw keyframes
        for kf_idx = 1, max_kf_count do
            local kf_uid = string.format("%s_kf%d", uid, kf_idx)
            draw_keyframe(track, kf_idx, kf_uid, max_kf_count)
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

        -- Draw tracks for this context (3 tracks per context)
        local context_tracks = tracks[context_key]
        if context_tracks then
            for i = 1, 3 do
                local track = context_tracks[i]
                if track then
                    draw_sound_track(track, context_key, i)
                end
            end
        else
            imgui.TextUnformatted("(no tracks)")
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Draw Help Section
--------------------------------------------------------------------------------

local function draw_help_section()
    if imgui.CollapsingHeader("Help: Sound Timeline (TIER 1)") then
        imgui.Indent()

        imgui.TextUnformatted("Sound timeline tracks control WHEN sounds play during effect execution.")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("3-TIER SOUND SYSTEM:")
        imgui.TextUnformatted("  TIER 1: Timeline tracks (this tab) - WHEN sounds trigger")
        imgui.TextUnformatted("  TIER 2: Config channels (Sound tab) - HOW sounds are selected")
        imgui.TextUnformatted("  TIER 3: feds opcodes (Sound tab) - WHAT sounds play")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("DATA FLOW:")
        imgui.TextUnformatted("  Timeline keyframe sound_id=3")
        imgui.TextUnformatted("    -> Config channel (3-2) = channel 1")
        imgui.TextUnformatted("    -> Config mode selects id_a/id_b/id_c")
        imgui.TextUnformatted("    -> feds pair plays SMD instructions")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("DURATION VALUES:")
        imgui.TextUnformatted("  - Each keyframe stores 'frames until NEXT keyframe'")
        imgui.TextUnformatted("  - Sound plays at the START of each keyframe")
        imgui.TextUnformatted("  - Duration of keyframe 0 = frames before keyframe 1 triggers")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("SOUND ID VALUES:")
        imgui.TextUnformatted("  0, 1 = No sound (skip this keyframe)")
        imgui.TextUnformatted("  2 = Use Config Channel 0")
        imgui.TextUnformatted("  3 = Use Config Channel 1")
        imgui.TextUnformatted("  4 = Use Config Channel 2")
        imgui.TextUnformatted("  5 = Use Config Channel 3")
        imgui.TextUnformatted("")

        imgui.TextUnformatted("CONTEXTS:")
        imgui.TextUnformatted("  For-Each: 3 channels x 17 keyframes (54 bytes each)")
        imgui.TextUnformatted("  Phase-1/2: 3 tracks x 9 keyframes (30 bytes each)")

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.sound_timelines then
        imgui.TextUnformatted("No sound timelines loaded. Load an effect first.")
        return
    end

    -- Count total tracks with sounds
    local total_sounds = 0
    for _, context_key in ipairs({"animate_tick", "phase1", "phase2"}) do
        local context_tracks = EFFECT_EDITOR.sound_timelines[context_key]
        if context_tracks then
            for i = 1, 3 do
                local track = context_tracks[i]
                if track then
                    for kf_idx = 1, track.max_keyframe + 1 do
                        local kf = track.keyframes[kf_idx]
                        if kf and kf.sound_id >= 2 then
                            total_sounds = total_sounds + 1
                        end
                    end
                end
            end
        end
    end

    imgui.TextUnformatted(string.format("9 tracks loaded (%d sound triggers total)", total_sounds))

    -- Help section (collapsed by default)
    draw_help_section()

    imgui.Separator()

    -- Draw each context section
    -- Order: for-each (default open), phase-1, phase-2
    draw_context_section("animate_tick", EFFECT_EDITOR.sound_timelines, true)
    draw_context_section("phase1", EFFECT_EDITOR.sound_timelines, false)
    draw_context_section("phase2", EFFECT_EDITOR.sound_timelines, false)
end

return M
