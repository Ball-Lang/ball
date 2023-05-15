import 'package:ball/ball.dart';

/// Represents a function call
class BallDeclareVariable extends BallFunctionImplementationBody {
  /// the variable name
  final String name;

  /// The variable type
  final List<TypeInfo> types;

  final Object? initialValue;
  
  const BallDeclareVariable({
    required this.name,
    this.types = const [],
    this.initialValue,
  });
}
