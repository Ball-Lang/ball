# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Ball Is

Ball is a programming language where every program is a Protocol Buffer message (`proto/ball/v1/ball.proto` is the single source of truth). Compilers translate Ball programs into target-language source, encoders do the reverse, and engines interpret Ball programs directly. Dart is the mature reference implementation; C++ is a prototype; Go/Python/TS/Java/C# currently ship proto bindings only.

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
5. **Never edit generated files:** `dart/shared/lib/gen/**`, `cpp/shared/gen/**`, `dart/shared/std.json`, `dart/shared/std.bin`. Regenerate via `buf generate` or `gen_std.dart`.

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

### Standard library modules
`std` (~73 fns: arithmetic, comparison, logic, bitwise, strings, math, control flow, type ops), `std_collections` (~43 list/map fns), `std_io` (~10 console/process/time/random), `std_memory` (~30 linear-memory fns for C/C++ interop), `dart_std` (~18 Dart-specific: cascade, null_aware_access, invoke, spread, etc.).

## Known Broken / Stubbed (don't assume these work)

- **Dart encoder:** Permissive mode silently collects (non-fatal) warnings on malformed metadata. Use `DartEncoder(strict: true)` to surface them as errors.
- **Both engines:** `async`/`await` is a synchronous simulation — `async` functions wrap their return value in `BallFuture`, `await` recursively unwraps, but there is no event loop, no microtask queue, and no deferred execution. A real scheduler would require rewriting every expression evaluator to be async.

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
