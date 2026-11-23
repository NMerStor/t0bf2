#!/usr/bin/env python3
from __future__ import annotations
import random
from typing import List

def opaque_true(rng: random.Random) -> str:
    a = rng.randint(10, 500)
    forms = [
        f"(({a})-({a}))==0",
        f"(({a}*{a})-({a}*{a}))==0",
        f"(not not (({a})==({a})))",
        f"(({a})%({a}+1))==({a})",
    ]
    return forms[rng.randint(0, len(forms) - 1)]

def opaque_false(rng: random.Random) -> str:
    a = rng.randint(10, 500)
    forms = [
        f"(({a})-({a}))~=0",
        f"(({a})==({a}+1))",
        f"(({a}*{a})<0)",
        f"(not (({a})==({a})))",
    ]
    return forms[rng.randint(0, len(forms) - 1)]

def opaque_pred(rng: random.Random, expect_true: bool = True) -> str:
    return opaque_true(rng) if expect_true else opaque_false(rng)

def mba_add(rng: random.Random, x: str, y: str) -> str:
    """Mixed boolean-arithmetic identity for x+y."""
    forms = [
        f"(({x})-(-({y})))",
        f"((({x})~({y}))+2*(({x})&({y})))",
        f"((({x})|({y}))+(({x})&({y})))",
    ]
    return forms[rng.randint(0, len(forms) - 1)]

def mba_xor(rng: random.Random, x: str, y: str) -> str:
    forms = [
        f"((({x})|({y}))-(({x})&({y})))",
        f"((({x})+({y}))-2*(({x})&({y})))",
    ]
    return forms[rng.randint(0, len(forms) - 1)]

def constant_encoding(rng: random.Random, value: int) -> str:
    k = rng.randint(0, 3)
    if k == 0:
        a = rng.randint(1, 10000)
        return f"(({a + value})-({a}))"
    if k == 1 and value:
        a = rng.randint(2, 20)
        return f"(({value * a})/({a}))"
    if k == 2:
        a = rng.randint(0, 500)
        return f"(({value})+({a})-({a}))"
    return str(value)

def emit_predicate_chain(rng: random.Random, depth: int = 3) -> str:
    parts = []
    for i in range(depth):
        parts.append(f"local _p{i}={opaque_true(rng)}")
    joined = " and ".join(f"_p{i}" for i in range(depth))
    return " ".join(parts) + f" local _pok=({joined}) "

def dead_code_branch(rng: random.Random, live: str, dead: str) -> str:
    return f"if {opaque_true(rng)} then {live} else {dead} end "

def invariant_check(rng: random.Random, var: str) -> str:
    a = rng.randint(1, 100)
    return f"if (({var})-({var}))~=0 then while true do end end local _={a} "
