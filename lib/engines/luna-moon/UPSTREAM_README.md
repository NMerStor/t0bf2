# Luna Moon Obfuscation Engine (Extracted)

Source: https://obfuuscator.vercel.app/
Extracted from: assets/Landing-BBVTw25V.js

## Important

- This is the **client-side** Lua/Luau obfuscation engine.
- No server is involved. Everything runs in the browser.
- Code is minified (original production build). Light formatting applied where possible.

## Files

| File | Description |
|------|-------------|
| `engine.js` | Core obfuscation logic only (tokenizer, parser, string encryption, renaming, control-flow, junk, integrity...) |
| `Landing-BBVTw25V.original.js` | Full original chunk (includes React UI + engine) |

## Main Components inside engine.js

- `class T` – custom Error
- `U(s)` – Lua/Luau tokenizer
- Parser / scope handling
- String encryption + multi-layer decoders (`Ot` related)
- Identifier renaming
- Control-flow flattening
- Junk / dead code insertion
- Number encoding
- Integrity checks
- Minification helpers
- Audit / stats generation

## Presets (from original UI)

- **Basic**: renames + string encoding
- **Strong**: + constants, junk, control flow
- **Extreme**: + aggressive layers, integrity

## Usage note

This is reverse-engineered from a minified production bundle.
To use it properly you still need to wire the entry function that accepts:

```js
{
  level: "basic" | "strong" | "extreme",
  encryptStrings: boolean,
  encodeNumbers: boolean,
  minify: boolean,
  integrityCheck: boolean
}
```

and returns the obfuscated source + stats / meta.

## License / Legal

This extraction is for research / educational purposes only.
Original tool: Luna Moon (obfuuscator.vercel.app)
