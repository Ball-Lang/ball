<!-- Parent: ../AGENTS.md -->

# cpp/cmake

## Purpose
CMake modules for buf CLI integration.

## Key Files
| File | Description |
|------|-------------|
| `BufGenerate.cmake` | Provides `buf_add_lint_target()`, `buf_add_breaking_target()`, `buf_add_format_target()` (proto lint/format only). `buf_generate_cpp()` remains but is UNUSED since #18 Stage 5 — the C++ build no longer consumes generated `ball.pb.*` |

## For AI Agents
- `BufGenerate.cmake` is `include()`-ed from `cpp/CMakeLists.txt` for its proto lint/breaking/format targets. #18 Stage 5 removed the C++ codegen: `buf_generate_cpp()` is no longer called and `cpp/shared/gen/` is gone (the build is libprotobuf-free).
- CMake targets exposed: `buf_lint`, `buf_breaking`, `buf_format`, `buf_check` (lint + format). Invoke via `cmake --build build --target buf_lint` from `cpp/`.
- There is no self-host CMake module any more. `BallSelfhostEngine.cmake` registered the sharded `engine_rt_shard_*.cpp` files of the multi-TU emit as an OBJECT library; issue #601 deleted that emit (it had never compiled, and `cpp/test/CMakeLists.txt` preferred its output over the engine CI actually builds), so the self-hosted engine is now one plain `dart/self_host/lib/engine_rt.cpp` detected inline by `cpp/test/CMakeLists.txt` and `cpp/cli/CMakeLists.txt`. Regenerate it with `cd dart && dart run compiler/tool/compile_engine_cpp.dart` — no flags (see `.claude/rules/cpp.md`).
- Do not add new CMake modules here without a matching `include()` in `cpp/CMakeLists.txt`.
- Reference `.claude/rules/cpp.md` for the full buf + self-host regeneration workflow.

## Dependencies
- External: buf CLI (optional — falls back gracefully), CMake ≥ 3.14.
