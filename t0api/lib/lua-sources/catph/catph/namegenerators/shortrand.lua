--
-- namegenerators/shortrand.lua
--
-- Generates short mixed-case names: single letters first (a–z, A–Z, shuffled),
-- then two-char pairs, then three-char triples.
--
-- KEY FIX: uses a module-level monotonic counter (_gid) that increments on
-- every generateName() call and is reset in prepare().  This ensures every
-- variable across ALL scopes gets a UNIQUE sequential id, so common-scope
-- first-args (id=0) in different functions no longer produce the same letter.
--
-- Namespace: 52 + 2704 + 140608 = 143364 unique names before any collision.

local util = require("catph.util");

-- 52-char alphabet: lowercase then uppercase
local ALPHA = {}
for c in ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do
    ALPHA[#ALPHA+1] = c
end

local N = #ALPHA  -- 52

-- Global monotonic counter — reset per obfuscation run in prepare().
local _gid = 0

-- Extra shuffled alphabets for 2nd/3rd character positions so consecutive
-- 2-char names don't share the same first letter (breaks ZAjO patterns).
-- Populated (and re-shuffled) in prepare() before first use.
local _unpack = table.unpack or unpack
local ALPHA2  = {_unpack(ALPHA)}
local ALPHA3a = {_unpack(ALPHA)}
local ALPHA3b = {_unpack(ALPHA)}

local function idToName(id)
    if id < N then
        return ALPHA[id + 1]
    elseif id < N + N * N then
        local rem = id - N
        local d1  = math.floor(rem / N) % N
        local d2  = rem % N
        -- Use ALPHA2 for position-2 to break shared-prefix visual patterns
        return ALPHA[d1 + 1] .. ALPHA2[d2 + 1]
    else
        local rem = id - N - N * N
        local d1  = math.floor(rem / (N * N)) % N
        local d2  = math.floor(rem / N) % N
        local d3  = rem % N
        -- Use ALPHA3a/ALPHA3b for positions 2/3
        return ALPHA[d1 + 1] .. ALPHA3a[d2 + 1] .. ALPHA3b[d3 + 1]
    end
end

-- `id` and `scope` are provided by the obfuscator framework but we ignore `id`
-- entirely; _gid is our source of truth to avoid cross-scope collisions.
local function generateName(id, scope)
    local name = idToName(_gid)
    _gid = _gid + 1
    return name
end

local function prepare(ast)
    util.shuffle(ALPHA)
    -- Independently shuffle the position-2/3 alphabets so no shared-prefix
    -- visual patterns emerge from sequential 2-char/3-char name generation.
    ALPHA2  = {_unpack(ALPHA)}; util.shuffle(ALPHA2)
    ALPHA3a = {_unpack(ALPHA)}; util.shuffle(ALPHA3a)
    ALPHA3b = {_unpack(ALPHA)}; util.shuffle(ALPHA3b)
    _gid = 0   -- reset for each new obfuscation run
end

return {
    generateName = generateName,
    prepare      = prepare,
}
