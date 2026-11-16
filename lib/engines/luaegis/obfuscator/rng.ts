export class Rng {
  private s: number;
  readonly seed: number;

  constructor(seed?: number) {
    this.seed = seed === undefined ? (Math.floor(Math.random() * 0xffffffff) >>> 0) : seed >>> 0;
    this.s = this.seed || 0x9e3779b9;
  }

  next() {
    let t = (this.s += 0x6d2b79f5);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  int(max: number) {
    return Math.floor(this.next() * max);
  }

  pick<T>(arr: T[]): T {
    return arr[this.int(arr.length)]!;
  }

  bytes(n: number) {
    const out: number[] = [];
    for (let i = 0; i < n; i++) out.push(this.int(256));
    return out;
  }
}
