#!/usr/bin/env python3
"""VMC3-style image: magic, key, encrypted code words, constants, guard."""
from __future__ import annotations
import struct, base64, json
from typing import List, Any, Optional, Dict
from .opcodes import (
    encode, decode, encrypt_word, decrypt_word, verify_image, U32, OP, NAME
)

MAGIC = "VMC3"
VERSION = 3

class Image:
    def __init__(self, key: int = 0xA7C3E219):
        self.magic = MAGIC
        self.version = VERSION
        self.key = U32(key)
        self.constants: List[Any] = []
        self.code: List[int] = []  # stored encrypted
        self.prototypes: List[dict] = []
        self.entry = 1
        self.fuel = 1_000_000
        self.guard: Optional[int] = None

    def add_const(self, v: Any) -> int:
        for i, c in enumerate(self.constants):
            if c == v and type(c) is type(v):
                return i + 1  # 1-based like sample
        self.constants.append(v)
        return len(self.constants)

    def emit(self, op: str, a: int = 0, b: int = 0, c: int = 0) -> int:
        pc = len(self.code) + 1
        plain = encode(op, a, b, c)
        self.code.append(encrypt_word(plain, self.key, pc))
        return pc

    def finalize(self) -> "Image":
        self.guard = verify_image(self.key, self.code, self.constants)
        return self

    def to_table(self) -> dict:
        return {
            "magic": self.magic,
            "version": self.version,
            "key": self.key,
            "constants": self.constants,
            "code": list(self.code),
            "prototypes": self.prototypes,
            "entry": self.entry,
            "fuel": self.fuel,
            "guard": self.guard,
        }

    def to_lua_literal(self) -> str:
        def lit(v):
            if v is None:
                return "nil"
            if isinstance(v, bool):
                return "true" if v else "false"
            if isinstance(v, (int, float)):
                return str(v)
            if isinstance(v, str):
                return json.dumps(v, ensure_ascii=False)
            return json.dumps(str(v), ensure_ascii=False)
        parts = [
            f'magic="{self.magic}"',
            f"version={self.version}",
            f"key={self.key}",
            "constants={" + ",".join(lit(c) for c in self.constants) + "}",
            "code={" + ",".join(str(w) for w in self.code) + "}",
            "prototypes={}",
            f"entry={self.entry}",
            f"fuel={self.fuel}",
            f"guard={self.guard or 0}",
        ]
        return "{" + ",".join(parts) + "}"

    @classmethod
    def from_program(cls, program: List[tuple], constants: list, key: int = 0xA7C3E219) -> "Image":
        img = cls(key)
        for c in constants:
            img.constants.append(c)
        for ins in program:
            op = ins[0]
            a = ins[1] if len(ins) > 1 else 0
            b = ins[2] if len(ins) > 2 else 0
            c = ins[3] if len(ins) > 3 else 0
            img.emit(op, a, b, c)
        return img.finalize()


def image_from_dict(d: dict) -> Image:
    img = Image(d.get("key", 0xA7C3E219))
    img.magic = d.get("magic", MAGIC)
    img.version = d.get("version", VERSION)
    img.constants = list(d.get("constants") or [])
    img.code = list(d.get("code") or [])
    img.prototypes = list(d.get("prototypes") or [])
    img.entry = d.get("entry", 1)
    img.fuel = d.get("fuel", 1_000_000)
    img.guard = d.get("guard")
    return img
