# Ball Implementation Plan

**Created:** March 22, 2026  
**Last Updated:** April 1, 2026  
**Based on:** STATUS_REPORT.md + code audit + GAP_ANALYSIS.md (C++17 / Dart 3.x full coverage)  
**Structure:** 10 tiers, ordered by dependency and impact. Tiers 1-6 are the original plan; Tiers 7-10 close gaps identified in the full spec-vs-Ball analysis.  
**Design principle:** NO schema changes. Every new feature is a base function, metadata key, or module-level type definition.

> **Status Legend:** [x] = done, [-] = partially done, [ ] = not started

---

## Phase 1 — Stabilize C++ (Fix Broken, Add Tests)

**Goal:** Get the C++ implementation from prototype to reliable baseline.  
**Prerequisite for:** Everything else — can't build on a broken foundation.

### 1.1 Fix C++ Compiler String Operations

**Files:** `cpp/compiler/src/compiler.cpp`, `cpp/compiler/include/compiler.h`  
**Status Report Ref:** Bug #1 (CRITICAL)

- [x] Implement `string_split` → emit `std::string` tokenization using `std::string::find` + `substr` loop, return `std::vector<std::string>`
- [x] Implement `string_replace` → emit `str.replace(str.find(from), from.length(), to)` with single-occurrence semantics
- [x] Implement `string_replace_all` → emit a while-loop replacement or `std::regex_replace` fallback
- [x] Verify all three produce compilable C++ by testing against `all_constructs.ball.json`

### 1.2 Fix C++ Engine Bugs

**Files:** `cpp/engine/src/engine.cpp`, `cpp/engine/include/engine.h`  
**Status Report Ref:** Bugs #2, #3, #4, #9, #11

- [x] **Switch case matching (Bug #2):** Replace string coercion with type-aware comparison — compare `int64_t` to `int64_t`, `std::string` to `std::string`, etc. before falling back to string
- [x] **Compound assignment (Bug #9):** Implement all compound ops in `apply_compound_op()`: `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, `??=`
- [-] **Labeled break/continue (Bug #11):** Add label-matching in the FlowSignal propagation loop — when a `break`/`continue` signal carries a label, only stop at the matching labeled statement
- [x] **Configurable memory (Bug #4):** Replace hardcoded 65KB with environment variable `BALL_MEMORY_SIZE` defaulting to 256KB

### 1.3 Create C++ Test Suite

**New files:** `cpp/test/CMakeLists.txt`, `cpp/test/test_engine.cpp`, `cpp/test/test_compiler.cpp`  
**Status Report Ref:** C++ Test Coverage = 0/10

- [x] Choose test framework: simple `assert`-based main() (no external deps) or integrate Catch2 via FetchContent
- [ ] **Engine tests (minimum 30):**
  - [ ] Literals: int, double, string, bool (4 tests)
  - [ ] Arithmetic: add, subtract, multiply, divide, modulo, negate (6)
  - [ ] Comparison: equals, not_equals, less_than, greater_than, lte, gte (6)
  - [ ] Logic: and, or, not with short-circuit (3)
  - [ ] Strings: length, substring, trim, to_upper, to_lower, split, replace (7)
  - [ ] Control flow: if/else, for, while, do_while, break, continue (6)
  - [ ] Scoping: let bindings, nested scopes, closures (3)
  - [ ] Error handling: undefined variable, division by zero (2)
- [ ] **Compiler tests (minimum 20):**
  - [ ] Verify hello_world.ball.json compiles to valid C++ (1)
  - [ ] Verify fibonacci.ball.json compiles and runs correctly (1)
  - [ ] Verify each expression type generates valid C++ (7)
  - [ ] Verify each fixed string op generates valid C++ (3)
  - [ ] Verify control flow generates correct structure (4)
  - [ ] Verify type/class emission (4)
- [ ] Add test target to `cpp/CMakeLists.txt`
- [ ] Document test commands in `cpp/AGENTS.md`

### 1.4 Complete C++ Switch Compilation ✅

**Files:** `cpp/compiler/src/compiler.cpp`  
**Status Report Ref:** Missing Feature — Switch statement compilation stubbed

- [x] Parse `switch` input fields: `value`, `cases` (list of case expressions + bodies), `default`
- [x] Emit `switch (value) { case X: { body; break; } ... default: { body; } }`
- [x] Handle fall-through control (default: break after each case unless metadata says otherwise)
- [ ] Add compiler test for switch with 3+ cases + default

### 1.5 Complete C++ Try-Catch Compilation ✅

**Files:** `cpp/compiler/src/compiler.cpp`  
**Status Report Ref:** Bug #7

- [x] Emit `try { body } catch (const std::exception& e) { catch_body }` with proper variable binding
- [-] Support multiple catch blocks if the Ball program specifies them
- [ ] Emit `finally` block as code after try-catch (C++ has no `finally` — emit cleanup code unconditionally)
- [ ] Add compiler test for try-catch-finally

### 1.6 Add C++ For-In Loop Support

**Files:** `cpp/compiler/src/compiler.cpp`  
**Status Report Ref:** Missing Feature — for_in not in compiler

- [ ] Parse `for_in` input fields: `variable`, `iterable`, `body`
- [ ] Emit `for (auto& variable : iterable) { body }`
- [ ] Add compiler + engine test

---

## Phase 2 — Complete C++ Standard Library

**Goal:** Fill all stub implementations so C++ programs don't crash on collection/IO operations.  
**Prerequisite for:** Cross-language conformance testing.

### 2.1 Implement std_collections in C++ Engine

**Files:** `cpp/engine/src/engine.cpp`, `cpp/shared/src/ball_shared.cpp`  
**Status Report Ref:** Bug #3, Missing Feature — std_collections stubs

List operations (connect dispatch table to implementations):
- [ ] `list_push` — `vec.push_back(value)`
- [ ] `list_pop` — `vec.pop_back(); return last`
- [ ] `list_insert` — `vec.insert(vec.begin() + index, value)`
- [ ] `list_remove_at` — `vec.erase(vec.begin() + index)`
- [ ] `list_get` — `vec.at(index)`
- [ ] `list_set` — `vec[index] = value`
- [ ] `list_length` — `vec.size()`
- [ ] `list_is_empty` — `vec.empty()`
- [ ] `list_first` / `list_last` / `list_single`
- [ ] `list_contains` — linear scan with equality
- [ ] `list_index_of` — linear scan returning index
- [ ] `list_map` — iterate, apply BallFunction to each, return new list
- [ ] `list_filter` — iterate, apply predicate, return matching
- [ ] `list_reduce` — accumulate with BallFunction
- [ ] `list_find` / `list_any` / `list_all` / `list_none`
- [ ] `list_sort` / `list_sort_by` / `list_reverse`
- [ ] `list_slice` / `list_take` / `list_drop` / `list_concat`
- [ ] `list_flat_map` / `list_zip`
- [ ] `string_join` — join list of strings with separator

Map operations:
- [ ] `map_get` / `map_set` / `map_delete`
- [ ] `map_contains_key` / `map_keys` / `map_values` / `map_entries`
- [ ] `map_from_entries` / `map_merge`
- [ ] `map_map` / `map_filter`
- [ ] `map_is_empty` / `map_length`

- [ ] Add engine tests for each implemented function (at least 1 per function)

### 2.2 Implement std_io in C++ Engine

**Files:** `cpp/engine/src/engine.cpp`, `cpp/shared/src/ball_shared.cpp`  
**Status Report Ref:** Missing Feature — std_io stubs

- [ ] `print_error` → `std::cerr << message << std::endl`
- [ ] `read_line` → `std::string line; std::getline(std::cin, line); return line`
- [ ] `exit` → `std::exit(code)`
- [ ] `panic` → `std::cerr << message; std::exit(1)`
- [ ] `sleep_ms` → `std::this_thread::sleep_for(std::chrono::milliseconds(ms))`
- [ ] `timestamp_ms` → `std::chrono::system_clock::now()` epoch millis
- [ ] `random_int` → `std::uniform_int_distribution<int64_t>`
- [ ] `random_double` → `std::uniform_real_distribution<double>`
- [ ] `env_get` → `std::getenv(name)`
- [ ] `args_get` → requires passing `argc`/`argv` into engine (design decision)
- [ ] Add engine tests for non-interactive functions (timestamp, random, env_get)

### 2.3 C++ Compiler: Emit Code for Collections/IO

**Files:** `cpp/compiler/src/compiler.cpp`

- [ ] Map collection base function calls to C++ STL equivalents
- [ ] Map IO base function calls to iostream/stdlib equivalents
- [ ] Ensure the compiler emits necessary `#include` directives (`<vector>`, `<map>`, `<iostream>`, `<cstdlib>`, `<thread>`, `<chrono>`, `<random>`)

---

## Phase 3 — Harden Dart Implementation

**Goal:** Fix silent failures, add missing CLI, improve error reporting.

### 3.1 Fix Dart Encoder Metadata Handling ✅

**Files:** `dart/encoder/lib/encoder.dart`  
**Status Report Ref:** Bug #5

- [x] Audit all `?? ''` and `?? []` fallbacks in the encoder
- [x] Add `strict` mode parameter to `DartEncoder` constructor
- [x] In strict mode: throw `EncoderError` with source location when metadata is malformed
- [x] In permissive mode (default): keep current behavior + emit warnings to a `List<String> warnings` field
- [ ] Add tests for both modes with intentionally malformed input

### 3.2 Fix Dart Engine Collection Operations ✅

**Files:** `dart/engine/lib/engine.dart`  
**Status Report Ref:** Bug #6

- [x] Implement `collection_if` — evaluate condition, include element if true
- [x] Implement `collection_for` — iterate, evaluate body for each, collect results
- [x] Add engine tests for both with simple and nested cases

### 3.3 Unify Dart CLI ✅

**Files:** `dart/cli/bin/ball.dart`, `dart/cli/pubspec.yaml`  
**Status Report Ref:** Missing Feature — CLI only has info/validate/version

- [x] Add `ball compile <input.ball.json> [--output <file>] [--format json|binary]` command
- [x] Add `ball encode <input.dart> [--output <file>] [--format json|binary]` command
- [x] Add `ball run <input.ball.json>` command
- [x] Add dependencies: `ball_compiler`, `ball_encoder`, `ball_engine` to cli pubspec
- [x] Add `--help` with examples for each command
- [ ] Add `ball round-trip <input.dart>` command — encode → compile → diff (nice-to-have)

### 3.4 Dart Engine: Basic Async Support

**Files:** `dart/engine/lib/engine.dart`  
**Status Report Ref:** Bug #10, Missing Feature — async pass-through

- [ ] Define `BallFuture` wrapper type in engine (wraps a completed value or a pending computation)
- [ ] Implement `await` — if value is `BallFuture`, unwrap it; otherwise return as-is
- [ ] Implement `async` functions — wrap return value in `BallFuture`
- [ ] This enables synchronous execution of "async" programs (which is valid for a tree-walking interpreter where all IO is mocked)
- [ ] Add engine tests for async function → await → use result

### 3.5 Dart Encoder: Part/Part-Of Directives ✅

**Files:** `dart/encoder/lib/encoder.dart`, `dart/encoder/lib/package_encoder.dart`  
**Status Report Ref:** Missing Feature — part directive not handled

- [x] When encountering `part 'file.dart'`, resolve the path and inline the declarations into the current module
- [x] When encountering `part of`, skip (the owning library handles inclusion)
- [ ] Add test with a two-file Dart library using `part`

---

## Phase 4 — Standard Library & Schema Evolution

**Goal:** Fill universal gaps that affect all implementations.

### 4.1 Add Regex Base Functions to std ✅

**Files:** `dart/shared/lib/std.dart`, `dart/compiler/lib/compiler.dart`, `dart/engine/lib/engine.dart`, `cpp/compiler/src/compiler.cpp`, `cpp/engine/src/engine.cpp`  
**Status Report Ref:** Missing Feature — regex missing, Schema Improvement — regex base functions

- [x] Define in `dart/shared/lib/std.dart`:
  - `regex_match(pattern, input)` → bool
  - `regex_find(pattern, input)` → string (first match) or null
  - `regex_find_all(pattern, input)` → list of strings
  - `regex_replace(pattern, input, replacement)` → string
  - `regex_replace_all(pattern, input, replacement)` → string
- [x] Regenerate `std.json` / `std.bin`
- [x] Implement in Dart engine using `RegExp`
- [-] Implement in Dart compiler (emit `RegExp` calls)
- [ ] Implement in C++ engine using `<regex>`
- [ ] Implement in C++ compiler (emit `std::regex` calls)
- [ ] Add tests in both Dart and C++

### 4.2 Add Universal Set Operations to std_collections

**Files:** `dart/shared/lib/std_collections.dart` + all compilers/engines  
**Status Report Ref:** Missing Feature — set Dart-only, Schema Improvement — universal set type

- [ ] Move `set_create` from `dart_std` to `std_collections`
- [ ] Add functions:
  - `set_add`, `set_remove`, `set_contains`
  - `set_union`, `set_intersection`, `set_difference`
  - `set_length`, `set_is_empty`, `set_to_list`
- [ ] Regenerate std modules
- [ ] Implement in Dart engine and compiler
- [ ] Implement in C++ engine (using `std::set<BallValue>` — requires comparator) and compiler
- [ ] Add tests

### 4.3 Typed Exception Support ✅

**Files:** `dart/engine/lib/engine.dart`, `cpp/engine/src/engine.cpp`  
**Status Report Ref:** Missing Feature — string-based exceptions, Schema Improvement — typed exceptions

- [x] In Dart engine: when catching, preserve the thrown object's type (not just `.toString()`)
- [-] In Dart engine: support `on TypeError catch (e)` style — match exception type against catch clause type
- [x] In C++ engine: wrap thrown values as `struct BallException { std::string type; BallValue value; }` instead of plain `std::exception`
- [x] In C++ engine: match catch clause against exception type string
- [ ] Update `docs/IMPLEMENTING_A_COMPILER.md` with typed exception guidance
- [ ] Add tests for typed catch in both engines

### 4.4 Evaluate Multi-Return / Destructuring ✅

**Status Report Ref:** Schema Improvement — multi-return support

- [x] Research: how do Go, Python, Rust represent multi-return in their encoders?
- [x] Decision: add `output_params` metadata key (Go/Python tuple returns) vs. schema-level `MultiReturn` message
- [x] Recommendation: metadata approach (cosmetic, not semantic) — `output_params: [{name: "err"}, {name: "value"}]` on FunctionDefinition
- [x] Document in `docs/METADATA_SPEC.md`
- [x] No schema change needed if metadata approach is chosen

---

## Phase 5 — Infrastructure & Tooling

**Goal:** Prevent regressions, enable collaboration, prepare for more languages.

### 5.1 Set Up CI/CD Pipeline ✅

**New file:** `.github/workflows/ci.yml`  
**Status Report Ref:** Bug #15, Project Improvement — CI/CD

- [x] **Dart job:**
  - Install Dart SDK 3.9+
  - `cd dart && dart pub get`
  - `cd dart/engine && dart test`
  - `dart analyze dart/`
- [x] **C++ job:**
  - Install CMake, protobuf, nlohmann-json
  - `cd cpp/build && cmake .. && cmake --build .`
  - Run C++ tests (once test suite exists from Phase 1)
- [x] **Proto job:**
  - Install Buf CLI
  - `buf lint`
  - `buf breaking --against ".git#subdir=proto"` (on PRs)
- [x] Trigger on push to main and on PRs
- [x] Badge in README.md

### 5.2 Cross-Language Conformance Test Suite ✅

**New directory:** `tests/conformance/`  
**Status Report Ref:** Project Improvement — cross-language conformance tests

- [x] Create 20 Ball program JSON files that test specific features
- [x] For each, define `expected_output.txt` with exact stdout lines
- [x] Create Dart test runner (`dart/engine/test/conformance_test.dart`)
- [ ] Create runner for C++ engine
- [ ] Report pass/fail matrix per language per test
- [x] Integrate into CI

### 5.3 Validate C++ Build on Windows

**Status Report Ref:** Bug #12

- [ ] Add Windows CI job using MSVC
- [ ] Fix any POSIX-specific stack size options in CMakeLists.txt for MSVC
- [ ] Test all 4 targets compile on Windows
- [ ] Document Windows build prerequisites

### 5.4 Improve Dart Format Success Rate

**Status Report Ref:** Bug #14

- [ ] Investigate why 964/965 FFmpeg-compiled Dart files fail formatting
- [ ] Hypothesis: deeply nested expressions exceed dart_style's line-length heuristics
- [ ] Add `--no-format` flag to compiler for intentional skip
- [ ] Consider: post-process output to break long lines before formatting
- [ ] Track format success rate in CI as a metric (not a gate)

### 5.5 Standard Library Completeness Tracker

**New file:** `docs/STD_COMPLETENESS.md`  
**Status Report Ref:** Project Improvement — completeness tracker

- [ ] Create markdown table with all ~120 std functions as rows
- [ ] Columns: Dart Compiler, Dart Engine, C++ Compiler, C++ Engine
- [ ] Mark each cell: ✅ implemented, ⚠️ partial, ❌ missing
- [ ] Keep updated when new functions are added or stubs are filled
- [ ] Eventually: auto-generate from code (grep for dispatch table entries)

---

## Phase 6 — Expansion (New Languages & Advanced Features)

**Goal:** Begin cross-language adoption; tackle advanced features.  
**Prerequisite:** Phases 1-5 complete (stable C++, hardened Dart, CI, conformance tests).

### 6.1 TypeScript Compiler (Ball → TypeScript)

**New directory:** `ts/compiler/`  
**Rationale:** Large community, proto bindings already exist, similar to Dart in syntax

- [ ] Set up Node.js project with protobuf-ts dependency
- [ ] Implement `TsCompiler.compile(Program)` following `IMPLEMENTING_A_COMPILER.md`
- [ ] Start with: literals, references, calls, message creation, field access, blocks
- [ ] Add base function dispatch for std (arithmetic, comparison, logic, strings)
- [ ] Add control flow (if, for, while) with lazy evaluation
- [ ] Add type emission (interfaces for Ball types, classes for full types)
- [ ] Pass all 20 conformance tests
- [ ] Add to CI

### 6.2 Python Compiler (Ball → Python)

**New directory:** `python/compiler/`  
**Rationale:** Large community, proto bindings exist, good test target for multi-return

- [ ] Set up Python project with protobuf dependency
- [ ] Implement `PythonCompiler.compile(Program)` following guide
- [ ] Expression compilation, base function dispatch
- [ ] Type emission (dataclasses for Ball types)
- [ ] Pass all 20 conformance tests
- [ ] Add to CI

### 6.3 Advanced Schema Features

Only after conformance suite validates cross-language correctness:

- [ ] **Async execution model:** Design Ball-level async (this is a research task — needs an RFC document)
- [ ] **Pattern matching:** Evaluate whether switch_expr + metadata covers enough, or if a new expression variant is needed
- [ ] **Module versioning protocol:** Define resolution algorithm for `ModuleImport` integrity + version
- [ ] **Error recovery specification:** Document how compilers should handle unknown expressions (emit comment? throw? skip?)

### 6.4 Tooling

- [ ] **Documentation site:** Set up with GitHub Pages (Docusaurus/MkDocs) pulling from `docs/`
- [ ] **Language server (LSP):** Ball JSON validation, completion for function/type names, hover for docs
- [ ] **Package registry:** Define discovery protocol using `ModuleImport` HTTP/Git sources
- [ ] **Binary protobuf as default:** Update all examples and tools to use `.ball.pb` as primary format with JSON as human-readable alternative

---

## Dependency Graph

```
Phase 1 (Stabilize C++)
    ├── 1.1 Fix string ops
    ├── 1.2 Fix engine bugs
    ├── 1.3 Create test suite ←── depends on 1.1, 1.2
    ├── 1.4 Switch compilation
    ├── 1.5 Try-catch compilation
    └── 1.6 For-in loops

Phase 2 (Complete C++ StdLib) ←── depends on Phase 1
    ├── 2.1 std_collections
    ├── 2.2 std_io
    └── 2.3 Compiler emission

Phase 3 (Harden Dart) ←── independent of Phase 1-2
    ├── 3.1 Encoder strict mode
    ├── 3.2 Collection operations
    ├── 3.3 Unify CLI
    ├── 3.4 Basic async
    └── 3.5 Part directives

Phase 4 (Std Library Evolution) ←── depends on Phase 2, 3
    ├── 4.1 Regex
    ├── 4.2 Sets
    ├── 4.3 Typed exceptions
    └── 4.4 Multi-return (research)

Phase 5 (Infrastructure) ←── depends on Phase 1.3
    ├── 5.1 CI/CD
    ├── 5.2 Conformance tests ←── depends on Phase 2
    ├── 5.3 Windows validation
    ├── 5.4 Format rate
    └── 5.5 Completeness tracker

Phase 6 (Expansion) ←── depends on Phase 5.2
    ├── 6.1 TypeScript compiler
    ├── 6.2 Python compiler
    ├── 6.3 Advanced schema
    └── 6.4 Tooling
```

## Notes

- **Phase 3 is independent** — Dart hardening can happen in parallel with C++ stabilization
- **Phase 5.1 (CI) should start early** — even a basic Dart-only CI pipeline prevents regressions during all other phases
- **Conformance tests (5.2) are the gate** for starting new language implementations — without them, there's no way to verify correctness across languages
- Every task above includes a testing component — no untested code should be merged

---

# GAP-CLOSURE TIERS (from GAP_ANALYSIS.md)

> **Design principle:** Every gap is resolved with base functions + metadata + module types.  
> No proto schema changes. Preprocessor, goto, RAII — all become function calls.

---

## Tier 7 — Runtime Correctness (HIGH IMPACT)

**Goal:** Make the engines actually execute programs correctly, not just parse them.  
**Unlocks:** Running real-world programs, not just toy examples.  
**Parallel:** Dart and C++ tracks can run simultaneously.

### 7.1 Object System & Inheritance Runtime

**Problem:** Engines create flat Maps for objects. No inheritance chain, no virtual dispatch, no super.  
**Affects:** Both C++ and Dart — any program using classes is semantically broken in the engine.

**Dart Engine (`dart/engine/lib/engine.dart`):**
- [ ] Define `BallObject` type: `{__type__: String, __super__: BallObject?, __fields__: Map, __methods__: Map<String, FunctionDefinition>}`
- [ ] On MessageCreation with a TypeDefinition: build `BallObject` with `__type__` set, fields initialized, methods resolved from module
- [ ] On FieldAccess: check `__fields__` first, then walk `__super__` chain
- [ ] On method call: look up `__methods__` on object, walk `__super__` if not found (virtual dispatch)
- [ ] Add `super` reference in constructor scope: binds to `__super__` object
- [ ] Tests: class with superclass, override method, super call, field access through chain

**C++ Engine (`cpp/engine/src/engine.cpp`):**
- [ ] Mirror Dart engine's BallObject design using `struct BallObject { string type; shared_ptr<BallObject> super_; map<string, BallValue> fields; map<string, FunctionDef> methods; }`
- [ ] Same dispatch logic: field lookup → super chain, method lookup → super chain
- [ ] Tests: same cases as Dart

### 7.2 Async/Await Execution

**Problem:** `async`/`await`/`yield` are no-ops. Any program using Futures or generators doesn't execute.  
**Affects:** Dart (critical — most Dart programs use async), C++ (less critical but coroutines exist).

**Approach:** Synchronous simulation — `await` unwraps completed values, `async` wraps returns.

**Dart Engine:**
- [ ] Define `BallFuture` wrapper: `{__ball_future__: true, value: dynamic, completed: bool}`
- [ ] `std.await`: if value is `BallFuture`, return `.value`; else return value as-is
- [ ] `async` function execution: wrap return value in `BallFuture(value: result, completed: true)`
- [ ] This is sufficient for synchronous simulation of async programs (which is valid for an interpreter where all I/O is synchronous)
- [ ] Tests: `async` function returning value, `await` consuming it, chained awaits

**Dart Engine — Generators:**
- [ ] Define `BallGenerator` wrapper: `{__ball_generator__: true, values: List}`
- [ ] `std.yield`: append value to generator's `values` list
- [ ] `dart_std.yield_each`: append all values from iterable
- [ ] `sync*` function: collect yielded values, return them as list
- [ ] Tests: `sync*` function yielding 3 values, `yield*` forwarding

**C++ Engine:**
- [ ] Mirror the BallFuture/BallGenerator wrappers
- [ ] Same execution semantics

### 7.3 Pattern Matching Semantics

**Problem:** Dart 3 patterns stored as strings in metadata but never interpreted. `switch_expr` does basic value matching only.  
**Affects:** Dart — pattern matching is core to Dart 3+ code.

**Dart Engine:**
- [ ] Parse pattern strings into a `BallPattern` ADT: `ConstPattern | VarPattern | TypeTestPattern | ListPattern | MapPattern | RecordPattern | ObjectPattern | LogicalAndPattern | LogicalOrPattern | RelationalPattern | WildcardPattern | CastPattern`
- [ ] Implement `matchPattern(BallPattern pattern, dynamic value, Scope scope) → bool` with destructuring side effects (binds variables in scope)
- [ ] Wire into `switch_expr` and `if-case` evaluation
- [ ] Tests: `if (x case int y)`, `switch (obj) { Point(x: var a) => a }`, list destructuring `[a, b, ...rest]`

### 7.4 Reified Generics (Basic)

**Problem:** Type parameters erased at runtime. `is` checks against generic types don't work.  
**Affects:** Both — programs using `List<int>` type checks fail.

**Dart Engine:**
- [ ] Track type arguments on BallObject: `__type_args__: List<String>`
- [ ] On `std.is` with generic type like `List<int>`: check container type + element types
- [ ] On `collection_if`/`collection_for`: propagate type info through collection operations
- [ ] Tests: `x is List<int>`, `x is Map<String, int>`

---

## Tier 8 — Missing Base Functions & Modules (MEDIUM IMPACT)

**Goal:** Add base functions for language features currently not representable.  
**Design:** Every new feature = new base function in the appropriate module. No schema changes.

### 8.1 `cpp_std` Module — Move to Shared Definition

**Problem:** `cpp_std` is only defined in the C++ encoder. Needs to be a proper shared module like `dart_std`.

**Files:** Create `dart/shared/lib/cpp_std.dart` or add to `dart/shared/lib/std.dart`

Functions already exist (from encoder):
- [x] `cpp_new`, `cpp_delete` — heap allocation
- [x] `cpp_sizeof`, `cpp_alignof` — size/alignment queries
- [x] `ptr_cast` — static/dynamic/reinterpret/const cast
- [x] `arrow` — pointer member access (`->`)
- [x] `deref` — pointer dereference
- [x] `address_of` — take address
- [x] `init_list` — initializer list
- [x] `nullptr` — null pointer constant

Functions to add:
- [ ] `cpp_move(UnaryInput)` → Move semantics: `std::move(value)`. Metadata: `is_rvalue: true`
- [ ] `cpp_forward(UnaryInput)` → Perfect forwarding: `std::forward<T>(value)`. Metadata: `type_param`
- [ ] `cpp_make_unique(InvokeInput)` → `std::make_unique<T>(args...)`
- [ ] `cpp_make_shared(InvokeInput)` → `std::make_shared<T>(args...)`
- [ ] `cpp_unique_ptr_get(UnaryInput)` → `ptr.get()`
- [ ] `cpp_shared_ptr_get(UnaryInput)` → `ptr.get()`
- [ ] `cpp_shared_ptr_use_count(UnaryInput)` → `ptr.use_count()`
- [ ] `cpp_static_assert(AssertInput)` → `static_assert(cond, msg)`
- [ ] `cpp_decltype(UnaryInput)` → `decltype(expr)` — metadata-only, compiler emits type
- [ ] `cpp_auto(UnaryInput)` → `auto x = expr` — metadata-only, compiler emits `auto`
- [ ] `cpp_structured_binding(StructuredBindingInput)` → `auto [a, b, c] = expr`. New input type: `{names: List<string>, value: Expression}`
- [ ] `cpp_template_instantiate(TemplateInstInput)` → Explicit template instantiation. Input: `{template_name, type_args: List<string>}`

### 8.2 `goto` and Labels as Base Functions

**Problem:** C++ has `goto` + labels. Ball doesn't support it.  
**Design:** `goto` is a control flow base function, same as `if`/`for`/`while`.

**New functions in `std` module:**
- [ ] `goto(GotoInput) → void` — Jump to label. Input type: `GotoInput{label: string}`
- [ ] `label(LabelInput) → void` — Define a label point. Input type: `LabelInput{name: string, body: Expression}`

**Compiler emission:**
- [ ] Dart compiler: emit comment `/* goto not supported in Dart */` or throw
- [ ] C++ compiler: emit `goto label_name;` and `label_name: { body }`
- [ ] Engine: implement goto via FlowSignal (similar to break with label, but jumps forward/backward)

**Engine implementation (both Dart and C++):**
- [ ] `std.label`: register label name in scope with its body expression and position marker
- [ ] `std.goto`: emit FlowSignal with `type: GOTO, label: name`, caught by nearest enclosing label handler
- [ ] For forward gotos: label handler skips to labeled body; for backward gotos: label handler re-evaluates from labeled point

### 8.3 Preprocessor Directives as Base Functions / Metadata

**Problem:** C++ uses `#define`, `#include`, `#ifdef`, etc. Ball has no preprocessor.  
**Design:** Preprocessor directives are metadata + base functions in `cpp_std`. Macros are expanded before encoding.

**Approach — two layers:**

**Layer 1: Metadata capture (round-trip fidelity):**
- [ ] `Module.metadata.cpp_defines: [{name, value?, params?}]` — `#define` directives
- [ ] `Module.metadata.cpp_ifdefs: [{condition, body_module}]` — Conditional compilation blocks
- [ ] `Module.metadata.cpp_pragmas: [string]` — `#pragma` directives
- [ ] These are cosmetic — stripping them doesn't change the program's semantics (macros already expanded by Clang before the encoder sees them)

**Layer 2: Base functions for runtime conditional compilation:**
- [ ] `cpp_ifdef(IfdefInput) → Expression` — Input: `{symbol: string, then: Expression, else: Expression}`. Compiler emits `#ifdef SYMBOL ... #else ... #endif`
- [ ] `cpp_defined(UnaryInput) → bool` — Compiler emits `defined(MACRO_NAME)`
- [ ] These let the Ball program represent conditional compilation for codegen purposes

**C++ Encoder changes:**
- [ ] When Clang AST contains `#define` info (from -E or preprocessor output), store in module metadata
- [ ] Macro bodies: store as metadata strings, not as Ball expressions (macros are text substitution, not semantic)

### 8.4 RAII & Destructors as Base Functions

**Problem:** C++ RAII pattern (constructor acquires, destructor releases) not modeled.  
**Design:** Destructor is already metadata (`annotations: [destructor]`). Add scope-exit base function.

**New function in `cpp_std`:**
- [ ] `cpp_scope_exit(UnaryInput) → void` — Register a cleanup expression to run when scope exits. Compiler emits `struct _Guard { ~_Guard() { cleanup; } } _guard;`
- [ ] `cpp_destructor(UnaryInput) → void` — Mark a function as destructor. Metadata: `{class_name: string}`

**Engine implementation:**
- [ ] Scope tracks list of `scope_exit` cleanup expressions
- [ ] On scope exit (block end, function return, exception), execute cleanups in LIFO order
- [ ] This faithfully simulates RAII without requiring C++ destructor semantics

### 8.5 C++ Concurrency Primitives (Base Functions)

**Problem:** No threading, atomics, or synchronization primitives.  
**Design:** Base functions in new `std_concurrency` module. Engines can choose single-threaded simulation or real threading.

**New module: `std_concurrency`**

Input types:
- [ ] `ThreadInput{body: Expression}` — Thread entry point
- [ ] `MutexInput{}` — Mutex handle
- [ ] `LockInput{mutex: Expression, body: Expression}` — Scoped lock
- [ ] `AtomicInput{value: Expression}` — Atomic value
- [ ] `AtomicOpInput{atomic: Expression, op: string, value: Expression}` — Atomic operation

Functions:
- [ ] `thread_spawn(ThreadInput) → (result: int)` — Create thread, return handle
- [ ] `thread_join(UnaryInput) → void` — Wait for thread completion
- [ ] `mutex_create(MutexInput) → (result: int)` — Create mutex handle
- [ ] `mutex_lock(UnaryInput) → void` — Acquire mutex
- [ ] `mutex_unlock(UnaryInput) → void` — Release mutex
- [ ] `scoped_lock(LockInput) → (result)` — RAII lock + execute body
- [ ] `atomic_load(UnaryInput) → (result)` — Atomic read
- [ ] `atomic_store(AtomicOpInput) → void` — Atomic write
- [ ] `atomic_compare_exchange(AtomicOpInput) → (result: bool)` — CAS

**Engine implementation (both):**
- [ ] Single-threaded simulation: `thread_spawn` runs body synchronously, returns immediately
- [ ] `mutex` operations are no-ops in single-threaded mode
- [ ] Correctly simulates sequential behavior of concurrent programs

**Compiler emission:**
- [ ] C++: `std::thread`, `std::mutex`, `std::lock_guard`, `std::atomic`
- [ ] Dart: `Isolate.spawn`, or `compute()`, or comment stubs

### 8.6 Dart-Specific Missing Base Functions

**New functions in `dart_std`:**

- [ ] `dart_await_for(ForInInput) → void` — `await for (var x in stream) { body }`. Metadata: `is_await: true`
- [ ] `dart_stream_yield(UnaryInput) → void` — `yield` in `async*` context
- [ ] `dart_tear_off(TearOffInput) → Function` — `object.method` as callable. Input: `{target: Expression, method: string}`
- [ ] `dart_list_generate(ListGenerateInput) → List` — `List.generate(count, (i) => expr)`. Input: `{count: Expression, generator: Expression}`
- [ ] `dart_list_filled(ListFilledInput) → List` — `List.filled(count, value)`. Input: `{count: Expression, value: Expression}`
- [ ] `dart_null_aware_cascade(CascadeInput) → (result)` — `target?..a()..b()` — currently partial

### 8.7 `std_convert` Module — Serialization

**Problem:** No JSON/UTF-8 encoding/decoding in any std module.  
**Design:** New universal module for data interchange.

**New module: `std_convert`**

Input types:
- [x] `JsonEncodeInput{value: Expression, indent: Expression?}`
- [x] `JsonDecodeInput{source: Expression}`
- [x] `Utf8EncodeInput{source: Expression}`
- [x] `Utf8DecodeInput{bytes: Expression}`
- [x] `Base64EncodeInput{bytes: Expression}`
- [x] `Base64DecodeInput{source: Expression}`

Functions:
- [x] `json_encode(JsonEncodeInput) → (result: string)` — Serialize value to JSON string
- [x] `json_decode(JsonDecodeInput) → (result)` — Parse JSON string to value
- [x] `utf8_encode(Utf8EncodeInput) → (result: bytes)` — String to UTF-8 bytes
- [x] `utf8_decode(Utf8DecodeInput) → (result: string)` — UTF-8 bytes to string
- [x] `base64_encode(Base64EncodeInput) → (result: string)` — Bytes to base64
- [x] `base64_decode(Base64DecodeInput) → (result: bytes)` — Base64 to bytes

**Compiler emission:**
- [-] Dart: `dart:convert` (jsonEncode, jsonDecode, utf8, base64) — engine done, compiler TODO
- [-] C++: `nlohmann::json` (already a dependency), manual base64 — engine done, compiler TODO

### 8.8 `std_fs` Module — File I/O

**Problem:** No file read/write capability. Only stdin/stdout/stderr.

**New module: `std_fs`**

Input types:
- [x] `FilePathInput{path: Expression}`
- [x] `FileWriteInput{path: Expression, content: Expression}`
- [x] `FileAppendInput{path: Expression, content: Expression}`

Functions:
- [x] `file_read(FilePathInput) → (result: string)` — Read file as string
- [x] `file_read_bytes(FilePathInput) → (result: bytes)` — Read file as bytes
- [x] `file_write(FileWriteInput) → void` — Write string to file
- [x] `file_write_bytes(FileWriteInput) → void` — Write bytes to file
- [x] `file_append(FileAppendInput) → void` — Append to file
- [x] `file_exists(FilePathInput) → (result: bool)` — Check existence
- [x] `file_delete(FilePathInput) → void` — Delete file
- [x] `dir_list(FilePathInput) → (result: list)` — List directory contents
- [x] `dir_create(FilePathInput) → void` — Create directory
- [x] `dir_exists(FilePathInput) → (result: bool)` — Check directory existence

**Compiler emission:**
- [-] Dart: `dart:io` (File, Directory) — engine done, compiler TODO
- [-] C++: `<filesystem>` (C++17) — engine done, compiler TODO

### 8.9 `std_time` Module — Date/Time

**Problem:** Only `timestamp_ms()` and `sleep_ms()`. No DateTime, Duration, formatting.

**New module: `std_time`**

Functions:
- [x] `now() → (result: int)` — Current Unix timestamp in milliseconds (alias for `timestamp_ms`)
- [x] `now_micros() → (result: int)` — Current timestamp in microseconds
- [x] `format_timestamp(FormatInput) → (result: string)` — Format timestamp. Input: `{timestamp: int, format: string}`
- [x] `parse_timestamp(FormatInput) → (result: int)` — Parse timestamp from string
- [x] `duration_add(BinaryInput) → (result: int)` — Add two durations
- [x] `duration_subtract(BinaryInput) → (result: int)` — Subtract durations
- [x] `year/month/day/hour/minute/second() → (result: int)` — Current date/time components

---

## Tier 9 — Compiler & Encoder Completeness (MEDIUM IMPACT)

**Goal:** Close codegen gaps so compiled output covers more language features.

### 9.1 C++ Compiler — Templates as Metadata-Driven Emission

**Problem:** Template parameters stored in metadata but compiler doesn't emit `template<typename T>`.  
**Files:** `cpp/compiler/src/compiler.cpp`

- [ ] When TypeDefinition has `type_params[]`: emit `template<typename T, typename U, ...>` before struct/class
- [ ] When FunctionDefinition has `metadata.type_params[]`: emit `template<typename T>` before function
- [ ] When MessageCreation references generic type: emit `TypeName<T>` with angle brackets
- [ ] Support bounds: `type_params[].extends` → `template<typename T>` with static_assert or concept constraint comment

### 9.2 C++ Compiler — Multiple Inheritance

**Problem:** Ball's metadata.superclass is single. C++ allows multiple inheritance.  
**Design:** Use metadata `interfaces[]` for additional base classes (C++ doesn't distinguish interface from class).

- [ ] When metadata has both `superclass` AND `interfaces[]`: emit `class Derived : public Base1, public Base2, ...`
- [ ] Virtual inheritance: if metadata has `virtual_bases: [...]`, emit `class D : virtual public B`
- [ ] C++ encoder: when Clang AST shows multiple base classes, put first in `superclass`, rest in `interfaces[]`

### 9.3 C++ Compiler — Operator Overloading

**Problem:** Metadata `is_operator` exists but C++ compiler doesn't emit `ReturnType operator+(...)`.  
**Files:** `cpp/compiler/src/compiler.cpp`

- [ ] When function has `is_operator: true` + `kind: "operator"`: extract operator symbol from name
- [ ] Emit `ReturnType operator+(const InputType& input)` form
- [ ] Handle: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `[]`, `()`, `<<`, `>>`, `=`, `+=`, etc.
- [ ] Handle conversion operators: `operator Type()` from metadata

### 9.4 C++ Encoder — Better Template Handling

**Problem:** `ClassTemplateDecl` and `FunctionTemplateDecl` parsed but type params not semantically preserved.  
**Files:** `cpp/encoder/src/encoder.cpp`

- [ ] Extract template parameters from Clang AST as `TypeParameter` entries
- [ ] Store in `TypeDefinition.type_params[]` (not just metadata)
- [ ] Preserve template specialization as metadata: `specializations: [{type_args: [...], body: ...}]`
- [ ] Handle SFINAE patterns: store `enable_if` conditions as metadata annotations

### 9.5 Dart Compiler — Tear-Off Emission

**Problem:** No tear-off syntax emitted.  
**Files:** `dart/compiler/lib/compiler.dart`

- [ ] When encountering `dart_std.tear_off` call: emit `object.methodName` (without parentheses)
- [ ] For constructor tear-offs: emit `ClassName.new` or `ClassName.named`
- [ ] For static method tear-offs: emit `ClassName.staticMethod`

### 9.6 Dart Encoder — Improved Pattern Encoding

**Problem:** Patterns stored as raw source strings. No semantic structure.  
**Files:** `dart/encoder/lib/encoder.dart`

- [ ] Instead of `pattern: "int x"` (string), encode patterns as nested expressions:
  - `TypeTestPattern` → `std.is` call + `std.assign` for binding
  - `ListPattern` → `std_collections.list_get` calls for destructuring
  - `RecordPattern` → field access calls
  - `ObjectPattern` → field access on typed object
- [ ] This enables the engine to interpret patterns without parsing strings
- [ ] Backward-compatible: keep `case_pattern` string for compilers that emit source directly

### 9.7 Function Overloading Representation

**Problem:** C++ allows multiple functions with same name but different parameter types. Ball requires unique names per module.

**Design:** Name mangling convention in metadata.

- [ ] C++ encoder: mangle overloaded function names as `functionName__overload_0`, `functionName__overload_1`, etc.
- [ ] Store original name in metadata: `original_name: "functionName"`
- [ ] Store signature hash in metadata: `signature: "int,double"` (parameter types)
- [ ] C++ compiler: when emitting, use `original_name` from metadata to restore original function name
- [ ] Document convention in `docs/METADATA_SPEC.md`

---

## Tier 10 — Expansion & Advanced Features (LOWER IMPACT)

**Goal:** New language targets, advanced runtime features, and polish.

### 10.1 TypeScript Compiler

(Carried from Phase 6.1 — no changes)

### 10.2 Python Compiler

(Carried from Phase 6.2 — no changes)

### 10.3 `std_net` Module — Network I/O

**New module for HTTP/socket operations.**

Functions:
- [ ] `http_get(HttpInput) → (result: string)` — HTTP GET request
- [ ] `http_post(HttpPostInput) → (result: string)` — HTTP POST request
- [ ] `tcp_connect(TcpInput) → (result: int)` — TCP connection handle
- [ ] `tcp_send(TcpSendInput) → void` — Send data
- [ ] `tcp_receive(TcpReceiveInput) → (result: bytes)` — Receive data
- [ ] `tcp_close(UnaryInput) → void` — Close connection

### 10.4 Dart Isolate Support

**New functions in `dart_std`:**
- [ ] `dart_isolate_spawn(IsolateInput) → (result: int)` — Spawn isolate
- [ ] `dart_isolate_send(IsolateSendInput) → void` — Send message to isolate port
- [ ] `dart_isolate_receive(UnaryInput) → (result)` — Receive from port

**Engine implementation:**
- [ ] Sequential simulation: spawn runs body in fresh scope and returns, send/receive are buffered queues

### 10.5 Dart Stream Support

**New functions in `dart_std`:**
- [ ] `dart_stream_create(StreamCreateInput) → (result)` — Create StreamController
- [ ] `dart_stream_add(BinaryInput) → void` — Add event to stream
- [ ] `dart_stream_close(UnaryInput) → void` — Close stream
- [ ] `dart_stream_listen(BinaryInput) → void` — Subscribe to stream with callback

### 10.6 C++20 Concepts as Metadata

**Design:** Concepts are compile-time constraints → metadata annotations.

- [ ] Add metadata key `concept_constraints: [{concept_name, type_param, expression}]` on TypeDefinition and FunctionDefinition
- [ ] C++ compiler: emit `template<typename T> requires ConceptName<T>` when metadata present
- [ ] C++ encoder: when Clang AST has `ConceptDecl` or `RequiresExpr`, store in metadata

### 10.7 C++20 Ranges as Base Functions

**Design:** Range adaptors as base functions in `cpp_std`.

- [ ] `cpp_views_filter(ListCallbackInput) → list` — `views::filter`
- [ ] `cpp_views_transform(ListCallbackInput) → list` — `views::transform`
- [ ] `cpp_views_take(ListInput) → list` — `views::take(n)`
- [ ] `cpp_views_drop(ListInput) → list` — `views::drop(n)`
- [ ] `cpp_views_zip(ListInput) → list` — `views::zip` (C++23)
- [ ] Compiler emits: `container | views::filter(...) | views::transform(...)`

### 10.8 Advanced Schema Research (No Implementation Yet)

These require RFCs and community discussion before implementation:

- [ ] **Coroutines model:** How to represent `co_await`/`co_yield`/`co_return` — likely `cpp_std.co_await(expr)` etc.
- [ ] **Module versioning:** Resolution algorithm for `ModuleImport` integrity + version
- [ ] **Error recovery spec:** How compilers handle unknown expression variants
- [ ] **Compile-time evaluation:** Whether `constexpr` functions should be evaluable by the engine at "compile time"
- [ ] **Null safety enforcement:** Whether Ball engines should enforce nullability from metadata
- [ ] **Multiple dispatch:** Whether Ball should support dynamic multi-method dispatch (beyond virtual)

---

## Updated Dependency Graph

```
Phase 1-6 (EXISTING — mostly done)
    ├── Phase 1: Stabilize C++ [mostly ✅]
    ├── Phase 2: Complete C++ StdLib [in progress]
    ├── Phase 3: Harden Dart [mostly ✅]
    ├── Phase 4: Std Library Evolution [mostly ✅]
    ├── Phase 5: Infrastructure [mostly ✅]
    └── Phase 6: Expansion [not started]

Tier 7 (Runtime Correctness) ←── depends on Phase 1-3
    ├── 7.1 Object System & Inheritance ←── HIGH PRIORITY
    ├── 7.2 Async/Await Execution ←── HIGH PRIORITY
    ├── 7.3 Pattern Matching Semantics (Dart) ←── depends on 7.1
    └── 7.4 Reified Generics ←── depends on 7.1

Tier 8 (Missing Base Functions) ←── depends on Phase 2, partially independent
    ├── 8.1 cpp_std to shared [small, unblocks 8.2-8.5]
    ├── 8.2 goto/labels [independent]
    ├── 8.3 Preprocessor directives [independent]
    ├── 8.4 RAII/scope-exit [depends on 7.1]
    ├── 8.5 Concurrency primitives [independent]
    ├── 8.6 Dart-specific functions [independent]
    ├── 8.7 std_convert (JSON/UTF8) [independent]
    ├── 8.8 std_fs (File I/O) [independent]
    └── 8.9 std_time (Date/Time) [independent]

Tier 9 (Compiler/Encoder Completeness) ←── depends on Tier 8
    ├── 9.1 C++ templates ←── depends on 8.1
    ├── 9.2 C++ multiple inheritance ←── depends on 7.1
    ├── 9.3 C++ operator overloading [independent]
    ├── 9.4 C++ encoder templates ←── depends on 8.1
    ├── 9.5 Dart tear-offs ←── depends on 8.6
    ├── 9.6 Dart pattern encoding ←── depends on 7.3
    └── 9.7 Function overloading ←── depends on 9.1

Tier 10 (Expansion & Advanced) ←── depends on Tier 7 + Phase 5.2
    ├── 10.1 TypeScript compiler (Phase 6.1)
    ├── 10.2 Python compiler (Phase 6.2)
    ├── 10.3 std_net (networking)
    ├── 10.4 Dart isolates ←── depends on 8.5
    ├── 10.5 Dart streams ←── depends on 7.2
    ├── 10.6 C++20 concepts
    ├── 10.7 C++20 ranges
    └── 10.8 Advanced research (RFCs)
```

## Parallel Work Streams

At any given time, 3-4 streams can run independently:

| Stream | Tiers | Focus |
|--------|-------|-------|
| **Dart Runtime** | 7.1 → 7.2 → 7.3 → 7.4 | Engine execution correctness |
| **C++ Runtime** | 7.1 → 7.2 (C++ mirror) | Engine execution correctness |
| **New Base Functions** | 8.2 → 8.3 → 8.5 → 8.7 → 8.8 → 8.9 | Expanding Ball vocabulary |
| **Compiler/Encoder** | 9.1 → 9.3 → 9.4 → 9.7 | Codegen completeness |

## Coverage Targets

| Milestone | C++ Coverage | Dart Coverage |
|-----------|-------------|--------------|
| Current (Apr 2026) | ~41% | ~69% |
| After Tier 7 | ~45% | ~80% |
| After Tier 8 | ~60% | ~85% |
| After Tier 9 | ~70% | ~90% |
| After Tier 10 | ~80% | ~95% |
