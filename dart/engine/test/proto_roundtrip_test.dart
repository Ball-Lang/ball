/// Proto serialization round-trip: asserts that every Ball program
/// can be serialized and deserialized through both JSON and binary
/// protobuf formats without losing or reordering any field.
///
/// This is the cheapest defense against schema drift bugs. Any new
/// proto field that isn't properly serialized, or any field-order
/// change that breaks parse order, will surface here immediately.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

String _stableString(Program p) {
  // DebugString is canonical within a given protobuf version:
  // same tree ⇒ same string regardless of build or timestamp.
  return p.toString();
}

void main() {
  group('proto round-trip: serialize → parse ≡ identity', () {
    final fixturesDir = Directory('../../tests/fixtures/dart');
    if (!fixturesDir.existsSync()) return;

    final fixtures = fixturesDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final fixture in fixtures) {
      final name = fixture.uri.pathSegments.last.replaceAll('.dart', '');

      test('$name: binary round-trip', () {
        final original = DartEncoder().encode(fixture.readAsStringSync());
        final bytes = original.writeToBuffer();
        final parsed = Program.fromBuffer(bytes);
        expect(
          _stableString(parsed),
          equals(_stableString(original)),
          reason: 'binary serialize/parse mutated the program tree',
        );
      });

      test('$name: JSON round-trip', () {
        final original = DartEncoder().encode(fixture.readAsStringSync());
        final jsonMap = original.toProto3Json() as Map<String, dynamic>;
        final jsonStr = jsonEncode(jsonMap);
        final parsed = Program()
          ..mergeFromProto3Json(jsonDecode(jsonStr), ignoreUnknownFields: true);
        expect(
          _stableString(parsed),
          equals(_stableString(original)),
          reason: 'JSON serialize/parse mutated the program tree',
        );
      });

      test('$name: binary ≡ JSON', () {
        // Both formats must produce the same in-memory tree.
        final original = DartEncoder().encode(fixture.readAsStringSync());
        final fromBinary = Program.fromBuffer(original.writeToBuffer());
        final fromJson = Program()
          ..mergeFromProto3Json(
            jsonDecode(jsonEncode(original.toProto3Json())),
            ignoreUnknownFields: true,
          );
        expect(_stableString(fromBinary), equals(_stableString(fromJson)));
      });
    }
  });
}
