--
-- NumbersToExpressions.lua
--
-- Catph V1.0.0 — converts Number Literals to obfuscated expressions.
-- All generated constants are emitted as hex by the unparser automatically.
-- Techniques:
--   1. Addition:        val2 + (val - val2)          where val2 is random
--   2. Subtraction:     (val + val2) - val2
--   3. Mul/Div cancel:  (val * K) / K                for safe range
--   4. Mixed sum:       (val + K) - K                chained
--   5. Zero-product:    (((A ^ B) + C) * 0) + val    Luraph-style
--      Makes static folding require full evaluation of A^B+C sub-tree.
--
unpack = unpack or table.unpack;

local Step = require("catph.step");
local Ast = require("catph.ast");
local Scope = require("catph.scope");
local visitast = require("catph.visitast");
local util     = require("catph.util")

local AstKind = Ast.AstKind;

local NumbersToExpressions = Step:extend();
NumbersToExpressions.Description = "Converts number literals to Luraph-style hex obfuscated expressions (Catph V1.0.0)";
NumbersToExpressions.Name = "Numbers To Expressions";

NumbersToExpressions.SettingsDescriptor = {
    Treshold = {
        type = "number",
        default = 1,
        min = 0,
        max = 1,
    },
    InternalTreshold = {
        type = "number",
        default = 0.15,
        min = 0,
        max = 0.8,
    }
}

function NumbersToExpressions:init(settings)
    self.ExpressionGenerators = {
        -- Addition: val2 + diff
        function(val, depth)
            local val2 = math.random(-2^16, 2^16);
            local diff = val - val2;
            if tonumber(tostring(diff)) + tonumber(tostring(val2)) ~= val then
                return false;
            end
            return Ast.AddExpression(self:CreateNumberExpression(val2, depth), self:CreateNumberExpression(diff, depth), false);
        end,
        -- Subtraction: sum - val2
        function(val, depth)
            local val2 = math.random(-2^16, 2^16);
            local diff = val + val2;
            if tonumber(tostring(diff)) - tonumber(tostring(val2)) ~= val then
                return false;
            end
            return Ast.SubExpression(self:CreateNumberExpression(diff, depth), self:CreateNumberExpression(val2, depth), false);
        end,
        -- Mul/div cancel: (val * K) / K
        function(val, depth)
            if val ~= val or val == 0 then return false end
            local factor = math.random(2, 16);
            local mul = val * factor;
            if mul ~= mul or math.abs(mul) > 2^44 then return false end
            if tonumber(tostring(mul)) / tonumber(tostring(factor)) ~= val then
                return false;
            end
            return Ast.DivExpression(self:CreateNumberExpression(mul, depth), self:CreateNumberExpression(factor, depth), false);
        end,
        -- Mixed: (val + K) - K
        function(val, depth)
            local k = math.random(-2^16, 2^16);
            local sum = val + k;
            if tonumber(tostring(sum)) - tonumber(tostring(k)) ~= val then
                return false;
            end
            return Ast.SubExpression(self:CreateNumberExpression(sum, depth), self:CreateNumberExpression(k, depth), false);
        end,
        -- Zero-product Luraph-style: (((A ^ B) + C) * 0) + val
        -- ^ is exponentiation in Lua — produces a large float that then gets
        -- multiplied by 0, leaving just val. Only at depth 0 to avoid blowup.
        function(val, depth)
            if depth > 0 then return false end
            local A = math.random(100, 0xFFFF)
            local B = math.random(2, 10)   -- small exponent
            local C = math.random(1, 0xFFFF)
            -- (A ^ B) via PowExpression
            local powExpr = Ast.PowExpression(Ast.NumberExpression(A), Ast.NumberExpression(B))
            local addC    = Ast.AddExpression(powExpr, Ast.NumberExpression(C))
            local mulZero = Ast.MulExpression(addC, Ast.NumberExpression(0))
            return Ast.AddExpression(mulZero, Ast.NumberExpression(val))
        end,
    }
end

function NumbersToExpressions:CreateNumberExpression(val, depth)
    if depth > 0 and math.random() >= self.InternalTreshold or depth > 12 then
        return Ast.NumberExpression(val)
    end

    local generators = util.shuffle({unpack(self.ExpressionGenerators)});
    for i, generator in ipairs(generators) do
        local node = generator(val, depth + 1);
        if node then
            return node;
        end
    end

    return Ast.NumberExpression(val)
end

function NumbersToExpressions:apply(ast)
    visitast(ast, nil, function(node, data)
        if node.kind == AstKind.NumberExpression then
            if math.random() <= self.Treshold then
                return self:CreateNumberExpression(node.value, 0);
            end
        end
    end)
end

return NumbersToExpressions;
