-- IronBrew0 v0.007c - Hardening utilities
-- Rolling XOR, Base85, opaque number expressions, junk proto factory

local Hardening = {}

local B85_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~"

function Hardening.hostXor(a, b)
    a, b = math.floor(a) % 256, math.floor(b) % 256
    local r, p = 0, 1
    for _ = 1, 8 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

-- Rolling XOR encrypt: key evolves with each byte
-- out[i] = in[i] XOR key; key = (key + in[i] + salt) % 256
function Hardening.rollingXorEncrypt(bytes, seed, salt)
    salt = salt or 1
    local key = seed % 256
    local out = {}
    for i = 1, #bytes do
        local b = bytes[i] % 256
        local x = Hardening.hostXor(b, key)
        out[i] = x
        key = (key * 3 + x + salt) % 256
    end
    return out
end

-- Decrypt mirrors encrypt (same recurrence using plaintext recovery)
function Hardening.rollingXorDecrypt(bytes, seed, salt)
    salt = salt or 1
    local key = seed % 256
    local out = {}
    for i = 1, #bytes do
        local b = bytes[i] % 256
        local x = Hardening.hostXor(b, key)
        out[i] = x
        key = (key * 3 + b + salt) % 256
    end
    return out
end

function Hardening.base85Encode(bytes)
    local alph = B85_ALPHABET
    local n = #bytes
    local out = {}
    local i = 1
    while i <= n do
        local b0 = bytes[i] or 0
        local b1 = bytes[i + 1] or 0
        local b2 = bytes[i + 2] or 0
        local b3 = bytes[i + 3] or 0
        -- pack 4 bytes -> 32-bit
        local v = b0 * 16777216 + b1 * 65536 + b2 * 256 + b3
        local c4 = v % 85; v = math.floor(v / 85)
        local c3 = v % 85; v = math.floor(v / 85)
        local c2 = v % 85; v = math.floor(v / 85)
        local c1 = v % 85; v = math.floor(v / 85)
        local c0 = v % 85
        out[#out + 1] = alph:sub(c0 + 1, c0 + 1)
        out[#out + 1] = alph:sub(c1 + 1, c1 + 1)
        out[#out + 1] = alph:sub(c2 + 1, c2 + 1)
        out[#out + 1] = alph:sub(c3 + 1, c3 + 1)
        out[#out + 1] = alph:sub(c4 + 1, c4 + 1)
        i = i + 4
    end
    return table.concat(out)
end

function Hardening.base85DecodeTable()
    -- returns a Lua snippet that builds decode map - used by generator
    return B85_ALPHABET
end

-- Opaque expression for a number 0-255 (simple MBA-ish)
function Hardening.opaqueByte(n, rng)
    n = math.floor(n) % 256
    rng = rng or math.random
    local style = rng(1, 4)
    if style == 1 then
        local x = rng(0, 255)
        local y = (n - x) % 256
        return string.format("(%d+%d)%%256", x, y)
    elseif style == 2 then
        local x = rng(1, 20)
        -- n = x*x - y  => y = x*x - n
        local y = (x * x - n) % 256
        return string.format("(%d*%d-%d)%%256", x, x, y)
    elseif style == 3 then
        local x = rng(0, 100)
        return string.format("((%d-%d)+256)%%256", n + x, x)
    else
        return string.format("(%d*1+0)%%256", n)
    end
end

-- v1.3 pack: interleaved quartets + PC perm + nonstandard const tags
function Hardening.packProtos(protos)
    local bytes = {}
    local function putU16(n)
        n = math.floor(n) % 65536
        bytes[#bytes + 1] = math.floor(n / 256)
        bytes[#bytes + 1] = n % 256
    end
    local function putI32(n)
        n = math.floor(n)
        if n < 0 then n = n + 4294967296 end
        n = n % 4294967296
        bytes[#bytes + 1] = math.floor(n / 16777216) % 256
        bytes[#bytes + 1] = math.floor(n / 65536) % 256
        bytes[#bytes + 1] = math.floor(n / 256) % 256
        bytes[#bytes + 1] = n % 256
    end
    putU16(#protos)
    for _, p in ipairs(protos) do
        local code = p.code or {}
        local nins = math.floor(#code / 4)
        putU16(nins)
        local perm = {}
        for i = 1, nins do perm[i] = i end
        for i = nins, 2, -1 do
            local j = math.random(1, i)
            perm[i], perm[j] = perm[j], perm[i]
        end
        local rk = math.random(1, 255)
        local rks = math.random(1, 40)
        bytes[#bytes + 1] = rk
        bytes[#bytes + 1] = rks
        for i = 1, nins do bytes[#bytes + 1] = perm[i] % 256 end
        local key = rk
        for phys = 1, nins do
            local log = 1
            for L = 1, nins do
                if perm[L] == phys then log = L break end
            end
            local s = (log - 1) * 4
            local op = math.floor(code[s + 1] or 0) % 256
            local a = math.floor(code[s + 2] or 0) % 256
            local b = math.floor(code[s + 3] or 0) % 256
            local c = math.floor(code[s + 4] or 0) % 256
            local eop = Hardening.hostXor(op, key)
            key = (key * 3 + eop + rks) % 256
            local ea = Hardening.hostXor(a, key)
            key = (key * 3 + ea + rks) % 256
            local eb = Hardening.hostXor(b, key)
            key = (key * 3 + eb + rks) % 256
            local ec = Hardening.hostXor(c, key)
            key = (key * 3 + ec + rks) % 256
            bytes[#bytes + 1] = eop
            bytes[#bytes + 1] = ea
            bytes[#bytes + 1] = eb
            bytes[#bytes + 1] = ec
        end
        local consts = p.consts or {}
        putU16(#consts)
        for i = 1, #consts do
            local c = consts[i]
            if type(c) == "number" then
                if c < 0 then
                    bytes[#bytes + 1] = 0xA7
                    putU16(-c)
                else
                    bytes[#bytes + 1] = 0x3C
                    putI32(c)
                end
            else
                bytes[#bytes + 1] = 0x00
                putI32(0)
            end
        end
        putU16(p.params or 0)
        bytes[#bytes + 1] = (p.isVararg or 0) % 256
        local nested = p.nested or {}
        putU16(#nested)
        for _, ni in ipairs(nested) do putU16(ni) end
    end
    return bytes
end

function Hardening.makeJunkProto(rng)
    rng = rng or math.random
    local code = {}
    local nops = rng(16, 48)
    for i = 1, nops do
        code[#code + 1] = rng(1, 29)
        code[#code + 1] = rng(0, 7)
        code[#code + 1] = rng(0, 7)
        code[#code + 1] = rng(0, 7)
    end
    code[#code + 1] = 23
    code[#code + 1] = 0
    code[#code + 1] = 1
    code[#code + 1] = 0
    local consts = {}
    for i = 1, rng(0, 3) do
        consts[i] = rng(0, 50)
    end
    return {
        code = code,
        consts = consts,
        params = 0,
        isVararg = 0,
        nested = {},
    }
end

function Hardening.emitBlobUnpack(encBytes, names)
    local nPr = names.protos
    local nXor = names.xor
    local nSeed = names.seed
    local nSalt = names.salt
    local L = names.L or {}
    local function N(k, fb) return L[k] or fb end
    local b, k, s, d, p = N("b", "_b"), N("k", "_k"), N("s", "_s"), N("d", "_d"), N("p", "_p")
    local rb, ru, ri = N("rb", "_rb"), N("ru", "_ru"), N("ri", "_ri")
    local t, np, pi, ni, ci = N("t", "_t"), N("np", "_np"), N("pi", "_pi"), N("ni", "_ni"), N("ci", "_ci")
    local ops, as_, bs, cs = N("ops", "_ops"), N("as", "_as"), N("bs", "_bs"), N("cs", "_cs")
    local consts, nk, tg = N("consts", "_c"), N("nk", "_nk"), N("tg", "_tg")
    local pm, va, nest, nj, ji = N("pm", "_pm"), N("va", "_va"), N("nest", "_n"), N("nj", "_nj"), N("ji", "_ji")
    local x, i, v = N("x", "_x"), N("i", "_i"), N("v", "_v")
    local ord = N("ord", "_ord")
    local rk, rks, rk2 = N("rk", "_rk"), N("rks", "_rks"), N("rk2", "_rk2")
    local eo, ea, eb, ec = N("eo", "_eo"), N("ea", "_ea"), N("eb", "_eb"), N("ec", "_ec")
    local o, aa, bb, cc = N("o", "_o"), N("aa", "_aa"), N("bb", "_bb"), N("cc", "_cc")

    local parts = {}
    local function A(s) parts[#parts + 1] = s end
    A(string.format("local %s; do", nPr))
    if names.b85 and #names.b85 > 0 then
        A(Hardening.emitBase85ToBytes(names.b85, b, N("bm", "_bm"), names.magic))
    else
        local encLit = "{" .. table.concat(encBytes, ",") .. "}"
        A(string.format("local %s=%s", b, encLit))
    end
    A(string.format("local %s=%s local %s=%s", k, nSeed, s, nSalt))
    A(string.format("local %s={}", d))
    A(string.format("local %s=1 while %s<=#%s do local %s=%s[%s] or 0 local %s=%s(%s,%s) %s[%s]=%s %s=(%s*3+%s+%s)%%256 %s=%s+1 end",
        i, i, b, v, b, i, x, nXor, v, k, d, i, x, k, k, v, s, i, i))
    if names.lz then
        local rawD = d
        local decD = N("lz", "_lz")
        A(Hardening.emitLzDecompress(rawD, decD, { i = N("lzi","_lzi"), n = N("lzn","_lzn"), tag = N("lzt","_lzt"), d = N("lzd","_lzd"), L = N("lzl","_lzl"), j = N("lzj","_lzj"), base = N("lzb","_lzb") }))
        A(string.format("%s=%s", d, decD))
    end
    A(string.format("local %s=1", p))
    A(string.format("local function %s() local %s=%s[%s] %s=%s+1 return %s or 0 end", rb, v, d, p, p, p, v))
    A(string.format("local function %s() return %s()*256+%s() end", ru, rb, rb))
    A(string.format("local function %s() local %s=((%s()*256+%s())*256+%s())*256+%s() if %s>=2147483648 then %s=%s-4294967296 end return %s end",
        ri, v, rb, rb, rb, rb, v, v, v, v))
    A(string.format("local %s={} local %s=%s()", t, np, ru))
    A(string.format("for %s=1,%s do", pi, np))
    A(string.format("local %s=%s()", ni, ru))
    A(string.format("local %s=%s() local %s=%s()", rk, rb, rks, rb))
    A(string.format("local %s={}", ord))
    A(string.format("for %s=1,%s do %s[%s]=%s() end", ci, ni, ord, ci, rb))
    A(string.format("local %s={} local %s={} local %s={} local %s={}", ops, as_, bs, cs))
    A(string.format("local %s=%s", rk2, rk))
    A(string.format("for %s=1,%s do", ci, ni))
    A(string.format("local %s=%s() local %s=%s() local %s=%s() local %s=%s()", eo, rb, ea, rb, eb, rb, ec, rb))
    A(string.format("local %s=%s(%s,%s) %s=(%s*3+%s+%s)%%256", o, nXor, eo, rk2, rk2, rk2, eo, rks))
    A(string.format("local %s=%s(%s,%s) %s=(%s*3+%s+%s)%%256", aa, nXor, ea, rk2, rk2, rk2, ea, rks))
    A(string.format("local %s=%s(%s,%s) %s=(%s*3+%s+%s)%%256", bb, nXor, eb, rk2, rk2, rk2, eb, rks))
    A(string.format("local %s=%s(%s,%s) %s=(%s*3+%s+%s)%%256", cc, nXor, ec, rk2, rk2, rk2, ec, rks))
    A(string.format("%s[%s]=%s %s[%s]=%s %s[%s]=%s %s[%s]=%s", ops, ci, o, as_, ci, aa, bs, ci, bb, cs, ci, cc))
    A("end")
    A(string.format("local %s={} local %s=%s()", consts, nk, ru))
    A(string.format("for %s=1,%s do local %s=%s() if %s==%d then %s[%s]=-%s() elseif %s==%d then %s[%s]=%s() else %s[%s]=0 end end",
        ci, nk, tg, rb, tg, 0xA7, consts, ci, ru, tg, 0x3C, consts, ci, ri, consts, ci))
    A(string.format("local %s=%s() local %s=%s()", pm, ru, va, rb))
    A(string.format("local %s={} local %s=%s()", nest, nj, ru))
    A(string.format("for %s=1,%s do %s[%s]=%s() end", ji, nj, nest, ji, ru))
    A(string.format("%s[%s]={%s,%s,%s,%s,%s,%s,%s,%s,%s}", t, pi, ops, as_, bs, cs, consts, pm, va, nest, ord))
    A("end")
    A(string.format("%s=%s", nPr, t))
    A("end")
    return table.concat(parts, "\n")
end


function Hardening.emitBase85ToBytes(b85str, dstName, mapName, magic)
    -- OxyEnv/Luau parser-safe Base85 transport. Never emit one giant quoted
    -- or long-bracket literal: split payload into small ordinary string tokens.
    local alph = B85_ALPHABET
    magic = magic or ("PR$" .. string.char(math.random(65, 90)))
    local payload = magic .. b85str
    local lines = {}
    local chunksName = (mapName or "_bm") .. "c"
    lines[#lines+1] = string.format("local %s; do", dstName)
    lines[#lines+1] = string.format("local %s={}", chunksName)
    local chunkSize = 144
    local ci = 0
    for pos = 1, #payload, chunkSize do
        ci = ci + 1
        lines[#lines+1] = string.format("%s[%d]=%q", chunksName, ci, payload:sub(pos, pos + chunkSize - 1))
    end
    lines[#lines+1] = string.format("local _s=table.concat(%s)", chunksName)
    lines[#lines+1] = string.format("if _s:sub(1,%d)==%q then _s=_s:sub(%d) end", #magic, magic, #magic + 1)
    lines[#lines+1] = string.format("local %s={}", mapName or "_bm")
    local mapBuild = {}
    for i = 1, #alph do
        mapBuild[#mapBuild+1] = string.format("[%q]=%d", alph:sub(i,i), i-1)
    end
    lines[#lines+1] = string.format("local %s={%s}", mapName or "_bm", table.concat(mapBuild, ","))
    lines[#lines+1] = string.format("%s={}", dstName)
    lines[#lines+1] = "local _i=1 local _n=#_s while _i<=_n do"
    lines[#lines+1] = string.format("local _v=0 for _j=0,4 do local _c=_s:sub(_i+_j,_i+_j) local _d=%s[_c] or 0 _v=_v*85+_d end", mapName or "_bm")
    lines[#lines+1] = "local _b0=math.floor(_v/16777216)%256 local _b1=math.floor(_v/65536)%256 local _b2=math.floor(_v/256)%256 local _b3=_v%256"
    lines[#lines+1] = string.format("local _o=#%s %s[_o+1]=_b0 %s[_o+2]=_b1 %s[_o+3]=_b2 %s[_o+4]=_b3", dstName, dstName, dstName, dstName, dstName)
    lines[#lines+1] = "_i=_i+5 end end"
    return table.concat(lines, "\n")
end


-- Lightweight LZ77-ish compressor (Luraph-style density without full zstd)
-- Format: [lit_len u8][lits...] | [0xFF][dist u8][len u8]  (match, dist 1..255, len 3..258)
function Hardening.lzCompress(bytes)
    local out = {}
    local n = #bytes
    local i = 1
    while i <= n do
        local bestLen, bestDist = 0, 0
        local maxDist = math.min(255, i - 1)
        local maxLen = math.min(258, n - i + 1)
        if maxDist >= 1 and maxLen >= 3 then
            for d = 1, maxDist do
                local L = 0
                while L < maxLen and bytes[i + L] == bytes[i - d + L] do
                    L = L + 1
                end
                if L >= 3 and L > bestLen then
                    bestLen, bestDist = L, d
                    if bestLen >= 32 then break end
                end
            end
        end
        if bestLen >= 3 then
            out[#out + 1] = 0xFF
            out[#out + 1] = bestDist
            out[#out + 1] = math.min(bestLen, 255)
            i = i + bestLen
        else
            -- gather literals until match or 254
            local start = i
            local lim = math.min(n, i + 253)
            while i <= lim do
                local bl, bd = 0, 0
                local md = math.min(255, i - 1)
                local ml = math.min(258, n - i + 1)
                if md >= 1 and ml >= 3 then
                    for d = 1, md do
                        local L = 0
                        while L < ml and bytes[i + L] == bytes[i - d + L] do L = L + 1 end
                        if L >= 3 and L > bl then bl, bd = L, d end
                    end
                end
                if bl >= 3 then break end
                i = i + 1
            end
            local litLen = i - start
            out[#out + 1] = litLen
            for j = start, i - 1 do out[#out + 1] = bytes[j] % 256 end
        end
    end
    return out
end

function Hardening.lzDecompress(bytes)
    local out = {}
    local i, n = 1, #bytes
    while i <= n do
        local tag = bytes[i] or 0
        i = i + 1
        if tag == 0xFF then
            local dist = bytes[i] or 1
            local len = bytes[i + 1] or 3
            i = i + 2
            local base = #out
            for j = 1, len do
                out[#out + 1] = out[base - dist + j] or 0
            end
        else
            for j = 1, tag do
                out[#out + 1] = bytes[i] or 0
                i = i + 1
            end
        end
    end
    return out
end

-- Emit runtime LZ decompress: input byte array `src` -> output array `dst`
function Hardening.emitLzDecompress(srcName, dstName, names)
    names = names or {}
    local i = names.i or "_i"
    local n = names.n or "_n"
    local tag = names.tag or "_tg"
    local d = names.d or "_d"
    local L = names.L or "_L"
    local j = names.j or "_j"
    local base = names.base or "_b"
    local parts = {}
    parts[#parts+1] = string.format("local %s={} do local %s=1 local %s=#%s while %s<=%s do local %s=%s[%s] or 0 %s=%s+1 if %s==255 then local %s=%s[%s] or 1 local %s=%s[%s+1] or 3 %s=%s+2 local %s=#%s for %s=1,%s do %s[#%s+1]=%s[%s-%s+%s] or 0 end else for %s=1,%s do %s[#%s+1]=%s[%s] or 0 %s=%s+1 end end end end",
        dstName, i, n, srcName, i, n, tag, srcName, i, i, i, tag, d, srcName, i, L, srcName, i, i, i, base, dstName, j, L, dstName, dstName, dstName, base, d, j, j, tag, dstName, dstName, srcName, i, i, i)
    return table.concat(parts, " ")
end


return Hardening
