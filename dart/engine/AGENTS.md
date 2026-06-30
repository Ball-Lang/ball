<!-- Parent: ../AGENTS.md -->

# engine (`ball_engine`)

## Purpose
Tree-walking interpreter that executes Ball expression trees directly (true async), with the full universal std library and pluggable custom-module handlers. The reference engine all other targets mirror.

## Key Files
| File | Description |
|------|-------------|
| `lib/engine.dart` | `BallEngine.run(Program)` — main interpreter (split via `part` files) |
| `lib/engine_eval.dart` | Expression evaluation core |
| `lib/engine_invocation.dart` | Function call / lambda invocation, scope chain |
| `lib/engine_control_flow.dart` | Lazy `if`/`for`/`while`/`for_each`, `FlowSignal` |
| `lib/engine_std.dart` | `StdModuleHandler` — universal std base-fn dispatch |
| `lib/engine_types.dart` | Type ops, `typeDefs[]` handling |
| `lib/ball_value.dart` | Runtime value model |

## For AI Agents
- Entry point: `BallEngine.run`. Scoping is a linked lexical `Scope` chain; break/continue/return propagate as `FlowSignal`.
- **Fail loud** on any unhandled shape — never return `null`/`[]`/placeholder strings (the silent-degradation trap behind issue #55).
- Control flow MUST evaluate lazily (Core Invariants, `../../CLAUDE.md`).
- Engine `part` files are concatenated by `dart/encoder/tool/concat_engine.dart` for self-encoding — keep them part-compatible.
- Prefer conformance fixtures over unit tests. `test/engine_test.dart` helpers: `buildProgram()`, `runAndCapture()`, `loadProgram()`.

## Dependencies
- Internal: `ball_base`, `ball_resolver` (`ball_encoder` dev-only).
- External: `protobuf`.
