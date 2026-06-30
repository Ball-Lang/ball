<!-- Parent: ../AGENTS.md -->

# ts/cli (`@ball-lang/cli`)

## Purpose

Command-line interface for the Ball TS toolchain. Provides `ball run` (execute a Ball program) and `ball audit` (static capability analysis). Installed as the `ball` binary.

## Key Files

| File | Description |
|------|-------------|
| `src/index.ts` | CLI entry point. Parses argv, dispatches `cmdRun` / `cmdAudit`, unwraps `.ball.json` Any envelopes, delegates to `@ball-lang/engine` for execution. |
| `src/capability_analyzer.ts` | `analyzeCapabilities(program, opts?) → CapabilityReport`. Static tree-walk over all (or reachable) functions; reports which `std` base functions are called and their side-effect category. Ported from `dart/shared/lib/capability_analyzer.dart`. |
| `src/capability_table.ts` | Lookup table mapping `std` function names → `Capability` enum values and risk levels. |

## For AI Agents

- No library exports — this is a pure CLI package. Do not add re-exports; keep `src/index.ts` as `#!/usr/bin/env node` entry only.
- `ball run` calls `new BallEngine(program, { stdout, stderr })` from `@ball-lang/engine` and calls `.run()` (async — `await` it internally, but the CLI top-level uses `process.exit(main(...))` with synchronous result; ensure async path is handled).
- `ball audit` uses `analyzeCapabilities` (no engine invocation) — the analysis is purely static.
- The `unwrapBallFile` helper in `src/index.ts` strips the `@type` Any envelope before passing to the engine. Keep it consistent with `ts/shared/src/ball_file.ts`.
- Test runner: `node --experimental-strip-types --disable-warning=ExperimentalWarning test/cli_test.ts`.
- When adding capability categories, update both `capability_table.ts` and `capability_analyzer.ts`, then verify parity with `dart/shared/lib/capability_analyzer.dart`.
- See `.claude/rules/ts.md` and `CLAUDE.md` for TS conventions.

## Dependencies

- Internal: `@ball-lang/engine` ^0.3.0
- Dev: `typescript` ^6, `@types/node` ^22
