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
- Dart-free distribution channels get the real verbs from the **self-host sidecar** (issues #368/#361): `release-cpp.yml` publishes `dart/self_host/lib/{cli_rt.h,engine_rt.cpp}` as the release asset `ball-selfhost-cpp-src-vX.Y.Z.tar.gz`, and `tools/vcpkg-port/`'s portfile downloads + unpacks it into `${SOURCE_PATH}/dart/self_host/lib/` before configuring (default-on `selfhost` feature; `ball-lang[core]` opts out). Never rename that asset on one side only — `tools/vcpkg-port/test/test_selfhost_asset_wiring.sh` pins both spellings, and a mismatch costs every future release its verbs silently.
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

#### Class-dispatch rules that are easy to get wrong

- **Method-shortcut dispatch is arity-gated (#511).** `compile_method_call`'s 77
  STL/Dart-SDK shortcuts are keyed on the method NAME, so each one carries the
  arity window of the Dart method it stands for (`argc_in(min, max)`); the 33
  names shared with `dart/encoder/lib/encoder.dart`'s `collectionRoutes` reuse
  that table's windows verbatim. A new shortcut MUST get a window, and a window
  MISS must FALL THROUGH (never `return`) so control reaches the user-defined
  class method dispatch below the chain. Too narrow pushes a real std call into
  the generic fallback; too wide re-opens the collision.
- **Shadowed-getter routing is PER CLASS, never program-wide (#515).**
  `shadowed_getter_names_` is a whole-program name set and must not decide a
  dispatch on its own. Use `class_field_shadows_getter` /`class_has_getter` /
  `class_has_own_field`, which are keyed by the SANITIZED bare class name —
  `class_shadowed_fields_`/`class_getters_` are keyed by the QUALIFIED name
  (`"main:B"`), so a lookup with `current_class_name_` silently misses. For an
  external receiver, resolve its class with `static_class_of()` and fall back
  EXPLICITLY when it cannot be proven; never guess "not shadowed".
- **A subclassed class is never passed or returned by value (#516).** C++ struct
  value semantics slice the derived part (vtable included) away. Parameters go
  through `map_param_type()` (`T&` when `class_is_subclassed(T)`), and
  `map_return_type()` emits the concrete class the body provably returns. Both
  are scoped to subclassed classes only — a leaf class keeps by-value emission,
  and nothing is universalized into `BallDyn`.
- **A class-typed FIELD is erased to `BallDyn`; recover it before naming a
  member (#513).** `emit_struct` maps every non-primitive descriptor field to a
  `BallDyn` member, and `map_type` answers `BallDyn` for every `T?`, so a
  receiver that is a class-typed field, or a `T?` local/parameter, is a BallDyn
  at the C++ level even though it holds a struct. Resolve it with
  `receiver_class_of()` (which widens `static_class_of()` with the DECLARED
  types recorded in `local_declared_types_` / `class_field_decl_types_by_sname_`
  and looks past the `std.null_check` a Dart `!` encodes to), ask
  `receiver_is_erased()`, and wrap the receiver in `ball_obj_as<C>(…)` before
  emitting the struct-member or accessor form. The bracket fallback must keep
  reading the untouched BallDyn. The same receiver-scoped proof is what lets a
  field literally named `value` / `fields` / `kind` / `values` take the struct
  path — that four-name skip list exists for map-backed proto-shaped receivers,
  not for a concrete class that declares such a field.
- **`BallDyn` accepts a compiler-emitted struct (#513).** `ball_is_user_struct`
  SFINAEs on the `static __ball_type_name()` every emitted struct carries — no
  standard-library or runtime type has it — so the constructor cannot steal
  overload resolution from the `BallMap` / `BallList` / typed-`std::vector`
  ones. It boxes through `BallUserRef`, so `ball_obj_as<T>` recovers the struct
  and `ball_identical` compares pointers. Without it, `f(root)` into a `Node?`
  (BallDyn) parameter needed two user-defined conversions and did not compile.
- **A constructor body is not always a Block (#513).** `Chain(this.depth) { if
  (…) … }` encodes to a single `std.if` Call. Emit every constructor body
  through `compile_ctor_body()`, never a Block-only loop — the old loops dropped
  a single-expression body silently, so the constructor ran and did nothing. A
  NAMED constructor additionally lowers to a STATIC factory over a local
  `__obj`, so its body needs `ctor_obj_prefix_` set: a bare own-field reference
  has no `this` to resolve against there.
- **An instance creation is a VALUE, not an argument bag (#523).** The Ball
  encoder gives a call's argument bag an EMPTY `typeName` (or a std input
  message name like `PrintInput`); only an instance creation names a user class.
  Check `is_instance_creation_value()` FIRST in `compile_call_arguments` and in
  the `.new` constructor-call path — matching a class's own fields against the
  callee's parameter names places nothing and drops the argument entirely. TS
  fixed the same bug class under #213.
- **A `let` bound to a CALL takes the callee's emitted return type (#524).**
  `map_return_type()` is the single source of truth for that type, #516's
  concrete-class widening included, and it covers a named constructor
  (`static <Class> from(...)`) as well as a top-level function. The only callee
  whose emission does not follow it is a FACTORY constructor (always
  `static BallDyn`). Declaring the local `BallDyn` erases every member;
  declaring it with the callee's *declared* base type slices.

- **`ClassName() = default;` is only emitted when no user constructor ALREADY
  is the zero-argument one (#514).** `emit_struct` synthesises a defaulted
  default constructor so `return ClassName()` compiles in a class that has user
  constructors. When the class's only constructor is itself zero-argument, the
  two declarations collide and g++ rejects the struct with
  "'Flags::Flags()' cannot be overloaded with 'Flags::Flags()'". Only a REAL
  C++ constructor can collide, so the scan skips `is_factory` ones (static
  methods) and named ones (static factories) - a class whose sole constructor is
  `Foo.named(...)` still needs the synthesised default.
- **`Foo.new(x)` is a CONSTRUCTOR TEAR-OFF, not a static method (#531).** The
  Dart encoder emits it as a generic self-carrying call
  (`{function: "new", input: {self: Reference("Foo"), arg0: ...}}`), which the
  `has_self` dispatch routes into `compile_method_call` before either
  constructor path can see it. `sanitize_name("new")` is `new_` (`new` is a C++
  keyword), so the static-dispatch branch emitted `Foo::new_(x)` - a member no
  emitted struct declares. Route `fn == "new"` to plain `Foo(args)` construction
  unless `class_has_factory_new(cls)` (a real `factory Foo.new`, the one shape
  that genuinely compiles to `Foo::new_`). The `throw` arm needs its own branch
  for the same shape: `call.function` is the bare string "new", so the
  `mod:Foo.new` identifier parsing finds no type name and leaves the generic
  "Exception" tag - take it from `self` instead. A BUILT-IN exception
  (`is_builtin_exception_name`) must land its first argument in
  `BallException::fields["message"]`, because a typed catch compiles `e.message`
  to `e.fields.at("message")`; `_ball_make_exception` stores it under `value`
  instead and aborts with `map::at`.

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
its `Run tests` step carries a **step-level `timeout-minutes`: 20 on Windows, 8
on Linux/macOS** (job budget 25), against a pre-fix 28m33s / 12m12s / 9m56s.
Those numbers are a gate, not decoration — a change that puts the fixture
compiles back on one core fails the job. Re-measure and update them (with the
run id, as the workflow comment does) if you change what the step does.

Size them against the **cold**-ccache run, never the warm one. Warm, the
Linux/macOS step is 11s / 19s; cold it is 5m19s / 4m57s (run 33698642352, with
`ccache -s` showing 22 hits of 292 cacheable calls). A cold cache is normal and
blameless — every PR that touches the Ball->C++ emitter or
`cpp/shared/include/ball_dyn.h` changes all ~269 generated TUs, as does a cache
eviction or a first run on a new key — so a budget sized to the warm number
red-lights a required check on an innocent PR.

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

`test_e2e` also writes its count line to `BALL_E2E_COVERAGE_FILE`
(`<build>/test/e2e_coverage.txt`), because `ctest --output-on-failure` prints
nothing for a passing test — the number would otherwise never appear in a green
log. ci.yml deletes that file before `ctest` and re-checks it afterwards
(`C++ e2e fixture coverage`), which also detects "the e2e test never ran".

Both shell harnesses run each fixture binary in a private empty directory, since
they execute fixtures concurrently (`test_e2e` parallelises only the build).
That is what makes concurrent execution safe for a future `std_fs` fixture; do
not drop it.

`full_e2e.sh` gets required-check coverage on every PR: the changed-fixture gate
when a PR touches fixtures, and otherwise a derived four-fixture harness smoke
on the Linux leg. Without one of those, the only thing exercising it is the
dispatch-only `C++ Compiled` matrix leg, which runs after merge.

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
