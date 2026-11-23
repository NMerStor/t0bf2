--
-- ControlFlowFlattening.lua
--
-- Applies basic Control Flow Flattening (CFF) to eligible function bodies.
--
-- Strategy:
--   1. Walk the AST and find function body blocks (isFunctionBlock = true).
--   2. Skip hot-path functions: those directly passed to per-frame events
--      (RenderStepped, Heartbeat, Stepped, PreRender, PostSimulation, Connect,
--       spawn, task.spawn, task.defer, pcall, xpcall) are left untouched.
--   3. Skip trivial functions (fewer than MinStatements top-level statements).
--   4. For eligible functions: collect the top-level statements as "blocks",
--      assign each a random state number, emit:
--
--        local _s = <entry_state>
--        while _s ~= 0 do
--            if _s == <s1> then
--                [block 1 statements]
--                _s = <s2>          -- → next block
--            elseif _s == <s2> then
--                [block 2 statements]
--                _s = <s3>
--            ...
--            elseif _s == <sN> then
--                [block N statements]
--                _s = 0             -- → exit loop
--            end
--        end
--
--   Return/break statements inside a block emit `_s = 0` before themselves
--   so the while loop also exits cleanly.
--
-- Performance note:
--   CFF adds one integer comparison + assignment per original statement group.
--   This is negligible for init/setup code that runs once. It is explicitly
--   NOT applied to per-frame callbacks so FPS is unaffected.

local Step     = require("catph.step")
local Ast      = require("catph.ast")
local Scope    = require("catph.scope")
local visitast = require("catph.visitast")
local AstKind  = Ast.AstKind

-- ── hot-path detection ────────────────────────────────────────────────────────
-- These call names indicate a function argument that runs frequently or is
-- called in a context where overhead is unacceptable.
local HOT_CALLERS = {
    -- Roblox per-frame events
    Connect         = true,
    connect         = true,
    -- task library
    spawn           = true,
    defer           = true,
    delay           = true,
    -- global spawn / pcall variants
    ["task.spawn"]  = true,
    ["task.defer"]  = true,
    ["task.delay"]  = true,
    -- coroutine
    wrap            = true,
    create          = true,
    -- error handling (usually tiny, but skip anyway)
    pcall           = true,
    xpcall          = true,
    -- Roblox-specific
    newcclosure     = true,
    hookfunction    = true,
}

-- ── helpers ───────────────────────────────────────────────────────────────────

local function randState()
    -- Large random range makes state pattern-matching harder
    return math.random(0x1000, 0x7FFFFF)
end

-- Build:  _s = A + B  (where A+B = value, obfuscates state transitions)
local function makeStateAssign(stateScope, stateId, value)
    -- Split value into two parts to defeat pattern recognition
    local A = math.random(1, math.max(1, math.floor(value / 2)))
    local B = value - A
    return Ast.AssignmentStatement(
        { Ast.AssignmentVariable(stateScope, stateId) },
        { Ast.AddExpression(
            Ast.NumberExpression(A),
            Ast.NumberExpression(B)
          )
        }
    )
end

-- Build the flattened while loop for a list of statement groups.
-- groups = { { state=N, stmts={...}, isTerminal=bool }, ... }
local function buildFlatLoop(groups, stateScope, stateId, exitState)
    local elseifs = {}
    for i = 2, #groups do
        local g = groups[i]
        local stmts = {}
        for _, s in ipairs(g.stmts) do stmts[#stmts + 1] = s end
        -- Only add state transition if this group doesn't already terminate.
        if not g.isTerminal then
            local nextState = (i < #groups) and groups[i + 1].state or exitState
            stmts[#stmts + 1] = makeStateAssign(stateScope, stateId, nextState)
        end
        local blkScope = Scope:new(stateScope)
        table.insert(elseifs, {
            condition = Ast.EqualsExpression(
                Ast.VariableExpression(stateScope, stateId),
                Ast.NumberExpression(g.state)
            ),
            body = Ast.Block(stmts, blkScope),
        })
    end

    local g1 = groups[1]
    local stmts1 = {}
    for _, s in ipairs(g1.stmts) do stmts1[#stmts1 + 1] = s end
    if not g1.isTerminal then
        local nextState1 = (#groups > 1) and groups[2].state or exitState
        stmts1[#stmts1 + 1] = makeStateAssign(stateScope, stateId, nextState1)
    end
    local blkScope1 = Scope:new(stateScope)
    local ifStat = Ast.IfStatement(
        Ast.EqualsExpression(
            Ast.VariableExpression(stateScope, stateId),
            Ast.NumberExpression(g1.state)
        ),
        Ast.Block(stmts1, blkScope1),
        elseifs,
        nil
    )

    local loopScope = Scope:new(stateScope)
    local loopBody  = Ast.Block({ ifStat }, loopScope)
    return Ast.WhileStatement(
        loopBody,
        Ast.NotEqualsExpression(
            Ast.VariableExpression(stateScope, stateId),
            Ast.NumberExpression(exitState)
        ),
        stateScope
    )
end

-- ── step ──────────────────────────────────────────────────────────────────────

local CFF = Step:extend()
CFF.Name        = "ControlFlowFlattening"
CFF.Description = "Applies control flow flattening to non-hot-path functions, destroying linear code structure without affecting per-frame performance."

CFF.SettingsDescriptor = {
    MinStatements = {
        type        = "number",
        default     = 4,
        min         = 2,
        max         = 100,
        description = "Minimum number of top-level statements a function body must have to be flattened.",
    },
    Probability = {
        type        = "number",
        default     = 1.0,
        min         = 0,
        max         = 1,
        description = "Probability (0..1) that an eligible function body gets flattened.",
    },
}

function CFF:init(settings) end

-- Check if a FunctionLiteralExpression node is being passed directly as an
-- argument to a known hot-path caller. `parentCall` is set by the visitor.
local function isHotPathArg(node, parentNode)
    if not parentNode then return false end

    -- Standard function call: spawn(function() ... end)
    if parentNode.kind == AstKind.FunctionCallExpression or
       parentNode.kind == AstKind.FunctionCallStatement then
        local isArg = false
        if parentNode.args then
            for _, a in ipairs(parentNode.args) do
                if a == node then isArg = true; break end
            end
        end
        if not isArg then return false end

        local base = parentNode.base
        if not base then return false end

        if base.kind == AstKind.VariableExpression then
            local name = base.scope and base.scope:getVariableName(base.id)
            if name and HOT_CALLERS[name] then return true end
        end

        if base.kind == AstKind.IndexExpression then
            local idx = base.index
            if idx and idx.kind == AstKind.StringExpression then
                if HOT_CALLERS[idx.value] then return true end
            end
        end
    end

    -- Colon method call: event:Connect(function() ... end)
    -- Uses PassSelfFunctionCallStatement / PassSelfFunctionCallExpression.
    local psKind = parentNode.kind
    if psKind == "PassSelfFunctionCallStatement" or
       psKind == "PassSelfFunctionCallExpression" then
        local isArg = false
        if parentNode.args then
            for _, a in ipairs(parentNode.args) do
                if a == node then isArg = true; break end
            end
        end
        if not isArg then return false end
        -- Check the method name.
        local methodName = parentNode.passSelfFunctionName
        if methodName and HOT_CALLERS[methodName] then return true end
        -- Also check base index (e.g. obj.RenderStepped → not a hot-caller name,
        -- but we can't know — only flag known hot-caller METHOD names).
    end

    return false
end

-- Split a flat statement list into groups of 1-3 statements each.
-- We keep related statements together (local + its first use, etc.) by
-- using a simple fixed group size chosen randomly per function.
-- Split a flat statement list into individual single-statement groups.
-- One statement per group is the safest approach — avoids any cross-group
-- local variable visibility issues after flattening into if/elseif branches.
local function splitIntoGroups(stmts)
    local groups = {}
    for i = 1, #stmts do
        local sk = stmts[i].kind
        local isExit = sk == AstKind.ReturnStatement or
                       sk == AstKind.BreakStatement  or
                       sk == AstKind.ContinueStatement
        groups[#groups + 1] = {
            state      = randState(),
            stmts      = { stmts[i] },
            isTerminal = isExit,
        }
    end
    return groups
end

function CFF:apply(ast, pipeline)
    -- We do a post-order walk so nested functions get processed after their
    -- parents (inside-out). We track the immediate parent call node so we
    -- can detect hot-path arguments.
    local parentStack = {}

    visitast(ast, function(node, data)
        -- Push this node onto the parent stack before visiting children.
        parentStack[#parentStack + 1] = node
    end, function(node, data)
        -- Pop on exit.
        parentStack[#parentStack] = nil

        -- Process both FunctionLiteralExpression AND LocalFunctionDeclaration/FunctionDeclaration.
        local body
        if node.kind == AstKind.FunctionLiteralExpression then
            body = node.body
        elseif node.kind == AstKind.LocalFunctionDeclaration or
               node.kind == AstKind.FunctionDeclaration then
            body = node.body
        else
            return
        end

        -- Respect probability setting.
        if math.random() > self.Probability then return end

        -- For FunctionLiteralExpression, check hot-path.
        if node.kind == AstKind.FunctionLiteralExpression then
            local parent = parentStack[#parentStack]
            if isHotPathArg(node, parent) then return end
        end
        if not body or not body.statements then return end
        local stmts = body.statements

        -- Skip trivial bodies.
        if #stmts < self.MinStatements then return end

        -- Don't flatten bodies that already contain a while loop at top level.
        for _, s in ipairs(stmts) do
            if s.kind == AstKind.WhileStatement then return end
        end

        local fnScope = body.scope

        -- ── Step 1: Hoist locals ─────────────────────────────────────────────
        -- Convert LocalVariableDeclarations to assignments so the variables
        -- are visible across all if/elseif branches after flattening.
        local hoistedIds = {}
        local splitStmts = {}

        for _, stmt in ipairs(stmts) do
            if stmt.kind == AstKind.LocalVariableDeclaration then
                for _, id in ipairs(stmt.ids) do
                    hoistedIds[#hoistedIds + 1] = id
                end
                if stmt.expressions and #stmt.expressions > 0 then
                    local lhs = {}
                    for _, id in ipairs(stmt.ids) do
                        lhs[#lhs + 1] = Ast.AssignmentVariable(fnScope, id)
                    end
                    splitStmts[#splitStmts + 1] = Ast.AssignmentStatement(lhs, stmt.expressions)
                end
            else
                splitStmts[#splitStmts + 1] = stmt
            end
        end

        -- Use splitStmts for the actual grouping.
        if #splitStmts < 2 then return end

        -- ── Step 2: Split into groups ────────────────────────────────────────
        local groups = splitIntoGroups(splitStmts)
        if #groups < 2 then return end

        -- Ensure unique state numbers.
        local seen = {}
        for _, g in ipairs(groups) do
            while seen[g.state] do g.state = randState() end
            seen[g.state] = true
        end

        local EXIT_STATE = 0

        -- ── Step 3: Build state variable ─────────────────────────────────────
        local _suffixes = {"_fs","_st","_pc","_sw","_dp","_rt","_vm","_cx","_bx","_nc"}
        local _sfx = _suffixes[math.random(1, #_suffixes)]
        local stateId    = fnScope:addVariable(_sfx .. tostring(math.random(100,999)))
        local entryState = groups[1].state
        local stateDecl  = Ast.LocalVariableDeclaration(
            fnScope, { stateId }, { Ast.NumberExpression(entryState) }
        )

        -- ── Step 4: Build hoisted locals declaration ─────────────────────────
        local hoistDecl = nil
        if #hoistedIds > 0 then
            hoistDecl = Ast.LocalVariableDeclaration(fnScope, hoistedIds, {})
        end

        -- ── Step 5: Build the while loop ─────────────────────────────────────
        local whileLoop = buildFlatLoop(groups, fnScope, stateId, EXIT_STATE)

        -- ── Step 6: Replace function body ────────────────────────────────────
        -- Layout:  [local x,y,z]  local _67fsc=N  while _67fsc~=0 do...end
        if hoistDecl then
            body.statements = { hoistDecl, stateDecl, whileLoop }
        else
            body.statements = { stateDecl, whileLoop }
        end
    end)

    return ast
end

return CFF
