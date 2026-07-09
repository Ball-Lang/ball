# Ball Project Agents

This file provides instructions for AI coding agents working on the Ball project.

## Project Context

Ball is a programming language where code is structured protobuf messages. The project has:
- **Dart** — the reference implementation: compiler, encoder, engine, CLI (most mature, broadest std coverage).
- **TypeScript** — a full pipeline, all CI-gated: compiler, self-hosted engine (passes the conformance corpus), encoder (TS→Ball; 100+ round-trip tests; routes through universal `std`, no `ts_std`), CLI.
- **C++** — compiler, encoder (Clang JSON AST → Ball), self-hosted engine; the self-host conformance passes **every** fixture (no skip-list). Still FetchContents upstream protobuf v34.1 (#18/#25).
- **Rust** (epic #32, closed) — a complete pipeline: compiler (`rust/compiler/`, #36-38) and encoder (`rust/encoder/`, #42-43), proto bindings + runtime value model (`rust/shared/`, #34-35), a self-hosted engine that runs the whole conformance corpus at Dart parity (`Results: 319 passed, 0 failed, 319 total`; #39/#300 closed), and a `ball` CLI (`run`/`compile`/`encode`/`check`; #41/#304 closed). Conformance harness (#40) and CI job (#44) both closed — see `rust/AGENTS.md`.
- **Proto bindings only** for Go, Python, Java, C#.

Statuses drift — verify maturity against CI (`.github/workflows/ci.yml`), not this prose. "stub"/"prototype" labels in older docs were stale; TS, C++, and Rust all have full compiler+encoder+engine pipelines gated in CI.

C++, TypeScript, and Rust all run a **self-hosted** engine (compiled from the Dart reference engine); there are no native C++/TS/Rust engines. All three now compile and run the full conformance corpus at Dart parity.

## Build & Test

Build & test commands: see CLAUDE.md → Build & Test (canonical). Per-language detail lives in `.claude/rules/<lang>.md`.

## Key Invariants

Core invariants are defined once in CLAUDE.md → Core Invariants — Never Violate. Do not duplicate them.

## Critical Known Issues

C++/self-host gaps are tracked in `docs/SELF_HOST_STATUS.md` (kept current); the strict all-green CI gates are in `.github/workflows/regression-gates.yml`.

## File Organization

Each implementation documents its own generated/editable files. See the per-language "Generated Files" sections in `dart/AGENTS.md`, `ts/AGENTS.md`, `cpp/AGENTS.md`, and `rust/AGENTS.md`. Cross-cutting entry points:

| Path | What it is | Editable? |
|------|-----------|-----------|
| `proto/ball/v1/ball.proto` | Language schema | Yes — run `buf lint` + `buf generate` after |
| `ball.schema.json` | JSON Schema (Draft 2020-12) mirroring `ball.proto`'s protobuf-JSON wire format, for JSON-only (non-protobuf) language implementers | Yes — keep in sync with `ball.proto`; re-run `scripts/validate_ball_schema.py` after any change |
| `docs/BALL_JSON_SPEC.md` | Narrative companion to `ball.schema.json` | Yes |
| `dart/shared/lib/std.dart` | Std library definition | Yes — run `gen_std.dart` after |
| `dart/shared/std.json` | Compiled std module | NO — generated |
| `dart/shared/lib/gen/` | Protobuf Dart types | NO — generated |
| `cpp/shared/gen/` | Protobuf C++ types | NO — generated |
| `rust/shared/gen/` | Protobuf Rust types (`buf.build/community/neoeinstein-prost`) | NO — generated |
| `dart/compiler/lib/compiler.dart` | Reference compiler | Yes |
| `dart/encoder/lib/encoder.dart` | Reference encoder | Yes |
| `dart/engine/lib/engine.dart` | Reference interpreter | Yes |
| `dart/engine/test/engine_test.dart` | Engine tests | Yes — add tests here |
| `dart/self_host/lib/engine_rt.cpp` | Self-hosted C++ engine | NO — generated from the Dart engine |
| `ts/engine/src/compiled_engine.ts` | Self-hosted TS engine | NO — generated |
| `rust/engine/src/compiled_engine.rs` | Self-hosted Rust engine (compiles and runs at Dart parity — #39/#300 closed) | NO — generated, gitignored |
| `ts/engine/src/index.ts` | TS engine wrapper / dispatch | Yes |
| `ts/compiler/src/compiler.ts` | TypeScript compiler | Yes |
| `cpp/shared/include/ball_dyn.h` + `ball_emit_runtime.h` | C++ runtime/type system (spliced into every emitted program) | Yes |
| `website/` | ball-lang.dev + playground (Jaspr) | Yes |

## Adding a New Language Implementation

To add a language, follow `.claude/skills/new-ball-language/SKILL.md` (8 phases).

**Agent**: Use `Ball Lang Bootstrapper` (`.claude/agents/ball-lang-bootstrapper.md`) to orchestrate.

## When Implementing a Feature

1. Check if it needs a proto schema change → edit `ball.proto`, lint, generate
2. Check if it needs a new std function → edit `dart/shared/lib/std.dart`, regenerate
3. Implement in Dart engine (`engine.dart`) — behavior is defined HERE
4. Implement in Dart compiler (`compiler.dart`)
5. **MAXIMIZE e2e conformance tests** — a single `.ball.json` fixture in `tests/conformance/` validates ALL engines (Dart, C++, TS) simultaneously. Prefer conformance tests over per-language unit tests.
6. If C++ is affected: implement in `cpp/compiler/`, then regenerate the self-hosted engine (`dart/self_host/lib/engine_rt.cpp`) — see `.claude/rules/cpp.md`
7. Add engine unit tests ONLY for engine-internal behavior not expressible as a Ball program
8. Update `docs/METADATA_SPEC.md` if new metadata keys are introduced

## Codebase Search

This repo is indexed with SocratiCode; its MCP tools are available for semantic search when useful.
