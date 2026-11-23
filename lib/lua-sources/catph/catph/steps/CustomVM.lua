--
-- steps/CustomVM.lua
--


local Step      = require("catph.step")
local Parser    = require("catph.parser")
local Unparser  = require("catph.unparser")
local Enums     = require("catph.enums")
local Compiler  = require("catph.customvm.compiler")
local CvmEmit   = require("catph.customvm.emit")
local logger    = require("logger")

local CustomVM = Step:extend()
CustomVM.Name = "CustomVM"
CustomVM.Description = "Compiles AST to custom bytecode with per-build encryption and emits a self-contained VM interpreter."

CustomVM.SettingsDescriptor = {
    Renumber = {
        type = "boolean",
        default = true,
        description = "Per-build opcode permutation (defeats static analysis of the bytecode format).",
    },
    StreamCipher = {
        type = "boolean",
        default = true,
        description = "Position-dependent additive cipher over the serialized proto region.",
    },
    EncryptStrings = {
        type = "boolean",
        default = true,
        description = "Per-string cipher with per-string salt derived from a build nonce.",
    },
    Nonce = {
        type = "number",
        default = 0,
        description = "Fixed nonce for reproducible builds. 0 means random per build.",
    },
    Flatten = {
        type = "boolean",
        default = true,
        description = "Enable bytecode-level control flow flattening.",
    },
    MicroOps = {
        type = "boolean",
        default = true,
        description = "Split arithmetic ops into multi-instruction sequences.",
    },
    FlattenIntensity = {
        type = "enum",
        default = "high",
        values = { "low", "medium", "high", "max" },
        description = "CFF intensity: low (1 dispatcher, no fakes), medium, high, max (4 dispatchers, 7 fake blocks).",
    },
    FlattenMinBlocks = {
        type = "number",
        default = 3,
        min = 2,
        max = 20,
        description = "Minimum basic blocks required to apply CFF (smaller functions are skipped).",
    },
    FlattenChance = {
        type = "number",
        default = 1.0,
        min = 0,
        max = 1,
        description = "Probability (0-1) that each eligible function gets flattened.",
    },
    JunkLevel = {
        type = "number",
        default = 2,
        min = 0,
        max = 3,
        description = "Dead-code junk density inside the runtime VM: 0=none, 1=light, 2=normal, 3=heavy.",
    },
    Compress = {
        type = "boolean",
        default = true,
        description = "LZ-compress + B85-encode the VM source before embedding. Set false to skip compression.",
    },
}

function CustomVM:init(settings) end

function CustomVM:apply(ast, pipeline)
    -- 1. Compile the AST to our custom proto format.
    logger:info("CustomVM: compiling AST to custom bytecode ...")
    local proto = Compiler.compile(ast)

    -- 2. Build serializer options from step settings.
    local opts = {
        renumber       = self.Renumber,
        streamCipher   = self.StreamCipher,
        encryptStrings = self.EncryptStrings,
        flatten        = self.Flatten,
        flattenIntensity = self.FlattenIntensity,
        flattenMinBlocks = self.FlattenMinBlocks,
        flattenChance    = self.FlattenChance,
        microOps         = self.MicroOps,
        junkLevel        = self.JunkLevel,
        compress         = self.Compress,
    }
    if self.Nonce > 0 then
        opts.nonce = self.Nonce
    end

    -- 3. Emit the self-contained Lua source (deserializer + VM + encrypted payload).
    logger:info("CustomVM: emitting encrypted payload + runtime VM ...")
    local code = CvmEmit.build(proto, opts)

    logger:info(string.format("CustomVM: emitted %d bytes of self-contained VM code.", #code))

    -- 4. Parse the emitted code back into an AST for the rest of the pipeline.
    local newAst = Parser:new({ LuaVersion = Enums.LuaVersion.LuaU }):parse(code)
    return newAst
end

return CustomVM
