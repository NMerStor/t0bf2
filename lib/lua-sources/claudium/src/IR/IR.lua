-- IronBrew0 v0.001 - Intermediate Representation
-- Simple three-address / register-based IR for obfuscation & VM backend

local IR = {}

IR.Op = {
    -- Data movement
    MOVE     = "MOVE",
    LOADK    = "LOADK",    -- load constant
    LOADNIL  = "LOADNIL",
    LOADBOOL = "LOADBOOL",
    LOADVARARG = "LOADVARARG",

    -- Arithmetic / logic
    ADD = "ADD", SUB = "SUB", MUL = "MUL", DIV = "DIV",
    MOD = "MOD", POW = "POW", CONCAT = "CONCAT",
    UNM = "UNM", NOT = "NOT", LEN = "LEN",

    -- Comparison (result -> register)
    EQ = "EQ", LT = "LT", LE = "LE",

    -- Control
    JMP      = "JMP",
    JMP_IF   = "JMP_IF",   -- if R[a] then jump
    JMP_IFNOT= "JMP_IFNOT",
    CALL     = "CALL",
    RETURN   = "RETURN",
    TAILCALL = "TAILCALL",

    -- Table
    NEWTABLE = "NEWTABLE",
    GETTABLE = "GETTABLE",
    SETTABLE = "SETTABLE",
    GETGLOBAL= "GETGLOBAL",
    SETGLOBAL= "SETGLOBAL",
    SELF     = "SELF",

    -- Closures / upvalues
    CLOSURE  = "CLOSURE",
    GETUPVAL = "GETUPVAL",
    SETUPVAL = "SETUPVAL",
    CLOSE    = "CLOSE",

    -- Loops
    FORPREP  = "FORPREP",
    FORLOOP  = "FORLOOP",
    TFORCALL = "TFORCALL",
    TFORLOOP = "TFORLOOP",

    -- Misc
    VARARG   = "VARARG",
    NOP      = "NOP",
    LABEL    = "LABEL",    -- pseudo for control-flow
}

function IR.Instruction(op, a, b, c, meta)
    return {
        op   = op,
        a    = a,   -- usually dest register or jump target
        b    = b,
        c    = c,
        meta = meta or {}, -- extra (constant index, function proto, etc.)
    }
end

function IR.Constant(value, kind)
    return { value = value, kind = kind or type(value) }
end

function IR.Prototype(name)
    return {
        name       = name or "main",
        params     = 0,
        isVararg   = false,
        maxStack   = 0,
        code       = {},        -- list of Instructions
        constants  = {},        -- Constant pool
        prototypes = {},        -- nested function protos
        upvalues   = {},
        locVars    = {},
        source     = nil,
    }
end

function IR.Module()
    return {
        main       = nil,       -- main Prototype
        prototypes = {},
        strings    = {},
        metadata   = {
            version = "0.001",
            target  = "lua51",
        },
    }
end

-- Simple pretty printer for IR
function IR.dump(proto, indent)
    indent = indent or 0
    local pad = string.rep("  ", indent)
    local lines = {}
    table.insert(lines, pad .. "proto " .. (proto.name or "?") .. " params=" .. proto.params
        .. (proto.isVararg and " vararg" or "") .. " maxstack=" .. proto.maxStack)
    table.insert(lines, pad .. "constants:")
    for i, k in ipairs(proto.constants) do
        table.insert(lines, pad .. "  [" .. i .. "] " .. tostring(k.value))
    end
    table.insert(lines, pad .. "code:")
    for i, ins in ipairs(proto.code) do
        local s = string.format("%s  %04d %-10s", pad, i, ins.op)
        if ins.a then s = s .. " A=" .. tostring(ins.a) end
        if ins.b then s = s .. " B=" .. tostring(ins.b) end
        if ins.c then s = s .. " C=" .. tostring(ins.c) end
        if ins.meta and ins.meta.label then s = s .. " @" .. ins.meta.label end
        table.insert(lines, s)
    end
    for _, p in ipairs(proto.prototypes) do
        table.insert(lines, IR.dump(p, indent + 1))
    end
    return table.concat(lines, "\n")
end

return IR
