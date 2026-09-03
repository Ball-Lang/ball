# cpp/cli — the unified `ball` CLI (C++)

A single `ball` binary with subcommands, the C++ analogue of `dart/cli`
(issue #367). Built by `add_subdirectory(cli)` in `cpp/CMakeLists.txt`.

## Subcommands

| Command                         | Backed by                                            |
|---------------------------------|------------------------------------------------------|
| `ball compile <in.ball.json>`   | `ball_cpp_compiler_lib` → C++ source (`cli_compile.cpp`) |
| `ball encode  <clang_ast.json>` | `ball_cpp_encoder_lib` → proto3-JSON Ball (`cli_encode.cpp`) |
| `ball run     <in.ball.json>`   | the self-hosted engine `engine_rt` (`cli_run.cpp`)   |
| `ball info / validate / tree / audit` | self-hosted `cli_core` (`cli_verbs.cpp` → `cli_rt.h`)|
| `ball version`                  | `cli_core.versionLine` / single-sourced fallback     |

The standalone `ball_cpp_compile` / `ball_cpp_encode` binaries are **kept** as
thin aliases (they also drive the engine_rt / ball_protobuf `--split` /
`--library` pipelines the end-user `ball compile` does not expose).

## Generated inputs (gitignored, CI-regenerated)

The portable verbs and `run` are **self-hosted**: they execute Ball's own
`cli_core` / engine, so they need artifacts generated from Ball source. All are
`dart/self_host/`-scoped and `.gitignore`d, exactly like `engine_rt.cpp`:

```bash
# 1. cli_core → Ball IR (the portable verbs as a Ball Program)
cd dart && dart run compiler/tool/gen_cli_json.dart        # → cli.ball.json / .pb
# 2. cli_core → callable C++ header (library-compiled via ball_cpp_compile)
cd dart && dart run compiler/tool/gen_cli_cpp.dart          # → lib/cli_rt.h (+ cli_module.ball.json)
# 3. self-hosted engine → C++ (monolithic, matches CI)
cd dart && dart run compiler/tool/compile_engine_cpp.dart --monolithic  # → lib/engine_rt.cpp
```

`gen_cli_cpp.dart` extracts the `main` module of `cli.ball.json` — the whole
module, including `auditReport` — and library-compiles it into namespace
`cli_core`. Its capability/termination analyzers became `part of cli_core.dart`
in #398, so `gen_cli_json.dart` merges them into `main`; they use only
first-order `std`/`std_collections` ops plus `ball_proto` `hasX` presence
accessors (dispatched by `ball_cpp_compile`'s emitted preamble), so `auditReport`
compiles with no undefined references.

**Windows note:** the `ball_cpp_compile` step in those Dart tools runs a native
binary — on Windows-with-WSL builds, run the emit directly in WSL:
`./cpp/build/compiler/ball_cpp_compile <module>.ball.json --library --ns cli_core --out dart/self_host/lib/cli_rt.h`.

## Build gating (why the target always builds)

`CMakeLists.txt` gates each self-hosted piece on its artifact so the target
builds everywhere — including the **build-isolated main cpp CI job** (no Dart,
no generated artifacts):

* `cli_rt.h` present → real verbs (`cli_verbs.cpp`); else fail-loud stub
  (`cli_verbs_stub.cpp`). `version` works either way (single-sourced from
  `dart/cli/pubspec.yaml`).
* `engine_rt.cpp` (or the multi-TU `engine_rt/` + `ball_selfhost_engine`
  object lib) present → real `run` (`cli_run.cpp`); else stub
  (`cli_run_stub.cpp`).

The full CLI (real verbs + `run`) plus the parity gate build in the
`cpp-selfhost-tally` CI job (`.github/workflows/regression-gates.yml`), which
bootstraps Dart + generates the artifacts.

### Getting the real verbs into a Dart-free build (the self-host sidecar)

`cli_rt.h` / `engine_rt.cpp` are emitted by Ball's own compiler from Ball
source, so producing them needs Dart plus a bootstrap `ball_cpp_compile` — a
distribution channel that has neither (vcpkg's sandboxed, network-isolated
build, most of all) used to be permanently stuck on the stubs. It no longer is
(issues #368/#361):

* `.github/workflows/release-cpp.yml` runs the pregeneration once per tag and
  publishes those two files, flat, as the release asset
  **`ball-selfhost-cpp-src-vX.Y.Z.tar.gz`** beside the `ball` binaries.
* `tools/vcpkg-port/ports/ball-lang/portfile.cmake` downloads that asset (the
  default-on `selfhost` feature) and copies it into
  `${SOURCE_PATH}/dart/self_host/lib/` **before** configuring, so the same
  `EXISTS` gates above fire inside vcpkg. `vcpkg install ball-lang[core]` opts
  back out to the compile/encode/version-only build.
* `ci.yml`'s `vcpkg` job pre-generates the sidecar on-runner, *deletes it from
  the checkout*, and then asserts the vcpkg-INSTALLED `ball run` / `ball info`
  against the conformance and cli-parity goldens — so the smoke can only pass
  if the portfile's own download-and-unpack works.

The asset name is written in two places that never meet at runtime;
`tools/vcpkg-port/test/test_selfhost_asset_wiring.sh` (run in the always-on
`Proto Checks` job) pins them against each other, because a rename would
silently cost every future release its verbs rather than failing loudly.

## Link model (one runtime, no ODR clashes)

`cli_verbs.cpp` (`cli_rt.h`) and `cli_run.cpp` (`engine_rt`) each splice the
same **global** BallDyn runtime, but it is entirely `inline`/internal-linkage,
so the two TUs link cleanly. The non-inline `cli_core::*` functions live in
exactly ONE TU (`cli_verbs.cpp`), and the engine's `BallEngine` lives only in
`cli_run.cpp`. `main.cpp` (the dispatcher) includes neither runtime — only
`cli_commands.h`.

## Parity gate

`cpp/test/test_cli_parity.cpp` (the C++ mirror of
`dart/cli/test/cli_core_parity_test.dart`) runs the compiled `cli_core` verbs
(`info`/`validate`/`tree`/`audit`) over every `tests/conformance/*.ball.json` and
asserts byte-identical output vs the Dart-native goldens from
`dart/cli/tool/gen_cli_parity_goldens.dart`. It is built only when `cli_rt.h` is
present. `ball audit` prints the capability + termination report and exits `0`;
the Dart-native `--deny`/`--exit-code`/`--reachable-only`/`--output` policy flags
are a native-only extra, out of scope for the self-hosted verb.
