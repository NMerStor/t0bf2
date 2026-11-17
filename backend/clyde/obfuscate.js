import { guard } from "../_lib/cors.js";
import { requireApiKey } from "../_lib/auth.js";
import { clydeObfuscate } from "../../lib-dist/engines/clyde/apiWrapper.js";

const MAX_SOURCE_BYTES = 1_000_000;

export default async function handler(req, res) {
  if (!guard(req, res, { method: "POST" })) return;
  if (!requireApiKey(req, res)) return;

  const body = req.body ?? {};
  const code = body.code ?? body.source;

  if (typeof code !== "string" || code.length === 0) {
    return res.status(400).json({ success: false, error: "Body must include a non-empty string field 'code'." });
  }
  if (Buffer.byteLength(code, "utf8") > MAX_SOURCE_BYTES) {
    return res.status(413).json({ success: false, error: `Source too large. Limit is ${MAX_SOURCE_BYTES} bytes.` });
  }

  try {
    const result = clydeObfuscate(code, body.options || {});
    res.status(200).json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ success: false, error: "Obfuscation failed.", detail: err instanceof Error ? err.message : String(err) });
  }
}
