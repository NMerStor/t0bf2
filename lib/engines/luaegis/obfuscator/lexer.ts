import { ParseError } from "./ast.js";

export type TokenKind =
  | "eof"
  | "name"
  | "number"
  | "string"
  | "interp"
  | "keyword"
  | "op";

export type Token = {
  kind: TokenKind;
  value: string;
  line: number;
  column: number;
};

const KEYWORDS = new Set([
  "and",
  "break",
  "do",
  "else",
  "elseif",
  "end",
  "false",
  "for",
  "function",
  "if",
  "in",
  "local",
  "nil",
  "not",
  "or",
  "repeat",
  "return",
  "then",
  "true",
  "until",
  "while",
  "continue",
]);

const OPS = [
  "...",
  "..=",
  "..",
  "//=",
  "//",
  "+=",
  "-=",
  "*=",
  "/=",
  "%=",
  "^=",
  "==",
  "~=",
  "!=",
  "<=",
  ">=",
  "::",
  "->",
  "+",
  "-",
  "*",
  "/",
  "%",
  "^",
  "#",
  "<",
  ">",
  "=",
  "(",
  ")",
  "{",
  "}",
  "[",
  "]",
  ";",
  ":",
  ",",
  ".",
];

export function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  const n = source.length;
  let line = 1;
  let col = 1;

  const peek = (k = 0) => source[i + k] ?? "";
  const at = () => ({ line, column: col });

  function advance(count = 1) {
    for (let k = 0; k < count; k++) {
      if (source[i] === "\n") {
        line += 1;
        col = 1;
      } else {
        col += 1;
      }
      i += 1;
    }
  }

  function startsLong(from: number, opener: "[" | "--["): { eq: number } | null {
    let p = from;
    if (opener === "--[") {
      if (source.slice(from, from + 3) !== "--[") return null;
      p = from + 3;
    } else {
      if (source[from] !== "[") return null;
      p = from + 1;
    }
    let eq = 0;
    while (source[p] === "=") {
      eq += 1;
      p += 1;
    }
    if (source[p] !== "[") return null;
    return { eq };
  }

  function readLong(eq: number, startAdvance: number): string {
    advance(startAdvance);
    const close = "]" + "=".repeat(eq) + "]";
    const start = i;
    const idx = source.indexOf(close, i);
    if (idx < 0) throw new ParseError("unfinished long string", line, col);
    const value = source.slice(start, idx);
    const skip = idx + close.length - i;
    advance(skip);
    return value;
  }

  function readShortString(q: string): string {
    const pos = at();
    advance();
    let out = "";
    while (i < n) {
      const c = peek();
      if (c === q) {
        advance();
        return out;
      }
      if (c === "\n") throw new ParseError("unfinished string", pos.line, pos.column);
      if (c === "\\") {
        advance();
        const e = peek();
        const map: Record<string, string> = {
          a: "\x07",
          b: "\b",
          f: "\f",
          n: "\n",
          r: "\r",
          t: "\t",
          v: "\v",
          "\\": "\\",
          '"': '"',
          "'": "'",
          "`": "`",
          "\n": "\n",
        };
        if (e in map) {
          out += map[e];
          advance();
          continue;
        }
        if (e === "x") {
          const hex = source.slice(i + 1, i + 3);
          if (!/^[0-9a-fA-F]{2}$/.test(hex)) {
            throw new ParseError("invalid hex escape", line, col);
          }
          out += String.fromCharCode(parseInt(hex, 16));
          advance(3);
          continue;
        }
        if (e === "u") {
          if (peek(1) !== "{") throw new ParseError("invalid unicode escape", line, col);
          let j = i + 2;
          while (source[j] && source[j] !== "}") j += 1;
          const hex = source.slice(i + 2, j);
          out += String.fromCodePoint(parseInt(hex, 16) || 0);
          advance(j + 1 - i);
          continue;
        }
        if (/[0-9]/.test(e)) {
          let j = 0;
          let digits = "";
          while (j < 3 && /[0-9]/.test(peek(j))) {
            digits += peek(j);
            j += 1;
          }
          out += String.fromCharCode(parseInt(digits, 10) % 256);
          advance(j);
          continue;
        }
        if (e === "z") {
          advance();
          while (/\s/.test(peek())) advance();
          continue;
        }
        out += e;
        advance();
        continue;
      }
      out += c;
      advance();
    }
    throw new ParseError("unfinished string", pos.line, pos.column);
  }

  function readInterp(): string {
    const pos = at();
    advance();
    let raw = "";
    while (i < n) {
      const c = peek();
      if (c === "`") {
        advance();
        return raw;
      }
      if (c === "\\") {
        raw += c;
        advance();
        if (i < n) {
          raw += peek();
          advance();
        }
        continue;
      }
      raw += c;
      advance();
    }
    throw new ParseError("unfinished interpolated string", pos.line, pos.column);
  }

  function readNumber(): string {
    const start = i;
    if (peek() === "0" && /[xX]/.test(peek(1))) {
      advance(2);
      while (/[0-9a-fA-F_]/.test(peek())) advance();
      if (/[pP]/.test(peek())) {
        advance();
        if (/[+-]/.test(peek())) advance();
        while (/[0-9_]/.test(peek())) advance();
      }
      return source.slice(start, i);
    }
    if (peek() === "0" && /[bB]/.test(peek(1))) {
      advance(2);
      while (/[01_]/.test(peek())) advance();
      return source.slice(start, i);
    }
    while (/[0-9_]/.test(peek())) advance();
    if (peek() === "." && peek(1) !== ".") {
      advance();
      while (/[0-9_]/.test(peek())) advance();
    }
    if (/[eE]/.test(peek())) {
      advance();
      if (/[+-]/.test(peek())) advance();
      while (/[0-9_]/.test(peek())) advance();
    }
    return source.slice(start, i);
  }

  while (i < n) {
    const c = peek();
    if (c === " " || c === "\t" || c === "\r" || c === "\n" || c === "\v" || c === "\f") {
      advance();
      continue;
    }

    if (c === "-" && peek(1) === "-") {
      const long = startsLong(i, "--[");
      if (long) {
        const extra = 3 + long.eq + 1;
        readLong(long.eq, extra);
        continue;
      }
      while (i < n && peek() !== "\n") advance();
      continue;
    }

    if (c === "#" && line === 1 && col === 1) {
      while (i < n && peek() !== "\n") advance();
      continue;
    }

    const longStr = startsLong(i, "[");
    if (longStr) {
      const extra = 1 + longStr.eq + 1;
      const value = readLong(longStr.eq, extra);
      tokens.push({ kind: "string", value, ...at() });
      continue;
    }

    if (c === '"' || c === "'") {
      const pos = at();
      const value = readShortString(c);
      tokens.push({ kind: "string", value, ...pos });
      continue;
    }

    if (c === "`") {
      const pos = at();
      const value = readInterp();
      tokens.push({ kind: "interp", value, ...pos });
      continue;
    }

    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(peek(1)))) {
      const pos = at();
      const value = readNumber();
      tokens.push({ kind: "number", value, ...pos });
      continue;
    }

    if (/[A-Za-z_]/.test(c) || c.charCodeAt(0) > 127) {
      const pos = at();
      let value = "";
      while (i < n && (/[A-Za-z0-9_]/.test(peek()) || peek().charCodeAt(0) > 127)) {
        value += peek();
        advance();
      }
      tokens.push({
        kind: KEYWORDS.has(value) ? "keyword" : "name",
        value,
        ...pos,
      });
      continue;
    }

    let matched = "";
    for (const op of OPS) {
      if (source.startsWith(op, i)) {
        matched = op;
        break;
      }
    }
    if (matched) {
      const pos = at();
      advance(matched.length);
      tokens.push({ kind: "op", value: matched, ...pos });
      continue;
    }

    throw new ParseError(`unexpected character ${JSON.stringify(c)}`, line, col);
  }

  tokens.push({ kind: "eof", value: "", line, column: col });
  return tokens;
}

export function isKeyword(tok: Token, word: string) {
  return tok.kind === "keyword" && tok.value === word;
}
