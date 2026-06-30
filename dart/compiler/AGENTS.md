<!-- Parent: ../AGENTS.md -->

# compiler (`ball_compiler`)

## Purpose
Ball → Dart code generator. Translates a Ball `Program` (protobuf expression tree) into formatted Dart source, with multi-module package compilation.

## Key Files
| File | Description |
|------|-------------|
| `lib/compiler.dart` | `DartCompiler.compile(Program)` → formatted Dart source |
| `lib/package_compiler.dart` | `PackageCompiler` — multi-module Program → Dart package |
| `lib/ball_compiler.dart` | Public library; re-exports compiler + encoder + engine facade |
| `bin/compile_ts.dart` | Helper that drives the TS compiler from Dart |
| `tool/gen_engine_json.dart` | Regenerate self-hosted engine JSON from the Dart engine |
| `tool/compile_engine_cpp.dart` | Compile self-hosted engine to C++ (`dart/self_host/`) |
| `tool/compile_ball_protobuf_cpp.dart` | Compile `ball_protobuf` facade to C++ |

## For AI Agents
- Entry point: `DartCompiler.compile`. Base-function dispatch is in `_compileBaseCall` — extract fields from the `MessageCreation` input.
- Control flow (`if`/`for`/`while`) MUST compile lazily — extract expression trees, never eval branches eagerly (see Core Invariants in `../../CLAUDE.md`).
- Types are emitted from `typeDefs[]` only; the legacy `types[]`/`_meta_*` path is gone.
- Compiler-specific patterns and gotchas: `.claude/rules/dart.md`.
- Tests in `test/`; cross-language matrix tests tagged `slow` (`-x slow` to skip).

## Dependencies
- Internal: `ball_base`, `ball_encoder`, `ball_engine`, `ball_resolver`.
- External: `code_builder` (Dart AST), `dart_style` (formatter), `protobuf`/`fixnum`.
