import 'package:ball_protobuf/well_known.dart';
import 'package:test/test.dart';

void main() {
  group('structToMap', () {
    test('with the fields wrapper', () {
      final struct = {
        'fields': {
          'a': {'numberValue': 1},
          's': {'stringValue': 'x'},
        },
      };
      final out = structToMap(struct);
      expect(out['a'], 1);
      expect(out['s'], 'x');
    });

    test('already-unwrapped fields map', () {
      final unwrapped = {
        'a': {'numberValue': 2},
      };
      expect(structToMap(unwrapped)['a'], 2);
    });

    test('non-Value entry passes through', () {
      final struct = {
        'fields': {'raw': 42},
      };
      expect(structToMap(struct)['raw'], 42);
    });
  });

  group('valueToNative', () {
    test('null / number / string / bool', () {
      expect(valueToNative({'nullValue': 'NULL_VALUE'}), null);
      expect(valueToNative({'numberValue': 3.5}), 3.5);
      expect(valueToNative({'stringValue': 'hi'}), 'hi');
      expect(valueToNative({'boolValue': true}), true);
    });

    test('structValue recurses', () {
      final v = {
        'structValue': {
          'fields': {
            'k': {'numberValue': 9},
          },
        },
      };
      expect(valueToNative(v), {'k': 9});
    });

    test('structValue with a non-map passes through', () {
      expect(valueToNative({'structValue': 'oops'}), 'oops');
    });

    test('listValue wrapped in {values:[...]}', () {
      final v = {
        'listValue': {
          'values': [
            {'numberValue': 1},
            {'stringValue': 'a'},
          ],
        },
      };
      expect(valueToNative(v), [1, 'a']);
    });

    test('listValue as a bare list', () {
      final v = {
        'listValue': [
          {'numberValue': 1},
          2,
        ],
      };
      expect(valueToNative(v), [1, 2]);
    });

    test('listValue neither map nor list passes through', () {
      expect(valueToNative({'listValue': 'oops'}), 'oops');
    });

    test('empty value map returns null', () {
      expect(valueToNative(<String, Object?>{}), null);
    });
  });

  group('nativeToValue', () {
    test('all supported scalar types', () {
      expect(nativeToValue(null), {'nullValue': 'NULL_VALUE'});
      expect(nativeToValue(5), {'numberValue': 5});
      expect(nativeToValue('x'), {'stringValue': 'x'});
      expect(nativeToValue(true), {'boolValue': true});
    });

    test('map becomes a structValue', () {
      final v = nativeToValue({'k': 1});
      expect(v.containsKey('structValue'), true);
    });

    test('list becomes a listValue with nested values', () {
      final v = nativeToValue([1, 'a', true]);
      final lv = v['listValue'] as Map;
      final values = lv['values'] as List;
      expect(values.length, 3);
      expect((values[0] as Map)['numberValue'], 1);
    });

    test('unsupported type throws', () {
      expect(
        () => nativeToValue(DateTime(2020)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('timestampToRfc3339 edge cases', () {
    test('negative seconds (pre-epoch)', () {
      final rfc = timestampToRfc3339({'seconds': -1, 'nanos': 0});
      expect(rfc, '1969-12-31T23:59:59Z');
    });

    test('nanos trim to milliseconds', () {
      final rfc = timestampToRfc3339({'seconds': 0, 'nanos': 120000000});
      expect(rfc, '1970-01-01T00:00:00.12Z');
    });

    test('full nanosecond precision retained', () {
      final rfc = timestampToRfc3339({'seconds': 0, 'nanos': 123456789});
      expect(rfc, '1970-01-01T00:00:00.123456789Z');
    });

    test('coerces num/string seconds via _toInt', () {
      expect(
        timestampToRfc3339({'seconds': 0.0, 'nanos': 0}),
        '1970-01-01T00:00:00Z',
      );
      expect(
        timestampToRfc3339({'seconds': '0', 'nanos': '0'}),
        '1970-01-01T00:00:00Z',
      );
    });
  });

  group('rfc3339ToTimestamp', () {
    test('with a numeric offset', () {
      final ts = rfc3339ToTimestamp('1970-01-01T01:00:00+01:00');
      expect(ts['seconds'], 0);
    });

    test('rejects a lenient form (missing Z)', () {
      expect(
        () => rfc3339ToTimestamp('1970-01-01T00:00:00'),
        throwsA(isA<FormatException>()),
      );
    });

    test('negative fractional flooring', () {
      // -0.5s should floor to seconds=-1, nanos=500000000.
      final ts = rfc3339ToTimestamp('1969-12-31T23:59:59.500Z');
      expect(ts['seconds'], -1);
      expect(ts['nanos'], 500000000);
    });
  });

  group('durationToString / stringToDuration', () {
    test('whole seconds', () {
      expect(durationToString({'seconds': 5, 'nanos': 0}), '5s');
    });

    test('negative whole seconds', () {
      expect(durationToString({'seconds': -5, 'nanos': 0}), '-5s');
    });

    test('negative with nanos', () {
      expect(durationToString({'seconds': 0, 'nanos': -250000000}), '-0.25s');
    });

    test('trailing zeros trimmed', () {
      expect(durationToString({'seconds': 1, 'nanos': 500000000}), '1.5s');
    });

    test('stringToDuration whole seconds', () {
      expect(stringToDuration('5s'), {'seconds': 5, 'nanos': 0});
    });

    test('stringToDuration negative whole', () {
      expect(stringToDuration('-3s'), {'seconds': -3, 'nanos': 0});
    });

    test('stringToDuration negative fractional', () {
      expect(stringToDuration('-0.5s'), {'seconds': 0, 'nanos': -500000000});
    });

    test('missing trailing s throws', () {
      expect(() => stringToDuration('5'), throwsA(isA<FormatException>()));
    });
  });

  group('packAny / unpackAny', () {
    test('pack merges @type with fields', () {
      final any = packAny('type.googleapis.com/foo.Bar', {'x': 1});
      expect(any['@type'], 'type.googleapis.com/foo.Bar');
      expect(any['x'], 1);
    });

    test('unpack splits @type from message body', () {
      final out = unpackAny({'@type': 'type.googleapis.com/foo.Bar', 'x': 1});
      expect(out['typeUrl'], 'type.googleapis.com/foo.Bar');
      expect((out['message'] as Map)['x'], 1);
    });

    test('unpack missing @type throws', () {
      expect(() => unpackAny({'x': 1}), throwsA(isA<ArgumentError>()));
    });
  });

  group('_toInt error path (via timestamp)', () {
    test('a non-coercible seconds value throws', () {
      expect(
        () => timestampToRfc3339({'seconds': true, 'nanos': 0}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
