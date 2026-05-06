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
