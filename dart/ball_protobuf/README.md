# ball_protobuf

An **Editions-capable, pure-Dart Protocol Buffers runtime**.

`ball_protobuf` is a descriptor-driven protobuf implementation written in
Ball-portable Dart: binary wire codecs, binary and proto3-JSON
marshal/unmarshal, well-known types, gRPC framing, and the complete protobuf
**Editions** feature model + protoc's canonical feature-resolution algorithm
(plus proto2/proto3 legacy inference).

Because it is authored in Ball-portable Dart, the *same* engine is compiled by
the Ball toolchain to every target language — so editions-aware protobuf
behaves identically on Dart, TypeScript, and C++ (see
`tests/editions/portability_matrix.md` in the repo).

## Editions features honoured

When a field descriptor carries a resolved `'features'` map, the codecs honour:

- `field_presence` — EXPLICIT / IMPLICIT / LEGACY_REQUIRED
- `enum_type` — OPEN / CLOSED (out-of-range CLOSED values routed to unknowns)
- `repeated_field_encoding` — PACKED / EXPANDED
- `message_encoding` — LENGTH_PREFIXED / DELIMITED (groups, wire types 3/4)
- `utf8_validation` — VERIFY / NONE
- `json_format` — ALLOW / LEGACY_BEST_EFFORT

A descriptor without a `'features'` key behaves as proto3 defaults (zero
behavioural change), so existing callers are unaffected.

## Usage

```dart
import 'package:ball_protobuf/ball_protobuf.dart';

final bytes = marshal({'x': 7}, [
  {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
]);
final decoded = unmarshal(bytes, [
  {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
]);

// Resolve editions feature sets:
final features = baseFeaturesForEdition(edition2023);
```

## Status

Part of the [Ball language](https://github.com/ball-lang/ball) project; versioned
in lockstep with the other Ball Dart packages. See `docs/EDITIONS_SPEC.md` for
the feature spec and `docs/EDITIONS_PLAN.md` for design.
