-- Project Radium - IB1/Luraph-style range-tree FAT state machine
-- Huge state ID space; O(stages) emitted nodes

local StateMachine = {}

local function shuffle(t, rng)
    for i = #t, 2, -1 do
        local j = rng(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

--- Wrap body in a very fat range-tree dispatcher.
-- opts.stages = node count (default 200, cap 12000)
function StateMachine.wrapBody(body, opts)
    opts = opts or {}
    local rng = opts.rng or math.random
    local stages = opts.stages or 200
    if stages < 16 then stages = 16 end
    if stages > 12000 then stages = 12000 end

    local stName = opts.stateName or ("_" .. tostring(rng(100, 999)))

    local used = {}
    local function rid()
        local n
        repeat
            n = rng(100000, 99999999)
        until not used[n]
        used[n] = true
        return n
    end

    local startS, workS, endS = rid(), rid(), rid()
    local nodes = {
        { id = startS, kind = "start" },
        { id = workS,  kind = "work" },
        { id = endS,   kind = "end" },
    }
    local junkIds = {}
    for i = 1, stages - 3 do
        local id = rid()
        junkIds[#junkIds + 1] = id
        local kind = "junk"
        local r = rng()
        if r < 0.12 then kind = "opaque"
        elseif r < 0.18 then kind = "dead"
        end
        nodes[#nodes + 1] = { id = id, kind = kind }
    end

    table.sort(nodes, function(a, b) return a.id < b.id end)

    local function bounce()
        if #junkIds == 0 then return workS end
        local r = rng()
        if r < 0.18 then return workS end
        if r < 0.05 then return startS end
        if r < 0.08 then return endS end
        return junkIds[rng(1, #junkIds)]
    end

    local function opaquePred()
        -- always-true or always-false mixed with noise
        local a, b = rng(1, 97), rng(1, 97)
        local style = rng(1, 4)
        if style == 1 then
            return ("(%d*%d-%d==%d)"):format(a, a, a * a, 0) -- a*a - a*a == 0 always true... wait
        elseif style == 2 then
            return ("(%d+%d>%d)"):format(a, b, a) -- always true if b>0
        elseif style == 3 then
            return ("(not not true)")
        else
            return ("(%d==%d)"):format(a, a)
        end
    end

    local function emitLeaf(n)
        if n.kind == "start" then
            return ("if %s==%d then %s=%d end"):format(stName, n.id, stName, workS)
        elseif n.kind == "work" then
            return "if " .. stName .. "==" .. tostring(n.id) .. " then do " .. body .. " end " .. stName .. "=" .. tostring(endS) .. " end"
        elseif n.kind == "end" then
            return ("if %s==%d then break end"):format(stName, n.id)
        elseif n.kind == "opaque" then
            -- confuse static analysis: branch both ways to bounce targets
            local t1, t2 = bounce(), bounce()
            return ("if %s==%d then if %s then %s=%d else %s=%d end end"):format(
                stName, n.id, opaquePred(), stName, t1, stName, t2)
        elseif n.kind == "dead" then
            -- dead arithmetic then bounce
            local x = rng(1, 999)
            return ("if %s==%d then local _=%d _=_*%d+(%d%%%d) %s=%d end"):format(
                stName, n.id, x, rng(2, 9), rng(1, 50), rng(3, 17), stName, bounce())
        else
            return ("if %s==%d then %s=%d end"):format(stName, n.id, stName, bounce())
        end
    end

    local function emitRange(lo, hi)
        if lo > hi then return "do end" end
        if lo == hi then return emitLeaf(nodes[lo]) end
        if hi - lo == 1 then
            return emitLeaf(nodes[lo]) .. " " .. emitLeaf(nodes[hi])
        end
        local mid = math.floor((lo + hi) / 2)
        local pivot = nodes[mid].id
        return ("if %s<=%d then %s else %s end"):format(
            stName, pivot, emitRange(lo, mid), emitRange(mid + 1, hi))
    end

    local tree = emitRange(1, #nodes)
    -- outer decoy locals
    local decoy = {}
    for i = 1, rng(3, 8) do
        decoy[#decoy + 1] = ("local _d%d=%d"):format(i, rng(0, 99999))
    end
    return table.concat(decoy, " ") .. (" local %s=%d repeat %s until false"):format(stName, startS, tree)
end

return StateMachine
