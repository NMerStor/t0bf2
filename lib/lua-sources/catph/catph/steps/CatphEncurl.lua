--
-- CatphEncurl.lua  (CATPH_ENCURL layer)
--
-- Encodes every string literal in "URL percent-encoding" style:
--   each byte → %XX  where XX = hex((byte + key) % 256)
--
-- A compact decoder is injected once at the top:
--   local _ce = function(s,k)
--     local r = s:gsub("%%(%x%x)", function(h)
--       return string.char((tonumber(h,16)-k)%256)
--     end)
--     return r
--   end
--
-- Pure Lua 5.1 — no bitwise operators.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local Scope    = require("catph.scope")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local CatphEncurl = Step:extend()
CatphEncurl.Name        = "CatphEncurl"
CatphEncurl.Description = "URL-percent-encoding cipher. CATPH_ENCURL layer."

CatphEncurl.SettingsDescriptor = {
    Probability = {
        name        = "Probability",
        description = "Chance (0-1) that a string is encoded.",
        type        = "number",
        default     = 0.85,
    },
}

function CatphEncurl:init(settings)
    self.probability = (settings and settings.Probability) or 0.85
end

-- Encode a string: each byte -> %XX where XX = hex((byte+key)%256)
-- Pure Lua 5.1 compatible.
local function encodeString(s, key)
    local out = {}
    for i = 1, #s do
        out[i] = string.format("%%%02X", (s:byte(i) + key) % 256)
    end
    return table.concat(out)
end

function CatphEncurl:apply(ast, pipeline)
    local prob      = self.probability
    local mainBlock = ast.body
    local mainScope = mainBlock.scope
    local globalScope = ast.globalScope

    -- Require globals: string, tonumber
    if not globalScope:hasVariable("string")   then return ast end
    if not globalScope:hasVariable("tonumber") then return ast end
    local stringGlobalId   = globalScope.variablesLookup["string"]
    local tonumberGlobalId = globalScope.variablesLookup["tonumber"]

    -- ── Mark table keys to skip ──────────────────────────────────────────────
    local skipNode = {}
    visitast(ast, function(node)
        if node.kind == AstKind.KeyedTableEntry then
            if node.key and (node.key.kind == AstKind.StringExpression
                          or node.key.kind == AstKind.LongStringExpression) then
                skipNode[node.key] = true
            end
        end
    end, nil)

    -- ── Allocate decoder id ──────────────────────────────────────────────────
    local decId = mainScope:addVariable()

    -- ── Replace string literals ──────────────────────────────────────────────
    local anyEncoded = false

    visitast(ast, nil, function(node)
        if (node.kind == AstKind.StringExpression or node.kind == AstKind.LongStringExpression)
            and not skipNode[node]
            and node.value ~= nil
            and #node.value > 0
            and math.random() < prob
        then
            local key     = math.random(1, 127)
            local encoded = encodeString(node.value, key)
            anyEncoded    = true

            -- _ce(encodedStr, key)
            local fnRef  = Ast.VariableExpression(mainScope, decId)
            local encArg = Ast.StringExpression(encoded)
            local keyArg = Ast.NumberExpression(key)
            return Ast.FunctionCallExpression(fnRef, { encArg, keyArg })
        end
    end)

    if not anyEncoded then
        mainScope:removeVariable(decId)
        return ast
    end

    -- ── Build decoder AST ────────────────────────────────────────────────────
    --
    -- local _ce = function(s, k)
    --     local r = s:gsub("%%(%x%x)", function(h)
    --         return string.char((tonumber(h, 16) - k) % 256)
    --     end)
    --     return r
    -- end

    -- Outer function scope: s, k
    local outerScope = Scope:new(mainScope)
    local sId = outerScope:addVariable()
    local kId = outerScope:addVariable()

    -- Inner function scope: h  (captures k from outer)
    local innerScope = Scope:new(outerScope)
    local hId = innerScope:addVariable()
    innerScope:addReferenceToHigherScope(outerScope, kId)

    -- tonumber(h, 16)
    local tonumberRef = Ast.VariableExpression(globalScope, tonumberGlobalId)
    local hRef        = Ast.VariableExpression(innerScope, hId)
    local kRef        = Ast.VariableExpression(outerScope, kId)
    local tnCall      = Ast.FunctionCallExpression(tonumberRef, { hRef, Ast.NumberExpression(16) })

    -- (tonumber(h,16) - k) % 256
    local subExpr = Ast.SubExpression(tnCall, kRef)
    local modExpr = Ast.ModExpression(subExpr, Ast.NumberExpression(256))

    -- string.char(modExpr)
    local stringRef  = Ast.VariableExpression(globalScope, stringGlobalId)
    local charField  = Ast.IndexExpression(stringRef, Ast.StringExpression("char"))
    local charCall   = Ast.FunctionCallExpression(charField, { modExpr })

    -- inner function body: return string.char(...)
    local innerReturn = Ast.ReturnStatement({ charCall })
    local innerBody   = Ast.Block({ innerReturn }, innerScope)
    local innerFn     = Ast.FunctionLiteralExpression(
        { Ast.VariableExpression(innerScope, hId) },
        innerBody
    )

    -- s:gsub("%%(%x%x)", innerFn)
    local sRef     = Ast.VariableExpression(outerScope, sId)
    local gsubExpr = Ast.PassSelfFunctionCallExpression(
        sRef, "gsub",
        { Ast.StringExpression("%%(%x%x)"), innerFn }
    )

    -- outer function body:
    --   local r = s:gsub(...)
    --   return r
    local rId     = outerScope:addVariable()
    local rDecl   = Ast.LocalVariableDeclaration(outerScope, { rId }, { gsubExpr })
    local rRef    = Ast.VariableExpression(outerScope, rId)
    local outerReturn = Ast.ReturnStatement({ rRef })
    local outerBody   = Ast.Block({ rDecl, outerReturn }, outerScope)
    local outerFn     = Ast.FunctionLiteralExpression(
        {
            Ast.VariableExpression(outerScope, sId),
            Ast.VariableExpression(outerScope, kId)
        },
        outerBody
    )

    -- local _ce = outerFn
    local decoderDecl = Ast.LocalVariableDeclaration(
        mainScope, { decId }, { outerFn }
    )

    table.insert(mainBlock.statements, 1, decoderDecl)
    return ast
end

return CatphEncurl
