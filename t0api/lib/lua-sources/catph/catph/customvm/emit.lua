--
-- customvm/emit.lua
--


local Serializer = require("catph.customvm.serializer")
local ISA        = require("catph.customvm.isa")
local Flatten    = require("catph.customvm.flatten")

local Emit = {}
local floor = math.floor


-- IronBrew1-style confusing names: l/I/1/O/0
local _IB_START = {"l","I","O","Il","lI","Ol","lO","OI","III","lll","OOO","lIl","IlI","OlO","lOl","IOI"}
local _IB_BODY  = {"l","I","1","O","0","l","l","I","I","l","I","1","l","I","l","0","O","l","1","I"}

local function randomName(used)
    local name
    repeat
        local prefix = _IB_START[math.random(1, #_IB_START)]
        local len = math.random(7, 14)
        local t = {prefix}
        for i = 1, len do
            t[#t+1] = _IB_BODY[math.random(1, #_IB_BODY)]
        end
        name = table.concat(t)
    until not used[name]
    used[name] = true
    return name
end


local function randomSaltStr(len)
    local t = {}
    for i = 1, len do
        local c; repeat c = math.random(48, 122) until c~=92 and c~=34 and c~=39 and c~=37
        t[i] = string.char(c)
    end
    return table.concat(t)
end

local function shuffle(arr)
    for i = #arr, 2, -1 do
        local j = math.random(1, i)
        arr[i], arr[j] = arr[j], arr[i]
    end
    return arr
end

local B85_ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@[]^"


local function encodeB85(s)
    local len = #s
    local data = string.char(
        floor(len/16777216)%256, floor(len/65536)%256,
        floor(len/256)%256,     len%256
    ) .. s
    local pad = (4 - #data % 4) % 4
    if pad > 0 then data = data .. string.rep("\0", pad) end
    local out = {}
    for i = 1, #data, 4 do
        local b1,b2,b3,b4 = string.byte(data, i, i+3)
        b1=b1 or 0; b2=b2 or 0; b3=b3 or 0; b4=b4 or 0
        local v = ((b1*256+b2)*256+b3)*256+b4
        local c5=v%85; v=floor(v/85)
        local c4=v%85; v=floor(v/85)
        local c3=v%85; v=floor(v/85)
        local c2=v%85; v=floor(v/85); local c1=v
        out[#out+1] = B85_ALPHA:sub(c1+1,c1+1)..B85_ALPHA:sub(c2+1,c2+1)
                   .. B85_ALPHA:sub(c3+1,c3+1)..B85_ALPHA:sub(c4+1,c4+1)
                   .. B85_ALPHA:sub(c5+1,c5+1)
    end
    return table.concat(out)
end



local function lzCompress(data)
    local WINDOW  = 4096
    local MIN_LEN = 3
    local MAX_LEN = 18
    local n  = #data
    local sb = string.byte
    local fl = math.floor

    local bytes = {}
    for i = 1, n, 4096 do
        local chunk = {sb(data, i, math.min(i+4095, n))}
        for _, b in ipairs(chunk) do bytes[#bytes+1] = b end
    end

    local chains = {}
    for i = 1, n-2 do
        local k = bytes[i]*65536 + bytes[i+1]*256 + bytes[i+2]
        local c = chains[k]; if not c then c = {}; chains[k] = c end
        c[#c+1] = i
    end

    local items = {}
    local i = 1
    while i <= n do
        local bestLen, bestOff = 0, 0
        if i <= n-2 then
            local k = bytes[i]*65536 + bytes[i+1]*256 + bytes[i+2]
            local c = chains[k]
            if c then
                local wStart = i - WINDOW
                for ci = #c, math.max(1, #c-20), -1 do
                    local j = c[ci]
                    if j >= wStart and j < i then
                        local maxL = math.min(MAX_LEN, n-i+1)
                        local len = 0
                        while len < maxL and bytes[j+len] == bytes[i+len] do len=len+1 end
                        if len > bestLen then bestLen=len; bestOff=i-j end
                        if bestLen == MAX_LEN then break end
                    end
                end
            end
        end
        if bestLen >= MIN_LEN then
            items[#items+1] = {true, bestLen, bestOff}
            i = i + bestLen
        else
            items[#items+1] = {false, bytes[i]}
            i = i + 1
        end
    end

    local packed = {}
    local ii = 1
    while ii <= #items do
        local flagIdx = #packed+1
        packed[flagIdx] = 0
        local flag, bit = 0, 1
        for _ = 0, 7 do
            local item = items[ii]; if not item then break end; ii=ii+1
            if item[1] then
                flag = flag + bit
                local eLen = item[2] - MIN_LEN
                local eOff = item[3] - 1
                packed[#packed+1] = eLen*16 + fl(eOff/256)
                packed[#packed+1] = eOff%256
            else
                packed[#packed+1] = item[2]
            end
            bit = bit * 2
        end
        packed[flagIdx] = flag
    end

    local chunks = {}
    for j = 1, #packed, 4096 do
        local sub = {}
        for k = j, math.min(j+4095, #packed) do sub[#sub+1] = packed[k] end
        chunks[#chunks+1] = string.char((table.unpack or unpack)(sub))
    end
    return table.concat(chunks)
end


local function randomizeLayout()
    local pool = {1,2,3,4,5,6,7,8,9,10}
    shuffle(pool)
    local insSlots = {
        op = pool[1],
        a  = pool[2],
        b  = pool[3],
        c  = pool[4],
        k  = pool[5],
        -- slots 6-10 are decoys
    }
    -- type and idx
    local capPool = {1,2,3,4}
    shuffle(capPool)
    local capSlots = { type = capPool[1], idx = capPool[2] }

    -- numparams, isvararg, maxstack, k(constants), code, protos, captures_flag(19)
    local protoPool = {1,2,3,4,5,6,7,8,9}
    shuffle(protoPool)
    local protoSlots = {
        numparams = protoPool[1],
        isvararg  = protoPool[2],
        maxstack  = protoPool[3],
        k         = protoPool[4],
        code      = protoPool[5],
        protos    = protoPool[6],
    }

    return insSlots, capSlots, protoSlots
end



local function generateHardenedNonce(nonce, used)
    local M = 2147483647
    local code = {}

    local part1 = math.random(1, floor(M/3))
    local part2 = math.random(1, floor(M/3))
    local part3 = (nonce - part1 - part2) % M

    -- closure
    local p1Ret = randomName(used)
    local p1a = math.random(2, 9999)
    local p1b = math.random(2, 9999)
    local p1c = (part1 - p1a * p1b) % M
    local p1d = math.random(1, 999999)
    local n1=randomName(used); local n2=randomName(used); local n3=randomName(used); local n4=randomName(used)
    code[#code+1] = string.format(
        'local %s=(function() local %s=%d;local %s=%d;local %s=%d;local %s=%d;'..
        'if type("")=="string" then return (%s*%s+%s)%%2147483647 else return %s end end)()',
        p1Ret, n1,p1a, n2,p1b, n3,p1c, n4,p1d, n1,n2,n3, n4)

    -- string bytes
    local saltLen = math.random(8,16)
    local salt = randomSaltStr(saltLen)
    local saltName = randomName(used)
    code[#code+1] = string.format('local %s="%s"', saltName, salt)
    local nPos = math.random(3, math.min(4, saltLen))
    local byteSum = 0
    local bparts = {}
    for _ = 1, nPos do
        local pos = math.random(1, saltLen)
        byteSum = byteSum + string.byte(salt, pos)
        bparts[#bparts+1] = string.format("%s:byte(%d)", saltName, pos)
    end
    local p2mult = math.random(100, 99999)
    local p2off = (part2 - byteSum * p2mult) % M
    local mn = randomName(used); local on = randomName(used); local rn = randomName(used)
    code[#code+1] = string.format("local %s=%d;local %s=%d", mn, p2mult, on, p2off)
    code[#code+1] = string.format("local %s=((%s)*%s+%s)%%2147483647", rn, table.concat(bparts,"+"), mn, on)

    -- table
    local tName = randomName(used)
    local tSize = math.random(5,9)
    local rIdx = math.random(1, tSize)
    local entries = {}
    for i=1,tSize do entries[i] = i==rIdx and tostring(part3) or tostring(math.random(1,2147483646)) end
    code[#code+1] = string.format("local %s={%s}", tName, table.concat(entries,","))
    local iName = randomName(used)
    local ib = math.random(1,99)
    code[#code+1] = string.format('local %s=(type(nil)=="nil") and (%d+%d) or %d', iName, ib, rIdx-ib, math.random(1,tSize))

    -- Decoys
    for _=1, math.random(3,6) do
        local dn = randomName(used)
        local dt = math.random(1,3)
        if dt==1 then code[#code+1]=string.format("local %s=%d",dn,math.random(1,2147483646))
        elseif dt==2 then code[#code+1]=string.format("local %s=(function() return %d end)()",dn,math.random(1,999999))
        else code[#code+1]=string.format("local %s=%s[%d]",dn,tName,math.random(1,tSize)) end
    end

    local finalExpr = string.format("(%s+%s+%s[%s])%%2147483647", p1Ret, rn, tName, iName)
    return table.concat(code, "\n"), finalExpr
end



local function buildRuntime(nonce, usedOps, aliasesOf, junkLevel, opFreqs, integrityHash)
    usedOps = usedOps or {}
    -- fmtN: Luraph-style hex/binary formatter for numbers emitted into VM source
    local function fmtN(n)
        if type(n) ~= "number" then return tostring(n) end
        if n == 0 then
            local z = math.random(1,4)
            if z==1 then return "0x0" elseif z==2 then return "0X0"
            elseif z==3 then return "0b0" else return "0" end
        end
        if n < 0 then return "-"..fmtN(-n) end
        local fmt = math.random(1, 10)
        if fmt <= 5 then
            local hex = string.format(math.random()<0.5 and "%X" or "%x", n)
            if #hex>4 and math.random()<0.5 then
                local p=math.random(2,#hex-2); hex=hex:sub(1,p).."__"..hex:sub(p+1)
            elseif #hex>3 and math.random()<0.4 then
                local p=math.random(2,#hex-1); hex=hex:sub(1,p).."_"..hex:sub(p+1)
            elseif #hex>=2 and math.random()<0.2 then
                hex=hex:sub(1,1).."_"..hex:sub(2)
            end
            return (math.random()<0.5 and "0X" or "0x")..hex
        elseif fmt<=8 and n<131072 then
            local bits={}; local tmp=n
            while tmp>0 do table.insert(bits,1,tmp%2); tmp=math.floor(tmp/2) end
            local bin=table.concat(bits)
            if #bin>=5 and math.random()<0.45 then
                local p=math.random(2,#bin-1); bin=bin:sub(1,p)..(math.random()<0.55 and "_" or "__")..bin:sub(p+1)
            elseif #bin>=3 and math.random()<0.3 then bin=bin:sub(1,1).."_"..bin:sub(2) end
            return (math.random()<0.5 and "0b" or "0B")..bin
        else
            local str=tostring(n)
            if #str>4 and math.random()<0.3 then
                local p=math.random(2,#str-2); str=str:sub(1,p).."_"..str:sub(p+1)
            end
            return str
        end
    end
    local ncSet
    do
        local parts = {}
        if aliasesOf then
            for _, b in ipairs(aliasesOf[19] or {}) do parts[#parts+1] = "["..fmtN(b).."]=true" end
        else
            parts[1] = "["..fmtN(19).."]=true"
        end
        ncSet = "{" .. table.concat(parts, ",") .. "}"
    end
    local fieldOrderTable
    do
        local fo = Serializer.deriveFieldOrder(nonce)
        local parts = {}
        if aliasesOf then
            for op = 0, 88 do
                local perm = fo[op]
                local inv = {0,0,0,0}
                for i = 1, 4 do inv[perm[i]] = i end
                for _, b in ipairs(aliasesOf[op] or {}) do
                    parts[#parts+1] = "["..fmtN(b).."]={" .. fmtN(inv[1]) .. "," .. fmtN(inv[2]) .. "," .. fmtN(inv[3]) .. "," .. fmtN(inv[4]) .. "}"
                end
            end
        else
            for op = 0, 88 do
                local perm = fo[op]
                local inv = {0,0,0,0}
                for i = 1, 4 do inv[perm[i]] = i end
                parts[#parts+1] = "["..fmtN(op).."]={" .. fmtN(inv[1]) .. "," .. fmtN(inv[2]) .. "," .. fmtN(inv[3]) .. "," .. fmtN(inv[4]) .. "}"
            end
        end
        fieldOrderTable = "{" .. table.concat(parts, ",") .. "}"
    end
    local used = {}
    local nonceCode, nonceExpr = generateHardenedNonce(nonce, used)
    local blindKey = Serializer.deriveBlindKey(nonce)
    -- Indirect dispatch: scramble opcode→dispatch key mapping
    local dispMod = 1024  -- power of 2 for fast bitwise AND instead of expensive modulo division
    local dispMul = math.random(3, 499) * 2 + 1  -- odd multiplier ensures unique mapping
    local dispAdd = math.random(1, dispMod - 1)
    -- Dynamic opcode re-keying constants (same derivation as serializer)
    local rkSeed, rkStep = Serializer.deriveRekeyParams(nonce)
    -- Pre-computed stream cipher keys (embedded directly, not recomputed from nonce at runtime)
    local streamBase, streamStep = Serializer.deriveStreamKeys(nonce)
    local insSlots, capSlots, protoSlots = randomizeLayout()

    local function randomOpSlots()
        local pool = {11,12,13,14,15,16}
        shuffle(pool)
        return { b = pool[1], c = pool[2], k = pool[3] }
    end
    local opSlotMap = {}
    for op = 0, 88 do opSlotMap[op] = randomOpSlots() end

    local function deriveCK(n)
        -- Must match deriveStringKeys in serializer (uses KDF domain separation)
        local h = Serializer.kdf(n, "strings")
        local k1 = h % 256
        h = (h * 65521 + 1) % 2147483647
        local k2 = (h % 255) + 1
        return k1, k2
    end
    local ck1, ck2 = deriveCK(nonce)
    local maskA = math.random(0, 255)
    local maskB = math.random(0, 254)
    local wck1 = (ck1 + maskA) % 256
    local wck2 = ((ck2 - 1) + maskB) % 255
    local wrapRecovery = "    sk1=("..fmtN(wck1).."-"..fmtN(maskA)..")%256;sk2=(("..fmtN(wck2).."-"..fmtN(maskB)..")%255)+1"


    local vR = randomName(used)       -- register array
    local vPC = randomName(used)      -- program counter
    local vTop = randomName(used)     -- top
    local vOUV = randomName(used)     -- open upvalues
    local vCode = randomName(used)    -- code array ref
    local vK = randomName(used)       -- constants ref
    local vProtos = randomName(used)  -- protos ref
    local vIns = randomName(used)     -- current instruction
    local vOp = randomName(used)      -- current opcode
    local vA = randomName(used)       -- operand a
    local vRun = randomName(used)     -- run function
    local vMkCl = randomName(used)    -- makeClosure
    local vGetO = randomName(used)    -- getOpen
    local vClsF = randomName(used)    -- closeFrom
    local vPk = randomName(used)      -- pack
    local vUnpk = randomName(used)    -- unpack
    local vFl = randomName(used)      -- floor
    local vEnv = randomName(used)     -- env (passed to run)
    local vRawGet = randomName(used)  -- rawget capture (anti-hook)
    local vRawSet = randomName(used)  -- rawset capture (anti-hook)
    local vNextF  = randomName(used)  -- next capture (anti-hook)
    local vTypeF  = randomName(used)  -- type capture (anti-hook)


    local vHash = randomName(used)
    local vMask = randomName(used)    -- running opcode mask state
    local vDK = randomName(used)      -- dispatch key (scrambled opcode)
    local hashSeed = math.random(1, 999999)
    local hashMult = math.random(3, 97)


    local sOp = insSlots.op
    local sA = insSlots.a
    local sB = insSlots.b
    local sC = insSlots.c
    local sK = insSlots.k
    local sCT = capSlots.type
    local sCI = capSlots.idx
    local pNP = protoSlots.numparams
    local pVA = protoSlots.isvararg
    local pMS = protoSlots.maxstack
    local pK = protoSlots.k
    local pCD = protoSlots.code
    local pPR = protoSlots.protos

    local rProtoCode = (
"local FO="..fieldOrderTable.."\n"..
"local _rkx = bit32.bxor\n"..
"local function rProto()\n"..
"    local p = {}\n"..
"    p["..fmtN(pNP).."] = rVU()\n"..
"    p["..fmtN(pVA).."] = r8() == 1\n"..
"    p["..fmtN(pMS).."] = rVU()\n"..
"    local nk = rVU(); local K = {}\n"..
"    for i = 1, nk do K[i] = rConst() end\n"..
"    p["..fmtN(pK).."] = K\n"..
"    local nc = rVU(); local cd = {}\n"..
"    local _rkm = "..fmtN(rkSeed).."\n"..
"    for i = 1, nc do\n"..
"        local raw = _rkx(r8(), _rkm)\n"..
"        _rkm = _rkx(_rkm, "..fmtN(rkStep)..")\n"..
"        local v1,v2,v3,v4 = rVI(),rVI(),rVI(),rVI()\n"..
"        local fo = FO[raw]\n"..
"        local ins = {}\n"..
"        ins["..fmtN(sOp).."]=raw\n"..
"        if fo then ins["..fmtN(sA).."]=({v1,v2,v3,v4})[fo[1]];ins["..fmtN(sB).."]=({v1,v2,v3,v4})[fo[2]];ins["..fmtN(sC).."]=({v1,v2,v3,v4})[fo[3]];ins["..fmtN(sK).."]=({v1,v2,v3,v4})[fo[4]]\n"..
"        else ins["..fmtN(sA).."]=v1;ins["..fmtN(sB).."]=v2;ins["..fmtN(sC).."]=v3;ins["..fmtN(sK).."]=v4 end\n"..
"        if NC[raw] then\n"..
"            local ncap = rVU(); local caps = {}\n"..
"            for j = 1, ncap do local c={}; c["..fmtN(sCT).."]=r8(); c["..fmtN(sCI).."]=rVI(); caps[j]=c end\n"..
"            ins.cap = caps\n"..
"        end\n"..
"        cd[i] = ins\n"..
"    end\n"..
"    p["..fmtN(pCD).."] = cd\n"..
"    local np = rVU(); local pr = {}\n"..
"    for i = 1, np do pr[i] = rProto() end\n"..
"    p["..fmtN(pPR).."] = pr\n"..
"    return p\n"..
"end")


    local vmCode = (
"local "..vRun.."\n"..
"local function "..vMkCl.."(p, env, ups) return function(...) return "..vRun.."(p, env, ups, "..vPk.."(...)) end end\n"..
"\n"..
"function "..vRun.."(proto, "..vEnv..", upvals, args)\n"..
"    local "..vCode.." = proto["..fmtN(pCD).."]\n"..
"    local "..vK.." = proto["..fmtN(pK).."]\n"..
"    local "..vProtos.." = proto["..fmtN(pPR).."]\n"..
"    local "..vR..", "..vPC..", "..vTop..", "..vOUV.." = {}, 1, 0, {}\n"..
"    local np = proto["..fmtN(pNP).."] or 0\n"..
"    local n = args and (args.n or #args) or 0\n"..
"    for i = 1, np do "..vR.."[i-1] = args[i] end\n"..
"    local va, nva = nil, 0\n"..
"    if proto["..fmtN(pVA).."] and n > np then\n"..
"        va = {}; for i = np+1, n do nva = nva+1; va[nva] = args[i] end\n"..
"    end\n"..
"    local "..vHash.." = "..fmtN(hashSeed).."\n"..
"    local "..vRawGet..","..vRawSet..","..vNextF..","..vTypeF.." = rawget,rawset,next,type\n"..
"\n")

   
    local emitAll = (next(usedOps) == nil)
    local handlers = {}
    local function h(opNum, body, generator)
        if emitAll or usedOps[opNum] then
            handlers[#handlers+1] = {op=opNum, code=body, gen=generator}
        end
    end

   
    local vB = randomName(used)    -- pre-extracted B field
    local vC = randomName(used)    -- pre-extracted C field
    local vKI = randomName(used)   -- pre-extracted K field
    local B = vB
    local C = vC
    local K_IDX = vKI
    -- KC = decrypt-on-access call: kg(<constants>, <const index>)
    local KC = string.format("kg(%s,%s)", vK, K_IDX)

    local vT1 = randomName(used)   -- polymorphic temp locals
    local vT2m = randomName(used)
    local vT3 = randomName(used)

    -- LOADK (polymorphic with handler duplication)
    do
        local function gen()
            local lkv = math.random(1, 3)
            if lkv == 1 then return string.format("%s[%s]=%s", vR, vA, KC)
            elseif lkv == 2 then return string.format("local %s=%s;%s[%s]=%s", vT1, KC, vR, vA, vT1)
            else return string.format("do %s[%s]=%s end", vR, vA, KC) end
        end
        h(5, gen(), gen)
    end
    -- MOVE (polymorphic with handler duplication)
    do
        local function gen()
            local mv = math.random(1, 3)
            if mv == 1 then return string.format("%s[%s]=%s[%s]", vR, vA, vR, B)
            elseif mv == 2 then return string.format("local %s=%s[%s];%s[%s]=%s", vT1, vR, B, vR, vA, vT1)
            else return string.format("do %s[%s]=%s[%s] end", vR, vA, vR, B) end
        end
        h(6, gen(), gen)
    end
    -- LOADNIL
    h(2, string.format("%s[%s]=nil", vR, vA))
    -- LOADB
    h(3, string.format("%s[%s]=%s~=0", vR, vA, B))
    -- LOADN (constant-blinded: stored value = real + blindKey)
    h(4, string.format("%s[%s]=%s-%d", vR, vA, B, blindKey))
    -- GETGLOBAL
    h(7, string.format("do local _v=%s(%s,%s);if _v==nil then _v=%s[%s] end;%s[%s]=_v end",
        vRawGet, vEnv, KC, vEnv, KC, vR, vA))
    -- SETGLOBAL
    h(8, string.format("%s(%s,%s,%s[%s])", vRawSet, vEnv, KC, vR, vA))
    -- GETTABLE
    h(13, string.format("%s[%s]=%s[%s][%s[%s]]", vR, vA, vR, B, vR, C))
    -- SETTABLE
    h(14, string.format("%s[%s][%s[%s]]=%s[%s]", vR, B, vR, C, vR, vA))
    -- GETTABLEKS (polymorphic with handler duplication)
    do
        local function gen()
            local gv = math.random(1, 3)
            if gv == 1 then return string.format("%s[%s]=%s[%s][%s]", vR, vA, vR, B, KC)
            elseif gv == 2 then return string.format("local %s=%s[%s];%s[%s]=%s[%s]", vT1, vR, B, vR, vA, vT1, KC)
            else return string.format("local %s=%s[%s][%s];%s[%s]=%s", vT1, vR, B, KC, vR, vA, vT1) end
        end
        h(15, gen(), gen)
    end
    -- SETTABLEKS
    h(16, string.format("%s[%s][%s]=%s[%s]", vR, B, KC, vR, vA))
    -- GETTABLEN
    h(17, string.format("%s[%s]=%s[%s][%s]", vR, vA, vR, B, C))
    -- SETTABLEN
    h(18, string.format("%s[%s][%s]=%s[%s]", vR, B, C, vR, vA))
    -- Polymorphic handler generation: each opcode randomly picks from
    -- structurally different but semantically identical implementations.
    -- All variants compile to the same native instructions in Luau's JIT,
    -- so there's zero FPS cost — only the source text shape differs per build.

    -- Helper: generates a random binary-op handler from multiple templates
    local function polyBinOp(opNum, op)
        local function gen()
            local variant = math.random(1, 5)
            if variant == 1 then
                return string.format(
                    "local %s=%s[%s];local %s=%s[%s];%s[%s]=%s"..op.."%s",
                    vT1, vR, B, vT2m, vR, C, vR, vA, vT1, vT2m)
            elseif variant == 2 then
                return string.format(
                    "local %s=%s[%s];%s[%s]=%s"..op.."%s[%s]",
                    vT1, vR, B, vR, vA, vT1, vR, C)
            elseif variant == 3 then
                return string.format(
                    "local %s=%s[%s];%s[%s]=%s[%s]"..op.."%s",
                    vT2m, vR, C, vR, vA, vR, B, vT2m)
            elseif variant == 4 then
                return string.format(
                    "%s[%s]=%s[%s]"..op.."%s[%s]",
                    vR, vA, vR, B, vR, C)
            else
                return string.format(
                    "local %s=%s[%s];local %s=%s[%s];local %s=%s"..op.."%s;%s[%s]=%s",
                    vT1, vR, B, vT2m, vR, C, vT3, vT1, vT2m, vR, vA, vT3)
            end
        end
        h(opNum, gen(), gen)
    end

    -- Commutative ops can also swap operand order
    local function polyBinOpCommutative(opNum, op)
        local function gen()
            if math.random() < 0.3 then
                local variant = math.random(1, 3)
                if variant == 1 then
                    return string.format(
                        "local %s=%s[%s];local %s=%s[%s];%s[%s]=%s"..op.."%s",
                        vT1, vR, C, vT2m, vR, B, vR, vA, vT1, vT2m)
                elseif variant == 2 then
                    return string.format(
                        "%s[%s]=%s[%s]"..op.."%s[%s]",
                        vR, vA, vR, C, vR, B)
                else
                    return string.format(
                        "local %s=%s[%s];%s[%s]=%s[%s]"..op.."%s",
                        vT1, vR, C, vR, vA, vR, B, vT1)
                end
            else
                local variant = math.random(1, 5)
                if variant == 1 then
                    return string.format(
                        "local %s=%s[%s];local %s=%s[%s];%s[%s]=%s"..op.."%s",
                        vT1, vR, B, vT2m, vR, C, vR, vA, vT1, vT2m)
                elseif variant == 2 then
                    return string.format(
                        "local %s=%s[%s];%s[%s]=%s"..op.."%s[%s]",
                        vT1, vR, B, vR, vA, vT1, vR, C)
                elseif variant == 3 then
                    return string.format(
                        "local %s=%s[%s];%s[%s]=%s[%s]"..op.."%s",
                        vT2m, vR, C, vR, vA, vR, B, vT2m)
                elseif variant == 4 then
                    return string.format(
                        "%s[%s]=%s[%s]"..op.."%s[%s]",
                        vR, vA, vR, B, vR, C)
                else
                    return string.format(
                        "local %s=%s[%s];local %s=%s[%s];local %s=%s"..op.."%s;%s[%s]=%s",
                        vT1, vR, B, vT2m, vR, C, vT3, vT1, vT2m, vR, vA, vT3)
                end
            end
        end
        h(opNum, gen(), gen)
    end

    -- ADD (merged with SUB: if c < 0, subtract R[-(c+1)] instead of adding R[c])
    do
        local function gen()
            local variant = math.random(1, 3)
            if variant == 1 then
                return string.format(
                    "if %s<0 then %s[%s]=%s[%s]-%s[-%s-1] else %s[%s]=%s[%s]+%s[%s] end",
                    C, vR, vA, vR, B, vR, C, vR, vA, vR, B, vR, C)
            elseif variant == 2 then
                return string.format(
                    "local %s=%s;if %s<0 then %s[%s]=%s[%s]-%s[-%s-1] else %s[%s]=%s[%s]+%s[%s] end",
                    vT1, C, vT1, vR, vA, vR, B, vR, vT1, vR, vA, vR, B, vR, vT1)
            else
                return string.format(
                    "local %s=%s[%s];if %s<0 then %s[%s]=%s-%s[-%s-1] else %s[%s]=%s+%s[%s] end",
                    vT1, vR, B, C, vR, vA, vT1, vR, C, vR, vA, vT1, vR, C)
            end
        end
        h(33, gen(), gen)
    end
    -- SUB (non-commutative)
    polyBinOp(34, "-")
    -- MUL (commutative)
    polyBinOpCommutative(35, "*")
    -- DIV
    polyBinOp(36, "/")
    -- MOD
    polyBinOp(37, "%%")
    -- POW
    polyBinOp(38, "^")
    -- IDIV
    polyBinOp(81, "//")

    -- CONCAT (polymorphic)
    do
        local cv = math.random(1, 3)
        if cv == 1 then
            h(49, string.format("local s=%s[%s];for r=%s+1,%s do s=s..%s[r] end;%s[%s]=s", vR, B, B, C, vR, vR, vA))
        elseif cv == 2 then
            h(49, string.format("local %s=%s[%s];local r=%s+1;while r<=%s do %s=%s..%s[r];r=r+1 end;%s[%s]=%s", vT1, vR, B, B, C, vT1, vT1, vR, vR, vA, vT1))
        else
            h(49, string.format("local %s=%s;local %s=%s[%s];for i=%s+1,%s do %s=%s..%s[i] end;%s[%s]=%s", vT1, B, vT2m, vR, vT1, vT1, C, vT2m, vT2m, vR, vR, vA, vT2m))
        end
    end

    -- NOT (polymorphic with handler duplication)
    do
        local function gen()
            local nv = math.random(1, 3)
            if nv == 1 then return string.format("%s[%s]=not %s[%s]", vR, vA, vR, B)
            elseif nv == 2 then return string.format("local %s=%s[%s];%s[%s]=not %s", vT1, vR, B, vR, vA, vT1)
            else return string.format("if %s[%s] then %s[%s]=false else %s[%s]=true end", vR, B, vR, vA, vR, vA) end
        end
        h(50, gen(), gen)
    end
    -- MINUS (polymorphic with handler duplication)
    do
        local function gen()
            local mv = math.random(1, 3)
            if mv == 1 then return string.format("%s[%s]=-%s[%s]", vR, vA, vR, B)
            elseif mv == 2 then return string.format("local %s=%s[%s];%s[%s]=-%s", vT1, vR, B, vR, vA, vT1)
            else return string.format("%s[%s]=0-%s[%s]", vR, vA, vR, B) end
        end
        h(51, gen(), gen)
    end
    -- LENGTH (polymorphic with handler duplication)
    do
        local function gen()
            local lv = math.random(1, 2)
            if lv == 1 then return string.format("%s[%s]=#%s[%s]", vR, vA, vR, B)
            else return string.format("local %s=%s[%s];%s[%s]=#%s", vT1, vR, B, vR, vA, vT1) end
        end
        h(52, gen(), gen)
    end
    -- JUMP/JUMPBACK
    h(23, string.format("%s=%s+%s", vPC, vPC, B))
    h(24, string.format("%s=%s+%s", vPC, vPC, B))
    -- Conditional jumps
    h(25, string.format("if %s[%s] then %s=%s+%s end", vR, vA, vPC, vPC, B))
    h(26, string.format("if not %s[%s] then %s=%s+%s end", vR, vA, vPC, vPC, B))
    h(27, string.format("if %s[%s]==%s[%s] then %s=%s+%s end", vR, vA, vR, C, vPC, vPC, B))
    h(29, string.format("if %s[%s]<%s[%s] then %s=%s+%s end", vR, vA, vR, C, vPC, vPC, B))
    h(28, string.format("if %s[%s]<=%s[%s] then %s=%s+%s end", vR, vA, vR, C, vPC, vPC, B))
    h(30, string.format("if %s[%s]~=%s[%s] then %s=%s+%s end", vR, vA, vR, C, vPC, vPC, B))
    h(32, string.format("if not(%s[%s]<%s[%s]) then %s=%s+%s end", vR, vA, vR, C, vPC, vPC, B))
    h(31, string.format("if not(%s[%s]<=%s[%s]) then %s=%s+%s end", vR, vA, vR, C, vPC, vPC, B))
    -- NEWTABLE
    h(53, string.format("%s[%s]={}", vR, vA))
    -- FORNPREP
    h(56, string.format(
        "local lim,step,idx=%s[%s],%s[%s+1],%s[%s+2];"..
        "if (step>0 and idx<=lim) or (step<=0 and idx>=lim) then %s[%s+3]=idx else %s=%s+%s end",
        vR, vA, vR, vA, vR, vA, vR, vA, vPC, vPC, B))
    -- FORNLOOP
    h(57, string.format(
        "local lim,step=%s[%s],%s[%s+1];"..
        "local idx=%s[%s+2]+step;%s[%s+2]=idx;"..
        "if (step>0 and idx<=lim) or (step<=0 and idx>=lim) then %s[%s+3]=idx;%s=%s+%s end",
        vR, vA, vR, vA, vR, vA, vR, vA, vR, vA, vPC, vPC, B))
    -- FORGLOOP (optimized: tries function call first, table/next fallback)
    h(58, string.format(
        "local vc=%s;local gen=%s[%s];"..
        "if %s(gen)==\"function\" then "..
        "if vc<=2 then local v1,v2=gen(%s[%s+1],%s[%s+2]);"..
        "if v1~=nil then %s[%s+2]=v1;%s[%s+3]=v1;if vc==2 then %s[%s+4]=v2 end;%s=%s+%s end "..
        "else local res=%s(gen(%s[%s+1],%s[%s+2]));"..
        "if res[1]~=nil then %s[%s+2]=res[1];for j=1,vc do %s[%s+2+j]=res[j] end;%s=%s+%s end end "..
        "else "..
        "local key,val=%s(gen,%s[%s+2]);"..
        "if key~=nil then %s[%s+2]=key;%s[%s+3]=key;if vc>=2 then %s[%s+4]=val end;%s=%s+%s end "..
        "end",
        K_IDX, vR, vA,
        vTypeF,
        vR, vA, vR, vA,
        vR, vA, vR, vA, vR, vA, vPC, vPC, B,
        vPk, vR, vA, vR, vA,
        vR, vA, vR, vA, vPC, vPC, B,
        vNextF, vR, vA,
        vR, vA, vR, vA, vR, vA, vPC, vPC, B))
    -- SETLIST
    h(55, string.format(
        "local t=%s[%s];local base=%s;local start=%s;"..
        "local cnt=%s;if cnt==0 then cnt=%s-base end;"..
        "for i=0,cnt-1 do t[start+i]=%s[base+i] end",
        vR, vA, B, K_IDX, C, vTop, vR))
    -- NEWCLOSURE
    h(19, string.format(
        "local cp=%s[%s];local caps=%s.cap;local nc=#caps;local ups;"..
        "if nc==0 then ups={} "..
        "elseif nc==1 then local c=caps[1];if c[%d]==1 then ups={%s(%s,%s,c[%d])} else ups={upvals[c[%d]]} end "..
        "else ups={};for u=1,nc do local c=caps[u];"..
        "if c[%d]==1 then ups[u]=%s(%s,%s,c[%d]) else ups[u]=upvals[c[%d]] end end end;"..
        "%s[%s]=%s(cp,%s,ups);_WR[%s[%s]]={ups=ups,k=cp[%d],pr=cp[%d]}",
        vProtos, K_IDX, vIns,
        sCT, vGetO, vOUV, vR, sCI, sCI,
        sCT, vGetO, vOUV, vR, sCI, sCI,
        vR, vA, vMkCl, vEnv, vR, vA, pK, pPR))
    -- GETUPVAL
    h(9, string.format(
        "local uv=upvals[%s];if uv.open then %s[%s]=uv.stack[uv.idx] else %s[%s]=uv.val end",
        B, vR, vA, vR, vA))
    -- SETUPVAL
    h(10, string.format(
        "local uv=upvals[%s];if uv.open then uv.stack[uv.idx]=%s[%s] else uv.val=%s[%s] end",
        B, vR, vA, vR, vA))
    -- CLOSEUPVALS
    h(11, string.format("%s(%s,%s,%s)", vClsF, vOUV, vR, vA))
    -- GETVARARGS
    h(63, string.format(
        "if %s==0 then for i=1,nva do %s[%s+i-1]=va[i] end;%s=%s+nva "..
        "else for i=1,%s-1 do %s[%s+i-1]=va and va[i] or nil end end",
        B, vR, vA, vTop, vA, B, vR, vA))
    -- NAMECALL
    h(20, string.format(
        "local s=%s[%s];%s[%s+1]=s;%s[%s]=s[%s]",
        vR, B, vR, vA, vR, vA, KC))
    -- CALL
    h(21, string.format(
        "local f=%s[%s];"..
        "local na=%s==0 and (%s-%s-1) or (%s-1);"..
        "if %s==2 then "..
        "if na==0 then %s[%s]=f() "..
        "elseif na==1 then %s[%s]=f(%s[%s+1]) "..
        "elseif na==2 then %s[%s]=f(%s[%s+1],%s[%s+2]) "..
        "elseif na==3 then %s[%s]=f(%s[%s+1],%s[%s+2],%s[%s+3]) "..
        "elseif na==4 then %s[%s]=f(%s[%s+1],%s[%s+2],%s[%s+3],%s[%s+4]) "..
        "elseif na==5 then %s[%s]=f(%s[%s+1],%s[%s+2],%s[%s+3],%s[%s+4],%s[%s+5]) "..
        "elseif na==6 then %s[%s]=f(%s[%s+1],%s[%s+2],%s[%s+3],%s[%s+4],%s[%s+5],%s[%s+6]) "..
        "else local av={};for i=1,na do av[i]=%s[%s+i] end;%s[%s]=f(%s(av,1,na)) end "..
        "else "..
        "local res;"..
        "if na==0 then res=%s(f()) "..
        "elseif na==1 then res=%s(f(%s[%s+1])) "..
        "elseif na==2 then res=%s(f(%s[%s+1],%s[%s+2])) "..
        "elseif na==3 then res=%s(f(%s[%s+1],%s[%s+2],%s[%s+3])) "..
        "elseif na==4 then res=%s(f(%s[%s+1],%s[%s+2],%s[%s+3],%s[%s+4])) "..
        "elseif na==5 then res=%s(f(%s[%s+1],%s[%s+2],%s[%s+3],%s[%s+4],%s[%s+5])) "..
        "elseif na==6 then res=%s(f(%s[%s+1],%s[%s+2],%s[%s+3],%s[%s+4],%s[%s+5],%s[%s+6])) "..
        "else local av={};for i=1,na do av[i]=%s[%s+i] end;res=%s(f(%s(av,1,na))) end;"..
        "if %s==0 then for i=1,res.n do %s[%s+i-1]=res[i] end;%s=%s+res.n "..
        "else for i=1,%s-1 do %s[%s+i-1]=res[i] end end "..
        "end",
        vR, vA,
        B, vTop, vA, B,
        C,
        -- Single-return fast path (C==2): no pack, direct assignment
        vR, vA,
        vR, vA, vR, vA,
        vR, vA, vR, vA, vR, vA,
        vR, vA, vR, vA, vR, vA, vR, vA,
        vR, vA, vR, vA, vR, vA, vR, vA, vR, vA,
        vR, vA, vR, vA, vR, vA, vR, vA, vR, vA, vR, vA,
        vR, vA, vR, vA, vR, vA, vR, vA, vR, vA, vR, vA, vR, vA,
        vR, vA, vR, vA, vUnpk,
        -- Multi-return path (C==0 or C>2): uses pack
        vPk, vPk, vR, vA, vPk, vR, vA, vR, vA, vPk, vR, vA, vR, vA, vR, vA,
        vPk, vR, vA, vR, vA, vR, vA, vR, vA,
        vPk, vR, vA, vR, vA, vR, vA, vR, vA, vR, vA,
        vPk, vR, vA, vR, vA, vR, vA, vR, vA, vR, vA, vR, vA,
        vR, vA, vPk, vUnpk,
        C, vR, vA, vTop, vA,
        C, vR, vA))
    -- RETURN
    h(22, string.format(
        "local b=%s;"..
        "if b==1 then return "..
        "elseif b==2 then return %s[%s] "..
        "elseif b==0 then local out,m={},0;for r=%s,%s-1 do m=m+1;out[m]=%s[r] end;return %s(out,1,m) "..
        "else local out={};for i=1,b-1 do out[i]=%s[%s+i-1] end;return %s(out,1,b-1) end",
        B, vR, vA, vA, vTop, vR, vUnpk, vR, vA, vUnpk))

    -- Super ops (fused instructions — visible as multi-step inline Lua)
    -- ADDMOVE: R[a] = R[b] + R[c], then R[k_idx] = R[a]
    h(82, string.format(
        "local %s=%s[%s]+%s[%s];%s[%s]=%s;%s[%s]=%s",
        vT1, vR, B, vR, C,
        vR, vA, vT1,
        vR, K_IDX, vT1))
    -- MOVE_ADD: R[a] = R[b]; R[a] = R[a] + R[c]
    h(83, string.format(
        "local %s=%s[%s];%s[%s]=%s;%s[%s]=%s[%s]+%s[%s]",
        vT1, vR, B,
        vR, vA, vT1,
        vR, vA, vR, vA, vR, C))
    -- GETTKS_MOVE: R[a] = R[b][K[c]]; R[k_idx] = R[a]
    h(84, string.format(
        "local %s=%s[%s][kg(%s,%s)];%s[%s]=%s;%s[%s]=%s",
        vT1, vR, B, vK, C,
        vR, vA, vT1,
        vR, K_IDX, vT1))
    -- LOADK_MOVE: R[a] = K[c]; R[k_idx] = R[a]
    h(85, string.format(
        "local %s=kg(%s,%s);%s[%s]=%s;%s[%s]=%s",
        vT1, vK, C,
        vR, vA, vT1,
        vR, K_IDX, vT1))

    -- Shuffle handler order
    shuffle(handlers)

  
    local HelperVM = require("catph.customvm.helpervm")
    local catHandlers = HelperVM.splitHandlers(handlers)


    -- BST dispatch: nested if/else over opcode value — O(log n) like Luraph
    local function buildBSTDispatch(catHandlerList)
        if #catHandlerList == 0 then return "" end

        -- expand aliases → flat list of {val, code}
        local entries = {}
        local usedVals = {}
        for _, hd in ipairs(catHandlerList) do
            local freq = opFreqs and opFreqs[hd.op] or 1
            if aliasesOf then
                local aliases = aliasesOf[hd.op] or {}
                local perAlias = math.max(1, math.floor(freq / #aliases))
                for _, av in ipairs(aliases) do
                    if not usedVals[av] then
                        -- Handler duplication: if a generator exists, produce a
                        -- unique polymorphic variant for each alias byte.
                        local code = hd.gen and hd.gen() or hd.code
                        entries[#entries+1] = {val=av, code=code, weight=perAlias}
                        usedVals[av] = true
                    end
                end
            else
                if not usedVals[hd.op] then
                    entries[#entries+1] = {val=hd.op, code=hd.code, weight=freq}
                    usedVals[hd.op] = true
                end
            end
        end

        -- decoy leaves (never actually reached) — no == check, just junk inline
        local function decoyBody()
            local t = math.random(1,3)
            if t==1 then return string.format("%s[%s]=%s[%s]", vR, vA, vR, B)
            elseif t==2 then return string.format("local _z=%s*1", vHash)
            else return string.format("%s=%s", vTop, vTop) end
        end
        for _ = 1, math.random(2,4) do
            local v; local tr=0
            repeat v=math.random(0,255); tr=tr+1 until not usedVals[v] or tr>200
            if not usedVals[v] then
                usedVals[v]=true
                entries[#entries+1] = {val=v, code=decoyBody(), decoy=true, weight=0}
            end
        end

        table.sort(entries, function(a,b) return a.val < b.val end)

        -- Transform entry values through the dispatch indirection
        for _, e in ipairs(entries) do
            e.dval = e.val
        end
        table.sort(entries, function(a,b) return a.dval < b.dval end)

        local function bst(list, depth)
            local ind = string.rep("    ", (depth or 0) + 3)
            if #list == 0 then return "" end
            if #list == 1 then
                if list[1].decoy then
                    local dead = math.random(0, 253)
                    return ind.."if "..vOp.."<"..fmtN(dead).." then "..list[1].code.." end"
                else
                    return ind..list[1].code
                end
            end
            -- Weighted pivot selection
            local totalWeight = 0
            for _, e in ipairs(list) do totalWeight = totalWeight + (e.weight or 1) end
            local mid = math.floor(#list/2)+1
            local bestDiff = math.huge
            local cumWeight = 0
            for i = 1, #list - 1 do
                cumWeight = cumWeight + (list[i].weight or 1)
                local diff = math.abs(cumWeight - (totalWeight - cumWeight))
                if diff < bestDiff then
                    bestDiff = diff
                    mid = i + 1
                end
            end
            local pivot = list[mid].dval
            local left, right = {}, {}
            for i, e in ipairs(list) do
                if i < mid then left[#left+1]=e else right[#right+1]=e end
            end

            -- Opaque predicate injection: at ~35% of internal nodes (depth 1-4),
            -- wrap the real dispatch in a predicate that's always true but looks
            -- data-dependent to a static analyzer. The false branch contains a
            -- decoy handler that never executes.
            local useOpaque = (depth or 0) >= 1 and (depth or 0) <= 4 and math.random() < 0.35
            local opaquePrefix, opaqueSuffix = "", ""
            if useOpaque then
                -- Generate an always-true predicate referencing live VM state
                local predVariant = math.random(1, 10)
                local pred
                if predVariant == 1 then
                    -- x*x >= 0 is always true for any number
                    pred = string.format("%s*%s>=0", vPC, vPC)
                elseif predVariant == 2 then
                    -- bit32.band(x, 0) == 0 is always true
                    pred = string.format("bit32.band(%s,0)==0", vPC)
                elseif predVariant == 3 then
                    -- (x - x) == 0 is always true
                    pred = string.format("(%s-%s)==0", vHash, vHash)
                elseif predVariant == 4 then
                    -- type(R) == "table" is always true (R is always a table)
                    pred = string.format("type(%s)==\"table\"", vR)
                elseif predVariant == 5 then
                    -- x >= 0 or x < 0 is always true (tautology)
                    pred = string.format("%s>=0 or %s<0", vPC, vPC)
                elseif predVariant == 6 then
                    -- bit32.bor(x, 0) == x is always true
                    pred = string.format("bit32.bor(%s,0)==%s", vA, vA)
                elseif predVariant == 7 then
                    -- (x%2==0 or x%2==1) is always true for integers
                    pred = string.format("(%s%%2==0 or %s%%2==1)", vPC, vPC)
                elseif predVariant == 8 then
                    -- bit32.band(x,x)==x is always true
                    pred = string.format("bit32.band(%s,%s)==%s", vTop, vTop, vTop)
                elseif predVariant == 9 then
                    -- 1==1 wrapped in runtime condition to defeat static analysis
                    local k1 = math.random(2,99)
                    local k2 = k1 * k1
                    pred = string.format("(%s*%s)==%d", vA, "1", k1)
                    pred = string.format("%d*%d==%d", k1, k1, k2)  -- always true literal
                    pred = string.format("bit32.bxor(%s,%s)==0", vHash, vHash)
                else
                    -- (x-x)==0 masked with bxor for extra confusion
                    pred = string.format("bit32.bxor(%s,%s)==0", vPC, vPC)
                end
                -- Decoy body for the false branch (never reached)
                local decoy = decoyBody()
                opaquePrefix = ind.."if "..pred.." then\n"
                opaqueSuffix = "\n"..ind.."else\n"..ind.."    "..decoy.."\n"..ind.."end"
            end

            local out = {opaquePrefix..ind.."if "..vOp.."<"..fmtN(pivot).." then"}
            local lc = bst(left, (depth or 0)+1)
            if lc~="" then out[#out+1]=lc end
            if #right>0 then
                out[#out+1]=ind.."else"
                local rc = bst(right, (depth or 0)+1)
                if rc~="" then out[#out+1]=rc end
            end
            out[#out+1]=ind.."end"..opaqueSuffix
            return table.concat(out, "\n")
        end

        return bst(entries, 0)
    end

    local subDisp = {}
    for cat = 1, 4 do subDisp[cat] = buildBSTDispatch(catHandlers[cat]) end

    local vCatLUT = randomName(used)
    local catLutParts = {}
    local catLutUsed = {}
    for _, hd in ipairs(handlers) do
        local cat = HelperVM.categoryOf(hd.op)
        if aliasesOf then
            for _, b in ipairs(aliasesOf[hd.op] or {}) do
                if not catLutUsed[b] then
                    catLutParts[#catLutParts+1] = {fmtN(b), cat}  -- {formatted_key, raw_cat}
                    catLutUsed[b] = true
                end
            end
        else
            if not catLutUsed[hd.op] then
                catLutParts[#catLutParts+1] = {fmtN(hd.op), cat}  -- {formatted_key, raw_cat}
                catLutUsed[hd.op] = true
            end
        end
    end
    shuffle(catLutParts)

    local catIDs = {math.random(10,99), math.random(100,199), math.random(200,299), math.random(300,399)}
    shuffle(catIDs)
    local catIDMap = {}
    for i = 1, 4 do catIDMap[i] = catIDs[i] end
    local remappedCatLut = {}
    for _, entry in ipairs(catLutParts) do
        -- entry = {formatted_key_string, raw_category_int}
        remappedCatLut[#remappedCatLut+1] = "["..entry[1].."]="..fmtN(catIDMap[entry[2]])
    end

    vmCode = vmCode .. string.format("    local %s={%s}\n", vCatLUT, table.concat(remappedCatLut, ","))

    local vCat = randomName(used)      -- category variable
    local vST = randomName(used)       -- state variable
    local vST2 = randomName(used)      -- secondary state (opaque)

    local stFetch = math.random(1000, 9999)
    local stRoute = math.random(10000, 19999)
    local stCats = {}
    for i = 1, 4 do stCats[i] = math.random(20000, 59999) + i * 1000 end
    local stLoopBack = math.random(60000, 69999)

    local nBogus = math.random(4, 7)
    local bogusStates = {}
    local allUsed = {[stFetch]=true, [stLoopBack]=true}
    for i = 1, 4 do allUsed[stCats[i]] = true end
    for i = 1, nBogus do
        local bs; repeat bs = math.random(1000, 99999) until not allUsed[bs]
        allUsed[bs] = true
        bogusStates[i] = bs
    end

    local stMul = math.random(3, 97)
    local stMod = math.random(100000, 999999)

    local function stAssign(target)
        local a = math.random(1, 50000)
        local b = target - a
        return vST.."="..fmtN(a).."+"..fmtN(b)
    end

    local vCatSt = randomName(used)
    local catStLutParts = {}
    for i = 1, 4 do
        catStLutParts[#catStLutParts+1] = "["..fmtN(catIDs[i]).."]="..fmtN(stCats[i])
    end
    for i = 1, nBogus do
        catStLutParts[#catStLutParts+1] = "["..fmtN(math.random(400, 999)).."]="..fmtN(bogusStates[i])
    end
    shuffle(catStLutParts)

    local fetchBlock = (
        "        "..vIns.." = "..vCode.."["..vPC.."]; "..vPC.." = "..vPC.." + 1\n" ..
        "        "..vOp.." = "..vIns.."["..fmtN(sOp).."]\n" ..
        "        "..vA.." = "..vIns.."["..fmtN(sA).."]\n" ..
        "        "..vB.." = "..vIns.."["..fmtN(sB).."]\n" ..
        "        "..vC.." = "..vIns.."["..fmtN(sC).."]\n" ..
        "        "..vKI.." = "..vIns.."["..fmtN(sK).."]\n")

    -- Build a single unified BST that handles ALL opcodes
    local allHandlerList = {}
    for _, hd in ipairs(handlers) do
        allHandlerList[#allHandlerList+1] = hd
    end
    local fullDispatch = buildBSTDispatch(allHandlerList)

    vmCode = vmCode .. string.format("    local %s,%s,%s,%s,%s,%s,%s\n", vIns, vOp, vA, vCat, vB, vC, vKI)
    vmCode = vmCode .. "    while true do\n"
    -- Inline fetch + BST dispatch in one iteration
    vmCode = vmCode .. fetchBlock .. "\n"
    vmCode = vmCode .. fullDispatch .. "\n"
    vmCode = vmCode .. "    end\nend\n"

    local helpersCode = string.format([=[
local function %s(ouv, R, reg)
    for i=1,#ouv do local u=ouv[i];if u.open and u.idx==reg then return u end end
    local u={open=true,stack=R,idx=reg};ouv[#ouv+1]=u;return u
end
local function %s(ouv, R, a)
    for i=1,#ouv do local u=ouv[i]
        if u.open and u.idx>=a then u.val=R[u.idx];u.open=false;u.stack=nil end
    end
end
]=], vGetO, vClsF)


    local vAT = randomName(used)
    local antiTamperCode = string.format([=[
local function %s()
    local _e = getfenv and getfenv() or _G
    if getmetatable(_e) then return true end
    if rawget(_e, "____hook") or rawget(_e, "__log") then return true end
    local d = rawget(_e, "debug")
    if d and type(d) == "table" then
        if d.sethook and type(debug) == "table" and debug.sethook ~= d.sethook then return true end
        local ok, info = pcall(function() return debug.getinfo(1) end)
        if ok and info and info.what == "C" then
            if debug.getinfo(2) and debug.getinfo(2).func and
               type(tostring(debug.getinfo(2).func)) ~= "string" then return true end
        end
    end
    if type(rawget(_e, "print")) == "function" then
        local s = tostring(rawget(_e, "print"))
        if not s:find("builtin") and not s:find("function: 0x") and not s:find("function:") then
            return true
        end
    end
    return false
end
if %s() then while true do end end
]=], vAT, vAT)

   
    local vAT2 = randomName(used)
    local vAT2chk = randomName(used)
    local extAntiTamperCode = string.format([=[
local function %s(fn) local ok,src=pcall(debug.info,fn,"s") if not ok or src~="[C]" then return true end return false end
local function %s()
    if not pcall(debug.getregistry) then while true do end end
    local builtins={print,warn,require,getfenv,setfenv,pcall,debug.info,debug.getregistry,rawget,rawset,select,type,getmetatable,setmetatable}
    for i=1,#builtins do if %s(builtins[i]) then while true do end end end
    local env=getfenv(0)
    for _,v in next,env do if type(v)=="table" and getmetatable(v) then while true do end end end
    local ok2,bad=pcall(function() return ({debug.info(print,'a')})[1]~=0 or ({debug.info(tostring,'a')})[1]~=0 or ({debug.info(print,'a')})[2]~=true or select(1,pcall(getfenv,69))==true end)
    if not ok2 or bad then while true do end end
    local fps=game:GetService('Workspace'):GetRealPhysicsFPS()
    if type(fps)~="number" or fps<0.1 or fps>500 then while true do end end
end
%s()
]=], vAT2chk, vAT2, vAT2chk, vAT2)


    if not _G.__cvm_enable_at then
        antiTamperCode = ""
        extAntiTamperCode = ""
    end
    if _G.__cvm_test_noat then
        antiTamperCode = ""
        extAntiTamperCode = ""
    end

    -- Junk block generator: dead functions + dead locals, all numeric-safe.
    -- junkLevel: 0=none, 1=light, 2=normal, 3=heavy
    local junkRanges = {
        [0] = {funcs={0,0}, vars={0,0}, flocals={0,0}},
        [1] = {funcs={2,4}, vars={3,6},  flocals={3,6}},
        [2] = {funcs={4,10}, vars={6,14}, flocals={5,12}},
        [3] = {funcs={8,16}, vars={10,20}, flocals={8,16}},
    }
    local junkLevel_ = junkRanges[junkLevel] or junkRanges[2]
    local function junkBlock()
        if junkLevel == 0 then return "" end
        local parts = {}
        local numNames = {}  -- only numeric locals, safe for arithmetic reuse
        -- dead functions
        local nFuncs = math.random(junkLevel_.funcs[1], junkLevel_.funcs[2])
        for _ = 1, nFuncs do
            local fname = randomName(used)
            local np = math.random(1, 3)
            local pms = {}
            for _ = 1, np do pms[#pms+1] = randomName(used) end
            local fbody = {}
            local fnums = {}
            local nfl = math.random(junkLevel_.flocals[1], junkLevel_.flocals[2])
            for _ = 1, nfl do
                local ln = randomName(used)
                local t = math.random(1, 6)
                local ex
                if     t == 1 then ex = math.random(1,999999)
                elseif t == 2 then ex = math.random(1,99999).."+"..math.random(1,99999)
                elseif t == 3 then ex = "math.floor("..math.random(1,99999).."/"..math.random(1,99)..")"
                elseif t == 4 and #fnums>0 then ex = fnums[math.random(1,#fnums)].."*"..math.random(2,99)
                elseif t == 5 then ex = "(function() return "..math.random(1,999999).." end)()"
                else   ex = math.random(1,999999)
                end
                fbody[#fbody+1] = "local "..ln.."="..ex
                fnums[#fnums+1] = ln
            end
            if #fnums > 0 then fbody[#fbody+1] = "return "..fnums[math.random(1,#fnums)] end
            parts[#parts+1] = "local function "..fname.."("..table.concat(pms,",")..") "..table.concat(fbody," ").." end"
            numNames[#numNames+1] = fname  -- treat as callable dead ref
        end
    -- dead top-level locals (flow-dependent junk: updates vHash via ptrM,
    -- making static elimination impossible without tracing ptrM's value)
        local nVars = math.random(junkLevel_.vars[1], junkLevel_.vars[2])
        for _ = 1, nVars do
            local vn = randomName(used)
            local t = math.random(1, 8)
            if t == 6 then
                -- flow-dependent: calls math.random to keep alive
                local ex = string.format("math.max(%d,%d)", math.random(1,999999), math.random(1,999999))
                parts[#parts+1] = "local "..vn.."="..ex
                numNames[#numNames+1] = vn
            elseif t == 7 then
                local ex = string.format("(function() local _a=%d;local _b=%d;return _a*_b end)()", math.random(1,9999), math.random(1,99))
                parts[#parts+1] = "local "..vn.."="..ex
                numNames[#numNames+1] = vn
                numNames[#numNames+1] = vn
            else
                local ex
                if     t == 1 then ex = math.random(1,999999)
                elseif t == 2 then ex = "math.max("..math.random(1,99999)..","..math.random(1,99999)..")"
                elseif t == 3 and #numNames>0 then ex = "("..numNames[math.random(1,#numNames)].." and "..math.random(1,999999).." or "..math.random(1,999999)..")"
                elseif t == 4 then ex = math.random(1,9999).."*"..math.random(1,9999)
                elseif t == 5 then ex = "(function() local _a="..math.random(1,99999).." local _b="..math.random(1,99).." return _a*_b end)()"
                else   ex = math.random(1,999999)
                end
                parts[#parts+1] = "local "..vn.."="..ex
                numNames[#numNames+1] = vn
            end
        end
        return table.concat(parts, " ")
    end

    local junkA = junkBlock()
    local junkB = junkBlock()
    local junkC = junkBlock()

    local fmtIntHash = fmtN(integrityHash or 0)
    local fmtStreamBase = fmtN(streamBase)
    local fmtStreamStep = fmtN(streamStep)

    local runtime = string.format([=[
local function CVMRUN(D, ...)
local rawget,rawset,type,pcall,next,select,tostring,getmetatable,setmetatable,rawequal,rawlen=rawget,rawset,type,pcall,next,select,tostring,getmetatable,setmetatable,rawequal,rawlen
local _WR=setmetatable({},{__mode='k'})
local %s=(function()
local _renv=getfenv and getfenv() or _G
local _crtn,_strn,_matn,_tbln=coroutine,string,math,table
local _osln,_u8ln,_b32n,_tskn=os,utf8,bit32,task
local _bufn,_typn,_vern=buffer,typeof,_VERSION
local _DBGX do
local _nd=debug
_DBGX={}
if _nd then for _k,_v in next,_nd do _DBGX[_k]=_v end end
_DBGX.traceback=function(m,l) if _nd and _nd.traceback then return _nd.traceback(m,l) end return tostring(m) end
_DBGX.info=_nd and _nd.info or nil
_DBGX.getinfo=function(f,what) if not _nd then return nil end local ok,r=pcall(_nd.info,f,what or 'slnaf') return ok and r or nil end
_DBGX.getregistry=_nd and _nd.getregistry or nil
_DBGX.profilebegin=_nd and _nd.profilebegin or function() end
_DBGX.profileend=_nd and _nd.profileend or function() end
_DBGX.getmetatable=function(o) return rawget(getmetatable(o) or {},"__metatable") and _nd and _nd.getmetatable and _nd.getmetatable(o) or getmetatable(o) end
_DBGX.setmetatable=function(o,mt) if _nd and _nd.setmetatable then return _nd.setmetatable(o,mt) end return setmetatable(o,mt) end
_DBGX.getupvalues=function(f) local m=_WR[f] if m and m.ups then local t={} for i,u in next,m.ups do t[i]={u.open and u.stack and u.stack[u.idx] or u.val} end return t end if _nd and _nd.getupvalues then return _nd.getupvalues(f) end return {} end
_DBGX.getupvalue=function(f,i) local m=_WR[f] if m and m.ups then local u=m.ups[i] if u then return u.open and u.stack and u.stack[u.idx] or u.val end end if _nd and _nd.getupvalue then return _nd.getupvalue(f,i) end end
_DBGX.setupvalue=function(f,i,v) local m=_WR[f] if m and m.ups then local u=m.ups[i] if u then if u.open and u.stack then u.stack[u.idx]=v else u.val=v end return true end end if _nd and _nd.setupvalue then return _nd.setupvalue(f,i,v) end end
_DBGX.getconstants=function(f) local m=_WR[f] if m and m.k then local t={} for i,v in next,m.k do t[i]=v end return t end if _nd and _nd.getconstants then return _nd.getconstants(f) end return {} end
_DBGX.getconstant=function(f,i) local m=_WR[f] if m and m.k then return m.k[i] end if _nd and _nd.getconstant then return _nd.getconstant(f,i) end end
_DBGX.setconstant=function(f,i,v) local m=_WR[f] if m and m.k then m.k[i]=v return true end if _nd and _nd.setconstant then return _nd.setconstant(f,i,v) end end
_DBGX.getprotos=function(f) local m=_WR[f] if m and m.pr then local t={} for i,p in next,m.pr do t[i]=p end return t end if _nd and _nd.getprotos then return _nd.getprotos(f) end return {} end
_DBGX.getproto=function(f,i,act) local m=_WR[f] if m and m.pr then return m.pr[i] end if _nd and _nd.getproto then return _nd.getproto(f,i,act) end end
end
local _bltn={coroutine=_crtn,string=_strn,math=_matn,table=_tbln,os=_osln,utf8=_u8ln,bit32=_b32n,task=_tskn,buffer=_bufn,typeof=_typn,_VERSION=_vern,debug=_DBGX}
return setmetatable({},{__index=function(_,k) local v=rawget(_renv,k) if v~=nil then return v end v=_renv[k] if v~=nil then return v end return _bltn[k] end,__newindex=function(_,k,v) rawset(_renv,k,v) end})
end)()
%s
%s
%s
%s
local _BM={}
do
    local _bi=0
    local function _bm(a,b) for _i=a,b do _BM[_i]=_bi; _bi=_bi+1 end end
    _bm(48,57) _bm(65,90) _bm(97,122)
    for _,_v in ipairs({33,35,36,37,38,40,41,42,43,44,45,46,47,58,59,60,61,62,63,64,91,93,94}) do _BM[_v]=_bi; _bi=_bi+1 end
end
local %s = math.floor
local _SC, _SB, _UP = string.char, string.byte, table.unpack
local function _BTS(t, n) if n <= 7000 then return _SC(_UP(t, 1, n)) end local p = {} for i = 1, n, 7000 do p[#p+1] = _SC(_UP(t, i, i + 6999 < n and i + 6999 or n)) end return table.concat(p) end
local %s = table.pack
local %s = table.unpack

local _br, _bw, _bc = buffer.readu8, buffer.writeu8, buffer.create
local function _D85(s)
    local sz = (#s // 5) * 4
    local b = _bc(sz)
    local bi = 0
    for i = 1, #s, 5 do
        local v = (((_BM[_SB(s,i)]*85 + _BM[_SB(s,i+1)])*85 + _BM[_SB(s,i+2)])*85 + _BM[_SB(s,i+3)])*85 + _BM[_SB(s,i+4)]
        _bw(b,bi,v//16777216%%256); _bw(b,bi+1,v//65536%%256); _bw(b,bi+2,v//256%%256); _bw(b,bi+3,v%%256)
        bi = bi + 4
    end
    return b
end

local _BY = _D85(D)
local _LN = _br(_BY,0) + _br(_BY,1)*256 + _br(_BY,2)*65536 + _br(_BY,3)*16777216
local _PT = _bc(_LN)
for i = 0, _LN-1 do _bw(_PT, i, _br(_BY, 4+i)) end

local _FL = _br(_PT,3)
local _NN = %s
local _DR = _FL %% 2 >= 1
local _DS = _FL//2 %% 2 >= 1
local _DE = _FL//4 %% 2 >= 1

local NC = %s

do local _ih=0;for _i=8,_LN-1 do _ih=(_ih*31+_br(_PT,_i))%%2147483647 end;if _ih~=%s then while true do end end end

if _DS then
    local _bxor = bit32.bxor
    local base = %s
    local step = %s
    local key = base
    for i = 8, _LN-1 do
        _bw(_PT, i, _bxor(_br(_PT, i), key))
        key = (key + step) %% 256
    end
end

local sk1, sk2
if _DE then
%s
end

local _tn = tonumber
local _RI = 8
local function r8() local v = _br(_PT, _RI); _RI = _RI + 1; return v end
local function rVU()
    local x, sh = 0, 1
    while true do
        local b = _br(_PT, _RI); _RI = _RI + 1
        x = x + (b %% 128) * sh
        if b < 128 then break end
        sh = sh * 128
    end
    return x
end
local function rVI()
    local zz = rVU()
    if zz %% 2 == 0 then return zz / 2 else return -(zz + 1) / 2 end
end

local function rConst()
    local tag = _br(_PT, _RI); _RI = _RI + 1
    if tag == 0 then return nil
    elseif tag == 1 then return false
    elseif tag == 2 then return true
    elseif tag == 3 then
        if _DE then
            local salt = _br(_PT, _RI); _RI = _RI + 1
            local len = rVU(); local t = {}
            for j = 1, len do t[j] = _br(_PT, _RI); _RI = _RI + 1 end
            return {salt, _BTS(t, len), true}
        else
            local len = rVU(); local t = {}
            for i = 1, len do t[i] = _br(_PT, _RI); _RI = _RI + 1 end
            return _tn(_BTS(t, len))
        end
    elseif tag == 4 then
        if _DE then
            local salt = _br(_PT, _RI); _RI = _RI + 1
            local len = rVU(); local t = {}
            for j = 1, len do t[j] = _br(_PT, _RI); _RI = _RI + 1 end
            return {salt, _BTS(t, len)}
        else
            local len = rVU(); local t = {}
            for i = 1, len do t[i] = _br(_PT, _RI); _RI = _RI + 1 end
            return _BTS(t, len)
        end
    elseif tag == 5 then
        local s = _br(_PT, _RI); _RI = _RI + 1
        if s == 0 then return 1/0 elseif s == 1 then return -1/0 else return 0/0 end
    end
end

local function kg(KT, i)
    local e = KT[i]
    if type(e) ~= "table" then return e end
    local salt = e[1]; local s = e[2]
    local base = (sk1 + salt) %% 256
    local len = #s
    local t = {}
    for j = 1, len do t[j] = (_SB(s,j) - base - j * sk2) %% 256 end
    local o = _BTS(t, len)
    if e[3] then o = _tn(o) end
    KT[i] = o
    return o
end

%s
%s

local proto = rProto()
%s
%s
%s
%s
return %s(proto, %s, nil, %s(...))
end
return CVMRUN
]=], vEnv, nonceCode, antiTamperCode, junkA,
    -- Anti-simulation detection block (env-logger / Lune / spy detection).
    -- On by default (unchanged production behavior). Gated behind the same
    -- __cvm_test_noat test-only flag as antiTamperCode/extAntiTamperCode so
    -- local test runs can disable all embedded anti-tamper + anti-logger
    -- checks with one switch, without weakening the default/production output.
    (function()
        if _G.__cvm_test_noat then return "" end
        local lines = {}
        -- Block 1: detect Lune environment (used by env loggers like crzyinfo)
        -- rawget(env,"require") avoids __index spy, then pcall with Lune-only path
        lines[#lines+1] = string.format(
            "do local _rq=rawget(%s,\"require\");if type(_rq)==\"function\" then local _ok=pcall(_rq,\"@lune/task\");if _ok then repeat until false end end end",
            vEnv)
        -- Block 2: detect spy type() wrapper (real type is always a C closure)
        lines[#lines+1] = string.format(
            "do local _tp=rawget(%s,\"type\");if type(_tp)==\"function\" then local _db=rawget(%s,\"debug\");if _db and _db.info then local _s=_db.info(_tp,\"s\");if _s~=nil and _s~=\"[C]\" then repeat until false end end end end",
            vEnv, vEnv)
        -- Block 3: detect spy tostring() wrapper
        lines[#lines+1] = string.format(
            "do local _ts=rawget(%s,\"tostring\");if type(_ts)==\"function\" then local _db=rawget(%s,\"debug\");if _db and _db.info then local _s=_db.info(_ts,\"s\");if _s~=nil and _s~=\"[C]\" then repeat until false end end end end",
            vEnv, vEnv)
        return table.concat(lines, "\r\n")
    end)(),
    vFl, vPk, vUnpk,
    nonceExpr,
    ncSet,
    fmtIntHash,
    fmtStreamBase, fmtStreamStep,
    wrapRecovery,
    rProtoCode, junkB, helpersCode, junkC, vmCode, extAntiTamperCode,
    vRun, vEnv, vPk)

    -- Reserve names for the XOR block before the rename pass
    -- (XOR layer disabled — using stream cipher + string encryption only)

    -- Post-process: rename remaining hardcoded identifiers to random names
    local renames = {
        {"CVMRUN", randomName(used)},
        {"rProto", randomName(used)},
        {"rConst", randomName(used)},
        {"rVU",    randomName(used)},
        {"rVI",    randomName(used)},
        {"_BM",    randomName(used)},
        {"_D85",   randomName(used)},
        {"_BY",    randomName(used)},
        {"_LN",    randomName(used)},
        {"_PT",    randomName(used)},
        {"_FL",    randomName(used)},
        {"_NN",    randomName(used)},
        {"_DR",    randomName(used)},
        {"_DS",    randomName(used)},
        {"_DE",    randomName(used)},
        {"_RI",    randomName(used)},
        {"_SC",    randomName(used)},
        {"_SB",    randomName(used)},
        {"_UP",    randomName(used)},
        {"_BTS",   randomName(used)},
        {"_br",    randomName(used)},
        {"_bw",    randomName(used)},
        {"_bc",    randomName(used)},
        {"sk1",    randomName(used)},
        {"sk2",    randomName(used)},
        {"kg",     randomName(used)},
        {"NC",     randomName(used)},
        {"r8",     randomName(used)},
        {"FO",     randomName(used)},
        {"_rkx",   randomName(used)},
        {"_rkm",   randomName(used)},
        {"_renv",  randomName(used)},
        {"_bltn",  randomName(used)},
        {"_crtn",  randomName(used)},
        {"_strn",  randomName(used)},
        {"_matn",  randomName(used)},
        {"_tbln",  randomName(used)},
        {"_osln",  randomName(used)},
        {"_u8ln",  randomName(used)},
        {"_b32n",  randomName(used)},
        {"_tskn",  randomName(used)},
        {"_WR",    randomName(used)},
        {"_DBGX",  randomName(used)},
        {"_nd",    randomName(used)},
        {"_bufn",  randomName(used)},
        {"_typn",  randomName(used)},
        {"_vern",  randomName(used)},
    }
    for _, r in ipairs(renames) do
        runtime = runtime:gsub("%f[%w_]" .. r[1] .. "%f[^%w_]", r[2])
    end

    -- renames[1][2] is the randomized name for CVMRUN
    return runtime, renames[1][2]
end



local function serializeWithHiddenNonce(proto, opts)
    local nonce = opts.nonce or math.random(1, 2147483646)
    opts.nonce = nonce
    local data = Serializer.serialize(proto, opts)

    local B85 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@[]^"
    local b85map = {}
    for i = 1, #B85 do b85map[string.byte(B85, i)] = i - 1 end
    local bytes, bi = {}, 0
    for i = 1, #data, 5 do
        local v = (((b85map[data:byte(i)]*85+b85map[data:byte(i+1)])*85+b85map[data:byte(i+2)])*85+b85map[data:byte(i+3)])*85+b85map[data:byte(i+4)]
        bytes[bi+1]=floor(v/16777216)%256; bytes[bi+2]=floor(v/65536)%256; bytes[bi+3]=floor(v/256)%256; bytes[bi+4]=v%256
        bi = bi + 4
    end
    bytes[9]=0; bytes[10]=0; bytes[11]=0; bytes[12]=0
    local out = {}
    for i = 1, #bytes, 4 do
        local v = ((bytes[i]*256+bytes[i+1])*256+bytes[i+2])*256+bytes[i+3]
        local c5=v%85;v=(v-c5)/85; local c4=v%85;v=(v-c4)/85
        local c3=v%85;v=(v-c3)/85; local c2=v%85;v=(v-c2)/85; local c1=v%85
        out[#out+1]=B85:sub(c1+1,c1+1)..B85:sub(c2+1,c2+1)..B85:sub(c3+1,c3+1)..B85:sub(c4+1,c4+1)..B85:sub(c5+1,c5+1)
    end
    return table.concat(out), nonce, bytes, bi
end




local function buildBootstrapper(b85vmSrc, b85bc, useCompression)
    local used = {}

    -- Base-36 encoder: mirrors unparser.lua toBase36
    local _B36C = "0123456789abcdefghijklmnopqrstuvwxyz"
    local function _toB36(n)
        if n == 0 then return "0" end
        local d = {}
        while n > 0 do
            local r = n % 36
            table.insert(d, 1, _B36C:sub(r + 1, r + 1))
            n = math.floor(n / 36)
        end
        return table.concat(d)
    end

    -- Mixed radix formatter: hex / binary / decimal — Luraph IlII1lO0 style
    local function mn(num)
        if num == 0 then
            local z = math.random(1, 4)
            if z == 1 then return "0x0"
            elseif z == 2 then return "0X0"
            elseif z == 3 then return "0b0"
            else return "0" end
        end
        if num < 0 then return "-" .. mn(-num) end
        local fmt = math.random(1, 10)
        if fmt <= 5 then
            -- Hex with random underscores (50%)
            local hex = string.format(math.random() < 0.5 and "%X" or "%x", num)
            if #hex > 4 and math.random() < 0.5 then
                local pos = math.random(2, #hex - 2)
                hex = hex:sub(1, pos) .. "__" .. hex:sub(pos + 1)
            elseif #hex > 3 and math.random() < 0.4 then
                local pos = math.random(2, #hex - 1)
                hex = hex:sub(1, pos) .. "_" .. hex:sub(pos + 1)
            elseif #hex >= 2 and math.random() < 0.2 then
                hex = hex:sub(1, 1) .. "_" .. hex:sub(2)
            end
            return (math.random() < 0.5 and "0X" or "0x") .. hex
        elseif fmt <= 8 and num < 131072 then
            -- Binary with random underscores (30%)
            local bits = {}
            local tmp = num
            while tmp > 0 do table.insert(bits, 1, tmp % 2); tmp = math.floor(tmp / 2) end
            local bin = table.concat(bits)
            if #bin >= 5 and math.random() < 0.45 then
                local pos = math.random(2, #bin - 1)
                bin = bin:sub(1, pos) .. (math.random() < 0.55 and "_" or "__") .. bin:sub(pos + 1)
            elseif #bin >= 3 and math.random() < 0.3 then
                bin = bin:sub(1, 1) .. "_" .. bin:sub(2)
            end
            return (math.random() < 0.5 and "0b" or "0B") .. bin
        else
            -- Decimal with optional underscore (20%)
            local str = tostring(num)
            if #str > 4 and math.random() < 0.3 then
                local pos = math.random(2, #str - 2)
                str = str:sub(1, pos) .. "_" .. str:sub(pos + 1)
            end
            return str
        end
    end
    -- Table access: always plain tbl[key] — parser rejects (tbl)[key]=v on lhs
    local function ba(tbl, key)
        return tbl.."["..key.."]"
    end
    -- Table append: always tbl[#tbl+1]=v
    local function ap(tbl, val)
        return tbl.."[#"..tbl.."+"..mn(1).."]="..val
    end
    local vD85  = randomName(used)
    local vAlph = randomName(used)
    local vBmap = randomName(used)
    local vFl   = randomName(used)
    local vSb   = randomName(used)
    local vSc   = randomName(used)
    local vGs   = randomName(used)
    local vSp   = randomName(used)
    local vIp   = randomName(used)
    local vV0   = randomName(used)
    local vBL   = randomName(used)
    local vTb   = randomName(used)
    local vVv   = randomName(used)
    local vLzd  = randomName(used)
    local vSb2  = randomName(used)
    local vSc2  = randomName(used)
    local vFl2  = randomName(used)
    local vUup  = randomName(used)
    local vDp   = randomName(used)
    local vOt   = randomName(used)
    local vI2   = randomName(used)
    local vNn   = randomName(used)
    local vFf   = randomName(used)
    local vHh   = randomName(used)
    local vLl   = randomName(used)
    local vLn   = randomName(used)
    local vOf   = randomName(used)
    local vBa   = randomName(used)
    local vJj   = randomName(used)
    local vT2   = randomName(used)
    local vJj2  = randomName(used)
    local vBc   = randomName(used)
    local vVm   = randomName(used)
    local vLdEnv = randomName(used)
    local vLdFn  = randomName(used)
    local vLdCh  = randomName(used)
    local vLdI   = randomName(used)
    local vLdSrc = randomName(used)
    local vLdRet = randomName(used)

    -- Build a hidden "loader" that resolves loadstring/load at runtime by
    -- reconstructing the identifier from character codes, so the literal
    -- text "loadstring"/"load"/"assert" never appears in the emitted output.
    local function buildHiddenLoader()
        local function codesOf(str)
            local t = {}
            for i = 1, #str do t[#t+1] = mn(string.byte(str, i)) end
            return table.concat(t, ",")
        end
        local lsCodes = codesOf("loadstring")
        local ldCodes = codesOf("load")
        local parts = {
            "local function "..vLdFn.."("..vLdSrc..")",
            "local "..vLdEnv.."=(getfenv and getfenv())or _G",
            "local "..vLdCh.."=string.char",
            "local "..vLdRet.."="..vLdEnv.."["..vLdCh.."("..lsCodes..")]"
                .."or "..vLdEnv.."["..vLdCh.."("..ldCodes..")]",
            "local "..vLdI.."="..vLdRet.."("..vLdSrc..")",
            "if not "..vLdI.." then error('load failed',"..mn(0)..") end",
            "return "..vLdI,
            "end",
        }
        return table.concat(parts, " ")
    end

    local alpha_q = string.format("%q", B85_ALPHA)
    local vm_q    = string.format("%q", b85vmSrc)
    local bc_q    = string.format("%q", b85bc)

    local parts = {
        "local "..vD85.." do",
        "local "..vAlph.."="..alpha_q,
        "local "..vBmap.."={}",
        "for "..vIp.."="..mn(1)..",#"..vAlph.." do "..ba(vBmap,vAlph..":byte("..vIp..")").."="..vIp.."-"..mn(1).." end",
        "local "..vFl..","..vSb..","..vSc.."=math.floor,string.byte,string.char",
        vD85.."=function("..vSp..")",
        "local function "..vGs.."("..vIp..")",
        "return((("..vBmap.."["..vSb.."("..vSp..","..vIp..")]"
            .."*"..mn(85).."+"..vBmap.."["..vSb.."("..vSp..","..vIp.."+"..mn(1)..")])"
            .."*"..mn(85).."+"..vBmap.."["..vSb.."("..vSp..","..vIp.."+"..mn(2)..")])"
            .."*"..mn(85).."+"..vBmap.."["..vSb.."("..vSp..","..vIp.."+"..mn(3)..")])"
            .."*"..mn(85).."+"..vBmap.."["..vSb.."("..vSp..","..vIp.."+"..mn(4)..")]",
        "end",
        "local "..vV0.."="..vGs.."("..mn(1)..")",
        "local "..vBL.."="..vFl.."("..vV0.."/"..mn(16777216)..")*"..mn(16777216)
            .."+("..vFl.."("..vV0.."/"..mn(65536)..")%"..mn(256)..")*"..mn(65536)
            .."+("..vFl.."("..vV0.."/"..mn(256)..")%"..mn(256)..")*"..mn(256).."+"..vV0.."%"..mn(256),
        "local "..vTb.."={}",
        "for "..vIp.."="..mn(6)..",#"..vSp..","..mn(5).." do",
        "local "..vVv.."="..vGs.."("..vIp..")",
        ap(vTb, vSc.."("..vFl.."("..vVv.."/"..mn(16777216)..")%"..mn(256)..","
            ..vFl.."("..vVv.."/"..mn(65536)..")%"..mn(256)..","
            ..vFl.."("..vVv.."/"..mn(256)..")%"..mn(256)..","..vVv.."%"..mn(256)..")"),
        "end",
        "return(table.concat("..vTb.."):sub("..mn(1)..","..vBL.."))",
        "end end",
    }

    if useCompression then
        -- LZ decompressor block
        local lzdParts = {
            "local "..vLzd.." do",
            "local "..vSb2..","..vSc2..","..vFl2.."=string.byte,string.char,math.floor",
            "local "..vUup.."=table.unpack",
            vLzd.."=function("..vDp..")",
            "local "..vOt.."={} local "..vI2.."="..mn(1).." local "..vNn.."=#"..vDp,
            "while "..vI2.."<="..vNn.." do",
            "local "..vFf.."="..vSb2.."("..vDp..","..vI2..") "..vI2.."="..vI2.."+"..mn(1),
            "for _="..mn(0)..","..mn(7).." do",
            "if "..vI2..">"..vNn.." then break end",
            "if "..vFf.."%"..mn(2).."=="..mn(1).." then",
            "local "..vHh.."="..vSb2.."("..vDp..","..vI2..") local "..vLl.."="..vSb2.."("..vDp..","..vI2.."+"..mn(1)..") "..vI2.."="..vI2.."+"..mn(2),
            "local "..vLn.."="..vFl2.."("..vHh.."/"..mn(16)..")+"..mn(3).." local "..vOf.."=("..vHh.."%"..mn(16)..")*"..mn(256).."+"..vLl.."+"..mn(1),
            "local "..vBa.."=#"..vOt.."-"..vOf.."+"..mn(1),
            "for "..vJj.."="..mn(0)..","..vLn.."-"..mn(1).." do "..ap(vOt, ba(vOt,vBa.."+"..vJj)).." end",
            "else "..ap(vOt, vSb2.."("..vDp..","..vI2..")").." "..vI2.."="..vI2.."+"..mn(1).." end",
            vFf.."="..vFl2.."("..vFf.."/"..mn(2)..")",
            "end end",
            "local "..vT2.."={} for "..vJj2.."="..mn(1)..",#"..vOt..","..mn(4096).." do "
                ..ap(vT2, vSc2.."("..vUup.."("..vOt..","..vJj2..","
                ..vJj2.."+"..mn(4095).."<#"..vOt.." and "..vJj2.."+"..mn(4095).." or #"..vOt.."))").." end",
            "return(table.concat)("..vT2..")",
            "end end",
        }
        for _, l in ipairs(lzdParts) do parts[#parts+1] = l end
        parts[#parts+1] = buildHiddenLoader()
        parts[#parts+1] = "local "..vBc.."="..bc_q
        parts[#parts+1] = "local "..vVm.."="..vLdFn.."("..vLzd.."("..vD85.."("..vm_q..")))()"
    else
        -- No compression: just decode B85 directly
        parts[#parts+1] = buildHiddenLoader()
        parts[#parts+1] = "local "..vBc.."="..bc_q
        parts[#parts+1] = "local "..vVm.."="..vLdFn.."("..vD85.."("..vm_q.."))()"
    end

    parts[#parts+1] = "return "..vVm.."("..vBc..",...)"

    return table.concat(parts, " ")
end


local function collectUsedOps(proto, set)
    set = set or {}
    for _, ins in ipairs(proto.code or {}) do
        set[ins.op] = (set[ins.op] or 0) + 1
    end
    for _, child in ipairs(proto.protos or {}) do
        collectUsedOps(child, set)
    end
    return set
end


local MICRO_JUMPS = {
    [23]=true,[24]=true,[25]=true,[26]=true,[27]=true,[28]=true,
    [29]=true,[30]=true,[31]=true,[32]=true,[56]=true,[57]=true,[58]=true,
}
local MICRO_SPLIT = {
    [33]=true,[34]=true,[35]=true,[36]=true,[37]=true,[38]=true,[81]=true,
}
-- Opcode splitting: additional operations that get split into multi-instruction sequences
local MICRO_SPLIT_TABLE = {
    [15]=true,  -- GETTABLEKS
    [7]=true,   -- GETGLOBAL
}
local function microOpPass(proto)
    local code = proto.code or {}
    local scratch = proto.maxstack or 0
    local usedScratch = false
    local newCode = {}
    local oldToNew = {}
    for i = 1, #code do
        oldToNew[i] = #newCode + 1
        local ins = code[i]
        if MICRO_SPLIT[ins.op] and math.random() < 0.6 then
            -- Arithmetic split: MOVE+OP+MOVE
            usedScratch = true
            newCode[#newCode+1] = { op = 6,      a = scratch, b = ins.b,  c = 0,     k = 0 } -- MOVE scratch=R[b]
            newCode[#newCode+1] = { op = ins.op, a = scratch, b = scratch, c = ins.c, k = 0 } -- OP scratch op R[c]
            newCode[#newCode+1] = { op = 6,      a = ins.a,   b = scratch, c = 0,     k = 0 } -- MOVE R[a]=scratch
        elseif ins.op == 15 and math.random() < 0.4 then
            -- GETTABLEKS split: MOVE(tmp, base) + GETTABLEKS(dst, tmp, key)
            usedScratch = true
            newCode[#newCode+1] = { op = 6,  a = scratch, b = ins.b, c = 0, k = 0 }   -- MOVE scratch=R[base]
            newCode[#newCode+1] = { op = 15, a = ins.a, b = scratch, c = ins.c, k = ins.k } -- GETTABLEKS dst, scratch, key
        elseif ins.op == 7 and math.random() < 0.4 then
            -- GETGLOBAL split: GETGLOBAL(tmp, key) + MOVE(dst, tmp)
            usedScratch = true
            newCode[#newCode+1] = { op = 7, a = scratch, b = ins.b, c = ins.c, k = ins.k } -- GETGLOBAL scratch, key
            newCode[#newCode+1] = { op = 6, a = ins.a, b = scratch, c = 0, k = 0 }         -- MOVE dst=scratch
        else
            newCode[#newCode+1] = ins
        end
    end
    oldToNew[#code+1] = #newCode + 1

    for i = 1, #code do
        local ins = code[i]
        if MICRO_JUMPS[ins.op] then
            local ni = oldToNew[i]
            local oldTarget = i + 1 + ins.b
            local newTarget = oldToNew[oldTarget] or (#newCode + 1)
            ins.b = newTarget - ni - 1
        end
    end

    proto.code = newCode
    if usedScratch then proto.maxstack = scratch + 1 end
    for _, child in ipairs(proto.protos or {}) do microOpPass(child) end
end

function Emit.build(proto, opts)
    opts = opts or {}
    if opts.microOps ~= false then
        microOpPass(proto)
    end
    if opts.flatten ~= false then
        Flatten.flatten(proto, opts)
    end
    local usedOps = collectUsedOps(proto)
    local data, nonce, payloadBytes, payloadLen = serializeWithHiddenNonce(proto, opts)
    -- Integrity hash: compute over encrypted proto bytes.
    -- payloadBytes layout: [1-4]=length(L), [5..4+L]=inner payload
    -- Inner payload: [5-8]=header, [9-12]=nonce, [13..4+L]=encrypted proto
    -- Runtime _PT[0..L-1] = inner payload, so _PT[8..L-1] = encrypted proto = payloadBytes[13..4+L]
    local L = payloadBytes[1] + payloadBytes[2]*256 + payloadBytes[3]*65536 + payloadBytes[4]*16777216
    local integrityHash = 0
    for i = 13, 4 + L do
        integrityHash = (integrityHash * 31 + (payloadBytes[i] or 0)) % 2147483647
    end
    local aliasesOf
    if opts.renumber ~= false then
        aliasesOf = Serializer.deriveAliases(nonce)
    end
    local junkLevel = opts.junkLevel
    if junkLevel == nil then junkLevel = 2 end

    local vmSource, cvmName = buildRuntime(nonce, usedOps, aliasesOf, junkLevel, usedOps, integrityHash)
    local doCompress = opts.compress ~= false  -- default true

    if doCompress then
        -- VM source is lz-compressed + B85-encoded, decoded at runtime via loadstring
        vmSource = vmSource:gsub("\n", " ")
        local b85vm = encodeB85(lzCompress(vmSource))
        return buildBootstrapper(b85vm, data, true)
    else
        -- No compression: emit VM source directly as inline Lua.
        -- vmSource ends with `return <cvmName>` — replace that with a direct call.
        local bc_q = string.format("%q", data)
        -- Find the last `return <cvmName>` and replace it without gsub
        -- (bc_q can contain % sequences that break gsub replacements)
        local tail = "return " .. cvmName
        local pos = #vmSource - #tail
        -- scan backwards for the exact tail
        while pos >= 1 do
            if vmSource:sub(pos, pos + #tail - 1) == tail then
                -- make sure nothing follows except whitespace/newlines
                local after = vmSource:sub(pos + #tail)
                if after:match("^%s*$") then
                    vmSource = vmSource:sub(1, pos - 1)
                        .. "return " .. cvmName .. "(" .. bc_q .. ", ...)"
                    break
                end
            end
            pos = pos - 1
        end
        return vmSource
    end
end

return Emit
