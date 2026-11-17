import { guard } from "../_lib/cors.js";
import { requireApiKey } from "../_lib/auth.js";
import { lunaMoonObfuscate } from "../../lib/engines/lunaMoonRunner.js";

const MAX_SOURCE_BYTES = 200_000; // keep conservative — this goes through a real browser session

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
    const result = await lunaMoonObfuscate(source);
    res.status(200).json({ success: true, experimental: true, engine: "luna-moon (headless-browser automation)", ...result });
  } catch (err) {
    res.status(500).json({
      success: false,
      experimental: true,
      error: "luna-moon automation failed. This drives the real web app with a headless browser and has not been verified end-to-end (no network/browser in the build sandbox) — see lib/engines/lunaMoonRunner.js and README.md.",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
}
