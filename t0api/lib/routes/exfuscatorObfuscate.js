import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { execFile } from "child_process";
import { promisify } from "util";
import { writeFile, readFile, unlink, chmod } from "fs/promises";
import { randomUUID } from "crypto";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { tmpdir } from "os";

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const BIN_PATH = join(__dirname, "..", "engines", "exfuscator", "bin", "exfuscator");

const PRESETS = ["light", "medium", "maximum"];
const MAX_SOURCE_BYTES = 400_000;
const EXEC_TIMEOUT_MS = 20_000;

// ExFuscator is a real compiled C++ binary (statically linked, Linux x86_64 --
// see lib/engines/exfuscator/bin/exfuscator), not a Node/WASM engine like
// the others. The original archive's source didn't compile as-is: every
// file does `#include "astra/..."` but the folder on disk was named
// "ExFuscator" (capital), and CMakeLists.txt itself referenced lowercase
// "exfuscator" paths that didn't match the actual "ExFuscator" folder
// either -- a real case-sensitivity mismatch, exactly as flagged before
// this was attempted. Fixed by keeping a copy of the source under an
// "astra" folder name matching its own internal namespace (see
// lib/engines/exfuscator/src-fixed/) and compiling directly with g++
// (CMake wasn't even available, so this bypasses CMakeLists.txt entirely).
// Compiled with `g++ -std=c++17 -O2 -static`, verified to actually run and
// produce real obfuscated output before being bundled here.
//
// Vercel's Node functions do allow spawning a bundled native binary via
// child_process, and /tmp is writable at runtime -- this route writes the
// input to a temp file (the binary is file-based, not stdin/stdout-based),
// runs the binary, reads the output file back, and cleans up both files.

export default async function handler(req, res) {
  if (!guard(req, res, { method: "POST" })) return;
  if (!requireApiKey(req, res)) return;

  const body = req.body ?? {};
  const source = body.source;
  if (typeof source !== "string" || source.length === 0) {
    return res.status(400).json({ success: false, error: "Body must include a non-empty string field 'source'." });
  }
  if (Buffer.byteLength(source, "utf8") > MAX_SOURCE_BYTES) {
    return res.status(413).json({ success: false, error: `Source too large. Limit is ${MAX_SOURCE_BYTES} bytes.` });
  }
  const preset = body.preset || "medium";
  if (!PRESETS.includes(preset)) {
    return res.status(400).json({ success: false, error: `'preset' must be one of: ${PRESETS.join(", ")}` });
  }
  const seed = typeof body.seed === "number" ? Math.floor(body.seed) : Math.floor(Date.now() / 1000);

  const id = randomUUID();
  const inputPath = join(tmpdir(), `exf-in-${id}.lua`);
  const outputPath = join(tmpdir(), `exf-out-${id}.lua`);

  const flagMap = {
    noStrings: "--no-strings",
    noNumbers: "--no-numbers",
    noRename: "--no-rename",
    noDeadcode: "--no-deadcode",
    noFlatten: "--no-flatten",
    noProxies: "--no-proxies",
    noOpaque: "--no-opaque",
    noDfm: "--no-dfm",
    renameGlobals: "--rename-globals",
    globalsReal: "--globals-real",
  };
  const extraFlags = [];
  for (const [key, flag] of Object.entries(flagMap)) {
    if (body[key] === true) extraFlags.push(flag);
  }

  try {
    await writeFile(inputPath, source, "utf8");
    try {
      await chmod(BIN_PATH, 0o755);
    } catch {
      // ignore -- already executable in most cases, this is just a safety net
    }

    await execFileAsync(
      BIN_PATH,
      [inputPath, "-o", outputPath, "--preset", preset, "--seed", String(seed), "-q", ...extraFlags],
      { timeout: EXEC_TIMEOUT_MS }
    );

    const output = await readFile(outputPath, "utf8");
    res.status(200).json({ success: true, engine: "exfuscator", output, preset, seed });
  } catch (err) {
    const timedOut = err && err.killed;
    res.status(500).json({
      success: false,
      error: timedOut ? "ExFuscator timed out." : "Obfuscation failed (ExFuscator).",
      detail: err instanceof Error ? (err.stderr || err.message) : String(err),
    });
  } finally {
    unlink(inputPath).catch(() => {});
    unlink(outputPath).catch(() => {});
  }
}
