# Ball `__dunder__` Field Audit

> Comprehensive audit of all double-underscore conventions in the Ball codebase.
> Goal: eliminate IR-level hacks, keep only legitimate engine runtime internals.

## Category 1: IR-Level Hacks (MUST FIX)

These appear in Ball IR files (`.ball.json`) as synthetic field names in
`MessageCreation.fields` or as magic reference names. They violate the proto
schema by encoding semantic information in string field names instead of
structured proto fields.

### `__type_args__` — MIGRATING
- **What**: Generic type arguments on function calls and constructors
- **Where**: Encoder produces it, compilers/engine consume it
- **Status**: Being migrated to `FunctionCall.type_args` (TypeRef)
- **Remaining**: Encoder still produces old format

### `__const__` (19 occurrences)
- **What**: Marks a constructor as `const` (Dart-specific optimization)
- **Where**: Encoder produces it in MessageCreation.fields
- **Fix**: Move to `MessageCreation.metadata.is_const` (proto field already added)
- **Impact**: Encoder + Dart compiler + TS compiler + C++ compiler

### `__cascade_self__` (34 occurrences)
- **What**: Sentinel reference name for the cascade target in Dart `..` chains
- **Where**: Encoder emits `Reference(name: "__cascade_self__")`, compilers check for it
- **Fix**: Add a `bool is_cascade_target` to `Reference` proto message, or use
  `Reference.metadata` with a `cascade_target: true` flag
- **Impact**: Encoder + Dart compiler + TS compiler

### `__pattern_kind__` (11 occurrences)
- **What**: Discriminator for structured pattern types (record, var, type, etc.)
- **Where**: Encoder emits in switch case MessageCreation fields
- **Fix**: Add a proper `Pattern` message to the proto schema:
  ```protobuf
  message Pattern {
    oneof kind {
      VarPattern var = 1;
      RecordPattern record = 2;
      TypePattern type = 3;
      WildcardPattern wildcard = 4;
      ConstantPattern constant = 5;
      ListPattern list = 6;
    }
  }
  ```
- **Impact**: Encoder + Dart compiler + TS compiler + engine

### `__no_init__` (14 occurrences)
- **What**: Sentinel for `late` (uninitialized) variables in Dart
- **Where**: Encoder emits as a reference, engine uses it as a sentinel value
- **Fix**: Add `bool is_late` to `LetBinding.metadata` or `LetBinding` proto.
  The engine's runtime sentinel is fine — it's the IR encoding that's wrong.
- **Impact**: Encoder + compilers

### `__builtin_class__` / `__class_ref__` (12 occurrences)
- **What**: Marks a type as a builtin class and provides a class reference for
  static method dispatch
- **Where**: Engine-generated type registry entries
- **Fix**: These are engine-internal, but if they appear in Ball IR, they should
  be `TypeDefinition.metadata.is_builtin: true`
- **Impact**: Engine internals mostly

### Operator overloading names (`__op_add__`, `__op_sub__`, etc.)
- **What**: Method names for Dart operator overloading (operator+, etc.)
- **Where**: Encoder produces as method names, engine dispatches on them
- **Count**: 23 different operators
- **Fix**: These are legitimate as method names (the encoding is `operator+` →
  `__op_add__`). But should be documented in METADATA_SPEC.md. Alternatively,
  add `string operator_symbol` to FunctionDefinition metadata (cosmetic).
- **Impact**: Documentation only — these actually work fine as conventions

## Category 2: Engine Runtime Internals (OK to keep)

These are used by the engine's OOP runtime to track instance state. They never
appear in the Ball IR proto schema — they're set at runtime on BallObject
instances. Every engine implementation needs equivalent mechanisms.

| Name | Purpose | Where |
|---|---|---|
| `__type__` | Instance type name | BallObject instances |
| `__super__` | Super object reference | BallObject inheritance chain |
| `__methods__` | Method dispatch table | BallObject instances |
| `__fields__` | Field storage map | BallObject instances |
| `__constructor_type__` | Constructor recursion guard | Scope binding during construction |
| `__generator__` | Generator state machine | Generator instances |
| `__ball_future__` | Async future wrapper | Async execution |
| `__buffer__` | StringBuffer backing store | StringBuffer instances |
| `__type_args__` (runtime) | Instance type arguments | BallObject instances (for reified generics) |

These are fine — they're engine internals, not IR-level hacks. Each target
engine (Dart, TS, C++, future Rust/Go) can use its own mechanism for tracking
instance state.

## Priority Order for Clean-up

1. **`__type_args__`** — IN PROGRESS (TypeRef migration)
2. **`__const__`** → `MessageCreation.metadata` (smallest change, high impact)
3. **`__cascade_self__`** → structured reference flag (medium change)
4. **`__pattern_kind__`** → `Pattern` proto message (larger change, big win)
5. **`__no_init__`** → `LetBinding` metadata (small change)
6. **Operator names** → document in METADATA_SPEC.md (no code change needed)
7. **`__builtin_class__`/`__class_ref__`** → engine-internal, low priority

## Recommended Proto Changes

```protobuf
// Already done:
message TypeRef { ... }
message FunctionCall { repeated TypeRef type_args = 4; }
message MessageCreation { google.protobuf.Struct metadata = 3; }

// Next batch:
message Reference {
  string name = 1;
  bool is_cascade_target = 2;  // replaces __cascade_self__
}

message LetBinding {
  string name = 1;
  Expression value = 2;
  google.protobuf.Struct metadata = 3;
  bool is_late = 4;  // replaces __no_init__
}

// Future: Pattern message for structured patterns
```
