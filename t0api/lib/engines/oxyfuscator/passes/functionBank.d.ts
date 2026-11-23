import type { TransformContext, TransformPass } from "../types.js";
export declare class FunctionBankPass implements TransformPass {
    private readonly enableTimingCheck;
    private readonly intensity;
    readonly name = "function-bank-layered-vm-v5-compressed";
    constructor(enableTimingCheck?: boolean, intensity?: number);
    run(source: string, context: TransformContext): string;
}
