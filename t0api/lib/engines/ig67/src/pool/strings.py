#!/usr/bin/env python3
from __future__ import annotations
import random, re
from typing import List

ALPHA = list("!@#$%^&*()_+-=[]")

def extract_pool(src: str, rng: random.Random) -> List[str]:
    found = set(re.findall(r'["\']([^"\']{1,60})["\']', src))
    found.update(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]{2,})\b", src))
    base = [
        "debug", "getinfo", "os", "file", "io", "ipairs", "gethook", "pcall", "_G",
        "__metatable", "This metatable is locked.", "package", "error", "table",
        "math", "string", "random", "concat", "print", "tostring", "gsub", "__index",
        "__newindex", "unpack", "getmetatable", "type", "load", "setmetatable",
        "xpcall", "pairs", "insert", "function", "tonumber", "select", "_ENV",
        "dump", "clock", "what", "getfenv", "setfenv", "newproxy", "rawget", "rawset",
    ]
    pool = list(found) + base
    for _ in range(28):
        pool.append("".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(10)))
    rng.shuffle(pool)
    seen, out = set(), []
    for s in pool:
        if s not in seen:
            seen.add(s)
            out.append(s)
    return out

def enc_str(s: str) -> str:
    return "".join(ALPHA[(ord(c) >> 4) & 0xF] + ALPHA[ord(c) & 0xF] for c in s)

def dec_str(encoded: str) -> str:
    inv = {c: i for i, c in enumerate(ALPHA)}
    out = []
    for i in range(0, len(encoded), 2):
        if i + 1 >= len(encoded):
            break
        hi = inv.get(encoded[i], 0)
        lo = inv.get(encoded[i + 1], 0)
        out.append(chr((hi << 4) | lo))
    return "".join(out)

def emit_pool_blob(pool: List[str]) -> str:
    return "|".join(enc_str(s) for s in pool)

def emit_alphabet_builder_lua() -> str:
    vals = [ord(c) for c in "!@#$%^&*()_+-=[]"]
    chunks = [vals[0:4], vals[4:8], vals[8:12], vals[12:16]]
    names = ["L", "F", "w", "r"]
    parts = []
    for n, ch in zip(names, chunks):
        parts.append(f"local {n}={{{','.join(str(x) for x in ch)}}}")
    return " ".join(parts)

def split_pool_by_usage(pool: List[str], src: str) -> tuple:
    used = []
    rest = []
    for s in pool:
        if s in src:
            used.append(s)
        else:
            rest.append(s)
    return used, rest
