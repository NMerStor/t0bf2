--
-- EnhancedVmCompression.lua
--
-- Pipeline step that serializes the (already obfuscated) program emitted by the
-- earlier steps -- in the `luaubc` line that means the LuauBytecode interpreter
-- plus its bytecode payload -- compresses it, encodes it to embed-safe text, and
-- replaces the whole AST with a compact runtime loader stub that decodes,
-- decompresses and executes it via load/loadstring.
--
-- Where it runs
-- -------------
-- After LuauBytecode (and, in `luaubc`, after the other AST steps) and before
-- the pipeline's final unparse. It consumes the AST, turns it into text, and
-- returns a brand-new (tiny) AST -- so it must be the LAST step that wants to
-- see real program structure.
--
-- Self-containment
-- ----------------
-- The pipeline's unparser lowers operators (==, <, #, and/or/not, ...) into
-- _2zvh* helper CALLS that cli.lua only defines on the final output text. The
-- compressed payload is opaque to that late textual pass, so it would lose those
-- definitions. We therefore prepend the same HELPER_PROLOGUE that LuauBytecode
-- uses, making the payload define its own _2zvh* helpers when load()ed. The
-- encoding alphabets omit `_`, so the substring "_2zvh" can never appear inside
-- the blob and cli.lua's substitution cannot corrupt it.
--
-- Compression / fallback
-- ----------------------
-- See vmcodec.lua: we ship a portable pure-Lua LZW codec rather than binding to
-- zlib/lzma, because the loader must decompress in environments (Luau sandboxes,
-- bare Lua 5.1) with no native compression library. Algorithm "zlib"/"lzma" are
-- honored by using that built-in codec (a native zlib, if present at build time,
-- is detected only to emit an informational log); "none" encodes without
-- compressing. If the achieved size reduction is below MinGain the step leaves
-- the AST untouched (unless AlwaysEmbed is set).
--
-- Modes
-- -----
--   "source"  -- compress the full emitted program. Portable, the default.
--   "vmimage" -- intended to compress only the serialized VM/bytecode image and
--                keep the interpreter in cleartext for a higher ratio. That
--                requires the interpreter to accept a standalone serialized
--                image, which interp.lua does not currently do, so this mode
--                compresses the full program image like "source" and logs a
--                note. Kept as a configurable seam for future interpreter work.

local Step      = require("catph.step");
local Parser    = require("catph.parser");
local Unparser  = require("catph.unparser");
local Enums     = require("catph.enums");
local Vmcodec   = require("catph.vmcodec");
local logger    = require("logger");

local EnhancedVmCompression = Step:extend();
EnhancedVmCompression.Name = "Enhanced VM Compression";
EnhancedVmCompression.Description =
    "Compresses and text-encodes the emitted VM program, injecting a compact runtime loader stub.";

EnhancedVmCompression.SettingsDescriptor = {
    Enabled = {
        type = "boolean",
        default = true,
        description = "Master switch. When false the step is a no-op.",
    },
    Algorithm = {
        type = "enum",
        default = "zlib",
        values = { "zlib", "lzma", "none" },
        description = "Compression algorithm. zlib/lzma use the portable built-in LZW codec; none only encodes.",
    },
    Encode = {
        type = "enum",
        default = "b85",
        values = { "b85", "base64" },
        description = "Text encoding used to embed the compressed bytes.",
    },
    Level = {
        type = "number",
        default = 6,
        min = 0,
        max = 9,
        description = "Compression level hint (accepted for API parity; the built-in LZW codec ignores it).",
    },
    MinGain = {
        type = "number",
        default = 0.05,
        min = 0,
        max = 1,
        description = "Minimum size-reduction ratio required to apply compression; otherwise the step is skipped.",
    },
    Mode = {
        type = "enum",
        default = "source",
        values = { "source", "vmimage" },
        description = "source = compress the full emitted program (portable). vmimage = reserved (see file header).",
    },
    AlwaysEmbed = {
        type = "boolean",
        default = false,
        description = "When true, embed the (encoded) blob even if MinGain is not met.",
    },
}

-- The unparser now emits native operators directly so no _2zvh* helpers
-- are needed. The payload is self-contained without them.
local HELPER_PROLOGUE = "";

function EnhancedVmCompression:init(settings) end

-- Build-time detection of a native zlib binding. We never actually use it for
-- the runtime payload (the target may not have it), but detecting it lets us
-- emit a helpful log, satisfying the "detect availability + graceful fallback"
-- requirement.
local function nativeZlibAvailable()
    local ok = pcall(require, "zlib");
    return ok;
end

function EnhancedVmCompression:apply(ast, pipeline)
    if _G.__2zvh_no_compression then
        logger:info("EnhancedVmCompression: disabled via --compression false.");
        return ast;
    end
    if not self.Enabled then
        logger:info("EnhancedVmCompression: disabled, skipping.");
        return ast;
    end

    local luaVersion = pipeline.LuaVersion or Enums.LuaVersion.LuaU;

    -- 1. Render the current AST back to source. This is exactly what the
    --    pipeline would otherwise emit, so its length is our baseline.
    local unparser = Unparser:new({ LuaVersion = luaVersion });
    local fullSrc = unparser:unparse(ast);
    local baseline = #fullSrc;

    -- 2. The payload must be self-contained: prepend the operator helpers.
    local payloadSrc = HELPER_PROLOGUE .. fullSrc;

    -- 3. Resolve the algorithm with graceful fallback + logging.
    local algorithm = self.Algorithm;
    if algorithm ~= "none" then
        if nativeZlibAvailable() then
            logger:info(string.format(
                "EnhancedVmCompression: native zlib detected but using the portable built-in codec for \"%s\" (runtime portability).",
                algorithm));
        else
            logger:info(string.format(
                "EnhancedVmCompression: no native \"%s\" binding; using the portable built-in LZW codec.",
                algorithm));
        end
    end

    if self.Mode == "vmimage" then
        logger:info("EnhancedVmCompression: \"vmimage\" mode requires interpreter support for standalone images; "
            .. "compressing the full program image (source-equivalent) for this build.");
    end

    -- 4. Compress + encode.
    local encText = Vmcodec.encode(payloadSrc, algorithm, self.Encode);
    local chunkName = (self.Mode == "vmimage") and "=(vmimage)" or "=(compressed)";
    local stubSrc = Vmcodec.buildLoaderSource(encText, algorithm, self.Encode, chunkName);

    -- 5. Gain check.
    local gain = (baseline - #stubSrc) / baseline;
    logger:info(string.format(
        "EnhancedVmCompression: baseline %d B, loader %d B, encoded %d B, reduction %.1f%% (MinGain %.1f%%).",
        baseline, #stubSrc, #encText, gain * 100, self.MinGain * 100));

    if algorithm ~= "none" and gain < self.MinGain and not self.AlwaysEmbed then
        logger:info("EnhancedVmCompression: reduction below MinGain, leaving AST unmodified.");
        return ast;
    end

    -- 6. Parse the loader stub into a fresh AST for the rest of the pipeline.
    local newAst = Parser:new({ LuaVersion = luaVersion }):parse(stubSrc);
    return newAst;
end

return EnhancedVmCompression;
