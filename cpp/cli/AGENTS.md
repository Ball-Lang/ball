# cpp/cli — the unified `ball` CLI (C++)

A single `ball` binary with subcommands, the C++ analogue of `dart/cli`
(issue #367). Built by `add_subdirectory(cli)` in `cpp/CMakeLists.txt`.

## Subcommands

| Command                         | Backed by                                            |
|---------------------------------|------------------------------------------------------|
| `ball compile <in.ball.json>`   | `ball_cpp_compiler_lib` → C++ source (`cli_compile.cpp`) |
| `ball encode  <clang_ast.json>` | `ball_cpp_encoder_lib` → proto3-JSON Ball (`cli_encode.cpp`) |
| `ball run     <in.ball.json>`   | the self-hosted engine `engine_rt` (`cli_run.cpp`)   |
| `ball info / validate / tree`   | self-hosted `cli_core` (`cli_verbs.cpp` → `cli_rt.h`)|
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

`gen_cli_cpp.dart` extracts the `main` module of `cli.ball.json`, drops
`auditReport` (its capability/termination analyzers are import stubs — audit
stays on #362), and library-compiles it into namespace `cli_core`.

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
over every `tests/conformance/*.ball.json` and asserts byte-identical output vs
the Dart-native goldens from `dart/cli/tool/gen_cli_parity_goldens.dart`. It is
built only when `cli_rt.h` is present.
