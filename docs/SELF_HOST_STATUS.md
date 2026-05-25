# Ball Self-Host Status

Tracks the round-trip story for the reference Dart engine across all
target languages: encode the live engine → Ball IR → compile back to
each supported language → run conformance.

Last refreshed: 2026-05-25 (C++ self-host 144 — dynamic-invoke callee/arg unwrap + `Map.values.first` emission fix, +3 incl. 85/203/211; TS 227/227 (100%), Dart parity 183).

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

`test_conformance` (cpp engine + cpp compiler, every fixture in `tests/conformance/`): **194 / 210 pass (92.4%)**. Stack of fixes this session:
- `cf2ca4b` — typed-throw lowering extracts class names from `ClassName.new(...)` so typed catches dispatch correctly.
- `c0cad5e` — `list_filled` dispatch added (was crashing every `List.filled(...)` fixture).
- `83abf4f` — `format_timestamp` emits the trailing `.millisZ` suffix to match Dart's `DateTime.toIso8601String()`.
- `f5b14ce` — std/dart_std flat namespace now routes std_time / std_convert helpers through `eval_time` / `eval_convert` so fixtures that call `std.year`, `std.json_encode`, etc. don't trip 'Unknown std_collections function'.
- `6d22688` — `list_generate` accepts Dart's `length`/`generator` field names alongside the legacy `count`/`function`.

### C++ self-host (compiled engine_rt.cpp)

**2026-05-25 (141 → 144): dynamic-invoke closure dispatch.** Two related
compiler/runtime-emission fixes for `dart_std.invoke` (calling a closure stored
in a variable/list — the higher-order-function path):
- **`apply()` callee/arg unwrap (`cpp/shared/include/ball_emit_runtime.h`).** The
  engine's `_stdInvoke` checks `ball_is_function(callee)` (which unwraps via
  `_BallDynUnwrapper`) and then calls `apply(Function, callee, args)`. But `apply`
  matched `callee.type() == typeid(std::function<...>)` WITHOUT unwrapping — and
  under MSVC a `BallDyn` passed where a `std::any` is expected is stored as
  `typeid(BallDyn)`, not its inner `std::function`. So every dynamically-stored
  closure passed `ball_is_function` yet `apply` returned `std::any{}` (null). Fix:
  unwrap `callee` (and the single argument) before the type check. Unblocked
  `85_closure_counter` and `203_closure_in_loop` (lambdas pushed into a list and
  invoked).
- **`Map.values.first` emission (`cpp/compiler/src/compiler.cpp`,
  `compile_field_access`).** `_stdInvoke`'s single-positional-argument path reads
  the Dart `args.values.first` (the `Map.values` getter → first value). The
  compiler deliberately does NOT blanket-map `.values` (it's overloaded across
  BallGenerator/enum/ListValue — a blanket `ball_map_values` once regressed
  72→40), so the bare `.values` fell through to a key lookup `args["values"]`
  (null), and the invoked lambda received null instead of its argument. Fix:
  when `.first`/`.last` directly consumes a `.values` field access, emit
  `ball_map_values(inner).front()`/`.back()` — unambiguous and narrow (only the
  chained form is rewritten; bare `.values` is untouched). Unblocked
  `211_nested_closures_currying` (`adder(a)=>(b)=>(c)=>a+b+c`, curried via invoke).
  Verified +3, zero regressions on the 141 baseline.

**Banked (need reference-semantic instances or ordered maps — architecture-level,
not mechanical; deferred):**
- **`106_factory_constructor`** — factory returns a cached instance; the test
  asserts `identical(l1, l2)` is `true` when both share a name. Two issues: (1)
  `BallDyn::operator==` (`cpp/shared/include/ball_dyn.h:459`) returns `false` for
  ALL maps/lists/objects (only int/double/bool/string compare by value), so
  `identical(BallDyn,BallDyn)` (ball_dyn.h:1092 `return a == b`) can never report
  identity for two instances; (2) even with a correct identity check, instances
  are by-value `BallObject`s, so the cached `_cache[name]` copy is not the same
  object as `l1`. A correct fix needs shared_ptr-backed reference-semantic
  instances (the documented blocker that causes self-referential `self` cycles →
  bad_alloc) AND pointer-identity in `operator==`. Output today differs by exactly
  one line (`false` vs `true`).
- **`109_enum_values`** — two C++ self-host bugs, both data-fidelity/container:
  (1) **index null for value 0**: enum values build `index` from `v["number"]`
  (engine.dart ~327), but `proto_msg_to_any` in the conformance harness omits
  zero-valued int32 fields (proto3-JSON default-omission, test_selfhost_conformance.cpp
  ~177), so `red`'s `number:0` is absent → `index` is null. The Dart reference
  reads the proto object where `v.number` always materializes 0. (2) **ordering**:
  `_enumValues[name]` is a `BallMap` (`std::map`, key-sorted), and `Color.values`
  iterates it alphabetically (`blue,green,red,yellow`) instead of declaration
  order. Needs insertion-ordered maps — a core container change (CLAUDE.md mandates
  `std::map`); deferred with the map-ordering cluster (155/118/124/125/205).
- **`110_mixin`** — `doc.label` via direct `fieldAccess` works ("My Report"), but
  the mixin method `printLabel` referencing the `label` getter through `self`
  returns null. Both paths funnel into the identical `_tryGetterDispatch(doc,
  "label")` with the same `doc` BallObject (`__type__`=`main:Document`,
  getterKey=`main.main:Document.label`); static trace shows no logic divergence
  (engine_rt.cpp: reference self-fallback ~4623-4645 vs fieldAccess ~4765). This
  is the documented "self-binding gate" class (same as 164/165/166/177/179) —
  needs a stepping debugger (cdb/VS) to watch the scope/self object identity
  through `_callFunction`'s `bind(scope,"self",…)` (engine_rt.cpp ~3731) and the
  body `label` reference. Not available in the agent environment; TS (227) and
  Dart (183) pass it, so the engine logic is correct.

**2026-05-25 (138 → 141):** Fixed a higher-order-callback drop in the C++
compiler. The self-hosted engine resolves bare class names (for static-method
dispatch) via `_functions.keys.any((k) => k.startsWith(...))`. The encoder names
that closure field `value` (not `callback`), but the compiler's `list_any`
handler (and `list_all`/`list_none`/`list_find`/`list_reduce`/`list_sort_by`/
`list_flat_map`/`map_map`/`map_filter`) only read the `callback` field — so the
lambda was dropped and emitted as an empty `BallDyn()`. At runtime `fn(e)` then
returned null, `hasStaticMethods` was always false, `MathUtils` never resolved to
a `__class__` ref, the static call fell through to a recursive resolution path,
and `105_static_methods` died with the empty `BallException` from the
`maxRecursionDepth` guard. Fix: a `get_callback_field()` helper
(`cpp/compiler/include/compiler.h`) that tries `callback`→`function`→`value` in
turn, wired into all the higher-order handlers in `cpp/compiler/src/compiler.cpp`
(`list_map`/`list_filter` already had this fallback inline). Verified +3 (incl.
105), zero regressions.

**Still failing — `104_getter_setter` (banked diagnosis, needs a debugger):**
A setter mutates `self.<field>`, but the mutation is not visible to a later
getter read. Reference engine path: `_trySetterDispatch` (engine_eval.dart ~838)
→ `_callFunction({self, value})` → setter body `assign(_celsius, value)` (a
simple-reference assign) → `_syncFieldToSelf` (engine_eval.dart ~898) mutates
`self['_celsius']`. Under Dart `self` is the same object reference as the
caller's `t`, so it persists. Under C++ the mutation is lost across the by-value
copy chain: in the generated engine_rt.cpp, `_syncFieldToSelf` does
`auto selfMap = BallDyn(_asMap(self))` then `ball_set(selfMap, ...)`, but
`_asMap` (and `lookup(scope,"self")` before it, and `_cfAsMap(obj)` in
`_evalAssign`) each value-copy the map (`ball_map_entries`/`BallDyn(v)`), so the
write lands on a throwaway local. The non-setter assign path papers over this
with `_cfWritebackInstance` (re-stores the mutated `map` into the scope var), but
the setter path returns the setter's value immediately (engine_rt.cpp ~6250) and
never writes back — and even if it did, `map` was never mutated (the setter
mutated its own deep copies). A correct fix needs the setter's `self` to share
storage with the caller's `map` (reference-backed) for the duration of the call,
then a writeback — but instance maps are deliberately by-value (a shared map
creates self-referential `self` cycles → bad_alloc). Pinning down exactly which
copy in the 4-deep chain (`t` → `obj` → `map` → setter `self` → `selfMap`) must
become reference-backed without re-introducing the cycle crash needs a stepping
debugger (cdb/VS) to watch object identity through `_evalAssign` → setter
`_callFunction` → `_syncFieldToSelf`. Curiously the celsius getter immediately
after the setter reads the new value (100.0) while the fahrenheit getter on the
same `t` reads stale (32.0), implying the mutation half-persists — a strong sign
the divergence is per-copy and only a debugger can resolve which lookup retains
it. Not available in the agent environment; TS (227/227) and Dart pass this, so
the engine logic is correct.

**2026-05-25 — reference-semantic instances built + REFUTED the by-value
hypothesis above (reverted, banked diagnosis).** Implemented shared_ptr-backed
OOP instances (`BallObjectRef = std::shared_ptr<BallObject>`, mirroring the
`BallListRef` precedent): `BallDyn(BallObject)` ctor allocates a shared handle;
`_objPtr()`/`_isObject()` deref both by-value and ref; `operator==` compares
pointer identity for two `BallObjectRef` (fixes `identical` + guards the
`__super__` cycle); deref hooks (`_BallRefDeref::_obj_fn`/`_obj_id_fn`) let
`ball_is_map`/`ball_object_type_matches`/`_ball_object_base_map` recognise the
handle from `ball_emit_runtime.h`; `self` is bound in the method SCOPE (never as
an owning instance-map entry), so there is NO self-cycle. **It compiled cleanly
under MSVC, was VERIFIED CORRECT in isolation** (a header-only `inst_probe`:
instance/obj/scope-var all observe a setter writeback = 100.0, and
`identical(instance,obj)==1`), and was **ZERO-REGRESSION (144→144)**.

But it flipped NOTHING, because the real 104 blocker is NOT the by-value copy
chain — it is **setter dispatch falling through to a spurious raw-field write**.
Env-gated `[SET]`/`[BIND self]` tracing of the live engine showed: for
`assign(t.celsius = 100)`, `_evalAssign`'s fieldAccess path calls
`_trySetterDispatch(map, "celsius", 100)` which **returns null** → the
fall-through `ball_set(map, "celsius", 100)` runs (confirmed landing on the
shared instance, objPtr stable across both setters). `_evalFieldAccess`
(engine_rt.cpp ~4867) reads a present RAW field BEFORE attempting getter
dispatch, so `t.celsius` then returns the spurious raw `celsius`=100 (right
answer, WRONG mechanism — the getter never ran), while `t.fahrenheit` has no raw
field, dispatches its getter, and reads the never-mutated `_celsius`=0 → 32. That
is the exact `100.0 / 32.0` split, not "half-persisted mutation." The fixture's
metadata DOES carry `is_setter:true` (under `metadata.fields.is_setter.boolValue`
in the harness's Struct→`{fields:{...}}` shape), and registration + `_isSetter`
read that key, so by static analysis `_trySetterDispatch` SHOULD recognise the
setter — yet the trace proves it returns null. The deciding condition (the
`_setters[key]`/`_setters[key=]` lookup vs the `object["__type__"]`-derived
`setterKey`, or the `_isSetter` boolValue read) needs a stepping debugger to
watch; this is the same self-binding/dispatch gate as 164/165/166/177/179.
Reference-semantic instances are a NECESSARY foundation (they make the eventual
writeback land on the live object and give `identical` pointer identity) but are
INSUFFICIENT alone — reverted to protect the clean 144 until the setter-dispatch
null-return is root-caused with a debugger. The full diff (ball_dyn.h /
ball_emit_runtime.h / compiler.cpp `ball_map_entries`/keys/values) is small and
re-appliable once the dispatch gate is fixed.

**2026-05-24:** `engine_rt.cpp` now **compiles cleanly under MSVC against the latest
encoder IR** (commits `861cb5f`, `00a3151`) and passes **61 / 175** conformance
fixtures (after the `ball_map_entries` unwrap fix below) when each test runs in
an isolated process (the in-process harness dies
on the first stack-overflowing fixture, so use a per-test loop with
`BALL_TEST_FILTER` to get a robust count). This is the first time the latest IR
compiles at all — the old 66/170 figure below was against a stale May-5 backup
that couldn't compile the current IR.

Getting from 0→56 required: a cascade fix (the compiler was dropping every
`..addAll()`/`..[]=` op), 17 missing std functions (`string_starts_with`,
`for_in`, `compare_to`, …, were emitting `0` placeholders), constructor-default
field initializers, `field_2`→`field` getter mapping, and `_Scope(parent)`→
`child(parent)`.

**2026-05-24 (later):** Root-caused and fixed the OOP field-visibility bug.
The method-scope field-binding loop iterates `ball_map_entries(selfMap)`, but
`ball_map_entries` did `static_cast<std::any>(v)` and checked `a.type()`
WITHOUT unwrapping — and under MSVC `static_cast<std::any>(BallDyn)` wraps the
BallDyn (typeid==BallDyn) instead of calling `operator std::any()`, so the
type checks matched neither `BallMap` nor `BallObject` and it returned an empty
list. Zero fields bound → method bodies read every instance field as `null`.
Fix: `_BallDynUnwrapper::unwrap` the value first (same fix applied to
`ball_concat`). Verified with a standalone `cpp/test/scope_probe` (a fast,
header-only reproduction of bind/child/has/lookup + ball_map_entries — builds in
seconds, no 9400-line engine rebuild). Field READS now work.

**2026-05-24 (later still):** Fixed OOP field WRITE (`p2.x = 5`) too. C++
`BallDyn` value-copies the instance map on every scope `lookup`, so the in-place
`map[field]=val` mutated a discarded copy. Added `_cfWritebackInstance` in the
engine's field-assignment path: after the write, re-store the mutated map to the
variable when the target is a simple reference. The guard
`obj is! Map || obj is BallMap` adapts per target — under Dart a `BallObject`
is not a `Map` (so it's skipped, no type change; raw-map instances re-set the
same reference harmlessly), while under C++ it reads as a map and is persisted.
Cross-target safe: Dart class-range conformance (`dart test --name "10"`) stays
green and `101_simple_class` now PASSES end to end. Count: **59/175**.

**2026-05-24 (index writeback + list-set):** Extended the same writeback to
index assignment (`list[i] = val` / `map[k] = val`) via `_cfWritebackIndexed`,
and taught `BallDyn::set(string, …)` to honour a numeric key on a `BallList`
(the emitter stringifies all index keys, and the list branch was missing — a
silent no-op). Raw-map mutation now persists → **61/175**. THEN list integer-index reads (list[i]) were returning null because BallDyn::operator[](BallDyn) stringified an int key — fixed to positional-index for list/string receivers → **72/175** (unlocked 27_list_ops, insertion_sort + list-algorithm family). NOTE: in-place list
mutation (sorts: 80/88/131–134, …) is still broken because the engine stores
program lists as a `BallList` *wrapper* (`{__type__:"BallList", items:[…]}`,
`_evalListLiteral` returns `BallList(...)`), and the C++ engine copies `.items`
out of the wrapper on read — so `list.items[i] = val` mutates a discarded copy.
A capture+`BallList(items)`+writeback attempt didn't help (the compiler emits
`BallList(items)` as the raw vector, and reads still copy). The real fix is
reference-semantic containers: back `BallList`/`BallMap`/`BallObject` instances
with a shared map/vector (like the scope `BallScope = shared_ptr<BallMap>`) so
lookups share rather than copy. That single change would unblock sorts, OOP
field mutation, and the collection-algorithm family at once.

**2026-05-24 (parallel multi-track wave — final state):** Four tracks run
concurrently (file-disjoint: cpp/, ts/, dart/compiler, tests/conformance +
shared encoder/engine fixes), each verified independently:
- **C++ self-host: 109 → 138** (`test_conformance` native engine steady at 201/221).
  Adds: reference-semantic program lists (`40ccd74` — shared_ptr-backed BallDyn
  lists; maps stay by-value to avoid self-referential `self` cycles; unblocked
  sorts 132/133/134 + matrix 83/128/138); `_stdFunctionToOperator` emitted as a
  BallMap (`e3aa4ed` — operator-overload dispatch, landed 113); then a tail wave
  (`1691f44` lambda statement-form bodies + list_pop + string-repeat; `9175102`
  rethrow payload + real JSON codec + Map.keys; `3744c1e` double Infinity/NaN
  formatting) → +15.
- **TS self-host: 198 → 227/227 (100%)** — zero-wrapper regeneration unblocked
  (`BallMap`/`BallList`/`BallObject` preamble base classes), generators deferred
  to native, virtual-dispatch + map-merge fixes; then `a83ede6` RangeError-shaped
  bounds-checked index (199) and `ea5b4f3` int64/BigInt precision (192). The
  last failure `169_pattern_destructure` was a malformed fixture (non-canonical
  switch IR) — rewritten to canonical `switch_expr`, clearing TS to 227/227 and
  lifting C++ (135→136) and Dart conformance too.
- **Dart parity: 156 → 183/183** (all non-skipped pass; 6 host-knob skips).
  `_generateLocalFunction` honours lambda `has_return` (`176af37`, unblocked 15
  OOP fixtures); 113/204 fixed by regenerating the stale `engine_roundtrip.dart`
  artifact (`591ef02` — the Ball→Dart compiler source was already correct).
- **+10 Dart-validated conformance fixtures** (204–213) and shared-pipeline
  fixes: encoder `replaceAll`→`string_replace_all` (`633ae72`), engine
  `operator+` dispatch (`334fd54`), malformed-fixture repair (`54b2a30`).

**NEXT C++ LEVER — BLOCKED ON DEBUGGER (self-binding gate, ~+5: 164/165/166/177/179):**
The OOP virtual-dispatch crash was two bugs. The `bad_any_cast` is fixed
(`bb5b5f1` — unguarded `any_cast<bool>` on filter predicates; safe `_ball_pred_true`
+ recursive `_BallDynUnwrapper::unwrap`). The SECOND bug remains: in a method
dispatched as `obj.method(self: d)`, the method scope never makes `self` visible
to the body's `self` lookup. Instrumented tracing confirmed the input map DOES
carry `self`, the `_evalCall` gate (~4379) and `_callFunction` gate (~3752) both
pass, but after `bind(scope, "self"s, self)` (engine_rt.cpp ~3754) `lookup(self)`
returns empty while the inherited field-binds (which pass a `BallDyn` key) take
effect. Prime suspect: MSVC overload resolution between
`bind(BallDyn&, const std::any&, …)` and `bind(BallDyn&, const BallDyn&, …)` when
the key is a `std::string` literal — adding explicit string/`const char*`
overloads changed behavior but didn't fully fix it, so there's a second layer
(either `self = inputMap["self"]` reads empty, or a scope-mutation/eval-order
issue). Pinning it down needs a stepping debugger (cdb/VS) to watch the scope
object identity + the bind→set at 3754 vs the body eval — not available in the
agent environment. TS (227/227) and Dart (183/183) pass these, so the engine
logic is correct; this is purely a C++ self-host compilation/runtime issue.

**Earlier the same day (compiler correctness wave — 72 → 109/175):** Five systemic
compiler bugs fixed, each verified with a full rebuild + isolated-process tally
and zero regressions on `test_conformance` (still 194 pass):
- **FlowSignal arg0→kind (72 → 93):** `_FlowSignal('return', value: v)` compiled
  its positional `kind` arg to map key `"arg0"`, but the runtime
  (`ball_is_flow_signal` + every `.kind`/`.value` read) keys on the real param
  name. Every early `return` inside an `if`/loop lost its value. Fix: resolve
  positional ctor args to param names in the stub-type map path
  (`lookup_ctor_params`). Unblocked the recursion/early-return cluster.
- **try/finally (93 → 101):** Dart `try { return X } finally { cleanup }`
  compiled to `try { return X } catch(std::exception&){} cleanup;` — the return
  skipped the cleanup and the empty catch swallowed all exceptions. In the
  engine this leaked `_expressionDepth` (+1 per `_evalExpression`, never
  decremented) until it exceeded `maxExpressionDepth=1000` (~100 nested calls)
  → threw → swallowed → null. Fix: `make_ball_finally` RAII guard runs cleanup
  on every exit; no swallowing catch when there are no catch clauses. Unblocked
  deep recursion (fibonacci, collatz, sorts).
- **exception payload (101 → 105):** `throw BallException(typeName, value)`
  compiled to a hardcoded `BallException("Exception","Exception",{})` —
  payload discarded. Fix: BallException carries a `std::any value`;
  `_ball_make_exception` preserves it; `_ball_caught_to_dyn` rebuilds the
  `{__type__,typeName,value}` shape on catch so `e["value"]`/`e is BallException`
  work. Unblocked 21/24/53/91.
- **List.filled unwrap (105 → 108):** `List_filled::operator std::vector` checked
  `arg0.type()` directly, but the length is a BallDyn-in-`std::any` under MSVC, so
  the check missed it → `n=0` → empty list. Unwrap arg0/arg1 via
  `_BallDynUnwrapper`. Unblocked 187 + two fixtures that pre-fill arrays.
- **null_aware_call dispatch (108 → 109):** `x?.toInt()` encodes as
  `null_aware_call{target, method}`, but the handler read an absent `callback`
  field (→ `"BallDyn()"`) and invoked it as a functor → `BallDyn()(x)` → null,
  so `(x as num?)?.toInt() ?? 0` always yielded 0. Route `method` through
  `compile_method_call` (synthesizing self=target); `?.call()` is special-cased
  to functor invocation. Unblocked 188_std_time_now.

**Next lever (highest value):** reference-semantic containers (below) — would
unblock in-place mutation (sorts 132–134, OOP setters 104) and the
collection-algorithm family at once. rethrow (22) and typed nested catch (146)
are smaller follow-ups.

**Known remaining (priority order):**
1. **OOP feature long-tail** — beyond field read/write, each class feature has
   its own dispatch path that still needs work: getters/setters (104),
   static/factory methods (105/106), `super` calls + override (107), operator
   overloading (113), inheritance/virtual dispatch (114/164–166/177–179),
   generics (115/168/180–181), and the collection/algorithm tests (116–135).
   These now fail for per-feature reasons, not the (now-fixed) field-access core.
   Note: constructor-with-body instances are `BallObject`; the writeback handles
   them in C++ but a fuller reference-semantic instance model (shared
   `BallScope`-backed maps) would be more robust for aliasing/identity cases.
2. Crashers are all tests that cannot pass in self-host anyway: host-knob tests
   `196_timeout`/`197_memory_limit`/`201_input_validation`/`202_sandbox_mode`
   (need `timeoutMs`/`maxMemoryBytes`/`sandbox` constructor args that the IR
   can't express — run unbounded and crash), plus known non-terminating
   recursion `108_class_tostring`, `144_lcm_computation`, `84_exception_chain`,
   `95_fibonacci_memo` (memoization with BallDyn map keys), `136_string_pattern_match`.
   These should be skip-listed in the in-process harness (one crash there kills
   the whole suite — use the per-fixture `cpp/test/run_selfhost_tally.sh`).

---
Older measurement (stale May-5 backup, pre-latest-IR): **66 / 170 pass (38.8%)**. Most remaining failures land in three categories:

1. `BallException: Exception type=Exception` — symptomatic of the MSVC `BallDyn`-in-`std::any` wrapping bug from `CLAUDE.md`: MSVC stores `BallDyn` instances inside `std::any` instead of using `operator std::any()`, which breaks every test that catches a typed exception or stores a class instance in a heterogeneous container.
2. Three skipped tests for infinite loops in memoization with `BallDyn` map keys.
3. `engine_rt.cpp` regen against the latest `engine.ball.pb` (with the Wave 7 security additions) currently fails to compile: the new `_trackMemoryAllocation` overload set confuses MSVC's overload resolution AND `_ballStringCodeUnitBytes` / `_ballPointerBytes` static-const class fields are not being emitted as class members. The May 5 backup remains the live build artifact until both are resolved. Once it can regen, the throw-typename fix above should bring the self-host count up too.

### TypeScript self-host

**Goal:** zero-wrapper engine — `import { BallEngine } from './compiled_engine.ts'` should be enough, no hand-written shim.

**Current:** zero-wrapper **224 / 227 conformance pass (98.7%)** (regen unblocked via preamble BallMap/BallList/BallObject base classes) after `a970c5f` added a host-knob skip-list, std_time/convert wiring in the wrapper, an operator-name sanitiser in the compiler, and a DateTime polyfill in the preamble. The drop-the-wrapper push (commits `b4287e7` → `e165f8b`) broke the wrapper integration and was reverted in `2c67f94` to keep the suite green; the pure-harness file `ts/engine/test/harness_pure.mjs` is kept as groundwork for the next attempt.

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
| US-003 Drive Dart parity ≥ 90% | ✅ 181/189 round-trip parity |
| US-004 Regenerate compiled_engine.ts | partial — regen produces an engine the wrapper can load; the drop-the-wrapper push was reverted to keep 194/220 green |
| US-005 Drive TS conformance ≥ 90% | ✅ 224/227 zero-wrapper (was 198/216 wrappered) after skip-list + std_time/convert wiring + DateTime polyfill |
| US-006 Regenerate engine_rt.cpp | partial — `compile_engine_cpp.dart` emits a 9013-line `engine_rt.cpp` from the latest engine.ball.pb, but it doesn't build under MSVC because the Wave 7 `_trackMemoryAllocation` overload set confuses overload resolution. The May 5 backup is the live build artifact. |
| US-007 Drive C++ conformance ≥ 50% | ✅ 92.4% on `test_conformance` (cpp engine + cpp compiler, 194/210); `test_selfhost_conformance` (compiled engine_rt.cpp) still 66/170 pending engine_rt regen + MSVC `BallDyn`-in-`std::any` fix. |
| US-008 Add new conformance fixtures | partial — 1/5 added (`203_closure_in_loop`) plus a `typed_list` dispatch fix that was blocking it; remaining 4 (record-pattern destructure, async chain rethrow, recursive types, generator state restore) are drafted but blocked on unrelated engine gaps |
| US-009 Final self-host status doc | this file ✅ |
