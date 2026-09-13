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

### Field write vs. declared setter (issues #501, #664)

`engine_eval.dart`'s `_trySetterDispatch` decides what `obj.x = v` does when the
class tree declares a setter named `x`. The question it must ask is **"does the
nearest declaration of `x` visible from this instance's class contribute a
setter?"** — not "does the instance carry a key called `x`".

* A **non-`final`** field declares a getter AND a setter, so it overrides
  anything inherited: the write is a plain map write. That is what #501 fixed
  (`class B extends A { @override int x = 5; }` over `class A { set x(v) {…} }`),
  pinned by `432_shadowed_getter_setter_write`.
* A **`final`** field declares a getter and NOTHING else, so an explicit setter
  written beside it is the only setter for that name — legal Dart, and the shape
  `collection`'s `ListSlice` uses. The `containsKey` guard alone suppressed it,
  silently overwriting the `final` field instead (#664), pinned by
  `470_setter_beside_final_field`.

Finality comes from `TypeDefinition.metadata['fields'][i]['is_final']`, recorded
into `_declaredFieldIsFinal` by `_registerDeclaredFieldFinality` on BOTH module
paths — `_buildLookupTables` and `engine_invocation.dart`'s lazy import
resolution — so a class reached through a lazily resolved import answers the
same as its eagerly loaded siblings. `_nearestFieldDeclarationIsFinal` walks
`__super__` and answers from the FIRST class that declares the field, because a
subclass's own non-`final` field overrides an ancestor's accessors; stopping at
the first `final` declaration anywhere up the chain would run an ancestor's
setter through a subclass's plain field. It never consults `is_late`: a
`late final` field IS assignable once, so its declaration does contribute a
setter, but Dart rejects that declaration next to an explicit same-named setter
outright — and the Dart compiler emits `late final` for a final field the
initializer list assigns (#651), so reading it would make the engine's answer
depend on whether the program had been round-tripped through that compiler.

This is metadata an engine DISPATCHES on. That is deliberate and bounded —
`docs/METADATA_SPEC.md`'s "Accessor shape" section is the contract; `is_setter`
was always in the same family, and nothing else may join it silently.

The target compilers have to lower the same shape into languages that have no
`final`-field/setter split — see `.claude/rules/ts.md` and `.claude/rules/cpp.md`
for the backing-member lowering each uses.

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
