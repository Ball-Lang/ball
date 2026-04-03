---
applyTo: "cpp/**"
---

# C++ Specific Instructions

## Build System

- C++17 standard required
- CMake build system — root at `cpp/CMakeLists.txt`
- 4 targets: `ball_shared`, `ball_cpp_runner` (engine), `ball_cpp_compile` (compiler), `ball_cpp_encode` (encoder)
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

### Engine (`cpp/engine/`)
- Tree-walking interpreter with lexical scoping
- Lazy evaluation for control flow (if, for, while)
- FlowSignal for break/continue/return propagation
- 65KB linear memory (heap + stack)

## Known Issues — MUST READ

- **ZERO TESTS**: Always add tests when modifying C++ code
- `string_split`, `string_replace`, `string_replace_all` → emit empty comments (BROKEN)
- `switch` statement compilation is STUBBED
- `try-catch` is simplified (only catches std::exception)
- `std_collections` module: functions declared but NOT implemented in engine
- `std_io` module: functions declared but STUBBED
- Labeled break/continue: tracked but dispatch is rudimentary

## When Adding Features

1. Implement in BOTH compiler AND engine where applicable
2. Add test cases (even though no test framework exists yet — create one)
3. Verify the feature works with the corresponding Dart implementation behavior
4. Check string operations carefully — several are broken/stubbed
