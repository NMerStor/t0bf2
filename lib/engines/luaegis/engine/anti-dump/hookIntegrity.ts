/**
 * Hook-integrity preamble.
 *
 * Scope, by design: this checks whether the handful of functions an
 * executor-side dumper needs to intercept in order to capture decoded
 * source at the `load()` boundary — `load`, `loadstring`, `getfenv`,
 * `setfenv`, `require` — have been replaced with a Lua-level hook
 * (the classic `hookfunction(load, function(s) capture(s); return old(s) end)`
 * pattern). It does this with `iscclosure`, which is the standard, narrow
 * way to tell "this is still the engine's real C function" from "this is
 * a Luau closure standing in for it".
 *
 * What this deliberately does NOT do: fingerprint the broader execution
 * environment (physics timing, DataStore round-trips, scheduler behavior,
 * etc.) to guess whether a human, a sandbox, a moderation tool, or a
 * researcher is the one running the script, and it never reacts to a
 * failed check with anything other than a clean, immediate error. It only
 * ever asks "are these specific loader functions still genuine", and on
 * failure it just refuses to run.
 */

export type HookIntegrityOptions = {
  /** Which globals to verify are still genuine C closures. */
  functions?: string[];
  /** Random name generator so names don't collide with the wrapped payload. */
  randomName?: () => string;
};

const DEFAULT_FUNCTIONS = ["load", "loadstring", "getfenv", "setfenv", "require"];

function defaultRandomName(): string {
  return "_" + Math.random().toString(36).slice(2, 8);
}

/**
 * Builds a standalone Lua statement sequence (NOT an expression) that:
 *   1. defines a local integrity-check function,
 *   2. runs it,
 *   3. errors out cleanly if it fails.
 *
 * It is meant to be placed immediately before an existing `return (...)`
 * payload in the same chunk — `if ... then return end` only returns out
 * of its own `if` block, so execution falls through to whatever statement
 * follows afterward, letting you prepend this ahead of an unmodified
 * existing payload without touching that payload's own source.
 */
export function buildHookIntegrityPreamble(opts: HookIntegrityOptions = {}): string {
  const fns = opts.functions ?? DEFAULT_FUNCTIONS;
  const rnd = opts.randomName ?? defaultRandomName;

  const checkFnName = rnd();
  const okName = rnd();
  const fName = rnd();
  const icName = rnd();
  const isCName = rnd();

  const fnList = "{" + fns.map((f) => JSON.stringify(f)).join(",") + "}";

  return [
    `local function ${checkFnName}()`,
    `  local ${icName}=rawget(_G,"iscclosure")`,
    `  if type(${icName})~="function" then return true end`, // not an executor that exposes it — nothing to verify, don't block ordinary clients
    `  for _,${fName} in ipairs(${fnList}) do`,
    `    local ${okName}=rawget(_G,${fName})`,
    `    if type(${okName})=="function" then`,
    `      local _p,${isCName}=pcall(${icName},${okName})`,
    `      if _p and ${isCName}==false then return false end`,
    `    end`,
    `  end`,
    `  return true`,
    `end`,
    `if not ${checkFnName}() then`,
    `  error("luaegis: environment integrity check failed",0)`,
    `end`,
  ].join("\n");
}

/**
 * Convenience: prepend the preamble to an existing self-contained Lua
 * payload (such as the output of `generateVM` / `generateRegVM`, or the
 * XOR-wrapper from the lightweight engine). The payload is left
 * byte-for-byte untouched; the preamble is simply inserted before it in
 * the same chunk.
 */
export function withHookIntegrity(payload: string, opts: HookIntegrityOptions = {}): string {
  return buildHookIntegrityPreamble(opts) + "\n" + payload;
}
