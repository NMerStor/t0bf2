#!/usr/bin/env python3
"""Reference executor for VMC3-style encrypted images."""
from __future__ import annotations
from typing import Any, Dict, List, Optional
from .opcodes import decrypt_word, unpack_word, NAME, verify_image, U32
from .bytecode import Image

class VMError(RuntimeError):
    pass

def execute(image: Image, env: Optional[dict] = None) -> Any:
    if image.magic != "VMC3" or image.version != 3:
        raise VMError("unsupported image")
    if image.guard is not None and image.guard != verify_image(image.key, image.code, image.constants):
        raise VMError("integrity failure")
    env = env if env is not None else {}
    Rg: Dict[int, Any] = {}
    Up: Dict[int, Any] = {}
    pc = image.entry
    key = image.key
    code = image.code
    K = [None] + list(image.constants)  # 1-based
    fuel = image.fuel
    while True:
        fuel -= 1
        if fuel <= 0:
            raise VMError("fuel")
        if pc < 1 or pc > len(code):
            return None
        raw = decrypt_word(code[pc - 1], key, pc)
        op, a, b, c = unpack_word(raw)
        ins = NAME.get(op)
        if ins == "NOP":
            pc += 1
        elif ins == "LOADK":
            Rg[a] = K[b] if b < len(K) else None
            pc += 1
        elif ins == "LOADN":
            Rg[a] = b
            pc += 1
        elif ins == "MOVE":
            Rg[a] = Rg.get(b)
            pc += 1
        elif ins == "GETGLOBAL":
            k = K[b] if b < len(K) else None
            Rg[a] = env.get(k, __builtins__.get(k) if isinstance(__builtins__, dict) else getattr(__builtins__, k, None))
            pc += 1
        elif ins == "SETGLOBAL":
            env[K[b]] = Rg.get(a)
            pc += 1
        elif ins == "NEWTABLE":
            Rg[a] = {}
            pc += 1
        elif ins == "GETTABLE":
            t = Rg.get(b)
            Rg[a] = t[Rg.get(c)] if t is not None else None
            pc += 1
        elif ins == "SETTABLE":
            t = Rg.get(a)
            if t is not None:
                t[Rg.get(b)] = Rg.get(c)
            pc += 1
        elif ins == "ADD":
            Rg[a] = Rg.get(b, 0) + Rg.get(c, 0)
            pc += 1
        elif ins == "SUB":
            Rg[a] = Rg.get(b, 0) - Rg.get(c, 0)
            pc += 1
        elif ins == "MUL":
            Rg[a] = Rg.get(b, 0) * Rg.get(c, 0)
            pc += 1
        elif ins == "DIV":
            Rg[a] = Rg.get(b, 0) / Rg.get(c, 0)
            pc += 1
        elif ins == "MOD":
            Rg[a] = Rg.get(b, 0) % Rg.get(c, 0)
            pc += 1
        elif ins == "POW":
            Rg[a] = Rg.get(b, 0) ** Rg.get(c, 0)
            pc += 1
        elif ins == "UNM":
            Rg[a] = -Rg.get(b, 0)
            pc += 1
        elif ins == "NOT":
            Rg[a] = not Rg.get(b)
            pc += 1
        elif ins == "LEN":
            Rg[a] = len(Rg.get(b) or [])
            pc += 1
        elif ins == "EQ":
            Rg[a] = Rg.get(b) == Rg.get(c)
            pc += 1
        elif ins == "LT":
            Rg[a] = Rg.get(b) < Rg.get(c)
            pc += 1
        elif ins == "LE":
            Rg[a] = Rg.get(b) <= Rg.get(c)
            pc += 1
        elif ins == "TEST":
            if (not Rg.get(a)) == (b != 0):
                pc += 2
            else:
                pc += 1
        elif ins == "JMP":
            pc = pc + (b - 128)
        elif ins == "CALL":
            fn = Rg.get(a)
            args = [Rg.get(a + i) for i in range(1, b + 1)]
            if callable(fn):
                ret = fn(*args)
                Rg[a] = ret
            pc += 1
        elif ins == "RETURN":
            outs = [Rg.get(a + i) for i in range(b)]
            return outs[0] if outs else None
        elif ins == "HALT":
            return Rg.get(a)
        elif ins == "CONCAT":
            x = "".join(str(Rg.get(i, "")) for i in range(b, c + 1))
            Rg[a] = x
            pc += 1
        elif ins == "EXTRA" or ins is None:
            pc += 1
        else:
            pc += 1


def run_image_dict(d: dict, env=None):
    img = Image.__new__(Image)
    img.magic = d.get("magic", "VMC3")
    img.version = d.get("version", 3)
    img.key = d.get("key", 0)
    img.constants = list(d.get("constants") or [])
    img.code = list(d.get("code") or [])
    img.prototypes = list(d.get("prototypes") or [])
    img.entry = d.get("entry", 1)
    img.fuel = d.get("fuel", 1000000)
    img.guard = d.get("guard")
    return execute(img, env)

def selftest() -> bool:
    from .compiler import compile_arith, compile_print_msg
    img = compile_arith(10, 20, key=0x4242)
    r = execute(img, {})
    if r != 30:
        return False
    # integrity tamper
    img2 = compile_arith(1, 2, key=0x99)
    img2.code[0] ^= 1
    try:
        execute(img2, {})
        return False
    except VMError:
        pass
    return True
