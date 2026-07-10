---
paths:
  - "cpp/**"
---

# C++ Specific Instructions

## Build System

- C++20 standard required (set in cpp/CMakeLists.txt:4)
- CMake build system — root at `cpp/CMakeLists.txt`
- Primary targets: `ball_shared`, `ball_cpp_compile` (compiler), `ball_cpp_encode` (encoder), `ball` (unified CLI — `cpp/cli/`, issue #367) — plus library targets and test executables (see the `CMakeLists.txt` files)
- Self-hosted engine: `dart/self_host/lib/engine_rt.cpp` (generated from Dart engine via Ball compiler)
- Self-host conformance: `test_selfhost_conformance` target
- Unified `ball` CLI (`cpp/cli/`): subcommands `compile`/`encode` (reuse the compiler/encoder libs), `run` (self-hosted `engine_rt`), and `info`/`validate`/`tree`/`version` (self-hosted `cli_core`, library-compiled to the generated `dart/self_host/lib/cli_rt.h` via `gen_cli_cpp.dart`). Verbs/run gate on their generated artifacts (stubbed when absent, so the build-isolated main cpp CI job still builds `ball`). Parity gate: `test_cli_parity` (see `cpp/cli/AGENTS.md`).
- Encoder requires nlohmann/json (FetchContent from GitHub if not installed)
- Stack sizes: compiler 128MB, encoder 256MB (for deep protobuf ASTs)

```bash
cd cpp/build && cmake .. && cmake --build .
```

## Buf CLI Integration

CMake integrates with `buf` CLI for protobuf code generation, linting, and formatting.

- **`BufGenerate.cmake`** (`cpp/cmake/`) — CMake module providing `buf_generate_cpp()`, `buf_add_lint_target()`, `buf_add_breaking_target()`, `buf_add_format_target()`
- When `buf` is on PATH: protos regenerate into the build tree when `ball.proto` changes
- #18 Stage 5: the C++ build is libprotobuf-free — there is NO C++ protobuf codegen, no `cpp/shared/gen/`, and no cpp plugin in `buf.gen.yaml`. `buf` is used only for proto lint/breaking/format.

### CMake Targets

| Target | Command | Description |
|--------|---------|-------------|
| `buf_lint` | `cmake --build build --target buf_lint` | Lint proto schema |
| `buf_breaking` | `cmake --build build --target buf_breaking` | Check backward compatibility |
| `buf_format` | `cmake --build build --target buf_format` | Check proto formatting |
| `buf_check` | `cmake --build build --target buf_check` | Lint + format in one shot |

### Manual generation (without CMake)

```bash
# From repo root:
# (no C++ codegen since #18 Stage 5 — C++ is libprotobuf-free; buf is proto lint/format only)
```

## Architecture

### Shared (`cpp/shared/`)
- `BallValue` = `std::any` (runtime polymorphism)
- `BallList` = `std::vector<BallValue>`
- `BallMap` = `std::map<std::string, BallValue>` (ORDERED — not unordered_map)
- `BallFunction` = `std::function<BallValue(BallValue)>`
- Module builders: `build_std_module()`, `build_std_memory_module()`, etc.

### Compiler (`cpp/compiler/`)
- Ball → C++ code generation via string concatenation
- Blocks compiled as immediately-invoked lambdas
- Base function dispatch maps std functions to C++ operators/calls
- Type mapping: int → int64_t, double → double, String → std::string, List → std::vector<std::any>

### Encoder (`cpp/encoder/`)
- Clang JSON AST → Ball program (`clang -Xclang -ast-dump=json`)
- C++ pointer/reference ops are inlined to universal std/std_memory during encoding (no separate normalizer)
- Recursion limit: 512 for encoder, 10000 for protobuf

### Self-Hosted Engine (`dart/self_host/lib/engine_rt.cpp`)
- Generated from the Dart reference engine via Ball IR → C++ compiler
- Regenerate: `cd dart && dart run compiler/tool/compile_engine_cpp.dart --monolithic`
- Conformance: `ctest -L selfhost` — one CTest test per fixture, each run in its own process (a crash/hang fails only that fixture). Run a single fixture directly: `test_selfhost_conformance <fixture_stem>` (the `BALL_TEST_FILTER=<stem>` env var also works)

## Test Harness

C++ tests live in `cpp/test/test_compiler.cpp`, `cpp/test/test_selfhost_conformance.cpp`, and `cpp/test/test_encoder.cpp` and use a custom `TEST(name)` macro framework (no gtest). Build + run via:

```bash
cd cpp && cmake --build build --target test_compiler test_selfhost_conformance
./build/test/Debug/test_compiler.exe
# Self-host conformance: one CTest test per fixture, each isolated in its own
# process (a crash/hang fails only that fixture). Run all, or a single fixture:
ctest --test-dir build -L selfhost -j4 --output-on-failure
./build/test/Debug/test_selfhost_conformance.exe 01_hello_world
```

**Always add tests alongside every C++ change.** Conformance tests automatically pick up new programs added to `tests/conformance/`.

## When Adding Features

1. Implement in the Dart reference engine first, then regenerate `engine_rt.cpp`
2. Add test cases in `cpp/test/test_compiler.cpp`; conformance tests automatically pick up new programs added to `tests/conformance/`
3. Verify the self-hosted engine passes conformance after regeneration
