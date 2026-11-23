-- IronBrew0 v0.001 - Scope Analysis
-- Builds lexical scope tree and binds local identifiers

local Scope = {}
Scope.__index = Scope

function Scope.new(parent, kind)
    local self = setmetatable({
        parent   = parent,
        kind     = kind or "block", -- block, function, chunk
        locals   = {},              -- name -> binding
        children = {},
        node     = nil,             -- associated AST node
    }, Scope)
    if parent then
        table.insert(parent.children, self)
    end
    return self
end

function Scope:declare(name, node, isParam)
    if self.locals[name] then
        -- redeclaration in same scope (allowed for locals in Lua)
    end
    local binding = {
        name     = name,
        node     = node,
        scope    = self,
        isParam  = isParam or false,
        isUpvalue = false,
        references = {},
        renamed  = nil,
    }
    self.locals[name] = binding
    return binding
end

function Scope:lookup(name)
    local s = self
    while s do
        if s.locals[name] then
            return s.locals[name]
        end
        s = s.parent
    end
    return nil -- global
end

function Scope:lookupLocal(name)
    return self.locals[name]
end

-- Walk AST and build scopes + bind identifiers
local Analyzer = {}
Analyzer.__index = Analyzer

function Analyzer.new(options)
    options = options or {}
    return setmetatable({
        rootScope = nil,
        current   = nil,
        globals   = {},
        preserved = options.preserved or {},
        target    = options.target or "lua51",
    }, Analyzer)
end

-- Known globals / libraries that must never be renamed
local DEFAULT_PRESERVED = {
    -- Lua base
    _G = true, _ENV = true, _VERSION = true,
    assert = true, collectgarbage = true, dofile = true, error = true,
    getfenv = true, getmetatable = true, ipairs = true, load = true,
    loadfile = true, loadstring = true, next = true, pairs = true,
    pcall = true, print = true, rawequal = true, rawget = true,
    rawset = true, select = true, setfenv = true, setmetatable = true,
    tonumber = true, tostring = true, type = true, unpack = true,
    xpcall = true,
    -- coroutine
    coroutine = true,
    -- package / require
    package = true, require = true, module = true,
    -- string, table, math, io, os, debug
    string = true, table = true, math = true, io = true, os = true, debug = true,
    bit = true, bit32 = true, utf8 = true,
    -- Luau / Roblox common
    game = true, workspace = true, script = true, plugin = true,
    Instance = true, Enum = true, Vector2 = true, Vector3 = true,
    CFrame = true, Color3 = true, UDim = true, UDim2 = true,
    Ray = true, Region3 = true, BrickColor = true, NumberSequence = true,
    ColorSequence = true, NumberRange = true, Rect = true, TweenInfo = true,
    task = true, typeof = true, tick = true, time = true, wait = true,
    delay = true, spawn = true, delay = true, SharedTable = true,
    buffer = true, bit32 = true,
    -- metamethods
    __index = true, __newindex = true, __call = true, __tostring = true,
    __add = true, __sub = true, __mul = true, __div = true, __mod = true,
    __pow = true, __unm = true, __concat = true, __len = true,
    __eq = true, __lt = true, __le = true, __mode = true, __gc = true,
    __name = true, __close = true, __idiv = true, __band = true,
    __bor = true, __bxor = true, __bnot = true, __shl = true, __shr = true,
}

function Analyzer:isPreserved(name)
    return self.preserved[name] or DEFAULT_PRESERVED[name]
end

function Analyzer:enter(kind, node)
    self.current = Scope.new(self.current, kind)
    self.current.node = node
    return self.current
end

function Analyzer:leave()
    self.current = self.current.parent
end

function Analyzer:analyze(ast)
    self.rootScope = Scope.new(nil, "chunk")
    self.current = self.rootScope
    self.rootScope.node = ast
    self:visit(ast)
    return self.rootScope
end

function Analyzer:visit(node)
    if not node then return end
    local k = node.kind

    if k == "Chunk" or k == "Block" then
        if k == "Block" then
            self:enter("block", node)
        end
        for _, stmt in ipairs(node.body or {}) do
            self:visit(stmt)
        end
        if k == "Block" then
            self:leave()
        end

    elseif k == "LocalStatement" then
        for _, init in ipairs(node.init or {}) do
            self:visit(init)
        end
        for _, var in ipairs(node.variables or {}) do
            local b = self.current:declare(var.name, var)
            var.binding = b
        end

    elseif k == "FunctionDeclaration" then
        if node.isLocal and node.name and node.name.kind == "Identifier" then
            local b = self.current:declare(node.name.name, node.name)
            node.name.binding = b
        elseif node.name then
            self:visit(node.name) -- global or member
        end
        self:enter("function", node)
        for _, p in ipairs(node.params or {}) do
            local b = self.current:declare(p.name, p, true)
            p.binding = b
        end
        self:visit(node.body)
        self:leave()

    elseif k == "FunctionExpression" then
        self:enter("function", node)
        for _, p in ipairs(node.params or {}) do
            local b = self.current:declare(p.name, p, true)
            p.binding = b
        end
        self:visit(node.body)
        self:leave()

    elseif k == "ForNumericStatement" then
        self:visit(node.start)
        self:visit(node.stop)
        if node.step then self:visit(node.step) end
        self:enter("block", node)
        local b = self.current:declare(node.variable.name, node.variable)
        node.variable.binding = b
        self:visit(node.body)
        self:leave()

    elseif k == "ForGenericStatement" then
        for _, it in ipairs(node.iterators or {}) do
            self:visit(it)
        end
        self:enter("block", node)
        for _, v in ipairs(node.variables or {}) do
            local b = self.current:declare(v.name, v)
            v.binding = b
        end
        self:visit(node.body)
        self:leave()

    elseif k == "IfStatement" then
        for _, clause in ipairs(node.clauses or {}) do
            if clause.test then self:visit(clause.test) end
            self:visit(clause.body)
        end

    elseif k == "WhileStatement" then
        self:visit(node.test)
        self:visit(node.body)

    elseif k == "RepeatStatement" then
        self:enter("block", node)
        self:visit(node.body)
        self:visit(node.test) -- until can see locals from body
        self:leave()

    elseif k == "DoStatement" then
        self:visit(node.body)

    elseif k == "ReturnStatement" then
        for _, a in ipairs(node.arguments or {}) do
            self:visit(a)
        end

    elseif k == "AssignmentStatement" then
        for _, v in ipairs(node.variables or {}) do
            self:visit(v)
        end
        for _, i in ipairs(node.init or {}) do
            self:visit(i)
        end

    elseif k == "CallStatement" then
        self:visit(node.expression)

    elseif k == "Identifier" then
        local binding = self.current:lookup(node.name)
        if binding then
            node.binding = binding
            table.insert(binding.references, node)
            -- mark upvalues later if needed
        else
            -- global
            node.isGlobal = true
            self.globals[node.name] = true
        end

    elseif k == "BinaryExpression" or k == "UnaryExpression" then
        if node.left then self:visit(node.left) end
        if node.right then self:visit(node.right) end
        if node.argument then self:visit(node.argument) end

    elseif k == "CallExpression" then
        self:visit(node.callee)
        for _, a in ipairs(node.arguments or {}) do
            self:visit(a)
        end

    elseif k == "MemberExpression" then
        self:visit(node.object)
        -- property name is not a variable reference

    elseif k == "IndexExpression" then
        self:visit(node.object)
        self:visit(node.index)

    elseif k == "TableConstructor" then
        for _, f in ipairs(node.fields or {}) do
            if f.key then self:visit(f.key) end
            self:visit(f.value)
        end

    elseif k == "ParenthesizedExpression" then
        self:visit(node.expression)
    end
end

return {
    Scope = Scope,
    Analyzer = Analyzer,
}
