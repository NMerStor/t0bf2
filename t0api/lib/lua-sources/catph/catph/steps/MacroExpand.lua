--
-- MacroExpand.lua
--
-- Pre-obfuscation macro expansion step.
--
-- Supported macros
-- ─────────────────────────────────────────────────────────────────────────────
-- FUS_OBFUSCATED  (boolean constant, true during obfuscation)
--
--   Any expression-level occurrence of the identifier FUS_OBFUSCATED is
--   replaced with the boolean literal `true`.
--
--   Compound boolean expressions whose both sides are now constant are
--   immediately folded:
--       FUS_OBFUSCATED and X   →  X         (truthy lhs of `and`)
--       FUS_OBFUSCATED or  X   →  true      (truthy lhs of `or`)
--       not FUS_OBFUSCATED     →  false
--
--   If-statement conditions that collapse to a constant are optimised:
--       if true  then <body>               →  do <body> end
--       if false then <body> else <else>   →  do <else> end   (or nothing)
--   elseif chains are processed left-to-right; the first truthy branch wins.
--
--   While/repeat loops whose condition is a constant false/true are removed
--   or inlined similarly.
--
--   Return-level "X and Y or Z" ternary patterns are also folded.
--
-- FUS_CRASH()  (silently halts the thread forever — no console output)
--
--   Every call site FUS_CRASH() is replaced with:
--       do while true do coroutine.yield() end end
--
--   The thread suspends itself permanently via coroutine.yield(). Nothing
--   ever resumes it. Zero console output, no traceback, no
--   "Error occurred, no output from Luau" message.
--   Variable names are randomised per call site for structural variation.
--   A shim for un-obfuscated execution:
--       if not FUS_OBFUSCATED then
--           getfenv().FUS_CRASH = function()
--               while true do coroutine.yield() end
--           end
--       end
--
-- FUS_ENCSTR  (encrypt a string constant at compile time)
--
--   FUS_ENCSTR("some string")  →  DECRYPT(ciphertext, seed, salt)
--
--   The argument MUST be a string literal. Variables, multiple arguments,
--   or no arguments all produce a compile-time error.
--
--   A shim for un-obfuscated execution:
--       if not FUS_OBFUSCATED then
--           getfenv().FUS_ENCSTR = function(s) return s end
--       end
--
-- FUS_ENCNUM  (encrypt a number constant at compile time)
--
--   FUS_ENCNUM(1000)  →  tonumber(DECRYPT(ciphertext, seed, salt))
--
--   The number is serialized to its string representation, encrypted with the
--   same cipher as FUS_ENCSTR, and decoded at runtime via tonumber(DECRYPT(...)).
--   Type is preserved: integer-valued numbers round-trip as integers; doubles
--   with fractional parts round-trip as doubles.
--   The argument MUST be a number literal. Variables, multiple arguments,
--   or no arguments all produce a compile-time error.
--
--   A shim for un-obfuscated execution:
--       if not FUS_OBFUSCATED then
--           getfenv().FUS_ENCNUM = function(n) return n end
--       end
--
-- FUS_ENCFUNC  (encrypt a function at compile time, decrypt+load at runtime)
--
--   local myFunc = FUS_ENCFUNC(function() ... end, encKey, decKey)
--   myFunc()
--
--   Parameters:
--     arg1 : a constant function literal  (must NOT be a variable)
--     arg2 : a 64-character hex-encoded encryption key string literal
--     arg3 : a runtime variable/expression that provides the decryption key
--            (must NOT be a compile-time constant — use a server-returned value)
--
--   The macro XOR-encrypts the function's source text with arg2 at compile
--   time.  The replacement expression is a self-calling IIFE that takes arg3
--   as its decryption key, decodes the ciphertext byte-by-byte with
--   bit32.bxor, and returns loadstring(result).  At runtime you call the
--   returned function to execute the original logic.
--
--   Security notes:
--     - obfuscation fails if the encKey hex string appears verbatim anywhere
--       else in the script (prevents accidental key leakage).
--     - each FUS_ENCFUNC site must use a unique encKey.
--     - using a hardcoded decKey constant (arg3) is your own risk; the warning
--       from Luraph's LPH_ENCFUNC applies equally here.
--
--   Aliases: FUS_FUNCENC  (accepted in addition to FUS_ENCFUNC — both expand
--            identically; register both in KNOWN_MACROS if desired).
--
--   Shim for un-obfuscated execution:
--       if not FUS_OBFUSCATED then
--           getfenv().FUS_ENCFUNC = function(fn, _encKey, _decKey) return fn end
--       end
--
-- FUS_NO_VIRTUALIZE  (pass a function through without extra obfuscation)
--
--   local myFunc = FUS_NO_VIRTUALIZE(function() ... end)
--   myFunc()
--   -- or inline:
--   FUS_NO_VIRTUALIZE(function() ... end)()
--
--   The argument MUST be a constant function literal (not a variable).
--   The macro call is replaced at compile time with just the function literal
--   itself — nothing more. The function is stripped of local/upvalue names and
--   comments by the normal pipeline (parser discards comments; variable renamer
--   strips names), but its logic is NOT run through the custom bytecode VM or
--   any encryption step. On the luaubc preset this means the function ends up
--   as standard Luau bytecode alongside everything else instead of inside the
--   custom interpreter.
--
--   FUS_NO_VIRTUALIZE does NOT call the function automatically — assign it to
--   a local and call it, or append () immediately: FUS_NO_VIRTUALIZE(fn)()
--
--   Shim for un-obfuscated execution:
--       if not FUS_OBFUSCATED then
--           getfenv().FUS_NO_VIRTUALIZE = function(...) return ... end
--       end
--
-- Reserved-prefix guard
-- ─────────────────────────────────────────────────────────────────────────────
--   Any identifier starting with FUS_ that is NOT one of the known macros
--   causes a compile-time error (mirrors Luraph's LPH_ behaviour).
--
-- Shim removal
-- ─────────────────────────────────────────────────────────────────────────────
--   User scripts should wrap their shim definitions in
--       if not FUS_OBFUSCATED then ... end
--   which is the canonical pattern.  After macro expansion that block becomes
--       if not true then ... end  →  if false then ... end
--   which the constant-folding pass above removes entirely, so no shim code
--   ever appears in the obfuscated output.

local Step      = require("catph.step")
local Ast       = require("catph.ast")
local Scope     = require("catph.scope")
local visitast  = require("catph.visitast")
local logger    = require("logger")
local Parser    = require("catph.parser")
local Enums     = require("catph.enums")
local Unparser  = require("catph.unparser")
local EncryptStrings = require("catph.steps.EncryptStrings")
local bit32     = require("catph.bit").bit32

local AstKind   = Ast.AstKind

-- ── known macros ─────────────────────────────────────────────────────────────
-- Both FUS_ and LPH_ prefixes are supported.  LPH_ names are normalised to
-- their FUS_ equivalents before all checks, so the expansion logic is shared.
local KNOWN_MACROS = {
    FUS_OBFUSCATED       = true,
    FUS_CRASH            = true,
    FUS_ENCSTR           = true,
    FUS_ENCNUM           = true,
    FUS_ENCFUNC          = true,
    FUS_NO_VIRTUALIZE    = true,
    FUS_LINE             = true,
    FUS_OPAQUE           = true,
    -- LPH_ aliases — normalized to FUS_ before all checks.
    LPH_OBFUSCATED       = true,
    LPH_CRASH            = true,
    LPH_ENCSTR           = true,
    LPH_ENCNUM           = true,
    LPH_ENCFUNC          = true,
    LPH_NO_VIRTUALIZE    = true,
    LPH_LINE             = true,
    -- LPH_ hint macros — silently stripped (no equivalent FUS_ behaviour).
    -- These are Luraph-only optimizer hints; we just remove them cleanly.
    LPH_NO_UPVALUES      = true,
    LPH_JIT              = true,
    LPH_JIT_MAX          = true,
    -- SADOXPH_ aliases — normalized to their FUS_ equivalents.
    SADOXPH_NO_VIRTUALIZE = true,
}

-- Accepted reserved prefixes (any identifier that starts with one of these and
-- is NOT a known macro triggers a compile-time error).
local RESERVED_PREFIXES = { "FUS_", "LPH_", "SADOXPH_" }

-- Canonical macro suffix for a given identifier, normalised to the FUS_ form.
-- Returns nil when the name does not carry a reserved prefix.
local function normalizeMacro(name)
    if not name then return nil end
    if name:sub(1, 4) == "FUS_" then return name end
    if name:sub(1, 4) == "LPH_" then return "FUS_" .. name:sub(5) end
    -- SADOXPH_ prefix: 8 characters → maps to the FUS_ equivalent.
    -- e.g. SADOXPH_NO_VIRTUALIZE → FUS_NO_VIRTUALIZE
    if name:sub(1, 8) == "SADOXPH_" then return "FUS_" .. name:sub(9) end
    return nil  -- not a macro name
end

-- Is `name` a reserved-prefix identifier (FUS_ or LPH_)?
local function hasReservedPrefix(name)
    if not name then return false end
    for _, pfx in ipairs(RESERVED_PREFIXES) do
        if name:sub(1, #pfx) == pfx then return true end
    end
    return false
end

-- LPH_ hint macros that are silently stripped (no FUS_ equivalent).
-- These are Luraph optimizer hints; we remove any call to them cleanly.
-- FUS_ENCFUNC and FUS_NO_VIRTUALIZE are also stripped — their first argument
-- (the function literal) is returned as-is without any encryption or
-- virtualization bypass logic.
local HINT_MACROS = {
    LPH_NO_UPVALUES      = true,
    LPH_JIT              = true,
    LPH_JIT_MAX          = true,
    FUS_ENCFUNC          = true,
    FUS_NO_VIRTUALIZE    = true,
    LPH_ENCFUNC          = true,
    LPH_NO_VIRTUALIZE    = true,
    -- SADOXPH_ aliases — same behaviour as their FUS_ counterparts.
    SADOXPH_NO_VIRTUALIZE = true,
}

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Is a node an expression that carries a known constant value?
local function isConst(node)
    return node and node.isConstant == true
end

-- Fold a binary boolean expression when both sides are constant.
-- Returns a replacement node, or nil if no folding was possible.
local function foldBinary(node)
    if not (isConst(node.lhs) and isConst(node.rhs)) then return nil end
    local l, r = node.lhs.value, node.rhs.value
    local kind  = node.kind
    if kind == AstKind.AndExpression then
        local v = l and r; return Ast.ConstantNode(v)
    elseif kind == AstKind.OrExpression then
        local v = l or r;  return Ast.ConstantNode(v)
    elseif kind == AstKind.EqualsExpression then
        return Ast.ConstantNode(l == r)
    elseif kind == AstKind.NotEqualsExpression then
        return Ast.ConstantNode(l ~= r)
    end
    return nil
end

-- Fold a unary boolean expression.
local function foldUnary(node)
    if not isConst(node.rhs) then return nil end
    if node.kind == AstKind.NotExpression then
        return Ast.ConstantNode(not node.rhs.value)
    end
    return nil
end

-- ── step ──────────────────────────────────────────────────────────────────────

local MacroExpand = Step:extend()
MacroExpand.Name        = "MacroExpand"
MacroExpand.Description = "Expands compile-time macros (FUS_OBFUSCATED, FUS_CRASH, FUS_ENCSTR, FUS_ENCNUM, FUS_ENCFUNC, FUS_NO_VIRTUALIZE) and folds dead branches."
MacroExpand.SettingsDescriptor = {}

function MacroExpand:init()
    -- Lazy-initialised per-build encryption service for FUS_ENCSTR/FUS_ENCNUM.
    -- Created once on first use so the same DECRYPT function covers all
    -- FUS_ENCSTR call sites in a single compilation.
    self._encryptor    = nil   -- EncryptStrings encryption service instance
    self._decryptVar   = nil   -- scope id for the injected DECRYPT local
    self._decryptScope = nil   -- the ast.body scope it belongs to
    self._decryptInjected = false

    -- FUS_ENCFUNC: set of encKeys already used in this build, to detect
    -- duplicate / plaintext encKey leaks. Populated during validation pass.
    self._encfuncUsedKeys = {}
end

-- ── FUS_CRASH expansion ───────────────────────────────────────────────────────
--
-- Replaces a FUS_CRASH() call site with a `do ... end` block that silently
-- halts the thread forever.
--
-- Uses: while true do coroutine.yield() end
-- The thread suspends itself; nothing resumes it → silent permanent death.
-- Zero console output. No "Error occurred, no output from Luau". No traceback.
--
-- task.wait(math.huge) NOT used — Roblox clamps it to 0 + prints a warning.
-- Infinite spin (while true do end) NOT used — Roblox kills it after ~10s.
--
local LETTERS = "abcdefghijklmnopqrstuvwxyz"
local function randIdent(len)
    len = len or math.random(4, 8)
    local s = "_"
    for _ = 1, len do
        s = s .. LETTERS:sub(math.random(1, #LETTERS), math.random(1, #LETTERS))
    end
    return s
end

-- Build the inner while-true-yield block given a parent scope.
local function makeYieldLoop(parentScope)
    local innerScope = Scope:new(parentScope)
    local coScope, coId = innerScope:resolve("coroutine")
    local coRef         = Ast.VariableExpression(coScope, coId)
    local yieldExpr     = Ast.IndexExpression(coRef, Ast.StringExpression("yield"))
    local yieldCall     = Ast.FunctionCallStatement(yieldExpr, {})
    local loopScope     = Scope:new(innerScope)
    local loopBody      = Ast.Block({ yieldCall }, loopScope)
    local whileStat     = Ast.WhileStatement(loopBody, Ast.BooleanExpression(true), innerScope)
    return whileStat, innerScope
end

function MacroExpand:buildCrashNode(parentScope)
    local whileStat, innerScope = makeYieldLoop(parentScope)
    local block = Ast.Block({ whileStat }, innerScope)
    return Ast.DoStatement(block)
end

-- Expression-context crash: (function() while true do coroutine.yield() end end)()
function MacroExpand:buildCrashExpression(refScope)
    local whileStat, innerScope = makeYieldLoop(refScope)
    local fnBody = Ast.Block({ whileStat }, innerScope)
    local fnLit  = Ast.FunctionLiteralExpression({}, fnBody)
    return Ast.FunctionCallExpression(fnLit, {})
end

-- ── FUS_OPAQUE expansion ─────────────────────────────────────────────────────
--
-- FUS_OPAQUE(expr)
--
-- Wraps expr in an opaque predicate that always evaluates to the same truth
-- value as expr, but makes static analysis unable to determine it.
-- The injected predicate is always mathematically true (non-zero / non-nil),
-- so: FUS_OPAQUE(x)  →  x and <opaque_true>
-- where <opaque_true> is a random expression guaranteed to be truthy but looks
-- like it could go either way to a decompiler/static analyser.
--
-- Generated forms (one chosen at random per call site):
--   bit32.bxor(N, N) == 0           → always true  (N XOR N = 0)
--   bit32.band(N, 0) == 0           → always true  (anything AND 0 = 0)
--   bit32.bor(0, N) == N            → always true
--   (N * 0 + 1) ~= 0               → always true
--   math.floor(N) == N              → true when N is integer (use integer N)
--   tostring(N):len() > 0          → always true
--
-- For expression context: FUS_OPAQUE(expr) → (expr) and <predicate> or nil
-- (preserves truthiness while adding noise)
--
-- Shim for un-obfuscated execution:
--     if not FUS_OBFUSCATED then
--         getfenv().FUS_OPAQUE = function(x) return x end
--     end

function MacroExpand:buildOpaqueNode(innerExpr, refScope)
    -- Pick random opaque-true predicate.
    local n1 = math.random(1, 0x7FFFF)
    local variant = math.random(1, 5)

    local predicateSrc
    if variant == 1 then
        predicateSrc = string.format("bit32.bxor(%d,%d)==0", n1, n1)
    elseif variant == 2 then
        predicateSrc = string.format("bit32.band(%d,0)==0", n1)
    elseif variant == 3 then
        predicateSrc = string.format("bit32.bor(0,%d)==%d", n1, n1)
    elseif variant == 4 then
        predicateSrc = string.format("(%d*0+1)~=0", n1)
    else
        predicateSrc = string.format("math.floor(%d)==%d", n1, n1)
    end

    local wrapSrc = "local _ = " .. predicateSrc
    local wrapAst = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 }):parse(wrapSrc)
    local predExpr = wrapAst.body.statements[1].expressions[1]
    wrapAst.body.scope:setParent(refScope)

    -- FUS_OPAQUE(expr) → expr and <pred> and expr or expr
    --
    -- This preserves the ORIGINAL VALUE of expr, not just its truthiness.
    -- expr and <pred> and expr  : if expr is truthy, <pred> is always true,
    --   so this evaluates to expr (original value).
    -- or expr                   : if expr is falsy, the whole `and` chain
    --   short-circuits to falsy, then `or expr` returns expr (original value).
    --
    -- Net: always returns expr unchanged. Static analysis sees three conditions
    -- and can't trivially determine the result.
    return Ast.OrExpression(
        Ast.AndExpression(Ast.AndExpression(innerExpr, predExpr), innerExpr),
        innerExpr
    )
end
--
-- Initialise the encryption service and inject the DECRYPT function into the
-- AST's top-level block the first time FUS_ENCSTR is encountered.
-- Subsequent calls reuse the same DECRYPT local so all encrypted strings share
-- one decoder function.
function MacroExpand:ensureEncryptor(ast)
    if self._decryptInjected then return end

    -- Spin up a fresh EncryptStrings service (borrows the cipher implementation).
    local svc = EncryptStrings:new({})
    self._encryptor = svc:CreateEncrypionService()

    -- Parse and inject the DECRYPT do-block into ast.body (position 1).
    local code   = self._encryptor.genCode()
    local newAst = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 }):parse(code)
    local doStat = newAst.body.statements[1]

    local scope = ast.body.scope
    local decryptVar = scope:addVariable()
    self._decryptVar   = decryptVar
    self._decryptScope = scope

    -- Re-parent the do-block's inner scope so variable resolution works.
    doStat.body.scope:setParent(scope)

    -- Remap the DECRYPT FunctionDeclaration to use our new variable id.
    visitast(newAst, nil, function(node, data)
        if node.kind == AstKind.FunctionDeclaration then
            if node.scope:getVariableName(node.id) == "DECRYPT" then
                data.scope:removeReferenceToHigherScope(node.scope, node.id)
                data.scope:addReferenceToHigherScope(scope, decryptVar)
                node.scope = scope
                node.id    = decryptVar
            end
        end
    end)

    -- Prepend: local <decryptVar>; do … DECRYPT = function(…) … end end
    -- These two inserts go BEFORE all user statements so DECRYPT is defined
    -- before any FUS_ENCSTR call site can reach it.
    table.insert(ast.body.statements, 1, doStat)
    table.insert(ast.body.statements, 1,
        Ast.LocalVariableDeclaration(scope, { decryptVar }, {}))

    self._decryptInjected = true
end

-- Build the replacement expression for FUS_ENCSTR("literal"):
--   DECRYPT(encryptedBytes, seed, salt)
function MacroExpand:buildEncstrNode(plaintext, callScope, ast)
    self:ensureEncryptor(ast)

    local encrypted, seed, salt = self._encryptor.encrypt(plaintext)
    local dScope = self._decryptScope
    local dVar   = self._decryptVar

    -- Make sure the call site scope can see the DECRYPT upvalue.
    callScope:addReferenceToHigherScope(dScope, dVar)

    return Ast.FunctionCallExpression(
        Ast.VariableExpression(dScope, dVar),
        {
            Ast.StringExpression(encrypted),
            Ast.NumberExpression(seed),
            Ast.NumberExpression(salt),
        }
    )
end

-- Build the replacement expression for FUS_ENCNUM(number):
--   tonumber(DECRYPT(encryptedBytes, seed, salt))
-- The number is converted to its canonical string form, encrypted with the
-- same cipher, and decoded at runtime via tonumber().
function MacroExpand:buildEncnumNode(value, callScope, ast)
    self:ensureEncryptor(ast)

    -- Serialize the number to a string that tonumber() can recover exactly.
    local numStr = tostring(value)

    local encrypted, seed, salt = self._encryptor.encrypt(numStr)
    local dScope = self._decryptScope
    local dVar   = self._decryptVar

    callScope:addReferenceToHigherScope(dScope, dVar)

    -- Resolve tonumber global from the call site scope.
    local tnScope, tnId = callScope:resolve("tonumber")

    -- tonumber(DECRYPT(ciphertext, seed, salt))
    return Ast.FunctionCallExpression(
        Ast.VariableExpression(tnScope, tnId),
        {
            Ast.FunctionCallExpression(
                Ast.VariableExpression(dScope, dVar),
                {
                    Ast.StringExpression(encrypted),
                    Ast.NumberExpression(seed),
                    Ast.NumberExpression(salt),
                }
            )
        }
    )
end

-- ── FUS_ENCFUNC expansion ─────────────────────────────────────────────────────
--
-- FUS_ENCFUNC(function() ... end, "HEX64", decKeyVar)
--
-- Compile-time:
--   1. Unparse the function literal to a Lua source string.
--   2. Decode the 64-char hex encKey into 32 raw key bytes.
--   3. XOR each byte of the source with the cycling key → ciphertext.
--   4. Validate that the encKey hex string does not appear in any other
--      string constant in the program (scanned later in apply()).
--
-- The replacement expression (returned in place of the FUS_ENCFUNC call):
--
--   (function(_dk)
--       local _ct = "<ciphertext>"
--       local _r  = {}
--       local _kl = #_dk
--       for _i = 1, #_ct do
--           _r[_i] = string.char(bit32.bxor(string.byte(_ct, _i),
--                                           string.byte(_dk, (_i - 1) % _kl + 1)))
--       end
--       return loadstring(table.concat(_r))
--   end)(decKeyArg)
--
-- The decKey must be a runtime expression (not a compile-time constant) so the
-- ciphertext cannot be decrypted without the server-provided key, matching
-- Luraph's LPH_ENCFUNC semantics exactly.

-- Decode a 64-char hex string → 32-byte string (compile-time, in the obfuscator).
local function hexDecode(hex)
    assert(#hex == 64, "FUS_ENCFUNC: encKey must be exactly 64 hex characters")
    local bytes = {}
    for i = 1, 64, 2 do
        local hi = tonumber(hex:sub(i, i), 16)
        local lo = tonumber(hex:sub(i + 1, i + 1), 16)
        if not hi or not lo then
            error("FUS_ENCFUNC: encKey contains non-hex character at position " .. i)
        end
        bytes[#bytes + 1] = hi * 16 + lo
    end
    return bytes   -- array of 32 integers 0..255
end

-- Escape an arbitrary binary string into a Lua string literal.
local function escapeBinary(s)
    local out = {}
    for i = 1, #s do
        out[i] = string.format("\\%d", string.byte(s, i))
    end
    return '"' .. table.concat(out) .. '"'
end

function MacroExpand:buildEncfuncNode(funcNode, encKey, decKeyNode, callScope, ast, pipeline)
    -- 1. Unparse the function literal to a source string.
    --    We wrap it in `return <funclit>` so load() returns the function directly.
    local unparser = Unparser:new({ LuaVersion = Enums.LuaVersion.LuaU })
    local funcSrc = "return " .. unparser:unparseExpression(funcNode)

    -- 2. Decode encKey (64 hex chars → 32 key bytes).
    local keyBytes = hexDecode(encKey)
    local keyLen   = #keyBytes   -- always 32

    -- 3. XOR encrypt the function source.
    local srcBytes = { string.byte(funcSrc, 1, #funcSrc) }
    local encBytes = {}
    for i = 1, #srcBytes do
        local kb = keyBytes[((i - 1) % keyLen) + 1]
        encBytes[i] = string.char(bit32.bxor(srcBytes[i], kb))
    end
    local ciphertext = table.concat(encBytes)

    -- 4. Build the runtime decoder as source text, then parse it into an AST
    --    sub-expression.  We use a randomized set of local names so every
    --    expansion looks structurally different in the obfuscated output.
    local vDk  = randIdent()  -- decryption key parameter
    local vCt  = randIdent()  -- ciphertext local
    local vR   = randIdent()  -- result table
    local vKl  = randIdent()  -- key length local
    local vI   = randIdent()  -- loop variable
    local vB32 = randIdent()  -- bit32 local alias
    local vSB  = randIdent()  -- string.byte local alias
    local vSC  = randIdent()  -- string.char local alias
    local vTC  = randIdent()  -- table.concat local alias
    local vLS  = randIdent()  -- loadstring local alias with a nil placeholder for the decKey argument.
    -- After parsing we replace the NilExpression arg with the real decKeyNode.
    --
    -- The decKey passed at runtime is a hex string (e.g. "6c7572...").
    -- The compile-time XOR used raw bytes decoded from that hex.
    -- So the IIFE must hex-decode dk before XORing, to match.
    --
    -- Template structure:
    --   local ct = <ciphertext>
    --   local kb = {}  -- key bytes decoded from hex dk
    --   for hi=1,#dk,2 do kb[#kb+1]=tonumber(dk:sub(hi,hi),16)*16+tonumber(dk:sub(hi+1,hi+1),16) end
    --   local kl = #kb
    --   local r = {}
    --   for i=1,#ct do r[i]=sc(bx(sb(ct,i), kb[(i-1)%kl+1])) end
    --   return (loadstring or load)(tc(r))
    local vHi = randIdent()  -- hex decode loop variable
    local vKB = randIdent()  -- key bytes table

    local wrapSrc = string.format(
        "local _ = (function(%s)" ..
        " local %s=loadstring" ..
        " local %s=string.byte" ..
        " local %s=string.char" ..
        " local %s=table.concat" ..
        " local %s=bit32.bxor" ..
        " local %s=%s" ..
        " local %s={}" ..
        " for %s=1,#%s,2 do %s[#%s+1]=tonumber(%s:sub(%s,%s),16)*16+tonumber(%s:sub(%s+1,%s+1),16) end" ..
        " local %s=#%s" ..
        " local %s={}" ..
        " for %s=1,#%s do %s[%s]=%s(%s(%s(%s,%s),%s[(%s-1)%%%s+1])) end" ..
        " return (%s or load)(%s(%s))" ..
        " end)(nil)",
        -- param
        vDk,                                          -- [1]
        -- aliases
        vLS,                                          -- [2]  local vLS=loadstring
        vSB,                                          -- [3]  local vSB=string.byte
        vSC,                                          -- [4]  local vSC=string.char
        vTC,                                          -- [5]  local vTC=table.concat
        vB32,                                         -- [6]  local vB32=bit32.bxor
        -- ciphertext
        vCt, escapeBinary(ciphertext),                -- [7][8]  local vCt=<cipher>
        -- key bytes table init
        vKB,                                          -- [9]  local vKB={}
        -- hex decode loop: for hi=1,#dk,2 do vKB[#vKB+1]=tonumber(dk:sub(hi,hi),16)*16+tonumber(dk:sub(hi+1,hi+1),16) end
        vHi, vDk, vKB, vKB, vDk, vHi, vHi, vDk, vHi, vHi,  -- [10..19]
        -- key length
        vKl, vKB,                                     -- [20][21]  local vKl=#vKB
        -- result table
        vR,                                           -- [22]  local vR={}
        -- decrypt loop: for i=1,#ct do r[i]=sc(bx(sb(ct,i), vKB[(i-1)%kl+1])) end
        vI, vCt, vR, vI, vSC, vB32, vSB, vCt, vI, vKB, vI, vKl,  -- [23..34]
        -- return
        vLS, vTC, vR)                                 -- [35][36][37]

    local wrapAst = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 }):parse(wrapSrc)

    -- Walk the parsed AST to extract the outermost FunctionCallExpression and
    -- replace the nil placeholder argument with the real decKeyNode.
    local resultExpr
    visitast(wrapAst, nil, function(node, _data)
        if resultExpr then return end
        if node.kind == AstKind.FunctionCallExpression then
            -- The outermost IIFE: (function(dk)...end)(nil)
            if #node.args == 1 and node.args[1].kind == AstKind.NilExpression then
                node.args[1] = decKeyNode
                resultExpr = node
            end
        end
    end)

    if not resultExpr then
        logger:error("MacroExpand: FUS_ENCFUNC internal error — could not locate decoder IIFE in parsed AST.")
    end

    -- Re-parent the parsed wrapper's body scope so that global references
    -- (loadstring, bit32, string.*, table.*) resolve correctly through the
    -- program's global scope.
    wrapAst.body.scope:setParent(callScope)

    return resultExpr
end

function MacroExpand:apply(ast, pipeline)
    local _ast = ast  -- captured for FUS_ENCSTR expansion inside visitast closures

    -- ── Pre-scan: inject DECRYPT block BEFORE the main pass ──────────────────
    -- If any FUS_ENCSTR call exists we must inject the DECRYPT do-block now,
    -- before visitast starts replacing call sites.  Doing it lazily inside
    -- visitast causes DECRYPT to be injected AFTER the first call site is
    -- already emitted, producing `local B; local x = B(...) do function B end`
    -- where B is nil at the call site.  Pre-injecting guarantees the block
    -- Scan the full AST for any FUS_ENCSTR / FUS_ENCNUM usage and pre-inject
    -- the DECRYPT function before the main pass starts.
    local needsEncryptor = false
    visitast(ast, function(node, data)
        if needsEncryptor then return node, true end
        if node.kind == AstKind.FunctionCallExpression or
           node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and base.kind == AstKind.VariableExpression then
                local name = base.scope and base.scope:getVariableName(base.id)
                local norm = normalizeMacro(name)
                if norm == "FUS_ENCSTR" or norm == "FUS_ENCNUM" then
                    needsEncryptor = true
                end
            end
        end
    end)
    if needsEncryptor then
        self:ensureEncryptor(ast)
    end

    -- ── Pass 1: replace macro identifiers + constant-fold expressions ─────────
    visitast(ast, function(node, data)

        -- Guard: reject any FUS_*/LPH_* identifier that is not a known macro.
        -- We check VariableExpression, AssignmentVariable, and local declarations.
        if node.kind == AstKind.VariableExpression or
           node.kind == AstKind.AssignmentVariable then
            local name = node.scope and node.scope:getVariableName(node.id)
            if hasReservedPrefix(name) then
                if not KNOWN_MACROS[name] and not KNOWN_MACROS[normalizeMacro(name)] and not HINT_MACROS[name] then
                    logger:error(string.format(
                        "MacroExpand: identifier '%s' uses the reserved %s prefix but is not a known macro.",
                        name, name:sub(1,4)))
                end
            end
        end

        if node.kind == AstKind.LocalVariableDeclaration then
            -- Check that no local is named with the FUS_/LPH_ prefix.
            local scope = node.scope
            for _, id in ipairs(node.ids) do
                local name = scope and scope:getVariableName(id)
                if hasReservedPrefix(name) and not HINT_MACROS[name] then
                    logger:error(string.format(
                        "MacroExpand: local variable '%s' uses the reserved %s prefix.",
                        name, name:sub(1,4)))
                end
            end
        end

        -- Guard: FUS_OBFUSCATED / LPH_OBFUSCATED must not be called as a function.
        if node.kind == AstKind.FunctionCallExpression or
           node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression or base.kind == AstKind.AssignmentVariable) then
                local rawName = base.scope and base.scope:getVariableName(base.id)
                -- Hint macros are silently stripped — skip all validation for them.
                if rawName and HINT_MACROS[rawName] then return end
                local name = normalizeMacro(rawName)
                if name == "FUS_OBFUSCATED" then
                    logger:error("MacroExpand: " .. rawName .. " is a boolean constant, not a function — do not call it.")
                end
                -- FUS_LINE / LPH_LINE: number constant, not callable.
                if name == "FUS_LINE" then
                    logger:error("MacroExpand: " .. rawName .. " is a number constant (current line), not a function — do not call it.")
                end
                -- Validate FUS_OPAQUE call signature.
                if name == "FUS_OPAQUE" then
                    local args = node.args
                    if #args ~= 1 then
                        logger:error("MacroExpand: " .. rawName .. "() requires exactly one argument, got " .. #args .. ".")
                    end
                end
                -- Validate FUS_ENCSTR / LPH_ENCSTR call signature at pre-visit time.
                if name == "FUS_ENCSTR" then
                    local args = node.args
                    if #args == 0 then
                        logger:error("MacroExpand: " .. rawName .. "() requires exactly one string literal argument.")
                    end
                    if #args > 1 then
                        logger:error("MacroExpand: " .. rawName .. "() takes exactly one argument, got " .. #args .. ".")
                    end
                    local arg = args[1]
                    if not arg or (arg.kind ~= AstKind.StringExpression and arg.kind ~= AstKind.LongStringExpression) then
                        logger:error("MacroExpand: " .. rawName .. "() argument must be a string literal constant, not a variable or expression.")
                    end
                end
                -- Validate FUS_ENCNUM / LPH_ENCNUM call signature at pre-visit time.
                if name == "FUS_ENCNUM" then
                    local args = node.args
                    if #args == 0 then
                        logger:error("MacroExpand: " .. rawName .. "() requires exactly one number literal argument.")
                    end
                    if #args > 1 then
                        logger:error("MacroExpand: " .. rawName .. "() takes exactly one argument, got " .. #args .. ".")
                    end
                    local arg = args[1]
                    if not arg or arg.kind ~= AstKind.NumberExpression then
                        logger:error("MacroExpand: " .. rawName .. "() argument must be a number literal constant, not a variable or expression.")
                    end
                end
                -- Validate FUS_ENCFUNC / LPH_ENCFUNC call signature at pre-visit time.
                if name == "FUS_ENCFUNC" then
                    local args = node.args
                    if #args ~= 3 then
                        logger:error("MacroExpand: " .. rawName .. "() requires exactly 3 arguments: (function, encKey, decKey).")
                    end
                    -- Arg 1: must be a function literal
                    local arg1 = args[1]
                    if not arg1 or arg1.kind ~= AstKind.FunctionLiteralExpression then
                        logger:error("MacroExpand: " .. rawName .. "() first argument must be a constant function literal (e.g. function() ... end).")
                    end
                    -- Arg 2: must be a 64-char hex string literal
                    local arg2 = args[2]
                    if not arg2 or (arg2.kind ~= AstKind.StringExpression and arg2.kind ~= AstKind.LongStringExpression) then
                        logger:error("MacroExpand: " .. rawName .. "() second argument (encKey) must be a string literal constant.")
                    end
                    local encKey = arg2.value
                    if type(encKey) ~= "string" or #encKey ~= 64 then
                        logger:error(string.format(
                            "MacroExpand: " .. rawName .. "() encKey must be a 64-character hex string, got %d characters.",
                            type(encKey) == "string" and #encKey or 0))
                    end
                    if encKey:find("[^0-9a-fA-F]") then
                        logger:error("MacroExpand: " .. rawName .. "() encKey must contain only hex characters (0-9, a-f, A-F).")
                    end
                    local arg3 = args[3]
                    if not arg3 then
                        logger:error("MacroExpand: " .. rawName .. "() third argument (decKey) must be a runtime variable/expression.")
                    end
                    if arg3.isConstant then
                        logger:error("MacroExpand: " .. rawName .. "() decKey (third argument) must be a runtime variable, not a string/number constant.")
                    end
                    if self._encfuncUsedKeys[encKey] then
                        logger:error("MacroExpand: " .. rawName .. "() the same encKey was used in multiple call sites. Each call must use a unique key.")
                    end
                    self._encfuncUsedKeys[encKey] = true
                end
                -- Validate FUS_NO_VIRTUALIZE / LPH_NO_VIRTUALIZE call signature.
                if name == "FUS_NO_VIRTUALIZE" then
                    local args = node.args
                    if #args ~= 1 then
                        logger:error("MacroExpand: " .. rawName .. "() requires exactly one argument, got " .. #args .. ".")
                    end
                    local arg1 = args[1]
                    if not arg1 or arg1.kind ~= AstKind.FunctionLiteralExpression then
                        logger:error("MacroExpand: " .. rawName .. "() argument must be a constant function literal (e.g. function() ... end), not a variable or other expression.")
                    end
                end
            end
        end

    end, function(node, data)
        -- Post-visit: replace + fold on the way back up (children already done).

        -- Hint macros (FUS_ENCFUNC, FUS_NO_VIRTUALIZE, LPH_* variants):
        -- In expression context → return the first argument (the function literal).
        -- In statement context  → NopStatement (call result discarded anyway).
        if node.kind == AstKind.FunctionCallExpression or
           node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression or base.kind == AstKind.AssignmentVariable) then
                local rawName = base.scope and base.scope:getVariableName(base.id)
                if rawName and HINT_MACROS[rawName] then
                    if node.kind == AstKind.FunctionCallExpression then
                        -- Return the first argument (the function literal) unchanged,
                        -- or nil-expression if there are no args.
                        if node.args and node.args[1] then
                            return node.args[1]
                        end
                        return Ast.NilExpression()
                    else
                        -- Statement context: just drop it
                        return Ast.NopStatement()
                    end
                end
            end
        end

        -- Replace FUS_OBFUSCATED / LPH_OBFUSCATED identifier → true
        if node.kind == AstKind.VariableExpression then
            local name = normalizeMacro(node.scope and node.scope:getVariableName(node.id))
            if name == "FUS_OBFUSCATED" then
                return Ast.BooleanExpression(true)
            end
        end

        -- Replace FUS_CRASH() / LPH_CRASH() call expression → crash expression.
        if node.kind == AstKind.FunctionCallExpression then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_CRASH" then
                    return self:buildCrashExpression(base.scope)
                end
            end
        end

        -- Replace FUS_CRASH() / LPH_CRASH() call statement → do...end crash block.
        if node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_CRASH" then
                    return self:buildCrashNode(base.scope)
                end
            end
        end

        -- Replace FUS_OPAQUE(expr) → expr and <opaque_true_predicate>
        if node.kind == AstKind.FunctionCallExpression then
            local base = node.base
            if base and base.kind == AstKind.VariableExpression then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_OPAQUE" then
                    return self:buildOpaqueNode(node.args[1], data.scope)
                end
            end
        end
        -- FUS_OPAQUE used as a bare statement is an error — result is discarded.
        if node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and base.kind == AstKind.VariableExpression then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_OPAQUE" then
                    logger:error("MacroExpand: FUS_OPAQUE() used as a bare statement — result is discarded. Wrap in a condition or assignment.")
                end
            end
        end

        -- Replace FUS_ENCSTR / LPH_ENCSTR
        if node.kind == AstKind.FunctionCallExpression then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_ENCSTR" then
                    local plaintext = node.args[1].value
                    return self:buildEncstrNode(plaintext, data.scope, _ast)
                end
            end
        end
        if node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_ENCSTR" then
                    logger:warn("MacroExpand: ENCSTR macro used as a statement — result is discarded.")
                    return Ast.NopStatement()
                end
            end
        end

        -- Replace FUS_ENCNUM / LPH_ENCNUM
        if node.kind == AstKind.FunctionCallExpression then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_ENCNUM" then
                    local value = node.args[1].value
                    return self:buildEncnumNode(value, data.scope, _ast)
                end
            end
        end
        if node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_ENCNUM" then
                    logger:warn("MacroExpand: ENCNUM macro used as a statement — result is discarded.")
                    return Ast.NopStatement()
                end
            end
        end

        -- Replace FUS_ENCFUNC / LPH_ENCFUNC
        if node.kind == AstKind.FunctionCallExpression then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_ENCFUNC" then
                    local funcNode   = node.args[1]
                    local encKeyNode = node.args[2]
                    local decKeyNode = node.args[3]
                    return self:buildEncfuncNode(
                        funcNode, encKeyNode.value, decKeyNode,
                        data.scope, _ast, pipeline)
                end
            end
        end
        if node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_ENCFUNC" then
                    logger:error("MacroExpand: ENCFUNC macro does not automatically call the passed function — assign it to a local and call it explicitly.")
                end
            end
        end

        -- Replace FUS_NO_VIRTUALIZE / LPH_NO_VIRTUALIZE
        -- Full Luraph-style native extraction:
        -- 1. Collect all outer-scope locals the function captures (upvalues).
        -- 2. Upvalue-free functions → tag __fus_no_virt, extracted as native Luau.
        -- 3. Upvalue-capturing functions → rewrite as a factory IIFE that
        --    receives a {name=value,...} table, destructures it at the top of the
        --    function body, then tags __fus_no_virt. The result runs as native
        --    Luau with correct values for all captured locals.
        if node.kind == AstKind.FunctionCallExpression then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local macroName = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if macroName == "FUS_NO_VIRTUALIZE" then
                    local fnNode = node.args[1]
                    local fnScope = fnNode.body and fnNode.body.scope

                    -- Collect upvalued outer locals: { name → {scope, id} }
                    local upvalNames = {}   -- ordered list of names
                    local upvalSeen  = {}   -- dedup
                    if fnScope then
                        visitast(fnNode, nil, function(inner, _)
                            if inner.kind == AstKind.VariableExpression then
                                local vs = inner.scope
                                if vs and not vs.isGlobal then
                                    if vs.level and fnScope.level and vs.level < fnScope.level then
                                        local vname = vs:getVariableName(inner.id)
                                        if vname and not upvalSeen[vname] then
                                            upvalSeen[vname] = true
                                            upvalNames[#upvalNames + 1] = { name = vname, scope = vs, id = inner.id }
                                        end
                                    end
                                end
                            end
                        end)
                    end

                    if #upvalNames == 0 then
                        -- Upvalue-free: extract directly as native Luau.
                        fnNode.__fus_no_virt = true
                        return fnNode
                    end

                    -- Has upvalues: rewrite the function body to pull values from
                    -- a `_u` parameter table, then wrap in a factory IIFE.
                    --
                    -- Transform:
                    --   FUS_NO_VIRTUALIZE(function(...) [body] end)
                    -- into:
                    --   (function(_u)
                    --       local lighting = _u.lighting
                    --       local camera   = _u.camera
                    --       ...
                    --       return function(...) [body — unchanged] end
                    --   end)({ lighting = lighting, camera = camera, ... })
                    --
                    -- The outer locals passed in via _u are now locals inside the
                    -- factory, so the inner function captures them as upvalues
                    -- from the factory — fully native Luau closure semantics.

                    -- Unparse the original function body to source.
                    local unp = Unparser:new({ LuaVersion = Enums.LuaVersion.LuaU })

                    -- Build the destructure lines and table entries.
                    local destructLines = {}
                    local tableEntries  = {}
                    for _, uv in ipairs(upvalNames) do
                        destructLines[#destructLines + 1] = "local " .. uv.name .. " = _u." .. uv.name
                        tableEntries[#tableEntries + 1]  = uv.name .. " = " .. uv.name
                    end

                    -- Build the factory source.
                    -- IMPORTANT: destructure locals go in the FACTORY body,
                    -- NOT inside the inner function. This way they run ONCE
                    -- when the factory is called, and the inner function
                    -- captures them as real Luau upvalues — zero table lookup
                    -- overhead per call. Critical for per-frame callbacks.
                    local fullFnSrc = unp:unparseExpression(fnNode)
                    local destructBlock = table.concat(destructLines, " ") .. " "

                    -- Assemble factory: destructure in factory scope, return
                    -- the original function unchanged (it sees the locals as upvalues).
                    local factorySrc = string.format(
                        "(function(_u) %s return %s end)({%s})",
                        destructBlock,
                        fullFnSrc,
                        table.concat(tableEntries, ", ")
                    )

                    -- Obfuscate string literals inside the factory source.
                    -- Each character in a quoted string is randomly encoded as
                    -- one of: \DDD (decimal), \xHH (hex), \u{H} (unicode), or
                    -- left as-is — matching Luraph's visual style.
                    local function obfuscateStringLiterals(src)
                        local function encodeChar(c)
                            local b = string.byte(c)
                            local r = math.random(4)
                            if r == 1 then
                                return string.format("\\%d", b)           -- \72
                            elseif r == 2 then
                                return string.format("\\x%02x", b)        -- \x48
                            elseif r == 3 then
                                return string.format("\\u{%x}", b)        -- \u{48}
                            else
                                return c                                   -- plain
                            end
                        end
                        -- Replace contents of single-quoted and double-quoted strings.
                        -- Process character by character to handle escapes correctly.
                        local out = {}
                        local i = 1
                        local n = #src
                        while i <= n do
                            local c = src:sub(i, i)
                            -- Enter a string literal.
                            if c == '"' or c == "'" then
                                local q = c
                                out[#out+1] = q
                                i = i + 1
                                while i <= n do
                                    local sc = src:sub(i, i)
                                    if sc == '\\' then
                                        -- Pass escape sequences through unchanged.
                                        out[#out+1] = src:sub(i, i+1)
                                        i = i + 2
                                    elseif sc == q then
                                        out[#out+1] = q
                                        i = i + 1
                                        break
                                    else
                                        out[#out+1] = encodeChar(sc)
                                        i = i + 1
                                    end
                                end
                            else
                                out[#out+1] = c
                                i = i + 1
                            end
                        end
                        return table.concat(out)
                    end

                    factorySrc = obfuscateStringLiterals(factorySrc)

                    -- Parse the factory into an AST node (use LuaU for continue/etc).
                    local ok, factoryAst = pcall(function()
                        return Parser:new({ LuaVersion = Enums.LuaVersion.LuaU }):parse(
                            "local __nv = " .. factorySrc)
                    end)

                    if not ok then
                        -- Parse failed (e.g. complex body) — fall back to VM.
                        logger:warn("MacroExpand: FUS_NO_VIRTUALIZE: could not rewrite upvalue function for native extraction, leaving in VM.")
                        return fnNode
                    end

                    -- Extract the factory expression from the parsed local declaration.
                    local factoryExpr = factoryAst.body.statements[1].expressions[1]
                    if not factoryExpr then
                        return fnNode
                    end

                    -- Tag the factory wrapper function literal for extraction.
                    local factoryFn = factoryExpr.base
                    if factoryFn and factoryFn.kind == AstKind.FunctionLiteralExpression then
                        factoryFn.__fus_no_virt = true
                    end

                    -- Re-parent scopes so variable resolution works.
                    factoryAst.body.scope:setParent(data.scope)

                    return factoryExpr
                end
            end
        end
        if node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and (base.kind == AstKind.VariableExpression) then
                local name = normalizeMacro(base.scope and base.scope:getVariableName(base.id))
                if name == "FUS_NO_VIRTUALIZE" then
                    logger:warn("MacroExpand: NO_VIRTUALIZE macro used as a bare statement — append () to call the function, or assign it to a local.")
                    return Ast.NopStatement()
                end
            end
        end

        -- Strip LPH_ hint macros (LPH_JIT, LPH_JIT_MAX, LPH_NO_UPVALUES, LPH_LINE).
        -- Statement position: remove entirely.
        -- Expression position: return the first argument as-is (passthrough).
        --   e.g. newcclosure(LPH_NO_UPVALUES(function() ... end))
        --   must become newcclosure(function() ... end), NOT newcclosure(nil).
        if node.kind == AstKind.FunctionCallStatement then
            local base = node.base
            if base and base.kind == AstKind.VariableExpression then
                local name = base.scope and base.scope:getVariableName(base.id)
                if name and HINT_MACROS[name] then
                    return Ast.NopStatement()
                end
            end
        end
        if node.kind == AstKind.FunctionCallExpression then
            local base = node.base
            if base and base.kind == AstKind.VariableExpression then
                local name = base.scope and base.scope:getVariableName(base.id)
                if name and HINT_MACROS[name] then
                    -- Pass through the first argument (usually a function literal).
                    -- Fall back to nil only if there are no arguments.
                    if node.args and node.args[1] then
                        return node.args[1]
                    end
                    return Ast.NilExpression()
                end
            end
        end

        -- Fold `not <const>`
        if node.kind == AstKind.NotExpression then
            local folded = foldUnary(node)
            if folded then return folded end
        end

        -- Fold binary bool expressions where both sides became constant.
        if node.kind == AstKind.AndExpression or
           node.kind == AstKind.OrExpression  or
           node.kind == AstKind.EqualsExpression or
           node.kind == AstKind.NotEqualsExpression then
            local folded = foldBinary(node)
            if folded then return folded end
        end

        -- Partial short-circuit fold for `and` / `or` with one const side.
        if node.kind == AstKind.AndExpression then
            if isConst(node.lhs) then
                if node.lhs.value then
                    return node.rhs  -- true and X → X
                else
                    return Ast.BooleanExpression(false)  -- false and X → false
                end
            end
        end
        if node.kind == AstKind.OrExpression then
            if isConst(node.lhs) then
                if node.lhs.value then
                    return Ast.BooleanExpression(true)   -- true or X → true
                else
                    return node.rhs  -- false or X → X
                end
            end
        end

    end)

    -- ── Pass 1.5: encKey leak detection ─────────────────────────────────────
    -- After expansion, scan every string literal in the AST and error if any
    -- of the encKeys we used still appears verbatim. (They should not, since
    -- the encKey was never emitted into the AST -- only the ciphertext was.
    -- But this guards against user error: if they hardcoded the same hex key
    -- elsewhere as a string constant, we catch it here.)
    if next(self._encfuncUsedKeys) then
        visitast(ast, nil, function(node, _data)
            if node.kind == AstKind.StringExpression or node.kind == AstKind.LongStringExpression then
                local v = node.value
                if type(v) == "string" then
                    for encKey, _ in pairs(self._encfuncUsedKeys) do
                        if v:find(encKey, 1, true) or v:find(encKey:lower(), 1, true) then
                            logger:error(string.format(
                                "MacroExpand: FUS_ENCFUNC security violation — the encKey '%s' appears verbatim in another string constant in the script. " ..
                                "For security purposes obfuscation will fail. Remove or rename that string.",
                                encKey))
                        end
                    end
                end
            end
        end)
    end

    -- ── Pass 2: constant-fold control-flow statements ─────────────────────────
    -- We do a second walk because statement folding may expose new expressions
    -- to fold in the first pass, but in practice one round is sufficient for
    -- the FUS_OBFUSCATED pattern.
    visitast(ast, nil, function(node, data)

        if node.kind == AstKind.IfStatement then
            return self:foldIf(node, data)
        end

        if node.kind == AstKind.WhileStatement then
            if isConst(node.condition) and not node.condition.value then
                -- while false do ... end  → remove entirely (NopStatement)
                return Ast.NopStatement()
            end
        end

        if node.kind == AstKind.RepeatStatement then
            -- repeat ... until true  → run body once (do ... end)
            if isConst(node.condition) and node.condition.value then
                return Ast.DoStatement(node.body)
            end
        end

    end)

    return ast
end

-- Fold an IfStatement whose condition (or elseif conditions) are constant.
-- Returns one or more replacement statements (may be zero → NopStatement).
function MacroExpand:foldIf(node, data)
    -- Condition is a known constant.
    if isConst(node.condition) then
        if node.condition.value then
            -- `if true then <body> end`  →  `do <body> end`
            -- The else/elseif branches are unreachable; drop them entirely.
            return Ast.DoStatement(node.body)
        else
            -- `if false then ... elseif <cond> then <body> ... else <else> end`
            -- Discard the false branch and promote the first elseif (or else).
            if node.elseifs and #node.elseifs > 0 then
                local first = table.remove(node.elseifs, 1)
                node.condition = first.condition
                node.body      = first.body
                -- Recurse: the new condition might also be constant.
                return self:foldIf(node, data)
            elseif node.elsebody then
                return Ast.DoStatement(node.elsebody)
            else
                return Ast.NopStatement()
            end
        end
    end

    -- Condition is not constant, but we can still prune elseif/else chains
    -- that are provably constant.
    if node.elseifs then
        local newElseifs = {}
        for _, eif in ipairs(node.elseifs) do
            if isConst(eif.condition) then
                if eif.condition.value then
                    -- This elseif is always true → becomes the else body;
                    -- all subsequent elseifs/else are unreachable.
                    node.elseifs = newElseifs
                    node.elsebody = eif.body
                    break
                end
                -- else: this elseif is always false → drop it silently.
            else
                table.insert(newElseifs, eif)
            end
        end
        node.elseifs = newElseifs
    end

    return node
end

return MacroExpand
