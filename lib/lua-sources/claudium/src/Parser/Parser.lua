-- IronBrew0 v0.001 - Recursive Descent Parser
-- Builds AST from token stream. Supports Lua 5.1 core + basic Luau extensions.

local Token = require("src.Lexer.Token")
local Nodes = require("src.AST.Nodes")

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens, options)
    options = options or {}
    local self = setmetatable({
        tokens  = tokens or {},
        pos     = 1,
        errors  = {},
        target  = options.target or "lua51",
    }, Parser)
    return self
end

function Parser:current()
    return self.tokens[self.pos] or self.tokens[#self.tokens]
end

function Parser:peek(offset)
    offset = offset or 0
    return self.tokens[self.pos + offset]
end

function Parser:advance()
    local tok = self:current()
    if tok and tok.kind ~= Token.Kind.Eof then
        self.pos = self.pos + 1
    end
    return tok
end

function Parser:check(kind)
    local tok = self:current()
    return tok and tok.kind == kind
end

function Parser:match(kind)
    if self:check(kind) then
        return self:advance()
    end
    return nil
end

function Parser:expect(kind, message)
    local tok = self:current()
    if tok and tok.kind == kind then
        return self:advance()
    end
    message = message or ("Expected " .. tostring(kind) .. ", got " .. (tok and tok.kind or "eof"))
    table.insert(self.errors, {
        message = message,
        line = tok and tok.line or 0,
        column = tok and tok.column or 0,
    })
    return tok
end

function Parser:error(message)
    local tok = self:current()
    table.insert(self.errors, {
        message = message,
        line = tok and tok.line or 0,
        column = tok and tok.column or 0,
    })
end

-- Precedence climbing for binary operators
local PRECEDENCE = {
    ["or"]  = 1,
    ["and"] = 2,
    ["<"]   = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
    [".."]  = 4,
    ["+"]   = 5, ["-"] = 5,
    ["*"]   = 6, ["/"] = 6, ["%"] = 6,
    ["^"]   = 8, -- right associative
}

local RIGHT_ASSOC = {
    [".."] = true,
    ["^"]  = true,
}

function Parser:parseChunk()
    local body = self:parseBlockBody()
    return Nodes.Chunk(body, 1, 1)
end

function Parser:parseBlock()
    local body = self:parseBlockBody()
    return Nodes.Block(body)
end

function Parser:parseBlockBody()
    local statements = {}
    while true do
        local tok = self:current()
        if not tok or tok.kind == Token.Kind.Eof
            or tok.kind == Token.Kind.End
            or tok.kind == Token.Kind.Else
            or tok.kind == Token.Kind.Elseif
            or tok.kind == Token.Kind.Until then
            break
        end
        local stmt = self:parseStatement()
        if stmt then
            table.insert(statements, stmt)
        else
            -- recovery: skip token
            self:advance()
        end
        -- optional semicolon
        self:match(Token.Kind.Semicolon)
    end
    return statements
end

function Parser:parseStatement()
    local tok = self:current()
    if not tok then return nil end

    if tok.kind == Token.Kind.Local then
        return self:parseLocal()
    elseif tok.kind == Token.Kind.Function then
        return self:parseFunctionDeclaration(false)
    elseif tok.kind == Token.Kind.If then
        return self:parseIf()
    elseif tok.kind == Token.Kind.While then
        return self:parseWhile()
    elseif tok.kind == Token.Kind.Repeat then
        return self:parseRepeat()
    elseif tok.kind == Token.Kind.For then
        return self:parseFor()
    elseif tok.kind == Token.Kind.Do then
        return self:parseDo()
    elseif tok.kind == Token.Kind.Return then
        return self:parseReturn()
    elseif tok.kind == Token.Kind.Break then
        self:advance()
        return Nodes.BreakStatement(tok.line, tok.column)
    elseif tok.kind == Token.Kind.Continue then
        self:advance()
        return Nodes.ContinueStatement(tok.line, tok.column)
    elseif tok.kind == Token.Kind.Goto then
        self:advance()
        local label = self:expect(Token.Kind.Identifier)
        return Nodes.GotoStatement(label and label.value, tok.line, tok.column)
    elseif tok.kind == Token.Kind.DoubleColon then
        self:advance()
        local label = self:expect(Token.Kind.Identifier)
        self:expect(Token.Kind.DoubleColon)
        return Nodes.LabelStatement(label and label.value, tok.line, tok.column)
    elseif tok.kind == Token.Kind.Semicolon then
        self:advance()
        return Nodes.EmptyStatement(tok.line, tok.column)
    else
        -- Expression statement or assignment
        return self:parseAssignmentOrCall()
    end
end

function Parser:parseLocal()
    local tok = self:advance() -- local
    if self:check(Token.Kind.Function) then
        return self:parseFunctionDeclaration(true)
    end

    local vars = {}
    repeat
        local name = self:expect(Token.Kind.Identifier)
        if name then
            table.insert(vars, Nodes.Identifier(name.value, name.line, name.column))
        end
    until not self:match(Token.Kind.Comma)

    local inits = {}
    if self:match(Token.Kind.Assign) then
        inits = self:parseExpressionList()
    end

    return Nodes.LocalStatement(vars, inits, tok.line, tok.column)
end

function Parser:parseFunctionDeclaration(isLocal)
    local tok = self:advance() -- function
    local name = nil

    if not isLocal then
        -- name can be a.b.c:d
        name = self:parseFunctionName()
    else
        local id = self:expect(Token.Kind.Identifier)
        name = id and Nodes.Identifier(id.value, id.line, id.column) or nil
    end

    self:expect(Token.Kind.LParen)
    local params, isVararg = self:parseParamList()
    self:expect(Token.Kind.RParen)

    local body = self:parseBlock()
    self:expect(Token.Kind.End)

    return Nodes.FunctionDeclaration(name, params, body, isLocal, isVararg, tok.line, tok.column)
end

function Parser:parseFunctionName()
    local id = self:expect(Token.Kind.Identifier)
    if not id then return nil end
    local expr = Nodes.Identifier(id.value, id.line, id.column)

    while self:match(Token.Kind.Dot) do
        local prop = self:expect(Token.Kind.Identifier)
        expr = Nodes.MemberExpression(expr, Nodes.Identifier(prop and prop.value or "", prop and prop.line, prop and prop.column), false, id.line, id.column)
    end

    if self:match(Token.Kind.Colon) then
        local method = self:expect(Token.Kind.Identifier)
        expr = Nodes.MemberExpression(expr, Nodes.Identifier(method and method.value or "", method and method.line, method and method.column), false, id.line, id.column)
        -- mark as method later if needed
        expr.isMethod = true
    end

    return expr
end

function Parser:parseParamList()
    local params = {}
    local isVararg = false

    if self:check(Token.Kind.RParen) then
        return params, false
    end

    if self:match(Token.Kind.DotDotDot) then
        return params, true
    end

    local id = self:expect(Token.Kind.Identifier)
    if id then
        table.insert(params, Nodes.Identifier(id.value, id.line, id.column))
    end

    while self:match(Token.Kind.Comma) do
        if self:match(Token.Kind.DotDotDot) then
            isVararg = true
            break
        end
        id = self:expect(Token.Kind.Identifier)
        if id then
            table.insert(params, Nodes.Identifier(id.value, id.line, id.column))
        end
    end

    return params, isVararg
end

function Parser:parseIf()
    local tok = self:advance() -- if
    local clauses = {}

    local test = self:parseExpression()
    self:expect(Token.Kind.Then)
    local body = self:parseBlock()
    table.insert(clauses, { test = test, body = body })

    while self:match(Token.Kind.Elseif) do
        test = self:parseExpression()
        self:expect(Token.Kind.Then)
        body = self:parseBlock()
        table.insert(clauses, { test = test, body = body })
    end

    if self:match(Token.Kind.Else) then
        body = self:parseBlock()
        table.insert(clauses, { body = body })
    end

    self:expect(Token.Kind.End)
    return Nodes.IfStatement(clauses, tok.line, tok.column)
end

function Parser:parseWhile()
    local tok = self:advance()
    local test = self:parseExpression()
    self:expect(Token.Kind.Do)
    local body = self:parseBlock()
    self:expect(Token.Kind.End)
    return Nodes.WhileStatement(test, body, tok.line, tok.column)
end

function Parser:parseRepeat()
    local tok = self:advance()
    local body = self:parseBlock()
    self:expect(Token.Kind.Until)
    local test = self:parseExpression()
    return Nodes.RepeatStatement(body, test, tok.line, tok.column)
end

function Parser:parseFor()
    local tok = self:advance() -- for
    local name = self:expect(Token.Kind.Identifier)
    local var = name and Nodes.Identifier(name.value, name.line, name.column)

    if self:match(Token.Kind.Assign) then
        -- numeric for
        local start = self:parseExpression()
        self:expect(Token.Kind.Comma)
        local stop = self:parseExpression()
        local step = nil
        if self:match(Token.Kind.Comma) then
            step = self:parseExpression()
        end
        self:expect(Token.Kind.Do)
        local body = self:parseBlock()
        self:expect(Token.Kind.End)
        return Nodes.ForNumericStatement(var, start, stop, step, body, tok.line, tok.column)
    else
        -- generic for
        local vars = { var }
        while self:match(Token.Kind.Comma) do
            local n = self:expect(Token.Kind.Identifier)
            if n then
                table.insert(vars, Nodes.Identifier(n.value, n.line, n.column))
            end
        end
        self:expect(Token.Kind.In)
        local iterators = self:parseExpressionList()
        self:expect(Token.Kind.Do)
        local body = self:parseBlock()
        self:expect(Token.Kind.End)
        return Nodes.ForGenericStatement(vars, iterators, body, tok.line, tok.column)
    end
end

function Parser:parseDo()
    local tok = self:advance()
    local body = self:parseBlock()
    self:expect(Token.Kind.End)
    return Nodes.DoStatement(body, tok.line, tok.column)
end

function Parser:parseReturn()
    local tok = self:advance()
    local args = {}
    if not self:check(Token.Kind.End)
        and not self:check(Token.Kind.Else)
        and not self:check(Token.Kind.Elseif)
        and not self:check(Token.Kind.Until)
        and not self:check(Token.Kind.Eof)
        and not self:check(Token.Kind.Semicolon) then
        args = self:parseExpressionList()
    end
    return Nodes.ReturnStatement(args, tok.line, tok.column)
end

function Parser:parseAssignmentOrCall()
    local expr = self:parseSuffixExpression()
    if not expr then
        self:error("Expected statement")
        return nil
    end

    if self:check(Token.Kind.Assign) or self:check(Token.Kind.Comma) then
        -- assignment
        local vars = { expr }
        while self:match(Token.Kind.Comma) do
            local e = self:parseSuffixExpression()
            if e then table.insert(vars, e) end
        end
        self:expect(Token.Kind.Assign)
        local inits = self:parseExpressionList()
        return Nodes.AssignmentStatement(vars, inits, expr.line, expr.column)
    end

    -- must be a call
    if expr.kind == "CallExpression" then
        return Nodes.CallStatement(expr, expr.line, expr.column)
    end

    self:error("Expected assignment or function call")
    return Nodes.CallStatement(expr, expr.line, expr.column)
end

function Parser:parseExpressionList()
    local list = { self:parseExpression() }
    while self:match(Token.Kind.Comma) do
        table.insert(list, self:parseExpression())
    end
    return list
end

function Parser:parseExpression()
    return self:parseBinaryExpression(0)
end

function Parser:parseBinaryExpression(minPrec)
    local left = self:parseUnary()

    while true do
        local tok = self:current()
        if not tok then break end
        local op = tok.value or tok.kind
        local prec = PRECEDENCE[op]
        if not prec or prec < minPrec then break end

        self:advance()
        local nextMin = prec + (RIGHT_ASSOC[op] and 0 or 1)
        local right = self:parseBinaryExpression(nextMin)
        left = Nodes.BinaryExpression(op, left, right, tok.line, tok.column)
    end

    return left
end

function Parser:parseUnary()
    local tok = self:current()
    if not tok then return nil end

    if tok.kind == Token.Kind.Not or tok.kind == Token.Kind.Minus or tok.kind == Token.Kind.Hash then
        self:advance()
        local arg = self:parseUnary()
        return Nodes.UnaryExpression(tok.value or tok.kind, arg, tok.line, tok.column)
    end

    return self:parseSuffixExpression()
end

function Parser:parseSuffixExpression()
    local expr = self:parsePrimary()
    if not expr then return nil end

    while true do
        local tok = self:current()
        if not tok then break end

        if tok.kind == Token.Kind.Dot then
            self:advance()
            local prop = self:expect(Token.Kind.Identifier)
            expr = Nodes.MemberExpression(expr, Nodes.Identifier(prop and prop.value or "", prop and prop.line, prop and prop.column), false, tok.line, tok.column)
        elseif tok.kind == Token.Kind.LBracket then
            self:advance()
            local index = self:parseExpression()
            self:expect(Token.Kind.RBracket)
            expr = Nodes.IndexExpression(expr, index, tok.line, tok.column)
        elseif tok.kind == Token.Kind.Colon then
            self:advance()
            local method = self:expect(Token.Kind.Identifier)
            local args
            if self:match(Token.Kind.LParen) then
                args = self:parseArgumentList()
                self:expect(Token.Kind.RParen)
            elseif self:check(Token.Kind.String) or self:check(Token.Kind.LongString) or self:check(Token.Kind.LBrace) then
                args = { self:parsePrimary() }
            else
                args = {}
            end
            local callee = Nodes.MemberExpression(expr, Nodes.Identifier(method and method.value or "", method and method.line, method and method.column), false, tok.line, tok.column)
            expr = Nodes.CallExpression(callee, args, true, tok.line, tok.column)
        elseif tok.kind == Token.Kind.LParen then
            self:advance()
            local args = self:parseArgumentList()
            self:expect(Token.Kind.RParen)
            expr = Nodes.CallExpression(expr, args, false, tok.line, tok.column)
        elseif tok.kind == Token.Kind.String or tok.kind == Token.Kind.LongString or tok.kind == Token.Kind.LBrace then
            -- sugar call: f"str" or f{table}
            local arg = self:parsePrimary()
            expr = Nodes.CallExpression(expr, { arg }, false, tok.line, tok.column)
        else
            break
        end
    end

    return expr
end

function Parser:parseArgumentList()
    if self:check(Token.Kind.RParen) then
        return {}
    end
    return self:parseExpressionList()
end

function Parser:parsePrimary()
    local tok = self:current()
    if not tok then return nil end

    if tok.kind == Token.Kind.Identifier then
        self:advance()
        return Nodes.Identifier(tok.value, tok.line, tok.column)
    elseif tok.kind == Token.Kind.Number then
        self:advance()
        local num = tonumber(tok.value)
        return Nodes.Literal(num, tok.value, tok.line, tok.column)
    elseif tok.kind == Token.Kind.String or tok.kind == Token.Kind.LongString then
        self:advance()
        return Nodes.Literal(tok.value, tok.value, tok.line, tok.column)
    elseif tok.kind == Token.Kind.True then
        self:advance()
        return Nodes.Literal(true, "true", tok.line, tok.column)
    elseif tok.kind == Token.Kind.False then
        self:advance()
        return Nodes.Literal(false, "false", tok.line, tok.column)
    elseif tok.kind == Token.Kind.Nil then
        self:advance()
        return Nodes.Literal(nil, "nil", tok.line, tok.column)
    elseif tok.kind == Token.Kind.DotDotDot then
        self:advance()
        return Nodes.Vararg(tok.line, tok.column)
    elseif tok.kind == Token.Kind.LParen then
        self:advance()
        local expr = self:parseExpression()
        self:expect(Token.Kind.RParen)
        return Nodes.ParenthesizedExpression(expr, tok.line, tok.column)
    elseif tok.kind == Token.Kind.LBrace then
        return self:parseTableConstructor()
    elseif tok.kind == Token.Kind.Function then
        return self:parseFunctionExpression()
    else
        self:error("Unexpected token in expression: " .. tostring(tok.kind))
        self:advance()
        return nil
    end
end

function Parser:parseTableConstructor()
    local tok = self:advance() -- {
    local fields = {}

    while not self:check(Token.Kind.RBrace) and not self:check(Token.Kind.Eof) do
        local field
        if self:check(Token.Kind.LBracket) then
            self:advance()
            local key = self:parseExpression()
            self:expect(Token.Kind.RBracket)
            self:expect(Token.Kind.Assign)
            local value = self:parseExpression()
            field = Nodes.TableField(key, value, tok.line, tok.column)
        elseif self:check(Token.Kind.Identifier) and self:peek(1) and self:peek(1).kind == Token.Kind.Assign then
            local keyTok = self:advance()
            self:advance() -- =
            local value = self:parseExpression()
            field = Nodes.TableField(Nodes.Identifier(keyTok.value, keyTok.line, keyTok.column), value, keyTok.line, keyTok.column)
        else
            local value = self:parseExpression()
            field = Nodes.TableField(nil, value, tok.line, tok.column)
        end
        table.insert(fields, field)

        if not self:match(Token.Kind.Comma) and not self:match(Token.Kind.Semicolon) then
            break
        end
    end

    self:expect(Token.Kind.RBrace)
    return Nodes.TableConstructor(fields, tok.line, tok.column)
end

function Parser:parseFunctionExpression()
    local tok = self:advance() -- function
    self:expect(Token.Kind.LParen)
    local params, isVararg = self:parseParamList()
    self:expect(Token.Kind.RParen)
    local body = self:parseBlock()
    self:expect(Token.Kind.End)
    return Nodes.FunctionExpression(params, body, isVararg, tok.line, tok.column)
end

function Parser:parse()
    local ast = self:parseChunk()
    return ast, self.errors
end

return Parser
