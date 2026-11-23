// Runs Claudium via wasmoon.
//
// The archive's own demo server (server.py, Railway/Docker) spun up a
// Python process just to shell out to a real `lua5.4` binary running
// cli.lua -- but the actual obfuscation logic is 100% pure Lua
// (src/**/*.lua), no Python needed at all. So this is wired exactly like
// every other Lua engine here (wasmoon), not as a Python function; the
// Python wrapper was only ever a thin demo-server detail, never a real
// runtime dependency.
//
// Presets (src/Presets/Presets.lua, via Claudium.Presets.get(name)):
// minimum, maximum, lua51 (default), lua53, luajit, roblox, luau, executor
// -- unknown names fall back to a generic target rather than erroring.
//
// UNTESTED end-to-end, same reason as every other wasmoon engine here (no
// Lua/network in the build sandbox).

import { LuaFactory } from "wasmoon";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { buildPreloadChunk } from "../lua-bundle.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(__dirname, "..", "lua-sources", "claudium");

export async function claudiumObfuscate(source, { preset = "lua51" } = {}) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error("source must be a non-empty string");
  }

  const factory = new LuaFactory();
  const lua = await factory.createEngine();

  try {
    await lua.doString(`arg = {}`);

    const preload = buildPreloadChunk(SRC_DIR);
    await lua.doString(preload);

    lua.global.set("__SOURCE__", source);
    lua.global.set("__PRESET__", preset);

    const glue = `
      local Claudium = require("src.init")
      local options = Claudium.Presets.get(__PRESET__)
      local out, errors = Claudium.obfuscate(__SOURCE__, options)
      if not out then
        local msg = "Claudium obfuscation failed"
        if errors then
          local parts = {}
          for _, e in ipairs(errors) do
            parts[#parts + 1] = (type(e) == "table" and e.message) or tostring(e)
          end
          msg = msg .. ": " .. table.concat(parts, "; ")
        end
        error(msg)
      end
      return out
    `;

    const output = await lua.doString(glue);
    if (typeof output !== "string") {
      throw new Error("Claudium did not return a string output.");
    }
    return { output, preset };
  } finally {
    lua.global.close();
  }
}
