-- IronBrew0 v0.001 - IR → Custom Bytecode Encoder

local Format = require("src.VM.Bytecode.Format")

local function hostXor(a, b)
    a, b = math.floor(a) % 256, math.floor(b) % 256
    local r, p = 0, 1
    for _ = 1, 8 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

local Encoder = {}
Encoder.__index = Encoder

function Encoder.new(options)
    options = options or {}
    return setmetatable({
        encryptConstants = options.encryptConstants or false,
        xorKey = options.xorKey or 0x5A,
    }, Encoder)
end

-- Resolve LABEL / JMP label names to numeric PCs
local function resolveLabels(proto)
    local labels = {}
    local code = {}
    -- First pass: strip LABEL, record PC
    for _, ins in ipairs(proto.code or {}) do
        if ins.op == "LABEL" and ins.meta and ins.meta.label then
            labels[ins.meta.label] = #code + 1
        else
            table.insert(code, ins)
        end
    end
    -- Second pass: patch jumps
    -- JMP:        A = relative
    -- JMP_IF*:    B = test register (already set), A = relative
    for pc, ins in ipairs(code) do
        if (ins.op == "JMP" or ins.op == "JMP_IF" or ins.op == "JMP_IFNOT")
            and ins.meta and ins.meta.label then
            local target = labels[ins.meta.label]
            if target then
                local rel = target - pc
                if ins.op == "JMP" then
                    ins.a = rel
                else
                    -- preserve test register in B; put relative in A
                    if ins.b == nil or ins.b == 0 then
                        ins.b = ins.a  -- old IR put register in A
                    end
                    ins.a = rel
                end
            end
        end
    end
    proto.code = code
end

local function encodeProto(self, proto)
    resolveLabels(proto)

    local bc = {
        name = proto.name or "f",
        params = proto.params or 0,
        isVararg = proto.isVararg and true or false,
        maxStack = proto.maxStack or 8,
        code = {},
        constants = {},
        prototypes = {},
    }

    -- constants
    for _, k in ipairs(proto.constants or {}) do
        local v = k.value
        if self.encryptConstants and type(v) == "string" then
            -- lightweight XOR obfuscation of string constants
            local bytes = {}
            for i = 1, #v do
                bytes[i] = hostXor(string.byte(v, i), self.xorKey)
            end
            table.insert(bc.constants, { t = "xs", d = bytes, k = self.xorKey })
        else
            table.insert(bc.constants, v)
        end
    end

    -- code
    for _, ins in ipairs(proto.code or {}) do
        local op = Format.FromIR[ins.op] or Format.Op.NOP
        local a = ins.a or 0
        local b = ins.b or 0
        local c = ins.c or 0
        -- JMP already has relative a
        table.insert(bc.code, op)
        table.insert(bc.code, a)
        table.insert(bc.code, b)
        table.insert(bc.code, c)
    end

    -- nested
    for _, child in ipairs(proto.prototypes or {}) do
        table.insert(bc.prototypes, encodeProto(self, child))
    end

    return bc
end

function Encoder:encode(module)
    local main = module.main or module.prototypes and module.prototypes[1]
    if not main then
        error("Encoder: no main prototype")
    end
    return {
        version = "0.001",
        main = encodeProto(self, main),
    }
end

return Encoder
