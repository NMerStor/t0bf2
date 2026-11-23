import { tokenize } from "../tokenizer.js";
export class StripCommentsPass {
    name = "strip-comments";
    run(source, _context) {
        return tokenize(source).map(token => {
            if (token.kind !== "comment")
                return token.text;
            const newlines = (token.text.match(/\n/g) ?? []).length;
            return "\n".repeat(newlines);
        }).join("");
    }
}
