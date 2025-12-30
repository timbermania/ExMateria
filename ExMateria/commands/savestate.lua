-- commands/savestate.lua
-- Savestate operations: save, reload, migrate

local ffi = require("ffi")

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local config = nil
local logging = nil
local MemUtils = nil
local zlib_io = nil
local apply_all_edits_fn = nil
local ee_refresh_sessions_fn = nil
local texture_ops = nil

function M.set_dependencies(cfg, log_module, mem_utils, zlib, apply_all_edits, refresh_fn, tex_ops)
    config = cfg
    logging = log_module
    MemUtils = mem_utils
    zlib_io = zlib
    apply_all_edits_fn = apply_all_edits
    ee_refresh_sessions_fn = refresh_fn
    texture_ops = tex_ops
end

--------------------------------------------------------------------------------
-- Helper: Check if file is gzip-compressed
--------------------------------------------------------------------------------

local function is_gzip_file(path)
    local win_path = path:gsub("/", "\\")
    local f = io.open(win_path, "rb")
    if not f then return false end
    local magic = f:read(2)
    f:close()
    if not magic or #magic < 2 then return false end
    return string.byte(magic, 1) == 0x1f and string.byte(magic, 2) == 0x8b
end

--------------------------------------------------------------------------------
-- ee_save: Save savestate + metadata
--------------------------------------------------------------------------------

function M.ee_save(name)
    name = name or EFFECT_EDITOR.session_name or "manual"
    local path = config.SAVESTATE_PATH .. name .. ".sstate"

    -- Pause emulator for safety
    PCSX.pauseEmulator()

    logging.log(string.format("Saving savestate '%s' (compressed)...", name))

    local success, err = pcall(function()
        if not zlib_io.save_savestate_to_file(path) then
            error("Compression failed")
        end
    end)

    if success then
        EFFECT_EDITOR.session_name = name
        logging.log(string.format("Savestate '%s' saved (compressed)!", name))

        -- Save metadata JSON
        local meta_path = config.META_PATH .. name .. ".json"
        local meta_file = io.open(meta_path, "w")
        if meta_file then
            local effect_idx = EFFECT_EDITOR.effect_id or 0
            meta_file:write(string.format('{\n  "effect_index": %d,\n  "name": "%s"\n}\n', effect_idx, name))
            meta_file:close()
        end

        EFFECT_EDITOR.status_msg = "Saved: " .. name
        if ee_refresh_sessions_fn then
            ee_refresh_sessions_fn()
        end
        return true
    else
        logging.log_error("Failed to save savestate: " .. tostring(err))
        return false
    end
end

--------------------------------------------------------------------------------
-- ee_reload: Reload savestate from file
--------------------------------------------------------------------------------

function M.ee_reload(name, quiet)
    -- If no name given, use current session
    if not name then
        name = EFFECT_EDITOR.session_name
    end

    if not name then
        logging.log_error("No session name specified.")
        return false
    end

    local path = config.SAVESTATE_PATH .. name .. ".sstate"
    local path_win = path:gsub("/", "\\")

    -- Check if file exists and get size
    local f = io.open(path_win, "rb")
    if not f then
        logging.log_error("Savestate file not found: " .. path_win)
        return false
    end
    local file_size = f:seek("end")
    f:close()

    if not quiet then
        logging.log(string.format("=== RELOAD SAVESTATE '%s' ===", name))
        logging.log(string.format("  Path: %s", path))
        logging.log(string.format("  File size: %d bytes", file_size or 0))
    end

    -- Check if file is compressed or not
    local is_compressed = is_gzip_file(path)
    if not quiet then
        logging.log(string.format("  Format: %s", is_compressed and "COMPRESSED (gzip)" or "UNCOMPRESSED (raw)"))
    end

    -- IMPORTANT: Pause emulator before loading savestate
    PCSX.pauseEmulator()
    if not quiet then logging.log("  Emulator paused for savestate load") end

    local file = nil
    local decompressed = nil

    local success, err = pcall(function()
        if not quiet then logging.log("  Opening file with Support.File...") end
        file = Support.File.open(path, "READ")
        if not file then
            error("Could not open file: " .. path)
        end
        if not quiet then logging.log("  File opened, Support.File size: " .. tostring(file:size()) .. " bytes") end

        if is_compressed then
            -- Compressed file - use zReader
            if not quiet then logging.log("  Using zReader for decompression...") end
            decompressed = Support.File.zReader(file)
            if not decompressed then
                error("Could not create zReader")
            end
            if not quiet then
                logging.log("  Decompressed size: " .. tostring(decompressed:size()) .. " bytes")
                logging.log("  Calling PCSX.loadSaveState(decompressed)...")
            end
            PCSX.loadSaveState(decompressed)
        else
            -- Uncompressed file - load directly
            if not quiet then logging.log("  Calling PCSX.loadSaveState(file) directly...") end
            PCSX.loadSaveState(file)
        end
        if not quiet then logging.log("  loadSaveState returned") end
    end)

    -- IMPORTANT: Explicitly close file handles to prevent leaks
    if decompressed then
        pcall(function() decompressed:close() end)
        if not quiet then logging.log("  Closed decompressed handle") end
    end
    if file then
        pcall(function() file:close() end)
        if not quiet then logging.log("  Closed file handle") end
    end

    if success then
        if not quiet then logging.log(string.format("=== RELOAD '%s' COMPLETE ===", name)) end

        -- Call any registered reload callbacks (e.g., to clear preview mode)
        if EFFECT_EDITOR.on_reload_callbacks then
            for _, callback in ipairs(EFFECT_EDITOR.on_reload_callbacks) do
                pcall(callback)
            end
        end

        return true
    else
        logging.log_error("Failed to load savestate: " .. tostring(err))
        return false
    end
end

--------------------------------------------------------------------------------
-- Helper: Save bin and metadata (used by ee_raw_save)
--------------------------------------------------------------------------------

local function ee_save_bin_and_meta(name, effect_idx)
    -- Save bin (effect data from memory)
    logging.log("Step 4: Saving bin...")
    MemUtils.refresh_mem()
    local base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + effect_idx * 4)
    if base < 0x80000000 or base >= 0x80200000 then
        logging.log_error(string.format("Invalid base 0x%08X for E%03d", base, effect_idx))
        return false
    end

    local bin_path = config.EFFECT_BINS_PATH .. name .. ".bin"
    local bin_ok = false
    local success, err = pcall(function()
        -- Use getMemPtr() directly to avoid readAt/ffi.string Slice issues
        -- Lookup table stores HEADER address directly (NOT size prefix address)
        -- So we read from base directly, no +4 needed
        local mem = PCSX.getMemPtr()
        local offset = base - 0x80000000  -- No +4, lookup table already points to header
        local read_size = config.EFFECT_MAX_SIZE - 4
        logging.log(string.format("  Reading %d bytes from offset 0x%X (base=0x%08X)",
            read_size, offset, base))
        local data_str = ffi.string(ffi.cast("char*", mem) + offset, read_size)

        -- Debug: show first 16 bytes being written
        local hex = ""
        for i = 1, math.min(16, #data_str) do
            hex = hex .. string.format("%02X ", string.byte(data_str, i))
        end
        logging.log(string.format("  First 16 bytes to write: %s", hex))

        local win_path = bin_path:gsub("/", "\\")
        local outfile = io.open(win_path, "wb")
        if not outfile then
            error("Could not create file: " .. win_path)
        end
        outfile:write(data_str)
        outfile:close()
        bin_ok = true
    end)

    if not bin_ok then
        logging.log_error("Failed to save bin: " .. tostring(err))
        return false
    end

    -- Save metadata
    logging.log("Step 5: Saving metadata...")
    local meta_path = config.META_PATH .. name .. ".json"
    local meta_file = io.open(meta_path, "w")
    if meta_file then
        meta_file:write(string.format('{\n  "effect_index": %d,\n  "name": "%s"\n}\n', effect_idx, name))
        meta_file:close()
    end

    EFFECT_EDITOR.memory_base = base
    EFFECT_EDITOR.status_msg = "Saved: " .. name
    logging.log(string.format("=== SESSION '%s' SAVED ===", name))

    if ee_refresh_sessions_fn then
        ee_refresh_sessions_fn()
    end
    return true
end

--------------------------------------------------------------------------------
-- ee_raw_save: Save savestate + bin + metadata AS-IS (for NEW captures)
--------------------------------------------------------------------------------

function M.ee_raw_save()
    logging.log("========================================")
    logging.log("=== EE_RAW_SAVE - Save current state + bin ===")
    logging.log("========================================")

    local name = EFFECT_EDITOR.session_name
    logging.log(string.format("  session_name: '%s'", name or "nil"))
    if not name or name == "" then
        logging.log_error("No session name set")
        return false
    end

    local effect_idx = EFFECT_EDITOR.effect_id
    logging.log(string.format("  effect_id: %d", effect_idx or 0))
    if effect_idx <= 0 then
        logging.log_error("Effect ID must be > 0")
        return false
    end

    local mem_base = EFFECT_EDITOR.memory_base
    logging.log(string.format("  memory_base: 0x%08X", mem_base or 0))

    -- Check effect lookup table to verify effect is in memory
    MemUtils.refresh_mem()
    local lookup_base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + effect_idx * 4)
    logging.log(string.format("  lookup_table[%d]: 0x%08X", effect_idx, lookup_base or 0))

    if lookup_base < 0x80000000 or lookup_base >= 0x80200000 then
        logging.log_error(string.format("WARNING: Effect %d not currently loaded in memory!", effect_idx))
    end

    logging.log(string.format("=== RAW SAVING '%s' (E%03d) ===", name, effect_idx))

    -- Pause emulator for safe save
    logging.log("Pausing emulator...")
    PCSX.pauseEmulator()
    logging.log("Emulator paused")

    -- Step 1: Save savestate
    local ss_path = config.SAVESTATE_PATH .. name .. ".sstate"
    logging.log("Step 1: Saving savestate to: " .. ss_path)

    local ss_ok = false
    local success, err = pcall(function()
        ss_ok = zlib_io.save_savestate_to_file(ss_path)
    end)

    if not ss_ok then
        logging.log_error("Failed to save savestate: " .. tostring(err or "save failed"))
        return false
    end
    logging.log("Savestate saved successfully!")

    -- Step 2: Save bin and metadata
    logging.log("Step 2: Saving bin and metadata...")
    local result = ee_save_bin_and_meta(name, effect_idx)
    logging.log("========================================")
    logging.log(string.format("=== EE_RAW_SAVE %s ===", result and "SUCCESS" or "FAILED"))
    logging.log("========================================")
    return result
end

--------------------------------------------------------------------------------
-- ee_save_bin_edited: Reload + Apply edits + Save bin only
--------------------------------------------------------------------------------

function M.ee_save_bin_edited()
    logging.log("========================================")
    logging.log("=== EE_SAVE_BIN_EDITED - Reload + Apply + Save Bin ===")
    logging.log("========================================")

    local name = EFFECT_EDITOR.session_name
    logging.log(string.format("  session_name: '%s'", name or "nil"))
    if not name or name == "" then
        logging.log_error("No session name set")
        return false
    end

    local effect_idx = EFFECT_EDITOR.effect_id
    logging.log(string.format("  effect_id: %d", effect_idx or 0))
    if effect_idx <= 0 then
        logging.log_error("Effect ID must be > 0")
        return false
    end

    -- Check savestate exists
    local ss_path = config.SAVESTATE_PATH .. name .. ".sstate"
    local ss_win_path = ss_path:gsub("/", "\\")
    local ss_file = io.open(ss_win_path, "rb")
    if not ss_file then
        logging.log_error("No savestate found! Use Raw Save first to create a session.")
        return false
    end
    ss_file:close()

    logging.log("Step 1: Reloading savestate to restore original effect state...")
    if not M.ee_reload(name) then
        logging.log_error("Failed to reload savestate")
        return false
    end

    -- Wait for savestate to fully load, then apply and save
    PCSX.nextTick(function()
        logging.log("Step 2: Applying all edits to memory...")
        if apply_all_edits_fn then
            apply_all_edits_fn(true)  -- silent mode
        end
        logging.log("  All edits applied")

        -- Step 2b: Also apply texture edits if a modified BMP exists
        if texture_ops then
            local tex_reloaded = texture_ops.maybe_reload_texture_before_test()
            if tex_reloaded then
                logging.log("  Texture edits applied from BMP")
            end
        end

        logging.log("Step 3: Saving bin from memory...")
        local bin_path = config.EFFECT_BINS_PATH .. name .. ".bin"

        MemUtils.refresh_mem()
        local base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + effect_idx * 4)
        if base < 0x80000000 or base >= 0x80200000 then
            logging.log_error(string.format("Invalid base 0x%08X for E%03d", base, effect_idx))
            return
        end

        local bin_ok = false
        pcall(function()
            -- Use getMemPtr() directly to avoid readAt/ffi.string Slice issues
            -- Lookup table stores HEADER address directly, no +4 needed
            local mem = PCSX.getMemPtr()
            local offset = base - 0x80000000  -- No +4
            local read_size = config.EFFECT_MAX_SIZE - 4
            local data_str = ffi.string(ffi.cast("char*", mem) + offset, read_size)
            local win_path = bin_path:gsub("/", "\\")
            local outfile = io.open(win_path, "wb")
            if outfile then
                outfile:write(data_str)
                outfile:close()
                bin_ok = true
            end
        end)

        if bin_ok then
            logging.log(string.format("Bin saved to %s", bin_path))
            EFFECT_EDITOR.status_msg = "Bin saved: " .. name
        else
            logging.log_error("Failed to save bin")
        end

        logging.log("========================================")
        logging.log(string.format("=== EE_SAVE_BIN_EDITED %s ===", bin_ok and "SUCCESS" or "FAILED"))
        logging.log("========================================")

        -- Resume emulator after save
        PCSX.resumeEmulator()
    end)

    return true
end

--------------------------------------------------------------------------------
-- ee_save_state_only: Save just the savestate
--------------------------------------------------------------------------------

function M.ee_save_state_only()
    logging.log("========================================")
    logging.log("=== EE_SAVE_STATE_ONLY - Save just savestate ===")
    logging.log("========================================")

    local name = EFFECT_EDITOR.session_name
    logging.log(string.format("  session_name: '%s'", name or "nil"))
    if not name or name == "" then
        logging.log_error("No session name set")
        return false
    end

    local effect_idx = EFFECT_EDITOR.effect_id
    logging.log(string.format("  effect_id: %d", effect_idx or 0))
    if effect_idx <= 0 then
        logging.log_error("Effect ID must be > 0")
        return false
    end

    logging.log(string.format("=== SAVING SAVESTATE ONLY '%s' ===", name))

    -- Pause emulator for safe save
    logging.log("Pausing emulator...")
    PCSX.pauseEmulator()
    logging.log("Emulator paused")

    -- Save savestate
    local ss_path = config.SAVESTATE_PATH .. name .. ".sstate"
    logging.log("Saving savestate to: " .. ss_path)

    local ss_ok = false
    local success, err = pcall(function()
        ss_ok = zlib_io.save_savestate_to_file(ss_path)
    end)

    if not ss_ok then
        logging.log_error("Failed to save savestate: " .. tostring(err or "save failed"))
        return false
    end

    logging.log("========================================")
    logging.log("=== SAVESTATE SAVED ===")
    logging.log("========================================")
    EFFECT_EDITOR.status_msg = "Savestate saved: " .. name
    return true
end

--------------------------------------------------------------------------------
-- ee_save_all: Legacy alias
--------------------------------------------------------------------------------

function M.ee_save_all()
    return M.ee_raw_save()
end

return M
