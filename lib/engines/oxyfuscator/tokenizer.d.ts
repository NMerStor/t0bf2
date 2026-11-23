export type TokenKind = "identifier" | "keyword" | "number" | "string" | "comment" | "whitespace" | "symbol";
export interface Token {
    kind: TokenKind;
    text: string;
    line: number;
}
export declare function tokenize(source: string): Token[];
