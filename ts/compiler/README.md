[![npm version](https://img.shields.io/npm/v/@ball-lang/compiler.svg)](https://www.npmjs.com/package/@ball-lang/compiler)

# @ball-lang/compiler

Compiles [Ball programs](https://github.com/ball-lang/ball) (proto3 JSON / `Program` objects) into idiomatic **TypeScript** source. Runs entirely in-process using [`ts-morph`](https://ts-morph.com) — no Dart subprocess. The Dart compiler (`dart/compiler/`) is the canonical reference implementation; this package mirrors its semantics.

## Install

```bash
npm install @ball-lang/compiler
```

## Usage

```ts
import { compile } from '@ball-lang/compiler';

// `program` is a Ball Program — a proto3 JSON object (or a parsed equivalent).
const program = {
  name: 'hello',
  version: '1.0.0',
  entryModule: 'main',
  entryFunction: 'main',
  modules: [
    {
      name: 'std',
      functions: [{ name: 'print', isBase: true }],
    },
    {
      name: 'main',
      moduleImports: [{ name: 'std' }],
      functions: [
        {
          name: 'main',
          body: {
            call: {
              module: 'std',
              function: 'print',
              input: {
                messageCreation: {
                  fields: [
                    { name: 'value', value: { literal: { stringValue: 'Hello, World!' } } },
                  ],
                },
              },
            },
          },
        },
      ],
    },
  ],
};

const tsSource: string = compile(program);
console.log(tsSource); // emitted TypeScript
```

## API

- `compile(program: Program, options?: CompileOptions): string` — compile a whole program to TypeScript source.
- `compileModule(module: Module, options?: CompileModuleOptions): string` — compile a single module.
- `BallCompiler` — the underlying class, if you need finer control.
- `TS_RUNTIME_PREAMBLE` — the Dart-flavored runtime polyfill preamble injected at the top of compiled output.

`CompileOptions`:

| Option | Type | Description |
|--------|------|-------------|
| `includePreamble` | `boolean` | Prepend `TS_RUNTIME_PREAMBLE` to the output. Default `true`. |
| `fileName` | `string` | Output file path hint (affects `ts-morph`'s internal resolution). |

## License

MIT
