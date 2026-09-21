---
paths:
  - "dart/**"
---

# Dart-Specific Instructions

## Package Structure

Ball's Dart implementation is a pub workspace. The five core Ball-portable packages are:
- `ball_base` (dart/shared/) — Protobuf types, std module builders. Dependency for all others.
- `ball_compiler` (dart/compiler/) — Ball → Dart code generator using `code_builder` + `dart_style`
- `ball_encoder` (dart/encoder/) — Dart → Ball using `analyzer` package
- `ball_engine` (dart/engine/) — Tree-walking Ball interpreter
- `ball_cli` (dart/cli/) — CLI tool

The same workspace also contains the protobuf-runtime and tooling packages
`ball_protobuf`, `ball_protobuf_gen`, `ball_rpc`, `resolver`, and `self_host`
(see root `CLAUDE.md` and the `workspace:` list in the repo-root `pubspec.yaml`
for the authoritative member set).

## Key Patterns

### Compiler
- `DartCompiler.compile(Program)` → returns formatted Dart source string
- Base functions are dispatched in `_compileBaseCall()` — extract fields from `MessageCreation` input
- Control flow (if, for, while) must use LAZY evaluation — extract expression trees, don't evaluate eagerly
- Types are emitted from `typeDefs[]` only (a `TypeDefinition` = descriptor + metadata); the legacy `types[]`/`_meta_*` path was removed

- **`std_collections.list_find` THROWS when nothing matches (#597).** It is Dart's
  `Iterable.firstWhere` WITHOUT `orElse` — what its own declaration in
  `dart/shared/lib/std_collections.dart` says ("Find first:
  list.firstWhere(callback)") and what the Dart reference engine does
  (`engine_std.dart`: `throw StateError('No element')`). Never a `null`/
  `undefined`/empty placeholder, and never an untyped throw: the thrown value
  must carry the type name `StateError` so the program's own `on StateError
  catch` sees it. `tests/conformance/463_list_find_no_match` is the cross-target
  guard; `dart/compiler/test/base_calls_test.dart`'s `list_find` group (the compiler lowers it to `.firstWhere(cb)` with NO `orElse`) is this target's half. See `docs/TESTING_STRATEGY.md` §5b.

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
  reference-semantics leg) plus this target's own tag test — `dart/engine/test/engine_test.dart`'s `std text sink (#630)` group (the engine) and `dart/compiler/test/base_calls_test.dart` (the compiler's `_ballSink*` helpers).
  Backing: the engine builds the tag map through `_ballUserMap()`, NOT a map literal — a plain literal lowers to a by-value `std::map` in the C++ self-host and the callee's append is lost; the compiler emits top-level `_ballSinkCreate`/`_ballSinkWrite`/`_ballSinkToString` helpers over a Dart `Map` (a reference type), never a host `StringBuffer`, which would make `_ballTypeOf` answer `StringBuffer`. The ENCODER routes `StringBuffer` syntactically (a local declared `StringBuffer`/`StringSink` or initialised with `StringBuffer(...)`, or a parameter annotated that way), because `generate_conformance.dart` parses without resolution; a `StringBuffer`/`StringSink` type ANNOTATION is recorded as `dynamic` (`_portableTypeSource`) so the compiled-back Dart does not annotate a sink as a `StringBuffer` and fail to type-check. `clear()`/`writeAll()` are deliberate carve-outs: they stay on the engines' Dart-SDK method surface, which now accepts the `std:Sink` tag as well as the legacy `:StringBuffer` one.
- **A caught `StateError` reads as `Bad state: <message>` (#616).** `463` above
  proves the throw is TYPED; it prints a hardcoded literal from its catch
  bodies, so it pins nothing about the caught VALUE. The reference engine used
  to raise a HOST `StateError` for an empty `.first`/`.last`/`.single`/`reduce`
  and a no-match `firstWhere`, which `_evalLazyTry` collapses to
  `e.toString()` — correct on Dart, but every SELF-HOSTED engine is that same
  source compiled through the Ball pipeline, where `StateError('No element')` is
  a construction of a class the program never declares, so their catch variable
  bound a target-shaped object and `to_string(e)` printed `{message: No element}`
  (TS) / `main:StateError` (Go). `engine_types.dart`'s `_stateError` raises a
  `BallException` whose value IS the canonical string instead, so the Dart
  observable is byte-identical and the same portable value travels every target.
  Never re-introduce a host `throw StateError(...)` in engine source — use
  `_stateError`. `tests/conformance/465_state_error_message` is the cross-target
  guard. See `docs/TESTING_STRATEGY.md` §5b.

- **A caught `TypeError` reads as Dart's own message, and the rendering table is
  CLOSED by a test (#641).** A failed cast pattern raises `TypeError`, and Dart
  spells it
  `type '<runtime type>' is not a subtype of type '<target>' in type cast` —
  naming the VALUE's type first, and with **no** `TypeError: ` prefix, because
  `_TypeError.toString()` IS its message (the odd one out of the four built-ins).
  Every target used to spell `type cast failed: not a <T>` and then render it a
  different way; the canonical form is real Dart's because
  `generate_conformance.dart` builds a golden by RUNNING the fixture's Dart
  source on the SDK. The reference engine has no rendering table either —
  `_evalLazyTry` binds `e.value` verbatim — so `engine_std.dart`'s `case 'cast'`
  spells the whole string, using `_typeNameOf(value)` for the runtime type.
  `tests/conformance/467_caught_type_error_to_string` is the cross-target guard,
  and `tools/check_error_rendering_tables.py` (`Proto Checks`, every PR, with its
  own self-test) is the structural one: it asserts every Dart error name this
  runtime RAISES has an entry in this runtime's table and that every entry's
  prefix equals Dart's. Add a new built-in error here and to that contract in the
  same PR, or the checker fails.
- **`_isBaseModule` is a CLOSED SET, checked against the builders (#606).** It
  enumerates base module names by hand, and `std_concurrency` was missing — so
  every `std_concurrency.*` call fell through `_compileCall` to the USER-function
  path and emitted a bare `thread_spawn(...)`, an identifier the generated Dart
  never defines, with NO diagnostic (not even the `/* unsupported: std.<fn> */`
  marker the `std` switch's default arm produces). A module added to
  `dart/shared/lib/std*.dart` needs BOTH an `_isBaseModule` entry and a
  `_compileBaseCall` lowering; `dart/compiler/test/std_concurrency_test.dart`
  re-derives the dispatcher's list from its own source and asserts every builder
  module is in it (with a positive floor, so an extraction that stops matching
  fails instead of passing vacuously).
- **The base-call dispatch is a CLOSED SET over the std BUILDERS, and every
  default arm FAILS LOUD (#654).** `_compileBaseCall`'s seven per-module
  switches used to end in `_ => '/* unsupported: <module>.<fn> */'` — a COMMENT
  spliced where an EXPRESSION belongs, so the compiled Dart broke later with
  `BODY_MIGHT_COMPLETE_NORMALLY` instead of the compiler saying what it cannot
  do (that is how #488's `map_contains_value` row hid). They all share
  `_unimplementedBaseCall(module, function)` now, the arm #663 already gave
  `std_concurrency`. Fourteen DECLARED names had no case:
  `std.int_to_double`/`double_to_int`/`string_interpolation` and eleven
  `std_collections` names. Six of the `std_collections` lowerings cannot be
  inline expressions and still mean what `engine_std.dart` means, so they go
  through `_collectionsHelperSources` — a per-DECLARATION preamble, like
  `_usesTypeOf`/`_usesSink`, never per-module (an unused private top-level
  function is an analyzer warning in the compiled output). An async callback is
  REFUSED there, the same call `_concurrencyPreamble` makes for an async body.
  `dart/compiler/test/base_call_dispatch_completeness_test.dart` builds its
  population IN PROCESS from the eight `buildStd*Module()` builders and probes
  each name by COMPILING a call to it — not by scanning switch-arm patterns,
  which is what let `std_collections.set_create` pass before: the name is in the
  file, in the `std` switch, because `DartEncoder._moduleForFunction` answers
  `'std'` for every std call, while the declared spelling reached the default
  arm. `ball_proto` is the one base module out of the population — it has no
  switch (`_compileBallProtoCall` lowers every name to `<receiver>.<name>()`).
  Shape is not meaning, and these names are unreachable from the ENCODER, so
  they can have no `tests/conformance/src/*.dart` fixture — nothing encodes to
  `std_collections.list_zip`, which is why they stayed unimplemented.
  `dart/compiler/test/declared_base_call_equivalence_test.dart` is the
  behavioural half: ONE hand-authored Ball program, run on the reference engine
  AND through `dart run` over its compiled Dart, both pinned to the same
  expected transcript — so "the two agree" cannot mean "they agree on the wrong
  answer". Add a lowering here and add its case there.
- **A module that needs STATE gets a conditional runtime preamble**, the way
  `std_memory`'s linear-memory block always has. `std_concurrency` emits one too
  (`_ballThreads`/`_ballMutexes`/`_ballAtomics` plus the `_ball*` helpers), only
  when `_baseModules.contains('std_concurrency')`, and its semantics must stay
  byte-for-byte equivalent to `engine_std.dart`'s — a program has to mean the
  same thing interpreted and compiled. An ASYNC body is REJECTED there rather
  than silently un-awaited: the engine awaits it, and dropping the `Future`
  would be a divergence, not an optimisation.

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
  The reference engine's own fix is `engine_std.dart`'s `_dartErrorPrefix`,
  consulted by `to_string`'s `Exception`/`Error` arm BEFORE the message arm -
  and only for Dart's own four names, so a user class called `ValidationError`
  keeps printing its message. `.message` is deliberately left unprefixed, and
  `dart/engine/test/user_thrown_builtin_error_test.dart` pins both halves.

- **`late` on an instance field is decided from the IR, not from the field
  declaration (#651).** A non-nullable field with no inline initializer needs
  `late` only when nothing PROVES it assigned by the end of construction — i.e.
  when it is written in a constructor BODY (#305). Two shapes prove it without
  a body, and the encoder already records both:
  `metadata['initializers']` `{kind: field, name, value}` (the constructor's own
  initializer list) and a `metadata['params']` entry with `is_this: true` that is
  ALWAYS supplied (required positional, `required` named, or optional carrying a
  `default`). `_definitelyAssignedFields(methods)` in `compiler.dart` computes
  the INTERSECTION of those across every generative constructor — skipping
  factories, `redirects_to`, and an initializer of `kind: redirect`, which
  delegate rather than initialize — and `_addInstanceFields` drops `fb.late` for
  the result. Never widen the decision back to "no initializer ⇒ `late`": a
  `late final` field is assignable after construction, so it contributes an
  implicit SETTER, and next to a user-declared setter of the same name that is a
  `DUPLICATE_DEFINITION` compile-time error — the real-world case is
  `collection`'s `ListSlice` (`final int length` + `set length(...)`), which is
  legal Dart precisely because a plain `final` field contributes a getter and
  nothing else. `dart/compiler/test/field_finality_test.dart` pins both
  directions and runs a real `dart analyze` over the compiled output;
  `tests/conformance/472_initializer_list_field_with_setter` is the cross-target
  fixture it compiles. Also keep `const`-constructor classes free of `late final`
  (#305) — that carve-out is unchanged.

### Encoder
- `DartEncoder.encode(String source)` → returns Ball `Program`
- Uses `analyzer` package to parse Dart AST
- Encodes ALL Dart expressions to Ball equivalents
- All constructs (including cascade, null_aware_access, spread) route to universal `std` module
- Build `std` modules from accumulated function references via `buildStdModules()`

#### Syntactic-encoder gotchas (parseString — NO type resolution)

The encoder parses with `parseString` and has **no static types**, so it dispatches
by *syntax* and *name heuristics*. When authoring "Ball-portable" Dart (code that
gets encoded and run on the Dart/TS/C++ engines — e.g. `dart/ball_protobuf/lib/`),
avoid constructs that need receiver-type info:

- **`Map.addAll` / `List.addAll` are mis-routed to the non-mutating list op
  `list_concat`** (no way to tell receiver type, and `list_concat` returns a new
  list rather than mutating). A spread splice written as `result.addAll(items)`
  works on the Dart engine but **silently drops the items on the TS/C++ engines**
  — append per-item with `.add` instead (`for (final it in items) result.add(it);`).
  Merge maps with an explicit `entries` loop (`for (final e in src.entries)
  dest[e.key] = e.value;`). Same caution for other methods shared by `List`/`Map`
  (`clear`, `remove`) and the bare `.keys` getter. (This is the portability trap
  that the issue-#55 spread fix had to route around.)
- **A method-name route only fires when the ARGUMENT COUNT fits** (issue #494 /
  the arity subset of #488). Each entry in `collectionRoutes` carries the
  `(minArgs, maxArgs)` window of the real Dart method it stands for; a call
  outside that window falls through to the generic user-method encoding
  (`function: <name>`, `self` field). So a user class may safely declare
  `int split()`, `int indexOf()` or `int toInt(int, int)` — they no longer get
  rerouted into `std.string_split` / `list_index_of` / `to_int`.
  `unaryRoutes` needs no window: its whole branch is already guarded by
  `args.isEmpty`.
- **The RECEIVER-TYPE gate is opt-in and only `PackageEncoder` turns it on**
  (issue #488 slices 1-2). `encode(String)` / `encodeModule(String, …)` parse with
  `parseString`, whose AST leaves `Expression.staticType` null — they are, and
  stay, resolution-free. `await PackageEncoder(dir).prepareStaticTypes()` before
  `encode()` swaps in analyzer-RESOLVED units, and the encoder then declines
  every `'list'`-flavored `collectionRoutes` entry whose receiver resolves to a
  `dart:core` `Set` (`_receiverIsSet`), letting the generic method-call encoding
  re-emit the source's own `s.add(x)`. It DECLINES rather than re-routing to
  `std_collections.set_add`, and that is now a SCOPE choice, not a correctness
  one: issue #545 gave `set_add`/`set_remove` one bool contract on every target
  (mutate in place, return `true` only on a fresh insert / an actual removal),
  so the cross-target divergence that used to make re-routing unsafe is gone and
  the Dart compiler no longer emits the offending cascade `s..add(v)`. Routing a
  `Set` receiver to `set_add`/`set_remove` is #488's call to make; until it does,
  the declined form stays executable because the Dart engine's generic method
  dispatch implements `Set.add`/`remove` with the same semantics.
  `prepareStaticTypes()` is fail-soft —
  no `package_config.json` (never `pub get`-ed) means a warning and an
  unresolved encode, never an exception — and costs a multi-second analyzer cold
  start, so callers that do not need receiver types should not call it.
  Slice 2 extended the same DECLINE to a resolved `dart:core` `Map`
  (`_receiverIsMap` — `Map.map()` returns a `Map`, but `list_map`'s codegen
  always appends `.toList()`) and `String` (`_receiverIsString`), and taught the
  null-aware lowering to bind a temporary local when the receiver is something
  Dart's flow analysis cannot PROMOTE — a field, a top-level variable, a getter
  (`_nullAwareNeedsTemp`). `x?.foo` desugars to `std.if(equals(x, null), null,
  x.foo)`, which names the receiver twice; for a mutable field
  (`StreamSubscription<T>? _inner;`) Dart rejects the else-branch access
  outright. #573 closed the two shapes that survived slice 2, and NEITHER
  needed a schema change — both were lowering-strategy gaps, not gaps in the IR:
  - **Flow-sensitive promotion through REASSIGNMENT**
    (`path/lib/src/context.dart`: `from = from == null ? current :
    absolute(from);` promotes a `String?` parameter for the rest of the body).
    The reassignment itself already compiled to a real Dart ternary, so the
    promotion held — it was lost three statements later, at
    `_parse(from)..normalize()`, because `_compileBlockExpression` lowered EVERY
    value-position `Block` to `(() { … })()` and Dart soundly refuses to carry a
    local's promotion across a function-literal boundary. The compiler now
    recognizes the encoder's Block cascade lowering
    (`_tryCompileCascadeBlock`, keyed on `LetBinding.metadata['kind'] ==
    'cascade'` — never on the Block's shape alone) and emits native `..` /
    `?..` syntax instead. Strictly additive: any Block that does not carry the
    tag, or whose result is not the bound name, keeps today's closure.
  - **Generic type-parameter erasure across a cascade return**
    (`async/lib/src/stream_sink_transformer/typed.dart`: `StreamController(sync:
    true)` inferred as `<S>` from the enclosing `StreamSink<S> bind(…)`).
    `_encodeInstanceCreation` only ever read type arguments written in SOURCE
    syntax; it now also reads what the analyzer INFERRED
    (`_inferredTypeArgsSource`, from `expr.staticType`) and feeds it through the
    SAME `_setTypeArgsMetadata` / `_setTypeArgsField` pair the explicit
    `Map<String, String>.from(...)` path has always used. Guarded twice: an
    all-`dynamic` inference is skipped (pure noise), and anything that is not
    plain writable type syntax (function types, record types, `InvalidType`)
    disqualifies the whole annotation rather than emitting a half-correct one.
    Gated behind `prepareStaticTypes()` like every other slice, so
    `dart/self_host/engine.ball.json`, `dart/shared/ball_protobuf.json` and the
    conformance corpus are provably byte-identical.

  After #573 the remaining #488 rows shared no mechanism with it, and none of
  them was a receiver-TYPE question at all — `PackageEncoder
  .prepareStaticTypes()` had closed every row that was. Three of the four were
  fixed in the #488 wrap-up slice, and NONE of them is gated on resolved types
  (the first two are pure syntax; the third is compiler codegen):
  - **A `?.` in the MIDDLE of a postfix chain guards the WHOLE remainder.**
    `x?.a.b(c)` is `x == null ? null : x.a.b(c)`, never
    `(x == null ? null : x.a).b(c)`. `_buildNullAwareAccess`/
    `_buildNullAwareCall` are leaf-level and cannot see the link that follows,
    so the guard collapsed one link early and every following link was applied
    UNCONDITIONALLY to its result — an ENGINE-semantics bug (on a null receiver
    every engine called the next link on `null`), not only a Dart-recompile one.
    `_encodeNullAwareChain` now walks the chain outer→inner, hoists the DEEPEST
    short-circuiting link's guard to cover everything above it, and re-encodes
    the chain once with that link marked plain (`_hoistedNullAware`) and its
    receiver bound (`_chainSubstitutions`). One guard is hoisted per pass, so
    `a?.b?.c.d()` lowers to nested guards, deepest first, and the recursion
    terminates. A promotable receiver is named directly; a field/getter/call is
    bound to a `__nachain_N` temporary — the same rule as `_nullAwareNeedsTemp`.
    Measured on `async/lib/src/cancelable_operation.dart`; guarded by
    `dart/encoder/test/null_aware_chain_scope_test.dart` and conformance fixture
    `471_null_aware_chain_scope`. **Syntactic, so it applies to
    `encode(String)`** — unlike every earlier #488 slice it CAN move
    `dart/self_host/engine.ball.json` and the committed TS/Go artifacts. It did
    not: the engine's own source happens to contain no multi-link `?.` chain
    today (verified by regenerating all four artifacts). Do not assume that
    stays true — regenerate rather than reason about it.
  - **`toList(growable: …)` declines its route** — the last member of the
    "arity window wider than the std function" family below.
    `std_collections.list_to_list`'s codegen is `'<list>.toList()'`, full stop,
    so a `(0, 1)` window could only DROP the operand and hand back a growable
    list where the source asked for a fixed-length one. Measured on
    `collection/lib/src/wrappers.dart` (`set.toList(growable: false).add(…)`
    must throw `UnsupportedError`; after the drop it silently succeeded).
    Window is now `(0, 0)`; see **#673**.
  - **`std_collections.map_contains_value` had no case in the DART compiler**
    — declared, encoder-routed, engine-implemented and present in every other
    compiler, it alone fell to `_ => '/* unsupported: … */'`, i.e. a COMMENT
    where an expression belongs (`collection/lib/src/wrappers.dart` compiled to
    `return /* unsupported: std_collections.map_contains_value */;`).
    `dart/compiler/test/base_call_dispatch_completeness_test.dart` is the
    compiler-side mirror of `check_encoder_completeness.dart`, and since **#654**
    its population is the DECLARED set with no exclusion — see the
    "closed set over the builders" bullet above.

  Still open, each with its own issue and its own measured repro:
  - `collection/lib/src/list_extensions.dart` — the compiler marks a
    non-nullable final field `late` whenever it has no inline initializer,
    which is wrong when the CONSTRUCTOR'S OWN INITIALIZER LIST already assigns
    it, and the stray `late` then collides with a user-declared setter of the
    same name (`DUPLICATE_DEFINITION`). Ball's field IR cannot tell "assigned
    by the initializer list" from "assigned in the constructor body". **#651**
    (a sibling of #573: the same "IR too coarse to tell two source shapes
    apart" family). That file needs a SECOND fix to go green: `ListSlice`
    declares a `final length` field next to an explicit `set length`, and the
    engine's `_trySetterDispatch` suppresses the setter whenever the instance
    carries a field of that name — right for a non-final field (#501, fixture
    `432_shadowed_getter_setter_write`), wrong for a final one, which
    contributes no setter of its own: **#664**.
  - `collection/lib/src/iterable_extensions.dart` — **`Ext(receiver).member`
    encodes by NAMING the extension member, and MUST NOT be erased to
    `receiver.member`.** An extension override is written precisely when the
    plain access would resolve to something else:
    `IterableComparableExtension.isSorted([compare])`'s body is
    `return IterableExtension(this).isSorted(compare);`, and erasing it makes
    the method call ITSELF. Tier B measured the erasure at `1706 → 1702
    passing, 4 failing` — a loud build error traded for a silently wrong
    answer. The encoder's slice of **#670** encodes the override as a
    `FunctionCall` whose `function` is the extension member's own Ball name
    (`<module>:<Ext>.<member>`) with the receiver in `self`, and the Dart
    compiler re-emits `Ext(receiver).member(args)` from the `kind: 'extension'`
    typeDef — no schema change, because the NAME carries the selection (the
    design record is in `docs/METADATA_SPEC.md`, "Extension overrides ride the
    function NAME"). Whether `()` is emitted comes from the member's own
    `is_getter`, the same accessor-shape family as #501/#664. It is a
    RESOLVED-AST-only path (`parseString` reads `Ext(x).m()` as a call on a
    constructor invocation), so `encode(String)`,
    `dart/self_host/engine.ball.json` and the conformance corpus never reach
    it. `<module>` is the DECLARING module, resolved from the override's own
    element (`_extensionOwnerModule`) against the `library URI → module` map
    `PackageEncoder.prepareStaticTypes()` records — so an extension in ANOTHER
    file of the package works, and so does an import PREFIX (a prefix is a
    spelling of the same library, not a different selection). The Dart compiler
    restores the prefix from `_dartModuleAliases[call.module]` and scans EVERY
    module's typeDefs for `kind: 'extension'`, not just the one being compiled.
    An override this encoder cannot name soundly — type arguments on the
    EXTENSION (`Ext<int>(x)`), a NULL-AWARE override (`Ext(x)?.m()`, whose `?`
    the override branch would drop because it runs before the null-aware
    lowering: "skip the call" silently becoming "call it on null"), or an
    extension NO module of this encode declares — stays a LOUD refusal (a
    warning naming the construct plus the `/* unsupported: … */` placeholder).
    The ENGINES already dispatch the qualified name by ordinary module-function
    lookup (pinned by running the cross-module program on the reference engine
    in `test/extension_override_test.dart`); the non-Dart COMPILERS still strip
    everything before the last `:` and in fact read `kind: 'extension'` nowhere
    at all, so extension DECLARATIONS have to come first there — that
    remainder, and the conformance fixture that depends on it, is the rest of
    #670. Two neighbouring shapes are NOT refusals and each had its own silent
    failure: type arguments on the MEMBER (`Ext(x).m<int>()`) ride
    `FunctionCall.typeArgs` like any other instance call — dropping them
    reified `List<dynamic>` — and a WRITE (`Ext(x).m = v`, `+= 1`, `++`)
    encodes as the same `self`-carrying call, so the compiler reads
    `is_setter` alongside `is_getter` (`_extensionAccessorFunctions`);
    emitting the method shape for a setter-only member produced
    `Ext(x).m() = v`, and the `FormatterException` that escaped
    `DartCompiler.compileModule` took the WHOLE module's output with it.
  - `collection/lib/src/wrappers.dart` — **`x.isNotEmpty` is its own member,
    never `!x.isEmpty`** (**#674**, fixed). The rewrite changed WHICH member a
    DELEGATING receiver is asked for — `collection`'s `wrapper_test.dart`
    records the forwarded `Invocation` symbol, and Tier B measured 5 failures
    of the form `Expected: Symbol("isEmpty") Actual: Symbol("isNotEmpty")`. The
    receiver-type seam cannot fix this one: the delegate's static type IS a
    `dart:core` `Iterable`. So `std.string_is_not_empty` is declared alongside
    `string_is_empty` and implemented on every target (polymorphic over the same
    receivers), and `_directGetterRoutes` routes `isNotEmpty` straight to it.
    Guards:
    `tests/conformance/474_is_not_empty_receivers` (cross-target) and
    `dart/encoder/test/is_not_empty_member_identity_test.dart`, which RUNS a
    recording receiver through `dart run` before and after the round trip —
    member identity is behavioural, so only executing it can see a change.
    Same root, other direction: the `.isEmpty` rewrite consulted no receiver
    type at all, so an instance FIELD named `isEmpty` was answered by
    `std.string_is_empty` on every engine — **#697 half A**, the last member of
    #488's receiver-type family and the only one outside its 16-file table; the
    receiver-type seam that fixes it is the next bullet.

- **A member the RECEIVER'S OWN TYPE declares beats the built-in accessor route
  of the same name (#697 A).** The encoder diverts ten getter names onto `std` /
  `std_collections` base calls BY NAME — `_directGetterRoutes` plus the three
  composites, and `DartEncoder.builtinAccessorGetters` is the closed set of all
  ten. Before #697 that route consulted nothing, so a class declaring
  `int isEmpty` encoded `b.isEmpty` as `std.string_is_empty(b)` and the program
  carried **no `fieldAccess` for the user's member at all**: every engine
  faithfully ran the wrong program and agreed on the wrong answer (`false` where
  `dart run` says `44`). It was the last member of #488's receiver-type family
  and the only one outside its 16-file table.
  `_userMemberShadowsBuiltinAccessor` is the seam, and it suppresses the route
  only on PROOF, by either of two routes — RESOLVED (`lookUpGetter` on the
  receiver's static type resolves the member outside the SDK) or SYNTACTIC (the
  receiver's declared type name is a class/mixin/enum/extension-type THIS unit
  declares that declares the member, walking
  `extends`/`with`/`implements`/`on` within the unit). No proof ⇒ the route
  stands exactly as before, which is what keeps it a refinement: the SYNTACTIC
  half matters because `generate_conformance.dart` and every self-host
  regeneration parse with `parseString`, where `staticType` is null.
  **`this` and `super` are the two receivers whose type is TRIVIALLY provable,
  and the first cut of the seam consulted neither** — so `this.isEmpty` inside
  the very class that declares `isEmpty` still encoded as
  `std.string_is_empty(self)` and every engine still answered `false` where
  `dart run` says `44`. `_enclosingThisTypeName` answers `this` (the enclosing
  class/mixin/enum/extension-type, and inside an EXTENSION the type it is
  declared `on` — `extension R on String` must keep its route, since there
  `this.isEmpty` IS `String.isEmpty`), and it lives in
  `_syntacticReceiverTypeName` rather than at the call site so the binding walk
  reaches it too (`var me = this; me.isEmpty`). `super` cannot ride that
  single-name channel — it denotes a DIFFERENT type from the enclosing
  declaration and a mixin's `on` clause may name several — so
  `_enclosingSuperTypeNames` answers a LIST (a class's `extends` clause, a
  mixin's `on` constraints) and never the enclosing declaration's own name: a
  class declaring `isEmpty` itself says nothing about whether its SUPERCLASS
  does, and `super.isEmpty` asks only the latter. One decline is deliberate and
  pinned: an extension type's REPRESENTATION parameter is not a declaration
  here, because the encoder models it nowhere — it reaches neither the
  descriptor nor `metadata['fields']` — so believing in it at this one site
  would be the only place in the encoder that does. Its BODY members are
  consulted normally. Guards:
  `tests/conformance/476_user_member_named_like_builtin_accessor`
  (cross-target, and it pins the `String`/`List`/`int`/`double` receivers whose
  route must survive) and `dart/encoder/test/builtin_accessor_user_member_test.dart`,
  which derives its cases per name from `builtinAccessorGetters` — add a route
  without the seam and that gate fails with no test edit. Its per-NAME matrix
  covers FIELD / GETTER / INSTANCE-CREATION / INHERITED / `this.` / `super.`
  plus the `dart:core` control whose route must survive; the receiver SHAPES
  that are not per-name (mixin, `on`, enum, interface, extension, enclosing
  field, top-level variable, named constructor, and the declines) sit beside it.
  Its closed-set assertion is a floor at the MEASURED count of ten, not at a
  lower round number — a floor below the measured value stays green through the
  silent deletion of a route, which would silently shrink the matrix with it.
  The SYNTACTIC proof is
  unit-local by construction, so it cannot see a member declared in another FILE;
  `dart/encoder/test/builtin_accessor_resolved_receiver_test.dart` is the gate
  for the RESOLVED half alone (its subject file declares no type at all, so a
  pass there can only come from `prepareStaticTypes()`).
  **Where this meets #674**: a forwarding getter whose delegate's own type
  DECLARES the member (`bool get isNotEmpty => _base.isNotEmpty;` over a class
  that declares it) is exactly the proof this seam looks for, so it encodes as a
  `fieldAccess` naming the member rather than `std.string_is_not_empty`. That
  keeps #674's property — the receiver is asked for the member the source named —
  by the MORE direct means, and it is the only encoding that reaches the
  delegate's getter at all, since the polymorphic emptiness predicate knows
  nothing about a user instance. The real `wrappers.dart` shape is unaffected:
  its delegate is a `dart:core` `Iterable`, nothing is provable, and the route
  stands. `is_not_empty_member_identity_test.dart` pins BOTH receiver kinds, so
  neither direction can collapse onto `std.string_is_empty` unnoticed.
  **#697's half B is still open**: a MAP key named like a built-in accessor
  (`{'length': 99}.length` must be `2`, not `99`) shadows the map's own accessor
  on every engine. The reference engine can be fixed at its one lookup-order site
  — an instance carries `__type__`/`__methods__`/`__super__` and a map literal
  does not — but the SELF-HOSTED engines cannot inherit that fix: the accessor
  implementation itself reads `objectMap.length` / `.keys` / `.values`, which
  each target runtime resolves key-first on a `Map`, and flipping that order at
  the runtime layer is **not** correct either, because the same runtime resolves
  the self-host's proto VIEW (`listValue.values`, `Struct.fields`) and its
  instance maps (`_Scope.values`) through the identical path — measured: the flip
  turns the Go sweep from 358/358 to 100+ failures. Closing B needs an
  unambiguous map-accessor primitive for the self-host (the `ball_proto` family
  already has the shape — `getStructFieldKeys` — but no encoder route), i.e. a
  representation decision across six runtimes.

- **The `async` safety return must type-check under `strict-casts`.** Every
  `async`, non-generator, non-`void` function gets a trailing statement so
  Dart's flow analysis accepts a body whose Ball IR already returns. It used to
  be `return null as dynamic;` unconditionally, which
  `analyzer: language: strict-casts: true` rejects — `dynamic` is not
  implicitly assignable to a non-dynamic type, and unreachable code is still
  type-checked (`dart-lang/async`'s own `analysis_options.yaml` sets it, which
  is how `async/lib/src/stream_queue.dart` and `async/lib/src/async_cache.dart`
  failed). `_asyncSafetyReturn` splits THREE shapes: a NULLABLE (or `dynamic`)
  result keeps a plain `return null;` — falling off the end really does produce
  null there, so a throw would be a behaviour regression — a CONCRETE
  non-nullable result gets a `Never`-typed
  `throw StateError('unreachable: …')`, which is assignable to every return
  type, and a BARE TYPE PARAMETER gets neither (**#766**).
  `dart/compiler/test/strict_casts_safety_return_test.dart` is the only gate in
  the repository that runs `dart analyze` under non-default analysis options.
  **A bare type parameter is not a non-nullable type — it is a type VARIABLE,
  and the caller's type argument decides (#766).** The first cut read
  nullability off the SPELLING, so `Future<T> maybe<T>() async` landed in the
  throwing arm; at `maybe<int?>()` the declared result is `Future<int?>`,
  falling off the end really does produce `null`, and the pre-#647 line
  (`return null as dynamic;`) returned exactly that — so #647 turned a
  null-returning program into an unconditional `StateError`, a real behaviour
  change rather than the unreachable-by-construction cleanup the doc comment
  claimed. `_asyncSafetyReturn` now takes the type-parameter names IN SCOPE
  (`_typeParamsInScope`: the enclosing class/mixin/enum/extension/
  extension-type's `metadata['type_params']`, unioned with the method's or
  local function's own, maintained by `_withTypeParams` and the `declMeta`
  argument of `_withClassContext`) and emits, for a declared result that is one
  of those names, a statement that ASKS at run time:
  `return null is T ? null as T : throw StateError('unreachable: …');`.
  `null as T` is an EXPLICIT cast, so `strict-casts` accepts it where the
  implicit `dynamic` → `T` conversion was #488's very error, and the
  conditional's static type is `T` (`UP(T, Never)`). Keying on the in-scope SET
  rather than on the spelling is what keeps a user class literally named `T` on
  the concrete shape. `dart/compiler/test/generic_async_safety_return_test.dart`
  is the guard, and it measures BEHAVIOUR — it RUNS the emitted Dart at
  `T = int?` (must print `null`, exit 0) and at `T = int` (must still fail
  loud) — because the throwing and returning shapes are indistinguishable by
  reading the source for a `throw`.
- **An arity window may never be WIDER than the std function it stands for.**
  A route whose `maxArgs` admits an argument the target function does not
  declare silently DROPS that argument — the compiler emits exactly the
  operands the function models and nothing warns. Four routes had this before
  #488 slice 2: `indexOf` (1,2), `startsWith` (1,2), `lastIndexOf` (1,2) and
  `replaceFirst` (2,3), all now narrowed so the extra-operand form declines to
  the generic method-call encoding — plus `toList` (0,1), the fifth and (as of
  the #488 wrap-up) last, found the same way and narrowed to (0,0) (#673).
  Every OTHER variable-arity route was re-audited against its codegen at the
  same time: `join`, `sublist`, `sort`, `substring`, `padLeft`/`padRight` and
  `toStringAsExponential` all consume their optional operand. `indexOf` was the worst: `arg0` and `arg1`
  BOTH renamed to `'value'`, so the second overwrote the first in the
  compiler's field map and `path.indexOf('\', 2)` compiled to
  `path.indexOf(2)`. When you add or widen a `collectionRoutes` entry, check
  the compiler's codegen for that name actually consumes every operand the
  window admits — `_methodCall2` emits exactly two, `_compileStringReplace`
  exactly three. The engine's GENERIC instance-method dispatch
  (`engine_control_flow.dart`) is what then has to implement the declined
  form, and it must do so PORTABLY: a two-argument `indexOf`/`startsWith`
  written inside the engine's own source would be declined by this very rule
  when the engine is self-hosted, so compose from `substring` plus the
  one-argument overload instead.
- **A name the encoder ROUTES to must be DECLARED by the canonical builder.**
  `dart/shared/test/std_routed_declarations_test.dart` re-derives every
  `('std'|'std_collections', '<fn>', …)` tuple from `encoder.dart` and asserts
  it is a subset of `buildStdModule()` / `buildStdCollectionsModule()`. Nothing
  else can see that drift — runtime never reads `std.json` (each encoder builds
  a program's `modules[]` from the names it used, so fixtures self-describe),
  `check_encoder_completeness.dart` checks the opposite direction, and
  `gen_std_coverage.dart` derives its canonical list from the same builders.
  That blind spot hid thirteen routed-but-undeclared functions until #505.
  **The REVERSE direction is gated too, by
  `dart/shared/test/std_reverse_closed_set_test.dart` (#702):** every base
  function the engine's `StdModuleHandler` DISPATCHES, every key of
  `buildCapabilityTable()`, and every `isBase` function an executed conformance
  fixture declares must be declared by a builder. `collectionRoutes` is only one
  consumer, so the #505 gate could not see the 30 language constructs
  (`map_create`, `typed_list`, `switch_expr`, `invoke`, `paren`, `cascade`, …)
  every encoder emitted through a different code path. Read the two as a PAIR.
  **A `_fn(...)` added here must be ported to the two hand-maintained mirrors in
  the same PR** — `csharp/shared/src/StdModuleBuilders.cs` and
  `rust/shared/src/std_*_module.rs`. Both are gated name-for-name against this
  Dart source (`csharp/shared/test/StdModuleBuilderTests.cs`,
  `rust/shared/src/std_dart_parity.rs`), so a Dart-only change turns those jobs
  red. Go, Python, TypeScript and C++ have no std module builders and need
  nothing.
- **Constructor vs function call** is decided by the first *letter* (skipping a
  leading `_`): `Foo()`/`_Foo()` → `MessageCreation`; `foo()`/`_foo()` → `call`.
  (A prior bug treated every `_`-prefixed name as a constructor — `'_'.toUpperCase()`
  is `'_'` — silently mis-encoding all private top-level function calls; fixed via
  `_looksLikeTypeName` in `encoder.dart`.)
- Prefer plain `Map`/`List`/`String`/`int` data and top-level functions; avoid heavy
  class hierarchies. When something runs as Dart unit tests but misbehaves through
  the engine, suspect a syntactic-encoding mismatch and diff the encoded program.

#### Null-aware collection elements (Dart 3.8 `?x`)

`[1, ?x]`, `{1, ?x}`, `{?k: v}` and `{k: ?v}` all encode (issue #494 Bug B).
`_encodeCollectionElement` desugars them to `collection_if(x != null, x)` — the
same shape `[if (x != null) x]` produces — so no engine needed a new base
function. Dart evaluates a null-aware operand **exactly once** and
**short-circuits** (`{?k: v()}` does not evaluate `v()` when `k` is null), so an
operand that is not syntactically pure is first bound with a synthetic
`collection_for` over a one-element list; a pure operand (identifier, property
access, literal, `this`, `!`, `as`) is simply repeated in the guard. The map
forms carry their `?` on the `MapLiteralEntry` itself (`keyQuestion` /
`valueQuestion`), not on a distinct node type — before #494 those markers were
silently DROPPED, so `{?k: 20}` with a null key produced the entry `null: 20`.

#### `runtimeType` → `std.type_of` (#489)

`<expr>.runtimeType.toString()` — and ONLY that exact chain — encodes to
`std.type_of(value: <expr>)`. A bare `x.runtimeType`, an interpolated
`'${x.runtimeType}'` and a null-aware `x?.runtimeType.toString()` are
deliberate carve-outs; the table in `dart/encoder/AGENTS.md` says why, and
`dart/encoder/test/type_of_test.dart` pins all four. `type_of` returns the BASE
type name (generics dropped, module prefix stripped) — never Dart's own
`List<int>` / `_Map<String, int>` spelling, which no other target can
reproduce. Do NOT write the `.runtimeType.toString()` chain inside
Ball-portable engine/runtime source: it now IS `std.type_of`, so a helper that
falls back to it would call itself in every compiled self-hosted engine. Use
`'${v.runtimeType}'` there instead.

### Engine
- `BallEngine.run(Program)` → executes, returns captured stdout
- Scoping via linked `Scope` chain (lexical scoping with parent pointers)
- `StdModuleHandler` dispatches all universal std base functions
- Flow signals (break, continue, return) propagate via `FlowSignal` objects
- Custom modules via `BallModuleHandler` abstract class
- **A constructor may legitimately construct its own class** (#499). Both
  `_evalMessageCreation` guards that stop `Foo() is Foo` from recursing forever
  key on `__constructor_type__ == msg.typeName` **AND**
  `_isBareSelfConstruction(msg)`: a construction carrying a positional `argN`
  or a field naming one of the constructor's declared parameters is a REAL
  construction and must invoke the constructor. Only field-initializer-shaped
  self-references (`Foo.new` → `messageCreation Foo{}` / `Foo{_x: 5}`) resolve
  to `self`. Keying on the type name alone silently turned every
  `next = Chain(depth - 1)` into an infinite self-cycle. The positional test is
  `^arg\d+$`, never an `arg` PREFIX: a class whose own field is named
  `argCount` emits `Foo{argCount: 5}` as its field-initializer self-reference,
  and a prefix match reads that as a real construction and recurses forever.
- **A constructor's initializer list runs even when it has a body.** Dart runs
  `Foo(a) : x = a { … }`'s initializer list before the body, so
  `_applyConstructorInitializers` fires on both instance-building paths
  (`_evalMessageCreation` and `_callObjectConstructor`), not only for body-less
  constructors. A string-literal initializer is stored as SOURCE text
  (`label = 'pt'` → `"'pt'"`) and its quotes must be stripped.
- **A constructor TEAR-OFF (`ClassName.new(args)`) is not the construction
  path (#531).** The encoder emits it as a generic self-carrying method call
  (`{function: "new", input: {self: Reference(Cls), arg0: ...}}`), never as a
  `messageCreation`, so it lands in `_evalCall`'s class-reference dispatch
  rather than in `_evalMessageCreation`. Three consequences the fix pins:
  (a) a BUILT-IN exception name (`FormatException`) has no `TypeDefinition`,
  no registered constructor and no static method, so `_evalReference`'s
  class-reference test rejected it and resolution fell through to
  `scope.lookup` - `Undefined variable: "FormatException"`. It is now accepted
  from the EXPLICITLY enumerated `_builtinExceptionNames`; never widen that to
  "any unbound upper-case identifier", which would swallow a real typo.
  (b) with no registered constructor the class-ref dispatch has nothing to
  call, so `call.function == 'new'` builds the same generic instance the
  typeDef-less `messageCreation` fallback produces
  (`{...args, __type__: '<module>:<Class>'}`) - which is exactly what
  `std.throw`'s `arg0 -> message` rename consumes.
  (c) a BODY-LESS constructor reached this way goes through
  `_buildConstructorInstance`, which never applied the class's own inline
  field initializers - `Counter.new()` produced an instance with no `n` field
  at all while `Counter()` worked. It now calls `_initFieldDefaults` like the
  `messageCreation` path does.

- **"Single-threaded" describes WHEN a `std_concurrency` body runs, never what
  the operations ANSWER (#608).** The old block in `engine_std.dart` fabricated
  results — `atomic_store` discarded the write, `atomic_load` echoed its own
  call input, `atomic_compare_exchange` returned an unconditional `true` (so a
  CAS retry loop exited on its first iteration with the wrong answer), and
  `thread_spawn` returned the literal `0` for every thread — and because the
  other six engines are compiled from this source, all seven agreed on the wrong
  answer. There are now three real tables (`_threadJoined`, `_mutexLocked`,
  `_atomicCells`) keyed by an OPAQUE 1-based handle, and every misuse (joining
  twice, locking a locked mutex, unlocking an unlocked one, naming an unminted
  handle) raises a `BallRuntimeError`. They are LISTS, not int-keyed maps, on
  purpose: this file is compiled into six other engines and a list index has one
  representation on every target. `tests/conformance/477_std_concurrency_handles`
  is the cross-target guard; `dart/engine/test/std_concurrency_test.dart` holds
  the fail-loud half. See `docs/TESTING_STRATEGY.md` §5c.
  **`sandbox: true` gates none of it.** `_checkSandbox` is called from exactly
  three `std_io` handlers (`exit`, `panic`, `env_get`) and the `std_fs` family;
  no `std_concurrency` handler consults it, so every function in this module
  runs freely under a sandboxed engine. That is deliberate — a handle table and
  an eagerly-run body touch no host resource — but it means the ONLY way to
  withhold the module is to leave it out of `StdModuleHandler.subset(...)`,
  which is a Dart-embedder knob and has no equivalent on the compiled targets.
  **`scoped_lock` releases when the body RETURNS, not when it throws.** All four
  implementations (this file, and the Dart/TS/C++ compiler preambles) unlock
  with a plain statement after the body call, so a throwing body propagates with
  the mutex still held and the next lock on that handle fails loud — consistent
  everywhere, never a silent wrong answer, but the declaration still says
  "release on exit". Issue #769 tracks making the two agree with a fixture; do
  not "fix" one implementation alone, or the targets stop agreeing.
  **An ASYNCHRONOUS body is awaited by this engine and refused by the compiled
  targets.** `_concurrencyPreamble` (Dart) and `BALL_CONCURRENCY_RUNTIME` (TS)
  both throw when the body answers a `Future`/thenable, while `engine_std.dart`
  awaits it — deliberate and fail-loud on every side, but a real
  interpreted-versus-compiled split that `477_std_concurrency_handles` does not
  reach. Issue #770.
- **A field write asks whether the field's own DECLARATION contributes a setter,
  not whether the instance carries that key (#501 + #664).**
  `_trySetterDispatch`'s guard used to be a bare
  `if (object.containsKey(fieldName)) return _sentinel;`. That is right for a
  NON-final field (it declares its own setter, which overrides an inherited one
  — fixture `432_shadowed_getter_setter_write`) and wrong for a `final` one,
  which declares a getter and NOTHING else: a setter written beside it is the
  only setter for that name, and the guard silently overwrote the `final` field
  instead of running it (fixture `470_setter_beside_final_field`). Finality is
  read from `TypeDefinition.metadata['fields'][i]['is_final']` into
  `_declaredFieldIsFinal`, registered on BOTH module paths (`_buildLookupTables`
  AND `engine_invocation.dart`'s lazy import resolution — a class reached through
  a lazily resolved import must answer the same), and
  `_nearestFieldDeclarationIsFinal` answers from the FIRST class up the
  `__super__` chain that declares the field. Never consult `is_late`: the Dart
  COMPILER emits `late final` for a final field the initializer list assigns
  (#651), so the answer would depend on whether the program had been
  round-tripped through it. This is metadata the engine DISPATCHES on —
  deliberate and bounded, see `docs/METADATA_SPEC.md`'s "Accessor shape" and
  `dart/engine/AGENTS.md`.

- **`arg0` is the sole argument only when it is the bag's ONLY argument
  (#740).** A call site that knows the callee's parameter names packs
  `{name: …}`; one that does not — a first-class `invoke`, or a target compiler
  that lowered every Ball function to one taking the whole message — packs
  `{arg0: …, arg1: …}`. `engine_invocation.dart`'s SINGLE-parameter binding
  path used to unwrap `arg0` out of any bag that carried it, which lost data in
  two shapes: a callee whose sole parameter IS the whole message (the shape
  every re-encoded compiler output has, reading `input["a"] ?? input["arg0"]`
  out of it) saw only the first argument, and a callee whose sole parameter is a
  genuine map/record carrying an `arg0` key of its own saw that key's value
  instead of the record. `_isSinglePositionalArgBag` now gates the unwrap on the
  bag carrying `arg0` and nothing else (engine-internal `__`-prefixed keys
  excepted); every other bag reaches the sole parameter WHOLE. By-name
  extraction is still checked first and is unaffected. The guard is
  `dart/engine/test/single_param_input_bag_test.dart` — the shape is not
  producible from Dart source, so no generated `tests/conformance` fixture can
  express it. The `self`-keyed twin (a 1-parameter callee whose input map
  carries `self`) is a DIFFERENT and genuinely ambiguous case and is still open;
  see `.claude/rules/csharp.md`.

- **An assignment the engine cannot perform is an ERROR, never a dropped write
  (#742).** `engine_control_flow.dart`'s `_evalAssign` and
  `_evalNullAwareAssign` write through exactly three `std.assign` target shapes
  — a bare `reference`, a `fieldAccess` whose object reads as a map, and a
  `std.index` call over a list/map. Every other shape fell out of all three
  branches into a bare `return val;`, so the write was never performed and the
  RHS was handed back as if it had been: a caller could not tell a dropped write
  from a successful one, on ANY target (this is engine source, so all seven
  engines agreed on the silent no-op). Every such path now throws a
  `BallRuntimeError` built by `_assignErrorMessage`, naming what could not be
  done — the unsupported shape, the field written on a non-object, the
  container/index pair that is not indexable, or the missing
  `target`/`value`/`index` field. Under `??=` the prefix carries the operator
  (`std.assign (??=): …`); there is no separate `std.assign_null_aware` base
  function, `??=` is `std.assign` with `op: '??='`. The shape name comes from an
  EXHAUSTIVE `switch` over `Expression_Expr`, so a new oneof case in
  `ball.proto` is a compile error here rather than a silently unnamed shape.
  Guards: `engine: assign to an unrecognised target fails loud (#742)` in
  `dart/engine/test/engine_test.dart` (one case per rejected shape under both
  `=` and `??=`, plus a closed-set completeness check derived from
  `Expression_Expr.values`) and, from the other side,
  `engine_wave5_control_flow_coverage_test.dart`'s `null-aware index assign on
  a non-indexable target throws` — which until #742 asserted the no-op's `'x'`,
  i.e. a coverage test had PINNED the bug. No conformance fixture can reach
  these paths: no encoder emits such a target, which is why the corpus never
  saw it.

- **The ordered-set representation probe is `is BallRawMap`, never `is Map`
  (#557).** `_ballValueIsSet` in `engine_types.dart` asks "is this value the raw
  `Map<String, Object?>` my `{'__ball_set__': [...]}` representation is built out
  of?", which is a DIFFERENT question from a user program's `x is Map` — and
  since #528/#553 the Rust/C#/C++ targets answer `false` to the latter for a set,
  by design. Asking with `is Map` made the probe permanently false there, so
  `_ballSetItems` returned a COPY and every in-place set mutation the engine
  performed (`set_add`, `set_remove`, `list_clear` on a set, the `Set.add`/
  `.remove` method dispatch) was silently lost. `BallRawMap` is a typedef for
  that raw map; each runtime answers it structurally. For the same reason
  `_ballSetItems` reads the tag through the `is BallRawMap` PROMOTION and not
  through `v as Map`: Rust's `ball_as` and C#'s `BallRuntime.AsType` check the
  cast against the same set-excluding `is Map` answer and would throw on the very
  value the probe just identified. Conformance fixture
  `462_set_mutation_in_place` is the guard.

## Generated Files — NEVER Edit

- `dart/shared/lib/gen/**` — Protobuf generated types
- `dart/shared/std.json` — Generated from std.dart via `dart run bin/gen_std.dart`
- `dart/shared/std.bin` — Binary protobuf version of std

## Testing

- Tests in `dart/engine/test/engine_test.dart`
- Use `buildProgram()` helper for minimal test programs
- Use `runAndCapture()` to execute and capture stdout
- Use `loadProgram()` to load .ball.json files from examples/
- **Every new encoder-emittable construct needs a `tests/conformance/src/*.dart`
  fixture** — gated by `check_encoder_completeness.dart` (forward completeness)
  and `check_fixture_names.dart` (no false coverage). The conformance oracle is
  native `dart run`, so fixtures verify Dart→Ball→engine ≡ real Dart. See
  `docs/TESTING_STRATEGY.md` (the issue-#55 post-mortem and the full ruleset).
- **Line coverage is a PR GATE (#605).** ci.yml's always-on `Dart Coverage
  Ratchet` job runs `dart run tools/coverage_dart.dart --floor 99.9` over all
  nine packages on every pull request. Adding a Dart line that no test reaches
  now fails CI — the same command was previously push-to-main-only in
  `coverage.yml`, so it went red for a week without blocking anything. Run it
  locally before pushing a `dart/` change; it is slow (~2.5 min) because it
  re-runs every package suite under the coverage collector.
- **Marking a line `// coverage:ignore-*` is a claim you must PROVE.** Use it
  only for a per-site, verified-unreachable defensive arm, with the caller
  analysis written beside it (which callers can reach it, and which argument or
  API contract rules the arm out) — never a file-level ignore, never on a line
  you have not read, and never in place of a test for a reachable path. A
  fail-loud `throw` that a program CAN trigger needs a test that triggers it.
  Worked examples: `dart/encoder/lib/package_encoder.dart`'s two
  `prepareStaticTypes` arms, and `dart/encoder/lib/encoder.dart`'s
  `_encodeCollectionElement` guard.

## Dependencies

- `protobuf: ^6.0.0` — Protobuf runtime
- `fixnum: ^1.1.1` — 64-bit integer support
- `code_builder` — Dart AST builder (compiler)
- `dart_style` — Dart formatter (compiler)
- `analyzer` — Dart parser (encoder)
