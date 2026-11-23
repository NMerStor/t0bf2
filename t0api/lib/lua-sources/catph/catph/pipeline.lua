--
-- pipeline.lua
--
-- This Script Provides a Configurable Obfuscation Pipeline that can obfuscate code using different Modules
-- These Modules can simply be added to the pipeline

local config = require("config");
local Ast    = require("catph.ast");
local Enums  = require("catph.enums");
local util = require("catph.util");
local Parser = require("catph.parser");
local Unparser = require("catph.unparser");
local logger = require("logger");

local NameGenerators = require("catph.namegenerators");

local Steps = require("catph.steps");

local lookupify = util.lookupify;
local LuaVersion = Enums.LuaVersion;
local AstKind = Ast.AstKind;

-- On Windows os.clock can be used. On other Systems os.time must be used for benchmarking
local isWindows = package and package.config and type(package.config) == "string" and package.config:sub(1,1) == "\\";
local function gettime()
	if isWindows then
		return os.clock();
	else
		return os.time();
	end
end

local Pipeline = {
	NameGenerators = NameGenerators;
	Steps = Steps;
	DefaultSettings = {
		LuaVersion = LuaVersion.LuaU; -- The Lua Version to use for the Tokenizer, Parser and Unparser
		PrettyPrint = false; -- Note that Pretty Print is currently not producing Pretty results
		Seed = 0; -- The Seed. 0 or below uses the current time as a seed
		VarNamePrefix = ""; -- The Prefix that every variable will start with
	}
}


function Pipeline:new(settings)
	local luaVersion = settings.luaVersion or settings.LuaVersion or Pipeline.DefaultSettings.LuaVersion;
	local conventions = Enums.Conventions[luaVersion];
	if(not conventions) then
		logger:error("The Lua Version \"" .. luaVersion 
			.. "\" is not recognised by the Tokenizer! Please use one of the following: \"" .. table.concat(util.keys(Enums.Conventions), "\",\"") .. "\"");
	end
	
	local prettyPrint = settings.PrettyPrint or Pipeline.DefaultSettings.PrettyPrint;
	local prefix = settings.VarNamePrefix or Pipeline.DefaultSettings.VarNamePrefix;
	local seed = settings.Seed or 0;
	
	local pipeline = {
		LuaVersion = luaVersion;
		PrettyPrint = prettyPrint;
		VarNamePrefix = prefix;
		Seed = seed;
		parser = Parser:new({
			LuaVersion = luaVersion;
		});
		unparser = Unparser:new({
			LuaVersion = luaVersion;
			PrettyPrint = prettyPrint;
			Highlight = settings.Highlight;
		});
		namegenerator = Pipeline.NameGenerators.MangledShuffled;
		conventions = conventions;
		steps = {};
	}
	
	setmetatable(pipeline, self);
	self.__index = self;
	
	return pipeline;
end

function Pipeline:fromConfig(config)
	config = config or {};
	local pipeline = Pipeline:new({
		LuaVersion    = config.LuaVersion or LuaVersion.Lua51;
		PrettyPrint   = config.PrettyPrint or false;
		VarNamePrefix = config.VarNamePrefix or "";
		Seed          = config.Seed or 0;
	});

	pipeline:setNameGenerator(config.NameGenerator or "MangledShuffled")

	-- Add all Steps defined in Config
	local steps = config.Steps or {};
	for i, step in ipairs(steps) do
		if type(step.Name) ~= "string" then
			logger:error("Step.Name must be a String");
		end
		local constructor = pipeline.Steps[step.Name];
		if not constructor then
			logger:error(string.format("The Step \"%s\" was not found!", step.Name));
		end
		pipeline:addStep(constructor:new(step.Settings or {}));
	end

	return pipeline;
end

function Pipeline:addStep(step)
	table.insert(self.steps, step);
end

function Pipeline:resetSteps(step)
	self.steps = {};
end

function Pipeline:getSteps()
	return self.steps;
end

function Pipeline:setOption(name, value)
	assert(false, "TODO");
	if(Pipeline.DefaultSettings[name] ~= nil) then
		
	else
		logger:error(string.format("\"%s\" is not a valid setting"));
	end
end

function Pipeline:setLuaVersion(luaVersion)
	local conventions = Enums.Conventions[luaVersion];
	if(not conventions) then
		logger:error("The Lua Version \"" .. luaVersion 
			.. "\" is not recognised by the Tokenizer! Please use one of the following: \"" .. table.concat(util.keys(Enums.Conventions), "\",\"") .. "\"");
	end
	
	self.parser = Parser:new({
		luaVersion = luaVersion;
	});
	self.unparser = Unparser:new({
		luaVersion = luaVersion;
	});
	self.conventions = conventions;
end

function Pipeline:getLuaVersion()
	return self.luaVersion;
end

function Pipeline:setNameGenerator(nameGenerator)
	if(type(nameGenerator) == "string") then
		nameGenerator = Pipeline.NameGenerators[nameGenerator];
	end
	
	if(type(nameGenerator) == "function" or type(nameGenerator) == "table") then
		self.namegenerator = nameGenerator;
		return;
	else
		logger:error("The Argument to Pipeline:setNameGenerator must be a valid NameGenerator function or function name e.g: \"mangled\"")
	end
end
local function addU(str)
    local t = {}
    for i = 1, #str do
        table.insert(t, str:sub(i, i))
        if math.random() > 0.9 then
            table.insert(t, "_")
        end
    end
    return table.concat(t)
end
local function numToB(num)
    local byteString = ""
    while num > 0 do
        local remainder = num % 2
        byteString = remainder .. byteString
        num = math.floor(num / 2)
    end
    return byteString ~= "" and byteString or "0"
end
local StringChars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_\\\""
local function luraphnumbers(str, max)
    -- Replace numbers with a unique placeholder
    local placeholder = {}
    local count = 0

    local modified_str = str:gsub('([^%w_])(%d+%.?%d*)([^%.%d])', function(prefix, num, suffix)
        local idx = str:find(num)
        local quote_count = 0
        -- Count unescaped quotes before the current number
        for i = 1, idx do
            local char = str:sub(i, i)
            if char == '"' and (i == 1 or str:sub(i - 1, i - 1) ~= "\\") then
                quote_count = quote_count + 1
            end
        end

        -- Convert only if the count of quotes is even (outside of string)
		local function test()
			local didrun, res = pcall(function() return StringChars:find(prefix) end)
			return didrun and not res
		end
        if quote_count % 2 == 0 and test() and suffix:find"." then --count<max
            count = count + 1
            -- Binary removed: use hex only (binary pattern "0B..." is too recognisable)
            local newvalue = addU(string.format("0x%X", tonumber(num)))
            -- Store the placeholder
            placeholder[count] = prefix .. newvalue .. suffix
            return "##PLACEHOLDER" .. count .. "##"  -- Use placeholder
        end

        return prefix .. num .. suffix
    end)

    -- Replace placeholders with the modified values
    for i = 1, count do
        modified_str = modified_str:gsub("##PLACEHOLDER" .. i .. "##", placeholder[i])
    end

    return modified_str
end


function Pipeline:apply(code, filename)
    local startTime = gettime();
    filename = filename or "Anonymus Script";
    logger:info(string.format("Obfuscating %s ...", filename));

    -- Seed the Random Generator. os.time() alone is guessable from a file's mtime
    -- or upload timestamp, which would let an attacker replay every "random"
    -- choice (encrypt keys, names, layouts). Mix in object-pointer entropy and
    -- sub-second clock so the seed isn't derivable from wall time alone.
    if(self.Seed > 0) then
        math.randomseed(self.Seed);
    else
        local function ptrHash(t)
            local s = tostring(t)
            local n = 0
            for i = 1, #s do n = (n * 257 + s:byte(i)) % 2147483647 end
            return n
        end
        local seed = os.time() % 2147483647
        seed = (seed * 65539 + ptrHash({})) % 2147483647
        seed = (seed * 65539 + ptrHash(function() end)) % 2147483647
        seed = (seed * 65539 + math.floor((os.clock() % 1) * 1e9)) % 2147483647
        math.randomseed(seed)
    end

    logger:info("Parsing ...");
    local parserStartTime = gettime();

    -- FUS_LINE / LPH_LINE: replace each occurrence with the actual line number
    -- before the parser sees the source. This is a text-level substitution so
    -- line info is available even though the AST doesn't store it.
    -- Only standalone identifier occurrences are replaced (not calls like FUS_LINE()).
    do
        local lines = {}
        local lineNum = 0
        -- Process source line by line to know current line number.
        local result = code:gsub("([^\n]*)\n?", function(lineContent)
            lineNum = lineNum + 1
            -- Replace FUS_LINE / LPH_LINE when they appear as identifiers
            -- (word boundary on both sides) but NOT followed by ( (that's a
            -- call which will be caught as an error by MacroExpand).
            local replaced = lineContent:gsub(
                "%f[%w_]([FL][PU][HS]_LINE)%f[^%w_]",
                function(macro)
                    if macro == "FUS_LINE" or macro == "LPH_LINE" then
                        return tostring(lineNum)
                    end
                    return macro
                end
            )
            lines[#lines + 1] = replaced
            return ""  -- consume input
        end)
        code = table.concat(lines, "\n")
        -- Trim trailing newline added by the gsub pattern if original didn't have one.
        if result == "" and #lines > 0 and lines[#lines] == "" then
            table.remove(lines)
            code = table.concat(lines, "\n")
        end
    end

    local sourceLen = string.len(code);
    local ast = self.parser:parse(code);

    local parserTimeDiff = gettime() - parserStartTime;
    logger:info(string.format("Parsing Done in %.2f seconds", parserTimeDiff));

    -- User Defined Steps
    for i, step in ipairs(self.steps) do
        local stepStartTime = gettime();
        logger:info(string.format("Applying Step \"%s\" ...", step.Name or "Unnamed"));
        local newAst = step:apply(ast, self);
        if type(newAst) == "table" then
            ast = newAst;
        end
        logger:info(string.format("Step \"%s\" Done in %.2f seconds", step.Name or "Unnamed", gettime() - stepStartTime));
    end

    -- Rename Variables Step
    self:renameVariables(ast);
    code = self:unparse(ast)


    local timeDiff = gettime() - startTime;
    logger:info(string.format("Obfuscation Done in %.2f seconds", timeDiff));

    logger:info(string.format("Generated Code is %.2f times the Source Code's size", (string.len(code) / sourceLen)))

    return code;
end

function Pipeline:unparse(ast)
	local startTime = gettime();
	logger:info("Generating Code ...");

	local unparsed = self.unparser:unparse(ast);
	-- unparsed = luraphnumbers(unparsed)
	local timeDiff = gettime() - startTime;
	logger:info(string.format("Code Generation Done in %.2f seconds", timeDiff));

	return unparsed;
end

function Pipeline:renameVariables(ast)
	local startTime = gettime();
	logger:info("Renaming Variables ...");


	local generatorFunction = self.namegenerator or Pipeline.NameGenerators.mangled;
	if(type(generatorFunction) == "table") then
		if (type(generatorFunction.prepare) == "function") then
			generatorFunction.prepare(ast);
		end
		generatorFunction = generatorFunction.generateName;
	end

	if not self.unparser:isValidIdentifier(self.VarNamePrefix) and #self.VarNamePrefix ~= 0 then
		logger:error(string.format("The Prefix \"%s\" is not a valid Identifier in %s", self.VarNamePrefix, self.LuaVersion));
	end

	local globalScope = ast.globalScope;
	globalScope:renameVariables({
		Keywords = self.conventions.Keywords;
		generateName = generatorFunction;
		prefix = self.VarNamePrefix;
	});

	local timeDiff = gettime() - startTime;
	logger:info(string.format("Renaming Done in %.2f seconds", timeDiff));
end




return Pipeline;
