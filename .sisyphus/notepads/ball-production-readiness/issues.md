
## 2026-05-06 — Task 1.8 unresolved gate blockers
- Compiled TS engine fails Wave 1 async/generator parity: 160, 161, 162, 163, 172, 173, 174, 175, 176 fail under `node --experimental-strip-types --test --test-name-pattern ... test/engine_runtime.test.ts`.
- C++ engine runner fails Wave 1 fixtures 160, 162, 163, 175, 176.
- C++ full build fails on Windows in fetched protobuf `libupb` with `error C1041: cannot open program database ... libupbd.pdb`; retrying `cmake --build . -- /m:1` did not clear it.
- `ts/engine` npm test command's `--grep` argument is unsupported/ignored by `test/engine_test.ts`, causing unrelated full-suite failures unless a separate targeted runner is used.

## 2026-05-06 — Wave 2 Implementation Blockers
- **Task 2.2 (C++ OOP)**: Multiple subagent timeouts (>30min each). Implementation complexity high. Needs manual implementation approach.
- **Task 2.3 (TS OOP)**: Multiple subagent timeouts (>30min each). Error: "Function 'main.speak' not found" - method dispatch on objects not working.
- **Task 2.5 (Constructor Chains)**: Not started due to dependency on 2.2 and 2.3.
- **Task 2.6 (Wave 2 Gate)**: Blocked - cannot pass until C++ and TS engines implement OOP.

### Root Cause Analysis
TS engine issues:
1. Method calls on objects don't resolve (error: "Function not found")
2. No BallObject pattern implementation
3. No virtual dispatch mechanism

C++ engine issues:
1. Windows build failures (protobuf PDB conflicts)
2. No BallObject struct defined
3. No inheritance chain walking for fields/methods

## Task 3.6 - verification notes (2026-05-06)
- Full `dart test` from `dart/engine` remains blocked by unrelated existing failures: BallDouble casts in math_floor/math_ceil/math_round, invalid JSON in 169_pattern_destructure, and a later stack overflow in broad type-check tests.
- `dart analyze` reports existing warnings unrelated to switch_expr: duplicate BallGenerator check in yield_each and unused `_isBallFutureError`.

## Additional Blockers (2026-05-06 continued)
- **Task 2.3 continued**: Another subagent timeout (>30min) for TS Engine OOP implementation
- **C++ Build**: Still blocked by protobuf dependency issues on Windows
- **Recommendation**: Switch to WSL/Linux for C++ development or fix Windows protobuf configuration

## Current Priority Stack
1. **URGENT**: Fix C++ build environment (Windows protobuf issues)
2. **HIGH**: Complete TS Engine OOP (Task 2.3) - requires focused implementation
3. **MEDIUM**: Repair fixture 169 protobuf structure
4. **LOWER**: Continue with Wave 5+ tasks (std library modules)

## 2026-05-06 — Task 7.1 verification note
- Attempting to assert the default 10000-depth guard with a 10001-step async recursive countdown hit the Dart VM/test harness stack while propagating the error. The final unit test uses `maxRecursionDepth: 5` for the guard behavior, and `59_deep_recursion` confirms default depth still permits the existing deep-recursion fixture.

## Task 7.4 verification notes - 2026-05-07
- dart analyze still reports two pre-existing warnings in untouched files: ngine_control_flow.dart:1376 unnecessary type check and ngine_types.dart:155 unused _isBallFutureError.
- A 1001-level JSON-built test fixture overflows protobuf JSON parsing before engine validation; direct protobuf construction plus static preflight avoids testing the parser instead of the engine.
