local util = require("util")
local vmgen = {}

local aAliases = { "M", "B", "p", "m", "P", "O" }
local bAliases = { "n", "d", "H", "a", "F", "L" }
local cAliases = { "w", "u", "t", "x", "s", "U" }

local function pickA()
    return aAliases[math.random(1, #aAliases)]
end

local function pickB()
    return bAliases[math.random(1, #bAliases)]
end

local function pickC()
    return cAliases[math.random(1, #cAliases)]
end

local function buildhandlers()
    local h = {}

    h["0"] = function()
        return string.format("h[o[%s]]=h[o[%s]];", pickA(), pickB())
    end

    h["1"] = function()
        return string.format("h[o[%s]]=o[%s];", pickA(), pickB())
    end

    h["2"] = function()
        return string.format("h[o[%s]]=(o[%s]~=0);if(o[%s]~=0)then l=l+e;end;", pickA(), pickB(), pickC())
    end

    h["3"] = function()
        return string.format("for o=o[%s],o[%s]do h[o]=nil;end;", pickA(), pickB())
    end

    h["4"] = function()
        return string.format("h[o[%s]]=C[o[%s]];", pickA(), pickB())
    end

    h["5"] = function()
        return string.format("local f=(o[%s]==255 and K or C[o[%s]]);h[o[%s]]=f[o[%s]];", pickB(), pickB(), pickA(), pickC())
    end

    h["6_R"] = function()
        return string.format("h[o[%s]]=h[o[%s]][h[o[%s]]];", pickA(), pickB(), pickC())
    end

    h["6_K"] = function()
        return string.format("h[o[%s]]=h[o[%s]][o[%s]];", pickA(), pickB(), pickC())
    end

    h["7_R"] = function()
        return string.format("local f=(o[%s]==255 and K or C[o[%s]]);f[o[%s]]=h[o[%s]];", pickA(), pickA(), pickB(), pickC())
    end

    h["7_K"] = function()
        return string.format("local f=(o[%s]==255 and K or C[o[%s]]);f[o[%s]]=o[%s];", pickA(), pickA(), pickB(), pickC())
    end

    h["8"] = function()
        return string.format("C[o[%s]]=h[o[%s]];", pickB(), pickA())
    end

    h["9_RR"] = function()
        return string.format("h[o[%s]][h[o[%s]]]=h[o[%s]];", pickA(), pickB(), pickC())
    end

    h["9_RK"] = function()
        return string.format("h[o[%s]][h[o[%s]]]=o[%s];", pickA(), pickB(), pickC())
    end

    h["9_KR"] = function()
        return string.format("h[o[%s]][o[%s]]=h[o[%s]];", pickA(), pickB(), pickC())
    end

    h["9_KK"] = function()
        return string.format("h[o[%s]][o[%s]]=o[%s];", pickA(), pickB(), pickC())
    end

    h["10"] = function()
        return string.format("h[o[%s]]={};", pickA())
    end

    h["11_R"] = function()
        return string.format("local f=o[%s];local b=h[o[%s]];h[f+1]=b;h[f]=b[h[o[%s]]];", pickA(), pickB(), pickC())
    end

    h["11_K"] = function()
        return string.format("local f=o[%s];local b=h[o[%s]];h[f+1]=b;h[f]=b[o[%s]];", pickA(), pickB(), pickC())
    end

    local function addbinop(opid, sym)
        h[opid .. "_RR"] = function()
            return string.format("h[o[%s]]=h[o[%s]]%sh[o[%s]];", pickA(), pickB(), sym, pickC())
        end
        h[opid .. "_RK"] = function()
            return string.format("h[o[%s]]=h[o[%s]]%so[%s];", pickA(), pickB(), sym, pickC())
        end
        h[opid .. "_KR"] = function()
            return string.format("h[o[%s]]=o[%s]%sh[o[%s]];", pickA(), pickB(), sym, pickC())
        end
        h[opid .. "_KK"] = function()
            return string.format("h[o[%s]]=o[%s]%so[%s];", pickA(), pickB(), sym, pickC())
        end
    end

    addbinop(12, "+")
    addbinop(13, "-")
    addbinop(14, "*")
    addbinop(15, "/")
    addbinop(16, "%")
    addbinop(17, "^")

    h["18"] = function()
        return string.format("h[o[%s]]=-h[o[%s]];", pickA(), pickB())
    end

    h["19"] = function()
        return string.format("h[o[%s]]=(not h[o[%s]]);", pickA(), pickB())
    end

    h["20"] = function()
        return string.format("h[o[%s]]=#h[o[%s]];", pickA(), pickB())
    end

    h["21"] = function()
        return string.format("local l=o[%s];local f=h[l]for o=l+1,o[%s]do f=f..h[o];end;h[o[%s]]=f;", pickB(), pickC(), pickA())
    end

    h["22"] = function()
        return string.format("l=o[%s];", pickB())
    end

    local function addcmpop(opid, sym)
        h[opid .. "_RR"] = function()
            return string.format("if((h[o[%s]]%sh[o[%s]])~=(o[%s]~=0))then l=l+e;end;", pickB(), sym, pickC(), pickA())
        end
        h[opid .. "_RK"] = function()
            return string.format("if((h[o[%s]]%so[%s])~=(o[%s]~=0))then l=l+e;end;", pickB(), sym, pickC(), pickA())
        end
        h[opid .. "_KR"] = function()
            return string.format("if((o[%s]%sh[o[%s]])~=(o[%s]~=0))then l=l+e;end;", pickB(), sym, pickC(), pickA())
        end
        h[opid .. "_KK"] = function()
            return string.format("if((o[%s]%so[%s])~=(o[%s]~=0))then l=l+e;end;", pickB(), sym, pickC(), pickA())
        end
    end

    addcmpop(23, "==")
    addcmpop(24, "<")
    addcmpop(25, "<=")

    h["26"] = function()
        return string.format("if((not not h[o[%s]])==(o[%s]==0))then l=l+e;end;", pickA(), pickC())
    end

    h["27"] = function()
        return string.format("if((not not h[o[%s]])==(o[%s]==0))then l=l+e;else h[o[%s]]=h[o[%s]];end;", pickB(), pickC(), pickA(), pickB())
    end

    h["28"] = function()
        return string.format(
            "local f=o[%s];local r=o[%s];local k=o[%s];if r~=0 then c=f+r-b;end;local z,v;if r==b then z,v=D(h[f]());else z,v=D(h[f](i(h,f+e,c)));end;if k~=b then if k==0 then c=f+v-b;else c=f+k-_;end;local l=0;for o=f,c do l=l+b;h[o]=z[l];end;else c=f-b;end;",
            pickA(), pickB(), pickC()
        )
    end

    h["29"] = function()
        return string.format(
            "local f=o[%s];local r=o[%s];if r~=0 then c=f+r-b;end;do return h[f](i(h,f+e,c))end;",
            pickA(), pickB()
        )
    end

    h["30"] = function()
        return string.format(
            "local z={};for o=1,#N do local o=N[o];for l=0,#o do local l=o[l];if l then local k=l[1];local o=l[2];if k==h and o>=0 then z[o]=k[o];l[1]=z;end;end;end;end;local f=o[%s];local r=o[%s];if r==b then do return end;elseif r==_ then do return h[f]end;elseif r==0 then do return i(h,f,c)end;else do return i(h,f,f+r-_)end;end;",
            pickA(), pickB()
        )
    end

    h["31"] = function()
        return string.format(
            "local b=o[%s];local f=h[b+2];local k=h[b]+f;h[b]=k;if(f>0)then if(k<=h[b+1])then l=o[%s];h[b+3]=k;end elseif(k>=h[b+1])then l=o[%s];h[b+3]=k;end;",
            pickA(), pickB(), pickB()
        )
    end

    h["32"] = function()
        return string.format("local b=o[%s];h[b]=h[b]-h[b+2];l=o[%s];", pickA(), pickB())
    end

    h["33"] = function()
        return string.format(
            "local f=o[%s];local r={h[f](h[f+1],h[f+2])};local k=f+2+o[%s];for o=1,o[%s]do h[k+o]=r[o];end;if h[k+1]~=nil then h[f+2]=h[k+1];else l=l+e;end;",
            pickA(), pickB(), pickC()
        )
    end

    h["34"] = function()
        return string.format(
            "local f=o[%s];local r=o[%s];local k=o[%s];local z=h[f];if r==0 then r=c-f;end;for o=1,r do z[k+o]=h[f+o];end;",
            pickA(), pickB(), pickC()
        )
    end

    h["35"] = function()
        return string.format(
            "if o[%s]==0 then local f=o[%s];local b={};for o=1,#N do local o=N[o];for l=0,#o do local l=o[l];if l then local k=l[1];local o=l[2];if k==h and o>=f then b[o]=k[o];l[1]=b;end;end;end;end;end;",
            pickB(), pickA()
        )
    end

    h["36"] = function()
        return string.format(
            "local f=g[o[%s]];local r=f[w];local k=#r;local z=nil;if k>0 then local v={};z=R({},{__index=function(l,o)if o==-1 then return v;end;local e=v[o];return e[1][e[2]];end,__newindex=function(l,o,n)local e=v[o];e[1][e[2]]=n;end});for o=1,k do local l=r[o];if l[1]~=0 then v[o-1]={h,l[2]};else v[o-1]=C[-1][l[2]];end;end;N[#N+1]=v;end;h[o[%s]]=S(f,z,K);",
            pickB(), pickA()
        )
    end

    h["37"] = function()
        return string.format(
            "local f=o[%s];local k=o[%s]>0 and(o[%s]-1)or(y-q);if k<0 then k=-1;end;for o=f,f+k do h[o]=v[o-f];end;if o[%s]==0 then c=f+k;end;",
            pickA(), pickB(), pickB(), pickB()
        )
    end

    local function addfnop(opid, fnexpr)
        h[opid .. "_RR"] = function()
            return string.format("h[o[%s]]=%s(h[o[%s]],h[o[%s]]);", pickA(), fnexpr, pickB(), pickC())
        end
        h[opid .. "_RK"] = function()
            return string.format("h[o[%s]]=%s(h[o[%s]],o[%s]);", pickA(), fnexpr, pickB(), pickC())
        end
        h[opid .. "_KR"] = function()
            return string.format("h[o[%s]]=%s(o[%s],h[o[%s]]);", pickA(), fnexpr, pickB(), pickC())
        end
        h[opid .. "_KK"] = function()
            return string.format("h[o[%s]]=%s(o[%s],o[%s]);", pickA(), fnexpr, pickB(), pickC())
        end
    end

    addfnop(38, "W.idiv")
    addfnop(39, "W.band")
    addfnop(40, "W.bor")
    addfnop(41, "W.bxor")
    addfnop(42, "W.shl")
    addfnop(43, "W.shr")

    h["44"] = function()
        return string.format("h[o[%s]]=W.bnot(h[o[%s]]);", pickA(), pickB())
    end

    return h
end

function vmgen.generate(payload, cfg)
    local ex = util.msexpr
    local dkeys = util.picknums(14, 120, 1450)
    local k_str    = dkeys[1]
    local k_ldexp  = dkeys[2]
    local k_byte   = dkeys[3]
    local k_char   = dkeys[4]
    local k_tbl    = dkeys[5]
    local k_sub    = dkeys[6]
    local k_concat = dkeys[7]
    local k_math   = dkeys[8]
    local k_catfn  = dkeys[9]
    local k_insert = dkeys[10]
    local k_unpack = dkeys[11]
    local k_select = dkeys[12]
    local k_tonum  = dkeys[13]
    local k_env    = dkeys[14]

    local rkeys = util.picknums(6, 1, 28)
    local r_u32  = rkeys[1]
    local r_byte = rkeys[2]
    local r_u16  = rkeys[3]
    local r_bits = rkeys[4]
    local r_dbl  = rkeys[5]
    local r_str  = rkeys[6]

    local handlers = buildhandlers()
    local opnodes = {}
    for i = 1, #cfg.vopList do
        local item = cfg.vopList[i]
        local mapped = cfg.opEncode[item.id]
        opnodes[#opnodes + 1] = {
            key = mapped,
            code = handlers[item.id]()
        }
    end
    table.sort(opnodes, function(a, b) return a.key < b.key end)
    local mstree = util.buildmstree(opnodes, "r", "f")

    local headerdecls = table.concat({
        string.format("local G=h[%s];", ex(k_env)),
        string.format("local E=l[o[%s]][o[%s]]or function(o,l)return o*(2^l)end;", ex(k_math), ex(k_ldexp)),
        string.format("local _=%s;", ex(2)),
        string.format("local e=%s;", ex(1)),
        string.format("local g=l[o[%s]][o[%s]];", ex(k_str), ex(k_byte)),
        string.format("local D=%s;", ex(3)),
        string.format("local r=l[o[%s]][o[%s]];", ex(k_tbl), ex(k_concat)),
        string.format("local b=%s;", ex(1)),
        string.format("local n=%s;local d=%s;local H=%s;local a=%s;local F=%s;local L=%s;", ex(3), ex(3), ex(3), ex(3), ex(3), ex(3)),
        string.format("local w=%s;local u=%s;local t=%s;local x=%s;local s=%s;local U=%s;", ex(4), ex(4), ex(4), ex(4), ex(4), ex(4)),
        string.format("local M=%s;local B=%s;local p=%s;local m=%s;local P=%s;local O=%s;", ex(2), ex(2), ex(2), ex(2), ex(2), ex(2)),
        string.format("local I=o[%s];", ex(k_catfn)),
        string.format("local j=l[o[%s]][o[%s]];", ex(k_str), ex(k_sub)),
        string.format("local R=l[(function(o)return type(o):sub(1,1)..'\\101\\116'end)('fMBLhppL')..'\\109\\101'..('\\116\\97'or'fOkBhKpF')..o[%s]];", ex(k_tbl)),
        string.format("local z=l[o[%s]][o[%s]];", ex(k_tbl), ex(k_insert)),
        string.format("local N=%s;local C=%s;", ex(0), ex(0)),
        string.format("local v=l[o[%s]][o[%s]];", ex(k_str), ex(k_char)),
        "local f=function(o,l)return o..l end;",
        string.format("local S=%s;", ex(16)),
        string.format("local A=l[o[%s]];", ex(k_select)),
        string.format("local K=%s;local y=%s;local q=%s;local c=%s;", ex(256), ex(2048), ex(52), ex(4)),
        string.format("local i=l[o[%s]]or l[o[%s]][o[%s]];", ex(k_unpack), ex(k_tbl), ex(k_unpack)),
        string.format("local k=%s;local o=l[o[%s]];", ex(256), ex(k_tonum)),
        "local W={idiv=function(a,b)local q=a/b;return q-q%1;end,band=function(a,b)a=a%4294967296;b=b%4294967296;local r,p=0,1;while a>0 and b>0 do if a%2==1 and b%2==1 then r=r+p;end;a=(a-a%2)/2;b=(b-b%2)/2;p=p*2;end;return r;end,bor=function(a,b)a=a%4294967296;b=b%4294967296;local r,p=0,1;while a>0 or b>0 do if a%2==1 or b%2==1 then r=r+p;end;a=(a-a%2)/2;b=(b-b%2)/2;p=p*2;end;return r;end,bxor=function(a,b)a=a%4294967296;b=b%4294967296;local r,p=0,1;while a>0 or b>0 do if(a%2)~=(b%2)then r=r+p;end;a=(a-a%2)/2;b=(b-b%2)/2;p=p*2;end;return r;end,bnot=function(a)return 4294967295-(a%4294967296);end,shl=function(a,b)if b>=32 or b<=-32 then return 0;end;if b<0 then local v=(a%4294967296)/(2^(-b));return v-v%1;end;return((a%4294967296)*(2^b))%4294967296;end,shr=function(a,b)if b>=32 or b<=-32 then return 0;end;if b<0 then return((a%4294967296)*(2^(-b)))%4294967296;end;local v=(a%4294967296)/(2^b);return v-v%1;end};"
    })

    local zdecoder = string.format(
        "local z=(function(f)local O,h=1,0x10 local l={j={},v={}}local k=-b local o=h+e while true do l[f:sub(o,(function()o=O+o return o-e end)())]=(function()k=k+b return k end)()if k==(S-b)then k=\"\"h=N break end end local k=#f while o<k+e do l.v[h]=f:sub(o,(function()o=O+o return o-e end)())h=h+b if h%%_==N then h=C z(l.j,(v((l[l.v[C]]*S)+l[l.v[b]])))end end return r(l.j)end)(%q);",
        payload
    )

    local streamtbl = string.format(
        "local r=%s local l=%d local h=b;local o={}o={[%s]=function()local o,b,f,O=g(z,h,h+D);h=h+c;l=(l+(r*c))%%k;return(((O+l-(r)+K*(c*_))%%K)*((_*y)^_))+(((f+l-(r*_)+K*(_^D))%%k)*(K*k))+(((b+l-(r*D)+y)%%k)*K)+((o+l-(r*c)+y)%%k);end,[%s]=function(o,o,o)local o=g(z,h,h);h=h+e;l=(l+(r))%%k;return((o+l-(r)+y)%%K);end,[%s]=function()local o,b=g(z,h,h+_);l=(l+(r*_))%%k;h=h+_;return(((b+l-(r)+K*(_*c))%%K)*k)+((o+l-(r*_)+k*(_^D))%%K);end,[%s]=function(h,o,l)if l then local o=(h/_^(o-b))%%_^((l-e)-(o-b)+e);return o-o%%b;else local o=_^(o-e);return(h%%(o+o)>=o)and b or C;end;end,[%s]=function()local l=o[%s]();local h=o[%s]();local O=b;local f=(o[%s](h,e,S+c)*(_^(S*_)))+l;local l=o[%s](h,21,31);local o=((-b)^o[%s](h,32));if(l==C)then if(f==N)then return o*C;else l=e;O=N;end;elseif(l==(K*(_^D))-e)then return(f==C)and(o*(e/N))or(o*(C/N));end;local res=E(o,l-((k*(c))-b))*(O+(f/(_^q)));if res%%1==0 and res>=-2147483648 and res<=2147483647 then return math.floor(res);end;return res;end,[%s]=function(f,O,O)local O;if(not f)then f=o[%s]();if(f==C)then return'';end;end;O=j(z,h,h+f-b);h=h+f;local o=''for h=e,#O do o=I(o,v((g(j(O,h,h))+l)%%k))l=(l+r)%%K end return o;end}",
        ex(cfg.stepKey), cfg.initKey,
        ex(r_u32), ex(r_byte), ex(r_u16), ex(r_bits), ex(r_dbl),
        ex(r_u32), ex(r_u32), ex(r_bits), ex(r_bits), ex(r_bits),
        ex(r_str), ex(r_u32)
    )

    local jloader = string.format(
        "local function y(...)return{...},A('#',...)end local function j()local M={};local f={};local l={};local B={M,f,nil,l};local h={}local P=%s local k={[%s]=(function(l)return not(#l==o[%s]())end),[%s]=(function(l)return o[%s]()end),[%s]=(function(l)local b=o[%s]()local o=''local l=1 for h=1,#b do l=(l+P)%%k o=I(o,v((g(b:sub(h,h))+l)%%K))end return o end)};for u=e,o[%s]()do f[u-e]=j();end;local r=o[%s]()for l=1,r do local o=o[%s]();local b;local o=k[o%%%s];h[l]=o and o({});end;for f=1,o[%s]()do local l=o[%s]();if(o[%s](l,b,e)==N)then local B=o[%s](l,_,D);local k=o[%s](l,c,_+c);local l={o[%s](),o[%s](),nil,nil};local P={[%s]=function()l[H]=o[%s]();l[s]=o[%s]();end,[%s]=function()l[L]=o[%s]();end,[%s]=function()l[d]=o[%s]()-(_^S)end,[%s]=function()l[L]=o[%s]()-(_^S)l[x]=o[%s]();end};P[B]();if(o[%s](k,e,b)==e)then l[m]=h[l[O]]end if(o[%s](k,_,_)==b)then l[L]=h[l[L]]end if(o[%s](k,D,D)==e)then l[t]=h[l[x]]end M[f]=l;end end;for u=1,o[%s]()do l[u]={o[%s](),o[%s]()};end;B[3]=o[%s]();return B;end;",
        ex(cfg.strStep),
        ex(cfg.tagBool), ex(r_byte),
        ex(cfg.tagNum), ex(r_dbl),
        ex(cfg.tagStr), ex(r_str),
        ex(r_u32), ex(r_u32), ex(r_byte), ex(cfg.tagMod),
        ex(r_u32), ex(r_byte), ex(r_bits), ex(r_bits), ex(r_bits), ex(r_u16), ex(r_u16),
        ex(0), ex(r_u16), ex(r_u16),
        ex(1), ex(r_u32),
        ex(2), ex(r_u32),
        ex(3), ex(r_u32), ex(r_u16),
        ex(r_bits), ex(r_bits), ex(r_bits),
        ex(r_byte), ex(r_byte), ex(r_u16), ex(r_byte)
    )

    local srunner = string.format(
        "local function S(o,C,K)local N=o[_];local r=o[D];local o=o[b];return(function(...)local l=b;local h={};local k=o;local z={...};local D=y local o=-b local c=o;local q=r;local v={};local y=A('#',...)-e;local g=N;local N={};for o=0,y do if(o>=q)then v[o-q]=z[o+e];else h[o]=z[o+b];end;end;local o=y-q+b local o;local r;while true do o=k[l];r=o[%s];%s l=l+e end;end);end;return S(j(),{[-1]={[0]={{[0]=G()},0}},[0]=G()},G())end);",
        ex(1), mstree
    )

    local dictentries = {
        string.format("[%s]=%s", ex(k_str),    util.msstr("string")),
        string.format("[%s]=%s", ex(k_ldexp),  util.msstr("ldexp")),
        string.format("[%s]=%s", ex(k_byte),   util.msstr("byte")),
        string.format("[%s]=%s", ex(k_char),   util.msstr("char")),
        string.format("[%s]=%s", ex(k_tbl),    util.msstr("table")),
        string.format("[%s]=%s", ex(k_sub),    util.msstr("sub")),
        string.format("[%s]=%s", ex(k_concat), util.msstr("concat")),
        string.format("[%s]=%s", ex(k_math),   util.msstr("math")),
        string.format("[%s]=(function(l,o)return l..o end)", ex(k_catfn)),
        string.format("[%s]=%s", ex(k_insert), util.msstr("insert")),
        string.format("[%s]=%s", ex(k_unpack), util.msstr("unpack")),
        string.format("[%s]=%s", ex(k_select), util.msstr("select")),
        string.format("[%s]=%s", ex(k_tonum),  util.msstr("tonumber"))
    }
    util.shuf(dictentries)

    local tailcall = string.format(
        "return _msec({%s},{[%s]=(getfenv or function()return _ENV end)},((getfenv and getfenv()or _ENV)))(...)end)(...)",
        table.concat(dictentries, ","),
        ex(k_env)
    )

    return string.format(
        "_, Protected_by_MoonSecV2, Discord = 'discord.gg/gQEH2uZxUk'\n\n\n,nil,nil;return(function(...) _msec=(function(o,h,l)%s%s%s%s%s%s",
        headerdecls, zdecoder, streamtbl, jloader, srunner, tailcall
    )
end

return vmgen
