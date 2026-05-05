-- mips/known_functions.lua
-- Database of known game functions called by effect code
-- Maps addresses to names, signatures, and semantic meaning

local M = {}

--------------------------------------------------------------------------------
-- Known Function Database
--------------------------------------------------------------------------------

-- Each entry:
--   name: short function name
--   semantic: what it means in high-level terms
--   signature: inputs/outputs
--   category: grouping for pattern matching

M.FUNCTIONS = {
    -- Math functions
    [0x801A8BE0] = {
        name = "lerp",
        semantic = "INTERPOLATE",
        signature = "v0 = a0 + ((a1 - a0) * a2) >> 8",
        category = "math",
        inputs = {"start", "end", "t"},
        output = "interpolated_value",
    },
    [0x8001BB5C] = {
        name = "rsin",
        semantic = "SINE",
        signature = "v0 = sin(a0) * 4096",
        category = "trig",
        inputs = {"angle_4096"},
        output = "sin_scaled",
        notes = "angle 0-4095 = 0-360 degrees",
    },
    [0x8001BC28] = {
        name = "rcos",
        semantic = "COSINE",
        signature = "v0 = cos(a0) * 4096",
        category = "trig",
        inputs = {"angle_4096"},
        output = "cos_scaled",
        notes = "angle 0-4095 = 0-360 degrees",
    },

    -- Graphics / Primitive submission
    [0x80023BB4] = {
        name = "AddPrim",
        semantic = "SUBMIT_PRIMITIVE",
        signature = "AddPrim(OT_entry, primitive_ptr)",
        category = "gpu",
        inputs = {"ot_ptr", "prim_ptr"},
        notes = "Adds primitive to ordering table for rendering",
    },

    -- Memory management
    [0x801A4DE8] = {
        name = "alloc_mem",
        semantic = "ALLOCATE",
        signature = "v0 = alloc_mem(size)",
        category = "memory",
        inputs = {"size"},
        output = "ptr",
    },
    [0x801A4E9C] = {
        name = "free_mem",
        semantic = "FREE",
        signature = "free_mem(ptr)",
        category = "memory",
        inputs = {"ptr"},
    },

    -- Effect system
    [0x801A90D0] = {
        name = "get_anchor_position",
        semantic = "GET_UNIT_POS",
        signature = "get_anchor_position(unit_id, out_x, out_y, out_z)",
        category = "effect",
        inputs = {"unit_id", "out_ptr"},
        notes = "Gets world position of a unit (caster/target)",
    },

    -- Callback system
    [0x801A1288] = {
        name = "resolve_callback",
        semantic = "RESOLVE_CALLBACK",
        signature = "v0 = callback_table[a0 * 4]",
        category = "system",
        inputs = {"callback_id"},
        output = "func_ptr",
    },

    -- Primitive initialization (need to verify these addresses)
    [0x80044A60] = {
        name = "init_primitive",
        semantic = "INIT_PRIM",
        signature = "init_primitive(?)",
        category = "gpu",
        notes = "Initializes primitive structure",
    },

    -- Texture/Script opcodes
    [0x801A2374] = {
        name = "op_set_texture_page",
        semantic = "SET_TEXTURE_PAGE",
        signature = "op_set_texture_page(script_byte >> 4)",
        category = "script",
        inputs = {"effect_state"},
        output = "1 (success)",
        notes = "Sets current_texture_page global from script data",
    },
}

--------------------------------------------------------------------------------
-- Lookup Functions
--------------------------------------------------------------------------------

function M.get_function_info(address)
    return M.FUNCTIONS[address]
end

function M.get_function_name(address)
    local info = M.FUNCTIONS[address]
    if info then
        return info.name
    end
    return nil
end

function M.get_semantic(address)
    local info = M.FUNCTIONS[address]
    if info then
        return info.semantic
    end
    return nil
end

-- Get annotation string for disassembly display
function M.get_annotation(address)
    local info = M.FUNCTIONS[address]
    if not info then return nil end

    local parts = {info.name}

    if info.signature then
        table.insert(parts, ": " .. info.signature)
    end

    return table.concat(parts)
end

--------------------------------------------------------------------------------
-- Category Queries
--------------------------------------------------------------------------------

function M.is_trig_function(address)
    local info = M.FUNCTIONS[address]
    return info and info.category == "trig"
end

function M.is_math_function(address)
    local info = M.FUNCTIONS[address]
    return info and (info.category == "math" or info.category == "trig")
end

function M.is_gpu_function(address)
    local info = M.FUNCTIONS[address]
    return info and info.category == "gpu"
end

--------------------------------------------------------------------------------
-- GTE Instruction Semantics
--------------------------------------------------------------------------------

M.GTE_SEMANTICS = {
    RTPS = {
        semantic = "TRANSFORM_VERTEX_SINGLE",
        description = "Rotate, translate, perspective transform 1 vertex",
        inputs = {"V0"},
        outputs = {"SXY0", "SZ0", "IR0"},
    },
    RTPT = {
        semantic = "TRANSFORM_VERTICES_TRIPLE",
        description = "Rotate, translate, perspective transform 3 vertices",
        inputs = {"V0", "V1", "V2"},
        outputs = {"SXY0", "SXY1", "SXY2", "SZ0", "SZ1", "SZ2"},
        notes = "KEY instruction for 3D rendering - projects 3D to screen",
    },
    MVMVA = {
        semantic = "MATRIX_VECTOR_MULTIPLY",
        description = "Matrix × Vector + Offset",
        notes = "Flexible matrix operation, used for rotations",
    },
    NCLIP = {
        semantic = "NORMAL_CLIP",
        description = "Calculate winding order for backface culling",
        outputs = {"MAC0"},
        notes = "MAC0 < 0 means backfacing",
    },
    AVSZ3 = {
        semantic = "AVERAGE_Z_3",
        description = "Average Z of 3 vertices for depth sorting",
        outputs = {"OTZ"},
    },
    AVSZ4 = {
        semantic = "AVERAGE_Z_4",
        description = "Average Z of 4 vertices for depth sorting",
        outputs = {"OTZ"},
    },
    DPCS = {
        semantic = "DEPTH_CUE_SINGLE",
        description = "Apply depth-based fog/color",
    },
    DPCT = {
        semantic = "DEPTH_CUE_TRIPLE",
        description = "Apply depth-based fog/color to 3 colors",
    },
    NCDS = {
        semantic = "NORMAL_COLOR_DEPTH_SINGLE",
        description = "Lighting calculation with normal",
    },
    SQR = {
        semantic = "SQUARE",
        description = "Square IR1, IR2, IR3",
    },
}

function M.get_gte_semantic(cmd_name)
    return M.GTE_SEMANTICS[cmd_name]
end

--------------------------------------------------------------------------------
-- Primitive Types
--------------------------------------------------------------------------------

M.PRIMITIVE_TYPES = {
    [0x20] = { name = "POLY_F3", desc = "Flat-shaded triangle", verts = 3 },
    [0x24] = { name = "POLY_FT3", desc = "Flat-shaded textured triangle", verts = 3 },
    [0x28] = { name = "POLY_F4", desc = "Flat-shaded quad", verts = 4 },
    [0x2C] = { name = "POLY_FT4", desc = "Flat-shaded textured quad", verts = 4 },
    [0x30] = { name = "POLY_G3", desc = "Gouraud-shaded triangle", verts = 3 },
    [0x34] = { name = "POLY_GT3", desc = "Gouraud-shaded textured triangle", verts = 3 },
    [0x38] = { name = "POLY_G4", desc = "Gouraud-shaded quad", verts = 4 },
    [0x3C] = { name = "POLY_GT4", desc = "Gouraud-shaded textured quad", verts = 4 },
    [0x40] = { name = "LINE_F2", desc = "Flat-shaded line", verts = 2 },
    [0x50] = { name = "LINE_G2", desc = "Gouraud-shaded line", verts = 2 },
    [0x60] = { name = "TILE", desc = "Rectangle primitive" },
    [0x64] = { name = "SPRT", desc = "Sprite primitive" },
}

--------------------------------------------------------------------------------
-- Known Global Variables
--------------------------------------------------------------------------------

-- Global variables at known addresses with semantic meaning
M.GLOBALS = {
    -- Effect State Management
    [0x801bf02c] = { name = "effect_state_array_base", desc = "Base of effect state slots" },
    [0x801bbf90] = { name = "active_effect_list_head", desc = "Head of active effects list" },
    [0x801b9158] = { name = "free_effect_list_head", desc = "Head of free effects list" },
    [0x801b67c8] = { name = "effect_handler_jump_table", desc = "Handler dispatch table" },
    [0x801b63e8] = { name = "effect_system_state", desc = "Effect system state flags" },
    [0x801c24d0] = { name = "current_effect_index", desc = "Currently processing effect" },
    [0x801b48d0] = { name = "effect_file_table", desc = "Effect file lookup table" },

    -- File Data Pointers (from loaded effect file)
    [0x801bc0c8] = { name = "timeline_section_ptr", desc = "Timeline data section" },
    [0x801bbf84] = { name = "timeline_channel_base", desc = "Timeline channel array" },
    [0x801bbf88] = { name = "effect_data_ptr", desc = "Effect parameters data" },
    [0x801bbf8c] = { name = "animation_table_ptr", desc = "Animation definitions" },
    [0x801bbf78] = { name = "sprite_def_table_ptr", desc = "Sprite definitions" },
    [0x801bbf7c] = { name = "effect_anim_tbl_ptr", desc = "Effect animation table" },
    [0x801bacc8] = { name = "effect_flags_ptr", desc = "Effect flags/options" },
    [0x801b9258] = { name = "time_scale_ptr", desc = "Time scale curves" },
    [0x801bc094] = { name = "script_bytecode_ptr", desc = "Script bytecode" },
    [0x801bbf80] = { name = "texture_data_ptr", desc = "Texture page data" },
    [0x801bf000] = { name = "current_texture_page", desc = "Active texture page for sprites" },
    [0x801bbf74] = { name = "sound_section_ptr", desc = "Sound section pointer" },
    [0x801bc0dc] = { name = "sound_data_base", desc = "Sound data base" },
    [0x801bad0c] = { name = "effect_context", desc = "Effect context/parameters" },

    -- Physics Globals
    [0x801b8a40] = { name = "gravity_x", desc = "Gravity vector X" },
    [0x801b8a44] = { name = "gravity_y", desc = "Gravity vector Y" },
    [0x801b8a48] = { name = "gravity_z", desc = "Gravity vector Z" },
    [0x801b8a4c] = { name = "inertia_threshold", desc = "Particle inertia threshold" },

    -- Animation State Pool
    [0x801bf00a] = { name = "anim_state_free_head", desc = "Free anim states" },
    [0x801c24da] = { name = "anim_state_alloc_head", desc = "Allocated anim states" },
    [0x801c00a4] = { name = "anim_state_pool_base", desc = "Animation state pool" },
    [0x801b9270] = { name = "particle_pool_head", desc = "Particle pool head" },

    -- Frame Pacing
    [0x80045998] = { name = "frame_pacing_value", desc = "Frame pacing setting" },
    [0x8004598c] = { name = "frame_pacing_timer", desc = "Frame pacing timer" },

    -- Camera System
    [0x801b69cc] = { name = "camera_track1_state", desc = "Camera track 1 state" },
    [0x801b69d0] = { name = "camera_track2_state", desc = "Camera track 2 state" },
    [0x801b69d4] = { name = "camera_track3_state", desc = "Camera track 3 state" },
    [0x801b8a60] = { name = "camera_track1_data", desc = "Camera track 1 data" },
    [0x801b8a88] = { name = "camera_track2_data", desc = "Camera track 2 data" },
    [0x801b8ad0] = { name = "camera_track3_data", desc = "Camera track 3 data" },

    -- Rendering
    [0x801b9278] = { name = "ordering_table_ptr", desc = "GPU ordering table" },

    -- Effect System State
    [0x801c24c8] = { name = "effect_phase_state", desc = "Effect system phase (0-3)" },
    [0x801c24d4] = { name = "child_effect_index", desc = "Allocated child effect index" },

    -- Line/Primitive Rendering
    [0x801bade4] = { name = "line_count", desc = "Current line primitive count" },
    [0x801bade8] = { name = "line_index_array", desc = "Line index array" },
    [0x801badec] = { name = "line_frame_counter", desc = "Line animation frame" },
    [0x801badf0] = { name = "line_pos_x", desc = "Line position X" },
    [0x801badf2] = { name = "line_pos_y", desc = "Line position Y" },
    [0x801badf4] = { name = "line_pos_z", desc = "Line position Z" },
    [0x801badf8] = { name = "line_time_scale", desc = "Line timing scale" },
    [0x801badfe] = { name = "line_buffer_x", desc = "Line buffer X coords" },
    [0x801bae00] = { name = "line_buffer_z", desc = "Line buffer Z coords" },

    -- Camera Position Slots (Track 2/3 output)
    [0x801b8ad8] = { name = "camera_saved_x", desc = "Camera saved position X" },
    [0x801b8adc] = { name = "camera_saved_y", desc = "Camera saved position Y" },
    [0x801b8ae0] = { name = "camera_saved_z", desc = "Camera saved position Z" },
    [0x801b8ae4] = { name = "camera_saved_w", desc = "Camera saved zoom" },
    [0x801b8ae8] = { name = "camera_start_x", desc = "Camera interpolation start X" },
    [0x801b8aec] = { name = "camera_start_y", desc = "Camera interpolation start Y" },
    [0x801b8af0] = { name = "camera_start_z", desc = "Camera interpolation start Z" },
    [0x801b8af4] = { name = "camera_start_w", desc = "Camera interpolation start W" },
    [0x801b8af8] = { name = "camera_current_x", desc = "Camera current position X" },
    [0x801b8afc] = { name = "camera_current_y", desc = "Camera current position Y" },
    [0x801b8b00] = { name = "camera_current_z", desc = "Camera current position Z" },
    [0x801b8b04] = { name = "camera_current_w", desc = "Camera current zoom" },

    -- Memory Allocator
    [0x801b69a8] = { name = "heap_free_list", desc = "Heap free list head pointer" },

    -- Sprite/Primitive Buffers
    [0x801cc074] = { name = "sprite_buffer_base", desc = "Sprite primitive buffer" },
    [0x801cc094] = { name = "sprite_buffer_1", desc = "Sprite buffer slot 1" },
    [0x801cc0b4] = { name = "sprite_buffer_2", desc = "Sprite buffer slot 2" },
    [0x801cc0d4] = { name = "sprite_buffer_3", desc = "Sprite buffer slot 3" },
    [0x801cc0f4] = { name = "sprite_buffer_4", desc = "Sprite buffer slot 4" },

    -- Miscellaneous
    [0x801b895c] = { name = "effect_audio_state", desc = "Effect audio state" },
    [0x801bbf64] = { name = "effect_target_unit", desc = "Current effect target unit" },
    [0x801b8b4c] = { name = "sound_effect_state", desc = "Sound effect playback state" },
}

function M.get_global_info(address)
    return M.GLOBALS[address]
end

function M.get_global_name(address)
    local info = M.GLOBALS[address]
    if info then
        return info.name
    end
    return nil
end

-- Try to match address to nearest known global (for nearby offsets)
function M.find_nearest_global(address)
    local best_match = nil
    local best_offset = 0x1000  -- Max search range

    for addr, info in pairs(M.GLOBALS) do
        local offset = address - addr
        -- Only positive offsets within reasonable range (structure access)
        if offset >= 0 and offset < best_offset and offset < 256 then
            best_match = { base = addr, info = info, offset = offset }
            best_offset = offset
        end
    end

    return best_match
end

--------------------------------------------------------------------------------
-- Known Constants (CLUT, TPAGE bases)
--------------------------------------------------------------------------------

M.CONSTANTS = {
    [0x7B00] = { name = "CLUT_PALETTE_1", desc = "Palette 1 at VRAM (0, 492)" },
    [0x7B40] = { name = "CLUT_PALETTE_2", desc = "Palette 2 at VRAM (0, 493)" },
}

function M.get_constant_name(value)
    local info = M.CONSTANTS[value]
    if info then
        return info.name
    end
    return nil
end

return M
