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

NOTE (2026-05-24): the previous list here was STALE — it claimed `string_split`/
`string_replace`/`switch`/`for_in` were broken, but all are implemented
(`compiler.cpp:1347`, `1362`, `2679`, `2579`). Below is the audited, verified set
of real stubs/silent-correctness gaps. C++ self-host conformance is ~75/175.

**Silent-correctness bugs (wrong result, no error):**
- `if` without `else` and any non-last statement in an EXPRESSION-context block:
  control-flow FlowSignals (return/break/continue) are NOT propagated across the
  block/if IIFE boundary, so an early `return`/`break` is silently swallowed
  (`compiler.cpp` if-handler ~1432, `compile_block` ~854). Statement-context
  `if` is correct (`compile_statement` ~2434). This is the biggest self-host gap.
- `for`/`while` in expression context whose body contains `return` or a labeled
  break/continue → still stubbed (`// for loop`), dropping the loop. Break/
  continue-only and jump-free bodies now emit real loops (`compiler.cpp` ~1438).
- Bytes literals → empty `std::vector<uint8_t>{}` (`compiler.cpp:437`).
- Unknown base functions → emit `/* std.fn */ 0` or a comment (wrong value, no
  error) (`compiler.cpp` module dispatchers ~2018+).
- Engine `cascade` drops all sections (`engine.cpp:4094`); list `index` has no
  bounds check → UB on out-of-range (`engine.cpp:4084`); `as` cast is a no-op.

**Runtime stubs (compile, produce wrong/fake results):**
- `jsonEncode`/`toProto3Json` are not real JSON (`ball_emit_runtime.h:1098`).
- Filesystem ops (`existsSync`/dir list/create, `writeAsBytesSync`) are no-ops.
- `await`/`yield`/`yield_each` are synchronous pass-throughs (no event loop).
- Generic proto `hasXxx`→false, `whichXxx`→"notSet" fallbacks.

**Other:**
- `try-catch` → simplified (only std::exception).
- Labeled break/continue → goto-based, dispatch rudimentary.
- Conformance harness (`cpp/test/test_selfhost_conformance.cpp`) ends `return 0`
  ("don't fail the build") and skip-lists ~9 unpassable fixtures — self-host
  failures do NOT fail CI. Use `cpp/test/run_selfhost_tally.sh` for the real count.
- Encoder silently drops unhandled AST nodes (`encoder.cpp:880`, depth-limit `781`).

## Architecture Notes

- `BallValue` = `std::any` for runtime polymorphism
- Maps use `std::map` (ordered), NOT `std::unordered_map`
- Encoder uses Clang JSON AST (via `clang -Xclang -ast-dump=json`)
- Normalizer converts `cpp_std` pointer ops to safe/unsafe memory ops
- Compiler stack size: 128MB, Encoder: 256MB, Engine memory: 65KB
- Memory.hpp: typed linear buffer for C/C++ interop
