-- zlib_io.lua
-- Zlib compression and savestate file operations

local ffi = require("ffi")

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local log = function(msg) print("[EE] " .. msg) end
local log_error = function(msg) print("[EE ERROR] " .. msg) end

function M.set_logger(log_fn, error_fn)
    log = log_fn
    log_error = error_fn
end

--------------------------------------------------------------------------------
-- Zlib FFI Bindings
--------------------------------------------------------------------------------

-- Only define once to avoid redefinition errors
pcall(function()
    ffi.cdef[[
        typedef void* gzFile;
        gzFile gzopen(const char* path, const char* mode);
        int gzwrite(gzFile file, const void* buf, unsigned len);
        int gzread(gzFile file, void* buf, unsigned len);
        int gzclose(gzFile file);
        const char* gzerror(gzFile file, int* errnum);
    ]]
end)

local zlib = nil

function M.load_zlib()
    if zlib then return true end
    local success, result = pcall(function()
        -- Try different names for zlib on Windows
        local names = {"zlib1", "zlib", "z"}
        for _, name in ipairs(names) do
            local ok, lib = pcall(ffi.load, name)
            if ok then
                zlib = lib
                log("Loaded zlib as: " .. name)
                return true
            end
        end
        return false
    end)
    return success and result
end

--------------------------------------------------------------------------------
-- Compression Functions
--------------------------------------------------------------------------------

-- Compress data and write to gzip file
function M.gzip_write(path, data, size)
    if not M.load_zlib() then
        log_error("zlib not available - cannot compress savestate")
        return false
    end

    -- Convert path to Windows format for zlib
    local win_path = path:gsub("/", "\\")

    local gz = zlib.gzopen(win_path, "wb9")  -- wb9 = write binary, max compression
    if gz == nil then
        log_error("gzopen failed for: " .. win_path)
        return false
    end

    local written = zlib.gzwrite(gz, data, size)
    zlib.gzclose(gz)

    if written ~= size then
        log_error(string.format("gzwrite wrote %d of %d bytes", written, size))
        return false
    end

    return true
end

--------------------------------------------------------------------------------
-- Savestate File Operations
--------------------------------------------------------------------------------

-- Save a savestate to file (UNCOMPRESSED - this is the working method)
function M.save_savestate_to_file(path)
    log("=== SAVE SAVESTATE TO FILE ===")
    log(string.format("  Path: %s", path))

    if not PCSX.createSaveState then
        log_error("PCSX.createSaveState not available")
        return false
    end

    local win_path = path:gsub("/", "\\")

    -- Check if file already exists and DELETE it first
    local existing = io.open(win_path, "rb")
    if existing then
        local existing_size = existing:seek("end")
        existing:close()
        log(string.format("  Existing file found (size: %d bytes) - DELETING first", existing_size or 0))
        local deleted = os.remove(win_path)
        if deleted then
            log("  File deleted successfully")
        else
            log_error("  WARNING: Could not delete existing file!")
        end
    else
        log("  Creating new file")
    end

    -- Create savestate and write directly to file
    log("  Calling PCSX.createSaveState()...")
    local state = PCSX.createSaveState()
    if not state then
        log_error("Failed to create savestate")
        return false
    end

    -- Log info about the slice (note: size() may return 0 for savestate slices)
    local state_size = 0
    pcall(function() state_size = state:size() end)
    log(string.format("  Savestate slice created, size reported: %d bytes", state_size))

    log("  Opening file for CREATE...")
    local file = Support.File.open(path, "CREATE")
    if not file then
        log_error("Could not create file: " .. path)
        return false
    end
    log("  File handle obtained")

    log("  Writing slice to file...")
    file:writeMoveSlice(state)
    log("  Closing file...")
    file:close()
    log("  File closed")

    -- Verify file was written
    local verify = io.open(win_path, "rb")
    if verify then
        local written_size = verify:seek("end")
        verify:close()
        log(string.format("  VERIFIED: File written, size: %d bytes", written_size or 0))
    else
        log_error("  VERIFICATION FAILED: Cannot read back file!")
        return false
    end

    log("=== SAVESTATE SAVED ===")
    return true
end

-- Alias for compatibility
M.save_compressed_savestate = M.save_savestate_to_file

--------------------------------------------------------------------------------
-- File Detection
--------------------------------------------------------------------------------

-- Check if a file is gzip compressed
function M.is_gzip_file(path)
    -- Convert to Windows path for io.open
    local win_path = path:gsub("/", "\\")
    local f = io.open(win_path, "rb")
    if not f then return false end
    local magic = f:read(2)
    f:close()
    if not magic or #magic < 2 then return false end
    return string.byte(magic, 1) == 0x1f and string.byte(magic, 2) == 0x8b
end

return M
