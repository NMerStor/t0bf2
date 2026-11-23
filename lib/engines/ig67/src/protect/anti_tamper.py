#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import Dict, Optional, List
from protect.strhide import hid

def emit_anti_tamper_frags(rng: random.Random) -> List[str]:
    def H(s):
        return hid(s)
    d = "_z" + str(rng.randint(10, 99))
    ai = "_a" + str(rng.randint(10, 99))
    frags: List[str] = []
    frags.append(f"local {d}=false ")
    frags.append(
        f"do local {ai}=debug and (debug.getinfo or debug.info) "
        f"if type({ai})~=\"function\" then {d}=true end end "
    )
    frags.append(
        f"if task and task.spawn then if pcall(function() task.spawn({{}}) end) then {d}=true end end "
    )
    roblox = []
    roblox.append(f"if pcall(function() return workspace[{H('subgmaballshaha')}](workspace) end) then {d}=true end ")
    roblox.append(f"if pcall(function() return game[{H('__definitely_not_a_real_member__')}](game) end) then {d}=true end ")
    for svc in ["PermissionsService","OpenCloudService","SharedTableRegistry","MaterialService","BrowserService"]:
        roblox.append(
            f"do local ok,svc=pcall(function() return game[{H('GetService')}](game,{H(svc)}) end) "
            f"if ok and svc then if typeof(svc)~=\"Instance\" or svc.ClassName~={H(svc)} then {d}=true end end end "
        )
    roblox.append(
        f"do local _lp=game[{H('GetService')}](game,{H('Players')})[{H('LocalPlayer')}] "
        f"if _lp then local age=_lp[{H('AccountAge')}] "
        f"if type(age)~=\"number\" or age<=0 or age~=math.floor(age) then {d}=true end end end "
    )
    roblox.append(
        f"do local _st=game[{H('GetService')}](game,{H('Stats')}) "
        f"local ok,v=pcall(function() return _st[{H('GetMemoryUsageMbForTag')}](_st,{H('Script')}) end) "
        f"if not ok or type(v)~=\"number\" or v<=0 then {d}=true end end "
    )
    roblox.append(
        f"do local fa,fb=math.frexp(8) if fa~=0.5 or fb~=4 then {d}=true end "
        f"if math.ldexp(0.5,4)~=8 then {d}=true end end "
    )
    roblox.append(
        f"if getmetatable(workspace)~={H('The metatable is locked')} then {d}=true end "
        f"if getmetatable(game)~={H('The metatable is locked')} then {d}=true end "
    )
    roblox.append(
        f"do local ss=tostring(math.sin) if ss:find({H('CALL')}) or ss:find({H('NAMECALL')}) then {d}=true end end "
    )
    frags.append("if game and workspace then " + "".join(roblox) + " else "
                 f"local fa,fb=math.frexp(8) if fa~=0.5 or fb~=4 then {d}=true end "
                 f"if math.ldexp(0.5,4)~=8 then {d}=true end end ")
    frags.append(f"if {d} then while true do end end ")
    return frags

def emit_anti_tamper(rng: random.Random, names: Optional[Dict[str, str]] = None) -> str:
    return "".join(emit_anti_tamper_frags(rng))
