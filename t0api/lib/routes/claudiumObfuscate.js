import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { claudiumObfuscate } from "../engines/claudiumRunner.js";

const MAX_SOURCE_BYTES = 400_000;
const PRESETS = ["minimum", "maximum", "lua51", "lua53", "luajit", "roblox", "luau", "executor"];

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
  const preset = body.preset || "lua51";
  if (!PRESETS.includes(preset)) {
    return res.status(400).json({ success: false, error: `'preset' must be one of: ${PRESETS.join(", ")}` });
  }

  try {
    const result = await claudiumObfuscate(source, { preset });
    res.status(200).json({ success: true, engine: "claudium", ...result });
  } catch (err) {
    res.status(500).json({
      success: false,
      error: "Obfuscation failed (Claudium/wasmoon).",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
}
