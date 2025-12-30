-- commands/session.lua
-- Session management: load, refresh, list, delete

local M = {}

-- Load platform utilities
local platform = require("platform")

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local config = nil
local logging = nil
local MemUtils = nil
local Parser = nil
local ee_reload_fn = nil
local load_from_memory_internal_fn = nil
local apply_all_edits_fn = nil
local texture_ops = nil

function M.set_dependencies(cfg, log_module, mem_utils, parser, reload_fn, load_mem_internal_fn, apply_all_edits, tex_ops)
    config = cfg
    logging = log_module
    MemUtils = mem_utils
    Parser = parser
    ee_reload_fn = reload_fn
    load_from_memory_internal_fn = load_mem_internal_fn
    apply_all_edits_fn = apply_all_edits
    texture_ops = tex_ops
end

--------------------------------------------------------------------------------
-- ee_load_session: Load full session (metadata + savestate + parse effect)
--------------------------------------------------------------------------------

function M.ee_load_session(name)
    logging.log("========================================")
    logging.log(string.format("=== EE_LOAD_SESSION '%s' ===", name))
    logging.log("========================================")

    -- Read metadata
    local meta_path = config.META_PATH .. name .. ".json"
    logging.log(string.format("  Meta path: %s", meta_path))

    local meta_file = io.open(meta_path, "r")
    if meta_file then
        local content = meta_file:read("*all")
        meta_file:close()
        logging.log(string.format("  Meta content: %s", content:gsub("\n", " ")))

        local effect_idx = content:match('"effect_index"%s*:%s*(%d+)')
        if effect_idx then
            EFFECT_EDITOR.effect_id = tonumber(effect_idx)
            logging.log(string.format("  Parsed effect_id: %d", EFFECT_EDITOR.effect_id))
        end
    else
        logging.log_error("  Could not read metadata file!")
    end

    -- Set session name
    local prev_session = EFFECT_EDITOR.session_name
    EFFECT_EDITOR.session_name = name
    logging.log(string.format("  session_name: '%s' -> '%s'", prev_session or "", name))

    -- Load savestate
    logging.log("  Calling ee_reload...")
    local reload_ok = ee_reload_fn(name)
    logging.log(string.format("  ee_reload returned: %s", tostring(reload_ok)))

    if reload_ok then
        -- IMPORTANT: Wait for savestate to fully load before reading memory
        logging.log("  Waiting for nextTick to ensure savestate is fully loaded...")
        PCSX.nextTick(function()
            logging.log("  nextTick callback - savestate should be loaded now")

            -- Update memory base from lookup table
            if EFFECT_EDITOR.effect_id > 0 then
                MemUtils.refresh_mem()
                local base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + EFFECT_EDITOR.effect_id * 4)
                logging.log(string.format("  lookup_table[%d]: 0x%08X", EFFECT_EDITOR.effect_id, base or 0))

                if base >= 0x80000000 and base < 0x80200000 then
                    EFFECT_EDITOR.memory_base = base
                    logging.log(string.format("  Set memory_base: 0x%08X", base))

                    -- Load .bin file and parse directly from it (not from PSX memory)
                    local bin_path = config.EFFECT_BINS_PATH .. name .. ".bin"
                    local bin_path_win = bin_path:gsub("/", "\\")
                    logging.log(string.format("  Looking for .bin: %s", bin_path_win))

                    local bin_file = io.open(bin_path_win, "rb")
                    if bin_file then
                        local bin_data = bin_file:read("*all")
                        bin_file:close()

                        if bin_data and #bin_data > 0 then
                            logging.log(string.format("  Parsing from .bin file (%d bytes)", #bin_data))

                            -- Debug: show first 32 bytes of the file
                            local hex = ""
                            for i = 1, math.min(32, #bin_data) do
                                hex = hex .. string.format("%02X ", string.byte(bin_data, i))
                            end
                            logging.log(string.format("  First 32 bytes: %s", hex))

                            -- Parse directly from .bin file data
                            EFFECT_EDITOR.file_data = bin_data
                            EFFECT_EDITOR.header = Parser.parse_header_from_data(bin_data)
                            logging.log(string.format("  Parsed header: effect_data_ptr=0x%X, anim_table_ptr=0x%X",
                                EFFECT_EDITOR.header.effect_data_ptr or 0, EFFECT_EDITOR.header.anim_table_ptr or 0))
                            EFFECT_EDITOR.sections = Parser.calculate_sections(EFFECT_EDITOR.header)

                            -- Parse frames section from .bin data
                            if Parser.parse_frames_section_from_data then
                                local frames_section_size = EFFECT_EDITOR.header.animation_ptr - EFFECT_EDITOR.header.frames_ptr
                                EFFECT_EDITOR.framesets, EFFECT_EDITOR.frames_group_count, EFFECT_EDITOR.frames_offset_table_count = Parser.parse_frames_section_from_data(
                                    bin_data,
                                    EFFECT_EDITOR.header.frames_ptr,
                                    frames_section_size
                                )
                                EFFECT_EDITOR.original_framesets = Parser.copy_framesets(EFFECT_EDITOR.framesets)
                                local total_frames = 0
                                for _, fs in ipairs(EFFECT_EDITOR.framesets or {}) do
                                    total_frames = total_frames + #fs.frames
                                end
                                logging.log(string.format("  Parsed %d framesets (%d total frames), %d groups, %d offset table entries from .bin",
                                    #(EFFECT_EDITOR.framesets or {}), total_frames, EFFECT_EDITOR.frames_group_count or 0, EFFECT_EDITOR.frames_offset_table_count or 0))
                            else
                                logging.log("  Frames parsing functions not available")
                            end

                            -- Parse animation sequences from .bin data
                            if Parser.parse_animation_section_from_data then
                                local anim_section_size = EFFECT_EDITOR.header.script_data_ptr - EFFECT_EDITOR.header.animation_ptr
                                EFFECT_EDITOR.sequences, EFFECT_EDITOR.sequence_count = Parser.parse_animation_section_from_data(
                                    bin_data,
                                    EFFECT_EDITOR.header.animation_ptr,
                                    anim_section_size
                                )
                                EFFECT_EDITOR.original_sequences = Parser.copy_sequences(EFFECT_EDITOR.sequences)
                                local total_instructions = 0
                                for _, seq in ipairs(EFFECT_EDITOR.sequences or {}) do
                                    total_instructions = total_instructions + #seq.instructions
                                end
                                logging.log(string.format("  Parsed %d sequences (%d total instructions) from .bin",
                                    #(EFFECT_EDITOR.sequences or {}), total_instructions))
                            else
                                logging.log("  Sequence parsing functions not available")
                            end

                            local particle_size = EFFECT_EDITOR.header.anim_table_ptr - EFFECT_EDITOR.header.effect_data_ptr
                            EFFECT_EDITOR.emitter_count = Parser.calc_emitter_count(particle_size)

                            -- Parse particle header
                            EFFECT_EDITOR.particle_header = Parser.parse_particle_header_from_data(
                                bin_data,
                                EFFECT_EDITOR.header.effect_data_ptr
                            )

                            -- Parse emitters from .bin data
                            EFFECT_EDITOR.emitters = Parser.parse_all_emitters(
                                bin_data,
                                EFFECT_EDITOR.header.effect_data_ptr,
                                EFFECT_EDITOR.emitter_count
                            )

                            -- Parse animation curves from .bin data
                            logging.log(string.format("  Parsing curves from anim_table_ptr=0x%X", EFFECT_EDITOR.header.anim_table_ptr or 0))
                            EFFECT_EDITOR.curves, EFFECT_EDITOR.curve_count = Parser.parse_curves_from_data(
                                bin_data,
                                EFFECT_EDITOR.header.anim_table_ptr
                            )
                            EFFECT_EDITOR.original_curves = Parser.copy_curves(EFFECT_EDITOR.curves)
                            logging.log(string.format("  Parsed %d curves from .bin", EFFECT_EDITOR.curve_count or 0))

                            -- Parse timeline from .bin data
                            logging.log(string.format("  Parsing timeline from timeline_section_ptr=0x%X", EFFECT_EDITOR.header.timeline_section_ptr or 0))
                            if Parser.parse_timeline_header_from_data then
                                EFFECT_EDITOR.timeline_header = Parser.parse_timeline_header_from_data(
                                    bin_data,
                                    EFFECT_EDITOR.header.timeline_section_ptr
                                )
                                EFFECT_EDITOR.timeline_channels = Parser.parse_all_timeline_channels(
                                    bin_data,
                                    EFFECT_EDITOR.header.timeline_section_ptr
                                )
                                EFFECT_EDITOR.original_timeline_header = Parser.copy_timeline_header(EFFECT_EDITOR.timeline_header)
                                EFFECT_EDITOR.original_timeline_channels = Parser.copy_timeline_channels(EFFECT_EDITOR.timeline_channels)
                                logging.log(string.format("  Parsed timeline header and %d channels from .bin", #EFFECT_EDITOR.timeline_channels))
                            else
                                logging.log("  Timeline parsing functions not available")
                            end

                            -- Parse camera timeline tables from .bin data
                            if Parser.parse_all_camera_tables then
                                EFFECT_EDITOR.camera_tables = Parser.parse_all_camera_tables(
                                    bin_data,
                                    EFFECT_EDITOR.header.timeline_section_ptr
                                )
                                EFFECT_EDITOR.original_camera_tables = Parser.copy_camera_tables(EFFECT_EDITOR.camera_tables)
                                logging.log(string.format("  Parsed %d camera tables from .bin", #EFFECT_EDITOR.camera_tables))
                            else
                                logging.log("  Camera parsing functions not available")
                            end

                            -- Parse color tracks from .bin data
                            if Parser.parse_all_color_tracks then
                                EFFECT_EDITOR.color_tracks = Parser.parse_all_color_tracks(
                                    bin_data,
                                    EFFECT_EDITOR.header.timeline_section_ptr
                                )
                                EFFECT_EDITOR.original_color_tracks = Parser.copy_color_tracks(EFFECT_EDITOR.color_tracks)
                                logging.log(string.format("  Parsed %d color tracks from .bin", #EFFECT_EDITOR.color_tracks))
                            else
                                logging.log("  Color track parsing functions not available")
                            end

                            -- Parse timing curves from .bin data
                            if Parser.parse_timing_curves_from_data then
                                EFFECT_EDITOR.timing_curves = Parser.parse_timing_curves_from_data(
                                    bin_data,
                                    EFFECT_EDITOR.header.timing_curve_ptr
                                )
                                EFFECT_EDITOR.original_timing_curves = Parser.copy_timing_curves(EFFECT_EDITOR.timing_curves)
                                if EFFECT_EDITOR.timing_curves then
                                    logging.log("  Parsed timing curves from .bin")
                                else
                                    logging.log("  No timing curves (timing_curve_ptr = 0)")
                                end
                            else
                                logging.log("  Timing curve parsing functions not available")
                            end

                            -- Parse effect flags from .bin data
                            if Parser.parse_effect_flags_from_data then
                                EFFECT_EDITOR.effect_flags = Parser.parse_effect_flags_from_data(
                                    bin_data,
                                    EFFECT_EDITOR.header.effect_flags_ptr
                                )
                                EFFECT_EDITOR.original_effect_flags = Parser.copy_effect_flags(EFFECT_EDITOR.effect_flags)
                                if EFFECT_EDITOR.effect_flags then
                                    logging.log(string.format("  Parsed effect flags from .bin: 0x%02X", EFFECT_EDITOR.effect_flags.flags_byte))
                                else
                                    logging.log("  Effect flags parsing returned nil")
                                end
                            else
                                logging.log("  Effect flags parsing functions not available")
                            end

                            -- Parse sound flags from .bin data (effect_flags section bytes 0x08-0x17)
                            if Parser.parse_sound_flags_from_data then
                                EFFECT_EDITOR.sound_flags = Parser.parse_sound_flags_from_data(
                                    bin_data,
                                    EFFECT_EDITOR.header.effect_flags_ptr
                                )
                                EFFECT_EDITOR.original_sound_flags = Parser.copy_sound_flags(EFFECT_EDITOR.sound_flags)
                                logging.log("  Parsed 4 sound config channels from .bin")
                            end

                            -- Parse sound definition (feds section) from .bin data
                            if Parser.parse_sound_definition_from_data then
                                local sound_section_size = EFFECT_EDITOR.header.texture_ptr - EFFECT_EDITOR.header.sound_def_ptr
                                if sound_section_size > 0 then
                                    EFFECT_EDITOR.sound_definition = Parser.parse_sound_definition_from_data(
                                        bin_data,
                                        EFFECT_EDITOR.header.sound_def_ptr,
                                        sound_section_size
                                    )
                                    EFFECT_EDITOR.original_sound_definition = Parser.copy_sound_definition(EFFECT_EDITOR.sound_definition)
                                    if EFFECT_EDITOR.sound_definition then
                                        logging.log(string.format("  Parsed feds section from .bin: %d channels",
                                            EFFECT_EDITOR.sound_definition.num_channels))
                                    end
                                end
                            end

                            -- Parse script bytecode from .bin data
                            if Parser.parse_script_from_data then
                                local script_size = EFFECT_EDITOR.header.effect_data_ptr - EFFECT_EDITOR.header.script_data_ptr
                                EFFECT_EDITOR.script_instructions = Parser.parse_script_from_data(
                                    bin_data,
                                    EFFECT_EDITOR.header.script_data_ptr,
                                    script_size
                                )
                                EFFECT_EDITOR.original_script_instructions = Parser.copy_script_instructions(EFFECT_EDITOR.script_instructions)
                                logging.log(string.format("  Parsed %d script instructions (%d bytes) from .bin",
                                    #EFFECT_EDITOR.script_instructions, script_size))
                            end

                            EFFECT_EDITOR.file_name = name .. ".bin"
                            logging.log(string.format("  Parsed %d emitters from .bin", EFFECT_EDITOR.emitter_count))

                            -- Apply loaded edits to PSX memory so effect plays with modifications
                            logging.log("  Applying all edits to memory...")
                            if apply_all_edits_fn then
                                apply_all_edits_fn(true)  -- silent mode
                            end
                            logging.log("  All edits applied to memory")

                            -- Apply texture edits from BMP if it exists
                            if texture_ops then
                                local tex_reloaded = texture_ops.maybe_reload_texture_before_test()
                                if tex_reloaded then
                                    logging.log("  Texture edits applied from BMP")
                                end
                            end
                        else
                            logging.log_error("  .bin file is empty, falling back to memory")
                            if load_from_memory_internal_fn then
                                load_from_memory_internal_fn(base)
                            end
                        end
                    else
                        logging.log("  No .bin file found, parsing from memory")
                        if load_from_memory_internal_fn then
                            load_from_memory_internal_fn(base)
                        end
                    end
                    logging.log("  load_from_memory_internal complete")
                else
                    logging.log_error(string.format("  Invalid base address: 0x%08X", base or 0))
                end
            end
            EFFECT_EDITOR.status_msg = "Loaded: " .. name
            logging.log("=== SESSION LOAD COMPLETE ===")

            -- Resume emulator after loading
            logging.log("  Resuming emulator...")
            PCSX.resumeEmulator()
        end)
    else
        logging.log_error("=== SESSION LOAD FAILED ===")
    end
end

--------------------------------------------------------------------------------
-- ee_refresh_sessions: Refresh list of saved sessions
--------------------------------------------------------------------------------

function M.ee_refresh_sessions()
    EFFECT_EDITOR.session_files = {}

    -- Look for .json files in meta folder using cross-platform file listing
    local files = platform.list_files(config.META_PATH, "*.json")

    for _, filename in ipairs(files) do
        local name = filename:match("(.+)%.json$")
        if name then
            table.insert(EFFECT_EDITOR.session_files, name)
        end
    end

    logging.log(string.format("Found %d session(s) on disk", #EFFECT_EDITOR.session_files))
    return #EFFECT_EDITOR.session_files
end

--------------------------------------------------------------------------------
-- ee_refresh_bins: Legacy alias
--------------------------------------------------------------------------------

function M.ee_refresh_bins()
    return M.ee_refresh_sessions()
end

--------------------------------------------------------------------------------
-- ee_refresh: Legacy alias
--------------------------------------------------------------------------------

function M.ee_refresh()
    return M.ee_refresh_sessions()
end

--------------------------------------------------------------------------------
-- ee_list: List all saved sessions
--------------------------------------------------------------------------------

function M.ee_list()
    M.ee_refresh_sessions()

    print("")
    print("=== SAVED SESSIONS ===")
    print("Meta: " .. config.META_PATH)
    print("")

    if #EFFECT_EDITOR.session_files == 0 then
        print("  (none)")
        print("")
        print("Use ee_arm() then cast a spell to auto-capture")
    else
        for _, name in ipairs(EFFECT_EDITOR.session_files) do
            local marker = (name == EFFECT_EDITOR.session_name) and " <-- current" or ""
            print(string.format("  '%s'%s", name, marker))
        end
    end
    print("")
end

--------------------------------------------------------------------------------
-- ee_copy: Copy a session to a new name
--------------------------------------------------------------------------------

function M.ee_copy(src_name, dst_name)
    if not src_name or not dst_name then
        logging.log_error("Usage: ee_copy('source', 'destination')")
        return false
    end

    if src_name == dst_name then
        logging.log_error("Source and destination names must be different")
        return false
    end

    local copied = 0

    -- Helper to copy a file
    local function copy_file(src_path, dst_path)
        local src_file = io.open(src_path, "rb")
        if not src_file then
            return false
        end
        local content = src_file:read("*all")
        src_file:close()

        local dst_file = io.open(dst_path, "wb")
        if not dst_file then
            return false
        end
        dst_file:write(content)
        dst_file:close()
        return true
    end

    -- Copy .sstate
    local src_ss = config.SAVESTATE_PATH .. src_name .. ".sstate"
    local dst_ss = config.SAVESTATE_PATH .. dst_name .. ".sstate"
    if copy_file(src_ss, dst_ss) then
        copied = copied + 1
        logging.log(string.format("  Copied savestate: %s", dst_name .. ".sstate"))
    end

    -- Copy .bin
    local src_bin = config.EFFECT_BINS_PATH .. src_name .. ".bin"
    local dst_bin = config.EFFECT_BINS_PATH .. dst_name .. ".bin"
    if copy_file(src_bin, dst_bin) then
        copied = copied + 1
        logging.log(string.format("  Copied bin: %s", dst_name .. ".bin"))
    end

    -- Copy and update .json (update the name field)
    local src_meta = config.META_PATH .. src_name .. ".json"
    local dst_meta = config.META_PATH .. dst_name .. ".json"
    local meta_file = io.open(src_meta, "r")
    if meta_file then
        local content = meta_file:read("*all")
        meta_file:close()

        -- Update the name field in the JSON
        content = content:gsub('"name"%s*:%s*"[^"]*"', '"name": "' .. dst_name .. '"')

        local dst_file = io.open(dst_meta, "w")
        if dst_file then
            dst_file:write(content)
            dst_file:close()
            copied = copied + 1
            logging.log(string.format("  Copied meta: %s", dst_name .. ".json"))
        end
    end

    if copied > 0 then
        logging.log(string.format("Copied session '%s' -> '%s' (%d files)", src_name, dst_name, copied))
        M.ee_refresh_sessions()
        EFFECT_EDITOR.status_msg = string.format("Copied: %s -> %s", src_name, dst_name)
        print(string.format("Session '%s' copied to '%s'", src_name, dst_name))
        return true
    else
        logging.log_error(string.format("Could not copy '%s' to '%s'", src_name, dst_name))
        return false
    end
end

--------------------------------------------------------------------------------
-- ee_delete: Delete a session (all files)
--------------------------------------------------------------------------------

function M.ee_delete(name)
    if not name then
        logging.log_error("Usage: ee_delete('name')")
        return false
    end

    local deleted = 0

    -- Delete .sstate
    local ss_path = config.SAVESTATE_PATH .. name .. ".sstate"
    if os.remove(ss_path) then deleted = deleted + 1 end

    -- Delete .bin
    local bin_path = config.EFFECT_BINS_PATH .. name .. ".bin"
    if os.remove(bin_path) then deleted = deleted + 1 end

    -- Delete .json
    local meta_path = config.META_PATH .. name .. ".json"
    if os.remove(meta_path) then deleted = deleted + 1 end

    if deleted > 0 then
        logging.log(string.format("Deleted session '%s' (%d files)", name, deleted))
        if EFFECT_EDITOR.session_name == name then
            EFFECT_EDITOR.session_name = ""
        end
        M.ee_refresh_sessions()
        EFFECT_EDITOR.status_msg = "Deleted: " .. name
        return true
    else
        logging.log_error(string.format("Could not delete '%s'", name))
        return false
    end
end

return M
