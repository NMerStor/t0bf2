import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { moonsecv2Obfuscate } from "../../lib/engines/moonsecv2Runner.js";

const MAX_SOURCE_BYTES = 300_000;

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
    const result = await moonsecv2Obfuscate(source);
    res.status(200).json({ success: true, experimental: true, ...result });
  } catch (err) {
    res.status(500).json({
      success: false,
      experimental: true,
      error: "Obfuscation failed (moonsecv2/wasmoon). This engine uses Lua bytecode internally and may be incompatible with wasmoon's Lua 5.4 — see README.md.",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
}
