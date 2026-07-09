/// Wave-6 tail-coverage for `gen_model.dart` (issue #61):
///   * `GenModelBuilder.registry` — the public getter exposing the shared
///     resolved descriptor registry (used by external consumers, e.g. the
///     Connect/gRPC service emitters resolve message types through it — but
///     the getter itself was never called directly in the corpus).
///   * `_buildExtension`'s `isEnum` branch — a proto2 `extend` field whose
///     type is an enum (`enumTypeName` is only populated on that arm). Also
///     closes dart_emitter.dart's matching `isEnum` extension-accessor
///     codegen branch (`get`/`set` using `EnumType.fromValue`/`.value`).
@TestOn('vm')
library;

import 'package:ball_base/ball_base.dart'
    show
        DescriptorProto,
        EnumDescriptorProto,
        EnumValueDescriptorProto,
        FieldDescriptorProto,
        FieldDescriptorProto_Label,
        FieldDescriptorProto_Type,
        FileDescriptorProto,
        FileDescriptorSet;
import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';
import 'package:test/test.dart';

FieldDescriptorProto _field(
  String name,
  int number,
  FieldDescriptorProto_Type type, {
  String? typeName,
  String? extendee,
}) {
  final f = FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = type
    ..label = FieldDescriptorProto_Label.LABEL_OPTIONAL;
  if (typeName != null) f.typeName = typeName;
  if (extendee != null) f.extendee = extendee;
  return f;
}

/// A proto2 file (extensions require proto2/editions — proto3 disallows
/// `extend`): enum Color, message Base, and a top-level `extend Base` field
/// of TYPE_ENUM.
FileDescriptorProto _proto2File() {
  final color = EnumDescriptorProto()
    ..name = 'Color'
    ..value.addAll([
      EnumValueDescriptorProto()
        ..name = 'COLOR_UNKNOWN'
        ..number = 0,
      EnumValueDescriptorProto()
        ..name = 'RED'
        ..number = 1,
    ]);
  final base = DescriptorProto()
    ..name = 'Base'
    ..field.add(_field('id', 1, FieldDescriptorProto_Type.TYPE_INT32));
  final colorExt = _field(
    'color_ext',
    100,
    FieldDescriptorProto_Type.TYPE_ENUM,
    typeName: '.wave6.Color',
    extendee: '.wave6.Base',
  );
  return FileDescriptorProto()
    ..name = 'wave6/base.proto'
    ..package = 'wave6'
    ..syntax = 'proto2'
    ..messageType.add(base)
    ..enumType.add(color)
    ..extension.add(colorExt);
}

List<int> _buildFds() =>
    (FileDescriptorSet()..file.add(_proto2File())).writeToBuffer();

void main() {
  test('GenModelBuilder.registry exposes the resolved descriptor registry', () {
    final builder = GenModelBuilder.fromBytes(_buildFds());
    expect(builder.registry, isNotEmpty);
    expect(builder.registry.containsKey('wave6.Base'), isTrue);
  });

  test('an enum-typed extension field generates enum get/set accessors', () {
    final generated = generateDartModels(
      _buildFds(),
      filesToGenerate: {'wave6/base.proto'},
    );
    final content = generated
        .firstWhere((g) => g.path == 'wave6/base.pb.dart')
        .content;
    // The isEnum branch: `Color.fromValue(v as int)` read + `.value` write.
    expect(content, contains('Color.fromValue('));
    expect(content, contains('.value'));
    expect(content, contains('ColorExt'));
  });
}
