<!-- Parent: ../AGENTS.md -->

# Go (compiler + encoder + engine + runtime; proto bindings)

## Third-party coverage study — Tier A (`tools/coverage-study/go`, issue #493)

A **standalone tool module**, deliberately outside `go/` and out of `go.work`:
the six modules under `go/` are published module paths that
`tools/go-module-proxy/smoke.sh` sweeps and that need release tags, and this is
an internal instrument, so it lives under `tools/` with plain `replace`
directives instead. Run its tests with `cd tools/coverage-study/go && go test
./...` — the module enumerations in the `go` job's Build/Vet/Test steps do NOT
cover it.

It runs pinned third-party modules through `encoder.Encode` →
`compiler.CompileLibrary` → `encoder.Encode`, diffs the declaration inventory
using **`go/parser` + `go/ast` directly** — never `go/encoder`'s own walk — and
checks a second-generation fixpoint.

**No accommodations (since #537).** `go/encoder` now has a real library mode —
`EncodeLibrary`, the sibling of Rust's `encode_library` and C#'s
`EncodeLibrary` — so the harness dispatches on the parsed file: `EncodeLibrary`
for an entry-point-less file (which is every real library file), `Encode` when
it declares a `func main`. Nothing is synthesized.
`TestEntryPointLessFilesAreEncodedThroughLibraryMode` pins that. Until #537
landed, the harness had to append an empty `func main() {}` before encoding —
a disclosed accommodation that measured the missing library mode rather than
construct coverage; it is gone. (A real `func main` is still excluded from the
declaration inventory, for the separate reason that `CompileLibrary` renames it
to `ball_main`.)

Honest first baseline: **0/21 clean, 0 files even encoded** (5 pinned modules,
`tools/coverage-study/packages/go.json`) — every real file trips the documented
top-level `type`/`const`/`var` and method-with-receiver gaps. Do not "improve"
that number by changing the pin list.

`go test ./...` there **is gated on every PR** in ci.yml's `go` job. The RUN is
the `go-tier-a` job in `coverage-study.yml`, which has **no `pull_request:`
trigger**; its row is floored by ratchet in that workflow's `publish` job. Methodology: `tests/conformance/COVERAGE_STUDY.md`.

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
| `encoder/` | `github.com/ball-lang/ball/go/encoder` | Go → Ball encoder: `go/parser` + `go/ast` walk emitting a Ball `Program`. `Encode` (requires `func main()`) and `EncodeLibrary` (#537, entry-point-less library files) share one walk. Every construct routes through the universal `std` base module — **no `go_std`** (the Rust encoder's "no rust_std" invariant). `cmd/ballgoenc` is a thin front-end. Test-only dependency on `compiler` for the round-trip proof. |
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
module commits a `go.sum` (except `runtime`, which is stdlib-only).

### Distribution / module shape (issue #361)

**No `go/*/go.mod` may carry a `replace` directive** — the Go module proxy serves
a nested module as its own directory tree only (never its siblings), and
`go install` refuses a module whose go.mod has one. Each module therefore
`require`s its intra-repo dependencies at the real published version (`v0.1.0`),
and the local pins live in `go/go.work`'s **versioned** `replace ... v0.1.0 =>
./<dep>` block, which is never published. A bare `use` block is not enough: Go
still loads the module graph, so an unpublished `require` fails with
`unknown revision go/<m>/v0.1.0` even inside the workspace.

```bash
bash tools/go-module-proxy/smoke.sh   # the gate ci.yml's `go` job runs
```

It synthesizes the `file://` proxy the `go/<module>/v0.1.0` tags will produce
(from this commit's tracked files, so the module hashes match what
proxy.golang.org will compute), builds each module standalone with no `go.work`
and no siblings, then `go install`s `.../go/cli/cmd/ball@v0.1.0` into a clean
GOPATH and runs the binary. Off the *public* proxy this resolves only once the
six `go/<module>/v0.1.0` tags are pushed on one commit — and **as of v1.64.0 they
have not been**, so `go install …@latest` still does not resolve. Those tags come
from `.github/workflows/tag-go-modules.yml`, which `release.yml` dispatches on
every release (`gh workflow run tag-go-modules.yml --ref vX.Y.Z`); the releases
that shipped before that wiring existed need a one-time maintainer backfill
(`gh workflow run tag-go-modules.yml --ref main`). See `docs/RELEASE.md`'s
"Go modules lane".

**Both legs run against a fresh `GOMODCACHE`** — leg 1 gained one while landing
#537. `v0.1.0` names a tag, not a commit, so a warm module cache already holding
`go/<m>@v0.1.0` serves that older content and the sweep measures stale code: a
false red when the tree just gained an API the cached copy lacks, and a false
green when a change breaks external resolution but the cached copy still builds.
`actions/setup-go` restores `GOMODCACHE` across CI runs keyed only on the
committed `go.sum` files, so this affected CI too. Do not remove it.

Before it builds anything, the script asserts the version story is internally
consistent: every intra-repo `require` names the same version, no `go.mod` has a
`replace`, and `go/go.work`'s versioned pins name that same version and cover
every required module. So a version bump is a single lockstep edit across
`go/*/go.mod` + `go/go.work`, and a half-bump fails here instead of surfacing
later as `unknown revision go/<m>/vX.Y.Z` in the `go` job's Build step.

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
- **Library mode: `EncodeLibrary(source string) (*ballv1.Program, error)`**
  (issue #537) — the same walk as `Encode`, minus the `func main()` requirement,
  for the entry-point-less files every real Go library is made of. Both delegate
  to the shared private `assembleProgram(funcs, entryFunction)`; `entryFunction`
  (`"main"` vs. `""`) is the ONLY difference between them, so `Encode`'s output
  is byte-for-byte what it always was. Reached from the CLI as
  `ball encode -lib`, and from `tools/coverage-study/go`. Mirrors Rust's
  `encode_library` and C#'s `EncodeLibrary`.
  **Deliberately non-runnable:** a library-mode `Program` carries
  `entry_module = "main"` (the module `CompileLibrary` emits) but an EMPTY
  `entry_function`, so `ball check` reports "missing entry_function" and `ball
  run` has nothing to call. That is the documented boundary — nobody should
  later "fix" it by synthesising a fake entry function. `go/encoder/
  library_mode_test.go` pins it, round-tripping the encoded library through
  `CompileLibrary` and `go build`ing the result as a real library package.

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

## Compiler conformance leg (`go/compiler/conformance` + `cmd/ballgoconf`)
The **engine** leg (`go/engine/conformance`, `-tags selfhost`) measures the
self-hosted engine. The **compiler** leg measures a different claim: that
`go/compiler` emits Go that prints the right answer. It compiles every
`tests/conformance/*.ball.json`, builds and runs the emitted Go with the real
toolchain (one throwaway module, one package per fixture, shared build cache,
`GOWORK=off`/`GOPROXY=off`), and byte-compares stdout to the golden.

```bash
cd go/compiler
go run ./cmd/ballgoconf                # whole corpus; prints the Results: line, exit 1 on any failure
go run ./cmd/ballgoconf 101_simple_class   # one fixture, full expected/actual dump
```

- **Honest count**: a fixture the compiler cannot emit is a **failure**, not a
  skip and not a crash — a compiler panic is recovered into that fixture's error
  so it cannot shrink the denominator. Only the 4 golden-less carve-outs skip.
- Per-fixture execution budget (`BALL_TIMEOUT_MS`, default 120 s) and build budget
  (`BALL_BUILD_TIMEOUT_MS`, default 180 s) — each fixture is a separate OS process,
  so a runaway is *killed* (unlike the engine leg's in-process goroutine, which leaks).
- It is a **command, not a test**, so the default `go test ./compiler/...` stays
  fast. `runner_test.go` keeps a positive floor: one fixture must actually pass, and
  an empty sweep is an error (a "0 passed, 0 failed" line must never read as green).
- **A named constructor (`Class.name(args)`) builds** since #527. The Dart encoder
  emits it as a method call whose packed `self` field is a bare
  `reference{name: "Class"}` — a static, syntactic class name, not a value — so
  `compileCall` resolves it at COMPILE time to the class's `Owner__member` impl
  (`selfFieldClassReference` + `namedConstructorImpl`) instead of falling through to
  a bare `from(...)` with no such Go function declared. **Shadowing wins**: a
  binding of that name is a real value and the call stays an ordinary dispatch.
  `indexConstructors` keys `bodyCtorImpl` on the UNNAMED (`new`) constructor only —
  keying every constructor there made the LAST named one win, so `Point(3, 4)` ran
  `Point.constants()`'s body — and a constructor's `metadata.initializers` are now
  applied when it carries a body (`constructorInitializer` lowers a literal value,
  not only the `field = param` shape). Fixtures `436_recursive_ctor_named` and
  `438_ctor_initializer_list_with_body` measure it end to end;
  `go/compiler/named_ctor_test.go` is the PR-gated guard (this leg is a **ratchet**
  on a workflow with no `pull_request:` trigger, so it never was).

## Round-trip conformance leg (`go/engine/conformance/roundtrip.go`, issue #452 item 3)
The third question, after the engine and compiler legs: **can `go/encoder` read
back what `go/compiler` emits?** Per fixture it compiles Ball → Go, re-encodes
that Go source back to Ball, runs the **RE-ENCODED** program on the **Dart
reference engine** (`dart run dart/cli/bin/ball.dart run <file>` — ground truth;
running it on Go's own engine would only prove the pipeline agrees with itself),
and byte-diffs the golden.

```bash
cd go/engine
go test -v -run TestRoundTrip -timeout 3600s ./conformance/   # -v is REQUIRED: see the note above
BALL_FIXTURE=101_simple_class go test -v -run TestRoundTrip ./conformance/
```

- **No `-tags selfhost`**: this leg never touches the compiled engine. That is
  why `Result`/`Summary`/`conformanceDir`/`diffDetail` moved out of the tagged
  `runner.go` into the untagged `support.go` — keep new shared helpers there.
- **Honest baseline `Results: 0 passed, 321 failed, 321 total`** (23
  compile-error, 298 encode-error, measured 2026-09-02). That zero is expected
  BY CONSTRUCTION and is the product: the compiler emits a flat package
  dispatching through `ballrt.*` over `ballrt.Value`, a shape the syntactic
  `go/ast` encoder was never built to re-parse. It mirrors
  `csharp/engine/conformance/RoundTripLeg.cs` exactly. **Do not make it green by
  weakening either side** — raising it is encoder/compiler work.
- Gated only on harness health (`total >= 1`), never on the failure count. Needs
  `dart` on PATH (or `BALL_DART`); it skips loudly rather than reporting a fake
  zero when Dart is missing.
- CI home: the `go-roundtrip` row in `.github/workflows/conformance-matrix.yml`.
  **That workflow has no `pull_request:` trigger**, so the row is ABSENT (not
  green) on a PR — `gh workflow run conformance-matrix.yml --ref <branch>` and
  read the run before merging a change to this leg.

## Status / deferred
- Compiler runs end-to-end (compile → `go run`): `hello_world`, `fibonacci`, a
  while-loop, and a `for_in` loop (see `go/compiler/compiler_test.go` + `testdata/`).
- **Compiler vs the whole corpus (measured, not assumed):**
  `Results: 243 passed, 77 failed, 320 total (4 skipped carve-outs)` via
  `go run ./cmd/ballgoconf`. The engine's 320/320 says nothing about this number —
  they are different legs. Top gaps: unsupported base functions (`std.yield*`,
  `std.labeled`/`std.label`, `std_collections.list_foreach`/`list_reduce`,
  `std.math_is_nan`, `std.type_literal`, `std.symbol`, `std_time.*`), pattern
  matching / switch-expression semantics (~20 wrong-output fixtures), class features
  (getter+setter name collision, named/factory constructors, `super`, statics, enum
  values, mixins), and **assignment to a module-level variable** — those are emitted
  as a lazily-initialized *function* (`func moves(input) Value` + `moves__val`), so a
  write emits `moves = ballrt.Add(moves, 1)`, i.e. an assignment to a package-level
  func (`89_tower_of_hanoi`, `151_recursive_descent_parser` fail to build).
- Encoder round-trips Go → Ball → (compile + `go run`) ≡ native Go for
  hello_world, an arithmetic case (multi-param func + `:=`), a control-flow case
  (`for`/`if`/`else`/compound-assign/`++`), and a slice + `for … range` case (see
  `go/encoder/roundtrip_test.go` + `testdata/`).
- **Self-hosted engine (Phase 4): complete, at Dart parity** — the compiled
  engine (compiling `dart/self_host/engine.ball.json` through `go/compiler`) runs
  the whole conformance corpus with Dart-identical output
  (`Results: 344 passed, 0 failed, 344 total`; 4 golden-less
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
- **cli-core verbs (`info`/`validate`/`tree`/`version`): complete / CI-gated**
  (#570) — compiled from `dart/self_host/cli.ball.pb` through `go/compiler` into
  the gitignored `go/cli/compiled/compiled_cli.go`, behind the off-by-default
  `clicore` build tag (independent of `selfhost`). The `go` job regenerates and
  runs the golden-parity gate against the Dart CLI's own output; the always-on
  `CLI Verb Parity` job checks the verb set itself. See `go/cli/AGENTS.md`.
- Deferred: `ball audit` (the verb + its options and goldens; `auditReport`
  itself already compiles into `compiled_cli.go`). Encoder gaps remain (top-level
  types/const/var, structs-as-TypeDefinitions, maps/sets in the encoder path,
  multi-value return/assign, `switch`/`defer`/goroutines, `fmt.Printf`).

## For AI Agents
- Verify maturity against CI (`.github/workflows/ci.yml`), not this prose.
- `go/shared/gen/` is generated — regenerate after proto changes, never hand-edit.
- Follow `.claude/skills/new-ball-language/SKILL.md` for the remaining phases.
