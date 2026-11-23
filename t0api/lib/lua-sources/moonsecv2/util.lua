local util = {}

function util.extract(val, pos, width)
    return math.floor(val / (2 ^ pos)) % (2 ^ width)
end

local function splitfrexp(x)
    if x == 0 then
        return 0, 0
    end
    local ax = math.abs(x)
    local e = math.floor(math.log(ax) / math.log(2)) + 1
    local m = ax / (2 ^ e)
    if m >= 1 then
        m = m / 2
        e = e + 1
    elseif m < 0.5 then
        m = m * 2
        e = e - 1
    end
    return m, e
end

function util.packu32(val)
    local v = math.floor(val) % 4294967296
    local b1 = v % 256
    local b2 = math.floor(v / 256) % 256
    local b3 = math.floor(v / 65536) % 256
    local b4 = math.floor(v / 16777216) % 256
    return { b1, b2, b3, b4 }
end

function util.packu16(val)
    local v = math.floor(val) % 65536
    local b1 = v % 256
    local b2 = math.floor(v / 256) % 256
    return { b1, b2 }
end

function util.packdbl(val)
    if val == 0 then
        return { 0, 0, 0, 0, 0, 0, 0, 0 }
    end
    local sign = 0
    if val < 0 then
        sign = 1
        val = -val
    end
    local mant, exp = splitfrexp(val)
    local bexp = exp + 1022
    local frac = (mant * 2 - 1) * (2 ^ 52)
    local lo = math.floor(frac % 4294967296)
    local hi20 = math.floor(frac / 4294967296) % 1048576
    local hi = sign * 2147483648 + bexp * 1048576 + hi20
    local b1 = util.packu32(lo)
    local b2 = util.packu32(hi)
    return { b1[1], b1[2], b1[3], b1[4], b2[1], b2[2], b2[3], b2[4] }
end

function util.shuf(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function util.picknums(count, lo, hi)
    local used = {}
    local res = {}
    for i = 1, count do
        local v
        repeat
            v = math.random(lo, hi)
        until not used[v]
        used[v] = true
        res[i] = v
    end
    return res
end

local phrases = {
    "protected by moonsec v2",
    "virtual machine bytecode",
    "runtime environment check",
    "bytecode stream decoder",
    "constant pool table",
    "register state frame",
    "instruction dispatch",
    "lexical scope upvalue",
    "closure prototype tree",
    "stack frame pointer",
    "binary chunk header",
    "opcode handler table",
    "moonsec v2 protection",
    "dynamic constant loader",
    "arithmetic expression"
}

local function randtblexpr()
    local items = {}
    local cnt = math.random(2, 6)
    for i = 1, cnt do
        local kind = math.random(1, 5)
        if kind == 1 then
            items[i] = tostring(math.random(1, 199))
        elseif kind == 2 then
            items[i] = "'nil'"
        elseif kind == 3 then
            items[i] = "{}"
        elseif kind == 4 then
            items[i] = "\",\""
        else
            items[i] = "(function()return{','}end)()"
        end
    end
    local sep = (math.random(1, 2) == 1) and "," or ";"
    return "{" .. table.concat(items, sep) .. "}", cnt
end

function util.msexpr(n)
    n = math.floor(n)
    local style = math.random(1, 5)
    if style == 1 then
        local d = math.random(15, 180)
        if math.random(1, 2) == 1 then
            return string.format("(%d+0x%x)", n - d, d)
        else
            return string.format("(0x%x-%d)", n + d, d)
        end
    elseif style == 2 then
        local ph = phrases[math.random(1, #phrases)]
        local plen = #ph
        local rem = n + plen
        local d = math.random(10, 90)
        if math.random(1, 2) == 1 then
            return string.format("(-#%q+(0x%x-%d))", ph, rem + d, d)
        else
            return string.format("((%d+0x%x)+-#[[%s]])", rem - d, d, ph)
        end
    elseif style == 3 then
        local texpr, tlen = randtblexpr()
        local rem = n + tlen
        return string.format("(-#%s+%d)", texpr, rem)
    elseif style == 4 and n > 0 and n < 5000 then
        local k = math.random(12, 190)
        local prod = n * k
        if math.random(1, 2) == 1 then
            return string.format("(0x%x/%d)", prod, k)
        else
            return string.format("(%d/0x%x)", prod, k)
        end
    else
        local ph = phrases[math.random(1, #phrases)]
        local plen = #ph
        local k = math.random(10, 60)
        local target = n + plen
        local prod = target * k
        return string.format("((0x%x/%d)+-#%q)", prod, k, ph)
    end
end

function util.msstr(s)
    if #s < 4 then
        local out = {}
        for i = 1, #s do
            out[i] = string.format("\\%d", s:byte(i))
        end
        return "'" .. table.concat(out) .. "'"
    end
    local p1 = s:sub(1, 2)
    local p2 = s:sub(3, 4)
    local p3 = s:sub(5)
    local function esc(part)
        local t = {}
        for i = 1, #part do
            local b = part:byte(i)
            if i == #part and math.random(1, 2) == 1 and ((b >= 97 and b <= 122) or (b >= 65 and b <= 90)) then
                t[i] = string.char(b)
            else
                t[i] = string.format("\\%d", b)
            end
        end
        return "'" .. table.concat(t) .. "'"
    end
    local n1 = math.random(5, 80)
    local n2 = n1 + math.random(3, 40)
    local fake1 = string.format("(0x%x-%d)", math.random(100, 400), math.random(10, 99))
    local fake2 = string.format("\\%d\\%d", math.random(40, 120), math.random(40, 120))
    local mid = string.format(
        "(function(o)return(o and'%s')or%sor'%s'end)((%s)==(%s))",
        fake1, esc(p2), fake2, util.msexpr(n1), util.msexpr(n2)
    )
    if #p3 > 0 then
        return esc(p1) .. ".." .. mid .. ".." .. esc(p3)
    else
        return esc(p1) .. ".." .. mid
    end
end

function util.makealpha()
    local chars = { "b", "B", "f", "F", "l", "L", "k", "K", "o", "O", "p", "P", "h", "H", "m", "M" }
    util.shuf(chars)
    return table.concat(chars)
end

function util.buildmstree(nodes, rvar, fvar, usedprods)
    usedprods = usedprods or {}

    local function pickpq()
        local p, q, prod
        repeat
            p = math.random(400, 3900)
            q = math.random(50, 3900)
            prod = p * q
        until not usedprods[prod]
        usedprods[prod] = true
        return p, q, prod
    end

    local function rec(lo, hi)
        if lo == hi then
            return nodes[lo].code
        elseif hi == lo + 1 then
            local p, q, prod = pickpq()
            local k1 = nodes[lo].key
            local c1 = nodes[lo].code
            local c2 = nodes[hi].code
            return string.format(
                "%s=(%d)while %s>%s do %s=%s-%s %s break end while(%s)/(%s)==%d do %s break end;",
                fvar, prod, rvar, util.msexpr(k1), fvar, fvar, fvar, c2,
                fvar, util.msexpr(p), q, c1
            )
        else
            local mid = math.floor((lo + hi) / 2)
            local p, q, prod = pickpq()
            local midk = nodes[mid].key
            local left = rec(lo, mid)
            local right = rec(mid + 1, hi)
            return string.format(
                "%s=(%d)while %s<=%s do %s=%s-%s %s break;end while(%s)/(%s)==%d do %s break;end;",
                fvar, prod, rvar, util.msexpr(midk), fvar, fvar, fvar, left,
                fvar, util.msexpr(p), q, right
            )
        end
    end

    return rec(1, #nodes)
end

return util
