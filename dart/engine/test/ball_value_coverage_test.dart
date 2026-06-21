// Pure unit tests for the BallValue hierarchy and wrap/unwrap helpers
// (lib/ball_value.dart). These types are exported from the engine package,
// so they can be exercised directly without running a program.
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

void main() {
  group('BallInt', () {
    test('toString / equality / hashCode', () {
      expect(const BallInt(42).toString(), '42');
      expect(const BallInt(42), const BallInt(42));
      expect(const BallInt(42) == const BallInt(7), isFalse);
      expect(const BallInt(42) == 42, isFalse);
      expect(const BallInt(42).hashCode, 42.hashCode);
    });
  });

  group('BallDouble', () {
    test('positive integral double prints with .0 suffix', () {
      expect(const BallDouble(3.0).toString(), '3.0');
      expect(const BallDouble(10.0).toString(), '10.0');
    });

    test('negative integral double', () {
      expect(const BallDouble(-5.0).toString(), '-5.0');
    });

    test('zero and negative zero', () {
      expect(const BallDouble(0.0).toString(), '0.0');
      expect(BallDouble(-0.0).toString(), '-0.0');
    });

    test('fractional double uses Dart toString', () {
      expect(const BallDouble(3.5).toString(), '3.5');
    });

    test('NaN and infinity fall through to Dart toString', () {
      expect(BallDouble(double.nan).toString(), 'NaN');
      expect(BallDouble(double.infinity).toString(), 'Infinity');
      expect(BallDouble(double.negativeInfinity).toString(), '-Infinity');
    });

    test('equality / hashCode', () {
      expect(const BallDouble(1.5), const BallDouble(1.5));
      expect(const BallDouble(1.5) == const BallDouble(2.5), isFalse);
      expect(const BallDouble(1.5) == 1.5, isFalse);
      expect(const BallDouble(1.5).hashCode, 1.5.hashCode);
    });
  });

  group('BallString', () {
    test('toString / equality / hashCode', () {
      expect(const BallString('hi').toString(), 'hi');
      expect(const BallString('hi'), const BallString('hi'));
      expect(const BallString('hi') == const BallString('bye'), isFalse);
      expect(const BallString('hi') == 'hi', isFalse);
      expect(const BallString('hi').hashCode, 'hi'.hashCode);
    });
  });

  group('BallBool', () {
    test('toString / equality / hashCode', () {
      expect(const BallBool(true).toString(), 'true');
      expect(const BallBool(false).toString(), 'false');
      expect(const BallBool(true), const BallBool(true));
      expect(const BallBool(true) == const BallBool(false), isFalse);
      expect(const BallBool(true) == true, isFalse);
      expect(const BallBool(true).hashCode, true.hashCode);
    });
  });

  group('BallList', () {
    test('default constructor yields empty list', () {
      expect(BallList().items, isEmpty);
    });

    test('toString joins items', () {
      expect(BallList(<Object?>[1, 'a', true]).toString(), '[1, a, true]');
    });
  });

  group('BallMap', () {
    test('default constructor yields empty map', () {
      expect(BallMap().entries, isEmpty);
    });

    test('index get/set operators', () {
      final m = BallMap();
      m['x'] = 1;
      expect(m['x'], 1);
      expect(m['missing'], isNull);
    });

    test('toString renders entries', () {
      final m = BallMap(<String, Object?>{'a': 1, 'b': 2});
      expect(m.toString(), '{a: 1, b: 2}');
    });
  });

  group('BallFunction', () {
    test('call forwards to wrapped function', () {
      final f = BallFunction((arg) => (arg as int) + 1);
      expect(f.call(41), 42);
      expect(f(10), 11);
    });
  });

  group('BallNull', () {
    test('toString / equality / hashCode', () {
      expect(const BallNull().toString(), 'null');
      expect(const BallNull(), const BallNull());
      expect(const BallNull() == 0, isFalse);
      expect(const BallNull().hashCode, 0);
    });
  });

  group('wrap', () {
    test('null -> BallNull', () {
      expect(wrap(null), const BallNull());
    });

    test('passthrough existing BallValue', () {
      const v = BallInt(5);
      expect(identical(wrap(v), v), isTrue);
    });

    test('int -> BallInt', () {
      expect(wrap(7), const BallInt(7));
    });

    test('double -> BallDouble', () {
      expect(wrap(2.5), const BallDouble(2.5));
    });

    test('bool -> BallBool', () {
      expect(wrap(true), const BallBool(true));
    });

    test('String -> BallString', () {
      expect(wrap('s'), const BallString('s'));
    });

    test('List -> BallList', () {
      final w = wrap(<Object?>[1, 2]);
      expect(w, isA<BallList>());
      expect((w as BallList).items, [1, 2]);
    });

    test('Map<String,dynamic> -> BallMap', () {
      final w = wrap(<String, dynamic>{'k': 1});
      expect(w, isA<BallMap>());
      expect((w as BallMap).entries, {'k': 1});
    });

    test('Function -> BallFunction', () {
      final w = wrap((Object? a) => a);
      expect(w, isA<BallFunction>());
      expect((w as BallFunction).call(99), 99);
    });

    test('unsupported type -> BallNull', () {
      expect(wrap(DateTime(2020)), const BallNull());
    });
  });

  group('unwrap', () {
    test('BallInt -> int', () => expect(unwrap(const BallInt(3)), 3));
    test(
      'BallDouble -> double',
      () => expect(unwrap(const BallDouble(3.5)), 3.5),
    );
    test(
      'BallString -> String',
      () => expect(unwrap(const BallString('x')), 'x'),
    );
    test(
      'BallBool -> bool',
      () => expect(unwrap(const BallBool(false)), false),
    );
    test('BallList -> List', () {
      expect(unwrap(BallList(<Object?>[1])), [1]);
    });
    test('BallMap -> Map', () {
      expect(unwrap(BallMap(<String, Object?>{'a': 1})), {'a': 1});
    });
    test('BallNull -> null', () => expect(unwrap(const BallNull()), isNull));
    test('BallFunction -> Function', () {
      final fn = (Object? a) => a;
      final unwrapped = unwrap(BallFunction(fn));
      expect(unwrapped, isA<Function>());
    });
  });

  test('wrap/unwrap round-trips primitive values', () {
    for (final raw in <Object?>[1, 2.5, 'str', true, false]) {
      expect(unwrap(wrap(raw)), raw);
    }
  });
}
