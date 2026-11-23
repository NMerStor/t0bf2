import type { TransformContext, TransformPass } from "../types.js";
export declare class EncodeStringsPass implements TransformPass {
    readonly name = "encode-strings";
    run(source: string, context: TransformContext): string;
}
