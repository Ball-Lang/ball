# Style customization — encoders, compilers, and engines

Custom style requirements ("4-space indent", "PascalCase file names", "braces on own lines") are implemented with three levers, cheapest first. The rule behind all three: **style lives in configuration or in the emitter, never in per-file edits** — one lever change styles every emitted file, forever, deterministically.

## Lever 1 — target-ecosystem formatter configuration (minutes)

Emit code, then run the target ecosystem's own formatter as the final deterministic pass:

| Target | Formatter | Where the style config lives |
|---|---|---|
| Dart | `dart format` (the Dart compiler already emits through `dart_style`; `ball compile --no-format` skips it) | `analysis_options.yaml`, `.editorconfig` |
| TypeScript | prettier / biome | `.prettierrc`, `biome.json` |
| C++ | clang-format | `.clang-format` |
| Rust | rustfmt | `rustfmt.toml` |

Indent width, line length, quote style, trailing commas — all belong here. Do not touch the compiler for anything a formatter option expresses.

## Lever 2 — cosmetic IR metadata (hours)

Naming and file-layout style is data on the IR, not code in the emitter: display names, file mapping, and grouping hints live in `metadata` Structs, which are **provably semantics-preserving** to edit (see `references/ir-transforms.md`). Example: "PascalCase file names" is a metadata transform mapping each module/type's emitted-file name — a 20-line script applied before emission, not 40 file renames after it.

## Lever 3 — extend the target compiler's emission layer (days; upstream it)

When style requirements exceed formatter options and metadata (e.g. "every public function gets a doc-comment scaffold", "one class per file", idiom preferences like `where` chains vs loops), extend the compiler itself in a `Ball-Lang/ball` checkout:

| Compiler | Location | Emission mechanism |
|---|---|---|
| Dart | `dart/compiler/lib/compiler.dart` | `code_builder` AST + `dart_style`; base-function dispatch in `_compileBaseCall` |
| TypeScript | `ts/compiler/src/` | `ts-morph` |
| C++ | `cpp/compiler/` | string-based emitter; blocks become immediately-invoked lambdas |
| Rust | `rust/compiler/` | string/AST emission |

Workflow: fork/branch the Ball repo → change the emitter → re-run the Ball conformance corpus for that target (the style change must be output-golden-neutral or the goldens must be regenerated deliberately) → use the built compiler for the conversion → upstream the change as an opt-in emitter option (PR to `Ball-Lang/ball`) so the fork does not have to live forever.

## Customizing encoders (source-side idioms)

Extend the **encoder** when the *source* codebase's idioms defeat the encoder's heuristics rather than when output style is wrong. Encoders are syntactic (no full type resolution), so receiver-ambiguous constructs can mis-route — e.g. the documented Dart trap: `Map.addAll`/`List.addAll` cannot be distinguished syntactically and route to a non-mutating list op; the fix is per-item `.add` loops or an encoder extension. Encoder locations: `dart/encoder/lib/encoder.dart` (analyzer-based, the reference), `ts/encoder` (TS Compiler API), `cpp/encoder` (Clang JSON AST), `rust/encoder`. Any encoder change must be proven with a round-trip conformance fixture before being used on the codebase.

## Extending engines (custom native modules)

When the codebase calls platform APIs with no std equivalent, add a **custom module**: functions declared `isBase: true` (no body) in the IR, implemented natively per engine — Dart: implement `BallModuleHandler`; TS/C++/Rust: the analogous handler registration. This is Ball's designed extensibility mechanism (base functions have no body; each platform supplies the implementation). Prefer the existing universal std modules first: `std`, `std_collections`, `std_io`, `std_memory`, `std_convert`, `std_fs`, `std_time`, `std_concurrency`.
