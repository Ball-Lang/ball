<!-- Parent: ../AGENTS.md -->

# ts/engine (`@ball-lang/engine`)

## Purpose

Self-hosted Ball interpreter for TypeScript/JavaScript (Node.js + browser). Wraps an auto-generated compiled engine with proto3-JSON normalization, std-function dispatch, and a public `BallEngine` class.

## Key Files

| File | Description |
|------|-------------|
| `src/compiled_engine.ts` | **Generated — never edit.** Produced by compiling `dart/self_host/engine.ball.json` through `@ball-lang/compiler`. Regenerate via the command in `CLAUDE.md` → Build & Test. |
| `src/index.ts` | Editable public API. `BallEngine` class wraps `compiled_engine.ts`, applies `protoWrap` normalization, wires `StdModuleHandler` + `MethodDispatchHandler`, and exposes `run() → Promise<string[]>`. |
| `src/engine_setup.ts` | `createEngineSetup(mod)` — factored setup logic (proto3-JSON normalization, method dispatch, extra std registrations, scope patching). Used by both `index.ts` and the compiler's conformance harness to avoid drift. |
| `src/ball_file.ts` | Local `unwrapBallFile` helper (strips `@type` from Any envelopes before normalization). |

## For AI Agents

- Public API: `new BallEngine(program, opts?) → { run(): Promise<string[]>, getOutput(): string[] }`. `program` can be a plain JSON object or a JSON string; the engine unwraps Any envelopes and normalizes proto3-JSON internally.
- **`compiled_engine.ts` is generated but committed to git** (unlike the C++ self-host artifact `dart/self_host/lib/engine_rt.cpp`, which is gitignored, and unlike Rust/Go/C#/Python's compiled engines, which are gitignored and regenerated unconditionally every CI run). Never hand-edit it — all behavioral fixes go in the Dart self-hosted engine (`dart/self_host/`) or in `engine_setup.ts` / `index.ts` for TS-specific concerns, then regenerate. Rebuild with the command in `CLAUDE.md → Build & Test`.
- **A missed regen is now a CI failure (#517).** Because it is the only committed compiled engine, it was the only one that could silently go stale: `npm run build`/`npm run coverage` take it as an INPUT (coverage even `--exclude`s it), so any drift that is behaviour-neutral for this suite used to leave the whole `TypeScript` job green. ci.yml's `typescript` job now regenerates it from `dart/self_host/engine.ball.json` through the current `@ball-lang/compiler` and runs `git diff --exit-code` on the result. If that step fails, run the `CLAUDE.md` recipe and commit the regenerated file — do not edit it by hand to make the diff go away.
- `engine_setup.ts` is the single source of truth for "what a working engine needs" — edit there when adding std functions or patching behavior, not inline in `index.ts`.
- `run()` is **async** (`Promise<string[]>`); always `await` it.
- Test runner: `node --experimental-strip-types test/engine_test.ts` (not vitest). Validation is primarily via shared conformance fixtures in `tests/conformance/`.
- After changing the Dart self-hosted engine, regenerate `compiled_engine.ts` and re-run `cd ts/engine && npm test` — a Dart-only fix is half a fix. See `CLAUDE.md` → Typical Feature Workflow step 7.
- See `.claude/rules/ts.md` for the `protoWrap` / oneof API patterns and `CLAUDE.md` for the three-engine verification requirement.

## Dependencies

- Internal: none at runtime (self-contained; engine has no package deps)
- Dev: `typescript` ^6, `@types/node` ^25
