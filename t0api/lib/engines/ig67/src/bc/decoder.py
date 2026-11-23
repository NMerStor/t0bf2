#!/usr/bin/env python3
from __future__ import annotations
import base64, struct, hashlib
from typing import List, Tuple, Any

def rolling_xor_decrypt(data: bytes, key: List[int], seed_acc: int = 0x5A, mul: int = 13) -> bytes:
    out = bytearray(len(data))
    acc = seed_acc & 0xFF
    kl = len(key)
    for i in range(1, len(data) + 1):
        acc = (acc + key[(i - 1) % kl] + i * mul) & 0xFF
        out[i - 1] = data[i - 1] ^ acc ^ key[(i - 1) % kl]
    return bytes(out)

def unpack_constants(raw: bytes, pos: int = 0) -> Tuple[list, int]:
    nconst = struct.unpack_from("<I", raw, pos)[0]
    pos += 4
    constants = []
    for _ in range(nconst):
        tag = raw[pos]
        pos += 1
        if tag == 1:
            ln = struct.unpack_from("<H", raw, pos)[0]
            pos += 2
            constants.append(raw[pos:pos + ln].decode("utf-8", errors="replace"))
            pos += ln
        elif tag == 2:
            constants.append(raw[pos] == 1)
            pos += 1
        elif tag == 3:
            constants.append(struct.unpack_from("<q", raw, pos)[0])
            pos += 8
        elif tag == 4:
            constants.append(struct.unpack_from("<d", raw, pos)[0])
            pos += 8
        else:
            constants.append(None)
    return constants, pos

def unpack_instructions(raw: bytes, pos: int = 0) -> Tuple[list, int]:
    nins = struct.unpack_from("<I", raw, pos)[0]
    pos += 4
    ins = []
    for _ in range(nins):
        w = struct.unpack_from("<I", raw, pos)[0]
        pos += 4
        op = w & 0x3F
        a = (w >> 6) & 0xFF
        b = (w >> 14) & 0x1FF
        c = (w >> 23) & 0x1FF
        ins.append((op, a, b, c))
    return ins, pos

def decode_chunk(raw: bytes, key: List[int]) -> Tuple[list, list]:
    plain = rolling_xor_decrypt(raw, key)
    checksum, body = plain[:4], plain[4:]
    if hashlib.sha256(body).digest()[:4] != checksum:
        raise ValueError("bytecode checksum mismatch")
    constants, pos = unpack_constants(body, 0)
    ins, _ = unpack_instructions(body, pos)
    return constants, ins

def decrypt_blob(b64: str, key: List[int]) -> bytes:
    data = base64.b64decode(b64)
    return rolling_xor_decrypt(data, key)

def verify_and_load_source(b64: str, key: List[int]) -> str:
    raw = decrypt_blob(b64, key)
    return raw.decode("utf-8")

def disassemble(ins: list, constants: list) -> List[str]:
    names = [
        "MOVE","LOADK","LOADN","LOADB","GETENV","SETENV","GETTABLE","SETTABLE",
        "ADD","SUB","MUL","DIV","MOD","POW","UNM","NOT","LEN","CONCAT","JMP",
        "EQ","LT","LE","TEST","CALL","RETURN","FORLOOP","FORPREP","TFORLOOP",
        "SELF","CLOSURE","VARARG","LOADNIL","GETUPVAL","SETUPVAL","NEWTABLE",
        "SETLIST","CLOSE","BXOR","BAND","BOR","SHL","SHR","BNOT","DECRYPT","OPCALL",
        "ATCHECK","SINK","NOP","ASSERT",
    ]
    lines = []
    for i, (op, a, b, c) in enumerate(ins):
        name = names[op] if op < len(names) else f"OP{op}"
        extra = ""
        if name == "LOADK" and b < len(constants):
            extra = f" ; {constants[b]!r}"[:40]
        lines.append(f"[{i:04d}] {name:10s} A={a} B={b} C={c}{extra}")
    return lines

def emit_b64_decoder_lua() -> str:
    return (
        "local function _B(s) local B='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' "
        "local t={} for i=1,#s,4 do local n=0 for j=0,3 do local ch=string.sub(s,i+j,i+j) local v=0 "
        "if ch and ch~='=' then local f=string.find(B,ch,1,true) v=f and (f-1) or 0 end n=n*64+v end "
        "local b1=math.floor(n/65536)%256 local b2=math.floor(n/256)%256 local b3=n%256 "
        "t[#t+1]=string.char(b1) if string.sub(s,i+2,i+2)~='=' then t[#t+1]=string.char(b2) end "
        "if string.sub(s,i+3,i+3)~='=' then t[#t+1]=string.char(b3) end end return table.concat(t) end "
    )

def emit_xor_lua() -> str:
    return (
        "local function _X(x,y) local r=0 local pp=1 for _=0,7 do if x%2~=y%2 then r=r+pp end "
        "x=math.floor(x/2) y=math.floor(y/2) pp=pp*2 end return r end "
    )
