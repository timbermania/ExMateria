-- ui/sound_debug_tab.lua
-- One-button "Record Sound Debug" tab. Orchestrator ticks on each draw frame.

local M = {}

local sound_debug = nil
local sound_capture = nil
local note_capture = nil
local spu_voice_trace = nil

function M.set_dependencies(sd, sc, nc, svt)
    sound_debug = sd
    sound_capture = sc
    note_capture = nc
    spu_voice_trace = svt
end

-- Map field name to a short human label for the UI.
local FIELD_LABEL = {
    envelopeVol = "env",
    adsrState = "state",
    startAddr = "start",
    pitch = "pitch",
    attackRate = "ar",
    decayRate = "dr",
    sustainLevel = "sl",
    sustainRate = "sr",
    releaseRate = "rr",
    key_on = "KEY_ON",
    key_off = "KEY_OFF",
}

local function label_for(field)
    return FIELD_LABEL[field] or field
end

function M.draw()
    -- Tick the orchestrator every draw frame while a run is active.
    if sound_debug and sound_debug.is_running() then
        sound_debug.tick()
    end

    imgui.TextUnformatted("Sound Debug — full-capture for a single effect playback.")
    imgui.TextUnformatted("Load a session first (Sessions panel), then click Record.")
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    local session = EFFECT_EDITOR and EFFECT_EDITOR.session_name or ""
    local has_session = session ~= nil and session ~= ""

    if has_session then
        imgui.TextUnformatted("Session: " .. session)
    else
        imgui.TextUnformatted("Session: <none selected>")
    end

    local running = sound_debug and sound_debug.is_running() or false

    if running then
        if imgui.Button("Stop", 140, 0) then
            sound_debug.ee_sound_debug_stop()
        end
        imgui.SameLine()
        imgui.TextUnformatted("RECORDING — " .. (sound_debug.get_status() or "running"))
    else
        if not has_session then
            -- Can't start without a session. Show a disabled-looking button by
            -- just displaying a dim label instead — ImGui BeginDisabled is not
            -- universally available in this binding.
            imgui.TextUnformatted("(Load a session to enable Record)")
        else
            if imgui.Button("Record Sound Debug", 180, 0) then
                sound_debug.ee_sound_debug_start(session)
            end
            imgui.SameLine()
            imgui.TextUnformatted("Status: " .. (sound_debug.get_status() or "idle"))
        end
    end

    imgui.Spacing()

    -- Live counters.
    local trig_count = sound_capture and sound_capture.get_count() or 0
    local note_count = note_capture and note_capture.get_count() or 0
    local voice_count = spu_voice_trace and spu_voice_trace.get_count() or 0
    local last_frame = spu_voice_trace and spu_voice_trace.get_last_frame() or 0

    imgui.TextUnformatted(string.format(
        "Counters: triggers=%d  notes=%d  voice_events=%d  frame=%d",
        trig_count, note_count, voice_count, last_frame))

    imgui.Spacing()
    local out_dir = sound_debug and sound_debug.get_output_dir() or ""
    if out_dir ~= "" then
        imgui.TextUnformatted("Output dir:")
        imgui.TextUnformatted("  " .. out_dir)
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Recent triggers (last 20).
    imgui.TextUnformatted("Recent sound triggers:")
    imgui.BeginChild("##triggers", 0, 140, true, 0)
    if SOUND_CAPTURE and SOUND_CAPTURE.triggers then
        local trigs = SOUND_CAPTURE.triggers
        local start_i = math.max(1, #trigs - 20 + 1)
        for i = start_i, #trigs do
            local t = trigs[i]
            imgui.TextUnformatted(string.format(
                "#%-3d frame=%-5d tl_ch=%-2d config=%-2d res=%-4d fch=[%d,%d]",
                t.seq or i,
                t.frame or 0,
                t.timeline_channel or -1,
                t.config_value or 0,
                t.resource_id or 0,
                t.file_channels and t.file_channels[1] or 0,
                t.file_channels and t.file_channels[2] or 0))
        end
    else
        imgui.TextUnformatted("(no triggers yet)")
    end
    imgui.EndChild()

    imgui.Spacing()

    -- Recent voice events (last 20).
    imgui.TextUnformatted("Recent SPU voice events:")
    imgui.BeginChild("##voice_events", 0, 180, true, 0)
    if SPU_VOICE_TRACE and SPU_VOICE_TRACE.events then
        local events = SPU_VOICE_TRACE.events
        local start_i = math.max(1, #events - 20 + 1)
        for i = start_i, #events do
            local e = events[i]
            local extra = ""
            if e.field == "key_on" then
                extra = string.format(" start=0x%X pitch=%s",
                    e.startAddr or 0, tostring(e.pitch))
            end
            imgui.TextUnformatted(string.format(
                "f=%-5d v=%-2d %-8s  %s -> %s%s",
                e.frame or 0,
                e.voice or 0,
                label_for(e.field),
                tostring(e.old),
                tostring(e.new),
                extra))
        end
    else
        imgui.TextUnformatted("(no voice events yet)")
    end
    imgui.EndChild()
end

return M
