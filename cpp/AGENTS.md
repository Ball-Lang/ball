# C++ Implementation Agents

When working in the C++ codebase:

## Critical Context

- **ZERO TESTS exist** — always add tests when modifying code
- Several features are BROKEN or STUBBED (see below)
- This is prototype-quality code, not production-ready

## Build

```bash
cd cpp/build && cmake .. && cmake --build .
```

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
