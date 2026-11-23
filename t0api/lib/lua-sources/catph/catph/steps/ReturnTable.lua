--
-- steps/ReturnTable.lua
--
-- Wraps the entire script in `return (function(...) ... end)(...)`.
-- Useful as a final pipeline step when the obfuscated output is meant
-- to be used as a module: the caller receives whatever the script returns.
--
-- Unlike WrapInFunction (which also returns), this step is intentionally
-- minimal with no Iterations setting — one clean wrap, placed last.

local Step  = require("catph.step")
local Ast   = require("catph.ast")
local Scope = require("catph.scope")

local ReturnTable = Step:extend()
ReturnTable.Name        = "ReturnTable"
ReturnTable.Description = "Wraps the entire script in `return (function(...) ... end)(...)` — makes the output usable as a require()-able module."

ReturnTable.SettingsDescriptor = {}

function ReturnTable:init(settings) end

function ReturnTable:apply(ast)
    local body  = ast.body
    local scope = Scope:new(ast.globalScope)
    body.scope:setParent(scope)

    -- IronBrew1-style: add 13 named params before vararg so the wrapper
    -- signature looks like (a,b,c,...) after name-generation.
    local args = {}
    for _ = 1, 13 do
        local id = scope:addVariable()
        args[#args+1] = Ast.VariableExpression(scope, id)
    end
    args[#args+1] = Ast.VarargExpression()

    ast.body = Ast.Block({
        Ast.ReturnStatement({
            Ast.FunctionCallExpression(
                Ast.FunctionLiteralExpression(args, body),
                { Ast.VarargExpression() }
            )
        })
    }, scope)
end

return ReturnTable
