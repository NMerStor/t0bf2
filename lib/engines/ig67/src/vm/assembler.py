#!/usr/bin/env python3
from __future__ import annotations
from typing import List, Tuple
from .bytecode import Image

def assemble_ops(ops: List[Tuple], constants: list = None, key: int = 0xA7C3E219) -> Image:
    return Image.from_program(ops, constants or [], key)
