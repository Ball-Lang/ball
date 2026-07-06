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
  base64/UTF-8 fixtures operate on `String`s via `std_convert`). It therefore
  cannot be produced from a `tests/conformance/src/*.dart`. **Phase 2b:** a
  HAND-AUTHORED fixture plus a `tests/conformance/CARVEOUTS.md` entry (like the
  other non-encodable fixtures).
- `message_creation.const` — a `MessageCreation` carrying `is_const` metadata
  (from Dart `const Foo(...)`). This IS encoder-emittable, but no fixture
  exercises a const construction yet. `is_const` is cosmetic metadata (stripping
  it must never change the computed value), so it has no stdout effect — a
  fixture verifies the encoder emits the flag and every engine ignores it.
  **Phase 2b:** a `const`-constructor `tests/conformance/src/*.dart` fixture.
- `lambda.typed_param` — a lambda (a `FunctionDefinition` with `name == ""`)
  that declares a non-empty `input_type`. Every lambda the encoder emits today
  has an empty `input_type` (the parameter is reached via the special `input`
  reference / type inference), so the declared-parameter-type shape never
  appears. **Phase 2b:** either teach the encoder to emit a lambda's declared
  parameter type, or hand-author a fixture that sets it.
