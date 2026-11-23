/**
 * Strong anti-tamper / anti-dump module for LuAegis.
 *
 * - Strong crash (goofyscator-style): error + typeof walk + infinite recursion
 * - Random DTC injection from the 200-probe library
 * - Hook integrity (kept from original)
 * - Polymorphic names every build
 */

import { pickRandomDtc, DTC_LIBRARY, type DtcEntry } from "./dtcLibrary.js";
import { buildHookIntegrityPreamble } from "./hookIntegrity.js";

export type StrongAntiOptions = {
  /** Include classic iscclosure hook check. Default true. */
  hookIntegrity?: boolean;
  /** Inject one random DTC from the 200-probe library. Default true. */
  randomDtc?: boolean;
  /** Force a specific DTC id (for testing). */
  dtcId?: string;
  /** RNG 0..1. Provide seeded RNG for reproducibility. */
  rng?: () => number;
  randomName?: () => string;
};

function defaultRandomName(rng: () => number): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  let s = "_";
  for (let i = 0; i < 6 + Math.floor(rng() * 4); i++) {
    s += alphabet[Math.floor(rng() * alphabet.length)];
  }
  return s;
}

/**
 * Strong crash body (inspired by goofyscator).
 * Called when any integrity check fails.
 */
function buildStrongCrash(crashName: string): string {
  return [
    `local function ${crashName}()`,
    `  error("luaegis: integrity violation", 0)`,
    `  local walk = typeof`,
    `  local state = nil`,
    `  while true do`,
    `    local value`,
    `    value, state = walk(nil, state)`,
    `    state = value`,
    `    if state ~= nil then`,
    `      continue`,
    `    else`,
    `      break`,
    `    end`,
    `  end`,
    `  local function recur()`,
    `    recur()`,
    `  end`,
    `  recur()`,
    `end`,
  ].join("\n");
}

/**
 * Wrap a raw DTC snippet so that its failure path calls our strong crash
 * instead of just printing "dtc".
 *
 * Many DTCs use a local function b() that errors, or set a flag `d=true`.
 * We inject the crash function and rewrite the most common fail patterns.
 */
function adaptDtc(dtc: DtcEntry, crashName: string, rng: () => number): string {
  let src = dtc.src;

  // Common pattern in det_*.luau: local function b() ... error("dtc") ... end
  // Replace the body of b() to call our crash
  src = src.replace(
    /local function b\(\)\s*if type\(error\) == "function" then\s*error\("dtc", 0\)\s*end\s*local s = "x"\s*s:dtc\(\)\s*end/g,
    `local function b() ${crashName}() end`
  );

  // Simpler: if they still call error("dtc"
  src = src.replace(/error\s*\(\s*["']dtc["']\s*,\s*0\s*\)/g, `${crashName}()`);
  src = src.replace(/error\s*\(\s*["']dtc["']\s*\)/g, `${crashName}()`);

  // For coroutine-style that set d=true then warn
  // We leave the logic and at the end force crash if d
  if (src.includes("local d=") || src.includes("local d =")) {
    // Append a final check
    src = src + `\nif d then ${crashName}() end`;
  }

  return src;
}

/**
 * Build the full anti-tamper preamble to place before the protected payload.
 */
export function buildStrongAntiPreamble(opts: StrongAntiOptions = {}): {
  preamble: string;
  usedDtcId: string | null;
  usedHook: boolean;
} {
  const rng = opts.rng ?? Math.random;
  const rnd = () => (opts.randomName ? opts.randomName() : defaultRandomName(rng));
  const crashName = rnd();
  const parts: string[] = [];

  parts.push(buildStrongCrash(crashName));

  let usedDtcId: string | null = null;
  const wantDtc = opts.randomDtc !== false;

  if (wantDtc) {
    let dtc: DtcEntry;
    if (opts.dtcId) {
      dtc = DTC_LIBRARY.find((e) => e.id === opts.dtcId) ?? pickRandomDtc(rng);
    } else {
      dtc = pickRandomDtc(rng);
    }
    usedDtcId = dtc.id;
    const adapted = adaptDtc(dtc, crashName, rng);
    parts.push(`-- anti:${dtc.id}`);
    parts.push(adapted);
  }

  const wantHook = opts.hookIntegrity !== false;
  if (wantHook) {
    // Replace the simple error in original hookIntegrity with our crash
    let hook = buildHookIntegrityPreamble({ randomName: rnd });
    hook = hook.replace(
      /error\("luaegis: environment integrity check failed",0\)/,
      `${crashName}()`
    );
    parts.push(hook);
  }

  return {
    preamble: parts.join("\n"),
    usedDtcId,
    usedHook: wantHook,
  };
}

/**
 * Prepend strong anti-tamper to an existing payload.
 */
export function withStrongAnti(
  payload: string,
  opts: StrongAntiOptions = {}
): { output: string; usedDtcId: string | null; usedHook: boolean } {
  const { preamble, usedDtcId, usedHook } = buildStrongAntiPreamble(opts);
  return {
    output: preamble + "\n" + payload,
    usedDtcId,
    usedHook,
  };
}
