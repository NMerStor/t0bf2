#!/usr/bin/env python3
"""LeakD-style environment fingerprint anti-dump, strings via alphabet hid()."""
from __future__ import annotations
import random
from typing import Dict, Optional, List
from protect.strhide import hid

DEFAULT_KEYS = [
    "pcall", "xpcall", "type", "tostring", "setmetatable",
    "getmetatable", "error", "select", "unpack", "rawget", "rawset",
]

def emit_anti_dump_frags(rng: random.Random) -> List[str]:
    """Emit fragments: capture baseline of env function identities, re-check, seal dump."""
    frags: List[str] = []
    keys = list(DEFAULT_KEYS)
    rng.shuffle(keys)
    keys = keys[:9]
    base = "_b" + str(rng.randint(10, 99))
    trig = "_t" + str(rng.randint(10, 99))
    # fingerprint helper
    frags.append(
        "local function _fp(v) local ok,r=pcall(function() return tostring(v) end) "
        "return ok and r or \"\" end "
    )
    # capture baseline
    frags.append(
        f"local {base}={{}} local {trig}=false "
        + "local _ks={" + ",".join(hid(k) for k in keys) + "} "
        + f"for _,_k in ipairs(_ks) do local ok,v=pcall(function() return _G[_k] or (rawget and rawget(_G,_k)) end) "
        + f"if ok then {base}[_k]=_fp(v) end end "
    )
    # re-check environment against baseline
    frags.append(
        f"do for _,_k in ipairs(_ks) do "
        f"local ok,v=pcall(function() return _G[_k] or (rawget and rawget(_G,_k)) end) "
        f"local now=_fp(ok and v or nil) "
        f"if {base}[_k]~=nil and now~={base}[_k] then {trig}=true end end "
        f"if {trig} then while true do end end end "
    )
    # disable dump APIs
    frags.append(
        "pcall(function() "
        f"local _s=rawget(_G,{hid('string')}) "
        f"if type(_s)==\"table\" and type(rawget(_s,{hid('dump')}))==\"function\" then "
        f"pcall(function() rawset(_s,{hid('dump')},function(...) end) end) end "
        f"local _d=rawget(_G,{hid('debug')}) "
        f"if type(_d)==\"table\" then "
        + "for _,_k in ipairs({" + ",".join(hid(k) for k in ["getupvalue","setupvalue","getconstants","getproto","getprotos","getstack"]) + "}) do "
        + "if type(rawget(_d,_k))==\"function\" then pcall(function() rawset(_d,_k,function(...) end) end) end end end end) "
    )
    # continuous dump probe
    frags.append(
        "pcall(function() "
        f"local _s=rawget(_G,{hid('string')}) "
        f"if type(_s)==\"table\" and type(rawget(_s,{hid('dump')}))==\"function\" then "
        f"local ok=pcall(function() return _s[{hid('dump')}](function() end) end) "
        f"if ok then while true do end end end end) "
    )
    return frags

def emit_anti_dump(rng: random.Random, names: Optional[Dict[str, str]] = None) -> str:
    return "".join(emit_anti_dump_frags(rng))

def emit_anti_dump_continuous(rng: random.Random) -> str:
    return ""
