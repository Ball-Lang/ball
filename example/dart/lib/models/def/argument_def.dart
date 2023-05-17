import 'type_info.dart';

/// Defines an argument that the function takes
class BallArgumentDef {
  /// The argument name.
  final String name;

  /// What this argument represents
  final String? desc;

  /// The argument types, this is a JSON schema.
  final TypeInfoBase type;

  const BallArgumentDef({
    required this.name,
    this.desc,
    required this.type,
  });
}
