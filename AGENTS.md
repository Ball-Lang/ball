# Ball Project Agents

This file provides instructions for AI coding agents working on the Ball project.

## Project Context

Ball is a programming language where code is structured protobuf messages. The project has:
- A **mature Dart implementation** (compiler, encoder, engine, CLI)
- A **prototype C++ implementation** (compiler, encoder with normalizer, engine)
- **Proto bindings** for Go, Python, TypeScript, Java, C# (no implementations)

## Build & Test

```bash
# Dart — test the engine
cd dart && dart pub get
cd dart/engine && dart test

# Dart — compile an example
cd dart/compiler && dart run bin/compile.dart ../../examples/hello_world.ball.json

# C++ — build all
cd cpp/build && cmake .. && cmake --build .

# Proto — lint and generate
buf lint
buf generate
```

## Key Invariants — NEVER Violate These

1. **One input, one output per function** — like gRPC. Don't add multi-parameter functions.
2. **Metadata is cosmetic** — stripping all metadata must not change what a program computes.
3. **Base functions have no body** — their implementation is per-platform.
4. **Control flow is function calls** — if/for/while are std functions with lazy evaluation.
5. **Never edit generated files** — `dart/shared/lib/gen/`, `cpp/shared/gen/`, `std.json`, `std.bin`

## Critical Known Issues

- C++ `string_split`/`string_replace`/`string_replace_all` emit empty comments (BROKEN)
- C++ has ZERO tests
- C++ `std_collections` and `std_io` modules are stubs (declared, not implemented)
- Dart encoder silently swallows malformed metadata

## File Organization

| Path | What it is | Editable? |
|------|-----------|-----------|
| `proto/ball/v1/ball.proto` | Language schema | Yes — run `buf lint` + `buf generate` after |
| `dart/shared/lib/std.dart` | Std library definition | Yes — run `gen_std.dart` after |
| `dart/shared/std.json` | Compiled std module | NO — generated |
| `dart/shared/lib/gen/` | Protobuf Dart types | NO — generated |
| `cpp/shared/gen/` | Protobuf C++ types | NO — generated |
| `dart/compiler/lib/compiler.dart` | Reference compiler | Yes |
| `dart/encoder/lib/encoder.dart` | Reference encoder | Yes |
| `dart/engine/lib/engine.dart` | Reference interpreter | Yes |
| `dart/engine/test/engine_test.dart` | Engine tests | Yes — add tests here |

## When Implementing a Feature

1. Check if it needs a proto schema change → edit `ball.proto`, lint, generate
2. Check if it needs a new std function → edit `dart/shared/lib/std.dart`, regenerate
3. Implement in Dart compiler (`compiler.dart`)
4. Implement in Dart engine (`engine.dart`)
5. Add tests (`engine_test.dart`)
6. If C++ is affected: implement in both `cpp/compiler/` and `cpp/engine/`
7. Update `docs/METADATA_SPEC.md` if new metadata keys are introduced
