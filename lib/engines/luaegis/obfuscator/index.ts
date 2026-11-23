import type { Chunk, Exp, Stat } from "./ast.js";
import { ParseError } from "./ast.js";
import { emit, quoteLua } from "./emit.js";
import { parse } from "./parser.js";
import {
  injectOpaque,
  renameLocals,
  replaceStrings,
  rewriteNumbers,
  wrapChunk,
} from "./passes.js";
import { Rng } from "./rng.js";

export type PresetId = "light" | "medium" | "heavy" | "maximum";

export type ObfuscateOptions = {
  preset?: PresetId;
  rename?: boolean;
  encryptStrings?: boolean;
  encryptMembers?: boolean;
  numbers?: boolean;
  controlFlow?: boolean;
  minify?: boolean;
  vmWrap?: boolean;
  seed?: number;
};

export type ObfuscateResult = {
  output: string;
  mode: "ast" | "wrapper";
  seed: number;
  originalBytes: number;
  outputBytes: number;
  localsRenamed: number;
  stringsEncrypted: number;
  warning?: string;
  parseError?: string;
};

export const PRESETS: Record<
  PresetId,
  Omit<Required<ObfuscateOptions>, "preset" | "seed">
> = {
  light: {
    rename: true,
    encryptStrings: true,
    encryptMembers: false,
    numbers: false,
    controlFlow: false,
    minify: true,
    vmWrap: false,
  },
  medium: {
    rename: true,
    encryptStrings: true,
    encryptMembers: true,
    numbers: true,
    controlFlow: false,
    minify: true,
    vmWrap: false,
  },
  heavy: {
    rename: true,
    encryptStrings: true,
    encryptMembers: true,
    numbers: true,
    controlFlow: true,
    minify: true,
    vmWrap: false,
  },
  maximum: {
    rename: true,
    encryptStrings: true,
    encryptMembers: true,
    numbers: true,
    controlFlow: true,
    minify: true,
    vmWrap: true,
  },
};

export function resolveOptions(opts: ObfuscateOptions = {}): Required<ObfuscateOptions> {
  const preset = opts.preset ?? "heavy";
  const base = PRESETS[preset];
  return {
    preset,
    seed: opts.seed ?? 0,
    rename: opts.rename ?? base.rename,
    encryptStrings: opts.encryptStrings ?? base.encryptStrings,
    encryptMembers: opts.encryptMembers ?? base.encryptMembers,
    numbers: opts.numbers ?? base.numbers,
    controlFlow: opts.controlFlow ?? base.controlFlow,
    minify: opts.minify ?? base.minify,
    vmWrap: opts.vmWrap ?? base.vmWrap,
  };
}

export function obfuscate(source: string, opts: ObfuscateOptions = {}): ObfuscateResult {
  const resolved = resolveOptions(opts);
  const rng = new Rng(opts.seed);
  const originalBytes = byteLen(source);

  try {
    const result = obfuscateAst(source, resolved, rng);
    return finalize(result, originalBytes, rng.seed);
  } catch (err) {
    const parseError = err instanceof ParseError ? err.message : err instanceof Error ? err.message : String(err);
    const output = wrapEncrypted(source, rng, "wrapper");
    return finalize(
      {
        output,
        mode: "wrapper",
        localsRenamed: 0,
        stringsEncrypted: 1,
        warning: "Could not fully parse — encrypted the whole script as a loader.",
        parseError,
      },
      originalBytes,
      rng.seed,
    );
  }
}

function obfuscateAst(source: string, opts: Required<ObfuscateOptions>, rng: Rng) {
  const chunk = parse(source);
  stripEmpty(chunk);

  let localsRenamed = 0;
  if (opts.rename) {
    const style = opts.preset === "light" ? "short" : opts.preset === "medium" ? "hex" : "confuse";
    localsRenamed = renameLocals(chunk, rng, style).locals;
  }

  let stringsEncrypted = 0;
  const prelude: Stat[] = [];

  if (opts.encryptStrings) {
    const key = rng.bytes(8 + rng.int(8));
    const keyName = unique("k", rng);
    const decName = unique("d", rng);
    const poolName = unique("s", rng);
    const pool: string[] = [];
    const index = new Map<string, number>();

    const intern = (value: string) => {
      const hit = index.get(value);
      if (hit) return hit;
      pool.push(value);
      index.set(value, pool.length);
      return pool.length;
    };

    const decode = (value: string): Exp => {
      stringsEncrypted += 1;
      const idx = intern(value);
      return {
        type: "Index",
        object: { type: "Name", name: poolName },
        key: opts.numbers
          ? {
              type: "Binary",
              op: "-",
              left: { type: "Number", value: idx + 9, raw: String(idx + 9) },
              right: { type: "Number", value: 9, raw: "9" },
            }
          : { type: "Number", value: idx, raw: String(idx) },
      };
    };

    replaceStrings(chunk, decode, opts.encryptMembers);

    prelude.push({
      type: "Local",
      names: [keyName],
      exps: [
        {
          type: "Table",
          fields: key.map((n) => ({
            kind: "list" as const,
            value: { type: "Number" as const, value: n, raw: "0x" + n.toString(16) },
          })),
        },
      ],
    });
    prelude.push(makeDecoder(decName, keyName));
    prelude.push({
      type: "Local",
      names: [poolName],
      exps: [
        {
          type: "Table",
          fields: pool.map((s) => ({
            kind: "list" as const,
            value: {
              type: "Call" as const,
              callee: { type: "Name" as const, name: decName },
              args: [{ type: "String" as const, value: xorLatin1(s, key) }],
            },
          })),
        },
      ],
    });
  }

  if (opts.numbers) rewriteNumbers(chunk, rng, opts.preset === "light" ? 1 : 2);
  if (opts.controlFlow) injectOpaque(chunk, rng, opts.preset === "maximum" ? 0.55 : 0.32);

  const wrapped = wrapChunk(chunk, prelude);
  let output = emit(wrapped, { minify: opts.minify });
  output = banner(rng.seed) + output;

  if (opts.vmWrap) {
    output = wrapEncrypted(output, rng, "vm");
  }

  return {
    output,
    mode: "ast" as const,
    localsRenamed,
    stringsEncrypted,
  };
}

function makeDecoder(decName: string, keyName: string): Stat {
  return {
    type: "Local",
    names: [decName],
    exps: [
      {
        type: "Function",
        body: {
          params: ["a"],
          vararg: false,
          body: [
            {
              type: "Local",
              names: ["r"],
              exps: [{ type: "Table", fields: [] }],
            },
            {
              type: "ForNum",
              name: "i",
              start: { type: "Number", value: 1, raw: "1" },
              last: { type: "Unary", op: "#", arg: { type: "Name", name: "a" } },
              body: [
                {
                  type: "Assignment",
                  vars: [
                    {
                      type: "Index",
                      object: { type: "Name", name: "r" },
                      key: { type: "Name", name: "i" },
                    },
                  ],
                  exps: [
                    {
                      type: "Call",
                      callee: { type: "Member", object: { type: "Name", name: "string" }, name: "char" },
                      args: [
                        {
                          type: "Call",
                          callee: { type: "Member", object: { type: "Name", name: "bit32" }, name: "bxor" },
                          args: [
                            {
                              type: "Call",
                              callee: { type: "Member", object: { type: "Name", name: "string" }, name: "byte" },
                              args: [
                                { type: "Name", name: "a" },
                                { type: "Name", name: "i" },
                              ],
                            },
                            {
                              type: "Index",
                              object: { type: "Name", name: keyName },
                              key: {
                                type: "Binary",
                                op: "+",
                                left: {
                                  type: "Binary",
                                  op: "%",
                                  left: {
                                    type: "Binary",
                                    op: "-",
                                    left: { type: "Name", name: "i" },
                                    right: { type: "Number", value: 1, raw: "1" },
                                  },
                                  right: { type: "Unary", op: "#", arg: { type: "Name", name: keyName } },
                                },
                                right: { type: "Number", value: 1, raw: "1" },
                              },
                            },
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
            {
              type: "Return",
              exps: [
                {
                  type: "Call",
                  callee: { type: "Member", object: { type: "Name", name: "table" }, name: "concat" },
                  args: [{ type: "Name", name: "r" }],
                },
              ],
            },
          ],
        },
      },
    ],
  };
}

export function wrapEncrypted(source: string, rng: Rng, _why: string): string {
  const key = rng.bytes(12);
  const payload = xorLatin1(source, key);
  const keyLit = "{" + key.map((n) => "0x" + n.toString(16)).join(",") + "}";
  const body = [
    `local _k=${keyLit}`,
    `local _d=function(s)local r={}for i=1,#s do r[i]=string.char(bit32.bxor(string.byte(s,i),_k[(i-1)%#_k+1]))end return table.concat(r)end`,
    `local _l=loadstring or load`,
    `local _f=_l(_d(${quoteLua(payload)}))`,
    `if not _f then error("luaegis: load failed")end`,
    `return _f(...)`,
  ].join(" ");
  return `${banner(rng.seed)}return(function(...) ${body} end)(...)`;
}

export function buildExecutorKit(seed?: number): string {
  const rng = new Rng(seed);
  const stamp = rng.seed.toString(16).padStart(8, "0");
  return `--[[
  LUAEGIS kit  ·  ${stamp}
  Paste this into a Luau executor.

    local out = luaegis([[ print("hello") ]])
    if setclipboard then setclipboard(out) end
    print(out)
]]

function luaegis(src)
  src = tostring(src)
  local k = {${Array.from({ length: 10 }, () => rng.int(256)).join(", ")}}
  local function enc(s)
    local r = {}
    for i = 1, #s do
      r[i] = string.char(bit32.bxor(string.byte(s, i), k[(i - 1) % #k + 1]))
    end
    return table.concat(r)
  end
  local function lit(s)
    local r = {'"'}
    for i = 1, #s do
      r[#r + 1] = "\\\\"
      r[#r + 1] = string.format("%03d", string.byte(s, i))
    end
    r[#r + 1] = '"'
    return table.concat(r)
  end
  local payload = lit(enc(src))
  local keylit = "{" .. table.concat(k, ",") .. "}"
  return table.concat({
    "-- luaegis ${stamp}\\n",
    "return(function(...) ",
    "local _k=",
    keylit,
    " local _d=function(s)local r={}for i=1,#s do r[i]=string.char(bit32.bxor(string.byte(s,i),_k[(i-1)%#_k+1]))end return table.concat(r)end ",
    "local _l=loadstring or load local _f=_l(_d(",
    payload,
    ")) if not _f then error(\\"luaegis: load failed\\") end return _f(...) end)(...)",
  })
end
`;
}

function xorLatin1(text: string, key: number[]): string {
  const bytes = utf8Bytes(text);
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += String.fromCharCode(bytes[i]! ^ key[i % key.length]!);
  }
  return out;
}

function utf8Bytes(text: string): number[] {
  const encoded = new TextEncoder().encode(text);
  return Array.from(encoded);
}

function unique(prefix: string, rng: Rng) {
  return `_${prefix}${rng.int(0xffff).toString(16)}${rng.int(0xfff).toString(16)}`;
}

function banner(seed: number) {
  return `-- luaegis ${seed.toString(16).padStart(8, "0")}\n`;
}

function byteLen(s: string) {
  return new TextEncoder().encode(s).length;
}

function stripEmpty(chunk: Chunk) {
  const clean = (stats: Stat[]): Stat[] => {
    const out: Stat[] = [];
    for (const s of stats) {
      if (s.type === "Do" && s.body.length === 0) continue;
      if (s.type === "Do") out.push({ ...s, body: clean(s.body) });
      else if (s.type === "While") out.push({ ...s, body: clean(s.body) });
      else if (s.type === "Repeat") out.push({ ...s, body: clean(s.body) });
      else if (s.type === "If") {
        out.push({
          ...s,
          clauses: s.clauses.map((c) => ({ ...c, body: clean(c.body) })),
          otherwise: s.otherwise ? clean(s.otherwise) : undefined,
        });
      } else if (s.type === "ForNum") out.push({ ...s, body: clean(s.body) });
      else if (s.type === "ForIn") out.push({ ...s, body: clean(s.body) });
      else if (s.type === "FunctionStat") {
        out.push({ ...s, body: { ...s.body, body: clean(s.body.body) } });
      } else if (s.type === "LocalFunction") {
        out.push({ ...s, body: { ...s.body, body: clean(s.body.body) } });
      } else out.push(s);
    }
    return out;
  };
  chunk.body = clean(chunk.body);
}

function finalize(
  result: {
    output: string;
    mode: "ast" | "wrapper";
    localsRenamed: number;
    stringsEncrypted: number;
    warning?: string;
    parseError?: string;
  },
  originalBytes: number,
  seed: number,
): ObfuscateResult {
  return {
    ...result,
    seed,
    originalBytes,
    outputBytes: byteLen(result.output),
  };
}

export { ParseError };
export { parse } from "./parser.js";
export { emit } from "./emit.js";
