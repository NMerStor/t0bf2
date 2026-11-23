--
-- DeadCode.lua
--
-- Injects unreachable dead-code blocks at random positions in the program.
-- Each dead block is guarded by an opaque-false condition so it can never run:
--
--   local x = 1              local x = 1
--   print(x)         →       if (N * N < 0) then local _junk = 0 end
--                            print(x)
--
-- Dead blocks contain harmless junk (local declarations, discarded math)
-- that look realistic but have no effect on program state.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local Scope    = require("catph.scope")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local DeadCode = Step:extend()
DeadCode.Name        = "DeadCode"
DeadCode.Description = "Injects unreachable dead-code blocks guarded by opaque-false predicates."
DeadCode.SettingsDescriptor = {
    Probability = {
        name        = "Probability",
        description = "Chance (0–1) that a dead block is injected after any given statement.",
        type        = "number",
        default     = 0.3,
    },
}

function DeadCode:init(settings)
    self.probability = (settings and settings.Probability) or 0.3
end

-- Always-false: N * N < 0  (squares are never negative)
local function opaqueFalse()
    local n = math.random(2, 99)
    return Ast.LessThanExpression(
        Ast.MulExpression(Ast.NumberExpression(n), Ast.NumberExpression(n)),
        Ast.NumberExpression(0)
    )
end

-- Alternate always-false: ("a" == "b")
local function opaqueFalse2()
    local s1 = tostring(math.random(1000, 9999))
    local s2 = tostring(math.random(1000, 9999))
    -- make sure they differ
    if s1 == s2 then s2 = s2 .. "x" end
    return Ast.EqualsExpression(
        Ast.StringExpression(s1),
        Ast.StringExpression(s2)
    )
end

local FALSE_PREDS = { opaqueFalse, opaqueFalse2 }

-- Build a convincing-looking but dead junk body
local function makeDeadBody(parentScope)
    local bodyScope = Scope:new(parentScope)
    local stmts = {}

    -- Pick 1-3 junk statements
    local count = math.random(1, 3)
    for _ = 1, count do
        local choice = math.random(1, 3)
        if choice == 1 then
            -- local _v = <number>
            local id = bodyScope:addVariable()
            table.insert(stmts, Ast.LocalVariableDeclaration(
                bodyScope, { id },
                { Ast.NumberExpression(math.random(0, 999)) }
            ))
        elseif choice == 2 then
            -- local _v = <string>
            local id = bodyScope:addVariable()
            local strs = { "init", "ready", "done", "ok", "check", "run", "exec" }
            table.insert(stmts, Ast.LocalVariableDeclaration(
                bodyScope, { id },
                { Ast.StringExpression(strs[math.random(#strs)]) }
            ))
        else
            -- local _v = true/false
            local id = bodyScope:addVariable()
            table.insert(stmts, Ast.LocalVariableDeclaration(
                bodyScope, { id },
                { Ast.BooleanExpression(math.random(2) == 1) }
            ))
        end
    end

    return Ast.Block(stmts, bodyScope)
end

-- Statement kinds that are safe to inject after (not control-flow terminators)
local SAFE_AFTER = {
    [AstKind.LocalVariableDeclaration]    = true,
    [AstKind.AssignmentStatement]         = true,
    [AstKind.FunctionCallStatement]       = true,
    [AstKind.PassSelfFunctionCallStatement] = true,
    [AstKind.IfStatement]                 = true,
    [AstKind.WhileStatement]              = true,
    [AstKind.ForStatement]                = true,
    [AstKind.ForInStatement]              = true,
    [AstKind.RepeatStatement]             = true,
    [AstKind.NopStatement]                = true,
}

function DeadCode:apply(ast, pipeline)
    local prob = self.probability

    visitast(ast, nil, function(node, data)
        if not SAFE_AFTER[node.kind] then return end
        if math.random() >= prob then return end

        local pred = FALSE_PREDS[math.random(#FALSE_PREDS)]()
        local body = makeDeadBody(data.scope)
        local deadIf = Ast.IfStatement(pred, body, {}, nil)

        -- Return both the original statement and the dead block after it
        return node, deadIf
    end)

    return ast
end

return DeadCode
