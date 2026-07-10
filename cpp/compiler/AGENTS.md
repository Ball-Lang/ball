<!-- Parent: ../AGENTS.md -->

# cpp/compiler

## Purpose
Ball → C++ code generator. Walks a protobuf-free `ball::ir::Program` tree (loaded via nlohmann/json — #18 Stage 4/5) and emits self-contained C++ source (single-TU or split multi-TU for the self-hosted engine).

## Key Files
| File | Description |
|------|-------------|
| `src/compiler.cpp` | `CppCompiler` implementation — expression dispatch, base-function dispatch, block→lambda emission |
| `src/main.cpp` | CLI entry point (`ball_cpp_compile` binary) |
| `include/compiler.h` | `CppCompiler` class declaration; `CompileSplitResult` (multi-TU) and `CompileLibraryResult` structs |
| `include/code_builder.h` | Line-oriented string builder used throughout emission |

## For AI Agents
- Entry point: `CppCompiler::compile()` (single TU) or `compile_split()` (sharded for engine_rt). Read `compiler.h` first.
- Base-function dispatch is in `_compileBaseCall` (large switch in `compiler.cpp`). Unknown base functions silently emit `/* std.fn */ 0` — a known silent-correctness gap; see `../AGENTS.md` § Known Broken/Stubbed Features.
- Blocks compile to immediately-invoked lambdas; `for`/`while` in expression context with `return` inside are partially stubbed — see `../AGENTS.md`.
- `ball_emit_runtime.h` (in `../shared/include/`) is slurped at CMake configure time and spliced verbatim into every emitted program's preamble. Changes there propagate automatically — do not duplicate its content.
- CMake target: `ball_cpp_compile`. Stack size: 128 MB (set in `cpp/CMakeLists.txt`).
- Tests live in `cpp/test/test_compiler.cpp`. Reference `.claude/rules/cpp.md` for build commands and `CLAUDE.md` for the full workflow.

## Dependencies
- Internal: `ball_shared` (shared types + generated protos), `ball_emit_runtime.h` (runtime preamble).
- External: nlohmann/json (via `ball_shared` → `ball_ir.h`). No libprotobuf (#18 Stage 5).
