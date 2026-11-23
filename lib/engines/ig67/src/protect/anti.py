#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import Dict, Optional, List

try:
    from protect.strhide import reset_registry, emit_str_builder, emit_pool_blob
    from protect.anti_tamper import emit_anti_tamper_frags
    from protect.anti_dump import emit_anti_dump_frags
    from protect.anti_envlogger import emit_anti_envlogger_frags, emit_asset_fingerprint
    from protect.anti_analysis import emit_anti_analysis_frags
except ImportError:
    from strhide import reset_registry, emit_str_builder, emit_pool_blob
    from anti_tamper import emit_anti_tamper_frags
    from anti_dump import emit_anti_dump_frags
    from anti_envlogger import emit_anti_envlogger_frags, emit_asset_fingerprint
    from anti_analysis import emit_anti_analysis_frags

def _op_n(rng: random.Random, v: int) -> str:
    a = rng.randint(40, 4000)
    return f"({a+v})-({a})"

def _weave(rng: random.Random, frags: List[str]) -> str:
    """Wrap each fragment in opaque nested if/local noise so structure is not a flat anti list."""
    if not frags:
        return ""
    order = list(range(len(frags)))
    rng.shuffle(order)
    parts = []
    # single outer while false-skip skeleton that always runs body once
    wv = "_w" + str(rng.randint(10, 99))
    entry = rng.randint(1000, 5000)
    parts.append(f"local {wv}={_op_n(rng, entry)} ")
    parts.append(f"while {wv} do ")
    for i, fi in enumerate(order):
        thr = entry + (i + 1) * rng.randint(50, 200)
        body = frags[fi]
        # wrap with opaque true predicate
        a = rng.randint(10, 500)
        parts.append(
            f"if {wv}<{_op_n(rng, thr)} then "
            f"if (({a})-({a}))==0 then {body} end "
            f"{wv}={_op_n(rng, thr)} "
        )
    parts.append(f"else break end " * len(order))
    parts.append("end ")
    return "".join(parts)

def emit_protect_block(rng: random.Random, names: Optional[Dict[str, str]] = None) -> str:
    names = names or {}
    reset_registry(rng.randint(0, 10**9))
    frags: List[str] = []
    frags.extend(emit_anti_analysis_frags(rng))
    frags.extend(emit_anti_dump_frags(rng))
    frags.extend(emit_anti_envlogger_frags(rng))
    frags.append(emit_asset_fingerprint(rng))
    frags.extend(emit_anti_tamper_frags(rng))
    # register strings first
    woven = _weave(rng, frags)
    return emit_str_builder(rng) + emit_pool_blob() + woven
