---
paths:
  - "cpp/**"
---

# C++ Specific Instructions

## Build System

- C++17 standard required
- CMake build system — root at `cpp/CMakeLists.txt`
- 3 targets: `ball_shared`, `ball_cpp_compile` (compiler), `ball_cpp_encode` (encoder)
- Self-hosted engine: `dart/self_host/lib/engine_rt.cpp` (generated from Dart engine via Ball compiler)
- Self-host conformance: `test_selfhost_conformance` target
- Encoder requires nlohmann/json (FetchContent from GitHub if not installed)
- Stack sizes: compiler 128MB, encoder 256MB (for deep protobuf ASTs)

```bash
cd cpp/build && cmake .. && cmake --build .
```

## Buf CLI Integration

CMake integrates with `buf` CLI for protobuf code generation, linting, and formatting.

- **`BufGenerate.cmake`** (`cpp/cmake/`) — CMake module providing `buf_generate_cpp()`, `buf_add_lint_target()`, `buf_add_breaking_target()`, `buf_add_format_target()`
- **`buf.gen.cpp.yaml`** (`cpp/`) — C++-only generation template
- When `buf` is on PATH: protos regenerate into the build tree when `ball.proto` changes
- When `buf` is NOT on PATH: falls back to checked-in files in `cpp/shared/gen/`

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
buf generate --template cpp/buf.gen.cpp.yaml -o cpp/shared/gen proto/
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
- Normalizer converts cpp_std pointer ops → safe refs or unsafe std_memory
- Recursion limit: 512 for encoder, 10000 for protobuf

### Self-Hosted Engine (`dart/self_host/lib/engine_rt.cpp`)
- Generated from the Dart reference engine via Ball IR → C++ compiler
- Regenerate: `cd dart && dart run compiler/tool/compile_engine_cpp.dart --monolithic`
- Conformance: `test_selfhost_conformance` (per-fixture isolated runs via `BALL_TEST_FILTER`)

## Known Issues — MUST READ

C++ tests live in `cpp/test/test_compiler.cpp`, `cpp/test/test_selfhost_conformance.cpp`, and `cpp/test/test_encoder.cpp` and use a custom `TEST(name)` macro framework (no gtest). Build + run via:

```bash
cd cpp && cmake --build build --target test_compiler test_selfhost_conformance
./build/test/Debug/test_compiler.exe
# Self-host: use per-fixture isolated runs for reliable count
BALL_TEST_FILTER="01_hello_world" ./build/test/Debug/test_selfhost_conformance.exe
```

**Always add tests alongside every C++ change.** Conformance tests automatically pick up new programs added to `tests/conformance/`.

## When Adding Features

1. Implement in the Dart reference engine first, then regenerate `engine_rt.cpp`
2. Add test cases in `cpp/test/test_compiler.cpp`; conformance tests automatically pick up new programs added to `tests/conformance/`
3. Verify the self-hosted engine passes conformance after regeneration
