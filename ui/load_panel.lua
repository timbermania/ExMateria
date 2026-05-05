-- ui/load_panel.lua
-- Capture from Game section

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local arm_capture_fn = nil
local disarm_capture_fn = nil

function M.set_dependencies(load_fn, arm_fn, disarm_fn)
    -- load_fn kept for API compatibility but unused
    arm_capture_fn = arm_fn
    disarm_capture_fn = disarm_fn
end

--------------------------------------------------------------------------------
-- Draw Capture Panel
--------------------------------------------------------------------------------

function M.draw()
    -- ImGuiTreeNodeFlags_DefaultOpen = 32
    if imgui.CollapsingHeader("Capture from Game", 32) then
        if EFFECT_EDITOR.capture_armed then
            imgui.TextUnformatted("Status: ARMED - waiting for spell cast...")

            if imgui.Button("Disarm Capture") then
                if disarm_capture_fn then
                    disarm_capture_fn()
                end
            end
        else
            imgui.TextUnformatted("Arm capture, then cast a spell in-game.")
            imgui.TextUnformatted("Emulator pauses when effect loads to memory.")

            if imgui.Button("Arm Capture") then
                if arm_capture_fn then
                    arm_capture_fn()
                end
            end
        end

        -- Show last captured info
        if EFFECT_EDITOR.last_captured_effect_id >= 0 then
            imgui.Separator()
            imgui.TextUnformatted(string.format("Last captured: E%03d @ 0x%08X",
                EFFECT_EDITOR.last_captured_effect_id, EFFECT_EDITOR.memory_base))
        end

        imgui.Separator()
        imgui.TextUnformatted(EFFECT_EDITOR.status_msg)
    end
end

return M
