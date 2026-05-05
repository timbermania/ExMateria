-- commands/workflow.lua
-- Quick test cycle and apply commands

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local config = nil
local logging = nil
local MemUtils = nil
local apply_all_edits_fn = nil
local ee_reload_fn = nil
local texture_ops = nil
local audio_record = nil
local parser = nil

function M.set_dependencies(cfg, log_module, mem_utils, apply_all_edits, reload_fn, tex_ops, audio_rec, parser_module)
    config = cfg
    logging = log_module
    MemUtils = mem_utils
    apply_all_edits_fn = apply_all_edits
    ee_reload_fn = reload_fn
    texture_ops = tex_ops
    audio_record = audio_rec
    parser = parser_module
end

--------------------------------------------------------------------------------
-- ee_test: Quick test cycle - reload savestate, apply changes, resume
--------------------------------------------------------------------------------

function M.ee_test()
    -- Check quiet mode - only log if not quiet
    local quiet = EFFECT_EDITOR.test_quiet

    if not quiet then
        logging.log("========================================")
        logging.log("=== EE_TEST (TEST CYCLE) ===")
        logging.log("========================================")
    end

    -- Check prerequisites - need a selected session name
    local has_session_name = EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""
    if not quiet then
        logging.log(string.format("  session_name: '%s'", EFFECT_EDITOR.session_name or "nil"))
        logging.log(string.format("  memory_base: 0x%08X", EFFECT_EDITOR.memory_base or 0))
        logging.log(string.format("  effect_id: %d", EFFECT_EDITOR.effect_id or 0))
    end

    if not has_session_name then
        logging.log_error("No session selected! Click a session in the list first.")
        return false
    end

    if EFFECT_EDITOR.memory_base < 0x80000000 then
        logging.log_error("No memory target! Capture an effect first.")
        return false
    end

    -- Check savestate file exists before trying to reload
    local ss_path = config.SAVESTATE_PATH .. EFFECT_EDITOR.session_name .. ".sstate"
    local ss_win_path = ss_path:gsub("/", "\\")
    local ss_file = io.open(ss_win_path, "rb")
    if ss_file then
        local ss_size = ss_file:seek("end")
        ss_file:close()
        if not quiet then
            logging.log(string.format("  Savestate file: %d bytes", ss_size or 0))
        end
    else
        logging.log_error(string.format("  Savestate file NOT FOUND: %s", ss_win_path))
        return false
    end

    -- Step 1: Reload savestate (this also pauses)
    if not quiet then logging.log("Step 1: Reloading savestate...") end
    if not ee_reload_fn(nil, quiet) then
        logging.log_error("Failed to reload savestate")
        return false
    end
    if not quiet then logging.log("Step 1 complete: ee_reload returned true") end

    -- Step 2: Apply all edits to memory
    -- Need to wait a tick for savestate to fully load before writing
    if not quiet then logging.log("Scheduling Step 2 on nextTick...") end
    PCSX.nextTick(function()
        if not quiet then logging.log("Step 2: Applying all edits to memory...") end

        -- Verify effect is in memory after reload
        MemUtils.refresh_mem()
        local lookup_base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + EFFECT_EDITOR.effect_id * 4)
        if not quiet then
            logging.log(string.format("  Post-reload lookup_table[%d]: 0x%08X", EFFECT_EDITOR.effect_id, lookup_base or 0))
        end

        -- Apply structure changes FIRST (this may shift memory addresses)
        if apply_all_edits_fn then
            apply_all_edits_fn(true)  -- silent mode - we'll resume ourselves
        end

        -- Check for modified texture BMP and reload if needed
        -- IMPORTANT: Must happen AFTER structure changes, otherwise memory shift overwrites texture!
        if not quiet then logging.log("  Checking for texture changes...") end
        if texture_ops then
            local reloaded = texture_ops.maybe_reload_texture_before_test()
            if reloaded and not quiet then
                logging.log("  Reloaded modified texture from BMP")
            end
        else
            if not quiet then logging.log("  texture_ops module not available") end
        end

        if not quiet then logging.log("Step 2 complete: all edits applied") end

        -- Mute background music (must be AFTER savestate load)
        -- Savestate restores game state, so we install mute hook here
        -- Uses MIPS hook to mute music while preserving effect sounds
        if audio_record then
            audio_record.mute_music()
            if not quiet then logging.log("  Music mute hook installed (effects preserved)") end
        end

        -- Step 3: Resume emulator
        if not quiet then logging.log("Step 3: Resuming emulator...") end
        PCSX.resumeEmulator()

        if not quiet then
            logging.log("========================================")
            logging.log("=== TEST CYCLE COMPLETE ===")
            logging.log("========================================")
        end
        EFFECT_EDITOR.status_msg = "Test cycle complete!"
    end)

    return true
end

--------------------------------------------------------------------------------
-- ee_apply: Apply all edits to memory (emitters + curves)
--------------------------------------------------------------------------------

function M.ee_apply()
    if apply_all_edits_fn then
        apply_all_edits_fn()
    end
end

--------------------------------------------------------------------------------
-- Audio Capture (for bridge-based recording)
-- Two-call pattern: ee_capture_audio_start() then ee_capture_audio_read()
--------------------------------------------------------------------------------

-- Timeline frame counter address (written each frame during effect)
local TIMELINE_FRAME_ADDR = 0x801BF14C

-- Memory addresses for phase boundary calculation (from trace_phases_v2.lua)
local G_TIMELINE_PTR = 0x801bc0c8
local G_EFFECT_CONTEXT = 0x801bad0c

-- Try to get precise system time via LuaJIT FFI (Windows)
local ffi_available, ffi = pcall(require, "ffi")
local get_precise_time = nil

if ffi_available then
    -- Define Windows FILETIME structure and GetSystemTimeAsFileTime
    pcall(function()
        ffi.cdef[[
            typedef struct { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } FILETIME;
            void GetSystemTimeAsFileTime(FILETIME* lpSystemTimeAsFileTime);
        ]]
        get_precise_time = function()
            local ft = ffi.new("FILETIME")
            ffi.C.GetSystemTimeAsFileTime(ft)
            -- Convert FILETIME (100-nanosecond intervals since 1601) to Unix epoch
            local ticks = ft.dwLowDateTime + ft.dwHighDateTime * 4294967296ULL
            return tonumber((ticks - 116444736000000000ULL) / 10000000ULL) +
                   tonumber((ticks - 116444736000000000ULL) % 10000000ULL) / 10000000
        end
        print("[AudioCapture] Using FFI for precise Windows time")
    end)
end

-- SPU registers for audio marker (fallback sync method)
local SPU_MAIN_VOL_L = 0x1F801D80
local SPU_MAIN_VOL_R = 0x1F801D82

-- Play a sync click by briefly muting SPU (creates audible marker)
local function play_sync_click()
    -- Write to SPU registers via hardware memory region
    -- SPU is at 0x1F801C00-0x1F801FFF, need to use PCSX SPU access
    print("[AudioCapture] SYNC CLICK")
    -- TODO: Implement actual SPU mute/unmute if FFI time doesn't work
end

-- Get system time with sub-second precision (UNIX epoch timestamp)
-- This matches Python's time.time() for cross-process timestamp correlation
local function get_system_time()
    -- Always use os.time() for Unix epoch (integer seconds)
    -- This is the most reliable cross-platform approach
    local unix_time = os.time()

    -- Try to get sub-second precision from FFI
    if get_precise_time then
        local precise = get_precise_time()
        -- Sanity check: precise time should be close to os.time()
        if math.abs(precise - unix_time) < 2 then
            return precise
        else
            print(string.format("[AudioCapture] WARNING: FFI time drift! os.time=%d, ffi=%.3f", unix_time, precise))
        end
    end

    -- Fallback: just use os.time() (integer seconds, no sub-second precision)
    return unix_time
end

-- Get phase boundaries by reading from memory (like trace_phases_v2.lua)
-- This reads the ACTUAL runtime values, not just the parsed timeline_header
local function get_phase_boundaries()
    MemUtils.refresh_mem()
    local ptr = MemUtils.read32(G_TIMELINE_PTR)
    if ptr == 0 or ptr < 0x80000000 then
        -- Fallback to timeline_header if pointer not set
        local th = EFFECT_EDITOR.timeline_header or {}
        local phase1_end = th.phase1_duration or 60
        local spawn_delay = th.spawn_delay or 0
        local phase2_delay = th.phase2_delay or 60
        return {
            phase1_end = phase1_end,
            spawn_delay = spawn_delay,
            phase2_delay = phase2_delay,
            target_count = 1,
            foreach_end = phase1_end,  -- No spawns for single target
            phase2_start = phase1_end + phase2_delay,
        }
    end

    -- Read from memory (timeline header offsets: +4=phase1_end, +6=spawn_delay, +10=phase2_delay)
    local phase1_end = MemUtils.read16(ptr + 4)
    local spawn_delay = MemUtils.read16(ptr + 6)
    local phase2_delay = MemUtils.read16(ptr + 10)
    local target_count = MemUtils.read16(G_EFFECT_CONTEXT)

    if target_count < 1 then target_count = 1 end

    -- foreach_end = when last child spawns
    local foreach_end = phase1_end + (target_count - 1) * spawn_delay
    -- phase2_start = after phase2_delay
    local phase2_start = foreach_end + phase2_delay

    return {
        phase1_end = phase1_end,
        spawn_delay = spawn_delay,
        phase2_delay = phase2_delay,
        target_count = target_count,
        foreach_end = foreach_end,
        phase2_start = phase2_start,
    }
end

-- Start audio capture: mute music, setup breakpoints, run test cycle
function M.ee_capture_audio_start()
    -- Check prerequisites
    local has_session = EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""
    if not has_session then
        print("ERROR: No session loaded. Use ee_load_session() first.")
        return false
    end

    if EFFECT_EDITOR.memory_base < 0x80000000 then
        print("ERROR: No memory target. Load a session with captured effect data.")
        return false
    end

    -- Initialize capture state with all phase timestamps
    EFFECT_EDITOR.audio_capture_timestamps = {
        effect_start = nil,      -- Frame 1 (system time)
        phase1_end = nil,        -- Frame == phase1_end (for-each START)
        foreach_end = nil,       -- Frame == foreach_end (last child spawned)
        phase2_start = nil,      -- Frame == phase2_start
        effect_end = nil,        -- Set by ee_capture_audio_read()
        -- Frame numbers for reference
        phase1_end_frame = nil,
        foreach_end_frame = nil,
        phase2_start_frame = nil,
    }
    EFFECT_EDITOR.audio_capture_active = true

    -- Phase boundaries - read when effect starts (not before, as effect isn't loaded yet)
    local bounds = nil

    -- Setup frame tracking breakpoint
    if AUDIO_CAPTURE_BP then
        pcall(function() AUDIO_CAPTURE_BP:disable() end)
        AUDIO_CAPTURE_BP = nil
    end

    AUDIO_CAPTURE_BP = PCSX.addBreakpoint(
        TIMELINE_FRAME_ADDR, "Write", 2, "AudioCapture",
        function()
            if not EFFECT_EDITOR.audio_capture_active then return true end

            MemUtils.refresh_mem()
            local frame = MemUtils.read16(TIMELINE_FRAME_ADDR)
            local now = get_system_time()  -- UNIX epoch timestamp
            local ts = EFFECT_EDITOR.audio_capture_timestamps

            -- Effect starts at frame 0 (when timeline counter resets)
            -- Read phase boundaries NOW when effect is actually loaded
            if frame == 0 and not ts.effect_start then
                ts.effect_start = now
                bounds = get_phase_boundaries()
                print(string.format("[AudioCapture] Effect started at frame %d, unix_time=%.6f", frame, now))
                print(string.format("[AudioCapture] Phase boundaries: phase1_end=%d, foreach_end=%d, phase2_start=%d",
                    bounds.phase1_end, bounds.foreach_end, bounds.phase2_start))
                print(string.format("[AudioCapture] DEBUG: os.time()=%d", os.time()))
            end

            -- Only track phase boundaries AFTER effect has started and bounds are loaded
            if ts.effect_start and bounds then
                -- Capture phase1_end (when for-each spawning starts)
                if frame == bounds.phase1_end and not ts.phase1_end then
                    ts.phase1_end = now
                    ts.phase1_end_frame = frame
                    if frame == 0 then
                        print(string.format("[AudioCapture] Phase 1 ended at frame 0 (no phase 1), unix_time=%.6f", now))
                    else
                        print(string.format("[AudioCapture] Phase 1 ended at frame %d, unix_time=%.6f", frame, now))
                    end
                end

            end

            -- Capture phase2_start and calculate foreach_end
            if ts.effect_start and bounds and frame == bounds.phase2_start and not ts.phase2_start then
                ts.phase2_start = now
                ts.phase2_start_frame = frame
                -- For-each audio = spawn_delay frames after phase1_end
                -- Back out: foreach_end = phase1_end + (spawn_delay / 30fps)
                ts.foreach_end = ts.phase1_end + (bounds.spawn_delay / 30)
                ts.foreach_end_frame = bounds.phase1_end + bounds.spawn_delay
                print(string.format("[AudioCapture] Phase 2 started at frame %d, foreach_end backed out to frame %d (spawn_delay=%d)",
                    frame, ts.foreach_end_frame, bounds.spawn_delay))
            end

            return true  -- Continue execution
        end
    )

    print("[AudioCapture] Breakpoint armed, running test cycle...")

    -- Run test cycle (async - uses nextTick)
    M.ee_test()

    print("[AudioCapture] Test cycle started. Call ee_capture_audio_read() after effect completes.")
    return true
end

-- Response file for bridge communication (Windows path for io.open)
local BRIDGE_RESPONSE_FILE = (os.getenv("APPDATA") or os.getenv("HOME") or ".") .. "/pcsx-redux/bridge_response.txt"

-- Write response to file for bridge
local function write_bridge_response(text)
    local f = io.open(BRIDGE_RESPONSE_FILE, "w")
    if f then
        f:write(text)
        f:close()
    end
end

-- Read capture results: get timestamps, cleanup, unmute
function M.ee_capture_audio_read()
    if not EFFECT_EDITOR.audio_capture_active then
        local err = "ERROR: No active capture. Call ee_capture_audio_start() first."
        print(err)
        write_bridge_response(err)
        return nil
    end

    -- Record end time (system time)
    local ts = EFFECT_EDITOR.audio_capture_timestamps
    ts.effect_end = get_system_time()

    -- Mark capture complete
    EFFECT_EDITOR.audio_capture_active = false

    -- Cleanup breakpoint
    if AUDIO_CAPTURE_BP then
        pcall(function() AUDIO_CAPTURE_BP:disable() end)
        AUDIO_CAPTURE_BP = nil
    end

    -- Output ABSOLUTE timestamps (UNIX epoch) for Python correlation
    -- Python will use these with its own record_start_time to calculate WAV positions
    -- Using %.6f for microsecond precision (needed for accurate WAV slicing)
    local json = string.format(
        'TIMESTAMPS:{"effect_start":%.6f,"phase1_end":%.6f,"foreach_end":%.6f,"phase2_start":%.6f,"effect_end":%.6f,"phase1_end_frame":%s,"foreach_end_frame":%s,"phase2_start_frame":%s}',
        ts.effect_start or 0,
        ts.phase1_end or 0,
        ts.foreach_end or 0,
        ts.phase2_start or 0,
        ts.effect_end,
        ts.phase1_end_frame or "null",
        ts.foreach_end_frame or "null",
        ts.phase2_start_frame or "null"
    )
    print(json)

    -- Write to response file for bridge
    write_bridge_response(json)

    return ts
end

--------------------------------------------------------------------------------
-- Phase Sound Isolation (bridge commands for isolated audio capture)
--------------------------------------------------------------------------------

-- Bridge command: isolate a single phase's sounds (mute other phases)
-- phase: "phase1", "foreach", or "phase2"
function M.ee_isolate_phase(phase)
    if not parser then
        print("[Workflow] ERROR: parser module not available")
        write_bridge_response("ERROR:parser_not_available")
        return false
    end

    local success = parser.isolate_sound_phase(phase)
    if success then
        write_bridge_response("OK:isolated_" .. phase)
    else
        write_bridge_response("ERROR:isolate_failed")
    end
    return success
end

-- Bridge command: restore all sounds to original state
function M.ee_restore_sounds()
    if not parser then
        print("[Workflow] ERROR: parser module not available")
        write_bridge_response("ERROR:parser_not_available")
        return false
    end

    local success = parser.restore_sound_timelines()
    if success then
        write_bridge_response("OK:restored")
    else
        write_bridge_response("ERROR:restore_failed")
    end
    return success
end

--------------------------------------------------------------------------------
-- Load sound data from a different BIN file
-- This allows reusing the same session savestate but with sounds from another effect
--------------------------------------------------------------------------------

-- Find embedded DATA header in CODE (MIPS) format files
-- Returns offset where the 40-byte header begins, or 0 for DATA format
local function find_embedded_header_offset(data)
    local mem = require("memory_utils")

    -- Check if this is a CODE format file (MIPS prologue: addiu sp, sp, -X = 0x27BDXXXX)
    local first_word = mem.buf_read32(data, 0)
    if first_word < 0x27BD0000 or first_word >= 0x27BE0000 then
        -- Not MIPS format, header is at offset 0
        return 0
    end

    print("[Workflow]   Detected MIPS format, searching for embedded header...")

    -- Search for embedded header by looking for the 0x28 pattern
    -- (first pointer = 0x28 = size of header, typical for DATA format)
    for i = 0, #data - 0x28, 4 do
        local ptr00 = mem.buf_read32(data, i)
        if ptr00 == 0x28 then
            -- Validate header structure: pointers should be ascending and reasonable
            local ptr08 = mem.buf_read32(data, i + 0x08)
            local ptr0C = mem.buf_read32(data, i + 0x0C)
            local ptr10 = mem.buf_read32(data, i + 0x10)

            if ptr08 > 0x28 and ptr08 < ptr0C and ptr0C < ptr10 and ptr10 < 0x8000 then
                print(string.format("[Workflow]   Found embedded header at offset 0x%X", i))
                return i
            end
        end
    end

    print("[Workflow]   WARNING: Could not find embedded header, using offset 0")
    return 0
end

function M.ee_load_sound_from_bin(bin_path)
    if not parser then
        print("[Workflow] ERROR: parser module not available")
        write_bridge_response("ERROR:parser_not_available")
        return false
    end

    local mem = require("memory_utils")

    -- 1. Read the BIN file
    print("[Workflow] Loading sound data from: " .. bin_path)
    local file = io.open(bin_path, "rb")
    if not file then
        print("[Workflow] ERROR: Cannot open " .. bin_path)
        write_bridge_response("ERROR:cannot_open_file")
        return false
    end
    local data = file:read("*all")
    file:close()
    print("[Workflow]   Read " .. #data .. " bytes")

    -- 2. Find base offset for MIPS files
    local base_offset = find_embedded_header_offset(data)

    -- 3. Parse header to get section pointers (adjusted for base_offset)
    -- Create adjusted data view for parsing
    local header = {
        frames_ptr = mem.buf_read32(data, base_offset + 0x00),
        animation_ptr = mem.buf_read32(data, base_offset + 0x04),
        script_data_ptr = mem.buf_read32(data, base_offset + 0x08),
        effect_data_ptr = mem.buf_read32(data, base_offset + 0x0C),
        anim_table_ptr = mem.buf_read32(data, base_offset + 0x10),
        time_scale_ptr = mem.buf_read32(data, base_offset + 0x14),
        effect_flags_ptr = mem.buf_read32(data, base_offset + 0x18),
        timeline_section_ptr = mem.buf_read32(data, base_offset + 0x1C),
        sound_def_ptr = mem.buf_read32(data, base_offset + 0x20),
        texture_ptr = mem.buf_read32(data, base_offset + 0x24),
    }

    -- All pointers are relative to the header location, so add base_offset
    local timeline_ptr = base_offset + header.timeline_section_ptr
    local effect_flags_ptr = base_offset + header.effect_flags_ptr
    local sound_def_ptr = base_offset + header.sound_def_ptr
    local texture_ptr = base_offset + header.texture_ptr

    print(string.format("[Workflow]   Header at 0x%X: effect_flags=0x%X, timeline=0x%X, sound_def=0x%X",
        base_offset, effect_flags_ptr, timeline_ptr, sound_def_ptr))

    -- 4. Parse sound-related sections from the BIN (using absolute offsets)

    -- TIER 1: Sound timelines
    local source_sound_timelines = parser.parse_all_sound_timelines(data, timeline_ptr)
    if source_sound_timelines then
        EFFECT_EDITOR.sound_timelines = source_sound_timelines
        print("[Workflow]   Loaded 9 sound timeline tracks")
    end

    -- TIER 2: Sound config channels (effect_flags bytes 0x08-0x17)
    local source_sound_flags = parser.parse_sound_flags_from_data(data, effect_flags_ptr)
    if source_sound_flags then
        EFFECT_EDITOR.sound_flags = source_sound_flags
        print("[Workflow]   Loaded 4 sound config channels")
    end

    -- TIER 3: Sound definition (feds section)
    local sound_section_size = texture_ptr - sound_def_ptr
    if sound_section_size > 0 then
        local source_sound_def = parser.parse_sound_definition_from_data(data, sound_def_ptr, sound_section_size)
        if source_sound_def then
            EFFECT_EDITOR.sound_definition = source_sound_def
            print(string.format("[Workflow]   Loaded feds section: %d channels", source_sound_def.num_channels))
        end
    end

    -- Phase timing from timeline header
    local source_timeline_header = parser.parse_timeline_header_from_data(data, timeline_ptr)
    if source_timeline_header and EFFECT_EDITOR.timeline_header then
        EFFECT_EDITOR.timeline_header.phase1_duration = source_timeline_header.phase1_duration
        EFFECT_EDITOR.timeline_header.spawn_delay = source_timeline_header.spawn_delay
        EFFECT_EDITOR.timeline_header.phase2_delay = source_timeline_header.phase2_delay
        print(string.format("[Workflow]   Loaded phase timing: phase1=%d, spawn_delay=%d, phase2_delay=%d",
            source_timeline_header.phase1_duration,
            source_timeline_header.spawn_delay,
            source_timeline_header.phase2_delay))
    end

    print("[Workflow] Sound data loaded successfully")
    write_bridge_response("OK:loaded_sound")
    return true
end

return M
