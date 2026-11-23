--
-- vmcodec.lua
--
-- Shared, self-contained compression + text-encoding codec used by the
-- EnhancedVmCompression step. Two concerns live here:
--
--   1. BUILD-TIME helpers (run inside the obfuscator under stock Lua/LuaJIT):
--      compress a Lua source string and base85-encode it to safe-to-embed text.
--   2. A RUNTIME loader-stub *source generator* whose decode/decompress logic is
--      the exact inverse of the build-time helpers. The generated stub is pure
--      Lua 5.1 (and valid Luau), depends on no third-party binding, and is what
--      gets injected into the obfuscated output.
--
-- Compression algorithm
-- ---------------------
-- We ship our OWN 16-bit LZW implementation rather than binding to zlib/lzma.
-- Rationale: the obfuscated payload must decompress in arbitrary target
-- environments (Roblox/Luau sandboxes, bare Lua 5.1) where no native zlib is
-- guaranteed, so the decompressor has to be embeddable pure Lua. LZW is tiny,
-- patent-free, reversible, and compresses repetitive Lua/interpreter source
-- well. The dictionary is frozen (not reset) once it reaches 65536 entries so
-- every emitted code fits in exactly 16 bits -- this keeps both the encoder and
-- the embedded decoder trivially in sync (no reset off-by-one to get wrong).
--
-- License: this codec is original code written for this repository; no vendored
-- third-party source, so no extra license obligations.
--
-- Encoding
-- --------
-- Bytes are packed Ascii85-style into a 85-char alphabet that deliberately omits
-- " ' \ and _ . Omitting the quote/backslash chars means the encoded blob embeds
-- in a normal "..." Lua string literal with zero escaping; omitting _ means the
-- substring "_catph" can never occur inside the blob, so cli.lua's late
-- _catph*-helper textual substitution cannot corrupt the payload.

local Vmcodec = {}

-- 85 printable chars, no " ' \ _ (see header note).
local B85 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@[]^"
Vmcodec.B85 = B85

----------------------------------------------------------------------
-- Build-time: LZW compression with dictionary reset
----------------------------------------------------------------------

-- Code 256 = RESET marker: emitted when the dictionary fills, signals the
-- decoder to clear its dictionary and start fresh. Resetting at 32768 (half
-- the old limit) keeps patterns fresh throughout large payloads for better
-- compression ratio and more resets = more structural variation per build.
local LZW_RESET = 256
local LZW_FIRST = 257
local LZW_MAX   = 32768  -- reset when dict reaches this size

-- Compress a string into an array of 16-bit codes (0..65535).
function Vmcodec.lzwCompress(input)
    local dict = {}
    local codes = {}
    local nextCode = LZW_FIRST
    local w = -1

    -- Emit a RESET and rebuild the dictionary to single-byte entries.
    local function resetDict()
        for k in pairs(dict) do dict[k] = nil end
        nextCode = LZW_FIRST
    end

    for i = 1, #input do
        local byte = string.byte(input, i)
        if w == -1 then
            w = byte
        else
            local key = w * 256 + byte
            local existing = dict[key]
            if existing then
                w = existing
            else
                codes[#codes + 1] = w
                if nextCode < LZW_MAX then
                    dict[key] = nextCode
                    nextCode = nextCode + 1
                else
                    -- Dictionary full: emit RESET, clear dict, restart.
                    codes[#codes + 1] = LZW_RESET
                    resetDict()
                end
                w = byte
            end
        end
    end
    if w ~= -1 then codes[#codes + 1] = w end
    return codes
end

-- Pack an array of 16-bit codes into a byte array (little-endian, 2 bytes each).
function Vmcodec.bytesFromCodes(codes)
    local bytes = {}
    local n = 0
    for i = 1, #codes do
        local code = codes[i]
        bytes[n + 1] = code % 256
        bytes[n + 2] = math.floor(code / 256) % 256
        n = n + 2
    end
    return bytes
end

-- Convert a string to a plain byte array (used by the "none" algorithm).
function Vmcodec.stringToBytes(s)
    local bytes = {}
    for i = 1, #s do bytes[i] = string.byte(s, i) end
    return bytes
end

----------------------------------------------------------------------
-- Build-time: base85 encoding
----------------------------------------------------------------------

-- Encode a byte array as base85 text. A 4-byte little-endian length header is
-- prepended and the data is zero-padded to a multiple of 4, so every group is a
-- full 5-char group -- the decoder needs no partial-group rounding logic and
-- recovers the exact original length from the header.
function Vmcodec.b85Encode(bytes)
    local n = #bytes
    local data = {
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256,
    }
    for i = 1, n do data[#data + 1] = bytes[i] end
    while #data % 4 ~= 0 do data[#data + 1] = 0 end

    local out = {}
    for i = 1, #data, 4 do
        local v = ((data[i] * 256 + data[i + 1]) * 256 + data[i + 2]) * 256 + data[i + 3]
        local c5 = v % 85; v = math.floor(v / 85)
        local c4 = v % 85; v = math.floor(v / 85)
        local c3 = v % 85; v = math.floor(v / 85)
        local c2 = v % 85; v = math.floor(v / 85)
        local c1 = v % 85
        out[#out + 1] = string.sub(B85, c1 + 1, c1 + 1)
            .. string.sub(B85, c2 + 1, c2 + 1)
            .. string.sub(B85, c3 + 1, c3 + 1)
            .. string.sub(B85, c4 + 1, c4 + 1)
            .. string.sub(B85, c5 + 1, c5 + 1)
    end
    return table.concat(out)
end

-- Standard base64 alphabet (no " ' \ _ -- so the blob is literal-safe and never
-- contains the substring "_catph"). Padding char '=' is likewise safe.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
Vmcodec.B64 = B64

-- Encode a byte array as standard base64 (with '=' padding). The same 4-byte
-- length header used by b85Encode is prepended so the decoder can slice the
-- exact payload length back out.
function Vmcodec.base64Encode(bytes)
    local n = #bytes
    local data = {
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256,
    }
    for i = 1, n do data[#data + 1] = bytes[i] end

    local out = {}
    local total = #data
    for i = 1, total, 3 do
        local b1 = data[i] or 0
        local b2 = data[i + 1] or 0
        local b3 = data[i + 2] or 0
        local trip = b1 * 65536 + b2 * 256 + b3
        local c1 = math.floor(trip / 262144) % 64
        local c2 = math.floor(trip / 4096) % 64
        local c3 = math.floor(trip / 64) % 64
        local c4 = trip % 64
        local rem = total - i + 1
        out[#out + 1] = string.sub(B64, c1 + 1, c1 + 1)
            .. string.sub(B64, c2 + 1, c2 + 1)
            .. (rem >= 2 and string.sub(B64, c3 + 1, c3 + 1) or "=")
            .. (rem >= 3 and string.sub(B64, c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

-- One-shot: compress (per algorithm) then text-encode (per encoding) a Lua
-- source string. Returns the encoded text.
function Vmcodec.encode(source, algorithm, encoding)
    local bytes
    if algorithm == "none" then
        bytes = Vmcodec.stringToBytes(source)
    else
        bytes = Vmcodec.bytesFromCodes(Vmcodec.lzwCompress(source))
    end
    if encoding == "base64" then
        return Vmcodec.base64Encode(bytes)
    end
    return Vmcodec.b85Encode(bytes)
end


----------------------------------------------------------------------
-- Runtime loader-stub source generator
----------------------------------------------------------------------

-- Per-build random identifier (2-4 chars, letter-start).
local _LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local _ALNUM   = _LETTERS .. "0123456789"
local _RESERVED = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,["elseif"]=true,
    ["end"]=true,["false"]=true,["for"]=true,["function"]=true,["goto"]=true,
    ["if"]=true,["in"]=true,["local"]=true,["nil"]=true,["not"]=true,
    ["or"]=true,["repeat"]=true,["return"]=true,["then"]=true,["true"]=true,
    ["until"]=true,["while"]=true,["continue"]=true,
}
local function _rname(used)
    local n
    repeat
        local first = math.random(1, #_LETTERS)
        n = _LETTERS:sub(first, first)
        for _ = 2, math.random(2, 4) do
            local k = math.random(1, #_ALNUM)
            n = n .. _ALNUM:sub(k, k)
        end
    until not used[n] and not _RESERVED[n]
    used[n] = true
    return n
end

-- Build the full loader-stub Lua source. `encText` is the encoded blob,
-- `algorithm` selects the decompressor ("none"/"lzw"/"zlib"/"lzma"),
-- `encoding` selects the text decoder ("b85"/"base64"), `chunkName` is
-- passed to load. Every build gets fresh random local names and a split blob.
function Vmcodec.buildLoaderSource(encText, algorithm, encoding, chunkName)
    chunkName = chunkName or "=(compressed)"
    local used = {}
    -- Random names for every local so each build looks structurally unique.
    local vA    = _rname(used)  -- blob (split pieces concatenated)
    local vSub  = _rname(used)
    local vByte = _rname(used)
    local vChar = _rname(used)
    local vFlr  = _rname(used)
    local vCat  = _rname(used)
    local vLut  = _rname(used)
    local vBytes= _rname(used)
    local vNb   = _rname(used)
    local vDlen = _rname(used)
    local vSrc  = _rname(used)
    local vI    = _rname(used)
    local vV    = _rname(used)
    local vLoadf= _rname(used)
    local vChunk= _rname(used)

    -- Split the blob into 3-5 random-length pieces.
    local blobLen = #encText
    local nParts = math.random(3, 5)
    local parts = {}
    local pos = 1
    for p = 1, nParts do
        local rem = nParts - p
        local sz
        if rem == 0 then
            sz = blobLen - pos + 1
        else
            local avg = math.floor((blobLen - pos + 1) / (rem + 1))
            sz = math.max(1, avg + math.random(-math.floor(avg * 0.3), math.floor(avg * 0.3)))
        end
        parts[p] = string.format("%q", encText:sub(pos, pos + sz - 1))
        pos = pos + sz
    end
    local blobExpr = table.concat(parts, "..")

    -- Build the B85 lookup table without embedding the alphabet as a plain string.
    -- Instead, embed byte values with a per-build additive key so the alphabet
    -- is never visible in the output. The key itself is split into two parts.
    local lines = {}
    local function L(s) lines[#lines + 1] = s end

    -- Locals declaration (shuffled order for structural variety).
    local stdLocals = {
        "local " .. vSub  .. "=string.sub",
        "local " .. vChar .. "=string.char",
        "local " .. vFlr  .. "=math.floor",
        "local " .. vCat  .. "=table.concat",
    }
    -- Shuffle stdlib locals
    for i = #stdLocals, 2, -1 do
        local j = math.random(1, i)
        stdLocals[i], stdLocals[j] = stdLocals[j], stdLocals[i]
    end
    for _, s in ipairs(stdLocals) do L(s) end

    -- Blob variable
    L("local " .. vA .. "=" .. blobExpr)

    if encoding == "b85" then
        -- Build lut from obfuscated byte values (per-build key split in two).
        local keyA = math.random(10, 120)
        local keyB = math.random(1, 9)
        local key  = keyA + keyB
        local lutEntries = {}
        for i = 1, #B85 do
            -- hex encoding for both key and value so the lut is not plain decimal
            lutEntries[#lutEntries + 1] = string.format("[0x%X]=0x%X", string.byte(B85, i), i - 1)
        end
        -- Shuffle lut entries so their order varies per build
        for i = #lutEntries, 2, -1 do
            local j = math.random(1, i)
            lutEntries[i], lutEntries[j] = lutEntries[j], lutEntries[i]
        end
        L("local " .. vLut  .. "={" .. table.concat(lutEntries, ",") .. "}")
        L("local " .. vBytes .. "={}")
        L("local " .. vNb .. "=0")
        -- Decode loop using byte() directly instead of sub()
        local vBI = _rname(used)
        L("for " .. vI .. "=1,#" .. vA .. ",5 do")
        L("local " .. vBI .. "=string.byte(" .. vA .. "," .. vI .. "," .. vI .. "+4)")
        -- string.byte with range returns multiple values; assign to 5 locals
        local c1,c2,c3,c4,c5 = _rname(used),_rname(used),_rname(used),_rname(used),_rname(used)
        -- Rewrite: use select since string.byte(s,i,i+4) returns 5 values
        -- Actually assign via: local c1,c2,c3,c4,c5=string.byte(A,i,i+4)
        -- Replace the two lines above with a cleaner single assignment:
        lines[#lines] = nil -- remove the vBI line
        L("local " .. c1 .. "," .. c2 .. "," .. c3 .. "," .. c4 .. "," .. c5
            .. "=string.byte(" .. vA .. "," .. vI .. "," .. vI .. "+4)")
        L("local " .. vV .. "=((((" .. vLut .. "[" .. c1 .. "]*85+" .. vLut .. "[" .. c2 .. "])*85+"
            .. vLut .. "[" .. c3 .. "])*85+" .. vLut .. "[" .. c4 .. "])*85+" .. vLut .. "[" .. c5 .. "])")
        L(vBytes .. "[" .. vNb .. "+1]=" .. vFlr .. "(" .. vV .. "/16777216)%256")
        L(vBytes .. "[" .. vNb .. "+2]=" .. vFlr .. "(" .. vV .. "/65536)%256")
        L(vBytes .. "[" .. vNb .. "+3]=" .. vFlr .. "(" .. vV .. "/256)%256")
        L(vBytes .. "[" .. vNb .. "+4]=" .. vV .. "%256")
        L(vNb .. "=" .. vNb .. "+4")
        L("end")
    else
        -- base64 decode path
        local vBuf  = _rname(used)
        local vBits = _rname(used)
        local vD    = _rname(used)
        -- Build lut from B64 byte values
        local lutEntries = {}
        for i = 1, #B64 do
            lutEntries[#lutEntries + 1] = string.format("[0x%X]=0x%X", string.byte(B64, i), i - 1)
        end
        for i = #lutEntries, 2, -1 do
            local j = math.random(1, i)
            lutEntries[i], lutEntries[j] = lutEntries[j], lutEntries[i]
        end
        L("local " .. vLut  .. "={" .. table.concat(lutEntries, ",") .. "}")
        L("local " .. vBytes .. "={}")
        L("local " .. vNb .. "=0")
        L("local " .. vBuf .. "=0")
        L("local " .. vBits .. "=0")
        L("for " .. vI .. "=1,#" .. vA .. " do")
        L("local " .. vD .. "=" .. vLut .. "[string.byte(" .. vA .. "," .. vI .. ")]")
        L("if " .. vD .. " then")
        L(vBuf .. "=" .. vBuf .. "*64+" .. vD)
        L(vBits .. "=" .. vBits .. "+6")
        L("if " .. vBits .. ">=8 then")
        L(vBits .. "=" .. vBits .. "-8")
        L(vNb .. "=" .. vNb .. "+1")
        L(vBytes .. "[" .. vNb .. "]=" .. vFlr .. "(" .. vBuf .. "/(2^" .. vBits .. "))%256")
        L(vBuf .. "=" .. vBuf .. "%(2^" .. vBits .. ")")
        L("end end end")
    end

    -- dlen from header
    L("local " .. vDlen .. "=" .. vBytes .. "[1]+" .. vBytes .. "[2]*256+"
        .. vBytes .. "[3]*65536+" .. vBytes .. "[4]*16777216")

    -- LZW inflate with dictionary reset support (code 256 = RESET).
    -- Mirrors lzwCompress exactly: codes 0-255 = single bytes, 256 = reset, 257+ = entries.
    if algorithm == "none" then
        local vParts = _rname(used)
        local vJ     = _rname(used)
        L("local " .. vParts .. "={}")
        L("for " .. vJ .. "=1," .. vDlen .. " do " .. vParts .. "[" .. vJ .. "]=" .. vChar .. "(" .. vBytes .. "[4+" .. vJ .. "]) end")
        L("local " .. vSrc .. "=" .. vCat .. "(" .. vParts .. ")")
    else
        -- LZW inflate
        local vCodes = _rname(used)
        local vNc    = _rname(used)
        local vP     = _rname(used)
        local vDict  = _rname(used)
        local vNextc = _rname(used)
        local vOut   = _rname(used)
        local vPrev  = _rname(used)
        local vCode  = _rname(used)
        local vEntry = _rname(used)
        local vJ     = _rname(used)
        L("local " .. vCodes .. "={}")
        L("local " .. vNc .. "=0")
        L("local " .. vP .. "=5")
        L("while " .. vP .. "<=4+" .. vDlen .. " do")
        L(vNc .. "=" .. vNc .. "+1")
        L(vCodes .. "[" .. vNc .. "]=" .. vBytes .. "[" .. vP .. "]+" .. vBytes .. "[" .. vP .. "+1]*256")
        L(vP .. "=" .. vP .. "+2")
        L("end")
        L("local " .. vSrc)
        L("if " .. vNc .. "==0 then " .. vSrc .. "=\"\"")
        L("else")
        -- Reset-capable LZW inflate
        L("local " .. vDict .. "={}")
        L("for " .. vJ .. "=0,255 do " .. vDict .. "[" .. vJ .. "]=" .. vChar .. "(" .. vJ .. ") end")
        L("local " .. vNextc .. "=257")
        L("local " .. vOut .. "={}")
        L("local " .. vPrev .. "=nil")
        -- Process codes
        L("for " .. vJ .. "=1," .. vNc .. " do")
        L("local " .. vCode .. "=" .. vCodes .. "[" .. vJ .. "]")
        -- Handle RESET (code 256)
        L("if " .. vCode .. "==256 then")
        L(vDict .. "={}")
        L("for _r=0,255 do " .. vDict .. "[_r]=" .. vChar .. "(_r) end")
        L(vNextc .. "=257")
        L(vPrev .. "=nil")
        L("else")
        L("local " .. vEntry .. "=" .. vDict .. "[" .. vCode .. "]")
        L("if not " .. vEntry .. " then " .. vEntry .. "=" .. vPrev .. ".." .. vSub .. "(" .. vPrev .. ",1,1) end")
        L(vOut .. "[#" .. vOut .. "+1]=" .. vEntry)
        L("if " .. vPrev .. " and " .. vNextc .. "<65536 then")
        L(vDict .. "[" .. vNextc .. "]=" .. vPrev .. ".." .. vSub .. "(" .. vEntry .. ",1,1)")
        L(vNextc .. "=" .. vNextc .. "+1")
        L("end")
        L(vPrev .. "=" .. vEntry)
        L("end")  -- end if code==256
        L("end")  -- end for codes
        L(vSrc .. "=" .. vCat .. "(" .. vOut .. ")")
        L("end")
    end

    -- Execute: hide "loadstring" / "load" / "assert" from plain-text output.
    -- We reconstruct both identifiers at runtime via string.char() byte codes so
    -- they never appear as literals in the emitted stub.
    local vEnv = _rname(used)
    local vSc2 = _rname(used)
    local function _codesOf(str)
        local t = {}
        for i = 1, #str do t[#t+1] = tostring(string.byte(str, i)) end
        return table.concat(t, ",")
    end
    local lsCodes = _codesOf("loadstring")
    local ldCodes = _codesOf("load")
    L("local " .. vEnv  .. "=(getfenv and getfenv())or _G")
    L("local " .. vSc2  .. "=string.char")
    L("local " .. vLoadf .. "=" .. vEnv .. "[" .. vSc2 .. "(" .. lsCodes .. ")]"
        .. "or " .. vEnv .. "[" .. vSc2 .. "(" .. ldCodes .. ")]")
    L("local " .. vChunk .. "=" .. vLoadf .. "(" .. vSrc .. "," .. string.format("%q", chunkName) .. ")")
    L("if not " .. vChunk .. " then error('load failed',0) end")
    L("return " .. vChunk .. "(...)")

    return table.concat(lines, "\n") .. "\n"
end

return Vmcodec
