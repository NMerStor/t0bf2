import { guard } from "../_lib/cors.js";
import { requireApiKey } from "../_lib/auth.js";
import { lumoraObfuscate } from "../../lib/engines/lumora.js";

const MAX_SOURCE_BYTES = 200_000; // output balloons to ~220k numbers regardless of input size

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
    const result = lumoraObfuscate(source);
    res.status(200).json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ success: false, error: "Obfuscation failed.", detail: err instanceof Error ? err.message : String(err) });
  }
}
