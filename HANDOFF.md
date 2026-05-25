# Ball — Engineering Handoff (for Cursor / next agent)

> Generated 2026-05-25. Honest, detailed status of an in-progress push toward
> production-readiness + full self-hosting. Read this top-to-bottom before
> touching anything. Where a number is *freshly verified this session* it says
> so; where it's *reported/older* it says "verify".
>
> **Cross-checked 2026-05-25 by 5 parallel read-only verification agents** (git/state,
> Dart, TS, C++, structure): all metrics, 16 commit hashes+messages, `stash@{0}`, every
> listed file path, build commands, invariants, and named fixtures were CONFIRMED. The
> only inaccuracies found were drifted `engine_rt.cpp` line anchors — corrected below.

---

## 0. Mission (north star — do not lose sight of these)

1. **100% conformance coverage across C++, Dart, TS** engines.
2. **Self-hosting fully working across all languages** — the Dart reference engine, encoded to Ball IR, compiled to each target, with the *compiled* engine passing the full conformance suite on each.
3. **Conformance tests covering every aspect & edge case of every language** (expand the fixture set; today's 189 fixtures are not exhaustive).
4. **Wire everything in GitHub Actions** with hard regression gates.
5. **Follow best practices** (no anti-patterns, well-tested compilers/encoders).
6. **Maximize performance, minimize cost.**

---

## 1. Current verified status (snapshot at HEAD `74057db`)

| Track | Status | Verified? |
|---|---|---|
| **TS self-host** | `ts/engine` **227/227**, `ts/compiler` **227 pass / 0 fail** (fresh-compile conformance + parse gate + units) | ✅ freshly verified this session |
| **C++ self-host** | `run_selfhost_tally.sh` = **PASS=144 FAIL=34 TIMEOUT=1 CRASH=10** (of 189) | ✅ re-tallied this session |
| **C++ native engine** | `test_conformance` = **201 passed / 20 failed / 221** | ✅ just ran this session |
| **Dart** | reference engine (mature); `dart/compiler` 85/85, `dart/encoder` 116/116 | reported by quality worker (commit `0c621c1`) — re-run to confirm |
| **Dart round-trip parity** | 183/183 non-skipped | per `docs/SELF_HOST_STATUS.md` — verify |
| **CI** | `.github/workflows/regression-gates.yml` added (numeric floors) | ✅ YAML validated; never executed (needs a push) |

**Bottom line:** TS self-host is *done and green*. C++ self-host is at **144/189** — a hard no-debugger ceiling (see §3). Dart is the reference. The remaining gap to "100%" is concentrated in C++ (an OOP dispatch gate that needs a stepping debugger) plus missing edge-case fixtures everywhere.

---

## 2. What was done this session (16 commits, `125e518`..`74057db`)

**Cross-language correctness**
- `125e518` fix(ts): **canonicalize comparison/shift std fn names** in encoder+compiler. The TS encoder emitted `less_than_or_equal`/`greater_than_or_equal`/`shift_left`/`shift_right` — names that **do not exist in the std module** (`dart/shared/lib/std.dart` defines `lte`/`gte`/`left_shift`/`right_shift`). A TS-encoded program compiled to `/* unsupported */` under the Dart compiler. Encoder now emits canonical names; removed the dead defensive aliases from the TS compiler.

**TS self-host (got `ts/compiler` Phase 2.7b from all-red → green)**
- `31a10c9` fix(ts/compiler test): the Phase 2.7b harness built `BallEngine` with a stale **9-arg ctor**; the self-host engine ctor grew to **16 args** (security knobs added; `moduleHandlers` is slot 15). Fixed → un-redded the whole suite.
- `823827c` fix(ts): extracted `index.ts`'s engine setup into a **shared `ts/engine/src/engine_setup.ts` factory** consumed by *both* `index.ts` and the Phase 2.7b harness → harness/index.ts drift is now structurally impossible. All 19 remaining failures were harness-parity gaps (zero compiler bugs). **Confirmed committed `compiled_engine.ts` is NOT stale** (0 content diff on regen).
- `d780fed` fix(ts/compiler test): `engine_parse.test.ts` asserted `export type BallValue`; compiler emits `class BallValue` (preamble base class). Stale assertion fixed.

**C++ self-host (138 → 141 → 144)**
- `0563e1d` fix(cpp/compiler): higher-order callback field-name bug — handlers read only `"callback"` but the encoder names the closure field `"value"`; added `get_callback_field()` (callback→function→value) across `list_any/all/none/find/reduce/sort_by/flat_map` + `map_map/filter`. Fixed `105_static_methods` + 2 others. **138→141**.
- `2a2a75e` fix(cpp/compiler): dynamic-invoke closure dispatch — `apply()` didn't unwrap the BallDyn callee (the MSVC `std::any`-of-`BallDyn` quirk); `Map.values.first` mis-compiled to a key lookup. Fixed `85_closure_counter`, `203_closure_in_loop`, `211_nested_closures_currying`. **141→144**.

**Compiler/encoder quality (audit-driven)**
- `0c621c1` fix(dart/compiler): `compileAllModules` now surfaces `failedModules` instead of `catch(_){}` silent drop; **handle goto/label in statement context** (was leaking `/* unsupported */`). + tests.
- `7ccc9f4` fix(ts/compiler): std-dispatch probes now **rethrow non-sentinel errors** (`__isUnknownFnError`) instead of swallowing all.
- `5b7c92b` fix(ts/encoder): **null/undefined/void → empty `Literal` `{literal:{}}`** (MATCHING the Dart reference — not invented); concat heuristic → `isProvablyString` else polymorphic `std.add`; `strict` now throws + `encodeWithWarnings()`. +15 encoder tests.

**CI**
- `705158a` ci: `regression-gates.yml` — hard numeric floors the existing exit-code-only workflows missed (TS 227/0; C++ self-host PASS≥144, `continue-on-error` until the C++ build stabilizes). Action versions verified vs release pages; Node pinned to 22 (`--experimental-strip-types` since 22.6.0).

**Performance**
- `88b5a87` perf(ts): gate the `whichExpr/whichValue/...` discriminator method-probe behind `hasOwnProperty` so plain AST nodes skip the `Object.prototype` walk. V8 `--prof`-confirmed megamorphic-IC win (KeyedLoadIC_Megamorphic 24.4%→17.8%); ~5% faster. Benchmark added at `ts/engine/bench/bench.ts`.
- `f5c4721` test(cpp): `test_perf_micro` focused native-engine benchmark.
- `0026b74` perf(cpp): compile out 7 engine debug-trace blocks behind `BALL_ENGINE_DEBUG_TRACE`.
- `2c205c8` perf(cpp): single-walk `Scope::set`/`eval_reference` (new `Scope::find`).
- `74057db` perf(cpp): borrow `Program` by `const&` instead of deep-copying per engine construction. (Micro-bench: deep_recursion 12.9→4.7ms.)

**Docs**
- `4ac946e` docs(self-host): banked the decisive diagnosis (see §3).
- `.omc/research/performance-roadmap.md` — full prioritized perf roadmap (evidence-backed, cited).

---

## 3. Key decisions & findings (the non-obvious stuff — READ THIS)

1. **The C++ OOP cluster (`104` getter/setter, `106` factory_ctor, `110` mixin, `164/165/166/177/179` oop_*) all converge on ONE root cause: a dispatch-via-self null-return.** In the *compiled* C++ engine, `_trySetterDispatch` (and getter-via-self) returns null despite valid `is_setter:true`/`is_getter:true` metadata — but the **identical logic passes on the Dart engine**. So it is a C++ *emission/runtime* divergence, not a reference-engine bug. For `104`: the failed setter falls through to writing a spurious *raw* field, and `_evalFieldAccess` (`dart/self_host/lib/engine_rt.cpp` ~4698) reads the raw field before getter dispatch → the exact `100.0/32.0` split.
2. **Reference-semantic instances are NECESSARY BUT INSUFFICIENT for 104/106.** A full, isolation-verified `BallObjectRef = shared_ptr<BallObject>` implementation was built (twice). It compiles, has correct pointer-identity `==`, avoids the old `bad_alloc` self-cycle (by binding `self` only in the method scope, never as an owning instance-map entry) — but it **flips zero fixtures** and one variant introduced a new crash (`165`). **The dispatch null-return is the orthogonal blocker.** This implementation is preserved in **`git stash@{0}`** ("ref-sem WIP (a79d26da...)") and the design sketch is banked in `docs/SELF_HOST_STATUS.md` — re-appliable once the dispatch gate is cracked.
3. **The dispatch gate is "debugger-class."** Multiple agent attempts (mechanical-bug hunting) failed; it needs a **stepping debugger** (the user has VS). See §8 for the recipe. This is the single highest-leverage item for C++ conformance (~8 fixtures).
4. **`std::any` tagged-union fast-path (perf #6) was deliberately SKIPPED.** The native engine uses `std::any` not `BallDyn`; `BallDyn._val` is *public* and the generated `engine_rt.cpp` writes it directly in 2 places → a separate tag would go stale → silent wrong-cast crashes. Arithmetic already tests `int64_t` first. Matches the roadmap's "do NOT bother (std::any rewrite family)" list.
5. **The self-host pipeline is a SHARED SERIAL RESOURCE.** `dart/compiler/tool/compile_engine_cpp.dart` reads `dart/engine/lib/engine.dart`, encodes via `ball_encoder`, writes `engine.ball.pb`, then runs `ball_cpp_compile.exe` → `engine_rt.cpp`. So **any worker editing `cpp/` OR `dart/engine` must run alone** — concurrent edits corrupt the regeneration. (TS-only work IS parallel-safe.)
6. **Build gotchas:** (a) MSVC `LNK1104` (exe locked by a prior process) can make MSBuild return **exit 0** with a broken/stale exe — always verify the exe and grep build output for `LNK`/`error`, never trust exit code alone. (b) Stale MSVC incremental builds repeatedly masked changes → `touch cpp/test/test_selfhost_conformance.cpp` before rebuilding. (c) The in-process self-host harness dies on the first stack-overflow fixture → only `bash cpp/test/run_selfhost_tally.sh` (isolated process per fixture) gives a reliable count.
7. **Rate-limit lesson:** long agent runs got killed mid-work by transient *server* rate-limits ("not your usage limit"). **Commit each verified item immediately** — never batch — so a throttle can't erase progress. This is why the perf commits are granular.

---

## 4. Remaining work (toward the mission)

### 4a. IMMEDIATE next — Perf wave 3 (started conceptually, NOT launched)
`dart/engine` perf, in priority order. **Every item re-flows into the self-host** (regenerate `engine_rt.cpp` + `compiled_engine.ts`, re-run FULL parity: Dart engine tests, C++ tally ≥144, ts/engine 227/227, ts/compiler 227/0). Commit each incrementally.
- **#3** `_validateProgramLimits` JSON-encodes the whole program on every engine construction (`dart/engine/lib/engine.dart:206-214`) → use binary size / opt-in. (Safe, S–M.)
- **#4** O(n²) module-scan dispatch fallbacks (`engine_eval.dart:262-303,527-571`) → `(type,method)` dispatch tables + inline cache. (M.)
- **#2 (CAPSTONE, biggest win ~2×, highest risk)** the Dart engine is `async` end-to-end (`engine_eval.dart:24-50`) — every node awaits a `Future`. De-async where awaiting has no effect. **Revert entirely if it regresses any engine's conformance.**

### 4b. C++ self-host → higher coverage
- **Crack the dispatch-via-self gate** (§3.1, §8) — needs a debugger. Unblocks ~8 OOP fixtures. Then re-apply `stash@{0}` (ref-sem) for the instance-mutation ones.
- **`109_enum_values` + `205_map_ordering`**: need **insertion-ordered maps** (current `std::map` iterates by key). `unordered_map` is forbidden (CLAUDE.md); the right move is an insertion-ordered map type — a perf+correctness twofer. Also `109` needs proto3-JSON zero-int32 handling for enum index 0.
- **Generators** (`162/163/174/175/176/209`): need a real event loop / coroutine model (currently sync simulation). Large.
- **CRASH set** (`196/197/200/201/202` etc.): host-knob / sandbox / resource-exhaustion fixtures — may need host integration or are intentionally unrunnable; triage which are fixable.
- **Build perf #5 (not done):** split the ~10,200-line `engine_rt.cpp` single TU into N TUs + wire **Ninja** (MSVC `/MP` can't parallelize one file). Near-linear recompile speedup; the stated build bottleneck.

### 4c. Conformance coverage (mission goal #3 — largely UNSTARTED)
The 189 fixtures are *not* exhaustive. Systematically add edge-case fixtures per language feature: numeric edge cases (overflow, NaN/Inf, int/double coercion), string/unicode edges, collection mutation aliasing, exception chaining/rethrow, async ordering, closures/currying, pattern-matching exhaustiveness, generics. Each fixture = `tests/conformance/<n>_<name>.ball.json` + `.expected_output.txt`, must pass on Dart (reference) first.

### 4d. CI (mission goal #4 — partially done)
- Extend `regression-gates.yml`: add Dart engine/encoder/compiler gates + native C++ `test_conformance` floor (201).
- Make the C++ self-host job **blocking** (drop `continue-on-error`) once the Linux build is reliably green.
- The workflow has **never run** — first push will shake out runner/version issues.

### 4e. Cleanup / parity milestones (NOT yet safe)
- `#11` delete hand-written `cpp/engine/` and `#12` delete `ts/engine/src/index.ts` wrapper — **only after** the self-host engines reach parity with the hand-written ones. C++ self-host (144) < native (201), so **NOT yet** for C++. TS could potentially drop the wrapper since `engine_setup.ts` is factored out — verify first.
- Stale tasks `#2` (`_trackMemoryAllocation` overload), `#3` (static-const class fields), `#15` (multi-param lambda callbacks) — verify if still relevant; some may be obsolete.

---

## 5. Repo hygiene / loose ends (uncommitted state at handoff)

- **`git stash@{0}`** — the ref-sem `BallObjectRef` WIP (see §3.2). Keep; re-appliable.
- **`CLAUDE.md`** — shows as modified (uncommitted, a manual edit — I did not touch it). **Review & commit/revert deliberately.** Note: its std fn-counts are stale (actual per `std.json`/`dart/shared/lib/`: `std`=118 not ~73, `std_collections`=53, `std_memory`=38, `std_io`~10 ok) — worth fixing while editing.
- **`dart/compiler/tool/compile_engine_cpp.dart`** — uncommitted improvement: auto-selects the *freshest* `ball_cpp_compile.exe` across build dirs (defeats stale-build picks). Useful — consider committing.
- **`dart/encoder/bin/inspect_ir.dart`** — ad-hoc inspection scratch script; harmless.
- **`conf_ps.txt`** — leftover scratch file; delete.
- **`.claude/worktrees/agent-a4359438`** — dirty git submodule (shows as ` m`, not untracked); leftover agent worktree, clean up.
- **`cpp/build3/**`** — build artifacts are *tracked* in this repo and show as modified after every build (noise). Decide whether to keep committing them or gitignore. Also untracked build dirs `cpp/build2/_deps/protobuf-src` + `cpp/build3/_deps/protobuf-src`. (`HANDOFF.md` itself is also currently untracked.)
- **`docs/marketing/`** — untracked; unrelated to engineering.

---

## 6. Key files map

- **Schema (source of truth):** `proto/ball/v1/ball.proto`
- **Std module:** `dart/shared/lib/std.dart` → regen `std.json`/`std.bin` via `dart run bin/gen_std.dart`
- **Dart (reference):** `dart/compiler/lib/compiler.dart`, `dart/encoder/lib/encoder.dart`, `dart/engine/lib/engine.dart` + `engine_eval.dart` + `engine_*.dart`
- **C++:** `cpp/compiler/src/compiler.cpp`, `cpp/shared/include/ball_dyn.h` + `ball_emit_runtime.h`, `cpp/engine/{include/engine.h,src/engine.cpp}`
- **C++ self-host (generated):** `dart/self_host/lib/engine_rt.cpp` (NEVER hand-edit), `dart/self_host/engine.ball.{pb,json}`
- **TS:** `ts/compiler/src/{compiler.ts,preamble.ts}`, `ts/encoder/src/encoder.ts`, `ts/engine/src/{index.ts,engine_setup.ts,compiled_engine.ts (generated)}`
- **Conformance fixtures:** `tests/conformance/*.ball.json` + `*.expected_output.txt`
- **Status docs:** `docs/SELF_HOST_STATUS.md` (history + banked diagnoses), `.omc/research/performance-roadmap.md` (perf roadmap), `cpp/AGENTS.md`, `.claude/rules/{cpp,dart}.md`

---

## 7. Build / test / verify (commands + gates)

```bash
# Dart
cd dart && dart pub get
cd dart/engine && dart test
cd dart/encoder && dart test
cd dart/compiler && dart test

# TS (each package has its own node_modules)
cd ts/engine && npm install && npm test       # MUST be 227/227
cd ts/compiler && npm install && npm test      # MUST be 227 pass / 0 fail

# C++ self-host regen + tally (the slow, shared-serial path)
cmake --build cpp/build3 --target ball_cpp_compile --config Release        # only if compiler.cpp changed
cd dart && dart run compiler/tool/compile_engine_cpp.dart                  # regen engine_rt.cpp from dart/engine
touch cpp/test/test_selfhost_conformance.cpp                               # defeat stale incremental build
cmake --build cpp/build3 --target test_selfhost_conformance --config Release
bash cpp/test/run_selfhost_tally.sh                                        # MUST stay PASS>=144  (isolated-process; only reliable count)

# C++ native conformance
cmake --build cpp/build3 --target test_conformance --config Release        # MUST stay 201/221
# (verify the exe exists; grep build log for LNK/error — MSBuild exit 0 can lie)

# Fast C++ inner loop (don't full-tally every change):
exe=cpp/build3/test/Release/test_selfhost_conformance.exe
for f in 101_simple_class 132_merge_sort 10_fibonacci 203_closure_in_loop 104_getter_setter; do
  BALL_TEST_FILTER="$f" "$exe" 2>/dev/null | grep -E "  (PASS|FAIL|TIMEOUT|CRASH): $f"; done

# Regenerate TS compiled engine (after a dart/engine OR ts/compiler change):
#   1) regenerate engine.ball.json from dart/engine (roundtrip_engine.dart)
#   2) compile engine.ball.json through ts/compiler into ts/engine/src/compiled_engine.ts
#      (see the exact node one-liner in root CLAUDE.md "Build & Test")
```

**Hard invariants (CLAUDE.md):** one input/output per function; metadata is cosmetic; base functions have no body; control flow is lazy std functions; never edit generated files; maps are ordered (`std::map`, never `unordered_map`).

---

## 8. Debugger recipe for the dispatch-via-self gate (the unlock for ~8 C++ fixtures)

1. Build `test_selfhost_conformance` in **Debug**, breakpoint in the `104_getter_setter` path.
2. In the *generated* `dart/self_host/lib/engine_rt.cpp`, find `_trySetterDispatch` (~4976) and `_isSetter` (~4964). Watch why it **returns the not-found sentinel** for a setter whose metadata clearly has `is_setter:true` — compare the **registration key** (how `_setters` is populated) vs the **lookup key** constructed at dispatch (module/type/field-name concatenation, trailing `=`, `__type__` resolution). The Dart engine does this correctly; the C++ emission diverges somewhere in key construction or a metadata read mis-compiled under MSVC (recall the `std::any`-of-`BallDyn` typeid quirk → always `_BallDynUnwrapper::unwrap` before `.type()`/`any_cast`).
3. Also watch `_evalFieldAccess` (~4698): it reads a present **raw** field *before* getter dispatch — confirm whether the fix is (a) make setter dispatch succeed, or (b) make field access prefer getter dispatch over a raw field when the type has a getter.
4. Once dispatch returns the live setter and mutates the scope-bound `self`, re-apply `git stash@{0}` (the `BallObjectRef` reference-semantics foundation) so the mutation is visible to other holders → expect `104`/`106` + several `oop_*` to flip. Re-tally; commit per the incremental discipline.

---

## 9. How to resume (suggested order)

1. **Decide on perf wave 3** (§4a) — `#3`/`#4` are safe; `#2` de-async is the big win but re-flows everywhere (gate hard, revert on any regression).
2. **Crack the dispatch gate with a debugger** (§8) — highest C++ conformance leverage; then re-apply `stash@{0}`.
3. **Insertion-ordered maps** (109/205) — perf+correctness twofer.
4. **Expand conformance coverage** (§4c) — the real path to "100% of every edge case."
5. **Push the branch & shake out CI** (§4d).
6. **Tidy loose ends** (§5) — especially review the uncommitted `CLAUDE.md`.

*Everything in §1 marked ✅ was verified this session; re-run the suites after any pull, since several artifacts (compiled_engine.ts, engine_rt.cpp) are generated and must stay in sync with their sources.*
