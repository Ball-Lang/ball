# Ball Production Readiness — Decisions & Issues

## Architectural Decisions

### Metadata vs Schema Distinction
**Decision**: The free-form `metadata` map (google.protobuf.Struct) on TypeDefinition/FunctionDefinition is cosmetic. Named proto fields on TypeDefinition (type_params, kind, descriptor fields) ARE structural and may affect computation.

**Rationale**: Task 0.2 must determine whether superclass/interfaces[] are in the proto struct or in the metadata map, and resolve accordingly before any OOP implementation begins.

### Wave Sequencing
**Decision**: 10 gated waves with explicit pass criteria. Runtime correctness (Waves 1-3) must complete before any other work proceeds.

**Critical Path**: Wave 0 → Wave 1 → Wave 2 → Wave 3 → Wave 4 → Wave 5 → Wave 6 → Wave 7 → Wave 8 → Wave 9 → Wave 10 → FINAL

### TDD Approach
**Decision**: All behavior changes must be preceded by failing tests. Conformance fixtures preferred over per-language unit tests.

## Issues & Blockers

### Current Blockers
- None (Wave 0 can start immediately)

### Potential Blockers (Watch)
- **Task 0.2 outcome**: If any runtime gap requires proto schema changes, all downstream waves are blocked until resolved
- **Async implementation**: Current async/await are no-ops in engines — must implement BallFuture simulation
- **OOP inheritance**: superclass/interfaces[] location in schema affects all OOP work

## Wave 0 Status

| Task | Status | Blocked By | Blocks |
|------|--------|------------|--------|
| 0.1 Documentation | ⏳ PENDING | None | None |
| 0.2 Schema Validation | ⏳ PENDING | None | Waves 1-10 |
| 0.3 Conformance Audit | ⏳ PENDING | None | Wave 6 |
| 0.4 Failing Tests | ⏳ PENDING | None | Wave 1.1-1.4 |

## Parallelization Notes

All Wave 0 tasks can run in parallel — they have no dependencies on each other.

However:
- Task 0.1 should ideally complete before Task 0.2 starts (to have authoritative docs)
- Task 0.4 should reference Task 0.2 findings for correct expected behavior

## Evidence Collection

All QA evidence goes to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`

Pattern:
- Shell output: `.txt`
- Screenshots: `.png`
- JSON results: `.json`

## Task 0.2: Schema Extension Analysis (2026-05-06)

### Decision: No proto schema changes required for any runtime gap

All five runtime gaps (async, OOP, generics, patterns, generators) are classified as **(A) BASE FUNCTIONS ONLY** — implementable with existing schema fields + new base functions + engine implementation.

### Key Findings

1. **superclass/interfaces[] are in metadata, not structural fields**: TypeDefinition.metadata (google.protobuf.Struct) contains superclass (string) and interfaces (string array). These are "cosmetic" per the design invariant but the engine reads them at runtime for OOP dispatch. This is a design tension but not a blocker.

2. **type_params has split existence**: TypeDefinition.type_params is a structural field (repeated TypeParameter), while FunctionDefinition.type_params is a metadata key (string array). This is consistent — type-level generics affect type structure, function-level generics are cosmetic.

3. **No pattern_expr expression variant exists**: Patterns are encoded as MessageCreation expressions with __pattern_kind__ discriminator convention. The 7 existing expression types are sufficient.

4. **Async/generator identification is in metadata**: is_async, is_sync_star, is_async_star are FunctionDefinition.metadata keys. The engine already reads them.

5. **All gaps can be implemented without proto changes**: The existing schema's structural fields, metadata keys, and base function mechanism are sufficient for all five gaps.

### Design Tension Noted

Metadata is "cosmetic" for compilation but the engine reads it for runtime behavior (is_async, superclass, interfaces). This tension is acceptable — metadata affects how code *looks* when compiled, and the engine uses it for *how code runs*. Both are valid uses of the same data.

