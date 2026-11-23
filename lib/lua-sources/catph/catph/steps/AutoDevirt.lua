--
-- AutoDevirt.lua
--
-- Automatic selective devirtualization: identifies simple loop bodies
-- (arithmetic, table access, assignments) and keeps them as native Lua code
-- instead of virtualizing them. The VM only handles control flow and API calls.
-- This gives near-native performance on tight loops while keeping security
-- on the parts that matter (function structure, string constants, globals).

local Step = require("catph.step")
local Ast = require("catph.ast")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local AutoDevirt = Step:extend()
AutoDevirt.Name = "AutoDevirt"
AutoDevirt.Description = "Selectively devirtualizes simple loop bodies for near-native performance."

AutoDevirt.SettingsDescriptor = {}

function AutoDevirt:init(settings) end

-- Check if an expression is "simple" (only arithmetic, table access, variables, constants)
local function isSimpleExpr(node)
    if not node then return false end
    local k = node.kind
    if k == AstKind.NumberExpression or k == AstKind.StringExpression
        or k == AstKind.BooleanExpression or k == AstKind.NilExpression
        or k == AstKind.VariableExpression or k == AstKind.VarargExpression then
        return true
    end
    if k == AstKind.AddExpression or k == AstKind.SubExpression
        or k == AstKind.MulExpression or k == AstKind.DivExpression
        or k == AstKind.ModExpression or k == AstKind.PowExpression
        or k == AstKind.IDivExpression then
        return isSimpleExpr(node.lhs) and isSimpleExpr(node.rhs)
    end
    if k == AstKind.StrCatExpression then
        return isSimpleExpr(node.lhs) and isSimpleExpr(node.rhs)
    end
    if k == AstKind.NegateExpression or k == AstKind.NotExpression
        or k == AstKind.LenExpression then
        return isSimpleExpr(node.rhs)
    end
    if k == AstKind.IndexExpression then
        return isSimpleExpr(node.base) and isSimpleExpr(node.index)
    end
    -- Comparisons
    if k == AstKind.EqualsExpression or k == AstKind.NotEqualsExpression
        or k == AstKind.LessThanExpression or k == AstKind.LessThanOrEqualsExpression
        or k == AstKind.GreaterThanExpression or k == AstKind.GreaterThanOrEqualsExpression then
        return isSimpleExpr(node.lhs) and isSimpleExpr(node.rhs)
    end
    if k == AstKind.AndExpression or k == AstKind.OrExpression then
        return isSimpleExpr(node.lhs) and isSimpleExpr(node.rhs)
    end
    return false
end

-- Check if a statement is "simple" (only assignments with simple expressions)
local function isSimpleStatement(stat)
    if not stat then return false end
    local k = stat.kind
    if k == AstKind.NopStatement then return true end
    if k == AstKind.AssignmentStatement then
        for _, expr in ipairs(stat.rhs or {}) do
            if not isSimpleExpr(expr) then return false end
        end
        return true
    end
    -- Compound assignments
    if k == AstKind.CompoundAddStatement or k == AstKind.CompoundSubStatement
        or k == AstKind.CompoundMulStatement or k == AstKind.CompoundDivStatement
        or k == AstKind.CompoundModStatement or k == AstKind.CompoundPowStatement
        or k == AstKind.CompoundConcatStatement or k == AstKind.CompoundIDivStatement then
        return isSimpleExpr(stat.rhs)
    end
    -- Local variable declaration with simple init
    if k == AstKind.LocalVariableDeclaration then
        for _, expr in ipairs(stat.expressions or {}) do
            if not isSimpleExpr(expr) then return false end
        end
        return true
    end
    return false
end

-- Check if a for-loop body is simple enough to keep native
local function isSimpleLoopBody(body)
    if not body or not body.statements then return false end
    local stmts = body.statements
    -- Max 6 statements in the body
    if #stmts > 6 then return false end
    if #stmts == 0 then return false end
    for _, stat in ipairs(stmts) do
        if not isSimpleStatement(stat) then return false end
    end
    return true
end

function AutoDevirt:apply(ast, pipeline)
    -- Mark simple for-loop bodies with __native flag
    -- The CustomVM compiler will check this flag and skip compilation for marked bodies
    visitast(ast, nil, function(node, data)
        if node.kind == AstKind.ForStatement then
            if isSimpleLoopBody(node.body) then
                node.__nativeBody = true
            end
        end
        if node.kind == AstKind.ForInStatement then
            if isSimpleLoopBody(node.body) then
                node.__nativeBody = true
            end
        end
    end)
    return ast
end

return AutoDevirt
