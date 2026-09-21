---
paths:
  - "go/**"
---

# Go-Specific Instructions

Go (epic #426) is a **complete pipeline** — compiler, encoder, self-hosted engine, and the `ball`
CLI (`run`/`compile`/`encode`/`check`, #437, plus the self-hosted cli-core verbs
`info`/`validate`/`tree`/`version`, #570) are all in place and tested — and since **#586 there are
no build tags**: `go/engine/compiled/compiled_engine.go` and `go/cli/compiled/compiled_cli.go` are
COMMITTED generated artifacts, so every verb works in every build, including the one
`go install` produces. The
self-hosted engine runs the whole conformance corpus at **Dart parity** (`Results: 363 passed,
0 failed, 363 total (4 skipped carve-outs)`; the 4 golden-less resource-limit/sandbox fixtures are
documented carve-outs). Always verify maturity against CI (`.github/workflows/ci.yml`'s `go` job —
build/vet/gofmt/test, the external-consumer module smoke, the cli-core golden gate and the
conformance sweep, all against the committed artifacts — the `Ball Artifact Freshness` job, which
regenerates and diffs those two artifacts, and the `go-engine` row in `conformance-matrix.yml`) and
`go/AGENTS.md`, not stale prose.

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
  `require github.com/ball-lang/ball/go/<dep> v0.2.0` lines (the module line #586 moved to), and
  the local pins live in **`go/go.work`** instead, as versioned replaces:

  ```
  replace (
  	github.com/ball-lang/ball/go/compiler v0.2.0 => ./compiler
  	…
  )
  ```

  A `use` block alone is **not** enough — Go still loads the module graph, so a `require` on a
  version that is not yet on the proxy fails with `unknown revision go/<m>/vX.Y.Z` even for a
  module that is itself in the workspace (verified with go 1.25). `go.work` is never published, so
  the go.mod files stay proxy-clean. **Never re-add a `replace` to a `go/*/go.mod`.**
- **The gate: `tools/go-module-proxy/smoke.sh`** (run by ci.yml's `go` job, gating). It synthesizes
  the exact `file://` module proxy the `go/<module>/vX.Y.Z` tags will produce — from the TRACKED
  files of the current commit, so the module hashes match what proxy.golang.org will compute (and
  so #586's two committed artifacts are inside the zips) — then (leg 1) builds every module
  standalone with no `go.work` and no siblings and (leg 2) runs
  `go install github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z` into a clean GOPATH/GOMODCACHE and
  (leg 2b) EXECUTES the installed binary: `ball run` over conformance fixtures plus `ball info` and
  `ball version`, byte-compared against the in-repo goldens behind a >= 4 execution floor. The
  version is derived from the go.mod files, never spelled. Run it locally after touching any
  `go.mod`/`go.work`; it needs
  `go` + `python3` and no network beyond the public proxy for `google.golang.org/protobuf`.
- **Both legs use a FRESH `GOMODCACHE`** — do not "simplify" that away. The intra-repo modules
  always resolve at the same version string (the module line names a tag, not a commit), so a warm
  module cache holding `go/<m>@vX.Y.Z` from an earlier run serves the OLD content and the sweep measures
  stale code: a false red when the tree just gained an API the cached copy lacks, and — the
  dangerous direction — a false green when a change breaks external resolution but the cached copy
  still builds. `actions/setup-go` restores `GOMODCACHE` across CI runs keyed only on the committed
  `go.sum` files, so this bit CI as well as local runs (found while landing #537).
- **Never bump the module version by hand — run `tools/go-module-proxy/bump_go_modules.sh vX.Y.Z`.**
  The same number lives in NINE places: six `go/*/go.mod` `require` blocks, `go/go.work`'s five
  `replace` pins, `tools/coverage-study/go/go.mod`, and `go/cli/version.go`'s `moduleVersion`
  fallback (unprefixed — what `ball version` prints from a checkout build; `go/cli`'s
  `TestModuleVersionMatchesGoMod` guards it). The script is idempotent, refuses a non-semver
  version, refuses any major >= 2 (the module paths carry no `/vN` suffix, which Go requires from
  v2 on — <https://go.dev/ref/mod#major-version-suffixes>, so the line stays 0.x/1.x until the
  paths are renamed), and re-derives through `build_local_proxy.py --print-version`.
  `tools/test/test_bump_go_modules.sh` (ci.yml's always-on `proto` job) proves it and every
  assertion on a scratch tree.

  `build_local_proxy.py` (which `smoke.sh` runs first) refuses unless every intra-repo `require`
  names the same version, no `go.mod` carries a `replace`, `go/go.work`'s versioned pins name that
  same version and cover every required module, and `go.work`'s `use` block matches the modules on
  disk (`tag_go_modules.sh` enumerates the tags from DISK) — e.g.
  `go/go.work's replace pins disagree with the go.mod requires; bump both in lockstep:
  go/encoder: go.work pins v0.2.0, go.mod requires v0.1.0`. Its `--version` flag is a redundant
  CROSS-CHECK, not an override: it must equal the derived version, so the proxy CI proves is by
  construction the one `tag-go-modules.yml` will publish. Without those checks a half-bumped
  workspace only fails later, in the `go` job's Build step, as `unknown revision go/<m>/vX.Y.Z` —
  or, worse, resolves off the PUBLIC proxy and silently measures released code while reading green.

  Go module tags are **immutable** once fetched through `proxy.golang.org`/`sum.golang.org` (a
  moved tag is a checksum mismatch for every consumer that already has it), so a released line is
  never re-cut in place — a change ships as a NEW version.
- **`go/go.work.sum` is gitignored, not committed.** It holds only "hashes used by the workspace
  that are not in collective workspace modules' go.sum files"
  (<https://go.dev/ref/mod#go-work-sum>); every dependency here is already in a committed `go.sum`,
  and `go build`/`go test`/`go work sync` across all six modules produce no such file at all
  (verified 2026-09-13). It is a derived, machine-local byproduct with no freshness gate, and
  `go.work` is never published.
- **`go install` off the public proxy needs the tags.** `go/<module>/vX.Y.Z` for all six modules
  must be pushed on one commit before `go install github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z`
  resolves for a real outside consumer; until then the target is still clone-and-build in practice,
  even though the module shape is now correct and CI proves it (#361). The `v0.1.0` tags exist but
  predate #586, so a binary installed from them cannot run a program or answer a cli-core verb —
  and they are not re-cut (see the immutability note above). **`v0.2.0` is the first Go module
  line that carries the committed engine and CLI core** (cut on `71724734`, #618).
- **The module VERSION moves on its own now (#361, second half).** It is a `semantic-release`
  version line: `.github/release/go.releaserc.json` (tagFormat `go-modules/vX.Y.Z`, commits
  path-filtered to `go/`) driven by `.github/workflows/go-release.yml`, which `release.yml`
  dispatches on every release (`--ref main`). Its `verifyReleaseCmd` is
  `bump_go_modules.sh --check-next` (legal semver, major < 2, and exactly `semver.inc` of the line
  in the tree — this runs under `--dry-run` too), its `prepareCmd` is the bump itself, and its
  `publishCmd` dispatches `tag-go-modules.yml` at the channel tag **and waits for that run**
  (`tools/release/await_workflow_run.py`, 30 s apart, 20 min budget — #627; a bare
  `gh workflow run` returns on acceptance, so a failed tag cut used to leave the release green).
  It waits for a run **strictly newer** than the newest one on that ref before the dispatch
  (#656) — GitHub creates the new row seconds later, and a manual repair re-dispatch on the same
  channel tag leaves a row whose stale `success` would otherwise answer on the first poll
  — so `tag_go_modules.sh` stays the SINGLE tagging path. Until that landed, tagging was automatic but the version was a human's
  `chore(go):` PR, so every release re-dispatched the tagger and it passed reporting "all six tags
  already exist, nothing to do" while the published line stayed put — the #551 failure one level
  down. `tools/release/check_go_release_wiring.sh` (ci.yml's `Proto Checks`) pins the lane's shape;
  `check_release_dispatch_wiring.sh` still pins the tag-pinned channels and that no workflow
  dispatches the tagger. Rehearse a change with
  `gh workflow run go-release.yml --ref <branch> -f dry_run=true`.
- **Whether the tags are actually SERVED is a separate alarm (#627).** Every guard above is
  static. `.github/workflows/go-freshness.yml` (weekly + dispatch) is the outcome guard: for each
  of the six modules it runs
  `GOWORK=off GOFLAGS=-mod=mod GOPROXY=https://proxy.golang.org go list -m -versions
  github.com/ball-lang/ball/go/<module>` from a scratch directory, and the version **main's**
  go.mod files name must appear in the answer. `GOWORK=off` is load-bearing: run anywhere under
  `go/`, the workspace's `replace` pins resolve the module locally and that command prints the
  module path with an EMPTY version list and exits 0 — which the classifier treats as UNKNOWN
  (a failure), never as an absence. A tag younger than `MAX_LAG_MINUTES` (60) is tolerated;
  `proxy.golang.org`'s index lag was measured at ~25 min. `check_go_freshness.sh --self-test`
  runs on every PR in `Proto Checks`. It is also the only freshness alarm here with a
  `pull_request` trigger, and that is safe *only* because its `paths:` filter names its own two
  files — `check_go_release_wiring.sh` asserts that list as a SET, and
  `check_go_release_wiring.sh --self-test` carries the negative controls (#656). Do not widen it.
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
- `go/engine` — self-hosted engine wrapper (`engine.go`/`loader.go`) driving the generated,
  COMMITTED `compiled/compiled_engine.go`. `cmd/regen` regenerates it; `conformance/` is the
  whole-corpus sweep. See `go/engine/AGENTS.md`.
- `go/cli` (package `cli`, `cmd/ball`) — the `ball` CLI (#437): `run`/`compile`/`encode`/`check`
  over engine/compiler/encoder plus the self-hosted cli-core verbs
  `info`/`validate`/`tree`/`version` (#570) (the Go sibling of `rust/cli`/`csharp/cli`; no
  package-registry commands, no `audit`). All logic is in package `cli` (`cli.Run`) so tests
  exercise every verb in-process. **No build tags** (#586): `run` drives the committed compiled
  engine and the cli-core verbs the committed `compiled/compiled_cli.go`, so a `go install`-ed
  binary — which can pass no `-tags` — runs programs and prints the portable reports. Rust and C#
  keep their `self_host`/`cli_core` gates because crates.io/NuGet regenerate at publish time; Go's
  registry is the git tag itself. Exit-code contract mirrors `rust/cli` (0 ok /
  1 runtime / 2 invalid-or-usage / 3 I/O). See `go/cli/AGENTS.md`.

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

- **`std_collections.list_foreach` compiles to `ballrt.ListForEach`, and the receiver may be a MAP
  (#642).** It had no case at all in `base_call.go`, so 116_map_iteration, 119_nested_maps and
  121_map_from_entries were refused outright — the same shape of gap #597 closed for `list_find`.
  The Dart → Ball encoder is syntactic, so `map.forEach((k, v) => ...)` and
  `list.forEach((e) => ...)` both arrive as `list_foreach` with no receiver type to tell them apart;
  `ballrt.ListForEach`'s map arm passes each entry as one `{key, value, arg0, arg1}` message,
  mirroring the Dart reference engine's own `list_foreach` (`engine_std.dart`) field for field.
  `Map.fromEntries` (`ballrt.MapFromEntries`) landed with it — 121's next blocker once it compiled.
  `go/compiler/list_foreach_test.go` compiles all three fixtures AND runs them against the goldens.

- **`std_collections.list_find` THROWS when nothing matches (#597).** It is Dart's
  `Iterable.firstWhere` WITHOUT `orElse` — what its own declaration in
  `dart/shared/lib/std_collections.dart` says ("Find first:
  list.firstWhere(callback)") and what the Dart reference engine does
  (`engine_std.dart`: `throw StateError('No element')`). Never a `null`/
  `undefined`/empty placeholder, and never an untyped throw: the thrown value
  must carry the type name `StateError` so the program's own `on StateError
  catch` sees it. `tests/conformance/463_list_find_no_match` is the cross-target
  guard; `go/runtime/list_find_contract_test.go` (`ListFind` throws via `dartError`, so the payload is a typed `*Message`) and `go/compiler/list_find_contract_test.go` (compiles the fixture and runs it) is this target's half. See `docs/TESTING_STRATEGY.md` §5b.

- **The declared text sink `std.sink_create` / `sink_write` / `sink_to_string`
  (#630).** A sink is a **`__type__`-tagged, REFERENCE-semantic value** carrying
  its accumulated text under `__buffer__` — never a bare host builder. Two
  properties are normative on every target and both fail SILENTLY when a target
  gets them wrong: `std.type_of(sink)` must answer `"Sink"` (a host builder
  answers its own type name, so a program branching on `type_of` takes a
  different arm per target), and an append performed inside a CALLEE must be
  visible to the caller (a by-value backing loses exactly that append — the
  shape of issue #300). `writeln` desugars to `sink_write` + `"\n"`,
  `writeCharCode` to `sink_write` + `string_from_char_code`, and
  `.length`/`.isEmpty`/`.isNotEmpty` to the existing string ops over
  `sink_to_string`, so three declarations are the whole abstraction. Guards:
  `tests/conformance/466_string_sink` (its `appendWord(out, 'c')` line is the
  reference-semantics leg) plus this target's own tag test — `go/runtime/sink_contract_test.go` and `go/compiler/string_sink_test.go` (which compiles the fixture and RUNS it against the golden).
  Backing: `ballrt.SinkCreate`/`SinkWrite`/`SinkToString` (`go/runtime/sink.go`), over a `*ballrt.Map` — a POINTER, so the callee's append is visible. A `*strings.Builder` would make `TypeOf` answer `Builder`, and a `strings.Builder` VALUE would lose appends outright: Go's own docs say "Do not copy a non-zero Builder".

- **Every Dart `StateError` site goes through `ballrt.stateError` (#616).** Two
  halves, and each site used to get exactly one right: TYPED (a `*Message` tagged
  `StateError`, so `on StateError catch` matches — `ListFirst`/`ListLast`/
  `ListPop` and the `.reduce`/`.firstWhere` method arms used to
  `panic(Thrown{Value: "Bad state: No element"})`, a plain string whose
  runtimeType is `String`), and OBSERVABLE (`ToStr` renders it as Dart's own
  `StateError.toString()`, `Bad state: <message>` — `ListFind` was typed but
  stringified as the bare tag `StateError`). `ops.go`'s `dartErrorToString` is
  that rendering, and its type table is deliberately CLOSED over the names
  `dartError` raises: a user class that merely declares a `message` field is not
  a Dart error and keeps printing its type name.
  `go/runtime/state_error_contract_test.go` +
  `go/compiler/state_error_contract_test.go` are this target's halves.
  See `docs/TESTING_STRATEGY.md` §5b.
- **A caught `TypeError` reads as Dart's own message, and the rendering table is
  CLOSED by a test (#641).** A failed cast pattern raises `TypeError`, and Dart
  spells it
  `type '<runtime type>' is not a subtype of type '<target>' in type cast` —
  naming the VALUE's type first, and with **no** `TypeError: ` prefix, because
  `_TypeError.toString()` IS its message (the odd one out of the four built-ins).
  Every target used to spell `type cast failed: not a <T>` and then render it a
  different way; the canonical form is real Dart's because
  `generate_conformance.dart` builds a golden by RUNNING the fixture's Dart
  source on the SDK. The cast assert lives in `ballrt.CastAssert` (not inlined by
  `go/compiler/pattern.go` any more) and `ops.go`'s `dartErrorToString` gained
  the `TypeError` arm with an EMPTY prefix.
  `tests/conformance/467_caught_type_error_to_string` is the cross-target guard,
  and `tools/check_error_rendering_tables.py` (`Proto Checks`, every PR, with its
  own self-test) is the structural one: it asserts every Dart error name this
  runtime RAISES has an entry in this runtime's table and that every entry's
  prefix equals Dart's. Add a new built-in error here and to that contract in the
  same PR, or the checker fails.

- **A USER-thrown built-in error reads the same on every target, and the table
  is closed on the LITERAL-throw side too (#658).** #641's three checks are all
  keyed on what a runtime RAISES, and that left the commoner path unwatched: a
  program's own `throw StateError('boom')` is built by the COMPILER, not raised
  by any runtime, so nothing observed it. The consequences were target-specific
  and all silent — the Dart REFERENCE engine printed the bare ctor argument
  (`boom`, not `Bad state: boom`), and `ArgumentError`, which Dart spells
  `Invalid argument(s): <message>` and no runtime in the repo raises, was in NO
  target's rendering table at all. `LITERAL_THROWABLE` in
  `tools/check_error_rendering_tables.py` is the new structural half (every
  explicit table must cover `StateError`/`FormatException`/`RangeError`/
  `ArgumentError`, raised or not), and
  `tests/conformance/473_caught_user_thrown_builtin_error` is the observable one:
  untyped catch, typed `on T catch`, a non-matching typed clause that falls
  through, and `.message` read alongside `'$e'` — DIFFERENT strings, so storing
  the prefixed form passes one half and breaks the other.
  This target needed only the `ArgumentError` row: `normalizeThrown`
  (`go/runtime/flow.go`, #615) already aliases `arg0` to `message` at throw
  time. `go/runtime/dart_error_rendering_test.go` and
  `go/compiler/user_thrown_builtin_error_test.go` (which compiles fixture 473
  and RUNS it against the golden) are this target's halves.

- **`try` dispatches EVERY catch clause, in source order (#615).** `compileTry`
  emits one `ballrt.TryCatch` catch closure containing an `if`-chain: an
  `on <Type> catch` clause runs only when `ballrt.CatchMatches(__ex, "<Type>")`
  accepts the thrown value's type tag (matching its FULL `main:StateError` or
  BARE `StateError` spelling, like `_evalLazyTry` in the reference engine), the
  first untyped `catch (e)` is the unconditional fallback, and a clause list
  where every typed clause misses ends in `ballrt.Rethrow()` so an enclosing
  `try` sees the original value. Before #615 only `catches[0]` was compiled — as
  an unconditional catch-all — so `throw StateError(...)` ran an
  `on ArgumentError catch` body: silently wrong output, never an error. The
  dispatch is compiled into the emitted closure on purpose; `ballrt.TryCatch`'s
  `(body, catch, finally)` signature is public API of `go/runtime`.
  `ballrt.Throw` also mirrors `std.throw`'s `arg0` -> `message` rename, so a
  caught `e.message` reads the constructor argument instead of `null`. Guards:
  `tests/conformance/464_typed_catch_clause_dispatch` +
  `146_nested_try_catch_types` (cross-target),
  `go/compiler/catch_clause_dispatch_test.go` and
  `go/runtime/catch_match_test.go`. Those two are what gate the SHAPE: the
  `go-compiler` matrix row is a PR gate since #619, but it is a RATCHET on a
  passing count, and 146's failure sat inside its floor from day one.

- **A constructor's INITIALIZER LIST is applied even when the constructor is BODYLESS (#706).**
  `unnamedCtorImpl` (was `bodyCtorImpl`) records a class's unnamed constructor when it carries a
  body **or** a `metadata.initializers` field entry, and `compileMessageCreation` invokes the impl
  for either; `compileClassMembers` emits the impl under the identical condition (a recorded impl
  that is never emitted is an undefined identifier in the emitted Go). Only the impl reads the
  initializer list; the inline field map beside it knows `metadata.params` and nothing else. So
  `FixedSlice(this.source, int end) : windowSize = end;` used to build an instance carrying the
  plain parameter `end` as a bogus field and no `windowSize` at all, and `slice.windowSize`
  answered `null` — a SILENT wrong answer, not a build failure. Note it is NOT the emitted setter
  shadowing the read, which is what #706 hypothesised: the setter is the free function
  `windowSize(input)` and the read is `ballrt.FieldGet(slice, "windowSize")` — two namespaces that
  never meet, and the bug bites every bodyless constructor with an initializer list, setter or no
  setter. Guard: `go/compiler/final_field_setter_test.go`, over fixture
  `472_initializer_list_field_with_setter`.

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
  structs-as-TypeDefinitions, map/set literals, multi-value return/assign,
  `switch`/`go`/channels, `fmt.Printf`/`Sprintf` and multi-arg `fmt.Println`. The
  `std_collections` ops are no longer among them (#691) — see the inverse-table bullet under
  Testing; nor is `defer`, in the one shape the compiler emits it
  (`defer ballrt.CatchReturn(&__ret)`), though a hand-written `defer` is still refused.
- The round-trip test (`go/encoder/roundtrip_test.go`) is the proof: Go → Ball → (compile with
  `go/compiler` + `go run`) ≡ running the original Go natively.

### Engine

- Self-hosted route only (SKILL.md Phase 4, Option B) — same approach as TS/C++/Rust/C#: compile
  `dart/self_host/engine.ball.json` through `go/compiler` into `compiled/compiled_engine.go`.
- **Status: complete, runs at Dart parity.** `Results: 363 passed, 0 failed, 363 total (4 skipped
  carve-outs)` — the whole conformance corpus, matching Dart byte-for-byte.
- **Committed, untagged (#586).** `compiled_engine.go` is TRACKED and carries no build
  constraint, so a plain `go build`/`go test` — and the binary `go install` produces — drive the
  real engine. Freshness is gated once, by ci.yml's `Ball Artifact Freshness` job
  (regenerate + `git diff --exit-code`), the same contract `ts/engine/src/compiled_engine.ts` has.
  **The regenerator's output must stay byte-reproducible**: anything that emits from a Go map must
  sort or use the proto's repeated-field order (#586 had to fix `compileRecord`, which ranged over
  a map and reordered a record's fields — in the emitted source AND at runtime —
  on every compile; `compileOneofDiscriminators` sorts for the same reason).
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
cd ../go/engine && go run ./cmd/regen                     # -> compiled/compiled_engine.go (COMMIT it)
go test -v -run TestConformance -timeout 3600s ./conformance/
```

`cmd/regen` prefers `dart/self_host/engine.ball.pb` and falls back to `engine.ball.json` (both
gitignored) — generating just the JSON is enough. **`-v` is REQUIRED** on the sweep: without it
`go test` caches and discards a passing test's stdout, so the `Results:` line (a plain
`fmt.Printf`) never reaches the log — and both CI jobs parse that line. `BALL_FIXTURE=<name>` runs
one fixture; `BALL_DEBUG_STACK=1` crashes on the first panic with a Go origin stack.

## Generated Files — NEVER Edit

- `go/shared/gen/**` — protobuf bindings (`buf generate proto`, plugin
  `buf.build/protocolbuffers/go`, root `buf.gen.yaml`).
- `go/engine/compiled/compiled_engine.go` and `go/cli/compiled/compiled_cli.go` — **committed**
  (#586), regenerated via `go run ./cmd/regen` in each module and diffed by ci.yml's
  `Ball Artifact Freshness` job. Regenerate and commit; never hand-edit. Since #619 you rarely run
  the regen locally: on drift that job uploads the regenerated bytes as the `regenerated-artifacts`
  workflow artifact, so `bash tools/ci/apply_regenerated.sh <pr-number>` + `git commit` is the whole
  fix (and with the optional `REGEN_PAT` secret configured, CI pushes that commit itself).

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
  on every PR in the `go` job; the RUN is the `go-tier-a` job in
  `coverage-study.yml`, which has **no `pull_request:` trigger** (its row is
  floored by ratchet in that workflow's `publish` job). Methodology:
  `tests/conformance/COVERAGE_STUDY.md`.

- `go test ./cli/... ./compiler/... ./encoder/... ./engine/... ./runtime/... ./shared/...`
  runs the compiler end-to-end tests, encoder round-trip tests, runtime unit tests, the CLI's
  every-verb tests (including the golden-driven `run` cases and the cli-core parity gate) and the
  whole-corpus engine sweep — no build tags, nothing to regenerate first.
- Prefer extending the compiler/encoder e2e fixtures (or `tests/conformance/*.ball.json`) over
  Go-only unit tests, per the repo-wide "prefer conformance tests" rule.
- `go/engine/conformance/` is the committed `tests/conformance/*.ball.json` runner — the
  `TestConformance` sweep is what CI gates on; quote its `Results:` line, not a hand-maintained
  count.
- `go/engine/conformance/roundtrip.go` (`go test -v -run TestRoundTrip ./conformance/`) is a
  measurement sweep (#452 item 3): Ball → Go → Ball → the **Dart** reference engine →
  golden diff (it needs `dart` on PATH and skips loudly without it; the shared
  `Result`/`Summary`/`conformanceDir`/`diffDetail` helpers live in `support.go`). It measured a
  flat **0/321** from the day it shipped until #642 — the encoder refused the compiler's own
  output outright (the unconditional `ballOneof_*` top-level vars, the `ballrt.RunEntry` entry
  wrapper, and every `ballrt.*` base-call helper). `go/encoder/ballrt.go` is the inverse table that
  closes the dominant part of that, and `go/encoder/ballrt_test.go` is the fast guard on the
  shape. Its CI home is the `go-roundtrip` row in `conformance-matrix.yml`, which **is a PR gate
  since #619** and **floored + ratcheted since #642**: harness health (a parseable `Results:` line,
  integer counts, `total >= 1`) PLUS `passed >= 1` PLUS `passed >= GO_ROUNDTRIP_FLOOR`, enforced by
  `tools/ci/roundtrip_floor.sh`. It is still NOT a parity gate — most of the corpus does not
  round-trip yet — but a flat zero is red, and the floor only rises. **Raise the floor in the SAME
  PR as the fix that earned it**; the job prints the exact new value. The remaining gap is named in
  the row's own step summary with the issue tracking it (#691), never as an "expected baseline".
- **The inverse tables carry the base MODULE, and four emitted SHAPES have inverses of their own
  (#691 — the row went 31 -> 79, measured on PR #738's matrix, run 35549906393:
  `Results: 79 passed, 281 failed, 360 total (floor: 79)`).** `ballrt.go` used to map every
  helper to a `std` call, so no `std_collections` helper could be inverted at all and the leg stopped at the first list/map/set op in most of the corpus.
  It is now two module-scoped tables (`stdHelpers`, `collectionsHelpers`) merged at init, and
  `mergeHelperTables` PANICS on a name claimed by both rather than letting map order pick a module.
  Each collections field is the compiler's FIRST alias for that argument (`c.arg(f, "value",
  "callback")` -> `value`), so a re-encode compiles back to the same call.
  `go/encoder/ballrt_table_test.go` is the drift guard and it derives the closed set from the source
  of truth — it PARSES `go/compiler/base_call.go` and compares every emission — with negative
  controls that prove it catches each way the two files can part. The four
  shapes: `ballrt.FieldGet(x, "n")` is a Ball `field_access` (a computed name is `std.index` and
  stays refused); `ballrt.NewList(a, b)` is a Ball list LITERAL; `if ballrt.RunLoopBody("",
  func(){…}) { break }` is a loop BODY, not an `if`; and every non-entry compiled function carries
  `(__ret ballrt.Value)` + `defer ballrt.CatchReturn(&__ret)` + `__ret = <body>; return`, whose Ball
  original is just `<body>` — encoding THAT literally would make the function answer null on every
  engine, since `__ret` is not a Ball variable. `SetCreate` is a documented exclusion: both
  `std.set_create` and `std_collections.set_create` lower to it, and the Dart engine reads a set's
  members from an `elements` field neither input descriptor declares.
- **BOTH tables are derived now, not just the collections one (#793).** The guard above shipped
  with exactly ONE `(dispatcher, table)` pair; `stdHelpers` — the ~80-entry sibling half — was
  checked only for non-overlap with `collectionsHelpers`, so a `compileBaseCall` case that grew
  with no inverse, or an entry that stopped matching its emission, had no failing test. It is now
  an `inverseSpec` per pair, so `compileBaseCall`'s `std` switch drives the same parse and the same
  comparison; its first run found NINE real gaps (`sink_create`/`sink_write`/`sink_to_string`,
  `string_from_char_code`, `round_to_double`/`floor_to_double`/`ceil_to_double`/
  `truncate_to_double`, and `throw`), all now mapped. Three shapes the collections switch does not
  have are handled explicitly: a clause with SEVERAL labels (`case "lte", "less_than_or_equal":` —
  the table must name the canonical first one), an emission whose arguments cannot be read
  positionally (a non-`%s` verb, a `c.typeName(f)`/`strconv.Quote(…)` operand, or the
  `ballrt.Value(nil)` placeholder the compiler substitutes for an omitted optional argument), and a
  helper emitted as a bare string literal or nested in a larger format. An unreadable emission is
  RECORDED as opaque and must be a documented exclusion — never silently skipped, which would let
  the table assert a shape no test checks. `documentedStdExclusions` carries the reason for each of
  the 15, including std_convert's six (`json_*`/`utf8_*`/`base64_*` reach this switch too, but
  invert to `std_convert.<fn>`, which `ballrt.go` has no table for) and `Invoke` (`std.invoke`'s
  InvokeInput declares only `callee`, never the `function`/`argument` the compiler emits). The
  mutation battery is judged on the problems a mutation ADDS, not on a non-empty report: a
  negative control needs its own positive floor, or a table that already has a finding makes every
  case pass vacuously. The round-trip floor moved 79 -> **80** with it (PR #866's matrix, run
  35606234552: `Results: 80 passed, 283 failed, 363 total`, against `79 passed, 284 failed, 363
  total` on the commit it branched from — run 35603702521, main at `ea8724bb`).
- **The round-trip leg's per-fixture kill is bounded by `cmd.WaitDelay` (#691).**
  `roundTripOne` runs the Dart CLI out of process with `cmd.Stdout` set to an
  `io.Writer`, so `os/exec` pipes the child and copies in a goroutine — and
  `cmd.Wait` does not return until that copy ends, which needs EVERY holder of the
  pipe's write end closed, the killed process's own descendants included. Killing
  the child is therefore NOT enough: one surviving grandchild makes the `<-done`
  after `Kill` block forever, the sweep never prints its `Results:` line, and the
  CI row dies on `timeout-minutes` instead of REPORTING a timeout — the defect
  `docs/TESTING_STRATEGY.md` §2c item 6 names. It was latent until #691 made
  enough fixtures re-encode for one to reach the engine and not terminate.
  `go/engine/conformance/roundtrip_timeout_test.go` is the negative control: a
  stand-in `dart` (a COPY of the test binary, so nothing the framework cleans up
  is locked while it runs) that hands its stdout to a grandchild and blocks.
  Measured: 5.6 s with the bound, 30.1 s without.
- **A leg's `Result.Detail` goes through `errorDetail`, which JOINS every line (#642).** The
  compiler's and the encoder's errors are multi-line — a header plus one bullet per unsupported
  construct — and a `FAILING [name] status detail` line is the only place CI shows why a fixture
  failed. The predecessor kept just the text before the first `\n`, dropping every bullet with no
  ellipsis, which is why #642's investigation had to reproduce the Go leg locally to learn what its
  six constructs were. `errorDetail` joins with `" / "` (Python's separator) and truncates at the
  same visible 200-character budget C#/Rust use. `go/engine/conformance/support_test.go` pins it.
