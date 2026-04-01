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
| `expression_body` | `bool` | Emit `=> expr` form (Dart) / expression body (C#). |
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
| `kind` | `string` | `"class"` \| `"struct"` \| `"trait"` \| `"interface"` \| `"mixin"` \| `"enum"` \| `"union"` \| `"record"` \| `"extension"` \| `"typedef"` \| `"sealed_class"` |
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
| `csharp_usings` | `[string]` | C# using directives. |
| `cpp_includes` | `[string]` | C++ include directives. |
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
