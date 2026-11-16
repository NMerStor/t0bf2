export type CompoundOp = "+=" | "-=" | "*=" | "/=" | "%=" | "^=" | "..=" | "//=";

export type BinOp =
  | "+"
  | "-"
  | "*"
  | "/"
  | "//"
  | "%"
  | "^"
  | ".."
  | "<"
  | "<="
  | ">"
  | ">="
  | "=="
  | "~="
  | "and"
  | "or";

export type UnOp = "-" | "not" | "#";

export type FuncBody = {
  params: string[];
  vararg: boolean;
  body: Stat[];
};

export type FuncName = {
  parts: string[];
  method?: string;
};

export type Field =
  | { kind: "list"; value: Exp }
  | { kind: "rec"; name: string; value: Exp }
  | { kind: "index"; key: Exp; value: Exp };

export type Stat =
  | { type: "Assignment"; vars: Exp[]; exps: Exp[]; compound?: CompoundOp }
  | { type: "CallStat"; call: CallExp }
  | { type: "Do"; body: Stat[] }
  | { type: "While"; cond: Exp; body: Stat[] }
  | { type: "Repeat"; body: Stat[]; cond: Exp }
  | {
      type: "If";
      clauses: { test: Exp; body: Stat[] }[];
      otherwise?: Stat[];
    }
  | {
      type: "ForNum";
      name: string;
      start: Exp;
      last: Exp;
      step?: Exp;
      body: Stat[];
    }
  | { type: "ForIn"; names: string[]; exps: Exp[]; body: Stat[] }
  | { type: "FunctionStat"; name: FuncName; body: FuncBody }
  | { type: "LocalFunction"; name: string; body: FuncBody }
  | { type: "Local"; names: string[]; exps?: Exp[] }
  | { type: "Return"; exps?: Exp[] }
  | { type: "Break" }
  | { type: "Continue" };

export type CallExp = {
  type: "Call";
  callee: Exp;
  args: Exp[];
  method?: string;
};

export type Exp =
  | { type: "Nil" }
  | { type: "Boolean"; value: boolean }
  | { type: "Number"; value: number; raw: string }
  | { type: "String"; value: string }
  | { type: "Vararg" }
  | { type: "Name"; name: string }
  | { type: "Binary"; op: BinOp; left: Exp; right: Exp }
  | { type: "Unary"; op: UnOp; arg: Exp }
  | { type: "Table"; fields: Field[] }
  | { type: "Function"; body: FuncBody }
  | { type: "Index"; object: Exp; key: Exp }
  | { type: "Member"; object: Exp; name: string }
  | CallExp
  | { type: "Paren"; exp: Exp }
  | {
      type: "IfExp";
      clauses: { test: Exp; value: Exp }[];
      otherwise: Exp;
    };

export type Chunk = { type: "Chunk"; body: Stat[] };

export class ParseError extends Error {
  line: number;
  column: number;
  constructor(message: string, line: number, column: number) {
    super(`${message} (${line}:${column})`);
    this.name = "ParseError";
    this.line = line;
    this.column = column;
  }
}
