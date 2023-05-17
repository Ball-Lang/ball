import 'package:ball/ball.dart';

/// Declare a new variable with a type and an initial variable
class BallVar extends BallFunctionImplementationBody {
  /// the variable name
  final String name;

  /// The variable type
  final SchemaTypeInfo type;

  final Object? initialValue;

  const BallVar({
    required this.name,
    this.type = SchemaTypeInfo.$dynamic,
    this.initialValue,
  });
}
