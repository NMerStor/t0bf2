import { lex } from "./lexer/Lexer.js";
import { parse } from "./parser/Parser.js";
import { obfuscate as obfuscateAst } from "./obfuscator/Obfuscator.js";
import { encodeStrings } from "./obfuscator/StringEncoder.js";
import { scrambleControlFlow } from "./obfuscator/ControlFlowScrambler.js";
import { printChunk, printChunkOneLine } from "./obfuscator/Printer.js";
import { compile } from "./vm/Compiler.js";
import { regCompile } from "./vm/RegCompiler.js";
import { generateVM, type VMGenLevel } from "./vm/vm-gen.js";
import { generateRegVM } from "./vm/reg-vm-gen.js";
import { withStrongAnti } from "./anti-dump/strongAnti.js";
import { padToSize } from "./anti-dump/padding.js";
import type { Chunk } from "./ast/types.js";
import { randomBytes } from "node:crypto";

export type VmType = "none" | "stack" | "register";
export type VmLevel = VMGenLevel; // "debug" | "normal" | "max"

export type VmObfuscateOptions = {
  vmType?: VmType;
  vmLevel?: VmLevel;
  rename?: boolean;
  preserveGlobals?: boolean;
  encodeStrings?: boolean;
  scrambleControlFlow?: boolean;
  oneLine?: boolean;
  /** Prepend hook-integrity + random DTC. Defaults to true for vmLevel "max". */
  hookIntegrity?: boolean;
  /** Inject one random DTC from the 200-probe library. Default true when anti is on. */
  randomDtc?: boolean;
  /**
   * Number of nested VM layers (1–5). Each layer re-obfuscates the previous
   * output. Default 1. 5 layers is extremely heavy — only use for tiny scripts.
   */
  vmLayers?: number;
  /**
   * Pad output with decoy junk code up to this many bytes. Defaults to
   * 150_000 when vmLevel is "max", 0 otherwise.
   */
  padBytes?: number;
  /**
   * Seed for reproducibility. If omitted, a fresh cryptographically-random
   * seed is generated every call → same source always produces different output.
   */
  seed?: number;
};

export type VmObfuscateResult = {
  output: string;
  vmType: VmType;
  vmLevel: VmLevel;
  hookIntegrity: boolean;
  padBytes: number;
  vmLayers: number;
  usedDtcId: string | null;
  seed: number;
};

function makeRng(seed: number): () => number {
  // Simple mulberry32
  let t = seed >>> 0;
  return () => {
    t = (t + 0x6d2b79f5) >>> 0;
    let r = Math.imul(t ^ (t >>> 15), 1 | t);
    r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}

function singleLayerObfuscate(
  source: string,
  opts: {
    vmType: VmType;
    vmLevel: VmLevel;
    rename: boolean;
    preserveGlobals: boolean;
    encodeStrings: boolean;
    scrambleControlFlow: boolean;
    oneLine: boolean;
    seed: number;
  }
): string {
  const { tokens, errors: lexErrors } = lex(source);
  if (lexErrors.length > 0) {
    throw new Error(`Lexer error: ${lexErrors.map((e) => e.message).join("; ")}`);
  }

  let ast: Chunk = parse(tokens);

  if (opts.encodeStrings) {
    ast = encodeStrings(ast, { enabled: true });
  }
  if (opts.scrambleControlFlow) {
    ast = scrambleControlFlow(ast, { enabled: true });
  }

  let output: string;

  if (opts.vmType === "stack") {
    const obfuscated = obfuscateAst(ast, {
      renameLocals: opts.rename,
      preserveGlobals: opts.preserveGlobals,
    });
    const chunk = compile(obfuscated);
    output = generateVM(chunk, {
      level: opts.vmLevel,
      executorGlobals: opts.vmLevel !== "debug",
    });
  } else if (opts.vmType === "register") {
    const obfuscated = obfuscateAst(ast, {
      renameLocals: opts.rename,
      preserveGlobals: opts.preserveGlobals,
    });
    const chunk = regCompile(obfuscated);
    const disableFeatures: string[] = [];
    if (opts.vmLevel === "debug") disableFeatures.push("controlFlowFlattening");
    output = generateRegVM(chunk, {
      level: opts.vmLevel,
      executorGlobals: opts.vmLevel !== "debug",
      polymorphicSeed: opts.seed,
      disableFeatures: disableFeatures as any[],
    });
  } else {
    const obfuscated = obfuscateAst(ast, {
      renameLocals: opts.rename,
      preserveGlobals: opts.preserveGlobals,
    });
    output = opts.oneLine ? printChunkOneLine(obfuscated) : printChunk(obfuscated);
  }

  return output;
}

export function vmObfuscate(source: string, opts: VmObfuscateOptions = {}): VmObfuscateResult {
  const vmType: VmType = opts.vmType ?? "none";
  const vmLevel: VmLevel = opts.vmLevel ?? "normal";
  const rename = opts.rename ?? true;
  const preserveGlobals = opts.preserveGlobals ?? true;
  const encodeStringsFlag = opts.encodeStrings ?? false;
  const scrambleControlFlowFlag = opts.scrambleControlFlow ?? false;
  const oneLine = opts.oneLine ?? false;

  // Always polymorphic unless user supplies a seed
  const seed =
    typeof opts.seed === "number"
      ? opts.seed >>> 0
      : randomBytes(4).readUInt32BE(0);

  let layers = Math.floor(opts.vmLayers ?? 1);
  if (layers < 1) layers = 1;
  if (layers > 5) layers = 5;

  const antiEnabled = opts.hookIntegrity ?? vmLevel === "max";
  const randomDtc = opts.randomDtc ?? antiEnabled;

  let current = source;

  // Multi-layer: each layer treats previous output as new source
  for (let i = 0; i < layers; i++) {
    // Slightly different seed per layer so nested VMs are not identical
    const layerSeed = (seed + i * 0x9e3779b9) >>> 0;
    current = singleLayerObfuscate(current, {
      vmType,
      vmLevel,
      rename,
      preserveGlobals,
      encodeStrings: encodeStringsFlag,
      scrambleControlFlow: scrambleControlFlowFlag,
      oneLine: oneLine && i === layers - 1, // only outermost can be oneLine
      seed: layerSeed,
    });
  }

  let usedDtcId: string | null = null;
  let usedHook = false;

  if (antiEnabled || randomDtc) {
    const rng = makeRng(seed ^ 0xdeadbeef);
    const anti = withStrongAnti(current, {
      hookIntegrity: antiEnabled,
      randomDtc,
      rng,
    });
    current = anti.output;
    usedDtcId = anti.usedDtcId;
    usedHook = anti.usedHook;
  }

  const padBytes = opts.padBytes ?? (vmLevel === "max" ? 150_000 : 0);
  if (padBytes > 0) {
    const rng = makeRng(seed ^ 0x12345678);
    current = padToSize(current, {
      targetBytes: padBytes,
      rng,
    });
  }

  return {
    output: current,
    vmType,
    vmLevel,
    hookIntegrity: usedHook,
    padBytes,
    vmLayers: layers,
    usedDtcId,
    seed,
  };
}

export { validate } from "./compiler/LuauCompiler.js";
