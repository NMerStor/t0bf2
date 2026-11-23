local util = require("util")
local parser = {}

local function getspecs51()
    local modes = {
        [0] = 0,  [1] = 1,  [2] = 0,  [3] = 0,
        [4] = 0,  [5] = 1,  [6] = 0,  [7] = 1,
        [8] = 0,  [9] = 0,  [10] = 0, [11] = 0,
        [12] = 0, [13] = 0, [14] = 0, [15] = 0,
        [16] = 0, [17] = 0, [18] = 0, [19] = 0,
        [20] = 0, [21] = 0, [22] = 2, [23] = 0,
        [24] = 0, [25] = 0, [26] = 0, [27] = 0,
        [28] = 0, [29] = 0, [30] = 0, [31] = 2,
        [32] = 2, [33] = 0, [34] = 0, [35] = 0,
        [36] = 1, [37] = 0
    }
    local rkb = {
        [9] = true, [12] = true, [13] = true, [14] = true,
        [15] = true, [16] = true, [17] = true, [23] = true,
        [24] = true, [25] = true
    }
    local rkc = {
        [6] = true, [9] = true, [11] = true, [12] = true,
        [13] = true, [14] = true, [15] = true, [16] = true,
        [17] = true, [23] = true, [24] = true, [25] = true
    }
    return modes, rkb, rkc
end

local function parse51(raw)
    local pos = 5
    local opmodes, rkb, rkc = getspecs51()

    local function rbyte()
        local b = raw:byte(pos)
        pos = pos + 1
        return b
    end

    local function rle(w)
        local v = 0
        local m = 1
        for _ = 1, w do
            v = v + rbyte() * m
            m = m * 256
        end
        return v
    end

    local function rbe(w)
        local v = 0
        for _ = 1, w do
            v = v * 256 + rbyte()
        end
        return v
    end

    local ver = rbyte()
    local fmt = rbyte()
    local le = (rbyte() == 1)
    local intw = rbyte()
    local sizetw = rbyte()
    local instw = rbyte()
    local numw = rbyte()
    local isint = (rbyte() ~= 0)

    assert(ver == 81 and fmt == 0 and not isint, "bad 5.1 header")

    local ruint = le and rle or rbe

    local function rint()
        return ruint(intw)
    end

    local function rsizet()
        return ruint(sizetw)
    end

    local function rnum()
        local lo = ruint(numw / 2)
        local hi = ruint(numw / 2)
        if not le then
            lo, hi = hi, lo
        end
        if lo == 0 and hi == 0 then
            return 0
        end
        local s = (util.extract(hi, 31, 1) == 1) and -1 or 1
        local e = util.extract(hi, 20, 11)
        local f = util.extract(hi, 0, 20) * 4294967296 + lo
        if e == 0 then
            return s * (2 ^ -1022) * (f / (2 ^ 52))
        elseif e == 2047 then
            return (f == 0) and (s * math.huge) or (0 / 0)
        end
        return s * (2 ^ (e - 1023)) * (f / (2 ^ 52) + 1)
    end

    local function rstr()
        local len = rsizet()
        if len == 0 then
            return ""
        end
        local s = raw:sub(pos, pos + len - 2)
        pos = pos + len
        return s
    end

    local halfbx = (2 ^ 17) - 1
    local rkbit = 2 ^ 8

    local function rproto()
        rstr()
        local linedef = rint()
        local lastline = rint()
        local nups = rbyte()
        local nparams = rbyte()
        local vflag = rbyte()
        local maxstk = rbyte()

        local ncode = rint()
        local code = {}
        for i = 1, ncode do
            local w = ruint(instw)
            local op = util.extract(w, 0, 6)
            local a = util.extract(w, 6, 8)
            local mode = opmodes[op]
            local ins = {
                op = op,
                mode = mode,
                a = a,
                b = 0,
                c = 0,
                bx = 0,
                sbx = 0,
                bIsConst = false,
                cIsConst = false
            }
            if mode == 0 then
                local c = util.extract(w, 14, 9)
                local b = util.extract(w, 23, 9)
                ins.b = b
                ins.c = c
                ins.bIsConst = rkb[op] and (b >= rkbit) or false
                ins.cIsConst = rkc[op] and (c >= rkbit) or false
                if ins.bIsConst then
                    ins.bConstIdx = b - rkbit
                end
                if ins.cIsConst then
                    ins.cConstIdx = c - rkbit
                end
            elseif mode == 1 then
                ins.bx = util.extract(w, 14, 18)
            elseif mode == 2 then
                ins.sbx = util.extract(w, 14, 18) - halfbx
            end
            code[i] = ins
        end

        local nk = rint()
        local consts = {}
        for i = 1, nk do
            local t = rbyte()
            local k = { tag = t }
            if t == 1 then
                k.value = (rbyte() ~= 0)
            elseif t == 3 then
                k.value = rnum()
            elseif t == 4 then
                k.value = rstr()
            end
            consts[i] = k
        end

        local np = rint()
        local protos = {}
        for i = 1, np do
            protos[i] = rproto()
        end

        local idx = 1
        while idx <= ncode do
            local ins = code[idx]
            if ins.op == 5 then
                ins.mode = 0
                ins.b = 255
                ins.c = ins.bx
                ins.cIsConst = true
                ins.cConstIdx = ins.bx
            elseif ins.op == 7 then
                local vreg = ins.a
                local kc = ins.bx
                ins.mode = 0
                ins.a = 255
                ins.b = kc
                ins.bIsConst = true
                ins.bConstIdx = kc
                ins.c = vreg
                ins.cIsConst = false
            elseif ins.op == 33 then
                ins.b = 0
            elseif ins.op == 34 then
                if ins.c == 0 then
                    idx = idx + 1
                    local ex = code[idx]
                    ins.c = (ex.op - 1) * 50
                    ex.op = 35
                    ex.mode = 0
                    ex.a = 0
                    ex.b = 1
                    ex.c = 0
                else
                    ins.c = (ins.c - 1) * 50
                end
            elseif ins.op == 36 then
                local sub = protos[ins.bx + 1]
                sub.upvals = {}
                for u = 1, sub.upvalCount do
                    local ps = code[idx + u]
                    sub.upvals[u] = {
                        instack = (ps.op == 0) and 1 or 0,
                        idx = ps.b
                    }
                    ps.op = 35
                    ps.mode = 0
                    ps.a = 0
                    ps.b = 1
                    ps.c = 0
                end
                idx = idx + sub.upvalCount
            end
            idx = idx + 1
        end

        local nline = rint()
        local lines = {}
        for i = 1, nline do
            lines[i] = rint()
        end

        local nloc = rint()
        for _ = 1, nloc do
            rstr()
            rint()
            rint()
        end

        local nupnames = rint()
        for _ = 1, nupnames do
            rstr()
        end

        return {
            linedef = linedef,
            lastline = lastline,
            upvalCount = nups,
            upvals = {},
            paramCount = nparams,
            varargFlag = vflag,
            maxStackSize = maxstk,
            code = code,
            lines = lines,
            constants = consts,
            protos = protos
        }
    end

    return rproto()
end

local function parse54(raw)
    local pos = 5

    local function rbyte()
        local b = raw:byte(pos)
        pos = pos + 1
        return b
    end

    local ver = rbyte()
    local fmt = rbyte()
    assert(ver == 84 and fmt == 0, "bad 5.4 header")

    pos = pos + 6
    local instw = rbyte()
    local intw = rbyte()
    local numw = rbyte()
    pos = pos + intw + numw
    rbyte()

    local function rvarint()
        local v = 0
        repeat
            local b = rbyte()
            v = v * 128 + (b % 128)
        until b >= 128
        return v
    end

    local function ru32()
        local b1, b2, b3, b4 = raw:byte(pos, pos + 3)
        pos = pos + 4
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end

    local function ri64()
        local lo = ru32()
        local hi = ru32()
        if hi >= 2147483648 then
            return (hi - 4294967296) * 4294967296 + lo
        end
        return hi * 4294967296 + lo
    end

    local function rdbl()
        if string.unpack then
            local v = string.unpack("<d", raw, pos)
            pos = pos + numw
            return v
        end
        local lo = ru32()
        local hi = ru32()
        if lo == 0 and hi == 0 then
            return 0
        end
        local s = (util.extract(hi, 31, 1) == 1) and -1 or 1
        local e = util.extract(hi, 20, 11)
        local f = util.extract(hi, 0, 20) * 4294967296 + lo
        if e == 0 then
            return s * (2 ^ -1022) * (f / (2 ^ 52))
        elseif e == 2047 then
            return (f == 0) and (s * math.huge) or (0 / 0)
        end
        return s * (2 ^ (e - 1023)) * (f / (2 ^ 52) + 1)
    end

    local function rstr()
        local sz = rvarint()
        if sz == 0 then
            return ""
        end
        local s = raw:sub(pos, pos + sz - 2)
        pos = pos + sz - 1
        return s
    end

    local function unpackinst(w)
        local op = w % 128
        local a = math.floor(w / 128) % 256
        local k = math.floor(w / 32768) % 2
        local b = math.floor(w / 65536) % 256
        local c = math.floor(w / 16777216) % 256
        local bx = math.floor(w / 32768)
        local ax = math.floor(w / 128)
        return {
            op = op, a = a, k = k, b = b, c = c,
            sb = b - 127, sc = c - 127,
            bx = bx, sbx = bx - 65535,
            ax = ax, sj = ax - 16777215
        }
    end

    local function rproto()
        rstr()
        local linedef = rvarint()
        local lastline = rvarint()
        local nparams = rbyte()
        local vflag = rbyte()
        local maxstk = rbyte()

        local ncode = rvarint()
        local words = {}
        for i = 1, ncode do
            words[i] = ru32()
        end

        local nk = rvarint()
        local consts = {}
        local kmap = {}

        local function addk(tag, val)
            local key = tostring(tag) .. ":" .. tostring(val)
            if kmap[key] then
                return kmap[key]
            end
            local idx = #consts + 1
            consts[idx] = { tag = tag, value = val }
            kmap[key] = idx - 1
            return idx - 1
        end

        for i = 1, nk do
            local t = rbyte()
            if t == 0 then
                consts[i] = { tag = 0 }
            elseif t == 1 then
                consts[i] = { tag = 1, value = false }
            elseif t == 17 then
                consts[i] = { tag = 1, value = true }
            elseif t == 3 then
                consts[i] = { tag = 3, value = ri64() }
            elseif t == 19 then
                consts[i] = { tag = 3, value = rdbl() }
            elseif t == 4 or t == 20 then
                consts[i] = { tag = 4, value = rstr() }
            else
                error("unknown const tag " .. tostring(t))
            end
            if consts[i].value ~= nil then
                kmap[tostring(consts[i].tag) .. ":" .. tostring(consts[i].value)] = i - 1
            end
        end

        local nups = rvarint()
        local upvals = {}
        for i = 1, nups do
            upvals[i] = { instack = rbyte(), idx = rbyte(), kind = rbyte() }
        end

        local np = rvarint()
        local protos = {}
        for i = 1, np do
            protos[i] = rproto()
        end

        local nline = rvarint()
        local ldeltas = {}
        for i = 1, nline do
            local d = rbyte()
            if d >= 128 then
                d = d - 256
            end
            ldeltas[i] = d
        end

        local nabsl = rvarint()
        local absl = {}
        for _ = 1, nabsl do
            local pc = rvarint()
            local ln = rvarint()
            absl[pc] = ln
        end

        local lines = {}
        local curline = linedef
        for i = 1, ncode do
            if absl[i - 1] then
                curline = absl[i - 1]
            end
            if ldeltas[i] then
                curline = curline + ldeltas[i]
            end
            lines[i] = curline > 0 and curline or 1
        end

        local nloc = rvarint()
        for _ = 1, nloc do
            rstr()
            rvarint()
            rvarint()
        end

        local nupn = rvarint()
        for _ = 1, nupn do
            rstr()
        end

        local code = {}
        for i = 1, ncode do
            local f = unpackinst(words[i])
            local op = f.op
            local ins = {
                op = 35, mode = 0, a = 0, b = 1, c = 0, bx = 0, sbx = 0,
                bIsConst = false, cIsConst = false
            }

            if op == 0 then
                ins.op = 0; ins.a = f.a; ins.b = f.b
            elseif op == 1 then
                ins.op = 1; ins.mode = 1; ins.a = f.a; ins.bx = addk(3, f.sbx)
            elseif op == 2 then
                ins.op = 1; ins.mode = 1; ins.a = f.a; ins.bx = addk(3, f.sbx * 1.0)
            elseif op == 3 then
                ins.op = 1; ins.mode = 1; ins.a = f.a; ins.bx = f.bx
            elseif op == 4 then
                local nf = unpackinst(words[i + 1])
                ins.op = 1; ins.mode = 1; ins.a = f.a; ins.bx = nf.ax
            elseif op == 5 then
                ins.op = 2; ins.a = f.a; ins.b = 0; ins.c = 0
            elseif op == 6 then
                ins.op = 2; ins.a = f.a; ins.b = 0; ins.c = 1
            elseif op == 7 then
                ins.op = 2; ins.a = f.a; ins.b = 1; ins.c = 0
            elseif op == 8 then
                ins.op = 3; ins.a = f.a; ins.b = f.a + f.b
            elseif op == 9 then
                ins.op = 4; ins.a = f.a; ins.b = f.b
            elseif op == 10 then
                ins.op = 8; ins.a = f.a; ins.b = f.b
            elseif op == 11 then
                ins.op = 5; ins.a = f.a; ins.b = f.b; ins.c = f.c
                ins.cIsConst = true; ins.cConstIdx = f.c
            elseif op == 12 then
                ins.op = 6; ins.a = f.a; ins.b = f.b; ins.c = f.c
            elseif op == 13 then
                local ki = addk(3, f.c)
                ins.op = 6; ins.a = f.a; ins.b = f.b; ins.c = ki
                ins.cIsConst = true; ins.cConstIdx = ki
            elseif op == 14 then
                ins.op = 6; ins.a = f.a; ins.b = f.b; ins.c = f.c
                ins.cIsConst = true; ins.cConstIdx = f.c
            elseif op == 15 then
                ins.op = 7; ins.a = f.a; ins.b = f.b
                ins.bIsConst = true; ins.bConstIdx = f.b
                ins.c = f.c
                if f.k == 1 then ins.cIsConst = true; ins.cConstIdx = f.c end
            elseif op == 16 then
                ins.op = 9; ins.a = f.a; ins.b = f.b; ins.c = f.c
                if f.k == 1 then ins.cIsConst = true; ins.cConstIdx = f.c end
            elseif op == 17 then
                local ki = addk(3, f.b)
                ins.op = 9; ins.a = f.a; ins.b = ki
                ins.bIsConst = true; ins.bConstIdx = ki
                ins.c = f.c
                if f.k == 1 then ins.cIsConst = true; ins.cConstIdx = f.c end
            elseif op == 18 then
                ins.op = 9; ins.a = f.a; ins.b = f.b
                ins.bIsConst = true; ins.bConstIdx = f.b
                ins.c = f.c
                if f.k == 1 then ins.cIsConst = true; ins.cConstIdx = f.c end
            elseif op == 19 then
                ins.op = 10; ins.a = f.a
            elseif op == 20 then
                ins.op = 11; ins.a = f.a; ins.b = f.b; ins.c = f.c
                if f.k == 1 then ins.cIsConst = true; ins.cConstIdx = f.c end
            elseif op == 21 then
                local ki = addk(3, f.sc)
                ins.op = 12; ins.a = f.a; ins.b = f.b; ins.c = ki
                ins.cIsConst = true; ins.cConstIdx = ki
            elseif op >= 22 and op <= 27 then
                local mk = { [22] = 12, [23] = 13, [24] = 14, [25] = 16, [26] = 17, [27] = 15 }
                ins.op = mk[op]; ins.a = f.a; ins.b = f.b; ins.c = f.c
                ins.cIsConst = true; ins.cConstIdx = f.c
            elseif op == 28 then
                ins.op = 38; ins.a = f.a; ins.b = f.b; ins.c = f.c
                ins.cIsConst = true; ins.cConstIdx = f.c
            elseif op >= 29 and op <= 31 then
                local mb = { [29] = 39, [30] = 40, [31] = 41 }
                ins.op = mb[op]; ins.a = f.a; ins.b = f.b; ins.c = f.c
                ins.cIsConst = true; ins.cConstIdx = f.c
            elseif op == 32 then
                local ki = addk(3, f.sc)
                ins.op = 43; ins.a = f.a; ins.b = f.b; ins.c = ki
                ins.cIsConst = true; ins.cConstIdx = ki
            elseif op == 33 then
                local ki = addk(3, f.sc)
                ins.op = 42; ins.a = f.a; ins.b = f.b; ins.c = ki
                ins.cIsConst = true; ins.cConstIdx = ki
            elseif op >= 34 and op <= 39 then
                local mr = { [34] = 12, [35] = 13, [36] = 14, [37] = 16, [38] = 17, [39] = 15 }
                ins.op = mr[op]; ins.a = f.a; ins.b = f.b; ins.c = f.c
            elseif op >= 40 and op <= 45 then
                local mb = { [40] = 38, [41] = 39, [42] = 40, [43] = 41, [44] = 42, [45] = 43 }
                ins.op = mb[op]; ins.a = f.a; ins.b = f.b; ins.c = f.c
            elseif op == 49 then
                ins.op = 18; ins.a = f.a; ins.b = f.b
            elseif op == 50 then
                ins.op = 44; ins.a = f.a; ins.b = f.b
            elseif op == 51 then
                ins.op = 19; ins.a = f.a; ins.b = f.b
            elseif op == 52 then
                ins.op = 20; ins.a = f.a; ins.b = f.b
            elseif op == 53 then
                ins.op = 21; ins.a = f.a; ins.b = f.a; ins.c = f.a + f.b - 1
            elseif op == 54 then
                ins.op = 35; ins.a = f.a; ins.b = 0
            elseif op == 56 then
                ins.op = 22; ins.mode = 2; ins.a = 0; ins.sbx = f.sj
            elseif op >= 57 and op <= 59 then
                local mc = { [57] = 23, [58] = 24, [59] = 25 }
                ins.op = mc[op]; ins.a = f.k; ins.b = f.a; ins.c = f.b
            elseif op == 60 then
                ins.op = 23; ins.a = f.k; ins.b = f.a; ins.c = f.b
                ins.cIsConst = true; ins.cConstIdx = f.b
            elseif op >= 61 and op <= 63 then
                local mc = { [61] = 23, [62] = 24, [63] = 25 }
                local ki = addk(3, f.sb)
                ins.op = mc[op]; ins.a = f.k; ins.b = f.a; ins.c = ki
                ins.cIsConst = true; ins.cConstIdx = ki
            elseif op == 64 then
                local ki = addk(3, f.sb)
                ins.op = 24; ins.a = f.k; ins.b = ki
                ins.bIsConst = true; ins.bConstIdx = ki; ins.c = f.a
            elseif op == 65 then
                local ki = addk(3, f.sb)
                ins.op = 25; ins.a = f.k; ins.b = ki
                ins.bIsConst = true; ins.bConstIdx = ki; ins.c = f.a
            elseif op == 66 then
                ins.op = 26; ins.a = f.a; ins.c = f.k
            elseif op == 67 then
                ins.op = 27; ins.a = f.a; ins.b = f.b; ins.c = f.k
            elseif op == 68 then
                ins.op = 28; ins.a = f.a; ins.b = f.b; ins.c = f.c
            elseif op == 69 then
                ins.op = 29; ins.a = f.a; ins.b = f.b; ins.c = 0
            elseif op == 70 then
                ins.op = 30; ins.a = f.a; ins.b = f.b; ins.c = 0
            elseif op == 71 then
                ins.op = 30; ins.a = 0; ins.b = 1; ins.c = 0
            elseif op == 72 then
                ins.op = 30; ins.a = f.a; ins.b = 2; ins.c = 0
            elseif op == 73 then
                ins.op = 31; ins.mode = 2; ins.a = f.a; ins.sbx = -f.bx
            elseif op == 74 then
                ins.op = 32; ins.mode = 2; ins.a = f.a; ins.sbx = f.bx
            elseif op == 75 then
                ins.op = 22; ins.mode = 2; ins.a = 0; ins.sbx = f.bx
            elseif op == 76 then
                ins.op = 33; ins.a = f.a; ins.b = 1; ins.c = f.c
            elseif op == 77 then
                ins.op = 22; ins.mode = 2; ins.a = 0; ins.sbx = -f.bx
            elseif op == 78 then
                local rc = f.c
                if f.k == 1 then
                    local nf = unpackinst(words[i + 1])
                    rc = rc + nf.ax * 256
                end
                ins.op = 34; ins.a = f.a; ins.b = f.b; ins.c = rc
            elseif op == 79 then
                ins.op = 36; ins.mode = 1; ins.a = f.a; ins.bx = f.bx
            elseif op == 80 then
                ins.op = 37; ins.a = f.a; ins.b = f.c; ins.c = 0
            end

            code[i] = ins
        end

        return {
            linedef = linedef,
            lastline = lastline,
            upvalCount = nups,
            upvals = upvals,
            paramCount = nparams,
            varargFlag = vflag,
            maxStackSize = maxstk,
            code = code,
            lines = lines,
            constants = consts,
            protos = protos
        }
    end

    return rproto()
end

function parser.getchunk(dump)
    assert(dump:byte(1) == 27 and dump:sub(2, 4) == "Lua", "not a lua chunk")
    local v = dump:byte(5)
    if v == 81 then
        return parse51(dump)
    elseif v == 84 then
        return parse54(dump)
    else
        error("unsupported lua version: " .. tostring(v))
    end
end

return parser
