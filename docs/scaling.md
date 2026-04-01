# Ball Pre-Scaling Analysis

Deep study of what needs to be addressed before Ball scales to C#, C++, Rust, Java, and JSON-only languages.

---

## Core Design Invariant (Do Not Break)

> **Every function in Ball has exactly one input message and one output message.**

This is the fundamental design decision — identical to gRPC. It is **not a limitation to work around**. It is the feature that makes Ball a universal representation.

The input and output message `DescriptorProto`s already encode everything: field names, types, and cardinality. How a compiler surfaces those messages as target-language syntax is purely cosmetic.

**Input side** — when a Dart compiler sees `FunctionDefinition { input_type: "AddInput" }` and `AddInput { left: int, right: int }`, it is free to emit:

```dart
int add(int left, int right) { ... }   // destructured: fields become parameters
int add(AddInput input) { ... }        // structured: input message passed as-is
```

**Output side** — when output_type is `IntResult { value: int }`, a compiler can emit:

```dart
IntResult add(...) { return IntResult(value: result); }  // structured
int       add(...) { return result; }                    // destructured single-field
```

In both directions, a single-field message and a bare scalar are the **same Ball program**. The choice is a **cosmetic preference** recorded in language-specific metadata on the `FunctionDefinition`, not a schema-level concern.

This distinction — **semantic** (changes what the program means) vs **cosmetic** (changes only how it looks in a target language) — is the lens through which every suggestion below should be read.

---

## Semantic vs Cosmetic: The Boundary

| Concern | Semantic or Cosmetic? | Mechanism |
|---|---|---|
| Multi-parameter input destructuring | **Cosmetic** | Metadata hint `params: [{name, kind}]` on `FunctionDefinition` |
| Single-field output unwrapped to bare scalar | **Cosmetic** | Metadata hint `output_unwrap: true` on `FunctionDefinition` |
| Multi-field output destructured to multiple returns | **Cosmetic** | Metadata hint `output_params: [{name}]` (Go, Python tuple returns) |
| Variable mutability (`let` vs `let mut`) | **Cosmetic** | Metadata hint `mutability: "mutable"|"immutable"|"const"` on `LetBinding` |
| Visibility (`public`/`private`) | **Cosmetic** | Metadata hint `visibility: "public"|"private"|"protected"|"internal"` on `FunctionDefinition` / `TypeDefinition` |
| Ternary `a ? b : c` vs `if` expression | **Cosmetic** | Compiler detects expression-position `std.if` and emits ternary |
| Type annotation on `let x: int = 5` | **Cosmetic** (hint) | Metadata on `LetBinding`; compiler infers from value if absent |
| `@Override` annotation | **Cosmetic** | Scoping already encodes the override — `B.x` over `A.x` when B extends A |
| `#[derive(Clone)]`, `@dataclass` | **Cosmetic** | Code-generation macros: encoder expands them into Ball functions OR stores in metadata for round-trip |
| Other annotations / attributes | **Cosmetic** | Metadata list `annotations: [{name, args}]` on `FunctionDefinition` / `TypeDefinition` |
| `struct` vs `class` vs `trait` vs `interface` (TypeKind) | **Cosmetic** | Metadata hint `kind: "class"|"struct"|"trait"|"interface"|...` on `TypeDefinition` |
| Inheritance (`superclass`, `interfaces`, `mixins`) | **Cosmetic** | Metadata hints on `TypeDefinition`; compiler uses them to emit extends/implements syntax |
| Named constructor `Foo.named(...)` | **Cosmetic** | Metadata on constructor `FunctionDefinition` |
| Async/sync generator flavors | **Cosmetic** | Metadata keys `is_async`, `is_sync_star`, `is_async_star` on `FunctionDefinition` |

---

## Existing Metadata Convention (Keep, Standardize)

The `google.protobuf.Struct metadata` field on `FunctionDefinition`, `LetBinding`, `Module`, and `Program` is the **intentional** home for cosmetic and language-specific preferences. It is not a hack — it is correct by design.

The actual problem is that these keys are **undocumented and unstandardized**. Each compiler invents its own keys. The `_extractParams()` pain in the Dart engine is not because metadata is wrong — it's because there is no canonical schema for what goes inside it.

**What to do:** Create a `METADATA_SPEC.md` that defines the standard metadata keys every compiler must understand, organized by what message type they appear on:

```
FunctionDefinition.metadata:
  params: [{name: string, kind: "positional"|"named"|"optional"|"varargs", default: expr?}]
    → how to destructure input_type fields into target-language parameters
    → if absent, compiler falls back to reading DescriptorProto fields directly
  output_unwrap: bool
    → if true and output_type has exactly one field, emit that field's type as the bare return type
    → e.g. IntResult {value: int} → emit return type as int, unwrap on return, re-wrap on call site
    → if false (default), emit the output message type as-is
  output_params: [{name: string}]
    → for languages with multi-value returns (Go, Python, Rust tuples)
    → lists the output message fields to destructure into separate return values
  is_async: bool         → emit async keyword
  is_sync_star: bool     → emit sync* (Dart) / yields (C#) / Iterator (Java)
  is_async_star: bool    → emit async* (Dart) / IAsyncEnumerable (C#) / AsyncIterator (Java)
  is_static: bool        → static method
  is_getter: bool        → property getter syntax
  is_setter: bool        → property setter syntax
  is_operator: bool      → operator overload syntax
  is_external: bool      → external/native declaration only
  expression_body: bool  → emit as => expr (Dart) / expression body (C#)
  kind: "function"|"method"|"constructor"|"static_field"|"typedef"|"top_level_variable"|...
  doc: string            → documentation comment
  type_params: [{name: string, metadata?: {...}}]  → generic type parameter names + their cosmetic hints
    → metadata on each entry holds bounds, variance, etc. (mirrors TypeParameter.metadata in schema)
  annotations: [{name: string, args: expr?, module: string?}]
    → language-specific annotations / attributes / decorators
    → stored for round-trip fidelity; compilers emit them verbatim
    → code-generating macros (#[derive], @dataclass) are typically expanded by
      the encoder into real Ball function bodies; the annotation can also be
      stored here as a hint to re-emit the shorthand form where the target
      language supports it
  dart_imports: [...]    → Dart-specific import declarations
  dart_exports: [...]    → Dart-specific export declarations
  visibility: string     → "public"|"private"|"protected"|"internal"|"file"
    → if absent, each language applies its own default
    → purely a compiler hint: does not change what the function computes,
      only whether the target language compiler issues access errors

LetBinding.metadata:
  type: string           → explicit type annotation hint (empty = infer)
  mutability: string     → "mutable"|"immutable"|"const"
    → if absent, compiler applies language default
    → cosmetic: the program logic is identical whether or not the compiler
      enforces reassignment — runtime reflection, unsafe blocks, etc.
      can always bypass these constraints in the target language
  is_late: bool          → Dart late keyword

Module.metadata:
  dart_imports: [...]
  dart_exports: [...]
  csharp_usings: [...]
  cpp_includes: [...]
  rust_use: [...]
  java_imports: [...]

TypeDefinition.metadata:
  kind: string           → "class"|"struct"|"trait"|"interface"|"mixin"|"enum"|"union"|"record"|"extension"|"typedef"
  superclass: string     → name of the superclass/parent type
  interfaces: [string]   → list of interface/protocol names this type implements
  mixins: [string]       → list of mixin names (Dart, Scala, etc.)
  visibility: string     → "public"|"private"|"internal"|"file"
  is_abstract: bool      → emit abstract keyword
  is_sealed: bool        → emit sealed keyword (C#, Kotlin)
  is_final: bool         → emit final keyword
  doc: string            → documentation comment
  annotations: [{name: string, args: expr?, module: string?}]
    → language-specific class/struct-level annotations (@Entity, #[derive], etc.)

TypeParameter.metadata:
  extends: string        → upper bound (T extends Comparable / T: Clone)
  super: string          → lower bound (T super String — Java wildcards)
  variance: string       → "covariant"|"contravariant"|"invariant"
    → used by Dart (out T, in T), Kotlin, Scala, C#
```

This spec costs nothing to add to the repo and immediately makes every new compiler implementer productive.

---

## What you have (solid foundation)

- Proto schema: `Program → Module → FunctionDefinition → Expression` tree, using `google.protobuf.DescriptorProto` for language-agnostic types. Smart.  
- `std` module: 73 universal base functions, well categorized.  
- `dart_std` module: proof of the language-specific extension pattern.  
- Dart compiler/encoder/engine: clean reference implementation, all three programs working.  
- Module import system with 4 source types and integrity hashing.

---

## Real Schema Gaps

The schema **cannot express** these things today, and they cannot be stored in metadata.

Note what is **not** in this list — all of the following are metadata hints:

- **Mutability / visibility** — a private function called via reflection runs identically to a public one; a `final` variable that is never reassigned computes identically to a mutable one.
- **Annotations / attributes** — `@Override` is verified, not computed. `#[derive(Clone)]` is a macro shorthand: a Rust encoder can either expand it into a real `Foo.clone()` Ball function body, or store the annotation in metadata for the Rust compiler to re-emit. Either way the Ball expression tree is complete without it.
- **Spread syntax** (`...list`, `*args`) — semantically equivalent to `std.list_concat` or passing the list directly. Cosmetic hint stored in call-site metadata.
- **TypeKind and inheritance** — whether a type is a `class`, `struct`, `trait`, or `interface` is a target-language rendering choice. `superclass`, `interfaces`, and `mixins` are metadata hints. Ball's scoping model handles dispatch structurally. See below.

### Ball Scoping Model and Overrides

Ball uses dot-notation to express scope. A `FunctionDefinition` named `x` inside module `main` is referenced externally as `main.x`. Methods and constructors follow the same pattern using the class name as an additional scope level:

```
"x"       → top-level function x in the current module
"A.x"     → method x belonging to class A
"A.new"   → default constructor of A
"A.named" → named constructor of A
"B.x"     → method x belonging to class B (overrides A.x if B extends A)
```

The existence of `B.x` as a `FunctionDefinition` in the module is all Ball needs to represent the override. A compiler emitting Dart/Java/Kotlin can infer the `override` keyword from the fact that `B.x` exists and `metadata["superclass"]` on B's `TypeDefinition` names A. No schema-level `superclass` field is needed for Ball to represent the computation.

The same logic applies to interface implementations: if `TypeDefinition` for B has `metadata["interfaces"]` listing A, and `B.x` is defined, it is implementing `A.x`.

---

### 1. `TypeDefinition` — Replace the `_meta_` Hack

The `_meta_Foo` convention is a load-bearing workaround with no schema support. `TypeDefinition` follows the same pattern as `FunctionDefinition`: a name, a descriptor for its fields, type parameter names, and a metadata bag for everything else.

Type parameter *names* are a schema-level concern because they are structural: the compiler needs `T` and `K` to emit `Map<K, V>` correctly. The bounds, variance, and constraints on those parameters are cosmetic hints for the target-language compiler and belong in `TypeParameter.metadata`.

Everything else — `TypeKind`, `superclass`, `interfaces`, `mixins`, `visibility`, `is_abstract`, `is_sealed`, `is_final`, `doc`, `annotations` — is a cosmetic hint that goes in `TypeDefinition.metadata`.

```proto
// A type parameter placeholder for generic types (e.g. T, K, V).
// Bounds, variance, and other constraints are cosmetic hints in metadata.
message TypeParameter {
  string                 name     = 1;  // e.g. "T", "K", "V"
  google.protobuf.Struct metadata = 2;  // bounds, variance, covariance, etc.
}

// Defines a named type, mirroring the structure of FunctionDefinition.
message TypeDefinition {
  // Type name (unique within its module)
  string                          name        = 1;

  // Field definitions using protobuf's own descriptor format
  google.protobuf.DescriptorProto descriptor  = 2;

  // Generic type parameter names (e.g. T, K, V)
  repeated TypeParameter          type_params = 3;

  // Human-readable description
  string                          description = 4;

  // All cosmetic hints: kind ("class"|"struct"|"trait"|"interface"|...),
  // superclass, interfaces, mixins, visibility, is_abstract, is_sealed,
  // is_final, annotations, type_param_bounds
  google.protobuf.Struct          metadata    = 5;
}

// Module: add
//   repeated TypeDefinition type_defs = 8;
// (keep existing repeated DescriptorProto types = 2 for backward compatibility
//  or migrate and reserve field 2)
```

This is the single highest-impact schema change.

---

### What `SpreadExpression` Is NOT a Schema Gap

`[a, ...b, c]` is semantically equivalent to calling `std.list_concat` — therefore it is cosmetic by the same rule as ternary and typeof. The spread form can be stored in `LetBinding.metadata` or `FunctionCall` input metadata as a hint for the encoder to reconstruct the original syntax on round-trip. No `Expression.oneof` variant needed.

---

### What `TypeExpression` Is NOT a Schema Gap

`sizeof(T)`, `typeof(x)`, `decltype(expr)`, `nameof(x)` all look like they need special treatment because their primary operand is a *type*, not a value. But in Ball's model, a type name is just a string, and strings can be passed to base functions. All of these reduce to ordinary function calls:

- `sizeof(int)` → `cpp_std.sizeof(SizeofInput { type_name: "int" })` — returns a number
- `typeof(x)` → `std.type_name(x)` — already in the std gaps list
- `nameof(x)` → a string literal; the encoder knows the name at parse time
- `decltype(expr)` → only used in type annotation context, which is cosmetic metadata
- `alignof(T)` → `cpp_std.alignof(AlignofInput { type_name: "T" })`

Each variant either already has a `std.*` equivalent or is a language-specific base function whose input happens to be a type-name string. No new `Expression.oneof` variant needed. These belong in `cpp_std`, `csharp_std`, etc. as base functions with string inputs.

---

### What `TernaryExpression` Is NOT a Schema Gap

`a ? b : c` is semantically identical to `std.if { condition: a, then: b, else: c }`. The only difference is that some compilers prefer to emit the ternary form when an `if` is used in expression position (i.e., the `std.if` call is the `result` of a `Block`, or directly the value of a `LetBinding`). This is a **compiler output preference** — it lives in the compiler's emit logic, not in the schema.

Each language compiler should detect expression-position `std.if` and emit whichever form is idiomatic:
- C/C++/Java/C#/Rust/JS → emit `a ? b : c`
- Python → emit `b if a else c`
- Dart → emit `a ? b : c`
- Go → no ternary, must emit `if/else` block

No schema change needed.

---

## `std` Module Gaps

The test for inclusion in `std`: **every target language, in every execution environment, will have this**. That rules out collections (not primitive in all runtimes), I/O (unavailable in browser JS, WASM sandboxes, embedded), and anything whose output format varies by language (toString, type_name). Those get their own modules below.

### Strings

Pure string manipulation — no I/O, no formatting, no type conversion. Every language has these regardless of runtime environment.

```
// Input: UnaryInput {value} or BinaryInput {left, right}

string_length, string_is_empty
string_concat                  → merge two strings (left + right)
string_contains, string_starts_with, string_ends_with
string_index_of, string_last_index_of
string_substring               → (value, start, end)
string_char_at                 → character at index
string_char_code_at            → numeric code of character at index
string_from_char_code          → character from numeric code
string_to_upper, string_to_lower
string_trim, string_trim_start, string_trim_end
string_replace, string_replace_all, string_replace_first
string_split                   → returns list of strings
string_repeat                  → repeat string N times
string_pad_left, string_pad_right
```

Excluded from `std`:
- `string_format` (printf / `%`, f-strings, `String.format` — syntax is per-language; use `string_concat` + explicit conversions or put in each language's `x_std`)
- `string_join` → depends on `std_collections` (takes a list); define there

### Math

Pure numeric computation. Universal across every language and environment.

```
math_abs, math_floor, math_ceil, math_round, math_trunc
math_sqrt, math_pow, math_log, math_log2, math_log10, math_exp
math_sin, math_cos, math_tan, math_asin, math_acos, math_atan, math_atan2
math_min, math_max, math_clamp
math_pi, math_e, math_infinity, math_nan
math_is_nan, math_is_finite, math_is_infinite
math_sign, math_gcd, math_lcm
```

---

## `std_collections` Module

Depends on `std`. Separate because not all runtimes expose a mutable collection API (e.g. some WASM targets), and the set of operations is large enough to warrant its own versioned module.

```
// Input types: ListInput {list, index?, value?, ...}, MapInput {map, key?, value?, ...}

// List — indexed, ordered
list_push, list_pop, list_insert, list_remove_at
list_get, list_set, list_length, list_is_empty
list_first, list_last, list_single
list_contains, list_index_of
list_map, list_filter, list_reduce, list_find
list_any, list_all, list_none
list_sort, list_sort_by, list_reverse, list_slice
list_flat_map, list_zip
list_take, list_drop, list_range
list_concat                    → merge two lists (complement of std.string_concat)

// Map — key/value
map_get, map_set, map_delete, map_contains_key
map_keys, map_values, map_entries
map_from_entries, map_merge, map_map, map_filter
map_is_empty, map_length

// String ↔ Collection bridge (defined here, not in std, because they depend on list)
string_join                    → join list of strings with separator
```

---

## `std_io` Module

Depends on `std`. Import explicitly — not available in browser JS, WASM sandboxes, embedded targets, or serverless functions without a TTY.

```
// Console
print_error    → write to stderr

// Standard input
read_line      → read one line from stdin

// Process control
exit           → terminate with exit code
panic          → hard abort with message (Rust panic!, C++ terminate, Java RuntimeException)

// Time
sleep_ms       → pause execution N milliseconds
timestamp_ms   → wall clock milliseconds since epoch

// Randomness
random_int     → random integer in range [min, max]
random_double  → random double in [0.0, 1.0)

// Environment
env_get        → read environment variable by name
args_get       → command-line arguments as list of strings
```

Excluded from `std_io` — per-language `x_std`:
- `type_name` — output format differs: JS `typeof`, Java `getClass().getName()`, Dart `runtimeType.toString()`, Rust `std::any::type_name`
- `as_safe`, `is_null`, `default_value` — Rust has no null; Go has no exceptions; semantics are too divergent to standardize

---

## Language-Specific Modules

Define these before writing each compiler. They isolate language-specific constructs, preventing them from bleeding into `std` and documenting the full surface area a compiler writer needs to handle.

Each of these modules follows the exact same pattern as `dart_std`: base functions with `is_base: true`, input types defined as `DescriptorProto`, no bodies.

### `csharp_std`

```
// Resource management
using_stmt            → using (var r = ...) { }  — IDisposable scope

// Properties (C# distinguishes properties from fields syntactically)
property_get          → obj.PropName  (get accessor)
property_set          → obj.PropName = value  (set accessor)
init_property_set     → obj.PropName = value  (init accessor — C# 9)

// Events
event_add             → obj.Event += handler
event_remove          → obj.Event -= handler

// Delegates and invocation
delegate_invoke        → del(args)  or  del.Invoke(args)

// LINQ — these are pervasive in idiomatic C#
linq_where, linq_select, linq_select_many
linq_first, linq_first_or_default
linq_single, linq_single_or_default
linq_any, linq_all, linq_count
linq_sum, linq_min, linq_max, linq_average
linq_order_by, linq_order_by_desc, linq_then_by
linq_group_by, linq_join, linq_zip
linq_to_list, linq_to_array, linq_to_dictionary
linq_distinct, linq_take, linq_skip, linq_where_not
linq_aggregate

// Numeric overflow control
checked_block         → checked { expr }
unchecked_block       → unchecked { expr }

// Unsafe / interop
unsafe_block          → unsafe { }
fixed_stmt            → fixed (T* p = &val) { }
stackalloc            → stackalloc T[n]

// Ref semantics
ref_param             → ref argument modifier
out_param             → out argument modifier
in_param              → in argument modifier (readonly ref)

// Pattern matching / deconstruction
switch_expr           → C# switch expression with pattern arms
tuple_deconstruct     → var (a, b) = pair
with_expr             → record with { Field = newVal }
is_pattern            → val is Type name  (positional/property/recursive patterns)

// Async
configure_await       → awaitable.ConfigureAwait(false)
```

### `cpp_std`

```
// Pointer / reference
raw_ptr               → T* (raw pointer type expression)
ref_type              → T& (lvalue reference)
rvalue_ref            → T&& (rvalue reference)
address_of            → &expr
deref                 → *expr
arrow_access          → expr->field  (member via pointer)

// Casts
cast_static           → static_cast<T>(val)
cast_dynamic          → dynamic_cast<T>(val)
cast_reinterpret      → reinterpret_cast<T>(val)
cast_const            → const_cast<T>(val)
c_cast                → (T)val

// Scope resolution
namespace_scope       → ns::name
scope_resolution      → ClassName::member

// Move semantics
move_expr             → std::move(val)
forward_expr          → std::forward<T>(val)

// Memory
new_expr              → new T(args)
new_array             → new T[n]
delete_expr           → delete ptr
delete_array          → delete[] ptr
placement_new         → new(ptr) T(args)

// Compile-time type queries — base functions taking type_name: string as input
sizeof_expr           → sizeof(T) or sizeof(expr)
decltype_expr         → decltype(expr)
alignof_expr          → alignof(T)
noexcept_spec         → noexcept(expr) specifier

// Aggregate initialization
aggregate_init        → {a, b, c} brace initialization
designated_init       → .field = val  (C++20)

// Lambdas
lambda_capture        → [=], [&], [x, &y] capture list specification

// Coroutines (C++20)
co_await, co_yield, co_return

// Templates
template_call         → func<T, U>(args)  explicit template instantiation
```

### `rust_std`

```
// Ownership / borrowing — semantically required for Rust
borrow                → &val (shared reference)
borrow_mut            → &mut val (mutable reference)
deref                 → *val (dereference)
raw_ptr_const         → *const T
raw_ptr_mut           → *mut T

// Smart pointers
box_new               → Box::new(val)
rc_new                → Rc::new(val)
arc_new               → Arc::new(val)
ref_cell              → RefCell::new(val)
cell_new              → Cell::new(val)

// Error propagation
question_mark         → expr? (propagate Err / None)

// Pattern matching — richer than std.switch
match_guard           → match arm with if guard
if_let                → if let Some(x) = opt { }
while_let             → while let Some(x) = iter.next() { }
let_else              → let Ok(x) = result else { return; }

// Struct update
struct_update         → Foo { field: val, ..other }

// Ranges
range_exclusive       → a..b
range_inclusive       → a..=b
range_from            → a..
range_to              → ..b

// Closures
closure_move          → move |x| body

// Trait implementation (needed as a module-level construct)
impl_trait            → impl TraitName for TypeName { ... }
impl_inherent         → impl TypeName { ... }

// Macros (invocation — not definition)
macro_call            → macro_name!(args) or macro_name![args] or macro_name!{args}

// Unsafe / FFI
unsafe_block          → unsafe { }
extern_block          → extern "C" { }
extern_fn             → extern "C" fn name(...)

// Lifetimes (annotation hints)
lifetime_param        → lifetime annotation on a reference type
```

### `java_std`

```
// Object creation (Java requires new keyword — not implicit)
new_expr              → new Foo(args)

// Instance checks
instanceof_check      → val instanceof Type
instanceof_pattern    → val instanceof Type name  (Java 16+ pattern matching)

// Synchronized concurrency
synchronized_block    → synchronized(lock) { }

// Static initializer
static_init_block     → static { }  class-level static initializer

// try-with-resources
try_with_resources    → try (Resource r = new R()) { }

// Anonymous classes
anonymous_class       → new Interface() { @Override method() { } }

// Method / constructor references
method_ref_static     → ClassName::staticMethod
method_ref_instance   → obj::instanceMethod
constructor_ref       → ClassName::new

// Arrays (Java arrays are distinct from java.util.List)
array_new_typed       → new int[n]
array_new_init        → new Foo[]{a, b, c}
array_get, array_set, array_length

// Varargs invocation
varargs_spread        → method(a, b, rest...)
```

---

## Module-Level Declarations Missing from Schema

```proto
// Add to Module:
repeated TypeAlias type_aliases    = 11;
repeated Constant  module_constants = 12;
```

```proto
message TypeAlias {
  string             name        = 1;  // alias name
  string             target_type = 2;  // aliased type
  repeated TypeParameter type_params = 3;
  google.protobuf.Struct metadata = 4;  // cosmetics: visibility, C++ using, Rust type, TS type
}

message Constant {
  string     name     = 1;
  string     type     = 2;  // empty = infer
  Expression value    = 3;
  google.protobuf.Struct metadata = 4;  // cosmetics: visibility, annotations
}
```

These enable: C++ `using MyVec = std::vector<int>`, Rust `type Result<T> = std::result::Result<T, MyError>`, TypeScript `type ID = string`, and module-level constants across all languages.

---

## JSON Canonical Schema (Non-Protobuf Languages)

Languages without a protobuf runtime can still participate using Ball's protobuf JSON serialization. The mapping is already defined by the protobuf spec but is not documented anywhere in this repo. Three things to create:

**1. `ball.schema.json`** — JSON Schema Draft-2020-12 mirroring `ball.proto`. Non-obvious protobuf JSON rules to document explicitly:
- `oneof` fields: only the set variant key appears in the object — no discriminator field
- `int64`/`uint64`: serialized as quoted strings per protobuf JSON spec §5
- `bytes`: base64-encoded string
- Enum values: serialized as their string name (`"TYPE_STRING"`) not integer
- Default/zero values: may be omitted from JSON entirely (proto3 default)

**2. `BALL_JSON_SPEC.md`** — narrative spec with full examples: a `Block` in JSON, a `FunctionCall` wrapping a `MessageCreation`, how to omit defaults. Every new language implementer needs this to write a JSON-only parser without reading Dart code.

**3. Canonical Normalization** — see AI Training section below. The canonical form doubles as the authoritative JSON representation.

---

## Compiler / Encoder / Engine Contract

Create `IMPLEMENTING_A_COMPILER.md` defining the abstract contract. This decouples the spec from the Dart reference implementation and lets any language start without reading `compiler.dart`.

```
# Required: Compiler (ball → Language)

CompileProgram(program: Program) → string
  - resolves all module_imports
  - calls CompileModule for program.entry_module
  - wraps in any file-level boilerplate (package declarations, shebang, etc.)

CompileModule(module: Module) → string
  - for each type_def: CompileTypeDef(type_def)
  - for each non-base function: CompileFunction(func)
  - emits language imports from module.metadata cosmetic keys

CompileFunction(func: FunctionDefinition) → string
  - reads func.metadata["visibility"] → emit public/private/pub/etc.
  - reads func.metadata["annotations"] → emit @Override, #[derive], etc.
  - reads func.metadata["params"] → destructure input_type fields into parameters
    if absent → compiler may emit (InputType input) or read DescriptorProto fields directly
  - reads func.metadata["output_unwrap"] → if true and output_type has one field,
    emit bare scalar return type; wrap/unwrap at boundary automatically
  - reads func.metadata["output_params"] → for multi-return languages (Go, Python tuples),
    destructure output_type fields into separate return values
  - reads func.metadata["is_async"], ["is_getter"], etc. → cosmetic output modifiers
  - calls CompileExpression(func.body)

CompileExpression(expr: Expression) → string
  switch expr.kind:
    call          → route to MapStdFunction(module, name, input) or user function call
    literal       → emit language-native literal
    reference     → emit variable name
    field_access  → emit obj.field (or obj->field in cpp_std context)
    message_creation → emit constructor call or struct literal
    block         → emit { stmts...; result }
    lambda        → emit anonymous function / closure / lambda
    // spread, ternary, sizeof, typeof etc. are cosmetic — stored in metadata or emitted via language_std base functions

MapStdFunction(module, function, compiledInput) → string
  ← THE ONLY function you MUST implement per language.
  Maps every std.* and language_std.* base function to native syntax.

CompileTypeDef(type: TypeDefinition) → string
  - reads type.kind → always TYPE_KIND_CLASS (kind is now in type.metadata["kind"])
  - reads type.metadata["kind"] → class/struct/trait/interface/union/enum
  - reads type.metadata["visibility"], ["is_abstract"], ["is_sealed"], ["is_final"] → cosmetic modifiers
  - reads type.metadata["superclass"], ["interfaces"], ["mixins"] → emit extends/implements
  - reads type.type_params → emit generic parameter names (e.g. <T, K, V>)
    each TypeParameter.metadata holds bounds (cosmetic: T extends Comparable)
  - reads type.metadata["annotations"] → emit @Override, #[derive], [Attribute], etc.
  - emits fields from type.descriptor.field
  - finds all FunctionDefinitions in the module whose name is "TypeName.methodName" → methods
    (presence of "B.x" when B's metadata["superclass"] is A implicitly encodes override — emit override keyword as cosmetic hint)

# Required: Encoder (Language → ball)
EncodeFile(source: string) → Program
  - parses source using language's own parser/AST library
  - maps each construct to the corresponding ball Expression / FunctionDefinition / TypeDefinition
  - cosmetic preferences are preserved in metadata for lossless round-trips

# Optional: Engine (execute ball in Language)
Run(program: Program) → BallValue
  - walks expression tree evaluating directly
  - implements all MapStdFunction mappings as runtime operations
  - lazy-evaluates control flow (if, while, for) — do not pre-evaluate branches
```

---

## Priority Order

| Priority | Change | Category | Why now |
|---|---|---|---|
| 1 | First-class `TypeDefinition` (replace `_meta_` hack) | Schema | Mirrors `FunctionDefinition`; type param names needed for generic signatures |
| 2 | `METADATA_SPEC.md` — standardize all metadata keys | Documentation | Covers annotations, visibility, mutability, params, output_unwrap, spread hints |
| 3 | Extend `std` — strings and math | Std module | Only what every language in every environment has; no I/O, no collections |
| 4 | `std_collections` module | Std module | List/map operations; separate because not universal across all runtimes |
| 5 | `std_io` module | Std module | I/O, time, random, env; separate because unavailable in browser/WASM/embedded |
| 6 | Define `csharp_std`, `cpp_std`, `rust_std`, `java_std` | Language modules | sizeof, typeof, alignof, type_name etc. live here; prevents std pollution |
| 7 | `TypeAlias` + `Constant` in `Module` | Schema | Rust `type`, C++ `using`, module-level constants — currently inexpressible |
| 8 | `ball.schema.json` + `BALL_JSON_SPEC.md` | Documentation | Required for non-protobuf language participation |
| 9 | `IMPLEMENTING_A_COMPILER.md` contract | Documentation | Next compiler writer should not need to read Dart source code |