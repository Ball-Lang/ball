# Implementing a Ball Compiler

This document is the contract for anyone writing a new Ball target-language
compiler (C#, C++, Rust, Java, Python, Go, etc.). You should not need to
read the Dart compiler source code.

---

## Architecture Overview

A Ball compiler translates a `Program` protobuf message into source code
for a specific target language. The program is a tree:

```
Program
 ├── name, version, entryModule, entryFunction
 └── modules[]
      ├── name, description
      ├── typeDefs[]        (TypeDefinition — descriptor + cosmetic metadata; the only type-declaration path)
      ├── typeAliases[]     (TypeAlias — typedef/using)
      ├── enums[]           (google.protobuf.EnumDescriptorProto)
      ├── moduleConstants[] (Constant — module-level constants)
      ├── functions[]       (FunctionDefinition — code)
      └── moduleImports[]   (ModuleImport — dependencies)
```

## Step-by-Step Guide

### 1. Parse the Program

Deserialize from protobuf binary or JSON:

```python
# Python
program = ball_pb2.Program()
program.ParseFromString(data)  # or json_format.Parse(json_str, program)
```

```csharp
// C#
var program = Program.Parser.ParseFrom(data);
```

### 2. Build Lookup Tables

Index all types and functions by name for O(1) resolution:

```
types["PrintInput"] → DescriptorProto
types["std.PrintInput"] → DescriptorProto
functions["std.print"] → FunctionDefinition { isBase: true }
functions["main.fibonacci"] → FunctionDefinition { body: Expression }
```

Also index `typeDefs` — each `TypeDefinition` has a `descriptor` field
containing the same `DescriptorProto`, plus `typeParams` and `metadata`.

### 3. Identify Base Modules

Modules where **every** function has `isBase = true` are base modules.
Your compiler must provide native implementations for these functions.

Required base modules:
- **`std`** — 118 declared base functions in `std.json` (arithmetic, comparison, logic, control flow, strings, math, etc.) plus additional engine-registered functions (`string_interpolation`, `cascade`, `null_aware_cascade`, `null_aware_access`, `spread`, `null_spread`, `invoke`, `paren`, etc.) that compilers and engines must also handle
- **`std_collections`** — list/map/set operations (optional — not all runtimes)
- **`std_io`** — console, process, time, random (optional — not all runtimes)

> **Note:** Language-specific base modules (`dart_std`, `cpp_std`) have been eliminated.
> All constructs now route through universal `std` operations. Encoders expand
> language-specific constructs at encoding time rather than emitting language-specific
> base function calls.

### 4. Generate Imports

Read `Module.metadata` for language-specific import details:

```json
{
  "dart_imports": [{"uri": "dart:math", "prefix": "math"}],
  "csharp_usings": ["System", "System.Collections.Generic"],
  "python_imports": [{"module": "math", "names": ["sqrt", "pi"]}]
}
```

Emit the appropriate import/include/using statements.

### 5. Generate Type Definitions

#### From `typeDefs[]` (preferred, first-class)

Each `TypeDefinition` has:
- `name` — type name
- `descriptor` — protobuf `DescriptorProto` with field definitions
- `typeParams[]` — generic type parameters
- `metadata` — cosmetic hints (see METADATA_SPEC.md)

Read `metadata.kind` to determine what to emit:

| `kind` | Dart | C# | C++ | Rust | Java | Python |
|--------|------|-----|-----|------|------|--------|
| `class` | `class Foo` | `class Foo` | `class Foo` | `struct Foo` | `class Foo` | `class Foo` |
| `struct` | N/A | `struct Foo` | `struct Foo` | `struct Foo` | `record Foo` | `@dataclass` |
| `interface` | `abstract class` | `interface IFoo` | pure virtual | `trait Foo` | `interface Foo` | `Protocol` |
| `mixin` | `mixin Foo` | N/A | N/A | `trait Foo` | N/A | mixin class |
| `enum` | `enum Foo` | `enum Foo` | `enum class` | `enum Foo` | `enum Foo` | `Enum` |
| `extension` | `extension Foo` | extension method | N/A | `impl Foo` | N/A | N/A |

Read `metadata.superclass`, `metadata.interfaces`, `metadata.mixins` for
inheritance. Read `metadata.fields` for field-level cosmetic hints (type,
is_final, is_late, initializer).

> **Removed:** the legacy `Module.types` field (bare descriptors) and the
> `_meta_<TypeName>` function hack no longer exist — proto field 2 was removed
> and `reserved`. All type declarations come through `typeDefs[]`. If you ingest
> very old `.ball.json` programs that still carry a `types`/`_meta_*` shape, run
> `scripts/migrate_types_to_typedefs.py` to convert them first.

#### From `typeAliases[]`

Emit `typedef`/`using`/`type` as appropriate for the target language.

### 6. Generate Functions

For each non-base `FunctionDefinition`:

1. Read `metadata.kind` to determine what to emit
2. Read `metadata.params` for parameter names, kinds, defaults
3. Read `outputType` / `inputType` for return/parameter types
4. Recursively compile `body` (an `Expression` tree)

#### Function Kinds

| `kind` | Meaning |
|--------|---------|
| `function` | Top-level function |
| `method` | Instance method (name = `"ClassName.methodName"`) |
| `constructor` | Constructor (name = `"ClassName.new"` or `"ClassName.named"`) |
| `getter` | Property getter (`is_getter: true`) |
| `setter` | Property setter (`is_setter: true`) |
| `operator` | Operator overload (`is_operator: true`) |
| `static_field` | Static field with initializer |
| `top_level_variable` | Top-level variable |

### 7. Compile Expressions

The expression tree is the core of every Ball program. Every node is one of:

| Expression variant | Meaning |
|---|---|
| `call` | Call a function: `{module, function, input}` |
| `literal` | Literal value: int, double, string, bool, bytes, list |
| `reference` | Variable reference: `{name}` |
| `fieldAccess` | Field access: `{object, field}` |
| `messageCreation` | Construct message: `{typeName, fields[]}` |
| `block` | Sequential statements + result expression |
| `lambda` | Anonymous function (FunctionDefinition with name = "") |

#### Compiling `call` — the critical path

A `FunctionCall` has `{module, function, input}`.

**If the function is a base function** (from std/std_collections/std_io), emit
the native language equivalent:

```
std.add          →  left + right          (extract fields from input MessageCreation)
std.print        →  print(message)
std.if           →  if (condition) then else
std.for          →  for (init; cond; update) body
std.string_trim  →  value.trim()
std.math_sqrt    →  sqrt(value)          or  Math.sqrt(value)
```

**If the function is user-defined**, emit a function call to the generated
function name.

#### Extracting fields from MessageCreation input

Most base function calls have a `MessageCreation` as input:

```json
{
  "call": {
    "module": "std",
    "function": "add",
    "input": {
      "messageCreation": {
        "typeName": "BinaryInput",
        "fields": [
          {"name": "left", "value": {"reference": {"name": "x"}}},
          {"name": "right", "value": {"literal": {"intValue": "1"}}}
        ]
      }
    }
  }
}
```

Extract `left` and `right` from the fields to emit `x + 1`.

### 8. Handle Control Flow (Lazy Evaluation)

Control flow functions (`std.if`, `std.for`, `std.while`, `std.try`,
`std.switch`) must be compiled structurally, not as function calls:

```
std.if
  → extract condition, then, else from input fields
  → emit: if (condition) { then } else { else }

std.for
  → extract init, condition, update, body
  → emit: for (init; condition; update) { body }
```

The input MessageCreation fields contain Expression trees — compile
them recursively.

### 9. Handle Blocks and Statements

A `Block` contains:
- `statements[]` — each is either a `LetBinding` or bare `Expression`
- `result` — final expression whose value is returned

A `LetBinding` has `{name, value, metadata}`. Read metadata for type
annotation and mutability hints.

### 10. Generate Entry Point

The program specifies `entryModule` and `entryFunction`. Generate a
`main()` function (or equivalent) that calls it.

---

## Base Function Reference

### std (universal, required)

#### Arithmetic
`add`, `subtract`, `multiply`, `divide` (integer), `divide_double`,
`modulo`, `negate`

#### Comparison
`equals`, `not_equals`, `less_than`, `greater_than`, `lte`, `gte`

#### Logical
`and`, `or`, `not`

#### Bitwise
`bitwise_and`, `bitwise_or`, `bitwise_xor`, `bitwise_not`,
`left_shift`, `right_shift`, `unsigned_right_shift`

#### Increment/Decrement
`pre_increment`, `post_increment`, `pre_decrement`, `post_decrement`

#### String & Conversion
`concat`, `to_string`, `length`, `int_to_string`, `double_to_string`,
`string_to_int`, `string_to_double`

#### Engine-Registered std Functions (not in std.json but required)

`string_interpolation`, `cascade`, `null_aware_cascade`, `null_aware_access`,
`spread`, `null_spread`, `invoke`, `paren`

#### Strings (pure manipulation)
`string_length`, `string_is_empty`, `string_concat`, `string_contains`,
`string_starts_with`, `string_ends_with`, `string_index_of`,
`string_last_index_of`, `string_substring`, `string_char_at`,
`string_char_code_at`, `string_from_char_code`, `string_to_upper`,
`string_to_lower`, `string_trim`, `string_trim_start`, `string_trim_end`,
`string_replace`, `string_replace_all`, `string_split`, `string_repeat`,
`string_pad_left`, `string_pad_right`

#### Math (pure numeric)
`math_abs`, `math_floor`, `math_ceil`, `math_round`, `math_trunc`,
`math_sqrt`, `math_pow`, `math_log`, `math_log2`, `math_log10`,
`math_exp`, `math_sin`, `math_cos`, `math_tan`, `math_asin`,
`math_acos`, `math_atan`, `math_atan2`, `math_min`, `math_max`,
`math_clamp`, `math_pi`, `math_e`, `math_infinity`, `math_nan`,
`math_is_nan`, `math_is_finite`, `math_is_infinite`, `math_sign`,
`math_gcd`, `math_lcm`

#### Control Flow
`if`, `for`, `for_in`, `while`, `do_while`, `switch`, `try`,
`return`, `break`, `continue`, `throw`, `rethrow`, `assert`

#### Null Safety
`null_coalesce`, `null_check`

#### Type Operations
`is`, `is_not`, `as`

#### Assignment
`assign`

#### Indexing
`index`

#### Generators & Async
`yield`, `await`

### std_collections (optional)

List: `list_push`, `list_pop`, `list_insert`, `list_remove_at`,
`list_get`, `list_set`, `list_length`, `list_is_empty`, `list_first`,
`list_last`, `list_contains`, `list_index_of`, `list_map`, `list_filter`,
`list_reduce`, `list_find`, `list_any`, `list_all`, `list_none`,
`list_sort`, `list_reverse`, `list_slice`, `list_flat_map`, `list_zip`,
`list_take`, `list_drop`, `list_concat`, `string_join`

Map: `map_get`, `map_set`, `map_delete`, `map_contains_key`, `map_keys`,
`map_values`, `map_entries`, `map_from_entries`, `map_merge`, `map_map`,
`map_filter`, `map_is_empty`, `map_length`

### std_io (optional, not available on all runtimes)

Console: `print_error`, `read_line`
Process: `exit`, `panic`
Time: `sleep_ms`, `timestamp_ms`
Random: `random_int`, `random_double`
Environment: `env_get`, `args_get`

---

## Testing Your Compiler

1. **Hello World** — `examples/hello_world/hello_world.ball.json` should produce working output
2. **Fibonacci** — `examples/fibonacci/fibonacci.ball.json` exercises recursion, comparison, arithmetic
3. **Comprehensive** — `examples/comprehensive/comprehensive.ball.json` exercises classes, enums, control flow
4. **Round-trip** — encode a target-language file → ball → compile back → output matches

---

## Common Pitfalls

1. **Don't evaluate control flow eagerly.** `std.if` input fields must not
   all be evaluated before deciding which branch to take.

2. **MessageCreation fields are the parameters.** When compiling `std.add`,
   extract `left` and `right` from the input's `messageCreation.fields`.

3. **Empty module name = current module.** A `FunctionCall` with `module: ""`
   refers to the module containing the calling function.

4. **Lambda = FunctionDefinition with empty name.** Compile it as an
   anonymous function / closure / lambda expression.

5. **Types come from `typeDefs[]` / `typeAliases[]` only.** The legacy
   `Module.types` field and `_meta_*` function hack were removed (proto field 2
   is `reserved`). Don't emit or scan for them.

6. **Metadata is optional and cosmetic.** Your compiler must produce valid
   code even if all metadata is stripped. Use metadata to improve output
   quality (proper type annotations, visibility, etc.) but don't depend
   on it for correctness.

---

## Cross-Target Design Notes

Durable design guidance distilled from the cross-target research (DDC/dart2js,
Kotlin/JS, Scala.js, Haxe, KMP, Nim, LLVM, GraalVM Truffle, AssemblyScript,
Emscripten, protobuf-es, CrossTL). These are the contracts a new compiler must
honor so that a Ball program computes the same answer regardless of which
compiler processes it. (Open, target-specific gap work — Rust/Go error-model
strategy, ownership modules, UTF-8 string indexing, etc. — is tracked in
[#132](https://github.com/Ball-Lang/ball/issues/132).)

### Reified Generics

JS erases generic type parameters (`new Box<int>(42) instanceof Box` is `true`
for any `Box<T>`). Dart, C#, and the CLR keep generics reified; Java, Kotlin,
Scala, and Go erase them; C++ and Rust monomorphize. A Ball compiler that must
support a parameterized `std.is(value, "Box<int>")` check lowers it per target:

| Target | Mechanism |
|--------|-----------|
| Dart | Native reified generics — emit `is List<int>` directly |
| TypeScript / JS | Type-descriptor `type_args` array on the instance (opt-in) |
| C++ / Rust | Monomorphization via templates / generics — distinct types |
| Java | Type-descriptor objects (JVM erases generics — same as TS) |
| Go | Type-tag field on the struct (no generics runtime checks) |
| Python | `isinstance()` + a `type_args` attribute |
| C# | Native reified generics (CLR supports them) |

**Key invariant:** programs that perform no parameterized type checks pay zero
cost. A compiler only emits type descriptors when the IR actually contains a
generic `is`-check; the structured generic arguments arrive via
`FunctionCall.type_args` / `MessageCreation.metadata.type_args` (see
METADATA_SPEC.md), not the legacy `__type_args__` string.

### BigInt / Int64 Cross-Target Contract

**Ball integers are signed 64-bit with wrapping overflow.** Every target must
preserve that semantics:

- Native-int64 targets (Dart, C++, Rust, Go, Java, Python, C#) use the platform
  integer; emit wrapping operations where the platform would trap or widen
  (Rust `wrapping_add`, C++ `-fwrapv`/explicit cast, Go's naturally-wrapping
  `int64`).
- **JavaScript / TypeScript has no native 64-bit integer**, so the TS compiler
  uses a **promotion-demotion** pattern:
  - emit `BigInt` literals for values beyond `Number.MAX_SAFE_INTEGER`;
  - arithmetic helpers promote to `BigInt` when either operand is a `BigInt`,
    then demote the result back to `Number` when it fits the safe range;
  - bitwise ops always go through `BigInt` (JS operators truncate to 32 bits);
  - signed 64-bit wrapping uses `BigInt.asIntN(64, v)`.

`BigInt` is a **JS-only implementation detail** — it must never leak into the
Ball IR or any other target. The demotion path keeps the common small-integer
case on `Number` (BigInt arithmetic is several times slower than `Number` in V8).
This contract aligns with protobuf-es v2, wasm-bindgen, and Emscripten. Fully
implemented in the TS compiler's preamble (`asIntN`/`asUintN` wrapping,
null/NaN-hardened promotion, a `BigInt.prototype.toJSON`, and a 32-bit fast
path that skips `BigInt` entirely when both bitwise operands already fit in
`Int32` — see `ts/compiler/src/preamble.ts`).

### Map Key Constraint

**Ball map keys are strings.** `std_collections.map_get`/`map_set`/
`map_delete`/`map_contains_key`/etc. and map-literal `MessageCreation` nodes
all key on `string`, matching protobuf's own `map<string, V>` restriction
(Ball programs *are* protobuf messages, so this isn't an arbitrary choice —
it's inherited from the wire format every target must round-trip through).
A target whose
native map type allows arbitrary key types (Python `dict`, C++
`std::map<K,V>`) must still constrain the *Ball-visible* map surface to
string keys; do not widen `std_collections` to accept non-string keys.

Programs that need non-string keys today encode them as strings at the call
site (e.g. `int_key.toString()`) — there is no `typed_map_*` family yet. If a
future target's idiomatic style makes that awkward enough to matter, propose
a `std_collections.typed_map_*` extension in a new issue; don't special-case
it in a single compiler.

### String Indexing Convention

**`string_char_at(s, i)` indexes by UTF-16 code unit**, matching Dart's
`String` (Dart strings are UTF-16 internally) and JavaScript's `String`
(native UTF-16). This is a zero-cost mapping for Dart and TS/JS — both
target languages already index this way natively.

UTF-8-native targets (Rust `&str`, Go `string`, C++ `std::string`) do **not**
index by UTF-16 code unit for free: Rust/Go strings are byte sequences of
UTF-8, and naive byte-indexing at a UTF-16 code-unit offset produces wrong
(or invalid, mid-codepoint) results for any string containing non-ASCII
characters. Two options, in order of preference when bootstrapping one of
these targets:

1. **Emulate UTF-16 code-unit indexing** (e.g. by decoding to UTF-16 code
   units internally, or precomputing a code-unit-to-byte-offset table) so
   `string_char_at` stays behaviorally identical across every target. This
   preserves conformance-corpus compatibility but costs something on the
   UTF-8 target.
2. **Add `std.string_char_at_codepoint(s, i)`** — a *codepoint*-indexed
   sibling that every target (including Dart/TS) can implement natively and
   cheaply, and steer UTF-8-target-authored programs toward it. This is the
   still-open action item from #132: it needs a `std.json` entry, Dart/TS/C++
   engine + compiler implementations, and a conformance fixture before any
   UTF-8 target can rely on it (not yet implemented anywhere as of this
   writing — do not assume it exists).

Either way: **do not silently truncate or reinterpret** a code-unit index as
a byte or codepoint index. An out-of-range or mid-codepoint index must fail
loud (matching invariant #4 in `CLAUDE.md` / the engine's fail-loud
convention), never return a mangled character.

### Nullable Type Representation

**Already solved — not the fragile `"int?"` metadata string.** Structured
nullability lives in `MessageCreation.metadata.type_args[].nullable` (a
proper `bool` field alongside `name`/`type_args`), documented in
`METADATA_SPEC.md` (`MessageCreation.metadata`) and `BALL_JSON_SPEC.md`
(nullable-parameter round-trip example). The `FunctionCall.type_args` /
`MessageCreation.metadata.type_args` migration replaced the old
`__type_args__` string-encoding convention outright — new compilers should
read the structured field and never need to parse a `"Type?"` string suffix.

### Multi-Target Compiler Patterns

1. **Capability declaration.** Each compiler should declare how it handles every
   base function — *legal* (direct equivalent, `std.add` → `+`), *expand*
   (decompose, `std.for_each` → a loop), *libcall* (runtime library call), or
   *custom* (target-specific lowering). A conformance matrix then detects gaps
   automatically when a new target is added (the KMP `expect`/`actual` idea).
2. **Module hierarchy for partial sharing.** Ball is universal-first: there are
   no language-specific base modules. Encoders expand language-specific
   constructs into universal `std` expression trees at encoding time. The
   hierarchy is `std` (universal — includes cascade, spread, invoke,
   null_aware_access, …) with `std_collections`, `std_io`, `std_memory`,
   `std_convert`, `std_fs`, `std_time`, and `std_concurrency` layered on top. Any
   future language-specific module should hold only cosmetic helpers, never base
   functions every target must implement.
3. **The IR must not encode target-specific semantics.** Ball's "metadata is
   cosmetic" invariant enforces this: a program's computed output must be
   identical regardless of which compiler processes it. Metadata controls
   formatting and naming, never behavior.
4. **Memory-model isolation.** Memory-management differences belong in dedicated
   modules (`std_memory` for C/C++ linear memory today; an ownership module for
   Rust, GC hints for managed targets, if ever needed), not bled into `std`.
5. **Whole-module replacement.** A compiler may substitute an entire module
   implementation (e.g. a hand-optimized STL-backed `std_collections` for C++).
   This is already possible through the base-function mechanism.
6. **O(n + m) translation via a canonical IR.** With n encoders and m compilers,
   total work is O(n + m): each new target needs only one new compiler. The
   seven-node expression model keeps the IR surface area small enough for that to
   hold.
7. **Protobuf-IR advantage.** Ball's protobuf IR is self-describing,
   schema-evolved, and natively serializable in every language protobuf supports.
   Adding a target starts with `buf generate` — the new compiler immediately has
   type-safe bindings, something no other multi-target system gets for free.

### Per-Target Strategies (Design When Bootstrapping, Not Before)

These are intentionally **not** designed in the abstract — a strategy picked
before a target's actual encoder/engine exists tends to be wrong in a detail
that only shows up once real fixtures are compiling. Decide these during
Phase 2–4 of the `new-ball-language` skill for the specific target, using the
patterns above as the constraint set:

- **Error handling.** Result-based languages (Rust) should propagate
  `std.try`/`std.throw` as `Result<T, BallError>`; error-return languages
  (Go) as `(value, error)`. Exception-based languages (Java, C#, Python) map
  `std.try`/`std.throw` onto native try/catch directly, same as Dart/TS/C++
  today. `std.try`'s `catches[].type` still needs a per-target mapping from
  Ball's typed-exception names (`FormatException`, `StateError`, …) to the
  target's native exception hierarchy or error-code space.
- **Ownership (Rust only).** A `std_ownership` module, analogous to
  `std_memory`'s role for C/C++ linear memory (pattern #4 above) — only
  needed if/when a Rust program requires explicit borrow/move semantics the
  encoder can't infer. Do not add it speculatively; most Ball programs
  (garbage-collected-language-shaped IR) will compile to safe, `Rc`/`Clone`-
  heavy Rust without one.
- **Multi-file output.** Dart/C++/TS compilers already emit a single file per
  program; TS's `compileModule()` and C++'s `compile_library()` already
  support multi-module output for library-shaped programs. A new target
  picks the idiomatic granularity when it needs multi-file output: Rust
  (module = file), Go (package = directory), Java (public class = file).
  This is purely an output-layout decision — it does not change the IR or
  any base-function contract.
- **Capability declaration matrix.** Pattern #1 above (Legal/Expand/LibCall/
  Custom) is the target *model*; the actual per-function table doesn't exist
  yet for any compiler (Dart/C++/TS included) — building it for the existing
  three compilers first would validate the model before a new target is
  expected to fill it in, and would let a conformance job flag "no author
  declared how this compiler handles `std.spawn`" instead of only surfacing
  a runtime crash.

## Cross-Target Gap Analysis (Rust/Go/Python/Java/C#)

Tracked in [#132](https://github.com/Ball-Lang/ball/issues/132). This section
is the durable analysis; **for current pass/fail state, read
`.github/workflows/ci.yml` and `<lang>/AGENTS.md`, not the prose below** — CI
is the only thing that can't silently drift out of date.

### Current State (verified against `buf.gen.yaml`, `<lang>/AGENTS.md`, and `ci.yml`)

| Target | Proto bindings | Compiler | Encoder | Engine | CI job |
|--------|:---:|:---:|:---:|:---:|:---:|
| Go     | Yes (`go/shared/gen`, `protocolbuffers/go`) | No | No | No | None |
| Python | Yes (`python/shared/gen`, `protocolbuffers/python`) | No | No | No | None |
| Java   | Yes (`java/shared/gen`, `protocolbuffers/java`) | No | No | No | None |
| C#     | Yes (`csharp/shared/gen`, `protocolbuffers/csharp`) | No | No | No | None |
| Rust   | No — not in `buf.gen.yaml` | No | No | No | None |

Go/Python/Java/C# are all at the identical starting line: `buf generate`
produces bindings into `<lang>/shared/gen/`, and each `<lang>/AGENTS.md`
explicitly says so ("proto bindings only; no compiler, encoder, or engine
exists yet"). None has a `<lang>/` job in `ci.yml` or
`conformance-matrix.yml`. Rust (epic #32) has no directory, no
`buf.gen.yaml` entry, and no bindings at all — it is one phase further back
than the other four.

None of the five is closer to "done" than another in any dimension that
matters for the project's definition of done (compile **and** encode **and**
run the conformance corpus) — this is a five-way tie at the bottom of the
maturity ladder, not a ranked list.

### Prioritized Action Items

Ordered by "unblocks the most future work per unit of effort," not by
target:

1. **Add `buf.gen.yaml` entry + `rust/` scaffold for Rust** (Phase 1 of
   `new-ball-language`) — the one action item that is strictly a
   prerequisite for Rust ever leaving last place; the other four targets
   already have this.
2. **Build the capability-declaration matrix (Legal/Expand/LibCall/Custom)
   for the three existing compilers (Dart/C++/TS)** before starting a fourth
   — validates the model from pattern #1 against real, working compilers
   first, and gives every subsequent target a checklist instead of a
   from-scratch design exercise. Cheapest to do now, most valuable the
   moment a fifth compiler starts.
3. **Add `std.string_char_at_codepoint`** (see "String Indexing Convention"
   above) — small, self-contained, and specifically unblocks Rust/Go/C++
   from inheriting UTF-16 code-unit indexing they'd otherwise have to
   emulate. Needs `std.json` + Dart/TS/C++ engine and compiler + a
   conformance fixture (all three existing engines, per the standard
   feature workflow) — do this on a host that can build/test the C++ leg.
4. **Pick the first non-Rust target to bootstrap using the
   `ball-lang-bootstrapper` agent / `new-ball-language` skill.** Go and C#
   are the strongest early candidates: Go's error-return model and
   package-per-file output are already scoped above, and C#'s reified
   generics + exception model are nearly Dart-identical (least novel
   design surface, per the Reified Generics table above) — either is lower
   design-risk than Python (duck typing / no static reified-generics
   equivalent) or Java (erasure + checked-exceptions modeling).
5. **Design Rust's error-model and `std_ownership` scope during Rust's own
   Phase 2–4**, not before — per "Per-Target Strategies" above, this is
   deliberately deferred until real fixtures are compiling.

---

## Typed Exceptions

Ball's `std.try` function supports typed catch clauses. The input message has:
- `body` — the try block expression
- `catches` — a list of catch clauses, each with:
  - `type` — exception type name (e.g., `"FormatException"`, `"StateError"`)
  - `variable` — the variable name to bind the caught exception
  - `body` — the catch block expression
- `finally` — optional cleanup expression (executed unconditionally)

### Compilation Rules

1. **Type matching:** If a catch clause has a `type` field, emit a typed
   catch. In Dart: `on FormatException catch (e)`. In C++: emit a 
   `catch (const FormatException& e)` or use `catch (const std::exception& e)`
   with a runtime type check when custom exception types aren't available.

2. **Untyped catch:** If a catch clause has no `type`, it catches everything.
   In Dart: `catch (e)`. In C++: `catch (...)`.

3. **Multiple catch blocks:** Emit them in order — the first matching type wins.

4. **Finally:** C++ has no `finally`. Emit the finally body as unconditional
   code after the try-catch block. Other languages emit a proper `finally`.

### Engine Rules (interpreters)

1. When `throw` is called, wrap the value with its type information.
2. When evaluating catch clauses, compare the thrown value's type against
   each clause's `type` field. Use the first match.
3. If no catch clause matches, re-throw to the next enclosing try-catch.
4. Always execute the `finally` expression regardless of whether an
   exception was thrown, caught, or propagated.

### Additional Modules

The following modules are available for compilers to support:

#### std_convert
`json_encode`, `json_decode`, `utf8_encode`, `utf8_decode`,
`base64_encode`, `base64_decode`

#### std_fs
`file_read`, `file_read_bytes`, `file_write`, `file_write_bytes`,
`file_append`, `file_exists`, `file_delete`,
`dir_list`, `dir_create`, `dir_exists`

#### std_time
`now`, `now_micros`, `format_timestamp`, `parse_timestamp`,
`duration_add`, `duration_subtract`,
`year`, `month`, `day`, `hour`, `minute`, `second`
