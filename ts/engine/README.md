[![npm version](https://img.shields.io/npm/v/@ball-lang/engine.svg)](https://www.npmjs.com/package/@ball-lang/engine)

# @ball-lang/engine

Tree-walking interpreter for the [Ball programming language](https://github.com/ball-lang/ball). Runs Ball programs directly from their proto3 JSON representation in Node.js and browsers -- no protobuf dependency required.

## Install

```bash
npm install @ball-lang/engine
```

## Quick start

```ts
import { BallEngine } from '@ball-lang/engine';

// A minimal Ball program that prints "Hello, World!"
const program = {
  name: 'hello',
  version: '1.0.0',
  entryModule: 'main',
  entryFunction: 'main',
  modules: [
    {
      name: 'std',
      functions: [
        { name: 'print', isBase: true },
        { name: 'add', isBase: true },
      ],
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
                    {
                      name: 'value',
                      value: { literal: { stringValue: 'Hello, World!' } },
                    },
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

// `run()` is async — `await` it (inside an async function, or at the
// top level of an ESM module / `--experimental-strip-types` script).
const engine = new BallEngine(program);
await engine.run();
console.log(engine.getOutput()); // ["Hello, World!"]
```

You can also pass a JSON string instead of an object:

```ts
import { readFileSync } from 'node:fs';

const json = readFileSync('my_program.ball.json', 'utf-8');
const engine = new BallEngine(json);
await engine.run();
console.log(engine.getOutput());
```

## API reference

### `new BallEngine(program, options?)`

Creates an engine instance.

| Parameter | Type | Description |
|-----------|------|-------------|
| `program` | `object \| string` | A Ball program object or its JSON string representation. |
| `options.stdout` | `(msg: string) => void` | Callback for `std.print` output. Defaults to collecting into an internal array. |
| `options.stderr` | `(msg: string) => void` | Callback for error output. Defaults to no-op. |
| `options.sandbox` | `boolean` | Run in sandbox mode (blocks file I/O, env access, etc.). Default `false`. |
| `options.timeoutMs` | `number \| null` | Maximum execution time in milliseconds (`null` = unbounded). Default `null`. |
| `options.maxMemoryBytes` | `number \| null` | Maximum memory usage in bytes (`null` = unbounded). Default `null`. |
| `options.maxRecursionDepth` | `number` | Maximum recursion depth. Default `100000`. |
| `options.maxExpressionDepth` | `number` | Maximum expression nesting depth. Default `1000000`. |
| `options.maxModules` | `number` | Maximum number of modules allowed in the program. Default `1000000`. |
| `options.maxProgramSizeBytes` | `number \| null` | Maximum program JSON size in bytes (`null` = skip check). Default `null`. |

See `BallEngineOptions` in `src/index.ts` for the authoritative list.

### `engine.run(): Promise<string[]>`

Executes the program starting from the entry function. The compiled engine is async internally, so `run()` returns a `Promise` — always `await` it. Resolves to the collected stdout output array.

### `engine.getOutput(): string[]`

Returns the stdout output collected so far (same array returned by `run()`).

## Supported standard library functions

The engine implements the universal Ball `std` module (arithmetic, comparison, logic, bitwise ops, string manipulation, math, control flow — `if`, `for`, `while`, `for_in`, `switch`, `try`, etc.) plus the `std_collections`, `std_io`, and `std_memory` modules. The exact function set is whatever the self-hosted `dart/self_host/engine.ball.json` implements; see the [Ball repository](https://github.com/ball-lang/ball) (`CLAUDE.md` → Standard library modules) for the authoritative list.

## Usage without a build step

The published package's `exports` map exposes only the main entry (`@ball-lang/engine` → the
prebuilt `dist/index.js`), so always import from the bare package specifier — subpath imports
such as `@ball-lang/engine/src/index.ts` are blocked by Node's package encapsulation
(`ERR_PACKAGE_PATH_NOT_EXPORTED`):

```ts
import { BallEngine } from '@ball-lang/engine';
```

If you are using Node.js >= 22.6.0, you can run a `.ts` consumer script directly with
`--experimental-strip-types`; the import above still resolves to the prebuilt entry:

```bash
node --experimental-strip-types your_script.ts
```

To consume the raw TypeScript source instead, work from a checkout of the
[Ball repository](https://github.com/ball-lang/ball) and import `ts/engine/src/index.ts` by
relative path.

## License

MIT
