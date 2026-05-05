-- particle_lifecycle_capture.lua
-- Complete particle lifecycle recording: every particle, every field, every frame
--
-- Uses 4 breakpoints:
--   BP1: Effect Start (0x801A1920) - begin recording
--   BP2: Spawn ENTRY (0x801A60AC) + EXIT (0x801A7F54) - track which emitter spawned which particle
--   BP3: Per-Frame (0x801A2EB4) - snapshot all particle fields
--   BP4: User-triggered stop - export CSV
--
-- Output: CSV file with all particle fields across all frames

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (injected)
--------------------------------------------------------------------------------

local MemUtils = nil
local particle_reader = nil
local config = nil

function M.set_dependencies(mem_utils, pr_module, config_module)
    MemUtils = mem_utils
    particle_reader = pr_module
    config = config_module
end

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Effect initialization (caseD_2 after effect_idx stored)
M.EFFECT_INIT_ADDR = 0x801A1920

-- emitter_control_routine entry and exit
M.EMITTER_CONTROL_ENTRY = 0x801A60AC
M.EMITTER_CONTROL_EXIT = 0x801A7F54

-- update_all_particles - fires once per frame per active effect
M.UPDATE_PARTICLES_ADDR = 0x801A2EB4

-- EffectState struct offsets
M.EFFECT_STATE_FRAME_OFFSET = 0x20  -- int32 frame counter
M.EFFECT_STATE_PARTICLE_LIST_OFFSET = 0xD0  -- Particle* list head

--------------------------------------------------------------------------------
-- State (stored in global to avoid GC)
--------------------------------------------------------------------------------

-- Initialize global state if not exists
if not PARTICLE_LIFECYCLE_CAPTURE then
    PARTICLE_LIFECYCLE_CAPTURE = {
        recording = false,
        effect_idx = -1,

        -- Pending spawn (between ENTRY and EXIT)
        pending_spawn = nil,  -- {emitter_idx, frame, old_addrs={}}

        -- Spawn registry: particle_addr -> {emitter_idx, spawn_frame}
        spawn_map = {},

        -- Frame snapshots: array of {frame_num, particles={addr -> data}}
        frames = {},

        -- Stats
        total_snapshots = 0,
    }
end

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Check if address is valid PSX RAM
local function is_valid_addr(addr)
    return addr ~= 0 and addr >= 0x80000000 and addr < 0x80200000
end

-- Get all current particle addresses as a set
local function snapshot_particle_addresses(effect_idx)
    if not particle_reader then return {} end

    local addrs = {}
    local particles = particle_reader.read_all_particles(effect_idx, 256)
    for _, p in ipairs(particles) do
        addrs[p.addr] = true
    end
    return addrs
end

-- Read all particle fields into a table
local function read_particle_full(addr)
    if not MemUtils or not is_valid_addr(addr) then return nil end

    local P = particle_reader.PARTICLE
    local p = {}

    -- Convert signed 32-bit
    local function to_signed32(value)
        if value >= 0x80000000 then
            return value - 0x100000000
        end
        return value
    end

    p.addr = addr

    -- Linked list (for traversal, not exported)
    p.next = MemUtils.read32(addr + P.next)

    -- Physics constants
    p.inertia = MemUtils.read16s(addr + P.inertia)
    p.weight = MemUtils.read16s(addr + P.weight)

    -- Position (raw fixed-point)
    p.pos_x = to_signed32(MemUtils.read32(addr + P.position_x))
    p.pos_y = to_signed32(MemUtils.read32(addr + P.position_y))
    p.pos_z = to_signed32(MemUtils.read32(addr + P.position_z))

    -- Velocity (raw fixed-point)
    p.vel_x = to_signed32(MemUtils.read32(addr + P.velocity_x))
    p.vel_y = to_signed32(MemUtils.read32(addr + P.velocity_y))
    p.vel_z = to_signed32(MemUtils.read32(addr + P.velocity_z))

    -- Acceleration (raw fixed-point)
    p.acc_x = to_signed32(MemUtils.read32(addr + P.acceleration_x))
    p.acc_y = to_signed32(MemUtils.read32(addr + P.acceleration_y))
    p.acc_z = to_signed32(MemUtils.read32(addr + P.acceleration_z))

    -- Drag (raw fixed-point)
    p.drag_x = to_signed32(MemUtils.read32(addr + P.drag_x))
    p.drag_y = to_signed32(MemUtils.read32(addr + P.drag_y))
    p.drag_z = to_signed32(MemUtils.read32(addr + P.drag_z))

    -- Target position (world units)
    p.tgt_x = MemUtils.read16s(addr + P.target_x)
    p.tgt_y = MemUtils.read16s(addr + P.target_y)
    p.tgt_z = MemUtils.read16s(addr + P.target_z)

    -- Lifetime
    p.life = MemUtils.read16s(addr + P.lifetime_counter)

    -- Homing
    p.hom_str = MemUtils.read16s(addr + P.homing_strength)
    p.hom_crv = MemUtils.read8(addr + P.homing_curve_index)

    -- Flags
    p.mo_flg = MemUtils.read16(addr + P.motion_flags)
    p.be_flg = MemUtils.read16(addr + P.behavior_flags)

    -- Animation
    p.anim_f = MemUtils.read16(addr + P.anim_frame_counter)

    -- Child emitters
    p.ch_dth = MemUtils.read8(addr + P.child_emitter_on_death)
    p.ch_mid = MemUtils.read8(addr + P.child_emitter_mid_life)

    -- Color curves
    p.col_r = MemUtils.read8(addr + P.color_r_curve)
    p.col_g = MemUtils.read8(addr + P.color_g_curve)
    p.col_b = MemUtils.read8(addr + P.color_b_curve)

    return p
end

--------------------------------------------------------------------------------
-- Breakpoint Callbacks
--------------------------------------------------------------------------------

-- BP1: Effect Start
local function on_effect_init(addr, width, cause)
    if not PARTICLE_LIFECYCLE_CAPTURE.recording then
        return true
    end

    -- Read effect index from $s0 (set earlier in caseD_2)
    local regs = PCSX.getRegisters()
    local effect_idx = regs.GPR.n.s0

    -- Only record the first effect we see (ignore child effects)
    if PARTICLE_LIFECYCLE_CAPTURE.effect_idx == -1 then
        PARTICLE_LIFECYCLE_CAPTURE.effect_idx = effect_idx
        print(string.format("[Lifecycle] Effect %d started", effect_idx))
    end

    return true
end

-- Debug: track BP hits
local debug_bp_hits = {
    spawn_entry = 0,
    spawn_exit = 0,
    frame_update = 0,
}

-- Debug: track effect_idx values seen
local debug_effect_idx_seen = {}

-- BP2a: Spawn ENTRY - snapshot current particle addresses
local function on_spawn_entry(addr, width, cause)
    debug_bp_hits.spawn_entry = debug_bp_hits.spawn_entry + 1

    if not PARTICLE_LIFECYCLE_CAPTURE.recording then
        return true
    end

    local regs = PCSX.getRegisters()
    local effect_idx = regs.GPR.n.a0
    local frame = regs.GPR.n.a1
    local emitter_idx = regs.GPR.n.a2

    -- Debug: track what effect_idx values we see
    debug_effect_idx_seen[effect_idx] = (debug_effect_idx_seen[effect_idx] or 0) + 1

    -- Track ALL effects (parent effect spawns child effects which spawn particles)
    -- Snapshot current particle addresses before spawn
    local old_addrs = snapshot_particle_addresses(effect_idx)
    local old_count = 0
    for _ in pairs(old_addrs) do old_count = old_count + 1 end

    PARTICLE_LIFECYCLE_CAPTURE.pending_spawn = {
        effect_idx = effect_idx,  -- track which effect this spawn is from
        emitter_idx = emitter_idx,
        frame = frame,
        old_addrs = old_addrs,
        old_count = old_count,  -- debug
    }

    return true
end

-- BP2b: Spawn EXIT - diff addresses to find new particles
local function on_spawn_exit(addr, width, cause)
    debug_bp_hits.spawn_exit = debug_bp_hits.spawn_exit + 1

    if not PARTICLE_LIFECYCLE_CAPTURE.recording then
        return true
    end

    local pending = PARTICLE_LIFECYCLE_CAPTURE.pending_spawn
    if not pending then
        return true
    end

    -- Snapshot current addresses after spawn (use the effect_idx from entry)
    local new_addrs = snapshot_particle_addresses(pending.effect_idx)

    -- Find newly added particles (in new but not in old)
    for addr, _ in pairs(new_addrs) do
        if not pending.old_addrs[addr] then
            -- This particle was just spawned
            PARTICLE_LIFECYCLE_CAPTURE.spawn_map[addr] = {
                effect_idx = pending.effect_idx,
                emitter_idx = pending.emitter_idx,
                spawn_frame = pending.frame,
            }
        end
    end

    PARTICLE_LIFECYCLE_CAPTURE.pending_spawn = nil
    return true
end

-- BP3: Per-Frame snapshot
local function on_frame_update(addr, width, cause)
    debug_bp_hits.frame_update = debug_bp_hits.frame_update + 1

    if not PARTICLE_LIFECYCLE_CAPTURE.recording then
        return true
    end

    -- $a0 = EffectState*
    local regs = PCSX.getRegisters()
    local effect_state_ptr = regs.GPR.n.a0

    if not is_valid_addr(effect_state_ptr) then
        return true
    end

    -- Read effect index from EffectState (offset 0x00 is effect_index)
    local effect_idx = MemUtils.read16(effect_state_ptr)

    -- Track ALL effects that have particles (not just target)
    -- Read frame number
    local frame_num = MemUtils.read32(effect_state_ptr + M.EFFECT_STATE_FRAME_OFFSET)

    -- Read particle list head
    local list_head = MemUtils.read32(effect_state_ptr + M.EFFECT_STATE_PARTICLE_LIST_OFFSET)

    -- Traverse particle list and snapshot all
    local frame_data = {
        frame_num = frame_num,
        effect_idx = effect_idx,
        particles = {},
    }

    local current = list_head
    local count = 0
    local visited = {}

    while is_valid_addr(current) and count < 256 do
        if visited[current] then break end
        visited[current] = true

        local p = read_particle_full(current)
        if not p then break end

        -- Add spawn info from spawn_map
        local spawn_info = PARTICLE_LIFECYCLE_CAPTURE.spawn_map[current]
        if spawn_info then
            p.emitter_idx = spawn_info.emitter_idx
            p.spawn_frame = spawn_info.spawn_frame
            p.spawn_effect_idx = spawn_info.effect_idx
        else
            p.emitter_idx = -1
            p.spawn_frame = -1
            p.spawn_effect_idx = -1
        end

        -- Also store current effect_idx
        p.effect_idx = effect_idx

        frame_data.particles[current] = p
        PARTICLE_LIFECYCLE_CAPTURE.total_snapshots = PARTICLE_LIFECYCLE_CAPTURE.total_snapshots + 1

        current = p.next
        count = count + 1
    end

    table.insert(PARTICLE_LIFECYCLE_CAPTURE.frames, frame_data)

    return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Start capture (arms breakpoints, waits for effect to start)
function M.start_capture()
    -- Clear any existing breakpoints
    M.cleanup_breakpoints()

    -- Reset state
    PARTICLE_LIFECYCLE_CAPTURE.recording = true
    PARTICLE_LIFECYCLE_CAPTURE.effect_idx = -1
    PARTICLE_LIFECYCLE_CAPTURE.pending_spawn = nil
    PARTICLE_LIFECYCLE_CAPTURE.spawn_map = {}
    PARTICLE_LIFECYCLE_CAPTURE.frames = {}
    PARTICLE_LIFECYCLE_CAPTURE.total_snapshots = 0

    -- Reset debug counters
    debug_bp_hits.spawn_entry = 0
    debug_bp_hits.spawn_exit = 0
    debug_bp_hits.frame_update = 0
    debug_effect_idx_seen = {}

    -- Create breakpoints (stored in globals to prevent GC)
    LIFECYCLE_BP_INIT = PCSX.addBreakpoint(
        M.EFFECT_INIT_ADDR, 'Exec', 4, 'LifecycleInit', on_effect_init
    )

    LIFECYCLE_BP_SPAWN_ENTRY = PCSX.addBreakpoint(
        M.EMITTER_CONTROL_ENTRY, 'Exec', 4, 'LifecycleSpawnEntry', on_spawn_entry
    )

    LIFECYCLE_BP_SPAWN_EXIT = PCSX.addBreakpoint(
        M.EMITTER_CONTROL_EXIT, 'Exec', 4, 'LifecycleSpawnExit', on_spawn_exit
    )

    LIFECYCLE_BP_FRAME = PCSX.addBreakpoint(
        M.UPDATE_PARTICLES_ADDR, 'Exec', 4, 'LifecycleFrame', on_frame_update
    )

    print("[Lifecycle] Capture armed - waiting for effect to start")
end

-- Stop capture
function M.stop_capture()
    PARTICLE_LIFECYCLE_CAPTURE.recording = false

    local stats = M.get_stats()
    print(string.format("[Lifecycle] Capture stopped: %d frames, %d snapshots, %d unique particles",
        stats.frame_count, stats.total_snapshots, stats.unique_particles))

    -- Debug: show breakpoint hit counts
    print(string.format("[Lifecycle] BP hits: spawn_entry=%d, spawn_exit=%d, frame_update=%d",
        debug_bp_hits.spawn_entry, debug_bp_hits.spawn_exit, debug_bp_hits.frame_update))

    -- Debug: show effect_idx values seen at spawn entry
    print(string.format("[Lifecycle] Target effect_idx=%d, seen effect_idx values:",
        PARTICLE_LIFECYCLE_CAPTURE.effect_idx))
    for eidx, count in pairs(debug_effect_idx_seen) do
        print(string.format("  effect_idx %d: %d times", eidx, count))
    end

    -- Debug: show spawn_map size
    local spawn_map_size = 0
    for _ in pairs(PARTICLE_LIFECYCLE_CAPTURE.spawn_map) do
        spawn_map_size = spawn_map_size + 1
    end
    print(string.format("[Lifecycle] spawn_map has %d entries", spawn_map_size))
end

-- Check if capturing
function M.is_capturing()
    return PARTICLE_LIFECYCLE_CAPTURE.recording
end

-- Get capture statistics
function M.get_stats()
    local unique_particles = {}
    for _, frame_data in ipairs(PARTICLE_LIFECYCLE_CAPTURE.frames) do
        for addr, _ in pairs(frame_data.particles) do
            unique_particles[addr] = true
        end
    end

    local unique_count = 0
    for _ in pairs(unique_particles) do
        unique_count = unique_count + 1
    end

    return {
        frame_count = #PARTICLE_LIFECYCLE_CAPTURE.frames,
        total_snapshots = PARTICLE_LIFECYCLE_CAPTURE.total_snapshots,
        unique_particles = unique_count,
        effect_idx = PARTICLE_LIFECYCLE_CAPTURE.effect_idx,
    }
end

-- Export to CSV
function M.export_csv(filename)
    if #PARTICLE_LIFECYCLE_CAPTURE.frames == 0 then
        print("[Lifecycle] No data to export")
        return false
    end

    -- Default filename
    if not filename then
        if config and config.SAVESTATE_PATH and EFFECT_EDITOR and EFFECT_EDITOR.session_name ~= "" then
            filename = config.SAVESTATE_PATH .. EFFECT_EDITOR.session_name .. "_lifecycle.csv"
        elseif config and config.SAVESTATE_PATH then
            filename = config.SAVESTATE_PATH .. "particle_lifecycle.csv"
        else
            filename = "particle_lifecycle.csv"
        end
    end

    local file = io.open(filename, "w")
    if not file then
        print("[Lifecycle] Failed to open file: " .. filename)
        return false
    end

    -- Write header
    file:write("Frame,EffIdx,Addr,Emu,SpawnF,PosX,PosY,PosZ,VelX,VelY,VelZ,AccX,AccY,AccZ,")
    file:write("DragX,DragY,DragZ,TgtX,TgtY,TgtZ,Life,Inertia,Weight,HomStr,HomCrv,")
    file:write("MoFlg,BeFlg,AnimF,ChDth,ChMid,ColR,ColG,ColB\n")

    -- Write data rows
    for _, frame_data in ipairs(PARTICLE_LIFECYCLE_CAPTURE.frames) do
        for addr, p in pairs(frame_data.particles) do
            file:write(string.format("%d,%d,%08X,%d,%d,",
                frame_data.frame_num, p.effect_idx, addr, p.emitter_idx, p.spawn_frame))
            file:write(string.format("%d,%d,%d,", p.pos_x, p.pos_y, p.pos_z))
            file:write(string.format("%d,%d,%d,", p.vel_x, p.vel_y, p.vel_z))
            file:write(string.format("%d,%d,%d,", p.acc_x, p.acc_y, p.acc_z))
            file:write(string.format("%d,%d,%d,", p.drag_x, p.drag_y, p.drag_z))
            file:write(string.format("%d,%d,%d,", p.tgt_x, p.tgt_y, p.tgt_z))
            file:write(string.format("%d,%d,%d,%d,%d,", p.life, p.inertia, p.weight, p.hom_str, p.hom_crv))
            file:write(string.format("0x%04X,0x%04X,%d,%d,%d,%d,%d,%d\n",
                p.mo_flg, p.be_flg, p.anim_f, p.ch_dth, p.ch_mid, p.col_r, p.col_g, p.col_b))
        end
    end

    file:close()
    print(string.format("[Lifecycle] Exported to: %s", filename))
    return true
end

-- Cleanup breakpoints
function M.cleanup_breakpoints()
    local function safe_disable(bp)
        if bp then
            pcall(function() bp:disable() end)
        end
    end

    safe_disable(LIFECYCLE_BP_INIT)
    safe_disable(LIFECYCLE_BP_SPAWN_ENTRY)
    safe_disable(LIFECYCLE_BP_SPAWN_EXIT)
    safe_disable(LIFECYCLE_BP_FRAME)

    LIFECYCLE_BP_INIT = nil
    LIFECYCLE_BP_SPAWN_ENTRY = nil
    LIFECYCLE_BP_SPAWN_EXIT = nil
    LIFECYCLE_BP_FRAME = nil
end

-- Full cleanup
function M.cleanup()
    M.cleanup_breakpoints()
    PARTICLE_LIFECYCLE_CAPTURE.recording = false
    print("[Lifecycle] Cleanup complete")
end

return M
