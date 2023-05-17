import 'package:ball/ball.dart';

class ValueInputMapping extends BallInputMappingBase {
  final Object? value;
  const ValueInputMapping({
    required this.value,
  });
}

class TypedValueInputMapping extends ValueInputMapping {
  final SchemaTypeInfo type;
  const TypedValueInputMapping({
    required super.value,
    required this.type,
  });
}
