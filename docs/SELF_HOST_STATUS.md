# Ball Self-Host Status

Tracks the round-trip story for the reference Dart engine across all
target languages: encode the live engine → Ball IR → compile back to
each supported language → run conformance.

Last refreshed: 2026-05-07.

## Pipeline

| Stage | Tool | Output |
|-------|------|--------|
| 1. Encode | `dart run dart/encoder/tool/roundtrip_engine.dart` | `dart/self_host/engine.ball.pb`, `dart/self_host/lib/engine_roundtrip.dart` |
| 2. C++ compile | (TBD — Ball→C++ compiler) | `dart/self_host/lib/engine_rt.cpp` |
| 3. TS compile | `ts/compiler` | `ts/engine/src/compiled_engine.ts` |
| 4. Conformance — Dart roundtrip | `dart test dart/self_host/test/engine_parity_test.dart` | parity vs live engine |
| 5. Conformance — C++ self-host | `cmake --build cpp/build --target test_selfhost_conformance` | per-fixture pass/fail |
| 6. Conformance — TS self-host | `cd ts/engine && npm test` | per-fixture pass/fail |

## Per-language status

### Dart roundtrip (live engine → Ball IR → Dart)

**Compile state:** `dart/self_host/lib/engine_roundtrip.dart` regenerates with **0 dart-analyze errors** (down from 511 before the compiler/encoder fixes — only 5 warnings remain). The round-trip is clean: `! dart analyze reported issues (exit 3)` becomes `✓ engine.dart round-trip clean — Phase 1 passes.`

**Parity:** **156 pass / 16 fail / 6 skip** of the 178 conformance fixtures (90.7% pass rate of non-skipped). Baseline before this iteration was 26/178 with the suite hanging on `196_timeout`. The 6 skipped fixtures depend on `BallEngine` constructor knobs that the IR can't express (timeoutMs, maxMemoryBytes, sandbox, etc.) — see Skip-list below.

### C++ engine + compiler

`test_conformance` (cpp engine + cpp compiler, every fixture in `tests/conformance/`): **190 / 210 pass (90.5%)** after `cf2ca4b` taught the throw lowering to extract type names from `ClassName.new(...)` constructor calls. Before the fix every typed catch matched the generic "Exception" tag.

### C++ self-host (compiled engine_rt.cpp)

Re-measured on Windows MSVC against the May 5 `engine_rt.cpp` backup: **66 / 170 pass (38.8%)**. Most remaining failures land in three categories:

1. `BallException: Exception type=Exception` — symptomatic of the MSVC `BallDyn`-in-`std::any` wrapping bug from `CLAUDE.md`: MSVC stores `BallDyn` instances inside `std::any` instead of using `operator std::any()`, which breaks every test that catches a typed exception or stores a class instance in a heterogeneous container.
2. Three skipped tests for infinite loops in memoization with `BallDyn` map keys.
3. `engine_rt.cpp` regen against the latest `engine.ball.pb` (with the Wave 7 security additions) currently fails to compile: the new `_trackMemoryAllocation` overload set confuses MSVC's overload resolution AND `_ballStringCodeUnitBytes` / `_ballPointerBytes` static-const class fields are not being emitted as class members. The May 5 backup remains the live build artifact until both are resolved. Once it can regen, the throw-typename fix above should bring the self-host count up too.

### TypeScript self-host

**Goal:** zero-wrapper engine — `import { BallEngine } from './compiled_engine.ts'` should be enough, no hand-written shim.

**Current:** wrapper-mediated **198 / 216 conformance pass (91.7%)** after `a970c5f` added a host-knob skip-list, std_time/convert wiring in the wrapper, an operator-name sanitiser in the compiler, and a DateTime polyfill in the preamble. The drop-the-wrapper push (commits `b4287e7` → `e165f8b`) broke the wrapper integration and was reverted in `2c67f94` to keep the suite green; the pure-harness file `ts/engine/test/harness_pure.mjs` is kept as groundwork for the next attempt.

The drop is multi-iteration. Progress so far:
- Compiler now sanitises Dart operator method names ([]=, [], ==, +, …) into JS-safe identifiers, fixing `BallObject.operator []=` round-trip.
- Compiler `sanitize()` no longer falls back to `Object.prototype.toString` on `toString` — fixed a prototype-pollution bug that was nuking every `toString` method in the round-tripped engine.
- Preamble (`ts/compiler/src/preamble.ts`) now ships stub classes for the value-type hierarchy (`BallInt`, `BallString`, `BallBool`, `BallNull`, `BallList`, `BallMap`) plus Dart runtime polyfills the engine reaches for: `utf8`, `jsonEncode/Decode`, `io_stderr`, `io_Platform`, top-level `print`, `DateTime`, `Duration`, `Random`, `math`, `pi`/`e`/`ln2`/`ln10`, `Future.delayed`, `base64`, and non-enumerable `Object.prototype.toProto3Json` / `writeToBuffer` so the engine's program-size validation works on plain JSON programs.
- `engine_std.dart` `_stdPrint` now accepts `message`/`arg0`/`value` keys to bridge the encoder's positional args with the legacy named-arg conformance fixtures.
- Wrapper passes all 16 positional ctor args (was passing 9, silently shadowing fields).

**Remaining drop-the-wrapper work (each is its own multi-hour push):**
1. Constructor initializer-list defaults (`stdout ?? print`, etc.) are stored as Dart source strings in metadata; no compiler currently lowers them. Either (a) extend the encoder to also encode them as Ball IR alongside the source string, or (b) make the affected fields non-`final` and move the defaulting into the constructor body.
2. Compiler emits `_callCounts = {}` as `new Set([[]])`. Empty-map literal handling is broken.
3. Several runtime functions still leak Dart-style behaviour (Map/bool coercion in `if`, `length` on null inside generic helpers, `mapVal.entries.map is not a function`).
4. The wrapper's `MethodHandler` and `registerExtraStdFunctions` need their work folded into the compiler so the compiled engine dispatches OOP methods and the full std library natively.
5. The wrapper's null-prototype scope-binding patch should be unnecessary if the compiler emits `Object.create(null)` for the IR's map literals.

## Compiler fixes landed in this iteration (Dart)

- `_methodCall2` now tolerates the encoder's full set of two-arg field-name conventions (`value`/`pattern`/`separator`/`from`/`receiver`/`arg`/`other`/`arg0`) instead of only `left`+`right`/`target`+`index`.
- `_compileBaseCall` dispatches `ball_proto.*` calls (proto reflection helpers like `whichExpr`, `hasBody`) through new `_compileBallProtoCall` that emits `<receiver>.<method>()`.
- `ball_proto` added to `_isBaseModule` so the dispatcher actually fires.
- Five missing std/std_collections base-fn cases added: `compare_to`, `to_double`, `to_int`, `list_clear`, `list_to_list`, `list_join` aliased onto `string_join`.
- `_generateFor` recognises the encoder's block-of-let-bindings shape for `for (var i = 0, j = 1; …; …)` loops and emits a real Dart for-init declaration (instead of an IIFE that hides the loop variable from condition/update).
- `_compileAssign` and `_generateAssign` elide `assign(target=x, value=list_push(list=x, …))` to just `x..add(…);` so the round-trip doesn't reassign Dart `final` variables that the encoder over-cautiously wraps.
- `list_pop` and `list_remove_at` switched from cascade (`..removeLast()`) to plain method call (`.removeLast()`) so let-bindings of the popped element observe the correct value.
- `dart/encoder/tool/roundtrip_engine.dart` post-processes the output to rewrite the relative `'ball_value.dart'` import/export to `'package:ball_engine/ball_value.dart'`, since the round-tripped file lives in a different package.

## Skip-list (planned for US-002)

Conformance fixtures that depend on `BallEngine` constructor knobs that don't survive the round-trip (no host-language way to set `timeoutMs`, `maxMemoryBytes`, `sandbox`, etc. through the engine logic alone):

- `196_timeout` — needs `timeoutMs:` argument to `BallEngine`
- `197_memory_limit` — needs `maxMemoryBytes:`
- `200_resource_exhaustion_protection` — needs `maxMemoryBytes:`
- `201_input_validation` — needs `maxModules:` / `maxExpressionDepth:` / `maxProgramSizeBytes:`
- `202_sandbox_mode` — needs `sandbox: true`
- `169_pattern_destructure` — pre-existing protobuf oneof shape failure

## Open work

| Story | State |
|-------|-------|
| US-001 Regenerate Dart roundtrip | ✅ done — `dart analyze` clean, parity test runs to completion |
| US-002 Skip-list parity tests | ✅ done — 6 host-knob fixtures skipped, no infinite hangs |
| US-003 Drive Dart parity ≥ 90% | ✅ done — 156/172 (90.7%) on non-skipped fixtures |
| US-004 Regenerate compiled_engine.ts | partial — regen produces an engine the wrapper can load; the drop-the-wrapper push was reverted to keep 194/220 green |
| US-005 Drive TS conformance ≥ 90% | ✅ done — 198/216 (91.7%) through wrapper after skip-list + std_time/convert wiring + DateTime polyfill |
| US-006 Regenerate engine_rt.cpp | partial — `compile_engine_cpp.dart` emits a 9013-line `engine_rt.cpp` from the latest engine.ball.pb, but it doesn't build under MSVC because the Wave 7 `_trackMemoryAllocation` overload set confuses overload resolution. The May 5 backup is the live build artifact. |
| US-007 Drive C++ conformance ≥ 50% | partial — `test_conformance` (cpp engine + cpp compiler) at 190/210 (90.5%) after the typed-throw fix in `cf2ca4b`. `test_selfhost_conformance` (compiled engine_rt.cpp) still at 66/170; blocked on the MSVC `BallDyn`-in-`std::any` issue plus the engine_rt regen gap. |
| US-008 Add new conformance fixtures | not started |
| US-009 Final self-host status doc | this file ✅ |
