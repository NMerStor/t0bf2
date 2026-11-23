--
-- luauc/remap.lua
--
-- Per-build opcode remapping. Luau bytecode stores opcodes as their canonical
-- enum values (LOADK=5, CALL=21, ...). That means anyone who extracts the
-- instruction stream can decode it with the public Luau opcode table. This pass
-- permutes the op byte of every instruction with a random per-build bijection,
-- so standard tooling no longer applies; the interpreter is handed the inverse
-- map (scrambled -> canonical) to dispatch correctly.
--
-- Only the op byte of *instruction* words is rewritten; AUX words (operands)
-- are left intact, so we must walk instruction boundaries using the set of
-- opcodes that carry a following AUX word.

local Remap = {}

-- Opcodes followed by exactly one AUX word (Bytecode.h @ 0.722).
local INSN_AUX = {
    [7] = true, [8] = true, [12] = true, [15] = true, [16] = true, [20] = true,
    [27] = true, [28] = true, [29] = true, [30] = true, [31] = true, [32] = true,
    [53] = true, [55] = true, [58] = true, [60] = true, [66] = true,
    [74] = true, [75] = true, [77] = true, [78] = true, [79] = true, [80] = true,
    [83] = true, [84] = true, [85] = true, [86] = true, [87] = true, [88] = true,
}

local MAXOP = 88

----------------------------------------------------------------------
-- Nonce-derived metadata (data-plane polymorphism, schema S1).
--
-- Instead of storing the opcode inverse-map and the encryption keys as standalone
-- container fields (bc[3]/bc[4]/bc[5]), schema S1 stores only a single nonce N and
-- DERIVES all three from it at runtime. The interpreter rebuilds the same values
-- with byte-identical code (emitted by interpgen) so the two stay in lockstep.
--
-- Both sides MUST use this exact integer math (portable across Lua 5.1 and Luau,
-- all within 2^53). The minimal-standard 16807 LCG is the one already used
-- elsewhere in the codebase. KEEP IN SYNC with the wrapper emitted by interpgen.
----------------------------------------------------------------------

-- Forward permutation ids[i+1] = scrambled opcode for canonical opcode i.
function Remap.derivePerm(N)
    local s = N % 2147483647
    if s == 0 then s = 1 end
    local ids = {}
    for i = 0, MAXOP do ids[i + 1] = i end
    for i = MAXOP + 1, 2, -1 do
        s = (s * 16807) % 2147483647
        local j = (s % i) + 1
        ids[i], ids[j] = ids[j], ids[i]
    end
    return ids
end

-- Position-cipher keys derived from N (distinct LCG seeding from derivePerm).
function Remap.deriveKeys(N)
    local t = (N * 16807 + 1) % 2147483647
    t = (t * 16807) % 2147483647; local hi = t % 65536
    t = (t * 16807) % 2147483647; local lo = t % 65536
    t = (t * 16807) % 2147483647; local bstep = (t % 65535) * 2 + 1
    return hi * 65536 + lo, bstep
end

-- Rewrite opcode bytes using a precomputed forward permutation (ids from
-- derivePerm). Unlike Remap.apply, this stores NO inverse map on bc -- the
-- interpreter rebuilds it from the nonce.
function Remap.applyWithPerm(bc, ids)
    for _, p in ipairs(bc.protos) do
        local code = p.code
        local i = 1
        while i <= #code do
            local wd = code[i]
            local op = wd % 256
            code[i] = ids[op + 1] + (wd - op)
            if INSN_AUX[op] then i = i + 2 else i = i + 1 end
        end
    end
    return bc
end

-- Encrypt with precomputed keys; stores NO bkey/bstep on bc.
function Remap.encryptCodeWithKeys(bc, bkey, bstep)
    for _, p in ipairs(bc.protos) do
        local code = p.code
        -- Running accumulator: key starts at bkey+bstep (i=1) and increments by
        -- bstep each step, replacing the i*bstep multiply with a single addition.
        local key = bkey + bstep
        for i = 1, #code do
            code[i] = (code[i] + key) % 4294967296
            key = key + bstep
        end
    end
    return bc
end

function Remap.apply(bc)
    -- Random bijection perm[canonical] = scrambled over 0..MAXOP.
    local ids = {}
    for i = 0, MAXOP do ids[#ids + 1] = i end
    for i = #ids, 2, -1 do
        local j = math.random(1, i)
        ids[i], ids[j] = ids[j], ids[i]
    end
    local perm = {}
    for i = 0, MAXOP do perm[i] = ids[i + 1] end

    -- Rewrite each proto's instruction op bytes, skipping AUX words.
    for _, p in ipairs(bc.protos) do
        local code = p.code
        local i = 1
        while i <= #code do
            local wd = code[i]
            local op = wd % 256
            code[i] = perm[op] + (wd - op)
            if INSN_AUX[op] then i = i + 2 else i = i + 1 end
        end
    end

    -- Inverse map for the interpreter: scrambled -> canonical.
    local inv = {}
    for c = 0, MAXOP do inv[perm[c]] = c end
    bc.opmap = inv
    return bc
end

local TWO32 = 4294967296

-- Encrypt every instruction word (and AUX words) with a position-dependent
-- additive key: enc[i] = (word + (bkey + i*bstep)) mod 2^32. Reversible with
-- plain arithmetic on both ends (no bit lib needed). After this, the emitted
-- code arrays are opaque numbers -- the instruction stream and operands no
-- longer read as anything; the interpreter recovers each word on first use.
function Remap.encryptCode(bc)
    -- Build a full-width key from 16-bit randoms (avoids lua5.1 int-cast limits).
    local bkey = math.random(0, 65535) * 65536 + math.random(0, 65535)
    local bstep = math.random(1, 65535) * 2 + 1 -- odd, nonzero
    for _, p in ipairs(bc.protos) do
        local code = p.code
        local key = bkey + bstep
        for i = 1, #code do
            code[i] = (code[i] + key) % TWO32
            key = key + bstep
        end
    end
    bc.bkey = bkey
    bc.bstep = bstep
    return bc
end

return Remap
