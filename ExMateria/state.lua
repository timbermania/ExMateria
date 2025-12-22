-- state.lua
-- Global state for the FFT Effect Editor
-- These MUST be global for breakpoint persistence (local variables get GC'd)

--------------------------------------------------------------------------------
-- Global State (must be global for GC reasons)
--------------------------------------------------------------------------------

EFFECT_EDITOR = {
    window_open = true,
    current_tab = 1,

    -- File state
    file_path = "",
    file_data = nil,
    file_name = "",

    -- Parsed data
    header = nil,
    sections = nil,
    emitter_count = 0,

    -- Particle system data
    particle_header = nil,
    emitters = nil,

    -- Animation curves data
    curves = nil,               -- Table of curves (1-indexed), each is table of 160 values
    curve_count = 0,            -- Number of curves (typically 15)
    original_curves = nil,      -- Copy for reset functionality

    -- Timeline data
    timeline_header = nil,              -- {phase1_duration, spawn_delay, phase2_delay, ...}
    timeline_channels = nil,            -- Array of 15 particle channels (5 animate_tick, 5 phase1, 5 phase2)
    original_timeline_header = nil,     -- Copy for reset functionality
    original_timeline_channels = nil,   -- Copy for reset functionality

    -- Camera timeline data
    camera_tables = nil,                -- Array of 3 camera tables (MAIN, FOR-EACH-TARGET, CLEANUP)
    original_camera_tables = nil,       -- Copy for reset functionality

    -- Color tracks data (12 tracks: 4 per context, 3 contexts)
    color_tracks = nil,                 -- Array of 12 color tracks
    original_color_tracks = nil,        -- Copy for reset functionality

    -- Time scale / timing curves data (2 regions: process_timeline and animate_tick)
    timing_curves = nil,                -- { process_timeline = {600 values}, animate_tick = {600 values} }
    original_timing_curves = nil,       -- Copy for reset functionality

    -- Effect flags (for timing curve enable bits)
    effect_flags = nil,                 -- { flags_byte = 0 }
    original_effect_flags = nil,        -- Copy for reset functionality

    -- Memory target
    memory_base = 0,

    -- Capture system
    capture_armed = false,
    last_captured_effect_id = -1,

    -- In-memory savestate (Slice) - used for Test Cycle
    in_memory_savestate = nil,

    -- Unified save/load state
    effect_id = 0,              -- Decimal effect ID (1 = E001.BIN)
    session_name = "",          -- Single name for .sstate, .bin, and .json

    -- File lists (populated by ee_refresh)
    session_files = {},         -- List of saved sessions (by name)

    -- Status
    status_msg = "Ready. Use ee_arm() to capture, then Save to create session.",
    effect_number = "001",

    -- Auto-loop settings
    auto_loop_enabled = false,
    auto_loop_seconds = 3.0,    -- Loop duration in seconds
    auto_loop_timer = 0,        -- Countdown timer (in seconds)
    auto_loop_last_time = 0,    -- Last frame time for delta calculation

    -- Test cycle settings
    test_quiet = true           -- Suppress console logging during test cycle
}

-- Breakpoint handle (must be global to avoid GC)
EFFECT_CAPTURE_BP = nil

-- Last error (for UI display)
EFFECT_EDITOR_LAST_ERROR = nil

--------------------------------------------------------------------------------
-- Module interface
--------------------------------------------------------------------------------

local M = {}

-- Reset state to defaults
function M.reset()
    EFFECT_EDITOR.window_open = true
    EFFECT_EDITOR.current_tab = 1
    EFFECT_EDITOR.file_path = ""
    EFFECT_EDITOR.file_data = nil
    EFFECT_EDITOR.file_name = ""
    EFFECT_EDITOR.header = nil
    EFFECT_EDITOR.sections = nil
    EFFECT_EDITOR.emitter_count = 0
    EFFECT_EDITOR.particle_header = nil
    EFFECT_EDITOR.emitters = nil
    EFFECT_EDITOR.curves = nil
    EFFECT_EDITOR.curve_count = 0
    EFFECT_EDITOR.original_curves = nil
    EFFECT_EDITOR.timeline_header = nil
    EFFECT_EDITOR.timeline_channels = nil
    EFFECT_EDITOR.original_timeline_header = nil
    EFFECT_EDITOR.original_timeline_channels = nil
    EFFECT_EDITOR.camera_tables = nil
    EFFECT_EDITOR.original_camera_tables = nil
    EFFECT_EDITOR.color_tracks = nil
    EFFECT_EDITOR.original_color_tracks = nil
    EFFECT_EDITOR.timing_curves = nil
    EFFECT_EDITOR.original_timing_curves = nil
    EFFECT_EDITOR.effect_flags = nil
    EFFECT_EDITOR.original_effect_flags = nil
    EFFECT_EDITOR.memory_base = 0
    EFFECT_EDITOR.capture_armed = false
    EFFECT_EDITOR.last_captured_effect_id = -1
    EFFECT_EDITOR.in_memory_savestate = nil
    EFFECT_EDITOR.effect_id = 0
    EFFECT_EDITOR.session_name = ""
    EFFECT_EDITOR.session_files = {}
    EFFECT_EDITOR.status_msg = "Ready. Use ee_arm() to capture, then Save to create session."
    EFFECT_EDITOR.effect_number = "001"
    EFFECT_EDITOR.auto_loop_enabled = false
    EFFECT_EDITOR.auto_loop_seconds = 3.0
    EFFECT_EDITOR.auto_loop_timer = 0
    EFFECT_EDITOR.auto_loop_last_time = 0
    EFFECT_EDITOR.test_quiet = true
end

return M
