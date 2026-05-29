# C++ Implementation Agents

When working in the C++ codebase. The C++ implementation is a **prototype** — Dart is the reference. C++ runs the **self-hosted** engine (`dart/self_host/lib/engine_rt.cpp`, generated from the Dart engine); there is no native C++ engine.

## Critical Context

- The C++ build produces the compiler (`ball_cpp_compile`) and encoder (`ball_cpp_encode`); the engine is the self-hosted `dart/self_host/lib/engine_rt.cpp`
- Tests exist across compiler, encoder, and self-host conformance (see `cpp/test/`)
- Several features are STUBBED or have silent-correctness gaps — tracked in `docs/SELF_HOST_STATUS.md`
- This is prototype-quality code, not production-ready

## Build & Test

Commands: see CLAUDE.md → Build & Test (canonical) and `.claude/rules/cpp.md` for the self-host build/regeneration flow.

**Prefer conformance tests over unit tests.** The conformance suite validates against shared `.ball.json` fixtures — the same programs tested across the Dart, C++ (self-hosted), and TS engines. Unit tests should be minimal.

```bash
cd cpp/build && cmake .. && cmake --build . && ctest --output-on-failure
# Self-host conformance (highest value — validates the self-hosted engine
# against shared fixtures). Use per-fixture isolated runs for a reliable count:
BALL_TEST_FILTER="01_hello_world" ./test/Debug/test_selfhost_conformance.exe
# Compiler / encoder unit tests (use sparingly):
ctest -R compiler_tests
ctest -R encoder_tests
```
- Test files: `cpp/test/test_*.cpp` — each compiles as standalone executable
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

The authoritative, kept-current list of C++/self-host gaps and pass counts lives in
`docs/SELF_HOST_STATUS.md`; the CI floor is in `.github/workflows/regression-gates.yml`.
The compiler/encoder/runtime-emit citations below are stable references into the C++
toolchain (the engine itself is the self-hosted `engine_rt.cpp`, not native C++).

**Compiler (`cpp/compiler/src/compiler.cpp`) — silent-correctness gaps:**
- `for`/`while` in expression context whose body contains `return` or a labeled
  break/continue → stubbed (`// for loop`), dropping the loop. Break/continue-only
  and jump-free bodies emit real loops (~1438). Not currently hit by the
  self-hosted engine, but a latent limitation for arbitrary programs.
- Bytes literals → empty `std::vector<uint8_t>{}` (~437).
- Unknown base functions → emit `/* std.fn */ 0` or a comment (wrong value, no
  error) (module dispatchers ~2018+).
- `string_split`/`string_replace`/`string_replace_all` ARE implemented (~1624/1639/1647).

**Runtime stubs (compile, produce wrong/fake results):**
- `jsonEncode`/`toProto3Json` are not real JSON (`ball_emit_runtime.h`).
- Filesystem ops (`existsSync`/dir list/create, `writeAsBytesSync`) are no-ops.
- `await`/`yield`/`yield_each` are synchronous pass-throughs (no event loop).
- Generic proto `hasXxx`→false, `whichXxx`→"notSet" fallbacks.

**Encoder (`cpp/encoder/src/encoder.cpp`):**
- Silently drops unhandled AST nodes (~880, depth-limit ~781).

**Conformance harness:**
- `cpp/test/test_selfhost_conformance.cpp` ends `return 0` ("don't fail the
  build") and skip-lists a few unpassable fixtures — self-host failures do NOT
  fail this target. Use the per-fixture isolated runs (above) for the real count.

## Architecture Notes

- `BallValue` = `std::any` for runtime polymorphism
- Maps use `std::map` (ordered), NOT `std::unordered_map`
- Encoder uses Clang JSON AST (via `clang -Xclang -ast-dump=json`)
- Normalizer converts `cpp_std` pointer ops to safe/unsafe memory ops
- Compiler stack size: 128MB, Encoder: 256MB, Engine memory: 65KB
- Memory.hpp: typed linear buffer for C/C++ interop
- Ball files (`.ball.json`/`.ball.bin`) are self-describing `google.protobuf.Any`
  envelopes (JSON form carries an `@type` key). Read them via
  `cpp/shared/include/ball_file.h` (`ball::LoadProgram(path)` / `LoadModule(path)`
  / `DecodeProgram(path, content)`), which mirrors `dart/shared/lib/ball_file.dart`.
  NEVER parse a ball file directly into a `Program`/`Module` — the envelope's
  type URL discriminates Program vs Module. Exception: `dart/self_host/engine.ball.pb`
  is a raw (non-Any) `Program` pipeline artifact, read directly by the self-host build.
