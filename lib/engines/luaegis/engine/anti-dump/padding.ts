/**
 * Size padding via junk code.
 *
 * Generates additional, syntactically valid Lua statements — decoy
 * "handler-shaped" functions holding large constant arrays, invoked from
 * inside opaque-predicate branches that never actually run — and prepends
 * them ahead of the real payload until the combined output reaches a
 * target byte size. This is the same opaque-if-junk idiom already used
 * elsewhere in this codebase (see the lightweight engine's `junkBlock`),
 * just scaled to a size target instead of a fixed random count.
 *
 * Note on what this is and isn't: it increases the amount of code a
 * static reader has to wade through, the same way most commercial
 * obfuscators pad output. It is not a security layer on its own — a
 * dead-code-elimination pass can in principle strip it back out. It's
 * bulk, not protection; pair it with the real protection layers
 * (string/constant encryption, VM, anti-tamper, hook-integrity) rather
 * than relying on it alone.
 */

export type PaddingOptions = {
  /** Target total output size in bytes. */
  targetBytes?: number;
  randomName?: () => string;
  rng?: () => number;
};

function defaultRandomName(): string {
  return "_" + Math.random().toString(36).slice(2, 8);
}

function buildDecoyBlock(rng: () => number, randomName: () => string): string {
  const fnName = randomName();
  const condName = randomName();
  const tblName = randomName();

  // Opaque-false predicate: arithmetically always false, but not
  // literally the token `false`, so it doesn't read as a trivial no-op.
  const a = 1 + Math.floor(rng() * 97);
  const b = a * a + 1; // a*a != b, so a*a == b is always false

  const count = 80 + Math.floor(rng() * 160);
  const nums: number[] = [];
  for (let i = 0; i < count; i++) nums.push(Math.floor(rng() * 256));

  const lines: string[] = [];
  lines.push(`local function ${fnName}()`);
  lines.push(`  local ${tblName}={${nums.join(",")}}`);
  lines.push(`  local ${condName}=0`);
  lines.push(`  for _i=1,#${tblName} do ${condName}=${condName}+${tblName}[_i] end`);
  lines.push(`  return ${condName}`);
  lines.push(`end`);
  lines.push(`if (${a}*${a})==${b} then ${fnName}() end`);
  return lines.join("\n");
}

/**
 * Prepend decoy blocks ahead of `payload` until the combined length
 * reaches `targetBytes`. `payload` itself is left untouched (same
 * prepend-before-an-existing-`return` trick used by the hook-integrity
 * preamble, so this composes safely with it in either order).
 */
export function padToSize(payload: string, opts: PaddingOptions = {}): string {
  const target = opts.targetBytes ?? 0;
  const rng = opts.rng ?? Math.random;
  const randomName = opts.randomName ?? defaultRandomName;

  if (target <= payload.length) return payload;

  const blocks: string[] = [];
  let total = payload.length;
  // Safety cap so a pathological target can't loop forever.
  let guard = 0;
  while (total < target && guard < 200_000) {
    const block = buildDecoyBlock(rng, randomName);
    blocks.push(block);
    total += block.length + 1;
    guard++;
  }

  return blocks.join("\n") + "\n" + payload;
}
