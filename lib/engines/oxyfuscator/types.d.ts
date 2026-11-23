export type PresetName = "minimum" | "balanced" | "maximum" | "swear";
export interface OxyfuscatorOptions {
    preset: PresetName;
    seed: number;
}
export interface RandomSource {
    next(): number;
    int(min: number, max: number): number;
    pick<T>(values: readonly T[]): T;
}
export interface TransformContext {
    options: OxyfuscatorOptions;
    random: RandomSource;
}
export interface TransformPass {
    readonly name: string;
    run(source: string, context: TransformContext): string;
}
