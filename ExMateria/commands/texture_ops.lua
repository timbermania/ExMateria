-- commands/texture_ops.lua
-- Texture export/import operations for live editing with Krita

local M = {}

-- Load BMP utilities
local bmp = require("bmp")

-- Load platform utilities
local platform = require("platform")

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local config = nil
local logging = nil
local MemUtils = nil

function M.set_dependencies(cfg, log_module, mem_utils)
    config = cfg
    logging = log_module
    MemUtils = mem_utils
end

--------------------------------------------------------------------------------
-- ImageMagick Integration
--------------------------------------------------------------------------------

-- Check if ImageMagick is available (cached)
local imagemagick_path = nil
local imagemagick_checked = false

local function get_imagemagick_path()
    if imagemagick_checked then
        return imagemagick_path
    end
    imagemagick_checked = true

    -- Check common Windows installation paths
    local paths = {
        "C:\\Program Files\\ImageMagick-7.1.2-Q16-HDRI\\magick.exe",
        "C:\\Program Files\\ImageMagick-7.1.1-Q16-HDRI\\magick.exe",
        "C:\\Program Files\\ImageMagick-7.1.0-Q16-HDRI\\magick.exe",
    }

    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            f:close()
            imagemagick_path = path
            return imagemagick_path
        end
    end

    return nil
end

-- Check if source file is newer than indexed file using lfs (LuaFileSystem)
-- PCSX-Redux has lfs loaded globally - instant, no shell commands
local function is_source_newer(source_path, indexed_path)
    local source_mtime = lfs.attributes(source_path, "modification")
    local indexed_mtime = lfs.attributes(indexed_path, "modification")

    if not source_mtime then
        return true  -- Can't read source, regenerate to be safe
    end
    if not indexed_mtime then
        return true  -- No indexed file, need to create
    end

    local is_newer = source_mtime > indexed_mtime
    return is_newer
end

-- Run ImageMagick to quantize image to indexed BMP
-- For RGBA input (TGA), this preserves alpha in the palette which we use for STP bits
local function run_imagemagick_quantize(input_path, output_path)
    local magick = get_imagemagick_path()
    if not magick then
        return false
    end

    -- Determine if input is RGBA (TGA) or RGB (legacy BMP)
    local is_tga = input_path:lower():match("%.tga$")

    local cmd
    if is_tga then
        -- TGA (RGBA) input: quantize with alpha channel support
        -- -channel RGBA ensures alpha is considered in quantization
        -- -quantize transparent enables transparency-aware quantization
        -- This creates palette entries with distinct alpha values
        cmd = string.format(
            'cmd /c ""%s" "%s" -channel RGBA -quantize transparent -colors 256 -dither FloydSteinberg -compress none BMP3:"%s""',
            magick, input_path, output_path
        )
    else
        -- Legacy BMP (RGB) input: original behavior
        cmd = string.format(
            'cmd /c ""%s" "%s" -depth 5 -colors 256 -dither FloydSteinberg -compress none BMP3:"%s""',
            magick, input_path, output_path
        )
    end

    local handle = io.popen(cmd .. " 2>&1")
    if handle then
        handle:read("*a")
        handle:close()
    end

    -- Check if output was created
    local f = io.open(output_path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Get texture directory path for current session
local function get_texture_dir()
    if not EFFECT_EDITOR.session_name or EFFECT_EDITOR.session_name == "" then
        return nil
    end
    return config.TEXTURES_PATH
end

-- Get texture TGA path for current session (RGBA export for editing)
local function get_texture_tga_path()
    local dir = get_texture_dir()
    if not dir then return nil end
    return dir .. EFFECT_EDITOR.session_name .. ".tga"
end

-- Get texture BMP path for current session (legacy, for indexed fallback)
local function get_texture_bmp_path()
    local dir = get_texture_dir()
    if not dir then return nil end
    return dir .. EFFECT_EDITOR.session_name .. ".bmp"
end

-- Check if current effect has exportable texture (8bpp or 4bpp)
-- Tries file_data first, falls back to memory if not available
local function is_exportable_texture()
    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.texture_ptr then
        return false
    end

    -- Just need a valid data source
    return (EFFECT_EDITOR.file_data and #EFFECT_EDITOR.file_data > 0) or
           (EFFECT_EDITOR.memory_base and EFFECT_EDITOR.memory_base >= 0x80000000)
end

-- Get texture dimensions from file data or memory
-- Returns: width, height, pixel_size or nil if invalid
local function get_texture_dimensions()
    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.texture_ptr then
        return nil
    end

    local texture_offset = EFFECT_EDITOR.header.texture_ptr
    local low, mid, high, depth_flag

    -- Texture section layout:
    -- 0x000: Palette 1 (512 bytes)
    -- 0x200: Palette 2 (512 bytes)
    -- 0x400: Header (4 bytes: low, mid, high, depth_flag)
    -- 0x404: Pixel data

    if EFFECT_EDITOR.file_data and #EFFECT_EDITOR.file_data > 0 then
        -- Read texture header bytes from file data
        local data = EFFECT_EDITOR.file_data
        low = MemUtils.buf_read8(data, texture_offset + 0x400)
        mid = MemUtils.buf_read8(data, texture_offset + 0x401)
        high = MemUtils.buf_read8(data, texture_offset + 0x402)
        depth_flag = MemUtils.buf_read8(data, texture_offset + 0x403)
    elseif EFFECT_EDITOR.memory_base and EFFECT_EDITOR.memory_base >= 0x80000000 then
        -- Fall back to reading from PSX memory
        MemUtils.refresh_mem()
        local base = EFFECT_EDITOR.memory_base
        low = MemUtils.read8(base + texture_offset + 0x400)
        mid = MemUtils.read8(base + texture_offset + 0x401)
        high = MemUtils.read8(base + texture_offset + 0x402)
        depth_flag = MemUtils.read8(base + texture_offset + 0x403)
    else
        return nil
    end

    -- The 24-bit combined value is total pixel data size in bytes
    -- Note: mid_byte is NOT the width - it's part of the 24-bit size value
    local pixel_count = low + mid * 256 + high * 65536

    if pixel_count <= 0 then
        return nil
    end

    local width, height

    if depth_flag ~= 0 then
        -- Custom indexed format: 1 byte = 1 pixel (low nibble=color, high nibble=sub-palette)
        width = 256
        height = math.floor(pixel_count / 256)
    else
        -- 8bpp: Determine width based on pixel count
        -- Large textures (>=65536 bytes) like Ramuh are 256 wide
        -- Standard textures are 128 wide
        if pixel_count >= 65536 then
            width = 256
        else
            width = 128
        end
        height = math.floor(pixel_count / width)
    end

    if height <= 0 then
        return nil
    end

    return width, height, pixel_count
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Check if texture export is available for current session
function M.can_export_texture()
    return is_exportable_texture() and EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""
end

-- Export current effect texture to RGBA TGA file
-- This format supports alpha channel which encodes STP (semi-transparency) bits
-- User can control transparency by editing alpha in Krita:
--   Alpha = 255 (fully visible) -> STP=0 (opaque on PSX)
--   Alpha < 255 (any transparency) -> STP=1 (semi-transparent on PSX)
-- Reads from .bin file data (not RAM) - always reliable regardless of emulator state
-- Returns: true on success, false and error message on failure
function M.export_texture_to_bmp()
    if not EFFECT_EDITOR.session_name or EFFECT_EDITOR.session_name == "" then
        logging.log_error("No session loaded - cannot export texture")
        return false, "No session loaded"
    end

    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.texture_ptr then
        logging.log_error("No effect header - cannot export texture")
        return false, "No header"
    end

    local texture_offset = EFFECT_EDITOR.header.texture_ptr
    local has_file_data = EFFECT_EDITOR.file_data and #EFFECT_EDITOR.file_data > 0
    local has_memory = EFFECT_EDITOR.memory_base and EFFECT_EDITOR.memory_base >= 0x80000000

    if not has_file_data and not has_memory then
        logging.log_error("No file data or memory base - cannot export texture")
        return false, "No data source"
    end

    -- Check depth flag (0 = 8bpp, non-zero = 4bpp)
    local depth_flag
    if has_file_data then
        depth_flag = MemUtils.buf_read8(EFFECT_EDITOR.file_data, texture_offset + 0x403)
    else
        MemUtils.refresh_mem()
        depth_flag = MemUtils.read8(EFFECT_EDITOR.memory_base + texture_offset + 0x403)
    end

    local is_4bpp = depth_flag ~= 0

    -- Get dimensions
    local width, height, pixel_size = get_texture_dimensions()
    if not width then
        logging.log_error("Could not determine texture dimensions")
        return false, "Invalid texture dimensions"
    end

    local source_name = has_file_data and ".bin file" or "PSX memory"
    local bpp_label = is_4bpp and "4bpp" or "8bpp"
    logging.log(string.format("Exporting texture: %dx%d %s (%d bytes) from %s", width, height, bpp_label, pixel_size, source_name))

    local palette_data, pixels, pal0, pal1

    if has_file_data then
        local data = EFFECT_EDITOR.file_data
        -- Read palette (512 bytes BGR555) from file data
        palette_data = data:sub(texture_offset + 1, texture_offset + 512)
        pal0 = MemUtils.buf_read16(data, texture_offset)
        pal1 = MemUtils.buf_read16(data, texture_offset + 2)
        -- Read pixel data from file
        local pixel_offset = texture_offset + 0x404
        pixels = data:sub(pixel_offset + 1, pixel_offset + pixel_size)
    else
        -- Read from PSX memory
        MemUtils.refresh_mem()
        local base = EFFECT_EDITOR.memory_base
        local tex_addr = base + texture_offset

        -- Read palette (512 bytes)
        local pal_bytes = {}
        for i = 0, 511 do
            pal_bytes[i + 1] = string.char(MemUtils.read8(tex_addr + i))
        end
        palette_data = table.concat(pal_bytes)

        pal0 = MemUtils.read16(tex_addr)
        pal1 = MemUtils.read16(tex_addr + 2)

        -- Read pixel data from memory
        local pixel_addr = tex_addr + 0x404
        local pix_bytes = {}
        for i = 0, pixel_size - 1 do
            pix_bytes[i + 1] = string.char(MemUtils.read8(pixel_addr + i))
        end
        pixels = table.concat(pix_bytes)
    end

    -- Debug: show first palette entries with STP bits
    local stp0 = bit.band(pal0, 0x8000) ~= 0 and 1 or 0
    local stp1 = bit.band(pal1, 0x8000) ~= 0 and 1 or 0
    local bpp_str = is_4bpp and "4bpp" or "8bpp"
    print(string.format("[TEXTURE] %s palette[0]=0x%04X (STP=%d) palette[1]=0x%04X (STP=%d)", bpp_str, pal0, stp0, pal1, stp1))

    -- Convert to RGBA pixels with alpha from STP bits
    local rgba_pixels
    if is_4bpp then
        rgba_pixels = bmp.psx_texture_to_rgba_pixels_4bpp(palette_data, width, height, pixels)
    else
        rgba_pixels = bmp.psx_texture_to_rgba_pixels(palette_data, width, height, pixels)
    end

    -- Ensure texture directory exists
    local texture_dir = get_texture_dir()
    config.ensure_dir(texture_dir)

    -- Write RGBA TGA (supports alpha channel for STP control)
    local tga_path = get_texture_tga_path()
    local success, err = bmp.write_rgba_tga(tga_path, width, height, rgba_pixels)

    if not success then
        logging.log_error("Failed to write TGA: " .. (err or "unknown error"))
        return false, err
    end

    -- Store export info
    EFFECT_EDITOR.texture_export_fingerprint = bmp.compute_file_fingerprint(tga_path)
    EFFECT_EDITOR.texture_width = width
    EFFECT_EDITOR.texture_height = height

    logging.log(string.format("Texture exported to: %s", tga_path))
    EFFECT_EDITOR.status_msg = string.format("Texture exported (%dx%d %s)", width, height, bpp_label)

    print("")
    print(string.format("Texture exported to: %s", tga_path))
    print(string.format("  Dimensions: %d x %d (%s)", width, height, bpp_label))
    print("  Format: 32-bit RGBA TGA")
    print("")
    print("  STP (Semi-Transparency) is encoded in the ALPHA channel:")
    print("    Alpha = 255 (fully visible) -> Opaque on PSX")
    print("    Alpha < 255 (any transparency) -> Semi-transparent on PSX")
    print("")
    print("  Edit in Krita, then click Test Effect to see changes")
    print("")

    return true
end

-- Reload texture from TGA/BMP file and patch RAM
-- The new workflow reads RGBA TGA directly and quantizes with alpha support:
--   1. User edits session.tga in Krita (32-bit RGBA)
--   2. We read the TGA directly and quantize ourselves (preserving alpha for STP)
--   3. No ImageMagick dependency for alpha handling
-- Fallback: If only indexed BMP exists (legacy), use it
-- silent: if true, don't print user-facing messages
-- Returns: true if texture was reloaded, false otherwise
function M.reload_texture_from_bmp(silent)
    local tga_path = get_texture_tga_path()
    local bmp_path = get_texture_bmp_path()  -- Legacy fallback

    if not tga_path and not bmp_path then
        return false
    end

    local indexed_path = (tga_path or bmp_path):gsub("%.[^.]+$", "_indexed.bmp")

    local tga_exists = tga_path and bmp.file_exists(tga_path)
    local legacy_bmp_exists = bmp_path and bmp.file_exists(bmp_path)
    local indexed_exists = bmp.file_exists(indexed_path)

    -- Get texture address from memory (after savestate reload, this is valid)
    MemUtils.refresh_mem()
    local base = EFFECT_EDITOR.memory_base
    local texture_ptr = MemUtils.read32(base + 0x24)
    local texture_addr = base + texture_ptr

    local width, height, palette, pixels

    -- Priority: TGA (new workflow with alpha) > legacy indexed BMP > legacy source BMP
    if tga_exists then
        -- NEW WORKFLOW: Read TGA directly, quantize ourselves with alpha support
        local rgba_width, rgba_height, rgba_pixels = bmp.read_rgba_tga(tga_path)
        if not rgba_width then
            if not silent then
                logging.log_error("Failed to read TGA: " .. (rgba_height or "unknown error"))
            end
            return false
        end

        -- Quantize to indexed with alpha support
        palette, pixels = bmp.quantize_rgba_to_indexed(rgba_width, rgba_height, rgba_pixels, silent)
        width, height = rgba_width, rgba_height

    elseif indexed_exists then
        -- LEGACY: Use existing indexed BMP
        width, height, palette, pixels = bmp.read_indexed_bmp(indexed_path, nil)
        if not width then
            if not silent then
                logging.log_error("Failed to read indexed BMP: " .. (height or "unknown error"))
            end
            return false
        end

    elseif legacy_bmp_exists then
        -- LEGACY: Source BMP exists, run ImageMagick
        if not run_imagemagick_quantize(bmp_path, indexed_path) then
            if not silent then
                logging.log_error("ImageMagick conversion failed")
            end
            return false
        end

        width, height, palette, pixels = bmp.read_indexed_bmp(indexed_path, nil)
        if not width then
            if not silent then
                logging.log_error("Failed to read indexed BMP: " .. (height or "unknown error"))
            end
            return false
        end

    else
        -- No texture files exist
        return false
    end

    -- Convert palette to BGR555, deriving STP bits from palette ALPHA
    local palette_data = bmp.palette_rgb_to_bgr555_from_alpha(palette)

    -- Patch RAM
    -- Write palette 1 (512 bytes at offset 0x000)
    for i = 1, #palette_data do
        MemUtils.write8(texture_addr + i - 1, palette_data:byte(i))
    end

    -- Write palette 2 (512 bytes at offset 0x200) - same data
    -- Some effects use palette 2, so we patch both to ensure edits are visible
    for i = 1, #palette_data do
        MemUtils.write8(texture_addr + 0x200 + i - 1, palette_data:byte(i))
    end

    -- Write pixel data
    local pixel_addr = texture_addr + 0x404
    for i = 1, #pixels do
        MemUtils.write8(pixel_addr + i - 1, pixels:byte(i))
    end

    return true
end

-- Apply texture from .bin file to RAM (fallback when no BMP files exist)
-- Returns: true if texture was applied, false otherwise
local function apply_texture_from_bin(silent)
    if not EFFECT_EDITOR.file_data or #EFFECT_EDITOR.file_data == 0 then
        return false
    end
    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.texture_ptr then
        return false
    end

    local data = EFFECT_EDITOR.file_data
    local texture_offset = EFFECT_EDITOR.header.texture_ptr

    -- Check if 8bpp (we only support 8bpp)
    local depth_flag = MemUtils.buf_read8(data, texture_offset + 0x403)
    if depth_flag ~= 0 then
        return false  -- 4bpp not supported
    end

    -- Get dimensions
    local low = MemUtils.buf_read8(data, texture_offset + 0x400)
    local width = MemUtils.buf_read8(data, texture_offset + 0x401)
    local high = MemUtils.buf_read8(data, texture_offset + 0x402)
    if width == 0 then
        return false
    end
    local pixel_size = low + width * 256 + high * 65536
    local height = math.floor(pixel_size / width)

    -- Get texture address in RAM
    MemUtils.refresh_mem()
    local base = EFFECT_EDITOR.memory_base
    local texture_ptr = MemUtils.read32(base + 0x24)
    local texture_addr = base + texture_ptr

    -- Copy palette 1 from .bin to RAM (512 bytes)
    for i = 0, 511 do
        local byte = MemUtils.buf_read8(data, texture_offset + i)
        MemUtils.write8(texture_addr + i, byte)
    end

    -- Copy palette 2 from .bin to RAM (512 bytes at offset 0x200)
    for i = 0, 511 do
        local byte = MemUtils.buf_read8(data, texture_offset + 0x200 + i)
        MemUtils.write8(texture_addr + 0x200 + i, byte)
    end

    -- Copy pixel data from .bin to RAM
    local pixel_addr = texture_addr + 0x404
    for i = 0, pixel_size - 1 do
        local byte = MemUtils.buf_read8(data, texture_offset + 0x404 + i)
        MemUtils.write8(pixel_addr + i, byte)
    end

    if not silent then
        logging.log(string.format("Applied texture from .bin (%dx%d)", width, height))
    end

    return true
end

-- Reload texture from TGA/BMP if it exists, or from .bin as fallback
-- Called before test effect runs - ALWAYS reloads because savestate resets RAM
-- Returns: true if texture was reloaded, false otherwise
function M.maybe_reload_texture_before_test()
    local tga_path = get_texture_tga_path()
    local bmp_path = get_texture_bmp_path()

    if not tga_path and not bmp_path then
        -- No session, try .bin fallback
        return apply_texture_from_bin(true)
    end

    -- Check if any texture source files exist (TGA, BMP, or indexed)
    local indexed_path = (tga_path or bmp_path):gsub("%.[^.]+$", "_indexed.bmp")
    local tga_exists = tga_path and bmp.file_exists(tga_path)
    local bmp_exists = bmp_path and bmp.file_exists(bmp_path)
    local indexed_exists = bmp.file_exists(indexed_path)

    if not tga_exists and not bmp_exists and not indexed_exists then
        -- No texture files, fall back to .bin
        return apply_texture_from_bin(true)
    end

    -- Texture files exist - reload from TGA/BMP (silent during test)
    return M.reload_texture_from_bmp(true)
end

-- Debug: Dump first N bytes of texture to verify patching worked
function M.debug_dump_texture(num_bytes)
    num_bytes = num_bytes or 32

    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        print("No effect in memory")
        return
    end

    MemUtils.refresh_mem()
    local base = EFFECT_EDITOR.memory_base
    local texture_ptr = MemUtils.read32(base + 0x24)
    local texture_addr = base + texture_ptr

    print(string.format("\n=== TEXTURE DEBUG (addr=0x%08X, ptr=0x%X) ===", texture_addr, texture_ptr))

    -- Dump palette (first 32 bytes = 16 colors)
    print("Palette 1 (first 16 colors as BGR555):")
    local hex = ""
    for i = 0, math.min(31, num_bytes - 1) do
        hex = hex .. string.format("%02X ", MemUtils.read8(texture_addr + i))
        if i % 16 == 15 then
            print("  " .. hex)
            hex = ""
        end
    end
    if hex ~= "" then print("  " .. hex) end

    -- Dump pixel data start
    print(string.format("\nPixel data (first %d bytes at offset 0x404):", num_bytes))
    hex = ""
    for i = 0, num_bytes - 1 do
        hex = hex .. string.format("%02X ", MemUtils.read8(texture_addr + 0x404 + i))
        if i % 16 == 15 then
            print("  " .. hex)
            hex = ""
        end
    end
    if hex ~= "" then print("  " .. hex) end

    print("=== END TEXTURE DEBUG ===\n")
end

-- Get export status info for UI
function M.get_texture_status()
    if not M.can_export_texture() then
        if not EFFECT_EDITOR.session_name or EFFECT_EDITOR.session_name == "" then
            return "no session"
        end
        if not EFFECT_EDITOR.header then
            return "no effect loaded"
        end
        if not EFFECT_EDITOR.file_data or #EFFECT_EDITOR.file_data == 0 then
            return "no file data"
        end
        return "unavailable"
    end

    local width, height = get_texture_dimensions()

    -- Determine if 4bpp or 8bpp
    local bpp = "8bpp"
    if EFFECT_EDITOR.header and EFFECT_EDITOR.header.texture_ptr then
        local texture_offset = EFFECT_EDITOR.header.texture_ptr
        local depth_flag
        if EFFECT_EDITOR.file_data and #EFFECT_EDITOR.file_data > 0 then
            depth_flag = MemUtils.buf_read8(EFFECT_EDITOR.file_data, texture_offset + 0x403)
        elseif EFFECT_EDITOR.memory_base and EFFECT_EDITOR.memory_base >= 0x80000000 then
            MemUtils.refresh_mem()
            depth_flag = MemUtils.read8(EFFECT_EDITOR.memory_base + texture_offset + 0x403)
        end
        if depth_flag and depth_flag ~= 0 then
            bpp = "4bpp"
        end
    end

    if width and height then
        return string.format("%dx%d %s", width, height, bpp)
    end

    return bpp
end

return M
