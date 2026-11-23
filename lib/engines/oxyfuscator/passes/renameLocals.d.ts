import type { TransformContext, TransformPass } from "../types.js";
export declare class RenameLocalsPass implements TransformPass {
    readonly name = "rename-locals";
    run(source: string, context: TransformContext): string;
}
