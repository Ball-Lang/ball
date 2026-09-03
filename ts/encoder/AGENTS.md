<!-- Parent: ../AGENTS.md -->

# ts/encoder (`@ball-lang/encoder`)

## Purpose

TypeScript → Ball encoder. Parses TypeScript source using the TypeScript Compiler API and emits a Ball `Program` (proto3-JSON). All constructs route through universal `std` — no `ts_std` module exists.

## Key Files

| File | Description |
|------|-------------|
| `src/encoder.ts` | `TsEncoder` class — entry: `encode(source: string, opts?) → Program`. Operator-to-std dispatch tables (`BINARY_OPS`, `COMPOUND_OPS`) map `ts.SyntaxKind` values to `std` function names. Also holds the lazily-built `ts.Program`/`TypeChecker` used for String-vs-Array dispatch (#506). |
| `src/index.ts` | Public exports: `encode`, `encodeWithWarnings`, `TsEncoder`, `EncodeError`, `EncodeOptions`, `EncodeResult`. |
| `src/types.ts` | Local TypeScript type aliases mirroring the Ball proto3-JSON shape (plain objects, not protobuf-es messages). |
| `ENCODER_CARVEOUTS.md` | The documented, accepted gaps: TS constructs this encoder cannot represent faithfully, and what it warns instead. Keep in sync with `KNOWN_GAPS` in `ts/compiler/test/std_name_consistency.test.ts`. |

## For AI Agents

- Entry: `encode(source: string, opts?: EncodeOptions) → Program`. Returns a plain proto3-JSON `Program` object.
- Uses the **TypeScript Compiler API** (`typescript` package, `ts.SyntaxKind`) — not `ts-morph`. Walk the AST via `ts.createSourceFile` + visitor pattern.
- The encoder is **mostly syntactic, semantic where it must be** (#506). Almost every construct is decided from the AST alone; the one exception is a method name that exists on both `String` and `Array` (`slice`/`indexOf`/`includes`), which is decided by `resolveReceiverKind` from a real `TypeChecker`. See the three rules below before touching it.

### The semantic model (`ts.Program` / `TypeChecker`) — #506

1. **It is lazy, and must stay lazy.** `encode()` still parses with
   `ts.createSourceFile`. `createChecker` wraps *that same `SourceFile` object*
   in a `ts.Program` only when `resolveReceiverKind` is first called — i.e. only
   for a file that actually contains an ambiguous name. Creating a Program costs
   ~190 ms (parsing + binding `lib.es2022.d.ts`) against ~2 ms for a typical
   single-file parse, so making it eager would tax every encode for a feature
   almost none of them use. `LIB_FILE_CACHE` then keeps the parsed lib files
   process-wide, so only the FIRST ambiguous file in a process pays.
2. **`lib` is pinned to `lib.es2022.d.ts`.** The default for this target is
   `lib.es2022.full.d.ts`, which drags in the whole DOM for no benefit —
   `String` and `Array` are all the resolution needs. Diagnostics are never
   read: a file with type errors must still encode exactly as before.
3. **`withNativeMapPrototype` is load-bearing, not defensive dressing.**
   `ts/compiler/src/preamble.ts` redefines `Map.prototype.entries/keys/values`
   as Dart-style *getters*, process-globally, in every compiled Ball program. A
   process that has loaded `@ball-lang/engine` therefore cannot call
   `map.keys()` — and TypeScript's own checker does, so building one throws
   `keys is not a function`. The guard hands the natives back for the duration
   of a checker call and restores the shadowing afterwards
   (`test/map_prototype_interop.test.ts` pins both halves). The one case it
   cannot cover is `src/encoder.ts` being loaded *after* a compiled Ball
   program, since the natives are captured at module load; that fails loudly
   rather than mis-resolving. Keep `@ball-lang/engine` imports lazy (as
   `ts/cli/src/index.ts` already does) and it does not arise.
- All TS operators (arithmetic, comparison, bitwise, logical, null-coalesce, `instanceof`, `**`) map to universal `std` function calls — see `BINARY_OPS` table in `encoder.ts`. Never introduce `ts_std` functions; expand everything to `std`/`std_collections`/`std_io`.
- `encodeWithWarnings` returns `{ program, warnings }` — prefer it over `encode` when callers need to surface non-fatal encoding issues.
- Three strictness levels: lenient (default, warn only), `{ strictBehaviorAffecting: true }` (throw `EncodeError` for anything that changes what the program computes, tolerate erasure-only constructs — the mode worth running over third-party code), and `{ strict: true }` (throw for ANY warning).
- CI-gated: 200+ tests covering encoder, conformance, and round-trip (TS → Ball → TS). Run with `node --experimental-strip-types --test test/*.test.ts`.

### Emitting a std base function — the two rules that broke before (#489)

1. **Use the CANONICAL name.** Canonical means "the name `dart/shared/lib/std*.dart`
   declares and `ts/compiler`'s `compileStdCall` dispatches on" — not a name that
   reads well. The encoder used to invent `list_add`, `optional_access`,
   `contains_key`, `string_replace_first`, `string_to_upper_case`,
   `list_for_each` (and seven more), none of which any compiler recognised, so
   real TS code threw `TS compiler: std.X is not implemented`. The gate is
   `ts/compiler/test/std_name_consistency.test.ts`: it statically enumerates
   every name this file can emit and compiles each one. **Spell the name as a
   literal argument to `stdCall(...)`** — a name computed from a ternary is
   invisible to that scan.
2. **Use the field names the compiler actually reads**, verified against the
   `case` body, not guessed from the argument's position. `string_replace` fed
   the old positional `other`/`arg1` names silently compiled to `''`, and
   `string_substring` crashed. `mapMethodToStd`'s tables now name every argument
   explicitly for this reason.

Then add a fixture to `test/roundtrip.test.ts` — it is the only leg that runs
`encode() → compile() → execute` and diffs stdout, i.e. the only one that can
catch either mistake. A name-only unit assertion cannot: that is precisely how
this class of bug shipped green.

3. **If the name has no counterpart at all, that is a MISSING BASE FUNCTION,
   not a naming bug.** `type_of` (for JS `typeof`) was the last of #489's
   fifteen names in that state; closing it meant declaring `type_of` in
   `dart/shared/lib/std.dart` and implementing it in all seven compilers,
   all seven runtimes and the Dart reference engine, plus a Dart-encoder
   idiom (`<expr>.runtimeType.toString()`) so a conformance fixture could be
   generated at all. `ENCODER_CARVEOUTS.md` no longer lists `typeof x`.


- After adding a new encoding case, ensure it appears in a conformance fixture (`tests/conformance/src/`) per the gate in `CLAUDE.md`.
- See `.claude/rules/ts.md` and `CLAUDE.md` for routing rules and the no-`ts_std` invariant.

## Dependencies

- Internal: none (emits plain JSON-shaped objects)
- External: `typescript` ^6 (TypeScript Compiler API for AST parsing)
