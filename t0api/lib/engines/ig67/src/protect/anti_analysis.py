#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import Dict, Optional, List
from protect.strhide import hid

def emit_anti_analysis_frags(rng: random.Random) -> List[str]:
    a = rng.randint(100, 900)
    b = rng.randint(100, 900)
    frags = []
    frags.append(
        f"local _aa=({a})-({a}) local _ab=({b})+({b})-({b*2}) "
        f"if _aa~=0 or _ab~=0 then while true do end end "
    )
    frags.append(
        f"local _clk=os and rawget(os,{hid('clock')}) local _t0=_clk and _clk() or 0 "
        f"local _sink=0 for _i=1,3 do _sink=_sink+_i end "
        f"if _clk then local _t1=_clk() if _t1 and _t0 and (_t1-_t0)>3 then while true do end end end "
    )
    frags.append(
        f"local _sinS=tostring(math.sin) if type(_sinS)==\"string\" then "
        f"if _sinS:find({hid('CALL')}) or _sinS:find({hid('NAMECALL')}) then while true do end end end "
    )
    frags.append(
        f"local _rp=rawget(_G,{hid('pcall')}) if type(_rp)~=\"function\" then while true do end end "
        f"local ok,res=pcall(function() return 1+1 end) if not ok or res~=2 then while true do end end "
    )
    return frags

def emit_anti_analysis(rng: random.Random, names: Optional[Dict[str, str]] = None) -> str:
    return "".join(f"do {f} end " for f in emit_anti_analysis_frags(rng))

def emit_anti_analysis_deep(rng: random.Random) -> str:
    return ""
