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
      ├── types[]           (google.protobuf.DescriptorProto — field schemas)
      ├── typeDefs[]        (TypeDefinition — first-class type metadata)
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
- **`std`** — ~100 universal functions (arithmetic, comparison, logic, control flow, strings, math)
- **`std_collections`** — list/map operations (optional — not all runtimes)
- **`std_io`** — console, process, time, random (optional — not all runtimes)
- **`dart_std`** (or `<lang>_std`) — language-specific extensions

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

#### From `types[]` (legacy, backward compat)

Older programs may store types in `Module.types` with metadata in `_meta_*`
functions. Look for `FunctionDefinition` with `name == "_meta_TypeName"` and
`isBase == true`. Its `metadata` Struct contains the same kind/superclass/etc.

**Prefer `typeDefs` when present.** Fall back to `_meta_*` scanning only for
programs that haven't been migrated.

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

**If the function is a base function** (from std/dart_std/std_io), emit
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
`string_to_int`, `string_to_double`, `string_interpolation`

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

1. **Hello World** — `examples/hello_world.ball.json` should produce working output
2. **Fibonacci** — `examples/fibonacci.ball.json` exercises recursion, comparison, arithmetic
3. **Comprehensive** — `examples/comprehensive.ball.json` exercises classes, enums, control flow
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

5. **`_meta_*` functions are deprecated.** Prefer `typeDefs[]` and
   `typeAliases[]`. Only fall back to `_meta_*` scanning for old programs.

6. **Metadata is optional and cosmetic.** Your compiler must produce valid
   code even if all metadata is stripped. Use metadata to improve output
   quality (proper type annotations, visibility, etc.) but don't depend
   on it for correctness.

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

### New Modules

The following additional modules are available for compilers to support:

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
