<!-- Parent: ../AGENTS.md -->

# cli (`ball_cli`)

## Purpose
User-facing `ball` command-line tool — compile, encode, run, and inspect Ball programs from the terminal. The only Dart package that ships an executable.

## Key Files
| File | Description |
|------|-------------|
| `bin/ball.dart` | Executable entry point (`ball_cli:ball`) |
| `lib/src/runner.dart` | Subcommand dispatch (run, compile, encode, audit, …) |

## For AI Agents
- This is a thin orchestration layer: it wires together `ball_compiler`, `ball_encoder`, `ball_engine`, and `ball_resolver` — implement real behavior in those packages, not here.
- Add new subcommands in `lib/src/runner.dart`; keep `bin/ball.dart` minimal.
- Core language invariants live in `../../CLAUDE.md`; Dart patterns in `.claude/rules/dart.md`. Don't restate.
- Tests in `test/`.

## Dependencies
- Internal: `ball_base`, `ball_compiler`, `ball_encoder`, `ball_engine`, `ball_resolver`.
- External: `yaml` (config), `protobuf`/`fixnum` (Ball message types).
