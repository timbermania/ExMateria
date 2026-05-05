-- ui/save_panel.lua
-- Save/Load header, identity fields, and save buttons

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local config = nil
local raw_save_fn = nil
local save_bin_edited_fn = nil
local save_state_only_fn = nil
local refresh_sessions_fn = nil
local session_list = nil
local copy_session_fn = nil

-- Local UI state for copy
local copy_to_name = ""

function M.set_dependencies(cfg, raw_save, save_bin, save_state, refresh_fn, session_list_module, copy_fn)
    config = cfg
    raw_save_fn = raw_save
    save_bin_edited_fn = save_bin
    save_state_only_fn = save_state
    refresh_sessions_fn = refresh_fn
    session_list = session_list_module
    copy_session_fn = copy_fn
end

--------------------------------------------------------------------------------
-- Save Panel Drawing
--------------------------------------------------------------------------------

function M.draw()
    -- Unified Save/Load Section
    if imgui.CollapsingHeader("Save/Load", 32) then  -- 32 = DefaultOpen
        M.draw_identity_fields()
        imgui.Separator()
        M.draw_computed_paths()
        imgui.Separator()
        M.draw_save_buttons()
        imgui.Separator()

        -- Draw session list (delegated to session_list module)
        if session_list then
            session_list.draw()
        end
    end
end

--------------------------------------------------------------------------------
-- Identity Fields Section
--------------------------------------------------------------------------------

function M.draw_identity_fields()
    -- Effect ID
    imgui.TextUnformatted("Effect ID:")
    imgui.SameLine()
    local changed_id, new_id = imgui.InputInt("##effect_id", EFFECT_EDITOR.effect_id)
    if changed_id then
        EFFECT_EDITOR.effect_id = math.max(0, math.min(999, new_id))
    end
    imgui.SameLine()
    imgui.TextUnformatted(string.format("(E%03d)", EFFECT_EDITOR.effect_id))

    -- Session Name
    imgui.TextUnformatted("Name:")
    imgui.SameLine()
    local changed_name, new_name = imgui.extra.InputText("##session_name", EFFECT_EDITOR.session_name or "capture")
    if changed_name then
        EFFECT_EDITOR.session_name = new_name
    end
end

--------------------------------------------------------------------------------
-- Computed Paths Section
--------------------------------------------------------------------------------

function M.draw_computed_paths()
    if not config then return end

    local short_ss_path = config.SAVESTATE_PATH:gsub(".*/pcsx%-effect%-editor/", ".../")
    local short_bin_path = config.EFFECT_BINS_PATH:gsub(".*/pcsx%-effect%-editor/", ".../")
    local short_meta_path = config.META_PATH:gsub(".*/pcsx%-effect%-editor/", ".../")
    local name = EFFECT_EDITOR.session_name or ""

    imgui.TextUnformatted("State: " .. short_ss_path .. name .. ".sstate")
    imgui.TextUnformatted("Bin:   " .. short_bin_path .. name .. ".bin")
    imgui.TextUnformatted("Meta:  " .. short_meta_path .. name .. ".json")
end

--------------------------------------------------------------------------------
-- Save Buttons Section
--------------------------------------------------------------------------------

function M.draw_save_buttons()
    local has_effect = EFFECT_EDITOR.effect_id > 0
    local has_name = EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""

    if has_name and has_effect then
        -- Raw Save - saves current state + bin (for NEW captures)
        if imgui.Button("Raw Save") then
            if raw_save_fn then raw_save_fn() end
        end
        imgui.SameLine()

        -- Save Bin - reload, apply edits, save bin only (for EDITING)
        if imgui.Button("Save Bin") then
            if save_bin_edited_fn then save_bin_edited_fn() end
        end
        imgui.SameLine()

        -- Save State - saves just savestate (to FIX broken states)
        if imgui.Button("Save State") then
            if save_state_only_fn then save_state_only_fn() end
        end
        imgui.SameLine()
    end

    if imgui.Button("Refresh") then
        if refresh_sessions_fn then refresh_sessions_fn() end
    end

    -- Copy session row
    if has_name and has_effect then
        imgui.TextUnformatted("Copy to:")
        imgui.SameLine()
        imgui.SetNextItemWidth(150)
        local changed, new_val = imgui.extra.InputText("##copy_to", copy_to_name)
        if changed then
            copy_to_name = new_val
        end
        imgui.SameLine()
        if imgui.Button("Copy") then
            if copy_session_fn and copy_to_name ~= "" then
                local src = EFFECT_EDITOR.session_name
                if copy_session_fn(src, copy_to_name) then
                    copy_to_name = ""  -- Clear after successful copy
                end
            end
        end
    end
end

return M
