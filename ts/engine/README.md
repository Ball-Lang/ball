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

const engine = new BallEngine(program);
engine.run();
console.log(engine.getOutput()); // ["Hello, World!"]
```

You can also pass a JSON string instead of an object:

```ts
import { readFileSync } from 'node:fs';

const json = readFileSync('my_program.ball.json', 'utf-8');
const engine = new BallEngine(json);
engine.run();
```

## API reference

### `new BallEngine(program, options?)`

Creates an engine instance.

| Parameter | Type | Description |
|-----------|------|-------------|
| `program` | `object \| string` | A Ball program object or its JSON string representation. |
| `options.stdout` | `(msg: string) => void` | Callback for `std.print` output. Defaults to collecting into an internal array. |
| `options.stderr` | `(msg: string) => void` | Callback for error output. Defaults to no-op. |

### `engine.run(): string[]`

Executes the program starting from the entry function. Returns the collected stdout output array.

### `engine.getOutput(): string[]`

Returns the stdout output collected so far (same array returned by `run()`).

## Supported standard library functions

The engine implements the Ball `std` module (~70 functions) covering arithmetic, comparison, logic, bitwise ops, string manipulation, math, control flow (`if`, `for`, `while`, `for_in`, `switch`, `try`), collections, and I/O. See the [Ball repository](https://github.com/ball-lang/ball) for the full specification.

## Usage without a build step

If you are using Node.js >= 22.6.0, you can import the TypeScript source directly:

```bash
node --experimental-strip-types your_script.ts
```

```ts
import { BallEngine } from '@ball-lang/engine/src/index.ts';
```

## License

MIT
