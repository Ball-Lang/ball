<!-- Parent: ../AGENTS.md -->

# Dart Implementation Agents

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
| `dart/ball_protobuf` | Descriptor-driven protobuf runtime (Ball-portable) | Library only |
| `dart/ball_protobuf_gen` | Consumer codegen: `protoc-gen-ball` / `-connect` / `-grpc` plugins | Plugin binaries |
| `dart/ball_rpc` | Dart-target RPC transport runtime (Connect/gRPC) for generated stubs | Library only |
| `dart/self_host` | Engine self-encoded as Ball (CI artifact) | N/A |
| `dart/scripts` | Build/generation tooling | N/A |

All packages use workspace resolution (`resolution: workspace`). The pub-workspace + Melos root is the **repo root** (`/pubspec.yaml`); run `dart pub get` and `melos …` from there. Per-package commands still work from each package dir (pub resolves upward).

## Publishing (pub.dev)

Nine of the packages above publish to pub.dev; `dart/self_host` is `publish_to: none`. Since #551 each one releases **independently**, on its own `<pkg>-vX.Y.Z` version line, from `.github/workflows/pubdev-release.yml` — one `semantic-release` run per package (`.github/release/<pkg>.releaserc.json`), dispatched by `release.yml` after it cuts the repo release. There is **no manual step**: the old `melos version` rolling-PR lane is gone, and so is the root `pubspec.yaml`'s `melos: command: version:` block. Melos remains a dev task runner only.

Consequences when working here:

- **Never hand-edit a `version:` in `dart/*/pubspec.yaml`** — semantic-release owns it, and `tools/release/sync_pubspec_deps.mjs` owns the sibling caret ranges (`ball_base: ^0.4.0`) during a release. A hand bump desynchronises pub.dev from `main` and trips `.github/workflows/pubdev-freshness.yml`.
- **All ten packages are ONE pub resolution unit.** If you do change a `version:`, every sibling constraint on it must move in the same commit — including `dart/self_host`'s, which has no release config of its own. Otherwise `dart pub get` at the repo root fails for the whole repo (`version solving failed`). Run `node tools/release/sync_pubspec_deps.mjs` to fix them all at once; `node tools/release/check_pubspec_workspace_consistency.mjs` is the PR gate.
- **A version bump in `dart/cli` must regenerate `lib/src/version.g.dart`** (`dart run tool/gen_version.dart`); the release does this automatically, and ci.yml's `--check` guard fails otherwise.
- **A sibling the release sweep re-pins must publish in the SAME run** (#566). The sweep rewrites every member's pins in the repo; a package with no releasable commits of its own is swept and then *not* published, so pub.dev keeps serving its old pubspec and the published graph splits (`ball_resolver 0.3.0+3` requiring `ball_base ^0.3.0+3` while `ball_base` is live at `0.4.0` — an external `dart pub get` on `ball_cli: ^0.4.0` then fails, while the repo and every static guard stay green). `tools/release/lockstep_plan.mjs` plans each run against the LIVE pub.dev graph and forces a patch release for exactly the packages whose **published** pins this run breaks — not for every package whose pin was merely rewritten, which would republish all nine forever. Its `--self-test` is a PR gate; `check_pubdev_release_wiring.sh` pins the wiring.
- **Adding a tenth publishable package** needs `.github/release/<pkg>.releaserc.json` plus an entry in `pubdev-release.yml`'s `PACKAGES` loop, placed **after every package it depends on at runtime** — `check_pubdev_release_wiring.sh` fails until the config exists, and `check_pubspec_workspace_consistency.mjs` fails until the loop entry is in a valid deps-first position.

Full flow, ordering rationale and failure recovery: `docs/RELEASE.md`.

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
