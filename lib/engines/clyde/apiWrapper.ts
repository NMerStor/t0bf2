// Thin wrapper around Clyde's pipeline, extracted from the original src/server.ts
// so it can be called directly from a Vercel serverless function instead of
// through an always-on Express server.

import { lex } from "./lexer/Lexer.js";
import { parse } from "./parser/Parser.js";
import { obfuscate } from "./obfuscator/Obfuscator.js";
import { encodeStrings } from "./obfuscator/StringEncoder.js";
import { scrambleControlFlow } from "./obfuscator/ControlFlowScrambler.js";
import { printChunk, printChunkOneLine } from "./obfuscator/Printer.js";
import { compile } from "./vm/Compiler.js";
import { regCompile } from "./vm/RegCompiler.js";
import { generateVM } from "./vm/vm-gen.js";
import { generateRegVM } from "./vm/reg-vm-gen.js";
import { validate as validateSource } from "./compiler/LuauCompiler.js";

export type ClydeOptions = {
  noRename?: boolean;
  noPreserve?: boolean;
  encodeStrings?: boolean;
  scramble?: boolean;
  oneLine?: boolean;
  vmType?: "none" | "stack" | "register";
  vmLevel?: "debug" | "normal" | "max";
};

export function clydeObfuscate(code: string, options: ClydeOptions = {}) {
  const noRename = options.noRename === true;
  const noPreserve = options.noPreserve === true;
  const encodeStringsOpt = options.encodeStrings === true;
  const scrambleOpt = options.scramble === true;
  const oneLineOpt = options.oneLine === true;
  const vmType = options.vmType || "none";
  const vmLevel = options.vmLevel || "normal";

  const { tokens, errors: lexErrors } = lex(code);
  if (lexErrors.length > 0) {
    const err: any = new Error("Lexer error");
    err.details = lexErrors;
    throw err;
  }

  let ast = parse(tokens);

  if (encodeStringsOpt) {
    ast = encodeStrings(ast, { enabled: true });
  }
  if (scrambleOpt) {
    ast = scrambleControlFlow(ast, { enabled: true });
  }

  let output: string;

  if (vmType === "stack") {
    const obfuscated = obfuscate(ast, { renameLocals: !noRename, preserveGlobals: !noPreserve });
    const chunk = compile(obfuscated);
    output = generateVM(chunk, { level: vmLevel as any, executorGlobals: vmLevel !== "debug" });
  } else if (vmType === "register") {
    const obfuscated = obfuscate(ast, { renameLocals: !noRename, preserveGlobals: !noPreserve });
    const chunk = regCompile(obfuscated);
    const disableFeatures: string[] = [];
    if (vmLevel === "debug") disableFeatures.push("controlFlowFlattening");
    output = generateRegVM(chunk, {
      level: vmLevel as any,
      executorGlobals: vmLevel !== "debug",
      polymorphicSeed: Date.now(),
      disableFeatures: disableFeatures as any[],
    });
  } else {
    const obfuscated = obfuscate(ast, { renameLocals: !noRename, preserveGlobals: !noPreserve });
    output = oneLineOpt ? printChunkOneLine(obfuscated) : printChunk(obfuscated);
  }

  return { output };
}

export function clydeValidate(code: string) {
  return validateSource(code);
}
