-- IronBrew0 v0.001 - Aggressive Minifier
-- Produces compact / single-line output from AST while preserving semantics

local Minifier = {}
Minifier.__index = Minifier

function Minifier.new(options)
    options = options or {}
    return setmetatable({
        singleLine = options.singleLine ~= false, -- default true for aggressive
        keepParens = options.keepParens or false,
    }, Minifier)
end

-- Operator precedence for deciding when parentheses are required
local PREC = {
    ["or"]  = 1, ["and"] = 2,
    ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
    [".."] = 4,
    ["+"] = 5, ["-"] = 5,
    ["*"] = 6, ["/"] = 6, ["%"] = 6,
    ["^"] = 8,
    unary = 9,
}

local RIGHT_ASSOC = { [".."] = true, ["^"] = true }

function Minifier:needsParens(parentOp, childOp, isRight)
    if not parentOp or not childOp then return false end
    local pp, cp = PREC[parentOp], PREC[childOp]
    if not pp or not cp then return true end
    if cp < pp then return true end
    if cp == pp then
        if RIGHT_ASSOC[parentOp] then
            return not isRight
        else
            return isRight
        end
    end
    return false
end

function Minifier:emit(node, parentOp, isRight)
    if not node then return "" end
    local k = node.kind

    if k == "Chunk" or k == "Block" then
        local parts = {}
        for i, stmt in ipairs(node.body or {}) do
            local s = self:emit(stmt)
            if s and s ~= "" then
                -- After return/break/goto a following statement on the same line
                -- needs a semicolon or it will be parsed as part of the return expr.
                if self.singleLine and #parts > 0 then
                    local prev = parts[#parts]
                    if prev:match("return$") or prev:match("return .+")
                        or prev == "break" or prev == "continue"
                        or prev:match("^goto ") then
                        parts[#parts] = prev .. ";"
                    end
                end
                table.insert(parts, s)
            end
        end
        if self.singleLine then
            return table.concat(parts, " ")
        else
            return table.concat(parts, "\n")
        end

    elseif k == "Identifier" then
        return node.name

    elseif k == "Literal" then
        if type(node.value) == "string" then
            -- Prefer the shortest representation
            local s = node.value
            local hasDq = s:find('"', 1, true)
            local hasSq = s:find("'", 1, true)
            if not hasDq then
                return '"' .. s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
            elseif not hasSq then
                return "'" .. s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. "'"
            else
                return string.format("%q", s)
            end
        elseif node.value == nil then
            return "nil"
        elseif node.value == true then
            return "true"
        elseif node.value == false then
            return "false"
        else
            return tostring(node.value)
        end

    elseif k == "Vararg" then
        return "..."

    elseif k == "UnaryExpression" then
        local arg = self:emit(node.argument, "unary", true)
        local op = node.op
        if op == "not" then
            return "not " .. arg
        end
        -- # and - bind tightly
        if node.argument.kind == "BinaryExpression" or node.argument.kind == "UnaryExpression" then
            return op .. "(" .. arg .. ")"
        end
        return op .. arg

    elseif k == "BinaryExpression" then
        local left = self:emit(node.left, node.op, false)
        local right = self:emit(node.right, node.op, true)
        if self:needsParens(parentOp, node.op, isRight) then
            return "(" .. left .. node.op .. right .. ")"
        end
        -- space around 'and'/'or' for safety with identifiers
        if node.op == "and" or node.op == "or" then
            return left .. " " .. node.op .. " " .. right
        end
        return left .. node.op .. right

    elseif k == "CallExpression" then
        local callee = self:emit(node.callee)
        local args = {}
        for _, a in ipairs(node.arguments or {}) do
            table.insert(args, self:emit(a))
        end
        return callee .. "(" .. table.concat(args, ",") .. ")"

    elseif k == "MemberExpression" then
        return self:emit(node.object) .. "." .. self:emit(node.property)

    elseif k == "IndexExpression" then
        return self:emit(node.object) .. "[" .. self:emit(node.index) .. "]"

    elseif k == "TableConstructor" then
        local fields = {}
        for _, f in ipairs(node.fields or {}) do
            if f.key then
                if f.key.kind == "Identifier" then
                    table.insert(fields, f.key.name .. "=" .. self:emit(f.value))
                else
                    table.insert(fields, "[" .. self:emit(f.key) .. "]=" .. self:emit(f.value))
                end
            else
                table.insert(fields, self:emit(f.value))
            end
        end
        return "{" .. table.concat(fields, ",") .. "}"

    elseif k == "FunctionExpression" then
        local params = {}
        for _, p in ipairs(node.params or {}) do
            table.insert(params, self:emit(p))
        end
        if node.isVararg then table.insert(params, "...") end
        local body = self:emit(node.body)
        return "function(" .. table.concat(params, ",") .. ")" .. body .. " end"

    elseif k == "ParenthesizedExpression" then
        -- Drop unnecessary parens when safe
        if self.keepParens then
            return "(" .. self:emit(node.expression) .. ")"
        end
        return self:emit(node.expression, parentOp, isRight)

    elseif k == "LocalStatement" then
        local vars = {}
        for _, v in ipairs(node.variables or {}) do
            table.insert(vars, self:emit(v))
        end
        local s = "local " .. table.concat(vars, ",")
        if node.init and #node.init > 0 then
            local inits = {}
            for _, i in ipairs(node.init) do
                table.insert(inits, self:emit(i))
            end
            s = s .. "=" .. table.concat(inits, ",")
        end
        return s

    elseif k == "AssignmentStatement" then
        local vars, inits = {}, {}
        for _, v in ipairs(node.variables or {}) do table.insert(vars, self:emit(v)) end
        for _, i in ipairs(node.init or {}) do table.insert(inits, self:emit(i)) end
        return table.concat(vars, ",") .. "=" .. table.concat(inits, ",")

    elseif k == "CallStatement" then
        return self:emit(node.expression)

    elseif k == "FunctionDeclaration" then
        local params = {}
        for _, p in ipairs(node.params or {}) do table.insert(params, self:emit(p)) end
        if node.isVararg then table.insert(params, "...") end
        local prefix = node.isLocal and "local function " or "function "
        local name = node.name and self:emit(node.name) or ""
        local body = self:emit(node.body)
        return prefix .. name .. "(" .. table.concat(params, ",") .. ")" .. body .. " end"

    elseif k == "IfStatement" then
        local parts = {}
        for i, clause in ipairs(node.clauses or {}) do
            if i == 1 then
                table.insert(parts, "if " .. self:emit(clause.test) .. " then " .. self:emit(clause.body))
            elseif clause.test then
                table.insert(parts, "elseif " .. self:emit(clause.test) .. " then " .. self:emit(clause.body))
            else
                table.insert(parts, "else " .. self:emit(clause.body))
            end
        end
        table.insert(parts, "end")
        return table.concat(parts, " ")

    elseif k == "WhileStatement" then
        return "while " .. self:emit(node.test) .. " do " .. self:emit(node.body) .. " end"

    elseif k == "RepeatStatement" then
        return "repeat " .. self:emit(node.body) .. " until " .. self:emit(node.test)

    elseif k == "ForNumericStatement" then
        local step = node.step and ("," .. self:emit(node.step)) or ""
        return "for " .. self:emit(node.variable) .. "=" .. self:emit(node.start) .. ","
            .. self:emit(node.stop) .. step .. " do " .. self:emit(node.body) .. " end"

    elseif k == "ForGenericStatement" then
        local vars, iters = {}, {}
        for _, v in ipairs(node.variables or {}) do table.insert(vars, self:emit(v)) end
        for _, i in ipairs(node.iterators or {}) do table.insert(iters, self:emit(i)) end
        return "for " .. table.concat(vars, ",") .. " in " .. table.concat(iters, ",")
            .. " do " .. self:emit(node.body) .. " end"

    elseif k == "DoStatement" then
        return "do " .. self:emit(node.body) .. " end"

    elseif k == "ReturnStatement" then
        if not node.arguments or #node.arguments == 0 then
            return "return"
        end
        local args = {}
        for _, a in ipairs(node.arguments) do table.insert(args, self:emit(a)) end
        return "return " .. table.concat(args, ",")

    elseif k == "BreakStatement" then
        return "break"

    elseif k == "ContinueStatement" then
        return "continue"

    elseif k == "GotoStatement" then
        return "goto " .. tostring(node.label)

    elseif k == "LabelStatement" then
        return "::" .. tostring(node.label) .. "::"

    elseif k == "EmptyStatement" then
        return ""

    else
        return ""
    end
end

function Minifier:minify(ast)
    return self:emit(ast)
end

return Minifier
