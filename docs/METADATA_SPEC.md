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
| `kind` | `string` | `"cascade"` when this binding is the receiver a lowered cascade re-applies its sections to (see `__cascade_self__` below). |
| `null_aware` | `bool` | With `kind: "cascade"`, the source wrote `?..` — the sections run only when the receiver is non-null. |

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
| `fields` | `[{name, type?, is_final?, is_const?, is_late?, is_static?, initializer?}]` | Field metadata for round-trip fidelity. `is_final` additionally participates in **accessor shape** — see "Accessor shape" below. |
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

The Dart encoder lowers a cascade it cannot route to a collection base
function into a `Block`:

```
Block {
  let __cascade_self__ = <target>     // metadata.kind == "cascade"
  <section>; <section>; …             // each references __cascade_self__
  result = reference(__cascade_self__)
}
```

with the null-aware (`?..`) form nesting the sections one `Block` deeper,
behind `std.if(std.equals(__cascade_self__, null), null, …)`. Engines execute
that Block directly. A compiler emitting a language that HAS cascades should
recognize the shape — keyed on the `kind == "cascade"` tag, never on the
Block's shape alone — and emit native `..` syntax: lowering it to a closure
instead (Dart's `(() { … })()`) is semantically correct but interposes a
function boundary that Dart's flow analysis will not carry a local's type
promotion across (issue #573).

### `__no_init__`

A sentinel reference used as the initial value of `late` (uninitialized)
variables. The engine treats `__no_init__` as a special marker; accessing
a late variable before assignment throws a runtime error.

### `__type_args__` (MessageCreation field)

**Migrated.** Formerly the only carrier of a `MessageCreation`'s generic type
arguments, as a raw string (e.g. `"<int>"`). The structured
`MessageCreation.metadata.type_args` (a list of `TypeRef`s, the sibling of
`FunctionCall.type_args`) is now the semantic source of truth, and compilers
prefer it. The Dart encoder still writes `__type_args__` alongside it because
the compiled engines' proto3-JSON wrapper cannot resolve the
`metadata.type_args` `structValue` chain; compilers keep the legacy fallback
for old programs. Both are set from one place
(`_setTypeArgsMetadata` / `_setTypeArgsField`), so they never disagree.

The Dart encoder fills them from the type arguments written in SOURCE syntax
and, on a `PackageEncoder.prepareStaticTypes()`-resolved AST, from the ones the
analyzer INFERRED where the source elided them (`StreamController(sync: true)`
in a `StreamSink<S>`-returning method, issue #573). It does not annotate an
inference that is `dynamic` throughout, which would add nothing. The
resolution-free `encode(String)` / `encodeModule` paths leave `staticType`
null and are unaffected. See `proto/ball/v1/ball.proto`
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

### Accessor shape — the one closed family metadata participates in

Accessors are the single place where the rule above needs saying precisely
rather than loosely. Ball has no accessor node type: a getter and a setter are
ordinary `FunctionDefinition`s, and the ONLY thing that says `main:Box.value` is
a setter rather than a method named `value` is `FunctionDefinition.metadata`'s
`is_getter` / `is_setter`. Strip those and a class has no accessors at all —
every `obj.x = v` is a plain field write, every `obj.x` a plain field read, and
the program is still internally consistent. That is the sense in which accessor
metadata is cosmetic: it never changes what an expression *tree* means, only
which declaration a field access resolves to.

`fields[].is_final` belongs to that same closed family, and engines read it for
exactly one decision (issue #664): **does this field's own declaration
contribute a setter?** A non-`final` field does, so it shadows any setter
inherited from an ancestor and the write is a plain field write (issue #501). A
`final` field contributes a getter and nothing else, so a setter declared
alongside it — legal in Dart, and the shape `collection`'s `ListSlice` uses —
is the only setter for that name and must run.

Keep the family closed. `is_const` / `is_late` / `is_static` / `visibility`, and
every other key in this document, stay purely cosmetic; do not widen the set of
keys an engine dispatches on without amending this section.

### Extension overrides ride the function NAME, not metadata (issue #670)

Dart's `Ext(receiver).member(args)` names WHICH extension supplies `member`, and
it is written precisely when the plain `receiver.member(args)` would resolve to
something else — `collection`'s `IterableComparableExtension.isSorted` calls
`IterableExtension(this).isSorted(compare)`, and erasing the override makes it
call itself. So the selection changes what the program computes and, by the rule
above, may **not** live in metadata.

It does not have to. An extension member is already declared as a module
function named `<module>:<Ext>.<member>`, and a `FunctionCall` already carries
its receiver in the input message's `self` field — the shape every instance call
uses. An override is therefore:

```
Ext(receiver).member(a, b)
  ⇒ FunctionCall{ module:   <module>,
                  function: "<module>:<Ext>.<member>",
                  input:    MessageCreation{ self: receiver, arg0: a, arg1: b } }
```

`<module>` is the module that DECLARES the extension, which need not be the one
making the call: `Ext` may live in another module of the same program, and the
call's `module` field names that one. A source-level import prefix
(`p.Ext(x).m()`) is a spelling of the same library and produces the same name —
which is the point, since two same-named extensions in two modules already
differ by their qualifier.

The name is semantic content, so the selection survives metadata stripping. No
schema change, and no new dispatch key: a `self`-carrying call whose qualifier is
not an extension typeDef still compiles to `self.member(args)` exactly as before.

Explicit type arguments written on the MEMBER (`Ext(x).m<int>()`) ride
`FunctionCall.type_args` — a real schema field, not metadata — exactly as they
do for every other instance call, because an instantiation changes what the
program computes too. (Type arguments on the EXTENSION, `Ext<int>(x)`, have no
sound home in this shape and are refused by the encoder. So is a NULL-AWARE
override, `Ext(x)?.m()`: the `?` decides whether the member runs at all, and
this shape has nowhere to put that guard without let-binding the receiver, so
the encoder refuses rather than emitting an unguarded call.)

Two metadata keys are read while RENDERING that call back to Dart, and both are
already in the closed family above. `TypeDefinition.metadata['kind'] ==
"extension"` is what makes the qualifier an extension at all — strip it and the
module stops declaring an extension, so the override has nothing to name and the
whole declaration degrades together, consistently. `is_getter` / `is_setter` on
the member decide `Ext(x).member` versus `Ext(x).member()`, which is the same
accessor question the section above answers for `obj.x` — and a WRITE
(`Ext(x).member = v`) encodes as that same call, so reading the setter's shape
is what keeps the emitted left-hand side assignable. Neither widens the family.

#### Recognising the override without an element model

Only a RESOLVED analyzer AST carries an `ast.ExtensionOverride` node:
`parseString` cannot know an identifier names an extension, so
`Ext(receiver).member` arrives there as an ordinary `ast.MethodInvocation`
`Ext(receiver)` in target position. That is the path
`generate_conformance.dart`, `ball encode` and `/ball:convert` use, so it is how
an override reaches the conformance corpus and every non-Dart target — and it
must produce the SAME IR, or the two parses disagree about what a program means.

The encoder reads it without resolution because `Ext` is a name it already
collected: the unit's extension declarations are gathered before any body is
encoded, and **Dart cannot construct an extension**, so an invocation of that
name in target position is unambiguously an override. Left to the generic
encoding it became a `MessageCreation` of the extension TYPE with the receiver
buried as `arg0` — a silent, running, wrong answer.

An extension declared in another LIBRARY is deliberately not recognised that
way: the parser cannot see it, so the resolved path (which resolves the
declaring module from the override's own element) is the only one that may name
those.

#### What a target does with the name

Only Dart has extensions, so only Dart re-emits `Ext(receiver).member`. Every
other compiler reaches the member the name selects, by whatever shape it already
emits that member under:

| target | emission for `<module>:<Ext>.<member>` with `self` |
|---|---|
| Dart | `Ext(receiver).member(args)` — the override form |
| Go | the member's impl func, `Ext__member(input)` |
| Rust | the member's associated fn, `<module>_Ext::member(input)` |
| C# | the member's impl method, `<Module>.Ext__member(input)` |
| Python | the member unbound on its class, `Ext.member(recv, …)` (`Ext.member.fget(recv)` for a getter) |
| TypeScript | the member on the class PROTOTYPE with the receiver as `this` — `.call` for a method, `Reflect.get` for a getter |
| C++ | the member lowered to a FREE function taking the receiver as parameter 0 |

The three targets whose ordinary instance-call emission is a **receiver-asking
dispatcher** (Go, Python, C#) are the reason this cannot be left to the generic
path: such a dispatcher switches on the RECEIVER's runtime type, and an
extension receiver is an ordinary list/string/map, so it can never pick between
two extensions declaring the same member on the same type — which is the only
situation an override is ever written for.

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
