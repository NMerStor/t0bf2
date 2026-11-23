import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { createRequire } from "module";
const require = createRequire(import.meta.url);
// CommonJS vendor module -- lib/engines/eatfuscator/package.json pins
// "type": "commonjs" so this resolves correctly even though the project
// root is "type": "module".
const { obfuscate } = require("../engines/eatfuscator/index.js");

const MAX_SOURCE_BYTES = 500_000;

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

  try {
    const output = obfuscate(source, {
      seed: typeof body.seed === "number" ? body.seed : undefined,
      minify: typeof body.minify === "string" ? body.minify : undefined,
    });
    res.status(200).json({
      success: true,
      engine: "eatfuscator",
      license: "AGPL-3.0 -- see docs/upstream/eatfuscator-LICENSE for the full text and lib/engines/eatfuscator/ for the unmodified source (network-use source-availability notice).",
      output,
    });
  } catch (err) {
    res.status(500).json({ success: false, error: "Obfuscation failed (Eatfuscator).", detail: err instanceof Error ? err.message : String(err) });
  }
}
