import type { TransformContext, TransformPass } from "../types.js";
export declare class StripCommentsPass implements TransformPass {
    readonly name = "strip-comments";
    run(source: string, _context: TransformContext): string;
}
