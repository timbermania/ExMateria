-- ui/header_tab.lua
-- Timeline Header tab (extracted from timeline_tab.lua)

local M = {}

--------------------------------------------------------------------------------
-- Timeline Header Tab Drawing
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.timeline_header then
        imgui.TextUnformatted("No timeline data loaded")
        return
    end

    local th = EFFECT_EDITOR.timeline_header

    imgui.TextUnformatted("Phase Timing (process_timeline_frame / opcode 41):")

    local c, v
    c, v = imgui.SliderInt("Phase 1 Duration##tlh", th.phase1_duration, 0, 500)
    if c then th.phase1_duration = v end
    imgui.SameLine()
    imgui.TextUnformatted("(frames Phase 1 runs)")

    c, v = imgui.SliderInt("Child Spawn Interval##tlh", th.spawn_delay, 0, 100)
    if c then th.spawn_delay = v end
    imgui.SameLine()
    imgui.TextUnformatted("(frames between each child)")

    c, v = imgui.SliderInt("Phase 2 Start Delay##tlh", th.phase2_delay, 0, 500)
    if c then th.phase2_delay = v end
    imgui.SameLine()
    imgui.TextUnformatted("(extra wait before Phase 2)")

    imgui.Separator()

    -- Calculate and show when Phase 2 starts
    local num_targets = EFFECT_EDITOR.emitter_count or 1  -- Approximation
    local phase2_start = th.phase1_duration + th.phase2_delay
    imgui.TextUnformatted(string.format("Phase 2 starts at frame: %d + (targets-1)*%d + %d",
        th.phase1_duration, th.spawn_delay, th.phase2_delay))
    imgui.TextUnformatted("  (Phase 1 runs frames 0 to " .. (th.phase1_duration - 1) .. ")")

    imgui.Separator()
    imgui.TextUnformatted(string.format("Raw: unknown_00=%d, unknown_02=%d, unknown_08=%d",
        th.unknown_00, th.unknown_02, th.unknown_08))
end

return M
