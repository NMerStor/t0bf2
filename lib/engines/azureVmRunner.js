// Runs AzureVM (a Prometheus fork, "Lua 5.1 VM-based obfuscator") via
// wasmoon, same bundling technique as 25msRunner.js/herculesRunner.js.
//
// *** HIGH-RISK ENGINE -- same class of risk as moonsecv2Runner.js ***
// AzureVM's own source does `local raw_bytecode = string.dump(chunk_fn)`
// (src/prometheus/azure_vm/init.lua) and hand-parses that bytecode
// (reader.lua) to build its VM encoding. The project literally describes
// itself as "Lua 5.1 VM-based" -- wasmoon embeds real Lua 5.4, and Lua
// bytecode layout is version-specific, so this has the same
// version-mismatch risk as moonsecv2. Untested end-to-end (no Lua/network
// in the build sandbox). If it errors or produces corrupt output, the real
// fix is hosting this on an actual Lua 5.1 interpreter and proxying to it
// (like /api/wearedev), not patching wasmoon.
//
// Preset names (src/presets.lua): Minify, Weak, Vmify, Medium, Strong,
// Luraph (default), Luraph14, Luraph15, AzureGod, AzureGod15,
// AzureGodUltra, Fast, Balanced, Hardened, Research.

import { LuaFactory } from "wasmoon";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { buildPreloadChunk } from "../lua-bundle.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(__dirname, "..", "lua-sources", "azurevm");

export async function azureVmObfuscate(source, { preset = "Luraph", seed } = {}) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error("source must be a non-empty string");
  }

  const factory = new LuaFactory();
  const lua = await factory.createEngine();

  try {
    await lua.doString(`arg = {}`);

    // cli.lua and the top-level prometheus.lua entrypoint are excluded from
    // the source copy (and so never preloaded) -- azure_obf.lua's own
    // require graph never touches either, and prometheus.lua in particular
    // carries the same debug.getinfo/script_path landmine fixed in
    // 25msRunner.js, so skipping it here avoids needing that fix twice.
    const preload = buildPreloadChunk(SRC_DIR);
    await lua.doString(preload);

    lua.global.set("__SOURCE__", source);
    lua.global.set("__PRESET__", preset);
    lua.global.set("__SEED__", typeof seed === "number" ? seed : Math.floor(Math.random() * 2147483647) + 1);

    const glue = `
      -- Lua 5.4 (what wasmoon embeds) dropped the Lua-5.1-era global
      -- "loadstring" in favor of "load" -- azure_obf.lua's own logic calls
      -- loadstring() to sanity-check the input is plain source (not
      -- already bytecode); alias it so that check behaves the same way
      -- here as it would under the Lua 5.1 this was written for.
      loadstring = loadstring or load

      local presets = require("presets")
      local Transpiler = require("prometheus.azure_vm.transpiler")
      local Pipeline = require("prometheus.pipeline")

      local pipeline_config = presets[__PRESET__]
      if not pipeline_config then
        error("Unknown preset: " .. tostring(__PRESET__))
      end

      local compile_source = __SOURCE__
      if not loadstring(compile_source) then
        compile_source = Transpiler.transpile(compile_source)
      end

      local pipeline = Pipeline:fromConfig(pipeline_config)
      pipeline.Seed = __SEED__
      pipeline.seed = __SEED__
      local out = pipeline:apply(compile_source)
      return out
    `;

    const output = await lua.doString(glue);
    if (typeof output !== "string") {
      throw new Error("AzureVM pipeline did not return a string output.");
    }
    return { output, preset };
  } finally {
    lua.global.close();
  }
}
