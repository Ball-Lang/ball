/// Phase-0 smoke tests for ball_protobuf_gen: the moved descriptor bridge plus
/// the new public runtime entry points it will drive (message-level proto3-JSON,
/// service/method descriptors, the Connect end-of-stream frame flag, and the
/// extension registry).
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show
        DescriptorProto,
        Edition,
        FeatureSet,
        FeatureSet_FieldPresence,
        FieldDescriptorProto,
        FieldDescriptorProto_Label,
        FieldDescriptorProto_Type,
        FileDescriptorProto,
        FileDescriptorSet,
        MessageOptions;
import 'package:ball_protobuf/ball_protobuf.dart';
import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';
import 'package:test/test.dart';

/// Walks up from the test's CWD to the checked-in conformance FileDescriptorSet
/// (mirrors `tool/conformance_main.dart`), so the test is CWD-independent.
String _findDescriptorSet() {
  const rel = 'tests/editions/descriptors/test_messages.fds.binpb';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final f = File('${dir.path}/$rel');
    if (f.existsSync()) return f.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate $rel from ${Directory.current.path}');
}

void main() {
  group('descriptor bridge (moved into ball_protobuf_gen)', () {
    late DescriptorRegistry registry;

    setUpAll(() {
      registry = buildRegistry(File(_findDescriptorSet()).readAsBytesSync());
    });

    test('builds a registry of resolved field descriptors', () {
      expect(registry, isNotEmpty);
      // The upstream conformance message types are present.
      expect(
        registry.keys,
        contains('protobuf_test_messages.proto3.TestAllTypesProto3'),
      );
      final fields =
          registry['protobuf_test_messages.proto3.TestAllTypesProto3']!;
      expect(fields, isNotEmpty);
      // Every field carries a resolved 6-key FeatureSet (the bridge's job).
      for (final f in fields) {
        expect(f['features'], isA<Map<String, String>>());
      }
    });

    test(
      'a bridged descriptor round-trips through the public proto3-JSON entry '
      'points',
      () {
        final desc =
            registry['protobuf_test_messages.proto3.TestAllTypesProto3']!;
        // anyTypeResolver is wired from the same registry, exactly as the
        // conformance loop does.
        final msg = <String, Object?>{
          'optional_int32': 42,
          'optional_string': 'hello',
          'repeated_int32': <int>[1, 2, 3],
        };
        final json = messageToJson(
          msg,
          desc,
          anyTypeResolver: (name) => registry[name],
        );
        expect(json, isA<Map<String, Object?>>());
        final jsonMap = json as Map<String, Object?>;
        // snake_case -> lowerCamelCase keys, defaults omitted.
        expect(jsonMap['optionalInt32'], 42);
        expect(jsonMap['optionalString'], 'hello');
        expect(jsonMap['repeatedInt32'], [1, 2, 3]);

        final back = messageFromJson(jsonMap, desc);
        expect(back['optional_int32'], 42);
        expect(back['optional_string'], 'hello');
        expect(back['repeated_int32'], [1, 2, 3]);
      },
    );

    test('a message-level FeatureSet override (editions) merges over the file '
        'defaults', () {
      // An EDITION_2023 file with NO file-level features.options.features
      // override, but the message itself overrides field_presence to
      // LEGACY_REQUIRED. This exercises `_indexMessage`'s
      // `m.hasOptions() && m.options.hasFeatures()` true arm (bridge builds
      // the message-level override map and merges it over the file's
      // resolved features), distinct from the (already-covered) file-level
      // override and the legacy proto2/proto3 paths.
      final fds = FileDescriptorSet(
        file: [
          FileDescriptorProto(
            name: 'msg_feature_override.proto',
            package: 'msgfeat',
            edition: Edition.EDITION_2023,
            messageType: [
              DescriptorProto(
                name: 'Overridden',
                field: [
                  FieldDescriptorProto(
                    name: 'value',
                    number: 1,
                    type: FieldDescriptorProto_Type.TYPE_INT32,
                    label: FieldDescriptorProto_Label.LABEL_OPTIONAL,
                  ),
                ],
                options: MessageOptions(
                  features: FeatureSet(
                    fieldPresence: FeatureSet_FieldPresence.LEGACY_REQUIRED,
                  ),
                ),
              ),
              // A sibling message with no options at all, to prove the
              // override doesn't leak: it must inherit the plain file
              // defaults (EXPLICIT presence for EDITION_2023).
              DescriptorProto(
                name: 'Plain',
                field: [
                  FieldDescriptorProto(
                    name: 'value',
                    number: 1,
                    type: FieldDescriptorProto_Type.TYPE_INT32,
                    label: FieldDescriptorProto_Label.LABEL_OPTIONAL,
                  ),
                ],
              ),
            ],
          ),
        ],
      );

      final registry = buildRegistry(fds.writeToBuffer());

      final overriddenFields = registry['msgfeat.Overridden']!;
      expect(overriddenFields, hasLength(1));
      expect(
        overriddenFields.single['features'],
        containsPair('field_presence', 'LEGACY_REQUIRED'),
      );

      final plainFields = registry['msgfeat.Plain']!;
      expect(plainFields, hasLength(1));
      expect(
        plainFields.single['features'],
        containsPair('field_presence', 'EXPLICIT'),
      );
    });
  });

  group('service descriptors', () {
    test('method kind derives from streaming flags', () {
      expect(
        methodKindFromFlags(clientStreaming: false, serverStreaming: false),
        MethodKind.unary,
      );
      expect(
        methodKindFromFlags(clientStreaming: false, serverStreaming: true),
        MethodKind.serverStreaming,
      );
      expect(
        methodKindFromFlags(clientStreaming: true, serverStreaming: false),
        MethodKind.clientStreaming,
      );
      expect(
        methodKindFromFlags(clientStreaming: true, serverStreaming: true),
        MethodKind.bidiStreaming,
      );
    });

    test('ServiceDescriptor looks up methods by name', () {
      const svc = ServiceDescriptor(
        fullName: 'acme.Eliza',
        methods: [
          MethodDescriptor(
            name: 'Say',
            fullName: 'acme.Eliza.Say',
            inputDescriptor: 'acme.SayRequest',
            outputDescriptor: 'acme.SayResponse',
            kind: MethodKind.unary,
            idempotency: IdempotencyLevel.noSideEffects,
          ),
        ],
      );
      final say = svc.methodByName('Say');
      expect(say, isNotNull);
      expect(say!.kind, MethodKind.unary);
      expect(say.idempotency, IdempotencyLevel.noSideEffects);
      expect(svc.methodByName('Nope'), isNull);
    });
  });

  group('gRPC / Connect frame flags', () {
    test('end-of-stream and compression bits round-trip', () {
      final flags = grpcMakeFlags(compressed: true, endOfStream: true);
      expect(grpcFlagIsCompressed(flags), isTrue);
      expect(grpcFlagIsEndOfStream(flags), isTrue);

      final frame = grpcEncodeFrameWithFlags([7, 8, 9], flags);
      final decoded = grpcDecodeFrameWithFlags(frame, 0);
      expect(decoded['messageBytes'], [7, 8, 9]);
      expect(decoded['compressed'], isTrue);
      expect(decoded['endOfStream'], isTrue);
    });

    test('plain gRPC frame has neither bit set', () {
      final frame = grpcEncodeFrame([1, 2, 3]);
      final decoded = grpcDecodeFrameWithFlags(frame, 0);
      expect(decoded['compressed'], isFalse);
      expect(decoded['endOfStream'], isFalse);
      expect(decoded['messageBytes'], [1, 2, 3]);
    });
  });

  group('extension registry', () {
    test('looks up by (extendee, number) and by type-url', () {
      const ext = Extension(
        extendeeFullName: 'acme.User',
        fieldKey: '[acme.user_email]',
        number: 121,
        type: 'TYPE_STRING',
      );
      expect(ext.fullName, 'acme.user_email');

      final reg = ExtensionRegistry.of([ext]);
      expect(reg.lookup('acme.User', 121), same(ext));
      expect(reg.lookup('acme.User', 999), isNull);
      expect(
        reg.lookupByTypeUrl('type.googleapis.com/acme.user_email'),
        same(ext),
      );
      // A bare FQN (no host prefix) also resolves.
      expect(reg.lookupByTypeUrl('acme.user_email'), same(ext));
    });

    test('mergeRegistries combines per-file registries', () {
      const a = Extension(
        extendeeFullName: 'acme.User',
        fieldKey: '[acme.a]',
        number: 1,
        type: 'TYPE_INT32',
      );
      const b = Extension(
        extendeeFullName: 'acme.Order',
        fieldKey: '[acme.b]',
        number: 2,
        type: 'TYPE_BOOL',
      );
      final merged = mergeRegistries([
        ExtensionRegistry.of([a]),
        ExtensionRegistry.of([b]),
      ]);
      expect(merged.lookup('acme.User', 1), same(a));
      expect(merged.lookup('acme.Order', 2), same(b));
      expect(merged.extensions, hasLength(2));
    });
  });
}
