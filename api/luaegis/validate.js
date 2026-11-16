import { guard } from "../_lib/cors.js";
import { requireApiKey } from "../_lib/auth.js";
import { validate } from "../../lib-dist/engines/luaegis/engine/vmEngine.js";

export default async function handler(req, res) {
  if (!guard(req, res, { method: "POST" })) return;
  if (!requireApiKey(req, res)) return;

  const body = req.body ?? {};
  const source = body.source;
  if (typeof source !== "string" || source.length === 0) {
    return res.status(400).json({ success: false, error: "Body must include a non-empty string field 'source'." });
  }

  try {
    res.status(200).json({ success: true, ...validate(source) });
  } catch (err) {
    res.status(500).json({ success: false, error: "Validation failed.", detail: err instanceof Error ? err.message : String(err) });
  }
}
