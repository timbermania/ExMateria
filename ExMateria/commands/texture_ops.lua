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
    print(string.format("[TEXTURE DEBUG] source_mtime=%d, indexed_mtime=%d, newer=%s",
        source_mtime, indexed_mtime, tostring(is_newer)))
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

    print(string.format("[TEXTURE DEBUG] ImageMagick command: %s", cmd))

    local handle = io.popen(cmd .. " 2>&1")
    if handle then
        local output = handle:read("*a")
        handle:close()
        if output and #output > 0 then
            print(string.format("[TEXTURE DEBUG] ImageMagick output: %s", output))
        end
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

-- Check if current effect has 8bpp texture (exportable)
-- Uses file_data (.bin) instead of RAM - always reliable
local function is_8bpp_texture()
    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.texture_ptr then
        return false
    end
    if not EFFECT_EDITOR.file_data or #EFFECT_EDITOR.file_data == 0 then
        return false
    end

    -- Read depth flag from .bin file data (not RAM)
    local texture_offset = EFFECT_EDITOR.header.texture_ptr
    local depth_flag = MemUtils.buf_read8(EFFECT_EDITOR.file_data, texture_offset + 0x403)

    return depth_flag == 0  -- 0 = 8bpp
end

-- Get texture dimensions from file data (.bin)
-- Returns: width, height, pixel_size or nil if invalid
local function get_texture_dimensions_from_file()
    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.texture_ptr then
        return nil
    end
    if not EFFECT_EDITOR.file_data or #EFFECT_EDITOR.file_data == 0 then
        return nil
    end

    local data = EFFECT_EDITOR.file_data
    local texture_offset = EFFECT_EDITOR.header.texture_ptr

    -- Texture section layout:
    -- 0x000: Palette 1 (512 bytes)
    -- 0x200: Palette 2 (512 bytes)
    -- 0x400: Header (4 bytes: low, width, high, depth_flag)
    -- 0x404: Pixel data

    -- Read texture header bytes from file data
    local low = MemUtils.buf_read8(data, texture_offset + 0x400)
    local width = MemUtils.buf_read8(data, texture_offset + 0x401)
    local high = MemUtils.buf_read8(data, texture_offset + 0x402)
    local depth_flag = MemUtils.buf_read8(data, texture_offset + 0x403)

    if width == 0 then
        return nil
    end

    -- The 24-bit combined value encodes total pixel data size
    local combined = low + width * 256 + high * 65536

    local pixel_data_size, height

    if depth_flag == 0 then
        -- 8bpp: 1 byte per pixel
        pixel_data_size = combined
        height = math.floor(combined / width)
    else
        -- 4bpp: not supported
        pixel_data_size = combined
        height = math.floor(combined / width)
    end

    if pixel_data_size <= 0 or height <= 0 then
        return nil
    end

    return width, height, pixel_data_size
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Check if texture export is available for current session
function M.can_export_texture()
    return is_8bpp_texture() and EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""
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

    if not EFFECT_EDITOR.file_data or #EFFECT_EDITOR.file_data == 0 then
        logging.log_error("No effect file data loaded - cannot export texture")
        return false, "No file data"
    end

    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.texture_ptr then
        logging.log_error("No effect header - cannot export texture")
        return false, "No header"
    end

    local data = EFFECT_EDITOR.file_data
    local texture_offset = EFFECT_EDITOR.header.texture_ptr

    -- Check depth flag from file data
    local depth_flag = MemUtils.buf_read8(data, texture_offset + 0x403)

    if depth_flag ~= 0 then
        logging.log_error("Cannot export 4bpp texture - only 8bpp supported")
        return false, "4bpp textures not supported"
    end

    -- Get dimensions from file data
    local width, height, pixel_size = get_texture_dimensions_from_file()
    if not width then
        logging.log_error("Could not determine texture dimensions")
        return false, "Invalid texture dimensions"
    end

    logging.log(string.format("Exporting texture: %dx%d (%d bytes) from .bin file", width, height, pixel_size))

    -- Read palette (512 bytes BGR555) from file data
    local palette_data = data:sub(texture_offset + 1, texture_offset + 512)

    -- Debug: show first palette entries with STP bits
    local pal0 = MemUtils.buf_read16(data, texture_offset)
    local pal1 = MemUtils.buf_read16(data, texture_offset + 2)
    local stp0 = bit.band(pal0, 0x8000) ~= 0 and 1 or 0
    local stp1 = bit.band(pal1, 0x8000) ~= 0 and 1 or 0
    print(string.format("[TEXTURE] palette[0]=0x%04X (STP=%d) palette[1]=0x%04X (STP=%d)", pal0, stp0, pal1, stp1))

    -- Read pixel data from file
    local pixel_offset = texture_offset + 0x404
    local pixels = data:sub(pixel_offset + 1, pixel_offset + pixel_size)

    -- Convert to RGBA pixels with alpha from STP bits
    local rgba_pixels = bmp.psx_texture_to_rgba_pixels(palette_data, width, height, pixels)

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
    EFFECT_EDITOR.status_msg = string.format("Texture exported (%dx%d)", width, height)

    print("")
    print(string.format("Texture exported to: %s", tga_path))
    print(string.format("  Dimensions: %d x %d", width, height))
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

    print(string.format("[TEXTURE DEBUG] tga_exists=%s, legacy_bmp_exists=%s, indexed_exists=%s",
        tostring(tga_exists), tostring(legacy_bmp_exists), tostring(indexed_exists)))

    -- Get texture address from memory (after savestate reload, this is valid)
    MemUtils.refresh_mem()
    local base = EFFECT_EDITOR.memory_base
    local texture_ptr = MemUtils.read32(base + 0x24)
    local texture_addr = base + texture_ptr
    print(string.format("[TEXTURE DEBUG] base=0x%08X, texture_ptr=0x%X, texture_addr=0x%08X", base, texture_ptr, texture_addr))

    local width, height, palette, pixels

    -- Priority: TGA (new workflow with alpha) > legacy indexed BMP > legacy source BMP
    if tga_exists then
        -- NEW WORKFLOW: Read TGA directly, quantize ourselves with alpha support
        print(string.format("[TEXTURE DEBUG] Reading TGA directly: %s", tga_path))
        if not silent then
            logging.log("Processing TGA with alpha support...")
        end

        local rgba_width, rgba_height, rgba_pixels = bmp.read_rgba_tga(tga_path)
        if not rgba_width then
            print(string.format("[TEXTURE DEBUG] Failed to read TGA: %s", tostring(rgba_height)))
            if not silent then
                logging.log_error("Failed to read TGA: " .. (rgba_height or "unknown error"))
            end
            return false
        end

        print(string.format("[TEXTURE DEBUG] Read TGA: %dx%d, %d pixels", rgba_width, rgba_height, #rgba_pixels))

        -- Quantize to indexed with alpha support
        palette, pixels = bmp.quantize_rgba_to_indexed(rgba_width, rgba_height, rgba_pixels)
        width, height = rgba_width, rgba_height

        if not silent then
            logging.log(string.format("Quantized TGA to indexed (%dx%d)", width, height))
        end

    elseif indexed_exists then
        -- LEGACY: Use existing indexed BMP
        print(string.format("[TEXTURE DEBUG] Using indexed BMP: %s", indexed_path))
        if not silent then
            logging.log("Using indexed texture: " .. indexed_path:match("[^/\\]+$"))
        end

        width, height, palette, pixels = bmp.read_indexed_bmp(indexed_path, nil)
        if not width then
            print(string.format("[TEXTURE DEBUG] Failed to read indexed BMP: %s", tostring(height)))
            if not silent then
                logging.log_error("Failed to read indexed BMP: " .. (height or "unknown error"))
            end
            return false
        end

    elseif legacy_bmp_exists then
        -- LEGACY: Source BMP exists, run ImageMagick
        print(string.format("[TEXTURE DEBUG] Legacy BMP workflow: %s", bmp_path))
        if not silent then
            logging.log("Quantizing legacy BMP with ImageMagick...")
        end

        if not run_imagemagick_quantize(bmp_path, indexed_path) then
            if not silent then
                logging.log_error("ImageMagick conversion failed")
            end
            return false
        end

        width, height, palette, pixels = bmp.read_indexed_bmp(indexed_path, nil)
        if not width then
            print(string.format("[TEXTURE DEBUG] Failed to read indexed BMP: %s", tostring(height)))
            if not silent then
                logging.log_error("Failed to read indexed BMP: " .. (height or "unknown error"))
            end
            return false
        end

    else
        -- No texture files exist
        print("[TEXTURE DEBUG] No texture files found")
        return false
    end

    print(string.format("[TEXTURE DEBUG] Final: %dx%d, palette entries: %d, pixel bytes: %d",
        width, height, #palette, #pixels))

    -- Convert palette to BGR555, deriving STP bits from palette ALPHA
    local palette_data = bmp.palette_rgb_to_bgr555_from_alpha(palette)

    -- Debug: show STP bits derived from palette alpha
    local stp_count = 0
    for i = 1, 256 do
        if palette[i] and palette[i].a and palette[i].a < 255 then
            stp_count = stp_count + 1
        end
    end
    print(string.format("[TEXTURE DEBUG] Palette entries with STP=1 (alpha<255): %d", stp_count))

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

    print(string.format("[TEXTURE DEBUG] Wrote %d palette bytes to 0x%08X", #palette_data, texture_addr))
    print(string.format("[TEXTURE DEBUG] Wrote %d pixel bytes to 0x%08X", #pixels, pixel_addr))

    -- Verify first few bytes
    local verify = ""
    for i = 0, 7 do
        verify = verify .. string.format("%02X ", MemUtils.read8(texture_addr + i))
    end
    print(string.format("[TEXTURE DEBUG] First 8 palette bytes in RAM: %s", verify))

    if not silent then
        logging.log(string.format("Reloaded texture (%dx%d) - STP from alpha", width, height))
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

    print(string.format("[TEXTURE DEBUG] Applying texture from .bin: %dx%d to 0x%08X", width, height, texture_addr))

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
    print(string.format("[TEXTURE DEBUG] tga_path = %s, bmp_path = %s", tostring(tga_path), tostring(bmp_path)))

    if not tga_path and not bmp_path then
        -- No session, try .bin fallback
        print("[TEXTURE DEBUG] No texture paths, trying .bin fallback")
        return apply_texture_from_bin(false)
    end

    -- Check if any texture source files exist (TGA, BMP, or indexed)
    local indexed_path = (tga_path or bmp_path):gsub("%.[^.]+$", "_indexed.bmp")
    local tga_exists = tga_path and bmp.file_exists(tga_path)
    local bmp_exists = bmp_path and bmp.file_exists(bmp_path)
    local indexed_exists = bmp.file_exists(indexed_path)
    print(string.format("[TEXTURE DEBUG] tga exists: %s, bmp exists: %s, indexed exists: %s",
        tostring(tga_exists), tostring(bmp_exists), tostring(indexed_exists)))

    if not tga_exists and not bmp_exists and not indexed_exists then
        -- No texture files, fall back to .bin
        print("[TEXTURE DEBUG] No texture files, falling back to .bin")
        return apply_texture_from_bin(false)
    end

    -- Texture files exist - reload from TGA/BMP
    print("[TEXTURE DEBUG] Calling reload_texture_from_bmp...")
    local success = M.reload_texture_from_bmp(false)  -- NOT silent - show what's happening
    print(string.format("[TEXTURE DEBUG] reload_texture_from_bmp returned: %s", tostring(success)))
    return success
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
        -- Check depth flag from file data
        local texture_offset = EFFECT_EDITOR.header.texture_ptr
        local depth_flag = MemUtils.buf_read8(EFFECT_EDITOR.file_data, texture_offset + 0x403)
        if depth_flag ~= 0 then
            return "4bpp (unsupported)"
        end
        return "unavailable"
    end

    local width, height = get_texture_dimensions_from_file()
    if width and height then
        return string.format("%dx%d 8bpp", width, height)
    end

    return "8bpp"
end

return M
