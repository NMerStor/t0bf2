#!/usr/bin/env python3
"""Emit Luau VMC3 runtime + optional source-decrypt path for obfuscate.py."""
from __future__ import annotations
import base64
from typing import List, Optional
from .bytecode import Image
from .opcodes import U32

def emit_bit_helpers() -> str:
    return (
        "local function U(x) x=x%4294967296 if x<0 then x=x+4294967296 end return math.floor(x) end "
        "local function mul32(a,b) "
        "a=U(a) b=U(b) "
        "local a0=a%65536 local a1=math.floor(a/65536) "
        "local b0=b%65536 local b1=math.floor(b/65536) "
        "local lo=a0*b0 "
        "local mid=a1*b0+a0*b1 "
        "return U(lo+(mid%65536)*65536) end "
        "local function bxor(a,b) a=U(a) b=U(b) local r=0 local p=1 for i=0,31 do if a%2~=b%2 then r=r+p end a=math.floor(a/2) b=math.floor(b/2) p=p*2 end return r end "
        "local function band(a,b) a=U(a) b=U(b) local r=0 local p=1 for i=0,31 do if a%2>0 and b%2>0 then r=r+p end a=math.floor(a/2) b=math.floor(b/2) p=p*2 end return r end "
        "local function bor(a,b) return bxor(band(a,b),bxor(a,b)) end "
        "local function rshift(a,n) a=U(a) n=n%32 return math.floor(a/2^n) end "
        "local function lshift(a,n) a=U(a) n=n%32 for i=1,n do a=a*2 if a>=4294967296 then a=a-4294967296 end end return a end "
        "local function F(x,k) x=U(x+k) x=bxor(x,rshift(x,16)) x=mul32(x,2146121005) x=bxor(x,rshift(x,15)) x=mul32(x,2221713035) return bxor(x,rshift(x,16)) end "
        "local function stream(key,pc) "
        "local x=U(key) "
        "x=U(x+mul32(pc,2654435761)) "
        "x=bxor(x,rshift(x,16)) "
        "x=mul32(x,2246822519) "
        "x=bxor(x,rshift(x,13)) "
        "x=mul32(x,3266489917) "
        "x=bxor(x,rshift(x,16)) "
        "return x end "
        "local function encw(w,key,pc) return bxor(w,stream(key,pc)) end "
        "local function decw(w,key,pc) return encw(w,key,pc) end "
        "local function UW(w) return band(w,255),band(rshift(w,8),255),band(rshift(w,16),255),band(rshift(w,24),255) end "
    )


def emit_verify_lua() -> str:
    return (
        "local function verify(image) "
        "local h=U(2166136261) h=F(h,image.key) "
        "for i,w in ipairs(image.code) do h=F(h,U(w+i*33)) end "
        "for i,v in ipairs(image.constants) do local s=tostring(v) for j=1,#s do h=F(h,string.byte(s,j)+i*17+j) end end "
        "return h end "
    )

def emit_execute_lua() -> str:
    """Full VMC3 dispatch loop."""
    return (
        "local function execute(image,supplied) "
        "if type(image)~=\"table\" then error(\"bad\",0) end "
        "if image.magic~=\"VMC3\" or image.version~=3 then error(\"ver\",0) end "
        "if image.guard and image.guard~=verify(image) then error(\"guard\",0) end "
        "local env=supplied or _G "
        "local Rg,Up,pc,key,code,K={}, {}, image.entry or 1, image.key, image.code, image.constants "
        "local fuel=image.fuel or 1000000 "
        "while true do "
        "fuel=fuel-1 if fuel<=0 then error(\"fuel\",0) end "
        "local raw=decw(code[pc],key,pc) "
        "local op,a,b,c=UW(raw) "
        "if op==11 then pc=pc+1 "
        "elseif op==23 then Rg[a]=K[b] pc=pc+1 "
        "elseif op==37 then Rg[a]=Rg[b] pc=pc+1 "
        "elseif op==41 then Rg[a]=Up[b] pc=pc+1 "
        "elseif op==53 then Up[b]=Rg[a] pc=pc+1 "
        "elseif op==67 then Rg[a]=env[K[b]] if Rg[a]==nil then Rg[a]=_G[K[b]] end pc=pc+1 "
        "elseif op==71 then env[K[b]]=Rg[a] pc=pc+1 "
        "elseif op==79 then Rg[a]={} pc=pc+1 "
        "elseif op==83 then Rg[a]=Rg[b][Rg[c]] pc=pc+1 "
        "elseif op==97 then Rg[a][Rg[b]]=Rg[c] pc=pc+1 "
        "elseif op==101 then Rg[a]=Rg[b]+Rg[c] pc=pc+1 "
        "elseif op==103 then Rg[a]=Rg[b]-Rg[c] pc=pc+1 "
        "elseif op==107 then Rg[a]=Rg[b]*Rg[c] pc=pc+1 "
        "elseif op==109 then Rg[a]=Rg[b]/Rg[c] pc=pc+1 "
        "elseif op==113 then Rg[a]=Rg[b]%Rg[c] pc=pc+1 "
        "elseif op==127 then Rg[a]=Rg[b]^Rg[c] pc=pc+1 "
        "elseif op==131 then Rg[a]=-Rg[b] pc=pc+1 "
        "elseif op==137 then Rg[a]=not Rg[b] pc=pc+1 "
        "elseif op==139 then Rg[a]=#Rg[b] pc=pc+1 "
        "elseif op==149 then Rg[a]=Rg[b]==Rg[c] pc=pc+1 "
        "elseif op==151 then Rg[a]=Rg[b]<Rg[c] pc=pc+1 "
        "elseif op==157 then Rg[a]=Rg[b]<=Rg[c] pc=pc+1 "
        "elseif op==163 then if (not Rg[a])==(b~=0) then pc=pc+2 else pc=pc+1 end "
        "elseif op==167 then if Rg[b] then Rg[a]=Rg[b] pc=pc+1 else pc=pc+2 end "
        "elseif op==173 then pc=pc+(b-128) "
        "elseif op==179 then Rg[a]=Rg[a]-Rg[a+2] pc=pc+(b-128) "
        "elseif op==181 then Rg[a]=Rg[a]+Rg[a+2] local step=Rg[a+2] local limit=Rg[a+1] local idx=Rg[a] "
        "local ok=(step>=0 and idx<=limit) or (step<0 and idx>=limit) if ok then Rg[a+3]=idx pc=pc+(b-128) else pc=pc+1 end "
        "elseif op==193 or op==197 then "
        "local fn=Rg[a] local args={} for i=1,b do args[i]=Rg[a+i] end "
        "if type(fn)==\"function\" then local ret={fn(table.unpack(args))} Rg[a]=ret[1] for i=2,#ret do Rg[a+i-1]=ret[i] end "
        "if op==197 then return table.unpack(ret) end end pc=pc+1 "
        "elseif op==199 then local out={} for i=0,b-1 do out[i+1]=Rg[a+i] end return table.unpack(out,1,b) "
        "elseif op==211 then local x=\"\" for i=b,c do x=x..tostring(Rg[i]) end Rg[a]=x pc=pc+1 "
        "elseif op==233 then return Rg[a] "
        "elseif op==239 then local _=Rg[a] pc=pc+1 "
        "elseif op==241 then if not _at then while true do end end pc=pc+1 "
        "else local q=F(raw,key) if band(q,15)==9 then pc=pc+1 else error(\"op\",0) end end "
        "end end "
    )

def emit_vm_module() -> str:
    return emit_bit_helpers() + emit_verify_lua() + emit_execute_lua()

def emit_helpers() -> str:
    return (
        "local function _B(s) local B='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' "
        "local t={} for i=1,#s,4 do local n=0 for j=0,3 do local ch=string.sub(s,i+j,i+j) local v=0 "
        "if ch and ch~='=' then local f=string.find(B,ch,1,true) v=f and (f-1) or 0 end n=n*64+v end "
        "local b1=math.floor(n/65536)%256 local b2=math.floor(n/256)%256 local b3=n%256 "
        "t[#t+1]=string.char(b1) if string.sub(s,i+2,i+2)~='=' then t[#t+1]=string.char(b2) end "
        "if string.sub(s,i+3,i+3)~='=' then t[#t+1]=string.char(b3) end end return table.concat(t) end "
        "local function _X(x,y) local r=0 local pp=1 for _=0,7 do if x%2~=y%2 then r=r+pp end "
        "x=math.floor(x/2) y=math.floor(y/2) pp=pp*2 end return r end "
    )

def emit_vm_core(blob_b64: str, key: List[int], real_len: int, W: str, load_s: int, entry: int) -> str:
    """Used by obfuscate.py: ship full VMC3 runtime + decrypt payload via load."""
    key_lit = ",".join(str(k) for k in key)
    return (
        emit_helpers()
        + emit_vm_module()
        + f"local {W}={load_s} "
        + f"while true do "
        + f"if {W}<{load_s+1} then "
        + f"if {W}=={load_s} then "
        + f"local dd=_B('{blob_b64}') "
        + f"local oo,kk,ii,aa,nn={{}},{{{key_lit}}},1,90,{real_len} "
        + f"while ii<=nn do "
        + f"aa=(aa+kk[(ii-1)%16+1]+ii*13)%256 "
        + f"local bi=string.byte(dd,ii) or 0 "
        + f"oo[ii]=string.char(_X(bi,_X(aa,kk[(ii-1)%16+1]))%256) "
        + f"ii=ii+1 end "
        + f"local cc=table.concat(oo) "
        + f"local Ldr=load "
        + f"if type(Ldr)~=\"function\" then Ldr=rawget(_G,\"loadstring\") end "
        + f"local f=Ldr and Ldr(cc,\"@x\",\"t\") "
        + f"if not f and Ldr then f=Ldr(cc) end "
        + f"if f then return f() end "
        + f"{W}={entry} "
    )


def emit_run_image_literal(image: Image) -> str:
    """Emit: local image=<literal>; return execute(image, env)"""
    return (
        emit_vm_module()
        + f"local image={image.to_lua_literal()} "
        + "return execute(image, getfenv and getfenv() or _ENV or _G) "
    )
