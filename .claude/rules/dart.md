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

  What #488 still tracks after #573 is a different set of mechanisms again —
  `collection/lib/src/list_extensions.dart` (implicit-setter conflict),
  `collection/lib/src/wrappers.dart` (missing explicit return, unmasked once the
  receiver-type error ahead of it was fixed),
  `collection/lib/src/iterable_extensions.dart` (extension-override syntax,
  `IterableExtension(this).isSorted(…)`, encoded as an `unsupported:` placeholder)
  and `async/lib/src/cancelable_operation.dart` (`x?.a.b(…)` encoded as
  `(x?.a).b(…)` instead of `x == null ? null : x.a.b(…)` — the short-circuit
  scope is wrong, which is an ENGINE-semantics risk, not only a Dart-recompile
  one). None of them shares a mechanism with #573.
- **An arity window may never be WIDER than the std function it stands for.**
  A route whose `maxArgs` admits an argument the target function does not
  declare silently DROPS that argument — the compiler emits exactly the
  operands the function models and nothing warns. Four routes had this before
  #488 slice 2: `indexOf` (1,2), `startsWith` (1,2), `lastIndexOf` (1,2) and
  `replaceFirst` (2,3), all now narrowed so the extra-operand form declines to
  the generic method-call encoding. `indexOf` was the worst: `arg0` and `arg1`
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
