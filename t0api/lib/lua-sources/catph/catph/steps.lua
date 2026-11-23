-- steps.lua
-- Registry of all obfuscation steps.
-- Steps that use Lua 5.3+ syntax (bitwise ~, >>, <<) are wrapped in pcall
-- so they fail gracefully when the obfuscator itself runs on Lua 5.1.

local function safeRequire(mod)
    local ok, result = pcall(require, mod)
    if ok then return result end
    return nil
end

return {
MacroExpand          = require("catph.steps.MacroExpand");
WrapInFunction       = require("catph.steps.WrapInFunction");
SplitStrings         = require("catph.steps.SplitStrings");
Vmify                = require("catph.steps.Vmify");
ConstantArray        = safeRequire("catph.steps.ConstantArray");
ProxifyLocals        = safeRequire("catph.steps.ProxifyLocals");
AntiTamper           = safeRequire("catph.steps.AntiTamper");
EncryptStrings       = safeRequire("catph.steps.EncryptStrings");
NumbersToExpressions = require("catph.steps.NumbersToExpressions");
AddVararg            = safeRequire("catph.steps.AddVararg");
WatermarkCheck       = require("catph.steps.WatermarkCheck");
DummyStep            = require("catph.steps.DummyStep");
LuauBytecode         = safeRequire("catph.steps.LuauBytecode");
EnhancedVmCompression = safeRequire("catph.steps.EnhancedVmCompression");
ControlFlowFlattening = require("catph.steps.ControlFlowFlattening");
CustomVM              = safeRequire("catph.steps.CustomVM");
IronBrew2VM           = safeRequire("catph.steps.IronBrew2VM");
ReturnTable           = require("catph.steps.ReturnTable");
SADOX_INLINE          = safeRequire("catph.steps.SadoxInline");
OpaquePredicates      = require("catph.steps.OpaquePredicates");
DeadCode              = require("catph.steps.DeadCode");
HelperTable           = require("catph.steps.HelperTable");
VariableSplitting     = require("catph.steps.VariableSplitting");
StringXOR             = require("catph.steps.StringXOR");
CatphEncurl           = require("catph.steps.CatphEncurl");
AntiDumpConstants     = require("catph.steps.AntiDumpConstants");
}
