import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { azureVmObfuscate } from "../engines/azureVmRunner.js";

const MAX_SOURCE_BYTES = 400_000;
const PRESETS = ["Minify", "Weak", "Vmify", "Medium", "Strong", "Luraph", "Luraph14", "Luraph15", "AzureGod", "AzureGod15", "AzureGodUltra", "Fast", "Balanced", "Hardened", "Research"];

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

  try {
    const result = await azureVmObfuscate(source, { preset, seed: typeof body.seed === "number" ? body.seed : undefined });
    res.status(200).json({ success: true, engine: "azurevm", ...result });
  } catch (err) {
    res.status(500).json({
      success: false,
      error: "Obfuscation failed (AzureVM/wasmoon) -- this engine reads raw Lua 5.1 bytecode, which may not match wasmoon's Lua 5.4.",
      detail: err instanceof Error ? err.message : String(err),
    });
  }
}
