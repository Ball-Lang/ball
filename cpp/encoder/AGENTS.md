<!-- Parent: ../AGENTS.md -->

# cpp/encoder

## Purpose
Clang JSON AST → Ball program encoder. Consumes the output of `clang -Xclang -ast-dump=json` and emits the protobuf-free plain-struct `ball::ir::Program` (from `cpp/shared/include/ball_ir.h`), routing all C++ constructs through the universal `std`/`std_memory` modules (no `cpp_std`). Serialized to proto3-JSON `.ball.json` via `ball::ir::programToJsonString`. **#18: the encoder links NO libprotobuf/abseil** — cosmetic Struct metadata and DescriptorProto/EnumDescriptorProto payloads are plain `nlohmann::json` (the latter via ball_ir's `descriptor_build` helpers).

## Key Files
| File | Description |
|------|-------------|
| `src/encoder.cpp` | `CppEncoder` implementation — `encode_from_clang_ast()`, AST node dispatch, C++ pointer ops inlined to `std_memory` |
| `src/main.cpp` | CLI entry point (`ball_cpp_encode` binary); invokes `clang -Xclang -ast-dump=json` and pipes result to `CppEncoder` |
| `include/encoder.h` | `CppEncoder` class declaration |

## For AI Agents
- Entry point: `CppEncoder::encode_from_clang_ast(json_str)`. Requires nlohmann/json (FetchContent from GitHub if not installed).
- Unhandled AST nodes are silently dropped (~line 880 in encoder.cpp) — a known gap. See `../AGENTS.md` § Known Broken/Stubbed Features.
- C++ pointer/reference ops are inlined to `std_memory` calls during encoding; there is no separate normalizer pass.
- Recursion limits: 512 for encoder depth, 10 000 for protobuf traversal.
- CMake target: `ball_cpp_encode`. Stack size: 256 MB (for deep Clang ASTs).
- Real Clang AST fixtures live in `tests/fixtures/cpp_ast/ast/*.ast.json`; regenerate with `clang -Xclang -ast-dump=json -fsyntax-only`. Tests run without clang on PATH by using committed fixtures.
- Tests live in `cpp/test/test_encoder.cpp`. Reference `.claude/rules/cpp.md` for build and test commands.

## Dependencies
- Internal: `ball_ir.h` (header-only plain-struct IR, in `cpp/shared/include/`). **No `ball_shared`/protobuf dependency since #18.**
- External: nlohmann/json (AST parsing + IR construction/serialization), Clang toolchain (runtime only — not required to run existing tests).
