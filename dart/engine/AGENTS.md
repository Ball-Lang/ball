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

### Which backing store the setter mirror writes (issue #768)

Once a setter has run, `_writeBackingField` mirrors the setter's RETURN value
onto the instance's backing store, because a target that value-copies `self`
never observes the body's own write. WHICH store is the whole question, and it
is answered from the setter's own body, not from its name:

* `_setterBackingStore(func)` walks the setter body for `std.assign` targets
  that name a **private store on the receiver** — a bare `_name` (the encoder's
  implicit-`this` shape) or an explicit `self._name` / `this._name`. Exactly one
  distinct target is an answer; zero or several is `null`. A nested `lambda`
  body is NOT walked: a closure's write happens only if something invokes it.
  The result is cached per setter function name in `_setterBackingStores`.
* Only if the body names no single store does the mirror fall back to Dart's
  `_<property>` convention (`set celsius` → `_celsius`) — a guess about the
  PROPERTY, bounded to the field that property would own.

Before #768 the fallback was the **literal name `_celsius`**, so a class that
declared a `_celsius` field had it silently overwritten by any unrelated
computed setter (`set fahrenheit(v) => _kelvin = …` left `_celsius` holding the
Kelvin value). A wrong answer with no diagnostic, invisible to the whole corpus
because the only fixture family that reached the branch happened to name its own
store `_celsius`. Pinned by `478_setter_backing_store_disambiguation` and by
`engine_test.dart`'s "setter backing-store mirror (#768)" group. The six
self-hosted engines compile THIS source, so they inherit the fix with their
regenerated artifacts — none of them carries a hardcoded fallback of its own.

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

### An assignment the engine cannot perform is an ERROR, never a dropped write (#742)

`engine_control_flow.dart`'s `_evalAssign` and `_evalNullAwareAssign` write
through exactly three `std.assign` target shapes — a bare `reference`, a
`fieldAccess` whose object reads as a map, and a `std.index` call over a
list/map. Every other shape used to fall out of all three branches into a bare
`return val;`, so the write was never performed and the RHS was handed back as
if it had been. Interpreted or compiled, a caller could not tell a dropped write
from a successful one — the exact silent-degradation class behind issue #55.

Every such path now throws a `BallRuntimeError` built by `_assignErrorMessage`,
and the message names what the engine could not do:

| Situation | Message |
|---|---|
| no `target`/`value` field on the call | `std.assign: call is missing its 'target'/'value' fields` |
| field write on a non-object | `std.assign: cannot write field 'f' on a non-object value of type int` |
| malformed `std.index` target | `std.assign: std.index target is missing its 'target'/'index' fields` |
| container/index pair not indexable | `std.assign: cannot index-assign into a value of type String with an index of type int` |
| any other target shape | `std.assign: unsupported assignment target shape literal: expected a reference, a field access, or a std.index call` |

Under `??=` the prefix carries the operator (`std.assign (??=): …`), since that
path is `_evalNullAwareAssign` — there is **no** separate `std.assign_null_aware`
base function; `??=` is `std.assign` with `op: '??='`.

`_assignTargetShapeName` names the shape from an **exhaustive `switch` over
`Expression_Expr`**, so a new oneof case in `ball.proto` is a compile error here
rather than a silently unnamed shape. Its `reference`/`fieldAccess`/`call` arms
are verified-unreachable (those targets return, throw their own message, or are
named by the early return above) and carry the coverage-ignore analysis inline.

Guards: `engine: assign to an unrecognised target fails loud (#742)` in
`test/engine_test.dart` — one case per rejected shape under both `=` and `??=`,
plus a closed-set completeness check that derives the rejected set from
`Expression_Expr.values` itself, so a new Expression case fails the suite until
it is classified. `test/engine_wave5_control_flow_coverage_test.dart`'s
`null-aware index assign on a non-indexable target throws` is the same contract
from the other side: it previously asserted the silent no-op's `'x'`.

This is engine source, so it reaches every self-hosted engine: the whole
conformance corpus was re-run on the Dart reference engine and on the compiled
Go engine to confirm no fixture depended on the old fallthrough, and
`compiled_engine.ts` / `compiled_engine.go` were regenerated in the same commit.
