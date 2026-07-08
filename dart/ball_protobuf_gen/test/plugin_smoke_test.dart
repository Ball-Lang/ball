/// Phase-1 smoke test for `protoc-gen-ball`: round-trip the plugin protocol
/// through the process-free [generate] / [decodeRequest] / [encodeResponse]
/// core, without spawning protoc.
///
/// We build a real `CodeGeneratorRequest` by wrapping the checked-in upstream
/// `test_messages.fds.binpb` FileDescriptorSet (each `FileDescriptorProto`
/// becomes a `proto_file` entry) and choosing a couple of its files as
/// `file_to_generate`. That request is encoded with the `ball_protobuf`
/// runtime, then fed back through [decodeRequest] — proving the decode path
/// handles real protoc output — and finally [generate]'s response is re-decoded
/// to assert feature flags, edition range, and one output file per requested
/// input.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart' show FileDescriptorSet;
import 'package:ball_protobuf/ball_protobuf.dart';
import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';
import 'package:test/test.dart';

/// Walks up from the test's CWD to the checked-in conformance FileDescriptorSet
/// (mirrors `descriptor_bridge_test.dart`), so the test is CWD-independent.
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

/// The same hand-authored request descriptor the plugin decodes against, used
/// here only to *encode* a synthetic request (proving encode↔decode agree).
const List<Map<String, Object?>> _requestDescriptor = [
  {
    'name': 'file_to_generate',
    'number': 1,
    'type': 'TYPE_STRING',
    'label': 'LABEL_REPEATED',
    'repeated': true,
  },
  {'name': 'parameter', 'number': 2, 'type': 'TYPE_STRING'},
  {
    'name': 'proto_file',
    'number': 15,
    'type': 'TYPE_MESSAGE',
    'label': 'LABEL_REPEATED',
    'repeated': true,
  },
];

/// The response descriptor, used to decode and inspect [encodeResponse] output.
const List<Map<String, Object?>> _responseFileDescriptor = [
  {'name': 'name', 'number': 1, 'type': 'TYPE_STRING'},
  {'name': 'insertion_point', 'number': 2, 'type': 'TYPE_STRING'},
  {'name': 'content', 'number': 15, 'type': 'TYPE_STRING'},
];
const List<Map<String, Object?>> _responseDescriptor = [
  {'name': 'error', 'number': 1, 'type': 'TYPE_STRING'},
  {'name': 'supported_features', 'number': 2, 'type': 'TYPE_UINT64'},
  {'name': 'minimum_edition', 'number': 3, 'type': 'TYPE_INT32'},
  {'name': 'maximum_edition', 'number': 4, 'type': 'TYPE_INT32'},
  {
    'name': 'file',
    'number': 15,
    'type': 'TYPE_MESSAGE',
    'label': 'LABEL_REPEATED',
    'repeated': true,
    'messageDescriptor': _responseFileDescriptor,
  },
];

/// Builds a serialized `CodeGeneratorRequest` wrapping the FileDescriptorSet at
/// [fdsPath]. Returns `(requestBytes, fileNames)` where `fileNames` are the
/// `.proto` names selected for `file_to_generate`.
({List<int> bytes, List<String> toGenerate}) _buildRequest(
  String fdsPath, {
  String parameter = '',
  int filesToGenerate = 2,
}) {
  final fds = FileDescriptorSet.fromBuffer(File(fdsPath).readAsBytesSync());
  final protoFileBytes = <List<int>>[
    for (final f in fds.file) f.writeToBuffer(),
  ];
  final names = [for (final f in fds.file) f.name];
  final toGenerate = names.take(filesToGenerate).toList();

  final map = <String, Object?>{
    'file_to_generate': toGenerate,
    if (parameter.isNotEmpty) 'parameter': parameter,
    'proto_file': protoFileBytes,
  };
  return (bytes: marshal(map, _requestDescriptor), toGenerate: toGenerate);
}

void main() {
  late String fdsPath;
  setUpAll(() => fdsPath = _findDescriptorSet());

  group('decodeRequest', () {
    test('decodes a real protoc-style CodeGeneratorRequest', () {
      final req = _buildRequest(fdsPath, parameter: 'k=v', filesToGenerate: 2);
      final decoded = decodeRequest(req.bytes);

      expect(decoded.filesToGenerate, req.toGenerate);
      expect(decoded.filesToGenerate, hasLength(2));
      expect(decoded.parameter, 'k=v');
      // proto_file carries every file in the set as raw bytes (left undecoded
      // by this layer), so there are at least as many as files_to_generate.
      expect(decoded.protoFiles.length, greaterThanOrEqualTo(2));
      expect(decoded.protoFiles, everyElement(isA<List<int>>()));
    });

    test('empty parameter decodes to empty string', () {
      final req = _buildRequest(fdsPath, filesToGenerate: 1);
      expect(decodeRequest(req.bytes).parameter, isEmpty);
    });
  });

  group('generate + encodeResponse round-trip', () {
    test(
      'response advertises proto3-optional + editions and the correct range',
      () {
        final req = _buildRequest(fdsPath, filesToGenerate: 3);
        final responseBytes = runPlugin(req.bytes);
        final resp = unmarshal(responseBytes, _responseDescriptor);

        // No error.
        expect(resp['error'], anyOf(isNull, isEmpty));

        // supported_features = FEATURE_PROTO3_OPTIONAL | FEATURE_SUPPORTS_EDITIONS
        expect(
          resp['supported_features'],
          featureProto3Optional | featureSupportsEditions,
        );
        expect(resp['supported_features'], 3);

        // Edition range = ball_protobuf's supported span (proto2 .. 2024).
        expect(resp['minimum_edition'], minimumSupportedEdition);
        expect(resp['maximum_edition'], maximumSupportedEdition);
        expect(resp['minimum_edition'], editionProto2);
        expect(resp['maximum_edition'], edition2024);
      },
    );

    test('emits exactly one output file per file_to_generate entry', () {
      final req = _buildRequest(fdsPath, filesToGenerate: 3);
      final resp = unmarshal(runPlugin(req.bytes), _responseDescriptor);

      final files = (resp['file'] as List).cast<Map<String, Object?>>();
      expect(files, hasLength(req.toGenerate.length));

      // Output names map 1:1 from input .proto names (.pb.dart), and each file
      // carries the generated do-not-edit header naming its source file.
      for (var i = 0; i < req.toGenerate.length; i++) {
        final input = req.toGenerate[i];
        final expectedName =
            '${input.substring(0, input.length - '.proto'.length)}.pb.dart';
        expect(files[i]['name'], expectedName);
        final content = files[i]['content'] as String;
        expect(content, contains('GENERATED CODE'));
        expect(content, contains('protoc-gen-ball from $input'));
        expect(
          content,
          contains("import 'package:ball_protobuf/ball_protobuf.dart'"),
        );
      }
    });

    test('no files requested ⇒ valid response with zero files', () {
      // A request with proto_file populated but file_to_generate empty.
      final fds = FileDescriptorSet.fromBuffer(File(fdsPath).readAsBytesSync());
      final reqBytes = marshal({
        'proto_file': [for (final f in fds.file) f.writeToBuffer()],
      }, _requestDescriptor);

      final resp = unmarshal(runPlugin(reqBytes), _responseDescriptor);
      expect(resp['file'], anyOf(isNull, isEmpty));
      expect(resp['supported_features'], 3);
    });
  });

  group('generate (direct, no codec)', () {
    test('one generated .pb.dart per requested input', () {
      final fds = FileDescriptorSet.fromBuffer(File(fdsPath).readAsBytesSync());
      final names = [for (final f in fds.file) f.name];
      final toGenerate = names.take(2).toList();
      final response = generate(
        PluginRequest(
          filesToGenerate: toGenerate,
          parameter: 'opt=1',
          protoFiles: [for (final f in fds.file) f.writeToBuffer()],
        ),
      );
      expect(response.error, isEmpty);
      expect(response.files, hasLength(2));
      for (var i = 0; i < toGenerate.length; i++) {
        final input = toGenerate[i];
        final expectedName =
            '${input.substring(0, input.length - '.proto'.length)}.pb.dart';
        expect(response.files[i].name, expectedName);
        expect(response.files[i].content, contains('GENERATED CODE'));
      }
      expect(
        response.supportedFeatures,
        featureProto3Optional | featureSupportsEditions,
      );
    });

    test('empty file_to_generate yields a valid zero-file response', () {
      final response = generate(
        const PluginRequest(filesToGenerate: [], parameter: '', protoFiles: []),
      );
      expect(response.error, isEmpty);
      expect(response.files, isEmpty);
      expect(
        response.supportedFeatures,
        featureProto3Optional | featureSupportsEditions,
      );
    });
  });
}
