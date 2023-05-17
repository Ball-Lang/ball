import 'package:ball/ball.dart';

/// Tracks the internal state of method calls
class MethodCallContext {
  /// Maps variable names to their values
  final Map<String, Object?> values;
  final Map<String, SchemaTypeInfo> genericArgumentAssignments;

  /// Uri of the called method
  final Uri methodUri;

  /// The resolved method def
  final BallFunctionDef def;

  
  const MethodCallContext({
    this.values = const {},
    required this.methodUri,
    required this.def,
    this.genericArgumentAssignments = const {},
  });
}
