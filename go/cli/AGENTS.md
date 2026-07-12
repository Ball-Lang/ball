<!-- Parent: ../AGENTS.md -->

# `go/cli` — the `ball` CLI (Go toolchain)

The binary `ball` (module `github.com/ball-lang/ball/go/cli`, entry point
`cmd/ball`): the four core verbs `run` / `compile` / `encode` / `check` over
`go/engine`, `go/compiler`, and `go/encoder` (epic #426 Phase 5). The Go sibling
of `rust/cli` and `csharp/cli`; narrower than `dart/cli` (no package-registry
commands, no `audit`). The self-hosted cli-core verbs (`info`/`validate`/`tree`/
`version`, compiled from `dart/self_host/cli.ball.json` — what the Rust/C# CLIs
added later) are a deliberate follow-up, not part of Phase 5.

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
- `run.go` / `compile.go` / `encode.go` / `check.go` — one file per verb.

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

## Build & Test

```bash
cd go/cli
go build ./...                     # default build — the `ball` binary + package
go vet ./...
gofmt -l .                         # must print nothing
go test ./...                      # default-build tests (run's honest-failure path)

# Full run execution, after regenerating the compiled engine (go/engine/AGENTS.md):
cd ../engine && go run ./cmd/regen        # writes compiled/compiled_engine.go
cd ../cli && go test -tags selfhost ./... # adds the golden-driven `run` cases
```

Tests drive each verb in-process through `cli.Run` (helpers in `helpers_test.go`).
`compile_test.go`/`encode_test.go` additionally build the emitted Go with the
**real toolchain** (`goRunSource` — a throwaway module replacing the Ball runtime
with the local `go/runtime`, mirroring `go/compiler`'s `goRun`) and assert on
stdout, proving `compile`/`encode`→`compile` produce Go that actually runs. The
`selfhost`-gated `run_selfhost_test.go` runs whole conformance fixtures through
the built CLI and compares stdout to their committed goldens; the default-build
`run_test.go` proves the honest-failure path.

## Known gaps / follow-ups

- No cli-core verbs (`info`/`validate`/`tree`/`version`) yet — the pattern ports
  from `rust/cli`/`csharp/cli` (compile `dart/self_host/cli.ball.json` through
  `go/compiler` in library mode into a gitignored `compiled_cli.go`, gated like
  the engine). A follow-up, out of Phase 5 scope.
- No package-registry commands (`dart/cli`'s `init`/`add`/`resolve`/`publish`) and
  no `ball audit` — same scope boundary as `rust/cli`.
- `check --compile` is a Go-target-specific dry-run compile (opt-in; can false-
  positive on a valid program that hits a documented `go/compiler` scope gap).
- CI wiring is Phase 7 — not added here.
