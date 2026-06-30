<!-- Parent: ../AGENTS.md -->

# cpp/cmake

## Purpose
CMake modules for buf CLI integration and multi-TU self-hosted engine_rt OBJECT library configuration.

## Key Files
| File | Description |
|------|-------------|
| `BufGenerate.cmake` | Provides `buf_generate_cpp()`, `buf_add_lint_target()`, `buf_add_breaking_target()`, `buf_add_format_target()`. Falls back to `cpp/shared/gen/` when buf is not on PATH |
| `BallSelfhostEngine.cmake` | `ball_add_selfhost_engine_target(target_name)` — registers the sharded `engine_rt_shard_*.cpp` files under `dart/self_host/lib/engine_rt/` as a CMake OBJECT library for parallel MSVC/Ninja builds |

## For AI Agents
- `BufGenerate.cmake` is `include()`-ed from `cpp/CMakeLists.txt`. When buf is found, protos regenerate into the build tree on `ball.proto` change; when absent, the checked-in `cpp/shared/gen/` files are used unchanged.
- CMake targets exposed: `buf_lint`, `buf_breaking`, `buf_format`, `buf_check` (lint + format). Invoke via `cmake --build build --target buf_lint` from `cpp/`.
- `BallSelfhostEngine.cmake` is a no-op if `dart/self_host/lib/engine_rt/engine_rt_common.hpp` does not exist (engine_rt not yet generated). Regenerate with `cd dart && dart run compiler/tool/compile_engine_cpp.dart --monolithic` (see `.claude/rules/cpp.md`).
- Do not add new CMake modules here without a matching `include()` in `cpp/CMakeLists.txt`.
- Reference `.claude/rules/cpp.md` for the full buf + self-host regeneration workflow.

## Dependencies
- External: buf CLI (optional — falls back gracefully), CMake ≥ 3.14.
