import obfuscate from "../../backend/luaegis/obfuscate.js";
import vm from "../../backend/luaegis/vm.js";
import validate from "../../backend/luaegis/validate.js";

const routes = new Map([
  ["obfuscate", obfuscate],
  ["vm", vm],
  ["validate", validate],
]);

export default function handler(req, res) {
  const pathname = new URL(req.url, "http://localhost").pathname;
  const routeName = pathname.replace(/^\/api\/luaegis\/?/, "").replace(/\/+$/, "");
  const route = routes.get(routeName);

  if (!route) {
    return res.status(404).json({ success: false, error: "Not found." });
  }

  return route(req, res);
}
