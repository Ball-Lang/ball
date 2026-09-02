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
  rerouted into `std.string_split` / `list_index_of` / `to_int`. What the gate
  canNOT see is the RECEIVER TYPE, so a same-arity collision (`Set.add` vs
  `List.add`, `Map.toList` vs `List.toList`) is still misrouted — that is
  #488's remaining, resolver-backed half. `unaryRoutes` needs no window: its
  whole branch is already guarded by `args.isEmpty`.
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

### Engine
- `BallEngine.run(Program)` → executes, returns captured stdout
- Scoping via linked `Scope` chain (lexical scoping with parent pointers)
- `StdModuleHandler` dispatches all universal std base functions
- Flow signals (break, continue, return) propagate via `FlowSignal` objects
- Custom modules via `BallModuleHandler` abstract class

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
