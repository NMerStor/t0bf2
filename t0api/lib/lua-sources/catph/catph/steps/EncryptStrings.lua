
local Step = require("catph.step")
local Ast = require("catph.ast")
local Scope = require("catph.scope")
local RandomStrings = require("catph.randomStrings")
local Parser = require("catph.parser")
local Enums = require("catph.enums")
local logger = require("logger")
local visitast = require("catph.visitast");
local util     = require("catph.util")
local AstKind = Ast.AstKind;

local EncryptStrings = Step:extend()
EncryptStrings.Description = "This Step will encrypt strings within your Program."
EncryptStrings.Name = "Encrypt Strings"

EncryptStrings.SettingsDescriptor = {
    EncryptNumbers = {
        name = "EncryptNumbers",
        description = "Also encrypt number literals as strings, decoded at runtime with tonumber(). Much harder to reverse than math expressions.",
        type = "boolean",
        default = true,
    },
}

function EncryptStrings:init(settings) end


function EncryptStrings:CreateEncrypionService()
    local usedSeeds = {};

    local secret_key_6 = math.random(0, 63) -- 6-bit  arbitrary integer (0..63)
    local secret_key_7 = math.random(0, 127) -- 7-bit  arbitrary integer (0..127)
    local secret_key_44 = math.random(0, 17592186044415) -- 44-bit arbitrary integer (0..17592186044415)
    local secret_key_8 = math.random(0, 255); -- 8-bit  arbitrary integer (0..255)

    -- Anti-oracle additions. The visible seed at each call site is offset by a
    -- per-build constant, and every string carries a per-string salt that seeds
    -- the rolling prevVal. Because prevVal chains through the whole byte stream,
    -- a wrong/absent salt corrupts the entire result -- so DECRYPT(str, seed) on
    -- its own (the classic 2-arg "dump every string" oracle) yields garbage.
    local seed_offset = math.random(1, 2 ^ 20);

    -- Environment-coupled key component (#2). _envk is recomputed at runtime
    -- from Roblox engine constructors (Vector3 / Vector2 / UDim) whose component
    -- values are fully deterministic. In a bare Lua sandbox these globals are
    -- absent, so the runtime _envk differs (or the chunk errors) and DECRYPT
    -- yields garbage -- this defeats offline string-dumping even by a manual
    -- attacker who extracts DECRYPT and calls it outside Roblox.
    local env_const = 0;
    local env_expr;
    do
        local builders = {
            function() local n = math.random(1, 60); return n, "Vector3.new(" .. n .. ",0,0).X" end,
            function() local n = math.random(1, 60); return n, "Vector3.new(0," .. n .. ",0).Y" end,
            function() local n = math.random(1, 60); return n, "Vector3.new(0,0," .. n .. ").Z" end,
            function() local n = math.random(1, 60); return n, "Vector2.new(" .. n .. ",0).X" end,
            function() local n = math.random(1, 60); return n, "Vector2.new(0," .. n .. ").Y" end,
            function() local n = math.random(1, 60); return n, "UDim.new(" .. n .. ",0).Scale" end,
        };
        local terms = {};
        for i = 1, math.random(2, 3) do
            local val, expr = builders[math.random(1, #builders)]();
            env_const = (env_const + val) % 256;
            terms[#terms + 1] = expr;
        end
        env_expr = table.concat(terms, " + ");
    end

    -- Per-build pre-LCG additive layer. A random seed string is embedded in
    -- the output; at runtime a small hash loop reconstructs an N-byte rolling
    -- key from it. Encryption applies (byte + key[i mod N]) % 256 BEFORE the
    -- LCG step, and DECRYPT subtracts the same after. An attacker who calls
    -- DECRYPT directly without running the hash-loop init sees garbage: the
    -- function depends on a local (_xk) populated by other code in the
    -- chunk, so the "precondition" of running the init is coupled to
    -- decryption working at all.
    local XK_LEN = 8;
    local extra_seed_bytes = {};
    -- Entropy reduced from 16-32 to 4-8 bytes; compute_xk still expands this
    -- into XK_LEN key bytes, so security of the rolling key is unchanged while
    -- the embedded literal shrinks substantially.
    for i = 1, math.random(4, 8) do
        extra_seed_bytes[i] = math.random(0, 255);
    end
    local extra_seed = string.char(unpack(extra_seed_bytes));

    -- This hash MUST match the runtime loop emitted in genCode below.
    local function compute_xk(seed_str)
        local key = {};
        local state = 17;
        for i = 1, XK_LEN do
            for j = 1, string.len(seed_str) do
                state = (state * 31 + string.byte(seed_str, j) + i * 7) % 65536;
            end
            key[i] = state % 256;
        end
        return key;
    end
    local extra_key = compute_xk(extra_seed);

    -- Escape an arbitrary byte string into a Lua string literal using \NNN.
    -- Still used for the internal extra_seed embedding.
    local function escapeLuaString(s)
        local out = {};
        for i = 1, #s do
            out[i] = string.format("\\%d", string.byte(s, i));
        end
        return '"' .. table.concat(out) .. '"';
    end
    local extra_seed_literal = escapeLuaString(extra_seed);

    -- Base85 encoder for encrypted string payloads.
    -- Same alphabet as CustomVM bytecode payload: printable ASCII, no raw escape bytes.
    local _B85 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@[]^"
    local function encodeB85(s)
        local pad = (4 - #s % 4) % 4
        s = s .. string.rep("\0", pad)
        local out = {}
        local fl = math.floor
        for i = 1, #s, 4 do
            local b1, b2, b3, b4 = string.byte(s, i, i + 3)
            local v = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
            local c5 = v % 85; v = fl((v - c5) / 85)
            local c4 = v % 85; v = fl((v - c4) / 85)
            local c3 = v % 85; v = fl((v - c3) / 85)
            local c2 = v % 85; v = fl((v - c2) / 85)
            local c1 = v % 85
            out[#out + 1] = _B85:sub(c1+1,c1+1).._B85:sub(c2+1,c2+1).._B85:sub(c3+1,c3+1).._B85:sub(c4+1,c4+1).._B85:sub(c5+1,c5+1)
        end
        return table.concat(out)
    end

    local floor = math.floor

    local function primitive_root_257(idx)
        local g, m, d = 1, 128, 2 * idx + 1
        repeat
            g, m, d = g * g * (d >= m and 3 or 1) % 257, m / 2, d % m
        until m < 1
        return g
    end

    local param_mul_8 = primitive_root_257(secret_key_7)
    local param_mul_45 = secret_key_6 * 4 + 1
    local param_add_45 = secret_key_44 * 2 + 1

    local state_45 = 0
    local state_8 = 2

    local prev_values = {}
    local function set_seed(seed_53)
        state_45 = seed_53 % 35184372088832
        state_8 = seed_53 % 255 + 2
        prev_values = {}
    end

    local function gen_seed()
        local seed;
        repeat
            seed = math.random(0, 35184372088832);
        until not usedSeeds[seed];
        usedSeeds[seed] = true;
        return seed;
    end

    local function get_random_32()
        state_45 = (state_45 * param_mul_45 + param_add_45) % 35184372088832
        repeat
            state_8 = state_8 * param_mul_8 % 257
        until state_8 ~= 1
        local r = state_8 % 32
        local n = floor(state_45 / 2 ^ (13 - (state_8 - r) / 32)) % 2 ^ 32 / 2 ^ r
        return floor(n % 1 * 2 ^ 32) + floor(n)
    end

    local function get_next_pseudo_random_byte()
        if #prev_values == 0 then
            local rnd = get_random_32() -- value 0..4294967295
            local low_16 = rnd % 65536
            local high_16 = (rnd - low_16) / 65536
            local b1 = low_16 % 256
            local b2 = (low_16 - b1) / 256
            local b3 = high_16 % 256
            local b4 = (high_16 - b3) / 256
            prev_values = { b1, b2, b3, b4 }
        end
        --print(unpack(prev_values))
        return table.remove(prev_values)
    end

    local function encrypt(str)
        local seed = gen_seed();
        set_seed(seed)
        local len = string.len(str)
        local out = {}
        local salt = math.random(0, 255);
        local prevVal = (secret_key_8 + salt + env_const) % 256;
        for i = 1, len do
            -- Pre-LCG additive layer with rolling key. prevVal carries the
            -- post-key byte so decryption can recover the same running state.
            local byte = (string.byte(str, i) + extra_key[((i - 1) % XK_LEN) + 1]) % 256;
            out[i] = string.char((byte - (get_next_pseudo_random_byte() + prevVal)) % 256);
            prevVal = byte;
        end
        -- Return the offset seed (hidden) and the per-string salt.
        return table.concat(out), seed + seed_offset, salt;
    end

    local function genCode()
        -- Single compact set of upvalue aliases. The randomized noise decls and
        -- their shuffle were removed -- they added bytes without changing
        -- behaviour and are trivially constant-folded by any analyst anyway.
        local localDecls = {
            "local f=math.floor;",
            "local rm=table.remove;",
            "local cc=table.concat;",
            "local ch=string.char;",
            "local sb=string.byte;",
            "local sl=string.len;",
            "local _tn=tonumber;",
        };

        -- Single most-compact charmap variant (was 3 variants chosen at random).
        local charmapInit = [[
    local cm={};
    for i=0,255 do cm[i+1]=ch(i) end]];

        -- Single most-compact PRNG byte-split (was 2 variants chosen at random).
        local prngBody = [[
            local b1=rnd%256
            local b2=f(rnd/256)%256
            local b3=f(rnd/65536)%256
            local b4=f(rnd/16777216)%256
            pv={b1,b2,b3,b4}]];

        -- Single most-compact DECRYPT (was 2 variants + 0-2 junk lines each).
        -- Trailing temp-state resets removed: state_45/state_8 are reseeded at
        -- the top of every call, and prevVal/len/str are locals that go out of
        -- scope, so the resets were pure dead weight.
        local decryptBody = [[
    function DECRYPT(str,seed,salt,n,_f)
        str=_db(str,n);
        pv={};
        seed=seed-]] .. tostring(seed_offset) .. [[;
        st45=seed%35184372088832
        st8=seed%255+2
        local r={};
        local p=(]] .. tostring(secret_key_8) .. [[+salt+_ek)%256;
        for i=1,n do
            p=(sb(str,i)+gnb()+p)%256
            r[i]=cm[((p-_xk[((i-1)%]] .. tostring(XK_LEN) .. [[)+1])%256)+1];
        end
        local _s=cc(r);return _f and _tn(_s) or _s;
    end]];

        local code = "do\n\t" .. table.concat(localDecls, "\n\t") .. [[

    local st45=0
    local st8=2
]] .. charmapInit .. [[

    local _b="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@[]^"
    local _bm={}
    for i=1,#_b do _bm[sb(_b,i)]=i-1 end
    local function _db(s,n)
        local t={}
        for i=1,#s,5 do
            local v=(((_bm[sb(s,i)]*85+_bm[sb(s,i+1)])*85+_bm[sb(s,i+2)])*85+_bm[sb(s,i+3)])*85+_bm[sb(s,i+4)]
            t[#t+1]=ch(f(v/16777216)%256)
            t[#t+1]=ch(f(v/65536)%256)
            t[#t+1]=ch(f(v/256)%256)
            t[#t+1]=ch(v%256)
        end
        return string.sub(cc(t),1,n)
    end
    local _xs=]] .. extra_seed_literal .. [[;
    local _xk={};
    do
        local s=17;
        for i=1,]] .. tostring(XK_LEN) .. [[ do
            for j=1,sl(_xs) do
                s=(s*31+sb(_xs,j)+i*7)%65536;
            end
            _xk[i]=s%256;
        end
    end
    _xs=nil;

    local _ek=(]] .. env_expr .. [[)%256;

    local pv={}
    local function gnb()
        if #pv==0 then
            st45=(st45*]] .. tostring(param_mul_45) .. [[+]] .. tostring(param_add_45) .. [[)%35184372088832
            repeat
                st8=st8*]] .. tostring(param_mul_8) .. [[%257
            until st8~=1
            local r=st8%32
            local n=f(st45/2^(13-(st8-r)/32))%2^32/2^r
            local rnd=f(n%1*2^32)+f(n)
]] .. prngBody .. [[

        end
        return rm(pv)
    end

]] .. decryptBody .. [[

end]]

        return code;
    end

    return {
        encrypt = encrypt,
        encodeB85 = encodeB85,
        param_mul_45 = param_mul_45,
        param_mul_8 = param_mul_8,
        param_add_45 = param_add_45,
        secret_key_8 = secret_key_8,
        genCode = genCode,
    }
end

function EncryptStrings:apply(ast, pipeline)
    local Encryptor = self:CreateEncrypionService();

    local code = Encryptor.genCode();
    local newAst = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 }):parse(code);
    local doStat = newAst.body.statements[1];

    local scope = ast.body.scope;
    local decryptVar = scope:addVariable();

    doStat.body.scope:setParent(ast.body.scope);

    visitast(newAst, nil, function(node, data)
        if(node.kind == AstKind.FunctionDeclaration) then
            if(node.scope:getVariableName(node.id) == "DECRYPT") then
                data.scope:removeReferenceToHigherScope(node.scope, node.id);
                data.scope:addReferenceToHigherScope(scope, decryptVar);
                node.scope = scope;
                node.id    = decryptVar;
            end
        end
    end)

    -- tonumber is now aliased as _tn inside the DECRYPT do-block (renamed by the
    -- name generator), so we no longer need a direct reference to the global.

    visitast(ast, nil, function(node, data)
        if(node.kind == AstKind.StringExpression) then
            -- Safety check: ensure this scope can reach the DECRYPT variable
            local canReach = false
            local s = data.scope
            while s do
                if s == scope then canReach = true; break end
                if s.isGlobal then break end
                s = s.parentScope
            end
            if not canReach then return end
            data.scope:addReferenceToHigherScope(scope, decryptVar);
            local encrypted, seed, salt = Encryptor.encrypt(node.value);
            local b85str = Encryptor.encodeB85(encrypted);
            local origLen = #node.value;
            return Ast.FunctionCallExpression(Ast.VariableExpression(scope, decryptVar), {
                Ast.StringExpression(b85str), Ast.NumberExpression(seed), Ast.NumberExpression(salt), Ast.NumberExpression(origLen),
            });
        end
        if self.EncryptNumbers and node.kind == AstKind.NumberExpression then
            local numStr = tostring(node.value);
            if tonumber(numStr) ~= node.value then return end
            local canReach = false
            local s = data.scope
            while s do
                if s == scope then canReach = true; break end
                if s.isGlobal then break end
                s = s.parentScope
            end
            if not canReach then return end
            data.scope:addReferenceToHigherScope(scope, decryptVar);
            local encrypted, seed, salt = Encryptor.encrypt(numStr);
            local b85num = Encryptor.encodeB85(encrypted);
            local numLen = #numStr;
            return Ast.FunctionCallExpression(Ast.VariableExpression(scope, decryptVar), {
                Ast.StringExpression(b85num), Ast.NumberExpression(seed), Ast.NumberExpression(salt), Ast.NumberExpression(numLen),
                Ast.BooleanExpression(true),
            });
        end
    end)


    -- Insert to Main Ast
    table.insert(ast.body.statements, 1, doStat);
    table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(scope, { decryptVar }, {}));
    return ast
end

return EncryptStrings