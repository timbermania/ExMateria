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
package.path = SCRIPT_DIR .. "?.lua;"
            .. SCRIPT_DIR .. "core\\?.lua;"
            .. SCRIPT_DIR .. "ui\\?.lua;"
            .. SCRIPT_DIR .. "commands\\?.lua;"
            .. SCRIPT_DIR .. "utils\\?.lua;"
            .. package.path

--------------------------------------------------------------------------------
-- Clear Module Cache (allows clean reload via dofile)
--------------------------------------------------------------------------------

local modules_to_clear = {
    "platform", "bmp",
    "config", "logging", "state", "memory_utils", "parser", "zlib_io", "structure_manager", "field_schema",
    "capture", "memory_ops", "texture_ops",
    "helpers", "structure_tab", "particles_tab", "header_tab", "timeline_tab", "camera_tab", "color_tracks_tab", "time_scale_tab", "settings_tab", "sound_tab", "script_tab", "frames_tab", "sequences_tab",
    "load_panel", "save_panel", "session_list", "main_window",
    "curve_generators", "curve_canvas", "curves_tab",
    "workflow", "file_ops", "savestate", "session", "debug_cmds"
}

for _, mod in ipairs(modules_to_clear) do
    package.loaded[mod] = nil
end

-- Clear globals from previous load
EFFECT_EDITOR = nil
EFFECT_CAPTURE_BP = nil
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
capture.set_dependencies(MemUtils, logging.log, logging.log_error)

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
time_scale_tab.set_dependencies(memory_ops.add_timing_curve_section, memory_ops.remove_timing_curve_section)
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
main_window.set_dependencies(load_panel, save_panel, structure_tab, particles_tab, curves_tab, header_tab, timeline_tab, camera_tab, color_tracks_tab, time_scale_tab, sound_tab, script_tab, frames_tab, sequences_tab, settings_tab, workflow.ee_test, savestate.ee_save_bin_edited, session.ee_load_session, texture_ops)

-- Register reload callbacks
EFFECT_EDITOR.on_reload_callbacks = EFFECT_EDITOR.on_reload_callbacks or {}
table.insert(EFFECT_EDITOR.on_reload_callbacks, sequences_tab.clear_preview_state)

-- Set up command modules (all use unified apply_all_edits_to_memory)
workflow.set_dependencies(config, logging, MemUtils, memory_ops.apply_all_edits_to_memory, savestate.ee_reload, texture_ops)
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
-- Register Global DrawImguiFrame
--------------------------------------------------------------------------------

function DrawImguiFrame()
    main_window.draw()
end

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

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- Note: Directories are ensured in config.lua at load time
-- Note: Session list is refreshed lazily when UI opens (avoids console window flash)

-- Show help
print("")
print("GUI will appear in PCSX-Redux window.")
ee_help()
