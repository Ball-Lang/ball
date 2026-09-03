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

### CI time budget + the e2e build knobs (#521)

`ctest` in ci.yml's `cpp` job runs with `-j <runner CPUs> --no-tests=error`, and
its `Run tests` step carries a **step-level `timeout-minutes`: 20 on Windows, 6
on Linux/macOS** (job budget 25), against a pre-fix 28m33s / 12m12s / 9m56s.
Those numbers are a gate, not decoration — a change that puts the fixture
compiles back on one core fails the job. Re-measure and update them (with the
run id, as the workflow comment does) if you change what the step does.

Windows is the outlier by measurement, not assumption: each generated fixture is
a ~278 KB TU pulling 29 standard headers, MSVC needs ~1000s of front-end CPU for
the 269 of them, link is 0.33s per fixture, and the generator is irrelevant (a
Ninja scratch build measured 590s against MSBuild's 591s). Reaching the issue's
aspirational 6-10 min there needs a compiler cache that actually works on
Windows (see below) or a decision to run a subset of the corpus on that leg.

Two env knobs drive the per-fixture compiles; CI sets both, and they work the
same way for `test_e2e`, `full_e2e.sh` and `quick_e2e.sh`:

| Env | Meaning |
|-----|---------|
| `BALL_E2E_JOBS` | Fixture compiles to run concurrently. Default: `hardware_concurrency()` / `nproc`. `1` restores the old serial behaviour. |
| `BALL_E2E_LAUNCHER` | Compiler launcher (`ccache` / `sccache`) for the fixture compiles, so an unchanged fixture is a cache hit. Empty/unset = none. |

`BALL_E2E_LAUNCHER` is set on Linux/macOS **only**. CMake honours
`<LANG>_COMPILER_LAUNCHER` for the Makefile and Ninja generators; the Visual
Studio (MSBuild) generator ignores it, so on Windows it would advertise a cache
that never gets used. (This is not hypothetical: on main run 33673078770 the
Windows leg's own `Post ccache` step reported `Compile requests 0` — the parent
build's `-DCMAKE_CXX_COMPILER_LAUNCHER=sccache` is a no-op there too. Moving that
leg to `-G Ninja` would make both real; it is tracked separately.)

Parallelism must never shrink coverage, so each harness asserts its own count:
`test_e2e` compares executed tests against `e2e_fixture_list.h` + 3 inline
programs, `full_e2e.sh`/`quick_e2e.sh` compare recorded outcomes against the
selected fixtures, and `cpp/test/CMakeLists.txt` fails at configure time if the
self-host fixture glob matches nothing.

### Fast local `test_compiler` without CMake

The full CMake build is 40+ minutes and does not work on native Windows, which
is why C++ work is usually gated on CI alone. `test_compiler` does not need it:
it links only `compiler.cpp`, `ball_shared.cpp` and `ball_rt_decode.cpp`, and the
only generated inputs are the two embed headers. That is a ~2-minute compile
with any C++20 compiler (clang++ works on Windows against the MSVC toolchain),
which turns a 40-minute CI round trip into a local edit/run loop — including
proving a unit test RED before a fix and green after.

```bash
T=$(mktemp -d)                       # scratch: embed headers + the binary
mkdir -p "$T/gen" "$T/include/nlohmann"
cmake -DIN=cpp/shared/include/ball_emit_runtime.h \
      -DOUT="$T/gen/ball_emit_runtime_embed.h" \
      -P cpp/shared/cmake/EmbedRuntimeHeader.cmake
cmake -DIN=cpp/shared/include/ball_dyn.h -DOUT="$T/gen/ball_dyn_embed.h" \
      -DVAR_NAME=BALL_DYN_SOURCE -P cpp/shared/cmake/EmbedRuntimeHeader.cmake
curl -sSL -o "$T/include/nlohmann/json.hpp" \
  https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp

clang++ -std=c++20 -O0 -w \
  -I cpp/compiler/include -I cpp/shared/include -I cpp/shared \
  -I "$T/gen" -I "$T/include" \
  -DBALL_CONFORMANCE_DIR="\"$PWD/tests/conformance\"" \
  cpp/test/test_compiler.cpp cpp/compiler/src/compiler.cpp \
  cpp/shared/src/ball_shared.cpp cpp/shared/ball_rt_decode.cpp \
  -o "$T/test_compiler" && "$T/test_compiler"
```

This covers `test_compiler` only. The compiled-fixture e2e and the self-hosted
engine still need the real build (CI), so it shortens the loop rather than
replacing the gate.

Two CI-plumbing shell tests need no C++ toolchain at all (sub-second, and run in
ci.yml's always-on `proto` job, so they gate every PR):

```bash
bash cpp/test/test_build_cov_floor_parsing.sh   # build-cov-floor.sh's parser + exit codes
bash cpp/test/test_cov_floor_ci_wiring.sh       # that coverage.yml actually RUNS it (#63/#59)
```

## Coverage floors

`cpp/build-cov-floor.sh` owns the per-target line-coverage floors for
cpp/{compiler,encoder,shared}, and since #63/#59 `.github/workflows/coverage.yml`'s
cpp job **invokes it** — its exit code fails the step. The floors are a
regression ratchet derived from CI's own measurement minus a ~2pt variance
buffer, not a completion target (#63's target is 100%). Raise them as tests land;
never lower one to clear a red. The workflow step also asserts each per-target
tracefile is non-empty and that all three targets reported, because the script's
missing-tracefile branch is a deliberate non-fatal SKIP.

A fast, CI-equivalent local measurement (no nested per-fixture g++ builds) is the
`corpus_driver` target wired into `build-cov-build.sh` / `build-cov-run.sh` /
`build-cov-report.sh`. Read the aggregate from `lcov --summary`, never
`lcov --list` — its per-file Rate column is unreliable on a merged tracefile.

**Always add tests alongside every C++ change.** Conformance tests automatically pick up new programs added to `tests/conformance/`.

## When Adding Features

1. Implement in the Dart reference engine first, then regenerate `engine_rt.cpp`
2. Add test cases in `cpp/test/test_compiler.cpp`; conformance tests automatically pick up new programs added to `tests/conformance/`
3. Verify the self-hosted engine passes conformance after regeneration
