-- commands/sound_debug.lua
-- Orchestrator for a single sound-debugging capture run.
--
-- Flow:
--   1. Timestamped output dir under {SAVESTATE_PATH}/sound_debug/{session}/
--   2. ee_load_session(name, no_autoplay=true)   — load savestate, stay paused
--   3. Arm sound_capture, note_capture, spu_voice_trace
--   4. ee_audio_mute()                           — mute music, preserve effect
--   5. PCSX.resumeEmulator()                     — let the effect play
--   6. UI tab calls tick() every frame; auto-stops when effect finishes
--      (no new triggers for AUTO_STOP_IDLE_FRAMES AND all voices silent)
--   7. stop()   — snapshot instrument table, stop captures, serialize JSONL

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (injected)
--------------------------------------------------------------------------------

local config = nil
local MemUtils = nil
local session_mod = nil         -- session.lua (for ee_load_session)
local sound_capture = nil
local note_capture = nil
local spu_voice_trace = nil
local instrument_snapshot = nil
local audio_record = nil

function M.set_dependencies(cfg, mem_utils, session_module, sc, nc, svt, is_mod, ar)
    config = cfg
    MemUtils = mem_utils
    session_mod = session_module
    sound_capture = sc
    note_capture = nc
    spu_voice_trace = svt
    instrument_snapshot = is_mod
    audio_record = ar
end

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

M.AUTO_STOP_IDLE_FRAMES = 60   -- game frames of silence after last trigger -> stop
M.MAX_RUN_FRAMES = 900         -- hard cap (~30s at 30fps)

--------------------------------------------------------------------------------
-- State (GLOBAL for GC safety)
--------------------------------------------------------------------------------

if not SOUND_DEBUG_RUN then
    SOUND_DEBUG_RUN = {
        running = false,
        session_name = "",
        output_dir = "",
        started_at = 0,
        last_trigger_count = 0,
        last_trigger_frame = 0,     -- game frame when last new trigger observed
        snapshot_taken = false,
        last_status = "idle",
    }
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function timestamp_str()
    -- os.date on Windows returns the format we want
    return os.date("%Y%m%d_%H%M%S")
end

local function ensure_dir(path)
    return config.ensure_dir(path)
end

-- Escape a Lua string for safe JSON embedding.
local function json_escape(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

-- Detect array-like Lua tables (contiguous integer keys 1..N).
local function is_array(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    for i = 1, n do
        if tbl[i] == nil then return false end
    end
    return n > 0
end

-- Minimal value-to-JSON. Handles nil/number/bool/string/table (flat).
local function j(v)
    local t = type(v)
    if v == nil then return "null"
    elseif t == "number" then
        -- Lua numbers may be floats or ints; %g keeps integers as ints.
        if v ~= v then return "null" end    -- NaN
        if v == math.huge or v == -math.huge then return "null" end
        if math.floor(v) == v and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%g", v)
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "string" then return '"' .. json_escape(v) .. '"'
    elseif t == "table" then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do
                parts[#parts + 1] = j(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. j(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return '"?"'
end

--------------------------------------------------------------------------------
-- Serialization
--------------------------------------------------------------------------------

local function write_jsonl(path, rows)
    local f = io.open(path, "w")
    if not f then
        print("[SoundDebug] can't open " .. path)
        return 0
    end
    for _, row in ipairs(rows) do
        f:write(j(row))
        f:write("\n")
    end
    f:close()
    return #rows
end

local function write_manifest(path, fields)
    local f = io.open(path, "w")
    if not f then
        print("[SoundDebug] can't open " .. path)
        return
    end
    f:write("{\n")
    local keys = {}
    for k, _ in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do
        f:write("  ")
        f:write('"' .. json_escape(k) .. '":')
        f:write(j(fields[k]))
        if i < #keys then f:write(",") end
        f:write("\n")
    end
    f:write("}\n")
    f:close()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.get_status()
    return SOUND_DEBUG_RUN.last_status
end

function M.is_running()
    return SOUND_DEBUG_RUN.running
end

function M.get_output_dir()
    return SOUND_DEBUG_RUN.output_dir
end

function M.ee_sound_debug_start(session_name)
    if SOUND_DEBUG_RUN.running then
        print("[SoundDebug] already running; call ee_sound_debug_stop() first")
        return false
    end

    session_name = session_name or EFFECT_EDITOR.session_name
    if not session_name or session_name == "" then
        print("[SoundDebug] no session_name — load a session first")
        SOUND_DEBUG_RUN.last_status = "no session"
        return false
    end

    -- Build output dir: {SAVESTATE_PATH}/sound_debug/{session}/{timestamp}/
    local root = config.DATA_PATH .. "sound_debug/"
    local session_root = root .. session_name .. "/"
    local run_dir = session_root .. timestamp_str() .. "/"
    ensure_dir(root)
    ensure_dir(session_root)
    ensure_dir(run_dir)

    SOUND_DEBUG_RUN.running = true
    SOUND_DEBUG_RUN.session_name = session_name
    SOUND_DEBUG_RUN.output_dir = run_dir
    SOUND_DEBUG_RUN.started_at = os.clock()
    SOUND_DEBUG_RUN.last_trigger_count = 0
    SOUND_DEBUG_RUN.last_trigger_frame = 0
    SOUND_DEBUG_RUN.snapshot_taken = false
    SOUND_DEBUG_RUN.last_status = "loading session"

    print("[SoundDebug] ==========================================")
    print("[SoundDebug] starting run for " .. session_name)
    print("[SoundDebug]   output: " .. run_dir)

    -- Load savestate paused (no_autoplay=true). This reloads the state
    -- synchronously but schedules its own nextTick for memory_base lookup
    -- and effect parse — we don't need to wait for those (we just need
    -- the game to be RESUMED so breakpoints can fire).
    session_mod.ee_load_session(session_name, true)

    -- Arm breakpoints synchronously. They hook fixed MIPS code addresses
    -- that are stable regardless of savestate contents, so it's safe to
    -- install them before the session's nextTick finishes.
    SOUND_DEBUG_RUN.last_status = "arming captures"
    sound_capture.start_capture()
    note_capture.start_capture()
    spu_voice_trace.start_capture()

    -- Defer music mute + resume by one nextTick so the savestate reload
    -- has settled. (mute_music patches game code in RAM — that RAM needs
    -- to be fully restored first.)
    PCSX.nextTick(function()
        if not SOUND_DEBUG_RUN.running then return end
        audio_record.mute_music()
        SOUND_DEBUG_RUN.last_status = "running"
        PCSX.resumeEmulator()
        print("[SoundDebug] emulator resumed; waiting for effect triggers")
    end)
    return true
end

-- Called from the UI tab each draw frame. Checks for auto-stop.
function M.tick()
    if not SOUND_DEBUG_RUN.running then return end

    local trig_count = sound_capture.get_count()
    local cur_frame = spu_voice_trace.get_last_frame()

    -- New trigger this tick? Remember the frame.
    if trig_count > SOUND_DEBUG_RUN.last_trigger_count then
        SOUND_DEBUG_RUN.last_trigger_count = trig_count
        SOUND_DEBUG_RUN.last_trigger_frame = cur_frame
    end

    -- Auto-stop criteria: we've seen at least one trigger AND enough idle
    -- frames have elapsed AND all SPU voices are now silent.
    if trig_count > 0 then
        local idle = cur_frame - SOUND_DEBUG_RUN.last_trigger_frame
        if idle >= M.AUTO_STOP_IDLE_FRAMES and spu_voice_trace.all_voices_silent() then
            print(string.format("[SoundDebug] auto-stop: %d frames idle, all voices silent", idle))
            M.ee_sound_debug_stop()
            return
        end
    end

    -- Hard cap on total runtime.
    if (os.clock() - SOUND_DEBUG_RUN.started_at) > 30.0 then
        print("[SoundDebug] hard-cap timeout at 30s")
        M.ee_sound_debug_stop()
    end
end

function M.ee_sound_debug_stop()
    if not SOUND_DEBUG_RUN.running then
        print("[SoundDebug] not running")
        return false
    end

    SOUND_DEBUG_RUN.last_status = "stopping"

    -- Snapshot instrument table while the effect-playing state is still live.
    local inst_ok, inst_addr, inst_count = false, 0, 0
    if instrument_snapshot then
        inst_ok, inst_addr, inst_count = instrument_snapshot.snapshot(SOUND_DEBUG_RUN.output_dir)
    end

    -- Stop all captures.
    sound_capture.stop_capture()
    note_capture.stop_capture()
    spu_voice_trace.stop_capture()

    -- Unmute music so user isn't stuck with a silent game after the capture.
    audio_record.unmute_music()

    -- Serialize captures.
    local run_dir = SOUND_DEBUG_RUN.output_dir
    local triggers = SOUND_CAPTURE and SOUND_CAPTURE.triggers or {}
    local notes = NOTE_CAPTURE and NOTE_CAPTURE.notes or {}
    local voice_events = spu_voice_trace.get_events()

    local n_triggers = write_jsonl(run_dir .. "sound_triggers.jsonl", triggers)
    local n_notes = write_jsonl(run_dir .. "note_events.jsonl", notes)
    local n_voice = write_jsonl(run_dir .. "spu_voice_events.jsonl", voice_events)

    -- Manifest.
    write_manifest(run_dir .. "manifest.json", {
        session = SOUND_DEBUG_RUN.session_name,
        effect_id = EFFECT_EDITOR.effect_id or 0,
        timestamp = timestamp_str(),
        last_frame = spu_voice_trace.get_last_frame(),
        trigger_count = n_triggers,
        note_count = n_notes,
        voice_event_count = n_voice,
        instrument_snapshot_ok = inst_ok,
        instrument_table_addr = string.format("0x%08X", inst_addr),
        instrument_entries = inst_count,
        files = {
            "manifest.json",
            "sound_triggers.jsonl",
            "note_events.jsonl",
            "spu_voice_events.jsonl",
            "instrument_table.bin",
            "waveset_regions.jsonl",
        },
    })

    SOUND_DEBUG_RUN.running = false
    SOUND_DEBUG_RUN.last_status = "done"
    print(string.format("[SoundDebug] done: %d triggers, %d notes, %d voice events -> %s",
        n_triggers, n_notes, n_voice, run_dir))
    return true
end

return M
