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

function M.set_dependencies(cfg, log_module, mem_utils, apply_all_edits, reload_fn, tex_ops)
    config = cfg
    logging = log_module
    MemUtils = mem_utils
    apply_all_edits_fn = apply_all_edits
    ee_reload_fn = reload_fn
    texture_ops = tex_ops
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

return M
