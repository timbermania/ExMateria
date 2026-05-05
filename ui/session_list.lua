-- ui/session_list.lua
-- Session list with delete buttons

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local load_session_fn = nil
local delete_session_fn = nil
local refresh_sessions_fn = nil

function M.set_dependencies(load_fn, delete_fn, refresh_fn)
    load_session_fn = load_fn
    delete_session_fn = delete_fn
    refresh_sessions_fn = refresh_fn
end

--------------------------------------------------------------------------------
-- Lazy Loading State
--------------------------------------------------------------------------------

local has_done_initial_refresh = false

--------------------------------------------------------------------------------
-- Session List Drawing
--------------------------------------------------------------------------------

function M.draw()
    -- Lazy load: refresh session list on first draw (avoids startup console window)
    if not has_done_initial_refresh then
        has_done_initial_refresh = true
        if refresh_sessions_fn then
            refresh_sessions_fn()
        end
    end

    local session_count = #EFFECT_EDITOR.session_files

    imgui.TextUnformatted(string.format("Saved Sessions (%d)", session_count))
    imgui.Separator()

    for _, sname in ipairs(EFFECT_EDITOR.session_files) do
        local is_current = (sname == EFFECT_EDITOR.session_name)
        local label = is_current and ("> " .. sname) or ("  " .. sname)

        -- Delete button FIRST (before Selectable so it gets click priority)
        if is_current then
            imgui.PushStyleColor(0, 0xFF4444FF)  -- Red text (ABGR)
            if imgui.SmallButton("X##del_" .. sname) then
                if delete_session_fn then
                    delete_session_fn(sname)
                end
            end
            imgui.PopStyleColor()
            imgui.SameLine()
        end

        -- Session name (click to load)
        -- Flag 16 = ImGuiSelectableFlags_AllowItemOverlap (lets button receive clicks)
        if imgui.Selectable(label .. "##session_" .. sname, is_current, 16) then
            if load_session_fn then
                load_session_fn(sname)
            end
        end
    end

    if session_count == 0 then
        imgui.TextUnformatted("(no saved sessions)")
    end
end

return M
