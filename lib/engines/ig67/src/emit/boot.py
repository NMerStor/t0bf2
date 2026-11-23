#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import Dict

def op_n(rng: random.Random, v: int) -> str:
    k = rng.randint(0, 3)
    if k == 0:
        a = rng.randint(40, 5000)
        return f"({a + v})-({a})" if v >= 0 else f"({a})-({a - v})"
    if k == 1 and v:
        a = rng.randint(2, 18)
        return f"({v}*{a})/({a})"
    if k == 2 and v >= 0:
        a = rng.randint(v + 1, v + 2000)
        return f"({a})-({a - v})"
    return str(int(v))

def emit_boot(rng: random.Random, names: Dict[str, str], y_blob: str) -> str:
    p, c, K, S, h, y, T, W, o, X, A, l, d, u, N, M = [
        names[k] for k in "p c K S h y T W o X A l d u N M".split()
    ]
    av = [ord(ch) for ch in "!@#$%^&*()_+-=[]"]
    def oarr(vs):
        return "{" + ",".join(str(int(v)) for v in vs) + "}"
    return (
        f"return(function(...)local {p},{c} do "
        f"local k={op_n(rng, 127)} local WW={op_n(rng, 255)} local J=function(x)return x end "
        f"local {A}={{}} for i=0,64,1 do {A}[i]={{}} for j=0,64,1 do {A}[i][j]=0 end end "
        f"local L={oarr(av[0:4])} local F={oarr(av[4:8])} local w={oarr(av[8:12])} local r={oarr(av[12:16])} "
        f"local {o}={{}} local {M}=1 "
        f"for _,arr in ipairs({{L,F,w,r}}) do for i=1,#arr,1 do "
        f"{o}[{M}]=string.char(tonumber(arr[i]) or 0) {M}={M}+1 end end "
        f"{o}=table.concat({o}) "
        f"local {u}={op_n(rng, 75)} local {N}={op_n(rng, 76)} local {d}={u}+{N} "
        f"local function {l}(a,b) "
        f"if {A}[a] and ({A}[a][b] and {A}[a][b]~=0) then return {A}[a][b] end "
        f"local kk=0 for bit=0,7,1 do local J=a/2+b/2 "
        f"if J~=math.floor(J) then kk=kk+(2)^bit end "
        f"a=math.floor(a/2) b=math.floor(b/2) end "
        f"if a<256 and b<256 then {A}[a]={A}[a] or {{}} {A}[a][b]=kk end return kk end "
        f"local {X}={{}} for i=1,#{o},1 do {X}[string.sub({o},i,i)]=i-1 end "
        f"local function {h}(ch) return {X}[ch] or 0 end "
        f'local {y}="{y_blob}" '
        f"local {S}={{}} local {T}=0 "
        f"local function {K}(idx) {T}={T}+1 if {S}[idx] then return {S}[idx] end "
        f"local buf={{}} local i=idx+1 while i<=#{y} do "
        f"local ch=string.sub({y},i,i) if ch=='|' then break end "
        f"local aa={h}(ch) local bb={h}(string.sub({y},i+1,i+1)) "
        f"local v=aa*16+bb local x={l}(v,{d}) "
        f"buf[#buf+1]=string.char(math.floor(tonumber(x) or 0)%256) i=i+2 end "
        f"local rr=table.concat(buf) {S}[idx]=rr return rr end "
        f"local R=true "
        f"{c}=setmetatable({{}},{{__index=function(_,i) if not R then end return {K}(i) end,"
        f'__metatable="locked",__newindex=function() end}}) '
        f"function {p}(x) if type(x)~=\"number\" then end return x end "
        f"end "
    )
