export class XorShift32 {
    state;
    constructor(seed) {
        let value = seed | 0;
        if (value === 0)
            value = 0x6d2b79f5;
        this.state = value;
    }
    next() {
        let x = this.state | 0;
        x ^= x << 13;
        x ^= x >>> 17;
        x ^= x << 5;
        this.state = x | 0;
        return (x >>> 0) / 0x100000000;
    }
    int(min, max) {
        if (max < min)
            [min, max] = [max, min];
        return min + Math.floor(this.next() * (max - min + 1));
    }
    pick(values) {
        if (values.length === 0)
            throw new Error("Cannot pick from an empty array.");
        return values[this.int(0, values.length - 1)];
    }
}
