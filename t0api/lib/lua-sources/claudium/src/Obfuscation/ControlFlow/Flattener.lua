-- IronBrew0 v0.001 - Control-Flow Flattening
-- Transforms sequential blocks into a state-machine dispatcher.
-- Operates on AST so the result remains valid, executable Lua.
--
-- Important: locals that span multiple original statements are hoisted
-- and turned into assignments so they remain visible across dispatcher states.

local Nodes = require("src.AST.Nodes")

local Flattener = {}
Flattener.__index = Flattener

function Flattener.new(options)
    options = options or {}
    return setmetatable({
        intensity      = options.intensity or 1.0,
        minStatements  = options.minStatements or 2,
        junkStates     = options.junkStates ~= false,
        stateName      = options.stateName or "__s",
        counter        = 0,
    }, Flattener)
end

local function isTerminator(stmt)
    if not stmt then return false end
    local k = stmt.kind
    return k == "ReturnStatement" or k == "BreakStatement"
        or k == "ContinueStatement" or k == "GotoStatement"
end

-- Collect names declared by LocalStatement or local FunctionDeclaration
local function localNames(stmt)
    local names = {}
    if not stmt then return names end
    if stmt.kind == "LocalStatement" then
        for _, v in ipairs(stmt.variables or {}) do
            if v.kind == "Identifier" then
                table.insert(names, v.name)
            end
        end
    elseif stmt.kind == "FunctionDeclaration" and stmt.isLocal and stmt.name then
        if stmt.name.kind == "Identifier" then
            table.insert(names, stmt.name.name)
        end
    end
    return names
end

-- Turn LocalStatement into pure assignments (variables already declared)
local function localToAssignments(stmt, line, column)
    local out = {}
    local vars = stmt.variables or {}
    local inits = stmt.init or {}
    for i, v in ipairs(vars) do
        local rhs = inits[i] or Nodes.Literal(nil, "nil", line, column)
        table.insert(out, Nodes.AssignmentStatement({ v }, { rhs }, line, column))
    end
    return out
end

-- Turn local function foo(...) ... end into: foo = function(...) ... end
local function localFunctionToAssignment(stmt, line, column)
    local name = stmt.name
    local fn = Nodes.FunctionExpression(stmt.params, stmt.body, stmt.isVararg, line, column)
    return {
        Nodes.AssignmentStatement({ name }, { fn }, line, column)
    }
end

function Flattener:_shouldFlatten(body)
    if not body or not body.body then return false end
    if #body.body < self.minStatements then return false end
    return math.random() <= self.intensity
end

function Flattener:_flattenStatements(stmts, line, column)
    if not stmts or #stmts < self.minStatements then
        return Nodes.Block(stmts or {}, line, column)
    end

    local n = #stmts
    if n < 2 then
        return Nodes.Block(stmts, line, column)
    end

    -- 1) Collect every local declared in this statement list (hoist)
    local hoisted = {}      -- ordered unique names
    local seen = {}
    for _, stmt in ipairs(stmts) do
        for _, name in ipairs(localNames(stmt)) do
            if not seen[name] then
                seen[name] = true
                table.insert(hoisted, name)
            end
        end
    end

    -- 2) Build per-statement blocks; convert locals / local-functions → assignments
    local blocks = {}
    for _, stmt in ipairs(stmts) do
        local bodyStmts
        if stmt.kind == "LocalStatement" then
            bodyStmts = localToAssignments(stmt, line, column)
        elseif stmt.kind == "FunctionDeclaration" and stmt.isLocal then
            bodyStmts = localFunctionToAssignment(stmt, line, column)
        else
            bodyStmts = { stmt }
        end
        table.insert(blocks, { statements = bodyStmts })
    end

    local exitState = n + 1
    local stateId = Nodes.Identifier(self.stateName, line, column)

    -- local __s = 1
    -- local v1, v2, ...  (hoisted, initially nil)
    local prelude = {}
    table.insert(prelude, Nodes.LocalStatement(
        { Nodes.Identifier(self.stateName, line, column) },
        { Nodes.Literal(1, "1", line, column) },
        line, column
    ))
    if #hoisted > 0 then
        local vars = {}
        for _, name in ipairs(hoisted) do
            table.insert(vars, Nodes.Identifier(name, line, column))
        end
        table.insert(prelude, Nodes.LocalStatement(vars, {}, line, column))
    end

    -- Dispatcher clauses
    -- NOTE: Lua forbids any statement after return/break in the same block.
    -- So we only append the state transition when the block does not already
    -- end with a terminator.
    local clauses = {}
    for i, blk in ipairs(blocks) do
        local bodyStmts = {}
        for _, s in ipairs(blk.statements) do
            table.insert(bodyStmts, s)
        end
        local last = bodyStmts[#bodyStmts]
        local term = isTerminator(last)
        if not term then
            local nextState = (i < n) and (i + 1) or exitState
            table.insert(bodyStmts, Nodes.AssignmentStatement(
                { Nodes.Identifier(self.stateName, line, column) },
                { Nodes.Literal(nextState, tostring(nextState), line, column) },
                line, column
            ))
        end

        local test = Nodes.BinaryExpression(
            "==",
            Nodes.Identifier(self.stateName, line, column),
            Nodes.Literal(i, tostring(i), line, column),
            line, column
        )
        table.insert(clauses, {
            test = test,
            body = Nodes.Block(bodyStmts, line, column),
        })
    end

    -- Optional dead / junk state
    if self.junkStates and n >= 2 then
        local junkId = n + 2
        table.insert(clauses, {
            test = Nodes.BinaryExpression(
                "==",
                Nodes.Identifier(self.stateName, line, column),
                Nodes.Literal(junkId, tostring(junkId), line, column),
                line, column
            ),
            body = Nodes.Block({
                Nodes.AssignmentStatement(
                    { Nodes.Identifier(self.stateName, line, column) },
                    { Nodes.Literal(1, "1", line, column) },
                    line, column
                ),
            }, line, column),
        })
    end

    -- Exit state → break
    table.insert(clauses, {
        test = Nodes.BinaryExpression(
            "==",
            Nodes.Identifier(self.stateName, line, column),
            Nodes.Literal(exitState, tostring(exitState), line, column),
            line, column
        ),
        body = Nodes.Block({ Nodes.BreakStatement(line, column) }, line, column),
    })

    local ifStmt = Nodes.IfStatement(clauses, line, column)
    local whileStmt = Nodes.WhileStatement(
        Nodes.Literal(true, "true", line, column),
        Nodes.Block({ ifStmt }, line, column),
        line, column
    )

    local body = {}
    for _, s in ipairs(prelude) do table.insert(body, s) end
    table.insert(body, whileStmt)

    return Nodes.DoStatement(Nodes.Block(body, line, column), line, column)
end

function Flattener:transform(node)
    if not node then return node end
    local k = node.kind

    if k == "Chunk" then
        for i, stmt in ipairs(node.body or {}) do
            node.body[i] = self:transform(stmt)
        end
        -- Flatten top-level only when it looks like a script body with several stmts
        if self:_shouldFlatten(node) then
            local flat = self:_flattenStatements(node.body, node.line, node.column)
            if flat.kind == "DoStatement" then
                node.body = flat.body.body
            else
                node.body = { flat }
            end
        end
        return node

    elseif k == "Block" then
        for i, stmt in ipairs(node.body or {}) do
            node.body[i] = self:transform(stmt)
        end
        return node

    elseif k == "FunctionDeclaration" or k == "FunctionExpression" then
        if node.body then
            node.body = self:transform(node.body)
            if self:_shouldFlatten(node.body) then
                local flat = self:_flattenStatements(node.body.body, node.line, node.column)
                if flat.kind == "DoStatement" then
                    node.body = flat.body
                else
                    node.body = Nodes.Block({ flat }, node.line, node.column)
                end
            end
        end
        return node

    elseif k == "IfStatement" then
        for _, clause in ipairs(node.clauses or {}) do
            if clause.body then clause.body = self:transform(clause.body) end
            if clause.test then clause.test = self:transform(clause.test) end
        end
        return node

    elseif k == "WhileStatement" or k == "RepeatStatement" or k == "DoStatement" then
        if node.body then node.body = self:transform(node.body) end
        if node.test then node.test = self:transform(node.test) end
        return node

    elseif k == "ForNumericStatement" or k == "ForGenericStatement" then
        if node.body then node.body = self:transform(node.body) end
        if node.start then node.start = self:transform(node.start) end
        if node.stop then node.stop = self:transform(node.stop) end
        if node.step then node.step = self:transform(node.step) end
        for i, it in ipairs(node.iterators or {}) do
            node.iterators[i] = self:transform(it)
        end
        return node

    elseif k == "LocalStatement" or k == "AssignmentStatement" then
        for i, v in ipairs(node.variables or {}) do
            node.variables[i] = self:transform(v)
        end
        for i, v in ipairs(node.init or {}) do
            node.init[i] = self:transform(v)
        end
        return node

    elseif k == "CallStatement" then
        if node.expression then node.expression = self:transform(node.expression) end
        return node

    elseif k == "ReturnStatement" then
        for i, a in ipairs(node.arguments or {}) do
            node.arguments[i] = self:transform(a)
        end
        return node

    elseif k == "BinaryExpression" then
        node.left = self:transform(node.left)
        node.right = self:transform(node.right)
        return node

    elseif k == "UnaryExpression" then
        node.argument = self:transform(node.argument)
        return node

    elseif k == "CallExpression" then
        node.callee = self:transform(node.callee)
        for i, a in ipairs(node.arguments or {}) do
            node.arguments[i] = self:transform(a)
        end
        return node

    elseif k == "MemberExpression" then
        if node.object then node.object = self:transform(node.object) end
        return node

    elseif k == "IndexExpression" then
        if node.object then node.object = self:transform(node.object) end
        if node.index then node.index = self:transform(node.index) end
        return node

    elseif k == "TableConstructor" then
        for _, f in ipairs(node.fields or {}) do
            if f.key then f.key = self:transform(f.key) end
            if f.value then f.value = self:transform(f.value) end
        end
        return node

    elseif k == "ParenthesizedExpression" then
        node.expression = self:transform(node.expression)
        return node
    end

    return node
end

function Flattener:run(ast)
    math.randomseed(os.time() % 100000 + (self.counter or 0))
    return self:transform(ast)
end

return Flattener
