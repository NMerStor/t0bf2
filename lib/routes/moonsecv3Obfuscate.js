import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { createRequire } from "module";
const require = createRequire(import.meta.url);
// CommonJS vendor module -- lib/engines/moonsecv3/package.json pins
// "type": "commonjs" so this resolves correctly even though the project
// root is "type": "module".
const { obfuscate } = require("../engines/moonsecv3/obfuscate.js");

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
    const result = obfuscate(source, {
      seed: typeof body.seed === "number" ? body.seed : undefined,
      watermark: typeof body.watermark === "boolean" ? body.watermark : undefined,
    });
    // result.proto is the internal (circular) bytecode object tree -- never
    // serialize it. Only output + the non-circular ctx metadata go out.
    res.status(200).json({
      success: true,
      engine: "moonsecv3 (reconstruction, not original)",
      output: result.output,
      meta: result.ctx ? { seed: result.ctx.seed, profile: result.ctx.profile, bytecodeBytes: result.ctx.bytecodeBytes } : undefined,
    });
  } catch (err) {
    res.status(500).json({ success: false, error: "Obfuscation failed (MoonSec V3).", detail: err instanceof Error ? err.message : String(err) });
  }
}
