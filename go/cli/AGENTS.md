<!-- Parent: ../AGENTS.md -->

# `go/cli` — the `ball` CLI (Go toolchain)

The binary `ball` (module `github.com/ball-lang/ball/go/cli`, entry point
`cmd/ball`): the four core verbs `run` / `compile` / `encode` / `check` over
`go/engine`, `go/compiler`, and `go/encoder` (epic #426 Phase 5), plus the four
self-hosted cli-core verbs `info` / `validate` / `tree` / `version` (issue #570).
The Go sibling of `rust/cli` and `csharp/cli`; narrower than `dart/cli` (no
package-registry commands, no `audit`).

The cli-core verbs do **not** compute their own report text: it comes from
`dart/shared/lib/cli_core.dart` compiled through `go/compiler` into
`compiled/compiled_cli.go`, so every `ball` on every registry prints
byte-identical reports. `tests/cli_core_goldens/` (the canonical golden set,
shared with the Python gate) is the proof.

**Every verb works in every build.** The two generated artifacts this CLI needs —
`go/engine/compiled/compiled_engine.go` (for `run`) and
`go/cli/compiled/compiled_cli.go` (for the cli-core verbs) — are COMMITTED and
carry no build constraint since #586, because `go install` accepts no `-tags` and
the module a proxy serves is the repository at the tag. Before that, a
registry-acquired `ball` could only `compile`/`encode`/`check`.

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
- `compiled/` — `doc.go` + `driver.go` (the exported
  `InfoReport`/`ValidateOk`/`ValidateReport`/`TreeReport`/`VersionLine` wrappers
  over the generated, lowercase Ball function names) + the generated, COMMITTED
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
| `1` | runtime error — a program ran but failed |
| `2` | invalid/unparseable program — bad `.ball.json`/`.ball.pb` shape, Go source `encode` couldn't turn into a program, a loaded program too malformed to compile, `check` found it invalid; also usage errors (unknown command/flag, wrong arg count) |
| `3` | file-not-found / other I/O error reading input or writing `--output` |

## `run`, the cli-core verbs, and why there are no build tags (issue #586)

`run` executes via the self-hosted `go/engine`; `info`/`validate`/`tree`/`version`
delegate to the compiled CLI core in `go/cli/compiled`. Until #586 each half sat
behind a build tag — `selfhost` (inherited from `go/engine` through Go's tag
propagation) and this module's own `clicore` — because both generated files were
gitignored and absent from a fresh checkout. A tag-less build dispatched the verbs
and listed them in `--help`, then failed loud at runtime with a regenerate hint.

That honest failure was still a broken product on the registry channel: **Go's
registry is the git tag**. `go install github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z`
serves the repository AT THAT TAG and gives the user no way to pass `-tags`, so
the published `ball` could only `compile`/`encode`/`check`. Rust and C# keep their
`self_host`/`cli_core` feature gates because crates.io and NuGet regenerate at
publish time; Go has no such step.

So both artifacts are tracked, the tags are gone, and every verb works in every
build — including the `go install`-ed one. The stub/honest-failure files
(`cli_core_stub.go`, the default-build `run_test.go`, `cli_core_default_test.go`)
are gone with them.

A missing or malformed program is still reported FIRST (exit 3 / exit 2): the
verbs load the program before building any report.

`validate` is the PORTABLE report every cli-core `ball` shares; `check` remains
this CLI's own Go-target battery (with the opt-in `-compile` dry run). They
overlap but are not the same verb.

### Regenerating `compiled/compiled_cli.go`

```bash
cd dart && dart run compiler/tool/gen_cli_json.dart   # dart/self_host/cli.ball.{json,pb}
cd ../go/cli && go run ./cmd/regen                    # -> compiled/compiled_cli.go (COMMIT it)
go test ./...                                         # includes the golden-parity gate
```

`cmd/regen` mirrors `go/engine/cmd/regen` exactly — it used to also rewrite the
`//go:build selfhost` constraint `CompileLibrary` stamped onto every emitted
library into `//go:build clicore`; `CompileLibrary` now emits no constraint at
all, so there is nothing left to rewrite.

`compiled_cli.go` is a GENERATED, NEVER-edit, TRACKED file: fix
`dart/shared/lib/cli_core.dart` (then rerun `gen_cli_json.dart`) or `go/compiler`,
rerun the regenerator, and commit the result. ci.yml's `Ball Artifact Freshness`
job regenerates it and `git diff --exit-code`s it — exactly one such gate per
artifact, so do not add a second regeneration pass to the `go` job.

## Build & Test

```bash
cd go/cli
go build ./...   # the `ball` binary + package — every verb, no build tags
go vet ./...
gofmt -l .       # must print nothing
go test ./...    # every verb in-process, the golden `run` cases, the cli-core gate
```

Tests drive each verb in-process through `cli.Run` (helpers in `helpers_test.go`).
`compile_test.go`/`encode_test.go` additionally build the emitted Go with the
**real toolchain** (`goRunSource` — a throwaway module replacing the Ball runtime
with the local `go/runtime`, mirroring `go/compiler`'s `goRun`) and assert on
stdout, proving `compile`/`encode`→`compile` produce Go that actually runs.
`run_golden_test.go` runs whole conformance fixtures through the built CLI and
compares stdout to their committed goldens — the in-repo half of the assertion
`tools/go-module-proxy/smoke.sh` makes against a `go install`-ed binary.

`cli_core_parity_test.go` is the cli-core golden gate: `info` / `validate` /
`tree` over the five-fixture set in `tests/cli_core_goldens/`, byte-compared to
the Dart CLI's own output, with a positive floor on the number of comparisons
made. `version_test.go` is the version drift guard: `moduleVersion`
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
  `shared` (+ indirect `runtime`) at **`v0.2.0`** (the line #586 moved to) and
  carries **no `replace` directives** — `go install` rejects any module whose
  go.mod has one:

  ```
  $ go install github.com/ball-lang/ball/go/cli/cmd/ball@latest   # before the fix
  go: github.com/ball-lang/ball/go/cli/cmd/ball@latest (in github.com/ball-lang/ball/go/cli@v0.0.0-...):
      The go.mod file for the module providing named packages contains one or
      more replace directives. It must not contain directives that would cause
      it to be interpreted differently than if it were the main module.
  ```

  The local pins moved to `go/go.work`'s versioned `replace ... vX.Y.Z => ./<dep>`
  block (go.work is never published). ci.yml's `go` job proves the external path
  every run and **gates** on it — `tools/go-module-proxy/smoke.sh` synthesizes the
  proxy the `go/<module>/vX.Y.Z` tags will produce, builds all six modules in
  isolation, then `go install .../go/cli/cmd/ball@vX.Y.Z` into a clean GOPATH and
  **runs** the binary — `ball run` over two conformance fixtures plus `ball info`
  and `ball version`, byte-compared against the same goldens the in-repo tests
  use (#586). Off the *public* proxy this only works once the six
  `go/<module>/vX.Y.Z` tags for that version are pushed on one commit; until then
  the practical acquisition path is still clone-and-build (#361).

  **`v0.1.0` is not usable and never will be.** Those six tags exist, but they
  predate #586: at that commit the compiled engine and CLI core were gitignored
  and build-tag-gated, so a binary installed from them can only
  `compile`/`encode`/`check`. Go tags are immutable once fetched through
  `proxy.golang.org`/`sum.golang.org` (a moved tag is a checksum mismatch for
  every consumer that already has it), so they are NOT re-cut — **`v0.2.0` is
  the first Go module line that carries the committed artifacts**, and its six
  tags come from `.github/workflows/tag-go-modules.yml`. Move the line only with
  `tools/go-module-proxy/bump_go_modules.sh` (see `go/AGENTS.md`).
