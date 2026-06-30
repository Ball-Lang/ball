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
- Entry point: `DartEncoder.encode`. The encoder is **syntactic** (`parseString`, no static types) — dispatch by syntax/name heuristics; see the syntactic-encoder gotchas in `.claude/rules/dart.md` (e.g. `addAll` mis-routing, constructor-vs-call by first letter).
- Encoder changes hit user programs AND the self-hosted engine — verify all three engines, not Dart-only.
- Every new emittable construct needs a `tests/conformance/src/*.dart` fixture (gated). See `docs/TESTING_STRATEGY.md`.
- Tests in `test/`.

## Dependencies
- Internal: `ball_base` (`ball_engine` is dev-only).
- External: `analyzer` (Dart parser), `yaml`, `pub_semver`, `http`, `archive`.
