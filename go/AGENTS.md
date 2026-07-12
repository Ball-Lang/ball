<!-- Parent: ../AGENTS.md -->

# Go (compiler + encoder + engine + runtime; proto bindings)

## Purpose
Ball → Go compiler (Phase 2 of epic #426), the Go → Ball encoder (Phase 3), the
self-hosted Go engine (Phase 4), the `ball` CLI (Phase 5), the Go runtime value
model the compiler targets, and the generated Go protobuf bindings. CI (Phase 7)
is wired — the `go` job in `.github/workflows/ci.yml` plus the `go-engine` row in
`conformance-matrix.yml`, both gating on 320/320 Dart parity.

## Layout (six Go modules, tied by `go/go.work`)
| Dir | Module path | Description |
|-----|-------------|-------------|
| `runtime/` | `github.com/ball-lang/ball/go/runtime` | Package `ballrt`: the runtime value model (`Value`/`List`/ordered `Map`/`Set`/`Function`/`Message`) + base-op helpers (`Add`, `Truthy`, `ToStr`, …) + flow signals (`Return`/`Break`/`Continue`/`Throw`/`Rethrow` via panic/recover) + the `ball_proto` access patterns, Dart-SDK method surface (`CallMethod`), `std_collections`/`std_convert`, and the is/as class-hierarchy registry the self-hosted engine calls. **Zero external dependencies** (Go stdlib only) so compiled programs build and run offline via a local `replace`. |
| `shared/` | `github.com/ball-lang/ball/go/shared` | Generated Go protobuf bindings (package `ballv1`, under `gen/`) — NEVER hand-edit; regenerate with `buf generate`. Requires `google.golang.org/protobuf`. |
| `compiler/` | `github.com/ball-lang/ball/go/compiler` | Ball → Go compiler (string emission, mirroring `rust/compiler` / `csharp/compiler`). Two modes: `Compile` (runnable `package main`) and `CompileLibrary` (a named library package — class members as flat funcs, dispatchers, constructors, oneof discriminators — for the self-hosted engine). `cmd/ballgoc` is a thin front-end. |
| `encoder/` | `github.com/ball-lang/ball/go/encoder` | Go → Ball encoder: `go/parser` + `go/ast` walk emitting a Ball `Program`. Every construct routes through the universal `std` base module — **no `go_std`** (the Rust encoder's "no rust_std" invariant). `cmd/ballgoenc` is a thin front-end. Test-only dependency on `compiler` for the round-trip proof. |
| `engine/` | `github.com/ball-lang/ball/go/engine` | Self-hosted engine (Phase 4): compiles `dart/self_host/engine.ball.json` through `go/compiler` into the gitignored, `selfhost`-tagged `compiled/compiled_engine.go`, driven by a native wrapper (loader + `ball_proto` view). See `go/engine/AGENTS.md`. |
| `cli/` | `github.com/ball-lang/ball/go/cli` | The `ball` CLI (Phase 5): `run`/`compile`/`encode`/`check` over engine/compiler/encoder (`cmd/ball` is the binary). `run` executes via the self-hosted engine, inheriting the `selfhost` build tag through Go's tag propagation (a default build reports a clear rebuild-with-selfhost error). See `go/cli/AGENTS.md`. |

## Build & Test
```bash
cd go/compiler && go build ./... && go vet ./... && go test ./...   # compiler + end-to-end
cd go/encoder  && go build ./... && go vet ./... && go test ./...   # encoder + round-trip
cd go/runtime  && go test ./...                                      # runtime unit tests
gofmt -l go/runtime go/compiler go/encoder                          # must print nothing
cd go/compiler && go run ./cmd/ballgoc   <program.ball.json>        # compile Ball → Go
cd go/encoder  && go run ./cmd/ballgoenc <program.go>               # encode Go → Ball
```
Native `go` (Windows) is used in this environment; WSL `go` works too. Each
module commits a `go.sum` (except `runtime`, which is stdlib-only) so a
`GOWORK=off` per-module build resolves without the workspace.

## Encoder design (see `go/encoder/encoder.go` doc comment)
- `Encode(source string) (*ballv1.Program, error)` parses Go and walks
  declarations → statements → expressions, mapping each to a Ball node. The
  seven-node tree, base-function dispatch, and the one-input convention mirror
  the Rust encoder (`rust/encoder`).
- **One input, one output** (invariant #1): a 0-param func takes no input; a
  1-param func keeps its parameter name (surfaced in `metadata.params`); a
  2+-param call packs its arguments into one anonymous message keyed by the
  callee's real parameter names, which the compiler's `paramPrologue` reads back.
- Control flow (`if`/`for`/`for … range`) encodes to the `std` `if`/`for`/`while`/
  `for_in` base functions with branch bodies as Ball sub-expressions the compiler
  evaluates lazily (invariant #4). Compound assignment / `++` / `--` desugar to
  `assign(target, <op>(target, …))` because the Go compiler's `std.assign` is a
  plain store.
- **Fail-loud** (issue #55): an unsupported construct records an error and Encode
  returns a non-nil error rather than a placeholder. Deferred (documented gaps,
  extend here): top-level type/const/var, structs-as-TypeDefinitions, map/set
  literals and `std_collections` ops (the Phase-2 compiler doesn't lower them
  yet), multi-value return/assignment, `switch`/`defer`/`go`/channels,
  `fmt.Printf`/`Sprintf` and multi-argument `fmt.Println`.
- The round-trip test (`go/encoder/roundtrip_test.go`) is the proof: Go →
  Ball → (compile with `go/compiler` + `go run`) is asserted equal to running the
  original Go natively, for the `testdata/*.go` sources.

## Compiler design (see `go/compiler/compiler.go` doc comment)
- Every Ball expression compiles to a Go expression evaluating to `ballrt.Value`
  (uniform, no "void" — like the Rust compiler). Go has no block/if/loop
  *expressions*, so statement-bearing constructs are wrapped in an IIFE
  `func() ballrt.Value { … }()` (the C++ compiler's device).
- All 7 expression node types are handled; `"input"` is the function parameter
  (invariant #1). Base-function dispatch is `base_call.go`; type emission from
  `typeDefs[]` is `type_emit.go`.
- Control flow (`if`/`for`/`while`/`for_in`) → **native Go** control flow,
  evaluated lazily (invariant #4). `return`/`break`/`continue`/`throw` →
  `ballrt` flow signals (panic/recover) so they cross IIFE boundaries; loops use
  `ballrt.RunLoopBody`, function bodies `defer ballrt.CatchReturn`.
- **Fail-loud** (issue #55): an unsupported base function / expression shape is a
  compile error, never silent bad code.

## Status / deferred
- Compiler runs end-to-end (compile → `go run`): `hello_world`, `fibonacci`, a
  while-loop, and a `for_in` loop (see `go/compiler/compiler_test.go` + `testdata/`).
- Encoder round-trips Go → Ball → (compile + `go run`) ≡ native Go for
  hello_world, an arithmetic case (multi-param func + `:=`), a control-flow case
  (`for`/`if`/`else`/compound-assign/`++`), and a slice + `for … range` case (see
  `go/encoder/roundtrip_test.go` + `testdata/`).
- **Self-hosted engine (Phase 4): complete, at Dart parity** — the compiled
  engine (compiling `dart/self_host/engine.ball.json` through `go/compiler`) runs
  the whole conformance corpus with Dart-identical output
  (`Results: 320 passed, 0 failed, 320 total`; 4 golden-less
  resource-limit/sandbox carve-outs). Behind the off-by-default `selfhost` build
  tag. See `go/engine/AGENTS.md`.
- **CLI (Phase 5): complete** — `go/cli` produces the `ball` binary with the four
  core verbs `run`/`compile`/`encode`/`check` over engine/compiler/encoder.
  `run` inherits the `selfhost` build tag through Go's tag propagation (default
  build reports a clear rebuild-with-selfhost error, exit 1). Tests drive every
  verb in-process, build `compile`/`encode` output with the real toolchain, and
  (under `-tags selfhost`) run conformance fixtures against their goldens. See
  `go/cli/AGENTS.md`.
- **CI (Phase 7): complete / CI-gated** — the `go` job in
  `.github/workflows/ci.yml` (build/vet/gofmt/test across the six modules, then
  regenerate the self-hosted engine and run the conformance sweep gated on 320/320
  Dart parity) plus the `go-engine` row in `conformance-matrix.yml`. Both gate on
  full parity, mirroring the `csharp`/`csharp-engine` jobs. The `go` output on the
  "Detect changed stacks" filter runs the job on `go/**` changes or any self-host
  Dart source change. NB: the selfhost sweep uses `go test -v` — without `-v`,
  `go test` caches and discards a passing test's `Results:` stdout.
- Deferred to a later phase: the self-hosted cli-core verbs
  (`info`/`validate`/`tree`/`version`). Encoder gaps remain (top-level
  types/const/var, structs-as-TypeDefinitions, maps/sets in the encoder path,
  multi-value return/assign, `switch`/`defer`/goroutines, `fmt.Printf`).

## For AI Agents
- Verify maturity against CI (`.github/workflows/ci.yml`), not this prose.
- `go/shared/gen/` is generated — regenerate after proto changes, never hand-edit.
- Follow `.claude/skills/new-ball-language/SKILL.md` for the remaining phases.
