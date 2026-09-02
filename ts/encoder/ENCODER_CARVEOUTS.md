# TS encoder — documented carve-outs

TypeScript source constructs that `@ball-lang/encoder` deliberately does **not**
encode faithfully, and why. Every entry here is an *accepted, visible* gap: the
encoder emits a behaviour-affecting warning (and throws under
`{ strict: true }` or `{ strictBehaviorAffecting: true }`) rather than quietly
producing a Ball program that computes something different.

The point of this file is the distinction CI needs to make: a **known** gap that
warns is fine; a **silent** gap is a bug. Issue #490 existed because six
constructs were in the second category — and three of them were locked in place
by tests asserting the broken behaviour as correct.

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

The encoder is **syntax-only** (`ts.createSourceFile`, no semantic model), so a
method name that exists on both `String` and `Array` cannot be resolved from
syntax alone. `STR_METHODS` is consulted first, so the string mapping wins:

| Method | Encoded as | Consequence |
| --- | --- | --- |
| `slice` | `std.string_substring` | `arr.slice(1, 3)` compiles to `arr.substring(1, 3)` and throws at runtime. Use `arr.filter`/index arithmetic, or encode with a type-aware front end. |
| `concat` | `std.string_concat`-shaped `+` via `std_collections.list_concat` only when reached through the array path | The string path wins for a bare `.concat`. |
| `indexOf`, `includes` | `std.string_index_of` / `std.string_contains` | Survivable in the TS target only because JS `Array` happens to spell both the same way; it would be wrong on a target where the two are distinct. |

Resolving these needs the TypeScript **semantic** model (a `ts.Program` with a
type checker), which is a larger change than the vocabulary alignment #489
covers. Until then they are ambiguities, not silent corruption: the failure is a
loud runtime `TypeError` on the compiled output, and the fixtures in
`roundtrip.test.ts` deliberately avoid the ambiguous spellings.

## Erasure-only — warns, but never behaviour-affecting

`type` aliases, `interface` declarations, empty statements and `satisfies`
clauses contribute nothing to what a program computes. They are recorded as
warnings (so `{ strict: true }` still rejects them for callers who want a
byte-exact round trip) but are exempt from `{ strictBehaviorAffecting: true }` —
see `ERASURE_ONLY_KINDS` in `src/encoder.ts`.
