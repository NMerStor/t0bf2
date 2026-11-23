const SWEAR_NAMES = [
    "fuck", "shit", "damn", "bastard", "ass", "crap", "hell",
    "motherfucker", "bullshit", "dumbass", "shithead", "fuckface",
    "jackass", "dipshit", "asshat", "fuckwit", "shitbag", "wanker",
    "bollocks", "arse"
];
const NORMAL_HEADS = ["l", "I", "O", "v", "x", "q", "z", "_"];
const NORMAL_TAIL = "IlO01vxqz_";
export class NameFactory {
    context;
    used = new Set();
    swearIndex = 0;
    constructor(context) {
        this.context = context;
    }
    next() {
        if (this.context.options.preset === "swear") {
            while (true) {
                const base = SWEAR_NAMES[this.swearIndex % SWEAR_NAMES.length];
                const round = Math.floor(this.swearIndex / SWEAR_NAMES.length);
                this.swearIndex++;
                const candidate = round === 0 ? base : `${base}_${round.toString(36)}`;
                if (!this.used.has(candidate)) {
                    this.used.add(candidate);
                    return candidate;
                }
            }
        }
        while (true) {
            let name = this.context.random.pick(NORMAL_HEADS);
            const length = this.context.random.int(5, 11);
            for (let i = 1; i < length; i++) {
                name += NORMAL_TAIL[this.context.random.int(0, NORMAL_TAIL.length - 1)];
            }
            if (!this.used.has(name)) {
                this.used.add(name);
                return name;
            }
        }
    }
}
