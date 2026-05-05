-- instrument_snapshot.lua
-- One-shot dump of the in-memory instrument table the game is currently using,
-- plus a small ADPCM fingerprint for each non-null instrument.
--
-- Called once per sound_debug run (after first play_sound fires) so we capture
-- whichever bank is live at that moment — possibly different from what the
-- music player uses. Compare these dumps between music-playing state and
-- effect-playing state to confirm whether feds uses a separate sample bank.
--
-- RAM layout (from research/lua_scripts/read_spu_ram.lua):
--   song_ptr     = read32(0x80032a50)
--   voice_slot_N = song_ptr + 0xB8 + N * 0x160   (N in 0..11)
--   inst_table   = read32(voice_slot_1 + 0x30)   -- ptr to table
--   entry N      = inst_table + N * 16 + 0x30    -- 0x30-byte table header
--   entry layout: [0..3] sample_offset (u32)
--                 [4..5] sample_size (u16)
--                 [6..7] fine_tune (s16)
--                 [8..15] ADSR bytes

local M = {}

local MemUtils = nil

function M.set_dependencies(mem_utils, cfg)
    MemUtils = mem_utils
end

M.SONG_PTR_ADDR = 0x80032a50
M.VOICE_SLOT_OFFSET = 0xB8           -- first voice slot inside the song struct
M.VOICE_STRIDE = 0x160
M.INST_TABLE_PTR_OFFSET = 0x30       -- field inside a voice slot that points to the table
M.INST_ENTRY_HEADER_SIZE = 0x30      -- entries start after this many header bytes
M.ENTRY_SIZE = 16
M.MAX_ENTRIES = 200                  -- WAVESET.WD has ~177; cap generously
M.ADPCM_FINGERPRINT_BYTES = 32       -- two ADPCM blocks, enough to fingerprint


-- Auto-detect the instrument table base address from live PSX memory.
function M.detect_inst_table_addr()
    if not MemUtils then return 0 end
    MemUtils.refresh_mem()
    local song_ptr = MemUtils.read32(M.SONG_PTR_ADDR)
    if song_ptr == 0 or song_ptr < 0x80000000 then
        return 0
    end
    -- Try voice slot 1 (slot 0 is the conductor — its +0x30 may be null)
    local voice1 = song_ptr + M.VOICE_SLOT_OFFSET + M.VOICE_STRIDE
    local tbl = MemUtils.read32(voice1 + M.INST_TABLE_PTR_OFFSET)
    if tbl == 0 or tbl < 0x80000000 then
        return 0
    end
    return tbl
end


-- Write a block of N bytes from PSX RAM to an open file, starting at addr.
local function write_mem_bytes(file, addr, n)
    for i = 0, n - 1 do
        local b = MemUtils.read8(addr + i)
        file:write(string.char(b))
    end
end


local function hex_bytes(addr, n)
    local buf = {}
    for i = 0, n - 1 do
        buf[#buf + 1] = string.format("%02X", MemUtils.read8(addr + i))
    end
    return table.concat(buf)
end


-- Dump the instrument table + per-entry ADPCM fingerprints to the given
-- output directory. Returns (ok, inst_table_addr, entries_written).
function M.snapshot(output_dir)
    if not MemUtils then
        return false, 0, 0
    end
    MemUtils.refresh_mem()

    local inst_table = M.detect_inst_table_addr()
    if inst_table == 0 then
        print("[InstrumentSnapshot] Could not auto-detect instrument table (no song playing?)")
        return false, 0, 0
    end

    -- 1) Raw dump of the table itself (header + entries). Size:
    --    INST_ENTRY_HEADER_SIZE + MAX_ENTRIES * ENTRY_SIZE
    local table_bytes = M.INST_ENTRY_HEADER_SIZE + M.MAX_ENTRIES * M.ENTRY_SIZE
    local table_path = output_dir .. "instrument_table.bin"
    local tf = io.open(table_path, "wb")
    if not tf then
        print("[InstrumentSnapshot] Can't open " .. table_path)
        return false, inst_table, 0
    end
    write_mem_bytes(tf, inst_table, table_bytes)
    tf:close()

    -- 2) Per-entry ADPCM fingerprints. The ADPCM data starts at
    --    inst_table + sample_offset (same address space as the table itself).
    --    Reference: read_spu_ram.lua uses inst_base + sample_offset + 0x30
    --    as the ADPCM start. We mirror that.
    local regions_path = output_dir .. "waveset_regions.jsonl"
    local rf = io.open(regions_path, "w")
    if not rf then
        print("[InstrumentSnapshot] Can't open " .. regions_path)
        return false, inst_table, 0
    end

    local entries_written = 0
    for i = 0, M.MAX_ENTRIES - 1 do
        local ent_addr = inst_table + i * M.ENTRY_SIZE + M.INST_ENTRY_HEADER_SIZE
        local sample_offset = MemUtils.read32(ent_addr)
        local sample_size = MemUtils.read16(ent_addr + 4)
        local fine_tune = MemUtils.read16(ent_addr + 6)
        if fine_tune >= 32768 then fine_tune = fine_tune - 65536 end

        local adsr1 = MemUtils.read32(ent_addr + 8)
        local adsr2 = MemUtils.read32(ent_addr + 12)

        if sample_offset ~= 0 or sample_size ~= 0 then
            local adpcm_start = inst_table + sample_offset + M.INST_ENTRY_HEADER_SIZE
            local fingerprint_len = math.min(M.ADPCM_FINGERPRINT_BYTES, sample_size)
            local adpcm_hex = ""
            if fingerprint_len > 0 then
                adpcm_hex = hex_bytes(adpcm_start, fingerprint_len)
            end

            -- JSONL — one object per line. Keep it simple (no string escapes needed).
            rf:write(string.format(
                '{"index":%d,"sample_offset":%d,"sample_size":%d,"fine_tune":%d,' ..
                '"adsr1":%d,"adsr2":%d,"adpcm_first_bytes_hex":"%s",' ..
                '"entry_addr":"0x%08X","adpcm_addr":"0x%08X"}\n',
                i, sample_offset, sample_size, fine_tune,
                adsr1, adsr2, adpcm_hex,
                ent_addr, adpcm_start))
            entries_written = entries_written + 1
        end
    end
    rf:close()

    print(string.format("[InstrumentSnapshot] inst_table=0x%08X entries=%d -> %s",
        inst_table, entries_written, output_dir))
    return true, inst_table, entries_written
end


return M
