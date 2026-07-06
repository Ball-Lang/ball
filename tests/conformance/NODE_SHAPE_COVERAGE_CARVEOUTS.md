# Node-Shape Coverage Carve-outs

`check_node_shape_coverage.dart` (a CI gate, in the `ball-freshness` job)
requires that **every Expression node shape in its required set is exercised by
at least one executed conformance fixture** — a
`tests/conformance/<name>.ball.json` with a golden `<name>.expected_output.txt`.
This file is the only sanctioned escape hatch: each `-` bullet whose leading
backticked token names a required shape exempts it from the gate.

Carve-outs must be **rare and justified**. Each names a structural shape that is
genuinely absent from the corpus today, with the reason it cannot yet be closed
and the follow-up (issue #64 Phase 2b) that will close it. **Remove an entry the
moment a fixture exercises the shape** — the gate fails loudly on a stale
carve-out (a shape that is both carved and now covered), so a gap can never be
silently re-hidden (the failure mode that produced issue #55 for std functions).

## Genuinely-absent shapes (tracked to #64 Phase 2b — add a fixture, then REMOVE the entry)

- `literal.bytes_value` — the `bytes` Literal kind (`Literal.bytes_value`). The
  Dart encoder never emits it: no Dart source construct maps to a bytes literal
  (`Uint8List.fromList([...])` encodes as a constructor call, and the
  base64/UTF-8 fixtures operate on `String`s via `std_convert`), so it cannot
  be produced from a `tests/conformance/src/*.dart`; closing this needs a
  HAND-AUTHORED fixture instead. **Phase 2b investigation (this pass) found a
  real blocker before that can happen**: 2 of the 3 compilers DISCARD a bytes
  literal's actual content rather than reproducing it —
  `ts/compiler/src/compiler.ts` (`compileLiteral`) emits a hardcoded
  `new Uint8Array()` regardless of the source bytes, and
  `cpp/compiler/src/compiler.cpp` (`compile_literal`,
  `case ball::v1::Literal::kBytesValue`) emits a hardcoded
  `std::vector<uint8_t>{}` — both always empty, never the real value. Only the
  Dart compiler (`_raw('${lit.bytesValue}')`, `dart/compiler/lib/compiler.dart`)
  and the Dart engine (`_trackByteListAllocation(lit.bytesValue.toList())`,
  `dart/engine/lib/engine_eval.dart`) actually use the real bytes. A
  hand-authored fixture with a non-trivial bytes literal would therefore FAIL
  on the TS and C++ compiled legs today — not because the fixture is wrong,
  but because those two compilers have a genuine codegen bug — filed as
  issue #244. This carve-out stays until that's fixed, since adding the
  fixture now would just be a third carve-out (an expected-failing engine leg)
  rather than closing anything.
- `lambda.typed_param` — a lambda (a `FunctionDefinition` with `name == ""`)
  that declares a non-empty `input_type`. Every lambda the encoder emits today
  has an empty `input_type` (the parameter is reached via the special `input`
  reference / type inference), so the declared-parameter-type shape never
  appears. **Phase 2b investigation (this pass) found this is NOT safe to
  hand-author**, unlike `message_creation.const` (which was closed this pass):
  `FunctionDefinition.input_type` is not purely cosmetic. Both the reference
  Dart engine (`dart/engine/lib/engine_invocation.dart`, the
  `func.inputType.isNotEmpty` guard before the `scope.bind('input', input)`
  fallback) and the self-hosted/compiled engines
  (`ts/engine/src/engine_setup.ts`'s `_callFunction` patch,
  `ts/engine/src/compiled_engine.ts`) branch on `inputType.isNotEmpty` to
  decide whether to extract a single named parameter from
  `_paramCache['$moduleName.${func.name}']` — a cache keyed by the function's
  OWN name. For a lambda, `func.name` is always `""`, so every lambda in the
  same module would share ONE cache key if this path were ever exercised for
  lambdas — untested, collision-prone interaction, not a safe cosmetic
  addition like `is_const`. Closing this needs either a real encoder change
  (teaching `_encodeFunctionExpression` to set `input_type` for a
  single-typed-param lambda) with matching engine verification that the
  `_paramCache` keying is safe for anonymous functions, or a deliberate,
  carefully-checked hand-authored fixture — neither is a quick addition.
  Flagged for a dedicated follow-up rather than forced in this pass.
