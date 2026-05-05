-- main.lua
-- FFT Effect Editor v0.9.14 - Entry Point
-- Modular refactored version

local ffi = require("ffi")

--------------------------------------------------------------------------------
-- Module Path Setup
--------------------------------------------------------------------------------

-- Dynamically detect script directory from the path used to load this file
-- Works with both Windows paths and WSL UNC paths
local function get_script_directory()
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local source = info.source
        -- Remove @ prefix if present (standard Lua source notation)
        if source:sub(1, 1) == "@" then
            source = source:sub(2)
        end

        -- Extract directory part (try backslash first for Windows/UNC paths)
        local dir = source:match("(.+\\)[^\\]+$")
        if dir then
            return dir
        end

        -- Try forward slash (POSIX paths)
        dir = source:match("(.+/)[^/]+$")
        if dir then
            return dir
        end
    end

    -- Fallback: prompt user to check documentation
    error([[
FFT Effect Editor: Could not detect script directory!

Please ensure you load the script using its full path, for example:
  dofile("C:\\path\\to\\effect_editor\\main.lua")

Or for WSL:
  dofile("\\\\wsl.localhost\\Ubuntu\\path\\to\\effect_editor\\main.lua")
]])
end

local SCRIPT_DIR = get_script_directory()

-- Add effect_editor directory and subdirectories to package.path
local SEP = package.config:sub(1, 1)  -- "\\" on Windows, "/" on Linux
package.path = SCRIPT_DIR .. "?.lua;"
            .. SCRIPT_DIR .. "core" .. SEP .. "?.lua;"
            .. SCRIPT_DIR .. "ui" .. SEP .. "?.lua;"
            .. SCRIPT_DIR .. "commands" .. SEP .. "?.lua;"
            .. SCRIPT_DIR .. "utils" .. SEP .. "?.lua;"
            .. SCRIPT_DIR .. "mips" .. SEP .. "?.lua;"
            .. SCRIPT_DIR .. "capture" .. SEP .. "?.lua;"
            .. package.path

--------------------------------------------------------------------------------
-- Clear Module Cache (allows clean reload via dofile)
--------------------------------------------------------------------------------

local modules_to_clear = {
    "platform", "bmp",
    "config", "logging", "state", "memory_utils", "parser", "zlib_io", "structure_manager", "field_schema",
    "capture", "memory_ops", "texture_ops",
    "helpers", "structure_tab", "particles_tab", "header_tab", "timeline_tab", "camera_tab", "color_tracks_tab", "sound_timeline_tab", "time_scale_tab", "settings_tab", "sound_tab", "script_tab", "frames_tab", "sequences_tab",
    "load_panel", "save_panel", "session_list", "main_window",
    "curve_generators", "curve_canvas", "curves_tab",
    "workflow", "file_ops", "savestate", "session", "debug_cmds",
    "disassembler", "known_functions",
    "particle_reader", "particle_spawn_logger", "particle_lifecycle_capture", "emitter_invocation_capture", "sound_capture", "note_capture", "opcode_capture", "audio_record", "debug_tab",
    "spu_voice_trace", "instrument_snapshot", "sound_debug", "sound_debug_tab"
}

for _, mod in ipairs(modules_to_clear) do
    package.loaded[mod] = nil
end

-- Clear globals from previous load
EFFECT_EDITOR = nil
EFFECT_CAPTURE_BP = nil
PARTICLE_SPAWN_LOG_BP = nil
LIFECYCLE_BP_INIT = nil
LIFECYCLE_BP_SPAWN_ENTRY = nil
LIFECYCLE_BP_SPAWN_EXIT = nil
LIFECYCLE_BP_FRAME = nil
PARTICLE_LIFECYCLE_CAPTURE = nil
EMITTER_INVOCATION_BP = nil
EMITTER_INVOCATION_BP_EXIT = nil
EMITTER_INVOCATION_CAPTURE = nil
SOUND_CAPTURE_BP = nil
SOUND_CAPTURE_FRAME_BP = nil
SOUND_CAPTURE_LOOKUP_BP = nil
SOUND_CAPTURE = nil
NOTE_CAPTURE_BP = nil
NOTE_CAPTURE_FRAME_BP = nil
NOTE_CAPTURE = nil
OPCODE_CAPTURE_INSTRUMENT_BP = nil
OPCODE_CAPTURE_OCTAVE_BP = nil
OPCODE_CAPTURE_DYNAMICS_BP = nil
OPCODE_CAPTURE_NOTE_BP = nil
OPCODE_CAPTURE_FRAME_BP = nil
OPCODE_CAPTURE = nil
AUDIO_RECORD_BP = nil
AUDIO_CAPTURE_BP = nil
SPU_VOICE_TRACE_BP = nil
SPU_VOICE_TRACE = nil
SOUND_DEBUG_RUN = nil
EFFECT_EDITOR_LAST_ERROR = nil

--------------------------------------------------------------------------------
-- Load All Modules
--------------------------------------------------------------------------------

-- Utility modules (must be loaded first)
local platform = require("platform")

-- Core modules (must be loaded before others that depend on them)
local config = require("config")
config.init(SCRIPT_DIR)  -- Initialize with detected script directory
local logging = require("logging")
local state = require("state")  -- Sets up EFFECT_EDITOR global
local MemUtils = require("memory_utils")
local Parser = require("parser")
local zlib_io = require("zlib_io")
local structure_manager = require("structure_manager")
local field_schema = require("field_schema")

-- System modules
local capture = require("capture")
local memory_ops = require("memory_ops")

-- UI modules
local helpers = require("helpers")
local structure_tab = require("structure_tab")
local particles_tab = require("particles_tab")
local header_tab = require("header_tab")
local timeline_tab = require("timeline_tab")
local camera_tab = require("camera_tab")
local color_tracks_tab = require("color_tracks_tab")
local sound_timeline_tab = require("sound_timeline_tab")
local time_scale_tab = require("time_scale_tab")
local settings_tab = require("settings_tab")
local sound_tab = require("sound_tab")
local script_tab = require("script_tab")
local frames_tab = require("frames_tab")
local sequences_tab = require("sequences_tab")
local load_panel = require("load_panel")
local save_panel = require("save_panel")
local session_list = require("session_list")
local main_window = require("main_window")
local curve_generators = require("curve_generators")
local curve_canvas = require("curve_canvas")
local curves_tab = require("curves_tab")

-- Debug tab modules
local particle_reader = require("particle_reader")
local particle_spawn_logger = require("particle_spawn_logger")
local particle_lifecycle_capture = require("particle_lifecycle_capture")
local emitter_invocation_capture = require("emitter_invocation_capture")
local sound_capture = require("sound_capture")
local note_capture = require("note_capture")
local opcode_capture = require("opcode_capture")
local audio_record = require("audio_record")
local debug_tab = require("debug_tab")

-- Sound-debug capture pipeline (SPU voice trace, instrument snapshot, orchestrator, tab)
local spu_voice_trace = require("spu_voice_trace")
local instrument_snapshot = require("instrument_snapshot")
local sound_debug = require("sound_debug")
local sound_debug_tab = require("sound_debug_tab")

-- Command modules
local workflow = require("workflow")
local file_ops = require("file_ops")
local savestate = require("savestate")
local session = require("session")
local debug_cmds = require("debug_cmds")
local texture_ops = require("texture_ops")

--------------------------------------------------------------------------------
-- Wire Up Dependencies
--------------------------------------------------------------------------------

-- Set up logging in zlib_io
zlib_io.set_logger(logging.log, logging.log_error)

-- Set up structure manager
structure_manager.set_dependencies(MemUtils, Parser, logging.log, logging.log_verbose)

-- Set up capture module
capture.set_dependencies(MemUtils, logging.log, logging.log_error, audio_record)

-- Set up memory_ops module
memory_ops.set_dependencies(MemUtils, Parser, config, logging.log, logging.log_verbose, logging.log_error, structure_manager)

-- Wire capture callback to memory_ops (avoids circular dependency)
capture.on_capture_callback = memory_ops.load_from_memory_internal

-- Set up UI modules
particles_tab.set_dependencies(helpers, Parser)
-- header_tab has no dependencies
timeline_tab.set_dependencies(helpers)
camera_tab.set_dependencies(helpers)
color_tracks_tab.set_dependencies(helpers)
sound_timeline_tab.set_dependencies(helpers)
time_scale_tab.set_dependencies(memory_ops.add_time_scale_section, memory_ops.remove_time_scale_section)
sound_tab.set_dependencies(helpers, Parser)
script_tab.set_dependencies(helpers, Parser)
frames_tab.set_dependencies(helpers, Parser, bmp, config)
sequences_tab.set_dependencies(helpers, Parser, workflow.ee_test, session.ee_load_session, memory_ops.apply_all_edits_to_memory)
load_panel.set_dependencies(memory_ops.load_effect_file, capture.arm_capture, capture.disarm_capture)
session_list.set_dependencies(session.ee_load_session, session.ee_delete, session.ee_refresh_sessions)
save_panel.set_dependencies(config, savestate.ee_raw_save, savestate.ee_save_bin_edited,
                            savestate.ee_save_state_only, session.ee_refresh_sessions, session_list,
                            session.ee_copy)
curves_tab.set_dependencies(curve_canvas, curve_generators, MemUtils, Parser, memory_ops)

-- Debug tab dependencies
particle_reader.set_dependencies(MemUtils)
particle_lifecycle_capture.set_dependencies(MemUtils, particle_reader, config)
emitter_invocation_capture.set_dependencies(MemUtils, config)
sound_capture.set_dependencies(MemUtils, config)
note_capture.set_dependencies(MemUtils, config)
opcode_capture.set_dependencies(MemUtils, config)
audio_record.set_dependencies(MemUtils, config)
spu_voice_trace.set_dependencies(MemUtils, config)
instrument_snapshot.set_dependencies(MemUtils, config)
sound_debug.set_dependencies(config, MemUtils, session, sound_capture, note_capture, spu_voice_trace, instrument_snapshot, audio_record)
sound_debug_tab.set_dependencies(sound_debug, sound_capture, note_capture, spu_voice_trace)
debug_tab.set_dependencies(particle_reader, particle_spawn_logger, helpers, particle_lifecycle_capture, emitter_invocation_capture, sound_capture, note_capture, opcode_capture, audio_record)

main_window.set_dependencies(load_panel, save_panel, structure_tab, particles_tab, curves_tab, header_tab, timeline_tab, camera_tab, color_tracks_tab, sound_timeline_tab, time_scale_tab, sound_tab, script_tab, frames_tab, sequences_tab, settings_tab, debug_tab, workflow.ee_test, savestate.ee_save_bin_edited, session.ee_load_session, texture_ops, sound_debug_tab)

-- Register reload callbacks
EFFECT_EDITOR.on_reload_callbacks = EFFECT_EDITOR.on_reload_callbacks or {}
table.insert(EFFECT_EDITOR.on_reload_callbacks, sequences_tab.clear_preview_state)

-- Set up command modules (all use unified apply_all_edits_to_memory)
workflow.set_dependencies(config, logging, MemUtils, memory_ops.apply_all_edits_to_memory, savestate.ee_reload, texture_ops, audio_record, Parser)
file_ops.set_dependencies(config, logging, MemUtils, memory_ops.load_effect_file,
                          memory_ops.load_from_memory, memory_ops.load_from_memory_internal,
                          session.ee_load_session)
savestate.set_dependencies(config, logging, MemUtils, zlib_io,
                           memory_ops.apply_all_edits_to_memory, session.ee_refresh_sessions, texture_ops)
session.set_dependencies(config, logging, MemUtils, Parser, savestate.ee_reload,
                         memory_ops.load_from_memory_internal, memory_ops.apply_all_edits_to_memory, texture_ops)
debug_cmds.set_dependencies(logging, capture.arm_capture, capture.disarm_capture, MemUtils, config)
texture_ops.set_dependencies(config, logging, MemUtils)

--------------------------------------------------------------------------------
-- Register Global DrawImguiFrame (with chaining to support watcher)
--------------------------------------------------------------------------------

-- Chain into DrawImguiFrame (allows bridge watcher to coexist)
-- NOTE: Load watcher FIRST, then effect_editor, so we chain off watcher
--
-- RELOAD HANDLING: On reload, we must restore DrawImguiFrame to its pre-effect-editor
-- state, otherwise we chain onto the old effect_editor and get duplicate draws.
-- EFFECT_EDITOR_PRE_HOOK_DRAW stores the DrawImguiFrame from BEFORE we first hooked.

if EFFECT_EDITOR_PRE_HOOK_DRAW then
    -- This is a reload - restore to pre-effect-editor state first
    DrawImguiFrame = EFFECT_EDITOR_PRE_HOOK_DRAW
    print("[EffectEditor] Reload detected - restored pre-hook DrawImguiFrame")
end

-- Save the current (pre-effect-editor) DrawImguiFrame for future reloads
local original_draw = DrawImguiFrame or function() end
EFFECT_EDITOR_PRE_HOOK_DRAW = original_draw

-- Now chain the effect editor
function DrawImguiFrame()
    original_draw()
    main_window.draw()
end
print("[EffectEditor] Hooked into DrawImguiFrame")

--------------------------------------------------------------------------------
-- Register Global Console Commands
--------------------------------------------------------------------------------

-- Workflow commands
ee_test = workflow.ee_test
ee_apply = workflow.ee_apply

-- File operations
ee_load = file_ops.ee_load
ee_mem = file_ops.ee_mem
ee_set_mem = file_ops.ee_set_mem
ee_save_bin = file_ops.ee_save_bin
ee_load_bin = file_ops.ee_load_bin
ee_delete_bin = file_ops.ee_delete_bin
ee_import_bin = file_ops.ee_import_bin

-- Savestate commands
ee_save = savestate.ee_save
ee_reload = savestate.ee_reload
ee_raw_save = savestate.ee_raw_save
ee_save_bin_edited = savestate.ee_save_bin_edited
ee_save_state_only = savestate.ee_save_state_only
ee_save_all = savestate.ee_save_all

-- Session commands
ee_load_session = session.ee_load_session
ee_refresh_sessions = session.ee_refresh_sessions
ee_refresh_bins = session.ee_refresh_bins
ee_refresh = session.ee_refresh
ee_list = session.ee_list
ee_delete = session.ee_delete
ee_copy = session.ee_copy

-- Debug commands
ee_help = debug_cmds.ee_help
ee_show = debug_cmds.ee_show
ee_hide = debug_cmds.ee_hide
ee_error = debug_cmds.ee_error
ee_dump = debug_cmds.ee_dump
ee_verbose = debug_cmds.ee_verbose
ee_status = debug_cmds.ee_status
ee_arm = debug_cmds.ee_arm
ee_disarm = debug_cmds.ee_disarm
ee_regression_dump = debug_cmds.ee_regression_dump
ee_debug_sections = memory_ops.debug_sections

-- Texture commands
ee_texture_dump = texture_ops.debug_dump_texture
ee_texture_export = texture_ops.export_texture_to_bmp
ee_texture_reload = texture_ops.reload_texture_from_bmp

-- Spawn logger commands
ee_spawn_arm = particle_spawn_logger.arm_recording
ee_spawn_stop = particle_spawn_logger.disarm_recording
ee_spawn_log = particle_spawn_logger.print_log
ee_spawn_clear = particle_spawn_logger.clear_log

-- Lifecycle capture commands
ee_lifecycle_start = particle_lifecycle_capture.start_capture
ee_lifecycle_stop = particle_lifecycle_capture.stop_capture
ee_lifecycle_export = particle_lifecycle_capture.export_csv

-- Emitter invocation capture commands
ee_emitter_start = emitter_invocation_capture.start_capture
ee_emitter_stop = emitter_invocation_capture.stop_capture
ee_emitter_export = emitter_invocation_capture.export_csv
ee_emitter_log = emitter_invocation_capture.print_log

-- Sound capture commands
ee_sound_start = sound_capture.start_capture
ee_sound_stop = sound_capture.stop_capture
ee_sound_log = sound_capture.print_log

-- Note capture commands
ee_note_start = note_capture.start_capture
ee_note_stop = note_capture.stop_capture
ee_note_log = note_capture.print_log

-- Opcode capture commands (effect-scoped SMD opcodes)
ee_opcode_start = opcode_capture.start_capture
ee_opcode_stop = opcode_capture.stop_capture
ee_opcode_log = opcode_capture.print_log
ee_opcode_summary = opcode_capture.print_timing_summary

-- Audio recording commands (music muting)
ee_audio_mute = audio_record.mute_music
ee_audio_unmute = audio_record.unmute_music
ee_audio_debug_hook = audio_record.start_hook_debug
ee_audio_debug_stop = audio_record.stop_hook_debug
ee_audio_debug_count = audio_record.get_hook_count
ee_audio_debug_count_response = audio_record.get_hook_count_response
ee_audio_debug_resource_breakdown = audio_record.get_resource_id_breakdown

-- Audio capture commands (for bridge-based recording)
ee_capture_audio_start = workflow.ee_capture_audio_start
ee_capture_audio_read = workflow.ee_capture_audio_read

-- Phase sound isolation (for isolated audio capture)
ee_isolate_phase = workflow.ee_isolate_phase
ee_restore_sounds = workflow.ee_restore_sounds

-- Sound-debug orchestrator commands
ee_sound_debug_start = sound_debug.ee_sound_debug_start
ee_sound_debug_stop = sound_debug.ee_sound_debug_stop

-- Sound data swap (load sound from different BIN file)
ee_load_sound_from_bin = workflow.ee_load_sound_from_bin

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- Note: Directories are ensured in config.lua at load time
-- Note: Session list is refreshed lazily when UI opens (avoids console window flash)

-- Show help
print("")
print("GUI will appear in PCSX-Redux window.")
ee_help()
