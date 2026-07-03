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

## Not byte-portable to the C++ self-host (issue #100)

The C++ self-host has **no skip-list** — every conformance fixture must pass on
every engine — but C++'s `std::scientific` / `std::setprecision` formatting does
not match Dart's output byte-for-byte: Dart uses a *minimal* exponent (`1.23e+2`,
not C++'s `1.23e+02`) and pads significant digits with trailing zeros
(`1.0.toStringAsPrecision(3)` → `1.00`, which `std::defaultfloat` drops). These
two formatters are fully implemented and **verified equal to native Dart on the
Dart reference engine and the TS self-host** (`(+(x)).toExponential(d)` /
`.toPrecision(p)` match Dart exactly); they are exercised by the Dart engine unit
tests in `dart/engine/test/engine_std_coverage_test.dart`, not a conformance
fixture, so the C++ corpus stays green. The C++ compiler still emits (best-effort,
exponent-normalized) branches so the self-host compiles.

- `to_string_as_exponential` — `num.toStringAsExponential([fractionDigits])`; C++ exponent-digit-count differs.
- `to_string_as_precision` — `num.toStringAsPrecision(precision)`; C++ drops the trailing zeros Dart keeps.

## Known-broken (tracked) — REMOVE the carve-out once fixed + add a fixture

_None currently._ `type_literal` was fixed by #66 (PR #158) and is now
exercised by `tests/conformance/src/340_type_literal.dart`.
