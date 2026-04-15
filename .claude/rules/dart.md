---
paths:
  - "dart/**"
---

# Dart-Specific Instructions

## Package Structure

Ball's Dart implementation is a workspace with 5 packages:
- `ball_base` (dart/shared/) — Protobuf types, std module builders. Dependency for all others.
- `ball_compiler` (dart/compiler/) — Ball → Dart code generator using `code_builder` + `dart_style`
- `ball_encoder` (dart/encoder/) — Dart → Ball using `analyzer` package
- `ball_engine` (dart/engine/) — Tree-walking Ball interpreter
- `ball_cli` (dart/cli/) — CLI tool

## Key Patterns

### Compiler
- `DartCompiler.compile(Program)` → returns formatted Dart source string
- Base functions are dispatched in `_compileBaseCall()` — extract fields from `MessageCreation` input
- Control flow (if, for, while) must use LAZY evaluation — extract expression trees, don't evaluate eagerly
- Types are emitted from `typeDefs[]` (preferred) or legacy `types[]` + `_meta_*` functions

### Encoder
- `DartEncoder.encode(String source)` → returns Ball `Program`
- Uses `analyzer` package to parse Dart AST
- Encodes ALL Dart expressions to Ball equivalents
- Dart-specific constructs go to `dart_std` module (cascade, null_aware_access, spread, etc.)
- Build `std` modules from accumulated function references via `buildStdModules()`

### Engine
- `BallEngine.run(Program)` → executes, returns captured stdout
- Scoping via linked `Scope` chain (lexical scoping with parent pointers)
- `StdModuleHandler` dispatches std/dart_std base functions
- Flow signals (break, continue, return) propagate via `FlowSignal` objects
- Custom modules via `BallModuleHandler` abstract class

## Generated Files — NEVER Edit

- `dart/shared/lib/gen/**` — Protobuf generated types
- `dart/shared/std.json` — Generated from std.dart via `dart run bin/gen_std.dart`
- `dart/shared/std.bin` — Binary protobuf version of std

## Testing

- Tests in `dart/engine/test/engine_test.dart`
- Use `buildProgram()` helper for minimal test programs
- Use `runAndCapture()` to execute and capture stdout
- Use `loadProgram()` to load .ball.json files from examples/

## Dependencies

- `protobuf: ^6.0.0` — Protobuf runtime
- `fixnum: ^1.1.1` — 64-bit integer support
- `code_builder` — Dart AST builder (compiler)
- `dart_style` — Dart formatter (compiler)
- `analyzer` — Dart parser (encoder)
