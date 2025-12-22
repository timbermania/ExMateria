-- commands/file_ops.lua
-- File operations: load, save bin, load bin, delete bin

local ffi = require("ffi")

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local config = nil
local logging = nil
local MemUtils = nil
local load_effect_file_fn = nil
local load_from_memory_fn = nil
local load_from_memory_internal_fn = nil

function M.set_dependencies(cfg, log_module, mem_utils, load_effect_fn, load_mem_fn, load_mem_internal_fn)
    config = cfg
    logging = log_module
    MemUtils = mem_utils
    load_effect_file_fn = load_effect_fn
    load_from_memory_fn = load_mem_fn
    load_from_memory_internal_fn = load_mem_internal_fn
end

--------------------------------------------------------------------------------
-- ee_load: Load E###.BIN from game files
--------------------------------------------------------------------------------

function M.ee_load(num)
    if load_effect_file_fn then
        load_effect_file_fn(string.format("%03d", num))
    end
end

--------------------------------------------------------------------------------
-- ee_mem: Parse effect from memory address
--------------------------------------------------------------------------------

function M.ee_mem(addr)
    if load_from_memory_fn then
        load_from_memory_fn(addr)
    end
end

--------------------------------------------------------------------------------
-- ee_set_mem: Set memory base address
--------------------------------------------------------------------------------

function M.ee_set_mem(addr)
    EFFECT_EDITOR.memory_base = addr
    logging.log(string.format("Memory base set to 0x%08X", addr))
end

--------------------------------------------------------------------------------
-- ee_save_bin: Save effect data from memory to .bin file
--------------------------------------------------------------------------------

function M.ee_save_bin(name)
    if not name or name == "" then
        name = EFFECT_EDITOR.session_name
    end
    if not name or name == "" then
        name = string.format("effect_%03d", EFFECT_EDITOR.effect_id or 0)
    end

    local effect_idx = EFFECT_EDITOR.effect_id or 0
    if effect_idx <= 0 then
        logging.log_error("Set Effect ID first (must be > 0)")
        return false
    end

    -- Look up base address from effect ID
    MemUtils.refresh_mem()
    local base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + effect_idx * 4)
    if base < 0x80000000 or base >= 0x80200000 then
        logging.log_error(string.format("Invalid base address 0x%08X for E%03d. Is the effect loaded?", base, effect_idx))
        return false
    end

    -- Pause emulator for safe memory read
    PCSX.pauseEmulator()

    local path = config.EFFECT_BINS_PATH .. name .. ".bin"
    logging.log(string.format("Saving effect E%03d from 0x%08X to %s", effect_idx, base, path))

    local success, err = pcall(function()
        -- Use getMemPtr() directly to avoid readAt/ffi.string Slice issues
        -- Lookup table stores HEADER address directly, no +4 needed
        local mem = PCSX.getMemPtr()
        local offset = base - 0x80000000  -- No +4
        local read_size = config.EFFECT_MAX_SIZE - 4
        local data_str = ffi.string(ffi.cast("char*", mem) + offset, read_size)
        local win_path = path:gsub("/", "\\")
        local outfile = io.open(win_path, "wb")
        if not outfile then
            error("Could not create file: " .. win_path)
        end
        outfile:write(data_str)
        outfile:close()
    end)

    if success then
        EFFECT_EDITOR.session_name = name
        EFFECT_EDITOR.memory_base = base
        logging.log(string.format("Saved effect to %s (%d bytes)", path, config.EFFECT_MAX_SIZE - 4))
        EFFECT_EDITOR.status_msg = "Saved: " .. name .. ".bin"
        return true
    else
        logging.log_error("Failed to save effect: " .. tostring(err))
        return false
    end
end

--------------------------------------------------------------------------------
-- ee_load_bin: Load .bin file into PSX memory
--------------------------------------------------------------------------------

function M.ee_load_bin(name)
    if not name or name == "" then
        name = EFFECT_EDITOR.session_name
    end
    if not name or name == "" then
        logging.log_error("Usage: ee_load_bin('name')")
        return false
    end

    -- Use current effect_id to determine base address
    local effect_idx = EFFECT_EDITOR.effect_id or 0
    if effect_idx <= 0 then
        logging.log_error("Set Effect ID first (must be > 0)")
        return false
    end

    -- Look up base address from effect ID
    MemUtils.refresh_mem()
    local base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + effect_idx * 4)
    if base < 0x80000000 or base >= 0x80200000 then
        logging.log_error(string.format("Invalid base address 0x%08X for E%03d. Is the effect loaded in game?", base, effect_idx))
        return false
    end

    logging.log(string.format("Using E%03d base from lookup table: 0x%08X", effect_idx, base))
    EFFECT_EDITOR.memory_base = base
    EFFECT_EDITOR.last_captured_effect_id = effect_idx

    local path = config.EFFECT_BINS_PATH .. name .. ".bin"
    logging.log(string.format("Loading effect from %s to 0x%08X", path, base))

    -- Read file
    local file = io.open(path, "rb")
    if not file then
        logging.log_error("Could not open file: " .. path)
        return false
    end
    local data = file:read("*all")
    file:close()

    if not data or #data == 0 then
        logging.log_error("File is empty: " .. path)
        return false
    end

    -- Pause emulator for safe memory write
    PCSX.pauseEmulator()

    -- Write to PSX memory byte by byte
    -- Lookup table stores header address directly, so write to base
    MemUtils.refresh_mem()
    for i = 1, #data do
        MemUtils.write8(base + i - 1, string.byte(data, i))
    end

    EFFECT_EDITOR.session_name = name
    logging.log(string.format("Loaded %d bytes into memory at 0x%08X", #data, base))
    EFFECT_EDITOR.status_msg = "Loaded: " .. name .. ".bin"

    -- Re-parse from memory
    if load_from_memory_internal_fn then
        load_from_memory_internal_fn(base)
    end

    return true
end

--------------------------------------------------------------------------------
-- ee_delete_bin: Delete just the .bin file
--------------------------------------------------------------------------------

function M.ee_delete_bin(name)
    if not name then
        logging.log_error("Usage: ee_delete_bin('name')")
        return false
    end

    local path = config.EFFECT_BINS_PATH .. name .. ".bin"
    local success, err = os.remove(path)

    if success then
        logging.log(string.format("Deleted bin file '%s'", name))
        return true
    else
        logging.log_error(string.format("Could not delete '%s': %s", name, tostring(err)))
        return false
    end
end

return M
