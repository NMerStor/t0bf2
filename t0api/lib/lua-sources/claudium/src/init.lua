-- Claudium v2.5.4 - Main module loader

local Claudium = {
    version = "2.5.4",
    name = "Claudium",
}

local function addPath()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("^@(.*/)") or "./"
    package.path = path .. "?.lua;" .. path .. "?/init.lua;" .. package.path
end
addPath()

Claudium.Token       = require("src.Lexer.Token")
Claudium.Lexer       = require("src.Lexer.Lexer")
Claudium.Nodes       = require("src.AST.Nodes")
Claudium.Printer     = require("src.AST.Printer")
Claudium.Parser      = require("src.Parser.Parser")
Claudium.Scope       = require("src.Obfuscation.Rename.Scope")
Claudium.Renamer     = require("src.Obfuscation.Rename.Renamer")
Claudium.Minifier    = require("src.Obfuscation.Minify.Minifier")
Claudium.Flattener   = require("src.Obfuscation.ControlFlow.Flattener")
Claudium.IR          = require("src.IR.IR")
Claudium.IRCompiler  = require("src.IR.Compiler")
Claudium.Presets     = require("src.Presets.Presets")
Claudium.Encoder     = require("src.VM.Encoder.Encoder")
Claudium.VMGenerator = require("src.VM.Generator.Generator")

function Claudium.parse(source, options)
    options = options or {}
    local lexer = Claudium.Lexer.new(source, options)
    local tokens = lexer:tokenize()
    local parser = Claudium.Parser.new(tokens, options)
    local ast, errors = parser:parse()
    return {
        ast = ast,
        tokens = tokens,
        errors = errors or {},
        lexerErrors = lexer.errors or {},
    }
end

function Claudium.printAst(ast, options)
    local printer = Claudium.Printer.new(options)
    return printer:print(ast)
end

function Claudium.rename(ast, options)
    local renamer = Claudium.Renamer.new(options or {})
    return renamer:run(ast, options)
end

function Claudium.minify(ast, options)
    local minifier = Claudium.Minifier.new(options or {})
    return minifier:minify(ast)
end

function Claudium.controlFlow(ast, options)
    local flattener = Claudium.Flattener.new(options or {})
    return flattener:run(ast)
end


function Claudium.compileIR(ast, options)
    local comp = Claudium.IRCompiler.new(options or {})
    return comp:compile(ast)
end

function Claudium.encodeBytecode(module, options)
    local enc = Claudium.Encoder.new(options or {})
    return enc:encode(module)
end

function Claudium.generateVM(bytecode, options)
    local gen = Claudium.VMGenerator.new(options or {})
    return gen:generate(bytecode)
end

--- High-level pipeline
-- Order: parse → [CF] → rename → [VM path: IR→bytecode→VM] or [minify]
function Claudium.obfuscate(source, options)
    options = options or {}

    if options.preset then
        local preset = Claudium.Presets.get(options.preset)
        for k, v in pairs(preset) do
            if options[k] == nil then
                options[k] = v
            end
        end
    end
    if options.controlFlow == nil then options.controlFlow = false end
    if options.vm == nil then options.vm = false end

    -- Anti-tamper is emitted by the VM generator after compilation.
    -- Do not prepend probe source here: compiling a large probe program together
    -- with user code changes register pressure and used to corrupt live locals.

    local result = Claudium.parse(source, options)
    if #result.errors > 0 then
        return nil, result.errors
    end
    local ast = result.ast

    -- Control-flow on AST (useful even before VM as extra layer)
    if options.controlFlow and not options.vm then
        -- when VM is on, CF on AST can confuse IR; apply CF only for non-VM path
        Claudium.controlFlow(ast, {
            intensity     = options.intensity or 1.0,
            minStatements = options.minStatements or 2,
            junkStates    = options.junkStates ~= false,
            stateName     = options.stateName or "__s",
        })
    end

    if options.rename ~= false then
        Claudium.rename(ast, options)
    end

    -- VM path: AST → IR → bytecode → self-contained loader
    if options.vm then
        local mod = Claudium.compileIR(ast, options)
        local bc = Claudium.encodeBytecode(mod, {
            encryptConstants = options.encryptConstants ~= false,
            xorKey = options.xorKey or (0x41 + (os.time() % 50)),
        })
        local out = Claudium.generateVM(bc, {
            minify = options.minify ~= false,
            singleLine = options.singleLine ~= false,
            target = options.target or "executor",
            antiTamper = options.antiTamper ~= false,
            scrambleOps = options.scrambleOps ~= false,
            encryptStrings = options.encryptStrings ~= false,
            seed = options.seed,
            intensity = options.intensity or 1,
            fatVM = options.fatVM ~= false,
            rollingXor = options.rollingXor ~= false,
            base85 = options.base85 ~= false,
            opaqueKeys = options.opaqueKeys ~= false,
            superOps = options.superOps ~= false,
        })
        return out, nil
    end

    local output
    if options.minify ~= false then
        output = Claudium.minify(ast, {
            singleLine = options.singleLine ~= false,
        })
    else
        output = Claudium.printAst(ast, options)
    end

    return output, nil
end

return Claudium
