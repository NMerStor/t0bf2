#!/usr/bin/env python3
from __future__ import annotations
import argparse, random, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pool.strings import extract_pool, emit_pool_blob
from emit.boot import emit_boot
from vm.runtime import emit_vm_core
from cff.flatten import emit_cff
from bc.encoder import compile_ir
from protect.anti import emit_protect_block

def rn(rng, used):
    ban = set("if do end or and not in for nil true false local function return then else elseif while repeat until break type load".split())
    while True:
        n = "".join(rng.choice("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(rng.randint(1, 2)))
        if n not in ban and n not in used:
            used.add(n)
            return n

def densify(s: str) -> str:
    out = []
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if ch in "'\"":
            q = ch
            j = i + 1
            while j < n:
                if s[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if s[j] == q:
                    j += 1
                    break
                j += 1
            out.append(s[i:j])
            i = j
            continue
        if ch.isspace():
            while i < n and s[i].isspace():
                i += 1
            out.append(" ")
            continue
        out.append(ch)
        i += 1
    s2 = "".join(out)
    out2 = []
    i, n = 0, len(s2)
    while i < n:
        ch = s2[i]
        if ch in "'\"":
            q = ch
            j = i + 1
            while j < n:
                if s2[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                if s2[j] == q:
                    j += 1
                    break
                j += 1
            out2.append(s2[i:j])
            i = j
            continue
        # digit then letter: only split if digit-run is a bare number, not part of identifier (Use2022Materials)
        if i + 1 < n and ch.isdigit() and (s2[i + 1].isalpha() or s2[i + 1] == "_"):
            j = i
            while j > 0 and s2[j - 1].isdigit():
                j -= 1
            if j > 0 and (s2[j - 1].isalpha() or s2[j - 1] == "_"):
                out2.append(ch)
                i += 1
                continue
            out2.append(ch)
            out2.append(" ")
            i += 1
            continue
        out2.append(ch)
        i += 1
    return "".join(out2).strip()



def build(payload: str, seed: int, min_kb: int, name: str, ver: str) -> str:
    rng = random.Random(seed)
    used = set()
    names = {k: rn(rng, used) for k in "p c K S h y T W o X A l d u N M".split()}
    pool = extract_pool(payload, rng)
    y_blob = emit_pool_blob(pool)
    blob, key, real_len = compile_ir(payload, seed)
    boot = emit_boot(rng, names, y_blob)
    protect = emit_protect_block(rng, names)
    entry = 1000 + rng.randint(0, 400)
    load_s = 3500000 + rng.randint(0, 400000)
    n_states = max(280, min_kb * 8)
    vm = "return(function() " + protect + emit_vm_core(blob, key, real_len, names["W"], load_s, entry)
    cff = emit_cff(rng, names["W"], entry, n_states, names["c"], names["p"], len(pool))
    close_vm = f"else {names['W']}={entry} end end end end)() "
    close = "end)(...)"
    body = densify(boot + vm + cff + close_vm + close)
    header = "--// This file was created by %s v%s\n\n" % (name, ver)
    out = header + body + "\n"
    if len(out) < min_kb * 1024:
        extra_states = emit_cff(rng, names["W"], entry + 5000, min_kb * 4, names["c"], names["p"], len(pool))
        body = densify(boot + vm + cff + extra_states + close_vm + close)
        out = header + body + "\n"
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o", default="out/output_obf.lua")
    ap.add_argument("--seed", type=lambda x: int(x, 0), default=0x7C01)
    ap.add_argument("--min-kb", type=int, default=35)
    ap.add_argument("--name", default="2zvh")
    ap.add_argument("--version", default="1.0")
    a = ap.parse_args()
    payload = Path(a.input).read_text(encoding="utf-8", errors="ignore")
    out = build(payload, a.seed, a.min_kb, a.name, a.version)
    Path(a.o).parent.mkdir(parents=True, exist_ok=True)
    Path(a.o).write_text(out, encoding="utf-8")
    print(f"wrote {a.o} bytes={len(out)} kb={len(out)/1024:.1f}")

if __name__ == "__main__":
    main()
