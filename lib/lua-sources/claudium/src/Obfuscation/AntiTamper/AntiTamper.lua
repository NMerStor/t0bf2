-- Claudium v2.5.4 anti-tamper helpers
-- Runtime integrity itself is emitted as the IB_AT virtual opcode by Generator.lua.

local AntiTamper = {}

function AntiTamper.scrambleOpcodeMap(seed, nops)
    nops = nops or 40
    math.randomseed(seed or os.time())
    local ops = {}
    for i = 1, nops do ops[i] = i end
    for i = nops, 2, -1 do
        local j = math.random(1, i)
        ops[i], ops[j] = ops[j], ops[i]
    end
    local map, inv = {}, {}
    for logical = 1, nops do
        map[logical] = ops[logical]
        inv[ops[logical]] = logical
    end
    return map, inv
end

return AntiTamper
