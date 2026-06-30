<!-- Parent: ../AGENTS.md -->

# scripts

## Purpose
Loose build/release tooling for the Dart workspace (not a pub package — no `pubspec.yaml`). Run with `dart run scripts/<file>.dart` from `dart/`.

## Key Files
| File | Description |
|------|-------------|
| `prepare_publish.dart` | Dry-run pub.dev publish-readiness check for all Dart packages: backs up each `pubspec.yaml`, rewrites `path:` deps to hosted constraints, runs `pub publish --dry-run`, then restores. Reversible via try/finally (survives Ctrl-C). |

## For AI Agents
- `prepare_publish.dart` walks packages in dependency order and is non-destructive — backups restore on normal exit and on crash. Exit 0 = all dry-runs pass.
- Publish ordering note: `ball_protobuf` must release before `ball_base` (circular dev-dep); see release docs.
- Core invariants: `../../CLAUDE.md`; Dart patterns: `.claude/rules/dart.md`.

## Dependencies
- None packaged — uses the SDK + workspace resolution from `dart/`.
