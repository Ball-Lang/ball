<!-- Parent: ../AGENTS.md -->

# cpp/test

## Purpose
All C++ test executables: compiler unit tests, encoder unit tests, self-hosted engine conformance, Ball IR tests, snapshot tests, and E2E scripts.

## Key Files
| File | Description |
|------|-------------|
| `test_compiler.cpp` | Compiler unit tests — verifies emitted C++ snippets via `ASSERT_CONTAINS` |
| `test_encoder.cpp` | Encoder tests — hand-crafted minimal ASTs, clang-shaped ASTs, and committed real clang AST fixtures under `tests/fixtures/cpp_ast/` |
| `test_selfhost_conformance.cpp` | Self-hosted engine conformance — runs every `tests/conformance/*.ball.json` through the compiled engine_rt; returns non-zero on any failure |
| `test_ball_ir.cpp` | Tests for the protobuf-free `ball::ir` representation — round-trips the whole conformance corpus through `parseProgramString`/`toJson` |
| `test_ball_ir_descriptor.cpp` | Dedicated coverage for `ball_ir.h`'s hand-rolled `DescriptorProto`/`EnumDescriptorProto` JSON builder (#18 P4) — pins output against golden proto3-JSON via nlohmann equality (the libprotobuf oracle retired with #18 Stage 5) |
| `test_ball_file.cpp` | Direct unit coverage for `ball_file.h`'s self-describing `google.protobuf.Any` envelope reader (malformed/wrong-kind error branches) plus `ball_rt_decode.cpp`'s opaque-payload helpers (`DecodeStructJsonB64`/`DecodeDescriptorProtoJsonB64`/`DecodeEnumDescriptorProtoJsonB64`) via hand-encoded golden wire vectors |
| `test_ball_dyn.cpp` | Direct unit coverage for the compiled-program runtime (`ball_dyn.h`/`ball_emit_runtime.h`): `BallDyn`, `BallOrderedMap`, `BallStringBuffer`, and the `File`/`Directory` std_fs backing — none of this is exercised by test_compiler/test_encoder/test_shared (those drive the compiler/encoder, not the emitted-program runtime) |
| `test_shared.cpp` | Covers `ball_shared.cpp`'s std-module descriptor builders and the `ball_shared.h` value-conversion helpers (`to_int`/`to_string`/`values_equal`/etc.) that compiler-emitted code calls |
| `test_cli.cpp` | Subprocess-invokes the real `ball_cpp_compile`/`ball_cpp_encode` executables — the only coverage for `cpp/{compiler,encoder}/src/main.cpp` |
| `test_e2e.cpp` | End-to-end compile+run tests |
| `test_snapshot.cpp` | Snapshot tests; set `BALL_UPDATE_SNAPSHOTS=1` to rewrite baselines |
| `scope_probe.cpp` | Debugging utility for scope/variable resolution in the engine; not a test binary |
| `quick_e2e.sh` / `full_e2e.sh` / `diff_e2e.sh` | Shell wrappers for E2E test scenarios (`full_e2e.sh` is the `C++ Compiled` conformance leg and ci.yml's per-PR changed-fixture gate) |
| `e2e_fixture_list.h` | The single list of programs `test_e2e.cpp` compiles+builds+runs and `corpus_driver.cpp` compiles — add a new fixture's stem here (after confirming `bash cpp/test/quick_e2e.sh <stem>` passes) |
| `check_e2e_fixture_list.sh` | Drift guard for that list (#63 / #511): fails when a runnable fixture is neither listed nor named in `e2e_fixture_list_known_gaps.txt`. `--self-test` runs 7 synthetic scenarios proving it bites. Wired into ci.yml's always-on `proto` job — no toolchain, sub-second |
| `e2e_fixture_list_known_gaps.txt` | The frozen, ratchet-only backlog of fixtures (the 257-397 band) not yet in the list. The guard also rejects an entry that is already listed or names no fixture, so it can only shrink |

## For AI Agents
- All test files use a **custom `TEST(name)` macro** (defined at the top of each file) — NOT gtest or Catch2. Register tests by defining `TEST(name) { ... }` at file scope; `struct Register_##name` self-registers via constructor.
- `test_selfhost_conformance.cpp` has **no skip-list** — every fixture must pass. It returns `tests_failed > 0 ? 1 : 0` so CTest treats any failure as an error. CTest isolates each fixture in its own subprocess so a crash/hang affects only that fixture.
- Run a single conformance fixture: `./build/test/Debug/test_selfhost_conformance.exe 01_hello_world` or set `BALL_TEST_FILTER=<stem>`.
- Conformance fixtures are in `tests/conformance/*.ball.json` (repo root). New fixtures are picked up automatically — no registration needed.
- Encoder tests use committed Clang AST JSON in `tests/fixtures/cpp_ast/ast/` so clang is not required at test time. Regenerate with the commands in `test_encoder.cpp` header.
- Reference `.claude/rules/cpp.md` for build + ctest invocations and `../AGENTS.md` for full conformance workflow.

## CI time budget + the e2e build knobs (issue #521)

`test_e2e` dominates ci.yml's `cpp` job: it writes ONE scratch CMake project
with an `add_executable` per fixture (~269 targets from `e2e_fixture_list.h`)
and builds it in a nested `cmake --build`. Until #521 that nested build was
serial and uncached — 28 of the Windows job's 32 minutes. Two env knobs, honoured
identically by `test_e2e`, `full_e2e.sh` and `quick_e2e.sh`:

| Env | Meaning |
|-----|---------|
| `BALL_E2E_JOBS` | Fixture compiles to run concurrently. Default: `hardware_concurrency()` / `nproc`. `1` restores the old serial behaviour. |
| `BALL_E2E_LAUNCHER` | Compiler launcher (`ccache`/`sccache`) threaded into the nested configure as `-DCMAKE_{C,CXX}_COMPILER_LAUNCHER` (`test_e2e`) or prefixed to `g++` (the shell harnesses), so an unchanged fixture is a cache hit. Empty/unset = none. |

- CI sets `BALL_E2E_LAUNCHER` on **Linux/macOS only**. CMake honours
  `<LANG>_COMPILER_LAUNCHER` for the Makefile and Ninja generators; the Visual
  Studio (MSBuild) generator ignores it. Measured on main run 33673078770: the
  Windows leg's `Post ccache` reported `Compile requests 0`, so even the parent
  build's launcher is a no-op there. Windows relies on `--parallel` alone.
- `ctest` runs with `-j <runner CPUs> --no-tests=error`. Safe because each CTest
  test is its own process with a distinct temp-path prefix, and because this
  build never registers the `selfhost` label (engine_rt is gitignored, no Dart in
  that job). regression-gates.yml's `C++ Self-Host Tally` — which does register
  them — stays deliberately sequential.
- The `Run tests` step has a **step-level `timeout-minutes`**: 20 (Windows) / 8
  (Linux, macOS), against a pre-fix 28m33s / 12m12s / 9m56s. Treat it as a gate:
  re-measure and update the numbers in the ci.yml comment (with the run id) if
  you change what the step does. Windows is looser by measurement — each fixture
  is a ~278 KB TU pulling 29 standard headers, MSVC needs ~1000s of front-end
  CPU for 269 of them, link is 0.33s each, and the generator is irrelevant (a
  Ninja scratch build measured 590s vs MSBuild's 591s).
  **Size these against the COLD-cache run, not the warm one.** Warm, the
  Linux/macOS step is 11s / 19s; cold it is 5m19s / 4m57s (measured on this
  branch's run 33698642352, `ccache -s`: 22 hits of 292 cacheable calls). Cold
  is blameless and routine — any PR touching the Ball->C++ emitter or
  `cpp/shared/include/ball_dyn.h` changes all ~269 generated TUs, and so does a
  cache eviction or a first run on a new key. 8 min is ~50% over the cold
  number while still failing a regression to the pre-fix 12m12s / 9m56s.
- `test_e2e` prints `Scratch configure:` and `Scratch compile+link:` timings,
  flushed as they happen, so a step killed by its timeout still shows which
  phase it died in.
- In `test_e2e` only the BUILD is parallel; the fixture binaries are still RUN
  one at a time in list order, so stdout diffing stays deterministic. In
  `full_e2e.sh`/`quick_e2e.sh` the compile+run happens in `xargs -P` workers that
  record per-fixture result files, which the parent aggregates in corpus order —
  same counts and same category lists as a serial run.
- Because those two shell harnesses run fixture binaries **concurrently**, each
  worker executes its binary in a private, empty `$W_WORK/<stem>.rundir`. No
  conformance fixture touches the filesystem today (none reference `std_fs` or
  `std_concurrency`), but that would otherwise be a load-bearing invariant
  nothing enforced: the first fixture to write a relative path would have
  raced its peers over a shared CWD. Isolating the working directory removes
  the precondition rather than documenting it — keep it if you touch the
  worker.

### Where each harness is actually exercised

- `test_e2e` — every PR, all three OS legs, via `ctest` in ci.yml's `cpp` job.
- `full_e2e.sh` — the dispatch-only `C++ Compiled` conformance-matrix leg runs
  the whole corpus, but that is push-to-main + weekly. On a PR it runs on the
  Linux leg only: over the added/changed fixtures when there are any, and
  otherwise over a **derived four-fixture smoke** (`C++ compiled e2e — harness
  smoke`). The smoke exists so the harness's own moving parts — worker
  dispatch, `xargs -P`, CWD isolation, corpus-ordered aggregation, the
  dropped-fixture assertion — are covered by a required check instead of only
  by a post-merge leg. Its fixture list is derived from the corpus at run time,
  never hard-coded, so a rename cannot leave a stale stem behind.
- `quick_e2e.sh` / `diff_e2e.sh` — local developer tools; not wired to CI.

### Coverage-preserving assertions

Parallelism must not silently drop a fixture ("0 failed" and "0 ran" look
identical to CTest), so every harness asserts its own count and fails loud:

- `test_e2e` — executed tests must equal `e2e_fixture_list.h` length + 3 inline
  programs (2x std_fs #319, 1x std_time #328); it prints both numbers **and
  writes the same line to `BALL_E2E_COVERAGE_FILE`** (baked in by
  `cpp/test/CMakeLists.txt` as `<build>/test/e2e_coverage.txt`). The file exists
  because `ctest --output-on-failure` prints nothing for a PASSING test, so on a
  green run the number was invisible — and an invisible number is an unchecked
  one. ci.yml deletes it before `ctest`, then its `C++ e2e fixture coverage`
  step prints it and re-derives `expected == executed >= 1`, which also catches
  "`e2e_tests` never ran at all".
- `full_e2e.sh` / `quick_e2e.sh` — a missing or unrecognised worker result file
  is a hard error, and recorded outcomes must equal the selected fixtures.
- `cpp/test/CMakeLists.txt` — the self-host fixture glob is a `FATAL_ERROR` when
  it matches nothing, and logs the registered count at configure time.
- `check_e2e_fixture_list.sh` — the count-preserving assertion one level up: the
  numbers above prove every LISTED fixture ran, and this proves the list itself
  still names every runnable fixture. Without it the list simply stopped growing
  at `399_bytes_literal` and nothing went red (#511). It refuses to report
  success on an empty list or an empty corpus, for the same reason.

## Dependencies
- Internal: `ball_shared`, `compiler` (for compiler tests), `encoder` (for encoder tests), `dart/self_host/lib/engine_rt.cpp` (included directly by the conformance test).
- External: nlohmann/json (libprotobuf is gone since #18 Stage 5 — the C++ build is protobuf-free).
