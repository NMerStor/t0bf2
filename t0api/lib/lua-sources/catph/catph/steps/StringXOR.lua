--
-- StringXOR.lua
--
-- Encodes every plain string literal with a per-string random key using a
-- byte-rotation cipher (encode = add key mod 256, decode = subtract key mod 256).
-- A single shared decode function is injected at the top of the script;
-- each string becomes a call to that function:
--
--   print("hello")    →    print(_sd("\x69\x66\x6f\x6f\x72", 1))
--
-- Works with Lua 5.1+ (no bitwise operators required).

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local Scope    = require("catph.scope")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local StringXOR = Step:extend()
StringXOR.Name        = "StringXOR"
StringXOR.Description = "Encodes string literals with a byte-rotation cipher and decodes them at runtime."
StringXOR.SettingsDescriptor = {
    Probability = {
        name        = "Probability",
        description = "Chance (0–1) that any given string literal gets encoded.",
        type        = "number",
        default     = 0.9,
    },
}

function StringXOR:init(settings)
    self.probability = (settings and settings.Probability) or 0.9
end

-- Encode: each byte = (original + key) % 256
local function encodeString(s, key)
    local out = {}
    for i = 1, #s do
        out[i] = string.char((s:byte(i) + key) % 256)
    end
    return table.concat(out)
end

function StringXOR:apply(ast, pipeline)
    local prob        = self.probability
    local mainBlock   = ast.body
    local mainScope   = mainBlock.scope
    local globalScope = ast.globalScope

    -- Resolve the "string" global (needed for string.char)
    if not globalScope:hasVariable("string") then return ast end
    local stringGlobalId = globalScope.variablesLookup["string"]

    -- ── Mark string keys in KeyedTableEntry so we skip them ─────────────────
    local skipNode = {}
    visitast(ast, function(node, data)
        if node.kind == AstKind.KeyedTableEntry then
            if node.key and (node.key.kind == AstKind.StringExpression
                          or node.key.kind == AstKind.LongStringExpression) then
                skipNode[node.key] = true
            end
        end
    end, nil)

    -- ── Create decoder local id ──────────────────────────────────────────────
    local decoderId = mainScope:addVariable()

    -- ── Replace string literals with decode calls ────────────────────────────
    local anyEncoded = false

    visitast(ast, nil, function(node, data)
        if (node.kind == AstKind.StringExpression or node.kind == AstKind.LongStringExpression)
            and not skipNode[node]
            and node.value ~= nil
            and #node.value > 0
            and math.random() < prob
        then
            local key     = math.random(1, 127)
            local encoded = encodeString(node.value, key)
            anyEncoded    = true

            -- _sd(encodedStr, key)
            local fnRef  = Ast.VariableExpression(mainScope, decoderId)
            local encArg = Ast.StringExpression(encoded)
            local keyArg = Ast.NumberExpression(key)
            return Ast.FunctionCallExpression(fnRef, { encArg, keyArg })
        end
    end)

    if not anyEncoded then
        mainScope:removeVariable(decoderId)
        return ast
    end

    -- ── Build decoder function AST ───────────────────────────────────────────
    -- local _sd = function(s, k)
    --   return (s:gsub(".", function(c)
    --     return string.char((c:byte() - k) % 256)
    --   end))
    -- end

    -- Outer function scope: s, k
    local outerScope = Scope:new(mainScope)
    local sId = outerScope:addVariable()
    local kId = outerScope:addVariable()

    -- Inner function scope: c   (captures k from outer)
    local innerScope = Scope:new(outerScope)
    local cId = innerScope:addVariable()

    -- c:byte()
    local cRef      = Ast.VariableExpression(innerScope, cId)
    local cByteExpr = Ast.PassSelfFunctionCallExpression(cRef, "byte", {})

    -- k (upvalue reference from inner scope)
    innerScope:addReferenceToHigherScope(outerScope, kId)
    local kRef = Ast.VariableExpression(outerScope, kId)

    -- (c:byte() - k) % 256
    local subExpr = Ast.SubExpression(cByteExpr, kRef)
    local modExpr = Ast.ModExpression(subExpr, Ast.NumberExpression(256))

    -- string.char(modExpr)
    local stringRef  = Ast.VariableExpression(globalScope, stringGlobalId)
    local charField  = Ast.IndexExpression(stringRef, Ast.StringExpression("char"))
    local charCall   = Ast.FunctionCallExpression(charField, { modExpr })

    -- inner function body: return string.char(...)
    local innerReturn = Ast.ReturnStatement({ charCall })
    local innerBody   = Ast.Block({ innerReturn }, innerScope)
    -- FunctionLiteralExpression args must be VariableExpression objects (not raw ids)
    local innerFn     = Ast.FunctionLiteralExpression(
        { Ast.VariableExpression(innerScope, cId) },
        innerBody
    )

    -- s:gsub(".", innerFn)
    local sRef      = Ast.VariableExpression(outerScope, sId)
    local gsubExpr  = Ast.PassSelfFunctionCallExpression(
        sRef, "gsub", { Ast.StringExpression("."), innerFn }
    )

    -- outer function body:
    --   local r = s:gsub(...)   -- capture only 1 return value (gsub returns string + count)
    --   return r
    local rId     = outerScope:addVariable()
    local rDecl   = Ast.LocalVariableDeclaration(outerScope, { rId }, { gsubExpr })
    local rRef    = Ast.VariableExpression(outerScope, rId)
    local outerReturn = Ast.ReturnStatement({ rRef })
    local outerBody   = Ast.Block({ rDecl, outerReturn }, outerScope)
    local outerFn     = Ast.FunctionLiteralExpression(
        { Ast.VariableExpression(outerScope, sId), Ast.VariableExpression(outerScope, kId) },
        outerBody
    )

    -- local _sd = outerFn
    local decoderDecl = Ast.LocalVariableDeclaration(
        mainScope, { decoderId }, { outerFn }
    )

    table.insert(mainBlock.statements, 1, decoderDecl)

    return ast
end

return StringXOR
