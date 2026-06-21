/// Coverage-focused tests for the Connect + gRPC service plugin cores
/// (generateConnect / generateGrpc / runConnectPlugin / runGrpcPlugin, plus
/// their error branches) and service_common's client-/bidi-streaming method
/// emission + duplicate-method-name disambiguation.
@TestOn('vm')
library;

import 'package:ball_base/ball_base.dart'
    show
        DescriptorProto,
        FieldDescriptorProto,
        FieldDescriptorProto_Label,
        FieldDescriptorProto_Type,
        FileDescriptorProto,
        MethodDescriptorProto,
        ServiceDescriptorProto;
import 'package:ball_protobuf/ball_protobuf.dart' show marshal;
import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';
import 'package:test/test.dart';

FieldDescriptorProto _field(
  String name,
  int number,
  FieldDescriptorProto_Type type,
) => FieldDescriptorProto()
  ..name = name
  ..number = number
  ..type = type
  ..label = FieldDescriptorProto_Label.LABEL_OPTIONAL;

MethodDescriptorProto _method(
  String name, {
  bool clientStreaming = false,
  bool serverStreaming = false,
}) => MethodDescriptorProto()
  ..name = name
  ..inputType = '.svc.Req'
  ..outputType = '.svc.Resp'
  ..clientStreaming = clientStreaming
  ..serverStreaming = serverStreaming;

/// `svc/svc.proto` with all four streaming kinds plus a duplicate method name
/// (after lowerCamel folding) to exercise _uniqueMethodName.
FileDescriptorProto _svcProto() {
  final req = DescriptorProto()
    ..name = 'Req'
    ..field.add(_field('x', 1, FieldDescriptorProto_Type.TYPE_INT32));
  final resp = DescriptorProto()
    ..name = 'Resp'
    ..field.add(_field('y', 1, FieldDescriptorProto_Type.TYPE_INT32));

  final service = ServiceDescriptorProto()
    ..name = 'Svc'
    ..method.addAll([
      _method('Unary'),
      _method('Down', serverStreaming: true),
      _method('Up', clientStreaming: true),
      _method('Chat', clientStreaming: true, serverStreaming: true),
      // 'Run' and 'run' both fold to dartName 'run' -> the second gets 'run2'.
      _method('Run'),
      _method('run'),
    ]);

  return FileDescriptorProto()
    ..name = 'svc/svc.proto'
    ..package = 'svc'
    ..syntax = 'proto3'
    ..messageType.addAll([req, resp])
    ..service.add(service);
}

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

/// Builds a serialized CodeGeneratorRequest wrapping [fdsProtoFiles].
List<int> _request(List<List<int>> protoFiles, List<String> toGenerate) =>
    marshal({
      'file_to_generate': toGenerate,
      'proto_file': protoFiles,
    }, _requestDescriptor);

void main() {
  late List<int> protoFile;
  setUpAll(() => protoFile = _svcProto().writeToBuffer());

  PluginRequest req([List<String>? toGenerate]) => PluginRequest(
    filesToGenerate: toGenerate ?? const ['svc/svc.proto'],
    parameter: '',
    protoFiles: [protoFile],
  );

  group('service_common method models', () {
    test('buildServiceModel resolves all four streaming kinds', () {
      final svc = _svcProto().service.single;
      final model = buildServiceModel(svc, 'svc');
      final kinds = {for (final m in model.methods) m.name: m.kind};
      expect(kinds['Unary'], ServiceMethodKind.unary);
      expect(kinds['Down'], ServiceMethodKind.serverStreaming);
      expect(kinds['Up'], ServiceMethodKind.clientStreaming);
      expect(kinds['Chat'], ServiceMethodKind.bidiStreaming);
      // Duplicate-name disambiguation: Run -> run, run -> run2.
      final dartNames = model.methods.map((m) => m.dartName).toList();
      expect(dartNames, containsAll(['run', 'run2']));
    });

    test('kindEnumName covers client/bidi streaming', () {
      expect(
        kindEnumName(ServiceMethodKind.clientStreaming),
        'clientStreaming',
      );
      expect(kindEnumName(ServiceMethodKind.bidiStreaming), 'bidiStreaming');
    });

    test('emitClientMethod emits client- and bidi-streaming bodies', () {
      final svc = _svcProto().service.single;
      final model = buildServiceModel(svc, 'svc');
      String classOf(String fqn) => fqn.split('.').last;
      final b = StringBuffer();
      for (final m in model.methods) {
        emitClientMethod(b, m, classOf);
      }
      final out = b.toString();
      // Client-streaming method takes a Stream and calls transport.clientStream.
      expect(out, contains('transport.clientStream('));
      // Bidi-streaming method calls transport.bidiStream.
      expect(out, contains('.bidiStream('));
      // Server-streaming + unary too.
      expect(out, contains('.serverStream('));
      expect(out, contains('transport.unary('));
    });
  });

  group('generateConnect', () {
    test('emits a <file>.connect.dart for the service', () {
      final resp = generateConnect(req());
      expect(resp.error, isEmpty);
      expect(resp.files.map((f) => f.name), contains('svc/svc.connect.dart'));
      expect(resp.files.single.content, contains('transport.clientStream('));
    });

    test('empty file_to_generate yields a valid zero-file response', () {
      final resp = generateConnect(
        const PluginRequest(filesToGenerate: [], parameter: '', protoFiles: []),
      );
      expect(resp.error, isEmpty);
      expect(resp.files, isEmpty);
    });

    test('a malformed proto_file surfaces as an error response', () {
      final resp = generateConnect(
        const PluginRequest(
          filesToGenerate: ['svc/svc.proto'],
          parameter: '',
          protoFiles: [
            [0xff, 0xff, 0xff, 0xff],
          ],
        ),
      );
      expect(resp.error, contains('protoc-gen-ball-connect'));
      expect(resp.files, isEmpty);
    });

    test('runConnectPlugin round-trips bytes -> response bytes', () {
      final bytes = runConnectPlugin(_request([protoFile], ['svc/svc.proto']));
      expect(bytes, isNotEmpty);
    });
  });

  group('generateGrpc', () {
    test('emits a <file>.grpc.dart for the service', () {
      final resp = generateGrpc(req());
      expect(resp.error, isEmpty);
      expect(resp.files.map((f) => f.name), contains('svc/svc.grpc.dart'));
    });

    test('empty file_to_generate yields a valid zero-file response', () {
      final resp = generateGrpc(
        const PluginRequest(filesToGenerate: [], parameter: '', protoFiles: []),
      );
      expect(resp.error, isEmpty);
      expect(resp.files, isEmpty);
    });

    test('a malformed proto_file surfaces as an error response', () {
      final resp = generateGrpc(
        const PluginRequest(
          filesToGenerate: ['svc/svc.proto'],
          parameter: '',
          protoFiles: [
            [0xff, 0xff, 0xff, 0xff],
          ],
        ),
      );
      expect(resp.error, contains('protoc-gen-ball-grpc'));
      expect(resp.files, isEmpty);
    });

    test('runGrpcPlugin round-trips bytes -> response bytes', () {
      final bytes = runGrpcPlugin(_request([protoFile], ['svc/svc.proto']));
      expect(bytes, isNotEmpty);
    });
  });

  group('generate (message plugin) error branch', () {
    test('a malformed proto_file surfaces as an error response', () {
      final resp = generate(
        const PluginRequest(
          filesToGenerate: ['svc/svc.proto'],
          parameter: '',
          protoFiles: [
            [0xff, 0xff, 0xff, 0xff],
          ],
        ),
      );
      expect(resp.error, contains('protoc-gen-ball'));
      expect(resp.files, isEmpty);
    });
  });
}
