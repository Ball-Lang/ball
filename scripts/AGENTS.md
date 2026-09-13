<!-- Parent: ../AGENTS.md -->

# scripts

## Purpose
One-off and maintenance scripts for build automation, FFmpeg video processing, and data migration. Not part of any Ball package; not run in regular CI.

## Key Files / Contents

| File | Language | What it does |
|------|----------|--------------|
| `build_cpp_ninja.ps1` | PowerShell | Builds the C++ implementation using Ninja (faster than default CMake generator). |
| `compare_signatures.ps1` | PowerShell | Compares function signatures across Ball modules to detect API drift. |
| `migrate_types_to_typedefs.py` | Python | One-time migration script that converted legacy `Module.types[]` entries to `typeDefs[]`. Kept for reference. |
| `validate_ball_schema.py` | Python | Validates `ball.schema.json` against every `tests/conformance/*.ball.json` + `examples/**/*.ball.json` fixture (`pip install jsonschema`). Re-run after any `ball.schema.json` or `ball.proto` change — this IS the test for the JSON-only-language schema (issue #133). It is a LOCAL check (the `jsonschema` dependency keeps it out of the hermetic always-run `proto` job) and it validates `ball.v1.Program` documents only; the CI-enforced, stdlib-only, field-for-field mirror check against `ball.proto` — every message, corpus or no corpus — is `tools/check_proto_schema_drift.py`. |
| `process_ffmpeg.ps1` | PowerShell | Processes video files with FFmpeg (original version). |
| `process_ffmpeg_v2.ps1` | PowerShell | Updated FFmpeg processing script (v2). |
| `process_ffmpeg_all.ps1` | PowerShell | Batch FFmpeg processing across multiple input files. |

## For AI Agents

- Most scripts here are maintenance/migration utilities — verify they still apply before running.
- `migrate_types_to_typedefs.py` is a completed one-shot migration; do not re-run it.
- `validate_ball_schema.py` is a live check, not a one-shot migration — run it whenever `ball.schema.json` or the conformance/examples corpus changes. After editing `ball.proto`, run `python tools/check_proto_schema_drift.py` too: it is the check that notices a new field the schema has not mirrored.
- FFmpeg scripts are unrelated to Ball language correctness — they support media generation workflows in the repo.
- For build automation that runs in CI, prefer `tools/` (Dart/shell) over adding new scripts here.
