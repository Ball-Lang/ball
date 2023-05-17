import 'argument_def.dart';
import 'type_info.dart';

class FunctionTypeInfoGenericTypeDeclaration {
  final String name;
  final String desc;
  final List<SchemaTypeInfo> constraints;

  const FunctionTypeInfoGenericTypeDeclaration({
    required this.name,
    required this.desc,
    this.constraints = const [],
  });
}

class FunctionTypeInfo extends SchemaTypeInfo {
  //Map<OutputName, SchemaTypeInfo>
  final List<BallArgumentDef> outputs;
  //Map<ArgumentName, SchemaTypeInfo>
  final List<BallArgumentDef> inputs;

  const FunctionTypeInfo({
    this.inputs = const [],
    this.outputs = const [],
    super.genericTypeArguments,
  }) : super(root: 'Function');
}
