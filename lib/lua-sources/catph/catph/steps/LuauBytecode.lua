--
-- LuauBytecode.lua
--
-- Compiles the program to real Luau bytecode (via luau-compile), then replaces
-- it with a custom bytecode interpreter + the (opcode-remapped) bytecode data.
-- The result is plain Luau source, so the remaining pipeline steps
-- (EncryptStrings, Vmify, ConstantArray, ...) obfuscate it on top.
--
-- Requires `luau-compile` available at build time (set CompilerPath).

local Step      = require("catph.step");
local Parser    = require("catph.parser");
local Unparser  = require("catph.unparser");
local Enums     = require("catph.enums");
local Reader    = require("catph.luauc.reader");
local Remap     = require("catph.luauc.remap");
local Emit      = require("catph.luauc.emit");
local Interpgen = require("catph.luauc.interpgen");
local visitast  = require("catph.visitast");
local Ast       = require("catph.ast");
local logger    = require("logger");

local AstKind = Ast.AstKind;

local LuauBytecode = Step:extend();
LuauBytecode.Name = "Luau Bytecode";
LuauBytecode.Description = "Compiles to real Luau bytecode and emits a custom interpreter with remapped opcodes.";

LuauBytecode.SettingsDescriptor = {
    CompilerPath = {
        type = "string",
        default = "luau-compile",
        description = "Path to the luau-compile executable.",
    },
    OptLevel = {
        type = "number",
        default = 1,
        min = 0,
        max = 2,
        description = "luau-compile optimization level (-O).",
    },
    Remap = {
        type = "boolean",
        default = true,
        description = "Per-build opcode remapping (defeats standard Luau bytecode tooling).",
    },
    EncryptBytecode = {
        type = "boolean",
        default = true,
        description = "Encrypt the instruction stream with a per-build position key.",
    },
    B85 = {
        type = "boolean",
        default = true,
        description = "Emit the instruction stream as base85 text instead of a number array.",
    },
    PolymorphicVM = {
        type = "boolean",
        default = false,
        description = "Per-build polymorphic interpreter: regenerate the dispatch structure/handlers so two builds with identical semantics yield structurally different interpreters.",
    },
    VMStyle = {
        type = "enum",
        default = "random",
        values = { "random", "ifelse", "split", "table" },
        description = "Dispatch style for PolymorphicVM. \"random\" picks one per build.",
    },
    VMRegisterRemap = {
        type = "boolean",
        default = false,
        description = "State-layout remap: shift the interpreter's register indices by a per-build offset (requires PolymorphicVM).",
    },
    VMConstRemap = {
        type = "boolean",
        default = false,
        description = "Constant-table relocation: pad the constants array and shift the interpreter's constant indices by a per-build offset (requires PolymorphicVM).",
    },
    VMContainerSchema = {
        type = "enum",
        default = "legacy",
        values = { "legacy", "derived", "random" },
        description = "Bytecode-container schema. \"derived\" (S1) stores only a nonce and derives opmap/bkey/bstep at runtime (requires PolymorphicVM + Remap + EncryptBytecode). \"random\" picks per build.",
    },
}

-- The obfuscator's unparser lowers operators (and/or/comparisons/if/while/...)
-- The unparser now emits native operators (and/or/not/# etc) directly,
-- so no _2zvh* helper locals are needed. The prologue is empty.
local HELPER_PROLOGUE = "";

function LuauBytecode:init(settings) end

-- Locate this step's directory so we can read the sibling interpreter source.
local function interpSourcePath()
    local src = debug.getinfo(1, "S").source:sub(2)        -- .../steps/LuauBytecode.lua
    local dir = src:match("(.*[/\\])") or "./"
    return dir .. "../luauc/interp.lua"
end

local function readFile(path, mode)
    local f = assert(io.open(path, mode or "r"), "LuauBytecode: cannot open " .. path);
    local data = f:read("*a"); f:close(); return data;
end

function LuauBytecode:apply(ast, pipeline)
    -- ── FUS_NO_VIRTUALIZE extraction ─────────────────────────────────────────
    -- Walk the AST and find all FunctionLiteralExpression nodes tagged with
    -- __fus_no_virt = true (set by MacroExpand). Replace each with a unique
    -- global variable reference (__FUS_NV_0, __FUS_NV_1, ...) so the VM only
    -- sees the placeholder. After building the VM source we prepend the actual
    -- function definitions as plain Lua locals so they appear unvirtualized in
    -- the final output.
    local nvFuncs = {}   -- { varName, unparsedSource }
    local nvCount = 0
    local nvUnparser = Unparser:new({ LuaVersion = Enums.LuaVersion.LuaU })

    -- String literal obfuscator for no-virt function sources.
    -- Encodes each character in quoted strings as a random mix of
    -- \DDD, \xHH, \u{H} escapes — same visual style as Luraph.
    local function obfuscateNvStrings(src)
        local function encChar(c)
            -- \u{...} removed — too recognisable; keep \DDD, \xHH, or raw char
            local b = string.byte(c)
            local r = math.random(3)
            if     r == 1 then return string.format("\\%d",    b)
            elseif r == 2 then return string.format("\\x%02x", b)
            else               return c
            end
        end
        local out, i, n = {}, 1, #src
        while i <= n do
            local c = src:sub(i, i)
            if c == '"' or c == "'" then
                local q = c; out[#out+1] = q; i = i + 1
                while i <= n do
                    local sc = src:sub(i, i)
                    if sc == '\\' then
                        out[#out+1] = src:sub(i, i+1); i = i + 2
                    elseif sc == q then
                        out[#out+1] = q; i = i + 1; break
                    else
                        out[#out+1] = encChar(sc); i = i + 1
                    end
                end
            else
                out[#out+1] = c; i = i + 1
            end
        end
        return table.concat(out)
    end

    visitast(ast, nil, function(node, data)
        if node.kind == AstKind.FunctionLiteralExpression and node.__fus_no_virt then
            nvCount = nvCount + 1
            local varName = "__FUS_NV_" .. nvCount .. "__"
            local fullSrc = obfuscateNvStrings(nvUnparser:unparseExpression(node))
            nvFuncs[nvCount] = { name = varName, src = fullSrc }
            local gScope, gId = data.scope:resolve(varName)
            return Ast.VariableExpression(gScope, gId)
        end
    end)

    -- 1. Unparse the current AST back to source for the external compiler.
    local unparser = Unparser:new({ LuaVersion = Enums.LuaVersion.LuaU });
    local source = HELPER_PROLOGUE .. unparser:unparse(ast);

    -- 2. Compile to Luau bytecode via luau-compile.
    local tag = tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9));
    local inPath = "_luaubc_" .. tag .. ".luau";
    local outPath = "_luaubc_" .. tag .. ".luauc";
    do
        local f = assert(io.open(inPath, "w")); f:write(source); f:close();
    end
    local cmd = string.format('"%s" --binary -O%d -g0 "%s" > "%s"',
        self.CompilerPath, self.OptLevel, inPath, outPath);
    -- On Windows, cmd /c strips the outer quotes when a command both starts and
    -- ends with a quote; wrap the whole command in an extra pair to be safe.
    if package.config:sub(1, 1) == "\\" then cmd = '"' .. cmd .. '"'; end
    local ok = os.execute(cmd);
    local blob = readFile(outPath, "rb");
    os.remove(inPath); os.remove(outPath);
    if not blob or #blob == 0 then
        logger:error("LuauBytecode: luau-compile produced no output (is CompilerPath correct?)");
    end
    if string.byte(blob, 1) == 0 then
        logger:error("LuauBytecode: compilation error: " .. blob:sub(2));
    end

    -- 3. Parse + (optionally) remap opcodes.
    local bc = Reader.parse(blob);

    -- 3a. Rename __FUS_NV_N__ placeholders to short random identifiers in-place
    --     inside the bytecode constant tables, before serialization.
    --     This means the final output uses clean short names everywhere —
    --     in the bytecode, in the dispatch table entry, and in the env setup.
    if nvCount > 0 then
        -- Build short-name map: "__FUS_NV_1__" -> "xYz", etc.
        local LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        local ALNUM   = LETTERS .. "0123456789"
        local usedNV  = {}
        local function nvName()
            local name
            repeat
                local idx = math.random(1, #LETTERS)
                local s = LETTERS:sub(idx, idx)
                for _ = 2, math.random(3, 6) do
                    local k = math.random(1, #ALNUM)
                    s = s .. ALNUM:sub(k, k)
                end
                name = s
            until not usedNV[name]
            usedNV[name] = true
            return name
        end

        local nvRename = {}  -- old name -> new short name
        for i = 1, nvCount do
            nvRename["__FUS_NV_" .. i .. "__"] = nvName()
        end

        -- Walk every proto and patch matching string constants.
        local function patchProto(p)
            for _, k in ipairs(p.k) do
                if k.tag == "string" and k.value and nvRename[k.value] then
                    k.value = nvRename[k.value]
                end
            end
            for _, child in ipairs(p.protos or {}) do
                patchProto(child)
            end
        end
        for _, p in ipairs(bc.protos) do
            patchProto(p)
        end

        -- Update nvFuncs entries with the new short names.
        for i = 1, nvCount do
            nvFuncs[i].name = nvRename["__FUS_NV_" .. i .. "__"]
        end
    end

    -- Resolve the container schema. Schema "derived" (S1) stores only a nonce and
    -- has the polymorphic interpreter derive the opcode inverse-map and the
    -- encryption keys at runtime, so they are NOT serialized at fixed positions.
    -- It needs both Remap and EncryptBytecode (it produces both); otherwise we
    -- fall back to legacy.
    local schema = "legacy";
    if self.PolymorphicVM then
        local s = self.VMContainerSchema;
        if s == "random" then s = ({ "legacy", "derived" })[math.random(1, 2)]; end
        if s == "derived" and self.Remap and self.EncryptBytecode then schema = "derived"; end
    end

    if schema == "derived" then
        local nonce = math.random(0, 65535) * 65536 + math.random(0, 65535);
        if nonce == 0 then nonce = 1; end
        Remap.applyWithPerm(bc, Remap.derivePerm(nonce));
        local bkey, bstep = Remap.deriveKeys(nonce);
        Remap.encryptCodeWithKeys(bc, bkey, bstep);
        -- Expose the derived keys to emit (for constant encryption). These are
        -- NOT serialized: emit takes the nonce branch and writes only bc.nonce,
        -- and the interpreter re-derives identical keys from the nonce at load.
        bc.bkey = bkey;
        bc.bstep = bstep;
        bc.nonce = nonce;
    else
        if self.Remap then Remap.apply(bc); end
        if self.EncryptBytecode then Remap.encryptCode(bc); end
    end
    bc.b85 = self.B85 and true or nil;

    -- 4. Emit interpreter + data as Luau source (env = getfenv() at runtime).
    local interpSrc = readFile(interpSourcePath(), "r");
    local koff = 0;
    if self.PolymorphicVM then
        local generated, style, off, k = Interpgen.generate(interpSrc, {
            Style = self.VMStyle,
            RegisterRemap = self.VMRegisterRemap,
            ConstRemap = self.VMConstRemap,
            Derive = (schema == "derived"),
        });
        interpSrc = generated;
        koff = k or 0;
        logger:info(string.format(
            "LuauBytecode: polymorphic VM enabled (dispatch style: %s, register offset: %s, const offset: %s, container: %s).",
            style, off ~= 0 and tostring(off) or "none", koff ~= 0 and tostring(koff) or "none", schema));
    end
    local code = Emit.build(bc, interpSrc, nil, koff);

    -- 5. Store no-virt function sources on the pipeline so cli.lua can prepend
    --    them AFTER all steps (including EnhancedVmCompression) have run.
    --    They must appear outside the compressed blob so they're visible as
    --    plain Lua in the final output file.
    if nvCount > 0 then
        if not pipeline._nvFuncs then pipeline._nvFuncs = {} end
        for i = 1, nvCount do
            pipeline._nvFuncs[#pipeline._nvFuncs + 1] = nvFuncs[i]
        end
        if nvCount == 1 then
            logger:info("LuauBytecode: 1 FUS_NO_VIRTUALIZE function extracted (will be emitted as plain Lua outside the VM).")
        else
            logger:info(string.format("LuauBytecode: %d FUS_NO_VIRTUALIZE functions extracted (will be emitted as plain Lua outside the VM).", nvCount))
        end
    end

    -- 6. Parse the generated program back into an AST for the rest of the pipeline.
    local newAst = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 }):parse(code);
    return newAst;
end

return LuauBytecode;
