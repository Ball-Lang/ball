---
paths:
  - "go/**"
---

# Go-Specific Instructions

Go (epic #426) is a **complete pipeline** — compiler, encoder, self-hosted engine, and the `ball`
CLI (`run`/`compile`/`encode`/`check`, #437) are all in place and tested (the self-hosted cli-core
verbs `info`/`validate`/`tree`/`version` are a deliberate follow-up, not yet ported). The
self-hosted engine runs the whole conformance corpus at **Dart parity** (`Results: 335 passed,
0 failed, 335 total (4 skipped carve-outs)`; the 4 golden-less resource-limit/sandbox fixtures are
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
- **Module shape for external consumers (issue #361).** No module's `go.mod` may carry a `replace`
  directive: the Go module proxy serves a nested module as its OWN directory tree only (never its
  siblings), and `go install` refuses outright — `The go.mod file for the module providing named
  packages contains one or more replace directives.` So the intra-repo dependencies are plain
  `require github.com/ball-lang/ball/go/<dep> v0.1.0` lines, and the local pins live in
  **`go/go.work`** instead, as versioned replaces:

  ```
  replace (
  	github.com/ball-lang/ball/go/compiler v0.1.0 => ./compiler
  	…
  )
  ```

  A `use` block alone is **not** enough — Go still loads the module graph, so a `require` on a
  version that is not yet on the proxy fails with `unknown revision go/<m>/v0.1.0` even for a
  module that is itself in the workspace (verified with go 1.25). `go.work` is never published, so
  the go.mod files stay proxy-clean. **Never re-add a `replace` to a `go/*/go.mod`.**
- **The gate: `tools/go-module-proxy/smoke.sh`** (run by ci.yml's `go` job, gating). It synthesizes
  the exact `file://` module proxy the `go/<module>/v0.1.0` tags will produce — from the tracked
  files of the current commit, so the module hashes match what proxy.golang.org will compute — then
  (leg 1) builds every module standalone with no `go.work` and no siblings and (leg 2) runs
  `go install github.com/ball-lang/ball/go/cli/cmd/ball@v0.1.0` into a clean GOPATH/GOMODCACHE and
  executes the installed binary. Run it locally after touching any `go.mod`/`go.work`; it needs
  `go` + `python3` and no network beyond the public proxy for `google.golang.org/protobuf`.
- **Both legs use a FRESH `GOMODCACHE`** — do not "simplify" that away. The intra-repo modules
  always resolve at the same version string (`v0.1.0` names a tag, not a commit), so a warm module
  cache holding `go/<m>@v0.1.0` from an earlier run serves the OLD content and the sweep measures
  stale code: a false red when the tree just gained an API the cached copy lacks, and — the
  dangerous direction — a false green when a change breaks external resolution but the cached copy
  still builds. `actions/setup-go` restores `GOMODCACHE` across CI runs keyed only on the committed
  `go.sum` files, so this bit CI as well as local runs (found while landing #537).
- **Bumping the module version is one edit in two files, and the smoke asserts they agree.**
  `build_local_proxy.py` (which `smoke.sh` runs first) refuses unless every intra-repo `require`
  names the same version, no `go.mod` carries a `replace`, and `go/go.work`'s versioned pins name
  that same version and cover every required module — e.g.
  `go/go.work's replace pins disagree with the go.mod requires; bump both in lockstep:
  go/encoder: go.work pins v0.2.0, go.mod requires v0.1.0`. Without that check a half-bumped
  workspace only fails later, in the `go` job's Build step, as `unknown revision go/<m>/vX.Y.Z`.
- **`go install` off the public proxy needs the tags.** `go/<module>/v0.1.0` for all six modules
  must be pushed on one commit before `go install github.com/ball-lang/ball/go/cli/cmd/ball@go/cli/v0.1.0`
  resolves for a real outside consumer; until then the target is still clone-and-build in practice,
  even though the module shape is now correct and CI proves it (#361). **No `go/` tag exists as of
  v1.64.0.** The tags are cut by `.github/workflows/tag-go-modules.yml`, dispatched from `release.yml`
  on every release; the already-shipped releases need a one-time maintainer backfill
  (`gh workflow run tag-go-modules.yml --ref main`). `tools/release/check_release_dispatch_wiring.sh`
  (ci.yml's `Proto Checks`) pins that dispatch so the channel cannot silently go dead again.
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
- **Library mode (`EncodeLibrary`, issue #537)** — the same walk minus the `func main()`
  requirement, for the entry-point-less files every real Go library is made of; reached from the
  CLI as `ball encode -lib`. Both entry points delegate to the shared private
  `assembleProgram(funcs, entryFunction)`, and `entryFunction` (`"main"` vs. `""`) is the ONLY
  difference, so `Encode`'s output is unchanged. A library-mode `Program` keeps
  `entry_module = "main"` but has an EMPTY `entry_function` and is **deliberately non-runnable**:
  `ball check` reports "missing entry_function". Never paper over that by synthesising a fake
  entry function (the same doctrine `rust/encoder` and `csharp/encoder` state).
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
- **Status: complete, runs at Dart parity.** `Results: 335 passed, 0 failed, 335 total (4 skipped
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

- **Third-party coverage study, Tier A (#493).** `tools/coverage-study/go` (a
  standalone tool module, deliberately OUTSIDE `go/` and out of `go.work` — the six
  modules there are published paths `tools/go-module-proxy/smoke.sh` sweeps) runs
  real pinned modules through `encoder.Encode` -> `compiler.CompileLibrary` ->
  `encoder.Encode`, diffs the declaration inventory with **`go/parser` + `go/ast`
  directly** (never `go/encoder`'s own walk) and checks a second-generation
  fixpoint. Honest first baseline **0/21 clean, 0 files even encoded**: every real
  library file trips the documented top-level `type`/`const`/`var` and
  method-with-receiver gaps. Since #537 the harness carries **no accommodation**:
  it dispatches to `encoder.EncodeLibrary` for an entry-point-less file and
  `encoder.Encode` otherwise, so nothing is synthesized (the empty
  `func main() {}` it used to append is gone). A real `main` is still excluded
  from the inventory, for the separate reason that `CompileLibrary` renames it to
  `ball_main`. `go test ./...` there IS gated
  on every PR in the `go` job; the RUN is the report-only `go-tier-a` job in
  `coverage-study.yml`, which has **no `pull_request:` trigger**. Methodology:
  `tests/conformance/COVERAGE_STUDY.md`.

- `go test ./cli/... ./compiler/... ./encoder/... ./engine/... ./runtime/... ./shared/...`
  (default, no tag) runs the compiler end-to-end tests, encoder round-trip tests, runtime unit
  tests, and the CLI's default-build tests (`run`'s honest-failure path), and stays green without
  the gitignored `compiled_engine.go` (its consumers are `selfhost`-gated).
- Prefer extending the compiler/encoder e2e fixtures (or `tests/conformance/*.ball.json`) over
  Go-only unit tests, per the repo-wide "prefer conformance tests" rule.
- `go/engine/conformance/` is the committed `tests/conformance/*.ball.json` runner — the `selfhost`
  `TestConformance` sweep is what CI gates on; quote its `Results:` line, not a hand-maintained
  count.
- `go/engine/conformance/roundtrip.go` (`go test -v -run TestRoundTrip ./conformance/`) is a
  **measurement-only** sweep (#452 item 3): Ball → Go → Ball → the **Dart** reference engine →
  golden diff. Deliberately **untagged** (it never touches the compiled engine — which is why the
  shared `Result`/`Summary`/`conformanceDir`/`diffDetail` helpers live in the untagged
  `support.go`). Honest baseline **0/321**, expected by construction and mirroring
  `csharp-roundtrip`; gated only on `total >= 1`, never on the failure count. Its CI home is the
  `go-roundtrip` row in `conformance-matrix.yml`, which has **no `pull_request` trigger** — the row
  is absent, not green, on a PR; dispatch the workflow and read the run.
