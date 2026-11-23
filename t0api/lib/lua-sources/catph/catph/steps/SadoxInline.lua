--
-- SadoxInline.lua
--
-- SADOX_INLINE step: constant propagation for local variables.
--
-- Finds declarations of the shape `local a = <literal>` where `a` is never
-- reassigned anywhere in the script, then replaces every read of `a` with
-- the literal value directly and drops the now-dead declaration.
--
--   local a = 5            print(5)
--   print(a)        →
--
-- Only the safe/simple case is handled:
--   - the initializer is a literal (number/string/long-string/boolean/nil)
--   - the declaration has a clean 1:1 id/expression pairing
--     (`local a, b = 1, 2` is fine; `local a, b = f()` is left alone)
--   - the variable is never written to anywhere in the program (no plain
--     assignment, no compound assignment like `a += 1`)
-- Anything that doesn't match is left untouched.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local SadoxInline = Step:extend()
SadoxInline.Name        = "SADOX_INLINE"
SadoxInline.Description = "Inlines local variables that are assigned a constant literal once and never reassigned."
SadoxInline.SettingsDescriptor = {}

function SadoxInline:init(settings)
end

-- Literal expression kinds we are willing to inline.
local INLINABLE_KINDS = {
    [AstKind.NumberExpression]     = true,
    [AstKind.StringExpression]     = true,
    [AstKind.LongStringExpression] = true,
    [AstKind.BooleanExpression]    = true,
    [AstKind.NilExpression]        = true,
}

-- Clone a constant literal node so each inlined use site gets its own node
-- instance instead of sharing one mutable table across the AST.
local function cloneConstant(node)
    if node.kind == AstKind.NumberExpression then
        return Ast.NumberExpression(node.value)
    elseif node.kind == AstKind.StringExpression then
        return Ast.StringExpression(node.value)
    elseif node.kind == AstKind.LongStringExpression then
        return Ast.LongStringExpression(node.value, node.level)
    elseif node.kind == AstKind.BooleanExpression then
        return Ast.BooleanExpression(node.value)
    elseif node.kind == AstKind.NilExpression then
        return Ast.NilExpression()
    end
end

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

function SadoxInline:apply(ast, pipeline)
    -- ── Pass 1: collect inline candidates + every write site ───────────────
    -- candidates[scope][id] = { declStat = <LocalVariableDeclaration>, index = i, value = <literal node> }
    local candidates = {}
    -- written[scope][id] = true  -- disqualifies that (scope,id) from inlining
    local written = {}

    local function markWritten(scope, id)
        written[scope] = written[scope] or {}
        written[scope][id] = true
    end

    local function markWrittenExpr(expr)
        if expr and expr.kind == AstKind.AssignmentVariable then
            markWritten(expr.scope, expr.id)
        end
    end

    visitast(ast, function(node, data)
        if node.kind == AstKind.AssignmentStatement then
            for _, lhs in ipairs(node.lhs) do
                markWrittenExpr(lhs)
            end
        elseif compoundKinds[node.kind] then
            markWrittenExpr(node.lhs)
        elseif node.kind == AstKind.FunctionDeclaration then
            -- `function a() ... end` (non-local) is sugar for assigning a
            -- function value to `a` — treat it as a write, same as
            -- `a = function() ... end`.
            markWritten(node.scope, node.id)
        elseif node.kind == AstKind.LocalVariableDeclaration then
            if #node.ids == #node.expressions then
                for i, id in ipairs(node.ids) do
                    local valueNode = node.expressions[i]
                    if valueNode and INLINABLE_KINDS[valueNode.kind] then
                        candidates[node.scope] = candidates[node.scope] or {}
                        candidates[node.scope][id] = {
                            declStat = node,
                            index    = i,
                            value    = valueNode,
                        }
                    end
                end
            end
        end
    end, nil)

    for scope, ids in pairs(written) do
        if candidates[scope] then
            for id in pairs(ids) do
                candidates[scope][id] = nil
            end
        end
    end

    if next(candidates) == nil then
        return ast
    end

    -- ── Pass 2: replace reads with the literal ──────────────────────────────
    -- touchedDecls[declStat] = { removed = { [index] = true, ... } }
    local touchedDecls = {}

    visitast(ast, nil, function(node, data)
        if node.kind == AstKind.VariableExpression then
            local scopeCandidates = candidates[node.scope]
            local candidate = scopeCandidates and scopeCandidates[node.id]
            -- Don't touch the declaration's own initializer expression.
            if candidate and node ~= candidate.value then
                -- Mirror the bookkeeping `Scope:resolve()` did when this read
                -- was first parsed: if the read happens in a nested (child)
                -- scope, walk the chain back down to the declaring scope,
                -- decrementing each hop's `variablesFromHigherScopes` count
                -- as well as the declaring scope's own referenceCounts. Using
                -- plain `scope:removeReference` here would leave stale
                -- cross-scope entries that later crash/corrupt variable
                -- renaming (Scope:renameVariables reads a now-nil variable
                -- name once the declaration is pruned in Pass 3).
                data.scope:removeReferenceToHigherScope(node.scope, node.id)
                touchedDecls[candidate.declStat] = touchedDecls[candidate.declStat]
                    or { declStat = candidate.declStat, removed = {} }
                touchedDecls[candidate.declStat].removed[candidate.index] = true
                return cloneConstant(candidate.value)
            end
        end
    end)

    -- ── Pass 3: drop inlined ids from their declarations ────────────────────
    -- Only drop an id if EVERY read of it got inlined (zero references left).
    for declStat, info in pairs(touchedDecls) do
        local scope = declStat.scope
        local keepIds, keepExprs = {}, {}
        for i, id in ipairs(declStat.ids) do
            local wasInlined       = info.removed[i]
            local stillReferenced  = scope:getReferences(id) > 0
            if wasInlined and not stillReferenced then
                scope:removeVariable(id)
            else
                table.insert(keepIds, id)
                table.insert(keepExprs, declStat.expressions[i])
            end
        end
        declStat.ids         = keepIds
        declStat.expressions = keepExprs
    end

    -- ── Pass 4: remove now-empty declarations from their blocks ─────────────
    visitast(ast, nil, function(node, data)
        if node.kind == AstKind.LocalVariableDeclaration and #node.ids == 0 then
            return Ast.NopStatement()
        end
    end)

    return ast
end

return SadoxInline
