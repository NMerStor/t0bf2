--
-- parser.lua
-- Overview:
-- This Script provides a class for parsing of lua code.
-- This Parser is Capable of parsing LuaU and Lua5.1
-- 
-- Note that when parsing LuaU "continue" is treated as a Keyword, so no variable may be named "continue" even though this would be valid in LuaU
--
-- Settings Object:
-- luaVersion : The LuaVersion of the Script - Currently Supported : Lua51 and LuaU
-- 

local Tokenizer = require("catph.tokenizer");
local Enums = require("catph.enums");
local util = require("catph.util");
local Ast = require("catph.ast");
local Scope = require("catph.scope");
local logger = require("logger");

local AstKind = Ast.AstKind;

local LuaVersion = Enums.LuaVersion;
local lookupify = util.lookupify;
local unlookupify = util.unlookupify;
local escape = util.escape;
local chararray = util.chararray;
local keys = util.keys;

local TokenKind = Tokenizer.TokenKind;

local Parser = {};

-- =========================================================================
local ASSIGNMENT_NO_WARN_LOOKUP = lookupify{
	AstKind.NilExpression,
	AstKind.FunctionCallExpression,
	AstKind.PassSelfFunctionCallExpression,
	AstKind.VarargExpression
};

local function generateError(self, message)
	local token;
	if(self.index > self.length) then
		token = self.tokens[self.length];
	elseif(self.index < 1) then
		return "Parsing Error at Position 0:0, " .. message;
	else
		token = self.tokens[self.index];
	end
	
	return "Parsing Error at Position " .. tostring(token.line) .. ":" .. tostring(token.linePos) .. ", " .. message;
end

local function generateWarning(token, message)
	return "Warning at Position " .. tostring(token.line) .. ":" .. tostring(token.linePos) .. ", " .. message;
end

function Parser:new(settings)
	local luaVersion = (settings and (settings.luaVersion or settings.LuaVersion)) or LuaVersion.LuaU;
	local parser = {
		luaVersion = luaVersion,
		tokenizer = Tokenizer:new({
			luaVersion = luaVersion
		}),
		tokens = {};
		length = 0;
		index = 0;
	};
	
	setmetatable(parser, self);
	self.__index = self;
	
	return parser;
end

-- Function to peek the n'th token
local function peek(self, n)
	n = n or 0;
	local i = self.index + n + 1;
	if i > self.length then
		return Tokenizer.EOF_TOKEN;
	end
	return self.tokens[i];
end

-- Function to get the next Token
local function get(self)
	local i = self.index + 1;
	if i > self.length then
		error(generateError(self, "Unexpected end of Input"));
	end
	self.index = self.index + 1;
	local tk = self.tokens[i];
	
	return tk;
end

local function is(self, kind, sourceOrN, n)
	local token = peek(self, n);
	
	local source = nil;
	if(type(sourceOrN) == "string") then
		source = sourceOrN;
	else
		n = sourceOrN;
	end
	n = n or 0;
	
	if(token.kind == kind) then
		if(source == nil or token.source == source) then
			return true;
		end
	end
	
	return false;
end

local function consume(self, kind, source)
	if(is(self, kind, source)) then
		self.index = self.index + 1;
		return true;
	end
	return false;
end

local function expect(self, kind, source)
	if(is(self, kind, source, 0)) then
		return get(self);
	end
	
	local token = peek(self);
	if self.disableLog then error() end
	if(source) then
		logger:error(generateError(self, string.format("unexpected token <%s> \"%s\", expected <%s> \"%s\"", token.kind, token.source, kind, source)));
	else
		logger:error(generateError(self, string.format("unexpected token <%s> \"%s\", expected <%s>", token.kind, token.source, kind)));
	end
end

-- =========================================================================
-- Luau type-annotation skipper
-- =========================================================================
-- Called whenever the parser is in LuaU mode and has just consumed whatever
-- triggered the type position (a ":", "::", "<" for generics, "->", etc.).
-- It reads and discards the full type expression including nested generics,
-- function types, union/intersection chains, optional "?", typeof(), etc.
-- Returns nothing – only advances self.index past the type.
--
-- Grammar fragment we implement (simplified EBNF):
--
--   type      = simpleType { ("|" | "&") simpleType }
--   simpleType = baseType { "?" }
--   baseType  = "nil" | "any" | "never" | "unknown"
--             | NAME [ "<" typeList ">" ]     -- named type, possibly generic
--             | "{" tableType "}"             -- table/array type
--             | "(" tupleType ")"             -- tuple or function type
--             | "typeof" "(" expr ")"         -- typeof
--             | STRING | NUMBER | "true" | "false"   -- singleton types
--
-- We don't need to build an AST for any of this – just consume tokens.
-- =========================================================================

-- forward declaration – body assigned below after helpers are defined
local skipType
local skipTypeList
local skipBaseType
local skipTableTypeBody
local skipParenTypeBody
local skipReturnTypeSuffix
local skipTypeofBody
local skipGenericParams

skipReturnTypeSuffix = function(self)
    if is(self, TokenKind.Symbol, "->") then
        self.index = self.index + 1  -- consume "->"
        skipType(self)
    end
end

-- Skip everything inside a table-type literal { ... }
-- The opening "{" has already been consumed.
skipTableTypeBody = function(self)
    local depth = 1
    while self.index < self.length do
        if is(self, TokenKind.Symbol, "{") then
            depth = depth + 1
            self.index = self.index + 1
        elseif is(self, TokenKind.Symbol, "}") then
            depth = depth - 1
            self.index = self.index + 1
            if depth == 0 then return end
        elseif is(self, TokenKind.Symbol, "[") then
            self.index = self.index + 1
            local d2 = 1
            while self.index < self.length and d2 > 0 do
                if is(self, TokenKind.Symbol, "[") then d2 = d2 + 1
                elseif is(self, TokenKind.Symbol, "]") then d2 = d2 - 1 end
                self.index = self.index + 1
            end
        elseif is(self, TokenKind.Symbol, "(") then
            self.index = self.index + 1
            local d2 = 1
            while self.index < self.length and d2 > 0 do
                if is(self, TokenKind.Symbol, "(") then d2 = d2 + 1
                elseif is(self, TokenKind.Symbol, ")") then d2 = d2 - 1 end
                self.index = self.index + 1
            end
        else
            self.index = self.index + 1
        end
    end
end

-- Skip a parenthesised type body. Opening "(" already consumed.
skipParenTypeBody = function(self)
    local depth = 1
    while self.index < self.length do
        if is(self, TokenKind.Symbol, "(") then
            depth = depth + 1
            self.index = self.index + 1
        elseif is(self, TokenKind.Symbol, ")") then
            depth = depth - 1
            self.index = self.index + 1
            if depth == 0 then break end
        elseif is(self, TokenKind.Symbol, "{") then
            self.index = self.index + 1
            skipTableTypeBody(self)
        else
            self.index = self.index + 1
        end
    end
    skipReturnTypeSuffix(self)
end

-- Skip typeof(expr). "typeof" ident already consumed.
skipTypeofBody = function(self)
    if not is(self, TokenKind.Symbol, "(") then return end
    self.index = self.index + 1  -- consume "("
    local depth = 1
    while self.index < self.length do
        if is(self, TokenKind.Symbol, "(") then
            depth = depth + 1
        elseif is(self, TokenKind.Symbol, ")") then
            depth = depth - 1
            if depth == 0 then
                self.index = self.index + 1
                return
            end
        end
        self.index = self.index + 1
    end
end

-- Skip a comma-separated list of types (inside <...> or (...))
skipTypeList = function(self)
    skipType(self)
    while is(self, TokenKind.Symbol, ",") do
        self.index = self.index + 1
        if is(self, TokenKind.Symbol, ">") or
           is(self, TokenKind.Symbol, ")") or
           is(self, TokenKind.Symbol, "]") then
            break
        end
        skipType(self)
    end
end

-- Skip a single base type token/construct
skipBaseType = function(self)
    local tk = peek(self)
    if tk.kind == TokenKind.Eof then return end

    -- singleton: string / number literal
    if tk.kind == TokenKind.String or tk.kind == TokenKind.Number then
        self.index = self.index + 1
        return
    end

    if tk.kind == TokenKind.Keyword then
        local kw = tk.source
        if kw == "nil" or kw == "true" or kw == "false" then
            self.index = self.index + 1
        end
        return  -- any other keyword stops the type
    end

    if tk.kind == TokenKind.Ident then
        local name = tk.source
        self.index = self.index + 1
        -- qualified name: Foo.Bar
        while is(self, TokenKind.Symbol, ".") do
            local nxt = peek(self, 1)
            if nxt.kind == TokenKind.Ident then
                self.index = self.index + 2
            else
                break
            end
        end
        -- generic params: Foo<A, B>
        if is(self, TokenKind.Symbol, "<") then
            self.index = self.index + 1
            skipTypeList(self)
            if is(self, TokenKind.Symbol, ">") then
                self.index = self.index + 1
            end
        end
        -- typeof() body
        if name == "typeof" then
            skipTypeofBody(self)
        end
        return
    end

    if tk.kind == TokenKind.Symbol then
        local sym = tk.source
        -- Generic function type:  <T>(T) -> T
        if sym == "<" then
            self.index = self.index + 1  -- consume "<"
            -- skip type param names until ">"
            while not is(self, TokenKind.Symbol, ">") and self.index < self.length do
                self.index = self.index + 1
            end
            if is(self, TokenKind.Symbol, ">") then
                self.index = self.index + 1  -- consume ">"
            end
            -- now expect a parenthesised type
            if is(self, TokenKind.Symbol, "(") then
                self.index = self.index + 1
                skipParenTypeBody(self)
            end
            return
        end
        if sym == "{" then
            self.index = self.index + 1
            skipTableTypeBody(self)
            return
        end
        if sym == "(" then
            self.index = self.index + 1
            skipParenTypeBody(self)
            return
        end
        if sym == "..." then
            self.index = self.index + 1
            skipBaseType(self)
            return
        end
    end
    -- anything else: stop without consuming
end

-- Full type expression: base with union/intersection/optional chain
skipType = function(self)
    skipBaseType(self)
    while true do
        if is(self, TokenKind.Symbol, "?") then
            self.index = self.index + 1
        elseif is(self, TokenKind.Symbol, "|") or is(self, TokenKind.Symbol, "&") then
            self.index = self.index + 1
            skipBaseType(self)
        elseif is(self, TokenKind.Symbol, "->") then
            self.index = self.index + 1
            skipType(self)
            break
        else
            break
        end
    end
end

-- Skip generic type parameter list <T, U> before a function's "(".
-- The "<" has NOT been consumed yet.
skipGenericParams = function(self)
    if not is(self, TokenKind.Symbol, "<") then return end
    self.index = self.index + 1  -- consume "<"
    while not is(self, TokenKind.Symbol, ">") and self.index < self.length do
        if is(self, TokenKind.Ident) then
            self.index = self.index + 1
            if is(self, TokenKind.Symbol, "...") then
                self.index = self.index + 1
            end
            if is(self, TokenKind.Symbol, "=") then
                self.index = self.index + 1
                skipType(self)
            end
            if is(self, TokenKind.Symbol, ",") then
                self.index = self.index + 1
            end
        else
            break
        end
    end
    if is(self, TokenKind.Symbol, ">") then
        self.index = self.index + 1
    end
end

-- Parse the given code to an Abstract Syntax Tree
function Parser:parse(code)
	self.tokenizer:append(code);
	self.tokens = self.tokenizer:scanAll();
	self.length = #self.tokens;
	
	-- Create Global Variable Scope
	local globalScope = Scope:newGlobal();
	
	local ast = Ast.TopNode(self:block(globalScope, false), globalScope);
	-- File Must be Over when Top Node is Fully Parsed
	expect(self, TokenKind.Eof);

	logger:debug("Cleaning up Parser for next Use ...")
	-- Clean Up
	self.tokenizer:reset();
	self.tokens = {};
	self.index = 0;
	self.length = 0;
	
	logger:debug("Cleanup Done")
	
	return ast;
end

-- Parse a Code Block
function Parser:block(parentScope, currentLoop, scope)
	scope = scope or Scope:new(parentScope);
	local statements = {};
	
	repeat
		local statement, isTerminatingStatement = self:statement(scope, currentLoop);
		table.insert(statements, statement);
	until isTerminatingStatement or not statement
	
	-- Consume Eventual Semicolon after terminating return, break or continue
	consume(self, TokenKind.Symbol, ";");
	
	return Ast.Block(statements, scope);
end

function Parser:statement(scope, currentLoop)
	-- Skip all semicolons before next real statement
	-- NOP statements are therefore ignored
	while(consume(self, TokenKind.Symbol, ";")) do
		
	end
	
	-- ---------------------------------------------------------------
	-- LuaU: "type Foo = ..."  and  "export type Foo = ..."
	-- Both are treated as NopStatements – the type info is discarded.
	-- "type" and "export" are NOT reserved keywords in LuaU so we
	-- check them as identifiers.
	-- ---------------------------------------------------------------
	if self.luaVersion == LuaVersion.LuaU then
		-- "type function NAME(...) ... end" — user-defined type function (skip entirely)
		if is(self, TokenKind.Ident, "type", 0) and is(self, TokenKind.Keyword, "function", 1) then
			self.index = self.index + 2  -- consume "type" and "function"
			if is(self, TokenKind.Ident) then
				self.index = self.index + 1  -- consume function name
			end
			skipGenericParams(self)
			-- Skip balanced ( ... )
			if consume(self, TokenKind.Symbol, "(") then
				local depth = 1
				while self.index < self.length and depth > 0 do
					if is(self, TokenKind.Symbol, "(") then depth = depth + 1
					elseif is(self, TokenKind.Symbol, ")") then depth = depth - 1 end
					if depth > 0 then self.index = self.index + 1 end
				end
				if is(self, TokenKind.Symbol, ")") then
					self.index = self.index + 1
				end
			end
			-- Skip body until matching "end"
			local endDepth = 1
			while self.index < self.length and endDepth > 0 do
				if is(self, TokenKind.Keyword, "function") or is(self, TokenKind.Keyword, "if")
					or is(self, TokenKind.Keyword, "do") or is(self, TokenKind.Keyword, "for")
					or is(self, TokenKind.Keyword, "while") then
					endDepth = endDepth + 1
				elseif is(self, TokenKind.Keyword, "end") then
					endDepth = endDepth - 1
				end
				self.index = self.index + 1
			end
			return Ast.NopStatement()
		end

		-- "type NAME ..."  – only if the token after "type" is an identifier
		-- (guards against a local named "type" being assigned normally).
		if is(self, TokenKind.Ident, "type", 0) and is(self, TokenKind.Ident, nil, 1) then
			self.index = self.index + 1  -- consume "type"
			-- skip optional generic params: type Pair<A, B> = ...
			skipGenericParams(self)
			-- now expect:  NAME < optional generics > = typeExpr
			if is(self, TokenKind.Ident) then
				self.index = self.index + 1  -- consume type name
				skipGenericParams(self)      -- e.g. type Foo<T> = ...
				if consume(self, TokenKind.Symbol, "=") then
					skipType(self)           -- discard the type expression
				end
			end
			return Ast.NopStatement()
		end

		-- "export type NAME ..."
		if is(self, TokenKind.Ident, "export", 0) and is(self, TokenKind.Ident, "type", 1) then
			self.index = self.index + 2  -- consume "export" and "type"
			if is(self, TokenKind.Ident) then
				self.index = self.index + 1  -- consume type name
				skipGenericParams(self)
				if consume(self, TokenKind.Symbol, "=") then
					skipType(self)
				end
			end
			return Ast.NopStatement()
		end
	end

	-- Break Statement - only valid inside of Loops
	if(consume(self, TokenKind.Keyword, "break")) then
		if(not currentLoop) then
			if self.disableLog then error() end;
			logger:error(generateError(self, "the break Statement is only valid inside of loops"));
		end
		-- Return true as Second value because break must be the last Statement in a block
		return Ast.BreakStatement(currentLoop, scope), true;
	end
	
	-- Continue Statement - only valid inside of Loops - only valid in LuaU
	if(self.luaVersion == LuaVersion.LuaU and consume(self, TokenKind.Keyword, "continue")) then
		if(not currentLoop) then
			if self.disableLog then error() end;
			logger:error(generateError(self, "the continue Statement is only valid inside of loops"));
		end
		-- Return true as Second value because continue must be the last Statement in a block
		return Ast.ContinueStatement(currentLoop, scope), true;
	end
	
	-- do ... end Statement
	if(consume(self, TokenKind.Keyword, "do")) then
		local body = self:block(scope, currentLoop);
		expect(self, TokenKind.Keyword, "end");
		return Ast.DoStatement(body);
	end
	
	-- While Statement
	if(consume(self, TokenKind.Keyword, "while")) then
		local condition = self:expression(scope);
		expect(self, TokenKind.Keyword, "do");
		local stat = Ast.WhileStatement(nil, condition, scope);
		stat.body = self:block(scope, stat);
		expect(self, TokenKind.Keyword, "end");
		return stat;
	end
	
	-- Repeat Statement
	if(consume(self, TokenKind.Keyword, "repeat")) then
		local repeatScope = Scope:new(scope);
		local stat = Ast.RepeatStatement(nil, nil, scope);
		stat.body = self:block(nil, stat, repeatScope);
		expect(self, TokenKind.Keyword, "until");
		stat.condition = self:expression(repeatScope);
		return stat;
	end
	
	-- Return Statement
	if(consume(self, TokenKind.Keyword, "return")) then
		local args = {};
		if(not is(self, TokenKind.Keyword, "end") and not is(self, TokenKind.Keyword, "elseif") and not is(self, TokenKind.Keyword, "else") and not is(self, TokenKind.Symbol, ";") and not is(self, TokenKind.Eof)) then
			args = self:exprList(scope);
		end
		-- Return true as Second value because return must be the last Statement in a block
		return Ast.ReturnStatement(args), true;
	end
	
	-- If Statement
	if(consume(self, TokenKind.Keyword, "if")) then
		local condition = self:expression(scope);
		expect(self, TokenKind.Keyword, "then");
		local body = self:block(scope, currentLoop);
		
		local elseifs = {};
		-- Elseifs
		while(consume(self, TokenKind.Keyword, "elseif")) do
			local condition = self:expression(scope);
			expect(self, TokenKind.Keyword, "then");
			local body = self:block(scope, currentLoop);
			
			table.insert(elseifs, {
				condition = condition,
				body = body,
			});
		end
		
		local elsebody = nil;
		-- Else
		if(consume(self, TokenKind.Keyword, "else")) then
			elsebody = self:block(scope, currentLoop);
		end
		
		expect(self, TokenKind.Keyword, "end");
		
		return Ast.IfStatement(condition, body, elseifs, elsebody);
	end
	
	-- LuaU: Function attributes (@native, @deprecated, etc.)
	-- Consume and discard any @name(...) attributes before function declarations.
	if self.luaVersion == LuaVersion.LuaU then
		while is(self, TokenKind.Symbol, "@") do
			self.index = self.index + 1  -- consume "@"
			if is(self, TokenKind.Ident) then
				self.index = self.index + 1  -- consume attribute name
			end
			-- Optional parameters: @deprecated("reason")
			if is(self, TokenKind.Symbol, "(") then
				self.index = self.index + 1  -- consume "("
				local depth = 1
				while self.index < self.length and depth > 0 do
					if is(self, TokenKind.Symbol, "(") then depth = depth + 1
					elseif is(self, TokenKind.Symbol, ")") then depth = depth - 1 end
					if depth > 0 then self.index = self.index + 1 end
				end
				if is(self, TokenKind.Symbol, ")") then
					self.index = self.index + 1  -- consume ")"
				end
			end
		end
	end

	-- Function Declaration
	if(consume(self, TokenKind.Keyword, "function")) then
		-- TODO: Parse Function Declaration Name
		local obj = self:funcName(scope);
		local baseScope = obj.scope;
		local baseId = obj.id;
		local indices = obj.indices;
		
		local funcScope = Scope:new(scope);

		-- LuaU: optional generic type params  <T, U>
		if self.luaVersion == LuaVersion.LuaU then skipGenericParams(self) end
		
		expect(self, TokenKind.Symbol, "(");
		local args = self:functionArgList(funcScope);
		expect(self, TokenKind.Symbol, ")");

		-- LuaU: optional return type annotation
		if self.luaVersion == LuaVersion.LuaU and is(self, TokenKind.Symbol, ":") then
			self.index = self.index + 1
			skipType(self)
		end
		
		if(obj.passSelf) then
			local id = funcScope:addVariable("self", obj.token);
			table.insert(args, 1, Ast.VariableExpression(funcScope, id));
		end

		local body = self:block(nil, false, funcScope);
		expect(self, TokenKind.Keyword, "end");
		
		return Ast.FunctionDeclaration(baseScope, baseId, indices, args, body);
	end
	
	-- Local Function or Variable Declaration
	if(consume(self, TokenKind.Keyword, "local")) then
		-- Local Function Declaration
		if(consume(self, TokenKind.Keyword, "function")) then
			local ident = expect(self, TokenKind.Ident);
			local name = ident.value;
			
			local id = scope:addVariable(name, ident);
			local funcScope = Scope:new(scope);

			-- LuaU: optional generic type params  <T, U>
			if self.luaVersion == LuaVersion.LuaU then skipGenericParams(self) end
			
			expect(self, TokenKind.Symbol, "(");
			local args = self:functionArgList(funcScope);
			expect(self, TokenKind.Symbol, ")");

			-- LuaU: optional return type annotation
			if self.luaVersion == LuaVersion.LuaU and is(self, TokenKind.Symbol, ":") then
				self.index = self.index + 1
				skipType(self)
			end

			local body = self:block(nil, false, funcScope);
			expect(self, TokenKind.Keyword, "end");

			return Ast.LocalFunctionDeclaration(scope, id, args, body);
		end
		
		-- Local Variable Declaration
		local ids = self:nameList(scope);
		local expressions = {};
		if(consume(self, TokenKind.Symbol, "=")) then
			expressions = self:exprList(scope);
		end

		-- Variables can only be reffered to in the next statement, so the id's are enabled after the expressions have been parsed
		self:enableNameList(scope, ids);
		
		if(#expressions > #ids) then
			logger:warn(generateWarning(peek(self, -1), string.format("assigning %d values to %d variable" .. ((#ids > 1 and "s") or ""), #expressions, #ids)));
		elseif(#ids > #expressions and #expressions > 0 and not ASSIGNMENT_NO_WARN_LOOKUP[expressions[#expressions].kind]) then
			logger:warn(generateWarning(peek(self, -1), string.format("assigning %d value" .. ((#expressions > 1 and "s") or "") .. 
				" to %d variables initializes extra variables with nil, add a nil value to silence", #expressions, #ids)));
		end		
		return Ast.LocalVariableDeclaration(scope, ids, expressions);
	end
	
	-- For Statement
	if(consume(self, TokenKind.Keyword, "for")) then
		-- Normal for Statement
		if(is(self, TokenKind.Symbol, "=", 1)) then
			local forScope = Scope:new(scope);
			
			local ident = expect(self, TokenKind.Ident);
			local varId = forScope:addDisabledVariable(ident.value, ident);
			
			expect(self, TokenKind.Symbol, "=");
			local initialValue = self:expression(scope);
			
			expect(self, TokenKind.Symbol, ",");
			local finalValue = self:expression(scope);
			local incrementBy = Ast.NumberExpression(1);
			if(consume(self, TokenKind.Symbol, ",")) then
				incrementBy = self:expression(scope);
			end
			
			local stat = Ast.ForStatement(forScope, varId, initialValue, finalValue, incrementBy, nil, scope);
			forScope:enableVariable(varId);
			expect(self, TokenKind.Keyword, "do");
			stat.body = self:block(nil, stat, forScope);
			expect(self, TokenKind.Keyword, "end");
			return stat;
		end
		
		-- For ... in ... statement
		local forScope = Scope:new(scope);
		
		local ids = self:nameList(forScope);
		expect(self, TokenKind.Keyword, "in");
		local expressions = self:exprList(scope);
		-- Enable Ids after Expression Parsing so that code like this works:
		--	local z = {10,20}
		--	for y,z in ipairs(z) do
		--		print(y, z);
		-- 	end
		self:enableNameList(forScope, ids);
		expect(self, TokenKind.Keyword, "do");
		local stat = Ast.ForInStatement(forScope, ids, expressions, nil, scope);
		stat.body = self:block(nil, stat, forScope);
		expect(self, TokenKind.Keyword, "end");
		
		return stat;
	end
	
	local expr = self:primaryExpression(scope);
	-- Variable Assignment or Function Call
	if expr then
		-- Function Call Statement
		if(expr.kind == AstKind.FunctionCallExpression) then
			return Ast.FunctionCallStatement(expr.base, expr.args);
		end
		
		-- Function Call Statement passing self
		if(expr.kind == AstKind.PassSelfFunctionCallExpression) then
			return Ast.PassSelfFunctionCallStatement(expr.base, expr.passSelfFunctionName, expr.args);
		end
		
		-- Variable Assignment
		if(expr.kind == AstKind.IndexExpression or expr.kind == AstKind.VariableExpression) then
			if(expr.kind == AstKind.IndexExpression) then
				expr.kind = AstKind.AssignmentIndexing
			end
			if(expr.kind == AstKind.VariableExpression) then
				expr.kind = AstKind.AssignmentVariable
			end

			if(self.luaVersion == LuaVersion.LuaU) then
				-- LuaU Compound Assignment
				if(consume(self, TokenKind.Symbol, "+=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundAddStatement(expr, rhs);
				end

				if(consume(self, TokenKind.Symbol, "-=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundSubStatement(expr, rhs);
				end

				if(consume(self, TokenKind.Symbol, "*=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundMulStatement(expr, rhs);
				end

				if(consume(self, TokenKind.Symbol, "/=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundDivStatement(expr, rhs);
				end

				if(consume(self, TokenKind.Symbol, "%=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundModStatement(expr, rhs);
				end

				if(consume(self, TokenKind.Symbol, "^=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundPowStatement(expr, rhs);
				end

				if(consume(self, TokenKind.Symbol, "..=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundConcatStatement(expr, rhs);
				end

				if(consume(self, TokenKind.Symbol, "//=")) then
					local rhs = self:expression(scope);
					return Ast.CompoundIDivStatement(expr, rhs);
				end
			end

			local lhs = {
				expr
			}
			
			while consume(self, TokenKind.Symbol, ",") do
				expr = self:primaryExpression(scope);
				
				if(not expr) then
					if self.disableLog then error() end;
					logger:error(generateError(self, string.format("expected a valid assignment statement lhs part but got nil")));
				end
				
				if(expr.kind == AstKind.IndexExpression or expr.kind == AstKind.VariableExpression) then
					if(expr.kind == AstKind.IndexExpression) then
						expr.kind = AstKind.AssignmentIndexing
					end
					if(expr.kind == AstKind.VariableExpression) then
						expr.kind = AstKind.AssignmentVariable
					end
					table.insert(lhs, expr);
				else
					if self.disableLog then error() end;
					logger:error(generateError(self, string.format("expected a valid assignment statement lhs part but got <%s>", expr.kind)));
				end
			end
			
			expect(self, TokenKind.Symbol, "=");
			
			local rhs = self:exprList(scope);
			
			return Ast.AssignmentStatement(lhs, rhs);
		end
		
		if self.disableLog then error() end;
		logger:error(generateError(self, "expressions are not valid statements!"));
	end
	
	return nil;
end

function Parser:primaryExpression(scope)
	local i = self.index;
	local s = self;
	self.disableLog = true;
	local status, val = pcall(self.expressionFunctionCall, self, scope);
	self.disableLog = false;
	if(status) then
		return val;
	else
		self.index = i;
		return nil;
	end
end

-- List of expressions Seperated by a comma
function Parser:exprList(scope)
	local expressions = {
		self:expression(scope)
	};
	while(consume(self, TokenKind.Symbol, ",")) do
		table.insert(expressions, self:expression(scope));
	end
	return expressions;
end

-- list of local variable names
function Parser:nameList(scope)
	local ids = {};
	local isLuaU = self.luaVersion == LuaVersion.LuaU;
	
	local ident = expect(self, TokenKind.Ident);
	local id = scope:addDisabledVariable(ident.value, ident);
	-- LuaU: optional type annotation  name: Type
	if isLuaU and is(self, TokenKind.Symbol, ":") then
		self.index = self.index + 1
		skipType(self)
	end
	table.insert(ids, id);
	
	while(consume(self, TokenKind.Symbol, ",")) do
		ident = expect(self, TokenKind.Ident);
		id = scope:addDisabledVariable(ident.value, ident);
		-- LuaU: optional type annotation
		if isLuaU and is(self, TokenKind.Symbol, ":") then
			self.index = self.index + 1
			skipType(self)
		end
		table.insert(ids, id);
	end
	
	return ids;
end

function Parser:enableNameList(scope, list)
	for i, id in ipairs(list) do
		scope:enableVariable(id);
	end
end


-- function name
function Parser:funcName(scope)
	local ident = expect(self, TokenKind.Ident);
	local baseName = ident.value;
	
	local baseScope, baseId = scope:resolve(baseName);
	
	local indices = {};
	local passSelf = false;
	while(consume(self, TokenKind.Symbol, ".")) do
		table.insert(indices, expect(self, TokenKind.Ident).value);
	end
	
	if(consume(self, TokenKind.Symbol, ":")) then
		table.insert(indices, expect(self, TokenKind.Ident).value);
		passSelf = true;
	end
	
	return {
		scope = baseScope,
		id = baseId,
		indices = indices,
		passSelf = passSelf,
		token = ident,
	};
end

-- Expression
function Parser:expression(scope)
	return self:expressionOr(scope);
end

function Parser:expressionOr(scope)
	local lhs = self:expressionAnd(scope);
	
	if(consume(self, TokenKind.Keyword, "or")) then
		local rhs = self:expressionOr(scope);
		return Ast.OrExpression(lhs, rhs, true);
	end
	
	return lhs;
end

function Parser:expressionAnd(scope)
	local lhs = self:expressionComparision(scope);

	if(consume(self, TokenKind.Keyword, "and")) then
		local rhs = self:expressionAnd(scope);
		return Ast.AndExpression(lhs, rhs, true);
	end

	return lhs;
end

function Parser:expressionComparision(scope)
	local curr = self:expressionStrCat(scope);
	repeat
		local found = false;
		if(consume(self, TokenKind.Symbol, "<")) then
			local rhs = self:expressionStrCat(scope);
			curr = Ast.LessThanExpression(curr, rhs, true);
			found = true;
		end
		
		if(consume(self, TokenKind.Symbol, ">")) then
			local rhs = self:expressionStrCat(scope);
			curr = Ast.GreaterThanExpression(curr, rhs, true);
			found = true;
		end
		
		if(consume(self, TokenKind.Symbol, "<=")) then
			local rhs = self:expressionStrCat(scope);
			curr = Ast.LessThanOrEqualsExpression(curr, rhs, true);
			found = true;
		end
	
		if(consume(self, TokenKind.Symbol, ">=")) then
			local rhs = self:expressionStrCat(scope);
			curr = Ast.GreaterThanOrEqualsExpression(curr, rhs, true);
			found = true;
		end
		
		if(consume(self, TokenKind.Symbol, "~=")) then
			local rhs = self:expressionStrCat(scope);
			curr = Ast.NotEqualsExpression(curr, rhs, true);
			found = true;
		end
	
		if(consume(self, TokenKind.Symbol, "==")) then
			local rhs = self:expressionStrCat(scope);
			curr = Ast.EqualsExpression(curr, rhs, true);
			found = true;
		end
	until not found;

	return curr;
end

function Parser:expressionStrCat(scope)
	local lhs = self:expressionAddSub(scope);

	if(consume(self, TokenKind.Symbol, "..")) then
		local rhs = self:expressionStrCat(scope);
		return Ast.StrCatExpression(lhs, rhs, true);
	end

	return lhs;
end

function Parser:expressionAddSub(scope)
	local curr = self:expressionMulDivMod(scope);

	repeat
		local found = false;
		if(consume(self, TokenKind.Symbol, "+")) then
			local rhs = self:expressionMulDivMod(scope);
			curr = Ast.AddExpression(curr, rhs, true);
			found = true;
		end
		
		if(consume(self, TokenKind.Symbol, "-")) then
			local rhs = self:expressionMulDivMod(scope);
			curr = Ast.SubExpression(curr, rhs, true);
			found = true;
		end
	until not found;
	

	return curr;
end

function Parser:expressionMulDivMod(scope)
	local curr = self:expressionUnary(scope);

	repeat
		local found = false;
		if(consume(self, TokenKind.Symbol, "*")) then
			local rhs = self:expressionUnary(scope);
			curr = Ast.MulExpression(curr, rhs, true);
			found = true;
		end
	
		if(consume(self, TokenKind.Symbol, "/")) then
			local rhs = self:expressionUnary(scope);
			curr = Ast.DivExpression(curr, rhs, true);
			found = true;
		end

		if(consume(self, TokenKind.Symbol, "//")) then
			local rhs = self:expressionUnary(scope);
			curr = Ast.IDivExpression(curr, rhs, true);
			found = true;
		end

		if(consume(self, TokenKind.Symbol, "%")) then
			local rhs = self:expressionUnary(scope);
			curr = Ast.ModExpression(curr, rhs, true);
			found = true;
		end
	until not found;

	return curr;
end

function Parser:expressionUnary(scope)
	if(consume(self, TokenKind.Keyword, "not")) then
		local rhs = self:expressionUnary(scope);
		return Ast.NotExpression(rhs, true);
	end
	
	if(consume(self, TokenKind.Symbol, "#")) then
		local rhs = self:expressionUnary(scope);
		return Ast.LenExpression(rhs, true);
	end
	
	if(consume(self, TokenKind.Symbol, "-")) then
		local rhs = self:expressionUnary(scope);
		return Ast.NegateExpression(rhs, true);
	end

	return self:expressionPow(scope);
end

function Parser:expressionPow(scope)
	local lhs = self:tableOrFunctionLiteral(scope);

	if(consume(self, TokenKind.Symbol, "^")) then
		local rhs = self:expressionPow(scope);
		return Ast.PowExpression(lhs, rhs, false);
	end

	return lhs;
end

-- Table Literals and Function Literals cannot directly be called or indexed
function Parser:tableOrFunctionLiteral(scope)
	
	if(is(self, TokenKind.Symbol, "{")) then
		return self:tableConstructor(scope);
	end
	
	if(is(self, TokenKind.Keyword, "function")) then
		return self:expressionFunctionLiteral(scope);
	end
	
	return self:expressionFunctionCall(scope);
end

function Parser:expressionFunctionLiteral(parentScope)
	local scope = Scope:new(parentScope);
	local isLuaU = self.luaVersion == LuaVersion.LuaU;
	
	expect(self, TokenKind.Keyword, "function");

	-- LuaU: optional generic type params  <T, U>
	if isLuaU then skipGenericParams(self) end
	
	expect(self, TokenKind.Symbol, "(");
	local args = self:functionArgList(scope);
	expect(self, TokenKind.Symbol, ")");

	-- LuaU: optional return type annotation  ): ReturnType
	if isLuaU and is(self, TokenKind.Symbol, ":") then
		self.index = self.index + 1  -- consume ":"
		skipType(self)
	end
	
	local body = self:block(nil, false, scope);
	expect(self, TokenKind.Keyword, "end");
	
	return Ast.FunctionLiteralExpression(args, body);
end

function Parser:functionArgList(scope)
	local args = {};
	local isLuaU = self.luaVersion == LuaVersion.LuaU;

	if(consume(self, TokenKind.Symbol, "...")) then
		-- vararg with optional LuaU type annotation: ...: Type
		if isLuaU and is(self, TokenKind.Symbol, ":") then
			self.index = self.index + 1  -- consume ":"
			skipType(self)
		end
		table.insert(args, Ast.VarargExpression());
		return args;
	end
	
	if(is(self, TokenKind.Ident)) then
		local ident = get(self);
		local name = ident.value;

		-- LuaU: optional "self" param type is just discarded
		local id = scope:addVariable(name, ident);
		-- skip optional type annotation: name: Type
		if isLuaU and is(self, TokenKind.Symbol, ":") then
			self.index = self.index + 1  -- consume ":"
			skipType(self)
		end
		table.insert(args, Ast.VariableExpression(scope, id));
		
		while(consume(self, TokenKind.Symbol, ",")) do
			if(consume(self, TokenKind.Symbol, "...")) then
				-- vararg with optional type annotation
				if isLuaU and is(self, TokenKind.Symbol, ":") then
					self.index = self.index + 1
					skipType(self)
				end
				table.insert(args, Ast.VarargExpression());
				return args;
			end
			
			ident = get(self);
			name = ident.value;

			id = scope:addVariable(name, ident);
			-- skip optional type annotation
			if isLuaU and is(self, TokenKind.Symbol, ":") then
				self.index = self.index + 1
				skipType(self)
			end
			table.insert(args, Ast.VariableExpression(scope, id));
		end
	end
	
	return args;
end

function Parser:expressionFunctionCall(scope, base)
	base = base or self:expressionIndex(scope);
	
	-- Normal Function Call
	local args = {};
	if(is(self, TokenKind.String)) then
		args = {
			Ast.StringExpression(get(self).value),
		};
	elseif(is(self, TokenKind.Symbol, "{")) then
		args = {
			self:tableConstructor(scope),
		};
	elseif(consume(self, TokenKind.Symbol, "(")) then
		if(not is(self, TokenKind.Symbol, ")")) then
			args = self:exprList(scope);
		end
		expect(self, TokenKind.Symbol, ")");
	else
		return base;
	end
	
	local node = Ast.FunctionCallExpression(base, args);
	
	-- LuaU type cast after a function call:  f(...) :: Type
	if self.luaVersion == LuaVersion.LuaU then
		while is(self, TokenKind.Symbol, "::") do
			self.index = self.index + 1
			skipType(self)
		end
	end

	-- the result of a function call can be indexed
	if(is(self, TokenKind.Symbol, ".") or is(self, TokenKind.Symbol, "[") or is(self, TokenKind.Symbol, ":")) then
		return self:expressionIndex(scope, node);
	end

	-- The result of a function call can be a function that is again called
	if(is(self, TokenKind.Symbol, "(") or is(self, TokenKind.Symbol, "{") or is(self, TokenKind.String)) then
		return self:expressionFunctionCall(scope, node);
	end
	
	return node;
end

function Parser:expressionIndex(scope, base)
	base = base or self:expressionLiteral(scope);
	
	-- Parse Indexing Expressions
	while(consume(self, TokenKind.Symbol, "[")) do
		local expr = self:expression(scope);
		expect(self, TokenKind.Symbol, "]");
		base = Ast.IndexExpression(base, expr);
	end
	
	-- Parse Indexing Expressions
	while consume(self, TokenKind.Symbol, ".") do
		local ident = expect(self, TokenKind.Ident);
		base = Ast.IndexExpression(base, Ast.StringExpression(ident.value));
		
		while(consume(self, TokenKind.Symbol, "[")) do
			local expr = self:expression(scope);
			expect(self, TokenKind.Symbol, "]");
			base = Ast.IndexExpression(base, expr);
		end
	end

	-- LuaU type cast:  expr :: Type  (discard the type, return base unchanged)
	if self.luaVersion == LuaVersion.LuaU then
		while is(self, TokenKind.Symbol, "::") do
			self.index = self.index + 1  -- consume "::"
			skipType(self)               -- discard the cast type
		end
	end

	-- Function Passing self
	if(consume(self, TokenKind.Symbol, ":")) then
		local passSelfFunctionName = expect(self, TokenKind.Ident).value;
		local args = {};
		if(is(self, TokenKind.String)) then
			args = {
				Ast.StringExpression(get(self).value),
			};
		elseif(is(self, TokenKind.Symbol, "{")) then
			args = {
				self:tableConstructor(scope),
			};
		else
			expect(self, TokenKind.Symbol, "(");
			if(not is(self, TokenKind.Symbol, ")")) then
				args = self:exprList(scope);
			end
			expect(self, TokenKind.Symbol, ")");
		end
		
		local node = Ast.PassSelfFunctionCallExpression(base, passSelfFunctionName, args);

		-- LuaU type cast after a method call:  obj:method() :: Type
		if self.luaVersion == LuaVersion.LuaU then
			while is(self, TokenKind.Symbol, "::") do
				self.index = self.index + 1
				skipType(self)
			end
		end

		-- the result of a function call can be indexed
		if(is(self, TokenKind.Symbol, ".") or is(self, TokenKind.Symbol, "[") or is(self, TokenKind.Symbol, ":")) then
			return self:expressionIndex(scope, node);
		end

		-- The result of a function call can be a function that is again called
		if(is(self, TokenKind.Symbol, "(") or is(self, TokenKind.Symbol, "{") or is(self, TokenKind.String)) then
			return self:expressionFunctionCall(scope, node);
		end
		
		return node
	end

	-- The result of a function call can be a function that is again called
	if(is(self, TokenKind.Symbol, "(") or is(self, TokenKind.Symbol, "{") or is(self, TokenKind.String)) then
		return self:expressionFunctionCall(scope, base);
	end
	
	return base;
end

function Parser:expressionLiteral(scope)
	-- () expression
	if(consume(self, TokenKind.Symbol, "(")) then
		local expr = self:expression(scope);
		expect(self, TokenKind.Symbol, ")");
		return expr;
	end
	
	-- String Literal
	if(is(self, TokenKind.String)) then
		return Ast.StringExpression(get(self).value);
	end

	-- Luau Interpolated String: `text {expr} text`
	-- Desugar into: "text" .. tostring(expr) .. "text"
	if(is(self, TokenKind.InterpolatedString)) then
		local tk = get(self);
		local parts = tk.value;
		if #parts == 0 then
			return Ast.StringExpression("");
		end
		if #parts == 1 and parts[1].type == "str" then
			return Ast.StringExpression(parts[1].value);
		end
		-- Build concatenation chain
		local Parser2 = require("catph.parser");
		local globalScope = scope;
		while globalScope.parent do globalScope = globalScope.parent end
		local result = nil;
		for _, part in ipairs(parts) do
			local node;
			if part.type == "str" then
				node = Ast.StringExpression(part.value);
			else
				-- Parse the expression text
				local subParser = Parser2:new({LuaVersion = self.luaVersion});
				subParser.disableLog = true;
				local exprAst = subParser:parse("return " .. part.value);
				local retStat = exprAst.body.statements[1];
				if retStat and retStat.args and retStat.args[1] then
					node = retStat.args[1];
					-- Wrap in tostring() call for safety
					local tostringScope, tostringId = scope:resolve("tostring");
					node = Ast.FunctionCallExpression(
						Ast.VariableExpression(tostringScope, tostringId),
						{node}
					);
				else
					node = Ast.StringExpression("");
				end
			end
			if result == nil then
				result = node;
			else
				result = Ast.StrCatExpression(result, node);
			end
		end
		return result;
	end
	
	-- Number Literal
	if(is(self, TokenKind.Number)) then
		return Ast.NumberExpression(get(self).value);
	end
	
	-- True Literal
	if(consume(self, TokenKind.Keyword, "true")) then
		return Ast.BooleanExpression(true);
	end
	
	-- False Literal
	if(consume(self, TokenKind.Keyword, "false")) then
		return Ast.BooleanExpression(false);
	end
	
	-- Nil Literal
	if(consume(self, TokenKind.Keyword, "nil")) then
		return Ast.NilExpression();
	end
	
	-- Vararg Literal
	if(consume(self, TokenKind.Symbol, "...")) then
		return Ast.VarargExpression();
	end
	
	-- LuaU: if-then-else expression
	-- local x = if cond then exprA elseif cond2 then exprB else exprC
	if self.luaVersion == LuaVersion.LuaU and is(self, TokenKind.Keyword, "if") then
		self.index = self.index + 1  -- consume "if"
		local condition = self:expression(scope)
		expect(self, TokenKind.Keyword, "then")
		local thenExpr = self:expression(scope)
		-- Handle elseif chains
		while is(self, TokenKind.Keyword, "elseif") do
			self.index = self.index + 1  -- consume "elseif"
			local elseifCond = self:expression(scope)
			expect(self, TokenKind.Keyword, "then")
			local elseifExpr = self:expression(scope)
			-- Build nested: if cond then thenExpr else (if elseifCond then elseifExpr else ...)
			-- We'll fold at the end with the final else
			thenExpr = Ast.OrExpression(
				Ast.AndExpression(condition, thenExpr),
				Ast.AndExpression(elseifCond, elseifExpr)
			)
			condition = Ast.OrExpression(condition, elseifCond)
		end
		expect(self, TokenKind.Keyword, "else")
		local elseExpr = self:expression(scope)
		-- Desugar: if cond then A else B  =>  (cond and A) or (not cond and B)
		-- But that's not semantically correct for falsy A values.
		-- Correct approach: use a ternary pattern that the VM handles.
		-- Since our VM compiles the AST, we emit it as:
		-- (function() if cond then return A else return B end end)()
		-- This is always correct regardless of A/B truthiness.
		local ternaryScope = Scope:new(scope)
		local ifStat = Ast.IfStatement(condition,
			Ast.Block({ Ast.ReturnStatement({thenExpr}) }, Scope:new(ternaryScope)),
			{}, -- no elseifs (already folded above)
			Ast.Block({ Ast.ReturnStatement({elseExpr}) }, Scope:new(ternaryScope))
		)
		local body = Ast.Block({ ifStat }, ternaryScope)
		local funcLiteral = Ast.FunctionLiteralExpression({}, body)
		return Ast.FunctionCallExpression(funcLiteral, {})
	end

	-- Variable
	if(is(self, TokenKind.Ident)) then
		local ident = get(self);
		local name = ident.value;
		
		local scope, id = scope:resolve(name);
		return Ast.VariableExpression(scope, id);
	end
	
	if(self.disableLog) then error() end
	logger:error(generateError(self, "Unexpected Token \"" .. peek(self).source .. "\". Expected a Expression!"))
end

function Parser:tableConstructor(scope)
	-- TODO: Parse Table Literals
	local entries = {};
	
	expect(self, TokenKind.Symbol, "{");
	
	while (not consume(self, TokenKind.Symbol, "}")) do
		if(consume(self, TokenKind.Symbol, "[")) then
			local key = self:expression(scope);
			expect(self, TokenKind.Symbol, "]");
			expect(self, TokenKind.Symbol, "=");
			local value = self:expression(scope);
			table.insert(entries, Ast.KeyedTableEntry(key, value));
		elseif(is(self, TokenKind.Ident, 0) and is(self, TokenKind.Symbol, "=", 1)) then
			local key = Ast.StringExpression(get(self).value);
			expect(self, TokenKind.Symbol, "=");
			local value = self:expression(scope);
			table.insert(entries, Ast.KeyedTableEntry(key, value));
		else
			local value = self:expression(scope);
			table.insert(entries, Ast.TableEntry(value));
		end
		
		
		if (not consume(self, TokenKind.Symbol, ";") and not consume(self, TokenKind.Symbol, ",") and not is(self, TokenKind.Symbol, "}")) then
			if self.disableLog then error() end
			logger:error(generateError(self, "expected a \";\" or a \",\""));
		end
	end
	
	return Ast.TableConstructorExpression(entries);
end

return Parser