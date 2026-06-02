# Plan: Eliminate Language-Specific Base Modules (`dart_std`, `cpp_std`)

**Status:** COMPLETE — dart_std eliminated, syntax expansions done, cpp_std inlined, __type_args__ migrated, Phase 3 doc cleanup done
**Priority:** High — blocks the cross-language conversion promise
**Created:** 2026-06-02

## Problem

`dart_std` and `cpp_std` are base modules with `isBase: true` functions (no body).
This means every target compiler/engine must hand-implement Dart-specific or
C++-specific idioms, which defeats Ball's cross-language portability promise.

`cpp_std` already has a normalizer pass that rewrites its functions into universal
`std`/`std_memory` equivalents, but it's a separate post-encoding step.
`dart_std` has NO normalizer — its 12 base functions leak into the final Ball
program and must be implemented by every target.

## Goal

Eliminate all language-specific base modules. The encoder for each language should
emit only universal modules (`std`, `std_collections`, `std_io`, `std_memory`, etc.).
Language-specific constructs become either:
1. Inline expression trees using `std` operations (syntax expansions)
2. Standard primitives with cosmetic metadata (representational sugar)

## Phase 1: Eliminate `dart_std` (Dart encoder changes)

### Syntax expansions (encoder emits equivalent `std` expression trees)

| dart_std function | Expansion |
|-------------------|-----------|
| `null_aware_access(target, field)` | `std.if(condition: std.is_null(target), then: null, else: FieldAccess(target, field))` |
| `null_aware_call(target, method, args)` | `std.if(condition: std.is_null(target), then: null, else: FunctionCall(target.method, args))` |
| `cascade(target, sections)` | `Block(let __cascade = target; section1(__cascade); ...; __cascade)` |
| `collection_if(cond, value)` | Expand inline during list/set/map literal encoding using `std.if` |
| `collection_for(var, iterable, body)` | Expand inline using `std_collections.list_map` or `std.for_each` + accumulator |

### Cosmetic metadata (encoder uses existing primitives + metadata)

| dart_std function | Representation |
|-------------------|---------------|
| `record(fields)` | `MessageCreation` with `metadata: {"kind": "record"}` |
| `symbol(name)` | `Literal(string)` with `metadata: {"kind": "symbol"}` |
| `type_literal(type)` | `Literal(string)` with `metadata: {"kind": "type_literal"}` |
| `typed_list(type, elements)` | `Literal(list)` with `metadata: {"element_type": "<type>"}` |
| `spread(value)` | List element with `metadata: {"spread": true}` or expand with `std_collections.list_concat` |
| `null_spread(value)` | `std.if(std.is_null(value), [], value)` + spread expansion |
| `invoke(fn, args)` | Direct `FunctionCall` expression (the function ref IS the callee) |

### Files to modify

1. **`dart/encoder/lib/encoder.dart`** — Remove `_dartStdFunctions` set. Change each
   encoding site to emit the expansion directly instead of a `dart_std.*` call.
2. **`dart/encoder/lib/encoder.dart`** — Remove `_buildDartStdModule()`.
3. **`dart/compiler/lib/compiler.dart`** — Remove all `dart_std` special-case handling
   in `_compileBaseCall`. The compiler will never see `dart_std` calls.
4. **`dart/engine/lib/engine.dart`** — Remove `dart_std` dispatch from `StdModuleHandler`.
5. **`ts/compiler/src/compiler.ts`** — Remove `dart_std` dispatch and post-processing
   injections for cascade/null_aware.
6. **`ts/engine/src/index.ts`** — Remove `dart_std` routing.
7. **`cpp/compiler/src/compiler.cpp`** — Remove `dart_std` handling in `compile_std_call`.
8. **Conformance tests** — All existing tests should still pass (behavior unchanged).
9. **`dart/self_host/engine.ball.json`** — Regenerate (the self-hosted engine uses
   dart_std internally; after re-encoding, it won't).

### Verification

- All 232 conformance tests pass on all engines (Dart, TS, C++)
- Dart encoder round-trip tests pass
- Self-hosted TS engine (227/227) still passes after regeneration
- Self-hosted C++ engine still passes after regeneration

## Phase 2: Inline `cpp_std` normalizer (C++ encoder changes)

The C++ encoder's `HybridNormalizer` already knows how to convert each `cpp_std`
operation into universal equivalents. Move this logic INTO the encoding step:

- When the encoder would emit `cpp_std.deref(ptr)`, emit the safe projection
  `Reference(ptr)` or unsafe `std_memory.memory_read(ptr)` directly.
- When the encoder would emit `cpp_std.arrow(ptr, member)`, emit
  `FieldAccess(Reference(ptr), member)` directly.
- Remove `cpp_std.cpp`, `cpp_std.h`, and the `HybridNormalizer` class.
- Remove `cpp_std` module from `build_cpp_std_module()`.

### Files to modify

1. **`cpp/encoder/src/encoder.cpp`** — Inline normalizer logic at each encoding site.
2. **`cpp/encoder/src/normalizer.cpp`** — Delete.
3. **`cpp/encoder/include/normalizer.h`** — Delete.
4. **`cpp/encoder/src/cpp_std.cpp`** — Delete.
5. **`cpp/encoder/include/cpp_std.h`** — Delete.
6. **`cpp/encoder/CMakeLists.txt`** — Remove normalizer and cpp_std sources.
7. **`cpp/compiler/src/compiler.cpp`** — Remove `cpp_std` handling (if any remains).

## Phase 3: Documentation & cleanup

1. Remove all references to `dart_std`/`cpp_std` from CLAUDE.md, AGENTS.md, rules.
2. Update `docs/METADATA_SPEC.md` with new metadata keys used for cosmetic representation.
3. Update the article to explain Ball's clean universal module design.
4. Add a "design principle" to CLAUDE.md: "Language-specific modules MUST NOT contain
   base functions. The encoder must expand language-specific constructs into universal
   `std` operations at encoding time."

## Risk

- **Cascade sections** reference `__cascade_self__` — need to ensure the block
  expansion correctly binds and references the cascade target variable.
- **Spread inside list literals** — may need `std_collections.list_concat` to work
  correctly when a spread appears mid-list.
- **collection_for** — may produce different evaluation order than Dart's collection-for.
  Need conformance tests to verify.
- **Self-hosted engine regeneration** — the engine itself uses `dart_std` internally.
  Must re-encode after the encoder changes, then recompile to TS/C++.
