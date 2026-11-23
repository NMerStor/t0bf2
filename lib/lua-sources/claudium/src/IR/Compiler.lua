-- IronBrew0 v0.001 - AST to IR Compiler
-- Produces a register-based IR suitable for control-flow obfuscation and VM

local IR = require("src.IR.IR")

local Compiler = {}
Compiler.__index = Compiler

function Compiler.new(options)
    options = options or {}
    return setmetatable({
        target = options.target or "lua51",
        proto  = nil,
        freeReg = 0,
        maxReg  = 0,
        localFloor = 0, -- lowest register index temps are allowed to reclaim
        labelCounter = 0,
        scopes = {},
        localMap = {}, -- binding -> register
    }, Compiler)
end

function Compiler:newLabel()
    self.labelCounter = self.labelCounter + 1
    return "L" .. self.labelCounter
end

function Compiler:allocReg()
    local r = self.freeReg
    self.freeReg = self.freeReg + 1
    if self.freeReg > self.maxReg then
        self.maxReg = self.freeReg
    end
    return r
end

function Compiler:freeRegs(n)
    -- Never recycle registers that hold live locals/parameters.
    -- The old allocator could free below a local slot and later overwrite it
    -- with a temporary expression, causing type corruption inside the VM.
    self.freeReg = math.max(self.localFloor or 0, self.freeReg - (n or 1))
end

function Compiler:emit(op, a, b, c, meta)
    table.insert(self.proto.code, IR.Instruction(op, a, b, c, meta))
end

function Compiler:addConstant(value)
    for i, k in ipairs(self.proto.constants) do
        if k.value == value and type(k.value) == type(value) then
            return i
        end
    end
    table.insert(self.proto.constants, IR.Constant(value))
    return #self.proto.constants
end

function Compiler:compile(ast)
    local mod = IR.Module()
    self.proto = IR.Prototype("main")
    self.proto.isVararg = true
    self.freeReg = 0
    self.maxReg = 0
    self.localFloor = 0
    self.localMap = {}

    self:compileBlock(ast)

    self.proto.maxStack = math.max(self.maxReg, 2)
    mod.main = self.proto
    table.insert(mod.prototypes, self.proto)
    return mod
end

function Compiler:compileBlock(node)
    if not node then return end
    for _, stmt in ipairs(node.body or {}) do
        self:compileStatement(stmt)
    end
end

function Compiler:compileStatement(node)
    if not node then return end
    local k = node.kind

    if k == "LocalStatement" then
        local regs = {}
        for i, var in ipairs(node.variables or {}) do
            local r = self:allocReg()
            regs[i] = r
            if var.binding then
                self.localMap[var.binding] = r
            end
        end
        -- Locals are live for at least the remainder of this prototype in the
        -- conservative allocator. Keep temporaries above them.
        if self.freeReg > self.localFloor then
            self.localFloor = self.freeReg
        end
        for i, init in ipairs(node.init or {}) do
            local r = regs[i]
            if r then
                self:compileExpression(init, r)
            else
                self:compileExpression(init, self:allocReg())
                self:freeRegs(1)
            end
        end
        -- nil remaining
        for i = #(node.init or {}) + 1, #regs do
            self:emit(IR.Op.LOADNIL, regs[i])
        end

    elseif k == "AssignmentStatement" then
        -- evaluate RHS first
        local temps = {}
        for _, init in ipairs(node.init or {}) do
            local t = self:allocReg()
            self:compileExpression(init, t)
            table.insert(temps, t)
        end
        for i, var in ipairs(node.variables or {}) do
            local src = temps[i]
            if var.kind == "Identifier" and var.binding and self.localMap[var.binding] then
                if src then
                    self:emit(IR.Op.MOVE, self.localMap[var.binding], src)
                end
            elseif var.kind == "Identifier" then
                -- global
                local idx = self:addConstant(var.name)
                if src then
                    self:emit(IR.Op.SETGLOBAL, src, idx)
                end
            elseif var.kind == "MemberExpression" or var.kind == "IndexExpression" then
                -- simplified: leave for later phases
                if src then
                    local obj = self:allocReg()
                    self:compileExpression(var.object or var, obj)
                    local key = self:allocReg()
                    if var.property then
                        local ki = self:addConstant(var.property.name)
                        self:emit(IR.Op.LOADK, key, ki)
                    elseif var.index then
                        self:compileExpression(var.index, key)
                    end
                    self:emit(IR.Op.SETTABLE, obj, key, src)
                    self:freeRegs(2)
                end
            end
        end
        self:freeRegs(#temps)

    elseif k == "CallStatement" then
        local r = self:allocReg()
        self:compileExpression(node.expression, r)
        self:freeRegs(1)

    elseif k == "ReturnStatement" then
        if not node.arguments or #node.arguments == 0 then
            self:emit(IR.Op.RETURN, 0, 1) -- return nothing
        else
            local base = self.freeReg
            for _, a in ipairs(node.arguments) do
                local r = self:allocReg()
                self:compileExpression(a, r)
            end
            self:emit(IR.Op.RETURN, base, #node.arguments + 1)
            self:freeRegs(#node.arguments)
        end

    elseif k == "BreakStatement" then
        -- placeholder: real jumps filled by control-flow pass
        self:emit(IR.Op.JMP, 0, 0, 0, { break_ = true })

    elseif k == "IfStatement" then
        local endLabel = self:newLabel()
        for i, clause in ipairs(node.clauses or {}) do
            if clause.test then
                local testR = self:allocReg()
                self:compileExpression(clause.test, testR)
                local nextLabel = self:newLabel()
                self:emit(IR.Op.JMP_IFNOT, testR, 0, 0, { label = nextLabel })
                self:freeRegs(1)
                self:compileBlock(clause.body)
                self:emit(IR.Op.JMP, 0, 0, 0, { label = endLabel })
                self:emit(IR.Op.LABEL, 0, 0, 0, { label = nextLabel })
            else
                self:compileBlock(clause.body)
            end
        end
        self:emit(IR.Op.LABEL, 0, 0, 0, { label = endLabel })

    elseif k == "WhileStatement" then
        local startL = self:newLabel()
        local endL = self:newLabel()
        self:emit(IR.Op.LABEL, 0, 0, 0, { label = startL })
        local testR = self:allocReg()
        self:compileExpression(node.test, testR)
        self:emit(IR.Op.JMP_IFNOT, testR, 0, 0, { label = endL })
        self:freeRegs(1)
        self:compileBlock(node.body)
        self:emit(IR.Op.JMP, 0, 0, 0, { label = startL })
        self:emit(IR.Op.LABEL, 0, 0, 0, { label = endL })

    elseif k == "DoStatement" then
        self:compileBlock(node.body)

    elseif k == "FunctionDeclaration" then
        -- nested proto (simplified)
        local child = IR.Prototype(node.name and (node.name.name or "anon") or "anon")
        child.params = #(node.params or {})
        child.isVararg = node.isVararg
        local saved = self.proto
        local savedFree, savedMax, savedFloor, savedMap = self.freeReg, self.maxReg, self.localFloor, self.localMap
        self.proto = child
        self.freeReg = child.params
        self.maxReg = child.params
        self.localFloor = child.params
        self.localMap = {}
        for i, p in ipairs(node.params or {}) do
            if p.binding then self.localMap[p.binding] = i - 1 end
        end
        self:compileBlock(node.body)
        child.maxStack = math.max(self.maxReg, 2)
        self.proto = saved
        self.freeReg, self.maxReg, self.localFloor, self.localMap = savedFree, savedMax, savedFloor, savedMap
        table.insert(self.proto.prototypes, child)
        local reg = self:allocReg()
        self:emit(IR.Op.CLOSURE, reg, #self.proto.prototypes)
        if node.isLocal and node.name and node.name.binding then
            self.localMap[node.name.binding] = reg
            if self.freeReg > self.localFloor then self.localFloor = self.freeReg end
        elseif node.name and node.name.kind == "Identifier" then
            local idx = self:addConstant(node.name.name)
            self:emit(IR.Op.SETGLOBAL, reg, idx)
        end

    else
        -- unsupported statement: ignore for v0.001
    end
end

function Compiler:compileExpression(node, dest)
    if not node then
        self:emit(IR.Op.LOADNIL, dest)
        return
    end
    local k = node.kind

    if k == "Literal" then
        if node.value == nil then
            self:emit(IR.Op.LOADNIL, dest)
        elseif type(node.value) == "boolean" then
            self:emit(IR.Op.LOADBOOL, dest, node.value and 1 or 0)
        else
            local idx = self:addConstant(node.value)
            self:emit(IR.Op.LOADK, dest, idx)
        end

    elseif k == "Identifier" then
        if node.binding and self.localMap[node.binding] then
            self:emit(IR.Op.MOVE, dest, self.localMap[node.binding])
        else
            local idx = self:addConstant(node.name)
            self:emit(IR.Op.GETGLOBAL, dest, idx)
        end

    elseif k == "Vararg" then
        self:emit(IR.Op.LOADVARARG, dest)

    elseif k == "BinaryExpression" then
        local left = self:allocReg()
        local right = self:allocReg()
        self:compileExpression(node.left, left)
        self:compileExpression(node.right, right)
        local opMap = {
            ["+"] = IR.Op.ADD, ["-"] = IR.Op.SUB, ["*"] = IR.Op.MUL,
            ["/"] = IR.Op.DIV, ["%"] = IR.Op.MOD, ["^"] = IR.Op.POW,
            [".."] = IR.Op.CONCAT,
            ["=="] = IR.Op.EQ, ["<"] = IR.Op.LT, ["<="] = IR.Op.LE,
        }
        local op = opMap[node.op]
        if op then
            self:emit(op, dest, left, right)
        else
            -- fallback for and/or etc.
            self:emit(IR.Op.MOVE, dest, left)
        end
        self:freeRegs(2)

    elseif k == "UnaryExpression" then
        local arg = self:allocReg()
        self:compileExpression(node.argument, arg)
        if node.op == "-" then
            self:emit(IR.Op.UNM, dest, arg)
        elseif node.op == "not" then
            self:emit(IR.Op.NOT, dest, arg)
        elseif node.op == "#" then
            self:emit(IR.Op.LEN, dest, arg)
        end
        self:freeRegs(1)

    elseif k == "CallExpression" then
        -- Method call (obj:method(...)): R[callBase]=fn, R[callBase+1]=self, args follow
        local isMethod = node.isMethod and node.callee and node.callee.kind == "MemberExpression"
        if isMethod then
            local objR = self:allocReg()
            self:compileExpression(node.callee.object, objR)
            local keyR = self:allocReg()
            local ki = self:addConstant(node.callee.property.name)
            self:emit(IR.Op.LOADK, keyR, ki)
            local fnR = self:allocReg()
            self:emit(IR.Op.GETTABLE, fnR, objR, keyR)
            -- Contiguous CALL frame AFTER temps so objR is not overwritten
            local callBase = self.freeReg
            self:emit(IR.Op.MOVE, callBase, fnR)
            self:emit(IR.Op.MOVE, callBase + 1, objR) -- self preserved
            self.freeReg = callBase + 2
            for _, a in ipairs(node.arguments or {}) do
                self:compileExpression(a, self:allocReg())
            end
            local nArgs = #(node.arguments or {})
            self:emit(IR.Op.CALL, callBase, nArgs + 2, 2)
            self:emit(IR.Op.MOVE, dest, callBase)
            self.freeReg = objR -- free all temps + frame
        else
            local base = self.freeReg
            self:compileExpression(node.callee, self:allocReg())
            for _, a in ipairs(node.arguments or {}) do
                self:compileExpression(a, self:allocReg())
            end
            local nArgs = #(node.arguments or {})
            self:emit(IR.Op.CALL, base, nArgs + 1, 2)
            self:emit(IR.Op.MOVE, dest, base)
            self:freeRegs(nArgs + 1)
        end

    elseif k == "MemberExpression" then
        local obj = self:allocReg()
        self:compileExpression(node.object, obj)
        local key = self:allocReg()
        local idx = self:addConstant(node.property.name)
        self:emit(IR.Op.LOADK, key, idx)
        self:emit(IR.Op.GETTABLE, dest, obj, key)
        self:freeRegs(2)

    elseif k == "IndexExpression" then
        local obj = self:allocReg()
        self:compileExpression(node.object, obj)
        local key = self:allocReg()
        self:compileExpression(node.index, key)
        self:emit(IR.Op.GETTABLE, dest, obj, key)
        self:freeRegs(2)

    elseif k == "TableConstructor" then
        self:emit(IR.Op.NEWTABLE, dest, 0, 0)
        for i, f in ipairs(node.fields or {}) do
            local val = self:allocReg()
            self:compileExpression(f.value, val)
            if f.key then
                local key = self:allocReg()
                if f.key.kind == "Identifier" then
                    local idx = self:addConstant(f.key.name)
                    self:emit(IR.Op.LOADK, key, idx)
                else
                    self:compileExpression(f.key, key)
                end
                self:emit(IR.Op.SETTABLE, dest, key, val)
                self:freeRegs(1)
            else
                -- array part: use integer key
                local key = self:allocReg()
                local idx = self:addConstant(i)
                self:emit(IR.Op.LOADK, key, idx)
                self:emit(IR.Op.SETTABLE, dest, key, val)
                self:freeRegs(1)
            end
            self:freeRegs(1)
        end

    elseif k == "ParenthesizedExpression" then
        self:compileExpression(node.expression, dest)

    elseif k == "FunctionExpression" then
        local child = IR.Prototype("anon")
        child.params = #(node.params or {})
        child.isVararg = node.isVararg
        local saved = self.proto
        local savedFree, savedMax, savedFloor, savedMap = self.freeReg, self.maxReg, self.localFloor, self.localMap
        self.proto = child
        self.freeReg = child.params
        self.maxReg = child.params
        self.localFloor = child.params
        self.localMap = {}
        for i, p in ipairs(node.params or {}) do
            if p.binding then self.localMap[p.binding] = i - 1 end
        end
        self:compileBlock(node.body)
        child.maxStack = math.max(self.maxReg, 2)
        self.proto = saved
        self.freeReg, self.maxReg, self.localFloor, self.localMap = savedFree, savedMax, savedFloor, savedMap
        table.insert(self.proto.prototypes, child)
        self:emit(IR.Op.CLOSURE, dest, #self.proto.prototypes)

    else
        self:emit(IR.Op.LOADNIL, dest)
    end
end

return Compiler
