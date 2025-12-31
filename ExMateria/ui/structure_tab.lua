-- ui/structure_tab.lua
-- Structure tab showing file header and sections

local M = {}

--------------------------------------------------------------------------------
-- Structure Tab Drawing
--------------------------------------------------------------------------------

function M.draw()
    local h = EFFECT_EDITOR.header

    imgui.TextUnformatted(string.format("File: %s", EFFECT_EDITOR.file_name))
    imgui.TextUnformatted(string.format("Format: %s", h.format or "?"))
    if h.file_size then
        imgui.TextUnformatted(string.format("Size: %d bytes (0x%X)", h.file_size, h.file_size))
    end
    if h.base_addr then
        imgui.TextUnformatted(string.format("Base: 0x%08X", h.base_addr))
    end

    imgui.Separator()
    imgui.TextUnformatted("Header Pointers:")

    -- Header pointer table
    imgui.Columns(3, "header_cols")
    imgui.TextUnformatted("Field")
    imgui.NextColumn()
    imgui.TextUnformatted("Offset")
    imgui.NextColumn()
    imgui.TextUnformatted("Value")
    imgui.NextColumn()
    imgui.Separator()

    local fields = {
        {"frames_ptr", 0x00, h.frames_ptr},
        {"animation_ptr", 0x04, h.animation_ptr},
        {"script_data_ptr", 0x08, h.script_data_ptr},
        {"effect_data_ptr", 0x0C, h.effect_data_ptr},
        {"anim_table_ptr", 0x10, h.anim_table_ptr},
        {"time_scale_ptr", 0x14, h.time_scale_ptr},
        {"effect_flags_ptr", 0x18, h.effect_flags_ptr},
        {"timeline_section_ptr", 0x1C, h.timeline_section_ptr},
        {"sound_def_ptr", 0x20, h.sound_def_ptr},
        {"texture_ptr", 0x24, h.texture_ptr},
    }

    for _, f in ipairs(fields) do
        imgui.TextUnformatted(f[1])
        imgui.NextColumn()
        imgui.TextUnformatted(string.format("0x%02X", f[2]))
        imgui.NextColumn()
        imgui.TextUnformatted(string.format("0x%08X", f[3]))
        imgui.NextColumn()
    end

    imgui.Columns(1)

    imgui.Separator()
    imgui.TextUnformatted("Sections:")

    -- Section table
    imgui.Columns(3, "section_cols")
    imgui.TextUnformatted("Section")
    imgui.NextColumn()
    imgui.TextUnformatted("Offset")
    imgui.NextColumn()
    imgui.TextUnformatted("Size")
    imgui.NextColumn()
    imgui.Separator()

    for _, sec in ipairs(EFFECT_EDITOR.sections) do
        imgui.TextUnformatted(sec.name)
        imgui.NextColumn()
        imgui.TextUnformatted(string.format("0x%04X", sec.offset))
        imgui.NextColumn()
        imgui.TextUnformatted(string.format("0x%04X (%d)", sec.size, sec.size))
        imgui.NextColumn()
    end

    imgui.Columns(1)
end

return M
