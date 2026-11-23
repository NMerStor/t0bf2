-- IronBrew0 v0.001 - Token definitions
-- Token kinds for the Lua/Luau lexer

local Token = {}
Token.__index = Token

Token.Kind = {
    -- Literals
    Identifier = "Identifier",
    Number     = "Number",
    String     = "String",
    LongString = "LongString",

    -- Keywords
    And      = "and",
    Break    = "break",
    Do       = "do",
    Else     = "else",
    Elseif   = "elseif",
    End      = "end",
    False    = "false",
    For      = "for",
    Function = "function",
    Goto     = "goto",      -- Lua 5.2+ / Luau
    If       = "if",
    In       = "in",
    Local    = "local",
    Nil      = "nil",
    Not      = "not",
    Or       = "or",
    Repeat   = "repeat",
    Return   = "return",
    Then     = "then",
    True     = "true",
    Until    = "until",
    While    = "while",
    Continue = "continue",  -- Luau

    -- Operators & punctuation
    Plus       = "+",
    Minus      = "-",
    Star       = "*",
    Slash      = "/",
    Percent    = "%",
    Caret      = "^",
    Hash       = "#",
    Eq         = "==",
    Neq        = "~=",
    Le         = "<=",
    Ge         = ">=",
    Lt         = "<",
    Gt         = ">",
    Assign     = "=",
    LParen     = "(",
    RParen     = ")",
    LBrace     = "{",
    RBrace     = "}",
    LBracket   = "[",
    RBracket   = "]",
    Semicolon  = ";",
    Colon      = ":",
    DoubleColon = "::",
    Comma      = ",",
    Dot        = ".",
    DotDot     = "..",
    DotDotDot  = "...",
    Pipe       = "|",       -- Luau type annotations (basic support)
    Amp        = "&",
    Question   = "?",

    -- Special
    Comment    = "Comment",
    Eof        = "Eof",
    Error      = "Error",
}

-- Reverse lookup for keywords
Token.Keywords = {
    ["and"]      = Token.Kind.And,
    ["break"]    = Token.Kind.Break,
    ["do"]       = Token.Kind.Do,
    ["else"]     = Token.Kind.Else,
    ["elseif"]   = Token.Kind.Elseif,
    ["end"]      = Token.Kind.End,
    ["false"]    = Token.Kind.False,
    ["for"]      = Token.Kind.For,
    ["function"] = Token.Kind.Function,
    ["goto"]     = Token.Kind.Goto,
    ["if"]       = Token.Kind.If,
    ["in"]       = Token.Kind.In,
    ["local"]    = Token.Kind.Local,
    ["nil"]      = Token.Kind.Nil,
    ["not"]      = Token.Kind.Not,
    ["or"]       = Token.Kind.Or,
    ["repeat"]   = Token.Kind.Repeat,
    ["return"]   = Token.Kind.Return,
    ["then"]     = Token.Kind.Then,
    ["true"]     = Token.Kind.True,
    ["until"]    = Token.Kind.Until,
    ["while"]    = Token.Kind.While,
    ["continue"] = Token.Kind.Continue,
}

function Token.new(kind, value, line, column, startPos, endPos)
    return setmetatable({
        kind     = kind,
        value    = value,
        line     = line or 1,
        column   = column or 1,
        startPos = startPos or 0,
        endPos   = endPos or 0,
    }, Token)
end

function Token:__tostring()
    if self.value and self.value ~= self.kind then
        return string.format("Token(%s, %q, %d:%d)", self.kind, tostring(self.value), self.line, self.column)
    end
    return string.format("Token(%s, %d:%d)", self.kind, self.line, self.column)
end

return Token
