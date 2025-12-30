-- utils/bmp.lua
-- BMP file read/write utilities for 8-bit indexed images

local M = {}

--------------------------------------------------------------------------------
-- Color Conversion Functions
--------------------------------------------------------------------------------

-- BGR555 (PSX) to RGB888 (BMP)
-- Input: 16-bit BGR555 value
-- Output: r, g, b (0-255 range, but only 0-248 actually used due to 5-bit precision)
function M.bgr555_to_rgb888(color16)
    local r = bit.band(color16, 0x1F) * 8
    local g = bit.band(bit.rshift(color16, 5), 0x1F) * 8
    local b = bit.band(bit.rshift(color16, 10), 0x1F) * 8
    return r, g, b
end

-- RGB888 (BMP) to BGR555 (PSX)
-- Input: r, g, b (0-255)
-- Output: 16-bit BGR555 value
function M.rgb888_to_bgr555(r, g, b)
    local r5 = math.floor(r / 8)
    local g5 = math.floor(g / 8)
    local b5 = math.floor(b / 8)
    return bit.bor(r5, bit.lshift(g5, 5), bit.lshift(b5, 10))
end

-- Convert PSX palette data (512 bytes) to RGB palette table
-- Input: string of 512 bytes (256 BGR555 values)
-- Output: table of 256 {r, g, b} entries (1-indexed)
function M.palette_bgr555_to_rgb(palette_data)
    local rgb_palette = {}
    for i = 0, 255 do
        local offset = i * 2
        local lo = palette_data:byte(offset + 1) or 0
        local hi = palette_data:byte(offset + 2) or 0
        local color16 = lo + hi * 256
        local r, g, b = M.bgr555_to_rgb888(color16)
        rgb_palette[i + 1] = {r = r, g = g, b = b}
    end
    return rgb_palette
end

-- Convert RGB palette table to PSX palette data (512 bytes)
-- Input: table of 256 {r, g, b} entries (1-indexed)
-- Output: string of 512 bytes
function M.palette_rgb_to_bgr555(rgb_palette)
    local bytes = {}
    for i = 1, 256 do
        local entry = rgb_palette[i] or {r = 0, g = 0, b = 0}
        local color16 = M.rgb888_to_bgr555(entry.r, entry.g, entry.b)
        -- Handle transparency: PSX uses 0x0000 for transparent
        -- BMP index 0 is typically transparent
        if i == 1 and entry.r == 0 and entry.g == 0 and entry.b == 0 then
            color16 = 0x0000  -- Transparent black
        end
        bytes[#bytes + 1] = string.char(bit.band(color16, 0xFF))
        bytes[#bytes + 1] = string.char(bit.rshift(color16, 8))
    end
    return table.concat(bytes)
end

-- Convert RGB palette table to PSX palette data, preserving original STP bits
-- Input: table of 256 {r, g, b} entries (1-indexed), original_palette (512 bytes string)
-- Output: string of 512 bytes with STP bits preserved from original
function M.palette_rgb_to_bgr555_preserve_stp(rgb_palette, original_palette)
    local bytes = {}
    for i = 1, 256 do
        local entry = rgb_palette[i] or {r = 0, g = 0, b = 0}
        local color16 = M.rgb888_to_bgr555(entry.r, entry.g, entry.b)

        -- Get original STP bit (bit 15) from the original palette
        if original_palette and #original_palette >= i * 2 then
            local offset = (i - 1) * 2
            local orig_lo = original_palette:byte(offset + 1) or 0
            local orig_hi = original_palette:byte(offset + 2) or 0
            local orig_color16 = orig_lo + orig_hi * 256
            local stp_bit = bit.band(orig_color16, 0x8000)  -- Preserve STP bit
            color16 = bit.bor(color16, stp_bit)
        end

        bytes[#bytes + 1] = string.char(bit.band(color16, 0xFF))
        bytes[#bytes + 1] = string.char(bit.rshift(color16, 8))
    end
    return table.concat(bytes)
end

-- Convert RGB palette table to PSX palette data, deriving STP bits from alpha channel
-- This is the NEW workflow where user controls transparency via alpha in their image editor
-- Input: table of 256 {r, g, b, a} entries (1-indexed)
--        Alpha = 255 (fully visible) -> STP=0 (opaque on PSX)
--        Alpha < 255 (any transparency) -> STP=1 (semi-transparent on PSX)
-- Output: string of 512 bytes with STP bits derived from alpha
function M.palette_rgb_to_bgr555_from_alpha(rgb_palette)
    local bytes = {}
    for i = 1, 256 do
        local entry = rgb_palette[i] or {r = 0, g = 0, b = 0, a = 255}
        local color16 = M.rgb888_to_bgr555(entry.r, entry.g, entry.b)

        -- Derive STP bit from alpha:
        -- alpha = 255 (fully opaque in editor) -> STP=0 (opaque on PSX)
        -- alpha < 255 (any transparency) -> STP=1 (semi-transparent on PSX)
        local a = entry.a or 255
        if a < 255 then
            color16 = bit.bor(color16, 0x8000)  -- Set STP bit
        end

        bytes[#bytes + 1] = string.char(bit.band(color16, 0xFF))
        bytes[#bytes + 1] = string.char(bit.rshift(color16, 8))
    end
    return table.concat(bytes)
end

--------------------------------------------------------------------------------
-- BMP File Writing
--------------------------------------------------------------------------------

-- Write a 32-bit little-endian value
local function write_u32(value)
    return string.char(
        bit.band(value, 0xFF),
        bit.band(bit.rshift(value, 8), 0xFF),
        bit.band(bit.rshift(value, 16), 0xFF),
        bit.band(bit.rshift(value, 24), 0xFF)
    )
end

-- Write a 16-bit little-endian value
local function write_u16(value)
    return string.char(
        bit.band(value, 0xFF),
        bit.band(bit.rshift(value, 8), 0xFF)
    )
end

-- Write 8-bit indexed BMP file
-- path: output file path
-- width, height: image dimensions in pixels
-- palette: table of 256 {r, g, b} entries (1-indexed)
-- pixels: string of (width * height) bytes, top-to-bottom row order
-- Returns: true on success, false and error message on failure
function M.write_indexed_bmp(path, width, height, palette, pixels)
    -- Calculate row size with 4-byte padding
    local row_size = math.ceil(width / 4) * 4
    local pixel_data_size = row_size * height

    -- BMP header sizes
    local file_header_size = 14
    local dib_header_size = 40
    local palette_size = 256 * 4  -- BGRA
    local pixel_offset = file_header_size + dib_header_size + palette_size
    local file_size = pixel_offset + pixel_data_size

    local parts = {}

    -- File header (14 bytes)
    parts[#parts + 1] = "BM"                    -- Signature
    parts[#parts + 1] = write_u32(file_size)   -- File size
    parts[#parts + 1] = write_u32(0)           -- Reserved
    parts[#parts + 1] = write_u32(pixel_offset) -- Pixel data offset

    -- DIB header (BITMAPINFOHEADER, 40 bytes)
    parts[#parts + 1] = write_u32(40)          -- Header size
    parts[#parts + 1] = write_u32(width)       -- Width (signed, but positive)
    parts[#parts + 1] = write_u32(height)      -- Height (positive = bottom-up)
    parts[#parts + 1] = write_u16(1)           -- Planes
    parts[#parts + 1] = write_u16(8)           -- Bits per pixel
    parts[#parts + 1] = write_u32(0)           -- Compression (none)
    parts[#parts + 1] = write_u32(pixel_data_size) -- Image size
    parts[#parts + 1] = write_u32(0)           -- X pixels per meter
    parts[#parts + 1] = write_u32(0)           -- Y pixels per meter
    parts[#parts + 1] = write_u32(256)         -- Colors used
    parts[#parts + 1] = write_u32(256)         -- Important colors

    -- Color table (1024 bytes: 256 x BGRA)
    for i = 1, 256 do
        local entry = palette[i] or {r = 0, g = 0, b = 0}
        parts[#parts + 1] = string.char(
            entry.b or 0,  -- Blue
            entry.g or 0,  -- Green
            entry.r or 0,  -- Red
            0              -- Reserved (alpha, unused)
        )
    end

    -- Pixel data (bottom-up order, padded rows)
    local padding_bytes = string.rep("\0", row_size - width)
    for y = height - 1, 0, -1 do  -- Bottom to top
        local row_start = y * width + 1
        local row_end = row_start + width - 1
        local row_data = pixels:sub(row_start, row_end)
        -- Pad row if it's shorter than expected (shouldn't happen normally)
        if #row_data < width then
            row_data = row_data .. string.rep("\0", width - #row_data)
        end
        parts[#parts + 1] = row_data
        if row_size > width then
            parts[#parts + 1] = padding_bytes
        end
    end

    -- Write to file
    local file = io.open(path, "wb")
    if not file then
        return false, "Could not open file for writing: " .. path
    end

    file:write(table.concat(parts))
    file:close()

    return true
end

--------------------------------------------------------------------------------
-- BMP File Reading
--------------------------------------------------------------------------------

-- Read a 32-bit little-endian value from string
local function read_u32(data, offset)
    local b0 = data:byte(offset + 1) or 0
    local b1 = data:byte(offset + 2) or 0
    local b2 = data:byte(offset + 3) or 0
    local b3 = data:byte(offset + 4) or 0
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

-- Read a 16-bit little-endian value from string
local function read_u16(data, offset)
    local b0 = data:byte(offset + 1) or 0
    local b1 = data:byte(offset + 2) or 0
    return b0 + b1 * 256
end

-- Read a signed 32-bit little-endian value from string
local function read_s32(data, offset)
    local value = read_u32(data, offset)
    if value >= 0x80000000 then
        value = value - 0x100000000
    end
    return value
end

-- Find closest palette index for an RGB color
local function find_closest_palette_index(r, g, b, palette)
    local best_index = 0
    local best_dist = 999999

    for i = 1, 256 do
        local p = palette[i]
        local dr = r - p.r
        local dg = g - p.g
        local db = b - p.b
        local dist = dr*dr + dg*dg + db*db
        if dist < best_dist then
            best_dist = dist
            best_index = i - 1  -- 0-indexed
        end
        if dist == 0 then break end  -- Exact match
    end

    return best_index
end

-- Read BMP file (8-bit indexed or 24-bit RGB)
-- For 24-bit: quantizes to provided palette or builds one
-- path: input file path
-- original_palette: optional, palette to quantize 24-bit images to
-- Returns: width, height, palette (table of 256 {r,g,b}), pixels (string)
-- Or: nil, error_message on failure
function M.read_indexed_bmp(path, original_palette)
    local file = io.open(path, "rb")
    if not file then
        return nil, "Could not open file: " .. path
    end

    local data = file:read("*all")
    file:close()

    if #data < 54 then
        return nil, "File too small to be a valid BMP"
    end

    -- Verify signature
    if data:sub(1, 2) ~= "BM" then
        return nil, "Not a BMP file (invalid signature)"
    end

    -- Read file header
    local pixel_offset = read_u32(data, 10)

    -- Read DIB header
    local dib_header_size = read_u32(data, 14)
    if dib_header_size < 40 then
        return nil, "Unsupported BMP header type"
    end

    local width = read_s32(data, 18)
    local height = read_s32(data, 22)
    local bpp = read_u16(data, 28)
    local compression = read_u32(data, 30)

    if compression ~= 0 then
        return nil, "Compressed BMPs not supported"
    end

    if width <= 0 then
        return nil, "Invalid width"
    end

    -- Handle negative height (top-down image)
    local top_down = false
    if height < 0 then
        height = -height
        top_down = true
    end

    local palette = {}
    local pixels_table = {}

    if bpp == 8 then
        -- 8-bit indexed: read palette and pixel indices directly
        local palette_offset = 14 + dib_header_size

        for i = 0, 255 do
            local entry_offset = palette_offset + i * 4
            local b = data:byte(entry_offset + 1) or 0
            local g = data:byte(entry_offset + 2) or 0
            local r = data:byte(entry_offset + 3) or 0
            local a = data:byte(entry_offset + 4) or 255  -- Read palette alpha
            palette[i + 1] = {r = r, g = g, b = b, a = a}
        end

        -- Read pixel data
        local row_size = math.ceil(width / 4) * 4

        if top_down then
            for y = 0, height - 1 do
                local row_offset = pixel_offset + y * row_size
                for x = 0, width - 1 do
                    pixels_table[y * width + x + 1] = string.char(data:byte(row_offset + x + 1) or 0)
                end
            end
        else
            for y = 0, height - 1 do
                local src_y = height - 1 - y
                local row_offset = pixel_offset + src_y * row_size
                for x = 0, width - 1 do
                    pixels_table[y * width + x + 1] = string.char(data:byte(row_offset + x + 1) or 0)
                end
            end
        end

    elseif bpp == 24 then
        -- 24-bit RGB: quantize to original palette
        if not original_palette then
            return nil, "24-bit BMP requires original palette for quantization"
        end
        palette = original_palette

        -- Row size for 24-bit (3 bytes per pixel, padded to 4 bytes)
        local row_size = math.ceil(width * 3 / 4) * 4

        if top_down then
            for y = 0, height - 1 do
                local row_offset = pixel_offset + y * row_size
                for x = 0, width - 1 do
                    local px_offset = row_offset + x * 3
                    local b = data:byte(px_offset + 1) or 0
                    local g = data:byte(px_offset + 2) or 0
                    local r = data:byte(px_offset + 3) or 0
                    local idx = find_closest_palette_index(r, g, b, palette)
                    pixels_table[y * width + x + 1] = string.char(idx)
                end
            end
        else
            for y = 0, height - 1 do
                local src_y = height - 1 - y
                local row_offset = pixel_offset + src_y * row_size
                for x = 0, width - 1 do
                    local px_offset = row_offset + x * 3
                    local b = data:byte(px_offset + 1) or 0
                    local g = data:byte(px_offset + 2) or 0
                    local r = data:byte(px_offset + 3) or 0
                    local idx = find_closest_palette_index(r, g, b, palette)
                    pixels_table[y * width + x + 1] = string.char(idx)
                end
            end
        end

    else
        return nil, string.format("Unsupported BMP format: %d-bit (need 8 or 24)", bpp)
    end

    local pixels = table.concat(pixels_table)

    return width, height, palette, pixels
end

--------------------------------------------------------------------------------
-- TGA File Writing (for RGBA export with alpha)
--------------------------------------------------------------------------------

-- Write 32-bit RGBA TGA file
-- This format supports alpha channel which we use to encode STP bits
-- path: output file path
-- width, height: image dimensions
-- pixels: table of {r, g, b, a} values in row-major order (1-indexed, top-to-bottom)
-- Returns: true on success, false and error message on failure
function M.write_rgba_tga(path, width, height, pixels)
    local parts = {}

    -- TGA Header (18 bytes)
    parts[#parts + 1] = string.char(0)      -- ID length
    parts[#parts + 1] = string.char(0)      -- Color map type (0 = no color map)
    parts[#parts + 1] = string.char(2)      -- Image type (2 = uncompressed true-color)
    parts[#parts + 1] = string.rep("\0", 5) -- Color map specification (unused)
    parts[#parts + 1] = write_u16(0)        -- X origin
    parts[#parts + 1] = write_u16(0)        -- Y origin
    parts[#parts + 1] = write_u16(width)    -- Width
    parts[#parts + 1] = write_u16(height)   -- Height
    parts[#parts + 1] = string.char(32)     -- Bits per pixel (32 = RGBA)
    parts[#parts + 1] = string.char(0x28)   -- Image descriptor (0x20 = top-left origin, 0x08 = 8 alpha bits)

    -- Pixel data (BGRA order, top-to-bottom due to origin flag)
    for i = 1, #pixels do
        local p = pixels[i]
        parts[#parts + 1] = string.char(p.b or 0, p.g or 0, p.r or 0, p.a or 255)
    end

    -- Write to file
    local file = io.open(path, "wb")
    if not file then
        return false, "Could not open file for writing: " .. path
    end

    file:write(table.concat(parts))
    file:close()

    return true
end

-- Write indexed BMP from PSX data with alpha in palette
-- This exports the texture with STP bits encoded as palette alpha
-- palette_data: 512-byte PSX BGR555 palette
-- width, height: dimensions
-- pixels: pixel indices
-- Returns: table of RGBA pixels for write_rgba_tga
function M.psx_texture_to_rgba_pixels(palette_data, width, height, pixel_data)
    local rgba_pixels = {}

    for i = 1, #pixel_data do
        local idx = pixel_data:byte(i)
        local offset = idx * 2
        local lo = palette_data:byte(offset + 1) or 0
        local hi = palette_data:byte(offset + 2) or 0
        local color16 = lo + hi * 256

        -- Extract RGB from BGR555
        local r = bit.band(color16, 0x1F) * 8
        local g = bit.band(bit.rshift(color16, 5), 0x1F) * 8
        local b = bit.band(bit.rshift(color16, 10), 0x1F) * 8

        -- Extract STP bit (bit 15) and convert to alpha
        -- STP=0 (opaque) -> alpha=255
        -- STP=1 (semi-transparent) -> alpha=128 (visible but marked as semi-transparent)
        local stp = bit.band(color16, 0x8000) ~= 0
        local a = stp and 128 or 255

        rgba_pixels[i] = {r = r, g = g, b = b, a = a}
    end

    return rgba_pixels
end

-- Convert PSX "indexed with sub-palette" format (depth_flag=1) to RGBA pixels
-- This is NOT standard 4bpp! Format: 1 byte = 1 pixel
--   Low nibble (bits 0-3) = color index within sub-palette (0-15)
--   High nibble (bits 4-7) = sub-palette selector (0-15)
-- palette_data: 512 bytes = 16 sub-palettes × 16 colors × 2 bytes per color
-- width, height: dimensions (in pixels)
-- pixel_data: raw pixel data (1 byte per pixel)
-- Returns: table of RGBA pixels
function M.psx_texture_to_rgba_pixels_4bpp(palette_data, width, height, pixel_data)
    local rgba_pixels = {}

    for i = 1, #pixel_data do
        local byte = pixel_data:byte(i)
        local color_idx = bit.band(byte, 0x0F)      -- bits 0-3: color within sub-palette
        local sub_palette = bit.rshift(byte, 4)     -- bits 4-7: which sub-palette

        -- Look up color in the correct sub-palette
        -- Each sub-palette is 32 bytes (16 colors × 2 bytes per color)
        local offset = sub_palette * 32 + color_idx * 2
        local lo = palette_data:byte(offset + 1) or 0
        local hi = palette_data:byte(offset + 2) or 0
        local color16 = lo + hi * 256

        -- Extract RGB from BGR555
        local r = bit.band(color16, 0x1F) * 8
        local g = bit.band(bit.rshift(color16, 5), 0x1F) * 8
        local b = bit.band(bit.rshift(color16, 10), 0x1F) * 8

        -- Extract STP bit (bit 15) for alpha
        local stp = bit.band(color16, 0x8000) ~= 0
        local a = stp and 128 or 255

        rgba_pixels[i] = {r = r, g = g, b = b, a = a}
    end

    return rgba_pixels
end

--------------------------------------------------------------------------------
-- TGA File Reading
--------------------------------------------------------------------------------

-- Read 32-bit RGBA TGA file
-- Returns: width, height, pixels (table of {r, g, b, a})
-- Or: nil, error_message on failure
function M.read_rgba_tga(path)
    local file = io.open(path, "rb")
    if not file then
        return nil, "Could not open file: " .. path
    end

    local data = file:read("*all")
    file:close()

    if #data < 18 then
        return nil, "File too small to be a valid TGA"
    end

    -- Parse TGA header
    local id_length = data:byte(1)
    local color_map_type = data:byte(2)
    local image_type = data:byte(3)
    -- Skip color map spec (5 bytes)
    local x_origin = data:byte(9) + data:byte(10) * 256
    local y_origin = data:byte(11) + data:byte(12) * 256
    local width = data:byte(13) + data:byte(14) * 256
    local height = data:byte(15) + data:byte(16) * 256
    local bpp = data:byte(17)
    local descriptor = data:byte(18)

    -- We only support uncompressed true-color (type 2) with 32bpp
    if image_type ~= 2 then
        return nil, string.format("Unsupported TGA type: %d (need type 2)", image_type)
    end
    if bpp ~= 32 then
        return nil, string.format("Unsupported TGA depth: %d-bit (need 32-bit)", bpp)
    end

    -- Check origin (bit 5 of descriptor: 0=bottom-left, 1=top-left)
    local top_down = bit.band(descriptor, 0x20) ~= 0

    -- Skip ID field
    local pixel_offset = 18 + id_length

    -- Read pixels (BGRA order in TGA)
    local pixels = {}
    local expected_size = width * height * 4

    if #data < pixel_offset + expected_size then
        return nil, "TGA file truncated"
    end

    for y = 0, height - 1 do
        local src_y = top_down and y or (height - 1 - y)
        for x = 0, width - 1 do
            local offset = pixel_offset + (src_y * width + x) * 4
            local b = data:byte(offset + 1) or 0
            local g = data:byte(offset + 2) or 0
            local r = data:byte(offset + 3) or 0
            local a = data:byte(offset + 4) or 255
            pixels[y * width + x + 1] = {r = r, g = g, b = b, a = a}
        end
    end

    return width, height, pixels
end

-- Build indexed palette from RGBA pixels with alpha support
-- Returns: palette (table of {r, g, b, a}), indexed_pixels (string of indices)
-- If more than 256 unique colors, uses simple quantization
function M.quantize_rgba_to_indexed(width, height, rgba_pixels, silent)
    -- Build color histogram (including alpha as part of color identity)
    -- Use string key for color+alpha combination
    local color_counts = {}
    local unique_colors = {}

    for i, p in ipairs(rgba_pixels) do
        -- Quantize to 5-bit per channel (PSX limitation) for color matching
        -- But preserve original alpha distinction
        local r5 = math.floor(p.r / 8)
        local g5 = math.floor(p.g / 8)
        local b5 = math.floor(p.b / 8)
        -- Alpha: just distinguish "opaque" (255) from "semi-transparent" (anything else)
        local a_key = p.a < 255 and 1 or 0

        local key = string.format("%d:%d:%d:%d", r5, g5, b5, a_key)

        if not color_counts[key] then
            color_counts[key] = {
                count = 0,
                r = r5 * 8,  -- Store as 8-bit for output
                g = g5 * 8,
                b = b5 * 8,
                a = p.a < 255 and 128 or 255  -- Normalize alpha
            }
            unique_colors[#unique_colors + 1] = key
        end
        color_counts[key].count = color_counts[key].count + 1
    end

    -- Sort by frequency (most common first)
    table.sort(unique_colors, function(a, b)
        return color_counts[a].count > color_counts[b].count
    end)

    -- Take top 256 colors for palette
    local palette = {}
    local color_to_index = {}

    for i = 1, math.min(256, #unique_colors) do
        local key = unique_colors[i]
        local c = color_counts[key]
        palette[i] = {r = c.r, g = c.g, b = c.b, a = c.a}
        color_to_index[key] = i - 1  -- 0-indexed
    end

    -- Pad palette to 256 entries
    while #palette < 256 do
        palette[#palette + 1] = {r = 0, g = 0, b = 0, a = 255}
    end

    -- Map pixels to palette indices
    local indexed_bytes = {}
    for i, p in ipairs(rgba_pixels) do
        local r5 = math.floor(p.r / 8)
        local g5 = math.floor(p.g / 8)
        local b5 = math.floor(p.b / 8)
        local a_key = p.a < 255 and 1 or 0
        local key = string.format("%d:%d:%d:%d", r5, g5, b5, a_key)

        local idx = color_to_index[key]
        if not idx then
            -- Color not in palette (>256 colors case) - find closest
            idx = M.find_closest_palette_index_rgba(p.r, p.g, p.b, p.a, palette)
        end
        indexed_bytes[i] = string.char(idx)
    end

    return palette, table.concat(indexed_bytes)
end

-- Find closest palette index for an RGBA color
function M.find_closest_palette_index_rgba(r, g, b, a, palette)
    local best_index = 0
    local best_dist = 999999999
    local target_stp = a < 255

    for i = 1, 256 do
        local p = palette[i]
        local dr = r - p.r
        local dg = g - p.g
        local db = b - p.b
        -- Heavily penalize alpha mismatch (STP is important!)
        local palette_stp = p.a < 255
        local da = (target_stp ~= palette_stp) and 10000 or 0

        local dist = dr*dr + dg*dg + db*db + da
        if dist < best_dist then
            best_dist = dist
            best_index = i - 1
        end
        if dist == 0 then break end
    end

    return best_index
end

--------------------------------------------------------------------------------
-- File Utilities
--------------------------------------------------------------------------------

-- Check if file exists
function M.file_exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

-- Compute a simple hash/fingerprint of file content
-- Uses size + sampled bytes to detect changes without reading entire file
function M.compute_file_fingerprint(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    -- Get file size
    local size = file:seek("end")
    file:seek("set", 0)

    -- Read first 256 bytes
    local head = file:read(256) or ""

    -- Read last 256 bytes (if file is large enough)
    local tail = ""
    if size > 512 then
        file:seek("set", size - 256)
        tail = file:read(256) or ""
    end

    file:close()

    -- Combine into fingerprint: size + hash of head + hash of tail
    local hash = size
    for i = 1, #head do
        hash = (hash * 31 + head:byte(i)) % 0x100000000
    end
    for i = 1, #tail do
        hash = (hash * 31 + tail:byte(i)) % 0x100000000
    end

    return hash
end

-- Read entire file content (for small files like textures)
function M.read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*all")
    file:close()
    return content
end

return M
