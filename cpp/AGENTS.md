# C++ Implementation Agents

When working in the C++ codebase:

## Critical Context

- 37 tests exist across engine + compiler (see `cpp/test/`)
- Several features are BROKEN or STUBBED (see below)
- This is prototype-quality code, not production-ready

## Build

```bash
cd cpp/build && cmake .. && cmake --build .
```

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
- Stack sizes: compiler 128MB, encoder 256MB, engine memory 65KB
