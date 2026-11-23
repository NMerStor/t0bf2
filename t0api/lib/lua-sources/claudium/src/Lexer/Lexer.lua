-- IronBrew0 v0.001 - Lexer
-- Produces a stream of tokens from Lua/Luau source

local Token = require("src.Lexer.Token")

local Lexer = {}
Lexer.__index = Lexer

function Lexer.new(source, options)
    options = options or {}
    local self = setmetatable({
        source      = source or "",
        pos         = 1,
        line        = 1,
        column      = 1,
        tokens      = {},
        errors      = {},
        preserveComments = options.preserveComments or false,
        target      = options.target or "lua51", -- lua51, lua53, luajit, luau, roblox
    }, Lexer)
    return self
end

function Lexer:peek(offset)
    offset = offset or 0
    local i = self.pos + offset
    if i > #self.source then
        return nil
    end
    return self.source:sub(i, i)
end

function Lexer:advance()
    local ch = self:peek()
    if not ch then return nil end
    self.pos = self.pos + 1
    if ch == "\n" then
        self.line = self.line + 1
        self.column = 1
    else
        self.column = self.column + 1
    end
    return ch
end

function Lexer:match(expected)
    if self:peek() == expected then
        self:advance()
        return true
    end
    return false
end

function Lexer:isAlpha(ch)
    return ch and ((ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or ch == "_")
end

function Lexer:isDigit(ch)
    return ch and ch >= "0" and ch <= "9"
end

function Lexer:isAlnum(ch)
    return self:isAlpha(ch) or self:isDigit(ch)
end

function Lexer:isSpace(ch)
    return ch == " " or ch == "\t" or ch == "\r" or ch == "\n" or ch == "\f" or ch == "\v"
end

function Lexer:skipWhitespace()
    while self:isSpace(self:peek()) do
        self:advance()
    end
end

function Lexer:readNumber()
    local startPos = self.pos
    local startCol = self.column
    local startLine = self.line
    local value = ""

    -- Hex
    if self:peek() == "0" and (self:peek(1) == "x" or self:peek(1) == "X") then
        value = value .. self:advance() .. self:advance()
        while self:isDigit(self:peek()) or (self:peek() and self:peek():match("[a-fA-F]")) do
            value = value .. self:advance()
        end
        -- Hex float (Lua 5.2+/Luau)
        if self:peek() == "." then
            value = value .. self:advance()
            while self:isDigit(self:peek()) or (self:peek() and self:peek():match("[a-fA-F]")) do
                value = value .. self:advance()
            end
        end
        if self:peek() == "p" or self:peek() == "P" then
            value = value .. self:advance()
            if self:peek() == "+" or self:peek() == "-" then
                value = value .. self:advance()
            end
            while self:isDigit(self:peek()) do
                value = value .. self:advance()
            end
        end
    else
        -- Decimal
        while self:isDigit(self:peek()) do
            value = value .. self:advance()
        end
        if self:peek() == "." and self:isDigit(self:peek(1)) then
            value = value .. self:advance()
            while self:isDigit(self:peek()) do
                value = value .. self:advance()
            end
        elseif self:peek() == "." and not self:isDigit(self:peek(1)) and not self:isAlpha(self:peek(1)) then
            -- trailing dot is allowed in some contexts but we treat as number if preceded by digits
            value = value .. self:advance()
        end
        if self:peek() == "e" or self:peek() == "E" then
            value = value .. self:advance()
            if self:peek() == "+" or self:peek() == "-" then
                value = value .. self:advance()
            end
            while self:isDigit(self:peek()) do
                value = value .. self:advance()
            end
        end
    end

    return Token.new(Token.Kind.Number, value, startLine, startCol, startPos, self.pos - 1)
end

function Lexer:readString(quote)
    local startPos = self.pos - 1 -- include the opening quote position conceptually
    local startCol = self.column - 1
    local startLine = self.line
    local value = ""

    while true do
        local ch = self:peek()
        if not ch then
            table.insert(self.errors, {
                message = "Unterminated string",
                line = startLine,
                column = startCol,
            })
            break
        end
        if ch == quote then
            self:advance()
            break
        end
        if ch == "\\" then
            self:advance()
            local esc = self:peek()
            if not esc then
                table.insert(self.errors, { message = "Unterminated escape", line = self.line, column = self.column })
                break
            end
            -- Keep the escape sequence as-is for fidelity
            value = value .. "\\" .. self:advance()
        else
            if ch == "\n" then
                -- short strings cannot contain unescaped newlines in standard Lua
                table.insert(self.errors, {
                    message = "Unterminated string (newline)",
                    line = startLine,
                    column = startCol,
                })
                break
            end
            value = value .. self:advance()
        end
    end

    return Token.new(Token.Kind.String, value, startLine, startCol, startPos, self.pos - 1)
end

function Lexer:readLongString()
    -- After seeing [, count the number of =
    local startPos = self.pos - 1
    local startCol = self.column - 1
    local startLine = self.line

    local level = 0
    while self:peek() == "=" do
        level = level + 1
        self:advance()
    end
    if self:peek() ~= "[" then
        -- Not a long string, treat as single [
        return nil
    end
    self:advance() -- consume [

    local value = ""
    while true do
        local ch = self:peek()
        if not ch then
            table.insert(self.errors, {
                message = "Unterminated long string",
                line = startLine,
                column = startCol,
            })
            break
        end
        if ch == "]" then
            local savePos = self.pos
            local saveLine = self.line
            local saveCol = self.column
            self:advance()
            local closeLevel = 0
            while self:peek() == "=" do
                closeLevel = closeLevel + 1
                self:advance()
            end
            if closeLevel == level and self:peek() == "]" then
                self:advance()
                break
            else
                -- restore and treat as content
                self.pos = savePos
                self.line = saveLine
                self.column = saveCol
                value = value .. self:advance()
            end
        else
            value = value .. self:advance()
        end
    end

    return Token.new(Token.Kind.LongString, value, startLine, startCol, startPos, self.pos - 1)
end

function Lexer:readIdentifierOrKeyword()
    local startPos = self.pos
    local startCol = self.column
    local startLine = self.line
    local value = ""

    while self:isAlnum(self:peek()) do
        value = value .. self:advance()
    end

    local kind = Token.Keywords[value] or Token.Kind.Identifier
    return Token.new(kind, value, startLine, startCol, startPos, self.pos - 1)
end

function Lexer:readComment()
    local startPos = self.pos - 1
    local startCol = self.column - 1
    local startLine = self.line
    local value = ""

    if self:peek() == "[" then
        -- long comment
        local level = 0
        local i = 1
        while self:peek(i) == "=" do
            level = level + 1
            i = i + 1
        end
        if self:peek(i) == "[" then
            -- consume [===
            self:advance() -- [
            for _ = 1, level do self:advance() end
            self:advance() -- [
            while true do
                local ch = self:peek()
                if not ch then break end
                if ch == "]" then
                    local save = self.pos
                    self:advance()
                    local closeLevel = 0
                    while self:peek() == "=" do
                        closeLevel = closeLevel + 1
                        self:advance()
                    end
                    if closeLevel == level and self:peek() == "]" then
                        self:advance()
                        break
                    else
                        self.pos = save
                        value = value .. self:advance()
                    end
                else
                    value = value .. self:advance()
                end
            end
            return Token.new(Token.Kind.Comment, value, startLine, startCol, startPos, self.pos - 1)
        end
    end

    -- short comment
    while self:peek() and self:peek() ~= "\n" do
        value = value .. self:advance()
    end
    return Token.new(Token.Kind.Comment, value, startLine, startCol, startPos, self.pos - 1)
end

function Lexer:nextToken()
    self:skipWhitespace()

    local ch = self:peek()
    if not ch then
        return Token.new(Token.Kind.Eof, nil, self.line, self.column, self.pos, self.pos)
    end

    local startCol = self.column
    local startLine = self.line
    local startPos = self.pos

    -- Comments
    if ch == "-" and self:peek(1) == "-" then
        self:advance()
        self:advance()
        local tok = self:readComment()
        if self.preserveComments then
            return tok
        end
        return self:nextToken() -- skip comments by default
    end

    -- Numbers
    if self:isDigit(ch) or (ch == "." and self:isDigit(self:peek(1))) then
        return self:readNumber()
    end

    -- Strings
    if ch == "'" or ch == '"' then
        self:advance()
        return self:readString(ch)
    end

    -- Long strings / long brackets
    if ch == "[" then
        local next = self:peek(1)
        if next == "[" or next == "=" then
            self:advance()
            local ls = self:readLongString()
            if ls then return ls end
            -- fallthrough to single [
        end
    end

    -- Identifiers / keywords
    if self:isAlpha(ch) then
        return self:readIdentifierOrKeyword()
    end

    -- Multi-char operators
    if ch == "=" then
        self:advance()
        if self:match("=") then
            return Token.new(Token.Kind.Eq, "==", startLine, startCol, startPos, self.pos - 1)
        end
        return Token.new(Token.Kind.Assign, "=", startLine, startCol, startPos, self.pos - 1)
    end

    if ch == "~" then
        self:advance()
        if self:match("=") then
            return Token.new(Token.Kind.Neq, "~=", startLine, startCol, startPos, self.pos - 1)
        end
        -- Lua 5.3 bitwise not
        return Token.new(Token.Kind.Error, "~", startLine, startCol, startPos, self.pos - 1)
    end

    if ch == "<" then
        self:advance()
        if self:match("=") then
            return Token.new(Token.Kind.Le, "<=", startLine, startCol, startPos, self.pos - 1)
        end
        if self:match("<") then
            -- << bitwise (Lua 5.3)
            return Token.new(Token.Kind.Error, "<<", startLine, startCol, startPos, self.pos - 1)
        end
        return Token.new(Token.Kind.Lt, "<", startLine, startCol, startPos, self.pos - 1)
    end

    if ch == ">" then
        self:advance()
        if self:match("=") then
            return Token.new(Token.Kind.Ge, ">=", startLine, startCol, startPos, self.pos - 1)
        end
        if self:match(">") then
            return Token.new(Token.Kind.Error, ">>", startLine, startCol, startPos, self.pos - 1)
        end
        return Token.new(Token.Kind.Gt, ">", startLine, startCol, startPos, self.pos - 1)
    end

    if ch == "." then
        self:advance()
        if self:match(".") then
            if self:match(".") then
                return Token.new(Token.Kind.DotDotDot, "...", startLine, startCol, startPos, self.pos - 1)
            end
            return Token.new(Token.Kind.DotDot, "..", startLine, startCol, startPos, self.pos - 1)
        end
        return Token.new(Token.Kind.Dot, ".", startLine, startCol, startPos, self.pos - 1)
    end

    if ch == ":" then
        self:advance()
        if self:match(":") then
            return Token.new(Token.Kind.DoubleColon, "::", startLine, startCol, startPos, self.pos - 1)
        end
        return Token.new(Token.Kind.Colon, ":", startLine, startCol, startPos, self.pos - 1)
    end

    -- Single character tokens
    local singles = {
        ["+"] = Token.Kind.Plus,
        ["-"] = Token.Kind.Minus,
        ["*"] = Token.Kind.Star,
        ["/"] = Token.Kind.Slash,
        ["%"] = Token.Kind.Percent,
        ["^"] = Token.Kind.Caret,
        ["#"] = Token.Kind.Hash,
        ["("] = Token.Kind.LParen,
        [")"] = Token.Kind.RParen,
        ["{"] = Token.Kind.LBrace,
        ["}"] = Token.Kind.RBrace,
        ["["] = Token.Kind.LBracket,
        ["]"] = Token.Kind.RBracket,
        [";"] = Token.Kind.Semicolon,
        [","] = Token.Kind.Comma,
        ["|"] = Token.Kind.Pipe,
        ["&"] = Token.Kind.Amp,
        ["?"] = Token.Kind.Question,
    }

    if singles[ch] then
        self:advance()
        return Token.new(singles[ch], ch, startLine, startCol, startPos, self.pos - 1)
    end

    -- Unknown character
    self:advance()
    table.insert(self.errors, {
        message = "Unexpected character: " .. ch,
        line = startLine,
        column = startCol,
    })
    return Token.new(Token.Kind.Error, ch, startLine, startCol, startPos, self.pos - 1)
end

function Lexer:tokenize()
    self.tokens = {}
    while true do
        local tok = self:nextToken()
        table.insert(self.tokens, tok)
        if tok.kind == Token.Kind.Eof then
            break
        end
    end
    return self.tokens
end

return Lexer
