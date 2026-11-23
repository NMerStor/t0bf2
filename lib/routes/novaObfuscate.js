import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { obfuscateLua } from "../../lib-dist/engines/nova/obfuscator.js";

const LEVELS = ["weak", "medium", "harder", "strong", "premium"];
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
  const level = body.level || "medium";
  if (!LEVELS.includes(level)) {
    return res.status(400).json({ success: false, error: `'level' must be one of: ${LEVELS.join(", ")}` });
  }

  // The original app hard-codes a leaked PREMIUM_KEY to gate the "premium"
  // level -- we do not ship that secret. If you want "premium" gated
  // separately from the rest of this gateway's own API_KEY, set
  // NOVA_PREMIUM_KEY in Vercel env vars; unset (default) means "premium"
  // behaves like any other level, protected only by this gateway's API_KEY.
  if (level === "premium" && process.env.NOVA_PREMIUM_KEY) {
    const provided = body.novaKey || req.headers["x-nova-key"];
    if (provided !== process.env.NOVA_PREMIUM_KEY) {
      return res.status(403).json({ success: false, error: "Premium level requires a valid 'novaKey' (NOVA_PREMIUM_KEY is set on this server)." });
    }
  }

  try {
    const output = obfuscateLua(source, level);
    res.status(200).json({ success: true, engine: "nova", output, level });
  } catch (err) {
    res.status(500).json({ success: false, error: "Obfuscation failed (Nova).", detail: err instanceof Error ? err.message : String(err) });
  }
}
