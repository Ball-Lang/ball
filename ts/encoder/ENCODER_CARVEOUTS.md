# TS encoder — documented carve-outs

TypeScript source constructs that `@ball-lang/encoder` deliberately does **not**
encode faithfully, and why. Every entry here is an *accepted, visible* gap: the
encoder emits a behaviour-affecting warning (and throws under
`{ strict: true }` or `{ strictBehaviorAffecting: true }`) rather than quietly
producing a Ball program that computes something different.

The point of this file is the distinction CI needs to make: a **known** gap that
warns is fine; a **silent** gap is a bug. Issue #490 existed because six
constructs were in the second category — and three of them were locked in place
by tests asserting the broken behaviour as correct. The
"Ambiguous without a type checker" table below was the last entry for which the
opening claim was **not** true: it was documented here but emitted no warning at
all, so `encodeWithWarnings(...)` came back empty even under
`{ strictBehaviorAffecting: true }`. #525 made it warn; **#506** then made it
*resolve* — the section below now describes only the residual receivers a type
checker genuinely cannot pin down.

Companion gates:

- `ts/compiler/test/std_name_consistency.test.ts` — every std base function the
  encoder can emit must be implemented by `compileStdCall`, or listed in that
  file's `KNOWN_GAPS` table with a reason. Keep the two lists in sync.
- `ts/encoder/test/roundtrip.test.ts` — the only leg that runs
  `encode() → compile() → execute` and diffs stdout. A construct without a
  fixture there is a construct nothing in CI actually executes.

## Not representable in Ball at all

| TS construct | Encoded as | Why |
| --- | --- | --- |
| `typeof x` | `std.type_of` (no compiler/engine support anywhere) | Ball has no `typeof` analogue. Implementing it means a genuinely new universal base function: `dart/shared/lib/std.dart` + `gen_std.dart` + the Dart compiler/engine + every target's compiler and engine + a conformance fixture. Tracked by **#489**; the encoder keeps emitting the honest name so the compiler fails loud and names the construct. |
| unary `+x` | behaviour-affecting warning + placeholder literal | `+x` is a numeric **coercion** (`+"5"` is the number 5). Ball has no coerce-to-number base function — `string_to_int`/`string_to_double` are wrong for a non-string operand, and `std.add(x, 0)` concatenates when `x` is a string. Previously this was the one unhandled path that emitted **no** placeholder: it returned the untouched operand, so `+"5"` stayed the string `"5"`. |
| `import.meta` (`MetaProperty`) | behaviour-affecting warning + placeholder literal | Ball's model is a single `Program` message with no ES module system, so there is no faithful target for `import.meta.url` or friends. |
| `{ [k]: v }` (computed key) | `std.computed_property` (no compiler support) | `MessageCreation` field names are static strings; a runtime-computed key has no shape to encode into. |
| tagged templates | `std.tagged_template` (no compiler support) | The tag function receives JS's raw/cooked strings array, a value Ball has no equivalent for. |
| `delete someBinding` | behaviour-affecting warning + placeholder | Deleting a *binding* (rather than a property) is a no-op in sloppy mode and a `SyntaxError` in strict mode; only `delete obj.a` / `delete obj[k]` map onto `std_collections.map_delete`. |

## Representable, but lossy — always warns

| TS construct | Loss | Notes |
| --- | --- | --- |
| regex flags (`/re/gimsuy`) | flags are dropped | The five `std.regex_*` base functions take the pattern as a **plain string** and model no flags at all. `g` is the exception: it is honoured by routing `.replace(/re/g, x)` to `regex_replace_all` and `.match(/re/g)` to `regex_find_all`, so it is not reported as dropped in those positions. Every other flag changes matching behaviour and is warned about. |
| `s.match(/re/)` without `g` | shape changes | JS returns a match array carrying capture groups and an index; `std.regex_find` returns only the matched substring. |
| `xs.splice(i, n)` for `n !== 1` | only `splice(i, 1)` maps | `std_collections.list_remove_at` removes exactly one element. Note also that `list_remove_at` evaluates to the removed **element**, where JS `splice` returns a one-element array. |
| `xs.forEach(cb)` with a multi-parameter `cb` | index/array parameters are lost | `.forEach` is desugared to the native `std.for_each` control-flow node (Ball has no `list_for_each` base function in any module, and iteration is control flow — Core Invariant #4). `for_each` yields only the element, so `(value, index, array)` callbacks lose the last two. |

## Ambiguous without a type checker

`slice`, `indexOf` and `includes` exist on **both** `String.prototype` and
`Array.prototype`, so the name alone cannot decide which std function to emit.

**Resolved since #506.** The encoder no longer decides by table order: it builds
a real `ts.Program` over an in-memory `ts.CompilerHost` (serving the actual
`lib.es2022.d.ts` from the resolved `typescript` package) and asks the
`TypeChecker` what the receiver statically is — `resolveReceiverKind` in
`src/encoder.ts`. A `string`-like receiver takes `STR_METHODS`, a `T[]` /
`ReadonlyArray<T>` / tuple receiver takes `ARR_METHODS` (`std_collections`), and
neither warns. The Program is built **lazily**, on the first ambiguous name in a
file, so encodes that contain none pay nothing.

What remains is the genuinely **inconclusive** receiver, and only that:

| Residual receiver | Encoded as | Why it cannot be resolved |
| --- | --- | --- |
| `any` (including an unresolved/undeclared name, whose error type is an `any`) | the `String` mapping, plus a warning | There is no static type to consult. |
| `unknown`, or a bare type parameter (`<T extends string \| number[]>`) | the `String` mapping, plus a warning | The receiver's type is not known at the call site. |
| a union whose members disagree (`string \| number[]`) | the `String` mapping, plus a warning | Both mappings are live; picking one would be a guess. (A union whose members *all* agree — `"a" \| "b"`, `number[] \| string[]` — **is** resolved.) |
| anything else that is neither String-like nor Array-like (e.g. a user-defined class with its own `slice`) | the `String` mapping, plus a warning | The name is not a std construct at all here. |

Each of those emits a behaviour-affecting `warn()` (kind
`AmbiguousStringArrayMethod`, the same mechanism and severity as the
`ArraySplice` warning), so `encodeWithWarnings(...)` reports it and
`{ strict: true }` / `{ strictBehaviorAffecting: true }` reject it. Guessing
instead would trade an honest warn-loud fallback for a new class of *silent*
mis-encode — strictly worse, and against the fail-loud Core Invariant.

`concat` is **not** in this table: it has no `STR_METHODS` entry at all, so
`a.concat(b)` always takes the array path (`std_collections.list_concat`, field
`other`) and the compiler's `case "list_concat"` reads it correctly. This note
exists only so the row is not re-added: it was checked, and it is unambiguous.

Coverage for all of the above lives in `test/semantic_resolution.test.ts`, which
asserts the emitted `{module, function}` pair directly. That is deliberate: a
round-trip (`test/roundtrip.test.ts`) asserts **TS-target output equivalence**,
and `std.string_index_of` / `std.string_contains` happen to compile back to JS's
receiver-agnostic `.indexOf()` / `.includes()` — so those two round-tripped
green for as long as the bug existed. A round-trip through one target is
structurally blind to *which* std function was chosen. Array `.slice()` is the
exception that a round-trip could see, because `std.string_substring` compiles
back to `.substring(...)`, which `Array` does not have; `roundtrip.test.ts`'s
"Array.slice on a typed array receiver (#506)" case pins that end to end.

## Erasure-only — warns, but never behaviour-affecting

`type` aliases, `interface` declarations and empty statements contribute nothing
to what a program computes. When one appears where the encoder has no branch for
it — a `type`/`interface` declared *inside* a function body, or a stray `;` — it
is recorded as a warning (so `{ strict: true }` still rejects it for callers who
want a byte-exact round trip) but is exempt from
`{ strictBehaviorAffecting: true }` — see `ERASURE_ONLY_KINDS` in
`src/encoder.ts`. At top level a `type` alias and an `interface` are genuinely
encoded (`typeAliases[]` / `typeDefs[]`), so neither warns there.

`x satisfies T` is different: it is erased in `encodeExpr` exactly like an
`as`/`<T>` cast — silently, with no warning at all — so neither strict mode sees
it and it has no `ERASURE_ONLY_KINDS` entry.
