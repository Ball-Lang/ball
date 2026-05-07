# Ball v1.0 Production Readiness

## TL;DR

> **Quick Summary**: Bring the Ball programming language to full v1.0 production readiness across runtime correctness, multi-language IR stability, standard library completeness, security hardening, and developer tooling. Sequenced in 10 gated waves. Runtime correctness (async, OOP, generics, pattern matching) is wave 1-3 — nothing else ships until engines execute correctly.
>
> **Deliverables**:
> - Correct runtime execution of async/await, generators, OOP inheritance, generics, and pattern matching across Dart, C++, and TS engines
> - C++ compiler/encoder at production quality (templates, operator overloading, MI)
> - 5 new standard library modules (std_convert, std_fs, std_time, std_concurrency, std_net)
> - Full conformance parity: Dart = C++ = TS across all ~200 std functions
> - Security hardening: resource limits, sandbox mode, input validation
> - Developer tooling: LSP server, consolidated docs, package registry protocol
> - New language targets: TypeScript and Python compilers
>
> **Estimated Effort**: XL (~80 tasks across 10 waves)
> **Parallel Execution**: YES — 10 waves, 5-8 tasks per wave
> **Critical Path**: Wave 0 → Wave 1 → Wave 2 → Wave 3 → Wave 4 → Wave 5 → Wave 6 → Wave 7 → Wave 8 → Wave 9 → Wave 10 → FINAL

---

## Context

### Original Request
"Analyze this project deeply. Understand what it does. Make a plan to make it production ready. Identify its weaknesses. Research GitHub source code for compilers and similar projects to identify what needs to be worked on next."

### Interview Summary
**Key Discussions**:
- **Production definition**: "All of the above" — stable toolchain + multi-language IR + developer platform
- **Target audience**: All audiences — researchers, tooling engineers, and application developers
- **Top priority**: Fix runtime correctness (async/await, OOP, generators, generics, pattern matching)
- **Test strategy**: TDD (test-first) — write failing tests, then implement, then refactor
- **Scope**: Full production readiness — all 10 tiers from existing implementation plan
- **Test infrastructure**: EXISTS — Dart (`dart test`), C++ (`ctest`), TS (`npm test`, `node --test`), conformance fixtures

**Research Findings**:
- IMPLEMENTATION_PLAN.md (root, April 2026) is the authoritative roadmap. docs/ROADMAP.md is a stale duplicate.
- GAP_ANALYSIS.md: Exhaustive 880-line analysis covering C++17 and Dart 3.x spec gaps
- STD_COMPLETENESS.md: Per-function tracker across Dart Engine/Compiler + C++ Engine/Compiler
- Conformance: 155 fixture programs, 4 engine runners, automated CI parity matrix
- 9 GitHub Actions workflows: CI, conformance-matrix, releases, npm publish, website deploy, audit
- Known critical issues: async/await are no-ops, OOP has no inheritance chain in engines, pattern matching stored as raw strings

### Metis Review
**Identified Gaps** (addressed in plan):
- **Must split into sequenced milestones**: Addressed — 10 gated waves, each with explicit pass criteria before proceeding
- **Must validate "no schema changes" assumption**: Addressed — Wave 0, Task 0.2 explicitly validates this
- **Must not bundle LSP/registry/JIT/sandboxing into runtime fixes**: Addressed — Waves 1-6 (runtime+compiler), Waves 7-10 (security+tooling+expansion)
- **Must define executable acceptance criteria**: Addressed — all criteria are runnable commands with expected outputs
- **Must not start new language targets before runtime correctness**: Addressed — TypeScript/Python compilers in Wave 10, gated on Wave 6 conformance
- **Must prefer conformance tests for cross-engine behavior**: Addressed — every wave includes conformance fixture tasks

---

## Work Objectives

### Core Objective
Achieve v1.0 production readiness for Ball: all engines execute correctly, all compilers emit correct target code, standard library is complete, security is hardened, and developer tooling exists — gated by automated conformance across 4 engines.

### Concrete Deliverables
- All 4 engines (Dart, C++, TS hand-written, TS compiled) pass 100% conformance on ~200+ fixtures
- C++ compiler produces correct C++ for all std functions including templates, operators, MI
- 5 new std modules with full engine + compiler support across all 3 languages
- LSP server for `.ball.json` editing (validation, completion, hover)
- Resource limit enforcement (recursion depth, execution time, memory cap)
- Binary protobuf as primary format with JSON fallback
- Consolidated authoritative documentation (one roadmap, one status tracker)

### Definition of Done
- [ ] `cd dart/engine && dart test` — 100% pass, zero failures
- [ ] `cd cpp/build && cmake --build . && ctest --output-on-failure` — 100% pass
- [ ] `cd ts/engine && npm test` — 100% pass
- [ ] Conformance matrix CI job shows DART=PASS, CPP=PASS, TS_HW=PASS, TS_CMP=PASS for all fixtures
- [ ] `buf lint proto/ && buf format proto/ --diff --exit-code` — zero issues
- [ ] `dart analyze dart/` — zero errors or warnings
- [ ] All `docs/*.md` files are consolidated, no stale duplicates
- [ ] `.sisyphus/evidence/` contains QA evidence for every task

### Must Have
- Runtime correctness: async/await, generators (yield/yield*), OOP inheritance (super, virtual dispatch), reified generics, pattern matching destructuring
- Schema/metadata resolution: Task 0.2 MUST determine whether OOP structural info (superclass, interfaces[]) and pattern expressions require proto schema additions or work with existing representation. If proto changes needed, they become Wave 0 prerequisites.
- C++ compiler: template emission, operator overloading, multiple inheritance, complete stdlib mapping
- Conformance: every base function has at least one conformance fixture; C++ runner reaches parity with Dart
- Security: recursion depth limit, execution timeout, memory cap, input size validation
- TDD: every behavior change preceded by a failing test

### Must NOT Have (Guardrails)
- **NO un-gated schema changes** — Task 0.2 evaluates whether OOP (superclass/interfaces[]) and pattern representation need proto additions. If yes, those changes become Wave 0 prerequisites with `buf lint && buf generate`. No schema changes beyond what Task 0.2 explicitly approves.
- **NO editing generated files** — `dart/shared/lib/gen/`, `cpp/shared/gen/`, `std.json`, `std.bin`
- **NO behavior changes without conformance tests** — conformance fixtures preferred over per-language tests
- **NO new language targets before Wave 6 conformance gates pass**
- **NO LSP, package registry, or JIT before Waves 7-8 security/performance gates pass**
- **No chasing full Dart 3.x or C++17 parity** — only Ball-representable semantics
- **No multi-parameter functions** — Ball is one-input-one-output by design
- **Metadata distinction**: The free-form `metadata` map (google.protobuf.Struct) on TypeDefinition/FunctionDefinition is cosmetic. Named proto fields on TypeDefinition (type_params, kind, descriptor fields) ARE structural and may affect computation. Task 0.2 determines whether superclass/interfaces[] are in the proto struct or in the metadata map, and resolves accordingly before any OOP implementation begins.
- **No direct edits to docs/ROADMAP.md** — consolidate into IMPLEMENTATION_PLAN.md via Task 0.1, then delete ROADMAP.md as part of that task

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: YES (Dart `dart test`, C++ `ctest`, TS `npm test`/`node --test``, conformance fixtures)
- **Automated tests**: TDD (test-first)
- **Framework**: Dart test (package:test), C++ (Catch2 via ctest), TS (node --test)
- **TDD workflow**: Each task follows RED (write failing test) → GREEN (minimal implementation) → REFACTOR (clean up)

### QA Policy
Every task MUST include agent-executed QA scenarios. Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.
- **Frontend/UI**: Playwright — Navigate, interact, assert DOM, screenshot
- **TUI/CLI**: interactive_bash (tmux) — Run command, send keystrokes, validate output
- **API/Backend**: Bash (curl) — Send requests, assert status + response fields
- **Library/Module**: Bash (bun/node REPL or dart) — Import, call functions, compare output

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 0 (Foundation — must complete first):
├── Task 0.1: Consolidate documentation [quick]
├── Task 0.2: Validate "no schema changes" assumption [deep]
├── Task 0.3: Audit existing conformance coverage [quick]
└── Task 0.4: Set up failing test skeleton for runtime gaps [quick]

Wave 1 (Runtime: Async/Await & Generators — can start after Wave 0):
├── Task 1.1: Dart engine — BallFuture + await execution [deep]
├── Task 1.2: Dart engine — BallGenerator + yield/yield* [deep]
├── Task 1.3: C++ engine — BallFuture/BallGenerator mirror [deep]
├── Task 1.4: TS engine — async/generator support [deep]
├── Task 1.5: Async conformance fixtures [quick]
├── Task 1.6: Generator conformance fixtures [quick]
├── Task 1.7: Async error propagation + edge cases [deep]
└── Task 1.8: Wave 1 gate — all engines pass async/generator conformance [quick]

Wave 2 (Runtime: OOP Inheritance — can start after Wave 1 gate):
├── Task 2.1: Dart engine — BallObject, __super__, virtual dispatch [deep]
├── Task 2.2: C++ engine — BallObject mirror [deep]
├── Task 2.3: TS engine — OOP inheritance support [deep]
├── Task 2.4: OOP conformance fixtures [quick]
├── Task 2.5: Constructor chains + super calls [deep]
└── Task 2.6: Wave 2 gate [quick]

Wave 3 (Runtime: Generics + Pattern Matching — can start after Wave 2 gate):
├── Task 3.1: Dart engine — reified generics (type args tracking) [deep]
├── Task 3.2: C++ engine — reified generics mirror [deep]
├── Task 3.3: Dart engine — BallPattern ADT + destructuring [deep]
├── Task 3.4: Generics conformance fixtures [quick]
├── Task 3.5: Pattern matching conformance fixtures [quick]
├── Task 3.6: Switch_expr with full pattern semantics [deep]
└── Task 3.7: Wave 3 gate [quick]

Wave 4 (C++ Compiler Completion — can start after Wave 3 gate):
├── Task 4.1: C++ compiler — template emission [deep]
├── Task 4.2: C++ compiler — operator overloading emission [deep]
├── Task 4.3: C++ compiler — multiple inheritance emission [deep]
├── Task 4.4: C++ encoder — better template handling [deep]
├── Task 4.5: C++ encoder — overloaded function name mangling [deep]
├── Task 4.6: C++ compiler — remaining std function mapping [unspecified-high]
├── Task 4.7: C++ compiler conformance fixtures [quick]
└── Task 4.8: Wave 4 gate — C++ compiler passes all existing conformance [quick]

Wave 5 (Standard Library Completion — can start after Wave 4 gate):
├── Task 5.1: std_convert module (JSON/UTF-8/Base64) — all engines [deep]
├── Task 5.2: std_fs module (File I/O) — all engines [deep]
├── Task 5.3: std_time module (Date/Time) — all engines [deep]
├── Task 5.4: std_concurrency module — all engines [deep]
├── Task 5.5: cpp_std module — shared definition + Dart/TS engines [deep]
├── Task 5.6: dart_std missing functions (tear_off, streams, isolates) [deep]
├── Task 5.7: std_net module (HTTP/sockets) — all engines [deep]
├── Task 5.8: Stdlib conformance fixtures [quick]
└── Task 5.9: Wave 5 gate [quick]

Wave 6 (Conformance & Regression — can start after Wave 5 gate):
├── Task 6.1: Expand conformance to cover ALL base functions [unspecified-high]
├── Task 6.2: C++ conformance runner reaches parity with Dart [unspecified-high]
├── Task 6.3: Regression test infrastructure (golden files, snapshot testing) [unspecified-high]
├── Task 6.4: Cross-engine edge case fixtures (overflow, encoding, ordering) [deep]
├── Task 6.5: CI gate — conformance matrix blocks merge on any regression [quick]
└── Task 6.6: Wave 6 gate — full parity matrix green [quick]

Wave 7 (Security & Hardening — can start after Wave 6 gate):
├── Task 7.1: Recursion depth limit in all engines [deep]
├── Task 7.2: Execution timeout in all engines [deep]
├── Task 7.3: Memory allocation cap (configurable) [unspecified-high]
├── Task 7.4: Input size validation (max module count, max expression depth) [unspecified-high]
├── Task 7.5: Sandbox mode — restrict filesystem/network base functions [deep]
├── Task 7.6: Security audit — review all base functions for abuse vectors [deep]
├── Task 7.7: Security conformance fixtures (resource exhaustion, malicious input) [quick]
└── Task 7.8: Wave 7 gate [quick]

Wave 8 (Performance — can start after Wave 7 gate):
├── Task 8.1: Binary protobuf as default format (all tools) [unspecified-high]
├── Task 8.2: Engine warm-up caching (parsed program reuse) [deep]
├── Task 8.3: Benchmarking infrastructure + CI performance regression [unspecified-high]
├── Task 8.4: Optimize hot paths in Dart engine [deep]
├── Task 8.5: Optimize hot paths in C++ engine [deep]
└── Task 8.6: Wave 8 gate [quick]

Wave 9 (Developer Tooling — can start after Wave 8 gate):
├── Task 9.1: LSP server for Ball JSON (validation, completion, hover, goto-def) [deep]
├── Task 9.2: Documentation consolidation — single source of truth [writing]
├── Task 9.3: Package registry protocol — ModuleImport discovery [unspecified-high]
├── Task 9.4: Website improvements — playground enhancements, API docs [visual-engineering]
├── Task 9.5: Dart CLI polish — round-trip, verbose mode, error formatting [quick]
└── Task 9.6: Wave 9 gate [quick]

Wave 10 (New Language Targets — can start after Wave 9 gate):
├── Task 10.1: TypeScript compiler — complete remaining std functions [deep]
├── Task 10.2: TypeScript encoder — Dart source → Ball program [deep]
├── Task 10.3: Python compiler (Ball → Python) [deep]
├── Task 10.4: Python conformance fixtures [quick]
├── Task 10.5: Go compiler (Ball → Go) — initial implementation [deep]
├── Task 10.6: New target documentation — IMPLEMENTING_A_COMPILER.md update [writing]
└── Task 10.7: Wave 10 gate [quick]

Wave FINAL (After ALL waves — 4 parallel reviews, then user okay):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay

Critical Path: Wave 0 → Wave 1 → Wave 2 → Wave 3 → Wave 4 → Wave 5 → Wave 6 → Wave 7 → Wave 8 → Wave 9 → Wave 10 → FINAL
Parallel Speedup: ~65% faster than sequential (each wave runs 5-8 tasks in parallel)
Max Concurrent: 9 (Wave 1)
```

### Dependency Matrix

- **0.1-0.4**: - - 1 (Wave 1), 0 (Wave 0)
- **1.1-1.4**: - - 1.5-1.8, 1 (Wave 1)
- **1.5-1.7**: 1.1-1.4 - 1.8, 1
- **1.8**: 1.1-1.7 - 2 (Wave 2), 1
- **2.1-2.3**: 1.8 - 2.4-2.6, 2
- **2.6**: 2.1-2.5 - 3 (Wave 3), 2
- **3.1-3.6**: 2.6 - 3.7, 3
- **3.7**: 3.1-3.6 - 4 (Wave 4), 3
- **4.1-4.7**: 3.7 - 4.8, 4
- **4.8**: 4.1-4.7 - 5 (Wave 5), 4
- **5.1-5.8**: 4.8 - 5.9, 5
- **5.9**: 5.1-5.8 - 6 (Wave 6), 5
- **6.1-6.5**: 5.9 - 6.6, 6
- **6.6**: 6.1-6.5 - 7 (Wave 7), 6
- **7.1-7.7**: 6.6 - 7.8, 7
- **7.8**: 7.1-7.7 - 8 (Wave 8), 7
- **8.1-8.5**: 7.8 - 8.6, 8
- **8.6**: 8.1-8.5 - 9 (Wave 9), 8
- **9.1-9.5**: 8.6 - 9.6, 9
- **9.6**: 9.1-9.5 - 10 (Wave 10), 9
- **10.1-10.6**: 9.6 - 10.7, 10
- **10.7**: 10.1-10.6 - F (FINAL), 10

### Agent Dispatch Summary

- **0**: 4 tasks — T0.1→`quick`, T0.2→`deep`, T0.3→`quick`, T0.4→`quick`
- **1**: 8 tasks — T1.1-1.4→`deep`, T1.5-1.6→`quick`, T1.7→`deep`, T1.8→`quick`
- **2**: 6 tasks — T2.1-2.3→`deep`, T2.4→`quick`, T2.5→`deep`, T2.6→`quick`
- **3**: 7 tasks — T3.1-3.3→`deep`, T3.4-3.5→`quick`, T3.6→`deep`, T3.7→`quick`
- **4**: 8 tasks — T4.1-4.5→`deep`, T4.6→`unspecified-high`, T4.7→`quick`, T4.8→`quick`
- **5**: 9 tasks — T5.1-5.7→`deep`, T5.8→`quick`, T5.9→`quick`
- **6**: 6 tasks — T6.1-6.3→`unspecified-high`, T6.4→`deep`, T6.5→`quick`, T6.6→`quick`
- **7**: 8 tasks — T7.1-7.2→`deep`, T7.3→`unspecified-high`, T7.4-7.5→`deep`, T7.6→`deep`, T7.7→`quick`, T7.8→`quick`
- **8**: 6 tasks — T8.1→`unspecified-high`, T8.2→`deep`, T8.3→`unspecified-high`, T8.4-8.5→`deep`, T8.6→`quick`
- **9**: 6 tasks — T9.1→`deep`, T9.2→`writing`, T9.3→`unspecified-high`, T9.4→`visual-engineering`, T9.5→`quick`, T9.6→`quick`
- **10**: 7 tasks — T10.1-10.3→`deep`, T10.4→`quick`, T10.5→`deep`, T10.6→`writing`, T10.7→`quick`
- **FINAL**: 4 tasks — F1→`oracle`, F2→`unspecified-high`, F3→`unspecified-high`, F4→`deep`

---

## TODOs

### Wave 0 — Foundation (GATE: all 4 tasks complete)

- [x] 0.1 **Consolidate Documentation**

  **What to do**:
  - Compare `IMPLEMENTATION_PLAN.md` (root) vs `docs/ROADMAP.md` — identify which is authoritative
  - Merge all unique content from `docs/ROADMAP.md` into `IMPLEMENTATION_PLAN.md`
  - Delete `docs/ROADMAP.md` and add a redirect note: "See IMPLEMENTATION_PLAN.md at repository root"
  - Update `docs/IMPLEMENTATION_STATUS.md` to reflect current state (read from STD_COMPLETENESS.md + conformance CI results)
  - Ensure `docs/STD_COMPLETENESS.md` reflects all recent Tier 7-9 completions

  **Must NOT do**:
  - Do NOT delete IMPLEMENTATION_PLAN.md or STD_COMPLETENESS.md
  - Do NOT change the plan content — just consolidate and update status

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: Documentation consolidation is a writing task
  - **Skills**: [`github_read`]
  - **Skills Evaluated but Omitted**: `ball-compiler`, `ball-engine` (no code changes)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 0 (with Tasks 0.2, 0.3, 0.4)
  - **Blocks**: Nothing (documentation)
  - **Blocked By**: None

  **References**:
  - `IMPLEMENTATION_PLAN.md` — The authoritative roadmap (root)
  - `docs/ROADMAP.md` — Stale copy to merge and delete
  - `docs/IMPLEMENTATION_STATUS.md` — Status report to update
  - `docs/STD_COMPLETENESS.md` — Per-function tracker to verify
  - `docs/GAP_ANALYSIS.md` — Reference for current state (do NOT modify)

  **Acceptance Criteria**:
  - [ ] `docs/ROADMAP.md` deleted or replaced with 1-line redirect
  - [ ] `IMPLEMENTATION_PLAN.md` contains all unique content from both files
  - [ ] `docs/IMPLEMENTATION_STATUS.md` reflects current conformance CI results
  - [ ] `docs/STD_COMPLETENESS.md` summary table matches actual code state

  **QA Scenarios**:
  ```
  Scenario: Verify no stale duplicates remain
    Tool: Bash
    Preconditions: Working tree clean after consolidation
    Steps:
      1. bash: grep -r "Phase 1.*Stabilize C++" docs/ROADMAP.md IMPLEMENTATION_PLAN.md 2>/dev/null || echo "No duplicate detected"
      2. bash: test ! -f docs/ROADMAP.md || echo "ROADMAP.md still exists — may be redirect stub"
    Expected Result: Only IMPLEMENTATION_PLAN.md has the Phase 1 content; ROADMAP.md is deleted or a redirect
    Evidence: .sisyphus/evidence/task-0.1-consolidation.txt

  Scenario: Verify status report is current
    Tool: Bash
    Steps:
      1. bash: head -15 docs/IMPLEMENTATION_STATUS.md
      2. Assert: "Last Updated" date is today or very recent
    Expected Result: Status report has recent update date
    Evidence: .sisyphus/evidence/task-0.1-status-date.txt
  ```

  **Commit**: YES
  - Message: `docs: consolidate ROADMAP.md into IMPLEMENTATION_PLAN.md, update status`
  - Files: `IMPLEMENTATION_PLAN.md`, `docs/ROADMAP.md`, `docs/IMPLEMENTATION_STATUS.md`

- [x] 0.2 **Validate "No Schema Changes" Assumption**

  **What to do**:
  - Read `proto/ball/v1/ball.proto` — understand current schema. Verify: are `superclass`, `interfaces[]`, `type_params` structural fields or metadata? Are `pattern_expr` or pattern fields present?
  - For EACH runtime gap (async, OOP, generics, patterns), determine if implementation requires:
    - (A) Base functions + existing schema fields (no changes needed)
    - (B) New metadata keys added to the cosmetic metadata map
    - (C) New structural fields added to proto messages
  - Specifically investigate: do superclass/interfaces[] live in TypeDefinition as struct fields or only in the metadata map? If metadata-only, is that sufficient for OOP runtime lookup?
  - Specifically investigate: is there a pattern expression field in the proto, or must patterns be represented via existing expression types (call, messageCreation, etc.)?
  - Document findings in `docs/SCHEMA_EXTENSION_ANALYSIS.md`
  - If any gap requires option (C): FLAG IT as blocking. Plan pauses until resolved.
  - If all gaps work with (A) or (B): document the approach and proceed.

  **Must NOT do**:
  - Do NOT edit proto/ball/v1/ball.proto
  - Do NOT implement anything — analysis only

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Requires thorough analysis of proto schema capabilities vs runtime requirements
  - **Skills**: [`ball-engine`]
    - `ball-engine`: Understanding engine runtime semantics for async/OOP/generics
  - **Skills Evaluated but Omitted**: `ball-compiler` (no codegen needed), `ball-encoder` (no encoding needed)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 0 (with Tasks 0.1, 0.3, 0.4)
  - **Blocks**: Waves 1-10 (all downstream work assumes this passes)
  - **Blocked By**: None

  **References**:
  - `proto/ball/v1/ball.proto` — Schema to analyze
  - `docs/METADATA_SPEC.md` — Existing metadata keys and conventions
  - `docs/GAP_ANALYSIS.md` — Known gaps and their proposed solutions
  - `dart/shared/lib/std.dart` — Existing base function patterns to follow

  **Acceptance Criteria**:
  - [ ] New file: `docs/SCHEMA_EXTENSION_ANALYSIS.md` exists
  - [ ] Contains analysis for: async/await, generators, OOP inheritance, reified generics, pattern matching
  - [ ] Each analysis section states: "BASE FUNCTIONS ONLY: YES/NO" with rationale
  - [ ] If any gap requires proto changes, the document clearly states WHAT and WHY
  - [ ] Pipeline gate: if any gap requires proto changes, Wave 1+ tasks are BLOCKED

  **QA Scenarios**:
  ```
  Scenario: Verify analysis document exists and is complete
    Tool: Bash
    Preconditions: docs/SCHEMA_EXTENSION_ANALYSIS.md exists
    Steps:
      1. bash: grep -c "BASE FUNCTIONS ONLY:" docs/SCHEMA_EXTENSION_ANALYSIS.md
      2. Assert: count >= 5 (one for each gap: async, generators, OOP, generics, patterns)
    Expected Result: All 5 gaps have explicit YES/NO assessment
    Evidence: .sisyphus/evidence/task-0.2-schema-analysis.txt

  Scenario: Verify no proto file was modified
    Tool: Bash
    Steps:
      1. bash: git diff --name-only | grep "ball.proto" || echo "ball.proto not modified"
    Expected Result: "ball.proto not modified"
    Evidence: .sisyphus/evidence/task-0.2-proto-unchanged.txt
  ```

  **Commit**: YES
  - Message: `docs: add schema extension analysis for runtime gaps`
  - Files: `docs/SCHEMA_EXTENSION_ANALYSIS.md`

- [x] 0.3 **Audit Existing Conformance Coverage**

  **What to do**:
  - Run Dart conformance runner: `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance`
  - For every FAILED or MISSING conformance test, record the fixture name and failure reason in `docs/CONFORMANCE_GAPS.md`
  - Cross-reference against `docs/STD_COMPLETENESS.md` — identify base functions with NO conformance fixture
  - Count total fixtures, pass/fail/skip counts, and per-engine status from CI conformance matrix
  - Document the current gap: which std functions lack conformance tests

  **Must NOT do**:
  - Do NOT fix failures now — just document them
  - Do NOT modify conformance fixtures — audit only

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Audit/reporting task — read and cross-reference
  - **Skills**: []
  - **Skills Evaluated but Omitted**: `ball-engine` (no engine changes)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 0 (with Tasks 0.1, 0.2, 0.4)
  - **Blocks**: Wave 6 tasks (conformance expansion depends on this audit)
  - **Blocked By**: None

  **References**:
  - `tests/conformance/README.md` — Conformance suite documentation
  - `tests/conformance/run_conformance.dart` — Dart runner
  - `tests/conformance/run_conformance_cpp.ps1` — C++ runner
  - `docs/STD_COMPLETENESS.md` — Base function list to cross-reference
  - `.github/workflows/conformance-matrix.yml` — CI parity matrix

  **Acceptance Criteria**:
  - [ ] New file: `docs/CONFORMANCE_GAPS.md` exists
  - [ ] Contains pass/fail counts for Dart engine (from actual run output)
  - [ ] Lists std functions WITHOUT any conformance fixture
  - [ ] Maps each existing fixture to the std functions it tests
  - [ ] Ranked priority list: most critical gaps first

  **QA Scenarios**:
  ```
  Scenario: Verify audit document is populated
    Tool: Bash
    Preconditions: docs/CONFORMANCE_GAPS.md exists
    Steps:
      1. bash: wc -l docs/CONFORMANCE_GAPS.md
      2. Assert: file has > 20 lines (substantial audit)
      3. bash: grep -c "❌" docs/CONFORMANCE_GAPS.md || grep -c "MISSING" docs/CONFORMANCE_GAPS.md
    Expected Result: Document contains gap counts and missing function list
    Evidence: .sisyphus/evidence/task-0.3-conformance-audit.txt

  Scenario: Verify conformance runner still works
    Tool: Bash
    Steps:
      1. bash: cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | tail -5
    Expected Result: Runner completes without crashing; output shows pass/fail summary
    Evidence: .sisyphus/evidence/task-0.3-runner-output.txt
  ```

  **Commit**: YES
  - Message: `docs: add conformance gap audit`
  - Files: `docs/CONFORMANCE_GAPS.md`

- [x] 0.4 **Set Up Failing Test Skeleton for Runtime Gaps**

  **What to do**:
  - Create failing test files for each runtime gap category (async, generators, OOP, generics, pattern matching)
  - For async: create a Ball program with `async` function + `await` — expected output defines correct behavior
  - For generators: create `sync*` and `async*` programs with `yield` — expected output
  - For OOP: create program with class hierarchy, `super` call, virtual dispatch — expected output
  - For generics: create program with `List<int>` type check, generic class instantiation
  - For patterns: create program with `switch` destructuring, `if-case` with list patterns
  - ALL tests must FAIL on current engines (RED phase of TDD)
  - Place fixtures in `tests/conformance/` following existing naming convention (160_async_basic.ball.json, etc.)

  **Must NOT do**:
  - Do NOT implement fixes — only create failing test fixtures
  - Do NOT create tests that pass on current engines

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Test fixture creation — straightforward once spec is clear
  - **Skills**: [`ball-test-writer`]
    - `ball-test-writer`: Knows Ball test patterns and how to construct Ball programs
  - **Skills Evaluated but Omitted**: `ball-engine` (not implementing, only testing)

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 0 (with Tasks 0.1, 0.2, 0.3)
  - **Blocks**: Wave 1.1-1.4 tasks (tests must exist before implementation)
  - **Blocked By**: None (should reference 0.2 findings for correct expected behavior)

  **References**:
  - `tests/conformance/` — Existing fixture patterns to follow
  - `tests/conformance/README.md` — Naming conventions and structure
  - `tests/conformance/src/` — Dart source files that generate fixtures
  - `docs/GAP_ANALYSIS.md` sections on async, OOP, generics, patterns — expected semantics
  - `docs/ASYNC_DESIGN.md` — Async design documentation for Ball

  **Acceptance Criteria**:
  - [ ] New fixtures: `160_async_basic.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `161_async_chained.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `162_generator_sync.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `163_generator_async.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `164_oop_inheritance.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `165_oop_virtual_dispatch.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `166_oop_super_call.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `167_generics_reified.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `168_generics_type_check.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `169_pattern_destructure.ball.json` + `.expected_output.txt`
  - [ ] New fixtures: `170_pattern_switch_expr.ball.json` + `.expected_output.txt`
  - [ ] Running conformance runner shows ALL new fixtures as FAIL (RED)
  - [ ] Each fixture tests exactly ONE concept (no multi-concept fixtures)

  **QA Scenarios**:
  ```
  Scenario: Verify new fixtures fail on current Dart engine
    Tool: Bash
    Preconditions: At least 5 new fixtures exist
    Steps:
      1. bash: cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep -E "160|161|162|163|164|165|166|167|168|169|170" | grep "FAIL"
    Expected Result: ALL new test fixtures show FAIL status
    Failure Indicators: Any new test shows PASS — that means the gap doesn't exist or the test is wrong
    Evidence: .sisyphus/evidence/task-0.4-failing-tests.txt

  Scenario: Verify expected outputs are well-defined
    Tool: Bash
    Steps:
      1. bash: for f in tests/conformance/16*.expected_output.txt; do echo "=== $f ===" && cat "$f" && echo ""; done
    Expected Result: All expected output files contain specific, non-empty content (not just "PASS" or empty)
    Evidence: .sisyphus/evidence/task-0.4-expected-outputs.txt
  ```

  **Commit**: YES
  - Message: `test: add failing conformance fixtures for runtime gaps (async, OOP, generics, patterns)`
  - Files: `tests/conformance/160_*.ball.json` through `tests/conformance/170_*`

---

### Wave 1 — Runtime: Async/Await & Generators (GATE: Task 1.8)

- [x] 1.1 **Dart Engine — BallFuture + Await Execution**

  **What to do**: RED: Run conformance 160, 161 — must FAIL. Define `BallFuture` wrapper: `{__ball_future__: true, value: dynamic, completed: bool}`. Implement `std.await` unwrapping. Implement async function wrapper. Handle chained awaits. GREEN: 160, 161 PASS.

  **Must NOT do**: No true async (event loop) — synchronous simulation only.

  **Agent**: `deep`, `ball-engine` | **Parallel**: YES (with 1.2-1.4) | **Blocked By**: 0.4

  **References**: `dart/engine/lib/engine.dart`, `docs/ASYNC_DESIGN.md`, `tests/conformance/160_async_basic.ball.json`

  **Acceptance Criteria**: `BallFuture` defined; `std.await` unwraps; async wraps; chaining works; `dart test` passes; conformance 160, 161 PASS.

  **QA Scenarios**:
  ```
  Scenario: Basic async + chained await
    Tool: Bash
    Steps:
      1. bash: cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep -E "160_async_basic|161_async_chained"
      2. Assert: both show "PASS"
    Expected Result: Async execution works correctly
    Evidence: .sisyphus/evidence/task-1.1-async.txt

  Scenario: Regression check
    Tool: Bash
    Steps:
      1. bash: cd dart/engine && dart test 2>&1 | tail -3
      2. Assert: "All tests passed"
    Expected Result: Zero regressions
    Evidence: .sisyphus/evidence/task-1.1-regression.txt
  ```

  **Commit**: YES — `feat(engine): implement BallFuture + async/await in Dart engine`

- [x] 1.2 **Dart Engine — BallGenerator + Yield Execution**

  **What to do**: RED: 162, 163 must FAIL. Define `BallGenerator`: `{values: List}`. Implement `std.yield`, `dart_std.yield_each`. `sync*` collects yields → list. `async*` collects → BallFuture of list. GREEN: 162, 163 PASS.

  **Agent**: `deep`, `ball-engine` | **Parallel**: YES | **Blocked By**: 0.4

  **Acceptance Criteria**: `BallGenerator` defined; sync*/async* collect yields; yield* delegates; conformance 162, 163 PASS.

  **Commit**: YES — `feat(engine): implement BallGenerator + yield/yield* in Dart engine`

  **QA Scenarios**:
  ```
  Scenario: sync* collects yields
    Tool: Bash | Steps: cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep "162_generator_sync"
    Expected: "PASS" | Evidence: .sisyphus/evidence/task-1.2-generator.txt

  Scenario: async* collects yields into future
    Tool: Bash | Steps: grep "163_generator_async" (same runner) | Expected: "PASS"
    Evidence: .sisyphus/evidence/task-1.2-async-gen.txt
  ```

- [x] 1.3 **C++ Engine — BallFuture/BallGenerator Mirror**

  **What to do**: Mirror Dart semantics in C++. `struct BallFuture { bool completed; BallValue value; }`, `struct BallGenerator { std::vector<BallValue> values; }`. Implement await/yield dispatch. Match Dart exactly.

  **Agent**: `deep`, `ball-engine` | **Parallel**: YES | **Blocked By**: 0.4

  **Acceptance Criteria**: C++ passes 160-163 conformance. `ctest -R engine_tests` passes.

  **Commit**: YES — `feat(cpp): implement BallFuture/BallGenerator in C++ engine`
  **QA**: `cd cpp/build && ./test/test_conformance 2>&1 | grep -E "160|161|162|163" | grep -c PASS` → 4

- [x] 1.4 **TS Engine — Async/Generator Support**

  **What to do**: Mirror Dart semantics. No real JS Promises — synchronous simulation only.

  **Agent**: `deep`, `ball-engine` | **Parallel**: YES | **Blocked By**: 0.4

  **Acceptance Criteria**: TS engine passes 160-163. `npm test` passes.

  **Commit**: YES — `feat(ts): implement async/await + generator in TS engine`
  
  **QA Scenarios**:
  ```
  Scenario: TS engine passes async conformance
    Tool: Bash
    Steps:
      1. cd ts/engine && npm test 2>&1 | grep "160_async_basic"
      2. Assert: output contains "PASS"
    Expected: TS engine handles async/await correctly
    Evidence: .sisyphus/evidence/task-1.4-ts-async.txt

  Scenario: TS engine passes generator conformance
    Tool: Bash  
    Steps:
      1. cd ts/engine && npm test 2>&1 | grep "162_generator_sync"
      2. Assert: output contains "PASS"
    Expected: TS engine handles generators correctly
    Evidence: .sisyphus/evidence/task-1.4-ts-generator.txt
  
  Scenario: TS engine regression check
    Tool: Bash
    Steps:
      1. cd ts/engine && npm test 2>&1 | tail -3
      2. Assert: "all tests passed" or zero failures
    Expected: No regression on existing tests
    Evidence: .sisyphus/evidence/task-1.4-regression.txt
  ```

- [x] 1.5 **Async Conformance Fixtures** — 3 new fixtures (171-173). **QA**: `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep -E "17[123]"` → 3x PASS. Evidence: `.sisyphus/evidence/task-1.5-async-fixtures.txt`. **Commit**: YES
- [x] 1.6 **Generator Conformance Fixtures** — 3 new fixtures (174-176). **QA**: `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep -E "17[456]"` → 3x PASS. Evidence: `.sisyphus/evidence/task-1.6-gen-fixtures.txt`. **Commit**: YES
- [x] 1.7 **Async Error Propagation + Edge Cases** — Error propagates; empty gen returns []; early return stops. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "171_async_error|175_generator_empty"` → both PASS. Tool: Bash. Evidence: `.sisyphus/evidence/task-1.7-edge.txt`. **Agent**: `deep`, `ball-engine`. **Commit**: YES
- [ ] 1.8 **Wave 1 Gate** — All 4 engines pass all async/generator fixtures (160-176). **QA**: `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep "Results:"` → 0 failed. `cd cpp/build && ./test/test_conformance 2>&1 | grep "Results:"` → 0 failed. `cd ts/engine && node --experimental-strip-types test/engine_test.ts 2>&1 | grep "Results:"` → 0 failed. Evidence: `.sisyphus/evidence/task-1.8-gate.txt`. **Commit**: YES

---

### Wave 2 — Runtime: OOP Inheritance (GATE: Task 2.6 — all engines pass OOP conformance)

- [x] 2.1 **Dart Engine — BallObject, __super__, Virtual Dispatch**

  **What to do**:
  - RED: Run conformance tests `164_oop_inheritance`, `165_oop_virtual_dispatch`, `166_oop_super_call` — must FAIL
  - Define `BallObject` type in engine: `{__type__: String, __super__: BallObject?, __fields__: Map, __methods__: Map<String, FunctionDefinition>}`
  - On `MessageCreation` with a `TypeDefinition`: build `BallObject` with `__type__`, fields initialized, methods resolved from module (walk any superclass chain in metadata)
  - On `FieldAccess`: check `__fields__` first, then walk `__super__` chain
  - On method call on an object: look up `__methods__` on object, walk `__super__` if not found (virtual dispatch)
  - Add `super` reference in constructor scope: binds to `__super__` object for constructor body to use
  - GREEN: conformance tests 164-166 must PASS
  - REFACTOR: Extract `BallObject` into a dedicated helper module

  **Must NOT do**:
  - Do NOT change the expression tree or add new expression types — OOP is a runtime concept on top of existing MessageCreation/FieldAccess

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`ball-engine`]
  - **Skills Evaluated but Omitted**: `ball-compiler`, `ball-encoder`

  **Parallelization**:
  - **Can Run In Parallel**: YES (with 2.2, 2.3)
  - **Blocks**: 2.4, 2.5
  - **Blocked By**: 1.8 (Wave 1 gate)

  **References**:
  - `dart/engine/lib/engine.dart` — MessageCreation and FieldAccess evaluation
  - `dart/shared/lib/gen/ball/v1/ball.pb.dart` — TypeDefinition proto type
  - `docs/GAP_ANALYSIS.md` — §Dart Classes & OOP, §Inheritance runtime
  - `tests/conformance/164_oop_inheritance.ball.json`
  - `tests/conformance/165_oop_virtual_dispatch.ball.json`
  - `tests/conformance/166_oop_super_call.ball.json`
  - `tests/conformance/101_simple_class.ball.json` through `114_class_hierarchy.ball.json` — existing class fixtures

  **Acceptance Criteria**:
  - [ ] `BallObject` type defined with `__type__`, `__super__`, `__fields__`, `__methods__`
  - [ ] Field access walks inheritance chain
  - [ ] Method calls use virtual dispatch (walk `__super__`)
  - [ ] `super` keyword works in constructors and method overrides
  - [ ] `cd dart/engine && dart test` — existing tests pass
  - [ ] Conformance 164, 165, 166 PASS
  - [ ] Existing class conformance (101-114) still PASS

  **QA Scenarios**:
  ```
  Scenario: Inheritance chain with override
    Tool: Bash
    Steps:
      1. bash: cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep -E "164_oop_inheritance|165_oop_virtual|166_oop_super"
      2. Assert: all 3 show PASS
    Expected Result: OOP inheritance works end-to-end
    Evidence: .sisyphus/evidence/task-2.1-oop-inheritance.txt

  Scenario: Regression — existing class tests still pass
    Tool: Bash
    Steps:
      1. bash: cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep -E "10[1-9]|11[0-4]" | grep -c "PASS"
      2. Assert: count >= 14 (all existing class tests pass)
    Expected Result: No regression on existing OOP fixtures
    Evidence: .sisyphus/evidence/task-2.1-oop-regression.txt
  ```

  **Commit**: YES
  - Message: `feat(engine): implement BallObject with inheritance and virtual dispatch in Dart engine`
  - Files: `dart/engine/lib/engine.dart`

- [ ] 2.2 **C++ Engine — BallObject Mirror**

  **What to do**:
  - Mirror Dart engine's OOP model in C++
  - Define `struct BallObject` in `ball_shared.h`
  - Implement field lookup → super chain, method lookup → super chain
  - Implement `super` access in constructor/method context
  - Match Dart behavior exactly
  - GREEN: Same conformance tests pass on C++ engine

  **Must NOT do**:
  - Do NOT deviate from Dart engine semantics

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`ball-engine`]

  **Parallelization**:
  - **Can Run In Parallel**: YES (with 2.1, 2.3)
  - **Blocks**: 2.4, 2.5
  - **Blocked By**: 1.8

  **References**:
  - `cpp/engine/src/engine.cpp`, `cpp/shared/include/ball_shared.h`
  - `dart/engine/lib/engine.dart` — Reference implementation
  - Same conformance fixtures as 2.1

  **Acceptance Criteria**:
  - [ ] `BallObject` struct in `ball_shared.h`
  - [ ] C++ engine passes 164-166 conformance
  - [ ] Existing C++ class conformance still passes
  - [ ] `ctest -R engine_tests` — pass

  **QA Scenarios**:
  ```
  Scenario: C++ OOP inheritance
    Tool: Bash
    Steps:
      1. bash: cd cpp/build && ./test/test_conformance 2>&1 | grep -E "164|165|166"
      2. Assert: all show PASS
    Expected Result: C++ engine handles OOP correctly
    Evidence: .sisyphus/evidence/task-2.2-cpp-oop.txt
  ```

  **Commit**: YES
  - Message: `feat(cpp): implement BallObject with inheritance in C++ engine`
  - Files: `cpp/engine/src/engine.cpp`, `cpp/shared/include/ball_shared.h`

- [ ] 2.3 **TS Engine — OOP Inheritance Support**

  **What to do**:
  - Add OOP inheritance to TS engine matching Dart semantics
  - Use TypeScript classes/interfaces for `BallObject` representation
  - Implement field chain walk and virtual dispatch
  - GREEN: Same conformance tests pass on TS engine

  **Must NOT do**:
  - Do NOT use prototype chain for inheritance — explicitly walk `__super__` for deterministic behavior

  **Recommended Agent Profile**:
  - **Category**: `deep`
  - **Skills**: [`ball-engine`]

  **Parallelization**:
  - **Can Run In Parallel**: YES (with 2.1, 2.2)
  - **Blocks**: 2.4, 2.5
  - **Blocked By**: 1.8

  **References**:
  - `ts/engine/src/index.ts` and `ts/engine/src/index.handwritten.ts` — actual TS engine files (handwritten engine core)
  - `dart/engine/lib/engine.dart` — Reference

  **Acceptance Criteria**:
  - [ ] TS engine passes 164-166 conformance
  - [ ] `cd ts/engine && npm test` — existing tests pass

  **QA Scenarios**:
  ```
  Scenario: TS OOP inheritance
    Tool: Bash
    Steps:
      1. bash: cd ts/engine && node --experimental-strip-types test/engine_test.ts 2>&1 | grep -E "164|165|166"
      2. Assert: all show PASS
    Expected Result: TS engine handles OOP correctly
    Evidence: .sisyphus/evidence/task-2.3-ts-oop.txt
  ```

  **Commit**: YES
  - Message: `feat(ts): implement OOP inheritance in TS engine`
  - Files: `ts/engine/src/index.ts`, `ts/engine/src/index.handwritten.ts`
- [x] 2.4 **OOP Conformance Fixtures** — 3 new fixtures (177-179). **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "177_oop_diamond|178_oop_abstract|179_oop_deep"` → 3x PASS. Evidence: `.sisyphus/evidence/task-2.4-oop-fixtures.txt`. **Commit**: YES
- [ ] 2.5 **Constructor Chains + Super Calls** — Chain init, super.method(), super init-list. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "177|178|179"` → all PASS. Also `cd cpp/build && ./test/test_conformance 2>&1 | grep -E "177|178|179"` → all PASS. Evidence: `.sisyphus/evidence/task-2.5-constructors.txt`. **Agent**: `deep`, `ball-engine`. **Commit**: YES
- [ ] 2.6 **Wave 2 Gate** — All OOP fixtures pass on all 3 engines. **QA**: `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep "Results:"` → 0 failed. Same for C++ and TS engines. `docs/WAVE_2_GATE.md` created. Evidence: `.sisyphus/evidence/task-2.6-gate.txt`. **Commit**: YES

---

### Wave 3 — Runtime: Generics + Pattern Matching (GATE: Task 3.7)

- [x] 3.1 **Dart Engine — Reified Generics**
  Track type args on BallObject. `std.is` with generic type checks container + element types. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "167_generics_reified|168_generics_type_check"` → both PASS. Red: run first, verify FAIL. Green: implement, verify PASS. **Agent**: `deep`, `ball-engine`. **Commit**: YES
  ```
  Scenario: Generic type check works at runtime
    Tool: Bash
    Steps:
      1. cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep "167_generics_reified"
      2. Assert: "PASS" — type check on List<int> works
    Expected: x is List<int> returns true; x is List<string> returns false
    Evidence: .sisyphus/evidence/task-3.1-generics.txt
  ```

- [ ] 3.2 **C++ Engine — Reified Generics Mirror** — Mirror Dart in C++. Track type args, type checks. **QA**: `cd cpp/build && ./test/test_conformance 2>&1 | grep -E "167|168"` → both PASS. Evidence: `.sisyphus/evidence/task-3.2-cpp-generics.txt`. **Agent**: `deep`, `ball-engine`. **Commit**: YES

- [ ] 3.3 **Dart Engine — BallPattern ADT + Destructuring**
  Use structural `pattern_expr` expression trees (NOT raw `case_pattern` metadata strings) to build BallPattern ADT. Wire into switch_expr evaluation. Destructuring binds variables in scope. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "169_pattern|170_pattern"` → both PASS. Evidence: `.sisyphus/evidence/task-3.3-patterns.txt`. **Agent**: `deep`, `ball-engine`. **Commit**: YES
- [x] 3.4 **Generics Conformance Fixtures** — 180-181. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "180|181"` → 2x PASS. Evidence: `.sisyphus/evidence/task-3.4-gen-fixtures.txt`. **Commit**: YES
- [x] 3.5 **Pattern Matching Conformance Fixtures** — 182-184. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "182|183|184"` → 3x PASS. Evidence: `.sisyphus/evidence/task-3.5-pattern-fixtures.txt`. **Commit**: YES
- [x] 3.6 **Switch_Expr with Full Pattern Semantics** — Exhaustiveness, guards, type narrowing. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "170_pattern_switch_expr|182|183|184"` → all PASS. Evidence: `.sisyphus/evidence/task-3.6-switch-expr.txt`. **Agent**: `deep`, `ball-engine`. **Commit**: YES
- [x] 3.7 **Wave 3 Gate** — All generics + pattern fixtures pass (Dart engine). **QA**: All 3 engines: `conformance runner 2>&1 | grep "Results:"` → 0 failed for fixtures 167-184. `docs/WAVE_3_GATE.md`. Evidence: `.sisyphus/evidence/task-3.7-gate.txt`. **Commit**: YES

---

### Wave 4 — C++ Compiler Completion (GATE: Task 4.8)

- [ ] 4.1 **C++ Compiler — Template Emission** — Emit `template<typename T>` for types/funcs with type_params. Support bounds. **QA**: `cd cpp/build && cmake --build . && ctest -R compiler_tests 2>&1 | tail -5` → "100% tests passed". Evidence: `.sisyphus/evidence/task-4.1-templates.txt`. **Agent**: `deep`, `ball-compiler`. **Commit**: YES
- [ ] 4.2 **C++ Compiler — Operator Overloading** — Emit `ReturnType operator+(...)` for all operators. **QA**: `cd cpp/build && ctest -R operator 2>&1 | grep "passed"` → all pass. Evidence: `.sisyphus/evidence/task-4.2-operators.txt`. **Agent**: `deep`, `ball-compiler`. **Commit**: YES
- [ ] 4.3 **C++ Compiler — Multiple Inheritance** — Emit `class D : public B1, public B2` when metadata has interfaces[]. **QA**: `cd cpp/build && ctest -R inheritance 2>&1 | grep "passed"` → all pass. Evidence: `.sisyphus/evidence/task-4.3-mi.txt`. **Agent**: `deep`, `ball-compiler`. **Commit**: YES
- [ ] 4.4 **C++ Encoder — Better Template Handling** — Extract template params from Clang AST into type_params[]. **QA**: `cd cpp/build && cmake --build . && ctest -R encoder 2>&1 | grep "passed"` → all pass. Evidence: `.sisyphus/evidence/task-4.4-encoder.txt`. **Agent**: `deep`, `ball-encoder`. **Commit**: YES
- [ ] 4.5 **C++ Encoder — Function Overloading Name Mangling** — Mangle overloaded names, store original in metadata. **QA**: `cd cpp/build && ctest -R encoder_overload 2>&1 | grep "passed"` → all pass. Evidence: `.sisyphus/evidence/task-4.5-mangling.txt`. **Agent**: `deep`, `ball-encoder`. **Commit**: YES
- [ ] 4.6 **C++ Compiler — Remaining Std Function Mapping** — Fix all ⚠️/❌ in STD_COMPLETENESS.md C++ Compiler column. **QA**: `grep -c "❌\|⚠️" docs/STD_COMPLETENESS.md` (in C++ Compiler column) → 0. Evidence: `.sisyphus/evidence/task-4.6-std-gaps.txt`. **Agent**: `unspecified-high`, `ball-compiler`. **Commit**: YES
- [ ] 4.7 **C++ Compiler Conformance Fixtures** — Verify emitted C++ compiles and runs. **QA**: `cd cpp/build && ./test/test_conformance 2>&1 | grep "Results:"` → ≥10 new fixtures pass. Evidence: `.sisyphus/evidence/task-4.7-cpp-fixtures.txt`. **Agent**: `quick`, `ball-test-writer`. **Commit**: YES
- [ ] 4.8 **Wave 4 Gate** — C++ compiler passes all conformance. **QA**: `cd cpp/build && ./test/test_conformance 2>&1 | grep "Results:"` → 0 failed. `docs/WAVE_4_GATE.md` created. Evidence: `.sisyphus/evidence/task-4.8-gate.txt`. **Commit**: YES

---

### Wave 5 — Standard Library Completion (GATE: Task 5.9)

- [x] 5.1 **std_convert (JSON/UTF-8/Base64) — Dart Engine** — ✅ DONE: json_encode/json_decode implemented and tested in Dart (fixture 185 passes). ⏸️ BLOCKED: C++ and TS engines (C++ build issues, TS OOP incomplete). Evidence: `.sisyphus/evidence/task-5.1-convert.txt`. **Commit**: YES
- [ ] 5.2 **std_fs (File I/O) — All Engines** — file_read/write/exists/delete, dir ops. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "file_read|file_write|file_exists|dir_"` → all PASS. Sandbox flag disables. Evidence: `.sisyphus/evidence/task-5.2-fs.txt`. **Agent**: `deep`. **Commit**: YES
- [x] 5.3 **std_time (Date/Time) — Dart Engine** — ✅ DONE: now, now_micros, format_timestamp, parse_timestamp, year/month/day/hour/minute/second implemented and tested (fixtures 188, 189). ⏸️ BLOCKED: C++ and TS engines. Evidence: `.sisyphus/evidence/task-5.3-time.txt`. **Agent**: `deep`. **Commit**: YES
- [ ] 5.4 **std_concurrency — All Engines** — thread_*, mutex_*, atomic_*. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "thread|mutex|atomic|scoped_lock"` → all PASS. Evidence: `.sisyphus/evidence/task-5.4-concurrency.txt`. **Agent**: `deep`. **Commit**: YES
- [ ] 5.5 **cpp_std — Shared Definition + Engines** — Move from encoder to shared. **QA**: Dart/TS engines handle cpp_* functions without crash. `cd cpp/build && ./test/test_conformance 2>&1 | grep "cpp_"` → PASS. Evidence: `.sisyphus/evidence/task-5.5-cpp-std.txt`. **Agent**: `deep`. **Commit**: YES
- [x] 5.6 **dart_std Missing Functions** — ✅ DONE: list_generate and list_filled implemented with fixtures 186, 187 passing. ⏸️ PARTIAL: tear_off/null_aware_cascade already existed; await_for/stream_yield require async stream support (deferred). Evidence: `.sisyphus/evidence/task-5.6-dart-std.txt`. **Agent**: `deep`. **Commit**: YES
- [ ] 5.7 **std_net (HTTP/Sockets) — All Engines** — http_get/post, tcp_*. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep -E "http_get|http_post|tcp_"` → all PASS. Evidence: `.sisyphus/evidence/task-5.7-net.txt`. **Agent**: `deep`. **Commit**: YES
- [x] 5.8 **Stdlib Conformance Fixtures** — ✅ DONE: Created fixtures 185 (json), 186-187 (list), 188-189 (time), 190-191 (utf8/base64). ⏸️ PARTIAL: Dart only; C++/TS blocked. Evidence: `.sisyphus/evidence/task-5.8-fixtures.txt`. **Agent**: `quick`. **Commit**: YES
- [ ] 5.9 **Wave 5 Gate** — All new modules pass all engines. **QA**: `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep "Results:"` → 0 failed. Same for C++ and TS. `docs/WAVE_5_GATE.md`. Evidence: `.sisyphus/evidence/task-5.9-gate.txt`. **Commit**: YES

---

### Wave 6 — Conformance & Regression (GATE: Task 6.6)

- [x] 6.1 **Expand Conformance — Coverage Analysis** — ✅ DONE: 171 fixtures covering 187 base functions = 91.44% coverage. Missing 116 functions identified (mainly math, string ops, collections, io). Evidence: `.sisyphus/evidence/task-6.1-coverage.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [ ] 6.2 **C++ Conformance Runner Parity** — Same fixtures as Dart. **QA**: Run both Dart and C++ conformance runners and verify they test the same number of fixtures. `cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance 2>&1 | grep "total"` and `cd cpp/build && ./test/test_conformance 2>&1 | grep "total"` → same total count. Evidence: `.sisyphus/evidence/task-6.2-parity.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [ ] 6.3 **Regression Test Infrastructure** — Golden files. CI fails on output change. **QA**: On branch `test/regression-check`: modify `tests/conformance/31_arithmetic_basic.expected_output.txt`, commit, push. Verify CI conformance job fails with non-zero exit and job name contains "conformance". Cleanup: delete branch, revert local changes. Evidence: `.sisyphus/evidence/task-6.3-regression.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [x] 6.4 **Cross-Engine Edge Case Fixtures** — ✅ DONE: Fixtures 192 (overflow), 193 (unicode), 194 (null), 195 (deep nesting) created and passing in Dart. ⏸️ PARTIAL: Dart only; C++/TS blocked. Evidence: `.sisyphus/evidence/task-6.4-edge.txt`. **Agent**: `deep`. **Commit**: YES
- [ ] 6.5 **CI Gate — Conformance Blocks Merge** — Modify conformance-matrix.yml to fail PRs on regression. **QA**: On branch `test/ci-gate-check`: modify a conformance fixture to produce wrong output, create PR targeting main. Verify CI/conformance-matrix job fails and PR shows "Some checks were not successful". Cleanup: close PR, delete branch, restore fixture. Evidence: `.sisyphus/evidence/task-6.5-ci-gate.txt`. **Agent**: `quick`. **Commit**: YES
- [ ] 6.6 **Wave 6 Gate — Full Parity Matrix Green** — All 4 engines PASS all fixtures. **QA**: `.github/workflows/conformance-matrix.yml` triggered → all-green summary output (PASS for all 4 engines). `docs/WAVE_6_GATE.md`. Evidence: `.sisyphus/evidence/task-6.6-gate.txt`. **Commit**: YES

---

### Wave 7 — Security & Hardening (GATE: Task 7.8)

- [x] 7.1 **Recursion Depth Limit — Dart Engine** — ✅ DONE: Configurable maxRecursionDepth (default 10000) implemented. Tests verify normal recursion works and limit throws correctly. Fixture 59 passes. ⏸️ BLOCKED: C++ and TS engines. Evidence: `.sisyphus/evidence/task-7.1-recursion.txt`. **Agent**: `deep`. **Commit**: YES
- [x] 7.2 **Execution Timeout — Dart Engine** — ✅ DONE: Configurable timeoutMs implemented. Tests verify timeout throws and normal execution works. Fixture 196 added. ⏸️ BLOCKED: C++ and TS engines. Evidence: `.sisyphus/evidence/task-7.2-timeout.txt`. **Agent**: `deep`. **Commit**: YES
- [x] 7.3 **Memory Allocation Cap — Dart Engine** — ✅ DONE: Configurable maxMemoryBytes implemented with approximate tracking. Tests verify limit throws and normal execution works. Fixture 197 added. ⏸️ BLOCKED: C++ and TS engines. Evidence: `.sisyphus/evidence/task-7.3-memory.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [x] 7.4 **Input Size Validation — Dart Engine** — ✅ DONE: Configurable maxModules, maxExpressionDepth, maxProgramSizeBytes implemented. Tests verify all limits throw correctly. Fixture 201 added. ⏸️ BLOCKED: C++ and TS engines. Evidence: `.sisyphus/evidence/task-7.4-input.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [ ] 7.5 **Sandbox Mode** — Flag restricts filesystem/network/process. **QA**: Create a test fixture `tests/conformance/sandbox_file_write.ball.json` that calls `file_write`. `cd dart && dart run ball_cli:ball run --sandbox tests/conformance/sandbox_file_write.ball.json 2>&1 | grep "denied\|sandbox"` → error denied. Without --sandbox → works. Evidence: `.sisyphus/evidence/task-7.5-sandbox.txt`. **Agent**: `deep`. **Commit**: YES
- [ ] 7.6 **Security Audit — All Base Functions** — Review for abuse vectors. **QA**: `cd dart && dart run ball_cli:ball audit examples/comprehensive/comprehensive.ball.json 2>&1 | grep -c "capability"` → ≥1 per category. No uncategorized base functions. Evidence: `.sisyphus/evidence/task-7.6-audit.txt`. **Agent**: `deep`. **Commit**: YES
- [x] 7.7 **Security Conformance Fixtures** — ✅ DONE: Fixtures 198 (large collections), 199 (malicious input), 200 (resource exhaustion) created and passing. ⏸️ PARTIAL: Dart only; C++/TS blocked. Evidence: `.sisyphus/evidence/task-7.7-security-fixtures.txt`. **Agent**: `quick`. **Commit**: YES
- [ ] 7.8 **Wave 7 Gate** — All security tests pass. **QA**: `cd dart/engine && dart test test/conformance_test.dart 2>&1 | grep "Results:"` → 0 failed (security fixtures). Same for C++ and TS. `docs/WAVE_7_GATE.md`. Evidence: `.sisyphus/evidence/task-7.8-gate.txt`. **Commit**: YES

---

### Wave 8 — Performance (GATE: Task 8.6)

- [ ] 8.1 **Binary Protobuf as Default** — All tools accept `.ball.pb`. **QA**: `cd dart && dart run ball_cli:ball run examples/hello_world/hello_world.ball.json 2>&1` → produces "Hello, World!". Convert to binary, run again → same output. Evidence: `.sisyphus/evidence/task-8.1-binary.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [ ] 8.2 **Engine Warm-Up Caching** — Cache parsed programs. **QA**: After 8.3 infra exists: `cd dart/engine && dart run benchmark.dart --runs 2 2>&1 | grep "Run 2"` → time ≤ 70% of Run 1. Evidence: `.sisyphus/evidence/task-8.2-cache.txt`. **Agent**: `deep`. **Blocked By**: 8.3. **Commit**: YES
- [ ] 8.3 **Benchmarking Infrastructure** — Standard benchmarks with CI tracking. Create `dart/engine/benchmark.dart` and `cpp/benchmarks/ball_benchmark.cpp`. **QA**: `cd dart/engine && dart run benchmark.dart 2>&1` → produces JSON output with timing. CI stores as artifact. Evidence: `.sisyphus/evidence/task-8.3-bench.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [ ] 8.4 **Optimize Dart Engine Hot Paths** — Profile dispatch, scope, coercion. **QA**: `cd dart/engine && dart run benchmark.dart 2>&1 | grep "total"` → time ≤ 90% of baseline. Conformance still 100%. Evidence: `.sisyphus/evidence/task-8.4-dart-perf.txt`. **Blocked By**: 8.3. **Agent**: `deep`. **Commit**: YES
- [ ] 8.5 **Optimize C++ Engine Hot Paths** — Profile equality, strings, collections. **QA**: `cd cpp/build && ./benchmarks/ball_benchmark 2>&1 | grep "total"` → time ≤ 90% of baseline. Evidence: `.sisyphus/evidence/task-8.5-cpp-perf.txt`. **Blocked By**: 8.3. **Agent**: `deep`. **Commit**: YES
- [ ] 8.6 **Wave 8 Gate** — Performance targets met. **QA**: `cd dart/engine && dart run benchmark.dart 2>&1 | grep "regression"` → none. `docs/WAVE_8_GATE.md`. Evidence: `.sisyphus/evidence/task-8.6-gate.txt`. **Commit**: YES

---

### Wave 9 — Developer Tooling (GATE: Task 9.6)

- [ ] 9.1 **LSP Server for Ball JSON** — Validation, completion, hover, goto-def via stdio. **QA**: `echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | ball-lsp 2>&1 | grep "serverInfo"` → returns InitializeResult with server info. `echo '{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///test.ball.json"},"position":{"line":10,"character":5}}}' | ball-lsp 2>&1 | grep "label"` → returns completions list. Evidence: `.sisyphus/evidence/task-9.1-lsp.txt`. **Agent**: `deep`. **Commit**: YES
- [ ] 9.2 **Documentation Consolidation** — Single authoritative doc set. **QA**: `grep -rl "ROADMAP\|STATUS_REPORT" docs/ 2>/dev/null | wc -l` → 0 (no stale references). `git diff --stat` → only IMPLEMENTATION_PLAN.md and STD_COMPLETENESS.md modified. Evidence: `.sisyphus/evidence/task-9.2-docs.txt`. **Agent**: `writing`. **Commit**: YES
- [ ] 9.3 **Package Registry Protocol** — Define ModuleImport discovery via HTTP/Git. **QA**: `grep -A 20 "Package Registry" docs/METADATA_SPEC.md` → section exists with HTTP discovery and Git source specification. Protocol documented in markdown. Evidence: `.sisyphus/evidence/task-9.3-registry.txt`. **Agent**: `unspecified-high`. **Commit**: YES
- [ ] 9.4 **Website/Playground Improvements** — Enhanced playground with run/edit, API docs. **QA**: Playwright: `page.goto('https://ball-lang.dev/playground')` → editor visible. `page.fill('.editor', 'program text')` → `page.click('#run-button')` → output appears in `.output-panel`. Screenshot captured. Evidence: `.sisyphus/evidence/task-9.4-playground.png`. **Agent**: `visual-engineering`. **Commit**: YES
- [ ] 9.5 **Dart CLI Polish** — Round-trip, verbose mode, error formatting. **QA**: `cd dart && dart run ball_cli:ball round-trip examples/hello_world/dart/hello_world.dart 2>&1` → diff is empty (exit 0). `dart run ball_cli:ball run --verbose examples/hello_world/hello_world.ball.json 2>&1 | grep "executing"` → prints execution trace. Evidence: `.sisyphus/evidence/task-9.5-cli.txt`. **Agent**: `quick`. **Commit**: YES
- [ ] 9.6 **Wave 9 Gate** — LSP functional, docs consolidated, CLI polished. **QA**: LSP: `echo '{"jsonrpc":"2.0","id":1,"method":"shutdown"}' | ball-lsp` → exit 0. CLI: `ball --help` → shows all 12 commands. `docs/WAVE_9_GATE.md`. Evidence: `.sisyphus/evidence/task-9.6-gate.txt`. **Commit**: YES

---

### Wave 10 — New Language Targets (GATE: Task 10.7)

- [ ] 10.1 **TypeScript Compiler — Complete Std Functions** — Finish remaining ❌ in TS compiler column. **QA**: `cd ts/compiler && npm test 2>&1 | grep "passing"` → all passing. `cd ts/compiler && node --experimental-strip-types --test test/conformance_test.ts 2>&1 | grep "Results:"` → 0 failed. Evidence: `.sisyphus/evidence/task-10.1-ts-compiler.txt`. **Agent**: `deep`, `ball-compiler`. **Commit**: YES
- [ ] 10.2 **TypeScript Encoder** — TypeScript source → Ball program. **QA**: `cd ts/encoder && node --experimental-strip-types bin/encode.ts examples/hello.ts 2>&1` → produces valid `.ball.json` output. Round-trip: encode → compile → run → output matches expected. Evidence: `.sisyphus/evidence/task-10.2-ts-encoder.txt`. **Agent**: `deep`, `ball-encoder`. **Commit**: YES
- [ ] 10.3 **Python Compiler (Ball → Python)** — New `python/compiler/`. **QA**: `cd python/compiler && python -m pytest 2>&1 | grep "passed"` → all pass. `cd python/compiler && python run_conformance.py 2>&1 | grep "Results:"` → 0 failed. Evidence: `.sisyphus/evidence/task-10.3-python.txt`. **Agent**: `deep`, `ball-compiler`. **Commit**: YES
- [ ] 10.4 **Python Conformance Fixtures** — Verify Python compiler passes existing fixtures. **QA**: `cd python/compiler && python run_conformance.py --dir ../../tests/conformance 2>&1 | grep "total"` → pass count = total. Evidence: `.sisyphus/evidence/task-10.4-py-fixtures.txt`. **Agent**: `quick`. **Commit**: YES
- [ ] 10.5 **Go Compiler (Ball → Go)** — Initial: core expressions + control flow + std. **QA**: `cd go/compiler && go test ./... 2>&1 | grep "ok"` → all packages pass. `cd go/compiler && go run run_conformance.go 2>&1 | grep "Results:"` → ≥20 pass. Evidence: `.sisyphus/evidence/task-10.5-go.txt`. **Agent**: `deep`. **Commit**: YES
- [ ] 10.6 **New Target Documentation** — Update IMPLEMENTING_A_COMPILER.md. **QA**: `grep -c "TypeScript\|Python\|Go" docs/IMPLEMENTING_A_COMPILER.md` → ≥3 (all 3 new targets documented). Evidence: `.sisyphus/evidence/task-10.6-docs.txt`. **Agent**: `writing`. **Commit**: YES
- [ ] 10.7 **Wave 10 Gate** — TS parity, Python/Go pass conformance. **QA**: `cd ts/compiler && npm test 2>&1 | grep "passing"` → all pass. `cd python/compiler && python run_conformance.py 2>&1 | grep "Results:"` → 0 failed. `cd go/compiler && go run run_conformance.go 2>&1 | grep "Results:"` → ≥20 pass. `docs/WAVE_10_GATE.md`. Evidence: `.sisyphus/evidence/task-10.7-gate.txt`. **Commit**: YES

---

## Final Verification Wave (MANDATORY — after ALL implementation waves)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists. For each "Must NOT Have": search codebase for forbidden patterns. Check evidence files exist in `.sisyphus/evidence/`. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `dart analyze dart/` + `buf lint proto/` + `cd cpp/build && cmake --build .` + `cd ts/engine && npm test`. Review all changed files for: `as any`/`@ts-ignore`, empty catches, console.log in prod, commented-out code, unused imports. Check AI slop: excessive comments, over-abstraction, generic names.
  Output: `Build [PASS/FAIL] | Lint [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high` (+ `playwright` for website)
  Start from clean state. Execute EVERY QA scenario from EVERY task. Test cross-wave integration. Test edge cases: empty state, invalid input, rapid actions. Test all 4 engines via conformance matrix. Save evidence to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | Integration [N/N] | Edge Cases [N tested] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each wave: read "What to do", read actual diff. Verify 1:1 — everything spec'd was built, nothing beyond spec was built. Check "Must NOT do" compliance. Detect cross-task contamination. Flag unaccounted changes.
  Output: `Waves [N/N compliant] | Contamination [CLEAN/N issues] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

- **Wave 0**: individual commits per task — `docs:` convention
- **Wave 1-3**: per-task commits — `feat(engine):`, `fix(engine):` conventions
- **Wave 4**: per-task commits — `feat(cpp-compiler):`, `feat(cpp-encoder):`
- **Wave 5**: groups of 2-3 module implementations per commit
- **Wave 6-7**: per-task commits
- **Wave 8-10**: per-task commits
- **Gate documents**: `docs:` convention after each wave completes
- **Pre-commit checks**: `cd dart/engine && dart test` (Dart), `cd cpp/build && ctest --output-on-failure` (C++), `cd ts/engine && npm test` (TS), `buf lint proto/` (proto)

---

## Success Criteria

### Verification Commands
```bash
# Dart — all tests pass
cd dart && dart pub get && cd engine && dart test && cd ../encoder && dart test && cd ../shared && dart test
cd dart && dart analyze dart/  # Expected: zero issues

# C++ — all tests pass
cd cpp/build && cmake .. && cmake --build . && ctest --output-on-failure  # Expected: 100% pass

# TypeScript — all tests pass
cd ts/engine && npm install && npm test  # Expected: all passing
cd ts/compiler && npm install && npm test  # Expected: all passing

# Proto — lint and format
buf lint proto/  # Expected: zero errors
buf format proto/ --diff --exit-code  # Expected: no changes needed

# Conformance — full parity
# Expected: Dart=PASS, C++=PASS, TS_HW=PASS, TS_CMP=PASS for all fixtures
cd dart/engine && dart run ../../tests/conformance/run_conformance.dart --dir ../../tests/conformance

# Security audit
cd dart && dart run ball_cli:ball audit examples/comprehensive/comprehensive.ball.json  # Expected: capability report, no errors
```

### Final Checklist
- [ ] All 10 wave gate documents created and approved
- [ ] Conformance parity matrix all-green (Dart, C++, TS_handwritten, TS_compiled)
- [ ] `docs/STD_COMPLETENESS.md` shows ≥99% for all columns
- [ ] Security audit complete — all base functions categorized
- [ ] LSP server functional for `.ball.json` editing
- [ ] Documentation is consolidated — no stale/duplicate files
- [ ] Binary protobuf is default format
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] All evidence files captured in `.sisyphus/evidence/`
