import type { RandomSource } from "./types.js";
export declare class XorShift32 implements RandomSource {
    private state;
    constructor(seed: number);
    next(): number;
    int(min: number, max: number): number;
    pick<T>(values: readonly T[]): T;
}
