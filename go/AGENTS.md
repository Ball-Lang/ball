<!-- Parent: ../AGENTS.md -->

# Go (compiler + runtime; proto bindings)

## Purpose
Ball → Go compiler (Phase 2 of epic #426) plus the Go runtime value model it
targets, and the generated Go protobuf bindings. Encoder, self-hosted engine,
CLI, conformance harness, and CI are later phases.

## Layout (three Go modules, tied by `go/go.work`)
| Dir | Module path | Description |
|-----|-------------|-------------|
| `runtime/` | `github.com/ball-lang/ball/go/runtime` | Package `ballrt`: the runtime value model (`Value`/`List`/ordered `Map`/`Function`/`Message`) + base-op helpers (`Add`, `Truthy`, `ToStr`, …) + flow signals (`Return`/`Break`/`Continue`/`Throw` via panic/recover). **Zero external dependencies** (Go stdlib only) so compiled programs build and run offline via a local `replace`. |
| `shared/` | `github.com/ball-lang/ball/go/shared` | Generated Go protobuf bindings (package `ballv1`, under `gen/`) — NEVER hand-edit; regenerate with `buf generate`. Requires `google.golang.org/protobuf`. |
| `compiler/` | `github.com/ball-lang/ball/go/compiler` | Ball → Go compiler (string emission, mirroring `rust/compiler` / `cpp/compiler`). `cmd/ballgoc` is a thin front-end. |

## Build & Test
```bash
cd go/compiler && go build ./... && go vet ./... && go test ./...   # compiler + end-to-end
cd go/runtime  && go test ./...                                      # runtime unit tests
gofmt -l go/runtime go/compiler                                      # must print nothing
cd go/compiler && go run ./cmd/ballgoc <program.ball.json>           # compile Ball → Go
```
Native `go` (Windows) is used in this environment; WSL `go` works too.

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
- Runs end-to-end (compile → `go run`): `hello_world`, `fibonacci`, a while-loop,
  and a `for_in` loop (see `go/compiler/compiler_test.go` + `testdata/`).
- Deferred to later phases: full std coverage (increment/decrement, switch/try,
  regex, collections, std_io/std_memory/…), the encoder (Go → Ball), the
  self-hosted engine (compiling `dart/self_host/engine.ball.json`), the CLI, the
  conformance harness, and CI wiring.

## For AI Agents
- Verify maturity against CI (`.github/workflows/ci.yml`), not this prose.
- `go/shared/gen/` is generated — regenerate after proto changes, never hand-edit.
- Follow `.claude/skills/new-ball-language/SKILL.md` for the remaining phases.
