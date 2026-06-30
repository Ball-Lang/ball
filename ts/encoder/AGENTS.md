<!-- Parent: ../AGENTS.md -->

# ts/encoder (`@ball-lang/encoder`)

## Purpose

TypeScript → Ball encoder. Parses TypeScript source using the TypeScript Compiler API and emits a Ball `Program` (proto3-JSON). All constructs route through universal `std` — no `ts_std` module exists.

## Key Files

| File | Description |
|------|-------------|
| `src/encoder.ts` | `TsEncoder` class — entry: `encode(source: string, opts?) → Program`. Operator-to-std dispatch tables (`BINARY_OPS`, `COMPOUND_OPS`) map `ts.SyntaxKind` values to `std` function names. |
| `src/index.ts` | Public exports: `encode`, `encodeWithWarnings`, `TsEncoder`, `EncodeError`, `EncodeOptions`, `EncodeResult`. |
| `src/types.ts` | Local TypeScript type aliases mirroring the Ball proto3-JSON shape (plain objects, not protobuf-es messages). |

## For AI Agents

- Entry: `encode(source: string, opts?: EncodeOptions) → Program`. Returns a plain proto3-JSON `Program` object.
- Uses the **TypeScript Compiler API** (`typescript` package, `ts.SyntaxKind`) — not `ts-morph`. Walk the AST via `ts.createSourceFile` + visitor pattern.
- All TS operators (arithmetic, comparison, bitwise, logical, null-coalesce, `instanceof`) map to universal `std` function calls — see `BINARY_OPS` table in `encoder.ts`. Never introduce `ts_std` functions; expand everything to `std`/`std_collections`/`std_io`.
- `encodeWithWarnings` returns `{ program, warnings }` — prefer it over `encode` when callers need to surface non-fatal encoding issues.
- CI-gated: 100+ tests covering encoder, conformance, and round-trip (TS → Ball → TS). Run with `node --experimental-strip-types --test test/*.test.ts`.
- After adding a new encoding case, ensure it appears in a conformance fixture (`tests/conformance/src/`) per the gate in `CLAUDE.md`.
- See `.claude/rules/ts.md` and `CLAUDE.md` for routing rules and the no-`ts_std` invariant.

## Dependencies

- Internal: none (emits plain JSON-shaped objects)
- External: `typescript` ^6 (TypeScript Compiler API for AST parsing)
