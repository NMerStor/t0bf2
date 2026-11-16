// Runs "25ms-obf [old]" via wasmoon.
//
// Naming note: this engine is a FORK of Prometheus (the open-source Lua
// obfuscator by levno-710) made by whoever maintains "25ms-obf" — it is NOT
// the upstream Prometheus project itself, so it is exposed here under its
// own name (25ms-obf) rather than being called "Prometheus". It is also the
// oldest/least maintained engine in this API, hence the [old] tag used in
// responses and docs.
//
// IMPORTANT / UNTESTED: this sandbox had no network access and no Lua
// interpreter available while this was written, so this file could not be
// executed end-to-end before shipping. The bundling approach
// (package.preload per module) is the standard way multi-file Lua projects
// are embedded in wasmoon/fengari, and the Pipeline:fromConfig/apply calls
// mirror the fork's own cli.lua usage exactly -- but please smoke-test this
// route first after `npm install` + deploy, before relying on it.
//
// Available presets (from presets.lua): ol, Normal, Vmify, Minify, me, Weak,
// doubled, Medium, Strong.

import { LuaFactory } from "wasmoon";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { buildPreloadChunk } from "../lua-bundle.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC_DIR = join(__dirname, "..", "lua-sources", "25ms-obf");

export async function obf25msObfuscate(source, { preset = "Minify" } = {}) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error("source must be a non-empty string");
  }

  const factory = new LuaFactory();
  const lua = await factory.createEngine();

  try {
    // `arg` is a global the real `lua` CLI sets up; config.lua reads it even
    // when required as a library, so give it an empty table to avoid a
    // nil-index error.
    await lua.doString(`arg = {}`);

    // Preload every submodule (prometheus/*.lua, logger.lua, colors.lua,
    // config.lua, presets.lua, highlightlua.lua) except the entrypoint,
    // which we preload separately below under the name "prometheus" (the
    // module's own internal require name — unrelated to this engine's
    // public API name "25ms-obf").
    const preload = buildPreloadChunk(SRC_DIR, { excludeFiles: ["prometheus.lua"] });
    await lua.doString(preload);

    // prometheus.lua computes its own directory at load time via
    // debug.getinfo(2, "S").source and a "(.*[/%\\])" pattern match, then
    // prepends that directory to package.path (purely for its own
    // require() calls — which we've already pre-satisfied above via
    // package.preload, so this computed path is never actually read from
    // disk). The chunkname we give load() becomes that `source` value: a
    // plain "@prometheus" has no "/" in it, so the pattern match returns
    // nil and `nil .. "?.lua;" .. package.path` throws "attempt to
    // concatenate a nil value" before the module's real API is even
    // reached. Giving it a fake chunkname that *contains* a slash fixes
    // this without touching the vendor source at all.
    const entrySource = readFileSync(join(SRC_DIR, "prometheus.lua"), "utf8");
    let level = 0;
    while (entrySource.includes(`]${"=".repeat(level)}]`)) level++;
    const eq = "=".repeat(level);
    await lua.doString(
      `package.preload["prometheus"] = assert(load([${eq}[\n${entrySource}\n]${eq}], "@/virtual/prometheus.lua"))`
    );

    lua.global.set("__SOURCE__", source);
    lua.global.set("__PRESET__", preset);

    const glue = `
      local Fork = require("prometheus")
      local config = Fork.Presets[__PRESET__]
      if not config then
        error("Unknown preset: " .. tostring(__PRESET__))
      end
      local pipeline = Fork.Pipeline:fromConfig(config)
      local out = pipeline:apply(__SOURCE__, "api-request.lua")
      return out
    `;

    const output = await lua.doString(glue);
    if (typeof output !== "string") {
      throw new Error("25ms-obf pipeline did not return a string output.");
    }
    return { output, preset };
  } finally {
    lua.global.close();
  }
}
