import type { TransformContext } from "./types.js";
export declare class NameFactory {
    private readonly context;
    private used;
    private swearIndex;
    constructor(context: TransformContext);
    next(): string;
}
