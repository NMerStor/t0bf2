import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { obfuscate, PRESETS } from "../../lib-dist/engines/veil/index.js";

const PRESET_IDS = Object.keys(PRESETS);
const MAX_SOURCE_BYTES = 1_000_000;

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
  if (body.preset !== undefined && !PRESET_IDS.includes(body.preset)) {
    return res.status(400).json({ success: false, error: `'preset' must be one of: ${PRESET_IDS.join(", ")}` });
  }

  try {
    const result = obfuscate(source, {
      preset: body.preset,
      seed: typeof body.seed === "number" ? body.seed : undefined,
      rename: typeof body.rename === "boolean" ? body.rename : undefined,
      encryptStrings: typeof body.encryptStrings === "boolean" ? body.encryptStrings : undefined,
      encryptMembers: typeof body.encryptMembers === "boolean" ? body.encryptMembers : undefined,
      numbers: typeof body.numbers === "boolean" ? body.numbers : undefined,
      controlFlow: typeof body.controlFlow === "boolean" ? body.controlFlow : undefined,
      minify: typeof body.minify === "boolean" ? body.minify : undefined,
      vmWrap: typeof body.vmWrap === "boolean" ? body.vmWrap : undefined,
    });
    res.status(200).json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ success: false, error: "Obfuscation failed.", detail: err instanceof Error ? err.message : String(err) });
  }
}
