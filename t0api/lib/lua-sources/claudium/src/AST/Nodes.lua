-- IronBrew0 v0.001 - AST Node definitions
-- Hierarchical representation of Lua/Luau programs

local Nodes = {}

local function node(kind, fields)
    fields = fields or {}
    fields.kind = kind
    fields.line = fields.line or 0
    fields.column = fields.column or 0
    return fields
end

-- Expressions
function Nodes.Identifier(name, line, column)
    return node("Identifier", { name = name, line = line, column = column })
end

function Nodes.Literal(value, raw, line, column)
    return node("Literal", { value = value, raw = raw, line = line, column = column })
end

function Nodes.Vararg(line, column)
    return node("Vararg", { line = line, column = column })
end

function Nodes.UnaryExpression(op, argument, line, column)
    return node("UnaryExpression", { op = op, argument = argument, line = line, column = column })
end

function Nodes.BinaryExpression(op, left, right, line, column)
    return node("BinaryExpression", { op = op, left = left, right = right, line = line, column = column })
end

function Nodes.CallExpression(callee, arguments, isMethod, line, column)
    return node("CallExpression", {
        callee = callee,
        arguments = arguments or {},
        isMethod = isMethod or false,
        line = line,
        column = column,
    })
end

function Nodes.MemberExpression(object, property, computed, line, column)
    return node("MemberExpression", {
        object = object,
        property = property,
        computed = computed or false,
        line = line,
        column = column,
    })
end

function Nodes.IndexExpression(object, index, line, column)
    return node("IndexExpression", {
        object = object,
        index = index,
        line = line,
        column = column,
    })
end

function Nodes.TableConstructor(fields, line, column)
    return node("TableConstructor", { fields = fields or {}, line = line, column = column })
end

function Nodes.TableField(key, value, line, column)
    return node("TableField", { key = key, value = value, line = line, column = column })
end

function Nodes.FunctionExpression(params, body, isVararg, line, column)
    return node("FunctionExpression", {
        params = params or {},
        body = body,
        isVararg = isVararg or false,
        line = line,
        column = column,
    })
end

function Nodes.ParenthesizedExpression(expression, line, column)
    return node("ParenthesizedExpression", { expression = expression, line = line, column = column })
end

-- Statements
function Nodes.Chunk(body, line, column)
    return node("Chunk", { body = body or {}, line = line, column = column })
end

function Nodes.Block(body, line, column)
    return node("Block", { body = body or {}, line = line, column = column })
end

function Nodes.LocalStatement(variables, init, line, column)
    return node("LocalStatement", {
        variables = variables or {},
        init = init or {},
        line = line,
        column = column,
    })
end

function Nodes.AssignmentStatement(variables, init, line, column)
    return node("AssignmentStatement", {
        variables = variables or {},
        init = init or {},
        line = line,
        column = column,
    })
end

function Nodes.CallStatement(expression, line, column)
    return node("CallStatement", { expression = expression, line = line, column = column })
end

function Nodes.FunctionDeclaration(name, params, body, isLocal, isVararg, line, column)
    return node("FunctionDeclaration", {
        name = name,
        params = params or {},
        body = body,
        isLocal = isLocal or false,
        isVararg = isVararg or false,
        line = line,
        column = column,
    })
end

function Nodes.IfStatement(clauses, line, column)
    -- clauses: { {test=expr, body=block}, ... , {body=block} for else }
    return node("IfStatement", { clauses = clauses or {}, line = line, column = column })
end

function Nodes.WhileStatement(test, body, line, column)
    return node("WhileStatement", { test = test, body = body, line = line, column = column })
end

function Nodes.RepeatStatement(body, test, line, column)
    return node("RepeatStatement", { body = body, test = test, line = line, column = column })
end

function Nodes.ForNumericStatement(variable, start, stop, step, body, line, column)
    return node("ForNumericStatement", {
        variable = variable,
        start = start,
        stop = stop,
        step = step,
        body = body,
        line = line,
        column = column,
    })
end

function Nodes.ForGenericStatement(variables, iterators, body, line, column)
    return node("ForGenericStatement", {
        variables = variables or {},
        iterators = iterators or {},
        body = body,
        line = line,
        column = column,
    })
end

function Nodes.DoStatement(body, line, column)
    return node("DoStatement", { body = body, line = line, column = column })
end

function Nodes.ReturnStatement(arguments, line, column)
    return node("ReturnStatement", { arguments = arguments or {}, line = line, column = column })
end

function Nodes.BreakStatement(line, column)
    return node("BreakStatement", { line = line, column = column })
end

function Nodes.ContinueStatement(line, column) -- Luau
    return node("ContinueStatement", { line = line, column = column })
end

function Nodes.GotoStatement(label, line, column)
    return node("GotoStatement", { label = label, line = line, column = column })
end

function Nodes.LabelStatement(label, line, column)
    return node("LabelStatement", { label = label, line = line, column = column })
end

function Nodes.EmptyStatement(line, column)
    return node("EmptyStatement", { line = line, column = column })
end

-- Utility
function Nodes.isExpression(n)
    local kinds = {
        Identifier = true, Literal = true, Vararg = true,
        UnaryExpression = true, BinaryExpression = true,
        CallExpression = true, MemberExpression = true, IndexExpression = true,
        TableConstructor = true, FunctionExpression = true,
        ParenthesizedExpression = true,
    }
    return n and kinds[n.kind]
end

function Nodes.isStatement(n)
    local kinds = {
        Chunk = true, Block = true, LocalStatement = true, AssignmentStatement = true,
        CallStatement = true, FunctionDeclaration = true, IfStatement = true,
        WhileStatement = true, RepeatStatement = true, ForNumericStatement = true,
        ForGenericStatement = true, DoStatement = true, ReturnStatement = true,
        BreakStatement = true, ContinueStatement = true, GotoStatement = true,
        LabelStatement = true, EmptyStatement = true,
    }
    return n and kinds[n.kind]
end

return Nodes
