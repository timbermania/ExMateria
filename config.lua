-- config.lua
-- Paths and constants for the FFT Effect Editor

local M = {}

-- Load platform utilities
local platform = require("platform")

--------------------------------------------------------------------------------
-- Default Paths
--------------------------------------------------------------------------------

-- Editor base path (set by init() from main.lua)
M.EDITOR_BASE_PATH = nil

-- Root data path - all editor data goes here
-- Subdirectories: savestates/, bins/, meta/
M.DATA_PATH = platform.get_appdata_dir() .. "/pcsx-effect-editor/"

-- Derived paths (computed from DATA_PATH)
M.SAVESTATE_PATH = nil
M.EFFECT_BINS_PATH = nil
M.META_PATH = nil
M.TEXTURES_PATH = nil

-- Path to original E###.BIN files (from fft-extract or ISO extraction)
-- Used for loading original effect files and comparison
M.EFFECT_FILES_PATH = nil

--------------------------------------------------------------------------------
-- Constants (SCUS94221 / NTSC-U version)
--------------------------------------------------------------------------------

-- Maximum effect file size (117,504 bytes = ~115 KB)
M.EFFECT_MAX_SIZE = 0x1CB00

-- Key PSX memory addresses (specific to SCUS94221 NTSC-U)
M.EFFECT_DATA_PTR_GLOBAL = 0x801BBF88   -- Written when effect file loads
M.EFFECT_BASE_LOOKUP_TABLE = 0x801B48D0 -- Array of effect base addresses
M.CURRENT_EFFECT_INDEX = 0x801C24D0     -- Current effect index

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

-- Ensure directory exists (uses platform module)
function M.ensure_dir(path)
    return platform.ensure_dir(path)
end

-- Update derived paths from DATA_PATH
local function update_derived_paths()
    M.SAVESTATE_PATH = M.DATA_PATH .. "savestates/"
    M.EFFECT_BINS_PATH = M.DATA_PATH .. "bins/"
    M.META_PATH = M.DATA_PATH .. "meta/"
    M.TEXTURES_PATH = M.DATA_PATH .. "textures/"
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- Track if already initialized
local initialized = false

-- Initialize config with script directory
-- Called by main.lua after detecting script location
function M.init(script_dir)
    if initialized then
        return  -- Only initialize once
    end

    -- Store editor base path
    M.EDITOR_BASE_PATH = script_dir

    -- Try to load user config if it exists
    local user_config_path = script_dir .. "config_user.lua"
    local user_config_fn = loadfile(user_config_path)
    if user_config_fn then
        local ok, user_config = pcall(user_config_fn)
        if ok and type(user_config) == "table" then
            -- Apply user overrides
            if user_config.DATA_PATH then
                M.DATA_PATH = user_config.DATA_PATH
            end
            if user_config.EFFECT_FILES_PATH then
                M.EFFECT_FILES_PATH = user_config.EFFECT_FILES_PATH
            end
            print("Effect Editor: Loaded user config from config_user.lua")
        end
    end

    -- Update derived paths
    update_derived_paths()

    -- Ensure data directories exist
    M.ensure_dir(M.DATA_PATH)
    M.ensure_dir(M.SAVESTATE_PATH)
    M.ensure_dir(M.EFFECT_BINS_PATH)
    M.ensure_dir(M.META_PATH)
    M.ensure_dir(M.TEXTURES_PATH)

    initialized = true
end

-- Update DATA_PATH and re-derive subdirectories (called from settings UI)
function M.set_data_path(new_path)
    -- Ensure trailing slash
    if not new_path:match("/$") and not new_path:match("\\$") then
        new_path = new_path .. "/"
    end
    M.DATA_PATH = new_path
    update_derived_paths()

    -- Create directories
    M.ensure_dir(M.DATA_PATH)
    M.ensure_dir(M.SAVESTATE_PATH)
    M.ensure_dir(M.EFFECT_BINS_PATH)
    M.ensure_dir(M.META_PATH)
    M.ensure_dir(M.TEXTURES_PATH)
end

-- Update EFFECT_FILES_PATH (called from settings UI)
function M.set_effect_files_path(new_path)
    if not new_path or new_path == "" then
        M.EFFECT_FILES_PATH = nil
        return
    end
    -- Ensure trailing slash
    if not new_path:match("/$") and not new_path:match("\\$") then
        new_path = new_path .. "/"
    end
    M.EFFECT_FILES_PATH = new_path
end

return M
