import { guard } from "../../api/_lib/cors.js";
import { requireApiKey } from "../../api/_lib/auth.js";
import { clydeValidate } from "../../lib-dist/engines/clyde/apiWrapper.js";

export default async function handler(req, res) {
  if (!guard(req, res, { method: "POST" })) return;
  if (!requireApiKey(req, res)) return;

  const body = req.body ?? {};
  const code = body.code ?? body.source;
  if (typeof code !== "string" || code.length === 0) {
    return res.status(400).json({ success: false, error: "Body must include a non-empty string field 'code'." });
  }

  try {
    res.status(200).json({ success: true, ...clydeValidate(code) });
  } catch (err) {
    res.status(500).json({ success: false, error: "Validation failed.", detail: err instanceof Error ? err.message : String(err) });
  }
}
