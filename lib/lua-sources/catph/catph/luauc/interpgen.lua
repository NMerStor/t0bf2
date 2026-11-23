--
-- luauc/interpgen.lua
--
-- Polymorphic interpreter generator. Produces, per build, a structurally
-- different but semantically identical Luau-bytecode interpreter source string.
--
-- How it preserves semantics
-- --------------------------
-- The interpreter's correctness lives in two places: (1) the prelude/tail of
-- interp.lua (field helpers, base85 decode, upvalue handling, run() setup, the
-- entry wrapper) and (2) the per-opcode handler bodies. We reuse (1) VERBATIM by
-- slicing interp.lua at the --@LOOP_BEGIN / --@LOOP_END markers, and we keep (2)
-- as exact copies of the handler bodies. Only the *shape* of the dispatch -- the
-- structure that a generic devirtualizer pattern-matches on -- is regenerated.
--
-- Crucially, dispatch is on CANONICAL Luau opcodes. The existing opcode remapping
-- (remap.lua) and position-encryption are applied to the bytecode before the
-- interpreter ever sees an op (the prelude decrypts; `opmap` re-canonicalizes the
-- op byte). So this generator is automatically compatible with opcode remapping,
-- bytecode encryption, EnhancedVmCompression, and the deterministic Seed (it only
-- calls math.random, which the pipeline seeds).
--
-- Dimensions varied per build (foundation set)
-- --------------------------------------------
--   * Dispatch style: "ifelse" (flat, shuffled branch order), "split" (the same
--     chain broken into randomly nested segments), or "table" (op -> closure
--     table, definition order shuffled).
--   * Field decode: equivalent alternative expressions for a/b/c/d.
--   * Handler templates: opcodes with multiple equivalent source forms pick one.
--
-- Deferred (documented as follow-ups): opcode fusion, opcode splitting, and
-- register/constant/stack/upvalue layout remapping.

local Interpgen = {}

----------------------------------------------------------------------
-- Handler table. Each entry:
--   ops    : list of canonical opcodes that share this body.
--   body   : inline source (statements; locals op/a/b/c/d/insn/pc/code/K/R/...
--            top/env/bc/proto/upvals/openuv/varargs/nva and the prelude helpers
--            floor/pack/tunpack/uvget/uvset/getOpen/closeFrom/fillCaptures/
--            makeClosure are all in scope).
--   alts   : optional list of equivalent alternative bodies (semantically ==).
--   ret    : RETURN -- needs special handling under table dispatch.
-- Bodies are copied verbatim from interp.lua (the known-correct reference).
----------------------------------------------------------------------

local function H(ops, body, alts, ret)
    return { ops = ops, body = body, alts = alts, ret = ret }
end

local HANDLERS = {
    H({ 6 }, [=[R[a] = R[b]]=], { [=[local _v = R[b]; R[a] = _v]=] }),
    H({ 15 }, [=[local aux = code[pc]; pc = pc + 1
R[a] = R[b][KV[aux + 1]]]=], { [=[local aux = code[pc]; pc = pc + 1
local _t = R[b]; R[a] = _t[KV[aux + 1]]]=] }),
    H({ 20 }, [=[local aux = code[pc]; pc = pc + 1
local self = R[b]
R[a + 1] = self
R[a] = self[KV[aux + 1]]]=], { [=[local aux = code[pc]; pc = pc + 1
local _s = R[b]; R[a + 1] = _s; R[a] = _s[KV[aux + 1]]]=] }),
    H({ 21, 87 }, [=[if op == 87 then pc = pc + 1 end
local nb = b
local na
if nb == 0 then na = top - a - 1 else na = nb - 1 end
local f = R[a]
local nc = c
if nc == 2 then
    if na == 0 then R[a] = f()
    elseif na == 1 then R[a] = f(R[a + 1])
    elseif na == 2 then R[a] = f(R[a + 1], R[a + 2])
    elseif na == 3 then R[a] = f(R[a + 1], R[a + 2], R[a + 3])
    elseif na == 4 then R[a] = f(R[a + 1], R[a + 2], R[a + 3], R[a + 4])
    elseif na == 5 then R[a] = f(R[a + 1], R[a + 2], R[a + 3], R[a + 4], R[a + 5])
    else
        local args = {}
        for k = 1, na do args[k] = R[a + k] end
        R[a] = f(tunpack(args, 1, na))
    end
elseif nc == 1 then
    if na == 0 then f()
    elseif na == 1 then f(R[a + 1])
    elseif na == 2 then f(R[a + 1], R[a + 2])
    elseif na == 3 then f(R[a + 1], R[a + 2], R[a + 3])
    elseif na == 4 then f(R[a + 1], R[a + 2], R[a + 3], R[a + 4])
    elseif na == 5 then f(R[a + 1], R[a + 2], R[a + 3], R[a + 4], R[a + 5])
    else
        local args = {}
        for k = 1, na do args[k] = R[a + k] end
        f(tunpack(args, 1, na))
    end
elseif nc == 3 then
    if na == 0 then R[a], R[a + 1] = f()
    elseif na == 1 then R[a], R[a + 1] = f(R[a + 1])
    elseif na == 2 then R[a], R[a + 1] = f(R[a + 1], R[a + 2])
    elseif na == 3 then R[a], R[a + 1] = f(R[a + 1], R[a + 2], R[a + 3])
    elseif na == 4 then R[a], R[a + 1] = f(R[a + 1], R[a + 2], R[a + 3], R[a + 4])
    elseif na == 5 then R[a], R[a + 1] = f(R[a + 1], R[a + 2], R[a + 3], R[a + 4], R[a + 5])
    else
        local args = {}
        for k = 1, na do args[k] = R[a + k] end
        R[a], R[a + 1] = f(tunpack(args, 1, na))
    end
else
    local res
    if na == 0 then res = pack(f())
    elseif na == 1 then res = pack(f(R[a + 1]))
    elseif na == 2 then res = pack(f(R[a + 1], R[a + 2]))
    elseif na == 3 then res = pack(f(R[a + 1], R[a + 2], R[a + 3]))
    elseif na == 4 then res = pack(f(R[a + 1], R[a + 2], R[a + 3], R[a + 4]))
    elseif na == 5 then res = pack(f(R[a + 1], R[a + 2], R[a + 3], R[a + 4], R[a + 5]))
    else
        local args = {}
        for k = 1, na do args[k] = R[a + k] end
        res = pack(f(tunpack(args, 1, na)))
    end
    if nc == 0 then
        for k = 1, res.n do R[a + k - 1] = res[k] end
        top = a + res.n
    else
        for k = 1, nc - 1 do R[a + k - 1] = res[k] end
    end
end]=]),
    H({ 16 }, [=[local aux = code[pc]; pc = pc + 1
R[b][KV[aux + 1]] = R[a]]=], { [=[local aux = code[pc]; pc = pc + 1
local _t = R[b]; _t[KV[aux + 1]] = R[a]]=] }),
    H({ 33 }, [=[R[a] = R[b] + R[c]]=], { [=[local x, y = R[b], R[c]; R[a] = x + y]=] }),
    H({ 34 }, [=[R[a] = R[b] - R[c]]=], { [=[local x, y = R[b], R[c]; R[a] = x - y]=] }),
    H({ 35 }, [=[R[a] = R[b] * R[c]]=], { [=[local x, y = R[b], R[c]; R[a] = x * y]=] }),
    H({ 36 }, [=[R[a] = R[b] / R[c]]=]),
    H({ 37 }, [=[R[a] = R[b] % R[c]]=]),
    H({ 81 }, [=[R[a] = floor(R[b] / R[c])]=]),
    H({ 5 }, [=[R[a] = KV[hw + 1]]=], { [=[local kc = KV[hw + 1]; R[a] = kc]=] }),
    H({ 4 }, [=[R[a] = hw >= 32768 and hw - 65536 or hw]=], { [=[local _n = hw >= 32768 and hw - 65536 or hw; R[a] = _n]=] }),
    H({ 12 }, [=[local aux = code[pc]; pc = pc + 1
local count = floor(aux / 1073741824) % 4
local p0 = floor(aux / 1048576) % 1024
local v = env[KV[p0 + 1]]
if count >= 2 and v ~= nil then v = v[KV[(floor(aux / 1024) % 1024) + 1]] end
if count >= 3 and v ~= nil then v = v[KV[(aux % 1024) + 1]] end
R[a] = v]=]),
    H({ 7 }, [=[local aux = code[pc]; pc = pc + 1
R[a] = env[KV[aux + 1]]]=], { [=[local aux = code[pc]; pc = pc + 1
local kn = KV[aux + 1]
R[a] = env[kn]]=] }),
    H({ 13 }, [=[R[a] = R[b][R[c]]]=]),
    H({ 14 }, [=[R[b][R[c]] = R[a]]=]),
    H({ 17 }, [=[R[a] = R[b][c + 1]]=]),
    H({ 18 }, [=[R[b][c + 1] = R[a]]=]),
    H({ 57 }, [=[local a = a
local limit, step = R[a], R[a + 1]
local idx = R[a + 2] + step
R[a + 2] = idx
local cont
if step > 0 then cont = idx <= limit else cont = idx >= limit end
if cont then R[a + 3] = idx; pc = pc + d end]=]),
    H({ 56 }, [=[local a = a
local limit, step, idx = R[a], R[a + 1], R[a + 2]
local cont
if step > 0 then cont = idx <= limit else cont = idx >= limit end
if cont then R[a + 3] = idx else pc = pc + d end]=]),
    H({ 58 }, [=[local aux = code[pc]; pc = pc + 1
local varcount = aux % 256
local gen = R[a]
if type(gen) == "function" then
    if varcount <= 2 then
        local v1, v2 = gen(R[a + 1], R[a + 2])
        if v1 ~= nil then
            R[a + 2] = v1
            R[a + 3] = v1
            if varcount == 2 then R[a + 4] = v2 end
            pc = pc + d - 1
        end
    else
        local res = pack(gen(R[a + 1], R[a + 2]))
        if res[1] ~= nil then
            R[a + 2] = res[1]
            for k = 1, varcount do R[a + 2 + k] = res[k] end
            pc = pc + d - 1
        end
    end
else
    local key, val = next(gen, R[a + 2])
    if key ~= nil then
        R[a + 2] = key
        R[a + 3] = key
        if varcount >= 2 then R[a + 4] = val end
        pc = pc + d - 1
    end
end]=]),
    H({ 23 }, [=[pc = pc + d]=]),
    H({ 24 }, [=[pc = pc + d]=]),
    H({ 25 }, [=[if R[a] then pc = pc + d end]=], { [=[local _v = R[a]; if _v then pc = pc + d end]=] }),
    H({ 26 }, [=[if not R[a] then pc = pc + d end]=], { [=[local _v = R[a]; if not _v then pc = pc + d end]=] }),
    H({ 27 }, [=[local aux = code[pc]; pc = pc + 1; if R[a] == R[aux] then pc = pc + d - 1 end]=]),
    H({ 28 }, [=[local aux = code[pc]; pc = pc + 1; if R[a] <= R[aux] then pc = pc + d - 1 end]=]),
    H({ 29 }, [=[local aux = code[pc]; pc = pc + 1; if R[a] < R[aux] then pc = pc + d - 1 end]=]),
    H({ 30 }, [=[local aux = code[pc]; pc = pc + 1; if R[a] ~= R[aux] then pc = pc + d - 1 end]=]),
    H({ 31 }, [=[local aux = code[pc]; pc = pc + 1; if not (R[a] <= R[aux]) then pc = pc + d - 1 end]=]),
    H({ 32 }, [=[local aux = code[pc]; pc = pc + 1; if not (R[a] < R[aux]) then pc = pc + d - 1 end]=]),
    H({ 22 }, [=[local nb = b
if nb == 2 then return R[a]
elseif nb == 3 then return R[a], R[a + 1]
elseif nb == 4 then return R[a], R[a + 1], R[a + 2]
elseif nb == 5 then return R[a], R[a + 1], R[a + 2], R[a + 3]
elseif nb == 6 then return R[a], R[a + 1], R[a + 2], R[a + 3], R[a + 4]
elseif nb == 1 then return
else
    local out, n = {}, 0
    if nb == 0 then
        for r = a, top - 1 do n = n + 1; out[n] = R[r] end
    else
        for r = a, a + nb - 2 do n = n + 1; out[n] = R[r] end
    end
    return tunpack(out, 1, n)
end]=], nil, true),
    H({ 39 }, [=[R[a] = R[b] + KV[c + 1]]=]),
    H({ 40 }, [=[R[a] = R[b] - KV[c + 1]]=]),
    H({ 41 }, [=[R[a] = R[b] * KV[c + 1]]=]),
    H({ 42 }, [=[R[a] = R[b] / KV[c + 1]]=]),
    H({ 43 }, [=[R[a] = R[b] % KV[c + 1]]=]),
    H({ 44 }, [=[R[a] = R[b] ^ KV[c + 1]]=]),
    H({ 38 }, [=[R[a] = R[b] ^ R[c]]=]),
    H({ 82 }, [=[R[a] = floor(R[b] / KV[c + 1])]=]),
    H({ 71 }, [=[R[a] = KV[b + 1] - R[c]]=]),
    H({ 72 }, [=[R[a] = KV[b + 1] / R[c]]=]),
    H({ 49 }, [=[local s = R[b]
for r = b + 1, c do s = s .. R[r] end
R[a] = s]=]),
    H({ 50 }, [=[R[a] = not R[b]]=]),
    H({ 51 }, [=[R[a] = -R[b]]=]),
    H({ 52 }, [=[R[a] = #R[b]]=]),
    H({ 45 }, [=[local bv = R[b]; if bv then R[a] = R[c] else R[a] = bv end]=]),
    H({ 46 }, [=[local bv = R[b]; if bv then R[a] = bv else R[a] = R[c] end]=]),
    H({ 47 }, [=[local bv = R[b]; if bv then R[a] = KV[c + 1] else R[a] = bv end]=]),
    H({ 48 }, [=[local bv = R[b]; if bv then R[a] = bv else R[a] = KV[c + 1] end]=]),
    H({ 66 }, [=[local aux = code[pc]; pc = pc + 1
R[a] = KV[aux + 1]]=]),
    H({ 3 }, [=[R[a] = b ~= 0
if c ~= 0 then pc = pc + c end]=]),
    H({ 2 }, [=[R[a] = nil]=]),
    H({ 8 }, [=[local aux = code[pc]; pc = pc + 1
env[KV[aux + 1]] = R[a]]=]),
    H({ 9 }, [=[local uv = upvals[b + 1]; if uv.open then R[a] = uv.stack[uv.idx] else R[a] = uv.val end]=]),
    H({ 10 }, [=[local uv = upvals[b + 1]; if uv.open then uv.stack[uv.idx] = R[a] else uv.val = R[a] end]=]),
    H({ 11 }, [=[closeFrom(openuv, R, a)]=]),
    H({ 53 }, [=[pc = pc + 1
R[a] = {}]=]),
    H({ 54 }, [=[local tmpl = Kraw[hw + 1]
local t = {}
if tmpl[1] == 5 then
    for _, keyIdx in ipairs(tmpl[2]) do t[KV[keyIdx + 1]] = 0 end
elseif tmpl[1] == 8 then
    for _, e in ipairs(tmpl[2]) do
        local ek1 = e[1]
        local ek2 = e[2]
        local kv = KV[ek1 + 1]
        if ek2 >= 0 then t[kv] = KV[ek2 + 1] end
    end
end
R[a] = t]=]),
    H({ 55 }, [=[local aux = code[pc]; pc = pc + 1
local t = R[a]
local b = b
local cnt = c
if cnt == 0 then cnt = top - b else cnt = cnt - 1 end
for k = 0, cnt - 1 do t[aux + k] = R[b + k] end]=]),
    H({ 19 }, [=[local cp = protos[childprotos[hw + 1] + 1]
local ups = {}
R[a] = makeClosure(bc, cp, env, ups)
pc = fillCaptures(code, pc, cp, ups, R, upvals, openuv)]=]),
    H({ 64 }, [=[local cp = protos[KV[hw + 1] + 1]
local ups = {}
R[a] = makeClosure(bc, cp, env, ups)
pc = fillCaptures(code, pc, cp, ups, R, upvals, openuv)]=]),
    H({ 70 }, [=[]=]),
    H({ 63 }, [=[local a = a
local nb = b
if nb == 0 then
    for k = 1, nva do R[a + k - 1] = varargs[k] end
    top = a + nva
else
    for k = 1, nb - 1 do R[a + k - 1] = varargs[k] end
end]=]),
    H({ 65 }, [=[]=]),
    H({ 0 }, [=[]=]),
    H({ 1 }, [=[]=]),
    H({ 69 }, [=[]=]),
    H({ 62 }, [=[]=]),
    H({ 68 }, [=[]=]),
    H({ 73 }, [=[]=]),
    H({ 74 }, [=[pc = pc + 1]=]),
    H({ 75 }, [=[pc = pc + 1]=]),
    H({ 60 }, [=[pc = pc + 1]=]),
    H({ 67 }, [=[local e = floor(insn / 256) % 16777216; if e >= 8388608 then e = e - 16777216 end; pc = pc + e]=]),
    H({ 77 }, [=[local aux = code[pc]; pc = pc + 1
local notf = floor(aux / 2147483648) % 2 == 1
local cmp = R[a] == nil
if notf then cmp = not cmp end
if cmp then pc = pc + d - 1 end]=]),
    H({ 78 }, [=[local aux = code[pc]; pc = pc + 1
local notf = floor(aux / 2147483648) % 2 == 1
local kv = (aux % 2) == 1
local cmp = R[a] == kv
if notf then cmp = not cmp end
if cmp then pc = pc + d - 1 end]=]),
    H({ 79, 80 }, [=[local aux = code[pc]; pc = pc + 1
local notf = floor(aux / 2147483648) % 2 == 1
local kidx = aux % 16777216
local cmp = R[a] == KV[kidx + 1]
if notf then cmp = not cmp end
if cmp then pc = pc + d - 1 end]=]),
    H({ 76, 61, 59 }, [=[pc = pc + d]=]),
    H({ 83 }, [=[local aux = code[pc]; pc = pc + 1
R[a] = R[b][KV[aux % 65536 + 1]]]=]),
    H({ 84 }, [=[local aux = code[pc]; pc = pc + 1
R[b][KV[aux % 65536 + 1]] = R[a]]=]),
    H({ 85 }, [=[local aux = code[pc]; pc = pc + 1
local self = R[b]
R[a + 1] = self
R[a] = self[KV[aux % 65536 + 1]]]=]),
    H({ 86 }, [=[pc = pc + 1]=]),
    H({ 88 }, [=[pc = pc + 1
pc = pc + hw]=]),
}

----------------------------------------------------------------------
-- Field-decode variants. Each produces locals op,a,b,c,d from `insn` (and
-- applies opmap). `assign` controls `local x` (inline) vs bare `x` (table-mode
-- upvalues). All variants are arithmetically equivalent.
----------------------------------------------------------------------

local function fieldDecode(variant, decl)
    local lp = decl and "local " or ""
    if variant == 2 then
        return table.concat({
            lp .. "op = opmap[insn % 256]",
            lp .. "a = floor(insn / 256) % 256",
            lp .. "hw = floor(insn / 65536)",
            lp .. "b = hw % 256",
            lp .. "c = floor(hw / 256)",
            lp .. "d = hw >= 32768 and hw - 65536 or hw",
        }, "\n")
    end
    -- variant 1: same fields, different local ordering for structural variation.
    -- NB: every line must honour `lp`. Under table dispatch (decl=false) these are
    -- bare assignments to the shared upvalues declared in emitTableDispatch; a
    -- hardcoded `local hw` here would shadow that upvalue and leave the handlers'
    -- copy of hw nil.
    return table.concat({
        lp .. "op = opmap[insn % 256]",
        lp .. "a = floor(insn / 256) % 256",
        lp .. "hw = floor(insn / 65536)",
        lp .. "b = hw % 256",
        lp .. "c = floor(hw / 256)",
        lp .. "d = hw >= 32768 and hw - 65536 or hw",
    }, "\n")
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function indent(src, pad)
    local out = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do
        if line == "" then out[#out + 1] = "" else out[#out + 1] = pad .. line end
    end
    return table.concat(out, "\n")
end

-- Pick a (possibly alternative) body for a handler.
local function pickBody(h, useVariants)
    if useVariants and h.alts and #h.alts > 0 and math.random() < 0.5 then
        return h.alts[math.random(1, #h.alts)]
    end
    return h.body
end

-- Condition for an if/elseif branch covering one or more ops.
local function condFor(ops)
    local parts = {}
    for _, o in ipairs(ops) do parts[#parts + 1] = "op == " .. o end
    return table.concat(parts, " or ")
end

local ERR = [[error("interp: unimplemented opcode " .. op .. " at pc " .. (pc - 1))]]

----------------------------------------------------------------------
-- Dispatch emitters. Each returns the full text that replaces the loop region
-- (from just after the varargs setup through the while loop's closing `end`).
----------------------------------------------------------------------

-- A flat or segment-nested if/elseif chain. `segments` >= 1; with >1 the shuffled
-- branch list is broken into that many contiguous groups, each rendered as its
-- own if/elseif chain nested inside the previous group's `else`. Correct by
-- construction: every opcode still appears in exactly one branch, and a group's
-- `else` falls through to the next group (or to the error at the innermost one).
local function emitInlineChain(branches, useVariants, fieldVariant, segments)
    local total = #branches
    local seg = math.max(1, math.min(segments, total))

    -- Partition into `seg` contiguous groups, each with >= 1 branch.
    local groups = {}
    local pos = 1
    for s = 1, seg do
        local remainingGroups = seg - s + 1
        local remainingItems = total - pos + 1
        local sz = (s == seg) and remainingItems
            or math.max(1, math.min(remainingItems - (remainingGroups - 1),
                math.floor(remainingItems / remainingGroups)))
        local g = {}
        for _ = 1, sz do g[#g + 1] = branches[pos]; pos = pos + 1 end
        groups[s] = g
    end

    -- Render group s (1-based), nesting deeper groups in its else.
    local function renderGroup(s)
        local g = groups[s]
        local b = {}
        for i, h in ipairs(g) do
            local kw = (i == 1) and "if" or "elseif"
            b[#b + 1] = kw .. " " .. condFor(h.ops) .. " then"
            local body = pickBody(h, useVariants)
            if #body > 0 then b[#b + 1] = body end
        end
        b[#b + 1] = "else"
        if s == seg then b[#b + 1] = ERR else b[#b + 1] = renderGroup(s + 1) end
        b[#b + 1] = "end"
        return table.concat(b, "\n")
    end

    local body = {}
    body[#body + 1] = "while true do"
    body[#body + 1] = "local insn = code[pc]"
    body[#body + 1] = "pc = pc + 1"
    body[#body + 1] = fieldDecode(fieldVariant, true)
    body[#body + 1] = renderGroup(1)
    body[#body + 1] = "end"
    return table.concat(body, "\n")
end

-- op -> closure table. Handlers close over run()'s locals (op/a/b/c/d/pc/R/...).
-- RETURN cannot `return` out of run from inside a closure, so it sets a shared
-- __DONE/__RET protocol the loop checks.
local function emitTableDispatch(branches, useVariants, fieldVariant)
    local pad = "        "
    local lines = {}
    -- All fields decoded each step are upvalues shared with the handler closures.
    -- `d` MUST be here: omitting it makes `d = ...` write a global that recursive
    -- run() calls (nested closures) clobber, corrupting jumps across frames.
    lines[#lines + 1] = pad .. "local op, a, b, c, d, hw, insn"
    lines[#lines + 1] = pad .. "local __DONE, __RET = false, nil"
    lines[#lines + 1] = pad .. "local H = {}"
    for _, h in ipairs(branches) do
        local body
        if h.ret then
            -- table-mode RETURN: capture results + signal instead of returning.
            body = [=[local nb = b
if nb == 2 then __RET = pack(R[a])
elseif nb == 3 then __RET = pack(R[a], R[a + 1])
elseif nb == 4 then __RET = pack(R[a], R[a + 1], R[a + 2])
elseif nb == 5 then __RET = pack(R[a], R[a + 1], R[a + 2], R[a + 3])
elseif nb == 6 then __RET = pack(R[a], R[a + 1], R[a + 2], R[a + 3], R[a + 4])
elseif nb == 1 then __RET = pack()
else
    local out, n = {}, 0
    if nb == 0 then
        for r = a, top - 1 do n = n + 1; out[n] = R[r] end
    else
        for r = a, a + nb - 2 do n = n + 1; out[n] = R[r] end
    end
    __RET = pack(tunpack(out, 1, n))
end
__DONE = true]=]
        else
            body = pickBody(h, useVariants)
        end
        lines[#lines + 1] = pad .. "do"
        lines[#lines + 1] = pad .. "    local _h = function()"
        if #body > 0 then lines[#lines + 1] = indent(body, pad .. "        ") end
        lines[#lines + 1] = pad .. "    end"
        for _, o in ipairs(h.ops) do
            lines[#lines + 1] = pad .. "    H[" .. o .. "] = _h"
        end
        lines[#lines + 1] = pad .. "end"
    end
    lines[#lines + 1] = pad .. "while true do"
    lines[#lines + 1] = pad .. "    insn = code[pc]"
    lines[#lines + 1] = pad .. "    pc = pc + 1"
    lines[#lines + 1] = indent(fieldDecode(fieldVariant, false), pad .. "    ")
    lines[#lines + 1] = pad .. "    local _f = H[op]"
    lines[#lines + 1] = pad .. "    if _f then _f() else " .. ERR .. " end"
    lines[#lines + 1] = pad .. "    if __DONE then return tunpack(__RET, 1, __RET.n) end"
    lines[#lines + 1] = pad .. "end"
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Register-table setup + state-layout (register offset) remap.
--
-- This block lives between --@LOOP_BEGIN and the dispatch loop in interp.lua, so
-- the generator owns it and can apply the offset to the parameter-load site too.
-- Kept semantically identical to interp.lua's setup for the no-remap path.
----------------------------------------------------------------------

local SETUP_TEMPLATE = [=[
local KV   = proto[6]
local KT   = proto[8]
local Kraw = proto[9]
local childprotos = proto[7]
local protos = bc[2]
local R = tcreate and tcreate(proto[1]) or {}
local pc=1; local top=0; local openuv={}
local nargs
local isFast = type(packedArgs)=="number"
if isFast then
    nargs=packedArgs
    if nargs>=1 then R[0]=a1 end
    if nargs>=2 then R[1]=a2 end
    if nargs>=3 then R[2]=a3 end
    if nargs>=4 then R[3]=a4 end
    if nargs>=5 then R[4]=a5 end
else
    nargs=packedArgs.n or #packedArgs
    for i=1,numparams do R[i-1]=packedArgs[i] end
end
local varargs,nva=nil,0
if proto[4]==1 and nargs > numparams then
    varargs={}
    if isFast then
        local va={a1,a2,a3,a4,a5}
        for i=numparams+1,nargs do nva=nva+1; varargs[nva]=va[i] end
    else
        for i=numparams+1,nargs do nva=nva+1; varargs[nva]=packedArgs[i] end
    end
end]=]

-- Apply the register offset: every R-index site R[<expr>] becomes R[(<expr>)+OFF]
-- (OFF is a per-build local constant). Register indices in our bodies never
-- contain nested brackets, so the [^%[%]]+ capture is exact and won't touch the
-- second bracket of R[b][...] (that's a table index on a value, not a register).
-- Upvalue records hold PHYSICAL indices, so getOpen/closeFrom/uvget/uvset stay
-- as-is; only the two helper boundaries that take a LOGICAL register need +OFF:
-- closeFrom's threshold and fillCaptures' roff argument.
local function transformRegisterOffset(src)
    src = src:gsub("R%[([^%[%]]+)%]", "R[(%1)+OFF]")
    src = src:gsub("closeFrom%(openuv, R, a%)", "closeFrom(openuv, R, a + OFF)")
    src = src:gsub("fillCaptures%(code, pc, cp, ups, R, upvals, openuv%)",
        "fillCaptures(code, pc, cp, ups, R, upvals, openuv, OFF)")
    return src
end

-- Constant-table relocation: the KV/KT/Kraw arrays are padded with KOFF dummy
-- leading entries by the emitter (see emit.lua), so logical constant index `ci`
-- lives at array position ci+1+KOFF. Every KV-index site KV[<expr>+1] becomes
-- KV[(<expr>+1)+KOFF], and same for KT and Kraw.
local function transformConstOffset(src)
    src = src:gsub("KV%[([^%[%]]+)%]", "KV[(%1)+KOFF]")
    src = src:gsub("KT%[([^%[%]]+)%]", "KT[(%1)+KOFF]")
    src = src:gsub("Kraw%[([^%[%]]+)%]", "Kraw[(%1)+KOFF]")
    return src
end

-- Opcodes that are hot in every real Roblox/ESP workload. These are placed in
-- the first third of the dispatch chain so they cost fewest comparisons to reach.
-- The canonical opcode numbers are what the handler list uses (pre-remap).
local HOT_OPS = {
    [6]  = true,  -- MOVE          (register copy, extremely common)
    [15] = true,  -- GETTABLEKS    (property read: part.Position, draw.Color, ...)
    [20] = true,  -- NAMECALL      (method call: obj:Method(...))
    [21] = true,  -- CALL          (function call)
    [87] = true,  -- CALLFB        (call fallback, same handler as CALL)
    [16] = true,  -- SETTABLEKS    (property write)
    [33] = true,  -- ADD
    [34] = true,  -- SUB
    [35] = true,  -- MUL
    [36] = true,  -- DIV
    [57] = true,  -- FORNLOOP      (numeric for body)
    [58] = true,  -- FORGLOOP      (generic for body)
    [22] = true,  -- RETURN
    [23] = true,  -- JUMP
    [24] = true,  -- JUMPBACK
    [25] = true,  -- JUMPIF
    [26] = true,  -- JUMPIFNOT
}

-- Biased shuffle: hot handlers go into the first zone (shuffled among themselves),
-- cold handlers fill the rest (also shuffled). This keeps the hottest opcodes near
-- the top of the if/elseif chain so they cost fewest comparisons per dispatch.
-- Security is unchanged: the attacker sees a shuffled chain with remapped op values.
local function biasedShuffle(handlers)
    local hot, cold = {}, {}
    for _, h in ipairs(handlers) do
        local isHot = false
        for _, op in ipairs(h.ops) do
            if HOT_OPS[op] then isHot = true; break end
        end
        if isHot then hot[#hot + 1] = h else cold[#cold + 1] = h end
    end
    shuffle(hot)
    shuffle(cold)
    local result = {}
    for _, h in ipairs(hot)  do result[#result + 1] = h end
    for _, h in ipairs(cold) do result[#result + 1] = h end
    return result
end

-- Slice interp.lua at the markers into: head (verbatim prelude up to the loop),
-- midTail (the `end` closing run, between the loop and the entry wrapper), and
-- endTail (everything after the entry wrapper). The entry wrapper itself is
-- regenerated so schema S1 can inject the nonce-derivation.
local function sliceInterp(interpSrc)
    local lb = interpSrc:find("%-%-@LOOP_BEGIN")
    local le1, le2 = interpSrc:find("%-%-@LOOP_END")
    local eb1 = interpSrc:find("%-%-@ENTRY_BEGIN")
    local ee1, ee2 = interpSrc:find("%-%-@ENTRY_END")
    assert(lb and le1 and eb1 and ee1,
        "interpgen: interp.lua is missing --@LOOP_BEGIN/--@LOOP_END/--@ENTRY_BEGIN/--@ENTRY_END markers")
    local head = interpSrc:sub(1, lb - 1)
    local midTail = interpSrc:sub(le2 + 1, eb1 - 1)
    local endTail = interpSrc:sub(ee2 + 1)
    return head, midTail, endTail
end

-- Entry wrapper, legacy (schema S0): opmap/bkey/bstep are already serialized.
local LEGACY_WRAPPER = [=[
return function(bc, env, ...)
    env = env or (getfenv and getfenv()) or _G
    return run(bc, bc[2][bc[1] + 1], env, nil, pack(...))
end]=]

-- Entry wrapper, schema S1 (data-plane polymorphism): the container stores only a
-- nonce at bc[3]; derive opmap (inverse opcode map) + bkey/bstep ONCE here and
-- stash them into bc[3]/bc[4]/bc[5] so run() (verbatim) reads them as before.
-- This integer math MUST match Remap.derivePerm/deriveKeys exactly.
local DERIVE_WRAPPER = [=[
return function(bc, env, ...)
    env = env or (getfenv and getfenv()) or _G
    local N = bc[3]
    local s = N % 2147483647
    if s == 0 then s = 1 end
    local ids = {}
    for i = 0, 88 do ids[i + 1] = i end
    for i = 89, 2, -1 do
        s = (s * 16807) % 2147483647
        local j = (s % i) + 1
        ids[i], ids[j] = ids[j], ids[i]
    end
    local opmap = {}
    for i = 0, 88 do opmap[ids[i + 1]] = i end
    local t = (N * 16807 + 1) % 2147483647
    t = (t * 16807) % 2147483647; local hi = t % 65536
    t = (t * 16807) % 2147483647; local lo = t % 65536
    t = (t * 16807) % 2147483647; local bstep = (t % 65535) * 2 + 1
    bc[3] = opmap
    bc[4] = hi * 65536 + lo
    bc[5] = bstep
    return run(bc, bc[2][bc[1] + 1], env, nil, pack(...))
end]=]

-- generate(interpSrc, opts) -> interpreterSource, style, registerOffset, constOffset.
-- opts.Style: "ifelse" | "split" | "table" | "random" (default "random").
-- opts.HandlerVariants: bool (default true).
-- opts.RegisterRemap: bool | "random" (default false) -- per-build register-index
--   offset (state-layout remap).
-- opts.ConstRemap: bool | "random" (default false) -- per-build constant-table
--   offset. The returned constOffset must be passed to Emit.build so the emitted
--   constants array is padded to match.
-- opts.Derive: bool (default false) -- schema S1: emit the nonce-deriving entry
--   wrapper (opmap/bkey/bstep rebuilt at runtime from bc[3]). The caller must
--   serialize the container with bc.nonce set (see LuauBytecode + emit.lua).
function Interpgen.generate(interpSrc, opts)
    opts = opts or {}
    local head, midTail, endTail = sliceInterp(interpSrc)

    local style = opts.Style or "random"
    if style == "random" then
        -- Exclude "table": it adds a __DONE check + H[op] lookup after every
        -- instruction, which is significant per-frame overhead. "ifelse" and "split"
        -- are structurally different between builds (different branch nesting/order)
        -- without any per-instruction overhead beyond the branch chain itself.
        style = ({ "ifelse", "split" })[math.random(1, 2)]
    end
    local useVariants = opts.HandlerVariants ~= false
    local fieldVariant = math.random(1, 2)

    local remap = opts.RegisterRemap
    if remap == "random" then remap = math.random() < 0.5 end
    local off = remap and math.random(8, 250) or 0

    local kremap = opts.ConstRemap
    if kremap == "random" then kremap = math.random() < 0.5 end
    local koff = kremap and math.random(4, 64) or 0

    -- Biased shuffle: hot opcodes first, cold ops after.
    -- Both zones are independently shuffled so the chain still looks random.
    local branches = biasedShuffle(HANDLERS)

    -- Separate hot and cold for the split-mode optimization.
    local hotBranches, coldBranches = {}, {}
    for _, h in ipairs(branches) do
        local isHot = false
        for _, op in ipairs(h.ops) do
            if HOT_OPS[op] then isHot = true; break end
        end
        if isHot then hotBranches[#hotBranches + 1] = h
        else coldBranches[#coldBranches + 1] = h end
    end

    local dispatch
    if style == "table" then
        dispatch = emitTableDispatch(branches, useVariants, fieldVariant)
    elseif style == "split" then
        -- Optimized split: hot handlers are ALWAYS in segment 1 (flat, no nesting
        -- overhead). Only cold handlers get nested into 2-3 sub-segments.
        -- This gives the same structural variation for anti-analysis on the cold
        -- path while keeping zero extra comparison cost on the hot path.
        local coldSegs = math.random(2, 3)
        -- Build combined list: hot group first (1 flat segment), then cold split.
        -- We achieve this by constructing a merged branch list where the first
        -- #hotBranches entries form segment 1 and the rest split into coldSegs.
        -- emitInlineChain partitions contiguously, so we pass total segs = coldSegs+1
        -- and the first segment gets exactly the hot handlers if we size it right.
        -- Simpler: emit hot as flat chain, cold as nested chain, concatenate.
        local hotDispatch = emitInlineChain(hotBranches, useVariants, fieldVariant, 1)
        -- Extract just the inner if/elseif chain from the hot dispatch (strip while+field)
        -- Actually easier: emit cold as standalone nested chain, then inline into one loop.
        -- Build a single merged list with total = #hot + #cold, segs = coldSegs + 1,
        -- but force first segment size = #hotBranches exactly.
        -- We do this by creating a custom ordered list and using segments = coldSegs+1
        -- with emitInlineChain, knowing the first segment cuts at #hotBranches.
        local merged = {}
        for _, h in ipairs(hotBranches) do merged[#merged + 1] = h end
        for _, h in ipairs(coldBranches) do merged[#merged + 1] = h end
        -- Override emitInlineChain to use exact first-segment size.
        -- Patch: use segments = coldSegs + 1 and the contiguous partition will
        -- naturally give the first segment ~(total/(coldSegs+1)) handlers.
        -- To guarantee exactly #hotBranches in segment 1, call emitInlineChain
        -- with a custom approach: treat hot as 1 segment, cold as coldSegs segments.
        dispatch = (function()
            local total = #merged
            local seg = coldSegs + 1
            -- Build groups manually: group 1 = all hot, groups 2..seg = cold split.
            local groups = {}
            groups[1] = hotBranches
            local coldTotal = #coldBranches
            local cpos = 1
            for s = 2, seg do
                groups[s] = {}
                local remaining = seg - s
                local items = coldTotal - cpos + 1
                local sz = (s == seg) and items
                    or math.max(1, math.floor(items / (remaining + 1)))
                for _ = 1, sz do
                    if cpos <= coldTotal then
                        groups[s][#groups[s] + 1] = coldBranches[cpos]
                        cpos = cpos + 1
                    end
                end
            end
            -- Render using the same renderGroup logic as emitInlineChain.
            local function renderGroup(s)
                local g = groups[s]
                if not g or #g == 0 then return ERR end
                local b = {}
                for i, h in ipairs(g) do
                    local kw = (i == 1) and "if" or "elseif"
                    b[#b + 1] = kw .. " " .. condFor(h.ops) .. " then"
                    local body = pickBody(h, useVariants)
                    if #body > 0 then b[#b + 1] = body end
                end
                b[#b + 1] = "else"
                if s == seg then b[#b + 1] = ERR else b[#b + 1] = renderGroup(s + 1) end
                b[#b + 1] = "end"
                return table.concat(b, "\n")
            end
            local body = {}
            body[#body + 1] = "while true do"
            body[#body + 1] = "local insn = code[pc]"
            body[#body + 1] = "pc = pc + 1"
            body[#body + 1] = fieldDecode(fieldVariant, true)
            body[#body + 1] = renderGroup(1)
            body[#body + 1] = "end"
            return table.concat(body, "\n")
        end)()
    else
        dispatch = emitInlineChain(branches, useVariants, fieldVariant, 1)
    end

    -- Assemble the generator-owned region (register setup + dispatch), apply the
    -- offset transforms, and declare the offset constants.
    local middle = SETUP_TEMPLATE .. "\n" .. dispatch
    if off ~= 0 then middle = transformRegisterOffset(middle) end
    if koff ~= 0 then middle = transformConstOffset(middle) end
    local decls = {}
    if off ~= 0 then decls[#decls + 1] = "local OFF = " .. off end
    if koff ~= 0 then decls[#decls + 1] = "local KOFF = " .. koff end
    if #decls > 0 then middle = table.concat(decls, "\n") .. "\n" .. middle end

    local wrapper = opts.Derive and DERIVE_WRAPPER or LEGACY_WRAPPER
    return head .. "\n" .. middle .. "\n" .. midTail .. "\n" .. wrapper .. "\n" .. endTail,
        style, off, koff
end

return Interpgen
