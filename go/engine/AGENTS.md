<!-- Parent: ../AGENTS.md -->

# `go/engine` — Go Ball engine (self-hosted)

Runs Ball programs by the **self-host** route (SKILL.md Phase 4, Option B), the
same approach as the TS/C++/Rust/C# targets: the reference engine is itself a
Ball program (`dart/self_host/engine.ball.json`), compiled through `go/compiler`
into `compiled/compiled_engine.go`, and driven by a thin native wrapper.

## Status: complete, at Dart parity (#426 Phase 4)

The compiled engine runs the whole conformance corpus with Dart-identical output:
**`Results: 320 passed, 0 failed, 320 total (4 skipped carve-outs)`**. The 4
golden-less fixtures (`196_timeout` / `197_memory_limit` / `201_input_validation`
/ `202_sandbox_mode`) are the same resource-limit/sandbox carve-outs the
Dart/Rust/C# runners skip. Behind the off-by-default `selfhost` build tag because
`compiled_engine.go` is a gitignored generated artifact absent from a fresh
checkout (see Build-tag gating below).

## Layout

- `engine.go` — public API (`BallEngine`, `FromJSON`/`FromBinary`, `Run`) and
  `ErrSelfHostPending`.
- `loader.go` — build the canonical proto3-JSON `ballrt.Value` view of a target
  `Program` (the shape the compiled engine reads through the `ball_proto`
  access-pattern functions): serialize with proto3 default values materialized,
  parse into an insertion-ordered `*ballrt.Map` tree (bytesValue base64-decoded,
  doubleValue forced to a double), then reconstruct the raw
  `google.protobuf.Struct` shape for every `metadata` field. The Go sibling of
  `csharp/engine/src/Loader.cs` / `rust/engine/src/loader.rs`.
- `run_selfhost.go` (`//go:build selfhost`) / `run_stub.go` (`//go:build
  !selfhost`) — the two `run()` implementations. The stub returns
  `ErrSelfHostPending`; the real one drives the compiled engine via
  `compiled.RunProgram`.
- `compiled/` — the generated engine package. `doc.go` (untagged) keeps the
  package non-empty on a fresh checkout; `driver.go` (`//go:build selfhost`)
  constructs the compiled `BallEngine` + `StdModuleHandler` and calls the
  compiled `run`; `compiled_engine.go` (`//go:build selfhost`, **GENERATED,
  gitignored**) is the compiled engine itself.
- `cmd/regen` — the regeneration entry point.
- `conformance/` — the whole-corpus sweep (`runner.go` + `conformance_test.go`,
  both `//go:build selfhost`; `doc.go` untagged).
- `ball_proto` access patterns + the base-op / Dart-SDK runtime the compiled
  engine calls live in `go/runtime` (package `ballrt`), not here.

## Generated file — NEVER edit

`compiled/compiled_engine.go` — the self-hosted engine, compiled from
`dart/self_host/engine.ball.json`. Regenerate, never hand-patch. Gitignored (like
C++'s `engine_rt.cpp`, Rust's `compiled_engine.rs`, C#'s `CompiledEngine.cs`)
because it is a ~1.3 MB / ~30k-line build artifact. To change engine behavior,
fix `go/compiler` or `go/runtime` (or the `dart/self_host/` source) and rerun the
regenerator.

## Regenerate + run

```bash
# From dart/, regenerate the self-host source if absent (gitignored):
cd dart && dart run compiler/tool/gen_engine_json.dart

# Regenerate compiled_engine.go:
cd go/engine && go run ./cmd/regen

# Run the whole conformance corpus (needs the selfhost tag):
go test -tags selfhost -run TestConformance -timeout 3600s ./conformance/
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

## Build-tag gating

The generated `compiled_engine.go` is a gitignored artifact absent from a fresh
checkout, so a plain `go build ./... && go test ./...` must not depend on it.
Everything that references it — `driver.go`, `run_selfhost.go`, the conformance
runner + test — carries `//go:build selfhost`; the untagged `doc.go` files keep
each package non-empty. A default build stays green on the wrapper foundation
(loader + `ball_proto` + the stub `run`); the compiled engine only participates
under `-tags selfhost`. This is the Go analog of Rust's off-by-default
`self_host` cargo feature and C#'s `-p:SelfHost=true` MSBuild property.

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
