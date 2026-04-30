/// Value type hierarchy for the Ball runtime.
///
/// When compiled to C++, maps to std::variant instead of std::any.
/// Abstract (not sealed) so the engine library can add internal subtypes
/// (FlowSignal, BallFuture, etc.) that participate in the same type system.
library;

/// The root class for all Ball runtime values.
///
/// Every value in the Ball interpreter is a [BallValue]. This explicit type
/// hierarchy enables target-language compilers to emit typed variants
/// (e.g., std::variant in C++, union types in TS) instead of dynamic any.
abstract class BallValue {
  const BallValue();
}

/// A Ball integer value.
class BallInt extends BallValue {
  final int value;
  const BallInt(this.value);

  @override
  String toString() => value.toString();

  @override
  bool operator ==(Object other) =>
      other is BallInt && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A Ball double value.
class BallDouble extends BallValue {
  final double value;
  const BallDouble(this.value);

  @override
  String toString() {
    if (value == value.truncateToDouble() &&
        !value.isNaN &&
        !value.isInfinite) {
      return '${value.truncate()}.0';
    }
    return value.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is BallDouble && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A Ball string value.
class BallString extends BallValue {
  final String value;
  const BallString(this.value);

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is BallString && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A Ball boolean value.
class BallBool extends BallValue {
  final bool value;
  const BallBool(this.value);

  @override
  String toString() => value.toString();

  @override
  bool operator ==(Object other) =>
      other is BallBool && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A Ball list value (ordered collection).
class BallList extends BallValue {
  final List<Object?> items;
  BallList([List<Object?>? items]) : items = items ?? [];

  @override
  String toString() => '[${items.join(', ')}]';
}

/// A Ball map value (string-keyed ordered map).
class BallMap extends BallValue {
  final Map<String, Object?> entries;
  BallMap([Map<String, Object?>? entries]) : entries = entries ?? {};

  Object? operator [](String key) => entries[key];
  void operator []=(String key, Object? value) => entries[key] = value;

  @override
  String toString() =>
      '{${entries.entries.map((e) => '${e.key}: ${e.value}').join(', ')}}';
}

/// A Ball function value (first-class callable).
class BallFunction extends BallValue {
  final Object? Function(Object?) value;
  const BallFunction(this.value);
  Object? call(Object? arg) => value(arg);
}

/// A Ball null value.
class BallNull extends BallValue {
  const BallNull();

  @override
  String toString() => 'null';

  @override
  bool operator ==(Object other) => other is BallNull;

  @override
  int get hashCode => 0;
}

/// Wrap a raw Dart [Object?] into the [BallValue] hierarchy.
BallValue wrap(Object? raw) {
  if (raw == null) return const BallNull();
  if (raw is BallValue) return raw;
  if (raw is int) return BallInt(raw);
  if (raw is double) return BallDouble(raw);
  if (raw is bool) return BallBool(raw);
  if (raw is String) return BallString(raw);
  if (raw is List) return BallList(raw);
  if (raw is Map<String, dynamic>) return BallMap(raw);
  if (raw is Function) {
    return BallFunction((arg) => (raw as dynamic)(arg));
  }
  return BallNull();
}

/// Unwrap a [BallValue] back to a raw Dart [Object?].
Object? unwrap(BallValue val) {
  return switch (val) {
    BallInt(:var value) => value,
    BallDouble(:var value) => value,
    BallString(:var value) => value,
    BallBool(:var value) => value,
    BallList(:var items) => items,
    BallMap(:var entries) => entries,
    BallFunction(:var value) => value,
    BallNull() => null,
    _ => val,
  };
}
