import 'argument_def.dart';

abstract class TypeInfoBase {
  const TypeInfoBase();
}

class FunctionTypeInfoGenericTypeDeclaration {
  final String name;
  final String desc;
  final List<TypeInfoBase> constraints;

  const FunctionTypeInfoGenericTypeDeclaration({
    required this.name,
    required this.desc,
    this.constraints = const [],
  });
}

class FunctionTypeInfo extends TypeInfoBase {
  final List<BallArgumentDef> genericArguments;
  //Map<OutputName, SchemaTypeInfo>
  final List<BallArgumentDef> outputs;
  //Map<ArgumentName, SchemaTypeInfo>
  final List<BallArgumentDef> inputs;

  const FunctionTypeInfo({
    this.inputs = const [],
    this.outputs = const [],
    this.genericArguments = const [],
  });
}

class SchemaTypeInfo extends TypeInfoBase {
  static const kTKey = 'TKey';
  static const kTValue = 'TValue';

  static const SchemaTypeInfo $null = SchemaTypeInfo(root: 'null');
  static const SchemaTypeInfo $any = SchemaTypeInfo(root: 'object');
  //signed num
  static const SchemaTypeInfo $num = SchemaTypeInfo(root: 'num');
  //signed int
  static const SchemaTypeInfo $int = SchemaTypeInfo(root: 'int');
  //unsigned num
  static const SchemaTypeInfo uNum = SchemaTypeInfo(root: 'uNum');
  //unsigned int
  static const SchemaTypeInfo uInt = SchemaTypeInfo(root: 'uInt');
  //string
  static const SchemaTypeInfo string = SchemaTypeInfo(root: 'string');

  factory SchemaTypeInfo.listOf(SchemaTypeInfo sub) => SchemaTypeInfo(
        root: 'list',
        genericTypeArguments: {kTValue: sub},
      );

  factory SchemaTypeInfo.mapOf(SchemaTypeInfo key, SchemaTypeInfo value) =>
      SchemaTypeInfo(
        root: 'map',
        genericTypeArguments: {
          kTKey: key,
          kTValue: value,
        },
      );

  final String root;
  final Map<String, SchemaTypeInfo> genericTypeArguments;

  const SchemaTypeInfo({
    required this.root,
    this.genericTypeArguments = const {},
  });
}
