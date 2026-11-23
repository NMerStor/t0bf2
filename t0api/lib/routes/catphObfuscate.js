import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { catphObfuscate } from "../engines/catphRunner.js";

const MAX_SOURCE_BYTES = 400_000;
const PRESETS = ["customvm", "ironbrew2", "catph", "luaubc"];

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
  const preset = body.preset || "customvm";
  if (!PRESETS.includes(preset)) {
    return res.status(400).json({ success: false, error: `'preset' must be one of: ${PRESETS.join(", ")}` });
  }
  if (preset === "luaubc") {
    return res.status(400).json({
      success: false,
      error: "'luaubc' preset needs a real external luau-compile binary (not bundled here) -- it will fail. Use 'customvm', 'ironbrew2' or 'catph' instead.",
    });
  }

  try {
    const result = await catphObfuscate(source, { preset });
    res.status(200).json({ success: true, engine: "catph", ...result });
  } catch (err) {
    res.status(500).json({
      success: false,
      error: "Obfuscation failed (Catph/wasmoon).",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
}
