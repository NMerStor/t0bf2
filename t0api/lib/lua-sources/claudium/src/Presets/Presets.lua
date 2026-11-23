-- IronBrew0 v0.002 - Target Presets
-- roblox / executor / maximum share the same max-protection pipeline

local Presets = {}

local BASE = {
    rename       = true,
    minify       = true,
    singleLine   = true,
    controlFlow  = false,
    vm           = false,
    junkStates   = true,
    intensity    = 1.0,
    minStatements = 2,
    encryptConstants = true,
    antiTamper   = false,
    scrambleOps  = false,
    encryptStrings = true,
    target       = "lua51",
}

Presets.list = {
    "minimum", "maximum", "lua51", "lua53", "luajit", "roblox", "luau", "executor",
}

-- Shared max pipeline used by roblox, executor, maximum
local function applyMax(p)
    p.rename = true
    p.minify = true
    p.singleLine = false
    p.controlFlow = false
    p.vm = true
    p.encryptConstants = true
    p.encryptStrings = true
    p.antiTamper = true
    p.scrambleOps = true
    p.junkStates = true
    p.intensity = 2.0
    p.fatVM = false  -- stable executor; enable manually for max size   -- Claudium: Luraph-style VERY FAT stage-2 VM
    p.rollingXor = true
    p.base85 = true
    p.opaqueKeys = true
    p.superOps = true
    -- same target so AntiTamper enables the full Roblox suite for both
    p.target = "roblox"
end

function Presets.get(name)
    name = (name or "lua51"):lower()
    local p = {}
    for k, v in pairs(BASE) do p[k] = v end

    if name == "minimum" then
        p.rename = true
        p.minify = true
        p.controlFlow = false
        p.vm = false
        p.target = "lua51"

    elseif name == "maximum" or name == "roblox" or name == "luau" or name == "executor" then
        applyMax(p)

    elseif name == "lua51" then
        p.target = "lua51"

    elseif name == "lua53" then
        p.target = "lua53"

    elseif name == "luajit" then
        p.target = "luajit"

    else
        p.target = name
    end

    p.preset = name
    return p
end

return Presets
