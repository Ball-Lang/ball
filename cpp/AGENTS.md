# C++ Implementation Agents

**Generated:** 2026-05-05 | **Commit:** e9d2668 | **Branch:** main

When working in the C++ codebase. The C++ implementation is a **prototype** — Dart is the reference.

## Critical Context

- Tests exist across engine + compiler (see `cpp/test/`)
- Several features are BROKEN or STUBBED (see below)
- This is prototype-quality code, not production-ready

## Build

```bash
cd cpp/build && cmake .. && cmake --build .
```

## Test

**Prefer conformance tests over unit tests.** The conformance suite (`test_conformance`, `test_selfhost_conformance`) validates against shared `.ball.json` fixtures — same programs tested across Dart, C++, and TS engines. Unit tests should be minimal.

```bash
cd cpp/build && cmake .. && cmake --build . && ctest --output-on-failure
# Conformance (highest value — validates against shared fixtures):
ctest -R conformance_tests
ctest -R test_selfhost_conformance
# Per-language (use sparingly):
ctest -R engine_tests
ctest -R compiler_tests
ctest -R encoder_tests
```
- Test files: `cpp/test/test_*.cpp` — each compiles as standalone executable
- CTest targets: `conformance_tests`, `engine_tests`, `compiler_tests`, `encoder_tests`, `e2e_tests`, `snapshot_tests`
- Non-registered executables: `test_perf` (benchmarks), `test_selfhost_conformance`
- Conformance fixtures live in `tests/conformance/*.ball.json`
- Stack sizes: compiler 128MB, encoder 256MB, engine memory 65KB
- Snapshot tests rewrite baselines with `BALL_UPDATE_SNAPSHOTS=1`

## Buf CLI Integration

- `cpp/cmake/BufGenerate.cmake` — CMake module for buf CLI operations
- `cpp/buf.gen.cpp.yaml` — C++-only buf generation template
- When buf is available, CMake regenerates C++ protos from ball.proto on change
- Fallback: checked-in `cpp/shared/gen/` files used when buf is not installed
- Extra targets: `buf_lint`, `buf_breaking`, `buf_format`, `buf_check`
- NEVER edit `cpp/shared/gen/` manually — regenerate via `buf generate`

## Known Broken/Stubbed Features

- `string_split`, `string_replace`, `string_replace_all` → emit empty comments in compiler
- `switch` statement compilation → stubbed
- `try-catch` → simplified (only std::exception)
- `std_collections` module in engine → functions declared but unimplemented
- `std_io` module in engine → functions declared but stubbed
- `for_in` loops → not supported in compiler
- Labeled break/continue → tracked but dispatch rudimentary

## Architecture Notes

- `BallValue` = `std::any` for runtime polymorphism
- Maps use `std::map` (ordered), NOT `std::unordered_map`
- Encoder uses Clang JSON AST (via `clang -Xclang -ast-dump=json`)
- Normalizer converts `cpp_std` pointer ops to safe/unsafe memory ops
- Compiler stack size: 128MB, Encoder: 256MB, Engine memory: 65KB
- Memory.hpp: typed linear buffer for C/C++ interop
