-- ui/camera_tab.lua
-- Camera Timeline tab for editing camera keyframes

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local helpers = nil

function M.set_dependencies(helpers_mod)
    helpers = helpers_mod
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local TABLE_NAMES = {
    [1] = "Table 0: Phase-1 Camera",
    [2] = "Table 1: For-Each Camera",
    [3] = "Table 2: Phase-2 Camera",
}

local TABLE_DESCRIPTIONS = {
    [1] = "Active during phase-1 (frames 0 to phase1_duration-1)",
    [2] = "Active during for-each spawning (per-target timing offsets)",
    [3] = "Active during phase-2 (cleanup/return to battle camera)",
}

local MAX_CAMERA_KEYFRAMES = 17

-- Position source decoding (bits 5-8, mask 0x01E0)
-- Must use ordered arrays for imgui.Combo (expects null-separated string)
local POSITION_SOURCE_BITS = {
    0x000, 0x020, 0x040, 0x060, 0x080, 0x0C0, 0x100, 0x140, 0x180, 0x1C0
}
local POSITION_SOURCE_NAMES = {
    "TARGET", "OFFSET", "DIRECT", "ORIGIN", "EFFECT_CTR",
    "MAP", "SLOT_COPY", "CASTER", "ALL_TARGETS", "CURSOR"
}
local POSITION_SOURCE_ITEMS = table.concat(POSITION_SOURCE_NAMES, "\000") .. "\000"

-- Build reverse lookup for bits -> index
local POSITION_SOURCE_LOOKUP = {}
for i, bits in ipairs(POSITION_SOURCE_BITS) do
    POSITION_SOURCE_LOOKUP[bits] = i
end

-- Interpolation curve decoding (bits 9-12, mask 0x1E00)
local INTERPOLATION_BITS = {
    0x0000, 0x0200, 0x0400, 0x0600, 0x0800, 0x0A00, 0x0C00, 0x0E00, 0x1000, 0x1200, 0x1400
}
local INTERPOLATION_NAMES = {
    "(none)", "IMMEDIATE", "COSINE_A", "COSINE_B", "LINEAR",
    "COSINE_C", "ADDITIVE", "ADDITIVE_B", "SHAKE_DAMPED", "SHAKE_DIRECT", "SHAKE_DAMPED_B"
}
local INTERPOLATION_ITEMS = table.concat(INTERPOLATION_NAMES, "\000") .. "\000"

-- Build reverse lookup for bits -> index
local INTERPOLATION_LOOKUP = {}
for i, bits in ipairs(INTERPOLATION_BITS) do
    INTERPOLATION_LOOKUP[bits] = i
end

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

local function decode_command(cmd)
    local track_angle = (cmd % 2) == 1
    local track_position = (math.floor(cmd / 2) % 2) == 1
    local track_zoom = (math.floor(cmd / 4) % 2) == 1

    local pos_source_bits = cmd % 0x200 - cmd % 0x20
    local pos_source_idx = POSITION_SOURCE_LOOKUP[pos_source_bits] or 1
    local pos_source = POSITION_SOURCE_NAMES[pos_source_idx] or string.format("0x%03X", pos_source_bits)

    local interp_bits = cmd % 0x2000 - cmd % 0x200
    local interp_idx = INTERPOLATION_LOOKUP[interp_bits] or 1
    local interp = INTERPOLATION_NAMES[interp_idx] or string.format("0x%04X", interp_bits)

    return {
        track_angle = track_angle,
        track_position = track_position,
        track_zoom = track_zoom,
        pos_source = pos_source,
        pos_source_bits = pos_source_bits,
        pos_source_idx = pos_source_idx,
        interp = interp,
        interp_bits = interp_bits,
        interp_idx = interp_idx,
    }
end

local function encode_command(decoded)
    local cmd = 0
    if decoded.track_angle then cmd = cmd + 1 end
    if decoded.track_position then cmd = cmd + 2 end
    if decoded.track_zoom then cmd = cmd + 4 end
    cmd = cmd + decoded.pos_source_bits
    cmd = cmd + decoded.interp_bits
    return cmd
end

local function zoom_to_scale(zoom)
    return zoom / 4096.0
end

--------------------------------------------------------------------------------
-- Draw Single Keyframe
--------------------------------------------------------------------------------

local function draw_keyframe(table_data, kf_index, table_idx)
    local kf = table_data.keyframes[kf_index]
    if not kf then return end

    local uid = string.format("t%d_kf%d", table_idx, kf_index)

    -- Build summary for display (shown on same line as tree node)
    local decoded = decode_command(kf.command)
    local tracks = ""
    if decoded.track_angle then tracks = tracks .. "A" end
    if decoded.track_position then tracks = tracks .. "P" end
    if decoded.track_zoom then tracks = tracks .. "Z" end
    if tracks == "" then tracks = "-" end

    local zoom_scale = zoom_to_scale(kf.zoom)

    -- Use STATIC label for TreeNode (just index) - prevents collapse on value change
    -- Dynamic summary shown separately via SameLine + Text
    local node_label = string.format("Keyframe [%d]##%s", kf_index - 1, uid)
    local is_open = imgui.TreeNode(node_label)

    -- Always show summary on same line (whether open or closed)
    imgui.SameLine()
    imgui.TextUnformatted(string.format("End:%d  Tracks:%s  Zoom:%.2fx",
        kf.end_frame, tracks, zoom_scale))

    if is_open then
        local c, v

        -- End frame
        c, v = imgui.DragInt("End Frame##" .. uid, kf.end_frame, 1, 0, 9999)
        if c then kf.end_frame = v end

        imgui.Separator()

        -- Angles (4096 = 360°, range ±720°)
        imgui.TextUnformatted("Angles:")
        c, v = imgui.SliderInt("Pitch##" .. uid, kf.pitch, -8192, 8192)
        if c then kf.pitch = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("%.1f°", kf.pitch / 4096 * 360))

        c, v = imgui.SliderInt("Yaw##" .. uid, kf.yaw, -8192, 8192)
        if c then kf.yaw = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("%.1f°", kf.yaw / 4096 * 360))

        c, v = imgui.SliderInt("Roll##" .. uid, kf.roll, -8192, 8192)
        if c then kf.roll = v end
        imgui.SameLine()
        imgui.TextUnformatted(string.format("%.1f°", kf.roll / 4096 * 360))

        imgui.Separator()

        -- Position
        imgui.TextUnformatted("Position:")
        c, v = imgui.SliderInt("X##pos" .. uid, kf.pos_x, -32768, 32767)
        if c then kf.pos_x = v end
        c, v = imgui.SliderInt("Y##pos" .. uid, kf.pos_y, -32768, 32767)
        if c then kf.pos_y = v end
        c, v = imgui.SliderInt("Z##pos" .. uid, kf.pos_z, -32768, 32767)
        if c then kf.pos_z = v end

        imgui.Separator()

        -- Zoom
        imgui.TextUnformatted(string.format("Zoom: %d (%.2fx)", kf.zoom, zoom_scale))
        c, v = imgui.SliderInt("Zoom##" .. uid, kf.zoom, 1024, 8192)
        if c then kf.zoom = v end

        imgui.Separator()

        -- Command word (displayed inline like other fields)
        imgui.TextUnformatted(string.format("Command: 0x%04X", kf.command))

        -- Track enable checkboxes
        c, v = imgui.Checkbox("Angles##trk" .. uid, decoded.track_angle)
        if c then
            decoded.track_angle = v
            kf.command = encode_command(decoded)
        end
        imgui.SameLine()
        c, v = imgui.Checkbox("Position##trk" .. uid, decoded.track_position)
        if c then
            decoded.track_position = v
            kf.command = encode_command(decoded)
        end
        imgui.SameLine()
        c, v = imgui.Checkbox("Zoom##trk" .. uid, decoded.track_zoom)
        if c then
            decoded.track_zoom = v
            kf.command = encode_command(decoded)
        end

        -- Position source combo
        imgui.SetNextItemWidth(120)
        c, v = imgui.Combo("Pos Source##" .. uid, decoded.pos_source_idx - 1, POSITION_SOURCE_ITEMS)
        if c then
            decoded.pos_source_bits = POSITION_SOURCE_BITS[v + 1]
            kf.command = encode_command(decoded)
        end

        -- Interpolation curve combo
        imgui.SetNextItemWidth(120)
        c, v = imgui.Combo("Interpolation##" .. uid, decoded.interp_idx - 1, INTERPOLATION_ITEMS)
        if c then
            decoded.interp_bits = INTERPOLATION_BITS[v + 1]
            kf.command = encode_command(decoded)
        end

        imgui.TreePop()
    end
end

--------------------------------------------------------------------------------
-- Draw Single Camera Table
--------------------------------------------------------------------------------

local function draw_camera_table(table_data, table_idx)
    if not table_data then return end

    local uid = "camtab" .. table_idx

    -- Collapsible header with table name
    local header_flags = (table_idx == 1) and 32 or 0  -- DefaultOpen for Table 0
    if imgui.CollapsingHeader(TABLE_NAMES[table_idx] .. "##" .. uid, header_flags) then
        imgui.Indent()

        imgui.TextUnformatted(TABLE_DESCRIPTIONS[table_idx])
        imgui.Separator()

        -- Max keyframe slider
        local c, v = imgui.SliderInt("Max Keyframe##" .. uid, table_data.max_keyframe, -1, MAX_CAMERA_KEYFRAMES - 1)
        if c then table_data.max_keyframe = v end
        imgui.SameLine()
        imgui.TextUnformatted("(last valid keyframe index)")

        imgui.Separator()

        -- Draw all keyframes (camera uses [0] unlike particle channels)
        for kf_index = 1, MAX_CAMERA_KEYFRAMES do
            -- Only show keyframes up to max_keyframe + 2 for editing purposes
            if kf_index <= table_data.max_keyframe + 3 or kf_index <= 3 then
                draw_keyframe(table_data, kf_index, table_idx)
            end
        end

        imgui.Unindent()
    end
end

--------------------------------------------------------------------------------
-- Main Draw Function
--------------------------------------------------------------------------------

function M.draw()
    if not EFFECT_EDITOR.camera_tables then
        imgui.TextUnformatted("No camera timeline data loaded")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("Camera data is part of the timeline section.")
        imgui.TextUnformatted("Load an effect file to edit camera keyframes.")
        return
    end

    -- Help section
    if imgui.CollapsingHeader("Camera Timeline Help") then
        imgui.Indent()
        imgui.TextUnformatted("3 camera tables control different phases of the effect:")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("  Table 0 (Phase-1 Camera): Primary effect camera")
        imgui.TextUnformatted("    Active: frames 0 to phase1_duration-1")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("  Table 1 (For-Each Camera): Per-target adjustments")
        imgui.TextUnformatted("    Active: during for-each spawning with per-target timing")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("  Table 2 (Phase-2 Camera): Restore pre-turn camera")
        imgui.TextUnformatted("    Active: phase2_start onwards")
        imgui.TextUnformatted("")
        imgui.Separator()
        imgui.TextUnformatted("Track Enable bits control which data is used:")
        imgui.TextUnformatted("  A = Angles (pitch/yaw/roll)")
        imgui.TextUnformatted("  P = Position (X/Y/Z)")
        imgui.TextUnformatted("  Z = Zoom")
        imgui.TextUnformatted("")
        imgui.TextUnformatted("Zoom: 4096 = 1.0x (normal)")
        imgui.TextUnformatted("  < 4096 = zoomed out, > 4096 = zoomed in")
        imgui.Unindent()
    end

    imgui.Separator()

    -- Draw all 3 tables
    for i = 1, 3 do
        draw_camera_table(EFFECT_EDITOR.camera_tables[i], i)
    end
end

return M
