/// Wave-7 tail-coverage for `dart_emitter.dart` (issue #61): the descriptor-map
/// literal writer's shape branches that the real descriptor bridge never emits
/// today but the emitter's typed input (`List<Map<String, Object?>>`) permits,
/// plus its two fail-loud guards.
///
/// These drive the *public* `emitDartFile(GenFile)` with hand-built
/// `GenFile`/`GenMessage`/`GenField` values (the bridge only ever produces
/// String/int/bool/Map descriptor values + the special-cased `messageDescriptor`
/// list, so a real `.proto` cannot reach these arms). Testing them locks the
/// writer's documented "JSON-ish scalar/list/map" contract and its guards.
@TestOn('vm')
library;

import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';
import 'package:test/test.dart';

/// A one-message `GenFile` carrying [descriptor] as its sole message's
/// field-descriptor list (and optional typed [fields]).
GenFile _fileWith({
  List<Map<String, Object?>> descriptor = const [],
  List<GenField> fields = const [],
}) => GenFile(
  protoPath: 'test/lit.proto',
  package: 'test',
  messages: [
    GenMessage(
      fullName: 'test.M',
      dartName: 'M',
      descriptor: descriptor,
      fields: fields,
      isMapEntry: false,
    ),
  ],
  enums: const [],
);

void main() {
  group('descriptor literal writer', () {
    test('emits null, double, and list descriptor values verbatim', () {
      final src = emitDartFile(
        _fileWith(
          descriptor: [
            {
              'name': 'f',
              'number': 1,
              'type': 'TYPE_INT32',
              // Value shapes a real bridge never emits, but the emitter's
              // typed input allows — each hits a distinct _writeDartLiteral arm.
              'nullDefault': null,
              'weight': 1.5,
              'items': [1, 'two', true],
            },
          ],
        ),
      );
      expect(src, contains("'nullDefault': null"));
      expect(src, contains("'weight': 1.5"));
      expect(src, contains("'items': [1, 'two', true]"));
    });

    test('emits null for a messageDescriptor with no resolvable ref', () {
      // A `messageDescriptor` entry whose field carries neither `typeName`
      // nor `valueTypeName` — the "shouldn't happen" defensive arm.
      final src = emitDartFile(
        _fileWith(
          descriptor: [
            {
              'name': 'm',
              'number': 1,
              'type': 'TYPE_MESSAGE',
              'messageDescriptor': <Map<String, Object?>>[],
            },
          ],
        ),
      );
      expect(src, contains("'messageDescriptor': null"));
    });

    test('throws on an unsupported descriptor value type', () {
      expect(
        () => emitDartFile(
          _fileWith(
            descriptor: [
              {
                'name': 'f',
                'number': 1,
                'type': 'TYPE_INT32',
                'weird': const Duration(seconds: 1),
              },
            ],
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  test('scalar-type mapping throws on a non-scalar field type', () {
    // A singular field whose protoType is neither message/enum nor a known
    // scalar reaches `_scalarDartType`'s fail-loud default.
    final file = _fileWith(
      fields: [
        GenField(
          protoName: 'x',
          dartName: 'x',
          protoType: 'TYPE_BOGUS',
          cardinality: FieldCardinality.singular,
          presence: PresenceKind.implicit,
        ),
      ],
    );
    expect(() => emitDartFile(file), throwsArgumentError);
  });
}
