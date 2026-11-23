import { tokenize } from "../tokenizer.js";
export class EncodeNumbersPass {
    name = "encode-numbers";
    run(source, context) {
        const tokens = tokenize(source);
        for (const token of tokens) {
            if (token.kind !== "number")
                continue;
            if (!/^\d+$/.test(token.text))
                continue;
            const value = Number(token.text);
            if (!Number.isSafeInteger(value))
                continue;
            if (Math.abs(value) > 0x3fffffff)
                continue;
            const delta = context.random.int(17, 8191);
            const mode = context.random.int(0, 2);
            if (mode === 0) {
                token.text = `(${value + delta}-${delta})`;
            }
            else if (mode === 1) {
                token.text = `(${value - delta}+${delta})`;
            }
            else {
                const left = context.random.int(2, 31);
                token.text = `((${value + left})-${left})`;
            }
        }
        return tokens.map(token => token.text).join("");
    }
}
