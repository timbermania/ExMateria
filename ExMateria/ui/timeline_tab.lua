-- ui/timeline_tab.lua
-- Timeline tab with particle channel editing UI

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local helpers = nil

function M.set_dependencies(helpers_module)
    helpers = helpers_module
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local MAX_KEYFRAMES = 25

-- Context display names
local CONTEXT_NAMES = {
    animate_tick = "Animate Tick",
    phase1 = "Process Timeline Phase 1",
    phase2 = "Process Timeline Phase 2",
}

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Build emitter dropdown items string based on current emitter count
-- Format: "None\0000\0001\0002\000..." (0-based display)
local function build_emitter_items()
    local items = "None\0"
    -- Use actual emitters array length, not cached emitter_count
    -- This ensures newly cloned emitters appear immediately in the dropdown
    local count = EFFECT_EDITOR.emitters and #EFFECT_EDITOR.emitters or 0
    for i = 0, count - 1 do
        items = items .. tostring(i) .. "\0"
    end
    return items
end

-- Convert memory emitter_id (1-based, 0=none) to UI index (0=none, 1=emitter0, 2=emitter1...)
local function emitter_id_to_ui(emitter_id)
    return emitter_id  -- Direct mapping: 0=None, 1=Emitter0, 2=Emitter1...
end

-- Convert UI index back to memory emitter_id
local function ui_to_emitter_id(ui_index)
    return ui_index  -- Direct mapping
end

-- Count active keyframes in a channel (keyframes with emitter_id > 0 up to max_keyframe)
local function count_active_keyframes(channel)
    local count = 0
    local limit = math.min(channel.max_keyframe + 1, MAX_KEYFRAMES)
    for i = 1, limit do
        if channel.keyframes[i] and channel.keyframes[i].emitter_id > 0 then
            count = count + 1
        end
    end
    return count
end

-- Calculate duration for a keyframe (difference between next time and this time)
-- This is how long the keyframe is active before advancing to the next one
local function get_keyframe_duration(channel, keyframe_index)
    local kf = channel.keyframes[keyframe_index]
    local next_kf = channel.keyframes[keyframe_index + 1]
    if kf and next_kf then
        return next_kf.time - kf.time
    elseif kf then
        return 0  -- Last keyframe has no duration
    end
    return 0
end

-- Calculate interarrival time (time since previous keyframe)
local function get_interarrival_time(channel, keyframe_index)
    local kf = channel.keyframes[keyframe_index]
    local prev_kf = channel.keyframes[keyframe_index - 1]
    if kf and prev_kf then
        return kf.time - prev_kf.time
    elseif kf then
        return kf.time  -- First keyframe: interarrival is just its time (from 0)
    end
    return 0
end

--------------------------------------------------------------------------------
-- Action Flags Decoding/Encoding
--------------------------------------------------------------------------------

-- Decode action_flags into components
local function decode_action_flags(flags)
    return {
        callback_slot = (flags % 8),  -- bits 0-2 (value 0-7, where 0 = direct spawn)
        use_global_target = (math.floor(flags / 8) % 2) == 1,      -- bit 3
        trigger_hit_reaction = (math.floor(flags / 16) % 2) == 1,  -- bit 4
        refresh_tile_state = (math.floor(flags / 32) % 2) == 1,    -- bit 5
        apply_ability_reaction = (math.floor(flags / 64) % 2) == 1, -- bit 6
        action_param = math.floor(flags / 256),  -- bits 8-15
    }
end

-- Encode components back into action_flags
local function encode_action_flags(decoded)
    local flags = decoded.callback_slot % 8
    if decoded.use_global_target then flags = flags + 8 end
    if decoded.trigger_hit_reaction then flags = flags + 16 end
    if decoded.refresh_tile_state then flags = flags + 32 end
    if decoded.apply_ability_reaction then flags = flags + 64 end
    flags = flags + (decoded.action_param % 256) * 256
    return flags
end

--------------------------------------------------------------------------------
-- Single Keyframe Drawing
--------------------------------------------------------------------------------

local function draw_keyframe(channel, kf_index, uid)
    local kf = channel.keyframes[kf_index]
    if not kf then return end

    local c, v
    local emitter_items = build_emitter_items()
    local duration = get_keyframe_duration(channel, kf_index)
    local interarrival = get_interarrival_time(channel, kf_index)

    -- kf_index 1 (displayed as [0]) is never used by the game - it pre-increments before reading
    local is_unused_kf0 = (kf_index == 1)

    -- Compact single-line layout for each keyframe
    if is_unused_kf0 then
        imgui.TextUnformatted("[ 0] (unused)")
        return  -- Don't show controls for unused keyframe
    end

    imgui.TextUnformatted(string.format("[%2d]", kf_index - 1))  -- 0-based display
    imgui.SameLine()

    -- Absolute frame (use DragInt - no +/- buttons, just click-drag or ctrl+click to type)
    imgui.SetNextItemWidth(50)
    c, v = imgui.DragInt("##frame" .. uid, kf.time, 1, 0, 9999)
    if c then kf.time = v end
    imgui.SameLine()
    -- Show derived times: delta from previous, duration until next
    -- "+N" = frames since previous keyframe, "dur:N" = frames until next keyframe
    imgui.TextUnformatted(string.format("(+%d dur:%d)", interarrival, duration))
    imgui.SameLine()

    -- Emitter dropdown (0-based display)
    imgui.SetNextItemWidth(60)
    local ui_emitter = emitter_id_to_ui(kf.emitter_id)
    c, v = imgui.Combo("##emit" .. uid, ui_emitter, emitter_items)
    if c then kf.emitter_id = ui_to_emitter_id(v) end
    imgui.SameLine()

    -- Show action flags indicator if non-zero
    if kf.action_flags ~= 0 then
        imgui.TextUnformatted(string.format("[0x%04X]", kf.action_flags))
        imgui.SameLine()
    end

    -- Action flags - stable TreeNode ID (hex shown inside to avoid label changes closing it)
    if imgui.TreeNode("Action Flags##af" .. uid) then
        local decoded = decode_action_flags(kf.action_flags)

        -- Show raw hex value
        imgui.TextUnformatted(string.format("Raw: 0x%04X", kf.action_flags))

        -- Callback slot dropdown
        local CALLBACK_ITEMS = "Direct\0Slot 0\0Slot 1\0Slot 2\0Slot 3\0Slot 4\0Slot 5\0Slot 6\0"
        imgui.SetNextItemWidth(80)
        c, v = imgui.Combo("Callback##cb" .. uid, decoded.callback_slot, CALLBACK_ITEMS)
        if c then
            decoded.callback_slot = v
            kf.action_flags = encode_action_flags(decoded)
        end

        -- Trigger flags (mutually exclusive)
        -- Bit 3 = Global Target, Bit 4 = Hit Reaction, Bit 5 = Refresh Tile, Bit 6 = Ability React
        local TRIGGER_ITEMS = "None\0Global Target\0Hit Reaction\0Refresh Tile\0Ability React\0"
        local current_trigger = 0
        if decoded.use_global_target then current_trigger = 1
        elseif decoded.trigger_hit_reaction then current_trigger = 2
        elseif decoded.refresh_tile_state then current_trigger = 3
        elseif decoded.apply_ability_reaction then current_trigger = 4
        end

        imgui.SetNextItemWidth(100)
        c, v = imgui.Combo("Trigger##trig" .. uid, current_trigger, TRIGGER_ITEMS)
        if c then
            decoded.use_global_target = (v == 1)
            decoded.trigger_hit_reaction = (v == 2)
            decoded.refresh_tile_state = (v == 3)
            decoded.apply_ability_reaction = (v == 4)
            kf.action_flags = encode_action_flags(decoded)
        end

        -- Unit animation param (triggers unit_animations_by_param when non-zero)
        imgui.SetNextItemWidth(60)
        c, v = imgui.InputInt("Unit Anim##ua" .. uid, decoded.action_param)
        if c then
            decoded.action_param = math.max(0, math.min(255, v))
            kf.action_flags = encode_action_flags(decoded)
        end

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Single Channel Drawing
--------------------------------------------------------------------------------

local function draw_channel(channel, channel_list_index)
    local active_count = count_active_keyframes(channel)
    -- max_keyframe is INCLUSIVE: value of 2 means keyframes 0,1,2 are valid (3 total)
    local keyframe_count = channel.max_keyframe + 1
    local label = string.format("Channel %d (%d active, %d keyframes)###ch%d_%s",
        channel.channel_index,
        active_count,
        keyframe_count,
        channel.channel_index,
        channel.context)

    if imgui.CollapsingHeader(label) then
        imgui.Indent()

        -- Max keyframe control (INCLUSIVE - keyframes 0..max are valid)
        local c, v
        if channel.context == "animate_tick" then
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("Show Keyframes##mk" .. channel_list_index, channel.max_keyframe, 0, MAX_KEYFRAMES - 1)
            if c then channel.max_keyframe = v end
            imgui.SameLine()
            imgui.TextUnformatted("(display only - game ignores this)")
        else
            imgui.TextUnformatted("Keyframes 0.." .. channel.max_keyframe .. " are active")
            imgui.SetNextItemWidth(80)
            c, v = imgui.SliderInt("Last Keyframe##mk" .. channel_list_index, channel.max_keyframe, 0, MAX_KEYFRAMES - 1)
            if c then channel.max_keyframe = v end
        end

        imgui.Separator()

        -- Draw keyframes up to max_keyframe + 1
        local limit = math.min(channel.max_keyframe + 2, MAX_KEYFRAMES)  -- +2 to show one beyond max
        for i = 1, limit do
            local uid = string.format("%d_%s_%d", channel.channel_index, channel.context, i)
            draw_keyframe(channel, i, uid)
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Channel Group Drawing (by context)
--------------------------------------------------------------------------------

local function draw_channel_group(context, channels)
    local display_name = CONTEXT_NAMES[context] or context

    if imgui.CollapsingHeader(display_name .. "###" .. context) then
        imgui.Indent()

        for _, channel in ipairs(channels) do
            if channel.context == context then
                draw_channel(channel, _)
            end
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.timeline_channels then
        imgui.TextUnformatted("No timeline data loaded")
        return
    end

    -- Particle channels legend
    if imgui.CollapsingHeader("Particle Channels Help") then
        imgui.Indent()
        imgui.TextUnformatted("Format: [idx] Frame (+delta dur:N) Emitter [Flags]")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("  Frame  = Absolute frame number (cumulative)")
        imgui.TextUnformatted("  +delta = Frames since previous keyframe")
        imgui.TextUnformatted("  dur:N  = Duration until next keyframe")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("Drag frame values or Ctrl+click to type directly.")
        imgui.TextUnformatted("Frame values must be ascending (each >= previous).")
        imgui.TextUnformatted("")
        imgui.Separator()
        imgui.TextUnformatted("Max Keyframe Behavior:")
        imgui.TextUnformatted("  Animate Tick: max_keyframe is IGNORED by opcode 40.")
        imgui.TextUnformatted("    Keyframes advance based on time markers only.")
        imgui.TextUnformatted("  Phase 1/2: max_keyframe IS used by opcode 41.")
        imgui.TextUnformatted("    Value N means keyframes 0..N are valid.")
        imgui.Unindent()
    end

    imgui.Separator()

    -- Group channels by context
    -- Channels 1-5: animate_tick
    -- Channels 6-10: phase1
    -- Channels 11-15: phase2
    draw_channel_group("animate_tick", EFFECT_EDITOR.timeline_channels)
    draw_channel_group("phase1", EFFECT_EDITOR.timeline_channels)
    draw_channel_group("phase2", EFFECT_EDITOR.timeline_channels)
end

return M
