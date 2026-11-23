--
-- VariableSplitting.lua
--
-- Splits local variables initialised with a plain integer/float literal into
-- two locals whose values combine back to the original:
--
--   local x = 10          local _a, _b = 3, 7     -- (3 + 7 = 10)
--   print(x)       →      print(_a + _b)
--
-- Only applies when:
--   • The declaration has a clean 1:1 id/expression pairing.
--   • The expression is a NumberExpression.
--   • The variable is never reassigned anywhere in the program.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local Scope    = require("catph.scope")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local VariableSplitting = Step:extend()
VariableSplitting.Name        = "VariableSplitting"
VariableSplitting.Description = "Splits numeric local variables into two locals that sum/combine to the original value."
VariableSplitting.SettingsDescriptor = {
    Probability = {
        name        = "Probability",
        description = "Chance (0–1) that any eligible local gets split.",
        type        = "number",
        default     = 0.7,
    },
}

local compoundKinds = {
    [AstKind.CompoundAddStatement]    = true,
    [AstKind.CompoundSubStatement]    = true,
    [AstKind.CompoundMulStatement]    = true,
    [AstKind.CompoundDivStatement]    = true,
    [AstKind.CompoundPowStatement]    = true,
    [AstKind.CompoundModStatement]    = true,
    [AstKind.CompoundConcatStatement] = true,
    [AstKind.CompoundIDivStatement]   = true,
}

function VariableSplitting:init(settings)
    self.probability = (settings and settings.Probability) or 0.7
end

function VariableSplitting:apply(ast, pipeline)
    local prob = self.probability

    -- ── Pass 1: collect candidates + written set ────────────────────────────
    -- candidates[scope][id] = { declStat, index, value (number) }
    local candidates = {}
    local written    = {}

    local function markWritten(scope, id)
        written[scope] = written[scope] or {}
        written[scope][id] = true
    end

    visitast(ast, function(node, data)
        if node.kind == AstKind.AssignmentStatement then
            for _, lhs in ipairs(node.lhs) do
                if lhs.kind == AstKind.AssignmentVariable then
                    markWritten(lhs.scope, lhs.id)
                end
            end
        elseif compoundKinds[node.kind] then
            if node.lhs and node.lhs.kind == AstKind.AssignmentVariable then
                markWritten(node.lhs.scope, node.lhs.id)
            end
        elseif node.kind == AstKind.FunctionDeclaration then
            markWritten(node.scope, node.id)
        elseif node.kind == AstKind.LocalVariableDeclaration then
            if #node.ids == #node.expressions then
                for i, id in ipairs(node.ids) do
                    local expr = node.expressions[i]
                    if expr and expr.kind == AstKind.NumberExpression then
                        candidates[node.scope] = candidates[node.scope] or {}
                        candidates[node.scope][id] = {
                            declStat = node,
                            index    = i,
                            value    = expr.value,
                        }
                    end
                end
            end
        end
    end, nil)

    -- Drop written candidates
    for scope, ids in pairs(written) do
        if candidates[scope] then
            for id in pairs(ids) do candidates[scope][id] = nil end
        end
    end

    -- Apply probability filter
    for scope, ids in pairs(candidates) do
        for id in pairs(ids) do
            if math.random() >= prob then candidates[scope][id] = nil end
        end
    end

    if next(candidates) == nil then return ast end

    -- ── Pass 2: build split info for each candidate ─────────────────────────
    -- splitInfo[scope][id] = { idA, idB, valA, valB }
    local splitInfo = {}

    for scope, ids in pairs(candidates) do
        splitInfo[scope] = {}
        for id, cand in pairs(ids) do
            local n  = cand.value
            -- Split: n = valA + valB  where valB is random offset
            local valB = math.random(-50, 50)
            local valA = n - valB

            local idA = scope:addVariable()
            local idB = scope:addVariable()

            splitInfo[scope][id] = {
                declStat = cand.declStat,
                index    = cand.index,
                idA      = idA,
                idB      = idB,
                valA     = valA,
                valB     = valB,
            }
        end
    end

    -- ── Pass 3: rewrite declarations + reads ────────────────────────────────
    visitast(ast, nil, function(node, data)
        -- Rewrite LocalVariableDeclaration that has split candidates
        if node.kind == AstKind.LocalVariableDeclaration then
            local scopeSplit = splitInfo[node.scope]
            if not scopeSplit then return end

            local newIds, newExprs = {}, {}
            local changed = false

            for i, id in ipairs(node.ids) do
                local info = scopeSplit[id]
                if info then
                    changed = true
                    -- Replace `id = n` with `idA, idB = valA, valB`
                    table.insert(newIds,   info.idA)
                    table.insert(newIds,   info.idB)
                    table.insert(newExprs, Ast.NumberExpression(info.valA))
                    table.insert(newExprs, Ast.NumberExpression(info.valB))
                    -- Remove original id from scope
                    node.scope:removeVariable(id)
                else
                    table.insert(newIds,   id)
                    table.insert(newExprs, node.expressions[i])
                end
            end

            if changed then
                node.ids         = newIds
                node.expressions = newExprs
            end

        -- Rewrite reads: x → (_a + _b)
        elseif node.kind == AstKind.VariableExpression then
            local scopeSplit = splitInfo[node.scope]
            local info = scopeSplit and scopeSplit[node.id]
            if info then
                -- Mirror SadoxInline: remove full reference chain for the
                -- replaced read (handles both direct referenceCounts and any
                -- variablesFromHigherScopes entries in intermediate scopes).
                data.scope:removeReferenceToHigherScope(node.scope, node.id)
                local exprA = Ast.VariableExpression(node.scope, info.idA)
                local exprB = Ast.VariableExpression(node.scope, info.idB)
                return Ast.AddExpression(exprA, exprB)
            end
        end
    end)

    return ast
end

return VariableSplitting
