#!/usr/bin/env python3
from __future__ import annotations
import base64, random, struct, hashlib
from typing import List, Tuple, Any

OPCODES = {
    "MOVE": 0, "LOADK": 1, "LOADN": 2, "LOADB": 3, "GETENV": 4, "SETENV": 5,
    "GETTABLE": 6, "SETTABLE": 7, "ADD": 8, "SUB": 9, "MUL": 10, "DIV": 11,
    "MOD": 12, "POW": 13, "UNM": 14, "NOT": 15, "LEN": 16, "CONCAT": 17,
    "JMP": 18, "EQ": 19, "LT": 20, "LE": 21, "TEST": 22, "CALL": 23,
    "RETURN": 24, "FORLOOP": 25, "FORPREP": 26, "TFORLOOP": 27, "SELF": 28,
    "CLOSURE": 29, "VARARG": 30, "LOADNIL": 31, "GETUPVAL": 32, "SETUPVAL": 33,
    "NEWTABLE": 34, "SETLIST": 35, "CLOSE": 36, "BXOR": 37, "BAND": 38,
    "BOR": 39, "SHL": 40, "SHR": 41, "BNOT": 42, "DECRYPT": 43, "OPCALL": 44,
    "ATCHECK": 45, "SINK": 46, "NOP": 47, "ASSERT": 48,
}

def encode_ins(op: str, a: int = 0, b: int = 0, c: int = 0) -> int:
    o = OPCODES[op] & 0x3F
    return o | ((a & 0xFF) << 6) | ((b & 0x1FF) << 14) | ((c & 0x1FF) << 23)

def decode_ins(w: int) -> Tuple[int, int, int, int]:
    return w & 0x3F, (w >> 6) & 0xFF, (w >> 14) & 0x1FF, (w >> 23) & 0x1FF

def rolling_xor_encrypt(data: bytes, key: List[int], seed_acc: int = 0x5A, mul: int = 13) -> bytes:
    out = bytearray(len(data))
    acc = seed_acc & 0xFF
    kl = len(key)
    for i in range(1, len(data) + 1):
        acc = (acc + key[(i - 1) % kl] + i * mul) & 0xFF
        out[i - 1] = data[i - 1] ^ acc ^ key[(i - 1) % kl]
    return bytes(out)

def rolling_xor_decrypt(data: bytes, key: List[int], seed_acc: int = 0x5A, mul: int = 13) -> bytes:
    return rolling_xor_encrypt(data, key, seed_acc, mul)

def derive_key(seed: int, length: int = 16) -> List[int]:
    rng = random.Random(seed)
    return [rng.randint(1, 255) for _ in range(length)]

def pack_constants(constants: list) -> bytes:
    raw = bytearray()
    raw += struct.pack("<I", len(constants))
    for k in constants:
        if isinstance(k, str):
            b = k.encode("utf-8")
            raw += b"\x01" + struct.pack("<H", len(b)) + b
        elif isinstance(k, bool):
            raw += b"\x02" + (b"\x01" if k else b"\x00")
        elif isinstance(k, int):
            raw += b"\x03" + struct.pack("<q", k)
        elif isinstance(k, float):
            raw += b"\x04" + struct.pack("<d", k)
        elif k is None:
            raw += b"\x00"
        else:
            b = str(k).encode("utf-8")
            raw += b"\x01" + struct.pack("<H", len(b)) + b
    return bytes(raw)

def pack_instructions(instructions: List[Tuple]) -> bytes:
    raw = bytearray()
    raw += struct.pack("<I", len(instructions))
    for item in instructions:
        op = item[0]
        a = item[1] if len(item) > 1 else 0
        b = item[2] if len(item) > 2 else 0
        c = item[3] if len(item) > 3 else 0
        if isinstance(op, str):
            raw += struct.pack("<I", encode_ins(op, a, b, c))
        else:
            raw += struct.pack("<I", int(op) | ((a & 0xFF) << 6) | ((b & 0x1FF) << 14) | ((c & 0x1FF) << 23))
    return bytes(raw)

def encode_chunk(instructions: List[Tuple], constants: list, rng: random.Random) -> Tuple[bytes, List[int]]:
    body = pack_constants(constants) + pack_instructions(instructions)
    checksum = hashlib.sha256(body).digest()[:4]
    body = checksum + body
    key = [rng.randint(1, 255) for _ in range(16)]
    enc = rolling_xor_encrypt(body, key)
    return enc, key

def source_to_ir(src: str) -> Tuple[list, list]:
    constants = [src]
    instructions = [
        ("LOADK", 0, 0, 0),
        ("GETENV", 1, 0, 0),
        ("LOADK", 2, 0, 0),
        ("CALL", 1, 2, 1),
        ("RETURN", 0, 1, 0),
    ]
    return instructions, constants

def compile_ir(src: str, seed: int = 0xBC01) -> Tuple[str, List[int], int]:
    rng = random.Random(seed)
    key = derive_key(seed, 16)
    raw = src.encode("utf-8")
    enc = rolling_xor_encrypt(raw, key)
    return base64.b64encode(enc).decode("ascii"), key, len(raw)

def compile_chunk_b64(src: str, seed: int = 0xBC01) -> Tuple[str, List[int]]:
    rng = random.Random(seed)
    ins, consts = source_to_ir(src)
    blob, key = encode_chunk(ins, consts, rng)
    return base64.b64encode(blob).decode("ascii"), key

def multi_layer_encrypt(data: bytes, layers: int, seed: int) -> Tuple[bytes, List[List[int]]]:
    rng = random.Random(seed)
    keys = []
    cur = data
    for layer in range(layers):
        key = [rng.randint(1, 255) for _ in range(16)]
        keys.append(key)
        cur = rolling_xor_encrypt(cur, key, seed_acc=0x5A ^ layer, mul=13 + layer)
    return cur, keys

def multi_layer_decrypt(data: bytes, keys: List[List[int]]) -> bytes:
    cur = data
    for layer in range(len(keys) - 1, -1, -1):
        cur = rolling_xor_decrypt(cur, keys[layer], seed_acc=0x5A ^ layer, mul=13 + layer)
    return cur

def shuffle_opcodes(seed: int) -> dict:
    rng = random.Random(seed)
    names = list(OPCODES.keys())
    ids = list(range(len(names)))
    rng.shuffle(ids)
    return {names[i]: ids[i] for i in range(len(names))}

def emit_key_schedule_lua(key: List[int], var: str = "kk") -> str:
    return f"local {var}={{{','.join(str(k) for k in key)}}}"

def emit_decrypt_loop_lua(blob_expr: str, key_var: str, out_var: str, len_var: str) -> str:
    return (
        f"local {out_var}={{}} local _acc=90 local _i=1 "
        f"while _i<={len_var} do "
        f"_acc=(_acc+{key_var}[(_i-1)%16+1]+_i*13)%256 "
        f"local _bi=string.byte({blob_expr},_i) or 0 "
        f"{out_var}[_i]=string.char((function(x,y) local r=0 local p=1 for _=0,7 do if x%2~=y%2 then r=r+p end "
        f"x=math.floor(x/2) y=math.floor(y/2) p=p*2 end return r end)(_bi,(function(x,y) local r=0 local p=1 for _=0,7 do "
        f"if x%2~=y%2 then r=r+p end x=math.floor(x/2) y=math.floor(y/2) p=p*2 end return r end)(_acc,{key_var}[(_i-1)%16+1]))) "
        f"_i=_i+1 end "
    )
