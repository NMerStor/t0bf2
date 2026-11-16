import {
  type BinOp,
  type Chunk,
  type CompoundOp,
  type Exp,
  type Field,
  type FuncBody,
  type FuncName,
  ParseError,
  type Stat,
  type UnOp,
} from "./ast.js";
import { isKeyword, tokenize, type Token } from "./lexer.js";

const COMPOUND = new Set<string>(["+=", "-=", "*=", "/=", "%=", "^=", "..=", "//="]);

const UNARY: Record<string, number> = { not: 8, "#": 8, "-": 8 };
const PREC: Record<string, { p: number; right?: boolean }> = {
  or: { p: 1 },
  and: { p: 2 },
  "<": { p: 3 },
  ">": { p: 3 },
  "<=": { p: 3 },
  ">=": { p: 3 },
  "~=": { p: 3 },
  "!=": { p: 3 },
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

export function parse(source: string): Chunk {
  return new Parser(source).parseChunk();
}

class Parser {
  private tokens: Token[];
  private i = 0;
  private source: string;

  constructor(source: string) {
    this.source = source;
    this.tokens = tokenize(source);
  }

  private tok(): Token {
    return this.tokens[this.i] ?? this.tokens[this.tokens.length - 1]!;
  }

  private peekKind(): string {
    const t = this.tok();
    if (t.kind === "keyword" || t.kind === "op") return t.value;
    return t.kind;
  }

  private at(kind: string, value?: string): boolean {
    const t = this.tok();
    if (value !== undefined) return t.kind === kind && t.value === value;
    if (t.kind === "keyword" || t.kind === "op") return t.value === kind;
    return t.kind === kind;
  }

  private eat(kind: string, value?: string): Token | null {
    if (this.at(kind, value)) {
      const t = this.tok();
      this.i += 1;
      return t;
    }
    return null;
  }

  private expect(kind: string, value?: string): Token {
    const t = this.eat(kind, value);
    if (t) return t;
    const cur = this.tok();
    throw new ParseError(
      `expected ${value ?? kind}, got ${cur.value || cur.kind}`,
      cur.line,
      cur.column,
    );
  }

  private err(msg: string): never {
    const t = this.tok();
    throw new ParseError(msg, t.line, t.column);
  }

  parseChunk(): Chunk {
    const body = this.parseBlock();
    if (!this.at("eof")) this.err("expected end of file");
    return { type: "Chunk", body };
  }

  private parseBlock(terminators: string[] = []): Stat[] {
    const body: Stat[] = [];
    while (!this.at("eof")) {
      const k = this.peekKind();
      if (terminators.includes(k)) break;
      if (k === "end" || k === "else" || k === "elseif" || k === "until") break;
      if (this.eat("op", ";")) continue;
      if (k === "return") {
        body.push(this.parseReturn());
        this.eat("op", ";");
        break;
      }
      const stat = this.parseStat();
      if (stat) body.push(stat);
      this.eat("op", ";");
    }
    return body;
  }

  private parseStat(): Stat {
    if (isKeyword(this.tok(), "do")) {
      this.i += 1;
      const body = this.parseBlock();
      this.expect("keyword", "end");
      return { type: "Do", body };
    }
    if (isKeyword(this.tok(), "while")) {
      this.i += 1;
      const cond = this.parseExp();
      this.expect("keyword", "do");
      const body = this.parseBlock();
      this.expect("keyword", "end");
      return { type: "While", cond, body };
    }
    if (isKeyword(this.tok(), "repeat")) {
      this.i += 1;
      const body = this.parseBlock(["until"]);
      this.expect("keyword", "until");
      const cond = this.parseExp();
      return { type: "Repeat", body, cond };
    }
    if (isKeyword(this.tok(), "if")) return this.parseIf();
    if (isKeyword(this.tok(), "for")) return this.parseFor();
    if (isKeyword(this.tok(), "function")) {
      this.i += 1;
      const name = this.parseFuncName();
      const body = this.parseFuncBody();
      return { type: "FunctionStat", name, body };
    }
    if (isKeyword(this.tok(), "local")) return this.parseLocal();
    if (isKeyword(this.tok(), "break")) {
      this.i += 1;
      return { type: "Break" };
    }
    if (isKeyword(this.tok(), "continue")) {
      this.i += 1;
      return { type: "Continue" };
    }
    if (isKeyword(this.tok(), "type") || (this.at("name", "type") && this.looksLikeTypeAlias())) {
      this.skipTypeAlias();
      return { type: "Do", body: [] };
    }
    if (this.at("name", "export") && this.looksLikeExportType()) {
      this.skipTypeAlias();
      return { type: "Do", body: [] };
    }

    const first = this.parsePrefix();
    if (this.at("op", ",") || this.at("op", "=") || COMPOUND.has(this.tok().value)) {
      const vars = [first];
      while (this.eat("op", ",")) vars.push(this.parsePrefix());
      const opTok = this.tok();
      if (COMPOUND.has(opTok.value)) {
        this.i += 1;
        if (vars.length !== 1) this.err("compound assignment needs one target");
        const exps = this.parseExpList();
        return { type: "Assignment", vars, exps, compound: opTok.value as CompoundOp };
      }
      this.expect("op", "=");
      const exps = this.parseExpList();
      return { type: "Assignment", vars, exps };
    }
    if (first.type === "Call") return { type: "CallStat", call: first };
    this.err("expected statement");
  }

  private looksLikeTypeAlias(): boolean {
    const next = this.tokens[this.i + 1];
    if (!next || next.kind !== "name") return false;
    const after = this.tokens[this.i + 2];
    return Boolean(after && after.kind === "op" && (after.value === "=" || after.value === "<"));
  }

  private looksLikeExportType(): boolean {
    const next = this.tokens[this.i + 1];
    return Boolean(next && ((next.kind === "name" && next.value === "type") || (next.kind === "keyword" && next.value === "type")));
  }

  private skipTypeAlias() {
    if (this.at("name", "export")) this.i += 1;
    if (this.at("name", "type") || isKeyword(this.tok(), "type")) this.i += 1;
    if (this.at("name")) this.i += 1;
    if (this.at("op", "<")) this.skipBalanced("<", ">");
    if (this.at("op", "=")) this.i += 1;
    this.skipType();
  }

  private skipBalanced(open: string, close: string) {
    let depth = 0;
    do {
      const t = this.tok();
      if (t.kind === "eof") this.err("unfinished type");
      if (t.kind === "op" && t.value === open) depth += 1;
      else if (t.kind === "op" && t.value === close) depth -= 1;
      this.i += 1;
    } while (depth > 0);
  }

  private skipType() {
    let depth = 0;
    while (!this.at("eof")) {
      const t = this.tok();
      const v = t.value;
      if (depth === 0) {
        if (t.kind === "op" && (v === "," || v === ")" || v === ";" || v === "=")) {
          break;
        }
        if (t.kind === "keyword" && ["end", "then", "do", "else", "elseif", "until", "in"].includes(v)) {
          break;
        }
      }
      if (t.kind === "op" && (v === "(" || v === "{" || v === "[" || v === "<")) {
        depth += 1;
        this.i += 1;
        continue;
      }
      if (t.kind === "op" && (v === ")" || v === "}" || v === "]" || v === ">")) {
        if (depth === 0) break;
        depth -= 1;
        this.i += 1;
        continue;
      }
      this.i += 1;
      if (depth === 0 && t.kind === "op" && v === "->") continue;
    }
  }

  private parseIf(): Stat {
    this.expect("keyword", "if");
    const clauses: { test: Exp; body: Stat[] }[] = [];
    const test = this.parseExp();
    this.expect("keyword", "then");
    clauses.push({ test, body: this.parseBlock() });
    while (isKeyword(this.tok(), "elseif")) {
      this.i += 1;
      const t = this.parseExp();
      this.expect("keyword", "then");
      clauses.push({ test: t, body: this.parseBlock() });
    }
    let otherwise: Stat[] | undefined;
    if (isKeyword(this.tok(), "else")) {
      this.i += 1;
      otherwise = this.parseBlock();
    }
    this.expect("keyword", "end");
    return { type: "If", clauses, otherwise };
  }

  private parseFor(): Stat {
    this.expect("keyword", "for");
    const first = this.expect("name").value;
    this.maybeSkipTypeAnnot();
    if (this.eat("op", "=")) {
      const start = this.parseExp();
      this.expect("op", ",");
      const last = this.parseExp();
      let step: Exp | undefined;
      if (this.eat("op", ",")) step = this.parseExp();
      this.expect("keyword", "do");
      const body = this.parseBlock();
      this.expect("keyword", "end");
      return { type: "ForNum", name: first, start, last, step, body };
    }
    const names = [first];
    while (this.eat("op", ",")) {
      names.push(this.expect("name").value);
      this.maybeSkipTypeAnnot();
    }
    this.expect("keyword", "in");
    const exps = this.parseExpList();
    this.expect("keyword", "do");
    const body = this.parseBlock();
    this.expect("keyword", "end");
    return { type: "ForIn", names, exps, body };
  }

  private parseLocal(): Stat {
    this.expect("keyword", "local");
    if (isKeyword(this.tok(), "function")) {
      this.i += 1;
      const name = this.expect("name").value;
      this.maybeSkipGenerics();
      const body = this.parseFuncBody();
      return { type: "LocalFunction", name, body };
    }
    const names = [this.expect("name").value];
    this.maybeSkipGenerics();
    this.maybeSkipTypeAnnot();
    while (this.eat("op", ",")) {
      names.push(this.expect("name").value);
      this.maybeSkipGenerics();
      this.maybeSkipTypeAnnot();
    }
    let exps: Exp[] | undefined;
    if (this.eat("op", "=")) exps = this.parseExpList();
    return { type: "Local", names, exps };
  }

  private maybeSkipGenerics() {
    if (this.at("op", "<")) this.skipBalanced("<", ">");
  }

  private maybeSkipTypeAnnot() {
    if (this.eat("op", ":") || this.eat("op", "::")) this.skipType();
  }

  private parseReturn(): Stat {
    this.expect("keyword", "return");
    const k = this.peekKind();
    if (
      k === "eof" ||
      k === ";" ||
      k === "end" ||
      k === "else" ||
      k === "elseif" ||
      k === "until"
    ) {
      return { type: "Return" };
    }
    return { type: "Return", exps: this.parseExpList() };
  }

  private parseFuncName(): FuncName {
    const parts = [this.expect("name").value];
    while (this.eat("op", ".")) parts.push(this.expect("name").value);
    let method: string | undefined;
    if (this.eat("op", ":")) method = this.expect("name").value;
    return { parts, method };
  }

  private parseFuncBody(): FuncBody {
    this.maybeSkipGenerics();
    this.expect("op", "(");
    const params: string[] = [];
    let vararg = false;
    if (!this.at("op", ")")) {
      while (true) {
        if (this.eat("op", "...")) {
          vararg = true;
          this.maybeSkipTypeAnnot();
          break;
        }
        params.push(this.expect("name").value);
        this.maybeSkipTypeAnnot();
        if (!this.eat("op", ",")) break;
      }
    }
    this.expect("op", ")");
    this.maybeSkipTypeAnnot();
    const body = this.parseBlock();
    this.expect("keyword", "end");
    return { params, vararg, body };
  }

  private parseExpList(): Exp[] {
    const list = [this.parseExp()];
    while (this.eat("op", ",")) list.push(this.parseExp());
    return list;
  }

  parseExp(minPrec = 0): Exp {
    let left = this.parsePrefixExp();
    for (;;) {
      if (this.eat("op", "::")) {
        this.skipType();
        continue;
      }
      const t = this.tok();
      const op = t.kind === "keyword" || t.kind === "op" ? t.value : "";
      const info = PREC[op];
      if (!info || info.p < minPrec) break;
      this.i += 1;
      const nextMin = info.right ? info.p : info.p + 1;
      const right = this.parseExp(nextMin);
      const norm = op === "!=" ? "~=" : op;
      left = { type: "Binary", op: norm as BinOp, left, right };
    }
    return left;
  }

  private parsePrefixExp(): Exp {
    const t = this.tok();
    if (t.kind === "keyword" && t.value === "not") {
      this.i += 1;
      return { type: "Unary", op: "not", arg: this.parseExp(UNARY.not) };
    }
    if (t.kind === "op" && (t.value === "-" || t.value === "#")) {
      this.i += 1;
      return { type: "Unary", op: t.value as UnOp, arg: this.parseExp(UNARY[t.value]!) };
    }
    return this.parsePrimary();
  }

  private parsePrimary(): Exp {
    const t = this.tok();
    if (isKeyword(t, "nil")) {
      this.i += 1;
      return { type: "Nil" };
    }
    if (isKeyword(t, "true") || isKeyword(t, "false")) {
      this.i += 1;
      return { type: "Boolean", value: t.value === "true" };
    }
    if (t.kind === "number") {
      this.i += 1;
      return { type: "Number", value: Number(t.value.replace(/_/g, "")), raw: t.value };
    }
    if (t.kind === "string") {
      this.i += 1;
      return { type: "String", value: t.value };
    }
    if (t.kind === "interp") {
      this.i += 1;
      return this.interpToExp(t.value);
    }
    if (t.kind === "op" && t.value === "...") {
      this.i += 1;
      return { type: "Vararg" };
    }
    if (isKeyword(t, "function")) {
      this.i += 1;
      return { type: "Function", body: this.parseFuncBody() };
    }
    if (isKeyword(t, "if")) return this.parseIfExp();
    if (t.kind === "op" && t.value === "{") return this.parseTable();
    return this.parsePrefix();
  }

  private parseIfExp(): Exp {
    this.expect("keyword", "if");
    const clauses: { test: Exp; value: Exp }[] = [];
    const test = this.parseExp();
    this.expect("keyword", "then");
    const value = this.parseExp();
    clauses.push({ test, value });
    while (isKeyword(this.tok(), "elseif")) {
      this.i += 1;
      const te = this.parseExp();
      this.expect("keyword", "then");
      clauses.push({ test: te, value: this.parseExp() });
    }
    this.expect("keyword", "else");
    const otherwise = this.parseExp();
    return { type: "IfExp", clauses, otherwise };
  }

  private parsePrefix(): Exp {
    let node: Exp;
    if (this.at("op", "(")) {
      this.i += 1;
      const inner = this.parseExp();
      this.expect("op", ")");
      node = { type: "Paren", exp: inner };
    } else if (this.at("name")) {
      node = { type: "Name", name: this.expect("name").value };
    } else {
      this.err("expected expression");
    }

    for (;;) {
      if (this.eat("op", "[")) {
        const key = this.parseExp();
        this.expect("op", "]");
        node = { type: "Index", object: node, key };
        continue;
      }
      if (this.eat("op", ".")) {
        node = { type: "Member", object: node, name: this.expect("name").value };
        continue;
      }
      if (this.eat("op", ":")) {
        const method = this.expect("name").value;
        const args = this.parseArgs();
        if (!args) this.err("expected method arguments");
        node = { type: "Call", callee: node, args, method };
        continue;
      }
      const args = this.parseArgs();
      if (args) {
        node = { type: "Call", callee: node, args };
        continue;
      }
      break;
    }
    return node;
  }

  private parseArgs(): Exp[] | null {
    if (this.eat("op", "(")) {
      if (this.eat("op", ")")) return [];
      const list = this.parseExpList();
      this.expect("op", ")");
      return list;
    }
    if (this.at("op", "{")) return [this.parseTable()];
    if (this.at("string")) {
      const s = this.expect("string");
      return [{ type: "String", value: s.value }];
    }
    return null;
  }

  private parseTable(): Exp {
    this.expect("op", "{");
    const fields: Field[] = [];
    while (!this.at("op", "}") && !this.at("eof")) {
      if (this.eat("op", "[")) {
        const key = this.parseExp();
        this.expect("op", "]");
        this.expect("op", "=");
        fields.push({ kind: "index", key, value: this.parseExp() });
      } else if (this.at("name") && this.tokens[this.i + 1]?.value === "=") {
        const name = this.expect("name").value;
        this.expect("op", "=");
        fields.push({ kind: "rec", name, value: this.parseExp() });
      } else {
        fields.push({ kind: "list", value: this.parseExp() });
      }
      if (this.eat("op", ",") || this.eat("op", ";")) continue;
      break;
    }
    this.expect("op", "}");
    return { type: "Table", fields };
  }

  private interpToExp(raw: string): Exp {
    const parts: Exp[] = [];
    let buf = "";
    let i = 0;
    const unescape = (s: string) =>
      s.replace(/\\(.)/g, (_, ch: string) => {
        const map: Record<string, string> = { n: "\n", t: "\t", "`": "`", "{": "{", "}": "}", "\\": "\\" };
        return map[ch] ?? ch;
      });
    while (i < raw.length) {
      if (raw[i] === "\\" && i + 1 < raw.length) {
        buf += unescape(raw.slice(i, i + 2));
        i += 2;
        continue;
      }
      if (raw[i] === "{") {
        if (buf) {
          parts.push({ type: "String", value: buf });
          buf = "";
        }
        i += 1;
        let depth = 1;
        const start = i;
        while (i < raw.length && depth > 0) {
          if (raw[i] === "{") depth += 1;
          else if (raw[i] === "}") depth -= 1;
          if (depth > 0) i += 1;
        }
        const inner = raw.slice(start, i);
        i += 1;
        const innerExp = new Parser(inner).parseExp();
        parts.push({
          type: "Call",
          callee: { type: "Name", name: "tostring" },
          args: [innerExp],
        });
        continue;
      }
      buf += raw[i] ?? "";
      i += 1;
    }
    if (buf) parts.push({ type: "String", value: buf });
    if (parts.length === 0) return { type: "String", value: "" };
    return parts.reduce((a, b) => ({ type: "Binary", op: "..", left: a, right: b }));
  }
}

export { Parser };
