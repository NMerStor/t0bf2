const KEYWORDS = new Set([
    "and", "break", "continue", "do", "else", "elseif", "end", "export", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "type", "until", "while"
]);
function isIdentStart(ch) { return /[A-Za-z_]/.test(ch); }
function isIdent(ch) { return /[A-Za-z0-9_]/.test(ch); }
function readLongBracket(source, start) {
    if (source[start] !== "[")
        return null;
    let i = start + 1;
    let equals = 0;
    while (source[i] === "=") {
        equals++;
        i++;
    }
    if (source[i] !== "[")
        return null;
    const close = "]" + "=".repeat(equals) + "]";
    const end = source.indexOf(close, i + 1);
    return end === -1 ? source.length : end + close.length;
}
export function tokenize(source) {
    const tokens = [];
    let i = 0;
    let line = 1;
    const push = (kind, text, tokenLine = line) => {
        tokens.push({ kind, text, line: tokenLine });
        line += (text.match(/\n/g) ?? []).length;
    };
    while (i < source.length) {
        const startLine = line;
        const ch = source[i];
        if (/\s/.test(ch)) {
            let j = i + 1;
            while (j < source.length && /\s/.test(source[j]))
                j++;
            const text = source.slice(i, j);
            push("whitespace", text, startLine);
            i = j;
            continue;
        }
        if (source.startsWith("--", i)) {
            const longStart = readLongBracket(source, i + 2);
            if (longStart !== null) {
                const text = source.slice(i, longStart);
                push("comment", text, startLine);
                i = longStart;
                continue;
            }
            let j = i + 2;
            while (j < source.length && source[j] !== "\n")
                j++;
            const text = source.slice(i, j);
            push("comment", text, startLine);
            i = j;
            continue;
        }
        if (ch === "'" || ch === '"') {
            const quote = ch;
            let j = i + 1;
            while (j < source.length) {
                if (source[j] === "\\") {
                    j += 2;
                    continue;
                }
                if (source[j] === quote) {
                    j++;
                    break;
                }
                j++;
            }
            const text = source.slice(i, j);
            push("string", text, startLine);
            i = j;
            continue;
        }
        if (ch === "`") {
            let j = i + 1;
            while (j < source.length) {
                if (source[j] === "\\") {
                    j += 2;
                    continue;
                }
                if (source[j] === "`") {
                    j++;
                    break;
                }
                j++;
            }
            const text = source.slice(i, j);
            push("string", text, startLine);
            i = j;
            continue;
        }
        const longEnd = readLongBracket(source, i);
        if (longEnd !== null) {
            const text = source.slice(i, longEnd);
            push("string", text, startLine);
            i = longEnd;
            continue;
        }
        if (isIdentStart(ch)) {
            let j = i + 1;
            while (j < source.length && isIdent(source[j]))
                j++;
            const text = source.slice(i, j);
            push(KEYWORDS.has(text) ? "keyword" : "identifier", text, startLine);
            i = j;
            continue;
        }
        if (/[0-9]/.test(ch)) {
            let j = i + 1;
            while (j < source.length && /[A-Za-z0-9_.]/.test(source[j]))
                j++;
            const text = source.slice(i, j);
            push("number", text, startLine);
            i = j;
            continue;
        }
        const multi = ["...", "..=", "//=", "<<=", ">>=", "==", "~=", "<=", ">=", "::", "+=", "-=", "*=", "/=", "%=", "^=", "//", "<<", ">>", "..", "->"].find(op => source.startsWith(op, i));
        if (multi) {
            push("symbol", multi, startLine);
            i += multi.length;
            continue;
        }
        push("symbol", ch, startLine);
        i++;
    }
    return tokens;
}
