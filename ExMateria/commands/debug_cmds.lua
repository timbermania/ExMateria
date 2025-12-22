-- commands/debug.lua
-- Debug and help commands

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local logging = nil
local arm_capture_fn = nil
local disarm_capture_fn = nil

function M.set_dependencies(log_module, arm_fn, disarm_fn)
    logging = log_module
    arm_capture_fn = arm_fn
    disarm_capture_fn = disarm_fn
end

--------------------------------------------------------------------------------
-- ee_help: Show help text
--------------------------------------------------------------------------------

function M.ee_help()
    print("")
    print("=== FFT Effect Editor v0.9.14 - Commands ===")
    print("Sessions persist to disk across PCSX restarts!")
    print("")
    print("QUICK TEST:")
    print("  ee_test()          - TEST CYCLE: reload + apply + resume")
    print("  [Button at top of editor window stays visible when scrolling]")
    print("")
    print("CAPTURE:")
    print("  ee_arm()           - Arm capture (pauses when effect loads)")
    print("  ee_disarm()        - Disarm capture")
    print("")
    print("SAVE BUTTONS:")
    print("  [Raw Save]         - Save state + bin as-is (for NEW captures)")
    print("  [Save Bin]         - Reload + apply edits + save bin (for EDITING)")
    print("  [Save State]       - Save just savestate (to FIX broken states)")
    print("")
    print("SESSION COMMANDS:")
    print("  ee_raw_save()      - Save state + bin + metadata as-is")
    print("  ee_save_bin_edited() - Reload, apply edits, save bin only")
    print("  ee_save_state_only() - Save just the savestate")
    print("  ee_reload('name')  - Load savestate from file")
    print("  ee_load_session()  - Load full session (metadata + savestate)")
    print("  ee_list()          - List saved sessions")
    print("  ee_copy('src','dst') - Copy session to new name (experiment)")
    print("  ee_delete('name')  - Delete session (.sstate + .bin + .json)")
    print("")
    print("MEMORY:")
    print("  ee_apply()         - Apply emitter edits to PSX memory")
    print("  ee_mem(addr)       - Parse effect from memory address")
    print("")
    print("EFFECT FILES:")
    print("  ee_load(N)         - Load E###.BIN from game files")
    print("  ee_load_bin('name')- Load .bin into memory")
    print("")
    print("WINDOW:")
    print("  ee_show() / ee_hide()")
    print("")
    print("DEBUG:")
    print("  ee_status(), ee_verbose(), ee_error(), ee_dump(), ee_help()")
    print("")
    print("=== WORKFLOW ===")
    print("  NEW SESSION:")
    print("    1. ee_arm()              -- Arm capture")
    print("    2. Cast spell            -- Emulator pauses")
    print("    3. Enter session name")
    print("    4. Click [Raw Save]      -- Creates .sstate + .bin + .json")
    print("")
    print("  EDITING:")
    print("    1. Click session in list -- Loads savestate")
    print("    2. Edit emitter params")
    print("    3. Click [Save Bin]      -- Reload + apply + save bin")
    print("    4. ee_test() or button   -- Test your changes")
    print("")
    print("  FIX BROKEN SAVESTATE:")
    print("    1. ee_arm(), cast spell  -- Re-capture effect")
    print("    2. Enter existing session name")
    print("    3. Click [Save State]    -- Overwrites .sstate only")
    print("")
    print("  TIP: Save creates your session. No auto-save on capture.")
    print("")
end

--------------------------------------------------------------------------------
-- ee_show / ee_hide: Window visibility
--------------------------------------------------------------------------------

function M.ee_show()
    EFFECT_EDITOR.window_open = true
end

function M.ee_hide()
    EFFECT_EDITOR.window_open = false
end

--------------------------------------------------------------------------------
-- ee_error: Show last error
--------------------------------------------------------------------------------

function M.ee_error()
    if EFFECT_EDITOR_LAST_ERROR then
        print("=== Last Effect Editor Error ===")
        print(tostring(EFFECT_EDITOR_LAST_ERROR))
    else
        print("No errors recorded")
    end
end

--------------------------------------------------------------------------------
-- ee_dump: Dump editor state
--------------------------------------------------------------------------------

function M.ee_dump()
    print("=== Effect Editor State ===")
    print(string.format("window_open: %s", tostring(EFFECT_EDITOR.window_open)))
    print(string.format("verbose: %s", tostring(logging.is_verbose())))
    print(string.format("file_name: %s", EFFECT_EDITOR.file_name or "nil"))
    print(string.format("file_path: %s", EFFECT_EDITOR.file_path or "nil"))
    print(string.format("effect_number: %s", EFFECT_EDITOR.effect_number or "nil"))
    print(string.format("emitter_count: %s", tostring(EFFECT_EDITOR.emitter_count)))
    print(string.format("status_msg: %s", EFFECT_EDITOR.status_msg or "nil"))
    if EFFECT_EDITOR.header then
        print("header: loaded")
        print(string.format("  frames_ptr: 0x%08X", EFFECT_EDITOR.header.frames_ptr or 0))
        print(string.format("  effect_data_ptr: 0x%08X", EFFECT_EDITOR.header.effect_data_ptr or 0))
    else
        print("header: nil")
    end
end

--------------------------------------------------------------------------------
-- ee_verbose: Toggle verbose logging
--------------------------------------------------------------------------------

function M.ee_verbose(on)
    if on == nil then
        -- Toggle
        logging.set_verbose(not logging.is_verbose())
    else
        logging.set_verbose(on)
    end
    logging.log("Verbose logging: " .. (logging.is_verbose() and "ON" or "OFF"))
end

--------------------------------------------------------------------------------
-- ee_status: Show current effect status
--------------------------------------------------------------------------------

function M.ee_status()
    if not EFFECT_EDITOR.header then
        print("No effect loaded")
        return
    end

    print(string.format("=== %s ===", EFFECT_EDITOR.file_name))
    print(string.format("Format: %s", EFFECT_EDITOR.header.format))
    print(string.format("Emitters: %d", EFFECT_EDITOR.emitter_count))
    print("")
    print("Header pointers:")
    print(string.format("  frames_ptr:    0x%08X", EFFECT_EDITOR.header.frames_ptr))
    print(string.format("  animation_ptr: 0x%08X", EFFECT_EDITOR.header.animation_ptr))
    print(string.format("  script_ptr:    0x%08X", EFFECT_EDITOR.header.script_data_ptr))
    print(string.format("  effect_ptr:    0x%08X", EFFECT_EDITOR.header.effect_data_ptr))
    print(string.format("  anim_table:    0x%08X", EFFECT_EDITOR.header.anim_table_ptr))
    print(string.format("  timing_curve:  0x%08X", EFFECT_EDITOR.header.timing_curve_ptr))
    print(string.format("  effect_flags:  0x%08X", EFFECT_EDITOR.header.effect_flags_ptr))
    print(string.format("  timeline:      0x%08X", EFFECT_EDITOR.header.timeline_section_ptr))
    print(string.format("  sound_def:     0x%08X", EFFECT_EDITOR.header.sound_def_ptr))
    print(string.format("  texture:       0x%08X", EFFECT_EDITOR.header.texture_ptr))
end

--------------------------------------------------------------------------------
-- ee_arm / ee_disarm: Capture control
--------------------------------------------------------------------------------

function M.ee_arm()
    if arm_capture_fn then
        arm_capture_fn()
    end
end

function M.ee_disarm()
    if disarm_capture_fn then
        disarm_capture_fn()
    end
end

return M
