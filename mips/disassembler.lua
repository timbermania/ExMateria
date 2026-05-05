-- mips/disassembler.lua
-- MIPS R3000 disassembler for PSX effect code analysis

local M = {}

-- Use LuaJIT bit library
local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

--------------------------------------------------------------------------------
-- Register Names
--------------------------------------------------------------------------------

local REG_NAMES = {
    [0] = "zero", "at", "v0", "v1", "a0", "a1", "a2", "a3",
    "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
    "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7",
    "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra"
}

local COP0_REG_NAMES = {
    [12] = "SR", [13] = "Cause", [14] = "EPC", [15] = "PRId"
}

-- GTE data registers (active in effects)
local GTE_DATA_NAMES = {
    [0] = "VXY0", [1] = "VZ0", [2] = "VXY1", [3] = "VZ1",
    [4] = "VXY2", [5] = "VZ2", [6] = "RGBC", [7] = "OTZ",
    [8] = "IR0", [9] = "IR1", [10] = "IR2", [11] = "IR3",
    [12] = "SXY0", [13] = "SXY1", [14] = "SXY2", [15] = "SXYP",
    [16] = "SZ0", [17] = "SZ1", [18] = "SZ2", [19] = "SZ3",
    [20] = "RGB0", [21] = "RGB1", [22] = "RGB2",
    [24] = "MAC0", [25] = "MAC1", [26] = "MAC2", [27] = "MAC3",
    [28] = "IRGB", [29] = "ORGB", [30] = "LZCS", [31] = "LZCR"
}

--------------------------------------------------------------------------------
-- Instruction Decoding Helpers
--------------------------------------------------------------------------------

-- Extract bits from word using bit library
local function bits(word, start, count)
    return band(rshift(word, start), lshift(1, count) - 1)
end

local function sign_extend_16(val)
    if val >= 0x8000 then
        return val - 0x10000
    end
    return val
end

local function sign_extend_26(val)
    if val >= 0x2000000 then
        return val - 0x4000000
    end
    return val
end

--------------------------------------------------------------------------------
-- R-Type Instructions (opcode = 0)
--------------------------------------------------------------------------------

local R_TYPE_FUNCTS = {
    [0x00] = function(rd, rt, sa)
        if rd == 0 and rt == 0 and sa == 0 then return "nop" end
        return string.format("sll %s, %s, %d", REG_NAMES[rd], REG_NAMES[rt], sa)
    end,
    [0x02] = function(rd, rt, sa) return string.format("srl %s, %s, %d", REG_NAMES[rd], REG_NAMES[rt], sa) end,
    [0x03] = function(rd, rt, sa) return string.format("sra %s, %s, %d", REG_NAMES[rd], REG_NAMES[rt], sa) end,
    [0x04] = function(rd, rt, rs) return string.format("sllv %s, %s, %s", REG_NAMES[rd], REG_NAMES[rt], REG_NAMES[rs]) end,
    [0x06] = function(rd, rt, rs) return string.format("srlv %s, %s, %s", REG_NAMES[rd], REG_NAMES[rt], REG_NAMES[rs]) end,
    [0x07] = function(rd, rt, rs) return string.format("srav %s, %s, %s", REG_NAMES[rd], REG_NAMES[rt], REG_NAMES[rs]) end,
    [0x08] = function(rd, rt, rs) return string.format("jr %s", REG_NAMES[rs]) end,
    [0x09] = function(rd, rt, rs) return string.format("jalr %s, %s", REG_NAMES[rd], REG_NAMES[rs]) end,
    [0x0C] = function() return "syscall" end,
    [0x0D] = function() return "break" end,
    [0x10] = function(rd) return string.format("mfhi %s", REG_NAMES[rd]) end,
    [0x11] = function(rd, rt, rs) return string.format("mthi %s", REG_NAMES[rs]) end,
    [0x12] = function(rd) return string.format("mflo %s", REG_NAMES[rd]) end,
    [0x13] = function(rd, rt, rs) return string.format("mtlo %s", REG_NAMES[rs]) end,
    [0x18] = function(rd, rt, rs) return string.format("mult %s, %s", REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x19] = function(rd, rt, rs) return string.format("multu %s, %s", REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x1A] = function(rd, rt, rs) return string.format("div %s, %s", REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x1B] = function(rd, rt, rs) return string.format("divu %s, %s", REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x20] = function(rd, rt, rs) return string.format("add %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x21] = function(rd, rt, rs)
        if rt == 0 then return string.format("move %s, %s", REG_NAMES[rd], REG_NAMES[rs]) end
        return string.format("addu %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt])
    end,
    [0x22] = function(rd, rt, rs) return string.format("sub %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x23] = function(rd, rt, rs) return string.format("subu %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x24] = function(rd, rt, rs) return string.format("and %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x25] = function(rd, rt, rs)
        if rs == 0 then return string.format("move %s, %s", REG_NAMES[rd], REG_NAMES[rt]) end
        return string.format("or %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt])
    end,
    [0x26] = function(rd, rt, rs) return string.format("xor %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x27] = function(rd, rt, rs) return string.format("nor %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x2A] = function(rd, rt, rs) return string.format("slt %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
    [0x2B] = function(rd, rt, rs) return string.format("sltu %s, %s, %s", REG_NAMES[rd], REG_NAMES[rs], REG_NAMES[rt]) end,
}

local function decode_r_type(word)
    local rs = bits(word, 21, 5)
    local rt = bits(word, 16, 5)
    local rd = bits(word, 11, 5)
    local sa = bits(word, 6, 5)
    local funct = bits(word, 0, 6)

    local handler = R_TYPE_FUNCTS[funct]
    if handler then
        return handler(rd, rt, rs, sa)
    end
    return string.format("??? (R-type funct=0x%02X)", funct)
end

--------------------------------------------------------------------------------
-- I-Type Instructions
--------------------------------------------------------------------------------

local function decode_i_type(opcode, word, pc)
    local rs = bits(word, 21, 5)
    local rt = bits(word, 16, 5)
    local imm = bits(word, 0, 16)
    local simm = sign_extend_16(imm)

    -- Branch target calculation
    local branch_target = pc + 4 + (simm * 4)

    local opcodes = {
        [0x01] = function()
            -- REGIMM: BLTZ, BGEZ, etc.
            if rt == 0 then return string.format("bltz %s, 0x%08X", REG_NAMES[rs], branch_target)
            elseif rt == 1 then return string.format("bgez %s, 0x%08X", REG_NAMES[rs], branch_target)
            elseif rt == 16 then return string.format("bltzal %s, 0x%08X", REG_NAMES[rs], branch_target)
            elseif rt == 17 then return string.format("bgezal %s, 0x%08X", REG_NAMES[rs], branch_target)
            end
            return string.format("??? (REGIMM rt=%d)", rt)
        end,
        [0x04] = function() return string.format("beq %s, %s, 0x%08X", REG_NAMES[rs], REG_NAMES[rt], branch_target) end,
        [0x05] = function() return string.format("bne %s, %s, 0x%08X", REG_NAMES[rs], REG_NAMES[rt], branch_target) end,
        [0x06] = function() return string.format("blez %s, 0x%08X", REG_NAMES[rs], branch_target) end,
        [0x07] = function() return string.format("bgtz %s, 0x%08X", REG_NAMES[rs], branch_target) end,
        [0x08] = function() return string.format("addi %s, %s, %d", REG_NAMES[rt], REG_NAMES[rs], simm) end,
        [0x09] = function()
            if rs == 0 then return string.format("li %s, %d", REG_NAMES[rt], simm) end
            return string.format("addiu %s, %s, %d", REG_NAMES[rt], REG_NAMES[rs], simm)
        end,
        [0x0A] = function() return string.format("slti %s, %s, %d", REG_NAMES[rt], REG_NAMES[rs], simm) end,
        [0x0B] = function() return string.format("sltiu %s, %s, %d", REG_NAMES[rt], REG_NAMES[rs], simm) end,
        [0x0C] = function() return string.format("andi %s, %s, 0x%04X", REG_NAMES[rt], REG_NAMES[rs], imm) end,
        [0x0D] = function()
            if rs == 0 then return string.format("li %s, 0x%04X", REG_NAMES[rt], imm) end
            return string.format("ori %s, %s, 0x%04X", REG_NAMES[rt], REG_NAMES[rs], imm)
        end,
        [0x0E] = function() return string.format("xori %s, %s, 0x%04X", REG_NAMES[rt], REG_NAMES[rs], imm) end,
        [0x0F] = function() return string.format("lui %s, 0x%04X", REG_NAMES[rt], imm) end,
        [0x20] = function() return string.format("lb %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x21] = function() return string.format("lh %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x22] = function() return string.format("lwl %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x23] = function() return string.format("lw %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x24] = function() return string.format("lbu %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x25] = function() return string.format("lhu %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x26] = function() return string.format("lwr %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x28] = function() return string.format("sb %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x29] = function() return string.format("sh %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x2A] = function() return string.format("swl %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x2B] = function() return string.format("sw %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
        [0x2E] = function() return string.format("swr %s, %d(%s)", REG_NAMES[rt], simm, REG_NAMES[rs]) end,
    }

    local handler = opcodes[opcode]
    if handler then
        return handler()
    end
    return nil  -- Not an I-type we handle
end

--------------------------------------------------------------------------------
-- J-Type Instructions
--------------------------------------------------------------------------------

local function decode_j_type(opcode, word, pc)
    local target = bits(word, 0, 26)
    -- Target address: PSX code runs in KSEG0 (0x80000000 region)
    -- Use 0x80000000 as base since we may be disassembling file-relative addresses
    local full_target = 0x80000000 + (target * 4)

    if opcode == 0x02 then
        return string.format("j 0x%08X", full_target), full_target
    elseif opcode == 0x03 then
        return string.format("jal 0x%08X", full_target), full_target
    end
    return nil
end

--------------------------------------------------------------------------------
-- Coprocessor Instructions (COP0, COP2/GTE)
--------------------------------------------------------------------------------

local GTE_COMMANDS = {
    [0x01] = "RTPS",    -- Perspective transform single
    [0x06] = "NCLIP",   -- Normal clipping
    [0x0C] = "OP",      -- Outer product
    [0x10] = "DPCS",    -- Depth cue single
    [0x11] = "INTPL",   -- Interpolation
    [0x12] = "MVMVA",   -- Matrix-vector multiply
    [0x13] = "NCDS",    -- Normal color depth single
    [0x14] = "CDP",     -- Color depth cue
    [0x16] = "NCDT",    -- Normal color depth triple
    [0x1B] = "NCCS",    -- Normal color color single
    [0x1C] = "CC",      -- Color color
    [0x1E] = "NCS",     -- Normal color single
    [0x20] = "NCT",     -- Normal color triple
    [0x28] = "SQR",     -- Square
    [0x29] = "DCPL",    -- Depth cue light
    [0x2A] = "DPCT",    -- Depth cue triple
    [0x2D] = "AVSZ3",   -- Average Z 3
    [0x2E] = "AVSZ4",   -- Average Z 4
    [0x30] = "RTPT",    -- Perspective transform triple (KEY for 3D!)
    [0x3D] = "GPF",     -- General purpose interpolation
    [0x3E] = "GPL",     -- General purpose interpolation
    [0x3F] = "NCCT",    -- Normal color color triple
}

local function decode_cop(opcode, word)
    local cop_num = opcode - 0x10  -- 0=COP0, 2=COP2(GTE)
    local rs = bits(word, 21, 5)
    local rt = bits(word, 16, 5)
    local rd = bits(word, 11, 5)
    local cofun = bits(word, 0, 25)

    if cop_num == 0 then
        -- COP0 (System coprocessor)
        if rs == 0 then
            return string.format("mfc0 %s, %s", REG_NAMES[rt], COP0_REG_NAMES[rd] or string.format("$%d", rd))
        elseif rs == 4 then
            return string.format("mtc0 %s, %s", REG_NAMES[rt], COP0_REG_NAMES[rd] or string.format("$%d", rd))
        elseif rs == 16 then
            return "rfe"  -- Return from exception
        end
    elseif cop_num == 2 then
        -- COP2 (GTE - Geometry Transform Engine)
        if rs == 0 then
            local reg_name = GTE_DATA_NAMES[rd] or string.format("$%d", rd)
            return string.format("mfc2 %s, %s", REG_NAMES[rt], reg_name)
        elseif rs == 2 then
            local reg_name = GTE_DATA_NAMES[rd] or string.format("$%d", rd)
            return string.format("cfc2 %s, %s", REG_NAMES[rt], reg_name)
        elseif rs == 4 then
            local reg_name = GTE_DATA_NAMES[rd] or string.format("$%d", rd)
            return string.format("mtc2 %s, %s", REG_NAMES[rt], reg_name)
        elseif rs == 6 then
            return string.format("ctc2 %s, $%d", REG_NAMES[rt], rd)
        elseif band(rs, 0x10) ~= 0 then
            -- GTE command
            local cmd = band(cofun, 0x3F)
            local cmd_name = GTE_COMMANDS[cmd]
            if cmd_name then
                return string.format("gte_%s", cmd_name)
            end
            return string.format("gte_cmd 0x%02X", cmd)
        end
    end

    return string.format("cop%d 0x%07X", cop_num, cofun)
end

--------------------------------------------------------------------------------
-- Load/Store Coprocessor
--------------------------------------------------------------------------------

local function decode_cop_ls(opcode, word)
    local base = bits(word, 21, 5)
    local rt = bits(word, 16, 5)
    local offset = sign_extend_16(bits(word, 0, 16))

    local cop_num = band(opcode, 0x03)
    local is_store = band(opcode, 0x08) ~= 0

    if cop_num == 2 then
        local reg_name = GTE_DATA_NAMES[rt] or string.format("$%d", rt)
        if is_store then
            return string.format("swc2 %s, %d(%s)", reg_name, offset, REG_NAMES[base])
        else
            return string.format("lwc2 %s, %d(%s)", reg_name, offset, REG_NAMES[base])
        end
    end

    if is_store then
        return string.format("swc%d $%d, %d(%s)", cop_num, rt, offset, REG_NAMES[base])
    else
        return string.format("lwc%d $%d, %d(%s)", cop_num, rt, offset, REG_NAMES[base])
    end
end

--------------------------------------------------------------------------------
-- Main Disassembly Function
--------------------------------------------------------------------------------

-- Disassemble a single instruction
-- Returns: mnemonic, call_target (if JAL/JALR), is_branch
function M.disassemble_instruction(word, pc)
    local opcode = bits(word, 26, 6)
    local call_target = nil
    local is_branch = false
    local mnemonic

    if opcode == 0 then
        -- R-type
        mnemonic = decode_r_type(word)
        -- Check for JR/JALR
        local funct = bits(word, 0, 6)
        if funct == 0x08 then is_branch = true end
        if funct == 0x09 then
            is_branch = true
            -- JALR - target is in register, can't know statically
        end
    elseif opcode == 0x02 or opcode == 0x03 then
        -- J-type
        mnemonic, call_target = decode_j_type(opcode, word, pc)
        is_branch = true
    elseif opcode >= 0x10 and opcode <= 0x13 then
        -- Coprocessor operations
        mnemonic = decode_cop(opcode, word)
    elseif opcode >= 0x30 and opcode <= 0x3B then
        -- Load/store coprocessor
        mnemonic = decode_cop_ls(opcode, word)
    else
        -- I-type or unknown
        mnemonic = decode_i_type(opcode, word, pc)
        if not mnemonic then
            mnemonic = string.format("??? (opcode=0x%02X)", opcode)
        end
        -- Check for branches
        if opcode >= 0x01 and opcode <= 0x07 then
            is_branch = true
        end
    end

    return mnemonic, call_target, is_branch
end

--------------------------------------------------------------------------------
-- Disassemble a block of code
--------------------------------------------------------------------------------

-- Disassemble bytes from a table/string, returning array of instruction info
-- code_bytes: array of bytes or string
-- base_addr: RAM address where code loads (e.g., 0x801C2500)
-- max_instructions: optional limit
function M.disassemble_block(code_bytes, base_addr, max_instructions)
    local results = {}
    local byte_len

    if type(code_bytes) == "string" then
        byte_len = #code_bytes
    else
        byte_len = #code_bytes
    end

    local num_instructions = math.floor(byte_len / 4)
    if max_instructions and max_instructions < num_instructions then
        num_instructions = max_instructions
    end

    for i = 0, num_instructions - 1 do
        local offset = i * 4
        local pc = base_addr + offset

        -- Read 4 bytes little-endian
        local b0, b1, b2, b3
        if type(code_bytes) == "string" then
            b0 = string.byte(code_bytes, offset + 1) or 0
            b1 = string.byte(code_bytes, offset + 2) or 0
            b2 = string.byte(code_bytes, offset + 3) or 0
            b3 = string.byte(code_bytes, offset + 4) or 0
        else
            b0 = code_bytes[offset + 1] or 0
            b1 = code_bytes[offset + 2] or 0
            b2 = code_bytes[offset + 3] or 0
            b3 = code_bytes[offset + 4] or 0
        end
        local word = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216

        local mnemonic, call_target, is_branch = M.disassemble_instruction(word, pc)

        table.insert(results, {
            offset = offset,
            address = pc,
            word = word,
            mnemonic = mnemonic,
            call_target = call_target,
            is_branch = is_branch,
        })
    end

    return results
end

--------------------------------------------------------------------------------
-- Detect CODE format and find code end
--------------------------------------------------------------------------------

function M.is_code_format(first_word)
    -- Check for addiu sp, sp, -X pattern
    return band(first_word, 0xFFFF0000) == 0x27BD0000
end

function M.get_stack_frame_size(first_word)
    if not M.is_code_format(first_word) then return 0 end
    local imm = band(first_word, 0xFFFF)
    return 0x10000 - imm  -- Negate the negative immediate
end

-- Find where code likely ends (jr ra after stack restore)
function M.find_code_end(code_bytes, base_addr)
    local disasm = M.disassemble_block(code_bytes, base_addr)
    local last_jr_ra = nil

    for i, insn in ipairs(disasm) do
        -- Look for "jr ra" which is 0x03E00008
        if insn.word == 0x03E00008 then
            last_jr_ra = insn.offset + 8  -- +8 to include delay slot
        end
    end

    return last_jr_ra
end

return M
