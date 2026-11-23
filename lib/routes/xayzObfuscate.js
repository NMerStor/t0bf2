import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";

// Docs provided by the user as "rayx obfuscator/zayx api docs.md" — the
// service itself calls its own product "Xayz" in the doc body and its base
// URL is https://luaob.vercel.app. No API key needed upstream, just a
// sane User-Agent: their own docs say their WAF auto-blocks requests whose
// User-Agent contains "bot", "curl" or "postman", and recommend sending a
// normal-looking one instead — that's exactly what we do below, we are not
// adding anything beyond what their own integration docs ask for.
// Rate limit (per their docs): ~100 requests/IP/hour.

const UPSTREAM_URL = "https://luaob.vercel.app/api/obfuscate";
const TARGET_MODES = ["roblox", "standard"];
const MAX_SOURCE_BYTES = 1_000_000;

export default async function handler(req, res) {
  if (!guard(req, res, { method: "POST" })) return;
  if (!requireApiKey(req, res)) return;

  const body = req.body ?? {};
  const code = body.code;
  if (typeof code !== "string" || code.length === 0) {
    return res.status(400).json({ success: false, error: "Body must include a non-empty string field 'code'." });
  }
  if (Buffer.byteLength(code, "utf8") > MAX_SOURCE_BYTES) {
    return res.status(413).json({ success: false, error: `Source too large. Limit is ${MAX_SOURCE_BYTES} bytes.` });
  }
  const targetMode = body.targetMode || "roblox";
  if (!TARGET_MODES.includes(targetMode)) {
    return res.status(400).json({ success: false, error: `'targetMode' must be one of: ${TARGET_MODES.join(", ")}` });
  }

  try {
    const upstreamResponse = await fetch(UPSTREAM_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "User-Agent": "Mozilla/5.0 (t0api gateway)",
      },
      body: JSON.stringify({ code, targetMode }),
      signal: AbortSignal.timeout(30000),
    });

    const responseText = await upstreamResponse.text();
    let data;
    try {
      data = JSON.parse(responseText);
    } catch {
      return res.status(502).json({ success: false, error: "Xayz returned a non-JSON response.", upstreamStatus: upstreamResponse.status, raw: responseText.slice(0, 500) });
    }

    return res.status(upstreamResponse.status).json(data);
  } catch (error) {
    const timedOut = error && (error.name === "TimeoutError" || error.name === "AbortError");
    return res.status(502).json({
      success: false,
      error: timedOut ? "Timed out while contacting Xayz." : "Could not reach Xayz.",
      detail: error && error.message ? error.message : "Unknown error",
    });
  }
}
