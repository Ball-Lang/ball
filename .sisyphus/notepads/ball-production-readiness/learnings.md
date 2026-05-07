# Ball Production Readiness — Learnings & Conventions

## Project Conventions

### File Organization
- **Proto schema**: `proto/ball/v1/ball.proto` — single source of truth
- **Generated files**: NEVER edit `dart/shared/lib/gen/`, `cpp/shared/gen/`, `std.json`, `std.bin`
- **Dart engine**: `dart/engine/lib/engine.dart` — reference implementation
- **C++ engine**: `cpp/engine/src/engine.cpp`, `cpp/shared/include/ball_shared.h`
- **TS engine**: `ts/engine/src/index.ts`, `ts/engine/src/index.handwritten.ts`
- **Conformance**: `tests/conformance/` — 155+ fixtures with runners

### Key Invariants (NEVER Violate)
1. **One input, one output per function** — like gRPC. No multi-parameter functions.
2. **Metadata is cosmetic** — stripping all metadata must not change what a program computes.
3. **Base functions have no body** — their implementation is per-platform.
4. **Control flow is function calls** — if/for/while are std functions with lazy evaluation.

### Build Commands
```bash
# Dart
cd dart && dart pub get
cd dart/engine && dart test
cd dart/encoder && dart test

# C++
cd cpp/build && cmake .. && cmake --build . && ctest --output-on-failure

# TypeScript
cd ts/engine && npm install && npm test

# Proto
buf lint && buf generate
```

### Test Strategy
- **TDD**: RED (failing test) → GREEN (minimal impl) → REFACTOR
- **Conformance tests preferred**: One fixture validates ALL engines simultaneously
- **Per-language tests**: Only for engine-internal behavior not expressible as Ball program

### Critical Known Issues
- C++ `string_split`/`string_replace`/`string_replace_all` emit empty comments (BROKEN)
- C++ `std_collections` and `std_io` modules are stubs (declared, not implemented)
- Dart encoder silently swallows malformed metadata

### Documentation State
- **IMPLEMENTATION_PLAN.md** (root): Authoritative roadmap
- **docs/ROADMAP.md**: Stale duplicate — to be consolidated into IMPLEMENTATION_PLAN.md
- **docs/GAP_ANALYSIS.md**: 880-line gap analysis vs C++17/Dart 3.x
- **docs/STD_COMPLETENESS.md**: Per-function completeness tracker
- **docs/METADATA_SPEC.md**: Metadata conventions

## Wave 0 Specific Notes

### Task 0.1: Documentation Consolidation
- Must merge docs/ROADMAP.md into IMPLEMENTATION_PLAN.md
- Must delete docs/ROADMAP.md or replace with redirect
- Must update docs/IMPLEMENTATION_STATUS.md with current state
- Do NOT modify GAP_ANALYSIS.md

### Task 0.1: Documentation Consolidation (COMPLETED May 6, 2026)
- IMPLEMENTATION_PLAN.md (root) is authoritative — docs/ROADMAP.md was identical duplicate
- No unique content to merge from docs/ROADMAP.md — files were in sync
- docs/ROADMAP.md replaced with redirect stub (not deleted, preserves links)
- docs/IMPLEMENTATION_STATUS.md updated with May 6, 2026 date + note pointing to IMPLEMENTATION_PLAN.md
- docs/STD_COMPLETENESS.md: dart_std module was outdated — 8 functions marked ❌/⚠️ that are actually implemented
- Updated dart_std from 14/18 to 18/18 (tear_off, dart_await_for, dart_stream_yield, dart_list_generate, dart_list_filled, null_aware_cascade)
- Summary totals corrected accordingly
- Evidence saved to: .sisyphus/evidence/task-0.1-consolidation.txt, task-0.1-status-date.txt

### Task 0.2: Schema Validation
- Must analyze proto/ball/v1/ball.proto
- Must determine if async/OOP/generics/patterns need schema changes
- Key question: Are superclass/interfaces[] in proto struct or metadata?
- Key question: Is there a pattern_expr field or must patterns use existing expressions?
- Document findings in docs/SCHEMA_EXTENSION_ANALYSIS.md
- If proto changes needed: FLAG as blocking, plan pauses

### Task 0.3: Conformance Audit
- Run: `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance`
- Record all failures/missing tests in docs/CONFORMANCE_GAPS.md
- Cross-reference with docs/STD_COMPLETENESS.md
- Do NOT fix failures — audit only

### Task 0.4: Failing Test Skeleton
- Create 11 fixtures: 160-170 range
- ALL must FAIL on current engines (RED phase)
- Each fixture tests ONE concept (no multi-concept)
- Naming: `160_async_basic.ball.json`, etc.
- Must include `.expected_output.txt` for each

### Task 1.2: BallGenerator + Yield Execution (COMPLETED May 6, 2026)

**Key finding**: The implementation was ALREADY COMPLETE in the codebase. The BallGenerator, BallFuture,
yield/yield_each, and sync*/async* function handling were all implemented before this task started.

**What was already implemented**:
- `BallGenerator` class in `engine_types.dart` (lines 94-109): has `values` list, `yield_()`, `yieldAll()`, `completed` flag
- `BallFuture` class in `engine_types.dart` (lines 77-88): wraps async results
- `_evalYield()` in `engine_control_flow.dart` (lines 1178-1202): walks scope chain to find `__generator__`, adds value
- `_evalYieldEach()` in `engine_control_flow.dart` (lines 1209-1242): delegates to generator or flattens iterable
- `_callFunction()` in `engine_invocation.dart` (lines 118-152): detects `is_sync_star`/`is_async_star`/`is_generator` metadata, creates BallGenerator, binds `__generator__` in scope, returns list (sync*) or BallFuture(list) (async*)

**What I changed**:
- Removed debug `stderr()` statements from `engine_invocation.dart` (lines 48-51, 60-62, 65-67) that were polluting test 160_async_basic output

**How generators work**:
1. `sync*` function: `_callFunction` detects `is_sync_star` metadata → creates `BallGenerator` → binds as `__generator__` in scope → evaluates body → `std.yield` calls `_evalYield` which walks scope to find `__generator__` and adds value → returns `generator.values` as plain list
2. `async*` function: Same as sync* but wraps result in `BallFuture(generator.values)` → `std.await` or `_unwrapFuture` unwraps
3. `yield_each` / `dart_std.yield_each`: `_evalYieldEach` flattens iterable into generator's values list

**Pre-existing failures (NOT related to this task)**:
- Test 160_async_basic: print receives raw map instead of extracting message field
- Tests 164, 166, 167, 168, 169: OOP/generics/pattern features not yet implemented
- Engine unit tests: BallDouble type cast issues, async BallFuture test, stack overflow on `is` type check

### Task 1.5: Async Conformance Fixtures 171-173 (COMPLETED May 6, 2026)

**Created 3 new async conformance fixtures**:
1. `171_async_error_propagation.ball.json` - Tests error propagation in async functions using std.try/std.throw
2. `172_async_nested_await.ball.json` - Tests nested async calls (async calling async)
3. `173_async_multiple_futures.ball.json` - Tests multiple concurrent async operations

**Pattern learned**:
- Async functions use `is_async: true` in metadata
- Error handling via `std.try` with `catches` list containing type + variable + body blocks
- Throw via `std.throw` with `value` field containing a message with `__type` field
- Multiple async calls can be stored in variables and combined

**All 3 fixtures PASS on Dart engine** (verified via `dart test test/conformance_test.dart -n "<name>"`)

### Task 1.6: Generator Conformance Fixtures 174-176 (COMPLETED May 6, 2026)

**Created 3 new generator conformance fixtures**:
1. 174_generator_yield_star.ball.json - Tests yield* (yield_each) with nested generators
2. 175_generator_empty_return.ball.json - Tests that empty generators return list with length 0
3. 176_generator_early_return.ball.json - Tests early return inside generator stops further yielding

**Pattern learned**:
- sync* functions use is_sync_star: true in metadata
- std.yield adds values to the current generator's values list
- dart_std.yield_each / std.yield_each delegates to another generator or flattens iterable
- Generator body executes normally; return inside generator just ends the iteration
- Empty generator (no yield statements) produces list with length 0

**All 3 fixtures PASS on Dart engine** (verified via dart test test/conformance_test.dart -n "<name>")

## 2026-05-06 — Task 1.8 Wave 1 gate verification
- Dart engine passed targeted async/generator fixtures 160-163 and 171-176 via `dart test --name ...` from `dart/engine`.
- `ts/engine` test runner does not implement the requested `--grep`; both npm and direct node invocations ran the full suite. A targeted inline Node verifier against `BallEngine` passed all 10 Wave 1 handwritten fixtures.
- Compiled TS engine parity (`ts/compiler/test/engine_runtime.test.ts`) failed 9/10 targeted fixtures, mostly returning `BallFuture(...)` values or generator runtime errors; only 171 passed.
- C++ build configuration passed, but full build fails in protobuf `libupb` with MSVC C1041 PDB conflicts even with `/m:1`; produced runner executables were usable for targeted testing.
- C++ runner failed 5/10 targeted fixtures: 160, 162, 163, 175, 176. Gate remains failed and plan was not marked complete.

## 2026-05-06 — Task 3.1 Reified Generics Implementation
- Fixed `_typeMatches` function in `dart/engine/lib/engine_std.dart` to handle `__type_args__` stored as string (e.g., "<int>") in addition to List format.
- The fixtures 167 and 168 store `__type_args__` as a string with angle brackets, but the engine expected a List.
- Solution: Parse string format by stripping angle brackets and splitting by comma.
- Fixtures 167 and 168 now PASS on Dart engine.
- Dart engine status: 191 passing, 1 failing (fixture 169 has malformed protobuf structure).

### Key Code Pattern for Generic Type Checking
```dart
// Handle __type_args__ as a string (e.g., "<int>") or as a List (e.g., ["int"])
List<String> objTypeArgs = [];
if (objArgs is String) {
  final argsStr = objArgs.trim();
  if (argsStr.startsWith('<') && argsStr.endsWith('>')) {
    objTypeArgs = argsStr.substring(1, argsStr.length - 1).split(',').map((s) => s.trim()).toList();
  } else {
    objTypeArgs = [argsStr];
  }
} else if (objArgs is List) {
  objTypeArgs = objArgs.map((e) => e.toString()).toList();
}
```

## Task 3.6 - switch_expr pattern semantics (2026-05-06)
- `std.switch_expr` must be lazy like `std.switch`; otherwise all case bodies are evaluated while building the base-function input, before pattern selection.
- Encoder structured patterns arrive at runtime as message maps with `__type__` values such as `ConstPattern`, `VarPattern`, `ListPattern`, and `RestPattern`, not just legacy `__pattern_kind__` maps.
- Evaluated pattern fields may be `BallList`/`BallMap`; normalize through `_stdAsList`/`_stdAsMap` before matching.
- Pattern variable bindings should be installed in a child case scope before evaluating guards and bodies.

## 2026-05-06 - Dart dart_std list helpers
- Dart engine std dispatch is function-name based across std/dart_std/std_collections; adding a public dart_std function usually means adding a dispatch key in engine_std.dart, not a separate module table.
- Existing List.generate static dispatch used internal dart_list_generate with count/generator; new conformance fixtures use dart_std.list_generate with length/generator, so helper implementations should accept both shapes.

## 2026-05-06 - Task 6.1 conformance coverage audit
- Conformance fixtures: 171 total across `tests/conformance/*.ball.json`.
- Base functions in the requested std modules: 187 total (`std` 118, `std_collections` 53, `std_io` 10, `std_convert` 6).
- Covered function counts by module: `std` 67, `std_collections` 12, `std_io` 1, `std_convert` 6.
- `std_convert` is fully covered; the largest gaps are in `std` math/regex/string helpers and `std_collections` list/map/set helpers.

## 2026-05-06 - Task 7.1 Dart recursion depth limit
- Dart engine recursion should be tracked around non-base Ball function execution in `_callFunction`; base functions have no body and should not consume recursion depth.
- Lazy control-flow branches and expression statements need explicit `await` when returning nested evaluation futures; otherwise active call-depth tracking can unwind too early.
- Targeted engine tests can use a small configured `maxRecursionDepth` to exercise the guard deterministically while fixture 59 verifies default-depth recursion still works.

- Task 7.2: Dart engine timeout enforcement belongs in _evalExpression, which covers normal expression evaluation plus lazy control-flow loop condition/body checks.
- Task 7.2: Error-case conformance fixtures can be handled in dart/engine/test/conformance_test.dart before expected-output file filtering.

## Task 7.3 - Memory allocation cap
- Dart engine already had BallEngine.maxMemoryBytes and _trackMemoryAllocation; completing the task meant wiring more allocation sites rather than adding a duplicate option.
- Approximate accounting uses 8 bytes per list slot, 16 bytes per map entry, and 2 bytes per string code unit. list_filled/list literals/map/string operations now fail with BallRuntimeError('Memory limit exceeded') before returning oversized values.
- Special conformance fixtures that expect runtime errors are handled in dart/engine/test/conformance_test.dart like 196_timeout; 197_memory_limit uses maxMemoryBytes: 1000 and expects the memory-limit error.


## Task 7.4 input validation - 2026-05-07
- Dart engine constructor now enforces module count and program JSON-size limits before lookup-table initialization.
- Expression depth is guarded twice: iterative static preflight prevents abusive static programs from creating deep async chains, while runtime _evalExpression tracking protects evaluation paths.
- maxProgramSizeBytes: null disables program-size enforcement for targeted depth validation, matching the nullable style of timeout/memory limits.
