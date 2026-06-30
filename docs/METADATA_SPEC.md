# Ball Metadata Specification

Standard metadata keys for the `google.protobuf.Struct metadata` field
on Ball schema messages. Every compiler must understand these keys.

All metadata is **cosmetic** — it affects how code looks in a target language,
not what the program computes. A Ball program with all metadata stripped
is semantically identical to the original.

---

## FunctionDefinition.metadata

| Key | Type | Description |
|-----|------|-------------|
| `kind` | `string` | `"function"` \| `"method"` \| `"constructor"` \| `"getter"` \| `"setter"` \| `"operator"` \| `"static_field"` \| `"top_level_variable"` |
| `params` | `[{name, kind, default?, type?}]` | Parameter descriptors. `kind`: `"positional"` \| `"named"` \| `"optional"` \| `"varargs"`. `default`: expression source for default value. `type`: explicit type annotation. |
| `output_unwrap` | `bool` | If `true`, single-field output message → emit bare scalar return type. |
| `visibility` | `string` | `"public"` \| `"private"` \| `"protected"` \| `"internal"` \| `"file"`. If absent, language default applies. |
| `is_static` | `bool` | Static method/field. |
| `is_abstract` | `bool` | Abstract method (no body). |
| `is_async` | `bool` | Async function (`async` in Dart/JS, `async` in Rust/Python). |
| `is_sync_star` | `bool` | Sync generator (`sync*` in Dart, `yield` in Python). |
| `is_async_star` | `bool` | Async generator (`async*` in Dart, `async for` in Python). |
| `is_getter` | `bool` | Property getter. |
| `is_setter` | `bool` | Property setter. |
| `is_operator` | `bool` | Operator overload. |
| `is_external` | `bool` | External/native declaration. |
| `is_override` | `bool` | Override annotation hint. |
| `is_factory` | `bool` | Factory constructor (Dart). |
| `expression_body` | `bool` | When `true`, the function's `body` field is a bare expression (not a `block`). Compilers must handle both forms at the top-level body position — bare expressions are NOT guaranteed to be wrapped in a block. The Dart compiler uses this to emit `=> expr` form; C++ routes through `compile_statement` so control-flow calls in the body hit their statement-context paths. |
| `constructor_name` | `string` | Named constructor: `"Foo.named"` → the `"named"` part. |
| `redirects_to` | `string` | Redirecting constructor target. |
| `initializers` | `string` | Constructor initializer list source. |
| `doc` | `string` | Documentation comment (verbatim source). |
| `annotations` | `[{name, args?, module?}]` | Language-specific annotations/attributes/decorators. |
| `type_params` | `[string]` | Generic type parameter names (e.g. `["T", "K extends Comparable"]`). |
| `output_params` | `[{name, type?}]` | Multi-return / destructured output parameters. Used by languages with tuple returns (Go, Python). Each entry names one component of the output message. Compilers emit destructuring patterns (e.g. `err, value := fn()` in Go). |

---

## LetBinding.metadata

| Key | Type | Description |
|-----|------|-------------|
| `type` | `string` | Explicit type annotation. Empty or absent = infer from value. |
| `mutability` | `string` | `"mutable"` \| `"immutable"` \| `"const"`. Default: language-specific. |
| `is_final` | `bool` | Dart `final`, Kotlin `val`, Rust default (non-`mut`). |
| `is_const` | `bool` | Compile-time constant. |
| `is_late` | `bool` | Dart `late` keyword. |
| `is_var` | `bool` | Explicitly untyped (`var x = ...`). |
| `doc` | `string` | Documentation comment. |

---

## TypeDefinition.metadata

| Key | Type | Description |
|-----|------|-------------|
| `kind` | `string` | `"class"` \| `"struct"` \| `"trait"` \| `"interface"` \| `"mixin"` \| `"enum"` \| `"union"` \| `"record"` \| `"extension"` \| `"extension_type"` \| `"typedef"` \| `"sealed_class"` |
| `superclass` | `string` | Parent type name. |
| `interfaces` | `[string]` | Implemented interfaces/protocols. |
| `mixins` | `[string]` | Applied mixins (Dart, Scala). |
| `on` | `string` or `[string]` | Extension `on` target type, or mixin `on` constraints. |
| `visibility` | `string` | Same as FunctionDefinition. |
| `is_abstract` | `bool` | Abstract class/interface. |
| `is_sealed` | `bool` | Sealed class (C#, Kotlin, Dart 3). |
| `is_final` | `bool` | Final class. |
| `is_base` | `bool` | Base class (Dart 3). |
| `is_interface` | `bool` | Interface class (Dart 3). |
| `is_mixin_class` | `bool` | Mixin class (Dart 3). |
| `doc` | `string` | Documentation comment. |
| `annotations` | `[{name, args?, module?}]` | Class-level annotations. |
| `fields` | `[{name, type?, is_final?, is_const?, is_late?, is_static?, initializer?}]` | Field metadata for round-trip fidelity. |
| `values` | `[{name, args?, doc?}]` | Enum value metadata (constructor args). |
| `rep_type` | `string` | Extension-type representation type (Dart 3 extension types). Only when `kind == "extension_type"`. |
| `rep_field` | `string` | Extension-type representation field name (Dart 3 extension types). Only when `kind == "extension_type"`. |

---

## TypeParameter.metadata

| Key | Type | Description |
|-----|------|-------------|
| `extends` | `string` | Upper bound (`T extends Comparable`). |
| `super` | `string` | Lower bound (Java wildcards: `? super String`). |
| `variance` | `string` | `"covariant"` \| `"contravariant"` \| `"invariant"`. |

---

## TypeAlias.metadata

| Key | Type | Description |
|-----|------|-------------|
| `kind` | `string` | Always `"typedef"`. |
| `aliased_type` | `string` | The aliased type expression source. |
| `visibility` | `string` | Same as FunctionDefinition. |
| `doc` | `string` | Documentation comment. |

---

## Module.metadata

| Key | Type | Description |
|-----|------|-------------|
| `dart_imports` | `[{uri, prefix?, show?, hide?, deferred?}]` | Dart import details. |
| `dart_exports` | `[{uri, show?, hide?}]` | Dart export details. |
| `dart_parts` | `[{uri}]` | `part` directive URIs for round-trip fidelity. |
| `dart_part_of` | `string` | `part of` URI — this file is a part of another library. |
| `csharp_usings` | `[string]` | C# using directives. |
| `cpp_includes` | `[string]` | C++ include directives. |
| `cpp_defines` | `[{name, value?, params?}]` | C++ `#define` directives. `name`: macro name. `value`: replacement text (absent for flag macros). `params`: list of parameter names for function-like macros. Cosmetic only — macros are already expanded by Clang before encoding. |
| `cpp_ifdefs` | `[{condition, body}]` | C++ conditional compilation blocks (`#ifdef`/`#ifndef`). `condition`: macro symbol name. `body`: raw source of the conditional block. Cosmetic only. |
| `cpp_pragmas` | `[string]` | C++ `#pragma` directives (e.g. `"once"`, `"pack(1)"`). Cosmetic only. |
| `rust_use` | `[string]` | Rust use declarations. |
| `java_imports` | `[string]` | Java import declarations. |
| `python_imports` | `[{module, names?, alias?}]` | Python import details. |
| `go_imports` | `[{path, alias?}]` | Go import declarations. |

---

## Program.metadata

| Key | Type | Description |
|-----|------|-------------|
| `source_language` | `string` | Original source language (`"dart"`, `"python"`, etc.). |
| `encoder_version` | `string` | Version of encoder that produced this program. |
| `target_languages` | `[string]` | Intended compilation targets. |

---

## MessageCreation.metadata

| Key | Type | Description |
|-----|------|-------------|
| `is_const` | `bool` | Const constructor call (`const Foo()`). |
| `type_args` | `[{name, type_args?, nullable?}]` | Structured generic type arguments (e.g. `Box<int>` → `[{name: "int"}]`). |
| `kind` | `string` | `"record"` for Dart record literals `(a, b, name: c)`. |

---

## Naming Conventions (Non-Metadata)

These are naming conventions used in references, let-bindings, and function
names. They are NOT metadata fields — they appear as string values within
the expression tree. All are internal conventions; stripping them would
change program semantics.

### `__cascade_self__`

A sentinel reference name for the cascade receiver. When encoding Dart
cascade expressions (`target..a()..b()`), the encoder emits sections that
reference `__cascade_self__` instead of re-evaluating the target. The
compiler recognizes this sentinel and emits cascade syntax.

### `__no_init__`

A sentinel reference used as the initial value of `late` (uninitialized)
variables. The engine treats `__no_init__` as a special marker; accessing
a late variable before assignment throws a runtime error.

### `__type_args__` (MessageCreation field)

**Migrated.** Formerly a legacy field in `MessageCreation.fields` carrying
generic type arguments as a string (e.g. `"<int>"`). Now replaced by
structured `FunctionCall.type_args` (repeated `TypeRef`) and
`MessageCreation.metadata.type_args`. The encoder no longer produces the
`__type_args__` field; compilers retain a legacy fallback for old programs.
The runtime engine reads from the structured metadata. See `proto/ball/v1/ball.proto`
for the `TypeRef` message and the `FunctionCall.type_args` field; `MessageCreation`
has no dedicated proto field — its generic arguments live under
`MessageCreation.metadata` as a `type_args` key.

### Operator method names (`__op_*__`)

Dart operator overloads are encoded as methods with dunder-wrapped names:

| Operator | Method Name |
|----------|-------------|
| `+` | `__op_add__` |
| `-` | `__op_sub__` |
| `*` | `__op_mul__` |
| `/` | `__op_div__` |
| `~/` | `__op_truncate_div__` |
| `%` | `__op_mod__` |
| `==` | `__op_eq__` |
| `<` | `__op_lt__` |
| `>` | `__op_gt__` |
| `<=` | `__op_lte__` |
| `>=` | `__op_gte__` |
| `-` (unary) | `__op_unary_minus__` |
| `[]` | `__op_index__` |
| `[]=` | `__op_index_set__` |
| `~` | `__op_bitwise_not__` |
| `<<` | `__op_shl__` |
| `>>` | `__op_shr__` |
| `>>>` | `__op_ushr__` |
| `&` | `__op_bitwise_and__` |
| `\|` | `__op_bitwise_or__` |
| `^` | `__op_bitwise_xor__` |

The engine's `StdModuleHandler` maps these back to operators for dispatch.
Compilers targeting languages with operator overloading should emit the
native operator syntax using `FunctionDefinition.metadata.is_operator`.

### `__pattern_kind__`

Discriminator field in MessageCreation for structured pattern types in
switch cases. Values: `"record"`, `"var"`, `"type"`, `"wildcard"`,
`"constant"`, `"list"`, `"map"`, `"object"`, `"logicalAnd"`,
`"logicalOr"`. See `docs/PATTERN_DESIGN.md` for the full pattern encoding
scheme.

---

## Ball Scoping Model

Ball uses dot-notation for scope:

```
"x"       → top-level function x in current module
"A.x"     → method x in class A
"A.new"   → default constructor of A
"A.named" → named constructor of A
"B.x"     → override: B extends A, B.x overrides A.x
```

A compiler infers `@override` from `B.x` existing when `superclass: "A"` in TypeDefinition metadata.

---

## Cosmetic vs Semantic Boundary

All metadata is cosmetic. The semantic content of a Ball program is:

1. **Expression tree** — the computation
2. **Function signatures** — input/output type names
3. **Type descriptors** — field names, types, cardinality
4. **Module structure** — grouping and imports

Everything else (visibility, mutability, annotations, syntax sugar) is metadata.
A Ball program with all metadata stripped still computes the same result.

---

## Function Overloading Convention

Ball has no native overloading: every function name in a module must be unique.
Languages with overloading (C++, Java, Dart via optional parameters) are encoded
by **mangling** the function name with a numeric or type-based suffix.

### Encoding

1. The **first** overload keeps the original name: `foo`.
2. Subsequent overloads are named `foo_2`, `foo_3`, … (sequential numeric suffix).
3. The original (un-mangled) name is stored in `metadata.original_name`.
4. The full mangled signature (for C++ ABI fidelity) is stored in `metadata.signature` as a string, e.g. `"void foo(int, double)"`.

| Key | Type | Description |
|-----|------|-------------|
| `original_name` | `string` | Un-mangled function name (e.g. `"foo"`). |
| `signature` | `string` | Full language-level signature string for round-trip fidelity. |
| `overload_index` | `int` | 1-based overload index within functions sharing the same `original_name`. |

### Compiler output

Compilers that target languages with overloading (C++) should use `original_name`
to emit the correct function name and ignore the Ball mangled suffix:

```cpp
// Ball: foo, foo_2, foo_3
// C++ output:
void foo(int x) { ... }           // original_name = "foo", overload_index = 1
void foo(int x, double y) { ... } // original_name = "foo", overload_index = 2
void foo(std::string s) { ... }   // original_name = "foo", overload_index = 3
```

Compilers targeting languages without overloading (Dart, Python) MAY either:

- Emit the mangled name as-is (`foo_2`), or
- Emit a comment and disambiguate using the `signature` metadata.
