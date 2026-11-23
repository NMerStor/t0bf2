// Generic multi-file Lua bundler for wasmoon.
//
// wasmoon runs a real Lua VM compiled to WASM, but it has no filesystem, so
// plain `require("foo.bar")` (which normally reads foo/bar.lua off disk)
// does nothing by default. The standard fix is to pre-register every module
// as a `package.preload["modname"] = function(...) <source> end` entry
// before running the entry script — that's exactly what real Lua's
// `require` checks first, so the obfuscator's own code doesn't need to be
// touched at all.
//
// Module name convention (standard Lua): a file at "a/b/c.lua" is reachable
// as require("a.b.c").

import { readFileSync, readdirSync, statSync } from "fs";
import { join, relative, sep } from "path";

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      walk(full, out);
    } else if (entry.endsWith(".lua")) {
      out.push(full);
    }
  }
  return out;
}

/**
 * Builds a Lua snippet that preloads every .lua file under `dir` (except
 * `excludeFiles`, matched by file name) into `package.preload`.
 */
export function buildPreloadChunk(dir, { excludeFiles = [], moduleSeparator = "." } = {}) {
  const files = walk(dir);
  const chunks = [];

  for (const file of files) {
    const base = file.split(sep).pop();
    if (excludeFiles.includes(base)) continue;

    const rel = relative(dir, file).split(sep).join("/").replace(/\.lua$/, "");
    const modname = moduleSeparator === "/" ? rel : rel.split("/").join(moduleSeparator);
    const source = readFileSync(file, "utf8");

    // Use a long-bracket string so we never have to escape quotes/newlines.
    // Pick a level that can't collide with the module's own source.
    let level = 0;
    while (source.includes(`]${"=".repeat(level)}]`)) level++;
    const eq = "=".repeat(level);

    chunks.push(
      `package.preload["${modname}"] = assert(load([${eq}[\n${source}\n]${eq}], "@${modname}"))`
    );
  }

  return chunks.join("\n");
}

export function readEntry(dir, entryFileName) {
  return readFileSync(join(dir, entryFileName), "utf8");
}
