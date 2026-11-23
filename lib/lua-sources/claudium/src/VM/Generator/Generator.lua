-- IronBrew0 v1.4 - anti-dcp: opaque entry, split keys, bounce dispatch, no host print
-- Rolling XOR, Base85 bytecode blob, opaque keys, junk protos, in-VM AT
-- Luau-safe (no bitwise ~ operator in emitted code)

local AntiTamper = require("src.Obfuscation.AntiTamper.AntiTamper")
local Hardening = require("src.Obfuscation.Hardening.Hardening")
local StateMachine = require("src.Obfuscation.Hardening.StateMachine")
local Opcodes = require("src.Bytecode.Opcodes")

local Generator = {}
Generator.__index = Generator

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local B85 = Hardening.base85DecodeTable()

local function hostXor(a, b)
    return Hardening.hostXor(a, b)
end

local KEYWORDS = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,
    ["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,
    ["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,
    ["or"]=true,["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,
    ["until"]=true,["while"]=true,["continue"]=true,
    -- stdlib / Roblox (never shadow)
    ["table"]=true,["string"]=true,["math"]=true,["bit32"]=true,["coroutine"]=true,
    ["debug"]=true,["os"]=true,["io"]=true,["package"]=true,["utf8"]=true,
    ["buffer"]=true,["vector"]=true,["task"]=true,["game"]=true,["workspace"]=true,
    ["script"]=true,["shared"]=true,["plugin"]=true,["typeof"]=true,["unpack"]=true,
    ["select"]=true,["pcall"]=true,["xpcall"]=true,["error"]=true,["assert"]=true,
    ["print"]=true,["warn"]=true,["pairs"]=true,["ipairs"]=true,["next"]=true,
    ["type"]=true,["tonumber"]=true,["tostring"]=true,["rawget"]=true,["rawset"]=true,
    ["rawequal"]=true,["setmetatable"]=true,["getmetatable"]=true,["load"]=true,
    ["loadstring"]=true,["require"]=true,["getfenv"]=true,["setfenv"]=true,
    ["getgenv"]=true,["getrenv"]=true,["Instance"]=true,["Vector3"]=true,
    ["CFrame"]=true,["UDim2"]=true,["Enum"]=true,["tick"]=true,["time"]=true,
    ["wait"]=true,["spawn"]=true,["delay"]=true,
}

local function randName(used, n)
    n = n or 1
    local name
    repeat
        local t = {}
        for i = 1, n do
            local idx = math.random(1, #ALPHA)
            t[i] = ALPHA:sub(idx, idx)
        end
        name = table.concat(t)
        if n == 1 or math.random() > 0.35 then
            name = name .. tostring(math.random(0, 99))
        end
    until not used[name] and not KEYWORDS[name]
    used[name] = true
    return name
end

function Generator.new(options)
    options = options or {}
    return setmetatable({
        singleLine = options.singleLine ~= false,
        seed = options.seed,
        target = options.target or "executor",
        antiTamper = options.antiTamper ~= false,
        scrambleOps = options.scrambleOps ~= false,
        encryptStrings = options.encryptStrings ~= false,
        intensity = tonumber(options.intensity) or 1,
        fatVM = options.fatVM ~= false, -- default ON unless explicit false
        rollingXor = options.rollingXor ~= false,
        base85 = options.base85 ~= false,
        opaqueKeys = options.opaqueKeys ~= false,
        superOps = options.superOps ~= false,
    }, Generator)
end

local function flattenProto(proto, protosOut, stringsOut, strMap, xorSeed, salt, strStride)
    table.insert(protosOut, false)
    local idx = #protosOut
    local code = {}
    for i, v in ipairs(proto.code or {}) do code[i] = v end

    local consts = {}
    for _, k in ipairs(proto.constants or {}) do
        local s
        if type(k) == "table" and k.t == "xs" then
            local chars = {}
            for i, b in ipairs(k.d) do chars[i] = hostXor(b, k.k or 0) end
            s = string.char(table.unpack(chars))
        elseif type(k) == "string" then
            s = k
        elseif type(k) == "number" then
            consts[#consts + 1] = k
        elseif type(k) == "boolean" then
            consts[#consts + 1] = k and 1 or 0
        else
            consts[#consts + 1] = 0
        end
        if s then
            if not strMap[s] then
                strMap[s] = #stringsOut + 1
                local raw = {}
                for i = 1, #s do raw[i] = string.byte(s, i) end
                if xorSeed and xorSeed > 0 then
                    -- per-string rolling xor with seed offset by index
                    local enc = Hardening.rollingXorEncrypt(raw, (xorSeed + #stringsOut * (strStride or 17)) % 256, salt or 1)
                    stringsOut[#stringsOut + 1] = enc
                else
                    stringsOut[#stringsOut + 1] = raw
                end
            end
            consts[#consts + 1] = -strMap[s]
        end
    end

    local nested, childMap = {}, {}
    for ci, child in ipairs(proto.prototypes or {}) do
        local fi = flattenProto(child, protosOut, stringsOut, strMap, xorSeed, salt, strStride)
        nested[#nested + 1] = fi
        childMap[ci] = fi
    end
    for i = 1, #code, 4 do
        if code[i] == 29 and childMap[code[i + 2]] then
            code[i + 2] = childMap[code[i + 2]]
        end
    end
    protosOut[idx] = {
        code = code,
        consts = consts,
        params = proto.params or 0,
        isVararg = proto.isVararg and 1 or 0,
        nested = nested,
    }
    return idx
end

-- Heavy superops (0.006c): fold real multi-op patterns into single logical ops 34+
-- 34 SUPER_ADDK   a=dest  b=k1  c=k2     -> R[a]=K[b]+K[c]
-- 35 SUPER_CALLG  a=base  b=gK  c=argK   -> R[a]=_G[K[b]]; R[a+1]=K[c]; call R[a](R[a+1])
-- 36 SUPER_MOVE2  a=dst   b=src  c=dst2  -> R[a]=R[b]; R[c]=R[a]
-- 30 SUPER_NOP    padding only
local function applySuperOps(code, rng, intensity)
    intensity = intensity or 1
    local foldChance = math.min(0.85, 0.35 + 0.15 * intensity)
    local nopChance = math.min(0.25, 0.05 + 0.04 * intensity)
    local out = {}
    local i = 1
    local n = #code
    while i <= n do
        local op = code[i] or 0
        local a, b, c = code[i+1] or 0, code[i+2] or 0, code[i+3] or 0
        local op2 = code[i+4]
        local a2, b2, c2 = code[i+5], code[i+6], code[i+7]
        local op3 = code[i+8]
        local a3, b3, c3 = code[i+9], code[i+10], code[i+11]

        local folded = false
        if rng() < foldChance then
            -- LOADK + LOADK + ADD -> SUPER_ADDK
            if op == 2 and op2 == 2 and op3 == 6
                and a3 == a and (b3 == a or b3 == a2) and (c3 == a2 or c3 == a) then
                -- dest of ADD is a3; const indices b, b2
                local kb, kc = b, b2
                if b3 == a2 and c3 == a then kb, kc = b2, b end
                out[#out+1] = 34; out[#out+1] = a3; out[#out+1] = kb; out[#out+1] = kc
                i = i + 12
                folded = true
            -- GETGLOBAL + LOADK + CALL(base, 2, 2) -> SUPER_CALLG
            elseif op == 27 and op2 == 2 and op3 == 22
                and a2 == (a + 1) and a3 == a and b3 == 2 then
                out[#out+1] = 35; out[#out+1] = a; out[#out+1] = b; out[#out+1] = b2
                i = i + 12
                folded = true
            -- MOVE + MOVE (chain) -> SUPER_MOVE2
            elseif op == 1 and op2 == 1 and b2 == a then
                -- MOVE a,b ; MOVE a2,a  -> SUPER_MOVE2 a,b,a2
                out[#out+1] = 36; out[#out+1] = a; out[#out+1] = b; out[#out+1] = a2
                i = i + 8
                folded = true
            end
        end
        if not folded then
            if rng() < nopChance then
                out[#out+1] = 30; out[#out+1] = rng(0,7); out[#out+1] = rng(0,7); out[#out+1] = rng(0,7)
            end
            out[#out+1] = op; out[#out+1] = a; out[#out+1] = b; out[#out+1] = c
            i = i + 4
        end
    end
    return out
end

local function collectUsedOps(protosOut)
    local used = {}
    for _, p in ipairs(protosOut) do
        local code = p.code or {}
        for i = 1, #code, 4 do
            local op = code[i]
            if op then used[op] = true end
        end
    end
    -- always keep NOP if any super path
    return used
end

function Generator:generate(bytecode)
    local seed = self.seed or (os.time() % 99991 + math.floor((os.clock() or 0) * 1000))
    math.randomseed(seed)
    local intensity = self.intensity
    local bcCodec = Opcodes.makeCodec(seed)
    local layer2Key = math.random(1, 255)
    bcCodec.layer2Key = layer2Key
    -- Custom ISA + layer2 fold

    if intensity < 1 then intensity = 1 end

    local used = {}
    local function rn(n) return randName(used, n or math.random(1, 2)) end

    local nC, nJ, nE = rn(1), rn(1), rn(1)
    local nPool, nGS, nGK, nPr, nRun = rn(2), rn(2), rn(2), rn(2), rn(2)
    local nR, nCd, nPc, nOp = rn(1), rn(1), rn(1), rn(1)
    local nA, nB, nC2 = rn(1), rn(1), rn(1)
    local nBase, nArgs, nFn, nRt, nI = rn(1), rn(1), rn(1), rn(1), rn(1)
    local nT, nVa, nPm, nP, nSub = rn(1), rn(1), rn(1), rn(1), rn(1)
    local nNarg, nNret, nKv, nLoop = rn(1), rn(1), rn(1), rn(1)
    local nFail, nTmp, nKey, nInv, nXor = rn(1), rn(2), rn(1), rn(2), rn(2)
    local nInv_m, nInv_ok, nInv_ak, nInv_bk, nInv_ck, nInv_l2 = rn(2), rn(2), rn(2), rn(2), rn(2), rn(2)
    local nSalt, nBlob, nDec, nMap = rn(1), rn(2), rn(2), rn(2)
    local nK0, nTick = rn(1), rn(1)
    local nRes, nCall, nGName = rn(2), rn(2), rn(2)

    local xorSeed = math.random(17, 240) -- always encrypt string pool (v1.0)
    local salt = math.random(1, 31)
    local blobSeed = math.random(17, 240)
    local strStride = math.random(3, 53) -- not fixed 17 (breaks static deobfuscators)

    -- Anti-tamper integrity is implemented by the IB_AT virtual opcode.

    local opMap, opInv, opMapPrimary = nil, nil, nil
    if self.scrambleOps then
        opMap, opInv = AntiTamper.scrambleOpcodeMap(seed, 40)
        -- Non-bijective aliases: extra physical opcodes decode to same logical
        -- Deobfuscators that assume inv is 1:1 break.
        do
            local nextPhys = 41
            local aliasList = {} -- logical -> {phys...}
            for log = 1, 40 do
                aliasList[log] = { opMap[log] }
            end
            for log = 1, 36 do
                local nAlias = math.random(0, 2)
                for _ = 1, nAlias do
                    if nextPhys > 80 then break end
                    local phys = nextPhys
                    nextPhys = nextPhys + 1
                    opMap[log .. "_" .. phys] = phys -- dummy
                    opInv[phys] = log
                    aliasList[log][#aliasList[log] + 1] = phys
                end
            end
            -- When encoding, pick random alias for each logical
            local primary = opMap
            opMap = setmetatable({}, {
                __index = function(_, log)
                    local list = aliasList[log]
                    if not list or #list == 0 then return primary[log] or log end
                    return list[math.random(1, #list)]
                end
            })
            -- Keep primary mapping for trampoline stability: use primary[log] via opMapPrimary
            opMapPrimary = primary
            for log, list in pairs(aliasList) do
                -- ensure primary is in inv
                opInv[primary[log]] = log
            end
        end

        -- also map superops 30-32
        for s = 30, 36 do
            if not opMap[s] then
                local phys = math.random(34, 62)
                while opInv[phys] do phys = math.random(34, 62) end
                opMap[s] = phys
                opInv[phys] = s
            end
        end
    end

    local protosOut, stringsOut, strMap = {}, {}, {}
        local mainIdx = flattenProto(bytecode.main, protosOut, stringsOut, strMap, xorSeed > 0 and xorSeed or nil, salt, strStride)

    -- v1.4: constant-dump taunt strings (show up in string dumpers, unused by real code)
    do
        local taunts = {
            "i was here. you cant do it. give up. -ironb2",
            "i was here. you cant do it. give up. -ironb2",
            "IronBrew0: constant dump is not a deobfuscation",
            "nice try. still encrypted. -ironb2",
            "you dumped strings. the VM remains. -ironb2",
        }
        for _, msg in ipairs(taunts) do
            if not strMap[msg] then
                strMap[msg] = #stringsOut + 1
                local raw = {}
                for i = 1, #msg do raw[i] = string.byte(msg, i) end
                if xorSeed and xorSeed > 0 then
                    local enc = Hardening.rollingXorEncrypt(raw, (xorSeed + #stringsOut * strStride) % 256, salt)
                    stringsOut[#stringsOut + 1] = enc
                else
                    stringsOut[#stringsOut + 1] = raw
                end
            end
        end
        -- plant taunt indices into a junk proto const list so proto-level dumps see them
        local tidx = strMap[taunts[1]]
        if tidx then
            local junkConsts = { -tidx, -tidx, -tidx }
            for i = 2, #taunts do
                local ti = strMap[taunts[i]]
                if ti then junkConsts[#junkConsts + 1] = -ti end
            end
            protosOut[#protosOut + 1] = {
                code = { 23, 0, 1, 0 }, -- RETURN only
                consts = junkConsts,
                params = 0,
                isVararg = 0,
                nested = {},
            }
        end
    end

    -- Superops first (logical ops)
    for _, p in ipairs(protosOut) do
        if self.superOps then
            p.code = applySuperOps(p.code, math.random, intensity)
        end
    end
    local usedOps = collectUsedOps(protosOut)
    if not next(usedOps) then usedOps[2] = true; usedOps[23] = true end

    local entryIdx = mainIdx
    -- Trampoline entry at index 1.
    -- When anti-tamper is enabled, IB_AT is the first virtual instruction.
    -- The expected VM checksum is stored as an encrypted numeric constant and
    -- filled after wire encoding, so there is no plaintext anti-tamper prelude.
    do
        local trampCode = {}
        local trampConsts = {}
        if self.antiTamper then
            trampCode[#trampCode + 1] = 33 -- IB_AT
            trampCode[#trampCode + 1] = 0
            trampCode[#trampCode + 1] = 1  -- K[1..4] = expected checksum bytes
            trampCode[#trampCode + 1] = 0
            trampConsts[1], trampConsts[2], trampConsts[3], trampConsts[4] = 0, 0, 0, 0
            usedOps[33] = true
        end
        local tail = {
            29, 0, mainIdx, 0,
            22, 0, 1, 1,
            23, 0, 1, 0,
        }
        for i = 1, #tail do trampCode[#trampCode + 1] = tail[i] end

        table.insert(protosOut, 1, {
            code = trampCode, consts = trampConsts, params = 0, isVararg = 0, nested = { mainIdx },
        })
        mainIdx = mainIdx + 1
        for pi = 2, #protosOut do
            local p = protosOut[pi]
            if p.nested then
                for j = 1, #p.nested do p.nested[j] = p.nested[j] + 1 end
            end
            if p.code then
                for i = 1, #p.code, 4 do
                    if p.code[i] == 29 then
                        p.code[i + 2] = (p.code[i + 2] or 0) + 1
                    end
                end
            end
        end
        for i = 1, #protosOut[1].code, 4 do
            if protosOut[1].code[i] == 29 then
                protosOut[1].code[i + 2] = mainIdx
                break
            end
        end
        protosOut[1].nested = { mainIdx }
        entryIdx = 1
        usedOps[29] = true
        usedOps[22] = true
        usedOps[23] = true
    end

    -- Decoys appended at END only (do not shift entry)
    do
        local nd = math.random(1, 3)
        for _ = 1, nd do
            local nins = math.random(2, 5)
            local code = {}
            for i = 1, nins do
                local o = (i - 1) * 4
                code[o + 1] = math.random(1, 28)
                code[o + 2] = math.random(0, 3)
                code[o + 3] = math.random(0, 3)
                code[o + 4] = math.random(0, 3)
            end
            local o = nins * 4
            code[o + 1] = 23
            code[o + 2] = 0
            code[o + 3] = 1
            code[o + 4] = 0
            protosOut[#protosOut + 1] = {
                code = code, consts = {}, params = 0, isVararg = 0, nested = {},
            }
        end
    end



    -- v1.0: encode to custom bytecode (wire opcodes + mixed operands)
    local function encodeProtoCode(code)
        local out = {}
        local nins = math.floor(#code / 4)
        for i = 1, nins do
            local o = (i - 1) * 4
            local logOp = code[o + 1] or 0
            local a, b, c = code[o + 2] or 0, code[o + 3] or 0, code[o + 4] or 0
            local wires = bcCodec.toWire[logOp] or { logOp }
            local w = wires[math.random(1, #wires)]
            out[o + 1] = w
            out[o + 2] = a % 256
            out[o + 3] = b % 256
            out[o + 4] = c % 256
        end
        return out
    end
    for _, p in ipairs(protosOut) do
        if p.code then
            p.code = encodeProtoCode(p.code)
        end
    end

    -- Fat VM: junk protos (collect logical ops before scramble)
    local junkCount = 0
    if self.fatVM then
        junkCount = math.floor(40 * intensity + math.random(20, 40 * intensity))
        for _ = 1, junkCount do
            local jp = Hardening.makeJunkProto(math.random)
            for i = 1, #(jp.code or {}), 4 do
                usedOps[jp.code[i] or 0] = true
            end
            jp.code = encodeProtoCode(jp.code)
            protosOut[#protosOut + 1] = jp
        end
    end

    -- The anti-tamper checksum is calculated over the final wire-code stream
    -- for every prototype, including fat-VM junk prototypes. IB_AT reconstructs
    -- this exact stream after blob unpacking and PC permutation.
    if self.antiTamper then
        local h = 2166136261
        local pos = 0
        local function addByte(v)
            pos = pos + 1
            local b = (v or 0) % 256
            h = (h + b * 16777619 + pos * 31) % 4294967296
        end
        for _, p in ipairs(protosOut) do
            local code = p.code or {}
            local nins = math.floor(#code / 4)
            addByte(nins % 256)
            addByte(math.floor(nins / 256) % 256)
            for i = 1, #code do addByte(code[i]) end
        end
        local expected = h % 2147483647
        protosOut[1].consts[1] = expected % 256
        protosOut[1].consts[2] = math.floor(expected / 256) % 256
        protosOut[1].consts[3] = math.floor(expected / 65536) % 256
        protosOut[1].consts[4] = math.floor(expected / 16777216) % 256
    end

    -- Pack protos -> rolling xor -> base85 (or number array fallback)
    local packed = Hardening.packProtos(protosOut)
    -- v1.7 Claudium: LZ compress then rolling XOR then base85 (Luraph-style density)
    local packedLz = Hardening.lzCompress(packed)
    local packedEnc = Hardening.rollingXorEncrypt(packedLz, blobSeed, salt)
    local blobStr = self.base85 and Hardening.base85Encode(packedEnc) or nil
    local useLz = true
    -- Luraph-style magic: PR$ + random symbol(s)
    local payloadMagic = "PR$" .. string.char(math.random(65, 90), math.random(97, 122))


    -- v1.0 custom ISA: wire->logical map + operand mix keys
    local invMask = math.random(1, 255)
    local invArr = {}
    for phys = 1, 250 do
        local v = (bcCodec.fromWire[phys]) or 0
        -- v1.3: inv[wire] = logical XOR mask (no position term - breaks dcp tu rebuild)
        invArr[phys] = Hardening.hostXor(v % 256, invMask)
    end
    local invLit = "{" .. table.concat(invArr, ",") .. "}"
    local invMaskLit = tostring(invMask)
    local opKeyLit = tostring(bcCodec.opKey)
    local aKeyLit = tostring(bcCodec.aKey)
    local bKeyLit = tostring(bcCodec.bKey)
    local cKeyLit = tostring(bcCodec.cKey)
    local layer2Lit = tostring(layer2Key)

    local lines = {}
    local function L(s) lines[#lines + 1] = s end

    -- Portable XOR
    L(("local function %s(%s,%s) %s=math.floor(%s)%%256 %s=math.floor(%s)%%256 local %s,%s=0,1 for %s=1,8 do local %s,%s=%s%%2,%s%%2 if %s~=%s then %s=%s+%s end %s=math.floor(%s/2) %s=math.floor(%s/2) %s=%s*2 end return %s end"):format(
        nXor, nA, nB, nA, nA, nB, nB, nT, nI, nLoop, nC, nC2, nA, nB, nC, nC2, nT, nT, nI, nA, nA, nB, nB, nI, nI, nT))

    
-- Opaque seeds
    local seedExpr = self.opaqueKeys and Hardening.opaqueByte(xorSeed) or tostring(xorSeed)
    local saltExpr = self.opaqueKeys and Hardening.opaqueByte(salt) or tostring(salt)
    local blobExpr = self.opaqueKeys and Hardening.opaqueByte(blobSeed) or tostring(blobSeed)
    L(("local %s=%s local %s=%s local %s=%s"):format(nKey, seedExpr, nSalt, saltExpr, nK0, blobExpr))

    -- v1.0: encrypted constant/string blob (flat stream, separate seed)
    local poolSeed = math.random(11, 250)
    local poolSalt = math.random(1, 40)
    local flat = {}
    local function putU16(n)
        n = math.floor(n) % 65536
        flat[#flat + 1] = math.floor(n / 256)
        flat[#flat + 1] = n % 256
    end
    putU16(#stringsOut)
    for i, bytes in ipairs(stringsOut) do
        putU16(#bytes)
        for j = 1, #bytes do flat[#flat + 1] = bytes[j] % 256 end
    end
    local flatEnc = Hardening.rollingXorEncrypt(flat, poolSeed, poolSalt)
    local flatLit = "{" .. table.concat(flatEnc, ",") .. "}"
    local nPoolBlob, nPoolSeed, nPoolSalt = rn(2), rn(2), rn(2)
    local nPD, nPK, nPS, nPpos, nPrb, nPru, nPns, nPln = rn(2), rn(2), rn(2), rn(2), rn(2), rn(2), rn(2), rn(2)
    L(("local %s=%s"):format(nPoolBlob, flatLit))
    L(("local %s=%s local %s=%s"):format(
        nPoolSeed, self.opaqueKeys and Hardening.opaqueByte(poolSeed) or tostring(poolSeed),
        nPoolSalt, self.opaqueKeys and Hardening.opaqueByte(poolSalt) or tostring(poolSalt)))
    L(("local %s; do"):format(nPool))
    L(("local %s={} local %s=%s local %s=%s"):format(nPD, nPK, nPoolSeed, nPS, nPoolSalt))
    L(("for %s=1,#%s do local %s=%s[%s] or 0 local %s=%s(%s,%s) %s[%s]=%s %s=(%s*3+%s+%s)%%256 end"):format(
        nI, nPoolBlob, nTmp.."c", nPoolBlob, nI, nTmp, nXor, nTmp.."c", nPK, nPD, nI, nTmp, nPK, nPK, nTmp.."c", nPS))
    L(("local %s=1"):format(nPpos))
    L(("local function %s() local %s=%s[%s] or 0 %s=%s+1 return %s end"):format(nPrb, nTmp, nPD, nPpos, nPpos, nPpos, nTmp))
    L(("local function %s() return %s()*256+%s() end"):format(nPru, nPrb, nPrb))
    L(("local %s=%s() %s={}"):format(nPns, nPru, nPool))
    L(("for %s=1,%s do local %s=%s() local %s={} for %s=1,%s do %s[%s]=%s() end %s[%s]=%s end"):format(
        nI, nPns, nPln, nPru, nRt, nLoop, nPln, nRt, nLoop, nPrb, nPool, nI, nRt))
    L("end")

    -- Rolling string decode: seed_i = (xorSeed + (i-1)*17) % 256
    local nStride = rn(2)
    L(("local %s=%s"):format(nStride, self.opaqueKeys and Hardening.opaqueByte(strStride) or tostring(strStride)))
    L(("local function %s(%s) local %s=(%s+(%s-1)*%s)%%256 local %s=%s[%s] if not %s then return '' end local %s={} for %s=1,#%s do local %s=%s[%s] or 0 local %s=%s(%s,%s) %s[%s]=%s(%s) %s=(%s*3+%s+%s)%%256 end return %s(%s) end"):format(
        nGS, nI,
        nT, nKey, nI, nStride,
        nArgs, nPool, nI, nArgs,
        nRt, nLoop, nArgs,
        nC2, nArgs, nLoop,
        nTmp, nXor, nC2, nT,
        nRt, nLoop, nC, nTmp,
        nT, nT, nC2, nSalt,
        nJ, nRt))

    L(("local function %s(%s,%s) local %s=%s[5] if not %s then return nil end local %s=%s[%s] if %s==nil then return nil end if type(%s)=='number' and %s<0 then return %s(-%s) end if type(%s)=='number' and %s>0 and type(%s[10])=='number' then return %s(%s,%s[10]) end return %s end"):format(
        nGK, nP, nB, nTmp.."ct", nP, nTmp.."ct", nKv, nTmp.."ct", nB, nKv, nKv, nKv, nGS, nKv, nKv, nKv, nP, nXor, nKv, nP, nKv))

    -- BYTECODE BLOB ONLY: no readable proto tables
    L(Hardening.emitBlobUnpack(packedEnc, {
        blob = nBlob,
        protos = nPr,
        xor = nXor,
        seed = nK0,
        salt = nSalt,
        b85 = (self.base85 and blobStr) or nil,
        lz = useLz,
        magic = payloadMagic,
        -- randomized locals so deobfuscators cannot grep `_b`/`_k`/`_s`
        L = (function()
            local function rn()
                local letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                local pool = letters .. "0123456789"
                local i = math.random(1, #letters)
                local s = letters:sub(i, i) -- always start with a letter
                for _ = 1, math.random(2, 5) do
                    local j = math.random(1, #pool)
                    s = s .. pool:sub(j, j)
                end
                return s
            end
            local keys = {"b","k","s","d","p","rb","ru","ri","t","np","pi","ni","ci","ops","as","bs","cs","aux","ord","consts","nk","tg","pm","va","nest","nj","ji","x","i","v"}
            local L = {}
            local used = {}
            for _, k in ipairs(keys) do
                local n
                repeat n = rn() until not used[n]
                used[n] = true
                L[k] = n
            end
            return L
        end)(),
    }))

    -- Anti-tamper is now a virtual instruction (IB_AT) in the encrypted VM blob.
    -- Keep only a runtime state bit in the host shell; no readable guard source,
    -- checksum body, or tamper message is emitted here.
    L(("%s=false"):format(nFail))

    -- v1.5 constant table protection (Rerubi/Luraph-style): numeric consts XOR'd at rest
    do
        local nCk = rn(2)
        L(("do local %s=%s for %s=1,#%s do local %s=%s[%s] if type(%s)=='table' and type(%s[5])=='table' then local %s=(%s+%s*17)%%255+1 %s[10]=%s local %s=%s[5] for %s=1,#%s do local %s=%s[%s] if type(%s)=='number' and %s>0 then %s[%s]=%s(%s,%s) end end end end end"):format(
            nCk, tostring(math.random(1,200)),
            nI, nPr, nTmp, nPr, nI, nTmp, nTmp,
            nTmp.."k", nCk, nI,
            nTmp, nTmp.."k",
            nTmp.."c", nTmp,
            nLoop, nTmp.."c",
            nKv, nTmp.."c", nLoop,
            nKv, nKv,
            nTmp.."c", nLoop, nXor, nKv, nTmp.."k"))
    end
    do
        local nM, nOk, nAk, nBk, nCk, nL2 = rn(2), rn(2), rn(2), rn(2), rn(2), rn(2)
        -- store for later dispatch use
        nInv_m, nInv_ok, nInv_ak, nInv_bk, nInv_ck, nInv_l2 = nM, nOk, nAk, nBk, nCk, nL2
        L(("local %s=%s"):format(nInv, invLit))
        L(("local %s=%s"):format(nM, invMaskLit))
        L(("local %s=%s"):format(nOk, opKeyLit))
        L(("local %s=%s"):format(nAk, aKeyLit))
        L(("local %s=%s"):format(nBk, bKeyLit))
        L(("local %s=%s"):format(nCk, cKeyLit))
        L(("local %s=%s"):format(nL2, layer2Lit or "0"))
    end


    -- Opaque env + Roblox-safe global resolve (use [] not only rawget — Roblox uses __index)
    L(("local function %s(%s) local %s={} for %s=1,#%s do %s[%s]=%s(%s[%s]) end return %s(%s) end"):format(
        nGName, nArgs, nRt, nLoop, nArgs, nRt, nLoop, nC, nArgs, nLoop, nJ, nRt))
    -- Env: getgenv first (hooks). Fill only MISSING keys from getrenv/_G so print still works on Roblox.
    L(("local function %s()"):format(nRes))
    L(("local %s=(type(_G)=='table' and _G) or (type(_ENV)=='table' and _ENV) or {}"):format(nTmp.."b"))
    L(("local %s=%s"):format(nTmp.."out", nTmp.."b"))
    -- getgenv
    L(("do local %s=%s({103,101,116,103,101,110,118}) local %s=%s[%s] if type(%s)=='function' then local %s,%s=pcall(%s) if %s and type(%s)=='table' then %s=%s end end end"):format(
        nTmp, nGName, nTmp.."x", nTmp.."b", nTmp, nTmp.."x", nTmp.."ok", nTmp.."e", nTmp.."x", nTmp.."ok", nTmp.."e", nTmp.."out", nTmp.."e"))
    -- getfenv fill into a copy-like prefer: if still base _G, try getfenv
    L(("do local %s=%s({103,101,116,102,101,110,118}) local %s=%s[%s] if type(%s)=='function' then local %s,%s=pcall(%s,0) if %s and type(%s)=='table' and %s==%s then %s=%s end end end"):format(
        nTmp.."f", nGName, nTmp.."x", nTmp.."b", nTmp.."f", nTmp.."x", nTmp.."ok", nTmp.."e", nTmp.."x", nTmp.."ok", nTmp.."e", nTmp.."out", nTmp.."b", nTmp.."out", nTmp.."e"))
    -- fill missing from getrenv (never overwrite existing — preserves hooked print)
    L(("do local %s=%s({103,101,116,114,101,110,118}) local %s=%s[%s] if type(%s)=='function' then local %s,%s=pcall(%s) if %s and type(%s)=='table' then for %s,%s in next,%s do if %s[%s]==nil then %s[%s]=%s end end end end end"):format(
        nTmp.."r", nGName, nTmp.."x", nTmp.."b", nTmp.."r", nTmp.."x", nTmp.."ok", nTmp.."e", nTmp.."x", nTmp.."ok", nTmp.."e", nTmp.."k", nTmp.."v", nTmp.."e", nTmp.."out", nTmp.."k", nTmp.."out", nTmp.."k", nTmp.."v"))
    -- fill missing from _G
    L(("if type(_G)=='table' then for %s,%s in next,_G do if %s[%s]==nil then %s[%s]=%s end end end"):format(
        nTmp.."k", nTmp.."v", nTmp.."out", nTmp.."k", nTmp.."out", nTmp.."k", nTmp.."v"))
    L(("return %s end"):format(nTmp.."out"))
    L(("local %s=%s()"):format(nE, nRes))
    -- Seed critical builtins into env if missing (Roblox/executor)
    L(("do local %s={'print','warn','error','pairs','ipairs','type','tostring','tonumber','pcall','xpcall','select','unpack','assert'} for %s=1,#%s do local %s=%s[%s] if %s[%s]==nil then local %s=nil if type(_G)=='table' then %s=_G[%s] end if %s==nil and type(getfenv)=='function' then local %s,%s=pcall(getfenv,0) if %s and type(%s)=='table' then %s=%s[%s] end end if %s~=nil then %s[%s]=%s end end end end"):format(
        nTmp.."bl", nI, nTmp.."bl", nTmp.."nm", nTmp.."bl", nI, nE, nTmp.."nm", nTmp.."v", nTmp.."v", nTmp.."nm", nTmp.."v", nTmp.."ok", nTmp.."e", nTmp.."ok", nTmp.."e", nTmp.."v", nTmp.."e", nTmp.."nm", nTmp.."v", nE, nTmp.."nm", nTmp.."v"))

    -- Lookup: prefer metamethod-aware index (Roblox), then rawget, then re-scan envs
    L(("local function %s(%s)"):format(nRes.."G", nTmp))
    L(("local %s"):format(nTmp.."v"))
    L(("if type(%s)=='table' then %s=%s[%s] end"):format(nE, nTmp.."v", nE, nTmp))
    L(("if %s==nil and type(_G)=='table' then %s=_G[%s] end"):format(nTmp.."v", nTmp.."v", nTmp))
    L(("if %s==nil and type(_ENV)=='table' then %s=_ENV[%s] end"):format(nTmp.."v", nTmp.."v", nTmp))
    L(("if %s==nil and type(getrenv)=='function' then local %s,%s=pcall(getrenv) if %s and type(%s)=='table' then %s=%s[%s] end end"):format(
        nTmp.."v", nTmp.."ok", nTmp.."e", nTmp.."ok", nTmp.."e", nTmp.."v", nTmp.."e", nTmp))
    L(("if %s==nil and type(shared)=='table' then %s=shared[%s] end"):format(nTmp.."v", nTmp.."v", nTmp))
    L(("if %s==nil then local %s=%s() if type(%s)=='table' then %s=%s[%s] %s=%s end end"):format(
        nTmp.."v", nTmp.."e", nRes, nTmp.."e", nTmp.."v", nTmp.."e", nTmp, nE, nTmp.."e"))
    L(("if %s==nil and type(getfenv)=='function' then local %s,%s=pcall(getfenv,0) if %s and type(%s)=='table' then %s=%s[%s] end end"):format(
        nTmp.."v", nTmp.."ok", nTmp.."e", nTmp.."ok", nTmp.."e", nTmp.."v", nTmp.."e", nTmp))
    L(("return %s end"):format(nTmp.."v"))
    -- Call proxy: resolve nil via env once more if callee missing (Roblox race)
    -- never call non-functions (executor: "attempt to call a string value")
    L(("local function %s(%s,...)"):format(nCall, nFn))
    L(("if type(%s)=='string' then %s=%s(%s) end"):format(nFn, nFn, nRes.."G", nFn))
    L(("if type(%s)~='function' then return end"):format(nFn))
    L(("return %s(...) end"):format(nFn))

    -- Anti-tamper executes as IB_AT inside the VM dispatcher.

    -- Interpreter
    L(("local function %s(%s,%s,%s)"):format(nRun, nP, nArgs, nE))
    L(("if %s then return end"):format(nFail))
    L("local _up=table.unpack or unpack or function(t,i,j) local r={} i=i or 1 j=j or #t for k=i,j do r[#r+1]=t[k] end return r[1],r[2],r[3],r[4],r[5],r[6],r[7],r[8] end")
    -- SoA: p[1]=ops p[2]=as p[3]=bs p[4]=cs p[5]=consts p[6]=params p[7]=vararg p[8]=nested
    L(("local %s=%s[1] local %s=%s[2] local %s=%s[3] local %s=%s[4] local %s=%s[9] local %s={} local %s=%s[6] or 0 local %s=1 local %s=0"):format(
        nCd, nP,           -- ops
        nBase, nP,         -- as
        nTmp .. "bs", nP,  -- bs
        nTmp .. "cs", nP,  -- cs
        nTmp .. "ord", nP, -- PC perm (logical->physical)
        nR, nPm, nP, nPc, nTick))
    L(("for %s=1,(%s or 0) do %s[%s-1]=%s[%s] end"):format(nI, nPm, nR, nI, nArgs, nI))
    L(("if (%s[7] or 0)>0 then local %s={} for %s=%s+1,#%s do %s[#%s+1]=%s[%s] end %s._=%s end"):format(
        nP, nVa, nI, nPm, nArgs, nVa, nVa, nArgs, nI, nR, nVa))
    -- v1.0: table dispatch + dispatcher state machine (replaces if/elseif chain)
    local function need(op) return usedOps[op] end
    local nH, nSt, nHfn = rn(2), rn(2), rn(2)

    local function poly(op, body)
        local variants = { body }
        if op == 6 then
            variants = {
                ("%s[%s]=(%s[%s] or 0)+(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2),
                ("%s[%s]=(%s[%s] or 0)-(-(%s[%s] or 0))"):format(nR, nA, nR, nB, nR, nC2),
                ("%s[%s]=0+(%s[%s] or 0)+(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2),
            }
        elseif op == 1 then
            variants = {
                ("%s[%s]=%s[%s]"):format(nR, nA, nR, nB),
                ("do local %s=%s[%s] %s[%s]=%s end"):format(nTmp, nR, nB, nR, nA, nTmp),
            }
        elseif op == 7 then
            variants = {
                ("%s[%s]=(%s[%s] or 0)-(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2),
                ("%s[%s]=(%s[%s] or 0)+(-(%s[%s] or 0))"):format(nR, nA, nR, nB, nR, nC2),
            }
        elseif op == 8 then
            variants = {
                ("%s[%s]=(%s[%s] or 0)*(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2),
                ("%s[%s]=(%s[%s] or 0)*(%s[%s] or 0)*1"):format(nR, nA, nR, nB, nR, nC2),
            }
        elseif op == 3 then
            variants = {
                ("%s[%s]=nil"):format(nR, nA),
                ("%s[%s]=(nil)"):format(nR, nA),
            }
        end
        return variants[math.random(1, #variants)]
    end

    local handlers = {}
    local function setH(op, body)
        if not need(op) then return end
        handlers[op] = poly(op, body)
    end
    setH(1, ("%s[%s]=%s[%s]"):format(nR, nA, nR, nB))
    setH(2, ("%s[%s]=%s(%s,%s)"):format(nR, nA, nGK, nP, nB))
    setH(3, ("%s[%s]=nil"):format(nR, nA))
    setH(4, ("%s[%s]=(%s~=0)"):format(nR, nA, nB))
    setH(5, ("local %s=%s._ or {} %s[%s]=%s[1]"):format(nVa, nR, nR, nA, nVa))
    setH(6, ("%s[%s]=(%s[%s] or 0)+(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2))
    setH(7, ("%s[%s]=(%s[%s] or 0)-(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2))
    setH(8, ("%s[%s]=(%s[%s] or 0)*(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2))
    setH(9, ("%s[%s]=(%s[%s] or 0)/(%s[%s] or 1)"):format(nR, nA, nR, nB, nR, nC2))
    setH(10, ("%s[%s]=(%s[%s] or 0)%%(%s[%s] or 1)"):format(nR, nA, nR, nB, nR, nC2))
    setH(11, ("%s[%s]=(%s[%s] or 0)^(%s[%s] or 0)"):format(nR, nA, nR, nB, nR, nC2))
    setH(12, ("%s[%s]=tostring(%s[%s] or '')..tostring(%s[%s] or '')"):format(nR, nA, nR, nB, nR, nC2))
    setH(13, ("%s[%s]=-(%s[%s] or 0)"):format(nR, nA, nR, nB))
    setH(14, ("%s[%s]=not %s[%s]"):format(nR, nA, nR, nB))
    setH(15, ("%s[%s]=#(%s[%s] or '')"):format(nR, nA, nR, nB))
    setH(16, ("%s[%s]=(%s[%s]==%s[%s])"):format(nR, nA, nR, nB, nR, nC2))
    setH(17, ("%s[%s]=(%s[%s]<%s[%s])"):format(nR, nA, nR, nB, nR, nC2))
    setH(18, ("%s[%s]=(%s[%s]<=%s[%s])"):format(nR, nA, nR, nB, nR, nC2))
    setH(19, ("%s=%s+%s-1"):format(nPc, nPc, nA))
    setH(20, ("if %s[%s] then %s=%s+%s-1 end"):format(nR, nB, nPc, nPc, nA))
    setH(21, ("if not %s[%s] then %s=%s+%s-1 end"):format(nR, nB, nPc, nPc, nA))
    if need(22) then
        handlers[22] = ("local %s=%s[%s] local %s=%s-1 if %s<0 then %s=0 end local %s={} for %s=1,%s do %s[%s]=%s[%s+%s] end local %s={%s(%s,_up(%s,1,%s))} local %s=(%s>0) and (%s-1) or #%s for %s=1,%s do %s[%s+%s-1]=%s[%s] end"):format(
            nFn, nR, nA, nNarg, nB, nNarg, nNarg, nArgs, nI, nNarg, nArgs, nI, nR, nA, nI, nRt, nCall, nFn, nArgs, nNarg, nNret, nC2, nC2, nRt, nI, nNret, nR, nA, nI, nRt, nI)
    end
    if need(23) then
        handlers[23] = ("local %s=%s-1 if %s<0 then %s=0 end local %s={} for %s=1,%s do %s[%s]=%s[%s+%s-1] end return _up(%s,1,%s)"):format(
            nNret, nB, nNret, nNret, nRt, nI, nNret, nRt, nI, nR, nA, nI, nRt, nNret)
    end
    setH(24, ("%s[%s]={}"):format(nR, nA))
    if need(25) then handlers[25] = ("local %s=%s[%s] %s[%s]=%s and %s[%s[%s]]"):format(nT, nR, nB, nR, nA, nT, nT, nR, nC2) end
    if need(26) then handlers[26] = ("local %s=%s[%s] if %s then %s[%s[%s]]=%s[%s] end"):format(nT, nR, nA, nT, nT, nR, nB, nR, nC2) end
    if need(27) then handlers[27] = ("local %s=%s(%s,%s) local %s=%s(%s) if %s==nil and type(%s)=='table' then %s=%s[%s] end %s[%s]=%s"):format(nT, nGK, nP, nB, nTmp, nRes.."G", nT, nTmp, nE, nTmp, nE, nT, nR, nA, nTmp) end
    if need(28) then handlers[28] = ("local %s=%s(%s,%s) if type(%s)=='table' then %s[%s]=%s[%s] end"):format(nT, nGK, nP, nB, nE, nE, nT, nR, nA) end
    if need(29) then handlers[29] = ("local %s=%s[%s] %s[%s]=function(...) return %s(%s,{...},%s) end"):format(nSub, nPr, nB, nR, nA, nRun, nSub, nE) end
    setH(30, "")
    setH(31, ("%s[%s]=%s(%s,%s)"):format(nR, nA, nGK, nP, nB))
    setH(32, ("%s[%s]=%s[%s]"):format(nR, nA, nR, nB))
    if need(33) then
        -- IB_AT: VM-resident full bytecode integrity check. The expected hash is
        -- fetched from the trampoline's protected constant table; the check is
        -- dispatched exactly like any other virtual opcode.
        local atH = nTmp .. "vh"
        local atPos = nTmp .. "vp"
        local atExp = nTmp .. "ve"
        local atPi = nTmp .. "vi"
        local atP = nTmp .. "vP"
        local atOps = nTmp .. "vo"
        local atAs = nTmp .. "va"
        local atBs = nTmp .. "vb"
        local atCs = nTmp .. "vc"
        local atOrd = nTmp .. "vr"
        local atLi = nTmp .. "vl"
        local atPh = nTmp .. "vq"
        local atV = nTmp .. "vv"
        local atAdd = nTmp .. "vx"
        local msg = nTmp .. "vm"
        handlers[33] = table.concat({
            "local " .. atExp .. "=(" .. nGK .. "(" .. nP .. "," .. nB .. ") or 0)+(" .. nGK .. "(" .. nP .. "," .. nB .. "+1) or 0)*256+(" .. nGK .. "(" .. nP .. "," .. nB .. "+2) or 0)*65536+(" .. nGK .. "(" .. nP .. "," .. nB .. "+3) or 0)*16777216",
            "local " .. atH .. "=2166136261 local " .. atPos .. "=0",
            "local function " .. atAdd .. "(" .. atV .. ") " .. atPos .. "=" .. atPos .. "+1 local _z=(" .. atV .. " or 0)%256 " .. atH .. "=(" .. atH .. "+_z*16777619+" .. atPos .. "*31)%4294967296 end",
            "for " .. atPi .. "=1,#" .. nPr .. " do",
            "local " .. atP .. "=" .. nPr .. "[" .. atPi .. "] local " .. atOps .. "=" .. atP .. "[1] or {} local " .. atAs .. "=" .. atP .. "[2] or {} local " .. atBs .. "=" .. atP .. "[3] or {} local " .. atCs .. "=" .. atP .. "[4] or {} local " .. atOrd .. "=" .. atP .. "[9] or {}",
            atAdd .. "(#" .. atOps .. ") " .. atAdd .. "(math.floor(#" .. atOps .. "/256))",
            "for " .. atLi .. "=1,#" .. atOps .. " do local " .. atPh .. "=" .. atOrd .. "[" .. atLi .. "] or " .. atLi .. " " .. atAdd .. "(" .. atOps .. "[" .. atPh .. "]) " .. atAdd .. "(" .. atAs .. "[" .. atPh .. "]) " .. atAdd .. "(" .. atBs .. "[" .. atPh .. "]) " .. atAdd .. "(" .. atCs .. "[" .. atPh .. "]) end",
            "end",
            "if (" .. atH .. "%2147483647)~=" .. atExp .. " then local " .. msg .. "=" .. nC .. "(67,108,97,117,100,105,117,109,58,32,116,97,109,112,101,114,32,100,101,116,101,99,116,101,100) error(" .. msg .. ",0) end",
        }, " ")
    end
    setH(34, ("%s[%s]=(%s(%s,%s) or 0)+(%s(%s,%s) or 0)"):format(nR, nA, nGK, nP, nB, nGK, nP, nC2))
    if need(35) then
        handlers[35] = ("local %s=%s(%s,%s) %s[%s]=%s(%s) %s[%s+1]=%s(%s,%s) local %s={%s(%s[%s],%s[%s+1])} %s[%s]=%s[1]"):format(
            nT, nGK, nP, nB, nR, nA, nRes.."G", nT, nR, nA, nGK, nP, nC2, nRt, nCall, nR, nA, nR, nA, nR, nA, nRt)
    end
    setH(36, ("%s[%s]=%s[%s] %s[%s]=%s[%s]"):format(nR, nA, nR, nB, nR, nC2, nR, nA))

    -- Operand locals BEFORE handlers so closures capture them as upvalues
    L(("local %s,%s,%s,%s"):format(nOp, nA, nB, nC2))
    -- v1.0 scrambled handler slots
    local slotOf = {}
    do
        local slots = {}
        for op in pairs(handlers) do slots[#slots+1] = op end
        table.sort(slots)
        local perm = {}
        for i = 1, #slots do perm[i] = i end
        for i = #perm, 2, -1 do
            local j = math.random(1, i)
            perm[i], perm[j] = perm[j], perm[i]
        end
        local slotBase = math.random(17, 90)
        for i, op in ipairs(slots) do
            slotOf[op] = slotBase + perm[i] * 3 + (op % 5)
        end
    end
    L(("local %s={}"):format(nH))

    -- v1.1 decoy handler tables (dead)
    do
        local nD1, nD2 = rn(2), rn(2)
        L(("local %s={} local %s={}"):format(nD1, nD2))
        for _ = 1, math.random(3, 8) do
            local s = math.random(100, 250)
            L(("%s[%d]=function() end"):format(nD1, s))
            L(("%s[%d]=function() end"):format(nD2, s + math.random(1, 5)))
        end
    end

    -- v2.0: polymorphic handlers + random registration order (breaks fixed dumper templates)
    local horder = {}
    for op in pairs(handlers) do horder[#horder+1] = op end
    for i = #horder, 2, -1 do
        local j = math.random(1, i)
        horder[i], horder[j] = horder[j], horder[i]
    end
    for _, op in ipairs(horder) do
        local body = handlers[op]
        local slot = slotOf[op] or op
        if body and #body > 0 then
            -- wrap with opaque noise unique per build
            local noise = ""
            if math.random() < 0.55 then
                local a, b = math.random(1, 99), math.random(1, 99)
                noise = string.format("local _=%d _=_+%d ", a, b)
            end
            if math.random() < 0.35 then
                body = string.format("do %s end", body)
            end
            L(("%s[%d]=function() %s%s end"):format(nH, slot, noise, body))
            -- alias decoy slots pointing at empty (confuse slot map recovery)
            if math.random() < 0.4 then
                local alias = slot + math.random(200, 500)
                L(("%s[%d]=function() end"):format(nH, alias))
            end
        else
            L(("%s[%d]=function() end"):format(nH, slot))
        end
    end
    -- extra dead handlers
    for _ = 1, math.random(8, 20) do
        L(("%s[%d]=function() local _=%d end"):format(nH, math.random(300, 900), math.random(0, 99999)))
    end
    -- slot remap table: logical -> slot (XOR masked)
    local slotMask = math.random(1, 255)
    local slotArr = {}
    for i = 1, 40 do slotArr[i] = 0 end
    for op, slot in pairs(slotOf) do
        slotArr[op] = Hardening.hostXor(slot % 256, Hardening.hostXor(slotMask, op % 256))
    end
    local nSlot = rn(2)
    L(("local %s={%s} local %s=%s"):format(nSlot, table.concat(slotArr, ","), nSlot.."m", tostring(slotMask)))

    -- Dispatcher CF: bounce states (shuffled IDs per build)
    do
        local ids = {11, 22, 33, 44}
        for i = #ids, 2, -1 do
            local j = math.random(1, i)
            ids[i], ids[j] = ids[j], ids[i]
        end
        local S1, S2, S3, S4 = ids[1], ids[2], ids[3], ids[4]
        L(("local %s=%d while %s do"):format(nSt, S1, nSt))
        L(("if %s==%d then local %s=(%s and %s[%s]) or %s %s=%s[%s] if not %s then break end %s=%d"):format(
            nSt, S1, nTmp.."ph", nTmp.."ord", nTmp.."ord", nPc, nPc, nOp, nCd, nTmp.."ph", nOp, nSt, S2))
        L(("elseif %s==%d then"):format(nSt, S2))
        L(("local %s=(%s and %s[%s]) or %s"):format(nTmp.."ph", nTmp.."ord", nTmp.."ord", nPc, nPc))
        L(("%s=%s(%s[%s] or 0,%s)"):format(nOp, nXor, nInv, nOp, nInv_m))
        L(("%s=%s[%s] or 0 %s=%s[%s] or 0 %s=%s[%s] or 0"):format(
            nA, nBase, nTmp.."ph", nB, nTmp.."bs", nTmp.."ph", nC2, nTmp.."cs", nTmp.."ph"))
        L(("%s=%s+1 %s=%d"):format(nPc, nPc, nSt, S3))
        L(("elseif %s==%d then local %s=0 if type(%s)=='number' and %s>0 and %s<=40 then %s=%s(%s[%s] or 0,%s(%s,%s%%256)) end local %s=%s[%s or 0] if %s then %s() end %s=%d"):format(
            nSt, S3, nTmp.."sl", nOp, nOp, nOp, nTmp.."sl", nXor, nSlot, nOp, nXor, nSlot.."m", nOp, nHfn, nH, nTmp.."sl", nHfn, nHfn, nSt, S4))
        -- always continue dispatcher (host AT handles env; in-VM tick poison caused nil/index errors)
        L(("elseif %s==%d then %s=%d"):format(nSt, S4, nSt, S1))
        L("else break end end")
    end
    L("end")  -- function nRun
    do
        local eidx = entryIdx or mainIdx
        local nEnt = rn(2)
        -- opaque entry: not protos[1] literal pattern
        L(("local %s=(%d*1)"):format(nEnt, eidx))
        L(("return %s(%s[%s],{},%s)"):format(nRun, nPr, nEnt, nE))
    end

    local inner = table.concat(lines, self.singleLine and " " or "\n")

    -- IB1-style range-tree fat VM (huge ID space, O(stages) nodes)
    if self.fatVM and intensity >= 1 then
        -- stages: intensity 1 ~ 60, 2 ~ 150, 3 ~ 280, 5 ~ 600 (capped in module)
        -- VERY FAT: intensity 4 ~ 900-1400 stages; intensity 5 ~ 1500+
        local stages = math.floor(80 + 90 * intensity * intensity + math.random(20, 80 * intensity))
        if stages > 8000 then stages = 8000 end
        inner = StateMachine.wrapBody(inner, {
            stages = stages,
            stateName = rn(2),
            rng = math.random,
        })
    end

    -- Do not start with `--` (some Roblox loaders: "got '-'").
    -- Marker must come BEFORE return (return must be last statement in chunk).
    -- Claudium v2.0: anti-dumper shell (no plaintext API names / no host AT literals)
    local usedKeys = {}
    local function uniqKey()
        local k
        repeat k = math.random(1, 400) until not usedKeys[k]
        usedKeys[k] = true
        return k
    end

    -- Only numeric noise + decoy fns. NO buffer.create / Vector3 / debug.info plaintext.
    local noise = {}
    for _ = 1, 28 do
        noise[#noise + 1] = string.format("[%d]=%d", uniqKey(), math.random(0, 2^30))
    end
    -- Split-string bait (looks like loader checks, not real APIs)
    local baitKey = uniqKey()
    local bait = string.format("[%d]=%q", baitKey, "PR$" .. string.char(math.random(65,90)) .. ":payload")

    -- String decoys without real metamethod use
    local Lch = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    local function rn2()
        local i = math.random(1, #Lch)
        return Lch:sub(i, i) .. tostring(math.random(0, 9))
    end
    local n1, n2 = rn2(), rn2()
    while n2 == n1 do n2 = rn2() end
    local strDecoys = {
        string.format("%s=%q", n1, "__index"),
        string.format("%s=%q", n2, "?"),
    }

    local letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local methodName
    do
        local i = math.random(1, #letters)
        methodName = letters:sub(i, i)
    end
    local usedLetters = { [methodName] = true }

    local decoyMethods = {}
    for _ = 1, 16 do
        local dn
        repeat
            local i = math.random(1, #letters)
            dn = letters:sub(i, i)
        until not usedLetters[dn]
        usedLetters[dn] = true
        local style = math.random(1, 4)
        if style == 1 then
            decoyMethods[#decoyMethods + 1] = string.format("%s=function()end", dn)
        elseif style == 2 then
            decoyMethods[#decoyMethods + 1] = string.format("%s=function()return end", dn)
        elseif style == 3 then
            decoyMethods[#decoyMethods + 1] = string.format("%s=function(s,...)return s end", dn)
        else
            decoyMethods[#decoyMethods + 1] = string.format("%s=function()local _=%d return _ end", dn, math.random(1,9999))
        end
    end

    local envExpr = "(type(getgenv)=='function' and getgenv())or(type(getrenv)=='function' and getrenv())or(type(getfenv)=='function' and getfenv())or _G or _ENV"

    -- Env gate: resolve names via byte tables so dumpers don't see 'game'/'Instance' as AT
    -- Built at emit time as char codes
    local function byteLit(s)
        local b = {}
        for i = 1, #s do b[i] = tostring(s:byte(i)) end
        return table.concat(b, ",")
    end
    local gameBytes = byteLit("game")
    local instBytes = byteLit("Instance")
    -- No standalone host anti-tamper prelude; IB_AT is dispatched from the VM bytecode.
    local gate = "do end "
    local invokeBody = string.format(
        "function(self,...) if type(_HP)=='function' then _HP('Claudium:boot') end %s local ok,err=pcall(function() local %s,%s,%s=string.char,table.concat,%s %s end) if not ok then if type(_HP)=='function' then _HP('Claudium:err '..tostring(err)) end if type(_HE)=='function' then _HE(tostring(err),0) else error(tostring(err),0) end end end",
        gate, nC, nJ, nE, envExpr, inner
    )

    local parts = {
        bait,
        table.concat(noise, ","),
        table.concat(strDecoys, ","),
        table.concat(decoyMethods, ","),
        string.format("%s=%s", methodName, invokeBody),
    }
    local tbl = "{" .. table.concat(parts, ",") .. "}"
    local body = string.format("local _HP,_HW,_HE=print,warn,error return setmetatable(%s,{}):%s()", tbl, methodName)

    if self.singleLine then
        body = body:gsub("\n", " "):gsub("%s+", " ")
        body = body:match("^%s*(.-)%s*$") or body
    end

    local marker = "-- Claudium v2.5.4 | claudium:tm:v2.5.4\n"
    return marker .. body




end

return Generator
