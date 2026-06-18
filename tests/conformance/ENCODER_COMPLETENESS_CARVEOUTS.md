# Encoder Completeness Carve-outs

`check_encoder_completeness.dart` (a CI gate) requires that **every std base
function the Dart encoder can emit is exercised by at least one executed
conformance fixture** (`tests/conformance/src/*.dart`). This file is the only
sanctioned escape hatch: each `-` bullet whose leading backticked token names an
emittable base function exempts it from the gate.

Carve-outs must be **rare and justified**. Prefer adding a real fixture. A
carve-out is appropriate only for a construct that is genuinely hard to exercise
deterministically, or one that is **known-broken and tracked** (so the gap is
loud and reviewed, never silent — the failure mode that produced issue #55).

## Known-broken (tracked) — REMOVE the carve-out once fixed + add a fixture

- `symbol` — `#foo` round-trips Dart→Ball→engine to `foo` but native Dart prints
  `Symbol("foo")`. Silent-wrong-output: the engine's symbol value/`toString`
  does not match Dart. Surfaced by the completeness gate 2026-06-18. TODO: make
  the engine represent a symbol so it stringifies as `Symbol("name")` across the
  Dart/TS/C++ engines, then replace this carve-out with a fixture.

- `type_literal` — a bare type used as a value (e.g. `print(int);`) throws
  `BallRuntimeError: Undefined variable: "int"` on the engine; native Dart
  prints `int`. The construct is emittable but the engine has no runtime
  representation for a type literal. Surfaced by the completeness gate
  2026-06-18. TODO: give the engine a `Type` value whose `toString` is the type
  name, then replace this carve-out with a fixture.
