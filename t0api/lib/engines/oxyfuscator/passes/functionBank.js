import { TAMPER_ART } from "../tamperArt.js";
import { BASE85_CHARS, base85Encode, lzCompress } from "../compression.js";
function utf8Bytes(value) {
    return Array.from(new TextEncoder().encode(value));
}
function encode(bytes, seed) {
    let state = seed >>> 0;
    const output = [];
    for (const byte of bytes) {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        const key = (state >>> 16) & 0xff;
        output.push((byte + key) & 0xff);
    }
    return output;
}
function checksum(values) {
    let value = 0;
    const mod = 2147483647;
    for (let i = 0; i < values.length; i++) {
        value = (value * 131 + values[i] + (i + 1)) % mod;
    }
    return value;
}
function luaByteString(values) {
    return `"${values.map(value => `\\${value.toString().padStart(3, "0")}`).join("")}"`;
}
function numberExpr(value, context) {
    const delta = context.random.int(7, 8191);
    const mode = context.random.int(0, 4);
    if (mode === 0)
        return `(${value + delta}-${delta})`;
    if (mode === 1)
        return `(${value - delta}+${delta})`;
    if (mode === 2)
        return `(${value * 3}-${value * 2})`;
    if (mode === 3) {
        const pad = context.random.int(1, 4095);
        return `(${value + pad * 2}-${pad}-${pad})`;
    }
    const pad = context.random.int(1, 2047);
    return `(${value - pad * 2}+${pad}+${pad})`;
}
function uniqueOpcode(context, used) {
    while (true) {
        const value = context.random.int(17, 250);
        if (!used.has(value)) {
            used.add(value);
            return value;
        }
    }
}
function uniqueSlot(context, used) {
    while (true) {
        const value = context.random.int(0x400, 0x1fffff);
        if (!used.has(value)) {
            used.add(value);
            return value;
        }
    }
}
function internal(context, used) {
    while (true) {
        const value = `__o${context.random.int(0x1000, 0xfffff).toString(36)}`;
        if (!used.has(value)) {
            used.add(value);
            return value;
        }
    }
}
function guardStep(value, mul, add) {
    return (Math.imul(value, mul) + add) >>> 0;
}
function noiseStep(value, mul, add, xorValue) {
    const mixed = (Math.imul(value, mul) + add) >>> 0;
    return (mixed ^ xorValue) >>> 0;
}
function shuffle(values, context) {
    for (let i = values.length - 1; i > 0; i--) {
        const j = context.random.int(0, i);
        [values[i], values[j]] = [values[j], values[i]];
    }
    return values;
}
export class FunctionBankPass {
    enableTimingCheck;
    intensity;
    name = "function-bank-layered-vm-v5-compressed";
    constructor(enableTimingCheck = true, intensity = 1) {
        this.enableTimingCheck = enableTimingCheck;
        this.intensity = intensity;
    }
    run(source, context) {
        const usedNames = new Set();
        const usedOpcodes = new Set();
        const usedSlots = new Set();
        const slotEntry = uniqueSlot(context, usedSlots);
        const slotHash = uniqueSlot(context, usedSlots);
        const slotVerifyProgram = uniqueSlot(context, usedSlots);
        const slotVerifyBank = uniqueSlot(context, usedSlots);
        const slotShadowStage = uniqueSlot(context, usedSlots);
        const slotShadowRunner = uniqueSlot(context, usedSlots);
        const slotTiming = uniqueSlot(context, usedSlots);
        const slotCollect = uniqueSlot(context, usedSlots);
        const slotVerifyPayload = uniqueSlot(context, usedSlots);
        const slotDecode = uniqueSlot(context, usedSlots);
        const slotCompile = uniqueSlot(context, usedSlots);
        const slotCall = uniqueSlot(context, usedSlots);
        const slotFail = uniqueSlot(context, usedSlots);
        const slotBase85 = uniqueSlot(context, usedSlots);
        const slotDecompress = uniqueSlot(context, usedSlots);
        const opVerifyProgram = uniqueOpcode(context, usedOpcodes);
        const opShadowStage = uniqueOpcode(context, usedOpcodes);
        const opVerifyBank = uniqueOpcode(context, usedOpcodes);
        const opTiming = uniqueOpcode(context, usedOpcodes);
        const opCollect = uniqueOpcode(context, usedOpcodes);
        const opVerifyPayload = uniqueOpcode(context, usedOpcodes);
        const opDecode = uniqueOpcode(context, usedOpcodes);
        const opCompile = uniqueOpcode(context, usedOpcodes);
        const opCall = uniqueOpcode(context, usedOpcodes);
        const opFail = uniqueOpcode(context, usedOpcodes);
        const fakeOpcodeCount = context.random.int(18 + this.intensity * 5, 24 + this.intensity * 7);
        const fakeOpcodes = [];
        const fakeSlots = [];
        const fakeTransforms = [];
        for (let n = 0; n < fakeOpcodeCount; n++) {
            fakeOpcodes.push(uniqueOpcode(context, usedOpcodes));
            fakeSlots.push(uniqueSlot(context, usedSlots));
            fakeTransforms.push({
                mul: context.random.int(19, 249) | 1,
                add: context.random.int(0x1000, 0x7fffff) >>> 0,
                xorValue: context.random.int(0x1000, 0x7fffffff) >>> 0
            });
        }
        const shadowOps = {
            load: uniqueOpcode(context, usedOpcodes),
            xor: uniqueOpcode(context, usedOpcodes),
            addk: uniqueOpcode(context, usedOpcodes),
            mulk: uniqueOpcode(context, usedOpcodes),
            rol: uniqueOpcode(context, usedOpcodes),
            mix: uniqueOpcode(context, usedOpcodes),
            finish: uniqueOpcode(context, usedOpcodes)
        };
        const shadowSlots = {
            load: uniqueSlot(context, usedSlots),
            xor: uniqueSlot(context, usedSlots),
            addk: uniqueSlot(context, usedSlots),
            mulk: uniqueSlot(context, usedSlots),
            rol: uniqueSlot(context, usedSlots),
            mix: uniqueSlot(context, usedSlots),
            finish: uniqueSlot(context, usedSlots)
        };
        const opcodeMask = context.random.int(1, 255);
        const handlerOpcodeMask = context.random.int(1, 255);
        const handlerSlotMask = context.random.int(0x400, 0x1fffff);
        const shadowOpcodeMask = context.random.int(1, 255);
        const shadowHandlerOpcodeMask = context.random.int(1, 255);
        const shadowHandlerSlotMask = context.random.int(0x400, 0x1fffff);
        const alphabet = shuffle(BASE85_CHARS.split(""), context).join("");
        const rawBytes = utf8Bytes(source);
        const compressedBytes = lzCompress(rawBytes);
        const codec = compressedBytes.length + 4 < rawBytes.length ? 1 : 0;
        const packedBytes = codec === 1 ? compressedBytes : rawBytes;
        const seed = context.random.int(1, 0x7fffffff) >>> 0;
        const encoded = encode(packedBytes, seed);
        const transport = base85Encode(encoded, alphabet);
        const payloadChecksum = checksum(utf8Bytes(transport));
        const tamperRaw = utf8Bytes(TAMPER_ART);
        const tamperCompressed = lzCompress(tamperRaw);
        const tamperCodec = tamperCompressed.length + 4 < tamperRaw.length ? 1 : 0;
        const tamperPacked = tamperCodec === 1 ? tamperCompressed : tamperRaw;
        const tamperSeed = context.random.int(1, 0x7fffffff) >>> 0;
        const tamperEncoded = encode(tamperPacked, tamperSeed);
        const tamperTransport = base85Encode(tamperEncoded, alphabet);
        const guard0 = context.random.int(0x10000, 0x7fffffff) >>> 0;
        const guardMul1 = context.random.int(17, 251) | 1;
        const guardAdd1 = context.random.int(0x1000, 0x7fffff) >>> 0;
        const guard1 = guardStep(guard0, guardMul1, guardAdd1);
        const shadowConstants = Array.from({ length: context.random.int(18 + this.intensity * 4, 28 + this.intensity * 6) }, () => context.random.int(1, 0xffff) >>> 0);
        const rp = shuffle([1, 2, 3, 4, 5, 6], context);
        const ci = () => context.random.int(1, shadowConstants.length);
        const shadowPlain = [
            [shadowOps.load, rp[0], ci(), ci()],
            [shadowOps.load, rp[1], ci(), ci()],
            [shadowOps.load, rp[2], ci(), ci()],
            [shadowOps.xor, rp[3], rp[0], rp[1]],
            [shadowOps.addk, rp[4], rp[3], ci()],
            [shadowOps.rol, rp[5], rp[4], ci()]
        ];
        const shadowExtra = context.random.int(18 + this.intensity * 8, 28 + this.intensity * 12);
        for (let n = 0; n < shadowExtra; n++) {
            const a = context.random.int(1, 6);
            const b = context.random.int(1, 6);
            const c = context.random.int(1, 6);
            const mode = context.random.int(0, 4);
            if (mode === 0)
                shadowPlain.push([shadowOps.xor, a, b, c]);
            else if (mode === 1)
                shadowPlain.push([shadowOps.addk, a, b, ci()]);
            else if (mode === 2)
                shadowPlain.push([shadowOps.mulk, a, b, ci()]);
            else if (mode === 3)
                shadowPlain.push([shadowOps.rol, a, b, ci()]);
            else
                shadowPlain.push([shadowOps.mix, a, b, c]);
        }
        shadowPlain.push([shadowOps.finish, rp[3], rp[4], rp[5]]);
        const shadowRegs = Array(7).fill(0);
        let shadowToken = 0;
        for (const ins of shadowPlain) {
            const [op, a, b, c] = ins;
            if (op === shadowOps.load) {
                shadowRegs[a] = shadowConstants[(b - 1) % shadowConstants.length] >>> 0;
            }
            else if (op === shadowOps.xor) {
                shadowRegs[a] = ((shadowRegs[b] ?? 0) ^ (shadowRegs[c] ?? 0)) >>> 0;
            }
            else if (op === shadowOps.addk) {
                shadowRegs[a] = (((shadowRegs[b] ?? 0) + shadowConstants[(c - 1) % shadowConstants.length]) >>> 0);
            }
            else if (op === shadowOps.mulk) {
                const x = shadowRegs[b] ?? 0;
                const k = shadowConstants[(c - 1) % shadowConstants.length];
                const k2 = shadowConstants[c % shadowConstants.length];
                shadowRegs[a] = (Math.imul(x, (k | 1)) + k2) >>> 0;
            }
            else if (op === shadowOps.rol) {
                const value = shadowRegs[b] ?? 0;
                const count = shadowConstants[(c - 1) % shadowConstants.length] % 31;
                shadowRegs[a] = ((value << count) | (value >>> (32 - count))) >>> 0;
            }
            else if (op === shadowOps.mix) {
                const left = shadowRegs[b] ?? 0;
                const right = shadowRegs[c] ?? 0;
                const k = shadowConstants[(a + b + c) % shadowConstants.length];
                shadowRegs[a] = (((left + right) >>> 0) ^ k) >>> 0;
            }
            else if (op === shadowOps.finish) {
                shadowToken = ((shadowRegs[a] ?? 0) ^ (shadowRegs[b] ?? 0) ^ (shadowRegs[c] ?? 0) ^ shadowConstants[0]) >>> 0;
            }
        }
        const guardMul2 = context.random.int(17, 251) | 1;
        const guardShadowAdd = ((shadowToken ^ context.random.int(0x1000, 0x7fffff)) >>> 0);
        const guard2 = guardStep(guard1, guardMul2, guardShadowAdd);
        const guardMul3 = context.random.int(17, 251) | 1;
        const guardGood3 = context.random.int(0x1000, 0x7fffff) >>> 0;
        const guardBad3 = (guardGood3 ^ 0x5a5a5a) >>> 0;
        const guard3 = guardStep(guard2, guardMul3, guardGood3);
        const guardMul4 = context.random.int(17, 251) | 1;
        const guardAdd4 = context.random.int(0x1000, 0x7fffff) >>> 0;
        const guard4 = guardStep(guard3, guardMul4, guardAdd4);
        const stages = [
            opVerifyProgram,
            opShadowStage,
            opVerifyBank,
            opTiming,
            opCollect,
            opVerifyPayload,
            opDecode,
            opCompile,
            opCall
        ];
        const noiseBuckets = Array.from({ length: stages.length - 1 }, () => []);
        fakeOpcodes.forEach((_, index) => {
            noiseBuckets[context.random.int(0, noiseBuckets.length - 1)].push(index);
        });
        const sequence = [];
        for (let s = 0; s < stages.length; s++) {
            sequence.push({ kind: "stage", op: stages[s] });
            if (s < noiseBuckets.length) {
                for (const idx of shuffle([...noiseBuckets[s]], context)) {
                    sequence.push({ kind: "noise", op: fakeOpcodes[idx], index: idx });
                }
            }
        }
        sequence.push({ kind: "stage", op: opFail });
        const noise0 = context.random.int(0x10000, 0x7fffffff) >>> 0;
        let noiseState = noise0;
        let noiseAtVerifyPayload = noise0;
        let noiseAtCompile = noise0;
        for (const item of sequence) {
            if (item.kind === "noise") {
                const t = fakeTransforms[item.index];
                noiseState = noiseStep(noiseState, t.mul, t.add, t.xorValue);
            }
            else if (item.op === opVerifyPayload) {
                noiseAtVerifyPayload = noiseState;
            }
            else if (item.op === opCompile) {
                noiseAtCompile = noiseState;
            }
        }
        const programPlain = sequence.map(item => item.op);
        const program = programPlain.map(op => (op ^ opcodeMask) & 0xff);
        const programChecksum = checksum(program);
        const failIndex = programPlain.indexOf(opFail) + 1;
        const bank = internal(context, usedNames);
        const ctx = internal(context, usedNames);
        const handlers = internal(context, usedNames);
        const opcode = internal(context, usedNames);
        const rawOpcode = internal(context, usedNames);
        const handler = internal(context, usedNames);
        const values = internal(context, usedNames);
        const result = internal(context, usedNames);
        const index = internal(context, usedNames);
        const out = internal(context, usedNames);
        const chunk = internal(context, usedNames);
        const chunkSlot = internal(context, usedNames);
        const state = internal(context, usedNames);
        const stream = internal(context, usedNames);
        const byte = internal(context, usedNames);
        const loader = internal(context, usedNames);
        const fn = internal(context, usedNames);
        const err = internal(context, usedNames);
        const ok = internal(context, usedNames);
        const s1 = internal(context, usedNames);
        const s2 = internal(context, usedNames);
        const bad = internal(context, usedNames);
        const art = internal(context, usedNames);
        const artFn = internal(context, usedNames);
        const artErr = internal(context, usedNames);
        const i = internal(context, usedNames);
        const j = internal(context, usedNames);
        const k = internal(context, usedNames);
        const mapOps = internal(context, usedNames);
        const mapSlots = internal(context, usedNames);
        const fakeMap = internal(context, usedNames);
        const fakeOps = internal(context, usedNames);
        const fakeSlotsEncoded = internal(context, usedNames);
        const ins = internal(context, usedNames);
        const reg = internal(context, usedNames);
        const consts = internal(context, usedNames);
        const token = internal(context, usedNames);
        const fieldIds = Array.from({ length: 38 }, () => uniqueSlot(context, usedSlots));
        let fi = 0;
        const F = {
            pc: fieldIds[fi++], fail: fieldIds[fi++], program: fieldIds[fi++], programHash: fieldIds[fi++],
            chunkSlots: fieldIds[fi++], chunkChecks: fieldIds[fi++], payloadHash: fieldIds[fi++], seed: fieldIds[fi++],
            opcodeMask: fieldIds[fi++], guard: fieldIds[fi++], critical: fieldIds[fi++], artBytes: fieldIds[fi++],
            artSeed: fieldIds[fi++], handlers: fieldIds[fi++], bytes: fieldIds[fi++], source: fieldIds[fi++],
            compiled: fieldIds[fi++], noise: fieldIds[fi++], slotMask: fieldIds[fi++], handlerOpMask: fieldIds[fi++],
            shadowProgram: fieldIds[fi++], shadowConsts: fieldIds[fi++], shadowPc: fieldIds[fi++], shadowRegs: fieldIds[fi++],
            shadowToken: fieldIds[fi++], shadowOpMask: fieldIds[fi++], shadowHandlerOpMask: fieldIds[fi++],
            shadowSlotMask: fieldIds[fi++], shadowMapOps: fieldIds[fi++], shadowMapSlots: fieldIds[fi++], shadowExpected: fieldIds[fi++],
            alphabet: fieldIds[fi++], encodedLen: fieldIds[fi++], rawLen: fieldIds[fi++], codec: fieldIds[fi++],
            artEncodedLen: fieldIds[fi++], artRawLen: fieldIds[fi++], artCodec: fieldIds[fi++]
        };
        const cf = (field) => `${ctx}[${numberExpr(field, context)}]`;
        const chunkCount = Math.max(5, Math.min(24, Math.ceil(transport.length / 640)));
        const chunkSize = Math.max(1, Math.ceil(transport.length / chunkCount));
        const chunkSlots = [];
        const chunkChecks = [];
        const entries = [];
        const entrySlots = [];
        for (let offset = 0; offset < transport.length; offset += chunkSize) {
            const slot = uniqueSlot(context, usedSlots);
            const text = transport.slice(offset, offset + chunkSize);
            chunkSlots.push(slot);
            chunkChecks.push(checksum(utf8Bytes(text)));
            entries.push(`[${numberExpr(slot, context)}]=function()return"${text}"end`);
            entrySlots.push(slot);
        }
        const hashBody = `[${numberExpr(slotHash, context)}]=function(${values})local ${result}=0 local __s=type(${values})=="string" for ${index}=1,#${values} do local __v=__s and string.byte(${values},${index}) or ${values}[${index}] ${result}=(${result}*131+__v+${index})%2147483647 end return ${result} end`;
        const base85Body = `[${numberExpr(slotBase85, context)}]=function(${bank},${ctx},__s,__n)local __r={} local __a=${cf(F.alphabet)} for __i=1,#__a do __r[string.byte(__a,__i)]=__i-1 end local __o={} local __z=0 for __p=1,#__s,5 do local __v=0 for __j=0,4 do local __d=__r[string.byte(__s,__p+__j)] if __d==nil then return nil end __v=__v*85+__d end local __b1=math.floor(__v/16777216)%256 local __b2=math.floor(__v/65536)%256 local __b3=math.floor(__v/256)%256 local __b4=__v%256 local __q={__b1,__b2,__b3,__b4} for __j=1,4 do if __z>=__n then break end __z=__z+1 __o[__z]=__q[__j] end end return __o end`;
        const decompressBody = `[${numberExpr(slotDecompress, context)}]=function(${bank},${ctx},__d,__c)if __c==0 then return __d end local __o={} local __p=1 while __p<=#__d do local __t=__d[__p] __p=__p+1 if __t<128 then local __n=__t+1 for __j=1,__n do if __p>#__d then return nil end __o[#__o+1]=__d[__p] __p=__p+1 end else local __n=(__t-128)+3 if __p+1>#__d then return nil end local __dist=__d[__p]*256+__d[__p+1] __p=__p+2 if __dist<1 or __dist>#__o then return nil end for __j=1,__n do __o[#__o+1]=__o[#__o-__dist+1] end end end return __o end`;
        const verifyProgramBody = `[${numberExpr(slotVerifyProgram, context)}]=function(${bank},${ctx})` +
            `if ${bank}[${numberExpr(slotHash, context)}](${cf(F.program)})~=${cf(F.programHash)} then ${cf(F.pc)}=${cf(F.fail)} return end ` +
            `${cf(F.guard)}=(${cf(F.guard)}*${guardMul1}+${guardAdd1})%4294967296 ${cf(F.pc)}=${cf(F.pc)}+1 end`;
        const verifyBankBody = `[${numberExpr(slotVerifyBank, context)}]=function(${bank},${ctx})local ${bad}=false ` +
            `for ${i}=1,#${cf(F.critical)} do local ${chunkSlot}=bit32.bxor(${cf(F.critical)}[${i}],${cf(F.slotMask)}) if type(${bank}[${chunkSlot}])~="function" then ${bad}=true break end end ` +
            `if ${bad} then ${cf(F.pc)}=${cf(F.fail)} else ${cf(F.pc)}=${cf(F.pc)}+1 end end`;
        const waitDelta = context.random.int(31, 997);
        const timingBody = this.enableTimingCheck
            ? `[${numberExpr(slotTiming, context)}]=function(${bank},${ctx})local ${ok}=pcall(function()` +
                `local __e=(getfenv and getfenv()) or _G local __o=__e[string.char(111,115)] local __t=__e[string.char(116,97,115,107)] ` +
                `local __d=string.char(100,97,116,101) local __w=string.char(119,97,105,116) local __f=string.char(37,83) ` +
                `local ${s1}=tonumber(__o[__d](__f));__t[__w]((1100+${waitDelta}-${waitDelta})/1000);local ${s2}=tonumber(__o[__d](__f));` +
                `if not ${s1} or not ${s2} or ${s1}==${s2} then error("",0) end end);` +
                `${cf(F.guard)}=(${cf(F.guard)}*${guardMul3}+(${ok} and ${guardGood3} or ${guardBad3}))%4294967296;${cf(F.pc)}=${cf(F.pc)}+1 end`
            : `[${numberExpr(slotTiming, context)}]=function(${bank},${ctx})local ${ok}=true ` +
                `${cf(F.guard)}=(${cf(F.guard)}*${guardMul3}+${guardGood3})%4294967296;${cf(F.pc)}=${cf(F.pc)}+1 end`;
        const shadowHandlerBodies = [
            `[${numberExpr(shadowSlots.load, context)}]=function(${bank},${ctx},${ins})${cf(F.shadowRegs)}[${ins}[2]]=${cf(F.shadowConsts)}[((${ins}[3]-1)%#${cf(F.shadowConsts)})+1] ${cf(F.shadowPc)}=${cf(F.shadowPc)}+1 end`,
            `[${numberExpr(shadowSlots.xor, context)}]=function(${bank},${ctx},${ins})${cf(F.shadowRegs)}[${ins}[2]]=bit32.bxor(${cf(F.shadowRegs)}[${ins}[3]] or 0,${cf(F.shadowRegs)}[${ins}[4]] or 0) ${cf(F.shadowPc)}=${cf(F.shadowPc)}+1 end`,
            `[${numberExpr(shadowSlots.addk, context)}]=function(${bank},${ctx},${ins})${cf(F.shadowRegs)}[${ins}[2]]=((${cf(F.shadowRegs)}[${ins}[3]] or 0)+${cf(F.shadowConsts)}[((${ins}[4]-1)%#${cf(F.shadowConsts)})+1])%4294967296 ${cf(F.shadowPc)}=${cf(F.shadowPc)}+1 end`,
            `[${numberExpr(shadowSlots.mulk, context)}]=function(${bank},${ctx},${ins})local ${k}=(((${ins}[4]-1)%#${cf(F.shadowConsts)})+1) local ${j}=(${k}%#${cf(F.shadowConsts)})+1 ${cf(F.shadowRegs)}[${ins}[2]]=(((${cf(F.shadowRegs)}[${ins}[3]] or 0)*bit32.bor(${cf(F.shadowConsts)}[${k}],1))+${cf(F.shadowConsts)}[${j}])%4294967296 ${cf(F.shadowPc)}=${cf(F.shadowPc)}+1 end`,
            `[${numberExpr(shadowSlots.rol, context)}]=function(${bank},${ctx},${ins})local ${k}=${cf(F.shadowConsts)}[((${ins}[4]-1)%#${cf(F.shadowConsts)})+1]%31 ${cf(F.shadowRegs)}[${ins}[2]]=bit32.lrotate(${cf(F.shadowRegs)}[${ins}[3]] or 0,${k}) ${cf(F.shadowPc)}=${cf(F.shadowPc)}+1 end`,
            `[${numberExpr(shadowSlots.mix, context)}]=function(${bank},${ctx},${ins})local ${k}=(((${ins}[2]+${ins}[3]+${ins}[4])%#${cf(F.shadowConsts)})+1) ${cf(F.shadowRegs)}[${ins}[2]]=bit32.bxor(((${cf(F.shadowRegs)}[${ins}[3]] or 0)+(${cf(F.shadowRegs)}[${ins}[4]] or 0))%4294967296,${cf(F.shadowConsts)}[${k}]) ${cf(F.shadowPc)}=${cf(F.shadowPc)}+1 end`,
            `[${numberExpr(shadowSlots.finish, context)}]=function(${bank},${ctx},${ins})${cf(F.shadowToken)}=bit32.bxor(${cf(F.shadowRegs)}[${ins}[2]] or 0,${cf(F.shadowRegs)}[${ins}[3]] or 0,${cf(F.shadowRegs)}[${ins}[4]] or 0,${cf(F.shadowConsts)}[1]) ${cf(F.shadowPc)}=0 end`
        ];
        const shadowPairs = shuffle([
            [shadowOps.load, shadowSlots.load],
            [shadowOps.xor, shadowSlots.xor],
            [shadowOps.addk, shadowSlots.addk],
            [shadowOps.mulk, shadowSlots.mulk],
            [shadowOps.rol, shadowSlots.rol],
            [shadowOps.mix, shadowSlots.mix],
            [shadowOps.finish, shadowSlots.finish]
        ], context);
        const shadowMapOpsLiteral = `{${shadowPairs.map(([op]) => numberExpr((op ^ shadowHandlerOpcodeMask) & 0xff, context)).join(",")}}`;
        const shadowMapSlotsLiteral = `{${shadowPairs.map(([, slot]) => numberExpr((slot ^ shadowHandlerSlotMask) >>> 0, context)).join(",")}}`;
        const shadowProgramLiteral = `{${shadowPlain.map(insn => `{${numberExpr((insn[0] ^ shadowOpcodeMask) & 0xff, context)},${numberExpr(insn[1], context)},${numberExpr(insn[2], context)},${numberExpr(insn[3], context)}}`).join(",")}}`;
        const shadowConstantsLiteral = `{${shadowConstants.map(v => numberExpr(v, context)).join(",")}}`;
        const shadowRunnerBody = `[${numberExpr(slotShadowRunner, context)}]=function(${bank},${ctx})local ${fakeMap}={} ` +
            `for ${i}=1,#${cf(F.shadowMapOps)} do ${fakeMap}[bit32.bxor(${cf(F.shadowMapOps)}[${i}],${cf(F.shadowHandlerOpMask)})]=bit32.bxor(${cf(F.shadowMapSlots)}[${i}],${cf(F.shadowSlotMask)}) end ` +
            `${cf(F.shadowRegs)}={} ${cf(F.shadowPc)}=1 ${cf(F.shadowToken)}=0 while ${cf(F.shadowPc)}>0 do local ${ins}=${cf(F.shadowProgram)}[${cf(F.shadowPc)}] ` +
            `if not ${ins} then return 0 end local ${opcode}=bit32.bxor(${ins}[1],${cf(F.shadowOpMask)}) local ${handler}=${fakeMap}[${opcode}] if not ${handler} then return 0 end ${bank}[${handler}](${bank},${ctx},${ins}) end return ${cf(F.shadowToken)} end`;
        const shadowStageBody = `[${numberExpr(slotShadowStage, context)}]=function(${bank},${ctx})local ${token}=${bank}[${numberExpr(slotShadowRunner, context)}](${bank},${ctx}) ` +
            `if ${token}~=${cf(F.shadowExpected)} then ${cf(F.pc)}=${cf(F.fail)} return end ` +
            `${cf(F.guard)}=(${cf(F.guard)}*${guardMul2}+bit32.bxor(${token},${numberExpr(guardShadowAdd ^ shadowToken, context)}))%4294967296 ${cf(F.pc)}=${cf(F.pc)}+1 end`;
        const collectBody = `[${numberExpr(slotCollect, context)}]=function(${bank},${ctx})local ${out}={} ` +
            `for ${i}=1,#${cf(F.chunkSlots)} do local ${chunkSlot}=bit32.bxor(${cf(F.chunkSlots)}[${i}],${cf(F.slotMask)}) local ${chunk}=${bank}[${chunkSlot}]()` +
            ` local __h=0 for ${j}=1,#${chunk} do local __b=string.byte(${chunk},${j}) __h=(__h*131+__b+${j})%2147483647 end ` +
            `if __h~=${cf(F.chunkChecks)}[${i}] then ${cf(F.guard)}=(${cf(F.guard)}+${context.random.int(0x1000, 0xfffff)})%4294967296 end ${out}[${i}]=${chunk} end ${cf(F.bytes)}=table.concat(${out});${cf(F.pc)}=${cf(F.pc)}+1 end`;
        const verifyPayloadBody = `[${numberExpr(slotVerifyPayload, context)}]=function(${bank},${ctx})` +
            `if ${bank}[${numberExpr(slotHash, context)}](${cf(F.bytes)})~=${cf(F.payloadHash)} or ${cf(F.guard)}~=${guard3} or ${cf(F.noise)}~=${noiseAtVerifyPayload} then ${cf(F.pc)}=${cf(F.fail)} return end ` +
            `${cf(F.guard)}=(${cf(F.guard)}*${guardMul4}+${guardAdd4})%4294967296;${cf(F.pc)}=${cf(F.pc)}+1 end`;
        const decodeBody = `[${numberExpr(slotDecode, context)}]=function(${bank},${ctx})local __enc=${bank}[${numberExpr(slotBase85, context)}](${bank},${ctx},${cf(F.bytes)},${cf(F.encodedLen)}) if not __enc then ${cf(F.pc)}=${cf(F.fail)} return end local ${state}=${cf(F.seed)} local ${out}={}` +
            ` for ${i}=1,#__enc do ${state}=(${state}*1664525+1013904223)%4294967296 local ${stream}=math.floor(${state}/65536)%256 ` +
            `${out}[${i}]=(__enc[${i}]-${stream})%256 end local __raw=${bank}[${numberExpr(slotDecompress, context)}](${bank},${ctx},${out},${cf(F.codec)}) if not __raw or #__raw~=${cf(F.rawLen)} then ${cf(F.pc)}=${cf(F.fail)} return end ` +
            `local __chars={} for ${i}=1,#__raw do __chars[${i}]=string.char(__raw[${i}]) end ${cf(F.source)}=table.concat(__chars);${cf(F.pc)}=${cf(F.pc)}+1 end`;
        const compileBody = `[${numberExpr(slotCompile, context)}]=function(${bank},${ctx})` +
            `if ${cf(F.guard)}~=${guard4} or ${cf(F.noise)}~=${noiseAtCompile} then ${cf(F.pc)}=${cf(F.fail)} return end ` +
            `local __e=(getfenv and getfenv()) or _G local ${loader}=__e[string.char(108,111,97,100,115,116,114,105,110,103)] or __e[string.char(108,111,97,100)] ` +
            `if not ${loader} then ${cf(F.pc)}=${cf(F.fail)} return end local ${fn},${err}=${loader}(${cf(F.source)})` +
            ` if not ${fn} then ${cf(F.pc)}=${cf(F.fail)} return end ${cf(F.compiled)}=${fn};${cf(F.pc)}=${cf(F.pc)}+1 end`;
        const callBody = `[${numberExpr(slotCall, context)}]=function(${bank},${ctx},...)return ${cf(F.compiled)}(...)end`;
        const failBody = `[${numberExpr(slotFail, context)}]=function(${bank},${ctx})` +
            `for ${i}=1,#${cf(F.program)} do ${cf(F.program)}[${i}]=bit32.bxor((${cf(F.program)}[${i}] or 0),(${i}*73+${cf(F.opcodeMask)})%256) end ` +
            `if type(${cf(F.bytes)})=="table" then for ${i}=1,#${cf(F.bytes)} do ${cf(F.bytes)}[${i}]=(${cf(F.bytes)}[${i}]+${i}*29+${cf(F.opcodeMask)})%256 end else ${cf(F.bytes)}="" end ` +
            `if ${cf(F.handlers)} then for ${k} in pairs(${cf(F.handlers)}) do ${cf(F.handlers)}[${k}]=nil end end ` +
            `${cf(F.chunkSlots)}={} ${cf(F.chunkChecks)}={} ${cf(F.source)}=nil ${cf(F.compiled)}=nil ${cf(F.guard)}=0 ${cf(F.shadowProgram)}={} ${cf(F.shadowConsts)}={} ` +
            `local __enc=${bank}[${numberExpr(slotBase85, context)}](${bank},${ctx},${cf(F.artBytes)},${cf(F.artEncodedLen)}) if not __enc then error("",0) end ` +
            `local ${state}=${cf(F.artSeed)} local ${out}={} for ${i}=1,#__enc do ${state}=(${state}*1664525+1013904223)%4294967296 ` +
            `local ${stream}=math.floor(${state}/65536)%256 ${out}[${i}]=(__enc[${i}]-${stream})%256 end ` +
            `local __raw=${bank}[${numberExpr(slotDecompress, context)}](${bank},${ctx},${out},${cf(F.artCodec)}) if not __raw or #__raw~=${cf(F.artRawLen)} then error("",0) end ` +
            `local __chars={} for ${i}=1,#__raw do __chars[${i}]=string.char(__raw[${i}]) end local ${art}=table.concat(__chars) local __e=(getfenv and getfenv()) or _G local ${loader}=__e[string.char(108,111,97,100,115,116,114,105,110,103)] or __e[string.char(108,111,97,100)] ` +
            `if ${loader} then local ${artFn},${artErr}=${loader}(${art}) if ${artFn} then ${artFn}() end error(${artErr} or "",0) end error("",0) end`;
        const noiseBodies = [];
        for (let n = 0; n < fakeOpcodeCount; n++) {
            const t = fakeTransforms[n];
            noiseBodies.push(`[${numberExpr(fakeSlots[n], context)}]=function(${bank},${ctx})${cf(F.noise)}=bit32.bxor((${cf(F.noise)}*${t.mul}+${t.add})%4294967296,${numberExpr(t.xorValue, context)}) ${cf(F.pc)}=${cf(F.pc)}+1 end`);
        }
        const handlersPairs = [
            [opVerifyProgram, slotVerifyProgram],
            [opShadowStage, slotShadowStage],
            [opVerifyBank, slotVerifyBank],
            [opTiming, slotTiming],
            [opCollect, slotCollect],
            [opVerifyPayload, slotVerifyPayload],
            [opDecode, slotDecode],
            [opCompile, slotCompile],
            [opCall, slotCall],
            [opFail, slotFail],
            ...fakeOpcodes.map((op, n) => [op, fakeSlots[n]])
        ];
        shuffle(handlersPairs, context);
        const mapOpsLiteral = `{${handlersPairs.map(([op]) => numberExpr((op ^ handlerOpcodeMask) & 0xff, context)).join(",")}}`;
        const mapSlotsLiteral = `{${handlersPairs.map(([, slot]) => numberExpr((slot ^ handlerSlotMask) >>> 0, context)).join(",")}}`;
        const programLiteral = `{${program.map(op => numberExpr(op, context)).join(",")}}`;
        const chunksLiteral = `{${chunkSlots.map(slot => numberExpr((slot ^ handlerSlotMask) >>> 0, context)).join(",")}}`;
        const chunkChecksLiteral = `{${chunkChecks.map(v => numberExpr(v, context)).join(",")}}`;
        const criticalSlots = [
            slotEntry, slotHash, slotVerifyProgram, slotShadowStage, slotShadowRunner, slotVerifyBank, slotTiming,
            slotCollect, slotVerifyPayload, slotDecode, slotCompile, slotCall, slotFail, slotBase85, slotDecompress,
            ...fakeSlots, ...Object.values(shadowSlots)
        ];
        const criticalSlotsLiteral = `{${criticalSlots.map(slot => numberExpr((slot ^ handlerSlotMask) >>> 0, context)).join(",")}}`;
        const artLiteral = `"${tamperTransport}"`;
        const alphabetLiteral = `"${alphabet}"`;
        const entryBody = `[${numberExpr(slotEntry, context)}]=function(${bank},...)` +
            `local ${mapOps}=${mapOpsLiteral} local ${mapSlots}=${mapSlotsLiteral} local ${handlers}={} ` +
            `for ${i}=1,#${mapOps} do ${handlers}[bit32.bxor(${mapOps}[${i}],${handlerOpcodeMask})]=bit32.bxor(${mapSlots}[${i}],${handlerSlotMask}) end ` +
            `local ${ctx}={` +
            `[${numberExpr(F.pc, context)}]=1,[${numberExpr(F.fail, context)}]=${failIndex},[${numberExpr(F.program, context)}]=${programLiteral},[${numberExpr(F.programHash, context)}]=${numberExpr(programChecksum, context)},` +
            `[${numberExpr(F.chunkSlots, context)}]=${chunksLiteral},[${numberExpr(F.chunkChecks, context)}]=${chunkChecksLiteral},[${numberExpr(F.payloadHash, context)}]=${numberExpr(payloadChecksum, context)},[${numberExpr(F.seed, context)}]=${numberExpr(seed, context)},` +
            `[${numberExpr(F.opcodeMask, context)}]=${numberExpr(opcodeMask, context)},[${numberExpr(F.guard, context)}]=${numberExpr(guard0, context)},[${numberExpr(F.critical, context)}]=${criticalSlotsLiteral},[${numberExpr(F.artBytes, context)}]=${artLiteral},` +
            `[${numberExpr(F.artSeed, context)}]=${numberExpr(tamperSeed, context)},[${numberExpr(F.handlers, context)}]=${handlers},[${numberExpr(F.noise, context)}]=${numberExpr(noise0, context)},[${numberExpr(F.slotMask, context)}]=${numberExpr(handlerSlotMask, context)},` +
            `[${numberExpr(F.alphabet, context)}]=${alphabetLiteral},[${numberExpr(F.encodedLen, context)}]=${numberExpr(encoded.length, context)},[${numberExpr(F.rawLen, context)}]=${numberExpr(rawBytes.length, context)},[${numberExpr(F.codec, context)}]=${numberExpr(codec, context)},` +
            `[${numberExpr(F.artEncodedLen, context)}]=${numberExpr(tamperEncoded.length, context)},[${numberExpr(F.artRawLen, context)}]=${numberExpr(tamperRaw.length, context)},[${numberExpr(F.artCodec, context)}]=${numberExpr(tamperCodec, context)},` +
            `[${numberExpr(F.handlerOpMask, context)}]=${numberExpr(handlerOpcodeMask, context)},[${numberExpr(F.shadowProgram, context)}]=${shadowProgramLiteral},[${numberExpr(F.shadowConsts, context)}]=${shadowConstantsLiteral},[${numberExpr(F.shadowOpMask, context)}]=${numberExpr(shadowOpcodeMask, context)},` +
            `[${numberExpr(F.shadowHandlerOpMask, context)}]=${numberExpr(shadowHandlerOpcodeMask, context)},[${numberExpr(F.shadowSlotMask, context)}]=${numberExpr(shadowHandlerSlotMask, context)},[${numberExpr(F.shadowMapOps, context)}]=${shadowMapOpsLiteral},[${numberExpr(F.shadowMapSlots, context)}]=${shadowMapSlotsLiteral},` +
            `[${numberExpr(F.shadowExpected, context)}]=${numberExpr(shadowToken, context)}} ` +
            `while true do local ${rawOpcode}=${cf(F.program)}[${cf(F.pc)}] local ${opcode}=bit32.bxor(${rawOpcode},${cf(F.opcodeMask)}) ` +
            `local ${handler}=${cf(F.handlers)}[${opcode}] if not ${handler} then ${cf(F.pc)}=${cf(F.fail)} ${rawOpcode}=${cf(F.program)}[${cf(F.pc)}] ${opcode}=bit32.bxor(${rawOpcode},${cf(F.opcodeMask)}) ${handler}=${cf(F.handlers)}[${opcode}] end ` +
            `if ${opcode}==${numberExpr(opCall, context)} then return ${bank}[${handler}](${bank},${ctx},...) end ` +
            `if ${opcode}==${numberExpr(opFail, context)} then return ${bank}[${handler}](${bank},${ctx}) end ` +
            `${bank}[${handler}](${bank},${ctx}) end end`;
        entries.push(hashBody, base85Body, decompressBody, verifyProgramBody, verifyBankBody, shadowStageBody, shadowRunnerBody, timingBody, collectBody, verifyPayloadBody, decodeBody, compileBody, callBody, failBody, ...noiseBodies, ...shadowHandlerBodies, entryBody);
        entrySlots.push(slotHash, slotBase85, slotDecompress, slotVerifyProgram, slotVerifyBank, slotShadowStage, slotShadowRunner, slotTiming, slotCollect, slotVerifyPayload, slotDecode, slotCompile, slotCall, slotFail, ...fakeSlots, shadowSlots.load, shadowSlots.xor, shadowSlots.addk, shadowSlots.mulk, shadowSlots.rol, shadowSlots.mix, shadowSlots.finish, slotEntry);
        const keyChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const usedBankKeys = new Set(["g", "V"]);
        const nextBankKey = () => {
            while (true) {
                const length = context.random.int(1, 3);
                let value = keyChars[context.random.int(0, keyChars.length - 1)];
                for (let z = 1; z < length; z++) {
                    value += keyChars[context.random.int(0, keyChars.length - 1)];
                }
                if (!usedBankKeys.has(value)) {
                    usedBankKeys.add(value);
                    return value;
                }
            }
        };
        const paired = entries.map((text, index) => ({
            text,
            slot: entrySlots[index],
            name: entrySlots[index] === slotEntry ? "V" : nextBankKey()
        }));
        const aliasOrder = [...paired];
        shuffle(paired, context);
        const emitted = paired.map(item => item.text.replace(/^\[[^\]]+\]=/, `${item.name}=`));
        const aliasSlots = `{${aliasOrder.map(item => numberExpr(item.slot, context)).join(",")}}`;
        const aliasNames = `{${aliasOrder.map(item => `"${item.name}"`).join(",")}}`;
        const bootstrap = `g=function(q,k,p,...)local __s=${aliasSlots} local __i=1 local __n=#k local __c=${numberExpr(0x45, context)} while true do if __c==${numberExpr(0x45, context)} then if __i>__n then __c=${numberExpr(0x91, context)} else q[__s[__i]]=q[k[__i]] __i=__i+1 end elseif __c==${numberExpr(0x91, context)} then return q[p](q,...) end end end`;
        return `return({${bootstrap},${emitted.join(",")}}):g(${aliasNames},"V",...)`;
    }
}
