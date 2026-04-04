# Ball Programming Language — Copilot Instructions

## Project Overview

Ball is a programming language represented entirely as Protocol Buffer messages. Code is data — every program is a structured protobuf message that can be serialized, shared, inspected, and compiled to any target language.

## Architecture

```
ball/
├── proto/ball/v1/ball.proto    # Language schema (source of truth)
├── dart/                        # Dart implementation (MOST MATURE)
│   ├── shared/                  # Protobuf types, std module definitions
│   ├── compiler/                # Ball → Dart code generator
│   ├── encoder/                 # Dart → Ball encoder
│   ├── engine/                  # Ball runtime interpreter
│   └── cli/                     # Command-line interface
├── cpp/                         # C++ implementation (PROTOTYPE)
│   ├── shared/                  # Protobuf types, base module builders
│   ├── compiler/                # Ball → C++ code generator
│   ├── encoder/                 # C++ Clang AST → Ball encoder
│   └── engine/                  # Ball runtime interpreter
├── examples/                    # Example Ball programs (.ball.json)
├── docs/                        # Documentation
└── {go,python,ts,java,csharp}/  # Proto bindings only (no implementations yet)
```

## Core Design Principles

1. **Every function has exactly one input message and one output message** (like gRPC). This is NOT a limitation — it IS the design.
2. **Semantic vs cosmetic boundary**: The expression tree, function signatures, type descriptors, and module structure are SEMANTIC. Everything else (visibility, mutability, annotations, syntax sugar) is COSMETIC metadata.
3. **Metadata is optional and cosmetic**: A Ball program with all metadata stripped computes the same result. Metadata improves round-trip fidelity.
4. **Base functions have no body**: Their implementation is provided by each target language compiler/engine. This is the extensibility mechanism.
5. **Control flow is function calls**: `if`, `for`, `while` are std base functions, keeping the language uniform. Compilers must handle them with lazy evaluation (don't evaluate all branches before choosing one).

## Key Files

- `proto/ball/v1/ball.proto` — Canonical language schema
- `dart/shared/lib/std.dart` — Standard library definition (~120 functions)
- `dart/shared/std.json` — Compiled std module (proto3 JSON)
- `dart/compiler/lib/compiler.dart` — Reference compiler (~2000 lines)
- `dart/encoder/lib/encoder.dart` — Reference encoder (~3000 lines)
- `dart/engine/lib/engine.dart` — Reference engine (~2000 lines)
- `docs/METADATA_SPEC.md` — Standard metadata keys
- `docs/IMPLEMENTING_A_COMPILER.md` — Compiler implementation guide

## Standard Library Modules

| Module | Functions | Description |
|--------|-----------|-------------|
| `std` | ~73 | Arithmetic, comparison, logic, bitwise, string, math, control flow, type ops |
| `std_collections` | ~43 | List and Map operations |
| `std_io` | ~10 | Console, process, time, random, environment |
| `std_memory` | ~30 | Linear memory (C/C++ interop) |
| `dart_std` | ~18 | Dart-specific: cascade, null_aware_access, invoke, spread, etc. |

## Coding Conventions

### Dart
- Use Dart 3.9+ features (records, patterns, sealed classes)
- Follow `lints` package rules (analysis_options.yaml)
- Use workspace pubspec resolution
- Protobuf types are in `dart/shared/lib/gen/` — NEVER edit generated files
- Run `buf generate` to regenerate protobuf bindings

### C++
- C++17 standard
- Use `std::any` for runtime polymorphism (`BallValue`)
- Use `std::map<std::string, BallValue>` for maps (ordered, not unordered)
- CMake build system with protobuf dependency
- Encoder requires nlohmann/json

### Proto
- Package: `ball.v1`
- Buf module: `buf.build/ball-lang/ball`
- Run `buf lint` before committing proto changes
- Run `buf breaking --against ".git#subdir=proto"` to check backward compatibility

## Expression Tree (the core of Ball)

Every Ball computation is one of:
- `call` — Call a function: `{module, function, input}`
- `literal` — Constant: int, double, string, bool, bytes, list
- `reference` — Variable: `{name}` (special: `"input"` = function parameter)
- `fieldAccess` — Field access: `{object, field}`
- `messageCreation` — Construct message: `{typeName, fields[]}`
- `block` — Sequential statements + result expression
- `lambda` — Anonymous function (FunctionDefinition with name = "")

## Known Issues

- C++ string operations (split, replace) emit empty comments — BROKEN
- C++ collections/IO modules are stubs — not implemented in engine
- Dart encoder silently swallows malformed metadata
- Both engines pass through async/await as no-ops
- Dart formatter fails on most FFmpeg-compiled output (compile succeeds)

## Build Commands

```bash
# Dart
cd dart && dart pub get
cd dart/engine && dart test
cd dart/compiler && dart run bin/compile.dart ../../examples/hello_world.ball.json

# C++
cd cpp/build && cmake .. && cmake --build .

# Proto
buf lint
buf generate
```

## Testing

- Dart engine: `dart/engine/test/engine_test.dart`
- Dart encoder: `dart/encoder/test/encoder_test.dart`
- C++: `cpp/test/test_engine.cpp` + `cpp/test/test_compiler.cpp`
- FFmpeg stress test: 965 files compiled successfully through both Dart and C++ compilers
