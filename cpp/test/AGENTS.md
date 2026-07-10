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
| `test_ball_ir.cpp` | Tests for the protobuf-free `ball::ir` representation — round-trips the whole conformance corpus through `parseProgramString`/`toJson` |
| `test_ball_ir_descriptor.cpp` | Dedicated coverage for `ball_ir.h`'s hand-rolled `DescriptorProto`/`EnumDescriptorProto` JSON builder (#18 P4) — pins output against golden proto3-JSON via nlohmann equality (the libprotobuf oracle retired with #18 Stage 5) |
| `test_ball_file.cpp` | Direct unit coverage for `ball_file.h`'s self-describing `google.protobuf.Any` envelope reader (malformed/wrong-kind error branches) plus `ball_rt_decode.cpp`'s opaque-payload helpers (`DecodeStructJsonB64`/`DecodeDescriptorProtoJsonB64`/`DecodeEnumDescriptorProtoJsonB64`) via hand-encoded golden wire vectors |
| `test_ball_dyn.cpp` | Direct unit coverage for the compiled-program runtime (`ball_dyn.h`/`ball_emit_runtime.h`): `BallDyn`, `BallOrderedMap`, `BallStringBuffer`, and the `File`/`Directory` std_fs backing — none of this is exercised by test_compiler/test_encoder/test_shared (those drive the compiler/encoder, not the emitted-program runtime) |
| `test_shared.cpp` | Covers `ball_shared.cpp`'s std-module descriptor builders and the `ball_shared.h` value-conversion helpers (`to_int`/`to_string`/`values_equal`/etc.) that compiler-emitted code calls |
| `test_cli.cpp` | Subprocess-invokes the real `ball_cpp_compile`/`ball_cpp_encode` executables — the only coverage for `cpp/{compiler,encoder}/src/main.cpp` |
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
- External: nlohmann/json (libprotobuf is gone since #18 Stage 5 — the C++ build is protobuf-free).
