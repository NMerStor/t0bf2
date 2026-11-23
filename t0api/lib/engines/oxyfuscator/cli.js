#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { obfuscate } from "./index.js";
function usage() {
    console.log(`Oxyfuscator v0.9\n\nUsage:\n  oxyfuscator <input> [-o output.lua] [--preset minimum|balanced|maximum|swear]\n\nPresets:\n  minimum  - conservative local renaming\n  balanced - rename + strings + comment removal\n  maximum  - balanced + numbers + two randomized VM layers + fake opcodes + shadow VMs + anti-tamper + LZ/Base85 VM compression\n  swear    - maximum, but renamed locals use swear words\n\nAdvanced:\n  --seed <number>\n`);
    process.exit(0);
}
function parseArgs(argv) {
    if (argv.includes("--help") || argv.includes("-h") || argv.length === 0)
        usage();
    const input = argv[0];
    let output = "obfuscated.lua";
    let preset = "balanced";
    let seed = Date.now() >>> 0;
    for (let i = 1; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === "-o" || arg === "--output") {
            output = argv[++i] ?? output;
        }
        else if (arg === "--preset") {
            const value = argv[++i];
            if (!value || !["minimum", "balanced", "maximum", "swear"].includes(value)) {
                throw new Error(`Unknown preset: ${value ?? ""}`);
            }
            preset = value;
        }
        else if (arg === "--seed") {
            const value = Number.parseInt(argv[++i] ?? "", 10);
            if (!Number.isFinite(value))
                throw new Error("--seed requires an integer");
            seed = value >>> 0;
        }
        else {
            throw new Error(`Unknown option: ${arg}`);
        }
    }
    return { input, output, preset, seed };
}
const raw = parseArgs(process.argv.slice(2));
const source = await readFile(resolve(raw.input), "utf8");
const result = obfuscate(source, { preset: raw.preset, seed: raw.seed });
const outputPath = resolve(raw.output);
await writeFile(outputPath, result, "utf8");
console.log(`[Oxyfuscator] preset: ${raw.preset}`);
console.log(`[Oxyfuscator] seed: ${raw.seed}`);
console.log(`[Oxyfuscator] loader VM: ${raw.preset === "maximum" || raw.preset === "swear" ? "enabled" : "disabled"}`);
console.log(`[Oxyfuscator] layered VM / anti-tamper: ${raw.preset === "maximum" || raw.preset === "swear" ? "enabled" : "disabled"}`);
console.log(`[Oxyfuscator] VM compression: ${raw.preset === "maximum" || raw.preset === "swear" ? "LZ + randomized Base85" : "disabled"}`);
console.log(`[Oxyfuscator] output: ${outputPath}`);
