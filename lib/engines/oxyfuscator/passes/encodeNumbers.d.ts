import type { TransformContext, TransformPass } from "../types.js";
export declare class EncodeNumbersPass implements TransformPass {
    readonly name = "encode-numbers";
    run(source: string, context: TransformContext): string;
}
