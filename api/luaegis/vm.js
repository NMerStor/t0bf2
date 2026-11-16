import { guard } from "../_lib/cors.js";
import { requireApiKey } from "../_lib/auth.js";
import { vmObfuscate } from "../../lib-dist/engines/luaegis/engine/vmEngine.js";

const MAX_SOURCE_BYTES = 1_000_000;
const VM_TYPES = ["none", "stack", "register"];
const VM_LEVELS = ["debug", "normal", "max"];

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
  if (body.vmType !== undefined && !VM_TYPES.includes(body.vmType)) {
    return res.status(400).json({ success: false, error: `'vmType' must be one of: ${VM_TYPES.join(", ")}` });
  }
  if (body.vmLevel !== undefined && !VM_LEVELS.includes(body.vmLevel)) {
    return res.status(400).json({ success: false, error: `'vmLevel' must be one of: ${VM_LEVELS.join(", ")}` });
  }

  // Vercel Hobby plan caps a function at 10s; Pro can go higher via
  // vercel.json's functions.*.maxDuration. vmLayers > 1-2 can genuinely take
  // longer than that — see README.md "Vercel execution-time limits".
  try {
    const result = vmObfuscate(source, {
      vmType: body.vmType,
      vmLevel: body.vmLevel,
      rename: typeof body.rename === "boolean" ? body.rename : undefined,
      preserveGlobals: typeof body.preserveGlobals === "boolean" ? body.preserveGlobals : undefined,
      encodeStrings: typeof body.encodeStrings === "boolean" ? body.encodeStrings : undefined,
      scrambleControlFlow: typeof body.scrambleControlFlow === "boolean" ? body.scrambleControlFlow : undefined,
      oneLine: typeof body.oneLine === "boolean" ? body.oneLine : undefined,
      hookIntegrity: typeof body.hookIntegrity === "boolean" ? body.hookIntegrity : undefined,
      randomDtc: typeof body.randomDtc === "boolean" ? body.randomDtc : undefined,
      vmLayers: typeof body.vmLayers === "number" ? body.vmLayers : undefined,
      padBytes: typeof body.padBytes === "number" ? body.padBytes : undefined,
      seed: typeof body.seed === "number" ? body.seed : undefined,
    });
    res.status(200).json({ success: true, ...result });
  } catch (err) {
    res.status(500).json({ success: false, error: "VM obfuscation failed.", detail: err instanceof Error ? err.message : String(err) });
  }
}
