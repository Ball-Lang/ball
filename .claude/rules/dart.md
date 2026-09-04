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
  (issue #488 slice 1). `encode(String)` / `encodeModule(String, …)` parse with
  `parseString`, whose AST leaves `Expression.staticType` null — they are, and
  stay, resolution-free. `await PackageEncoder(dir).prepareStaticTypes()` before
  `encode()` swaps in analyzer-RESOLVED units, and the encoder then declines
  every `'list'`-flavored `collectionRoutes` entry whose receiver resolves to a
  `dart:core` `Set` (`_receiverIsSet`), letting the generic method-call encoding
  re-emit the source's own `s.add(x)`. It DECLINES rather than re-routing to
  `std_collections.set_add`: `set_add` is value-flavored (the Dart engine
  returns the NEW SET and the Dart compiler emits `s..add(v)`) — and it is
  bool-flavored on the TS engine, a live cross-target divergence tracked as
  issue #545 — so re-routing would reproduce the very `return s..add(x)` /
  `return_of_invalid_type` this fixed and import #545 along with it. `prepareStaticTypes()` is fail-soft —
  no `package_config.json` (never `pub get`-ed) means a warning and an
  unresolved encode, never an exception — and costs a multi-second analyzer cold
  start, so callers that do not need receiver types should not call it.
  Still misrouted, because the seam is not extended there yet: `String.contains`
  vs `Iterable.contains`, `Map…toList` vs `List.toList`, and nullable-receiver
  `!`/`?.`/`??` preservation (#488 slice 2).
- **A name the encoder ROUTES to must be DECLARED by the canonical builder.**
  `dart/shared/test/std_routed_declarations_test.dart` re-derives every
  `('std'|'std_collections', '<fn>', …)` tuple from `encoder.dart` and asserts
  it is a subset of `buildStdModule()` / `buildStdCollectionsModule()`. Nothing
  else can see that drift — runtime never reads `std.json` (each encoder builds
  a program's `modules[]` from the names it used, so fixtures self-describe),
  `check_encoder_completeness.dart` checks the opposite direction, and
  `gen_std_coverage.dart` derives its canonical list from the same builders.
  That blind spot hid thirteen routed-but-undeclared functions until #505.
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

## Dependencies

- `protobuf: ^6.0.0` — Protobuf runtime
- `fixnum: ^1.1.1` — 64-bit integer support
- `code_builder` — Dart AST builder (compiler)
- `dart_style` — Dart formatter (compiler)
- `analyzer` — Dart parser (encoder)
