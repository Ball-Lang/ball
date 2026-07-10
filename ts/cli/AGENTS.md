<!-- Parent: ../AGENTS.md -->

# ts/cli (`@ball-lang/cli`)

## Purpose

Command-line interface for the Ball TS toolchain. Provides `ball run` (execute a Ball program), `ball info` / `ball validate` / `ball tree` / `ball version` (portable cli-core verbs, self-hosted — see below), and `ball audit` (static capability analysis, still hand-ported — issue #362). Installed as the `ball` binary.

## Key Files

| File | Description |
|------|-------------|
| `src/index.ts` | CLI entry point. Parses argv, dispatches `cmdRun` / `cmdInfo` / `cmdValidate` / `cmdTree` / `cmdAudit` / `cmdVersion`, unwraps `.ball.json` Any envelopes. **Lazily** (`await import(...)`) loads `@ball-lang/engine` inside `cmdRun` and `./cli_core.ts` inside the info/validate/tree/version handlers — see the "two compiled engines, one process" gotcha below. |
| `src/cli_core.ts` | Hand-written wrapper around `compiled_cli.ts`. Exports `infoReport`/`validateReport`/`validateOk`/`treeReport`/`versionLine`, each accepting a loosely-typed, proto3-JSON-shaped `Program` and normalizing it (`normalizeProgram`) into the fully-materialized-defaults shape the compiled verbs expect before calling through. |
| `src/compiled_cli.ts` | **Generated — never edit.** Produced by compiling `dart/self_host/cli.ball.json` (encoded from `dart/shared/lib/cli_core.dart`) through `@ball-lang/compiler`, then exporting every top-level declaration (cli_core.dart is a free-function library, not a single class like `engine.dart`, so it needs this export pass — `compile()`'s own class-export logic doesn't cover top-level functions). Regenerate via the command in `CLAUDE.md` → Build & Test ("Regenerate compiled TS CLI core"). |
| `src/capability_analyzer.ts` | `analyzeCapabilities(program, opts?) → CapabilityReport`. Static tree-walk over all (or reachable) functions; reports which `std` base functions are called and their side-effect category. Ported from `dart/shared/lib/capability_analyzer.dart`. **Temporary** (issue #362): `cli_core.dart`'s own `auditReport` isn't self-hostable yet (its analyzers use proto accessors + enum/Set shapes the engine can't represent), so this hand-port stays until that residual lands — do not delete it as part of any future cli-core work without checking #362 first. |
| `src/capability_table.ts` | Lookup table mapping `std` function names → `Capability` enum values and risk levels. |

## For AI Agents

- No library exports — this is a pure CLI package. Do not add re-exports; keep `src/index.ts` as `#!/usr/bin/env node` entry only.
- `ball run` calls `new BallEngine(program, { stdout, stderr })` from `@ball-lang/engine` and calls `.run()` (async — `await` it internally, but the CLI top-level uses `process.exit(main(...))` with synchronous result; ensure async path is handled).
- **Two compiled Ball TS artifacts must never share a process.** Both `compiled_cli.ts` and `@ball-lang/engine`'s `compiled_engine.ts` install a runtime preamble as a side effect of module evaluation, including monkey-patching shared native prototypes (`Map.prototype.get`/`entries`/`keys`/`values`). That patching survives being installed *once*, but a *second*, independently-compiled preamble installing on top of the first corrupts it (the second artifact's "capture the native method" step actually captures the first artifact's already-shadowed version) — the observed symptom is `TypeError: Method Map.prototype.entries called on incompatible receiver`. Since every `ball` invocation is a single-command process, `index.ts` avoids this by `await import()`-ing each compiled engine lazily, only inside the command handler that needs it — never add a top-level `import` of either `@ball-lang/engine` or `./cli_core.ts` back to `index.ts`.
- `ball info` / `ball validate` / `ball tree` / `ball version` delegate their report text to `cli_core.ts` → `compiled_cli.ts`, so the output is byte-identical to the native Dart CLI's (proven by `test/cli_core_parity.test.ts`, which spawns both CLIs as subprocesses). Only argv parsing / usage-error text is TS-local.
- `ball audit` uses `analyzeCapabilities` (no engine invocation) — the analysis is purely static.
- The `unwrapBallFile` helper in `src/index.ts` strips the `@type` Any envelope before passing to the engine. Keep it consistent with `ts/shared/src/ball_file.ts`.
- Test runners: `node --experimental-strip-types --disable-warning=ExperimentalWarning test/cli_test.ts` (black-box subprocess suite) and `node --experimental-strip-types --test test/*.test.ts` (unit + parity suites, including `cli_core_parity.test.ts` — needs the Dart SDK on `PATH`; skips gracefully if absent).
- When adding capability categories, update both `capability_table.ts` and `capability_analyzer.ts`, then verify parity with `dart/shared/lib/capability_analyzer.dart`.
- See `.claude/rules/ts.md` and `CLAUDE.md` for TS conventions.

## Dependencies

- Internal: `@ball-lang/engine` ^0.3.0
- Dev: `typescript` ^6, `@types/node` ^22
