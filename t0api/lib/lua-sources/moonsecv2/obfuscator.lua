local util = require("util")
local parser = require("parser")
local encoder = require("encoder")
local vmgen = require("vmgen")

local obfl = {}

math.randomseed(os.time())

local function makecfg()
    local vopList = encoder.buildvopmap()
    local count = #vopList
    local pool = {}
    for i = 1, count do
        pool[i] = i - 1
    end
    util.shuf(pool)

    local opEnc = {}
    for i = 1, count do
        opEnc[vopList[i].id] = pool[i]
    end

    local tagMod = math.random(28, 48)
    local tkeys = util.picknums(4, 1, tagMod - 1)

    return {
        vopList  = vopList,
        opEncode = opEnc,
        initKey  = math.random(15, 240),
        stepKey  = math.random(10, 120) * 2 + 1,
        strStep  = math.random(25, 220),
        tagMod   = tagMod,
        tagNil   = tkeys[1],
        tagBool  = tkeys[2],
        tagNum   = tkeys[3],
        tagStr   = tkeys[4],
        alphabet = util.makealpha()
    }
end

function obfl.obfuscate(srctxt)
    local fn, err = (loadstring or load)(srctxt)
    if not fn then
        error("compile error: " .. tostring(err))
    end
    local raw = string.dump(fn)
    local root = parser.getchunk(raw)
    local cfg = makecfg()
    local payload = encoder.encode(root, cfg)
    return vmgen.generate(payload, cfg)
end

if arg and arg[1] and select(1, ...) == arg[1] then
    local inp = arg[1]
    local outp = arg[2]
    local f = assert(io.open(inp, "rb"))
    local src = f:read("*a")
    f:close()
    local res = obfl.obfuscate(src)
    if outp then
        local out = assert(io.open(outp, "wb"))
        out:write(res)
        out:close()
    else
        print(res)
    end
end

return obfl
