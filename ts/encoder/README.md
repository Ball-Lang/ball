[![npm version](https://img.shields.io/npm/v/@ball-lang/encoder.svg)](https://www.npmjs.com/package/@ball-lang/encoder)

# @ball-lang/encoder

Encodes **TypeScript** source into a [Ball](https://github.com/ball-lang/ball) `Program` (the reverse of `@ball-lang/compiler`). Built on the TypeScript Compiler API; every construct — operators, control flow, closures, try/catch, string/list ops — routes through the universal `std` module (there is no `ts_std`). The Dart encoder (`dart/encoder/`, built on the `analyzer` package) is the canonical reference implementation.

## Install

```bash
npm install @ball-lang/encoder
```

## Usage

```ts
import { encode } from '@ball-lang/encoder';

const program = encode(`
  function main(): void {
    console.log("Hello, World!");
  }
`);

// `program` is a Ball Program object (proto3-JSON-shaped) you can
// serialize, run through @ball-lang/engine, or compile back to a
// target language.
console.log(JSON.stringify(program, null, 2));
```

## API

- `encode(source: string, options?: EncodeOptions): Program` — encode TypeScript source to a Ball `Program`. With `{ strict: true }` it throws an `EncodeError` on any unhandled construct.
- `encodeWithWarnings(source, options?): EncodeResult` — same as `encode`, but returns `{ program, warnings }` so you can inspect non-fatal warnings (e.g. unhandled statement/expression kinds).
- `TsEncoder` — the underlying class.
- `EncodeError` — thrown in strict mode; carries the accumulated `warnings`.

`EncodeOptions`:

| Option | Type | Description |
|--------|------|-------------|
| `moduleName` | `string` | Name of the generated module. Default `"main"`. |
| `entryFunction` | `string` | Entry function name. Default `"main"`. |
| `strict` | `boolean` | Throw `EncodeError` on any unhandled construct. Default `false`. |

## License

MIT
