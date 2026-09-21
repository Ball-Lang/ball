<!-- Parent: ../AGENTS.md -->

# encoder (`ball_encoder`)

## Purpose
Dart → Ball encoder. Parses Dart source with the `analyzer` package and emits a Ball `Program`, routing every construct through the universal `std` module. Full package + `pubspec.yaml` encoding.

## Key Files
| File | Description |
|------|-------------|
| `lib/encoder.dart` | `DartEncoder.encode(String source)` → Ball `Program` |
| `lib/package_encoder.dart` | `PackageEncoder` — whole Dart package dir → Program |
| `lib/pubspec_parser.dart` / `pubspec_manifest.dart` | pubspec.yaml parse/model |
| `lib/parts_resolver.dart` / `pub_client.dart` | `part` flattening, pub fetch |
| `bin/generate_conformance.dart` | Regenerate `tests/conformance/*.ball.json` from `src/*.dart` |
| `bin/check_encoder_completeness.dart` | CI gate: every emittable std fn has an executed fixture |
| `bin/check_fixture_names.dart` | CI gate: fixture name matches its content |
| `bin/gen_ball_protobuf.dart` | Regenerate `dart/shared/ball_protobuf.{json,bin}` |
| `tool/concat_engine.dart` | Flatten engine `part` files for self-encoding |

## For AI Agents
- Entry point: `DartEncoder.encode`. The encoder is **syntactic by default** (`parseString`, no static types) — dispatch by syntax/name heuristics; see the syntactic-encoder gotchas in `.claude/rules/dart.md` (e.g. `addAll` mis-routing, constructor-vs-call by first letter).
- **`PackageEncoder.prepareStaticTypes()` is the one opt-in that changes that** (#488 slices 1-2). `await` it before `encode()` and every in-package file is encoded from an analyzer-RESOLVED unit, so `Expression.staticType` is non-null and the receiver-type gate fires. It is fail-soft (a missing `package_config.json` yields a `warnings` entry, never an exception) and costs a multi-second analyzer cold start. `encode(String)` / `encodeModule(String, …)` are unaffected and stay resolution-free by design.
  - What the gate decides, once resolution is available: a `'list'`-flavored `collectionRoutes` entry is DECLINED when the receiver resolves to a `dart:core` `Set` (slice 1), `Map` or `String` (slice 2) — `_receiverIsSet` / `_receiverIsMap` / `_receiverIsString`, all three one call into `_receiverIsCoreType`. Declining hands the call to the generic method-call encoding, which re-emits the source's own call verbatim; it never re-routes to a different std function.
  - A null-aware receiver (`x?.foo`, `x?.m(…)`) that resolves to something Dart's flow analysis cannot PROMOTE — a field, a top-level variable, a getter — is bound to a temporary local first (`_nullAwareNeedsTemp`). The `std.if(equals(t, null), null, t.foo)` guard names the receiver twice, and Dart rejects the else-branch access outright when `t` is a non-promotable field. The temp-local path already existed for non-`Reference` targets; slice 2 only widened when it is taken.
  - A constructor call whose type arguments the SOURCE elided but the analyzer INFERRED (`StreamController(sync: true)` in a `StreamSink<S>`-returning method) records them through `_inferredTypeArgsSource` (#573). It reuses the explicit-syntax path's own `_setTypeArgsMetadata` / `_setTypeArgsField` pair — no new metadata key, no proto change — and declines twice over: an all-`dynamic` inference adds nothing, and anything that is not plain writable type syntax (function types, record types, `InvalidType`) disqualifies the whole annotation rather than emitting half of one.
  - An `ast.ExtensionOverride` (`Ext(receiver).member`) encodes as the NAMED extension member (`<module>:<Ext>.<member>` with the receiver in `self`) when this module declares the extension unprefixed, and is otherwise REPORTED and left to the `/* unsupported: … */` placeholder. It must NEVER be erased to `receiver.member`: the override is written precisely when the plain access resolves to a DIFFERENT member (#670, measured — erasing `collection`'s `IterableExtension(this).isSorted(compare)` makes it call itself, 4 real test failures). See "Extension overrides" below for the member-type-argument and write-position rules.
  - **`PackageEncoder` now propagates the per-file encoder's own `warnings`.** It used to report only its OWN resolution warnings, so every encoder-level diagnostic from a package encode was dropped on the floor — which is why the construct above could go unnoticed.
  - **Tier B is wired to this seam** (`tools/coverage-study/rq1_tierb.dart`'s `preparePackageCompileBack`). Until #488 slice 2 it called bare `DartEncoder().encode()`, so every receiver-type branch was structurally invisible to the only instrument that measures them. If you add a receiver-type refinement here, Tier B is where it shows up.
- **A built-in accessor route yields to a member the receiver's own type declares** (#697 A, `_userMemberShadowsBuiltinAccessor`). `DartEncoder.builtinAccessorGetters` is the CLOSED SET of the ten getter names the encoder diverts away from a plain `fieldAccess` — `_directGetterRoutes`' six (`sign`/`isNaN`/`isFinite`/`isInfinite`/`isEmpty`/`runes`, one `std` call each) plus the four composites (`isNotEmpty`, `isEven`, `isOdd`, `reversed`). It is the single source of truth for that routing, and `test/builtin_accessor_user_member_test.dart` derives one case per entry, so a route added without the seam fails that gate with no test edit. The seam suppresses a route only on PROOF, by either of two routes, because the encoder runs in two modes: RESOLVED (`InterfaceType.lookUpGetter` resolves the member to a declaration outside the SDK — the `prepareStaticTypes()` half) or SYNTACTIC (the receiver's declared type name is a class/mixin/enum THIS unit declares that declares the member, walking `extends`/`with`/`implements`/`on` inside the unit; the type name comes from an instance creation, an unresolved-AST constructor call, or the nearest binding of a simple identifier — local, formal parameter, field, top-level variable, mirroring `_isSinkReceiver`'s walk). Neither proof ⇒ the route stands exactly as before. The SYNTACTIC half is what makes this reach `encode(String)` — the mode `generate_conformance.dart` and every self-host regeneration use — so like the null-aware chain fix below it CAN move the committed artifacts (it did not: no class in `engine.dart`/`cli_core.dart` declares one of the ten names — regenerate rather than assume).
- **Null-aware CHAIN scope is NOT gated on resolution** (#488, `_encodeNullAwareChain`). `?.` is syntax, so the fix applies to `encode(String)` as well — and it is the one #488 slice that CAN move `dart/self_host/engine.ball.json` and the committed TS/Go artifacts (it did not: the engine's own source has no multi-link `?.` chain today — regenerate rather than assume). A `?.` short-circuits every link to its RIGHT, so the encoder hoists the deepest short-circuiting link's guard over the whole remainder of the chain and re-encodes it once with `_hoistedNullAware` (that link is plain now) + `_chainSubstitutions` (its receiver is already bound). One guard per pass, deepest first; the per-link `_buildNullAwareAccess`/`_buildNullAwareCall` still handle a one-link chain unchanged. See `.claude/rules/dart.md` and `test/null_aware_chain_scope_test.dart`.
- **`bin/check_encoder_completeness.dart` also reads the dispatch TABLES** (`_routeTables`). A base function named only in a `collectionRoutes`/`unaryRoutes`/… map VALUE reaches `..function =` through a variable, so the two emit-site regexes could not see it and the whole routed class was silently exempt from the gate (#488). Adding a route table means adding it there too; the scan exits non-zero if a declared table name no longer exists.
- Encoder changes hit user programs AND the self-hosted engine — verify every engine row of
  `conformance-matrix.yml`'s `summary` parity table, not Dart-only.
- Every new emittable construct needs a `tests/conformance/src/*.dart` fixture (gated). See `docs/TESTING_STRATEGY.md`.
- Tests in `test/`.

## Encoder carve-outs

### `runtimeType` → `std.type_of` (#489)

Exactly one Dart idiom maps to the universal `std.type_of` base function; the
neighbouring shapes are deliberate carve-outs, pinned by
`test/type_of_test.dart`:

| Dart source | Encoded as | Why |
| --- | --- | --- |
| `<expr>.runtimeType.toString()` | `std.type_of(value: <expr>)` | The only idiom yielding a plain type-name **string**, which is what `type_of` returns. Dart has no `typeof`; the TS encoder emits `std.type_of` for JS `typeof`. |
| `<expr>.runtimeType` (bare) | unchanged `fieldAccess(runtimeType)` | A `Type` **object**, not a string. Ball has no `Type` value. |
| `'${<expr>.runtimeType}'` | unchanged (`to_string(fieldAccess(…))`) | Never passes through `toString()` syntactically. Deliberately left alone: the reference engine's own `type_of` fallback is written this way, and mapping it would make that helper call itself in every compiled self-hosted engine. |
| `<expr>?.runtimeType.toString()` | unchanged (`null_aware_call`) | The `?.` short-circuit must survive. |

`std.type_of` returns the **base** type name — `int`, `double`, `String`,
`bool`, `List`, `Map`, `Set`, `Function`, `Null`, or a user class's short name —
with generic type arguments dropped and any module prefix stripped
(`main:Chain` → `Chain`). It is the string form of the discrimination `std.is`
already performs, so no new vocabulary was invented. It deliberately does NOT
reproduce Dart's own `runtimeType` spelling for collections (`List<int>`,
`_Map<String, int>`, `_Set<int>`): no target can do that without real generic
tracking. Conformance fixture `434_type_of` normalises those three shapes before
printing, so its golden is still the real `dart run` output.

### `StringBuffer` → the declared text sink (#630)

`StringBuffer` routes onto `std.sink_create` / `sink_write` / `sink_to_string`.
Before #630 it encoded as a generic constructor plus generic method calls that
the Dart and TS *engines* then special-cased by name — divergently (#633) — and
that the Rust/C#/Go/Python/C++ compilers did not implement at all.

The decision is **syntactic**, because it has to be: `generate_conformance.dart`
and every self-host regeneration parse with `parseString`, so `staticType` is
null and #488's receiver-type gate is unavailable. A receiver counts as a sink
only when the nearest enclosing scope declares that exact name as a
`StringBuffer`/`StringSink` — by type annotation, by a `StringBuffer(...)`
initializer, or as a formal parameter of that type. Pinned by
`test/string_sink_test.dart`, including the two carve-out directions (an
untracked receiver; a same-named local in a different function).

| Dart source | Encoded as |
| --- | --- |
| `StringBuffer()` / `new StringBuffer(seed)` | `std.sink_create` (`initial` when seeded) |
| `sb.write(x)` | `std.sink_write(sink, text)` — `x` wrapped in `std.to_string` unless it is a string literal |
| `sb.writeln([x])` | `sink_write` with `"\n"` appended (`core`'s own `writeln!` rule) |
| `sb.writeCharCode(c)` | `sink_write` over `std.string_from_char_code(c)` |
| `sb.toString()` | `std.sink_to_string(sink)` |
| `sb.length` / `.isEmpty` / `.isNotEmpty` | the existing `string_*` ops over `sink_to_string(sink)` |
| `sb.clear()` / `sb.writeAll(...)` | **carve-out** — unchanged generic method call; they stay on the engines' Dart-SDK method surface, which accepts the `std:Sink` tag as well as the legacy `:StringBuffer` one |

Two related consequences:

* A `StringBuffer`/`StringSink` **type annotation** is recorded in metadata as
  `dynamic` (`_portableTypeSource`). Metadata is cosmetic (invariant #2), and
  recording the Dart spelling would make the compiled-back Dart annotate a sink
  — a tagged map on every target — as a `StringBuffer` and fail to type-check.
* `String.fromCharCode(n)` now routes to `std.string_from_char_code`. That
  closes a round-trip hole the sink work exposed: the Dart COMPILER emits that
  exact spelling, and with no route back the compile → re-encode → engine leg
  turned it into a generic call carrying `self: reference("String")`, which no
  engine can resolve.

### `.isNotEmpty` → `std.string_is_not_empty` (#674)

`.isEmpty` and `.isNotEmpty` are SEPARATE base functions. The encoder used to
emit `std.not(std.string_is_empty(x))` for the second, which is
value-equivalent for a `dart:core` receiver and WRONG for a delegating one: the
rewrite changes which member the receiver is asked for, and a wrapper, a mock, a
proxy or a `noSuchMethod` forwarder sees the difference. `collection`'s
`lib/src/wrappers.dart` is built on exactly that shape, and its own
`wrapper_test.dart` asserts the forwarded `Invocation`'s symbol — Tier B measured
5 failures.

Note that the receiver-TYPE seam cannot decide this one: in `wrappers.dart` the
delegate's static type IS a `dart:core` `Iterable`. The member itself has to
round-trip, so `string_is_not_empty` is declared in `std.dart` next to
`string_is_empty`, polymorphic over the same receivers, and implemented by every
compiler and runtime. Guards: `tests/conformance/474_is_not_empty_receivers`
(cross-target) and `test/is_not_empty_member_identity_test.dart`, which RUNS a
recording receiver through `dart run` before and after the round trip.

### Extension overrides — `Ext(receiver).member` (#670)

Encoded as a `FunctionCall` whose `function` is the extension member's own Ball
name, `<module>:<Ext>.<member>`, with the receiver in the input message's `self`
field. The NAME carries which extension was selected, so it is semantic content
and survives metadata stripping — no schema change (the design record is in
`docs/METADATA_SPEC.md`, "Extension overrides ride the function NAME").

REFUSED, loudly, for every override this encoder cannot name soundly: an import
prefix (`p.Ext(x)`), explicit type arguments ON THE EXTENSION (`Ext<int>(x)` —
the call's structured `type_args` renders on the MEMBER, a different
instantiation), or an extension another module declares. A refusal warns naming
the construct and leaves the `/* unsupported: … */` placeholder, which breaks
the front end. Never erase an override to `receiver.member`: #670 MEASURED that
repair as 4 real test failures on `collection` — a loud build error traded for a
silently wrong answer.

Type arguments on the MEMBER (`Ext(x).m<int>()`) are a different thing and DO
round-trip: the invocation's own `<…>` lands in `FunctionCall.typeArgs`, the
same structured channel every other instance call uses, and the compiler
re-emits it. Dropping them was its own silent substitution — `conv<String>()`
came back as `conv()` and reified `List<dynamic>`.

A WRITE (`Ext(x).m = v`, `Ext(x).m += 1`, `Ext(x).m++`) encodes exactly like the
getter read — a `self`-carrying call wrapped by `std.assign` — so the ACCESSOR
SHAPE is the compiler's call, read from the member's own `is_getter`/`is_setter`
(`_extensionAccessorFunctions`). A setter-only member emitted as the METHOD
shape produced `Ext(x).m() = v`, which `dart_style` cannot parse: the exception
escaped `DartCompiler.compileModule` and the WHOLE module produced no output.
`test/extension_override_test.dart` pins both, by RUNNING the compiled-back
program.

Resolved-AST-only: `parseString` reads `Ext(x).m()` as a call on a constructor
invocation, so `encode(String)` / `encodeModule` never reach this path and
`dart/self_host/engine.ball.json` plus the conformance corpus are untouched by
it. `PackageEncoder.prepareStaticTypes()` is the opt-in.

## Dependencies
- Internal: `ball_base` (`ball_engine` is dev-only).
- External: `analyzer` (Dart parser), `yaml`, `pub_semver`, `http`, `archive`.
