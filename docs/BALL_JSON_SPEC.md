# Ball JSON Specification

A narrative companion to [`ball.schema.json`](../ball.schema.json), the
JSON Schema (Draft 2020-12) that mirrors [`proto/ball/v1/ball.proto`](../proto/ball/v1/ball.proto)
field-for-field. This document exists so a language without a protobuf
runtime can still read and emit Ball programs, by implementing the
protobuf-JSON mapping directly against plain JSON — without reading the
Dart reference implementation or linking a protobuf library.

If your target language *does* have a protobuf runtime (most do), prefer
generating typed bindings from `ball.proto` via `buf generate` and skip this
document — the runtime's proto3-JSON codec already implements everything
described here. This spec is for the JSON-only case (write a hand-rolled
parser/serializer against `ball.schema.json`).

Every `*.ball.json` file in this repo — see `examples/**/*.ball.json` and
`tests/conformance/*.ball.json` — validates against `ball.schema.json`.
Run `python scripts/validate_ball_schema.py` to check the whole corpus; that
script is CI's authoritative check that the schema and the real files it
describes have not drifted apart.

## Contents

- [Protobuf-JSON rules](#protobuf-json-rules)
- [The `google.protobuf.Any` envelope](#the-googleprotobufany-envelope)
- [Worked example: a `Block`](#worked-example-a-block)
- [Worked example: `FunctionCall` wrapping `MessageCreation`](#worked-example-functioncall-wrapping-messagecreation)
- [The `null` literal](#the-null-literal)
- [Types: protobuf descriptors, not a Ball type system](#types-protobuf-descriptors-not-a-ball-type-system)
- [`metadata` is cosmetic](#metadata-is-cosmetic)
- [Canonical JSON form](#canonical-json-form)
- [Other top-level document kinds](#other-top-level-document-kinds)

---

## Protobuf-JSON rules

Ball does not define its own JSON mapping — it uses the mapping defined by
the [protobuf JSON spec](https://protobuf.dev/programming-guides/json/)
applied to `ball.proto`. The rules that matter most for a from-scratch
implementer, all enforced by `ball.schema.json`:

### 1. Field names are `lowerCamelCase`

Every proto field is `snake_case` (e.g. `entry_module`, `is_base`,
`field_access`); every Ball-JSON key is the camelCase conversion
(`entryModule`, `isBase`, `fieldAccess`). This is the protobuf-JSON default
(`json_name`) — Ball does not override it anywhere.

### 2. `oneof` fields: the set variant is a plain key, there is no discriminator

Every `oneof` in `ball.proto` (`Expression.expr`, `Literal.value`,
`Statement.stmt`, `ModuleImport.source`, `InlineSource.content`,
`ResolvedDependency.resolved_source`) becomes, in JSON, an object where **at
most one** of the variant field names is present. There is no
`"type": "call"` or `"$kind"` discriminator key — the discriminator *is*
which key is present:

```json
{ "call": { "module": "std", "function": "add", "input": { /* ... */ } } }
```

not

```json
{ "kind": "call", "value": { /* ... */ } }
```

A well-formed `Expression` object therefore has **exactly zero or one** of
`call`, `literal`, `reference`, `fieldAccess`, `messageCreation`, `block`,
`lambda` as a key (`ball.schema.json` enforces this with `maxProperties: 1`
on every oneof-only message). Zero keys present means the oneof is unset —
see [The `null` literal](#the-null-literal) for the one place this shows up
in real programs.

### 3. `int64` / `uint64` are quoted strings

```json
{ "intValue": "9223372036854775807" }
```

never

```json
{ "intValue": 9223372036854775807 }
```

JSON numbers are IEEE-754 doubles and cannot losslessly represent the full
64-bit integer range (anything past 2^53 silently loses precision in a
JSON parser that decodes numbers as `double`/`float64`, which is most of
them — JavaScript's `JSON.parse` included). Every `int64`/`uint64` scalar
in `ball.proto` (`Literal.int_value` is the only one that appears in
practice) is therefore a *string* of decimal digits in Ball-JSON, matching
protobuf's own rule. `int32`/`uint32` fields (e.g.
`FieldDescriptorProto.number`, `CapabilitySummary.total_functions`) are
plain JSON numbers — 32-bit values always fit exactly in a double.

### 4. `bytes` is a base64 string

`Literal.bytes_value`, `ModuleAsset.content`, `InlineSource.proto_bytes` are
all base64-encoded strings using the standard alphabet (RFC 4648 §4), the
protobuf-JSON default.

### 5. Enum values are their string name, never the integer

```json
{ "type": "TYPE_STRING", "label": "LABEL_OPTIONAL" }
```

never `{ "type": 9, "label": 1 }`. This applies to every enum reused from
`google/protobuf/descriptor.proto` (`FieldDescriptorProto.Type`,
`FieldDescriptorProto.Label`) as well as Ball's own `Registry` and
`ModuleEncoding` enums. (A tolerant *parser* may also accept the bare
integer per the protobuf-JSON spec's read-side leniency, but a compliant
*writer* — and the canonical form defined below — always emits the name.)

### 6. Default/zero values may be omitted

A field holding its type's default (`0`, `""`, `false`, an empty list, an
absent message) does not need to appear in the JSON at all. This is why
almost every field in `ball.schema.json` is optional (`required` is nearly
empty everywhere) — omission is always valid. For example, a base function
declaration omits `inputType`, `outputType`, `body`, `description`, and
`metadata` entirely when they're at their defaults:

```json
{ "name": "print", "isBase": true }
```

**The one exception is rule 2**: a field that sits inside a `oneof` is
*always* emitted once that oneof case is selected, even when the value
equals the type's default — because omitting it would make the oneof look
entirely unset instead of "set to the default". This is how the corpus
distinguishes the integer literal `0` from "no literal set":

```json
{ "literal": { "intValue": "0" } }
```

`intValue` is present (case selected, value is zero) — contrast with
`{ "literal": {} }`, where no case is selected at all (see below).

---

## The `google.protobuf.Any` envelope

Every file this repo's encoders/compilers produce
(`tests/conformance/*.ball.json`, `examples/**/*.ball.json`,
`dart/self_host/engine.ball.json`) wraps its `Program` in a self-describing
envelope by adding one extra sibling key, `@type`, alongside the `Program`'s
own fields:

```json
{
  "@type": "type.googleapis.com/ball.v1.Program",
  "name": "encoded",
  "version": "1.0.0",
  "modules": [ /* ... */ ],
  "entryModule": "main",
  "entryFunction": "main"
}
```

This is the standard proto3-JSON representation of a
`google.protobuf.Any{type_url, value}` holding a non-well-known message
type: the `Any`'s own fields are `type_url` (renamed `@type` in JSON) and a
binary `value`, but proto3-JSON *inlines* the wrapped message's fields as
siblings of `@type` instead of nesting them under a `value` key. A tool
reading a `*.ball.json` file can therefore identify what kind of document it
is looking at from `@type` alone, without out-of-band context (a file
extension, a directory convention, etc.) — hence "self-describing".

`@type` is **optional** in `ball.schema.json` — a bare `Program` object
(without the envelope) is equally valid Ball-JSON wherever a `Program` is
expected out-of-band (e.g. a tool that already knows it's reading a
`.ball.json` program file doesn't strictly need the envelope). To strip the
envelope before feeding a JSON object into a plain `Program` parser, just
delete the `@type` key if present:

```js
function unwrapBallFile(json) {
  if (json === null || typeof json !== "object" || Array.isArray(json)) return json;
  if (json["@type"] === undefined) return json;
  const { "@type": _drop, ...rest } = json;
  return rest;
}
```

(this is functionally the same `unwrapBallFile` helper the TS compiler build
step uses to strip `dart/self_host/engine.ball.json`'s envelope before
compiling it — see CLAUDE.md's "TS engine regeneration" command for the
canonical version.)

---

## Worked example: a `Block`

Source (Dart-flavored pseudocode):

```dart
{
  var total = add(x, y);
  print(total);
  total
}
```

Ball-JSON (`Block.statements` is an ordered array of `Statement`; the final
value is `Block.result`, a bare `Expression` — not itself a `Statement`):

```json
{
  "block": {
    "statements": [
      {
        "let": {
          "name": "total",
          "value": {
            "call": {
              "module": "std",
              "function": "add",
              "input": {
                "messageCreation": {
                  "fields": [
                    { "name": "left", "value": { "reference": { "name": "x" } } },
                    { "name": "right", "value": { "reference": { "name": "y" } } }
                  ]
                }
              }
            }
          },
          "metadata": { "keyword": "var" }
        }
      },
      {
        "expression": {
          "call": {
            "module": "std",
            "function": "print",
            "input": {
              "messageCreation": {
                "typeName": "PrintInput",
                "fields": [
                  { "name": "message", "value": { "call": { "module": "std", "function": "to_string", "input": { "messageCreation": { "fields": [ { "name": "value", "value": { "reference": { "name": "total" } } } ] } } } } }
                ]
              }
            }
          }
        }
      }
    ],
    "result": { "reference": { "name": "total" } }
  }
}
```

Notes:
- `Statement` is itself a `oneof` (rule 2): a `let`-binding statement has
  the `let` key, a bare-expression statement (evaluated for side effects,
  value discarded) has the `expression` key. Never both.
- `LetBinding.metadata.keyword` (`"var"` / `"final"` / `"const"`/...) is
  cosmetic — see [`metadata` is cosmetic](#metadata-is-cosmetic). A
  conforming reader can drop it and the program still computes the same
  result; it only affects how a compiler re-emits source-level mutability
  keywords.
- `Block.result` is **required to be structurally present** whenever the
  block is used as a value-producing expression (Ball has no implicit
  `undefined`/fallthrough); a block used purely for side effects still sets
  `result` — typically to a `void`-typed call or an empty-message literal.

---

## Worked example: `FunctionCall` wrapping `MessageCreation`

Every Ball function takes **exactly one input and returns exactly one
output** (the gRPC-style constraint — see CLAUDE.md's Core Invariants #1).
A call site therefore always looks like: a `FunctionCall` whose `input` is a
single `Expression`, and — for any function taking more than zero
"logical" arguments — that `Expression` is almost always a
`MessageCreation` whose fields carry the individual argument values.

`std.add(x, y)`, i.e. `add({left: x, right: y})`:

```json
{
  "call": {
    "module": "std",
    "function": "add",
    "input": {
      "messageCreation": {
        "typeName": "",
        "fields": [
          { "name": "left", "value": { "reference": { "name": "x" } } },
          { "name": "right", "value": { "reference": { "name": "y" } } }
        ]
      }
    }
  }
}
```

Points worth calling out:
- `module` is the local alias from the caller's `Module.moduleImports`
  (`ModuleImport.name`), not necessarily the imported module's own `name`.
  `module: ""` (or the key omitted, since `""` is the default) means "look
  up `function` in the current module" — this is how method calls on a
  user-defined type read (`self.describe()` compiles to a call with an
  empty `module` and `function: "describe"`, `input` a `MessageCreation`
  with a single `self` field).
- `MessageCreation.typeName` is the empty string for these synthetic
  "argument bundle" messages — there is no real user-visible type behind
  `{left, right}`; it exists purely to satisfy the one-input-one-output
  shape. `typeName` is only non-empty when constructing an actual
  `TypeDefinition`-declared type, e.g. `main:Point.new(3, 4)`'s input is
  `{"typeName": "", "fields": [...]}` too (the constructor's positional
  args), while the constructed *value* itself,
  `{"messageCreation": {"typeName": "main:Point", "fields": [...]}}`, has a
  real `typeName`.
- Field *order* inside `fields[]` does not carry meaning beyond matching
  each `FieldValuePair.name` against the callee's declared input
  descriptor — a conforming reader must match by `name`, not position (see
  [Canonical JSON form](#canonical-json-form) for the one place a stable
  order *is* prescribed, for diffing).

---

## The `null` literal

`Literal.value` has no dedicated "null" variant in `ball.proto` — the
`oneof` only lists `int_value`, `double_value`, `string_value`,
`bool_value`, `bytes_value`, `list_value`. Ball represents "no value" the
same way protobuf represents "oneof case unset": an entirely empty
`Literal` object.

```json
{ "literal": {} }
```

This is exactly what the Dart encoder emits for a source-level `null`
literal (see `tests/conformance/194_null_handling.ball.json`, which
round-trips a nullable parameter through this exact shape, including inside
a `listValue.elements[]`). A reader must treat `{}` at a `Literal` position
as the null value, distinct from `{}` never appearing at all (a field whose
type is `Expression` but which is entirely absent means "this optional
message-typed field is unset", a different condition — e.g. `Constant`
declared without a `value`, which is not something the corpus does but the
schema permits since `Constant.value` is an ordinary optional message
field).

---

## Types: protobuf descriptors, not a Ball type system

Ball does not invent its own type-declaration syntax. A `TypeDefinition`'s
fields are described with `google.protobuf.DescriptorProto` — the same
message protoc uses internally to describe a `.proto` message — and
`Module.enums` uses `google.protobuf.EnumDescriptorProto` directly:

```json
{
  "name": "main:Point",
  "descriptor": {
    "name": "main:Point",
    "field": [
      { "name": "x", "number": 1, "label": "LABEL_OPTIONAL", "type": "TYPE_INT64" },
      { "name": "y", "number": 2, "label": "LABEL_OPTIONAL", "type": "TYPE_INT64" }
    ]
  },
  "metadata": { "kind": "class", "fields": [ { "name": "x", "type": "int" }, { "name": "y", "type": "int" } ] }
}
```

Every target language already has a protobuf-descriptor-to-native-type
mapping (that's the entire point of protobuf codegen), so reusing
`DescriptorProto` means Ball gets `int32`/`int64`/`string`/nested
message/`repeated`/etc. type mapping across every language "for free" — no
Ball-specific type mapping table exists or needs to. `ball.schema.json`'s
`$defs.DescriptorProto` / `$defs.FieldDescriptorProto` mirror the subset of
`descriptor.proto` Ball actually reuses; message-option/field-option
sub-messages (`FieldOptions`, `MessageOptions`, ...) are modeled as opaque
JSON objects (`google.protobuf.Struct`-shaped) since Ball itself never
populates them.

`TypeRef` (used for generic type arguments and function-call
`typeArgs`) is Ball's own, much smaller, structured type reference — *not*
a `DescriptorProto` — because it needs to express things a field descriptor
can't, like an unresolved generic parameter or nullability at a call site:

```json
{ "name": "Map", "typeArgs": [ { "name": "String" }, { "name": "List", "typeArgs": [ { "name": "int", "nullable": true } ] } ] }
```

`Map<String, List<int?>>`.

---

## `metadata` is cosmetic

Every message that carries a `metadata` field types it as
`google.protobuf.Struct`, which the proto3-JSON mapping serializes as a
plain JSON object with arbitrary JSON-typed values (`GoogleValue` in
`ball.schema.json`: `null | number | string | bool | object | array`,
recursively — this is *the entire mapping*, `Struct`/`Value`/`ListValue`
carry no other structure in JSON). Ball's core invariant (CLAUDE.md #2):
**stripping every `metadata` field from a program must never change what it
computes.** `metadata` only carries information a target compiler may use
to make its emitted source look more idiomatic — visibility keywords,
parameter names/kinds, doc comments, annotations, constructor vs. method
`kind`, and so on. See [`docs/METADATA_SPEC.md`](METADATA_SPEC.md) for the
full catalog of keys compilers understand. A JSON-only implementer that
skips `metadata` entirely still gets a semantically correct compiler/engine
— just one that emits less idiomatic-looking target source.

---

## Canonical JSON form

For diffing and tooling (e.g. deterministic content hashes for
`ModuleImport.integrity`), Ball defines one canonical JSON serialization
per message, on top of the protobuf-JSON rules above:

1. **Field order**: object keys appear in **ascending protobuf field-number
   order** — *not* the textual order fields happen to be written in
   `ball.proto` (which, for `Module`, is not itself number-sorted: `name=1`
   is followed by `enums=7` in the `.proto` source, but `enums` still
   serializes *after* `functions=3`/`description=5`/`metadata=6`, because 7
   is the larger field number), and not alphabetical. E.g. a canonical
   `Expression` object with a `call` key sorts before one with a `literal`
   key only because `call = 1` precedes `literal = 2` — but since at most
   one key is ever present (rule 2), this only matters for the non-oneof,
   multi-field messages (`Program`, `Module`, `FunctionDefinition`, ...).
   This is what protobuf's own generated JSON serializers already do (they
   walk fields by number, not by source order), and it's exactly the order
   every fixture under `tests/conformance/` and `examples/` is already in —
   e.g. a `Module` with both `enums` and `typeAliases` present always shows
   `..., "metadata", "enums", "typeDefs", "typeAliases"` (field numbers 6,
   7, 8, 11), never `enums` ahead of `metadata`.
2. **Default omission is mandatory, not optional**: rule 6 says a
   default-valued field *may* be omitted; the canonical form says it *must*
   be, for every field outside a oneof. (Fields inside a oneof still always
   appear per rule 2's exception.) Two programs that differ only in whether
   they spell out `"nullable": false` or `"description": ""` are the same
   program and must canonicalize to byte-identical JSON.
3. **No insignificant whitespace**: canonical form is the minified
   (no extra whitespace) UTF-8 JSON text, `\n`-free, keys and string values
   using JSON's standard escaping (no raw control characters).
4. **Base64/int64-string/enum-name rules (1–5 above) are unconditional** —
   there is no alternate "canonical" encoding for those; the protobuf-JSON
   representation *is* the canonical one for those scalar kinds.

A round-trip test — Ball → canonical JSON → Ball → canonical JSON again,
asserting byte-identical output on the second pass — is the way to verify a
new-language JSON reader/writer implements this correctly without needing a
protobuf library at all. (`ball.schema.json` validates *shape*; it cannot
by itself verify field *order*, since JSON Schema has no concept of object
key ordering — order is a serializer-level guarantee this document defines
separately.)

---

## Other top-level document kinds

A `*.ball.json` **program** file's root is always a `Program` (optionally
`@type`-enveloped, see above). Ball defines a few other top-level document
kinds that are *not* produced at a program file's root but that
`ball.schema.json` still fully models under `$defs`, for direct validation
of those file kinds:

| Kind | File convention | Validate against |
| --- | --- | --- |
| Program | `*.ball.json` | `ball.schema.json` root (this doc) |
| Module (standalone / `InlineSource.json`) | embedded, or `module.ball.json` | `ball.schema.json#/$defs/Module` |
| Package manifest | `ball.yaml` (YAML) or `ball.manifest.json` | `ball.schema.json#/$defs/BallManifest` |
| Lockfile | `ball.lock.json` | `ball.schema.json#/$defs/BallLockfile` |
| Capability report (`ball audit` output) | tool-defined | `ball.schema.json#/$defs/BallCapabilityReport` |

All four follow the same protobuf-JSON rules described above; only the
message shape differs.
