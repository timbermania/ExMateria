-- spu_voice_trace.lua
-- Per-frame SPU voice state trace during effect playback.
--
-- Hooks update_all_particles (0x801A2EB4) — the same frame-tick hook
-- sound_capture already uses. On each hit polls PCSX.SPU.getVoiceInfo(0..23),
-- diffs against the previous snapshot, emits change events per voice.
--
-- Pair this with sound_capture (per-trigger) + note_capture (per-SMD note)
-- and you have a complete picture of what the game does to the SPU during
-- an effect. Compare against smd-player's Sequencer.player_trace.jsonl to
-- find where synthesis diverges.

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (injected)
--------------------------------------------------------------------------------

local MemUtils = nil

function M.set_dependencies(mem_utils, cfg)
    MemUtils = mem_utils
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

M.UPDATE_PARTICLES_ADDR = 0x801A2EB4  -- $a0 = EffectState*, frame counter at +0x20
M.FRAME_COUNTER_OFFSET = 0x20
M.NUM_VOICES = 24

-- Fields we care about. Strings picked to match what getVoiceInfo returns.
-- Any field not present in a given PCSX-Redux build is silently skipped.
M.TRACKED_FIELDS = {
    "envelopeVol",
    "adsrState",
    "startAddr",
    "pitch",
    "attackRate", "attackExp",
    "decayRate",
    "sustainLevel", "sustainRate", "sustainExp", "sustainIncrease",
    "releaseRate", "releaseExp",
}

--------------------------------------------------------------------------------
-- State (GLOBAL to survive GC)
--------------------------------------------------------------------------------

if not SPU_VOICE_TRACE then
    SPU_VOICE_TRACE = {
        recording = false,
        events = {},                 -- {frame, voice, field, old, new}
        event_count = 0,
        last_frame = 0,
        prev = {},                   -- [voice] = {field = value, ...}
        -- Synthetic events:
        last_env_vol = {},           -- [voice] = number (to detect key_on/key_off)
    }
end

--------------------------------------------------------------------------------
-- Poll callback
--------------------------------------------------------------------------------

local function safe_get_voice_info(v)
    -- getVoiceInfo may return nil; guard against it.
    local ok, info = pcall(PCSX.SPU.getVoiceInfo, v)
    if ok then return info end
    return nil
end

local function on_frame_tick(addr, width, cause)
    if not SPU_VOICE_TRACE.recording then
        return true
    end

    -- Read current effect frame from EffectState at $a0 + 0x20
    local regs = PCSX.getRegisters()
    local es_ptr = regs.GPR.n.a0
    local frame = 0
    if MemUtils and es_ptr and es_ptr >= 0x80000000 then
        frame = MemUtils.read32(es_ptr + M.FRAME_COUNTER_OFFSET)
    end
    SPU_VOICE_TRACE.last_frame = frame

    for v = 0, M.NUM_VOICES - 1 do
        local info = safe_get_voice_info(v)
        if info then
            local prev = SPU_VOICE_TRACE.prev[v]
            if not prev then
                prev = {}
                SPU_VOICE_TRACE.prev[v] = prev
            end

            for _, field in ipairs(M.TRACKED_FIELDS) do
                local cur = info[field]
                if cur ~= nil then
                    local old = prev[field]
                    if old ~= cur then
                        SPU_VOICE_TRACE.event_count = SPU_VOICE_TRACE.event_count + 1
                        table.insert(SPU_VOICE_TRACE.events, {
                            frame = frame,
                            voice = v,
                            field = field,
                            old = old,
                            new = cur,
                        })
                        prev[field] = cur
                    end
                end
            end

            -- Synthetic key_on / key_off events on envelopeVol 0 <-> nonzero.
            local env = info.envelopeVol or 0
            local last_env = SPU_VOICE_TRACE.last_env_vol[v] or 0
            if last_env == 0 and env > 0 then
                SPU_VOICE_TRACE.event_count = SPU_VOICE_TRACE.event_count + 1
                table.insert(SPU_VOICE_TRACE.events, {
                    frame = frame,
                    voice = v,
                    field = "key_on",
                    old = 0,
                    new = env,
                    startAddr = info.startAddr,
                    pitch = info.pitch,
                })
            elseif last_env > 0 and env == 0 then
                SPU_VOICE_TRACE.event_count = SPU_VOICE_TRACE.event_count + 1
                table.insert(SPU_VOICE_TRACE.events, {
                    frame = frame,
                    voice = v,
                    field = "key_off",
                    old = last_env,
                    new = 0,
                })
            end
            SPU_VOICE_TRACE.last_env_vol[v] = env
        end
    end

    return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.start_capture()
    if SPU_VOICE_TRACE_BP then
        pcall(function() SPU_VOICE_TRACE_BP:disable() end)
        SPU_VOICE_TRACE_BP = nil
    end

    SPU_VOICE_TRACE.recording = true
    SPU_VOICE_TRACE.events = {}
    SPU_VOICE_TRACE.event_count = 0
    SPU_VOICE_TRACE.last_frame = 0
    SPU_VOICE_TRACE.prev = {}
    SPU_VOICE_TRACE.last_env_vol = {}

    SPU_VOICE_TRACE_BP = PCSX.addBreakpoint(
        M.UPDATE_PARTICLES_ADDR, 'Exec', 4, 'SPUVoiceTrace', on_frame_tick
    )
    print("[SPUVoiceTrace] Recording started")
end

function M.stop_capture()
    SPU_VOICE_TRACE.recording = false
    print(string.format("[SPUVoiceTrace] Stopped: %d events across %d voices (last frame %d)",
        SPU_VOICE_TRACE.event_count,
        M.NUM_VOICES,
        SPU_VOICE_TRACE.last_frame))
end

function M.is_capturing()
    return SPU_VOICE_TRACE.recording
end

function M.get_count()
    return SPU_VOICE_TRACE.event_count
end

function M.get_events()
    return SPU_VOICE_TRACE.events
end

function M.get_last_frame()
    return SPU_VOICE_TRACE.last_frame
end

-- Return true if no voice has a non-zero envelopeVol right now.
-- Used by the sound_debug orchestrator to detect "effect has finished".
function M.all_voices_silent()
    for v = 0, M.NUM_VOICES - 1 do
        local info = safe_get_voice_info(v)
        if info and (info.envelopeVol or 0) > 0 then
            return false
        end
    end
    return true
end

function M.cleanup()
    if SPU_VOICE_TRACE_BP then
        pcall(function() SPU_VOICE_TRACE_BP:disable() end)
        SPU_VOICE_TRACE_BP = nil
    end
    SPU_VOICE_TRACE.recording = false
end

function M.print_log(limit)
    limit = limit or 40
    local events = SPU_VOICE_TRACE.events
    local n = #events
    print(string.format("=== SPU Voice Trace: %d events (last frame %d) ===",
        n, SPU_VOICE_TRACE.last_frame))
    print(string.format("%-6s %-6s %-18s %-12s %-12s", "Frame", "Voice", "Field", "Old", "New"))
    print(string.rep("-", 56))
    local start_idx = math.max(1, n - limit + 1)
    for i = start_idx, n do
        local e = events[i]
        local extra = ""
        if e.field == "key_on" then
            extra = string.format(" startAddr=0x%X pitch=%s",
                e.startAddr or 0, tostring(e.pitch))
        end
        print(string.format("%-6d %-6d %-18s %-12s %-12s%s",
            e.frame, e.voice, e.field, tostring(e.old), tostring(e.new), extra))
    end
end

return M
