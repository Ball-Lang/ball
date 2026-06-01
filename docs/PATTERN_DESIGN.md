# Ball Pattern Matching Design

> Patterns are represented as **function calls**, following Ball's core design:
> "control flow is function calls." No dedicated proto messages needed.

## Design Principle

Ball already has `std.if`, `std.for`, `std.while` as base functions for control
flow. Pattern matching follows the same principle: `std.switch_expr` with pattern
cases encoded using std pattern functions and metadata conventions.

## Pattern Encoding

Patterns are encoded as MessageCreation fields within switch case entries,
using the `__pattern_kind__` metadata convention and existing Ball expressions:

- **Variable pattern**: `{__pattern_kind__: "var", name: "x"}`
- **Record pattern**: `{__pattern_kind__: "record", fields: [...]}`
- **Type pattern**: `{__pattern_kind__: "type", type: "int"}`
- **Wildcard**: `{__pattern_kind__: "wildcard"}`
- **Constant**: `{__pattern_kind__: "constant", value: expr}`
- **List pattern**: `{__pattern_kind__: "list", elements: [...]}`

These use Ball's existing Expression tree — no new proto messages required.
The `__pattern_kind__` discriminator is metadata (cosmetic), and the patterns
themselves decompose into type checks (`std.is`) + field access + variable
binding — all primitives Ball already supports.

## Cross-Language Coverage

The 12 semantic pattern categories identified in research:

1. **Wildcard** — `_` in all languages
2. **Variable** — capture/binding patterns
3. **Constant** — literal/value matching
4. **Type test** — `is Type` checks (use `std.is`)
5. **Destructure** — positional/named field extraction
6. **List/Sequence** — `[p1, p2, ...rest]`
7. **Map/Mapping** — `{'key': pattern}`
8. **Or** — `p1 | p2` alternatives
9. **And** — `p1 && p2` conjunction
10. **Relational** — `< 5`, `>= 10`
11. **Binding** — `name @ pattern`
12. **Rest** — `..`, `...rest`

All can be expressed through Ball's existing function call + metadata system.
Guard expressions are just expressions in the case's `guard` field.

## Why Not Proto Messages

Adding 15 proto messages for patterns would duplicate what Ball already
expresses through its 7 Expression node types + base functions. Ball's power
comes from its minimal IR — control flow IS function calls, patterns ARE
expressions. The metadata convention (`__pattern_kind__`) is the right
level of abstraction for a cosmetic hint that tells compilers how to
reconstruct source-level pattern syntax.
