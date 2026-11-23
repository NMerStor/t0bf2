import type { BinOp, Chunk, Exp, Field, FuncBody, Stat } from "./ast.js";

const PREC: Record<BinOp, { p: number; right?: boolean }> = {
  or: { p: 1 },
  and: { p: 2 },
  "<": { p: 3 },
  ">": { p: 3 },
  "<=": { p: 3 },
  ">=": { p: 3 },
  "~=": { p: 3 },
  "==": { p: 3 },
  "..": { p: 4, right: true },
  "+": { p: 5 },
  "-": { p: 5 },
  "*": { p: 6 },
  "/": { p: 6 },
  "//": { p: 6 },
  "%": { p: 6 },
  "^": { p: 9, right: true },
};

const UNARY = 8;

export type EmitOptions = {
  minify?: boolean;
};

export function emit(chunk: Chunk, options: EmitOptions = {}): string {
  return new Emitter(options).emitChunk(chunk);
}

class Emitter {
  private minify: boolean;
  private indent = 0;
  private out = "";
  private last = "";

  constructor(options: EmitOptions) {
    this.minify = Boolean(options.minify);
  }

  emitChunk(chunk: Chunk): string {
    this.out = "";
    this.last = "";
    this.emitStats(chunk.body);
    return this.out;
  }

  private write(s: string) {
    if (!s) return;
    if (this.out && needsSpace(this.last, s[0] ?? "")) this.out += " ";
    this.out += s;
    this.last = s[s.length - 1] ?? "";
  }

  private nl() {
    if (this.minify) {
      if (this.out && this.last !== ";") {
        this.out += ";";
        this.last = ";";
      }
      return;
    }
    this.out += "\n" + "  ".repeat(this.indent);
    this.last = "\n";
  }

  private emitStats(stats: Stat[]) {
    for (let i = 0; i < stats.length; i++) {
      if (i > 0) this.nl();
      else if (this.out && !this.minify) this.nl();
      const s = stats[i]!;
      if (this.minify && startsAmbiguous(s)) this.write(";");
      this.emitStat(s);
    }
  }

  private emitStat(s: Stat) {
    switch (s.type) {
      case "Assignment": {
        this.emitVarList(s.vars);
        this.write(s.compound ?? "=");
        this.emitExpList(s.exps);
        break;
      }
      case "CallStat":
        this.emitExp(s.call, 0);
        break;
      case "Do":
        this.write("do");
        this.indent += 1;
        this.emitStats(s.body);
        this.indent -= 1;
        this.nl();
        this.write("end");
        break;
      case "While":
        this.write("while");
        this.emitExp(s.cond, 0);
        this.write("do");
        this.indent += 1;
        this.emitStats(s.body);
        this.indent -= 1;
        this.nl();
        this.write("end");
        break;
      case "Repeat":
        this.write("repeat");
        this.indent += 1;
        this.emitStats(s.body);
        this.indent -= 1;
        this.nl();
        this.write("until");
        this.emitExp(s.cond, 0);
        break;
      case "If":
        s.clauses.forEach((c, idx) => {
          this.write(idx === 0 ? "if" : "elseif");
          this.emitExp(c.test, 0);
          this.write("then");
          this.indent += 1;
          this.emitStats(c.body);
          this.indent -= 1;
          this.nl();
        });
        if (s.otherwise) {
          this.write("else");
          this.indent += 1;
          this.emitStats(s.otherwise);
          this.indent -= 1;
          this.nl();
        }
        this.write("end");
        break;
      case "ForNum":
        this.write("for");
        this.write(s.name);
        this.write("=");
        this.emitExp(s.start, 0);
        this.write(",");
        this.emitExp(s.last, 0);
        if (s.step) {
          this.write(",");
          this.emitExp(s.step, 0);
        }
        this.write("do");
        this.indent += 1;
        this.emitStats(s.body);
        this.indent -= 1;
        this.nl();
        this.write("end");
        break;
      case "ForIn":
        this.write("for");
        s.names.forEach((n, i) => {
          if (i) this.write(",");
          this.write(n);
        });
        this.write("in");
        this.emitExpList(s.exps);
        this.write("do");
        this.indent += 1;
        this.emitStats(s.body);
        this.indent -= 1;
        this.nl();
        this.write("end");
        break;
      case "FunctionStat": {
        this.write("function");
        this.write(s.name.parts.join("."));
        if (s.name.method) {
          this.write(":");
          this.write(s.name.method);
        }
        this.emitFuncBody(s.body, Boolean(s.name.method));
        break;
      }
      case "LocalFunction":
        this.write("local function");
        this.write(s.name);
        this.emitFuncBody(s.body, false);
        break;
      case "Local":
        this.write("local");
        s.names.forEach((n, i) => {
          if (i) this.write(",");
          this.write(n);
        });
        if (s.exps) {
          this.write("=");
          this.emitExpList(s.exps);
        }
        break;
      case "Return":
        this.write("return");
        if (s.exps?.length) this.emitExpList(s.exps);
        break;
      case "Break":
        this.write("break");
        break;
      case "Continue":
        this.write("continue");
        break;
    }
  }

  private emitFuncBody(body: FuncBody, method: boolean) {
    this.write("(");
    const params = method ? body.params.filter((p, i) => !(i === 0 && p === "self")) : body.params;
    params.forEach((p, i) => {
      if (i) this.write(",");
      this.write(p);
    });
    if (body.vararg) {
      if (params.length) this.write(",");
      this.write("...");
    }
    this.write(")");
    this.indent += 1;
    this.emitStats(body.body);
    this.indent -= 1;
    this.nl();
    this.write("end");
  }

  private emitVarList(vars: Exp[]) {
    vars.forEach((v, i) => {
      if (i) this.write(",");
      this.emitExp(v, 0);
    });
  }

  private emitExpList(exps: Exp[]) {
    exps.forEach((e, i) => {
      if (i) this.write(",");
      this.emitExp(e, 0);
    });
  }

  private emitExp(e: Exp, parent: number) {
    switch (e.type) {
      case "Nil":
        this.write("nil");
        return;
      case "Boolean":
        this.write(e.value ? "true" : "false");
        return;
      case "Number":
        this.write(formatNumber(e.value, e.raw));
        return;
      case "String":
        this.write(quoteLua(e.value));
        return;
      case "Vararg":
        this.write("...");
        return;
      case "Name":
        this.write(e.name);
        return;
      case "Paren":
        this.write("(");
        this.emitExp(e.exp, 0);
        this.write(")");
        return;
      case "Unary": {
        const wrap = parent > UNARY;
        if (wrap) this.write("(");
        this.write(e.op);
        this.emitExp(e.arg, UNARY);
        if (wrap) this.write(")");
        return;
      }
      case "Binary": {
        const info = PREC[e.op];
        const wrap = info.p < parent || (info.p === parent && !info.right);
        if (wrap) this.write("(");
        this.emitExp(e.left, info.right ? info.p + 1 : info.p);
        this.write(e.op);
        this.emitExp(e.right, info.right ? info.p : info.p + 1);
        if (wrap) this.write(")");
        return;
      }
      case "Table":
        this.write("{");
        e.fields.forEach((f, i) => {
          if (i) this.write(",");
          this.emitField(f);
        });
        this.write("}");
        return;
      case "Function":
        this.write("function");
        this.emitFuncBody(e.body, false);
        return;
      case "Index":
        this.emitExp(e.object, 10);
        this.write("[");
        this.emitExp(e.key, 0);
        this.write("]");
        return;
      case "Member":
        this.emitExp(e.object, 10);
        if (isIdent(e.name)) {
          this.write(".");
          this.write(e.name);
        } else {
          this.write("[");
          this.write(quoteLua(e.name));
          this.write("]");
        }
        return;
      case "Call": {
        this.emitExp(e.callee, 10);
        if (e.method) {
          this.write(":");
          this.write(e.method);
        }
        this.write("(");
        e.args.forEach((a, i) => {
          if (i) this.write(",");
          this.emitExp(a, 0);
        });
        this.write(")");
        return;
      }
      case "IfExp": {
        const wrap = parent > 0;
        if (wrap) this.write("(");
        e.clauses.forEach((c, i) => {
          this.write(i === 0 ? "if" : "elseif");
          this.emitExp(c.test, 0);
          this.write("then");
          this.emitExp(c.value, 0);
        });
        this.write("else");
        this.emitExp(e.otherwise, 0);
        if (wrap) this.write(")");
        return;
      }
    }
  }

  private emitField(f: Field) {
    if (f.kind === "list") {
      this.emitExp(f.value, 0);
      return;
    }
    if (f.kind === "rec" && isIdent(f.name)) {
      this.write(f.name);
      this.write("=");
      this.emitExp(f.value, 0);
      return;
    }
    this.write("[");
    if (f.kind === "rec") this.write(quoteLua(f.name));
    else this.emitExp(f.key, 0);
    this.write("]");
    this.write("=");
    this.emitExp(f.value, 0);
  }
}

function needsSpace(prev: string, next: string) {
  const id = (c: string) => /[A-Za-z0-9_]/.test(c);
  if (id(prev) && id(next)) return true;
  if (prev === "-" && next === "-") return true;
  if (prev === "." && next === ".") return true;
  return false;
}

function startsAmbiguous(s: Stat): boolean {
  if (s.type === "CallStat") return s.call.callee.type === "Paren" || s.call.callee.type === "Function";
  if (s.type === "Assignment") {
    const v = s.vars[0];
    return Boolean(v && (v.type === "Paren" || v.type === "Index"));
  }
  return false;
}

function isIdent(name: string) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
}

function formatNumber(value: number, raw?: string) {
  if (raw && !raw.includes("_") && Number(raw.replace(/_/g, "")) === value) {
    if (/^0[xXbB]/.test(raw) || /^[0-9.]+$/.test(raw)) return raw;
  }
  if (Number.isInteger(value) && Math.abs(value) <= Number.MAX_SAFE_INTEGER) return String(value);
  return String(value);
}

export function quoteLua(value: string): string {
  let single = 0;
  let dbl = 0;
  for (const ch of value) {
    if (ch === "'") single += 1;
    else if (ch === '"') dbl += 1;
  }
  const q = single <= dbl ? "'" : '"';
  let out = q;
  for (const ch of value) {
    const code = ch.charCodeAt(0);
    if (ch === "\\") out += "\\\\";
    else if (ch === q) out += "\\" + q;
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (ch === "\0") out += "\\000";
    else if (code < 32 || code > 126) out += "\\" + String(code).padStart(3, "0");
    else out += ch;
  }
  out += q;
  return out;
}
