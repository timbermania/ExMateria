-- ui/curve_generators.lua
-- Generator functions for creating 160-byte animation curves
-- All generators now support timing (start_frame, end_frame) and value range parameters

local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local CURVE_LENGTH = 160
local PI = math.pi

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

local function clamp(val, min_val, max_val)
    return math.max(min_val, math.min(max_val, val))
end

local function floor(val)
    return math.floor(val)
end

--------------------------------------------------------------------------------
-- Core Generator: Linear
--------------------------------------------------------------------------------

-- Linear interpolation from start_val to end_val over [start_frame, end_frame)
-- Frames before start_frame hold start_val, frames at/after end_frame hold end_val
function M.linear(start_frame, end_frame, start_val, end_val)
    local curve = {}
    start_val = clamp(start_val, 0, 255)
    end_val = clamp(end_val, 0, 255)

    for i = 1, CURVE_LENGTH do
        local frame = i - 1  -- 0-indexed frame
        if frame < start_frame then
            curve[i] = floor(start_val)
        elseif frame >= end_frame then
            curve[i] = floor(end_val)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            curve[i] = floor(start_val + (end_val - start_val) * t)
        end
    end
    return curve
end

--------------------------------------------------------------------------------
-- Easing Functions
--------------------------------------------------------------------------------

-- Ease-in: slow start, accelerates toward end
-- power: 1=linear, 2=quadratic, 3=cubic, etc.
function M.ease_in(start_frame, end_frame, start_val, end_val, power)
    local curve = {}
    start_val = clamp(start_val, 0, 255)
    end_val = clamp(end_val, 0, 255)
    power = power or 2.0

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = floor(start_val)
        elseif frame >= end_frame then
            curve[i] = floor(end_val)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local eased = t ^ power
            curve[i] = floor(start_val + (end_val - start_val) * eased)
        end
    end
    return curve
end

-- Ease-out: fast start, decelerates toward end
function M.ease_out(start_frame, end_frame, start_val, end_val, power)
    local curve = {}
    start_val = clamp(start_val, 0, 255)
    end_val = clamp(end_val, 0, 255)
    power = power or 2.0

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = floor(start_val)
        elseif frame >= end_frame then
            curve[i] = floor(end_val)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local eased = 1 - (1 - t) ^ power
            curve[i] = floor(start_val + (end_val - start_val) * eased)
        end
    end
    return curve
end

-- S-Curve (ease-in-out): slow start and end, fast middle
function M.s_curve(start_frame, end_frame, start_val, end_val, power)
    local curve = {}
    start_val = clamp(start_val, 0, 255)
    end_val = clamp(end_val, 0, 255)
    power = power or 2.0

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = floor(start_val)
        elseif frame >= end_frame then
            curve[i] = floor(end_val)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local eased
            if t < 0.5 then
                eased = (2 ^ (power - 1)) * (t ^ power)
            else
                eased = 1 - (((-2 * t + 2) ^ power) / 2)
            end
            curve[i] = floor(start_val + (end_val - start_val) * eased)
        end
    end
    return curve
end

--------------------------------------------------------------------------------
-- Exponential Functions
--------------------------------------------------------------------------------

-- Exponential ease-in: very slow start, explosive end
function M.exponential_in(start_frame, end_frame, start_val, end_val, strength)
    local curve = {}
    start_val = clamp(start_val, 0, 255)
    end_val = clamp(end_val, 0, 255)
    strength = strength or 10

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = floor(start_val)
        elseif frame >= end_frame then
            curve[i] = floor(end_val)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local eased = (t == 0) and 0 or (2 ^ (strength * (t - 1)))
            curve[i] = floor(start_val + (end_val - start_val) * eased)
        end
    end
    return curve
end

-- Exponential ease-out: explosive start, very slow end
function M.exponential_out(start_frame, end_frame, start_val, end_val, strength)
    local curve = {}
    start_val = clamp(start_val, 0, 255)
    end_val = clamp(end_val, 0, 255)
    strength = strength or 10

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = floor(start_val)
        elseif frame >= end_frame then
            curve[i] = floor(end_val)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local eased = (t == 1) and 1 or (1 - 2 ^ (-strength * t))
            curve[i] = floor(start_val + (end_val - start_val) * eased)
        end
    end
    return curve
end

--------------------------------------------------------------------------------
-- Oscillating Functions
--------------------------------------------------------------------------------

-- Sine wave oscillation between min_val and max_val
-- cycles: number of complete cycles within the frame range
-- phase: phase offset (0-1, where 1 = full cycle)
function M.sine_wave(start_frame, end_frame, min_val, max_val, cycles, phase)
    local curve = {}
    min_val = clamp(min_val, 0, 255)
    max_val = clamp(max_val, 0, 255)
    cycles = cycles or 1
    phase = phase or 0

    local amplitude = (max_val - min_val) / 2
    local offset = (max_val + min_val) / 2

    -- Calculate value at start_frame for holding before
    local start_t = phase
    local start_wave_val = offset + amplitude * math.sin(start_t * 2 * PI)

    -- Calculate value at end_frame for holding after
    local end_t = cycles + phase
    local end_wave_val = offset + amplitude * math.sin(end_t * 2 * PI)

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = clamp(floor(start_wave_val), 0, 255)
        elseif frame >= end_frame then
            curve[i] = clamp(floor(end_wave_val), 0, 255)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local wave_t = t * cycles + phase
            local v = offset + amplitude * math.sin(wave_t * 2 * PI)
            curve[i] = clamp(floor(v), 0, 255)
        end
    end
    return curve
end

-- Triangle wave oscillation between min_val and max_val
function M.triangle_wave(start_frame, end_frame, min_val, max_val, cycles, phase)
    local curve = {}
    min_val = clamp(min_val, 0, 255)
    max_val = clamp(max_val, 0, 255)
    cycles = cycles or 1
    phase = phase or 0

    local amplitude = (max_val - min_val) / 2
    local offset = (max_val + min_val) / 2

    local function triangle_value(cycle_pos)
        local pos = cycle_pos % 1
        local triangle
        if pos < 0.25 then
            triangle = pos * 4  -- 0 to 1 over first quarter
        elseif pos < 0.75 then
            triangle = 2 - pos * 4  -- 1 to -1 over middle half
        else
            triangle = pos * 4 - 4  -- -1 to 0 over last quarter
        end
        return offset + amplitude * triangle
    end

    -- Values for holding
    local start_wave_val = triangle_value(phase)
    local end_wave_val = triangle_value(cycles + phase)

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = clamp(floor(start_wave_val), 0, 255)
        elseif frame >= end_frame then
            curve[i] = clamp(floor(end_wave_val), 0, 255)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local wave_t = t * cycles + phase
            local v = triangle_value(wave_t)
            curve[i] = clamp(floor(v), 0, 255)
        end
    end
    return curve
end

-- Sawtooth wave (repeating ramps from min to max)
-- teeth: number of complete ramps within the frame range
function M.sawtooth(start_frame, end_frame, min_val, max_val, teeth)
    local curve = {}
    min_val = clamp(min_val, 0, 255)
    max_val = clamp(max_val, 0, 255)
    teeth = teeth or 1

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = floor(min_val)
        elseif frame >= end_frame then
            curve[i] = floor(max_val)
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local tooth_pos = (t * teeth) % 1  -- Position within current tooth
            curve[i] = floor(min_val + (max_val - min_val) * tooth_pos)
        end
    end
    return curve
end

-- Pulse/square wave
-- pulses: number of complete pulses within the frame range
-- duty_cycle: fraction of each pulse that is high (0-1)
function M.pulse(start_frame, end_frame, low_val, high_val, pulses, duty_cycle)
    local curve = {}
    low_val = clamp(floor(low_val), 0, 255)
    high_val = clamp(floor(high_val), 0, 255)
    pulses = pulses or 1
    duty_cycle = clamp(duty_cycle or 0.5, 0, 1)

    for i = 1, CURVE_LENGTH do
        local frame = i - 1
        if frame < start_frame then
            curve[i] = low_val
        elseif frame >= end_frame then
            curve[i] = low_val
        else
            local t = (frame - start_frame) / (end_frame - start_frame)
            local pulse_pos = (t * pulses) % 1  -- Position within current pulse
            if pulse_pos < duty_cycle then
                curve[i] = high_val
            else
                curve[i] = low_val
            end
        end
    end
    return curve
end

--------------------------------------------------------------------------------
-- Simple Generators
--------------------------------------------------------------------------------

-- Constant value across all frames
function M.constant(value)
    local curve = {}
    value = clamp(floor(value), 0, 255)
    for i = 1, CURVE_LENGTH do
        curve[i] = value
    end
    return curve
end

--------------------------------------------------------------------------------
-- Curve Manipulation Utilities
--------------------------------------------------------------------------------

-- Invert curve (255 - each value)
function M.invert(curve)
    local result = {}
    for i = 1, CURVE_LENGTH do
        result[i] = 255 - (curve[i] or 0)
    end
    return result
end

-- Reverse curve (flip horizontally)
function M.reverse(curve)
    local result = {}
    for i = 1, CURVE_LENGTH do
        result[i] = curve[CURVE_LENGTH - i + 1] or 0
    end
    return result
end

-- Scale curve values around midpoint
function M.scale(curve, factor, midpoint)
    midpoint = midpoint or 128
    local result = {}
    for i = 1, CURVE_LENGTH do
        local v = midpoint + (curve[i] - midpoint) * factor
        result[i] = clamp(floor(v), 0, 255)
    end
    return result
end

-- Shift all values by offset
function M.shift(curve, offset)
    local result = {}
    for i = 1, CURVE_LENGTH do
        result[i] = clamp(curve[i] + offset, 0, 255)
    end
    return result
end

-- Deep copy a curve
function M.copy(curve)
    local result = {}
    for i = 1, CURVE_LENGTH do
        result[i] = curve[i] or 0
    end
    return result
end

return M
