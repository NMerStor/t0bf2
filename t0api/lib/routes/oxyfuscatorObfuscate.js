import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { obfuscate } from "../engines/oxyfuscator/index.js";

const PRESETS = ["minimum", "balanced", "maximum", "swear"];
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
  const preset = body.preset || "balanced";
  if (!PRESETS.includes(preset)) {
    return res.status(400).json({ success: false, error: `'preset' must be one of: ${PRESETS.join(", ")}` });
  }

  try {
    // cli.ts always passes a real numeric seed (defaulting to
    // Date.now() >>> 0 when the user doesn't give one) -- obfuscate()
    // itself isn't written to tolerate seed being undefined, so the
    // adapter fills in the same default the original CLI uses rather than
    // passing undefined through.
    const seed = typeof body.seed === "number" ? body.seed : (Date.now() >>> 0);
    const output = obfuscate(source, { preset, seed });
    res.status(200).json({ success: true, engine: "oxyfuscator", output, preset });
  } catch (err) {
    res.status(500).json({ success: false, error: "Obfuscation failed (Oxyfuscator).", detail: err instanceof Error ? err.message : String(err) });
  }
}
