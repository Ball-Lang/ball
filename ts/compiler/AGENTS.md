<!-- Parent: ../AGENTS.md -->

# ts/compiler (`@ball-lang/compiler`)

## Purpose

Ball → TypeScript compiler. Consumes a `Program` (proto3-JSON object) and emits idiomatic TypeScript source via `ts-morph`. Also used internally to regenerate `ts/engine/src/compiled_engine.ts` from the self-hosted engine Ball source, and `ts/cli/src/compiled_cli.ts` from the self-hosted `cli_core.dart` source (issue #364).

## Key Files

| File | Description |
|------|-------------|
| `src/compiler.ts` | `BallCompiler` class — walks the expression tree and emits TS. |
| `src/index.ts` | Public exports: `compile(program, opts?) → string`, `compileModule`, `BallCompiler`, `CompileOptions`. |
| `src/preamble.ts` | `TS_RUNTIME_PREAMBLE` — Dart-flavored polyfills installed on `Object.prototype` (e.g. `whichExpr()`, `hasBody()`) so compiled Dart-origin code can call proto-style methods on plain JSON objects. The `ball_proto` module's `hasX()` proto-accessor free functions (e.g. `hasBody`/`hasMetadata`/`hasHttp`/`hasFile`/`hasGit`/`hasRegistry`/`hasInline`) are a **hand-curated, fixed list** here — NOT derived from whatever `ball_proto` functions a given compiled Program actually declares. Adding a *new* `hasX()`/`whichX()` call site anywhere in a compiled-to-TS Ball source (e.g. issue #364's `cli_core.dart` calling `ModuleImport.hasHttp()`/etc. for the first time) needs its stub added here too, or it throws `ReferenceError: hasX is not defined` at runtime — this is exactly the gap issue #364 found and fixed for the `ModuleImport.source` oneof. |
| `src/types.ts` | Local TypeScript type aliases for the Ball proto3-JSON tree (used internally; not protobuf-es `Message` objects). |
| `bin/ball-ts-compile.mjs` | CLI shim (`ball-ts-compile`) called by the Dart compiler runner. |

## For AI Agents

- Entry point: `compile(program: Program, opts?: CompileOptions) → string`. `program` is a **plain proto3-JSON object** (not a protobuf-es `Message`) — no `fromJson` needed here.
- Declarations (functions, classes, enums) go through ts-morph's structure API; expressions/statements are emitted as raw TS strings into an internal buffer (`BallCompiler.out`).
- Base-function dispatch lives in `_callBaseFunction()` — that is the correct place to add or fix built-in function compilation.
- `TS_RUNTIME_PREAMBLE` from `preamble.ts` is prepended to every output and must remain consistent with the runtime assumptions of compiled code.
- **Regenerating the self-hosted engine:** compile `dart/self_host/engine.ball.json` (strip `@type` first) through `compile()` and write to `ts/engine/src/compiled_engine.ts`. Full command in `CLAUDE.md` → Build & Test.
- **Regenerating the CLI core (issue #364):** compile `dart/self_host/cli.ball.json` through `compile()`, then add `export` to every top-level `function`/`class`/`enum`/`let`/`const` not already exported (cli_core.dart is a free-function library, not a single class, so `compile()`'s built-in class-export logic alone isn't enough), and write to `ts/cli/src/compiled_cli.ts`. Full command in `CLAUDE.md` → Build & Test ("Regenerate compiled TS CLI core").
- Test runner: `node --experimental-strip-types --test test/*.test.ts`. Tests compile fixtures and verify output parses / runs through the engine.
- Never import from `ts/shared/gen/` in compiler source — this package uses raw proto3-JSON trees (plain objects), not protobuf-es `Message` types.
- See `.claude/rules/ts.md` and `CLAUDE.md` for TS API conventions and invariants.

## Dependencies

- Internal: none (operates on plain JSON objects matching the Ball proto3-JSON shape)
- External: `ts-morph` ^28 (AST building and TS file emission)
