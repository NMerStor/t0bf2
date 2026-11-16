local util = require("util")
local encoder = {}

local rk4ops = {
    [9]  = true,
    [12] = true, [13] = true, [14] = true, [15] = true, [16] = true, [17] = true,
    [23] = true, [24] = true, [25] = true,
    [38] = true, [39] = true, [40] = true, [41] = true, [42] = true, [43] = true
}

local rk2cops = {
    [6]  = true,
    [7]  = true,
    [11] = true
}

function encoder.buildvopmap()
    local list = {}
    for op = 0, 44 do
        if rk4ops[op] then
            list[#list + 1] = { op = op, bc = false, cc = false, id = op .. "_RR" }
            list[#list + 1] = { op = op, bc = false, cc = true,  id = op .. "_RK" }
            list[#list + 1] = { op = op, bc = true,  cc = false, id = op .. "_KR" }
            list[#list + 1] = { op = op, bc = true,  cc = true,  id = op .. "_KK" }
        elseif rk2cops[op] then
            list[#list + 1] = { op = op, bc = (op == 7), cc = false, id = op .. "_R" }
            list[#list + 1] = { op = op, bc = (op == 7), cc = true,  id = op .. "_K" }
        else
            list[#list + 1] = { op = op, bc = (op == 1), cc = (op == 5), id = tostring(op) }
        end
    end
    return list
end

local function encodemoonsec(bytes, alphabet)
    local out = { "..:::MoonSec::..", alphabet }
    for i = 1, #bytes do
        local b = bytes[i]
        local hi = math.floor(b / 16) + 1
        local lo = (b % 16) + 1
        out[#out + 1] = alphabet:sub(hi, hi) .. alphabet:sub(lo, lo)
    end
    return table.concat(out)
end

function encoder.encode(root, cfg)
    local stream = {}
    local lstate = cfg.initKey
    local rstep = cfg.stepKey

    local function wraw(b)
        local plain = math.floor(b) % 256
        local enc = (plain - lstate) % 256
        lstate = (lstate + rstep) % 256
        stream[#stream + 1] = enc
    end

    local function wbyte(b)
        wraw(b)
    end

    local function wu16(v)
        local bytes = util.packu16(v)
        wraw(bytes[1])
        wraw(bytes[2])
    end

    local function wu32(v)
        local bytes = util.packu32(v)
        wraw(bytes[1])
        wraw(bytes[2])
        wraw(bytes[3])
        wraw(bytes[4])
    end

    local function wdbl(v)
        local bytes = util.packdbl(v)
        for i = 1, 8 do
            wraw(bytes[i])
        end
    end

    local function wstr(s)
        wu32(#s)
        local skey = 1
        for i = 1, #s do
            skey = (skey + cfg.strStep) % 256
            local pre = (s:byte(i) - skey) % 256
            wraw(pre)
        end
    end

    local function getvopkey(ins)
        local op = ins.op
        if rk4ops[op] then
            local s1 = ins.bIsConst and "K" or "R"
            local s2 = ins.cIsConst and "K" or "R"
            return op .. "_" .. s1 .. s2
        elseif rk2cops[op] then
            local s2 = ins.cIsConst and "K" or "R"
            return op .. "_" .. s2
        else
            return tostring(op)
        end
    end

    local function wproto(p)
        wu32(#p.protos)
        for i = 1, #p.protos do
            wproto(p.protos[i])
        end

        wu32(#p.constants)
        for i = 1, #p.constants do
            local k = p.constants[i]
            local mult = math.random(0, 4) * cfg.tagMod
            if k.tag == 0 then
                wbyte(cfg.tagNil + mult)
            elseif k.tag == 1 then
                wbyte(cfg.tagBool + mult)
                wbyte(k.value and 1 or 0)
            elseif k.tag == 3 then
                wbyte(cfg.tagNum + mult)
                wdbl(k.value)
            elseif k.tag == 4 then
                wbyte(cfg.tagStr + mult)
                wstr(k.value)
            end
        end

        wu32(#p.code)
        for pc = 1, #p.code do
            local ins = p.code[pc]
            local vkey = getvopkey(ins)
            local vop = cfg.opEncode[vkey]
            local bmode = 0
            local kmask = 0

            if ins.op == 1 then
                bmode = 1
                kmask = 2
            elseif ins.op == 36 then
                bmode = 1
                kmask = 0
            elseif ins.mode == 2 then
                bmode = 2
                kmask = 0
            else
                bmode = 0
                if ins.bIsConst then
                    kmask = kmask + 2
                end
                if ins.cIsConst then
                    kmask = kmask + 4
                end
            end

            local desc = bmode * 2 + kmask * 8
            wbyte(desc)
            wu16(vop)
            wu16(ins.a)

            if bmode == 0 then
                local vb = ins.bIsConst and (ins.bConstIdx + 1) or ins.b
                local vc = ins.cIsConst and (ins.cConstIdx + 1) or ins.c
                wu16(vb)
                wu16(vc)
            elseif bmode == 1 then
                local vbx = (ins.op == 1) and (ins.bx + 1) or ins.bx
                wu32(vbx)
            elseif bmode == 2 then
                local target = pc + ins.sbx
                wu32(target + 65536)
            end
        end

        local uvs = p.upvals or {}
        wbyte(#uvs)
        for i = 1, #uvs do
            wbyte(uvs[i].instack)
            wu16(uvs[i].idx)
        end

        wbyte(p.paramCount)
    end

    wproto(root)
    return encodemoonsec(stream, cfg.alphabet)
end

return encoder
