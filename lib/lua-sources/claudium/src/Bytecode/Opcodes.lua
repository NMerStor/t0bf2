-- IronBrew0 v1.2 - Custom bytecode opcode ISA
-- Proprietary numeric opcodes (not Lua 5.1/Luau numbering).
-- Per-build permutation of the private ISA.

local Opcodes = {}

-- Stable private ISA names (order is the canonical logical index internally)
Opcodes.ISA = {
    "IB_MOVE",      -- 1  R[a] = R[b]
    "IB_LOADK",     -- 2  R[a] = K[b]
    "IB_LOADNIL",   -- 3
    "IB_LOADBOOL",  -- 4
    "IB_LOADVARG",  -- 5
    "IB_ADD",       -- 6
    "IB_SUB",       -- 7
    "IB_MUL",       -- 8
    "IB_DIV",       -- 9
    "IB_MOD",       -- 10
    "IB_POW",       -- 11
    "IB_CONCAT",    -- 12
    "IB_UNM",       -- 13
    "IB_NOT",       -- 14
    "IB_LEN",       -- 15
    "IB_EQ",        -- 16
    "IB_LT",        -- 17
    "IB_LE",        -- 18
    "IB_JMP",       -- 19
    "IB_JMPIF",     -- 20
    "IB_JMPIFNOT",  -- 21
    "IB_CALL",      -- 22
    "IB_RETURN",    -- 23
    "IB_NEWTABLE",  -- 24
    "IB_GETTABLE",  -- 25
    "IB_SETTABLE",  -- 26
    "IB_GETGLOBAL", -- 27
    "IB_SETGLOBAL", -- 28
    "IB_CLOSURE",   -- 29
    "IB_NOP",       -- 30
    "IB_LOADKX",    -- 31  alias LOADK
    "IB_MOVE2",     -- 32  SUPER_MOVE2
    "IB_AT",        -- 33  reserved
    "IB_ADDK",      -- 34  SUPER_ADDK
    "IB_CALLG",     -- 35  SUPER_CALLG
    "IB_DUP",       -- 36  SUPER_MOVE2-like
}

-- Map old numeric IR (1..36) -> ISA index (same order for compatibility)
Opcodes.FROM_LEGACY = {}
for i, name in ipairs(Opcodes.ISA) do
    Opcodes.FROM_LEGACY[i] = i
end

--- Build a per-seed custom encoding:
--  logical (1..n) -> wire byte (1..255)
--  wire byte -> logical
--  operand mix keys
function Opcodes.makeCodec(seed)
    math.randomseed(seed or 1)
    local n = #Opcodes.ISA
    -- pick unique wire bytes in 1..250
    local pool = {}
    for i = 1, 250 do pool[i] = i end
    for i = 250, 2, -1 do
        local j = math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local toWire, fromWire = {}, {}
    for log = 1, n do
        local w = pool[log]
        toWire[log] = w
        fromWire[w] = log
    end
    -- extra aliases: some logicals get secondary wire codes
    local nextSlot = n + 1
    for log = 1, math.min(36, n) do
        local extra = math.random(0, 2)
        for _ = 1, extra do
            if nextSlot > 250 then break end
            local w = pool[nextSlot]
            nextSlot = nextSlot + 1
            fromWire[w] = log
            -- toWire stays primary; encoding picks randomly
            if type(toWire[log]) == "number" then
                toWire[log] = { toWire[log], w }
            else
                toWire[log][#toWire[log] + 1] = w
            end
        end
    end
    -- normalize toWire to always be list
    for log = 1, n do
        if type(toWire[log]) == "number" then
            toWire[log] = { toWire[log] }
        end
    end

    local opKey = math.random(1, 255)
    local aKey = math.random(1, 255)
    local bKey = math.random(1, 255)
    local cKey = math.random(1, 255)

    return {
        toWire = toWire,
        fromWire = fromWire,
        opKey = opKey,
        aKey = aKey,
        bKey = bKey,
        cKey = cKey,
        n = n,
    }
end

local function xor8(a, b)
    a, b = math.floor(a) % 256, math.floor(b) % 256
    local r, p = 0, 1
    for _ = 1, 8 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end
Opcodes.xor8 = xor8

--- Encode one instruction (logical op,a,b,c) -> wire bytes (already operand-mixed)
function Opcodes.encodeIns(codec, logOp, a, b, c, pc)
    local wires = codec.toWire[logOp] or { logOp }
    local w = wires[math.random(1, #wires)]
    pc = pc or 1
    local mix = (pc * pc + pc * 7 + codec.opKey) % 256
    a = xor8(a or 0, xor8(codec.aKey, mix))
    b = xor8(b or 0, xor8(codec.bKey, mix))
    c = xor8(c or 0, xor8(codec.cKey, mix))
    return w, a, b, c
end

function Opcodes.decodeOperands(codec, a, b, c, pc)
    pc = pc or 1
    local mix = (pc * pc + pc * 7 + codec.opKey) % 256
    a = xor8(a or 0, xor8(codec.aKey, mix))
    b = xor8(b or 0, xor8(codec.bKey, mix))
    c = xor8(c or 0, xor8(codec.cKey, mix))
    return a, b, c
end


--- Second transform layer (v1.2): position-dependent fold into wire stream
function Opcodes.layer2Encode(bytes4, pc, key2)
    -- bytes4 = {op,a,b,c} already wire-encoded
    local k = (key2 + pc * 31) % 256
    local o, a, b, c = bytes4[1], bytes4[2], bytes4[3], bytes4[4]
    return {
        Opcodes.xor8(o, k),
        Opcodes.xor8(a, Opcodes.xor8(k, 0x3D)),
        Opcodes.xor8(b, Opcodes.xor8(k, 0x5B)),
        Opcodes.xor8(c, Opcodes.xor8(k, 0x7E)),
    }
end

function Opcodes.layer2Decode(o, a, b, c, pc, key2)
    local k = (key2 + pc * 31) % 256
    return Opcodes.xor8(o, k),
        Opcodes.xor8(a, Opcodes.xor8(k, 0x3D)),
        Opcodes.xor8(b, Opcodes.xor8(k, 0x5B)),
        Opcodes.xor8(c, Opcodes.xor8(k, 0x7E))
end

return Opcodes
