# Ball Cross-Target Compilation Strategy

> Research synthesis from DDC/dart2js, Kotlin/JS, Scala.js, Haxe, KMP, Nim, LLVM,
> GraalVM Truffle, AssemblyScript, Emscripten, protobuf-es, and CrossTL.
> Covers reified generics, BigInt/int64, and cross-language gaps for future targets
> (Rust, Python, Java, Go, Ruby, C#).

## Current State (June 2026)

- **277 conformance programs** in `tests/conformance/`
- **Dart engine:** 277/277 (0 failures across compiled + roundtrip legs)
- **TS engine:** 291/291 (273 conformance + 18 unit tests, self-hosted)
- **C++ engine:** 273/273 (compiled leg in conformance matrix)
- **ball_protobuf:** 2769/2769 Dart conformance; compiles to TS (9217 lines, marshal/unmarshal proven) and C++ (3942 lines, g++ clean)
- **Phase 5 (cross-target library mode) DONE:** TS `compileModule()` and C++ `compile_library()` both work
- **Language-specific modules eliminated:** `dart_std`, `cpp_std`, `ts_std` all removed; everything routes through universal `std`

## 1. Reified Generics Strategy

### The Problem

JS erases generic type parameters. `new Box<int>(42) instanceof Box` returns `true`
for any `Box<T>`. Dart, C#, and (partially) Hack have reified generics. Java, Kotlin,
Scala, Go erase them. C++/Rust monomorphize them.

### Industry Approaches

| System | Mechanism | Cost | Generic `is` Check |
|---|---|---|---|
| dart2js Rti | Per-instance `$ti` type descriptor + recipe strings | Medium | Full |
| DDC | ES6 class factories per type instantiation | Large (duplication) | Full |
| Kotlin `reified` | Compile-time inline substitution | Zero runtime | Partial (inline-only) |
| Scala ClassTag | Implicit raw-class parameter threading | Low | Raw type only |
| Haxe `@:generic` | Monomorphization (mangled class names) | Large (duplication) | Broken (`Std.is` fails) |

### Recommended: Type Descriptor Objects (Opt-in)

When the compiler detects `std.is(value, "Box<int>")` referencing a parameterized type:

```typescript
// TS output — only emitted when generic is-checks exist
class Box {
  __type_args__: string[];
  constructor(value: any, typeArgs: string[] = []) {
    this.value = value;
    this.__type_args__ = typeArgs;
  }
}
// Construction: new Box(42, ["int"])
// Type check:  obj instanceof Box && obj.__type_args__[0] === "int"
```

**Per-target strategy:**
- **Dart**: Native reified generics — emit `is List<int>` directly
- **TS/JS**: Type descriptor `__type_args__` array on instances (opt-in)
- **C++/Rust**: Monomorphization via templates/generics — distinct types
- **Java**: Type descriptor objects (same as TS — JVM erases generics)
- **Go**: Type tag field on structs (Go lacks generics runtime checks)
- **Python**: `isinstance()` + `__type_args__` attribute
- **C#**: Native reified generics (CLR supports them)

**Key invariant**: Programs that don't perform parameterized type checks pay zero cost.
The compiler only emits type descriptors when the IR contains generic `is`-checks.

## 2. BigInt / Int64 Strategy

### Current Approach (Validated)

Ball's TS compiler uses a **promotion-demotion** pattern:
- Emit `BigInt` literals for values > `MAX_SAFE_INTEGER`
- Arithmetic helpers promote to BigInt when either operand is BigInt
- Results demote back to `Number` when they fit in safe range
- Bitwise ops always use BigInt (JS operators truncate to 32 bits)
- Signed 64-bit wrapping via `BigInt.asIntN(64, v)` (recommended improvement)

This aligns with protobuf-es v2, wasm-bindgen, and Emscripten's approaches.

### Improvements to Implement

1. **Use `BigInt.asIntN(64, v)`** instead of manual modulo wrapping — single built-in
   call, likely V8-optimized
2. **Harden `__to_bigint`** against null/undefined/NaN inputs
3. **Add `BigInt.prototype.toJSON`** to preamble — prevents `JSON.stringify` crashes
4. **32-bit fast path for bitwise ops** — skip BigInt conversion when both operands
   are within 32-bit range (significant perf win for the self-hosted engine)
5. **Document cross-target contract**: BigInt is JS-only; all other targets (Dart,
   C++, Rust, Go, Java, Python) have native 64-bit integers

### Performance Context

BigInt arithmetic is ~3-10x slower than Number in V8 (2024-2025). The demotion
strategy keeps the fast path on Number for the common case (small integers).

## 3. Cross-Target Gap Analysis

### Priority 1: Structured Type Arguments -- DONE

**Resolved.** The legacy `__type_args__` string in `MessageCreation.fields` has been
replaced by structured `TypeRef` messages: `FunctionCall.type_args` and
`MessageCreation.type_args` (both `repeated TypeRef`) in `proto/ball/v1/ball.proto`.
The encoder no longer produces the legacy string format. Compilers retain a legacy
fallback for old programs.

### Priority 2: Numeric Overflow Semantics

**Current**: Undocumented — Dart wraps at 64-bit, JS uses BigInt, C++ is UB
**Fix**: Specify in Ball spec: "Ball integers are signed 64-bit with wrapping overflow."
Each compiler emits appropriate wrapping: Rust `.wrapping_add()`, Go native int64
(wraps naturally), C++ use `-fwrapv` or explicit casting.

### Priority 3: Map Key Type Constraint

**Current**: TS compiler uses plain objects (string keys only)
**Fix**: Document that Ball maps have string keys (matching protobuf semantics).
For non-string keys, consider `std_collections.typed_map_*` family.

### Priority 4: UTF-16 vs UTF-8 String Indexing

**Current**: `string_char_at(i)` accesses i-th UTF-16 code unit (Dart/JS semantics)
**Problem**: Rust/Go/C++ use UTF-8 — byte indexing gives different results
**Fix**: Document the convention. Add `string_char_at_codepoint` for Unicode-correct
access. Compilers for UTF-8 targets convert to UTF-16 for indexing or document the
difference.

### Priority 5: Error Handling for Non-Exception Languages

**Current**: `std.try/std.throw` assume exception-based error handling
**Problem**: Rust uses `Result<T, E>`, Go uses error returns
**Fix**: Document that these are exception-model primitives. Rust/Go compilers need
fundamentally different strategies: Rust transforms call graph to propagate
`Result<T, BallError>`, Go uses multi-return `(value, error)` patterns.

### Priority 6: Multi-File / Library Output for TS -- DONE

**Resolved.** TS compiler now exports `compileModule()` (`ts/compiler/src/compiler.ts`)
which emits a complete library from a `Module` facade (including inline sub-modules).
C++ has `compile_library()`. Both are proven on `ball_protobuf`. Remaining for future
targets: Rust (module = file), Go (package = directory), Java (class = file) will need
per-target multi-file strategies.

### Priority 7: Nullable Type Representation

**Current**: Nullability in metadata type strings (`"int?"`)
**Fix**: Add `bool nullable` to field descriptors or metadata convention. Compilers
parse `?` suffix from strings today, which is fragile for `Map<String?, List<int?>>`.

## 4. Multi-Target Compiler Patterns

### Pattern 1: Capability Declaration (LLVM + KMP)

Each compiler should declare which base functions it supports and how:
- **Legal**: Direct target equivalent (`std.add` -> `+`)
- **Expand**: Decompose into multiple operations (`std.for_each` -> for loop)
- **LibCall**: Emit runtime library call
- **Custom**: Target-specific lowering in `_compileBaseCall`

A conformance matrix can automatically detect gaps when adding new targets. KMP
enforces missing `expect/actual` at compile time — Ball should do the same.

### Pattern 2: Module Hierarchy for Partial Sharing (KMP)

Ball's module hierarchy is now universal-first. Language-specific base modules (`dart_std`,
`cpp_std`) have been eliminated -- encoders expand language-specific constructs into universal
`std` operations at encoding time. The hierarchy is:
```
std (universal, all targets — includes cascade, spread, invoke, null_aware_access, etc.)
├── std_collections (universal)
├── std_io (universal)
└── std_memory (C/C++ interop, linear memory)
```

Future language-specific modules (if ever needed) would contain only cosmetic helpers
or constructs that genuinely cannot be expressed as `std` expression trees, not base
functions that every target must implement.

### Pattern 3: IR Must Not Encode Target-Specific Semantics (LLVM + Haxe)

Ball's "metadata is cosmetic" invariant already enforces this. Strengthened rule:
**A Ball program's computed output must be identical regardless of which compiler
processes it.** Metadata controls formatting/naming, not behavior.

### Pattern 4: Memory Model Isolation (Nim + KMP)

Memory management differences should be encapsulated in dedicated modules:
- `std_memory` — linear memory for C/C++ interop (exists)
- `std_ownership` — ownership patterns for Rust (future)
- `std_gc` — GC hints for managed targets (future)

### Pattern 5: Whole-Module Replacement (Haxe)

Allow compilers to substitute entire module implementations (e.g., hand-optimized
`std_collections` for C++ using STL). Already possible via base functions, but an
explicit convention would help.

### Pattern 6: O(n) Translation via Canonical IR (CrossTL)

Ball already follows this perfectly. With n encoders and m compilers, total work is
O(n + m). Each new target requires only a new compiler. The 7-node expression model
keeps the IR surface area tractable.

### Pattern 7: Protobuf IR Advantage

Ball's protobuf IR is self-describing, schema-evolved, and natively serializable in
every language protobuf supports. Adding a new target starts with `buf generate` —
the new compiler immediately has type-safe bindings. No other multi-target system
gets this for free.

## 5. Action Items

### Immediate

- [ ] Apply BigInt improvements (asIntN, toJSON, 32-bit fast path)

### Short-term (before adding next target)

- [ ] Document numeric overflow semantics in Ball spec
- [ ] Document map key type constraint
- [ ] Document string indexing convention (UTF-16 code units)
- [x] Add structured `type_args` to `FunctionCall` proto — DONE (`TypeRef` message, `FunctionCall.type_args`, `MessageCreation.type_args`)
- [x] Implement `compileModule()` in TS compiler — DONE (also C++ `compile_library()`)
- [ ] Add base function capability declaration per compiler

### Medium-term (when adding Rust/Go/Python)

- [ ] Design error handling strategy for Result-based languages (Rust)
- [ ] Design error handling strategy for error-return languages (Go)
- [ ] Design ownership module for Rust
- [x] Formalize module hierarchy — DONE (universal `std` only; `dart_std`/`cpp_std`/`ts_std` eliminated)
- [ ] Add `string_char_at_codepoint` for UTF-8 targets
- [ ] Add nullable type representation to proto schema
