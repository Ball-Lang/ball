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
