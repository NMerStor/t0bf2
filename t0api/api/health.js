import { guard } from "./_lib/cors.js";

export default function handler(req, res) {
  if (!guard(req, res, { method: "GET" })) return;
  res.status(200).json({
    ok: true,
    service: "t0api",
    engines: [
      "luaegis", "clyde", "veil", "lumora",
      "wearedev", "25ms-obf [old]", "hercules", "moonsecv2",
      "voltfuscator", "xayz",
      "oxyfuscator", "moonsecv3 [reconstruction]", "eatfuscator [AGPL-3.0]", "nova",
      "exfuscator", "azurevm [exp]", "catph [exp]", "claudium", "ig67",
    ],
    time: new Date().toISOString(),
  });
}
