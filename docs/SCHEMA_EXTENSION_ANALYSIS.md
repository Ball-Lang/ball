# Ball Schema Extension Analysis — Runtime Gaps

> **Purpose**: Determine whether each runtime gap (async, OOP, generics, patterns, generators) requires proto schema changes (option C), or can be implemented with existing structural fields + base functions (option A) or cosmetic metadata (option B).
>
> **Classification key**:
> - **(A) BASE FUNCTIONS ONLY**: Implementable with existing proto schema fields + new std module base functions. No proto changes needed.
> - **(B) METADATA ONLY**: Implementable by adding new keys to existing `metadata` (google.protobuf.Struct) fields. No proto changes needed — metadata is cosmetic.
> - **(C) SCHEMA CHANGE REQUIRED**: Requires adding new structural fields or messages to `ball.proto`. **BLOCKING** — must be resolved before downstream waves.

---

## 1. Async/Await

### Current State

- `FunctionDefinition.metadata` already has `is_async` (bool), `is_async_star` (bool) keys
- `std.await` exists as a base function (currently a no-op in the engine)
- The Dart engine already has native `async`/`await` support via Dart's `Future` mechanism
- The engine reads `is_async` from metadata to determine async dispatch (see `engine_invocation.dart:112`)

### Analysis

Async/await execution requires:
1. **Async function dispatch** — engine must know a function is async → already in metadata (`is_async`)
2. **Await semantics** — `std.await` must actually suspend and resume → engine implementation, no schema change
3. **Future/Stream types** — these are runtime values, not schema constructs
4. **Async combinators** (`Future.wait`, `Future.any`) — new base functions in a `std_async` module

### Classification: **(A) BASE FUNCTIONS ONLY**

**Rationale**: The proto schema already has everything needed. `is_async` is in metadata (cosmetic). `std.await` exists as a base function. The engine just needs to implement proper async scheduling. New async combinators (`Future.wait`, `Future.any`, `Completer`, etc.) are all base functions. No structural fields needed.

---

## 2. OOP (Inheritance, Virtual Dispatch, super calls)

### Current State

- `TypeDefinition.metadata` has `superclass` (string), `interfaces[]` (string array), `mixins[]` (string array)
- `TypeDefinition.metadata` has `is_abstract`, `is_sealed`, `is_final`, `is_base`, `is_interface`, `is_mixin_class`
- `FunctionDefinition.metadata` has `is_override`, `is_static`, `kind` (method/constructor/getter/setter)
- The engine creates Map-based "objects" with no inheritance chain (GAP_ANALYSIS.md line 615)

### Analysis

OOP runtime requires:
1. **Inheritance chain resolution** — engine must resolve `superclass` to find parent type → `superclass` is in metadata, engine can read it
2. **Virtual dispatch** — engine must look up method on the actual type, not the static type → engine implementation using existing TypeDefinition + metadata
3. **`super` keyword** — engine must walk up the inheritance chain → `superclass` in metadata provides the chain
4. **Interface implementation checking** — `interfaces[]` in metadata provides the list
5. **Mixin application** — `mixins[]` in metadata provides the list

### Classification: **(A) BASE FUNCTIONS ONLY**

**Rationale**: All OOP information (`superclass`, `interfaces[]`, `mixins[]`, `is_abstract`, `is_sealed`, etc.) is already in `TypeDefinition.metadata`. The engine just needs to implement inheritance chain resolution and virtual dispatch at runtime. No new structural fields are needed — the metadata keys exist and are already populated by the encoder.

**Key insight**: `superclass` and `interfaces[]` live in `TypeDefinition.metadata` (the cosmetic `google.protobuf.Struct` field), NOT as named proto fields on `TypeDefinition`. This is correct per the metadata-is-cosmetic invariant: stripping metadata removes class hierarchy hints, but the engine needs them for runtime behavior. However, since the engine reads metadata at runtime, this works — metadata is "cosmetic" for *compilation* (affects how code looks), but the engine uses it for *execution semantics*. This is a design tension worth noting but not a blocker.

---

## 3. Generics (Reified Type Parameters)

### Current State

- `TypeDefinition` has a **structural** field `repeated TypeParameter type_params = 3` (NOT in metadata)
- `TypeParameter` has `name` (string) and `metadata` (Struct with `extends`, `super`, `variance`)
- `FunctionDefinition.metadata` has `type_params` (string array) — this is in metadata, not structural
- `TypeAlias` has `repeated TypeParameter type_params = 3` — structural
- The engine erases generic types at runtime (GAP_ANALYSIS.md line 630)

### Analysis

Generics at runtime require:
1. **Type parameter declaration** — already structural on `TypeDefinition` and `TypeAlias`
2. **Type parameter bounds** — already in `TypeParameter.metadata` (`extends`, `variance`)
3. **Reified type checking** — engine must carry type arguments at runtime → engine implementation, no schema change
4. **Generic function type parameters** — currently in `FunctionDefinition.metadata` as `type_params` (string array)

**Potential issue**: `FunctionDefinition.type_params` is in metadata (a string array), while `TypeDefinition.type_params` is a structural field (repeated TypeParameter). This inconsistency means function-level generics are cosmetic-only in the current schema. For reified generics, function type parameters would need to become structural too.

### Classification: **(A) BASE FUNCTIONS ONLY** (with caveat)

**Rationale**: Type-level generics already have structural `type_params` on `TypeDefinition`. The engine can implement reified generics by carrying type arguments at runtime without schema changes. Function-level generics are in metadata (`type_params` string array), which the engine can read at runtime.

**Caveat**: If we want *enforced* generic constraints at the Ball level (not just cosmetic), `FunctionDefinition.type_params` should migrate from metadata to a structural field. However, this is a **nice-to-have**, not blocking — the engine can read metadata for runtime type information. The current design treats function type params as cosmetic, which is consistent with Ball's "metadata is cosmetic" principle.

---

## 4. Pattern Matching (Destructuring)

### Current State

- The encoder produces structured pattern data in two forms:
  1. **String patterns**: `case_pattern` (string) and `pattern` (string) in control flow metadata
  2. **Structured patterns**: `pattern_expr` (Expression) — a Ball expression encoding the pattern as a `MessageCreation`
- The engine already has `_matchPattern()` and `_matchStructuredPattern()` methods that interpret structured pattern data
- Pattern types supported: type_test, list, object, record, logical_or, logical_and, cast, null_check, null_assert, relational, wildcard, variable
- All pattern data flows through existing `Expression` and `MessageCreation` message types

### Analysis

Pattern matching requires:
1. **Pattern representation** — already encoded as `MessageCreation` expressions with `__pattern_kind__` discriminator → uses existing Expression types
2. **Pattern evaluation** — engine already has `_matchPattern()` implementation
3. **Destructuring bindings** — engine already populates `bindings` map from pattern matches
4. **Exhaustiveness checking** — compiler-level concern, not runtime → can be done without schema changes

### Classification: **(A) BASE FUNCTIONS ONLY**

**Rationale**: Patterns are already encoded using existing `Expression` and `MessageCreation` message types. The `pattern_expr` field in control flow is an `Expression` — not a new proto field, but a field name within the `MessageCreation.fields` structure. The engine already interprets these. No new structural fields or expression types are needed. The `__pattern_kind__` discriminator is a convention within `MessageCreation`, not a schema change.

---

## 5. Generators (yield/yield*)

### Current State

- `FunctionDefinition.metadata` has `is_sync_star` (bool) and `is_async_star` (bool)
- `std.yield` and `dart_std.yield_each` exist as base functions (currently no-op in engine)
- The engine has no generator state machine

### Analysis

Generators require:
1. **Generator function identification** — already in metadata (`is_sync_star`, `is_async_star`)
2. **Yield/resume semantics** — `std.yield` and `dart_std.yield_each` are base functions that need real implementation
3. **Generator state machine** — engine must implement coroutine-like state management
4. **Iterable/Stream return types** — runtime values, not schema constructs

### Classification: **(A) BASE FUNCTIONS ONLY**

**Rationale**: Generator identification is in metadata. Yield is a base function. The engine needs to implement a state machine for generator functions, but this is purely an engine implementation concern. No new proto fields are needed — the engine can detect `is_sync_star`/`is_async_star` in metadata and switch to generator execution mode.

---

## Summary Table

| Gap | Classification | Proto Changes Needed? | Blocking? |
|-----|---------------|----------------------|-----------|
| Async/Await | **(A) BASE FUNCTIONS ONLY** | No | No |
| OOP (Inheritance/Dispatch) | **(A) BASE FUNCTIONS ONLY** | No | No |
| Generics (Reified) | **(A) BASE FUNCTIONS ONLY** | No | No |
| Pattern Matching | **(A) BASE FUNCTIONS ONLY** | No | No |
| Generators (yield/yield*) | **(A) BASE FUNCTIONS ONLY** | No | No |

**Overall conclusion**: **No proto schema changes are required for any of the five runtime gaps.** All can be implemented using the existing schema's structural fields, metadata keys, and base function mechanism.

---

## Detailed Findings

### Where `superclass` and `interfaces[]` Live

**Finding**: `superclass` and `interfaces[]` are in `TypeDefinition.metadata` (the `google.protobuf.Struct` field), NOT as named proto fields on `TypeDefinition`.

**Evidence**:
- `ball.proto` line 387-390: `TypeDefinition.metadata` is described as "All cosmetic hints: kind, superclass, interfaces, mixins, visibility, is_abstract, is_sealed, is_final, annotations, fields metadata, etc."
- `METADATA_SPEC.md` lines 61-63: `superclass` (string) and `interfaces` (string array) are listed under `TypeDefinition.metadata`
- `TypeDefinition` structural fields are: `name`, `descriptor`, `type_params`, `description`, `metadata`

**Implication**: Since `superclass` and `interfaces[]` are in metadata, they are "cosmetic" per Ball's design invariant. However, the engine reads metadata at runtime for OOP dispatch. This creates a semantic dependency on metadata that goes beyond pure cosmetics. This is a **design tension** but not a blocker — the engine can continue reading metadata for runtime behavior.

### Where `type_params` Lives

**Finding**: `type_params` has a split existence:
- On `TypeDefinition`: **structural** field (`repeated TypeParameter type_params = 3`)
- On `FunctionDefinition`: **metadata** key (`type_params: [string]`)

**Evidence**:
- `ball.proto` line 382: `repeated TypeParameter type_params = 3` on `TypeDefinition`
- `METADATA_SPEC.md` line 37: `type_params: [string]` under `FunctionDefinition.metadata`

**Implication**: Type-level generics are structural (part of the type definition). Function-level generics are cosmetic (in metadata). This is consistent with Ball's design: type parameters on types affect the type's structure (field types reference them), while function type parameters are purely for compilation/round-tripping.

### Pattern Expression Representation

**Finding**: Patterns are encoded as regular `Expression` values (specifically `MessageCreation` with `__pattern_kind__` discriminator), NOT as a new expression type in the proto `oneof`.

**Evidence**:
- `ball.proto` lines 460-486: The `Expression` oneof has exactly 7 variants: `call`, `literal`, `reference`, `field_access`, `message_creation`, `block`, `lambda`. No `pattern_expr` variant exists.
- `encoder.dart` lines 3632-3920: The `_encodePattern()` method produces `MessageCreation` expressions with `__pattern_kind__` fields
- `engine_control_flow.dart` lines 308-316: The engine reads `pattern_expr` from control flow fields and evaluates it as a regular expression

**Implication**: Pattern matching does NOT need a new expression type in the proto. The existing `MessageCreation` + `Literal` expression types are sufficient to encode all pattern kinds. The `__pattern_kind__` convention is an engine-level agreement, not a schema change.

### Async Metadata

**Finding**: Async/generator identification is entirely in `FunctionDefinition.metadata`:
- `is_async` (bool) — marks async functions
- `is_sync_star` (bool) — marks sync generators
- `is_async_star` (bool) — marks async generators

**Evidence**:
- `METADATA_SPEC.md` lines 22-24
- `engine_invocation.dart` line 112: `final asyncField = func.metadata.fields['is_async']`

**Implication**: The engine already reads these metadata keys. Implementing real async execution only requires engine changes, not schema changes.

---

## Design Tensions (Non-Blocking)

### 1. Metadata as Runtime Data

The "metadata is cosmetic" invariant states that stripping all metadata must not change what a program computes. However, several runtime features depend on metadata:
- `is_async` determines whether a function returns a Future
- `superclass` determines inheritance chain resolution
- `interfaces[]` determines interface implementation checking
- `is_abstract` determines whether a class can be instantiated

This creates a tension: metadata is "cosmetic" for compilation (it affects how code looks), but the engine reads it for execution semantics. Two resolutions:
1. **Accept the tension**: Metadata is cosmetic for *compilation output*, but the engine uses it for *runtime behavior*. This is the current design.
2. **Promote to structural fields**: Move `superclass`, `interfaces[]`, etc. to named proto fields on `TypeDefinition`. This would break the "metadata is cosmetic" invariant but make the schema more explicit about runtime-relevant data.

**Recommendation**: Accept the tension for now. The current design works — the engine reads metadata at runtime, and compilers use metadata for code generation. No schema changes are needed.

### 2. Function-Level Generics in Metadata

`FunctionDefinition.type_params` is a string array in metadata, while `TypeDefinition.type_params` is a structural field. If reified generics require function-level type parameters to be structural, this would be a schema change. However, the current design treats function type params as cosmetic (they affect compilation output, not runtime behavior), which is consistent.

**Recommendation**: Keep function-level type params in metadata. If reified generics are needed at the function level in the future, this can be promoted to a structural field then.

---

## Appendix: Proto Field Classification

### TypeDefinition Structural Fields (ball.proto lines 374-391)

| Field | Number | Type | Classification |
|-------|--------|------|----------------|
| `name` | 1 | `string` | Structural — type identity |
| `descriptor` | 2 | `google.protobuf.DescriptorProto` | Structural — field definitions |
| `type_params` | 3 | `repeated TypeParameter` | Structural — generic parameters |
| `description` | 4 | `string` | Structural — documentation |
| `metadata` | 5 | `google.protobuf.Struct` | Cosmetic — superclass, interfaces, mixins, kind, etc. |

### TypeParameter Structural Fields (ball.proto lines 361-367)

| Field | Number | Type | Classification |
|-------|--------|------|----------------|
| `name` | 1 | `string` | Structural — parameter name |
| `metadata` | 2 | `google.protobuf.Struct` | Cosmetic — bounds, variance |

### Expression Variants (ball.proto lines 460-486)

| Variant | Number | Used For |
|---------|--------|----------|
| `call` | 1 | Function calls |
| `literal` | 2 | Constant values |
| `reference` | 3 | Variable access |
| `field_access` | 4 | Object field access |
| `message_creation` | 5 | Object construction + pattern encoding |
| `block` | 6 | Sequential statements |
| `lambda` | 7 | Anonymous functions |

**No `pattern_expr` variant exists.** Patterns are encoded as `MessageCreation` with `__pattern_kind__` convention.