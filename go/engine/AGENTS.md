<!-- Parent: ../AGENTS.md -->

# `go/engine` — Go Ball engine (self-hosted)

Runs Ball programs by the **self-host** route (SKILL.md Phase 4, Option B), the
same approach as the TS/C++/Rust/C# targets: the reference engine is itself a
Ball program (`dart/self_host/engine.ball.json`), compiled through `go/compiler`
into `compiled/compiled_engine.go`, and driven by a thin native wrapper.

## Status: complete, at Dart parity (#426 Phase 4)

The compiled engine runs the whole conformance corpus with Dart-identical output:
**`Results: 349 passed, 0 failed, 349 total (4 skipped carve-outs)`**. The 4
golden-less fixtures (`196_timeout` / `197_memory_limit` / `201_input_validation`
/ `202_sandbox_mode`) are the same resource-limit/sandbox carve-outs the
Dart/Rust/C# runners skip. No build tag: `compiled/compiled_engine.go` is a
COMMITTED generated artifact since #586 (see "Why the artifact is committed"
below), so a plain `go build ./...` / `go test ./...` in a fresh checkout drives
the real engine.

## Layout

- `engine.go` — public API (`BallEngine`, `FromJSON`/`FromBinary`, `Run`);
  `Run` drives the compiled engine through `compiled.RunProgram`.
- `loader.go` — build the canonical proto3-JSON `ballrt.Value` view of a target
  `Program` (the shape the compiled engine reads through the `ball_proto`
  access-pattern functions): serialize with proto3 default values materialized,
  parse into an insertion-ordered `*ballrt.Map` tree (bytesValue base64-decoded,
  doubleValue forced to a double), then reconstruct the raw
  `google.protobuf.Struct` shape for every `metadata` field. The Go sibling of
  `csharp/engine/src/Loader.cs` / `rust/engine/src/loader.rs`.
- `compiled/` — the generated engine package. `driver.go` constructs the
  compiled `BallEngine` + `StdModuleHandler` and calls the compiled `run`;
  `compiled_engine.go` (**GENERATED, committed, never hand-edit**) is the
  compiled engine itself; `doc.go` documents the package.
- `cmd/regen` — the regeneration entry point.
- `conformance/` — the whole-corpus sweeps. The **engine** leg (`runner.go` +
  `conformance_test.go`) drives the compiled engine; the **round-trip** leg
  (`roundtrip.go` + `roundtrip_test.go`, issue #452 item 3) never touches it — it
  goes Ball → `go/compiler` → `go/encoder` → the **Dart** reference engine →
  golden diff. Their shared `Result`/`Summary`/`conformanceDir`/`diffDetail`
  helpers live in `support.go`. Honest round-trip baseline:
  `Results: 0 passed, 321 failed, 321 total` — expected by construction (see
  `go/AGENTS.md`'s "Round-trip conformance leg").
- `ball_proto` access patterns + the base-op / Dart-SDK runtime the compiled
  engine calls live in `go/runtime` (package `ballrt`), not here.

## Generated file — NEVER edit

`compiled/compiled_engine.go` — the self-hosted engine, compiled from
`dart/self_host/engine.ball.json`. Regenerate and COMMIT, never hand-patch. To
change engine behavior, fix `go/compiler` or `go/runtime` (or the
`dart/self_host/` source), rerun the regenerator, and commit the result;
ci.yml's `Ball Artifact Freshness` job regenerates it and `git diff
--exit-code`s it, so a codegen change without a regen fails the build.

The regenerator's output must be **byte-reproducible** — that is what makes the
freshness gate possible. #586 had to fix one source of non-determinism first:
`go/compiler`'s `compileRecord` ranged over a Go map, so every compile emitted a
record's fields in a different order (and gave the record a different RUNTIME
field order). Anything new that emits from a map must sort or use the proto's
repeated-field order; `compileOneofDiscriminators` sorts for the same reason.

## Regenerate + run

```bash
# From dart/, regenerate the self-host source if absent (gitignored):
cd dart && dart run compiler/tool/gen_engine_json.dart

# Regenerate compiled_engine.go (then COMMIT it — it is tracked):
cd go/engine && go run ./cmd/regen

# Run the whole conformance corpus (no build tag; -v so Results: reaches stdout):
go test -v -run TestConformance -timeout 3600s ./conformance/
#   → prints `Results: N passed, M failed, T total (K skipped carve-outs)`
# BALL_FIXTURE=<name> runs one fixture; BALL_DEBUG_STACK=1 crashes on the first
# panic with a Go origin stack (locates the compiled-engine line).
```

## Per-fixture timeout (issue #436)

Go cannot kill a goroutine, so the conformance runner cannot stop a runaway
fixture by abandoning it — a hung fixture's goroutine would keep spinning for the
rest of the sweep, starving CPU. Instead the runner drives the compiled engine's
**cooperative** execution-timeout guard: it sets `BallEngine.TimeoutMs` to the
per-fixture budget (`perFixtureTimeout()`, 120 s default, `BALL_TIMEOUT_MS`
override), and the compiled engine's per-expression `_checkExecutionTimeout`
(`dart/engine/lib/engine.dart`) makes a **flat-stack** runaway (an infinite
`while`/`for`) self-abort with `Execution timeout exceeded` once it has run that
long — the goroutine then exits and the fixture is reported as a `timeout`.

**Known limitation — the cooperative guard does NOT reliably stop every
runaway.** Two shapes escape it: a native loop inside a runtime helper (never
returns to an expression eval, so the guard is never consulted), and
**unbounded-stack Ball recursion** (guard checks run per level but were observed
not to abort within the budget). Both only surface via the `select` backstop on
`time.After(budget + hardDeadlineGrace)`, and in both cases the goroutine keeps
running afterwards — it LEAKS, exactly the residual #436 describes — while
unbounded recursion additionally risks a fatal Go stack overflow under the
driver's 1 GiB `SetMaxStack` ceiling, which would kill the whole sweep binary.
The hardening here fully covers flat-stack runaways (the shape that actually
wedged sweeps); the recursion shape remains open. `TimeoutMs` is off
(0, unbounded) by default, so the CLI/`Run()` path is unaffected. Regression
test: `conformance/timeout_test.go`.

## Why the artifact is committed (issue #586)

Rust, C# and Python keep their compiled engines gitignored behind an
off-by-default feature/property, because their registry channels (crates.io,
NuGet, PyPI) regenerate or bootstrap at publish time. **Go's registry IS the git
tag**: the module proxy serves the repository at `go/<module>/vX.Y.Z`, and
`go install` accepts no `-tags`. A gitignored, `selfhost`-gated
`compiled_engine.go` therefore never reached a consumer, and
`go install github.com/ball-lang/ball/go/cli/cmd/ball@…` produced a `ball` that
could not run a single program.

So the artifact is tracked and the build tag is gone — the shape
`ts/engine/src/compiled_engine.ts` has had since #517. The two halves of that
contract:

- **freshness** — ci.yml's `Ball Artifact Freshness` job regenerates
  `compiled_engine.go` (and `go/cli/compiled/compiled_cli.go`) and
  `git diff --exit-code`s them. Exactly one such gate per artifact; do not add a
  second regeneration pass to the `go` job.
- **behaviour** — `tools/go-module-proxy/smoke.sh` (run by the `go` job)
  `go install`s the CLI into a clean GOPATH off a synthesized proxy and runs
  `ball run` / `ball info` / `ball version`, byte-comparing against the same
  goldens the sweeps use.

## Fixing engine behavior

A divergence from Dart is either in the compiler's emitted code (a `go/compiler`
fix + regen) or in a runtime helper the emitted code calls (a `go/runtime` fix,
no regen). Common `go/runtime` families: `ball_proto` access patterns
(`proto.go`), the Dart-SDK method surface (`methods.go`, dispatched by
`CallMethod`), `std_collections`/set (`collections.go`), `std_convert`
(`convert.go`), value-wrapper unwrapping + the is/as class-hierarchy registry
(`wrappers.go`). Never hand-patch `compiled_engine.go`.

**Polymorphic std ops (a load-bearing gotcha):** the Dart→Ball encoder is
syntactic (no receiver types), so `.isEmpty`/`.isNotEmpty` on a List/Map routes
to `std.string_is_empty`, and `List.contains`/`indexOf` and `String.contains`/
`indexOf` cross-route between the `string_*` and `list_*` families. Those runtime
helpers must therefore accept both a string and a collection receiver (matching
the reference engines' polymorphic std handler) — see `StrIsEmpty`,
`ListContains`, `ListIndexOf`.
