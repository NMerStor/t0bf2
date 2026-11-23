--
-- OpaquePredicates.lua
--
-- Wraps existing if-statement conditions with an always-true opaque predicate
-- so the condition looks more complex without changing behavior:
--
--   if x > 0 then          if (x > 0) and (N * N >= 0) then
--   ...              →     ...
--   end                    end
--
-- Also wraps while-loop conditions the same way.
-- Does NOT inject dead branches here — see DeadCode.lua for that.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local OpaquePredicates = Step:extend()
OpaquePredicates.Name        = "OpaquePredicates"
OpaquePredicates.Description = "Wraps if/while conditions with always-true opaque predicates."
OpaquePredicates.SettingsDescriptor = {
    Probability = {
        name        = "Probability",
        description = "Chance (0–1) that any given condition gets wrapped.",
        type        = "number",
        default     = 0.85,
    },
}

function OpaquePredicates:init(settings)
    self.probability = (settings and settings.Probability) or 0.85
end

-- Returns a compound expression that is ALWAYS TRUE:
--   (N * N >= 0)  where N is a random integer literal
local function opaqueTrue()
    local n = math.random(2, 99)
    return Ast.GreaterThanOrEqualsExpression(
        Ast.MulExpression(Ast.NumberExpression(n), Ast.NumberExpression(n)),
        Ast.NumberExpression(0)
    )
end

-- Alternate always-true: (type("") == "string")  — uses a different pattern
local function opaqueTrue2()
    return Ast.EqualsExpression(
        Ast.StringExpression("string"),
        Ast.StringExpression("string")
    )
end

local PREDICATES = { opaqueTrue, opaqueTrue2 }

function OpaquePredicates:apply(ast, pipeline)
    local prob = self.probability

    visitast(ast, function(node, data)
        -- Wrap IfStatement condition
        if node.kind == AstKind.IfStatement then
            if math.random() < prob then
                local pred = PREDICATES[math.random(#PREDICATES)]()
                node.condition = Ast.AndExpression(node.condition, pred)
            end
            -- Also wrap elseif conditions
            if node.elseifs then
                for _, elseif_ in ipairs(node.elseifs) do
                    if math.random() < prob then
                        local pred = PREDICATES[math.random(#PREDICATES)]()
                        elseif_.condition = Ast.AndExpression(elseif_.condition, pred)
                    end
                end
            end

        -- Wrap WhileStatement condition
        elseif node.kind == AstKind.WhileStatement then
            if math.random() < prob then
                local pred = PREDICATES[math.random(#PREDICATES)]()
                node.condition = Ast.AndExpression(node.condition, pred)
            end
        end
    end, nil)

    return ast
end

return OpaquePredicates
