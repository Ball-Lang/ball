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
of real stubs/silent-correctness gaps. C++ self-host conformance is 144/189
(2026-05-25, after the dynamic-invoke fixes — `apply()` now unwraps the
BallDyn-wrapped callee/arg before the `std::function` type check, and
`Map.values.first` emits `ball_map_values(...).front()` instead of a bogus
`["values"]` key lookup, unblocking 85/203/211 higher-order closures; earlier:
higher-order callback-field fix (`list_any`/`list_all`/etc. read the callback
from `callback`→`function`→`value`); FlowSignal-key / try-finally /
exception-payload / List.filled-unwrap fixes — see docs/SELF_HOST_STATUS.md).

**FIXED 2026-05-24 (kept here as history):**
- FlowSignal early-return loss — was an `arg0` vs `kind` ctor-key mismatch, not
  an IIFE-propagation gap. Fixed (positional ctor args resolve to param names).
- try/finally no longer skips cleanup on the return path and no longer swallows
  exceptions (RAII `make_ball_finally` guard).
- thrown exception payloads are preserved through throw/catch
  (`_ball_make_exception` / `_ball_caught_to_dyn`).

**Silent-correctness bugs (wrong result, no error):**
- `for`/`while` in expression context whose body contains `return` or a labeled
  break/continue → still stubbed (`// for loop`), dropping the loop. Break/
  continue-only and jump-free bodies emit real loops (`compiler.cpp` ~1438).
  NOTE: not currently hit by the self-host engine (0 loop stubs in engine_rt.cpp)
  but a latent limitation for arbitrary programs.
- Bytes literals → empty `std::vector<uint8_t>{}` (`compiler.cpp:437`).
- Unknown base functions → emit `/* std.fn */ 0` or a comment (wrong value, no
  error) (`compiler.cpp` module dispatchers ~2018+).
- Engine `cascade` drops all sections (`engine.cpp:4094`); list `index` has no
  bounds check → UB on out-of-range (`engine.cpp:4084`); `as` cast is a no-op.
- In-place container mutation: program LISTS are now reference-semantic
  (shared_ptr-backed `BallDyn` lists, commit `40ccd74`) — sorts 132–134 + matrix
  83/128/138 pass. MAPS deliberately stay by-value (a shared map creates
  self-referential cycles via `self` → bad_alloc on OOP/map tests); raw-map +
  instance mutation is handled by the existing copy-on-read + writeback. If a
  future map-aliasing case needs it, make ONLY non-instance maps shared.

**Runtime stubs (compile, produce wrong/fake results):**
- `jsonEncode`/`toProto3Json` are not real JSON (`ball_emit_runtime.h:1098`).
- Filesystem ops (`existsSync`/dir list/create, `writeAsBytesSync`) are no-ops.
- `await`/`yield`/`yield_each` are synchronous pass-throughs (no event loop).
- Generic proto `hasXxx`→false, `whichXxx`→"notSet" fallbacks.

**Other:**
- `rethrow` (22) re-raises a generic BallException, losing the original payload;
  typed nested catch dispatch (146) still partial.
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
