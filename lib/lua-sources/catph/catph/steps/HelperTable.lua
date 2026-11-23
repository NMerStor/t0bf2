--
-- HelperTable.lua
--
-- Gathers all global built-in references used in the script into a single
-- helper table declared at the top of the program, then replaces every
-- read of those globals with an index into the table:
--
--   print("hi")          local _H = {print, math.floor}
--   math.floor(x)   →   _H[1]("hi")
--                        _H[2](x)
--
-- Only plain global VariableExpression reads are moved (e.g. `print`,
-- `math`, `string`, `table`, `pcall`, …).  Assignment targets and
-- globals whose name starts with "_" are left untouched.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local Scope    = require("catph.scope")
local visitast = require("catph.visitast")

local AstKind = Ast.AstKind

local HelperTable = Step:extend()
HelperTable.Name        = "HelperTable"
HelperTable.Description = "Moves global built-in references into a helper table and replaces accesses with indexed lookups."
HelperTable.SettingsDescriptor = {}

function HelperTable:init(settings)
end

function HelperTable:apply(ast, pipeline)
    local globalScope = ast.globalScope

    -- ── Pass 1: collect every global id that is READ (not written) ──────────
    -- writtenGlobals[id] = true  → skip (it's assigned somewhere)
    local writtenGlobals = {}
    local readGlobals    = {}   -- id → true

    visitast(ast, function(node, data)
        if node.kind == AstKind.AssignmentStatement then
            for _, lhs in ipairs(node.lhs) do
                if lhs.kind == AstKind.AssignmentVariable and lhs.scope == globalScope then
                    writtenGlobals[lhs.id] = true
                end
            end
        end
        if node.kind == AstKind.VariableExpression and node.scope == globalScope then
            readGlobals[node.id] = true
        end
    end, nil)

    -- Remove written globals from candidates
    for id in pairs(writtenGlobals) do readGlobals[id] = nil end

    -- Skip globals whose original name starts with "_" (internal / env vars)
    for id in pairs(readGlobals) do
        local name = globalScope:getVariableName(id) or ""
        if name:sub(1, 1) == "_" then
            readGlobals[id] = nil
        end
    end

    if next(readGlobals) == nil then return ast end

    -- ── Build ordered list + index map ──────────────────────────────────────
    local orderedIds = {}
    local idToIndex  = {}
    for id in pairs(readGlobals) do
        table.insert(orderedIds, id)
    end
    -- Sort by name for deterministic output
    table.sort(orderedIds, function(a, b)
        return (globalScope:getVariableName(a) or "") < (globalScope:getVariableName(b) or "")
    end)
    for i, id in ipairs(orderedIds) do
        idToIndex[id] = i
    end

    -- ── Create helper table local in the main block's scope ─────────────────
    local mainBlock  = ast.body
    local mainScope  = mainBlock.scope
    local helperId   = mainScope:addVariable()

    -- Table entries: {global1, global2, ...}
    -- Track the entry nodes so Pass 2 can skip them (avoid circular reference)
    local entries    = {}
    local skipNodes  = {}
    for _, id in ipairs(orderedIds) do
        local entryNode = Ast.VariableExpression(globalScope, id)
        skipNodes[entryNode] = true
        table.insert(entries, Ast.TableEntry(entryNode))
    end

    local helperDecl = Ast.LocalVariableDeclaration(
        mainScope,
        { helperId },
        { Ast.TableConstructorExpression(entries) }
    )

    -- Insert at position 1 in the main block
    table.insert(mainBlock.statements, 1, helperDecl)

    -- ── Pass 2: replace every read VariableExpression of a candidate global ──
    -- Skip the table-constructor entry nodes built above to avoid self-reference.
    visitast(ast, nil, function(node, data)
        if node.kind == AstKind.VariableExpression
            and node.scope == globalScope
            and idToIndex[node.id]
            and not skipNodes[node]
        then
            local idx = idToIndex[node.id]
            -- Remove the direct reference on the global scope
            globalScope:removeReference(node.id)
            -- Register the helper variable as an upvalue in any nested scope
            -- so the renamer knows to reserve its name there (avoid collisions).
            -- Top-level / global scope reads return early from this call (isGlobal).
            if not data.scope.isGlobal then
                data.scope:addReferenceToHigherScope(mainScope, helperId)
            end
            local helperRef = Ast.VariableExpression(mainScope, helperId)
            return Ast.IndexExpression(helperRef, Ast.NumberExpression(idx))
        end
    end)

    return ast
end

return HelperTable
