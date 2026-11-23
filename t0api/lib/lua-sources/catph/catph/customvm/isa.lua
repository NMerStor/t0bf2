
-- customvm/isa.lua


local ISA = {}

ISA.MULTRET = -1 

ISA.OP = {
    -- loads
    LOADNIL    = 2,
    LOADB      = 3,   -- a, b(0/1)
    LOADN      = 4,   -- a, b(int imm)
    LOADK      = 5,   -- a, k
    MOVE       = 6,   -- a, b
    -- globals
    GETGLOBAL  = 7,   -- a, k(name)
    SETGLOBAL  = 8,   -- a, k(name)
    -- upvalues (Fase 4)
    GETUPVAL   = 9,
    SETUPVAL   = 10,
    CLOSEUPVALS= 11,
    -- table access
    GETTABLE   = 13,  -- a, b(tbl), c(key reg)
    SETTABLE   = 14,  -- a(val), b(tbl), c(key reg)
    GETTABLEKS = 15,  -- a, b(tbl), k(key const)
    SETTABLEKS = 16,  -- a(val), b(tbl), k(key const)
    GETTABLEN  = 17,  -- a, b(tbl), c(1-based int)
    SETTABLEN  = 18,  -- a(val), b(tbl), c(1-based int)
    -- closures / calls
    NEWCLOSURE = 19,
    NAMECALL   = 20,
    CALL       = 21,  -- a(func), b(nargs+1|0), c(nret+1|0)
    RETURN     = 22,  -- a(base), b(nret+1|0)
    -- jumps / control flow 
    JUMP       = 23,
    JUMPBACK   = 24,
    JUMPIF     = 25,
    JUMPIFNOT  = 26,
    JUMPIFEQ   = 27,
    JUMPIFLE   = 28,
    JUMPIFLT   = 29,
    JUMPIFNOTEQ= 30,
    JUMPIFNOTLE= 31,
    JUMPIFNOTLT= 32,
    -- arithmetic
    ADD        = 33,  -- a, b, c
    SUB        = 34,
    MUL        = 35,
    DIV        = 36,
    MOD        = 37,
    POW        = 38,
    IDIV       = 81,
    -- super ops (fused instructions)
    ADDMOVE    = 82,  -- R[a] = R[b] + R[c], then move to R[k]  (k = final dst)
    MOVE_ADD   = 83,  -- R[a] = R[b]; R[a] = R[a] + R[c]  (ADD with explicit stage)
    GETTKS_MOVE= 84,  -- GETTABLEKS then MOVE: R[a] = R[b][K]; R[k] = R[a]
    LOADK_MOVE = 85,  -- LOADK then MOVE: R[a] = K; R[k] = R[a]
    -- string / unary
    CONCAT     = 49,  -- a, b(first), c(last)  R[a]=R[b]..…..R[c]
    NOT        = 50,  -- a, b
    MINUS      = 51,  -- a, b
    LENGTH     = 52,  -- a, b
    -- tables
    NEWTABLE   = 53,  -- a
    SETLIST    = 55,  -- a(tbl), b(first val), c(count), k(start index)
    FORNPREP   = 56,
    FORNLOOP   = 57,
    FORGLOOP   = 58,
    --varargs
    GETVARARGS = 63,  -- a, b(want+1|0)
}

-- Reverse map (number -> name)
ISA.NAME = {}
for name, num in pairs(ISA.OP) do
    ISA.NAME[num] = name
end

return ISA
