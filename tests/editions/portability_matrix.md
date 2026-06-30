# Editions Portability Matrix

> The portability milestone tracked in `docs/EDITIONS_SPEC.md`: proof that **one** Ball-source
> protobuf-Editions resolver runs **identically** on every target engine. This is
> the concrete demonstration of Ball's portability thesis — write the hard
> protobuf-Editions semantics once in Ball-portable Dart, get a correct,
> Editions-capable runtime everywhere.

## What is proven

The real Editions resolver — `dart/ball_protobuf/lib/edition.dart` +
`editions.dart`, the same sources that ship inside `ball_protobuf` — is encoded
into a single self-contained Ball `Program`,
[`tests/conformance/256_editions_resolver.ball.json`](256_editions_resolver.ball.json).
A small driver resolves feature sets for editions **2023**, **proto3**, and
**legacy/proto2**, plus a 2023 file that overrides `field_presence=IMPLICIT`, and
prints them deterministically (fixed `featureKeys()` order, manual string
concatenation — no sort/join — so the output is engine-independent).

That one program is run by the existing **conformance matrix** on each engine and
its stdout compared byte-for-byte against the single checked-in golden,
[`256_editions_resolver.expected_output.txt`](256_editions_resolver.expected_output.txt),
whose values match `protoc --edition_defaults_out` (protoc 28.2).

## Results

| Target | Engine | How it runs the program | Result |
|--------|--------|-------------------------|--------|
| **A** | **Dart** | tree-walking interpreter (`BallEngine`) | ✅ PASS — golden-exact |
| **B** | **TypeScript** | self-hosted engine (`compiled_engine.ts`, compiled from `engine.ball.json`) | ✅ PASS — golden-exact |
| **C** | **C++** | self-hosted engine (`engine_rt.cpp`, compiled from `engine.ball.json`) | ✅ PASS — golden-exact |

All three engines produce identical output:

```
2023: field_presence=EXPLICIT,enum_type=OPEN,repeated_field_encoding=PACKED,utf8_validation=VERIFY,message_encoding=LENGTH_PREFIXED,json_format=ALLOW
proto3: field_presence=IMPLICIT,enum_type=OPEN,repeated_field_encoding=PACKED,utf8_validation=VERIFY,message_encoding=LENGTH_PREFIXED,json_format=ALLOW
legacy: field_presence=EXPLICIT,enum_type=CLOSED,repeated_field_encoding=EXPANDED,utf8_validation=NONE,message_encoding=LENGTH_PREFIXED,json_format=LEGACY_BEST_EFFORT
2023+IMPLICIT: field_presence=IMPLICIT,enum_type=OPEN,repeated_field_encoding=PACKED,utf8_validation=VERIFY,message_encoding=LENGTH_PREFIXED,json_format=ALLOW
```

All three engines pass the full conformance corpus (293 fixtures, including the
`256` program); the CI `conformance-matrix` is green for the Dart engine, the TS
self-hosted + compiled engines, the C++ Compiled engine, and the Parity Matrix:

| Engine | Result |
|--------|--------|
| Dart   | all conformance fixtures pass (0 failed) |
| TS     | all conformance fixtures pass (0 failed) |
| C++    | all conformance fixtures pass (0 failed) |

## Reproduce locally

```bash
# Regenerate the program from the current editions sources:
cd dart/encoder && dart run tool/gen_editions_conformance.dart

# Target A — Dart engine:
cd dart/engine && dart run tool/run_program.dart \
  ../../tests/conformance/256_editions_resolver.ball.json

# Target B — TypeScript self-hosted engine (full conformance incl. 256):
cd ts/engine && npm test            # → "✓ conformance: 256_editions_resolver"

# Target C — C++ self-hosted engine (full conformance incl. 256):
cmake -S cpp -B cpp/build
cmake --build cpp/build --target test_selfhost_conformance --config Release
cpp/build/test/Release/test_selfhost_conformance   # → "PASS: 256_editions_resolver"
```

In CI the same coverage runs automatically: `.github/workflows/conformance-matrix.yml`
runs every `tests/conformance/*.ball.json` (now including `256`) on the Dart, TS,
and C++ engines, and `.github/workflows/regression-gates.yml` enforces that every
test passes (0 failed, 0 skipped) on each engine.

## Notes

- **Edition 2024** runtime features are identical to 2023 by construction (2024
  only adds `RETENTION_SOURCE` features the runtime ignores) and so are not
  separately exercised here; see the *Known limitations* section of
  [`docs/EDITIONS_SPEC.md`](../../docs/EDITIONS_SPEC.md).
- **C++ linear memory.** The C++ engine's 65 KB linear-memory budget was flagged
  as a risk for the resolver + defaults table. The
  full resolver fits and runs (1.3 s, no memory error), so that risk is retired
  for the resolver path.
- This proves the **resolver**. The feature-aware binary/JSON codecs
  (`marshal.dart` / `unmarshal.dart` / `json_codec.dart`) are validated by the
  Dart suite + `dart/ball_protobuf/tool/editions_conformance.dart`; extending the
  cross-target program to exercise the codecs end-to-end is a natural follow-on.
