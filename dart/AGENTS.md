# Dart Implementation Agents

**Generated:** 2026-05-05 | **Commit:** e9d2668 | **Branch:** main

When working in the Dart packages. The Dart implementation is the **reference** — all other languages mirror it.

## Package Layout

| Package | Role | Has CLI? |
|---------|------|----------|
| `dart/cli` | User-facing `ball` CLI (run, compile, encode, audit, etc.) | Yes (`ball_cli:ball`) |
| `dart/compiler` | Ball → Dart code generation | Library only |
| `dart/encoder` | Dart source → Ball Program | Library only |
| `dart/engine` | Runtime interpreter (true async) | Library only |
| `dart/resolver` | Package manager (pub/npm adapters) | Library only |
| `dart/shared` | Protobuf types, std module, capability analyzer | Library only |
| `dart/self_host` | Engine self-encoded as Ball (CI artifact) | N/A |
| `dart/scripts` | Build/generation tooling | N/A |

All packages use workspace resolution (`resolution: workspace`). Run `dart pub get` from `dart/` root. Melos is configured at `dart/pubspec.yaml`.

## Testing

**Prefer conformance tests over unit tests.** A `.ball.json` fixture in `tests/conformance/` validates the Dart engine, C++ engine, TS engine, and all compilers simultaneously. Engine unit tests should be minimal — only for internal behavior not expressible as a Ball program (e.g., error handling edge cases, async scheduling, memory limits).

- Conformance: `dart run test -x slow` from compiler dir (runs ALL conformance fixtures)
- Engine: `cd dart/engine && dart test` — `engine_test.dart` has `buildProgram()`, `runAndCapture()`, `loadProgram()` helpers
- Compiler: `cd dart/compiler && dart test` — skip slow cross-language with `-x slow`
- Encoder: `cd dart/encoder && dart test`
- Tag conventions: `@TestOn('vm')` for engine; `@Tags(['slow'])` for cross-language matrix
- Snapshot tests rewrite baselines when `BALL_UPDATE_SNAPSHOTS=1`

## Generated Files

NEVER edit:
- `dart/shared/lib/gen/` — protobuf generated
- `dart/shared/std.json` — run `dart run bin/gen_std.dart` in `dart/shared/`
- `dart/shared/std.bin` — generated alongside std.json

## Code Style

- Dart 3.9+ features (records, patterns, sealed classes are fine)
- Follow `lints` package rules (`dart/shared/analysis_options.yaml`)
- No unnecessary null-safety annotations on non-nullable types

## Engine Architecture

- Split across `dart/engine/lib/engine.dart` + `part` files
- `dart/encoder/tool/concat_engine.dart` flattens parts for self-encoding
- Entry point: `main()` dispatches via CLI package, not engine directly
