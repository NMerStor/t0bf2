-- IronBrew0 v0.001 - Custom Bytecode Format
-- Compact instruction stream + constant pool + prototypes

local Format = {}

-- Opcodes (byte values). Keep stable; append only when extending.
Format.Op = {
    MOVE      = 1,
    LOADK     = 2,
    LOADNIL   = 3,
    LOADBOOL  = 4,
    LOADVARG  = 5,
    ADD       = 6,
    SUB       = 7,
    MUL       = 8,
    DIV       = 9,
    MOD       = 10,
    POW       = 11,
    CONCAT    = 12,
    UNM       = 13,
    NOT       = 14,
    LEN       = 15,
    EQ        = 16,
    LT        = 17,
    LE        = 18,
    JMP       = 19,
    JMP_IF    = 20,
    JMP_IFNOT = 21,
    CALL      = 22,
    RETURN    = 23,
    NEWTABLE  = 24,
    GETTABLE  = 25,
    SETTABLE  = 26,
    GETGLOBAL = 27,
    SETGLOBAL = 28,
    CLOSURE   = 29,
    FORPREP   = 30,
    FORLOOP   = 31,
    SELF      = 32,
    NOP       = 33,
    LABEL     = 34, -- resolved away before emit
}

Format.OpName = {}
for name, id in pairs(Format.Op) do
    Format.OpName[id] = name
end

-- Map IR op strings → bytecode opcode ids
Format.FromIR = {
    MOVE = Format.Op.MOVE,
    LOADK = Format.Op.LOADK,
    LOADNIL = Format.Op.LOADNIL,
    LOADBOOL = Format.Op.LOADBOOL,
    LOADVARARG = Format.Op.LOADVARG,
    ADD = Format.Op.ADD, SUB = Format.Op.SUB, MUL = Format.Op.MUL,
    DIV = Format.Op.DIV, MOD = Format.Op.MOD, POW = Format.Op.POW,
    CONCAT = Format.Op.CONCAT,
    UNM = Format.Op.UNM, NOT = Format.Op.NOT, LEN = Format.Op.LEN,
    EQ = Format.Op.EQ, LT = Format.Op.LT, LE = Format.Op.LE,
    JMP = Format.Op.JMP, JMP_IF = Format.Op.JMP_IF, JMP_IFNOT = Format.Op.JMP_IFNOT,
    CALL = Format.Op.CALL, RETURN = Format.Op.RETURN, TAILCALL = Format.Op.CALL,
    NEWTABLE = Format.Op.NEWTABLE,
    GETTABLE = Format.Op.GETTABLE, SETTABLE = Format.Op.SETTABLE,
    GETGLOBAL = Format.Op.GETGLOBAL, SETGLOBAL = Format.Op.SETGLOBAL,
    CLOSURE = Format.Op.CLOSURE,
    FORPREP = Format.Op.FORPREP, FORLOOP = Format.Op.FORLOOP,
    SELF = Format.Op.SELF, NOP = Format.Op.NOP, LABEL = Format.Op.LABEL,
}

-- Instruction packing: each instr is a table {op, a, b, c}
-- Serialized as array of numbers for the Lua loader:
--   code = { op, a, b, c, op, a, b, c, ... }
-- Constants: mixed array of numbers/strings/bools (nil encoded as special)
-- Prototypes: nested tables

function Format.encodeString(s)
    -- simple safe escape for embedding in generated Lua
    return string.format("%q", s)
end

return Format
