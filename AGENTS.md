# Ball Project Agents

This file provides instructions for AI coding agents working on the Ball project.

## Project Context

Ball is a programming language where code is structured protobuf messages. The project has:
- A **mature Dart implementation** (compiler, encoder, engine, CLI)
- A **TypeScript implementation** (compiler, self-hosted engine, stub encoder, CLI)
- A **prototype C++ implementation** (compiler, encoder, self-hosted engine)
- **Proto bindings** for Go, Python, Java, C# (no implementations yet)

Both C++ and TypeScript run the **self-hosted** engine (compiled from the Dart reference engine); there are no native C++/TS engines.

## Build & Test

Build & test commands: see CLAUDE.md → Build & Test (canonical). Per-language detail lives in `.claude/rules/<lang>.md`.

## Key Invariants

Core invariants are defined once in CLAUDE.md → Core Invariants — Never Violate. Do not duplicate them.

## Critical Known Issues

C++/self-host gaps are tracked in `docs/SELF_HOST_STATUS.md` (kept current); the strict all-green CI gates are in `.github/workflows/regression-gates.yml`.

## File Organization

Each implementation documents its own generated/editable files. See the per-language "Generated Files" sections in `dart/AGENTS.md`, `ts/AGENTS.md`, and `cpp/AGENTS.md`. Cross-cutting entry points:

| Path | What it is | Editable? |
|------|-----------|-----------|
| `proto/ball/v1/ball.proto` | Language schema | Yes — run `buf lint` + `buf generate` after |
| `dart/shared/lib/std.dart` | Std library definition | Yes — run `gen_std.dart` after |
| `dart/shared/std.json` | Compiled std module | NO — generated |
| `dart/shared/lib/gen/` | Protobuf Dart types | NO — generated |
| `cpp/shared/gen/` | Protobuf C++ types | NO — generated |
| `dart/compiler/lib/compiler.dart` | Reference compiler | Yes |
| `dart/encoder/lib/encoder.dart` | Reference encoder | Yes |
| `dart/engine/lib/engine.dart` | Reference interpreter | Yes |
| `dart/engine/test/engine_test.dart` | Engine tests | Yes — add tests here |
| `dart/self_host/lib/engine_rt.cpp` | Self-hosted C++ engine | NO — generated from the Dart engine |
| `ts/engine/src/compiled_engine.ts` | Self-hosted TS engine | NO — generated |
| `ts/engine/src/index.ts` | TS engine wrapper / dispatch | Yes |
| `ts/compiler/src/compiler.ts` | TypeScript compiler | Yes |
| `cpp/shared/ball_runtime.h` | C++ runtime/type system | Yes |
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
