import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";

const MAX_SOURCE_BYTES = 400_000;
const PRESETS = ["Minify", "Weak", "Vmify", "Medium", "Strong", "Luraph", "Luraph14", "Luraph15", "AzureGod", "AzureGod15", "AzureGodUltra", "Fast", "Balanced", "Hardened", "Research"];

function getServiceUrl() {
  const value = process.env.AZUREVM_LUA51_SERVICE_URL;
  if (!value) return null;

  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("AZUREVM_LUA51_SERVICE_URL must be a valid URL.");
  }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new Error("AZUREVM_LUA51_SERVICE_URL must be an HTTP(S) URL without embedded credentials.");
  }
  return url;
}

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
  const preset = body.preset || "Luraph";
  if (!PRESETS.includes(preset)) {
    return res.status(400).json({ success: false, error: `'preset' must be one of: ${PRESETS.join(", ")}` });
  }

  let serviceUrl;
  try {
    serviceUrl = getServiceUrl();
  } catch (error) {
    return res.status(500).json({ success: false, error: error.message });
  }
  if (!serviceUrl) {
    return res.status(503).json({
      success: false,
      error: "AzureVM Lua 5.1 service is not configured. Set AZUREVM_LUA51_SERVICE_URL.",
    });
  }

  const serviceToken = process.env.AZUREVM_LUA51_SERVICE_TOKEN;
  if (!serviceToken) {
    return res.status(503).json({
      success: false,
      error: "AzureVM service authentication is not configured. Set AZUREVM_LUA51_SERVICE_TOKEN.",
    });
  }

  try {
    const upstreamResponse = await fetch(serviceUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceToken}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        source,
        preset,
        ...(typeof body.seed === "number" ? { seed: body.seed } : {}),
      }),
      signal: AbortSignal.timeout(240_000),
    });

    const responseText = await upstreamResponse.text();
    let data;
    try {
      data = JSON.parse(responseText);
    } catch {
      return res.status(502).json({
        success: false,
        error: "AzureVM Lua 5.1 service returned a non-JSON response.",
        upstreamStatus: upstreamResponse.status,
      });
    }

    if (!upstreamResponse.ok) {
      return res.status(502).json({
        success: false,
        error: "AzureVM Lua 5.1 service failed to obfuscate the source.",
        upstreamStatus: upstreamResponse.status,
        detail: typeof data.error === "string" ? data.error : undefined,
      });
    }
    if (typeof data.output !== "string") {
      return res.status(502).json({
        success: false,
        error: "AzureVM Lua 5.1 service returned an invalid response.",
      });
    }

    return res.status(200).json({ success: true, engine: "azurevm", output: data.output, preset });
  } catch (error) {
    const timedOut = error && (error.name === "TimeoutError" || error.name === "AbortError");
    return res.status(502).json({
      success: false,
      error: timedOut ? "Timed out while contacting the AzureVM Lua 5.1 service." : "Could not reach the AzureVM Lua 5.1 service.",
      detail: error instanceof Error ? error.message : String(error),
    });
  }
}
