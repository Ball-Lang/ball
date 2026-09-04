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
- **`PackageEncoder.prepareStaticTypes()` is the one opt-in that changes that** (#488 slice 1). `await` it before `encode()` and every in-package file is encoded from an analyzer-RESOLVED unit, so `Expression.staticType` is non-null and the receiver-type gate fires. It is fail-soft (a missing `package_config.json` yields a `warnings` entry, never an exception) and costs a multi-second analyzer cold start. `encode(String)` / `encodeModule(String, …)` are unaffected and stay resolution-free by design.
- Encoder changes hit user programs AND the self-hosted engine — verify all three engines, not Dart-only.
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

## Dependencies
- Internal: `ball_base` (`ball_engine` is dev-only).
- External: `analyzer` (Dart parser), `yaml`, `pub_semver`, `http`, `archive`.
