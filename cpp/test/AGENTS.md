<!-- Parent: ../AGENTS.md -->

# cpp/test

## Purpose
All C++ test executables: compiler unit tests, encoder unit tests, self-hosted engine conformance, Ball IR tests, snapshot tests, and E2E scripts.

## Key Files
| File | Description |
|------|-------------|
| `test_compiler.cpp` | Compiler unit tests — verifies emitted C++ snippets via `ASSERT_CONTAINS` |
| `test_encoder.cpp` | Encoder tests — hand-crafted minimal ASTs, clang-shaped ASTs, and committed real clang AST fixtures under `tests/fixtures/cpp_ast/` |
| `test_selfhost_conformance.cpp` | Self-hosted engine conformance — runs every `tests/conformance/*.ball.json` through the compiled engine_rt; returns non-zero on any failure |
| `test_ball_ir.cpp` | Tests for the protobuf-free `ball::ir` representation |
| `test_e2e.cpp` | End-to-end compile+run tests |
| `test_snapshot.cpp` | Snapshot tests; set `BALL_UPDATE_SNAPSHOTS=1` to rewrite baselines |
| `scope_probe.cpp` | Debugging utility for scope/variable resolution in the engine; not a test binary |
| `quick_e2e.sh` / `full_e2e.sh` / `diff_e2e.sh` | Shell wrappers for E2E test scenarios |

## For AI Agents
- All test files use a **custom `TEST(name)` macro** (defined at the top of each file) — NOT gtest or Catch2. Register tests by defining `TEST(name) { ... }` at file scope; `struct Register_##name` self-registers via constructor.
- `test_selfhost_conformance.cpp` has **no skip-list** — every fixture must pass. It returns `tests_failed > 0 ? 1 : 0` so CTest treats any failure as an error. CTest isolates each fixture in its own subprocess so a crash/hang affects only that fixture.
- Run a single conformance fixture: `./build/test/Debug/test_selfhost_conformance.exe 01_hello_world` or set `BALL_TEST_FILTER=<stem>`.
- Conformance fixtures are in `tests/conformance/*.ball.json` (repo root). New fixtures are picked up automatically — no registration needed.
- Encoder tests use committed Clang AST JSON in `tests/fixtures/cpp_ast/ast/` so clang is not required at test time. Regenerate with the commands in `test_encoder.cpp` header.
- Reference `.claude/rules/cpp.md` for build + ctest invocations and `../AGENTS.md` for full conformance workflow.

## Dependencies
- Internal: `ball_shared`, `compiler` (for compiler tests), `encoder` (for encoder tests), `dart/self_host/lib/engine_rt.cpp` (included directly by the conformance test).
- External: protobuf (`google/protobuf`).
