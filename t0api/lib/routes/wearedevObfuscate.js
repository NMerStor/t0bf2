import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";

const UPSTREAM_URL = "https://wearedevs.net/api/obfuscate";

export default async function handler(req, res) {
  if (!guard(req, res, { method: "POST" })) return;
  if (!requireApiKey(req, res)) return;

  const body = req.body ?? {};
  const script = body.script ?? body.source;
  if (typeof script !== "string" || script.trim().length === 0) {
    return res.status(400).json({ success: false, error: 'Missing or invalid "script". Expected { "script": "..." }.' });
  }

  try {
    const upstreamResponse = await fetch(UPSTREAM_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ script }),
      signal: AbortSignal.timeout(60000),
    });

    const responseText = await upstreamResponse.text();
    let data;
    try {
      data = JSON.parse(responseText);
    } catch {
      return res.status(502).json({ success: false, error: "WeAreDevs returned a non-JSON response.", upstreamStatus: upstreamResponse.status });
    }

    return res.status(upstreamResponse.status).json(data);
  } catch (error) {
    const timedOut = error && (error.name === "TimeoutError" || error.name === "AbortError");
    return res.status(502).json({
      success: false,
      error: timedOut ? "Timed out while contacting WeAreDevs." : "Could not reach WeAreDevs.",
      detail: error && error.message ? error.message : "Unknown error",
    });
  }
}
