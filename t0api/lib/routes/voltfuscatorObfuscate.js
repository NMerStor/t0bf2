import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";

// Official docs: https://voltils.cc/docs/ (snapshot kept at
// /Voltfuscator_API_Docs.md in this repo). This is a third-party paid
// service with its OWN API key and its OWN strict quota — separate from
// this gateway's API_KEY:
//   Basic: 3 builds / 12h, 6/day · Pro: 12/12h, 24/day · Elite: 120/12h, 240/day
// Quota is shared across their Website + Discord bot + API, so calling this
// a lot will burn through your Voltfuscator plan's quota, not ours.

const UPSTREAM_URL = "https://voltils.cc/v1/obfuscate";
const PRESETS = ["normal", "ultra"]; // "max" was removed upstream
const RUNTIMES = ["luau", "lua51", "roblox", "studio", "executor"];
const MAX_SOURCE_BYTES = 600_000; // upstream's own Elite-plan cap; they'll reject smaller plans themselves

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
  const preset = body.preset || "normal";
  if (!PRESETS.includes(preset)) {
    return res.status(400).json({ success: false, error: `'preset' must be one of: ${PRESETS.join(", ")}` });
  }
  const runtime = body.runtime || "luau";
  if (!RUNTIMES.includes(runtime)) {
    return res.status(400).json({ success: false, error: `'runtime' must be one of: ${RUNTIMES.join(", ")}` });
  }

  // The caller's own Voltfuscator key can be sent per-request (so several
  // bot owners could share this gateway without sharing one Voltfuscator
  // quota); otherwise it falls back to a single shared key set as the
  // VOLTFUSCATOR_API_KEY environment variable.
  const voltKey = body.voltKey || process.env.VOLTFUSCATOR_API_KEY;
  if (!voltKey) {
    return res.status(400).json({
      success: false,
      error: "Missing Voltfuscator API key. Send it as body.voltKey, or set VOLTFUSCATOR_API_KEY in Vercel env vars.",
    });
  }

  try {
    const upstreamResponse = await fetch(UPSTREAM_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${voltKey}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({ code, preset, runtime }),
      signal: AbortSignal.timeout(20000), // upstream's own default compiler timeout is 15s
    });

    const responseText = await upstreamResponse.text();
    let data;
    try {
      data = JSON.parse(responseText);
    } catch {
      return res.status(502).json({ success: false, error: "Voltfuscator returned a non-JSON response.", upstreamStatus: upstreamResponse.status, raw: responseText.slice(0, 500) });
    }

    return res.status(upstreamResponse.status).json(data);
  } catch (error) {
    const timedOut = error && (error.name === "TimeoutError" || error.name === "AbortError");
    return res.status(502).json({
      success: false,
      error: timedOut ? "Timed out while contacting Voltfuscator." : "Could not reach Voltfuscator.",
      detail: error && error.message ? error.message : "Unknown error",
    });
  }
}
