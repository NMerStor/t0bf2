#!/usr/bin/env python3
"""2zvh VM ISA — sparse opcode IDs, 32-bit words, encrypted-at-rest ready."""
from __future__ import annotations
from typing import Dict, List, Tuple, Optional

# Sparse opcode numbers (not sequential) — harder to pattern-match
OP: Dict[str, int] = {
    "NOP": 11,
    "LOADK": 23,
    "MOVE": 37,
    "GETUP": 41,
    "SETUP": 53,
    "GETGLOBAL": 67,
    "SETGLOBAL": 71,
    "NEWTABLE": 79,
    "GETTABLE": 83,
    "SETTABLE": 97,
    "ADD": 101,
    "SUB": 103,
    "MUL": 107,
    "DIV": 109,
    "MOD": 113,
    "POW": 127,
    "UNM": 131,
    "NOT": 137,
    "LEN": 139,
    "EQ": 149,
    "LT": 151,
    "LE": 157,
    "TEST": 163,
    "TESTSET": 167,
    "JMP": 173,
    "FORPREP": 179,
    "FORLOOP": 181,
    "CLOSURE": 191,
    "CALL": 193,
    "TAILCALL": 197,
    "RETURN": 199,
    "CONCAT": 211,
    "VARARG": 223,
    "EXTRA": 227,
    "HALT": 233,
    "SINK": 239,
    "ATCHECK": 241,
    "LOADN": 251,
    "LOADB": 257,
    "LOADNIL": 263,
    "SELF": 269,
    "BNOT": 271,
    "BAND": 277,
    "BOR": 281,
    "BXOR": 283,
    "SHL": 293,
    "SHR": 307,
    "DECRYPT": 311,
    "ASSERT": 313,
}

NAME: Dict[int, str] = {v: k for k, v in OP.items()}
OP_NAMES: List[str] = list(OP.keys())
OP_ENCODING: Dict[str, int] = dict(OP)

def U32(x: int) -> int:
    return x & 0xFFFFFFFF

def pack_word(op: int, a: int = 0, b: int = 0, c: int = 0) -> int:
    return (
        (op & 255)
        | ((a & 255) << 8)
        | ((b & 255) << 16)
        | ((c & 255) << 24)
    ) & 0xFFFFFFFF

def unpack_word(w: int) -> Tuple[int, int, int, int]:
    return w & 255, (w >> 8) & 255, (w >> 16) & 255, (w >> 24) & 255

def encode(op: str, a: int = 0, b: int = 0, c: int = 0) -> int:
    if op not in OP:
        raise KeyError(op)
    return pack_word(OP[op], a, b, c)

def decode(w: int) -> Tuple[str, int, int, int]:
    op, a, b, c = unpack_word(w)
    return NAME.get(op, f"UNK_{op}"), a, b, c

def scramble_mix(x: int, k: int) -> int:
    """Avalanche mixer used for keystream + integrity (F-style)."""
    x = U32(x + k)
    x ^= x >> 16
    x = U32(x * 0x7FEB352D)
    x ^= x >> 15
    x = U32(x * 0x846CA68B)
    return x ^ (x >> 16)

def stream_word(key: int, pc: int) -> int:
    """Per-instruction keystream — mul32-safe constants for Luau parity."""
    x = U32(key)
    x = U32(x + U32(pc * 2654435761))
    x ^= (x >> 16)
    x = U32(x * 2246822519)
    x ^= (x >> 13)
    x = U32(x * 3266489917)
    x ^= (x >> 16)
    return x


def encrypt_word(w: int, key: int, pc: int) -> int:
    return U32(w ^ stream_word(key, pc))

def decrypt_word(w: int, key: int, pc: int) -> int:
    return encrypt_word(w, key, pc)  # XOR self-inverse

def verify_image(key: int, code: List[int], constants: list) -> int:
    h = U32(0x811C9DC5)
    h = scramble_mix(h, key)
    for i, w in enumerate(code, 1):
        h = scramble_mix(h, U32(w + i * 33))
    for i, v in enumerate(constants, 1):
        s = str(v)
        for j, ch in enumerate(s, 1):
            h = scramble_mix(h, ord(ch) + i * 17 + j)
    return h

def is_jump(op: str) -> bool:
    return op in ("JMP", "TEST", "TESTSET", "FORPREP", "FORLOOP")

def is_alu(op: str) -> bool:
    return op in ("ADD", "SUB", "MUL", "DIV", "MOD", "POW", "UNM", "BNOT", "BAND", "BOR", "BXOR", "SHL", "SHR")


def disassemble_program(code: List[int], key: int, constants: list = None) -> List[str]:
    lines = []
    for pc, enc_w in enumerate(code, 1):
        w = decrypt_word(enc_w, key, pc)
        name, a, b, c = decode(w)
        extra = ""
        if name == "LOADK" and constants and 1 <= b <= len(constants):
            extra = f" ; {constants[b-1]!r}"[:40]
        lines.append(f"[{pc:04d}] {name:12s} A={a} B={b} C={c}{extra}")
    return lines

def opcode_coverage() -> Dict[str, int]:
    return dict(OP)

def randomize_secondary_key(seed: int) -> int:
    import random
    rng = random.Random(seed)
    return U32(rng.randint(1, 0xFFFFFF00))
