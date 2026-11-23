// Single dynamic-route function that fans out to every engine's handler.
//
// Why this file exists: Vercel's Hobby plan caps a deployment at 12
// serverless functions. One file per endpoint would need 18 (and counting)
// -- way over the cap. Vercel counts physical .js files directly under
// /api, not URL paths, so collapsing everything into one file with a
// [engine]/[action] dynamic route makes it ONE function (plus
// /api/health.js = 2 total) while every URL stays exactly the same --
// /api/luaegis/obfuscate still resolves here with
// req.query.engine === "luaegis" and req.query.action === "obfuscate".
//
// Each handler lives at lib/routes/<name>.js (same default-export shape a
// Vercel api/*.js file would have) -- only the file location changed, not
// the logic. Engine source/adapters living under lib/ (not api/) is also
// why Vercel doesn't count them as separate functions.
//
// Imports are done with dynamic import() INSIDE the request, not static
// imports at the top of the file, on purpose:
//  1. Several engines pull in heavy deps (wasmoon for the Lua-via-WASM
//     engines). A static top-level import would load ALL of that on every
//     single cold start, even for a plain /api/luaegis/obfuscate call that
//     needs none of it.
//  2. Isolation: if one engine's module has a broken/missing dependency,
//     only requests to THAT engine fail -- it can't take down every other
//     route by throwing at module-load time, which a static import would.

const ROUTE_MODULES = {
  "luaegis/obfuscate": () => import("../../lib/routes/luaegisObfuscate.js"),
  "luaegis/vm": () => import("../../lib/routes/luaegisVm.js"),
  "luaegis/validate": () => import("../../lib/routes/luaegisValidate.js"),
  "clyde/obfuscate": () => import("../../lib/routes/clydeObfuscate.js"),
  "clyde/validate": () => import("../../lib/routes/clydeValidate.js"),
  "veil/obfuscate": () => import("../../lib/routes/veilObfuscate.js"),
  "lumora/obfuscate": () => import("../../lib/routes/lumoraObfuscate.js"),
  "wearedev/obfuscate": () => import("../../lib/routes/wearedevObfuscate.js"),
  "25ms-obf/obfuscate": () => import("../../lib/routes/obf25msObfuscate.js"),
  "hercules/obfuscate": () => import("../../lib/routes/herculesObfuscate.js"),
  "moonsecv2/obfuscate": () => import("../../lib/routes/moonsecv2Obfuscate.js"),
  "voltfuscator/obfuscate": () => import("../../lib/routes/voltfuscatorObfuscate.js"),
  "xayz/obfuscate": () => import("../../lib/routes/xayzObfuscate.js"),
  "oxyfuscator/obfuscate": () => import("../../lib/routes/oxyfuscatorObfuscate.js"),
  "moonsecv3/obfuscate": () => import("../../lib/routes/moonsecv3Obfuscate.js"),
  "eatfuscator/obfuscate": () => import("../../lib/routes/eatfuscatorObfuscate.js"),
  "nova/obfuscate": () => import("../../lib/routes/novaObfuscate.js"),
  "exfuscator/obfuscate": () => import("../../lib/routes/exfuscatorObfuscate.js"),
  "azurevm/obfuscate": () => import("../../lib/routes/azurevmObfuscate.js"),
  "catph/obfuscate": () => import("../../lib/routes/catphObfuscate.js"),
  "claudium/obfuscate": () => import("../../lib/routes/claudiumObfuscate.js"),
};

export default async function handler(req, res) {
  const { engine, action } = req.query;
  const key = `${engine}/${action}`;
  const load = ROUTE_MODULES[key];

  if (!load) {
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(404).json({
      success: false,
      error: `No such route: /api/${key}`,
      availableRoutes: Object.keys(ROUTE_MODULES).map((k) => `/api/${k}`),
    });
  }

  let mod;
  try {
    mod = await load();
  } catch (err) {
    res.setHeader("Access-Control-Allow-Origin", "*");
    return res.status(500).json({
      success: false,
      error: `Failed to load the handler for /api/${key}.`,
      detail: err instanceof Error ? err.message : String(err),
    });
  }

  return mod.default(req, res);
}
