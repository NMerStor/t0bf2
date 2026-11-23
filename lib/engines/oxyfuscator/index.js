import { createPreset } from "./presets.js";
import { XorShift32 } from "./random.js";
export function obfuscate(source, options) {
    const context = {
        options,
        random: new XorShift32(options.seed)
    };
    let output = source;
    for (const pass of createPreset(options.preset, context)) {
        output = pass.run(output, context);
    }
    return `-- Protected using Oxyfuscator v0.9\n${output}`;
}
export * from "./types.js";
