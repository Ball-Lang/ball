import 'package:ball/ball.dart';

class BallDeclareVariable extends BallFunctionImplementationBody {
  /// the variable name
  final String name;

  /// The variable type
  final SchemaTypeInfo type;

  final Object? initialValue;

  const BallDeclareVariable({
    required this.name,
    this.type = SchemaTypeInfo.$any,
    this.initialValue,
  });
}
