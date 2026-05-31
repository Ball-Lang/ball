/// Phase-3 TEST GATE: generated protobuf **extension** support.
///
/// The golden `test/golden/test_messages.pb.dart` is generated from the
/// upstream conformance `FileDescriptorSet`, which already carries real
/// extensions across proto2 and edition2023:
///   * scalar — `extension_int32` / `extension_string` / `extension_bytes`,
///   * message — `groupliketype` (editions) and `groupfield` (a proto2 group,
///     normalized by the bridge to a DELIMITED-encoded message),
///   * nested — `message_set_extension` declared inside a message.
///
/// Each test proves, for the generated typed surface:
///   (a) set an extension via the typed `setX` helper, `toBytes()` ->
///       `fromBytes()` -> `getX()` returns the value (binary round-trip), and
///       the bytes match the equivalent dynamic `marshal()` against the same
///       embedded descriptor;
///   (b) the extension survives a proto3-JSON round-trip
///       (`toProto3Json()` -> `fromProto3Json()`), keyed by the canonical
///       bracketed `[fqn]` form;
///   (c) an `Any` field whose `@type` is a *generated* message resolves through
///       the file registry (`$descriptorForOrNull`) in `toProto3Json()` /
///       `fromProto3Json()`;
///   (d) the per-file `$extensionRegistry` finds every extension by
///       `(extendee, number)` and by Any-style type-url.
@TestOn('vm')
library;

import 'package:ball_protobuf/ball_protobuf.dart' as pb;
import 'package:test/test.dart';

import 'golden/test_messages.pb.dart' as gen;

void main() {
  group('scalar extensions (edition2023) — binary round-trip', () {
    test('int32 / string / bytes set -> toBytes -> fromBytes -> getX', () {
      final msg = gen.TestAllTypesEdition2023();
      // Initially unset.
      expect(gen.hasExtensionInt32(msg), isFalse);
      expect(gen.getExtensionInt32(msg), isNull);

      gen.setExtensionInt32(msg, 4242);
      gen.setExtensionString(msg, 'ext-hello');
      gen.setExtensionBytes(msg, const [9, 8, 7]);

      expect(gen.hasExtensionInt32(msg), isTrue);

      // Round-trip through the runtime.
      final bytes = msg.toBytes();
      final decoded = gen.TestAllTypesEdition2023.fromBytes(bytes);
      expect(gen.getExtensionInt32(decoded), 4242);
      expect(gen.getExtensionString(decoded), 'ext-hello');
      expect(gen.getExtensionBytes(decoded), const [9, 8, 7]);

      // (a, cont.) the generated toBytes equals a dynamic marshal of the same
      // backing map against the same embedded descriptor — proving the typed
      // helpers write exactly the `[fqn]`-keyed shape the runtime expects.
      final dynamicMap = <String, Object?>{
        '[protobuf_test_messages.editions.extension_int32]': 4242,
        '[protobuf_test_messages.editions.extension_string]': 'ext-hello',
        '[protobuf_test_messages.editions.extension_bytes]': const [9, 8, 7],
      };
      final fromDynamic = pb.marshal(
        dynamicMap,
        gen.TestAllTypesEdition2023.descriptor,
      );
      expect(bytes, fromDynamic);
    });

    test('clearX removes the extension; round-trips to nothing', () {
      final msg = gen.TestAllTypesEdition2023();
      gen.setExtensionInt32(msg, 7);
      expect(gen.hasExtensionInt32(msg), isTrue);
      gen.clearExtensionInt32(msg);
      expect(gen.hasExtensionInt32(msg), isFalse);
      expect(gen.getExtensionInt32(msg), isNull);
      expect(msg.toBytes(), isEmpty);
    });

    test('an extension coexists with regular fields on the same message', () {
      final msg = gen.TestAllTypesEdition2023()..optionalInt32 = 11;
      gen.setExtensionInt32(msg, 99);
      final decoded = gen.TestAllTypesEdition2023.fromBytes(msg.toBytes());
      expect(decoded.optionalInt32, 11);
      expect(gen.getExtensionInt32(decoded), 99);
    });
  });

  group('message extensions — binary round-trip', () {
    test('editions message extension (groupliketype) round-trips', () {
      final msg = gen.TestAllTypesEdition2023();
      gen.setGroupliketype(msg, gen.GroupLikeType()..c = 555);
      final decoded = gen.TestAllTypesEdition2023.fromBytes(msg.toBytes());
      final got = gen.getGroupliketype(decoded);
      expect(got, isNotNull);
      expect(got!.c, 555);
    });

    test('proto2 group extension (groupfield) round-trips', () {
      // `groupfield` is a proto2 TYPE_GROUP extension; the bridge normalizes it
      // to a DELIMITED-encoded message so the typed message accessor works.
      final msg = gen.TestAllTypesProto2();
      gen.setGroupfield(
        msg,
        gen.GroupField()
          ..groupInt32 = 17
          ..groupUint32 = 18,
      );
      final decoded = gen.TestAllTypesProto2.fromBytes(msg.toBytes());
      final got = gen.getGroupfield(decoded);
      expect(got, isNotNull);
      expect(got!.groupInt32, 17);
      expect(got.groupUint32, 18);
    });

    test('nested-scope extension (message_set_extension) round-trips', () {
      final container = gen.TestAllTypesProto2_MessageSetCorrect();
      gen.setMessageSetExtension(
        container,
        gen.TestAllTypesProto2_MessageSetCorrectExtension1()..str = 'in-set',
      );
      final decoded = gen.TestAllTypesProto2_MessageSetCorrect.fromBytes(
        container.toBytes(),
      );
      final got = gen.getMessageSetExtension(decoded);
      expect(got, isNotNull);
      expect(got!.str, 'in-set');
    });
  });

  group('extension JSON round-trip', () {
    test('scalar extension survives toProto3Json -> fromProto3Json', () {
      final msg = gen.TestAllTypesEdition2023();
      gen.setExtensionInt32(msg, 321);
      gen.setExtensionString(msg, 'json-ext');

      final json = msg.toProto3Json() as Map<String, Object?>;
      // Canonical proto3-JSON keys extensions by the bracketed FQN.
      expect(
        json['[protobuf_test_messages.editions.extension_int32]'],
        // int32 stays a JSON number.
        321,
      );
      expect(
        json['[protobuf_test_messages.editions.extension_string]'],
        'json-ext',
      );

      final back = gen.TestAllTypesEdition2023.fromProto3Json(json);
      expect(gen.getExtensionInt32(back), 321);
      expect(gen.getExtensionString(back), 'json-ext');
    });

    test('message extension survives a JSON round-trip', () {
      final msg = gen.TestAllTypesEdition2023();
      gen.setGroupliketype(msg, gen.GroupLikeType()..c = 7);
      final json = msg.toProto3Json();
      final back = gen.TestAllTypesEdition2023.fromProto3Json(json);
      final got = gen.getGroupliketype(back);
      expect(got, isNotNull);
      expect(got!.c, 7);
    });
  });

  group('Any-in-JSON resolves through the generated file registry', () {
    test('optional_any holding a generated message round-trips via @type', () {
      // Pack a generated message into the message\'s google.protobuf.Any field
      // using the runtime-shaped Any map {type_url, value: <bytes>}.
      final inner = gen.ForeignMessage()..c = 4321;
      final any = gen.Any()
        ..typeUrl =
            'type.googleapis.com/protobuf_test_messages.proto3.ForeignMessage'
        ..value = inner.toBytes();
      final msg = gen.TestAllTypesProto3()..optionalAny = any;

      // toProto3Json must resolve ForeignMessage via $descriptorForOrNull and
      // inline its fields under the @type key (no resolver thrown).
      final json = msg.toProto3Json() as Map<String, Object?>;
      final anyJson = json['optionalAny'] as Map<String, Object?>;
      expect(
        anyJson['@type'],
        'type.googleapis.com/protobuf_test_messages.proto3.ForeignMessage',
      );
      expect(anyJson['c'], 4321);

      // fromProto3Json must resolve the same @type back to bytes.
      final back = gen.TestAllTypesProto3.fromProto3Json(json);
      final backAny = back.optionalAny;
      expect(backAny, isNotNull);
      final backInner = gen.ForeignMessage.fromBytes(backAny!.value);
      expect(backInner.c, 4321);
    });

    test('a WKT Any (Duration) still resolves via the registry', () {
      final any = gen.Any()
        ..typeUrl = 'type.googleapis.com/google.protobuf.Duration'
        ..value =
            (gen.Duration()
                  ..seconds = 3
                  ..nanos = 0)
                .toBytes();
      final msg = gen.TestAllTypesProto3()..optionalAny = any;
      final json = msg.toProto3Json() as Map<String, Object?>;
      final anyJson = json['optionalAny'] as Map<String, Object?>;
      expect(anyJson['@type'], 'type.googleapis.com/google.protobuf.Duration');
      // A WKT embeds under a "value" member alongside "@type".
      expect(anyJson['value'], '3s');

      final back = gen.TestAllTypesProto3.fromProto3Json(json);
      final backDur = gen.Duration.fromBytes(back.optionalAny!.value);
      expect(backDur.seconds, 3);
    });
  });

  group('per-file \$extensionRegistry', () {
    test('finds every extension by (extendee, number)', () {
      final reg = gen.$extensionRegistry;
      final byNum = reg.lookup(
        'protobuf_test_messages.editions.TestAllTypesEdition2023',
        120,
      );
      expect(byNum, isNotNull);
      expect(
        byNum!.fullName,
        'protobuf_test_messages.editions.extension_int32',
      );
      expect(byNum.type, 'TYPE_INT32');

      // A proto2 extension on a different extendee resolves too.
      final p2 = reg.lookup(
        'protobuf_test_messages.proto2.TestAllTypesProto2',
        121,
      );
      expect(p2, isNotNull);
      expect(p2!.fullName, 'protobuf_test_messages.proto2.groupfield');

      expect(
        reg.lookup('protobuf_test_messages.proto2.TestAllTypesProto2', 9999),
        isNull,
      );
    });

    test('finds an extension by Any-style type-url and bare FQN', () {
      final reg = gen.$extensionRegistry;
      final byUrl = reg.lookupByTypeUrl(
        'type.googleapis.com/protobuf_test_messages.editions.extension_string',
      );
      expect(byUrl, isNotNull);
      expect(byUrl!.number, 133);
      // A bare FQN (no host prefix) also resolves.
      expect(
        reg.lookupByTypeUrl('protobuf_test_messages.editions.extension_bytes'),
        isNotNull,
      );
    });

    test('a message-typed extension handle carries its embedded descriptor', () {
      final reg = gen.$extensionRegistry;
      final groupExt = reg.lookup(
        'protobuf_test_messages.editions.TestAllTypesEdition2023',
        121,
      );
      expect(groupExt, isNotNull);
      expect(groupExt!.type, 'TYPE_MESSAGE');
      // The handle\'s descriptor is the GroupLikeType field list (its `c` field).
      expect(groupExt.descriptor, isNotNull);
      expect(groupExt.descriptor!.any((f) => f['name'] == 'c'), isTrue);
    });
  });
}
