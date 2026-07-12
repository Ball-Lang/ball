---
paths:
  - "go/**"
---

# Go-Specific Instructions

Go (epic #426) is a **complete pipeline** — compiler, encoder, self-hosted engine, and the `ball`
CLI (`run`/`compile`/`encode`/`check`, #437) are all in place and tested (the self-hosted cli-core
verbs `info`/`validate`/`tree`/`version` are a deliberate follow-up, not yet ported). The
self-hosted engine runs the whole conformance corpus at **Dart parity** (`Results: 320 passed,
0 failed, 320 total (4 skipped carve-outs)`; the 4 golden-less resource-limit/sandbox fixtures are
documented carve-outs). Always verify maturity against CI (`.github/workflows/ci.yml`'s `go` job —
build/vet/gofmt/test plus the regenerate-then-run self-hosted engine conformance sweep — and the
`go-engine` row in `conformance-matrix.yml`) and `go/AGENTS.md`, not stale prose.

## Build System

- Native `go` works **on Windows** in this dev environment — no WSL needed (unlike Rust/C++). CI
  pins `go-version: "1.25.x"` via `actions/setup-go`; the `go.mod` files declare `go 1.23` (the
  minimum), and the tree is gofmt'd with the 1.25 line.
- The six modules are tied by `go/go.work`: `runtime`, `shared`, `compiler`, `encoder`, `engine`,
  `cli` (module paths `github.com/ball-lang/ball/go/<name>`). Each commits a `go.sum` **except**
  `runtime`, which is Go-stdlib-only (zero external deps).
- **The workspace-root `./...` pattern is invalid** — `go/` is not itself a module, so
  `cd go && go build ./...` fails with "directory prefix . does not contain modules listed in
  go.work". Enumerate the module subdirs instead:

```bash
cd go
go build ./cli/... ./compiler/... ./encoder/... ./engine/... ./runtime/... ./shared/...
go vet   ./cli/... ./compiler/... ./encoder/... ./engine/... ./runtime/... ./shared/...
go test  ./cli/... ./compiler/... ./encoder/... ./engine/... ./runtime/... ./shared/...
gofmt -l cli compiler encoder engine runtime shared    # must print nothing
```

- **gofmt + Windows CRLF gotcha:** on a Windows checkout `gofmt -l` lists *every* `.go` file,
  because the working tree is CRLF (git `text=auto`, `w/crlf`) while gofmt emits LF. This is
  harmless — the git **index** stores LF (`git ls-files --eol` shows `i/lf`), and the LF checkout
  CI runs on is gofmt-clean. Do not "fix" it by rewriting line endings. To check a single file's
  real state, run gofmt on an LF-normalized copy (`tr -d '\r' < f.go | gofmt`).

## Package Structure

- `go/runtime` (package `ballrt`) — the runtime value model (`Value`/`List`/ordered `Map`/`Set`/
  `Function`/`Message`) + base-op helpers (`Add`, `Truthy`, `ToStr`, …) + `Return`/`Break`/
  `Continue`/`Throw`/`Rethrow` flow signals (panic/recover) + the `ball_proto` access patterns, the
  Dart-SDK method surface (dispatched by `CallMethod`), `std_collections`/`std_convert`, and the
  is/as class-hierarchy registry the self-hosted engine calls. **Zero external dependencies** (Go
  stdlib only) so compiled programs build and run offline via a local `replace`.
- `go/shared` (package `ballv1`, under `gen/`) — generated Go protobuf bindings (`buf generate`,
  plugin `buf.build/protocolbuffers/go`); requires `google.golang.org/protobuf`. Never hand-edit.
- `go/compiler` — Ball → Go. Emits Go source as strings (like the C++/Rust compilers, not Dart's
  `code_builder`). Two modes: `Compile` (runnable `package main`) and `CompileLibrary` (a named
  library package — flat funcs, dispatchers, constructors, oneof discriminators — for the
  self-hosted engine). Base-function dispatch is `base_call.go`; `typeDefs[]` emission is
  `type_emit.go`. `cmd/ballgoc` is the front-end.
- `go/encoder` — Go → Ball via `go/parser` + `go/ast` + `go/token`. Routes every construct through
  universal `std`/`std_collections` — **no `go_std` base module**, ever (the Rust encoder's "no
  rust_std" invariant). `cmd/ballgoenc` is the front-end. Test-only dep on `compiler` for the
  round-trip proof.
- `go/engine` — self-hosted engine wrapper (`engine.go`/`loader.go` + the `selfhost`-tagged
  `run_selfhost.go` / untagged `run_stub.go`) driving the generated, gitignored
  `compiled/compiled_engine.go`. `cmd/regen` regenerates it; `conformance/` is the whole-corpus
  sweep. See `go/engine/AGENTS.md`.
- `go/cli` (package `cli`, `cmd/ball`) — the `ball` CLI (#437): `run`/`compile`/`encode`/`check`
  over engine/compiler/encoder (the Go sibling of `rust/cli`/`csharp/cli`; no package-registry
  commands, no `audit`). All logic is in package `cli` (`cli.Run`) so tests exercise every verb
  in-process. `run` inherits the `selfhost` build tag through Go's tag propagation — a default
  build compiles and returns `ErrSelfHostPending` (exit 1) at runtime, never a silent success;
  `-tags selfhost` (after regenerating the compiled engine) executes for real. Exit-code contract
  mirrors `rust/cli` (0 ok / 1 runtime / 2 invalid-or-usage / 3 I/O). See `go/cli/AGENTS.md`.

## Key Patterns

### Compiler

- Every Ball expression compiles to a Go expression evaluating to `ballrt.Value` (uniform, no
  "void" — like the Rust compiler). Go has no block/if/loop **expressions**, so statement-bearing
  constructs are wrapped in an IIFE `func() ballrt.Value { … }()` (the C++ compiler's device).
- All 7 expression node types are handled; the reference name `"input"` is the function parameter
  (invariant #1). Control flow (`if`/`for`/`while`/`for_in`) → **native Go** control flow, evaluated
  lazily (invariant #4); `return`/`break`/`continue`/`throw` → `ballrt` flow signals (panic/recover)
  so they cross IIFE boundaries — loops use `ballrt.RunLoopBody`, function bodies
  `defer ballrt.CatchReturn`.
- **Fail-loud (issue #55):** an unsupported base function / expression shape is a compile error,
  never silent bad code.

### Encoder

- `Encode(source string) (*ballv1.Program, error)` parses Go and walks declarations → statements →
  expressions. **One input, one output** (invariant #1): a 0-param func takes no input; a 1-param
  func keeps its parameter name; a 2+-param call packs args into one anonymous message keyed by the
  callee's real parameter names (read back by the compiler's `paramPrologue`).
- Compound assignment / `++` / `--` desugar to `assign(target, <op>(target, …))` because the Go
  compiler's `std.assign` is a plain store.
- **Fail-loud:** an unsupported construct records an error and `Encode` returns non-nil, never a
  placeholder. Documented deferred gaps (extend the encoder here): top-level type/const/var,
  structs-as-TypeDefinitions, map/set literals + `std_collections` ops, multi-value return/assign,
  `switch`/`defer`/`go`/channels, `fmt.Printf`/`Sprintf` and multi-arg `fmt.Println`.
- The round-trip test (`go/encoder/roundtrip_test.go`) is the proof: Go → Ball → (compile with
  `go/compiler` + `go run`) ≡ running the original Go natively.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++/Rust/C#: compile
  `dart/self_host/engine.ball.json` through `go/compiler` into `compiled/compiled_engine.go`.
- **Status: complete, runs at Dart parity.** `Results: 320 passed, 0 failed, 320 total (4 skipped
  carve-outs)` — the whole conformance corpus, matching Dart byte-for-byte.
- **Build-tag gating.** `compiled_engine.go` is a gitignored artifact absent from a fresh checkout,
  so everything that references it (`driver.go`, `run_selfhost.go`, `conformance/runner.go` +
  `conformance_test.go`) carries `//go:build selfhost`; untagged `doc.go` files keep each package
  non-empty. A default `go build`/`go test` stays green on the wrapper foundation alone; the
  compiled engine only participates under `-tags selfhost`. This is the Go analog of Rust's
  off-by-default `self_host` cargo feature and C#'s `-p:SelfHost=true`.
- **Fix compiled-engine behavior in `go/compiler` (a fix + regen) or `go/runtime` (no regen) —
  NEVER hand-edit `compiled_engine.go`.** Common `go/runtime` families: `ball_proto` access
  patterns (`proto.go`), the Dart-SDK method surface (`methods.go`, via `CallMethod`),
  `std_collections`/set (`collections.go`), `std_convert` (`convert.go`), value unwrapping + the
  is/as class registry (`wrappers.go`).
- **Polymorphic std ops (load-bearing gotcha):** the Dart→Ball encoder is syntactic (no receiver
  types), so `.isEmpty`/`.isNotEmpty` on a List/Map routes to `std.string_is_empty`, and
  `List.contains`/`indexOf` cross-route with the `string_*` family. Those runtime helpers must
  accept both a string and a collection receiver (`StrIsEmpty`, `ListContains`, `ListIndexOf`).

## Regenerate the Self-Hosted Engine

```bash
cd dart && dart run compiler/tool/gen_engine_json.dart   # writes dart/self_host/engine.ball.json
cd ../go/engine && go run ./cmd/regen                     # -> compiled/compiled_engine.go
go test -v -tags selfhost -run TestConformance -timeout 3600s ./conformance/
```

`cmd/regen` prefers `dart/self_host/engine.ball.pb` and falls back to `engine.ball.json` (both
gitignored) — generating just the JSON is enough. **`-v` is REQUIRED** on the sweep: without it
`go test` caches and discards a passing test's stdout, so the `Results:` line (a plain
`fmt.Printf`) never reaches the log — and both CI jobs parse that line. `BALL_FIXTURE=<name>` runs
one fixture; `BALL_DEBUG_STACK=1` crashes on the first panic with a Go origin stack.

## Generated Files — NEVER Edit

- `go/shared/gen/**` — protobuf bindings (`buf generate proto`, plugin
  `buf.build/protocolbuffers/go`, root `buf.gen.yaml`).
- `go/engine/compiled/compiled_engine.go` — gitignored, regenerated via `go run ./cmd/regen`. Only
  participates in the build under `-tags selfhost`.

## Testing

- `go test ./cli/... ./compiler/... ./encoder/... ./engine/... ./runtime/... ./shared/...`
  (default, no tag) runs the compiler end-to-end tests, encoder round-trip tests, runtime unit
  tests, and the CLI's default-build tests (`run`'s honest-failure path), and stays green without
  the gitignored `compiled_engine.go` (its consumers are `selfhost`-gated).
- Prefer extending the compiler/encoder e2e fixtures (or `tests/conformance/*.ball.json`) over
  Go-only unit tests, per the repo-wide "prefer conformance tests" rule.
- `go/engine/conformance/` is the committed `tests/conformance/*.ball.json` runner — the `selfhost`
  `TestConformance` sweep is what CI gates on; quote its `Results:` line, not a hand-maintained
  count.
