-- IronBrew0 v0.001 - AST Pretty Printer (debug)

local Printer = {}
Printer.__index = Printer

function Printer.new(options)
    options = options or {}
    return setmetatable({
        indentSize = options.indentSize or 2,
        singleLine = options.singleLine or false,
    }, Printer)
end

function Printer:indent(level)
    if self.singleLine then return "" end
    return string.rep(" ", level * self.indentSize)
end

function Printer:print(node, level)
    level = level or 0
    if not node then return "nil" end

    local k = node.kind
    local ind = self:indent(level)
    local nl = self.singleLine and " " or "\n"

    if k == "Chunk" or k == "Block" then
        local parts = {}
        for _, stmt in ipairs(node.body or {}) do
            table.insert(parts, self:print(stmt, level))
        end
        return table.concat(parts, self.singleLine and "; " or "\n")
    elseif k == "Identifier" then
        return node.name
    elseif k == "Literal" then
        if type(node.value) == "string" then
            return string.format("%q", node.value)
        elseif node.value == nil then
            return "nil"
        else
            return tostring(node.value)
        end
    elseif k == "Vararg" then
        return "..."
    elseif k == "UnaryExpression" then
        return node.op .. self:print(node.argument, level)
    elseif k == "BinaryExpression" then
        return "(" .. self:print(node.left, level) .. " " .. node.op .. " " .. self:print(node.right, level) .. ")"
    elseif k == "CallExpression" then
        local args = {}
        for _, a in ipairs(node.arguments or {}) do
            table.insert(args, self:print(a, level))
        end
        local sep = node.isMethod and ":" or ""
        return self:print(node.callee, level) .. "(" .. table.concat(args, ", ") .. ")"
    elseif k == "MemberExpression" then
        return self:print(node.object, level) .. "." .. self:print(node.property, level)
    elseif k == "IndexExpression" then
        return self:print(node.object, level) .. "[" .. self:print(node.index, level) .. "]"
    elseif k == "TableConstructor" then
        local fields = {}
        for _, f in ipairs(node.fields or {}) do
            if f.key then
                if f.key.kind == "Identifier" then
                    table.insert(fields, f.key.name .. " = " .. self:print(f.value, level))
                else
                    table.insert(fields, "[" .. self:print(f.key, level) .. "] = " .. self:print(f.value, level))
                end
            else
                table.insert(fields, self:print(f.value, level))
            end
        end
        return "{" .. table.concat(fields, ", ") .. "}"
    elseif k == "FunctionExpression" then
        local params = {}
        for _, p in ipairs(node.params or {}) do
            table.insert(params, self:print(p, level))
        end
        if node.isVararg then table.insert(params, "...") end
        return "function(" .. table.concat(params, ", ") .. ")" .. nl
            .. self:print(node.body, level + 1) .. nl
            .. ind .. "end"
    elseif k == "ParenthesizedExpression" then
        return "(" .. self:print(node.expression, level) .. ")"
    elseif k == "LocalStatement" then
        local vars = {}
        for _, v in ipairs(node.variables or {}) do
            table.insert(vars, self:print(v, level))
        end
        local s = "local " .. table.concat(vars, ", ")
        if node.init and #node.init > 0 then
            local inits = {}
            for _, i in ipairs(node.init) do
                table.insert(inits, self:print(i, level))
            end
            s = s .. " = " .. table.concat(inits, ", ")
        end
        return ind .. s
    elseif k == "AssignmentStatement" then
        local vars, inits = {}, {}
        for _, v in ipairs(node.variables or {}) do table.insert(vars, self:print(v, level)) end
        for _, i in ipairs(node.init or {}) do table.insert(inits, self:print(i, level)) end
        return ind .. table.concat(vars, ", ") .. " = " .. table.concat(inits, ", ")
    elseif k == "CallStatement" then
        return ind .. self:print(node.expression, level)
    elseif k == "FunctionDeclaration" then
        local params = {}
        for _, p in ipairs(node.params or {}) do table.insert(params, self:print(p, level)) end
        if node.isVararg then table.insert(params, "...") end
        local prefix = node.isLocal and "local function " or "function "
        local name = node.name and self:print(node.name, level) or ""
        return ind .. prefix .. name .. "(" .. table.concat(params, ", ") .. ")" .. nl
            .. self:print(node.body, level + 1) .. nl
            .. ind .. "end"
    elseif k == "IfStatement" then
        local parts = {}
        for i, clause in ipairs(node.clauses or {}) do
            if i == 1 then
                table.insert(parts, ind .. "if " .. self:print(clause.test, level) .. " then" .. nl
                    .. self:print(clause.body, level + 1))
            elseif clause.test then
                table.insert(parts, ind .. "elseif " .. self:print(clause.test, level) .. " then" .. nl
                    .. self:print(clause.body, level + 1))
            else
                table.insert(parts, ind .. "else" .. nl .. self:print(clause.body, level + 1))
            end
        end
        table.insert(parts, ind .. "end")
        return table.concat(parts, nl)
    elseif k == "WhileStatement" then
        return ind .. "while " .. self:print(node.test, level) .. " do" .. nl
            .. self:print(node.body, level + 1) .. nl
            .. ind .. "end"
    elseif k == "RepeatStatement" then
        return ind .. "repeat" .. nl
            .. self:print(node.body, level + 1) .. nl
            .. ind .. "until " .. self:print(node.test, level)
    elseif k == "ForNumericStatement" then
        local step = node.step and (", " .. self:print(node.step, level)) or ""
        return ind .. "for " .. self:print(node.variable, level) .. " = "
            .. self:print(node.start, level) .. ", " .. self:print(node.stop, level) .. step
            .. " do" .. nl .. self:print(node.body, level + 1) .. nl .. ind .. "end"
    elseif k == "ForGenericStatement" then
        local vars, iters = {}, {}
        for _, v in ipairs(node.variables or {}) do table.insert(vars, self:print(v, level)) end
        for _, i in ipairs(node.iterators or {}) do table.insert(iters, self:print(i, level)) end
        return ind .. "for " .. table.concat(vars, ", ") .. " in " .. table.concat(iters, ", ")
            .. " do" .. nl .. self:print(node.body, level + 1) .. nl .. ind .. "end"
    elseif k == "DoStatement" then
        return ind .. "do" .. nl .. self:print(node.body, level + 1) .. nl .. ind .. "end"
    elseif k == "ReturnStatement" then
        local args = {}
        for _, a in ipairs(node.arguments or {}) do table.insert(args, self:print(a, level)) end
        if #args > 0 then
            return ind .. "return " .. table.concat(args, ", ")
        end
        return ind .. "return"
    elseif k == "BreakStatement" then
        return ind .. "break"
    elseif k == "ContinueStatement" then
        return ind .. "continue"
    elseif k == "GotoStatement" then
        return ind .. "goto " .. tostring(node.label)
    elseif k == "LabelStatement" then
        return ind .. "::" .. tostring(node.label) .. "::"
    elseif k == "EmptyStatement" then
        return ind .. ";"
    else
        return ind .. "--[[ unknown node " .. tostring(k) .. " ]]"
    end
end

return Printer
