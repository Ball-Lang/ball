import 'package:collection/collection.dart';

import 'argument_def.dart';
import 'function_type.dart';

final _eq = DeepCollectionEquality();

class SchemaTypeInfo {
  static const kTKey = 'TKey';
  static const kTValue = 'TValue';

  static const SchemaTypeInfo $null = SchemaTypeInfo(root: 'null');
  static const SchemaTypeInfo $dynamic = SchemaTypeInfo(root: 'dynamic');
  //signed num
  static const SchemaTypeInfo $bool = SchemaTypeInfo(root: 'bool');
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
        genericTypeArguments: [
          BallArgumentDef(name: kTValue, type: sub),
        ],
      );

  factory SchemaTypeInfo.mapOf(SchemaTypeInfo key, SchemaTypeInfo value) =>
      SchemaTypeInfo(
        root: 'map',
        genericTypeArguments: [
          BallArgumentDef(name: kTKey, type: key),
          BallArgumentDef(name: kTValue, type: value)
        ],
      );

  factory SchemaTypeInfo.function({
    List<BallArgumentDef> inputs = const [],
    List<BallArgumentDef> outputs = const [],
    List<BallArgumentDef> genericTypeArguments = const [],
  }) =>
      FunctionTypeInfo(
        inputs: inputs,
        outputs: outputs,
        genericTypeArguments: genericTypeArguments,
      );

  final String root;
  final List<BallArgumentDef> genericTypeArguments;
  Map<String, SchemaTypeInfo> get genericTypeArgumentsMap => Map.fromEntries(
        genericTypeArguments.map((e) => MapEntry(e.name, e.type)),
      );

  @override
  bool operator ==(Object other) =>
      other is SchemaTypeInfo &&
      other.runtimeType == runtimeType &&
      other.root == root &&
      _eq.equals(genericTypeArgumentsMap, other.genericTypeArgumentsMap);

  @override
  int get hashCode =>
      Object.hash(root.hashCode, _eq.hash(genericTypeArgumentsMap));

  const SchemaTypeInfo({
    required this.root,
    this.genericTypeArguments = const [],
  });
}
