<!-- Parent: ../AGENTS.md -->

# self_host (`ball_self_host_tests`)

## Purpose
Self-hosting validation harness: the Dart engine encoded **as a Ball program**, plus the compiled-back outputs in every target language, with parity tests against the live engine. `publish_to: none`.

## Key Files
| File | Description |
|------|-------------|
| `engine.ball.json` | Engine self-encoded as a Ball `Program` (proto3-JSON, `Any` envelope) — **generated** |
| `engine.ball.pb` | Binary protobuf form of the above — **generated** |
| `cli.ball.json` | Portable CLI verbs (`dart/shared/lib/cli_core.dart`) self-encoded as a Ball `Program` — **generated** by `compiler/tool/gen_cli_json.dart` |
| `cli.ball.pb` | Binary protobuf form of the above — **generated** |
| `lib/engine_roundtrip.dart` | Ball→Dart compiled engine — **generated** |
| `lib/engine_rt.cpp` | Ball→C++ compiled engine — **generated** (one emit shape since #601) |
| `lib/engine_rt.ts` / `engine_smoke.ts` | Ball→TS compiled engine + smoke — **generated** |
| `test/` | Parity tests: compiled outputs vs the live `ball_engine` |

## For AI Agents
- **Everything here except `test/` is a GENERATED artifact — never hand-edit.** Fix the source engine in `dart/engine/lib/engine.dart`, then regenerate.
- Regen: `engine.ball.json` via `dart run compiler/tool/gen_engine_json.dart`; C++ via `compiler/tool/compile_engine_cpp.dart`; TS per the regen command in `../../CLAUDE.md`. C++ self-host is CI-only (uses the built compiler binary; stale/gitignored locally — trust the "C++ Self-Host Tally" CI check). See `.claude/rules/cpp.md`.
- A Dart-only engine fix is half a fix — re-run conformance on all three engines.

## Dependencies
- Internal: `ball_base`, `ball_engine`, `ball_resolver`.
- External: `protobuf`, `fixnum`.
