// Runs the real hercules-obfuscator Lua source via wasmoon.
//
// UNTESTED end-to-end for the same reason as 25msRunner.js (no Lua /
// no network in the build sandbox). Presets mirror manifest.lua exactly:
//   light    - variable_renaming, compressor
//   balanced - + control_flow, string_encoding, opaque_predicates
//   heavy    - + string_to_expressions, garbage_code, function_inlining,
//              wrap_in_function, antitamper, dynamic_code
//   maximum  - + virtual_machine, bytecode_encoding (uses string.dump --
//              see the big warning in README.md about Lua bytecode engines
//              under wasmoon; "maximum" is the one most likely to need a
//              real Lua 5.1/5.4-matching host instead of wasmoon)

import { LuaFactory } from "wasmoon";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { buildPreloadChunk } from "../lua-bundle.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(__dirname, "..", "lua-sources", "hercules");

export async function herculesObfuscate(source, { preset = "balanced" } = {}) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error("source must be a non-empty string");
  }

  const factory = new LuaFactory();
  const lua = await factory.createEngine();

  try {
    await lua.doString(`arg = {}`);

    // hercules uses slash-separated require() strings (e.g.
    // require("modules/watermark")), not dot-separated like Prometheus.
    const preload = buildPreloadChunk(SRC_DIR, {
      excludeFiles: ["hercules.lua"],
      moduleSeparator: "/",
    });
    await lua.doString(preload);

    lua.global.set("__SOURCE__", source);
    lua.global.set("__PRESET__", preset);

    const glue = `
      local config = require("config")
      local manifest = require("manifest")
      local Pipeline = require("pipeline")

      local preset
      for _, p in ipairs(manifest.presets) do
        if p.key == __PRESET__ then preset = p break end
      end
      if not preset then
        error("Unknown preset: " .. tostring(__PRESET__))
      end

      local selected = {}
      for _, mkey in ipairs(preset.methods) do selected[mkey] = true end

      for _, method in ipairs(manifest.modules) do
        config.settings[method.config_key].enabled = (selected[method.key] == true)
      end

      local out = Pipeline.process(__SOURCE__)
      return out
    `;

    const output = await lua.doString(glue);
    if (typeof output !== "string") {
      throw new Error("Hercules pipeline did not return a string output.");
    }
    return { output, preset };
  } finally {
    lua.global.close();
  }
}
