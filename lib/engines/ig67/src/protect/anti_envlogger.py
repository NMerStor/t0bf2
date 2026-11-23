#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import Dict, List, Optional
from protect.strhide import hid

ASSET_PROBES = [
    "game","workspace","Enum","Instance","CFrame","task","debug","os",
    "string","table","math","pcall","type","tostring","pairs","rawget",
]

SERVICE_PROBES = [
    "Players","RunService","HttpService","Stats","PhysicsService",
    "TweenService","UserInputService","ReplicatedStorage",
]

def emit_anti_envlogger_frags(rng: random.Random) -> List[str]:
    frags = []
    eb = "_e" + str(rng.randint(10, 99))
    need = ["pcall","type","tostring","pairs","error","select"]
    frags.append(
        f"local {eb}=false "
        "local _need={" + ",".join(hid(n) for n in need) + "} "
        "for _,_n in ipairs(_need) do "
        f"if type(rawget(_G,_n))~=\"function\" and type(_G[_n])~=\"function\" then {eb}=true end end "
    )
    picks = list(ASSET_PROBES)
    rng.shuffle(picks)
    for name in picks[:10]:
        frags.append(
            f"do local _v=rawget(_G,{hid(name)}) "
            f"if _v~=nil and type(_v)==\"userdata\" then "
            f"local ok,mt=pcall(getmetatable,_v) "
            f"if ok and type(mt)==\"table\" and mt.__namecall then {eb}=true end end end "
        )
    frags.append(
        f"if game and type(game[{hid('GetService')}])==\"function\" then "
        "local _svcs={" + ",".join(hid(s) for s in SERVICE_PROBES[:6]) + "} "
        "for _,_sn in ipairs(_svcs) do "
        f"local ok,svc=pcall(function() return game[{hid('GetService')}](game,_sn) end) "
        f"if ok and svc~=nil and typeof and typeof(svc)~=\"Instance\" then {eb}=true end end end "
    )
    frags.append(f"if {eb} then while true do end end ")
    return frags

def emit_anti_envlogger(rng: random.Random, names: Optional[Dict[str, str]] = None) -> str:
    return "".join(emit_anti_envlogger_frags(rng))

def emit_asset_fingerprint(rng: random.Random) -> str:
    names = ["string","table","math","debug","coroutine","os","task"]
    return (
        "do local _fp=0 local _names={" + ",".join(hid(n) for n in names) + "} "
        "for _i,_n in ipairs(_names) do if rawget(_G,_n)~=nil then _fp=_fp+(_i*17) end end end "
    )
