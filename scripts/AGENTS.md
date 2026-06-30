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
| `process_ffmpeg.ps1` | PowerShell | Processes video files with FFmpeg (original version). |
| `process_ffmpeg_v2.ps1` | PowerShell | Updated FFmpeg processing script (v2). |
| `process_ffmpeg_all.ps1` | PowerShell | Batch FFmpeg processing across multiple input files. |

## For AI Agents

- Most scripts here are maintenance/migration utilities — verify they still apply before running.
- `migrate_types_to_typedefs.py` is a completed one-shot migration; do not re-run it.
- FFmpeg scripts are unrelated to Ball language correctness — they support media generation workflows in the repo.
- For build automation that runs in CI, prefer `tools/` (Dart/shell) over adding new scripts here.
