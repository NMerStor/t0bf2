import { NameFactory } from "../names.js";
import { tokenize } from "../tokenizer.js";
function significant(tokens) {
    const result = [];
    for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].kind !== "whitespace" && tokens[i].kind !== "comment")
            result.push(i);
    }
    return result;
}
function previousSignificant(tokens, index) {
    for (let i = index - 1; i >= 0; i--) {
        const token = tokens[i];
        if (token.kind !== "whitespace" && token.kind !== "comment")
            return token;
    }
    return undefined;
}
function isPropertyIdentifier(tokens, index) {
    const prev = previousSignificant(tokens, index);
    return prev?.text === "." || prev?.text === ":";
}
function resolve(scope, name, line) {
    let current = scope;
    while (current) {
        const binding = current.bindings.get(name);
        if (binding && line >= binding.activationLine)
            return binding;
        current = current.parent;
    }
    return undefined;
}
function declarationActivationLine(tokens, tokenIndex) {
    const line = tokens[tokenIndex].line;
    for (let i = tokenIndex + 1; i < tokens.length; i++) {
        const token = tokens[i];
        if (token.line > line)
            return token.line;
        if (token.text === ";")
            return line;
    }
    return line;
}
export class RenameLocalsPass {
    name = "rename-locals";
    run(source, context) {
        const tokens = tokenize(source);
        const sig = significant(tokens);
        const names = new NameFactory(context);
        const root = { parent: null, bindings: new Map() };
        let scope = root;
        const tokenScopes = new Map();
        const declarationTokens = new Set();
        let pendingForVariables = [];
        const pushScope = () => { scope = { parent: scope, bindings: new Map() }; };
        const popScope = () => { if (scope.parent)
            scope = scope.parent; };
        const declare = (tokenIndex, activationLine) => {
            const token = tokens[tokenIndex];
            if (token.kind !== "identifier")
                return;
            if (resolve(scope, token.text, token.line)) {
                scope.bindings.set(token.text, { original: token.text, replacement: token.text, activationLine: activationLine ?? token.line });
                declarationTokens.add(tokenIndex);
                return;
            }
            const binding = { original: token.text, replacement: names.next(), activationLine: activationLine ?? token.line };
            scope.bindings.set(token.text, binding);
            declarationTokens.add(tokenIndex);
            token.text = binding.replacement;
        };
        for (let s = 0; s < sig.length; s++) {
            const tokenIndex = sig[s];
            const token = tokens[tokenIndex];
            tokenScopes.set(tokenIndex, scope);
            if (token.kind !== "keyword")
                continue;
            if (token.text === "local") {
                const nextIndex = sig[s + 1];
                if (nextIndex === undefined)
                    continue;
                const next = tokens[nextIndex];
                if (next.text === "function") {
                    const nameIndex = sig[s + 2];
                    if (nameIndex !== undefined)
                        declare(nameIndex, tokens[nameIndex].line);
                    continue;
                }
                let cursor = s + 1;
                while (cursor < sig.length) {
                    const candidateIndex = sig[cursor];
                    const candidate = tokens[candidateIndex];
                    if (candidate.kind === "identifier") {
                        declare(candidateIndex, declarationActivationLine(tokens, candidateIndex));
                        cursor++;
                        const commaIndex = sig[cursor];
                        if (commaIndex !== undefined && tokens[commaIndex].text === ",") {
                            cursor++;
                            continue;
                        }
                    }
                    break;
                }
                continue;
            }
            if (token.text === "function") {
                pushScope();
                let cursor = s + 1;
                while (cursor < sig.length && tokens[sig[cursor]].text !== "(")
                    cursor++;
                if (cursor < sig.length) {
                    cursor++;
                    while (cursor < sig.length) {
                        const paramIndex = sig[cursor];
                        const param = tokens[paramIndex];
                        if (param.text === ")")
                            break;
                        if (param.kind === "identifier")
                            declare(paramIndex, param.line);
                        cursor++;
                    }
                }
                continue;
            }
            if (token.text === "for") {
                pendingForVariables = [];
                let cursor = s + 1;
                while (cursor < sig.length) {
                    const candidateIndex = sig[cursor];
                    const candidate = tokens[candidateIndex];
                    if (candidate.kind === "identifier") {
                        pendingForVariables.push(candidateIndex);
                        cursor++;
                        const sepIndex = sig[cursor];
                        if (sepIndex !== undefined && tokens[sepIndex].text === ",") {
                            cursor++;
                            continue;
                        }
                    }
                    break;
                }
                continue;
            }
            if (token.text === "then" || token.text === "repeat") {
                pushScope();
                continue;
            }
            if (token.text === "do") {
                pushScope();
                if (pendingForVariables.length) {
                    for (const variableIndex of pendingForVariables)
                        declare(variableIndex, token.line);
                    pendingForVariables = [];
                }
                continue;
            }
            if (token.text === "else") {
                popScope();
                pushScope();
                continue;
            }
            if (token.text === "elseif") {
                popScope();
                continue;
            }
            if (token.text === "end" || token.text === "until") {
                popScope();
                continue;
            }
        }
        for (const tokenIndex of sig) {
            const token = tokens[tokenIndex];
            const mappedScope = tokenScopes.get(tokenIndex) ?? root;
            if (token.kind === "identifier" && !declarationTokens.has(tokenIndex) && !isPropertyIdentifier(tokens, tokenIndex)) {
                const binding = resolve(mappedScope, token.text, token.line);
                if (binding && binding.replacement !== binding.original)
                    token.text = binding.replacement;
            }
        }
        return tokens.map(token => token.text).join("");
    }
}
