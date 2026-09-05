<!-- Parent: ../AGENTS.md -->

# ts/compiler (`@ball-lang/compiler`)

## Purpose

Ball → TypeScript compiler. Consumes a `Program` (proto3-JSON object) and emits idiomatic TypeScript source via `ts-morph`. Also used internally to regenerate `ts/engine/src/compiled_engine.ts` from the self-hosted engine Ball source, and `ts/cli/src/compiled_cli.ts` from the self-hosted `cli_core.dart` source (issue #364).

## Key Files

| File | Description |
|------|-------------|
| `src/compiler.ts` | `BallCompiler` class — walks the expression tree and emits TS. |
| `src/index.ts` | Public exports: `compile(program, opts?) → string`, `compileLibrary`, `compileModule`, `BallCompiler`, `CompileOptions`. |
| `src/preamble.ts` | `TS_RUNTIME_PREAMBLE` — Dart-flavored polyfills installed on `Object.prototype` (e.g. `whichExpr()`, `hasBody()`) so compiled Dart-origin code can call proto-style methods on plain JSON objects. The `ball_proto` module's `hasX()` proto-accessor free functions (e.g. `hasBody`/`hasMetadata`/`hasHttp`/`hasFile`/`hasGit`/`hasRegistry`/`hasInline`) are a **hand-curated, fixed list** here — NOT derived from whatever `ball_proto` functions a given compiled Program actually declares. Adding a *new* `hasX()`/`whichX()` call site anywhere in a compiled-to-TS Ball source (e.g. issue #364's `cli_core.dart` calling `ModuleImport.hasHttp()`/etc. for the first time) needs its stub added here too, or it throws `ReferenceError: hasX is not defined` at runtime — this is exactly the gap issue #364 found and fixed for the `ModuleImport.source` oneof. |
| `src/types.ts` | Local TypeScript type aliases for the Ball proto3-JSON tree (used internally; not protobuf-es `Message` objects). |
| `bin/ball-ts-compile.mjs` | CLI shim (`ball-ts-compile`) called by the Dart compiler runner. |

## For AI Agents

- Entry point: `compile(program: Program, opts?: CompileOptions) → string`. `program` is a **plain proto3-JSON object** (not a protobuf-es `Message`) — no `fromJson` needed here.
- Declarations (functions, classes, enums) go through ts-morph's structure API; expressions/statements are emitted as raw TS strings into an internal buffer (`BallCompiler.out`).
- Base-function dispatch lives in `_callBaseFunction()` — that is the correct place to add or fix built-in function compilation.
- `TS_RUNTIME_PREAMBLE` from `preamble.ts` is prepended to every output and must remain consistent with the runtime assumptions of compiled code.
- **Regenerating the self-hosted engine:** run `node --experimental-strip-types tool/regen_compiled_engine.mjs` (compiles `dart/self_host/engine.ball.json`, `@type` stripped, through `compile()` and writes `ts/engine/src/compiled_engine.ts`). That script is the TS sibling of Rust's `ball-engine-regen` / Go's `cmd/regen` / Python's `ball_engine.regen`, and ci.yml's `Ball Artifact Freshness` job runs it and diffs the result — the committed artifact is the only compiled engine that can go stale in git. Full command in `CLAUDE.md` → Build & Test.
- **Regenerating the CLI core (issue #364):** compile `dart/self_host/cli.ball.json` through `compile()`, then add `export` to every top-level `function`/`class`/`enum`/`let`/`const` not already exported (cli_core.dart is a free-function library, not a single class, so `compile()`'s built-in class-export logic alone isn't enough), and write to `ts/cli/src/compiled_cli.ts`. Full command in `CLAUDE.md` → Build & Test ("Regenerate compiled TS CLI core").
- Test runner: `node --experimental-strip-types --test test/*.test.ts`. Tests compile fixtures and verify output parses / runs through the engine.
- **`test/engine_runtime.test.ts` is the leg that matters most for any change to
  `compileStdCall` or expression emission.** It compiles `engine.ball.json` — the
  self-hosted Ball engine — with THIS compiler and runs the entire ~321-fixture
  conformance corpus through the result. A compiler change can be green across
  every other leg and still break every engine (that is the shape of #464/#465):
  making `null_aware_index` null-safe in read position emitted `a?.[i] = v` in
  WRITE position, a JS `SyntaxError` that killed all 321 fixtures at once, while
  `std_call_dispatch.test.ts` and the fixture suites stayed green. Since
  `engine.ball.json` is a gitignored build artifact absent from a fresh checkout,
  the suite regenerates it on demand (into a process-unique temp path) rather
  than skipping — a skipped suite here is a fake green, not a pass.
- **`test/std_name_consistency.test.ts`** statically enumerates every std name
  `ts/encoder` can emit and compiles each one, so a name the encoder emits but
  `compileStdCall` does not implement fails the build. When you deliberately
  leave one unimplemented, add it to that file's `KNOWN_GAPS` table with a reason
  and mirror the entry in `ts/encoder/ENCODER_CARVEOUTS.md`.
- **A defaultless `switch_expr` that matches nothing throws** (`Non-exhaustive
  switch expression`), matching the Dart engine, C#, Go and Rust (#467); it used
  to answer `undefined`. Two guards keep it faithful and are pinned by tests in
  `test/pattern_matching.test.ts`: a statement `switch` legally matches nothing
  and still yields `undefined`, and a `default:` arm with no body still catches.
  The self-hosted engine's own oneof dispatchers are defaultless switch
  *expressions*, so verify any change here with `engine_runtime.test.ts` — they
  are safe only because each carries an explicit `notSet` arm.
- Never import from `ts/shared/gen/` in compiler source — this package uses raw proto3-JSON trees (plain objects), not protobuf-es `Message` types.
- See `.claude/rules/ts.md` and `CLAUDE.md` for TS API conventions and invariants.

## Dependencies

- Internal: none (operates on plain JSON objects matching the Ball proto3-JSON shape)
- External: `ts-morph` ^28 (AST building and TS file emission)
