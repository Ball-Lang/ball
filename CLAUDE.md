# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Ball Is

Ball is a programming language where every program is a Protocol Buffer message (`proto/ball/v1/ball.proto` is the single source of truth). Compilers translate Ball programs into target-language source, encoders do the reverse, and engines interpret Ball programs directly. Dart is the mature reference implementation; C++ is a prototype; Go/Python/TS/Java/C# currently ship proto bindings only.

## Gemeral Rules to follow (CRITICAL)

- Avoid anti-patterns, follow best practices
- Maximize performance and minimize memory usage where possible, but not at the cost of readability or maintainability.
- Write clear, concise code with good variable names and comments where necessary.
- Make sure everything is covered by tests, maximize using e2e tests instead of just unit tests.
- DO NOT leave any hanging TODOs or FIXMEs in the code. If something is not implemented, either implement it or remove the placeholder.
- When in doubt, use Askquestions tool to get feedback on design decisions or implementation details.
- Maximize automation via github actions, scripts, and code generation. Avoid manual steps that can be automated.
- Follow the existing code style and patterns in the repository for consistency. If you need to introduce a new pattern, make sure to justify it and document it well.
- Update CLAUDE.md and AGENTS.md and .claude/* as needed when making changes to the codebase, especially if it affects how agents interact with the code or how developers should work with it.
- Always cross check your work against official latest docs, compiler source codes, and any relevant resources to ensure accuracy and completeness.

## Build & Test

```bash
# Dart — workspace resolution; run from dart/ root
cd dart && dart pub get
cd dart/engine && dart test                    # full engine test suite
cd dart/engine && dart test --name "pattern"   # single test by name
cd dart/encoder && dart test                   # encoder tests
cd dart/compiler && dart run bin/compile.dart ../../examples/hello_world/hello_world.ball.json
cd dart/engine   && dart run bin/engine.dart   ../../examples/hello_world/hello_world.ball.json

# C++ — CMake; buf auto-regenerates protos if buf CLI is on PATH
cd cpp && mkdir -p build && cd build && cmake .. && cmake --build .
cmake --build cpp/build --target buf_lint     # also: buf_format, buf_breaking, buf_check

# TypeScript — shared protobuf types
cd ts/shared && npm install && npm test          # protobuf-es binding tests

# TS engine tests (self-hosted compiled engine, 140 conformance tests)
cd ts/engine && npm test

# TS compiler tests (including compiled engine conformance)
cd ts/compiler && npm install && npm test

# Regenerate compiled TS engine from self-hosted Ball source
cd ts/compiler && node --experimental-strip-types -e "
const {readFileSync, writeFileSync} = require('fs');
const {compile} = require('./src/index.ts');
const program = JSON.parse(readFileSync('../../dart/self_host/engine.ball.json', 'utf8'));
const ts = compile(program);
writeFileSync('../engine/src/compiled_engine.ts', '// @ts-nocheck — auto-generated\n' + ts);
"

# Proto — lint, breaking-change check, regenerate all bindings
buf lint
buf breaking --against ".git#subdir=proto"
buf generate

# After editing dart/shared/lib/std.dart, regenerate std.json/std.bin
cd dart/shared && dart run bin/gen_std.dart
```

## Core Invariants — Never Violate

1. **One input, one output per function** (gRPC-style). Not a limitation — it is the design. Don't add multi-parameter functions.
2. **Metadata is cosmetic.** Stripping all metadata must never change what a program computes. Semantic content = expression tree, function signatures, type descriptors, module structure. Everything else lives in `google.protobuf.Struct metadata` fields.
3. **Base functions have no body.** Their implementation is supplied per-platform by the target compiler/engine — this is the extensibility mechanism.
4. **Control flow is function calls.** `if`, `for`, `while`, `for_each` are std base functions. Compilers and engines MUST evaluate them lazily — never eagerly evaluate all branches before choosing one.
5. **Never edit generated files:** `dart/shared/lib/gen/**`, `cpp/shared/gen/**`, `ts/shared/gen/**`, `ts/engine/src/compiled_engine.ts`, `dart/shared/std.json`, `dart/shared/std.bin`. Regenerate via `buf generate`, `gen_std.dart`, or the TS engine regeneration command above.

## Architecture Big Picture

Every Ball computation is one of seven `Expression` node types: `call`, `literal`, `reference`, `fieldAccess`, `messageCreation`, `block`, `lambda`. The special reference name `"input"` always means "this function's parameter." Understanding this tree is the key to reading both compilers (`DartCompiler.compile` / the C++ string-based emitter) and engines (tree-walking interpreters with lexical `Scope` chains and `FlowSignal` for break/continue/return).

### Dart workspace (`dart/`)
Five packages resolved as a workspace:
- `ball_base` (`shared/`) — protobuf types + std module builders; dependency for the rest.
- `ball_compiler` — Ball → Dart via `code_builder` + `dart_style`. Base-function dispatch lives in `_compileBaseCall`; extract fields from the `MessageCreation` input.
- `ball_encoder` — Dart → Ball via the `analyzer` package. Dart-specific constructs (cascade, null-aware access, spread, invoke) encode to the `dart_std` module, not `std`.
- `ball_engine` — tree-walking interpreter. `StdModuleHandler` dispatches `std`/`dart_std`; custom modules implement `BallModuleHandler`.
- `ball_cli` — CLI entry point.

Types are emitted from `typeDefs[]` (preferred) or the legacy `types[]` + `_meta_*` functions path.

### C++ prototype (`cpp/`)
- `BallValue = std::any`, `BallList = std::vector<BallValue>`, `BallMap = std::map<std::string, BallValue>` (ordered — **not** `unordered_map`).
- Compiler emits C++ via string concatenation; blocks become immediately-invoked lambdas.
- Encoder consumes Clang JSON AST (`clang -Xclang -ast-dump=json`), then a normalizer rewrites `cpp_std` pointer ops into safe references or `std_memory` unsafe ops.
- Stack sizes are bumped for deep protobuf ASTs: compiler 128 MB, encoder 256 MB; engine has 65 KB linear memory.

### TypeScript workspace (`ts/`)

Four packages (no workspace manager — each has its own `node_modules`):

- `@ball-lang/shared` (`shared/`) — protobuf-es generated types from `ball.proto` (via `buf generate`). Depends on `@bufbuild/protobuf` v2. Provides typed messages with discriminated unions for oneofs (`expr.expr.case === "call"`), JSON/binary serialization (`fromJson`/`toJson`/`fromBinary`/`toBinary` from `@bufbuild/protobuf`), and presence checking (`field !== undefined`). API mapping from Dart protobuf: `whichExpr()` -> `expr.case`, `hasBody()` -> `body !== undefined`, `metadata.fields['key'].whichKind()` -> `typeof metadata?.['key']`.
- `@ball-lang/compiler` — Ball -> TypeScript. Uses `ts-morph`. The preamble (`preamble.ts`) installs Dart-flavored polyfills (`whichExpr()`, `hasBody()`, etc.) on `Object.prototype` so compiled Dart code can call proto-style methods on plain JSON objects.
- `@ball-lang/engine` — Self-hosted engine: `compiled_engine.ts` is generated by compiling `dart/self_host/engine.ball.json` through `@ball-lang/compiler`. `index.ts` wraps it with proto3 JSON normalization (protoWrap), method dispatch handlers, and extra std function registrations. The hand-written engine is preserved as `index.handwritten.ts` for reference. `run()` is async (returns `Promise<string[]>`).
- `@ball-lang/encoder` — TS -> Ball (stub).

### Standard library modules
`std` (~73 fns: arithmetic, comparison, logic, bitwise, strings, math, control flow, type ops), `std_collections` (~43 list/map fns), `std_io` (~10 console/process/time/random), `std_memory` (~30 linear-memory fns for C/C++ interop), `dart_std` (~18 Dart-specific: cascade, null_aware_access, invoke, spread, etc.).

## Known Broken / Stubbed (don't assume these work)

- **Dart encoder:** Permissive mode silently collects (non-fatal) warnings on malformed metadata. Use `DartEncoder(strict: true)` to surface them as errors.
- **Dart engine:** `async`/`await` is now truly non-blocking — all expression evaluators are `async` and `await` suspends execution via Dart's native `Future` mechanism. `BallFuture` is retained for backward compatibility with programs that wrap return values explicitly. `sleep_ms` uses `Future.delayed` instead of blocking `dart:io` sleep.
- **C++ engine:** `async`/`await` is still a synchronous simulation — `async` functions wrap their return value in `BallFuture`, `await` recursively unwraps, but there is no event loop, no microtask queue, and no deferred execution.
- **Self-hosted engine** (`dart/self_host/lib/engine_rt.cpp`): The Dart engine compiled to C++ via the Ball C++ compiler. Compiles and runs but has known issues: (1) `/* is check */ true` / `/* is_not check */ false` patterns where the compiler couldn't emit Dart type checks — these are always-true/false placeholders that break control flow, FlowSignal detection, and super chain walking; (2) `while(true)` infinite loops from `while (obj is Map)` that became `while (true)`; (3) BallDyn wrapping/unwrapping issues where values get double-wrapped as `std::any(BallDyn(std::any(value)))` instead of `std::any(value)`. The conformance test suite (`test_selfhost_conformance`) runs a subset of tests — currently 0/17 pass but the engine produces output for all of them. Build: `cmake --build build --target test_selfhost_conformance`.

C++ has a custom test framework (`TEST(name)` macros) at [cpp/test/test_engine.cpp](cpp/test/test_engine.cpp), [cpp/test/test_compiler.cpp](cpp/test/test_compiler.cpp), and [cpp/test/test_conformance.cpp](cpp/test/test_conformance.cpp) (the conformance harness runs every `tests/conformance/*.ball.json` through the C++ engine and diff-checks stdout against the matching `.expected_output.txt`). Build via `cmake --build build --target test_engine test_compiler test_conformance` and run the resulting binaries. Always add tests alongside C++ changes.

## Typical Feature Workflow

1. Does it need a schema change? Edit `proto/ball/v1/ball.proto`, then `buf lint` → `buf breaking ...` → `buf generate`.
2. Does it need a new std function? Edit `dart/shared/lib/std.dart`, then rerun `gen_std.dart`.
3. Implement in `dart/compiler/lib/compiler.dart`.
4. Implement in `dart/engine/lib/engine.dart`.
5. Add a test in `dart/engine/test/engine_test.dart` (helpers: `buildProgram()`, `runAndCapture()`, `loadProgram()`).
6. If C++ is in scope: mirror in `cpp/compiler/` **and** `cpp/engine/` and add C++ tests.
7. If new metadata keys were introduced, update `docs/METADATA_SPEC.md`.

## Examples Layout

Each example lives at `examples/<name>/` with `<name>.ball.json` (proto3 JSON Ball program) and optional `dart/` / `cpp/` compiled outputs. Every program must define the std module with all base functions/types it uses; user functions carry a `body` expression tree, base functions set `"isBase": true` with no body.
