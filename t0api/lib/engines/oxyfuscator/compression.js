export const BASE85_CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#";
export function lzCompress(input) {
    const out = [];
    const literals = [];
    const chains = new Map();
    const maxDistance = 0xffff;
    const maxLength = 130;
    const maxCandidates = 32;
    const keyAt = (pos) => {
        if (pos + 2 >= input.length)
            return null;
        return ((input[pos] << 16) | (input[pos + 1] << 8) | input[pos + 2]) >>> 0;
    };
    const addPosition = (pos) => {
        const key = keyAt(pos);
        if (key === null)
            return;
        let list = chains.get(key);
        if (!list) {
            list = [];
            chains.set(key, list);
        }
        list.push(pos);
        if (list.length > 64)
            list.splice(0, list.length - 64);
    };
    const flushLiterals = () => {
        let offset = 0;
        while (offset < literals.length) {
            const length = Math.min(128, literals.length - offset);
            out.push(length - 1);
            for (let i = 0; i < length; i++)
                out.push(literals[offset + i]);
            offset += length;
        }
        literals.length = 0;
    };
    let pos = 0;
    while (pos < input.length) {
        let bestLength = 0;
        let bestDistance = 0;
        const key = keyAt(pos);
        const candidates = key === null ? undefined : chains.get(key);
        if (candidates) {
            let tested = 0;
            for (let c = candidates.length - 1; c >= 0 && tested < maxCandidates; c--, tested++) {
                const candidate = candidates[c];
                const distance = pos - candidate;
                if (distance <= 0 || distance > maxDistance)
                    continue;
                let length = 0;
                const limit = Math.min(maxLength, input.length - pos);
                while (length < limit && input[candidate + length] === input[pos + length])
                    length++;
                if (length > bestLength) {
                    bestLength = length;
                    bestDistance = distance;
                    if (bestLength === maxLength)
                        break;
                }
            }
        }
        if (bestLength >= 4) {
            flushLiterals();
            out.push(0x80 | (bestLength - 3));
            out.push((bestDistance >>> 8) & 0xff, bestDistance & 0xff);
            for (let p = pos; p < pos + bestLength; p++)
                addPosition(p);
            pos += bestLength;
            continue;
        }
        literals.push(input[pos]);
        addPosition(pos);
        pos++;
        if (literals.length === 128)
            flushLiterals();
    }
    flushLiterals();
    return out;
}
export function base85Encode(input, alphabet) {
    if (alphabet.length !== 85)
        throw new Error("Base85 alphabet must contain 85 characters.");
    let out = "";
    for (let offset = 0; offset < input.length; offset += 4) {
        const b0 = input[offset] ?? 0;
        const b1 = input[offset + 1] ?? 0;
        const b2 = input[offset + 2] ?? 0;
        const b3 = input[offset + 3] ?? 0;
        let value = b0 * 16777216 + b1 * 65536 + b2 * 256 + b3;
        const chars = new Array(5);
        for (let i = 4; i >= 0; i--) {
            const digit = value % 85;
            chars[i] = alphabet[digit];
            value = Math.floor(value / 85);
        }
        out += chars.join("");
    }
    return out;
}
