-- logging.lua
-- Logging utilities for the FFT Effect Editor

local M = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local LOG_VERBOSE = false  -- Set to true for detailed logging

--------------------------------------------------------------------------------
-- Logging functions
--------------------------------------------------------------------------------

function M.log(msg)
    print("[EE] " .. msg)
end

function M.log_verbose(msg)
    -- Check UI state (EFFECT_EDITOR.test_verbose) or module state (LOG_VERBOSE)
    local verbose = LOG_VERBOSE or (EFFECT_EDITOR and EFFECT_EDITOR.test_verbose)
    if verbose then
        print("[EE] " .. msg)
    end
end

function M.log_error(msg)
    print("[EE ERROR] " .. msg)
    -- Set global error for UI display
    EFFECT_EDITOR_LAST_ERROR = msg
end

--------------------------------------------------------------------------------
-- Verbose control
--------------------------------------------------------------------------------

function M.set_verbose(on)
    LOG_VERBOSE = on
    M.log("Verbose logging " .. (on and "enabled" or "disabled"))
end

function M.is_verbose()
    return LOG_VERBOSE or (EFFECT_EDITOR and EFFECT_EDITOR.test_verbose)
end

return M
