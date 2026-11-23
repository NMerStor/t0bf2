
-- customvm/compiler.lua


local Ast = require("catph.ast")
local ISA = require("catph.customvm.isa")

local AstKind = Ast.AstKind
local OP = ISA.OP
local MULTRET = ISA.MULTRET

local Compiler = {}


local BINOP = {
    [AstKind.AddExpression]  = OP.ADD,
    [AstKind.SubExpression]  = OP.SUB,
    [AstKind.MulExpression]  = OP.MUL,
    [AstKind.DivExpression]  = OP.DIV,
    [AstKind.ModExpression]  = OP.MOD,
    [AstKind.PowExpression]  = OP.POW,
    [AstKind.IDivExpression] = OP.IDIV,
}

local UNOP = {
    [AstKind.NotExpression]    = OP.NOT,
    [AstKind.NegateExpression] = OP.MINUS,
    [AstKind.LenExpression]    = OP.LENGTH,
}


local COMPARE = {
    [AstKind.EqualsExpression]              = { OP.JUMPIFEQ, false },
    [AstKind.NotEqualsExpression]           = { OP.JUMPIFEQ, false, negate = true },
    [AstKind.LessThanExpression]            = { OP.JUMPIFLT, false },
    [AstKind.LessThanOrEqualsExpression]    = { OP.JUMPIFLE, false },
    [AstKind.GreaterThanExpression]         = { OP.JUMPIFLT, true },
    [AstKind.GreaterThanOrEqualsExpression] = { OP.JUMPIFLE, true },
}



local FuncState = {}
FuncState.__index = FuncState

local function newFuncState(parent)
    return setmetatable({
        parent = parent,
        code = {},
        k = {},
        klookup = {},
        protos = {},    
        upvals = {},      
        upvalLookup = {}, 
        anyCapture = false,
        freereg = 0,
        nactive = 0,
        maxstack = 0,
        localRegs = {},   
        loops = {},       
    }, FuncState)
end


local function resolveUpval(fs, scope, id)
    local key = tostring(scope) .. "#" .. tostring(id)
    if fs.upvalLookup[key] then return fs.upvalLookup[key] end
    local parent = fs.parent
    if not parent then return nil end

    local pm = parent.localRegs[scope]
    local idx
    if pm and pm[id] ~= nil then
        idx = #fs.upvals + 1
        fs.upvals[idx] = { kind = "local", index = pm[id] }
        parent.anyCapture = true
    else
        local pu = resolveUpval(parent, scope, id)
        if not pu then return nil end
        idx = #fs.upvals + 1
        fs.upvals[idx] = { kind = "upval", index = pu }
    end
    fs.upvalLookup[key] = idx
    return idx
end


function FuncState:emit(op, a, b, c, k)
    self.code[#self.code + 1] = { op = op, a = a, b = b, c = c, k = k }
    return #self.code
end


function FuncState:patchJump(idx, target)
    self.code[idx].b = target - (idx + 1)
end


function FuncState:patchHere(idx)
    self.code[idx].b = (#self.code + 1) - (idx + 1)
end

function FuncState:setReg(r)
    if r + 1 > self.maxstack then self.maxstack = r + 1 end
end

function FuncState:constK(value)
    local key = type(value) .. ":" .. tostring(value)
    local idx = self.klookup[key]
    if idx then return idx end
    self.k[#self.k + 1] = value
    idx = #self.k
    self.klookup[key] = idx
    return idx
end

function FuncState:setLocal(scope, id, reg)
    local m = self.localRegs[scope]
    if not m then m = {}; self.localRegs[scope] = m end
    m[id] = reg
end

function FuncState:getLocal(scope, id)
    local m = self.localRegs[scope]
    local r = m and m[id]
    if r == nil then
        error("customvm compiler: unresolved local '"
            .. tostring(scope:getVariableName(id)) .. "' (register not assigned)")
    end
    return r
end



local compileExprToReg, compileExprAnyReg, compileBlock, compileStat
local compileCallCore, compileOpenList, compileExprList, compileTable
local compileCompareToReg, compileFunction, compileMethodCore, compileMultiTo

local function isMultiExpr(node)
    return node.kind == AstKind.FunctionCallExpression
        or node.kind == AstKind.PassSelfFunctionCallExpression
        or node.kind == AstKind.VarargExpression
end


function compileMultiTo(fs, node, dst, count)
    local k = node.kind
    if k == AstKind.FunctionCallExpression then
        compileCallCore(fs, node, dst, count)
    elseif k == AstKind.PassSelfFunctionCallExpression then
        compileMethodCore(fs, node, dst, count)
    elseif k == AstKind.VarargExpression then
        fs:emit(OP.GETVARARGS, dst, (count == MULTRET) and 0 or (count + 1))
    else
        error("customvm compiler: not a multi-valued expression: " .. tostring(k))
    end
end




function compileExprAnyReg(fs, node)
    if node.kind == AstKind.VariableExpression and not node.scope.isGlobal then
        local m = fs.localRegs[node.scope]
        if m and m[node.id] ~= nil then
            return m[node.id], false  
        end
    end
    local r = fs.freereg
    fs.freereg = fs.freereg + 1
    fs:setReg(r)
    compileExprToReg(fs, node, r)
    return r, true
end


local function compileConcat(fs, node, dst)
    local operands = {}
    local function gather(n)
        if n.kind == AstKind.StrCatExpression then
            gather(n.lhs); gather(n.rhs)
        else
            operands[#operands + 1] = n
        end
    end
    gather(node)

    local base = fs.freereg
    for i = 1, #operands do
        local r = base + i - 1
        fs.freereg = r + 1
        fs:setReg(r)
        compileExprToReg(fs, operands[i], r)
    end
    fs:emit(OP.CONCAT, dst, base, base + #operands - 1)
    fs.freereg = base
end


function compileCompareToReg(fs, node, dst)
    local spec = COMPARE[node.kind]
    local op, swap, negate = spec[1], spec[2], spec.negate
    local rl = compileExprAnyReg(fs, node.lhs)
    local rr = compileExprAnyReg(fs, node.rhs)
    local ra, rb = rl, rr
    if swap then ra, rb = rr, rl end
    local jumpVal = negate and 0 or 1  
    local fallVal = negate and 1 or 0
    local jc = fs:emit(op, ra, nil, rb)  
    fs:emit(OP.LOADB, dst, fallVal)
    local jj = fs:emit(OP.JUMP)
    fs:emit(OP.LOADB, dst, jumpVal)
    fs.code[jc].b = 2  
    fs.code[jj].b = 1   
end

function compileExprToReg(fs, node, dst)
    local saved = fs.freereg
    local k = node.kind

    if k == AstKind.NumberExpression or k == AstKind.StringExpression
        or k == AstKind.LongStringExpression then
        fs:emit(OP.LOADK, dst, nil, nil, fs:constK(node.value))

    elseif k == AstKind.BooleanExpression then
        fs:emit(OP.LOADB, dst, node.value and 1 or 0)

    elseif k == AstKind.NilExpression then
        fs:emit(OP.LOADNIL, dst)

    elseif k == AstKind.VariableExpression then
        if node.scope.isGlobal then
            fs:emit(OP.GETGLOBAL, dst, nil, nil, fs:constK(node.scope:getVariableName(node.id)))
        else
            local m = fs.localRegs[node.scope]
            if m and m[node.id] ~= nil then
                local r = m[node.id]
                if r ~= dst then fs:emit(OP.MOVE, dst, r) end
            else
                local u = resolveUpval(fs, node.scope, node.id)
                if not u then
                    error("customvm compiler: unresolved variable '"
                        .. tostring(node.scope:getVariableName(node.id)) .. "'")
                end
                fs:emit(OP.GETUPVAL, dst, u)
            end
        end

    elseif BINOP[k] then
        local b = compileExprAnyReg(fs, node.lhs)
        local c = compileExprAnyReg(fs, node.rhs)
        fs:emit(BINOP[k], dst, b, c)

    elseif UNOP[k] then
        local b = compileExprAnyReg(fs, node.rhs)
        fs:emit(UNOP[k], dst, b)

    elseif k == AstKind.StrCatExpression then
        compileConcat(fs, node, dst)

    elseif k == AstKind.IndexExpression then
        local b = compileExprAnyReg(fs, node.base)
        if node.index.kind == AstKind.StringExpression then
            fs:emit(OP.GETTABLEKS, dst, b, nil, fs:constK(node.index.value))
        else
            local c = compileExprAnyReg(fs, node.index)
            fs:emit(OP.GETTABLE, dst, b, c)
        end

    elseif k == AstKind.FunctionCallExpression then
        local base = fs.freereg
        compileCallCore(fs, node, base, 1)
        if dst ~= base then fs:emit(OP.MOVE, dst, base) end

    elseif k == AstKind.TableConstructorExpression then
        compileTable(fs, node, dst)

    elseif COMPARE[k] then
        compileCompareToReg(fs, node, dst)

    elseif k == AstKind.AndExpression then
        compileExprToReg(fs, node.lhs, dst)
        local j = fs:emit(OP.JUMPIFNOT, dst)
        compileExprToReg(fs, node.rhs, dst)
        fs:patchHere(j)

    elseif k == AstKind.OrExpression then
        compileExprToReg(fs, node.lhs, dst)
        local j = fs:emit(OP.JUMPIF, dst)
        compileExprToReg(fs, node.rhs, dst)
        fs:patchHere(j)

    elseif k == AstKind.FunctionLiteralExpression then
        local protoIdx, captures = compileFunction(fs, node.args, node.body)
        local idx = fs:emit(OP.NEWCLOSURE, dst, nil, nil, protoIdx)
        fs.code[idx].captures = captures

    elseif k == AstKind.VarargExpression then
        fs:emit(OP.GETVARARGS, dst, 2)   -- single value

    elseif k == AstKind.PassSelfFunctionCallExpression then
        local base = fs.freereg
        compileMethodCore(fs, node, base, 1)
        if dst ~= base then fs:emit(OP.MOVE, dst, base) end

    else
        error("customvm compiler: unsupported expression node: " .. tostring(k))
    end

    fs.freereg = saved
    fs:setReg(dst)
end


function compileOpenList(fs, exprs, base)
    local n = #exprs
    if n == 0 then return 0, false end
    for i = 1, n do
        local dst = base + i - 1
        fs.freereg = dst + 1
        fs:setReg(dst)
        if i < n then
            compileExprToReg(fs, exprs[i], dst)
        else
            if isMultiExpr(exprs[i]) then
                compileMultiTo(fs, exprs[i], dst, MULTRET)
                return n - 1, true
            end
            compileExprToReg(fs, exprs[i], dst)
        end
    end
    return n, false
end


function compileCallCore(fs, node, base, nres)
    fs:setReg(base)
    compileExprToReg(fs, node.base, base)   -- function into base
    fs.freereg = base + 1
    local nargs, open = compileOpenList(fs, node.args, base + 1)
    local B = open and 0 or (nargs + 1)
    local C = (nres == MULTRET) and 0 or (nres + 1)
    fs:emit(OP.CALL, base, B, C)
    -- Track result registers in maxstack so CFF doesn't alias them
    if nres ~= MULTRET and nres > 0 then
        fs:setReg(base + nres - 1)
    end
end


function compileFunction(fs, args, body)
    local cfs = newFuncState(fs)
    local numparams = 0
    local isvararg = false
    for _, arg in ipairs(args) do
        if arg.kind == AstKind.VarargExpression then
            isvararg = true
        else
            cfs:setLocal(arg.scope, arg.id, numparams)   -- params occupy R[0..np-1]
            numparams = numparams + 1
        end
    end
    cfs.nactive = numparams
    cfs.freereg = numparams
    cfs:setReg(numparams > 0 and numparams - 1 or 0)

    compileBlock(cfs, body)
    cfs:emit(OP.RETURN, 0, 1)   -- implicit empty return

    fs.protos[#fs.protos + 1] = {
        maxstack  = cfs.maxstack,
        numparams = numparams,
        isvararg  = isvararg,
        code      = cfs.code,
        k         = cfs.k,
        protos    = cfs.protos,
    }
    local protoIdx = #fs.protos

    local captures = {}
    for u, uv in ipairs(cfs.upvals) do
        captures[u] = { type = (uv.kind == "local") and 1 or 2, idx = uv.index }
    end
    return protoIdx, captures
end


function compileMethodCore(fs, node, base, nres)
    fs:setReg(base)
    compileExprToReg(fs, node.base, base)      -- object into base
    -- NAMECALL: R[base] = obj[method], R[base+1] = obj (self).
    fs:emit(OP.NAMECALL, base, base, nil, fs:constK(node.passSelfFunctionName))
    fs:setReg(base + 1)
    fs.freereg = base + 2
    local nargs, open = compileOpenList(fs, node.args, base + 2)
    local B = open and 0 or (nargs + 2)
    local C = (nres == MULTRET) and 0 or (nres + 1)
    fs:emit(OP.CALL, base, B, C)
    -- Track result registers in maxstack
    if nres ~= MULTRET and nres > 0 then
        fs:setReg(base + nres - 1)
    end
end



function compileTable(fs, node, dst)
    fs:emit(OP.NEWTABLE, dst)
    fs:setReg(dst)

    
    local arrayVals = {}
    for _, e in ipairs(node.entries) do
        if e.kind == AstKind.TableEntry then
            arrayVals[#arrayVals + 1] = e.value
        end
    end
    local m = #arrayVals
    if m > 0 then
        local base = fs.freereg
        local open = false
        for i = 1, m do
            local r = base + i - 1
            fs.freereg = r + 1
            fs:setReg(r)
            if i == m and isMultiExpr(arrayVals[i]) then
                compileMultiTo(fs, arrayVals[i], r, MULTRET)   
                open = true
            else
                compileExprToReg(fs, arrayVals[i], r)
            end
        end
        fs:emit(OP.SETLIST, dst, base, open and 0 or m, 1)  
        fs.freereg = base
    end

    for _, e in ipairs(node.entries) do
        if e.kind == AstKind.KeyedTableEntry then
            if e.key.kind == AstKind.StringExpression then
                local v = fs.freereg
                fs.freereg = v + 1; fs:setReg(v)
                compileExprToReg(fs, e.value, v)
                fs:emit(OP.SETTABLEKS, v, dst, nil, fs:constK(e.key.value))
                fs.freereg = v
            else
                local kr = fs.freereg
                fs.freereg = kr + 1; fs:setReg(kr)
                compileExprToReg(fs, e.key, kr)
                local vr = fs.freereg
                fs.freereg = vr + 1; fs:setReg(vr)
                compileExprToReg(fs, e.value, vr)
                fs:emit(OP.SETTABLE, vr, dst, kr)
                fs.freereg = kr
            end
        end
    end
end


function compileExprList(fs, exprs, base, want)
    local n = #exprs
    if n == 0 then
        for i = 0, want - 1 do fs:emit(OP.LOADNIL, base + i); fs:setReg(base + i) end
        return
    end
    for i = 1, n do
        local dst = base + i - 1
        fs.freereg = dst + 1
        fs:setReg(dst)
        if i < n then
            compileExprToReg(fs, exprs[i], dst)
        else
            local remaining = want - (n - 1)
            if remaining <= 1 then
                compileExprToReg(fs, exprs[i], dst)        -- single (extras land in scratch)
            elseif isMultiExpr(exprs[i]) then
                compileMultiTo(fs, exprs[i], dst, remaining)   -- fills dst..dst+remaining-1
            else
                compileExprToReg(fs, exprs[i], dst)
                for j = 1, remaining - 1 do fs:emit(OP.LOADNIL, dst + j); fs:setReg(dst + j) end
            end
        end
    end
end



local function compileLocalDecl(fs, stat)
    local ids = stat.ids
    local nids = #ids
    local base = fs.nactive
    fs.freereg = base
    compileExprList(fs, stat.expressions, base, nids)
    for i = 1, nids do
        fs:setLocal(stat.scope, ids[i], base + i - 1)
    end
    fs.nactive = base + nids
    fs.freereg = fs.nactive
    fs:setReg(fs.nactive - 1 >= 0 and fs.nactive - 1 or 0)
end

local function compileAssignment(fs, stat)
    local lhs, rhs = stat.lhs, stat.rhs
    local n = #lhs

 
    if n == 1 and #rhs == 1
        and lhs[1].kind == AstKind.AssignmentVariable and not lhs[1].scope.isGlobal then
        local m = fs.localRegs[lhs[1].scope]
        if m and m[lhs[1].id] ~= nil then
            compileExprToReg(fs, rhs[1], m[lhs[1].id])
            fs.freereg = fs.nactive
            return
        end
      
    end


    local targets = {}
    for i = 1, n do
        local t = lhs[i]
        if t.kind == AstKind.AssignmentVariable then
            if t.scope.isGlobal then
                targets[i] = { kind = "global", name = t.scope:getVariableName(t.id) }
            else
                local m = fs.localRegs[t.scope]
                if m and m[t.id] ~= nil then
                    targets[i] = { kind = "local", reg = m[t.id] }
                else
                    targets[i] = { kind = "upval", index = resolveUpval(fs, t.scope, t.id) }
                end
            end
        elseif t.kind == AstKind.AssignmentIndexing then
            local breg = fs.freereg
            fs.freereg = breg + 1; fs:setReg(breg)
            compileExprToReg(fs, t.base, breg)
            if t.index.kind == AstKind.StringExpression then
                targets[i] = { kind = "indexks", base = breg, key = fs:constK(t.index.value) }
            else
                local kreg = fs.freereg
                fs.freereg = kreg + 1; fs:setReg(kreg)
                compileExprToReg(fs, t.index, kreg)
                targets[i] = { kind = "index", base = breg, key = kreg }
            end
        else
            error("customvm compiler: unsupported assignment target: " .. tostring(t.kind))
        end
    end

    local vbase = fs.freereg
    compileExprList(fs, rhs, vbase, n)

    for i = 1, n do
        local tg = targets[i]
        local vreg = vbase + i - 1
        if tg.kind == "local" then
            if tg.reg ~= vreg then fs:emit(OP.MOVE, tg.reg, vreg) end
        elseif tg.kind == "upval" then
            fs:emit(OP.SETUPVAL, vreg, tg.index)
        elseif tg.kind == "global" then
            fs:emit(OP.SETGLOBAL, vreg, nil, nil, fs:constK(tg.name))
        elseif tg.kind == "indexks" then
            fs:emit(OP.SETTABLEKS, vreg, tg.base, nil, tg.key)
        elseif tg.kind == "index" then
            fs:emit(OP.SETTABLE, vreg, tg.base, tg.key)
        end
    end
    fs.freereg = fs.nactive
end

local function compileReturn(fs, stat)
    local exprs = stat.args
    if #exprs == 0 then
        fs:emit(OP.RETURN, 0, 1)
        return
    end
    local base = fs.freereg
    local nvals, open = compileOpenList(fs, exprs, base)
    local B = open and 0 or (nvals + 1)
    fs:emit(OP.RETURN, base, B)
    fs.freereg = fs.nactive
end

local function compileCallStatement(fs, node)
    local base = fs.freereg
    compileCallCore(fs, node, base, 0)
    fs.freereg = fs.nactive
end


local function condJumpIfFalse(fs, cond)
    local r = fs.freereg
    fs.freereg = r + 1
    fs:setReg(r)
    compileExprToReg(fs, cond, r)
    local idx = fs:emit(OP.JUMPIFNOT, r)
    fs.freereg = fs.nactive
    return idx
end

local function compileIf(fs, stat)
    local endJumps = {}
    local fj = condJumpIfFalse(fs, stat.condition)
    compileBlock(fs, stat.body)
    endJumps[#endJumps + 1] = fs:emit(OP.JUMP)
    fs:patchHere(fj)
    for _, ei in ipairs(stat.elseifs or {}) do
        local f = condJumpIfFalse(fs, ei.condition)
        compileBlock(fs, ei.body)
        endJumps[#endJumps + 1] = fs:emit(OP.JUMP)
        fs:patchHere(f)
    end
    if stat.elsebody then
        compileBlock(fs, stat.elsebody)
    end
    for _, j in ipairs(endJumps) do fs:patchHere(j) end
end

local function compileWhile(fs, stat)
    local condStart = #fs.code + 1
    local fj = condJumpIfFalse(fs, stat.condition)
    fs.loops[#fs.loops + 1] = { breaks = {}, continues = {} }
    compileBlock(fs, stat.body)
    fs:patchJump(fs:emit(OP.JUMP), condStart)   -- loop back to the condition
    fs:patchHere(fj)                            -- condition false -> after loop
    local L = table.remove(fs.loops)
    for _, b in ipairs(L.breaks) do fs:patchHere(b) end
    for _, c in ipairs(L.continues) do fs:patchJump(c, condStart) end
end

local function compileRepeat(fs, stat)
    local body_start = #fs.code + 1
    fs.loops[#fs.loops + 1] = { breaks = {}, continues = {} }
    local savedNactive = fs.nactive
    for _, st in ipairs(stat.body.statements) do
        compileStat(fs, st)
        fs.freereg = fs.nactive
    end
    local contTarget = #fs.code + 1
    local r = fs.freereg
    fs.freereg = r + 1; fs:setReg(r)
    compileExprToReg(fs, stat.condition, r)
    fs:patchJump(fs:emit(OP.JUMPIFNOT, r), body_start)   -- cond false -> repeat
    fs.nactive = savedNactive
    fs.freereg = savedNactive
    local L = table.remove(fs.loops)
    for _, b in ipairs(L.breaks) do fs:patchHere(b) end
    for _, c in ipairs(L.continues) do fs:patchJump(c, contTarget) end
end

local function compileForNum(fs, stat)
    local base = fs.nactive
    -- Control registers: R[base]=limit, R[base+1]=step, R[base+2]=index.
    fs.freereg = base + 1; compileExprToReg(fs, stat.finalValue, base)
    fs.freereg = base + 2; compileExprToReg(fs, stat.incrementBy, base + 1)
    fs.freereg = base + 3; compileExprToReg(fs, stat.initialValue, base + 2)
    fs:setReg(base + 3)
    local prep = fs:emit(OP.FORNPREP, base)
    -- Loop variable visible in the body is R[base+3].
    fs:setLocal(stat.scope, stat.id, base + 3)
    fs.nactive = base + 4
    fs.freereg = fs.nactive
    fs.loops[#fs.loops + 1] = { breaks = {}, continues = {} }
    local body_start = #fs.code + 1
    compileBlock(fs, stat.body)
    -- Per-iteration close so closures capturing the loop var get distinct copies.
    local contTarget
    if fs.anyCapture then contTarget = fs:emit(OP.CLOSEUPVALS, base + 3) end
    local loopIdx = fs:emit(OP.FORNLOOP, base)
    contTarget = contTarget or loopIdx
    fs:patchJump(loopIdx, body_start)
    fs:patchHere(prep)               -- not entering -> after FORNLOOP
    local L = table.remove(fs.loops)
    for _, b in ipairs(L.breaks) do fs:patchHere(b) end
    for _, c in ipairs(L.continues) do fs:patchJump(c, contTarget) end
    fs.nactive = base
    fs.freereg = base
end

local function compileForIn(fs, stat)
    local base = fs.nactive
    fs.freereg = base
    compileExprList(fs, stat.expressions, base, 3)   -- gen, state, control
    local nvars = #stat.ids
    fs:setReg(base + 3 + nvars - 1)
    local prep = fs:emit(OP.JUMP)                    -- enter at the FORGLOOP check
    for i = 1, nvars do fs:setLocal(stat.scope, stat.ids[i], base + 3 + i - 1) end
    fs.nactive = base + 3 + nvars
    fs.freereg = fs.nactive
    -- Ensure maxstack fully covers all for-in slots so flatten's scratch
    -- registers (allocated at maxstack+N) never alias live loop variables.
    fs:setReg(fs.nactive)
    fs.loops[#fs.loops + 1] = { breaks = {}, continues = {} }
    local body_start = #fs.code + 1
    compileBlock(fs, stat.body)
    local contTarget
    if fs.anyCapture then contTarget = fs:emit(OP.CLOSEUPVALS, base + 3) end
    local loopIdx = fs:emit(OP.FORGLOOP, base, nil, nil, nvars)
    contTarget = contTarget or loopIdx
    fs:patchJump(loopIdx, body_start)
    fs:patchJump(prep, loopIdx)
    local L = table.remove(fs.loops)
    for _, b in ipairs(L.breaks) do fs:patchHere(b) end
    for _, c in ipairs(L.continues) do fs:patchJump(c, contTarget) end
    fs.nactive = base
    fs.freereg = base
end

function compileStat(fs, stat)
    local k = stat.kind
    -- ----------------------------------------------------------------
    -- LuaU compound assignments: lower to a regular AssignmentStatement
    -- x += y  =>  x = x + y  (etc.)
    -- ----------------------------------------------------------------
    local compoundOpMap = {
        [AstKind.CompoundAddStatement]    = function(l,r) return Ast.AddExpression(l, r) end,
        [AstKind.CompoundSubStatement]    = function(l,r) return Ast.SubExpression(l, r) end,
        [AstKind.CompoundMulStatement]    = function(l,r) return Ast.MulExpression(l, r) end,
        [AstKind.CompoundDivStatement]    = function(l,r) return Ast.DivExpression(l, r) end,
        [AstKind.CompoundModStatement]    = function(l,r) return Ast.ModExpression(l, r) end,
        [AstKind.CompoundPowStatement]    = function(l,r) return Ast.PowExpression(l, r) end,
        [AstKind.CompoundConcatStatement] = function(l,r) return Ast.StrCatExpression(l, r) end,
        [AstKind.CompoundIDivStatement]   = function(l,r) return Ast.IDivExpression(l, r) end,
    }
    local compoundBuilder = compoundOpMap[k]
    if compoundBuilder then
        -- Clone the lhs node as a read expression (VariableExpression or IndexExpression)
        local lhsRead = {}
        for key, val in pairs(stat.lhs) do lhsRead[key] = val end
        if lhsRead.kind == AstKind.AssignmentVariable then
            lhsRead.kind = AstKind.VariableExpression
        elseif lhsRead.kind == AstKind.AssignmentIndexing then
            lhsRead.kind = AstKind.IndexExpression
        end
        local expanded = Ast.AssignmentStatement({ stat.lhs }, { compoundBuilder(lhsRead, stat.rhs) })
        compileStat(fs, expanded)
        return
    end

    if k == AstKind.LocalVariableDeclaration then
        compileLocalDecl(fs, stat)
    elseif k == AstKind.AssignmentStatement then
        compileAssignment(fs, stat)
    elseif k == AstKind.FunctionCallStatement then
        compileCallStatement(fs, stat)
    elseif k == AstKind.ReturnStatement then
        compileReturn(fs, stat)
    elseif k == AstKind.DoStatement then
        compileBlock(fs, stat.body)
    elseif k == AstKind.NopStatement then
        -- nothing
    elseif k == AstKind.IfStatement then
        compileIf(fs, stat)
    elseif k == AstKind.WhileStatement then
        compileWhile(fs, stat)
    elseif k == AstKind.RepeatStatement then
        compileRepeat(fs, stat)
    elseif k == AstKind.ForStatement then
        compileForNum(fs, stat)
    elseif k == AstKind.ForInStatement then
        compileForIn(fs, stat)
    elseif k == AstKind.BreakStatement then
        local L = fs.loops[#fs.loops]
        if not L then error("customvm compiler: 'break' outside a loop") end
        L.breaks[#L.breaks + 1] = fs:emit(OP.JUMP)
    elseif k == AstKind.ContinueStatement then
        local L = fs.loops[#fs.loops]
        if not L then error("customvm compiler: 'continue' outside a loop") end
        L.continues[#L.continues + 1] = fs:emit(OP.JUMP)
    elseif k == AstKind.LocalFunctionDeclaration then
        -- capture it as an upvalue.
        local reg = fs.nactive
        fs.nactive = fs.nactive + 1
        fs:setReg(reg)
        fs:setLocal(stat.scope, stat.id, reg)
        fs.freereg = fs.nactive
        local protoIdx, captures = compileFunction(fs, stat.args, stat.body)
        fs.code[fs:emit(OP.NEWCLOSURE, reg, nil, nil, protoIdx)].captures = captures
        fs.freereg = fs.nactive

    elseif k == AstKind.FunctionDeclaration then
        local protoIdx, captures = compileFunction(fs, stat.args, stat.body)
        local treg = fs.freereg
        fs.freereg = treg + 1; fs:setReg(treg)
        fs.code[fs:emit(OP.NEWCLOSURE, treg, nil, nil, protoIdx)].captures = captures
        local indices = stat.indices or {}
        if #indices == 0 then
            if stat.scope.isGlobal then
                fs:emit(OP.SETGLOBAL, treg, nil, nil, fs:constK(stat.scope:getVariableName(stat.id)))
            else
                local m = fs.localRegs[stat.scope]
                if m and m[stat.id] ~= nil then
                    fs:emit(OP.MOVE, m[stat.id], treg)
                else
                    fs:emit(OP.SETUPVAL, treg, resolveUpval(fs, stat.scope, stat.id))
                end
            end
        else
            local bx = fs.freereg
            fs.freereg = bx + 1; fs:setReg(bx)
            compileExprToReg(fs, Ast.VariableExpression(stat.scope, stat.id), bx)
            for i = 1, #indices - 1 do
                fs:emit(OP.GETTABLEKS, bx, bx, nil, fs:constK(indices[i]))
            end
            fs:emit(OP.SETTABLEKS, treg, bx, nil, fs:constK(indices[#indices]))
        end
        fs.freereg = fs.nactive

    elseif k == AstKind.PassSelfFunctionCallStatement then
        local base = fs.freereg
        compileMethodCore(fs, stat, base, 0)
        fs.freereg = fs.nactive

    else
        error("customvm compiler: unsupported statement node: " .. tostring(k))
    end
end

function compileBlock(fs, block)
    local savedNactive = fs.nactive
    for _, stat in ipairs(block.statements) do
        compileStat(fs, stat)
        fs.freereg = fs.nactive
    end
    if fs.anyCapture and fs.nactive > savedNactive then
        fs:emit(OP.CLOSEUPVALS, savedNactive)
    end
    fs.nactive = savedNactive
    fs.freereg = savedNactive
end



-- Super op fusion pass: walks the compiled code and fuses eligible
-- instruction pairs into single super opcodes.
local SUPER_OPS = {
    -- ADD followed by MOVE of the result → ADDMOVE
    -- pattern: ADD R[a], R[b], R[c]  then  MOVE R[k], R[a]
    function(code, i)
        local i1, i2 = code[i], code[i+1]
        if not i2 then return nil end
        if i1.op == OP.ADD and i1.c >= 0 and i2.op == OP.MOVE and i2.b == i1.a and i2.a ~= i1.a then
            return {op=OP.ADDMOVE, a=i1.a, b=i1.b, c=i1.c, k=i2.a}, 2
        end
        return nil
    end,
    -- MOVE followed by ADD using moved reg → MOVE_ADD
    -- pattern: MOVE R[a], R[b]  then  ADD R[a], R[a], R[c]
    function(code, i)
        local i1, i2 = code[i], code[i+1]
        if not i2 then return nil end
        if i1.op == OP.MOVE and i2.op == OP.ADD and i2.c >= 0 and i2.b == i1.a and i2.a == i1.a then
            return {op=OP.MOVE_ADD, a=i1.a, b=i1.b, c=i2.c, k=0}, 2
        end
        return nil
    end,
    -- GETTABLEKS followed by MOVE of the result → GETTKS_MOVE
    function(code, i)
        local i1, i2 = code[i], code[i+1]
        if not i2 then return nil end
        if i1.op == OP.GETTABLEKS and i2.op == OP.MOVE and i2.b == i1.a and i2.a ~= i1.a then
            return {op=OP.GETTKS_MOVE, a=i1.a, b=i1.b, c=i1.k, k=i2.a}, 2
        end
        return nil
    end,
    -- LOADK followed by MOVE of the result → LOADK_MOVE
    function(code, i)
        local i1, i2 = code[i], code[i+1]
        if not i2 then return nil end
        if i1.op == OP.LOADK and i2.op == OP.MOVE and i2.b == i1.a and i2.a ~= i1.a then
            return {op=OP.LOADK_MOVE, a=i1.a, b=0, c=i1.k, k=i2.a}, 2
        end
        return nil
    end,
}

local SUPER_JUMPS = {
    [OP.ADD]=true,[OP.MOVE]=true,[OP.GETTABLEKS]=true,[OP.LOADK]=true
}

local function superOpPass(proto)
    local code = proto.code
    local newCode = {}
    local oldToNew = {}
    local i = 1
    while i <= #code do
        oldToNew[i] = #newCode + 1
        local fused = nil
        local skip = 1
        -- Only fuse with ~30% probability to keep variety
        if math.random() < 0.3 then
            for _, tryFuse in ipairs(SUPER_OPS) do
                local ins, n = tryFuse(code, i)
                if ins then fused = ins; skip = n; break end
            end
        end
        if fused then
            newCode[#newCode+1] = fused
        else
            newCode[#newCode+1] = code[i]
        end
        i = i + skip
    end
    oldToNew[#code+1] = #newCode + 1

    -- Patch jump targets
    local JUMP_OPS = {
        [OP.JUMP]=true,[OP.JUMPBACK]=true,[OP.JUMPIF]=true,[OP.JUMPIFNOT]=true,
        [OP.JUMPIFEQ]=true,[OP.JUMPIFLE]=true,[OP.JUMPIFLT]=true,
        [OP.JUMPIFNOTEQ]=true,[OP.JUMPIFNOTLE]=true,[OP.JUMPIFNOTLT]=true,
        [OP.FORNPREP]=true,[OP.FORNLOOP]=true,[OP.FORGLOOP]=true,
    }
    -- rebuild oldToNew for original indices that got fused
    for oi = 1, #code do
        if not oldToNew[oi] then oldToNew[oi] = oldToNew[oi-1] or 1 end
    end
    for ni, ins in ipairs(newCode) do
        if JUMP_OPS[ins.op] then
            -- find original index for this new index
            local oi
            for k, v in pairs(oldToNew) do if v == ni then oi = k; break end end
            if oi then
                local oldTarget = oi + 1 + ins.b
                local newTarget = oldToNew[oldTarget] or (#newCode + 1)
                ins.b = newTarget - (ni + 1)
            end
        end
    end

    proto.code = newCode
    for _, child in ipairs(proto.protos or {}) do superOpPass(child) end
end

-- Security pass 1: Constant pool poisoning
-- Adds fake constants (random strings and numbers) to each proto's constant pool.
-- These are never referenced by any instruction, but they make the constant table
-- harder to analyze — a decompiler can't tell which constants are real vs fake.
local function constantPoisonPass(proto)
    local nFake = math.random(3, 8)
    for _ = 1, nFake do
        local t = math.random(1, 3)
        if t == 1 then
            -- Random string (looks like a real identifier or API name)
            local CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
            local len = math.random(4, 12)
            local s = {}
            for i = 1, len do
                local c = math.random(1, #CHARS)
                s[i] = CHARS:sub(c, c)
            end
            proto.k[#proto.k + 1] = table.concat(s)
        elseif t == 2 then
            -- Random number
            proto.k[#proto.k + 1] = math.random(1, 999999) + math.random() * 0.001
        else
            -- Random plausible API-like string
            local prefixes = {"Get", "Set", "Find", "Is", "Has", "On", "Fire", "Wait", "Create", "Destroy"}
            local suffixes = {"Child", "Service", "Event", "Value", "Instance", "Part", "Player", "Object", "Data", "Remote"}
            proto.k[#proto.k + 1] = prefixes[math.random(#prefixes)] .. suffixes[math.random(#suffixes)]
        end
    end
    for _, child in ipairs(proto.protos or {}) do
        constantPoisonPass(child)
    end
end

-- Security pass 2: Dead bytecode injection
-- Inserts unreachable instruction sequences after RETURN and JUMP instructions.
-- These never execute (they're after an unconditional exit) but they appear in the
-- bytecode stream, confusing linear-sweep disassemblers that don't track reachability.
local function deadCodePass(proto)
    local code = proto.code
    if #code < 3 then return end
    local newCode = {}
    local oldToNew = {}
    
    for i = 1, #code do
        oldToNew[i] = #newCode + 1
        newCode[#newCode + 1] = code[i]
        
        -- After RETURN or unconditional JUMP, insert 1-3 fake instructions
        local op = code[i].op
        if (op == OP.RETURN or op == OP.JUMP) and math.random() < 0.4 then
            local nDead = math.random(1, 3)
            for _ = 1, nDead do
                local fakeOp = math.random(1, 5)
                if fakeOp == 1 then
                    newCode[#newCode + 1] = { op = OP.LOADN, a = 0, b = math.random(1, 9999), c = 0, k = 0 }
                elseif fakeOp == 2 then
                    newCode[#newCode + 1] = { op = OP.LOADNIL, a = 0, b = 0, c = 0, k = 0 }
                elseif fakeOp == 3 then
                    newCode[#newCode + 1] = { op = OP.ADD, a = 0, b = 0, c = 0, k = 0 }
                elseif fakeOp == 4 then
                    newCode[#newCode + 1] = { op = OP.MOVE, a = 0, b = 0, c = 0, k = 0 }
                else
                    newCode[#newCode + 1] = { op = OP.LOADK, a = 0, b = 0, c = 0, k = math.random(1, math.max(1, #proto.k)) }
                end
            end
        end
    end
    oldToNew[#code + 1] = #newCode + 1
    
    -- Patch jump targets
    for oi = 1, #code do
        if not oldToNew[oi] then oldToNew[oi] = oldToNew[oi-1] or 1 end
    end
    local JUMP_OPS = {
        [OP.JUMP]=true,[OP.JUMPBACK]=true,[OP.JUMPIF]=true,[OP.JUMPIFNOT]=true,
        [OP.JUMPIFEQ]=true,[OP.JUMPIFLE]=true,[OP.JUMPIFLT]=true,
        [OP.JUMPIFNOTEQ]=true,[OP.JUMPIFNOTLE]=true,[OP.JUMPIFNOTLT]=true,
        [OP.FORNPREP]=true,[OP.FORNLOOP]=true,[OP.FORGLOOP]=true,
    }
    for ni, ins in ipairs(newCode) do
        if JUMP_OPS[ins.op] and ins.b then
            -- Find original index for this new instruction
            local oi
            for k, v in pairs(oldToNew) do if v == ni then oi = k; break end end
            if oi then
                local oldTarget = oi + 1 + ins.b
                local newTarget = oldToNew[oldTarget] or (#newCode + 1)
                ins.b = newTarget - (ni + 1)
            end
        end
    end
    
    proto.code = newCode
    for _, child in ipairs(proto.protos or {}) do
        deadCodePass(child)
    end
end

-- Security pass: Opaque Constant Computation
-- Replaces LOADN instructions with multi-instruction sequences that compute
-- the same value, so no number constants appear directly in the bytecode.
local function opaqueConstPass(proto)
    local code = proto.code
    if #code < 2 then return end
    local scratch = proto.maxstack or 0
    local usedScratch = false
    local newCode = {}

    for i = 1, #code do
        local ins = code[i]
        -- Expand LOADN into opaque arithmetic (40% probability)
        if ins.op == OP.LOADN and ins.b ~= 0 and math.random() < 0.4 then
            local val = ins.b
            local dst = ins.a
            local method = math.random(1, 4)

            if method == 1 and val > 2 and val < 100000 then
                -- Multiplication decomposition: val = a * b
                -- Find a factor pair
                local factor = nil
                for f = 2, math.min(val - 1, 20) do
                    if val % f == 0 then factor = f; break end
                end
                if factor then
                    usedScratch = true
                    local other = val / factor
                    newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = factor, c = 0, k = 0 }
                    newCode[#newCode+1] = { op = OP.LOADN, a = scratch, b = other, c = 0, k = 0 }
                    newCode[#newCode+1] = { op = OP.MUL, a = dst, b = dst, c = scratch, k = 0 }
                else
                    newCode[#newCode+1] = ins
                end

            elseif method == 2 and val > 1 then
                -- Addition decomposition: val = a + b
                local a = math.random(1, val - 1)
                local b = val - a
                usedScratch = true
                newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = a, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.LOADN, a = scratch, b = b, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.ADD, a = dst, b = dst, c = scratch, k = 0 }

            elseif method == 3 and val >= 0 then
                -- Subtraction decomposition: val = a - b
                local b = math.random(1, 100)
                local a = val + b
                usedScratch = true
                newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = a, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.LOADN, a = scratch, b = b, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.SUB, a = dst, b = dst, c = scratch, k = 0 }

            elseif method == 4 and val % 2 == 0 and val > 0 then
                -- Double: val = (val/2) + (val/2) → LOADN then ADD self
                local half = val / 2
                newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = half, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.ADD, a = dst, b = dst, c = dst, k = 0 }
            else
                newCode[#newCode+1] = ins
            end
        else
            newCode[#newCode+1] = ins
        end
    end

    -- Patch jumps (instruction indices shifted)
    -- Build old-to-new mapping
    -- Actually we need to track the mapping properly
    -- Simple approach: rebuild with index tracking
    -- Re-do with proper jump patching:
    proto.code = code  -- restore original
    local newCode2 = {}
    local oldToNew = {}
    for i = 1, #code do
        oldToNew[i] = #newCode2 + 1
        local ins = code[i]
        if ins.op == OP.LOADN and ins.b ~= 0 and ins._opaque then
            -- Already marked for expansion in first pass
            for _, expanded in ipairs(ins._opaque) do
                newCode2[#newCode2+1] = expanded
            end
        else
            newCode2[#newCode2+1] = ins
        end
    end

    -- Simpler approach: just use the newCode from first pass and patch jumps
    -- Reset and redo properly:
    newCode = {}
    oldToNew = {}
    for i = 1, #code do
        oldToNew[i] = #newCode + 1
        local ins = code[i]
        if ins.op == OP.LOADN and ins.b ~= 0 and math.random() < 0.4 then
            local val = ins.b
            local dst = ins.a
            local method = math.random(1, 4)
            local expanded = false

            if method == 1 and val > 2 and val < 100000 then
                local factor = nil
                for f = 2, math.min(val - 1, 20) do
                    if val % f == 0 then factor = f; break end
                end
                if factor then
                    usedScratch = true
                    local other = val / factor
                    newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = factor, c = 0, k = 0 }
                    newCode[#newCode+1] = { op = OP.LOADN, a = scratch, b = other, c = 0, k = 0 }
                    newCode[#newCode+1] = { op = OP.MUL, a = dst, b = dst, c = scratch, k = 0 }
                    expanded = true
                end
            elseif method == 2 and val > 1 then
                local a = math.random(1, val - 1)
                local b = val - a
                usedScratch = true
                newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = a, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.LOADN, a = scratch, b = b, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.ADD, a = dst, b = dst, c = scratch, k = 0 }
                expanded = true
            elseif method == 3 and val >= 0 then
                local b = math.random(1, 100)
                local a = val + b
                usedScratch = true
                newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = a, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.LOADN, a = scratch, b = b, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.SUB, a = dst, b = dst, c = scratch, k = 0 }
                expanded = true
            elseif method == 4 and val % 2 == 0 and val > 0 then
                local half = val / 2
                newCode[#newCode+1] = { op = OP.LOADN, a = dst, b = half, c = 0, k = 0 }
                newCode[#newCode+1] = { op = OP.ADD, a = dst, b = dst, c = dst, k = 0 }
                expanded = true
            end

            if not expanded then
                newCode[#newCode+1] = ins
            end
        else
            newCode[#newCode+1] = ins
        end
    end
    oldToNew[#code+1] = #newCode + 1

    -- Patch jump targets
    local JUMP_OPS = {
        [OP.JUMP]=true,[OP.JUMPBACK]=true,[OP.JUMPIF]=true,[OP.JUMPIFNOT]=true,
        [OP.JUMPIFEQ]=true,[OP.JUMPIFLE]=true,[OP.JUMPIFLT]=true,
        [OP.JUMPIFNOTEQ]=true,[OP.JUMPIFNOTLE]=true,[OP.JUMPIFNOTLT]=true,
        [OP.FORNPREP]=true,[OP.FORNLOOP]=true,[OP.FORGLOOP]=true,
    }
    for oi = 1, #code do
        if not oldToNew[oi] then oldToNew[oi] = oldToNew[oi-1] or 1 end
    end
    for ni, ins in ipairs(newCode) do
        if JUMP_OPS[ins.op] and ins.b then
            local oi
            for k, v in pairs(oldToNew) do if v == ni then oi = k; break end end
            if oi then
                local oldTarget = oi + 1 + ins.b
                local newTarget = oldToNew[oldTarget] or (#newCode + 1)
                ins.b = newTarget - (ni + 1)
            end
        end
    end

    proto.code = newCode
    if usedScratch then proto.maxstack = scratch + 1 end
    for _, child in ipairs(proto.protos or {}) do
        opaqueConstPass(child)
    end
end

-- Security pass: Handler Merging
-- Merges SUB into ADD by encoding SUB as ADD with negated c field.
-- The ADD handler checks if c < 0: if yes → subtract R[-c], if no → add R[c].
-- This makes the ADD handler ambiguous — a devirtualizer can't tell if it's
-- addition or subtraction without inspecting the c field of every instruction.
local function handlerMergePass(proto)
    for _, ins in ipairs(proto.code) do
        if ins.op == OP.SUB and math.random() < 0.7 then
            ins.op = OP.ADD       -- rewrite as ADD
            ins.c = -(ins.c + 1)  -- negate c (add 1 to avoid -0 ambiguity)
        end
    end
    for _, child in ipairs(proto.protos or {}) do
        handlerMergePass(child)
    end
end

function Compiler.compile(ast)
    local fs = newFuncState(nil)
    compileBlock(fs, ast.body)
    fs:emit(OP.RETURN, 0, 1)
    local proto = {
        maxstack  = fs.maxstack,
        numparams = 0,
        isvararg  = true,
        code      = fs.code,
        k         = fs.k,
        protos    = fs.protos,
    }
    superOpPass(proto)
    constantPoisonPass(proto)
    opaqueConstPass(proto)
    deadCodePass(proto)
    handlerMergePass(proto)
    return proto
end

return Compiler
