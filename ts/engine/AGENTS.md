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
| `test/compiled_engine_parity.test.ts` | Behavioural staleness lock for `src/compiled_engine.ts` — hand-built programs whose answers were verified against the Dart reference engine, chosen so they discriminate shapes the Dart-generated conformance corpus never emits. |

## For AI Agents

- Public API: `new BallEngine(program, opts?) → { run(): Promise<string[]>, getOutput(): string[] }`. `program` can be a plain JSON object or a JSON string; the engine unwraps Any envelopes and normalizes proto3-JSON internally.
- **`compiled_engine.ts` is generated but committed to git** (unlike the C++ self-host artifact `dart/self_host/lib/engine_rt.cpp`, which is gitignored, and unlike Rust/Go/C#/Python's compiled engines, which are gitignored and regenerated unconditionally every CI run). Never hand-edit it — all behavioral fixes go in the Dart self-hosted engine (`dart/self_host/`) or in `engine_setup.ts` / `index.ts` for TS-specific concerns, then regenerate. Rebuild with the command in `CLAUDE.md → Build & Test` (`ts/compiler/tool/regen_compiled_engine.mjs`).
- **Being committed makes it the ONE compiled engine that can go stale in git, and a missed regen is now a CI failure (#517).** Every other target rebuilds its own from source inside its CI job; this one is consumed as a committed INPUT by `npm run build`/`npm run coverage` (coverage even `--exclude`s it), so drift that is behaviour-neutral for those suites used to leave the whole `TypeScript` job green. Two gates now cover it: ci.yml's `Ball Artifact Freshness` job regenerates it from `dart/self_host/engine.ball.json` through the current `@ball-lang/compiler` and runs `git diff --exit-code` (`Assert compiled TS engine is up to date` — the single #517 gate; the `typescript` job deliberately does NOT carry a second regeneration pass), and `test/compiled_engine_parity.test.ts` locks the behaviour. If that step fails, run the `CLAUDE.md` recipe and commit the regenerated file — do not edit it by hand to make the diff go away. The corpus alone cannot catch this: it is generated from Dart by the Dart encoder, so it only exercises the Ball shapes that encoder emits — a stale artifact carrying an older `_isBareSelfConstruction` rule (#499) left all 371 fixtures green while this engine infinitely recursed on a program the Dart engine ran fine.
- `engine_setup.ts` is the single source of truth for "what a working engine needs" — edit there when adding std functions or patching behavior, not inline in `index.ts`.
- `run()` is **async** (`Promise<string[]>`); always `await` it.
- Test runner: `node --experimental-strip-types test/engine_test.ts` (not vitest). Validation is primarily via shared conformance fixtures in `tests/conformance/`.
- After changing the Dart self-hosted engine, regenerate `compiled_engine.ts` and re-run `cd ts/engine && npm test` — a Dart-only fix is half a fix. See `CLAUDE.md` → Typical Feature Workflow step 7.
- See `.claude/rules/ts.md` for the `protoWrap` / oneof API patterns and `CLAUDE.md` for the three-engine verification requirement.

## Dependencies

- Internal: none at runtime (self-contained; engine has no package deps)
- Dev: `typescript` ^6, `@types/node` ^25

### Dart's `StateError`: typed AND readable (issue #616)

#597/#604 settled that `std_collections.list_find`'s no-match THROWS and that the throw is
typed. Neither settled what the program then OBSERVES — conformance fixture
`463_list_find_no_match` prints a hardcoded literal from its catch bodies — and every target
answered differently. Measured on `origin/main` before the fix, one program printing
`to_string(e)` from its catch: the Dart reference engine `Bad state: No element` (which is also
real Dart's `StateError('No element').toString()`), the TS self-hosted engine
`{message: No element}`, the Go self-hosted engine `main:StateError`.

The contract now has two halves at EVERY site that raises Dart's `StateError` — an empty
`.first`/`.last`/`.single`/`removeLast`/`reduce`, or a `firstWhere` with no match:

1. **TYPED** — the thrown value carries the type name `StateError`, so a program's own
   `on StateError catch` matches it. Several sites used to raise an untyped native fault that
   the compiled `try` could not see at all.
2. **OBSERVABLE** — it stringifies as Dart's own `StateError.toString()`, `Bad state: <message>`,
   so `to_string(e)` in the catch body reads the same here as on the Dart reference engine.

`tests/conformance/464_state_error_message` is the cross-target guard (it prints the caught
value for `list_find`'s no match AND `list_first` on an empty list — never a hardcoded string).
Per-target details are in `.claude/rules/<lang>.md`; the gap class is
`docs/TESTING_STRATEGY.md` §5b.
