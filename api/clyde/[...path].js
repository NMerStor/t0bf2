import obfuscate from "../../backend/clyde/obfuscate.js";
import validate from "../../backend/clyde/validate.js";

const routes = new Map([
  ["obfuscate", obfuscate],
  ["validate", validate],
]);

export default function handler(req, res) {
  const pathname = new URL(req.url, "http://localhost").pathname;
  const routeName = pathname.replace(/^\/api\/clyde\/?/, "").replace(/\/+$/, "");
  const route = routes.get(routeName);

  if (!route) {
    return res.status(404).json({ success: false, error: "Not found." });
  }

  return route(req, res);
}
