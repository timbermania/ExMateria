-- ui/main_window.lua
-- Main window orchestration with auto-loop and tabs

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local load_panel = nil
local save_panel = nil
local structure_tab = nil
local particles_tab = nil
local curves_tab = nil
local header_tab = nil
local timeline_tab = nil
local camera_tab = nil
local color_tracks_tab = nil
local time_scale_tab = nil
local sound_tab = nil
local settings_tab = nil
local test_cycle_fn = nil
local save_bin_fn = nil
local reload_fn = nil

function M.set_dependencies(load_p, save_p, struct_tab, particles_t, curves_t, header_t, timeline_t, camera_t, color_t, time_scale_t, sound_t, settings_t, test_fn, save_bin, reload)
    load_panel = load_p
    save_panel = save_p
    structure_tab = struct_tab
    particles_tab = particles_t
    curves_tab = curves_t
    header_tab = header_t
    timeline_tab = timeline_t
    camera_tab = camera_t
    color_tracks_tab = color_t
    time_scale_tab = time_scale_t
    sound_tab = sound_t
    settings_tab = settings_t
    test_cycle_fn = test_fn
    save_bin_fn = save_bin
    reload_fn = reload
end

--------------------------------------------------------------------------------
-- Auto-Loop Timer Logic
--------------------------------------------------------------------------------

local function update_auto_loop()
    if not EFFECT_EDITOR.auto_loop_enabled then return end

    local current_time = os.clock()
    local delta = current_time - EFFECT_EDITOR.auto_loop_last_time
    EFFECT_EDITOR.auto_loop_last_time = current_time

    -- Decrement timer
    EFFECT_EDITOR.auto_loop_timer = EFFECT_EDITOR.auto_loop_timer - delta

    -- Check if timer expired
    if EFFECT_EDITOR.auto_loop_timer <= 0 then
        -- Reset timer
        EFFECT_EDITOR.auto_loop_timer = EFFECT_EDITOR.auto_loop_seconds
        -- Trigger test cycle
        if test_cycle_fn then
            test_cycle_fn()
        end
    end
end

--------------------------------------------------------------------------------
-- Top Control Bar Drawing
--------------------------------------------------------------------------------

local function draw_top_control_bar()
    local has_session_name = EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""
    local has_memory_target = EFFECT_EDITOR.memory_base >= 0x80000000

    -- Get window width for right-alignment
    local window_width = imgui.GetWindowWidth()

    -- Left side: Test Effect button + Quiet/Verbose checkboxes
    if has_session_name and has_memory_target then
        if imgui.Button("Test Effect", 100, 28) then
            if test_cycle_fn then test_cycle_fn() end
            EFFECT_EDITOR.auto_loop_timer = EFFECT_EDITOR.auto_loop_seconds
            EFFECT_EDITOR.auto_loop_last_time = os.clock()
        end
        imgui.SameLine()
        local c, v = imgui.Checkbox("Quiet", EFFECT_EDITOR.test_quiet)
        if c then EFFECT_EDITOR.test_quiet = v end
        imgui.SameLine()
        c, v = imgui.Checkbox("Verbose", EFFECT_EDITOR.test_verbose)
        if c then EFFECT_EDITOR.test_verbose = v end
    else
        -- Show placeholder text when not ready
        imgui.TextUnformatted("(Load effect first)")
    end

    -- Middle: Effect info
    imgui.SameLine()
    local effect_info = ""
    if has_session_name then
        effect_info = EFFECT_EDITOR.session_name
        if EFFECT_EDITOR.effect_id and EFFECT_EDITOR.effect_id > 0 then
            effect_info = string.format("E%03d: %s", EFFECT_EDITOR.effect_id, EFFECT_EDITOR.session_name)
        end
    elseif has_memory_target then
        effect_info = "(unsaved effect)"
    else
        effect_info = "(no effect loaded)"
    end
    -- Center the text roughly
    local text_width = #effect_info * 7  -- approximate
    local center_x = (window_width - text_width) / 2
    local cursor_x = imgui.GetCursorPosX()
    if center_x > cursor_x then
        imgui.SetCursorPosX(center_x)
    end
    imgui.TextUnformatted(effect_info)

    -- Right side: Save Bin and Reload buttons
    imgui.SameLine()
    imgui.SetCursorPosX(window_width - 190)  -- Right-align

    if has_session_name then
        if imgui.Button("Save Bin", 85, 28) then
            if save_bin_fn then save_bin_fn() end
        end
        imgui.SameLine()
        if imgui.Button("Reload", 85, 28) then
            if reload_fn then reload_fn(EFFECT_EDITOR.session_name) end
        end
    else
        -- Show placeholder when no session loaded
        imgui.TextUnformatted("(no session)")
    end

    -- Second row: Auto-loop controls
    if has_session_name and has_memory_target then
        local c, v
        c, v = imgui.Checkbox("Auto Loop", EFFECT_EDITOR.auto_loop_enabled)
        if c then
            EFFECT_EDITOR.auto_loop_enabled = v
            if v then
                EFFECT_EDITOR.auto_loop_timer = EFFECT_EDITOR.auto_loop_seconds
                EFFECT_EDITOR.auto_loop_last_time = os.clock()
            end
        end
        imgui.SameLine()
        imgui.SetNextItemWidth(100)
        c, v = imgui.SliderFloat("##loop_secs", EFFECT_EDITOR.auto_loop_seconds, 0.5, 10.0, "%.1f sec")
        if c then
            EFFECT_EDITOR.auto_loop_seconds = v
            if EFFECT_EDITOR.auto_loop_enabled then
                EFFECT_EDITOR.auto_loop_timer = math.min(EFFECT_EDITOR.auto_loop_timer, v)
            end
        end
        if EFFECT_EDITOR.auto_loop_enabled then
            imgui.SameLine()
            imgui.TextUnformatted(string.format("(%.1fs)", EFFECT_EDITOR.auto_loop_timer))
        end
    end
end

--------------------------------------------------------------------------------
-- Editor Tabs Drawing
--------------------------------------------------------------------------------

local function draw_editor_tabs()
    local has_effect_data = EFFECT_EDITOR.header ~= nil

    -- If no effect loaded, just show message
    if not has_effect_data then
        imgui.TextUnformatted("No effect loaded. Arm capture and cast a spell.")
        return
    end

    if imgui.BeginTabBar("EditorTabs") then

        -- Header/Structure tab
        if imgui.BeginTabItem("Structure") then
            if structure_tab then structure_tab.draw() end
            imgui.EndTabItem()
        end

        -- Particle System tab
        if imgui.BeginTabItem("Particles") then
            if particles_tab then particles_tab.draw() end
            imgui.EndTabItem()
        end

        -- Animation Curves tab
        if imgui.BeginTabItem("Curves") then
            if curves_tab then curves_tab.draw() end
            imgui.EndTabItem()
        end

        -- Timeline Header tab
        if imgui.BeginTabItem("Timeline Header") then
            if header_tab then header_tab.draw() end
            imgui.EndTabItem()
        end

        -- Particle Timeline tab
        if imgui.BeginTabItem("Particle Timeline") then
            if timeline_tab then timeline_tab.draw() end
            imgui.EndTabItem()
        end

        -- Camera Timeline tab
        if imgui.BeginTabItem("Camera Timeline") then
            if camera_tab then camera_tab.draw() end
            imgui.EndTabItem()
        end

        -- Color Tracks tab
        if imgui.BeginTabItem("Color Tracks") then
            if color_tracks_tab then color_tracks_tab.draw() end
            imgui.EndTabItem()
        end

        -- Time Scale tab
        if imgui.BeginTabItem("Time Scale") then
            if time_scale_tab then time_scale_tab.draw() end
            imgui.EndTabItem()
        end

        -- Sound Definitions tab
        if imgui.BeginTabItem("Sound Defs") then
            if sound_tab then sound_tab.draw() end
            imgui.EndTabItem()
        end

        -- Script tab (placeholder)
        if imgui.BeginTabItem("Script") then
            imgui.TextUnformatted("Script Bytecode Editor")
            imgui.TextUnformatted("(Coming in Phase 7)")
            imgui.EndTabItem()
        end

        imgui.EndTabBar()
    end
end

--------------------------------------------------------------------------------
-- Safe Draw (Main Window)
--------------------------------------------------------------------------------

local function safe_draw()
    if not EFFECT_EDITOR.window_open then return end

    -- Update auto-loop timer (runs every frame)
    update_auto_loop()

    -- ImGuiCond_FirstUseEver = 4 (raw value)
    imgui.SetNextWindowSize(900, 600, 4)

    -- Begin returns: visible, open (open=false if X clicked)
    local visible, open = imgui.Begin("FFT Effect Editor", true)

    -- Handle X button close
    if open == false then
        EFFECT_EDITOR.window_open = false
    end

    if visible then
        draw_top_control_bar()
        imgui.Separator()

        -- Begin scrollable child region (everything below top bar scrolls)
        -- Parameters: id, width (0=auto), height (0=fill remaining), border, flags
        imgui.BeginChild("##ScrollRegion", 0, 0, false, 0)

        -- Settings section (collapsible, above capture)
        if settings_tab then
            settings_tab.draw()
        end

        -- Capture panel
        if load_panel then
            load_panel.draw()
        end

        -- Save/Load panel (includes session list)
        imgui.Separator()
        if save_panel then
            save_panel.draw()
        end

        imgui.Separator()

        -- Editor tabs
        draw_editor_tabs()

        imgui.EndChild()  -- End scrollable region
    end

    imgui.End()
end

--------------------------------------------------------------------------------
-- Public Draw Entry Point
--------------------------------------------------------------------------------

function M.draw()
    -- Draw main editor window with error catching
    local success, err = pcall(safe_draw)
    if not success then
        EFFECT_EDITOR_LAST_ERROR = err
        print("")
        print("!!! EFFECT EDITOR ERROR !!!")
        print(tostring(err))
        print("Run ee_error() to see again")
        print("")
    end
end

return M
