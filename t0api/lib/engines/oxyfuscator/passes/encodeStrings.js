import { tokenize } from "../tokenizer.js";
function isTypeLiteral(tokens, index) {
    const line = tokens[index].line;
    for (let i = index - 1; i >= 0; i--) {
        const token = tokens[i];
        if (token.line !== line)
            break;
        if (token.kind === "keyword" && (token.text === "type" || token.text === "export")) {
            return true;
        }
    }
    return false;
}
function decodeSimpleQuoted(text) {
    if (text.length < 2)
        return null;
    const quote = text[0];
    if ((quote !== "\"" && quote !== "'") || text[text.length - 1] !== quote)
        return null;
    const body = text.slice(1, -1);
    if (body.includes("\\"))
        return null;
    return body;
}
function utf8Bytes(value) {
    return Array.from(new TextEncoder().encode(value));
}
export class EncodeStringsPass {
    name = "encode-strings";
    run(source, context) {
        const tokens = tokenize(source);
        const nonce = `${context.options.seed.toString(36)}_${context.random.int(0x1000, 0xffff).toString(36)}`;
        const decoder = `__oxy_s_${nonce}`;
        let changed = false;
        for (let i = 0; i < tokens.length; i++) {
            const token = tokens[i];
            if (token.kind !== "string")
                continue;
            if (isTypeLiteral(tokens, i))
                continue;
            const value = decodeSimpleQuoted(token.text);
            if (value === null || value.length === 0)
                continue;
            const bytes = utf8Bytes(value);
            if (bytes.length > 1024)
                continue;
            const key = context.random.int(7, 223);
            const encoded = bytes.map(byte => (byte + key) % 256);
            token.text = `${decoder}({${encoded.join(",")}},${key})`;
            changed = true;
        }
        if (!changed)
            return source;
        const t = `__oxy_t_${nonce}`;
        const k = `__oxy_k_${nonce}`;
        const out = `__oxy_o_${nonce}`;
        const i = `__oxy_i_${nonce}`;
        const helper = `local ${decoder}=function(${t},${k})local ${out}={} for ${i}=1,#${t} do ${out}[${i}]=string.char((${t}[${i}]-${k})%256) end return table.concat(${out}) end\n`;
        return helper + tokens.map(token => token.text).join("");
    }
}
