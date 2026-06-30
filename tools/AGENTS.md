<!-- Parent: ../AGENTS.md -->

# tools

## Purpose
Repo-wide automation scripts for coverage collection, conformance descriptor generation, and Editions golden regeneration. These are run by CI and by developers; they are not part of any Ball package.

## Key Files / Contents

| File | Language | What it does |
|------|----------|--------------|
| `coverage_dart.dart` | Dart | Collects and merges Dart code-coverage across the workspace; used by CI coverage step. Run with `--exclude-tags slow` to skip slow round-trips. |
| `gen_edition_defaults.ps1` | PowerShell | Regenerates `tests/editions/featureset_defaults.binpb` from protoc output. Supports `--check` for drift detection. |
| `gen_edition_defaults.sh` | Bash | POSIX equivalent of the above; use on Linux/macOS/WSL. |
| `gen_conformance_descriptors.ps1` | PowerShell | Generates proto descriptor fixtures under `tests/editions/descriptors/`. |
| `gen_conformance_descriptors.sh` | Bash | POSIX equivalent of the above. |

## For AI Agents

- Run `gen_edition_defaults.{ps1,sh} --check` after any protoc upgrade to detect drift against the golden `featureset_defaults.binpb`; regenerate if drift is reported.
- `coverage_dart.dart` is the authoritative coverage collector; always use `--exclude-tags slow` in non-release CI to avoid timeout.
- These scripts are invoked directly (`dart run tools/coverage_dart.dart`, `tools/gen_edition_defaults.ps1`); they are not pub packages and have no `pubspec.yaml`.
- Do not add per-language tooling here — language-specific scripts belong under their respective `dart/`, `ts/`, or `cpp/` directories.
