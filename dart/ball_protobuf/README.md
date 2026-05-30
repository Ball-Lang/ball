# ball_protobuf

An **Editions-capable, pure-Dart Protocol Buffers runtime**.

`ball_protobuf` is a descriptor-driven protobuf implementation written in
Ball-portable Dart: binary wire codecs, binary and proto3-JSON
marshal/unmarshal, well-known types, gRPC framing, and the complete protobuf
**Editions** feature model + protoc's canonical feature-resolution algorithm
(plus proto2/proto3 legacy inference).

Because it is authored in Ball-portable Dart, the *same* engine is compiled by
the Ball toolchain to every target language — so editions-aware protobuf
behaves identically on Dart, TypeScript, and C++ (see the
[portability matrix](https://github.com/Ball-Lang/ball/blob/main/tests/editions/portability_matrix.md)).

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

## Conformance

The codecs are validated against the **official protobuf
`conformance_test_runner`** for the proto2, proto3, and edition2023
`TestAllTypes` messages (2513 tests pass; remaining gaps — chiefly Well-Known
Types, oneof, and message merge — are tracked in the failure list). See the
[conformance harness docs](https://github.com/Ball-Lang/ball/blob/main/dart/ball_protobuf/conformance/README.md)
for how to build the runner and run it locally; CI runs it on every change.

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

Part of the [Ball language](https://github.com/Ball-Lang/ball) project; versioned
in lockstep with the other Ball Dart packages. See the
[Editions spec](https://github.com/Ball-Lang/ball/blob/main/docs/EDITIONS_SPEC.md)
for the feature tables and the
[Editions plan](https://github.com/Ball-Lang/ball/blob/main/docs/EDITIONS_PLAN.md)
for design.
