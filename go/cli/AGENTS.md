<!-- Parent: ../AGENTS.md -->

# `go/cli` — the `ball` CLI (Go toolchain)

The binary `ball` (module `github.com/ball-lang/ball/go/cli`, entry point
`cmd/ball`): the four core verbs `run` / `compile` / `encode` / `check` over
`go/engine`, `go/compiler`, and `go/encoder` (epic #426 Phase 5), plus the four
self-hosted cli-core verbs `info` / `validate` / `tree` / `version` (issue #570).
The Go sibling of `rust/cli` and `csharp/cli`; narrower than `dart/cli` (no
package-registry commands, no `audit`).

The cli-core verbs do **not** compute their own report text: it comes from
`dart/shared/lib/cli_core.dart` compiled through `go/compiler` into the
gitignored `compiled/compiled_cli.go`, so every `ball` on every registry prints
byte-identical reports. `tests/cli_core_goldens/` (the canonical golden set,
shared with the Python gate) is the proof.

## Layout

All logic lives in package `cli` so the whole CLI is exercisable in-process by
the tests (via `cli.Run`) without spawning a subprocess; `cmd/ball/main.go` is a
thin `os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))`.

- `cli.go` — `Run(args, stdout, stderr) int`: subcommand dispatch, usage, and a
  top-level `recover` that turns any stray compiler/encoder panic into a clean
  exit 2 instead of a Go stack trace.
- `error.go` — `cliError` + the exit-code contract (below); the `ioErr`/
  `parseErr`/`runtimeErr` constructors.
- `flagset.go` — `parseCommand`: parses a subcommand's `flag.FlagSet` allowing
  flags to appear before, after, or interspersed with positionals (Go's `flag`
  alone stops at the first positional), recovering the clap/System.CommandLine
  ergonomics.
- `loader.go` — `loadEngine` (for `run`, via `engine.FromJSON`/`FromBinary`) and
  `loadProgram` (for `compile`/`check`, via `compiler.LoadProgram*` — no engine
  view built). Both sniff `.bin`/`.pb` (binary protobuf, Any-preferred) vs.
  proto3 JSON by extension.
- `serialize.go` — `programToJSON` (`@type`-enveloped proto3 JSON) / `programToBinary`
  (Any-wrapped binary) for `encode`'s output.
- `output.go` — `writeOut` (`-o <file>` vs. stdout) / `printLine`.
- `run.go` / `compile.go` / `encode.go` / `check.go` / `info.go` / `validate.go`
  / `tree.go` / `version.go` — one file per verb. `tree.go` also holds
  `loadCliCoreView`, the shared "parse the one program positional, return its
  proto3-JSON view" helper the three program-taking cli-core verbs use.
- `cli_core_stub.go` (`//go:build !clicore`) / `cli_core_clicore.go`
  (`//go:build clicore`) — the cli-core availability seam (below).
- `compiled/` — `doc.go` (untagged) + `driver.go` (`clicore`; the exported
  `InfoReport`/`ValidateOk`/`ValidateReport`/`TreeReport`/`VersionLine` wrappers
  over the generated, lowercase Ball function names) + the generated, gitignored
  `compiled_cli.go`. The same shape as `go/engine/compiled/`.
- `cmd/regen` — regenerates `compiled/compiled_cli.go` (below).
- `version.go` — `moduleVersion` (the published Go module version, drift-guarded
  against `go.mod` by `version_test.go`) and `toolchainVersion()`, which prefers
  the build-info stamp a `go install …@vX.Y.Z` binary carries.

## `encode -lib` (library mode, issue #537)

`ball encode <source.go>` requires a `func main()`. `ball encode -lib
<source.go>` does not: it routes through `encoder.EncodeLibrary`, the sibling of
Rust's `encode_library` and C#'s `EncodeLibrary`, for the entry-point-less files
every real Go library is made of. The resulting program keeps `entry_module =
"main"` but has an **empty `entry_function`** and is deliberately non-runnable —
`ball check` on it reports `missing entry_function` (exit 2) and `ball run` has
nothing to call. That boundary is the contract, pinned by
`encode_lib_test.go`; never quiet it by synthesising a fake entry function.

**Cross-CLI flag-name asymmetry, on purpose.** Go's `flag` package is
single-dash and this CLI already spells its options `-o`/`-format`, so the flag
is `-lib`. Rust's clap CLI spells the same thing `--lib` and C#'s
System.CommandLine CLI `--library`. The behaviour is identical in all three;
only the spelling follows each ecosystem's convention.

## Exit-code contract

Mirrors the Rust CLI (`rust/cli/src/error.rs`) so the four Go verbs behave
identically:

| Code | Meaning |
|------|---------|
| `0` | success |
| `1` | runtime error — a program ran but failed, or `run` in a build without the self-hosted engine (`ErrSelfHostPending`) |
| `2` | invalid/unparseable program — bad `.ball.json`/`.ball.pb` shape, Go source `encode` couldn't turn into a program, a loaded program too malformed to compile, `check` found it invalid; also usage errors (unknown command/flag, wrong arg count) |
| `3` | file-not-found / other I/O error reading input or writing `--output` |

## `run` and the `selfhost` build tag

`run` executes via the self-hosted `go/engine`, whose compiled-engine driver is
gated behind the `selfhost` build tag (`go/engine`'s `run_selfhost.go` /
`run_stub.go`; the generated `compiled/compiled_engine.go` is a gitignored build
artifact absent from a fresh checkout). Because **Go build tags propagate
through the whole build**, the CLI needs no tag of its own — it just imports
`go/engine` and calls `engine.Run()`:

- **Default build** (`go build ./...`, no tag): `engine.Run()` returns
  `ErrSelfHostPending`, which `run` surfaces as a runtime error (exit 1) carrying
  the "regenerate compiled_engine.go … build with -tags selfhost" message — never
  a silent success, never a broken build.
- **`-tags selfhost`** (after regenerating the compiled engine — see
  `go/engine/AGENTS.md`): `run` executes programs for real.

This is the Go analog of the Rust CLI's `self_host` Cargo feature and C#'s
`-p:SelfHost=true` MSBuild property. `compile`/`encode`/`check` are unaffected by
the tag.

## The cli-core verbs and the `clicore` build tag (issue #570)

`info`/`validate`/`tree`/`version` delegate to the compiled CLI core in
`go/cli/compiled`, gated behind this module's own **`clicore`** build tag —
deliberately **independent of `selfhost`**:

- these verbs never touch the interpreter, so requiring the (much larger,
  engine-bearing) self-host artifact for a pure report call would be wrong;
- it matches Rust's `cli_core` Cargo feature and C#'s `-p:CliCore=true`, both
  separate from their self-host gates;
- the two combine freely: `go build -tags "clicore selfhost" ./cmd/ball`.

Behaviour, exactly like `run`'s:

- **Default build**: the verbs still EXIST — they are dispatched and listed in
  `--help`, so `tools/check_cli_verb_parity.py`'s answer never depends on how the
  binary was built — and fail loud at runtime with exit 1 plus the two commands
  that fix it (`cli_core_stub.go`). Never a silent success, never a build failure.
- **`-tags clicore`** (after `go run ./cmd/regen`): real reports.

A missing or malformed program is still reported FIRST (exit 3 / exit 2): the
verbs load the program before consulting the CLI core, so the build-tag message
can never mask a more specific failure.

`validate` is the PORTABLE report every cli-core `ball` shares; `check` remains
this CLI's own Go-target battery (with the opt-in `-compile` dry run). They
overlap but are not the same verb.

### Regenerating `compiled/compiled_cli.go`

```bash
cd dart && dart run compiler/tool/gen_cli_json.dart   # dart/self_host/cli.ball.{json,pb}
cd ../go/cli && go run ./cmd/regen                    # -> compiled/compiled_cli.go (gitignored)
go test -tags clicore ./...                           # the golden-parity gate
```

`cmd/regen` mirrors `go/engine/cmd/regen` with one addition: `CompileLibrary`
hardcodes `//go:build selfhost` in its emitted header (its only caller until now
was the engine regenerator), so this tool rewrites that single constraint line to
`//go:build clicore` and **fails loud** if the constraint it expects is absent.
Post-processing keeps codegen shared with `go/engine/cmd/regen` untouched — the
same route `ts/compiler` already takes for `compiled_cli.ts`'s export rewrite.

`compiled_cli.go` is a GENERATED, NEVER-edit file: fix
`dart/shared/lib/cli_core.dart` (then rerun `gen_cli_json.dart`) or `go/compiler`
and rerun the regenerator.

## Build & Test

```bash
cd go/cli
go build ./...                     # default build — the `ball` binary + package
go vet ./...
gofmt -l .                         # must print nothing
go test ./...                      # default-build tests (run's + cli-core's honest-failure paths)

# Full run execution, after regenerating the compiled engine (go/engine/AGENTS.md):
cd ../engine && go run ./cmd/regen        # writes compiled/compiled_engine.go
cd ../cli && go test -tags selfhost ./... # adds the golden-driven `run` cases

# The cli-core verbs, after regenerating the compiled CLI core:
cd ../../dart && dart run compiler/tool/gen_cli_json.dart
cd ../go/cli && go run ./cmd/regen
go build -tags clicore ./... && go vet -tags clicore ./...
go test -tags clicore ./...               # adds the golden-parity gate
```

Tests drive each verb in-process through `cli.Run` (helpers in `helpers_test.go`).
`compile_test.go`/`encode_test.go` additionally build the emitted Go with the
**real toolchain** (`goRunSource` — a throwaway module replacing the Ball runtime
with the local `go/runtime`, mirroring `go/compiler`'s `goRun`) and assert on
stdout, proving `compile`/`encode`→`compile` produce Go that actually runs. The
`selfhost`-gated `run_selfhost_test.go` runs whole conformance fixtures through
the built CLI and compares stdout to their committed goldens; the default-build
`run_test.go` proves the honest-failure path.

`cli_core_parity_test.go` (`clicore`) is the cli-core golden gate: `info` /
`validate` / `tree` over the five-fixture set in `tests/cli_core_goldens/`,
byte-compared to the Dart CLI's own output, with a positive floor on the number
of comparisons made. `cli_core_default_test.go` (`!clicore`) is the other half:
every verb exits 1 with an actionable hint, prints nothing, and stays listed in
`--help`. `version_test.go` is the version drift guard (untagged): `moduleVersion`
must match the version `go.mod` requires its intra-repo siblings at, which is what
`tools/go-module-proxy/build_local_proxy.py --print-version` publishes.

Cross-CLI, `tools/check_cli_verb_parity.py` (the always-on `CLI Verb Parity` CI
job) asserts this CLI's `--help` verb set against `tools/cli_verbs.json`, so a
verb silently disappearing here fails even though every Go test would still pass.

## Known gaps / follow-ups

- No package-registry commands (`dart/cli`'s `init`/`add`/`resolve`/`publish`) and
  no `ball audit` — same scope boundary as `rust/cli`. (`cli_core.auditReport`
  itself compiles fine into `compiled_cli.go`; the verb, its options and its
  goldens are a separate slice, declared in `tools/cli_verbs.json`.)
- `check --compile` is a Go-target-specific dry-run compile (opt-in; can false-
  positive on a valid program that hits a documented `go/compiler` scope gap).
- **`go install` needs the module tags pushed** (issue #361). The module *shape*
  is now correct: `go/cli/go.mod` `require`s `compiler`/`encoder`/`engine`/
  `shared` (+ indirect `runtime`) at **`v0.1.0`** and carries **no `replace`
  directives** — `go install` rejects any module whose go.mod has one:

  ```
  $ go install github.com/ball-lang/ball/go/cli/cmd/ball@latest   # before the fix
  go: github.com/ball-lang/ball/go/cli/cmd/ball@latest (in github.com/ball-lang/ball/go/cli@v0.0.0-...):
      The go.mod file for the module providing named packages contains one or
      more replace directives. It must not contain directives that would cause
      it to be interpreted differently than if it were the main module.
  ```

  The local pins moved to `go/go.work`'s versioned `replace ... v0.1.0 => ./<dep>`
  block (go.work is never published). ci.yml's `go` job proves the external path
  every run and **gates** on it — `tools/go-module-proxy/smoke.sh` synthesizes the
  proxy the `go/<module>/v0.1.0` tags will produce, builds all six modules in
  isolation, then `go install .../go/cli/cmd/ball@v0.1.0` into a clean GOPATH and
  runs the binary. Off the *public* proxy this only works once the six
  `go/<module>/v0.1.0` tags are pushed on one commit; until then the practical
  acquisition path is still clone-and-build (#361).
