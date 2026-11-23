--
-- AntiDumpConstants.lua
--
-- Strong anti-dump constant protection step (Catph V1.0.0).
-- Replaces integer literals with runtime-computed expressions that a static
-- memory dump cannot recover.  Three Luraph-style techniques:
--
--   1. Zero-product shield:  (((A ^ B) + C) * 0) + val
--      A, B, C are random 16-bit integers. A^B+C is computed at runtime;
--      multiply by 0 collapses it, then + val gives the real value. A static
--      analyser must evaluate the entire sub-tree to fold this.
--
--   2. Arithmetic split:     (val + K) - K
--      Classic but still effective; K is a random 16-bit integer.
--
--   3. Modular recovery:     ((val + M) % R) + (val - ((val + M) % R))
--      M = random 1..R-1, R = random prime ≥ val+2. Returns val at runtime.
--
-- All emitted number literals are formatted as hex (0xNN) by the unparser.
-- The combination of methods makes pattern-based constant recovery non-trivial.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local Scope    = require("catph.scope")
local visitast = require("catph.visitast")
local util     = require("catph.util")

local AstKind = Ast.AstKind

local AntiDumpConstants = Step:extend()
AntiDumpConstants.Name        = "AntiDumpConstants"
AntiDumpConstants.Description = "Replaces integer constants with runtime-computed hex expressions to defeat memory dumps (Catph-style)."

AntiDumpConstants.SettingsDescriptor = {
    Probability = {
        name    = "Probability",
        description = "Chance (0–1) that a given number literal is protected.",
        type    = "number",
        default = 0.80,
    },
    MaxValue = {
        name    = "MaxValue",
        description = "Only protect integers in [0, MaxValue].",
        type    = "number",
        default = 8191,
    },
}

function AntiDumpConstants:init(settings)
    self.probability = (settings and settings.Probability) or 0.80
    self.maxValue    = (settings and settings.MaxValue)    or 8191
end

local function numNode(val)
    return Ast.NumberExpression(val)
end

-- Technique 1: (((A ^ B) + C) * 0) + val
-- Zero-product: entire A^B+C collapses to 0, leaves just val.
-- ^ is PowExpression in Lua (exponentiation), so this is a float expression
-- that a constant folder must evaluate. The * 0 collapses everything.
local function zeroProduct(val)
    local A = math.random(100, 0xFFFF)
    local B = math.random(2, 12)     -- small exponent keeps the float manageable
    local C = math.random(1, 0xFFFF)
    -- (A ^ B)  — emits A^B (exponentiation), produces a large float at runtime
    local powExpr = Ast.PowExpression(numNode(A), numNode(B))
    -- (pow + C)
    local addC = Ast.AddExpression(powExpr, numNode(C))
    -- ((pow + C) * 0)
    local mulZero = Ast.MulExpression(addC, numNode(0))
    -- (mulZero + val)
    return Ast.AddExpression(mulZero, numNode(val))
end

-- Technique 2: (val + K) - K
local function addSubSplit(val)
    local K = math.random(1, 0xFFFF)
    return Ast.SubExpression(
        Ast.AddExpression(numNode(val), numNode(K)),
        numNode(K)
    )
end

-- Technique 3: mixed mul/div cancellation  val*(K+1) / (K+1)
-- Only for non-zero val; K chosen so overflow stays in 32-bit safe range.
local function mulDivCancel(val)
    if val == 0 then return addSubSplit(0) end
    local K = math.random(2, math.min(32, math.floor(0xFFFFFF / (val + 1))))
    if K < 2 then K = 2 end
    return Ast.DivExpression(
        Ast.MulExpression(numNode(val), numNode(K)),
        numNode(K)
    )
end

function AntiDumpConstants:launder(val)
    local choice = math.random(1, 3)
    if choice == 1 then
        return zeroProduct(val)
    elseif choice == 2 then
        return addSubSplit(val)
    else
        return mulDivCancel(val)
    end
end

function AntiDumpConstants:apply(ast, pipeline)
    local prob   = self.probability
    local maxVal = self.maxValue

    visitast(ast, nil, function(node)
        if node.kind ~= AstKind.NumberExpression then return nil end
        local v = node.value
        if type(v) ~= "number" then return nil end
        if v ~= math.floor(v) then return nil end
        if v < 0 or v > maxVal then return nil end
        if math.random() > prob then return nil end
        return self:launder(v)
    end)

    return ast
end

return AntiDumpConstants
