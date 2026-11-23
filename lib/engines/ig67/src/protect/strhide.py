#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import List, Dict

ALPHA = list("!@#$%^&*()_+-=[]")

def enc_str(s: str) -> str:
    out = []
    for c in s:
        b = ord(c) & 0xFF
        out.append(ALPHA[(b >> 4) & 0xF])
        out.append(ALPHA[b & 0xF])
    return "".join(out)

_registry: List[str] = []
_index: Dict[str, int] = {}
_names: Dict[str, str] = {}

def reset_registry(seed: int = 0):
    global _registry, _index, _names
    _registry = []
    _index = {}
    rng = random.Random(seed ^ 0xA11CE)
    used = set("if do end or and not in for nil true false local function return then else elseif while repeat until break type load string table math".split())
    def rn():
        while True:
            n = "".join(rng.choice("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(rng.randint(1, 2)))
            if n not in used:
                used.add(n)
                return n
    _names = {
        "HA": rn(), "HM": rn(), "HB": rn(), "HD": rn(), "HX": rn(), "HS": rn(),
    }

def register(s: str) -> int:
    if s in _index:
        return _index[s]
    idx = len(_registry)
    _registry.append(s)
    _index[s] = idx
    return idx

def hid(s: str) -> str:
    idx = register(s)
    return f"{_names['HS']}({idx})"

def n(key: str) -> str:
    return _names.get(key, key)

def emit_str_builder(rng: random.Random) -> str:
    HA, HM, HB, HD, HX, HS = [n(k) for k in ("HA","HM","HB","HD","HX","HS")]
    return (
        f"local {HA}=nil local {HM}={{}} local {HB}=nil "
        f"local function {HD}() "
        f"if {HA} then return end "
        f"local L={{33,64,35,36}} local F={{37,94,38,42}} local w={{40,41,95,43}} local r={{45,61,91,93}} "
        f"local o={{}} local M=1 "
        f"for _,arr in ipairs({{L,F,w,r}}) do for i=1,#arr do o[M]=string.char(arr[i]) M=M+1 end end "
        f"{HA}=table.concat(o) "
        f"for i=1,#{HA} do {HM}[string.sub({HA},i,i)]=i-1 end "
        f"end "
        f"local function {HX}(enc) "
        f"{HD}() "
        f"local buf={{}} local i=1 "
        f"while i<=#enc do "
        f"local a={HM}[string.sub(enc,i,i)] or 0 "
        f"local b={HM}[string.sub(enc,i+1,i+1)] or 0 "
        f"buf[#buf+1]=string.char(a*16+b) i=i+2 "
        f"end return table.concat(buf) end "
        f"local function {HS}(i) "
        f"if type({HB})~=\"table\" then return \"\" end "
        f"local e={HB}[i+1] "
        f"if not e then return \"\" end "
        f"return {HX}(e) "
        f"end "
    )

def emit_pool_blob() -> str:
    HB = n("HB")
    if not _registry:
        return f"{HB}={{}} "
    parts = []
    for s in _registry:
        parts.append('"' + enc_str(s).replace("\\", "\\\\").replace('"', '\\"') + '"')
    return f"{HB}={{{','.join(parts)}}} "
