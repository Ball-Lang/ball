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

_None currently._ `type_literal` was fixed by #66 (PR #158) and is now
exercised by `tests/conformance/src/340_type_literal.dart`.
