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

`tests/conformance/465_state_error_message` is the cross-target guard (it prints the caught
value for `list_find`'s no match AND `list_first` on an empty list — never a hardcoded string).
Per-target details are in `.claude/rules/<lang>.md`; the gap class is
`docs/TESTING_STRATEGY.md` §5b.

### Property-read precedence: a declared member beats a virtual one (#664, #681)

`engine_setup.ts`'s `patchCompiledEngine` wraps the compiled engine's `_evalFieldAccess` and
answers two families of read BEFORE delegating: the numeric ones (`isNaN`/`isFinite`/…, via
`_numFieldAccess`) and the virtual map/iterable ones (`length`/`isEmpty`/`isNotEmpty`, via
`_collectionFieldAccess`). Anything answered there never reaches the compiled engine at all, so
anything that engine would have resolved FIRST must be deferred here explicitly.

The Dart reference engine's order — `engine_eval.dart`'s map field-access block — is:

> the object's own key → the `__super__` chain → `__methods__` → a user getter → **and only
> then** the virtual map properties.

The rule this target must therefore follow is **a DECLARED member always beats a virtual one**.
Two deferrals in `_collectionFieldAccess` make that concrete, and both are behavioural:

- **a `__type__`-tagged object defers wholesale.** A Ball instance and a Ball map are both plain
  JS objects here, and only `__type__` tells them apart. An instance's field may be INHERITED
  (it lives on `__super__`, not as an own key) or supplied by a user getter, so an own-key test
  alone is not enough — an instance is not a Map and must not be answered by Map emulation at
  all. An instance that genuinely declares none of these still gets the same number back from
  the compiled engine's own virtual-property arm, so deferring is never a behaviour loss.
- **an own key of that name defers.** A plain map carrying a literal `'length'` key is the map
  analogue of the same collision.

Both were live wrong answers — silent, and on this target only. #664 found a class declaring
`final int length` reading its instance's ENTRY COUNT; #681 found the plain
`class Holder { int length; }` reading back `1` instead of `3` while the same object's
`toString` printed `{length: 3}`. `tests/conformance/470_setter_beside_final_field` and
`475_instance_field_named_length` are the cross-target gates, and
`test/engine_setup.test.ts`'s `_evalFieldAccess: a declared field beats the virtual map
getters` group is the unit guard.

Two neighbouring shapes are NOT covered by this rule and are tracked as **#697**: an instance
field named `isEmpty` (the Dart encoder rewrites any `.isEmpty` to `std.string_is_empty`
without consulting the receiver's type) and `.length` on a map carrying a `'length'` key, which
every engine answers with the key's value rather than the entry count. Both are wrong on every
target, so they are encoder / reference-engine bugs rather than TS ones.

### The override registry's two drift guards (#817, #732)

`registerExtraStdFunctions` (`engine_setup.ts`) is `_r('name', handler)` repeated ~135 times.
Two different classes of drift it can hide needed their own gates — see each script's own
docstring for exactly what it checks and does not:

- **A registered name may be a phantom no builder declares at all (#817).**
  `tools/check_ts_engine_setup_declared.py` asserts every `_r(...)`'d name is DECLARED by some
  canonical `dart/shared/lib/std*.dart` builder (`tests/conformance/std_coverage.json`'s union
  across all eight modules — `StdHandler.register` is a flat, module-less namespace, the TS
  mirror of `dart/engine/lib/engine_types.dart`'s `StdModuleHandler._dispatch`), or is a frozen
  entry in `tools/declared_ts_engine_overrides_known_gaps.txt`. `string_from_char_codes`
  (plural) was exactly this: no builder declared it, no encoder anywhere emitted it, the Dart
  reference engine never dispatched it, and the six tests beside it called the handler
  directly — covering nothing but themselves. Deleted, the same branch #743 took for the
  identical arm in the Python compiler. The known-gaps file freezes 34 more names found the
  same way but not individually investigated by #817's scope — a RATCHET (the gate also fails
  when an entry becomes declared or stops being registered), never a dumping ground for a new
  one.
- **A registered name's Dart COUNTERPART can change shape with nothing noticing (#732).**
  `register()` is last-write-wins, and BOTH of this file's override-registration call shapes —
  `registerExtraStdFunctions`'s `_r('name', ...)` and `patchCompiledEngine`'s
  `for (const handler of e.moduleHandlers ?? [])` loop, which calls `handler.register('name',
  ...)` instead — run AFTER the compiled engine's own table is built. So a name registered by
  EITHER shape, if it is ALSO in `dart/engine/lib/engine_std.dart`'s `_buildStdDispatch()`,
  permanently SHADOWS that Dart entry (~117 names, measured) — and a later change to the Dart
  side is invisible here: the TS regen gate (`Ball Artifact Freshness`) only diffs the COMPILED
  half, never this hand-written registry, and conformance only catches it if some fixture happens
  to hit the exact input shape the two now disagree on. **PR #919's review caught the checker
  covering only the first shape**: `patchCompiledEngine`'s loop registers 17
  arithmetic/comparison overrides (`add`, `subtract`, `multiply`, `divide`, `modulo`, `negate`,
  `bitwise_and`/`bitwise_or`/`bitwise_xor`/`bitwise_not`, `left_shift`, `right_shift`,
  `unsigned_right_shift`, `less_than`, `greater_than`, `lte`, `gte`) that `tools/
  check_ts_engine_overrides_sync.py` could not see at all — reproduced by mutating
  `dart/engine/lib/engine_std.dart`'s real `divide` entry and watching the gate answer `[]`.
  The checker now extracts names from both call shapes (its own module docstring has the detail)
  and fingerprints each shadowed Dart entry's behaviour (resolving a bare tear-off —
  `'concat': _stdConcat,` — to `_stdConcat`'s own body, not the one-line reference that never
  changes) against a committed snapshot, failing on any mismatch, any newly-shadowed name with
  no snapshot entry (from either shape), or any stale entry for a name that no longer shadows
  anything. `--update` regenerates the snapshot — run it, then actually read the diff and decide
  whether the override at `engine_setup.ts` still agrees, before committing. This generalizes the
  single override family `tools/check_error_rendering_tables.py` already pinned (PR #722's
  error-rendering table) to every other shadowing site reachable through either of the file's two
  registration-call shapes, structurally rather than by a hand-curated line list.

Both run in the `typescript` CI job, `--self-test` first.
