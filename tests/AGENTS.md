<!-- Parent: ../AGENTS.md -->

# tests

## Purpose
Cross-language conformance corpus and supporting test assets. This directory is the operational definition of "done" for any Ball feature — a fixture here validates Dart, C++, and TS engines simultaneously.

## Key Files / Contents

| Path | Description |
|------|-------------|
| `conformance/src/*.dart` | **Editable** Dart fixture sources — one per language construct |
| `conformance/*.ball.json` | **Generated** Ball programs — do NOT hand-edit; regenerate via `dart run bin/generate_conformance.dart` in `dart/encoder/` |
| `conformance/*.expected_output.txt` | Golden stdout for each fixture, compared by all three engines |
| `editions/featureset_defaults.binpb` | Golden Editions feature-set defaults (from protoc 28.2); regenerate with `tools/gen_edition_defaults.{ps1,sh}` |
| `editions/conformance_runner.{ps1,sh}` | Runs the Editions portability matrix across engines |
| `editions/portability_matrix.md` | Status table for Editions resolver across Dart/TS/C++ |
| `editions/descriptors/` | Proto descriptor fixtures for Editions tests |
| `editions/golden/` | Golden outputs for Editions conformance |
| `fixtures/dart/` | Dart-specific unit test fixtures |
| `fixtures/cpp_ast/` | C++ AST JSON fixtures for the encoder |
| `scale/roundtrip_top100.csv` | Perf baseline for the top-100 round-trip cases |
| `snapshots/dart/` | Dart compiler snapshot goldens |
| `snapshots/cpp/` | C++ compiler snapshot goldens |
| `perf_baseline.csv` | Repo-wide performance baseline |

## Subdirectories

- `conformance/` — The primary CI corpus. Each `NN_<name>.ball.json` + `.expected_output.txt` pair is run against Dart, C++, and TS engines in CI.
- `editions/` — Protobuf Editions-specific conformance assets.
- `fixtures/` — Static input files used by per-language unit tests.
- `scale/` — Large-input performance test data.
- `snapshots/` — Compiler output golden files; rewrite with `BALL_UPDATE_SNAPSHOTS=1`.

## For AI Agents

- **Never hand-edit `conformance/*.ball.json`** — they are generated from `conformance/src/*.dart` by running `dart run bin/generate_conformance.dart` in `dart/encoder/`. Editing them directly will be overwritten and may cause the fixture-name lint to fail.
- Adding a new std function or encoder construct requires a new `conformance/src/NN_<name>.dart` fixture; CI (`check_encoder_completeness.dart`) will fail otherwise.
- The fixture-name lint (`check_fixture_names.dart`) enforces that a fixture's file name matches what it actually tests — name precisely.
- Full testing strategy (conformance philosophy, encoder-completeness gate, issue-#55 post-mortem) is in `docs/TESTING_STRATEGY.md`.
- Snapshot goldens in `snapshots/` are rewritten by setting `BALL_UPDATE_SNAPSHOTS=1` before running the relevant test suite.
- `editions/featureset_defaults.binpb` is regenerated via `tools/gen_edition_defaults.{ps1,sh} --check` in drift-detection mode; run after a protoc upgrade.
