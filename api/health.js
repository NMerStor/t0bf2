import { guard } from "./_lib/cors.js";

export default function handler(req, res) {
  if (!guard(req, res, { method: "GET" })) return;
  res.status(200).json({
    ok: true,
    service: "t0api",
    engines: [
      "luaegis", "clyde", "veil", "lumora",
      "wearedev", "25ms-obf [old]", "hercules", "moonsecv2",
      "voltfuscator", "xayz", "luna-moon [not implemented]",
    ],
    time: new Date().toISOString(),
  });
}
