-- bit.lua - Compatibility shim for bit module
-- For Lua 5.3+ where bit32 was deprecated in favor of native operators

local M = {}

-- Check if we can use native Lua 5.3+ operators
local function has_native_ops()
    local fn, err = load("return 1 & 2")
    return fn ~= nil
end

if has_native_ops() then
    -- Lua 5.3+ with native bitwise operators
    M.band = load("return function(a, b) return a & b end")()
    M.bor = load("return function(a, b) return a | b end")()
    M.bxor = load("return function(a, b) return a ~ b end")()
    M.bnot = load("return function(a) return ~a end")()
    M.lshift = load("return function(a, b) return a << b end")()
    M.rshift = load("return function(a, b) return a >> b end")()
    -- Arithmetic shift right (preserves sign)
    M.arshift = function(x, n)
        if x >= 0x80000000 then
            -- Negative number (when treated as signed 32-bit)
            return ((x >> n) | (0xFFFFFFFF << (32 - n))) & 0xFFFFFFFF
        else
            return x >> n
        end
    end
elseif bit32 then
    -- Lua 5.2 with bit32 library
    M.band = bit32.band
    M.bor = bit32.bor
    M.bxor = bit32.bxor
    M.bnot = bit32.bnot
    M.lshift = bit32.lshift
    M.rshift = bit32.rshift
    M.arshift = bit32.arshift
else
    error("No bitwise operation support found")
end

return M
