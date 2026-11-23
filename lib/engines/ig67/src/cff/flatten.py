#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import List, Tuple, Dict, Set

def op_n(rng: random.Random, v: int) -> str:
    k = rng.randint(0, 4)
    if k == 0:
        a = rng.randint(40, 5000)
        return f"({a + v})-({a})" if v >= 0 else f"({a})-({a - v})"
    if k == 1 and v:
        a = rng.randint(2, 18)
        return f"({v}*{a})/({a})"
    if k == 2 and v >= 0:
        a = rng.randint(v + 1, v + 2000)
        return f"({a})-({a - v})"
    if k == 3:
        a = rng.randint(10, 400)
        return f"({v})+({a})-({a})"
    return str(int(v))

def build_state_ids(rng: random.Random, entry: int, n_states: int) -> List[int]:
    ids = []
    base = entry
    for _ in range(n_states):
        base = base + rng.randint(40, 350)
        ids.append(base)
    return ids

def build_cfg_edges(ids: List[int], rng: random.Random) -> Dict[int, List[int]]:
    edges: Dict[int, List[int]] = {s: [] for s in ids}
    n = len(ids)
    for i, s in enumerate(ids):
        targets = set()
        for _ in range(rng.randint(1, 3)):
            targets.add(ids[(i + rng.randint(1, max(1, n - 1))) % n])
        edges[s] = list(targets)
    return edges

def emit_state_block(rng: random.Random, W: str, sid: int, nxt: int, kind: int, c: str, p: str, pool_len: int, entry: int, n_all: int) -> str:
    pidx = rng.randint(0, max(0, min(35, pool_len - 1)))
    if kind == 0:
        return f"elseif {W}<{op_n(rng, sid + rng.randint(1000, 8000))} then if {W}<{sid} then {W}={nxt} else {W}={sid} end "
    if kind == 1:
        return f"elseif {W}>={sid} then if {W}<={sid + rng.randint(3, 8)} then {W}={nxt} else {W}={sid} end "
    if kind == 2:
        return f"elseif {W}=={sid} then {W}={op_n(rng, nxt)} "
    if kind == 3:
        return f"elseif {W}<={sid} then {W}=({W}+{rng.randint(1, 55)})%{max(n_all, 10)}+{entry} "
    if kind == 4:
        return f"elseif {W}=={sid} then local t={op_n(rng, rng.randint(0, 90))} {W}=(t%2==0) and {nxt} or {sid} "
    if kind == 5:
        return f"elseif {W}>={sid} then if {W}<{sid + rng.randint(8, 14)} then {W}={nxt} else {W}={sid} end "
    if kind == 6:
        return f"elseif {W}=={sid} then local _s={c}[{p}({pidx})] {W}={nxt} "
    if kind == 7:
        bigv = rng.randint(100000, 9000000)
        return f"elseif {W}<{bigv}*{rng.randint(2, 5)} then {W}={op_n(rng, nxt)} "
    if kind == 8:
        return f"elseif {W}<{op_n(rng, sid)} then if {W}<{op_n(rng, max(sid // 2, 1))} then {W}={nxt} else {W}={sid} end "
    return f"elseif {W}=={sid} then {W}={nxt} "

def emit_cff(rng: random.Random, W: str, entry: int, n_states: int, c: str, p: str, pool_len: int) -> str:
    thresholds = build_state_ids(rng, entry, n_states)
    big = [entry + 3000000 - rng.randint(1000, 400000) for _ in range(50)]
    all_t = sorted(set(thresholds + [t for t in big if t > entry]))
    parts: List[str] = []
    for i, sid in enumerate(all_t):
        nxt = all_t[(i + 7) % len(all_t)]
        parts.append(emit_state_block(rng, W, sid, nxt, i % 10, c, p, pool_len, entry, len(all_t)))
    return "".join(parts)

def flatten_basic_blocks(blocks: List[str], rng: random.Random, state_var: str = "S") -> str:
    """Take ordered basic-block source strings and emit a dispatcher switch."""
    n = len(blocks)
    ids = [rng.randint(1000, 99999) for _ in range(n)]
    order = list(range(n))
    rng.shuffle(order)
    parts = [f"local {state_var}={ids[0]} while true do "]
    for i, bi in enumerate(order):
        nxt = ids[order[(i + 1) % n]] if i + 1 < n else -1
        body = blocks[bi]
        if nxt < 0:
            parts.append(f"if {state_var}=={ids[bi]} then {body} break ")
        else:
            parts.append(f"if {state_var}=={ids[bi]} then {body} {state_var}={nxt} ")
        if i > 0:
            parts[-1] = "else" + parts[-1]
    parts.append("else break end end ")
    return "".join(parts)

def insert_bogus_states(states: List[int], rng: random.Random, density: float = 0.3) -> List[int]:
    out = list(states)
    extra = int(len(states) * density)
    for _ in range(extra):
        out.append(rng.randint(min(states), max(states) + 5000))
    return sorted(set(out))

def opaque_branch(rng: random.Random, true_target: int, false_target: int) -> str:
    a = rng.randint(50, 500)
    return f"if (({a})-({a}))==0 then S={true_target} else S={false_target} end "

def dispatch_table_lua(ids: List[int], handler_exprs: List[str], W: str) -> str:
    parts = []
    for i, (sid, expr) in enumerate(zip(ids, handler_exprs)):
        kw = "if" if i == 0 else "elseif"
        parts.append(f"{kw} {W}=={sid} then {expr} ")
    parts.append("end ")
    return "".join(parts)
