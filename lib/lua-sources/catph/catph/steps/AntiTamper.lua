local Step = require("catph.step");
local Ast = require("catph.ast");
local Enums = require("catph.enums");
local Parser = require("catph.parser");
local RandomStrings = require("catph.randomStrings");
local logger = require("logger");

local AntiTamper = Step:extend();
AntiTamper.Name = "Anti Tamper";

AntiTamper.SettingsDescriptor = {
    UseDebug = {
        type = "boolean",
        default = true,
        description = "Use debug library checks (recommended)."
    }
}

function AntiTamper:init(settings)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Compile-time helpers: encode a string with a position-dependent key so the
-- plaintext never appears in the emitted Lua source and the decoder cannot be
-- recognised as a fixed-shift Caesar cipher.
--
-- Key schedule per byte i:  ki = (key*(i%11+1) + i*7 + key%31) % 256
-- Encode:  out[i] = (byte + ki) % 256
-- Decode:  char   = (out[i] - ki + 512) % 256
--
-- Uses only standard Lua (string.char / table.concat), executor-safe.
-- ─────────────────────────────────────────────────────────────────────────────
local function xorKeyEncode(s, key)
    local t = {}
    for i = 1, #s do
        local ki = (key * ((i % 11) + 1) + i * 7 + (key % 31)) % 256
        t[i] = (string.byte(s, i) + ki) % 256
    end
    return t
end

local function bytesLiteral(t)
    return "{" .. table.concat(t, ",") .. "}"
end

-- Emit a self-contained IIFE that decodes a position-keyed byte table.
-- decodeVar : local variable name that will hold the decoded string
-- encodedBytes : already-computed table from xorKeyEncode()
-- key : the base key integer
local function emitDecoder(decodeVar, encodedBytes, key)
    return string.format(
        "local %s=(function()local _t=%s;local _k=%d;local _r={};" ..
        "for _i=1,#_t do " ..
        "local _ki=(_k*((_i%%11)+1)+_i*7+(_k%%31))%%256;" ..
        "_r[_i]=string.char((_t[_i]-_ki+512)%%256)" ..
        "end;return table.concat(_r)end)()",
        decodeVar, bytesLiteral(encodedBytes), key
    )
end

function AntiTamper:apply(ast, pipeline)
    if pipeline.PrettyPrint then
        logger:warn(string.format("\"%s\" cannot be used with PrettyPrint, ignoring.", self.Name));
        return ast;
    end

    -- ── Per-build random shift keys ───────────────────────────────────────────
    local keyMarker = math.random(1, 200)
    local keyErr    = math.random(1, 200)
    local keyEPfx   = math.random(1, 200)

    -- Sensitive strings encoded at obfuscation time
    local encMarker = xorKeyEncode("Catph:1: Expected ')' (to close '(' at column 23013), got '...'",                                          keyMarker)
    local encErr    = xorKeyEncode("Catph:attempt to index a nil value / invalid upvalue index",  keyErr)
    local encEPfx   = xorKeyEncode("Catph:1: Expected ')' (to close '(' at column 23013), got '...'",                                                     keyEPfx)

    -- Emit the decode statements (injected at the top of the protection block)
    local decMarkerStmt = emitDecoder("_AT1_MARKER",  encMarker, keyMarker)
    local decErrStmt    = emitDecoder("_errMsg",      encErr,    keyErr)
    local decEPfxStmt   = emitDecoder("_eMsgPfx",     encEPfx,   keyEPfx)

    local code = string.format([[
do
    local _lIl1IlI:{a:number}&{b:string}={a=0,b=""}
    local _IlI1lIl:((number)->string)&((string)->number)=nil::any
    local _Il1:number=0;_Il1 += 0;_Il1 //= 1
    do for _IlIl=1,1 do continue end end

    local _sx_type        = type
    local _sx_pcall       = pcall
    local _sx_error       = error
    local _sx_find        = string.find
    local _sx_gmatch      = string.gmatch
    local _sx_tostring    = tostring
    local _sx_tonumber    = tonumber
    local _sx_math_random = math.random
    local _sx_unpack      = table.unpack or unpack
    local _sx_select      = select

    local function _sx_crash()
        local _t
        while true do _t = {_t} end
    end

    -- ── LAYER 1: MARKER probe ──────────────────────────────────────────────
    %s
    local function _AT1_probe(fn)
        local _ok, _err = _sx_pcall(fn)
        if _sx_type(_err) ~= "string" then return false end
        return _sx_find(_err, _AT1_MARKER, 1, true) ~= nil
    end
    local function _AT1_check()
        if _sx_type(game) ~= "userdata" then return false end
        if _sx_type(Enum) ~= "userdata" then return false end
        for _ = 1, 7 do
            if not _AT1_probe(function() _sx_error(_AT1_MARKER) end) then
                return false
            end
        end
        return true
    end
    if not _AT1_check() then _sx_crash() end

    -- ── LAYER 2: pcall integrity + accumulator ─────────────────────────────
    do
        %s
        local _valid    = true
        local _err1     = function() error(_errMsg) end
        local _err2     = function() error(_errMsg) end
        local _err3     = function() error(_errMsg) end
        local _errFuncs = {_err1, _err2, _err3}
        local _errFn    = _errFuncs[_sx_math_random(1, #_errFuncs)]

        local _intact2 = false
        local _intact  = _sx_pcall(function() _intact2 = true end) and _intact2
        if not _intact then _sx_crash() end

        local _n = _sx_math_random(3, 65)
        if _n < 3 or _n > 65 then _sx_crash() end

        local _acc1 = 0
        local _acc2 = 0
        local _len  = 100

        %s
        for _i = 1, _len do
            local _n2       = _i %% 256
            local _pos      = _i %% _len + 1
            local _shouldErr = (_i %% 2 == 0)
            local _eMsg     = _eMsgPfx .. _sx_tostring(_i)
            local _arr      = {_sx_pcall(function()
                if _shouldErr then _sx_error(_eMsg, 0) end
                local _res = {}
                for _j = 1, _len do _res[_j] = _sx_math_random(0, 255) end
                _res[_pos] = _n2
                return _sx_unpack(_res)
            end)}
            if _shouldErr then
                _valid = _valid and _arr[1] == false and _arr[2] == _eMsg
            else
                _valid = _valid and _arr[1]
                _acc1 = (_acc1 + (_arr[_pos + 1] or 0)) %% 256
                _acc2 = (_acc2 + _n2) %% 256
            end
        end

        _valid = _valid and (_acc1 == _acc2)
        if not _valid then
            repeat
                return (function() _errFn() end)()
            until true
        end
    end

    -- ── LAYER 3: env-logger / executor detection ───────────────────────────
    local _gg = getfenv and getfenv(0) or _G

    local function _isHooked(fn)
        local _ok, _r = pcall(debug.info, fn, "s")
        if not _ok or _r ~= "[C]" then return true end
        return false
    end

    local function _antiLogger()
        if not pcall(debug.getregistry) then
            error(string.char(115,116,111,112,32,115,107,105,100,100,105,110,103,44,32,104,116,116,112,115,58,47,47,111,98,102,117,115,99,97,116,111,114,46,99,102,100,47),0)
        end
        local _fns = {print,warn,require,getfenv,setfenv,pcall,debug.info,debug.getregistry,rawget,rawset,select,type,getmetatable,setmetatable}
        for _i = 1, #_fns do
            if _isHooked(_fns[_i]) then
                error(string.char(115,116,111,112,32,115,107,105,100,100,105,110,103,44,32,104,116,116,112,115,58,47,47,111,98,102,117,115,99,97,116,111,114,46,99,102,100,47),0)
            end
        end
        for _, _v in next, _gg do
            if type(_v) == "table" and getmetatable(_v) then
                error(string.char(115,116,111,112,32,115,107,105,100,100,105,110,103),0)
            end
        end
        local _ok2, _r2 = pcall(function()
            return ({debug.info(print,"a")})[1]~=0
                or ({debug.info(tostring,"a")})[1]~=0
                or ({debug.info(print,"a")})[2]~=true
                or select(1,pcall(getfenv,69))==true
        end)
        if not _ok2 or _r2 then
            error(string.char(115,116,111,112,32,115,107,105,100,100,105,110,103),0)
        end
        local _fps = game:GetService(string.char(87,111,114,107,115,112,97,99,101)):GetRealPhysicsFPS()
        if type(_fps) ~= "number" or _fps < 0.1 or _fps > 500 then
            error(string.char(115,116,111,112,32,115,107,105,100,100,105,110,103),0)
        end
    end

    local _ok3, _e3 = pcall(_antiLogger)
    if not _ok3 then
        for _k in next, _gg do _gg[_k] = nil end
        while true do end
    end

    -- Anti-dump constant: NaN never equals itself in correct Lua/LuaU
    -- A naive bytecode dumper that reconstructs it as 0 or nil will pass == and crash
    local _nan = 0/0
    if _nan == _nan then _sx_crash() end

    -- Executor request stack-overflow probe
    local _req = request or (syn and syn.request) or (http and http.request)
    if _req then
        local function _depth() local _d=0 local function _r() _d=_d+1 _r() end pcall(_r) return _d end
        local _sd = _depth()
        local function _probe(_n2) if _n2 < _sd-2 then _probe(_n2+1) else _req({Url="http://localhost:1/",Method="GET"}) end end
        local _ok4, _m4 = pcall(_probe, 1)
        if not _ok4 and _sx_tostring(_m4):lower():find("stack overflow") then game:Shutdown() end
    end
end
]], decMarkerStmt, decErrStmt, decEPfxStmt)

    local parsed = Parser:new({LuaVersion = Enums.LuaVersion.LuaU}):parse(code);
    local doStat = parsed.body.statements[1];
    doStat.body.scope:setParent(ast.body.scope);
    table.insert(ast.body.statements, 1, doStat);

    return ast;
end

return AntiTamper;
