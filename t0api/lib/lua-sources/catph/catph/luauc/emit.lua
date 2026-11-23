--
-- luauc/emit.lua
--
-- Serializes a parsed+remapped+encrypted bytecode structure into a runnable
-- Luau program. To avoid fingerprintable field names (mainid, code, tag, ...),
-- everything is emitted as POSITIONAL arrays -- there are no named keys to
-- recognize. Layout (kept in sync with interp.lua):
--
--   bc    = { [1]=mainid, [2]=protos, [3]=opmap|nil, [4]=bkey|nil, [5]=bstep|nil }
--   proto = { [1]=maxstacksize, [2]=numparams, [3]=nups, [4]=is_vararg,
--             [5]=code, [6]=kv, [7]=childprotos, [8]=kt }
--   kv    = flat value array: kv[ci+1] = value of constant ci (nil/bool/number/string/
--             import-packed-int/protoidx). Hot paths use only kv.
--   kt    = flat tag array: kt[ci+1] = tagnum (0=nil,1=bool,2=number,3=string,
--             4=import,5=table,6=closure,7=vector,8=table_wc). Cold paths (DUPTABLE,
--             GETIMPORT) that need the tag or extra fields use the raw `kraw` array
--             which preserves the original {tag,...} sub-tables only for those tags.
--   kraw  = sparse array: kraw[ci+1] present only for table/table_wc/vector consts.
--   The code array is a base85 string (see encodeCode) when bc.b85 is set.

local Emit = {}

local function serString(s) return string.format("%q", s) end

-- Serialize an arbitrary byte string as a Lua literal using 3-digit decimal
-- escapes (\DDD). Unlike string.format("%q", ...) this is safe for binary data:
-- Lua 5.1's %q emits "\0" (and "\n") forms that misparse when followed by a
-- digit, and encrypted constants contain every byte value 0..255. Zero-padded
-- 3-digit escapes are always unambiguous regardless of the following character.
local function serBytes(s)
    local out = {}
    for i = 1, #s do out[i] = string.format("\\%03d", string.byte(s, i)) end
    return '"' .. table.concat(out) .. '"'
end

local function serNumber(n)
    if n ~= n then return "(0/0)" end
    if n == math.huge then return "(1/0)" end
    if n == -math.huge then return "(-1/0)" end
    if math.floor(n) == n and math.abs(n) < 2 ^ 53 then
        return string.format("%.0f", n)
    end
    return string.format("%.17g", n)
end

-- Canonical, tonumber-able decimal literal for a finite number, or nil when the
-- value cannot round-trip through text (inf/nan). Mirrors serNumber's finite
-- cases so the runtime tonumber() recovers the exact value.
local function numericLiteral(n)
    if n ~= n or n == math.huge or n == -math.huge then return nil end
    if math.floor(n) == n and math.abs(n) < 2 ^ 53 then
        return string.format("%.0f", n)
    end
    return string.format("%.17g", n)
end

-- Per-build constant-cipher keys, derived from the same bkey/bstep used for the
-- instruction-stream cipher. KEEP IN SYNC with the decrypt loop in interp.lua.
local function constCipherKeys(bkey, bstep)
    local ckey = bkey % 256
    local cstep = (bstep % 255) + 1
    local cstep2 = (math.floor(bkey / 256) % 255) + 1
    return ckey, cstep, cstep2
end

-- Position-dependent additive byte cipher for a constant at physical array
-- position `pos` (1-based, padding included). Reversible by subtracting the same
-- keystream; the keystream depends on both the constant's position and the byte
-- index so identical strings at different slots encrypt differently.
local function encryptConstStr(s, pos, ckey, cstep, cstep2)
    local base = (ckey + pos * cstep) % 256
    local out = {}
    for j = 1, #s do
        local key = (base + j * cstep2) % 256
        out[j] = string.char((string.byte(s, j) + key) % 256)
    end
    return table.concat(out)
end

-- Serialize one constant's KV value, encrypting string/number constants when a
-- per-build key is present. Non-finite numbers (no text round-trip) and all
-- other tags return nil so the caller falls back to the plain serialization.
local function serKVMaybeEnc(k, pos, enc, ckey, cstep, cstep2)
    if enc and k.tag == "string" then
        return serBytes(encryptConstStr(k.value, pos, ckey, cstep, cstep2))
    elseif enc and k.tag == "number" then
        local lit = numericLiteral(k.value)
        if lit then
            return serBytes(encryptConstStr(lit, pos, ckey, cstep, cstep2))
        end
    end
    return nil
end

-- Base85 alphabet (no " ' \ so it needs no escaping in a Lua string literal).
local B85 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@[]^"
-- Encode an array of 32-bit words as base85 text.
local function encodeCode(words)
    local bytes = {}
    for i = 1, #words do
        local w = words[i]
        bytes[#bytes + 1] = w % 256
        bytes[#bytes + 1] = math.floor(w / 256) % 256
        bytes[#bytes + 1] = math.floor(w / 65536) % 256
        bytes[#bytes + 1] = math.floor(w / 16777216) % 256
    end
    local out = {}
    local n = #bytes
    local i = 1
    while i <= n do
        local b1 = bytes[i] or 0
        local b2 = bytes[i + 1] or 0
        local b3 = bytes[i + 2] or 0
        local b4 = bytes[i + 3] or 0
        local v = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        local c5 = v % 85; v = (v - c5) / 85
        local c4 = v % 85; v = (v - c4) / 85
        local c3 = v % 85; v = (v - c3) / 85
        local c2 = v % 85; v = (v - c2) / 85
        local c1 = v % 85
        local group = n - i + 1; if group > 4 then group = 4 end
        local digits = { c1, c2, c3, c4, c5 }
        for k = 1, group + 1 do out[#out + 1] = string.sub(B85, digits[k] + 1, digits[k] + 1) end
        i = i + 4
    end
    return table.concat(out)
end

-- tagnum constants (must match interp.lua)
local TAG_NIL     = 0
local TAG_BOOL    = 1
local TAG_NUMBER  = 2
local TAG_STRING  = 3
local TAG_IMPORT  = 4
local TAG_TABLE   = 5
local TAG_CLOSURE = 6
local TAG_VECTOR  = 7
local TAG_TABLE_WC= 8

local function tagOf(k)
    if k.tag == "nil"      then return TAG_NIL
    elseif k.tag == "boolean" then return TAG_BOOL
    elseif k.tag == "number"  then return TAG_NUMBER
    elseif k.tag == "string"  then return TAG_STRING
    elseif k.tag == "import"  then return TAG_IMPORT
    elseif k.tag == "table"   then return TAG_TABLE
    elseif k.tag == "closure" then return TAG_CLOSURE
    elseif k.tag == "vector"  then return TAG_VECTOR
    elseif k.tag == "table_wc" then return TAG_TABLE_WC
    else error("emit: unknown tag " .. tostring(k.tag)) end
end

-- Serialize the flat value for kv[]. For complex types (table, vector, table_wc)
-- the value slot is nil (they go into kraw); for import the packed int is stored.
local function serKV(k)
    if k.tag == "nil"     then return "nil"
    elseif k.tag == "boolean" then return tostring(k.value)
    elseif k.tag == "number"  then return serNumber(k.value)
    elseif k.tag == "string"  then return serString(k.value)
    elseif k.tag == "import"  then return serNumber(k.value)
    elseif k.tag == "closure" then return tostring(k.proto)
    -- table/vector/table_wc: value is stored in kraw, kv slot left nil
    else return "nil" end
end

-- Serialize the kraw entry (only for table/vector/table_wc consts).
-- Returns nil if this constant doesn't need a kraw entry.
local function serKRaw(k)
    if k.tag == "table" then
        return "{5,{" .. table.concat(k.keys, ",") .. "}}"
    elseif k.tag == "table_wc" then
        local parts = {}
        for _, e in ipairs(k.entries) do parts[#parts + 1] = "{" .. e.key .. "," .. e.const .. "}" end
        return "{8,{" .. table.concat(parts, ",") .. "}}"
    elseif k.tag == "vector" then
        return "{7," .. serNumber(k.x) .. "," .. serNumber(k.y) .. "," .. serNumber(k.z) .. "," .. serNumber(k.w) .. "}"
    end
    return nil
end

-- `koff` pads each proto's KV/KT/Kraw arrays with that many leading dummy
-- entries for polymorphic const-remap (see interpgen.lua).
function Emit.serializeBC(bc, koff)
    koff = koff or 0
    -- Constant encryption is keyed off the same per-build bkey/bstep as the
    -- instruction-stream cipher; it is active exactly when those keys exist
    -- (i.e. EncryptBytecode is on). The interpreter decrypts under `if bc[4]`,
    -- so the two are deliberately coupled and never get out of step.
    local enc = bc.bkey ~= nil
    local ckey, cstep, cstep2
    if enc then ckey, cstep, cstep2 = constCipherKeys(bc.bkey, bc.bstep) end
    local buf = {}
    local function w(s) buf[#buf + 1] = s end
    w("{" .. bc.mainid .. ",{")
    for _, p in ipairs(bc.protos) do
        w("{" .. p.maxstacksize .. "," .. p.numparams .. "," .. p.nups .. "," .. p.is_vararg .. ",")
        -- [5] code
        if bc.b85 then
            w(serString(encodeCode(p.code)) .. ",")
        else
            w("{" .. table.concat(p.code, ",") .. "},")
        end
        -- [6] kv: flat value array (string/number consts position-encrypted)
        w("{")
        for _ = 1, koff do w("nil,") end
        for ci, k in ipairs(p.k) do
            local s = serKVMaybeEnc(k, koff + ci, enc, ckey, cstep, cstep2)
            w((s or serKV(k)) .. ",")
        end
        w("},")
        -- [7] childprotos
        w("{" .. table.concat(p.p, ",") .. "},")
        -- [8] kt: flat tag array
        w("{")
        for _ = 1, koff do w("0,") end
        for _, k in ipairs(p.k) do w(tagOf(k) .. ",") end
        w("},")
        -- [9] kraw: sparse array for table/vector/table_wc consts
        w("{")
        local hasRaw = false
        for i, k in ipairs(p.k) do
            local raw = serKRaw(k)
            if raw then
                w("[" .. (i + koff) .. "]=" .. raw .. ",")
                hasRaw = true
            end
        end
        w("}},")
    end
    w("},")
    if bc.nonce then
        w(string.format("%.0f", bc.nonce))
    else
        if bc.opmap then
            local parts = {}
            for k, v in pairs(bc.opmap) do parts[#parts + 1] = "[" .. k .. "]=" .. v end
            w("{" .. table.concat(parts, ",") .. "},")
        else
            w("nil,")
        end
        w((bc.bkey and string.format("%.0f", bc.bkey) or "nil") .. ",")
        w((bc.bstep and string.format("%.0f", bc.bstep) or "nil"))
    end
    w("}")
    return table.concat(buf)
end

-- Build the full runnable Luau program: data literal + inlined interpreter +
-- bootstrap call.
-- When bootstrapEnv is nil the generated code captures getfenv() at the call
-- site (i.e. inside the payload function) and passes it explicitly to the VM
-- so the interpreter never needs to call getfenv() itself.  This ensures the
-- VM's env is the *same* table that the no-virt setup assignments wrote into.
function Emit.build(bc, interpSrc, bootstrapEnv, koff)
    local out = {}
    out[#out + 1] = "local bc = " .. Emit.serializeBC(bc, koff) .. "\n"
    out[#out + 1] = "local makeInterp = (function()\n" .. interpSrc .. "\nend)()\n"
    -- Always pass env explicitly so the VM uses the same env table as the
    -- enclosing payload function (where no-virt globals were set).
    local envExpr = bootstrapEnv or "(getfenv and getfenv() or _G)"
    out[#out + 1] = "return (makeInterp())(bc, " .. envExpr .. ", ...)\n"
    return table.concat(out)
end

return Emit
