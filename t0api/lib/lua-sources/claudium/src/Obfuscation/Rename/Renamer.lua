-- IronBrew0 v0.001 - Identifier Renamer
-- Configurable short-name generation respecting scopes and preserved names

local ScopeMod = require("src.Obfuscation.Rename.Scope")

local Renamer = {}
Renamer.__index = Renamer

local CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local CHARSET_FIRST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

function Renamer.new(options)
    options = options or {}
    return setmetatable({
        strategy   = options.strategy or "short", -- short, numbered, hex
        preserved  = options.preserved or {},
        target     = options.target or "lua51",
        counter    = 0,
        usedNames  = {}, -- global used short names to avoid collisions with globals
    }, Renamer)
end

function Renamer:nextName()
    self.counter = self.counter + 1
    local n = self.counter
    if self.strategy == "numbered" then
        return "_" .. tostring(n)
    elseif self.strategy == "hex" then
        return string.format("_x%X", n)
    end

    -- short: a, b, ..., z, A, ..., aa, ab, ...
    local name = ""
    local first = true
    while n > 0 do
        n = n - 1
        local charset = first and CHARSET_FIRST or CHARSET
        local idx = (n % #charset) + 1
        name = charset:sub(idx, idx) .. name
        n = math.floor(n / #charset)
        first = false
    end
    return name
end

function Renamer:generateUnique(scope, preferred)
    local name
    repeat
        name = preferred or self:nextName()
        preferred = nil
        -- check not used in this scope chain and not a preserved/global name
        local clash = false
        if self.usedNames[name] then clash = true end
        local s = scope
        while s and not clash do
            if s.locals[name] and s.locals[name].renamed then
                clash = true
            end
            s = s.parent
        end
        -- also avoid Lua keywords
        local keywords = {
            ["and"]=1, ["break"]=1, ["do"]=1, ["else"]=1, ["elseif"]=1, ["end"]=1,
            ["false"]=1, ["for"]=1, ["function"]=1, ["goto"]=1, ["if"]=1, ["in"]=1,
            ["local"]=1, ["nil"]=1, ["not"]=1, ["or"]=1, ["repeat"]=1, ["return"]=1,
            ["then"]=1, ["true"]=1, ["until"]=1, ["while"]=1, ["continue"]=1,
        }
        if keywords[name] then clash = true end
    until not clash
    self.usedNames[name] = true
    return name
end

function Renamer:renameScope(scope)
    for name, binding in pairs(scope.locals) do
        if not binding.renamed then
            local newName = self:generateUnique(scope)
            binding.renamed = newName
            -- update the declaration node
            if binding.node then
                binding.node.name = newName
            end
            -- update all references
            for _, ref in ipairs(binding.references) do
                ref.name = newName
            end
        end
    end
    for _, child in ipairs(scope.children) do
        self:renameScope(child)
    end
end

function Renamer:run(ast, options)
    options = options or {}
    local analyzer = ScopeMod.Analyzer.new({
        preserved = self.preserved,
        target = self.target,
    })
    local root = analyzer:analyze(ast)

    -- Mark known globals as used so we don't collide
    for g in pairs(analyzer.globals) do
        self.usedNames[g] = true
    end
    for p in pairs(analyzer.preserved) do
        self.usedNames[p] = true
    end

    self:renameScope(root)
    return ast, root
end

return Renamer
