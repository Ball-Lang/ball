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

### Dart's `StateError`: typed AND readable (issue #616)

#597/#604 settled that `std_collections.list_find`'s no-match THROWS and that the throw is
typed. Neither settled what the program then OBSERVES — conformance fixture
`463_list_find_no_match` prints a hardcoded literal from its catch bodies — and every target
answered differently. Measured on `origin/main` before the fix, one program printing
`to_string(e)` from its catch: the Dart reference engine `Bad state: No element` (which is also
real Dart's `StateError('No element').toString()`), the TS self-hosted engine
`{message: No element}`, the Go self-hosted engine `main:StateError`.

The contract now has two halves at EVERY site that raises Dart's `StateError` — an empty
`.first`/`.last`/`.single`/`removeLast`/`reduce`, or a `firstWhere` with no match:

1. **TYPED** — the thrown value carries the type name `StateError`, so a program's own
   `on StateError catch` matches it. Several sites used to raise an untyped native fault that
   the compiled `try` could not see at all.
2. **OBSERVABLE** — it stringifies as Dart's own `StateError.toString()`, `Bad state: <message>`,
   so `to_string(e)` in the catch body reads the same here as on the Dart reference engine.

`tests/conformance/465_state_error_message` is the cross-target guard (it prints the caught
value for `list_find`'s no match AND `list_first` on an empty list — never a hardcoded string).
Per-target details are in `.claude/rules/<lang>.md`; the gap class is
`docs/TESTING_STRATEGY.md` §5b.
