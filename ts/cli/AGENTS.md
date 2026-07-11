<!-- Parent: ../AGENTS.md -->

# ts/cli (`@ball-lang/cli`)

## Purpose

Command-line interface for the Ball TS toolchain. Provides `ball run` (execute a Ball program) and the portable cli-core verbs `ball info` / `ball validate` / `ball tree` / `ball version` / `ball audit` — all self-hosted through `compiled_cli.ts` (audit's capability + termination analyzers self-host too since issue #362). Installed as the `ball` binary.

## Key Files

| File | Description |
|------|-------------|
| `src/index.ts` | CLI entry point. Parses argv, dispatches `cmdRun` / `cmdInfo` / `cmdValidate` / `cmdTree` / `cmdAudit` / `cmdVersion`, unwraps `.ball.json` Any envelopes. **Lazily** (`await import(...)`) loads `@ball-lang/engine` inside `cmdRun` and `./cli_core.ts` inside the info/validate/tree/version/audit handlers — see the "two compiled engines, one process" gotcha below. |
| `src/cli_core.ts` | Hand-written wrapper around `compiled_cli.ts`. Exports `infoReport`/`validateReport`/`validateOk`/`treeReport`/`versionLine` (over `normalizeProgram`) plus the audit surface `analyzeCapabilities`/`formatCapabilityReport`/`checkPolicy`/`auditReport`. Audit needs a **deep** materializer (`matExpr`/`matLiteral`/`matStmt`) because the compiled analyzers walk the whole expression tree reading scalars like `call.module.length` — the TS analog of the Dart parity gate's `protoToEngineMap`. A Program with no `modules` key throws (fail-loud, matching the native audit). |
| `src/compiled_cli.ts` | **Generated — never edit.** Produced by compiling `dart/self_host/cli.ball.json` (encoded from `dart/shared/lib/cli_core.dart`, whose capability/termination analyzers are `part of cli_core.dart` since #362) through `@ball-lang/compiler`, then exporting every top-level declaration (cli_core.dart is a free-function library, not a single class like `engine.dart`, so it needs this export pass — `compile()`'s own class-export logic doesn't cover top-level functions). Regenerate via the command in `CLAUDE.md` → Build & Test ("Regenerate compiled TS CLI core"). |

## For AI Agents

- No library exports — this is a pure CLI package. Do not add re-exports; keep `src/index.ts` as `#!/usr/bin/env node` entry only.
- `ball run` calls `new BallEngine(program, { stdout, stderr })` from `@ball-lang/engine` and calls `.run()` (async — `await` it internally, but the CLI top-level uses `process.exit(main(...))` with synchronous result; ensure async path is handled).
- **Two compiled Ball TS artifacts must never share a process.** Both `compiled_cli.ts` and `@ball-lang/engine`'s `compiled_engine.ts` install a runtime preamble as a side effect of module evaluation, including monkey-patching shared native prototypes (`Map.prototype.get`/`entries`/`keys`/`values`). That patching survives being installed *once*, but a *second*, independently-compiled preamble installing on top of the first corrupts it (the second artifact's "capture the native method" step actually captures the first artifact's already-shadowed version) — the observed symptom is `TypeError: Method Map.prototype.entries called on incompatible receiver`. Since every `ball` invocation is a single-command process, `index.ts` avoids this by `await import()`-ing each compiled engine lazily, only inside the command handler that needs it — never add a top-level `import` of either `@ball-lang/engine` or `./cli_core.ts` back to `index.ts`.
- `ball info` / `ball validate` / `ball tree` / `ball version` / `ball audit` delegate their report text to `cli_core.ts` → `compiled_cli.ts`, so the output is byte-identical to the native Dart CLI's (proven by `test/cli_core_parity.test.ts`, which spawns both CLIs as subprocesses, and — for audit — by `dart/cli/test/cli_core_parity_test.dart`). Only argv parsing / usage-error text is TS-local.
- `ball audit`'s analysis is purely static (no engine invocation): `cli_core.analyzeCapabilities` runs the compiled capability walker, `formatCapabilityReport`/`checkPolicy` render + enforce policy. Adding a capability category is now a **Dart-only** change: edit `dart/shared/lib/capability_table.dart`, regenerate `cli.ball.json` + `compiled_cli.ts`, done — there is no TS-side table to keep in sync anymore (`capability_analyzer.ts`/`capability_table.ts` were deleted in #362).
- The `unwrapBallFile` helper in `src/index.ts` strips the `@type` Any envelope before passing to the engine. Keep it consistent with `ts/shared/src/ball_file.ts`.
- Test runners: `node --experimental-strip-types --disable-warning=ExperimentalWarning test/cli_test.ts` (black-box subprocess suite) and `node --experimental-strip-types --test test/*.test.ts` (unit + parity suites, including `cli_core_parity.test.ts` — needs the Dart SDK on `PATH`; skips gracefully if absent — and `audit.test.ts` for the self-hosted audit surface).
- See `.claude/rules/ts.md` and `CLAUDE.md` for TS conventions.

## Dependencies

- Internal: `@ball-lang/engine` ^0.3.0
- Dev: `typescript` ^6, `@types/node` ^22
