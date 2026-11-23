// Runs Catph via wasmoon.
//
// Presets: customvm, ironbrew2, catph, luaubc (src: presets.lua). Only
// "luaubc" uses the "LuauBytecode" pipeline step, which shells out to a
// real official `luau-compile` binary via os.execute (catph/steps/
// LuauBytecode.lua) to produce genuine Roblox Luau bytecode -- something no
// pure-Lua VM (wasmoon included) can do, and we don't bundle that compiler.
// wasmoon runs inside a WASM sandbox, so os.execute very likely can't
// spawn a real host process there anyway (no network/Lua available while
// writing this to confirm either way) -- either way, calling the "luaubc"
// preset here is expected to fail with Catph's own built-in error
// ("LuauBytecode: luau-compile produced no output"), surfaced as a normal
// error response, not a crash or a security hole. The other 3 presets
// (customvm, ironbrew2, catph) don't use that step and should work like
// any other wasmoon-based engine here.
//
// catph.lua (the module's own entrypoint, required as "catph") has the
// same debug.getinfo/script_path pattern fixed in 25msRunner.js -- same
// fix applied here (preload it under a fake chunkname containing "/").
//
// UNTESTED end-to-end, same reason as every other wasmoon engine here (no
// Lua/network in the build sandbox).

import { LuaFactory } from "wasmoon";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { buildPreloadChunk } from "../lua-bundle.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(__dirname, "..", "lua-sources", "catph");

export async function catphObfuscate(source, { preset = "customvm" } = {}) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error("source must be a non-empty string");
  }

  const factory = new LuaFactory();
  const lua = await factory.createEngine();

  try {
    await lua.doString(`arg = {}`);

    const preload = buildPreloadChunk(SRC_DIR, { excludeFiles: ["catph.lua"] });
    await lua.doString(preload);

    const entrySource = readFileSync(join(SRC_DIR, "catph.lua"), "utf8");
    let level = 0;
    while (entrySource.includes(`]${"=".repeat(level)}]`)) level++;
    const eq = "=".repeat(level);
    await lua.doString(
      `package.preload["catph"] = assert(load([${eq}[\n${entrySource}\n]${eq}], "@/virtual/catph.lua"))`
    );

    lua.global.set("__SOURCE__", source);
    lua.global.set("__PRESET__", preset);

    const glue = `
      local Obf = require("catph")
      local config = Obf.Presets[__PRESET__]
      if not config then
        error("Unknown preset: " .. tostring(__PRESET__))
      end
      local pipeline = Obf.Pipeline:fromConfig(config)
      local out = pipeline:apply(__SOURCE__, "api-request.lua")
      return out
    `;

    const output = await lua.doString(glue);
    if (typeof output !== "string") {
      throw new Error("Catph pipeline did not return a string output.");
    }
    return { output, preset };
  } finally {
    lua.global.close();
  }
}
