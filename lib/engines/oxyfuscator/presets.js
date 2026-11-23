import { EncodeNumbersPass } from "./passes/encodeNumbers.js";
import { EncodeStringsPass } from "./passes/encodeStrings.js";
import { FunctionBankPass } from "./passes/functionBank.js";
import { RenameLocalsPass } from "./passes/renameLocals.js";
import { StripCommentsPass } from "./passes/stripComments.js";
export function createPreset(name, _context) {
    const passes = [];
    if (name === "minimum") {
        passes.push(new RenameLocalsPass());
        return passes;
    }
    passes.push(new RenameLocalsPass(), new StripCommentsPass(), new EncodeStringsPass());
    if (name === "maximum" || name === "swear") {
        passes.push(new EncodeNumbersPass(), new FunctionBankPass(true, 2), new FunctionBankPass(false, 3));
    }
    return passes;
}
