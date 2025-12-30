-- memory_utils.lua
-- Read/write helpers for PSX memory and file data

local M = {}

-- Cache memory pointer (refresh if needed)
local mem = nil

function M.refresh_mem()
    mem = PCSX.getMemPtr()
end

-- Ensure mem is valid
local function ensure_mem()
    if not mem then M.refresh_mem() end
end

--------------------------------------------------------------------------------
-- PSX Memory Read/Write (addresses like 0x801XXXXX)
--------------------------------------------------------------------------------

function M.read8(addr)
    ensure_mem()
    return mem[addr - 0x80000000]
end

function M.read16(addr)
    ensure_mem()
    local o = addr - 0x80000000
    return mem[o] + mem[o + 1] * 256
end

function M.read16s(addr)
    local v = M.read16(addr)
    if v >= 32768 then v = v - 65536 end
    return v
end

function M.read32(addr)
    ensure_mem()
    local o = addr - 0x80000000
    return mem[o] + mem[o+1]*256 + mem[o+2]*65536 + mem[o+3]*16777216
end

function M.write8(addr, val)
    ensure_mem()
    mem[addr - 0x80000000] = val % 256
end

function M.write16(addr, val)
    ensure_mem()
    local o = addr - 0x80000000
    -- Handle signed values (convert negative to unsigned)
    if val < 0 then val = val + 65536 end
    mem[o] = val % 256
    mem[o + 1] = math.floor(val / 256) % 256
end

function M.write32(addr, val)
    ensure_mem()
    local o = addr - 0x80000000
    mem[o] = val % 256
    mem[o + 1] = math.floor(val / 256) % 256
    mem[o + 2] = math.floor(val / 65536) % 256
    mem[o + 3] = math.floor(val / 16777216) % 256
end

-- Read N bytes from PSX memory into a table
function M.read_bytes(addr, count)
    ensure_mem()
    local result = {}
    local base = addr - 0x80000000
    for i = 0, count - 1 do
        result[i + 1] = mem[base + i]
    end
    return result
end

-- Write table of bytes to PSX memory
function M.write_bytes(addr, bytes)
    ensure_mem()
    local base = addr - 0x80000000
    for i, b in ipairs(bytes) do
        mem[base + i - 1] = b % 256
    end
end

--------------------------------------------------------------------------------
-- File/Buffer Read (for parsing loaded files)
--------------------------------------------------------------------------------

-- Read from string buffer (1-indexed like Lua strings)
function M.buf_read8(data, offset)
    return string.byte(data, offset + 1) or 0
end

function M.buf_read16(data, offset)
    local lo = string.byte(data, offset + 1) or 0
    local hi = string.byte(data, offset + 2) or 0
    return lo + hi * 256
end

function M.buf_read16s(data, offset)
    local v = M.buf_read16(data, offset)
    if v >= 32768 then v = v - 65536 end
    return v
end

function M.buf_read32(data, offset)
    local b0 = string.byte(data, offset + 1) or 0
    local b1 = string.byte(data, offset + 2) or 0
    local b2 = string.byte(data, offset + 3) or 0
    local b3 = string.byte(data, offset + 4) or 0
    return b0 + b1*256 + b2*65536 + b3*16777216
end

--------------------------------------------------------------------------------
-- File I/O
--------------------------------------------------------------------------------

-- Load binary file, return contents as string
function M.load_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, "Could not open file: " .. path
    end
    local data = file:read("*all")
    file:close()
    return data
end

-- Save binary data to file
function M.save_file(path, data)
    local file = io.open(path, "wb")
    if not file then
        return false, "Could not create file: " .. path
    end
    file:write(data)
    file:close()
    return true
end

-- Build binary string from table of bytes
function M.bytes_to_string(bytes)
    local chars = {}
    for i, b in ipairs(bytes) do
        chars[i] = string.char(b % 256)
    end
    return table.concat(chars)
end

--------------------------------------------------------------------------------
-- Unified Reader Abstraction
-- Allows same parsing code to work with file buffers OR PSX memory
--------------------------------------------------------------------------------

-- Create a buffer reader (for file data)
-- All offsets are relative to base_offset
function M.buffer_reader(data, base_offset)
    base_offset = base_offset or 0
    return {
        source = "buffer",
        read8 = function(offset) return M.buf_read8(data, base_offset + offset) end,
        read16 = function(offset) return M.buf_read16(data, base_offset + offset) end,
        read16s = function(offset) return M.buf_read16s(data, base_offset + offset) end,
        read32 = function(offset) return M.buf_read32(data, base_offset + offset) end,
    }
end

-- Create a memory reader (for PSX RAM)
-- All offsets are relative to base_addr
function M.memory_reader(base_addr)
    return {
        source = "memory",
        read8 = function(offset) return M.read8(base_addr + offset) end,
        read16 = function(offset) return M.read16(base_addr + offset) end,
        read16s = function(offset) return M.read16s(base_addr + offset) end,
        read32 = function(offset) return M.read32(base_addr + offset) end,
    }
end

return M
