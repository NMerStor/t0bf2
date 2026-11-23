#!/usr/bin/env python3
from __future__ import annotations
from typing import List, Any
from .bytecode import Image

def compile_print_msg(msg: str, key: int = 0x73A91C5D) -> Image:
    return Image.from_program(
        [
            ("GETGLOBAL", 0, 1),
            ("LOADK", 1, 2),
            ("CALL", 0, 1),
            ("RETURN", 0, 1),
        ],
        ["print", msg],
        key,
    )

def compile_source_bootstrap(src: str, key: int = 0xA7C3E219) -> Image:
    """Embed source; VM will GETGLOBAL load + CALL."""
    return Image.from_program(
        [
            ("GETGLOBAL", 0, 1),  # load
            ("LOADK", 1, 2),      # src
            ("CALL", 0, 1),
            ("CALL", 0, 0),       # call returned function
            ("RETURN", 0, 1),
        ],
        ["load", src],
        key,
    )

def compile_arith(a: int, b: int, key: int = 0x1111) -> Image:
    img = Image(key)
    # LOADN not in sparse set for b>255 — use LOADK
    ia = img.add_const(a)
    ib = img.add_const(b)
    img.emit("LOADK", 0, ia)
    img.emit("LOADK", 1, ib)
    img.emit("ADD", 2, 0, 1)
    img.emit("RETURN", 2, 1)
    return img.finalize()


def compile_loop_sum(n: int, key: int = 0x55) -> Image:
    """sum 1..n via FORPREP/FORLOOP style simplified with JMP."""
    img = Image(key)
    # R0=0 acc, R1=1 i, R2=n limit, R3=1 step
    i0 = img.add_const(0)
    i1 = img.add_const(1)
    iN = img.add_const(n)
    img.emit("LOADK", 0, i0)  # acc
    img.emit("LOADK", 1, i1)  # i
    img.emit("LOADK", 2, iN)  # limit
    img.emit("LOADK", 3, i1)  # step
    # loop: if i > n jmp end; acc=acc+i; i=i+1; jmp loop
    # TESTSET style manual
    loop = img.emit("LE", 4, 1, 2)  # R4 = i<=n
    # if not R4 skip body — use TEST
    img.emit("TEST", 4, 0)  # if not R4 then pc+2
    img.emit("JMP", 0, 128 + 4)  # skip to after loop (placeholder-ish)
    img.emit("ADD", 0, 0, 1)
    img.emit("ADD", 1, 1, 3)
    img.emit("JMP", 0, 128 - 5)
    img.emit("RETURN", 0, 1)
    return img.finalize()

def compile_concat(parts: list, key: int = 0x66) -> Image:
    img = Image(key)
    regs = []
    for i, p in enumerate(parts):
        idx = img.add_const(p)
        img.emit("LOADK", i, idx)
        regs.append(i)
    if len(regs) >= 2:
        img.emit("CONCAT", len(regs), 0, len(regs) - 1)
        img.emit("RETURN", len(regs), 1)
    else:
        img.emit("RETURN", 0, 1)
    return img.finalize()
