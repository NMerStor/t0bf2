import type { CallExp, Chunk, Exp, Field, FuncBody, Stat } from "./ast.js";
import type { Rng } from "./rng.js";

export const BUILTINS = new Set([
  "_G",
  "_VERSION",
  "_ENV",
  "assert",
  "bit32",
  "buffer",
  "collectgarbage",
  "coroutine",
  "debug",
  "delay",
  "elapsedTime",
  "Enum",
  "error",
  "game",
  "gcinfo",
  "getfenv",
  "getmetatable",
  "ipairs",
  "Instance",
  "load",
  "loadstring",
  "math",
  "newproxy",
  "next",
  "os",
  "pairs",
  "pcall",
  "plugin",
  "print",
  "rawequal",
  "rawget",
  "rawlen",
  "rawset",
  "require",
  "script",
  "select",
  "setfenv",
  "setmetatable",
  "settings",
  "shared",
  "spawn",
  "string",
  "table",
  "task",
  "tick",
  "time",
  "tonumber",
  "tostring",
  "type",
  "typeof",
  "unpack",
  "utf8",
  "UserSettings",
  "vector",
  "wait",
  "warn",
  "workspace",
  "xpcall",
  "Axes",
  "BrickColor",
  "CFrame",
  "Color3",
  "ColorSequence",
  "DateTime",
  "DockWidgetPluginGuiInfo",
  "Faces",
  "Font",
  "NumberRange",
  "NumberSequence",
  "OverlapParams",
  "PathWaypoint",
  "PhysicalProperties",
  "Random",
  "Ray",
  "RaycastParams",
  "Rect",
  "Region3",
  "TweenInfo",
  "UDim",
  "UDim2",
  "Vector2",
  "Vector3",
]);

type Scope = { map: Map<string, string>; parent?: Scope };

function lookup(scope: Scope | undefined, name: string): string | undefined {
  while (scope) {
    const v = scope.map.get(name);
    if (v) return v;
    scope = scope.parent;
  }
  return undefined;
}

export type RenameStats = { locals: number };

export function renameLocals(chunk: Chunk, rng: Rng, style: "short" | "hex" | "confuse"): RenameStats {
  let n = 0;
  const used = new Set<string>(BUILTINS);

  const nextName = (): string => {
    for (;;) {
      n += 1;
      let name: string;
      if (style === "short") name = `_${toBase(n, 36)}`;
      else if (style === "hex") name = `_0x${(rng.int(0x1000) + n * 17).toString(16)}${toBase(n, 16)}`;
      else name = confuseName(n, rng);
      if (!used.has(name) && !BUILTINS.has(name)) {
        used.add(name);
        return name;
      }
    }
  };

  const bind = (scope: Scope, name: string) => {
    if (name === "self" || name === "...") return name;
    const existing = scope.map.get(name);
    if (existing) return existing;
    const mangled = nextName();
    scope.map.set(name, mangled);
    return mangled;
  };

  const walkStats = (stats: Stat[], scope: Scope) => {
    for (const s of stats) walkStat(s, scope);
  };

  const walkBody = (body: FuncBody, parent: Scope, extra?: string[]) => {
    const scope: Scope = { map: new Map(), parent };
    if (extra) extra.forEach((n) => bind(scope, n));
    body.params = body.params.map((p) => bind(scope, p));
    walkStats(body.body, scope);
  };

  const walkStat = (s: Stat, scope: Scope) => {
    switch (s.type) {
      case "Assignment":
        s.exps.forEach((e) => walkExp(e, scope));
        s.vars.forEach((v) => walkExp(v, scope));
        break;
      case "CallStat":
        walkExp(s.call, scope);
        break;
      case "Do":
        walkStats(s.body, { map: new Map(), parent: scope });
        break;
      case "While":
        walkExp(s.cond, scope);
        walkStats(s.body, { map: new Map(), parent: scope });
        break;
      case "Repeat": {
        const inner: Scope = { map: new Map(), parent: scope };
        walkStats(s.body, inner);
        walkExp(s.cond, inner);
        break;
      }
      case "If":
        for (const c of s.clauses) {
          walkExp(c.test, scope);
          walkStats(c.body, { map: new Map(), parent: scope });
        }
        if (s.otherwise) walkStats(s.otherwise, { map: new Map(), parent: scope });
        break;
      case "ForNum": {
        walkExp(s.start, scope);
        walkExp(s.last, scope);
        if (s.step) walkExp(s.step, scope);
        const inner: Scope = { map: new Map(), parent: scope };
        s.name = bind(inner, s.name);
        walkStats(s.body, inner);
        break;
      }
      case "ForIn": {
        s.exps.forEach((e) => walkExp(e, scope));
        const inner: Scope = { map: new Map(), parent: scope };
        s.names = s.names.map((nm) => bind(inner, nm));
        walkStats(s.body, inner);
        break;
      }
      case "FunctionStat": {
        if (s.name.parts.length === 1 && !s.name.method) {
          const mapped = lookup(scope, s.name.parts[0]!);
          if (mapped) s.name.parts[0] = mapped;
        } else {
          const mapped = lookup(scope, s.name.parts[0]!);
          if (mapped) s.name.parts[0] = mapped;
        }
        const extras = s.name.method ? ["self"] : [];
        walkBody(s.body, scope, extras);
        break;
      }
      case "LocalFunction": {
        s.name = bind(scope, s.name);
        walkBody(s.body, scope);
        break;
      }
      case "Local":
        s.exps?.forEach((e) => walkExp(e, scope));
        s.names = s.names.map((nm) => bind(scope, nm));
        break;
      case "Return":
        s.exps?.forEach((e) => walkExp(e, scope));
        break;
      case "Break":
      case "Continue":
        break;
    }
  };

  const walkExp = (e: Exp, scope: Scope) => {
    switch (e.type) {
      case "Name": {
        const mapped = lookup(scope, e.name);
        if (mapped) e.name = mapped;
        break;
      }
      case "Binary":
        walkExp(e.left, scope);
        walkExp(e.right, scope);
        break;
      case "Unary":
        walkExp(e.arg, scope);
        break;
      case "Paren":
        walkExp(e.exp, scope);
        break;
      case "Table":
        e.fields.forEach((f) => walkField(f, scope));
        break;
      case "Function":
        walkBody(e.body, scope);
        break;
      case "Index":
        walkExp(e.object, scope);
        walkExp(e.key, scope);
        break;
      case "Member":
        walkExp(e.object, scope);
        break;
      case "Call":
        walkExp(e.callee, scope);
        e.args.forEach((a) => walkExp(a, scope));
        break;
      case "IfExp":
        e.clauses.forEach((c) => {
          walkExp(c.test, scope);
          walkExp(c.value, scope);
        });
        walkExp(e.otherwise, scope);
        break;
      default:
        break;
    }
  };

  const walkField = (f: Field, scope: Scope) => {
    walkExp(f.value, scope);
    if (f.kind === "index") walkExp(f.key, scope);
  };

  walkStats(chunk.body, { map: new Map() });
  return { locals: n };
}

function toBase(n: number, base: number) {
  return n.toString(base);
}

function confuseName(n: number, rng: Rng) {
  const alphabet = ["l", "I", "O", "0", "o", "_"];
  let s = "_";
  const len = 6 + (n % 5);
  for (let i = 0; i < len; i++) s += alphabet[rng.int(alphabet.length)]!;
  s += n.toString(16);
  return s;
}

export function collectStrings(chunk: Chunk): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const add = (s: string) => {
    if (!seen.has(s)) {
      seen.add(s);
      out.push(s);
    }
  };
  visit(chunk, {
    string: (v) => add(v),
    member: (name) => add(name),
    rec: (name) => add(name),
    method: (name) => add(name),
  });
  return out;
}

type VisitHooks = {
  string?: (v: string, replace: (e: Exp) => void, node: { type: "String"; value: string }) => void;
  member?: (name: string) => void;
  rec?: (name: string) => void;
  method?: (name: string) => void;
};

function visit(chunk: Chunk, hooks: VisitHooks) {
  const stats = (ss: Stat[]) => ss.forEach(stat);
  const stat = (s: Stat) => {
    switch (s.type) {
      case "Assignment":
        s.vars.forEach(exp);
        s.exps.forEach(exp);
        break;
      case "CallStat":
        exp(s.call);
        break;
      case "Do":
      case "While":
        if (s.type === "While") exp(s.cond);
        stats(s.body);
        break;
      case "Repeat":
        stats(s.body);
        exp(s.cond);
        break;
      case "If":
        s.clauses.forEach((c) => {
          exp(c.test);
          stats(c.body);
        });
        if (s.otherwise) stats(s.otherwise);
        break;
      case "ForNum":
        exp(s.start);
        exp(s.last);
        if (s.step) exp(s.step);
        stats(s.body);
        break;
      case "ForIn":
        s.exps.forEach(exp);
        stats(s.body);
        break;
      case "FunctionStat":
        body(s.body);
        break;
      case "LocalFunction":
        body(s.body);
        break;
      case "Local":
        s.exps?.forEach(exp);
        break;
      case "Return":
        s.exps?.forEach(exp);
        break;
      default:
        break;
    }
  };
  const body = (b: FuncBody) => stats(b.body);
  const exp = (e: Exp) => {
    switch (e.type) {
      case "String":
        hooks.string?.(e.value, () => undefined, e);
        break;
      case "Binary":
        exp(e.left);
        exp(e.right);
        break;
      case "Unary":
        exp(e.arg);
        break;
      case "Paren":
        exp(e.exp);
        break;
      case "Table":
        e.fields.forEach((f) => {
          if (f.kind === "rec") hooks.rec?.(f.name);
          if (f.kind === "index") exp(f.key);
          exp(f.value);
        });
        break;
      case "Function":
        body(e.body);
        break;
      case "Index":
        exp(e.object);
        exp(e.key);
        break;
      case "Member":
        hooks.member?.(e.name);
        exp(e.object);
        break;
      case "Call":
        if (e.method) hooks.method?.(e.method);
        exp(e.callee);
        e.args.forEach(exp);
        break;
      case "IfExp":
        e.clauses.forEach((c) => {
          exp(c.test);
          exp(c.value);
        });
        exp(e.otherwise);
        break;
      default:
        break;
    }
  };
  stats(chunk.body);
}

export function replaceStrings(
  chunk: Chunk,
  decode: (value: string) => Exp,
  members: boolean,
) {
  const mapExp = (e: Exp): Exp => {
    switch (e.type) {
      case "String":
        return decode(e.value);
      case "Binary":
        return { ...e, left: mapExp(e.left), right: mapExp(e.right) };
      case "Unary":
        return { ...e, arg: mapExp(e.arg) };
      case "Paren":
        return { ...e, exp: mapExp(e.exp) };
      case "Table":
        return {
          ...e,
          fields: e.fields.map((f) => {
            if (f.kind === "list") return { ...f, value: mapExp(f.value) };
            if (f.kind === "index") return { ...f, key: mapExp(f.key), value: mapExp(f.value) };
            if (members) {
              return { kind: "index" as const, key: decode(f.name), value: mapExp(f.value) };
            }
            return { ...f, value: mapExp(f.value) };
          }),
        };
      case "Function":
        return { ...e, body: mapBody(e.body) };
      case "Index":
        return { ...e, object: mapExp(e.object), key: mapExp(e.key) };
      case "Member": {
        const object = mapExp(e.object);
        if (members) return { type: "Index", object, key: decode(e.name) };
        return { ...e, object };
      }
      case "Call": {
        const callee = mapExp(e.callee);
        const args = e.args.map(mapExp);
        if (members && e.method) {
          return desugarMethod(callee, e.method, args, decode);
        }
        return { ...e, callee, args };
      }
      case "IfExp":
        return {
          ...e,
          clauses: e.clauses.map((c) => ({ test: mapExp(c.test), value: mapExp(c.value) })),
          otherwise: mapExp(e.otherwise),
        };
      default:
        return e;
    }
  };

  const mapBody = (b: FuncBody): FuncBody => ({ ...b, body: b.body.map(mapStat) });

  const mapStat = (s: Stat): Stat => {
    switch (s.type) {
      case "Assignment":
        return { ...s, vars: s.vars.map(mapExp), exps: s.exps.map(mapExp) };
      case "CallStat":
        return { ...s, call: mapExp(s.call) as CallExp };
      case "Do":
        return { ...s, body: s.body.map(mapStat) };
      case "While":
        return { ...s, cond: mapExp(s.cond), body: s.body.map(mapStat) };
      case "Repeat":
        return { ...s, body: s.body.map(mapStat), cond: mapExp(s.cond) };
      case "If":
        return {
          ...s,
          clauses: s.clauses.map((c) => ({ test: mapExp(c.test), body: c.body.map(mapStat) })),
          otherwise: s.otherwise?.map(mapStat),
        };
      case "ForNum":
        return {
          ...s,
          start: mapExp(s.start),
          last: mapExp(s.last),
          step: s.step ? mapExp(s.step) : undefined,
          body: s.body.map(mapStat),
        };
      case "ForIn":
        return { ...s, exps: s.exps.map(mapExp), body: s.body.map(mapStat) };
      case "FunctionStat":
        return { ...s, body: mapBody(s.body) };
      case "LocalFunction":
        return { ...s, body: mapBody(s.body) };
      case "Local":
        return { ...s, exps: s.exps?.map(mapExp) };
      case "Return":
        return { ...s, exps: s.exps?.map(mapExp) };
      default:
        return s;
    }
  };

  chunk.body = chunk.body.map(mapStat);
}

function desugarMethod(object: Exp, method: string, args: Exp[], decode: (s: string) => Exp): CallExp {
  const simple = object.type === "Name";
  if (simple) {
    return {
      type: "Call",
      callee: { type: "Index", object, key: decode(method) },
      args: [object, ...args],
    };
  }
  return {
    type: "Call",
    callee: {
      type: "Function",
      body: {
        params: ["_o"],
        vararg: false,
        body: [
          {
            type: "Return",
            exps: [
              {
                type: "Call",
                callee: {
                  type: "Index",
                  object: { type: "Name", name: "_o" },
                  key: decode(method),
                },
                args: [{ type: "Name", name: "_o" }, ...args],
              },
            ],
          },
        ],
      },
    },
    args: [object],
  };
}

export function rewriteNumbers(chunk: Chunk, rng: Rng, intensity: number) {
  const mapExp = (e: Exp): Exp => {
    switch (e.type) {
      case "Number":
        return obfuscateNumber(e.value, rng, intensity);
      case "Binary":
        return { ...e, left: mapExp(e.left), right: mapExp(e.right) };
      case "Unary":
        return { ...e, arg: mapExp(e.arg) };
      case "Paren":
        return { ...e, exp: mapExp(e.exp) };
      case "Table":
        return {
          ...e,
          fields: e.fields.map((f) => {
            if (f.kind === "index") return { ...f, key: mapExp(f.key), value: mapExp(f.value) };
            return { ...f, value: mapExp(f.value) };
          }),
        };
      case "Function":
        return { ...e, body: { ...e.body, body: e.body.body.map(mapStat) } };
      case "Index":
        return { ...e, object: mapExp(e.object), key: mapExp(e.key) };
      case "Member":
        return { ...e, object: mapExp(e.object) };
      case "Call":
        return { ...e, callee: mapExp(e.callee), args: e.args.map(mapExp) };
      case "IfExp":
        return {
          ...e,
          clauses: e.clauses.map((c) => ({ test: mapExp(c.test), value: mapExp(c.value) })),
          otherwise: mapExp(e.otherwise),
        };
      default:
        return e;
    }
  };
  const mapStat = (s: Stat): Stat => {
    switch (s.type) {
      case "Assignment":
        return { ...s, vars: s.vars.map(mapExp), exps: s.exps.map(mapExp) };
      case "CallStat":
        return { ...s, call: mapExp(s.call) as CallExp };
      case "Do":
        return { ...s, body: s.body.map(mapStat) };
      case "While":
        return { ...s, cond: mapExp(s.cond), body: s.body.map(mapStat) };
      case "Repeat":
        return { ...s, body: s.body.map(mapStat), cond: mapExp(s.cond) };
      case "If":
        return {
          ...s,
          clauses: s.clauses.map((c) => ({ test: mapExp(c.test), body: c.body.map(mapStat) })),
          otherwise: s.otherwise?.map(mapStat),
        };
      case "ForNum":
        return {
          ...s,
          start: mapExp(s.start),
          last: mapExp(s.last),
          step: s.step ? mapExp(s.step) : undefined,
          body: s.body.map(mapStat),
        };
      case "ForIn":
        return { ...s, exps: s.exps.map(mapExp), body: s.body.map(mapStat) };
      case "FunctionStat":
        return { ...s, body: { ...s.body, body: s.body.body.map(mapStat) } };
      case "LocalFunction":
        return { ...s, body: { ...s.body, body: s.body.body.map(mapStat) } };
      case "Local":
        return { ...s, exps: s.exps?.map(mapExp) };
      case "Return":
        return { ...s, exps: s.exps?.map(mapExp) };
      default:
        return s;
    }
  };
  chunk.body = chunk.body.map(mapStat);
}

export function obfuscateNumber(n: number, rng: Rng, intensity: number): Exp {
  if (!Number.isFinite(n)) return { type: "Number", value: n, raw: String(n) };
  if (!Number.isInteger(n) || Math.abs(n) > 0x7fffffff) {
    if (intensity < 1) return { type: "Number", value: n, raw: String(n) };
    const a = rng.int(40) + 1;
    return {
      type: "Binary",
      op: "-",
      left: { type: "Number", value: n + a, raw: String(n + a) },
      right: { type: "Number", value: a, raw: String(a) },
    };
  }
  const mode = rng.int(2 + intensity);
  const a = rng.int(80) + 3;
  if (mode === 0) {
    return {
      type: "Binary",
      op: "-",
      left: { type: "Number", value: n + a, raw: String(n + a) },
      right: { type: "Number", value: a, raw: String(a) },
    };
  }
  if (mode === 1) {
    const x = (n ^ a) >>> 0;
    return xorCall(x, a);
  }
  const b = rng.int(50) + 2;
  return {
    type: "Binary",
    op: "+",
    left: {
      type: "Binary",
      op: "-",
      left: { type: "Number", value: n + a, raw: String(n + a) },
      right: { type: "Number", value: a, raw: String(a) },
    },
    right: {
      type: "Binary",
      op: "-",
      left: { type: "Number", value: b, raw: String(b) },
      right: { type: "Number", value: b, raw: String(b) },
    },
  };
}

function xorCall(a: number, b: number): Exp {
  return {
    type: "Call",
    callee: { type: "Member", object: { type: "Name", name: "bit32" }, name: "bxor" },
    args: [
      { type: "Number", value: a, raw: "0x" + a.toString(16) },
      { type: "Number", value: b, raw: "0x" + b.toString(16) },
    ],
  };
}

export function injectOpaque(chunk: Chunk, rng: Rng, density: number) {
  const wrap = (stats: Stat[]): Stat[] => {
    const out: Stat[] = [];
    for (const s of stats) {
      const mapped = mapStat(s);
      if (rng.next() < density && canWrap(mapped)) {
        const k = rng.int(200) + 7;
        out.push({
          type: "If",
          clauses: [
            {
              test: {
                type: "Binary",
                op: "==",
                left: xorCall(k, k),
                right: { type: "Number", value: 0, raw: "0" },
              },
              body: [mapped],
            },
          ],
          otherwise: rng.next() < 0.5 ? junkBlock(rng) : undefined,
        });
      } else {
        out.push(mapped);
      }
    }
    return out;
  };

  const mapStat = (s: Stat): Stat => {
    switch (s.type) {
      case "Do":
        return { ...s, body: wrap(s.body) };
      case "While":
        return { ...s, body: wrap(s.body) };
      case "Repeat":
        return { ...s, body: wrap(s.body) };
      case "If":
        return {
          ...s,
          clauses: s.clauses.map((c) => ({ ...c, body: wrap(c.body) })),
          otherwise: s.otherwise ? wrap(s.otherwise) : undefined,
        };
      case "ForNum":
        return { ...s, body: wrap(s.body) };
      case "ForIn":
        return { ...s, body: wrap(s.body) };
      case "FunctionStat":
        return { ...s, body: { ...s.body, body: wrap(s.body.body) } };
      case "LocalFunction":
        return { ...s, body: { ...s.body, body: wrap(s.body.body) } };
      default:
        return s;
    }
  };

  chunk.body = wrap(chunk.body);
}

function canWrap(s: Stat) {
  return s.type !== "Local" && s.type !== "LocalFunction" && s.type !== "Return" && s.type !== "Break" && s.type !== "Continue";
}

function junkBlock(rng: Rng): Stat[] {
  const n = rng.int(4) + 1;
  const name = `_j${rng.int(9999)}`;
  return [
    { type: "Local", names: [name], exps: [{ type: "Number", value: n, raw: String(n) }] },
    {
      type: "Assignment",
      vars: [{ type: "Name", name }],
      exps: [
        {
          type: "Binary",
          op: "+",
          left: { type: "Name", name },
          right: { type: "Number", value: 0, raw: "0" },
        },
      ],
    },
  ];
}

export function wrapChunk(chunk: Chunk, prelude: Stat[]): Chunk {
  return {
    type: "Chunk",
    body: [
      {
        type: "Return",
        exps: [
          {
            type: "Call",
            callee: {
              type: "Paren",
              exp: {
                type: "Function",
                body: {
                  params: [],
                  vararg: true,
                  body: [...prelude, ...chunk.body],
                },
              },
            },
            args: [{ type: "Vararg" }],
          },
        ],
      },
    ],
  };
}
