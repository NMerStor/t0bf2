// Runs "moonsec v2 by larpcorrupt" via wasmoon.
//
// *** HIGH-RISK ENGINE - READ BEFORE ENABLING IN PRODUCTION ***
// Unlike Prometheus/Hercules (which transform Lua *source* as text/AST),
// this engine's obfuscate() calls `string.dump(fn)` to grab the compiled
// *bytecode* of the input script, then hand-parses that bytecode in
// parser.lua. Lua bytecode is tied to the exact Lua version (and often
// build) that produced it -- wasmoon embeds real Lua 5.4. If parser.lua's
// byte-level reader was written against Lua 5.1 bytecode layout (extremely
// common for this style of "VM obfuscator", since Roblox/most obfuscator
// targets historically assumed 5.1), it will likely throw or produce a
// corrupt payload when fed Lua 5.4's bytecode format here.
//
// This sandbox has no Lua interpreter and no network, so it could not be
// verified either way before shipping. Treat this route as experimental:
// test it with a trivial script first, and if it errors out or produces
// garbage, the real fix is hosting this engine on an actual Lua 5.1
// interpreter elsewhere and proxying to it (same pattern as /api/wearedev),
// not patching wasmoon.

import { LuaFactory } from "wasmoon";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { buildPreloadChunk } from "../lua-bundle.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(__dirname, "..", "lua-sources", "moonsecv2");

export async function moonsecv2Obfuscate(source) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error("source must be a non-empty string");
  }

  const factory = new LuaFactory();
  const lua = await factory.createEngine();

  try {
    await lua.doString(`arg = {}`);

    const preload = buildPreloadChunk(SRC_DIR, { excludeFiles: ["obfuscator.lua"] });
    await lua.doString(preload);

    const entrySource = (await import("fs")).readFileSync(join(SRC_DIR, "obfuscator.lua"), "utf8");
    let level = 0;
    while (entrySource.includes(`]${"=".repeat(level)}]`)) level++;
    const eq = "=".repeat(level);
    await lua.doString(
      `package.preload["obfuscator"] = assert(load([${eq}[\n${entrySource}\n]${eq}], "@obfuscator"))`
    );

    lua.global.set("__SOURCE__", source);

    const glue = `
      local obfl = require("obfuscator")
      local ok, res = pcall(obfl.obfuscate, __SOURCE__)
      if not ok then
        error("moonsecv2 failed (likely a Lua-bytecode-version mismatch under wasmoon): " .. tostring(res))
      end
      return res
    `;

    const output = await lua.doString(glue);
    if (typeof output !== "string") {
      throw new Error("moonsecv2 did not return a string output.");
    }
    return { output };
  } finally {
    lua.global.close();
  }
}
