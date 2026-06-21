import 'dart:convert';

import 'package:ball_protobuf/json_codec.dart';
import 'package:test/test.dart';

/// A descriptor for a single field carrying `typeName` so the JSON codec can
/// dispatch on well-known types.
List<Map<String, Object?>> _msgField(
  String name,
  int number,
  String typeName, {
  String? label,
}) => [
  {
    'name': name,
    'number': number,
    'type': 'TYPE_MESSAGE',
    'typeName': typeName,
    if (label != null) 'label': label,
  },
];

void main() {
  group('isWellKnownJsonType', () {
    test('wrapper + structural types are recognized', () {
      expect(isWellKnownJsonType('google.protobuf.Int32Value'), true);
      expect(isWellKnownJsonType('google.protobuf.Timestamp'), true);
      expect(isWellKnownJsonType('google.protobuf.Struct'), true);
      expect(isWellKnownJsonType('google.protobuf.ListValue'), true);
      expect(isWellKnownJsonType('google.protobuf.FieldMask'), true);
    });

    test('Any and ordinary types are not WKT-JSON', () {
      expect(isWellKnownJsonType('google.protobuf.Any'), false);
      expect(isWellKnownJsonType('foo.Bar'), false);
    });
  });

  group('WKT wrapper types via wktToJson/wktFromJson', () {
    test('Int32Value to JSON unwraps the value', () {
      final json = wktToJson('google.protobuf.Int32Value', {'value': 42}, null);
      expect(json, 42);
    });

    test('empty Int32Value yields the scalar zero', () {
      final json = wktToJson(
        'google.protobuf.Int32Value',
        <String, Object?>{},
        null,
      );
      expect(json, 0);
    });

    test('Int64Value renders as a string', () {
      final json = wktToJson('google.protobuf.Int64Value', {
        'value': 9007199254740993,
      }, null);
      expect(json, '9007199254740993');
    });

    test('BoolValue / StringValue / BytesValue zero values', () {
      expect(
        wktToJson('google.protobuf.BoolValue', <String, Object?>{}, null),
        false,
      );
      expect(
        wktToJson('google.protobuf.StringValue', <String, Object?>{}, null),
        '',
      );
      expect(
        wktToJson('google.protobuf.BytesValue', <String, Object?>{}, null),
        '',
      );
    });

    test('FloatValue/DoubleValue zero is 0.0', () {
      expect(
        wktToJson('google.protobuf.DoubleValue', <String, Object?>{}, null),
        0.0,
      );
    });

    test('wktFromJson wraps a scalar', () {
      final msg = wktFromJson('google.protobuf.Int32Value', 42, null);
      expect(msg, {'value': 42});
    });

    test('wktFromJson null wrapper yields an empty message', () {
      final msg = wktFromJson('google.protobuf.Int32Value', null, null);
      expect(msg, <String, Object?>{});
    });

    test('round-trip via marshalJson/unmarshalJson', () {
      final desc = _msgField('w', 1, 'google.protobuf.Int32Value');
      final json = marshalJson({
        'w': {'value': 5},
      }, desc);
      expect(json, contains('"w":5'));
      final back = unmarshalJson(json, desc);
      expect((back['w'] as Map)['value'], 5);
    });
  });

  group('Timestamp / Duration WKT JSON', () {
    test('Timestamp to/from JSON', () {
      final json = wktToJson('google.protobuf.Timestamp', {
        'seconds': 0,
        'nanos': 0,
      }, null);
      expect(json, '1970-01-01T00:00:00Z');
      final back = wktFromJson(
        'google.protobuf.Timestamp',
        '1970-01-01T00:00:00Z',
        null,
      );
      expect((back as Map)['seconds'], 0);
    });

    test('Timestamp seconds out of range throws', () {
      expect(
        () => wktToJson('google.protobuf.Timestamp', {
          'seconds': 253402300800,
          'nanos': 0,
        }, null),
        throwsA(isA<FormatException>()),
      );
    });

    test('Timestamp nanos out of range throws', () {
      expect(
        () => wktToJson('google.protobuf.Timestamp', {
          'seconds': 0,
          'nanos': 1000000000,
        }, null),
        throwsA(isA<FormatException>()),
      );
    });

    test('Timestamp from a non-string throws', () {
      expect(
        () => wktFromJson('google.protobuf.Timestamp', 123, null),
        throwsA(isA<FormatException>()),
      );
    });

    test('Duration to/from JSON', () {
      final json = wktToJson('google.protobuf.Duration', {
        'seconds': 1,
        'nanos': 500000000,
      }, null);
      expect(json, '1.5s');
      final back = wktFromJson('google.protobuf.Duration', '1.5s', null);
      expect((back as Map)['seconds'], 1);
      expect(back['nanos'], 500000000);
    });

    test('Duration seconds out of range throws', () {
      expect(
        () => wktToJson('google.protobuf.Duration', {
          'seconds': 315576000001,
          'nanos': 0,
        }, null),
        throwsA(isA<FormatException>()),
      );
    });

    test('Duration mismatched signs throws', () {
      expect(
        () => wktToJson('google.protobuf.Duration', {
          'seconds': 1,
          'nanos': -1,
        }, null),
        throwsA(isA<FormatException>()),
      );
    });

    test('Duration from a non-string throws', () {
      expect(
        () => wktFromJson('google.protobuf.Duration', 1, null),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('FieldMask WKT JSON', () {
    test('to JSON joins camelCase paths with commas', () {
      final json = wktToJson('google.protobuf.FieldMask', {
        'paths': ['foo_bar', 'baz.qux_quux'],
      }, null);
      expect(json, 'fooBar,baz.quxQuux');
    });

    test('empty paths to JSON is empty string', () {
      final json = wktToJson('google.protobuf.FieldMask', {
        'paths': <String>[],
      }, null);
      expect(json, '');
    });

    test('absent paths to JSON is empty string', () {
      final json = wktToJson(
        'google.protobuf.FieldMask',
        <String, Object?>{},
        null,
      );
      expect(json, '');
    });

    test('from JSON splits and snake_cases', () {
      final msg = wktFromJson(
        'google.protobuf.FieldMask',
        'fooBar,bazQux',
        null,
      );
      expect((msg as Map)['paths'], ['foo_bar', 'baz_qux']);
    });

    test('from empty JSON yields empty paths', () {
      final msg = wktFromJson('google.protobuf.FieldMask', '', null);
      expect((msg as Map)['paths'], <String>[]);
    });

    test('from a non-string throws', () {
      expect(
        () => wktFromJson('google.protobuf.FieldMask', 1, null),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Struct / Value / ListValue WKT JSON', () {
    test('Value variants to JSON', () {
      expect(wktToJson('google.protobuf.Value', {'null_value': 0}, null), null);
      expect(
        wktToJson('google.protobuf.Value', {'number_value': 3.5}, null),
        3.5,
      );
      expect(
        wktToJson('google.protobuf.Value', {'string_value': 'x'}, null),
        'x',
      );
      expect(
        wktToJson('google.protobuf.Value', {'bool_value': true}, null),
        true,
      );
      expect(
        wktToJson('google.protobuf.Value', <String, Object?>{}, null),
        null,
      );
    });

    test('nested struct_value / list_value to JSON', () {
      final structVal = {
        'struct_value': {
          'fields': {
            'a': {'number_value': 1},
          },
        },
      };
      expect(wktToJson('google.protobuf.Value', structVal, null), {'a': 1});

      final listVal = {
        'list_value': {
          'values': [
            {'string_value': 'x'},
            {'bool_value': false},
          ],
        },
      };
      expect(wktToJson('google.protobuf.Value', listVal, null), ['x', false]);
    });

    test('Value variants from JSON', () {
      expect(wktFromJson('google.protobuf.Value', null, null), {
        'null_value': 0,
      });
      expect(wktFromJson('google.protobuf.Value', true, null), {
        'bool_value': true,
      });
      expect(wktFromJson('google.protobuf.Value', 2, null), {
        'number_value': 2.0,
      });
      expect(wktFromJson('google.protobuf.Value', 'hi', null), {
        'string_value': 'hi',
      });
    });

    test('Value from a nested map/list', () {
      final fromMap = wktFromJson('google.protobuf.Value', {'a': 1}, null);
      expect((fromMap as Map).containsKey('struct_value'), true);
      final fromList = wktFromJson('google.protobuf.Value', [1, 2], null);
      expect((fromList as Map).containsKey('list_value'), true);
    });

    test('Struct round-trips through JSON', () {
      final msg = {
        'fields': {
          'name': {'string_value': 'bob'},
          'age': {'number_value': 30},
        },
      };
      final json = wktToJson('google.protobuf.Struct', msg, null);
      expect(json, {'name': 'bob', 'age': 30});
      final back = wktFromJson('google.protobuf.Struct', json, null);
      expect((back as Map)['fields'], isA<Map>());
    });

    test('Struct from a non-object throws', () {
      expect(
        () => wktFromJson('google.protobuf.Struct', 'x', null),
        throwsA(isA<FormatException>()),
      );
    });

    test('ListValue to/from JSON', () {
      final msg = {
        'values': [
          {'number_value': 1},
          {'string_value': 'a'},
        ],
      };
      expect(wktToJson('google.protobuf.ListValue', msg, null), [1, 'a']);
      final back = wktFromJson('google.protobuf.ListValue', [1, 'a'], null);
      expect((back as Map)['values'], isA<List>());
    });

    test('empty ListValue message to JSON is empty list', () {
      expect(
        wktToJson('google.protobuf.ListValue', <String, Object?>{}, null),
        <Object?>[],
      );
    });

    test('ListValue from a non-array throws', () {
      expect(
        () => wktFromJson('google.protobuf.ListValue', 'x', null),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('google.protobuf.Any JSON', () {
    final innerDesc = <Map<String, Object?>>[
      {
        'name': 'value',
        'number': 1,
        'type': 'TYPE_INT32',
        'label': 'LABEL_OPTIONAL',
      },
    ];
    AnyTypeResolver resolver = (name) => name == 'foo.Inner' ? innerDesc : null;

    final anyField = <Map<String, Object?>>[
      {
        'name': 'a',
        'number': 1,
        'type': 'TYPE_MESSAGE',
        'typeName': 'google.protobuf.Any',
      },
    ];

    test('ordinary message merges fields under @type', () {
      final json = marshalJson({
        'a': {
          'type_url': 'type.googleapis.com/foo.Inner',
          'value': [0x08, 0x07], // field 1 = 7
        },
      }, anyField);
      // No global resolver: pass per-call via messageToJson.
      final obj = messageToJson(
        {
          'a': {
            'type_url': 'type.googleapis.com/foo.Inner',
            'value': [0x08, 0x07],
          },
        },
        anyField,
        anyTypeResolver: resolver,
      );
      final a = (obj as Map)['a'] as Map;
      expect(a['@type'], 'type.googleapis.com/foo.Inner');
      expect(a['value'], 7);
      // marshalJson without a resolver leaves Any as a passthrough map.
      expect(json, isNotEmpty);
    });

    test('Any round-trips through messageFromJson with a resolver', () {
      final decoded = messageFromJson(
        {
          'a': {'@type': 'type.googleapis.com/foo.Inner', 'value': 7},
        },
        anyField,
        anyTypeResolver: resolver,
      );
      final a = decoded['a'] as Map;
      expect(a['type_url'], 'type.googleapis.com/foo.Inner');
      expect(a['value'], isA<List<int>>());
    });

    test('empty Any object from JSON is the empty Any', () {
      final decoded = messageFromJson(
        {'a': <String, Object?>{}},
        anyField,
        anyTypeResolver: resolver,
      );
      final a = decoded['a'] as Map;
      expect(a['type_url'], '');
      expect(a['value'], <int>[]);
    });

    test('Any from JSON missing @type throws', () {
      expect(
        () => messageFromJson(
          {
            'a': {'value': 7},
          },
          anyField,
          anyTypeResolver: resolver,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('Any from JSON with unknown type throws', () {
      expect(
        () => messageFromJson(
          {
            'a': {'@type': 'type.googleapis.com/foo.Unknown', 'value': 7},
          },
          anyField,
          anyTypeResolver: resolver,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('library-global anyTypeResolver is used as a fallback', () {
      setAnyTypeResolver(resolver);
      addTearDown(() => setAnyTypeResolver(null));
      final obj = messageToJson({
        'a': {
          'type_url': 'type.googleapis.com/foo.Inner',
          'value': [0x08, 0x07],
        },
      }, anyField);
      final a = (obj as Map)['a'] as Map;
      expect(a['value'], 7);
    });

    test('Any wrapping a well-known type embeds under value', () {
      AnyTypeResolver wktResolver = (name) => name == 'google.protobuf.Duration'
          ? <Map<String, Object?>>[
              {'name': 'seconds', 'number': 1, 'type': 'TYPE_INT64'},
              {'name': 'nanos', 'number': 2, 'type': 'TYPE_INT32'},
            ]
          : null;
      final obj = messageToJson(
        {
          'a': {
            'type_url': 'type.googleapis.com/google.protobuf.Duration',
            'value': [0x08, 0x05], // seconds = 5
          },
        },
        anyField,
        anyTypeResolver: wktResolver,
      );
      final a = (obj as Map)['a'] as Map;
      expect(a['@type'], contains('Duration'));
      expect(a['value'], '5s');
    });
  });

  group('64-bit integer JSON conversions', () {
    final desc = <Map<String, Object?>>[
      {
        'name': 'u',
        'number': 1,
        'type': 'TYPE_UINT64',
        'label': 'LABEL_OPTIONAL',
      },
    ];

    test('uint64 >= 2^63 renders as the unsigned decimal string', () {
      // -1 as a Dart int is 2^64-1 unsigned.
      final json = marshalJson({'u': -1}, desc);
      expect(json, contains('"18446744073709551615"'));
    });

    test('uint64 from string parses', () {
      final back = unmarshalJson('{"u":"18446744073709551615"}', desc);
      expect(back['u'], -1);
    });

    test('uint64 from a JSON number', () {
      final back = unmarshalJson('{"u":42}', desc);
      expect(back['u'], 42);
    });

    test('int64 from exponential string', () {
      final d = <Map<String, Object?>>[
        {'name': 'i', 'number': 1, 'type': 'TYPE_INT64'},
      ];
      final back = unmarshalJson('{"i":"1E3"}', d);
      expect(back['i'], 1000);
    });

    test('int64 out of range throws', () {
      final d = <Map<String, Object?>>[
        {'name': 'i', 'number': 1, 'type': 'TYPE_INT64'},
      ];
      expect(
        () => unmarshalJson('{"i":"99999999999999999999"}', d),
        throwsA(isA<FormatException>()),
      );
    });

    test('uint64 negative value throws', () {
      expect(
        () => unmarshalJson('{"u":"-1"}', desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('integer field rejects a bool', () {
      expect(
        () => unmarshalJson('{"u":true}', desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('integer field rejects a non-integral number', () {
      final d = <Map<String, Object?>>[
        {'name': 'i', 'number': 1, 'type': 'TYPE_INT64'},
      ];
      expect(
        () => unmarshalJson('{"i":1.5}', d),
        throwsA(isA<FormatException>()),
      );
    });

    test('integer JSON string with whitespace throws', () {
      final d = <Map<String, Object?>>[
        {'name': 'i', 'number': 1, 'type': 'TYPE_INT64'},
      ];
      expect(
        () => unmarshalJson('{"i":" 1 "}', d),
        throwsA(isA<FormatException>()),
      );
    });

    test('invalid integer string throws', () {
      final d = <Map<String, Object?>>[
        {'name': 'i', 'number': 1, 'type': 'TYPE_INT64'},
      ];
      expect(
        () => unmarshalJson('{"i":"abc"}', d),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('32-bit integer range checks', () {
    test('int32 out of range throws', () {
      final d = <Map<String, Object?>>[
        {'name': 'i', 'number': 1, 'type': 'TYPE_INT32'},
      ];
      expect(
        () => unmarshalJson('{"i":3000000000}', d),
        throwsA(isA<FormatException>()),
      );
    });

    test('uint32 negative throws', () {
      final d = <Map<String, Object?>>[
        {'name': 'u', 'number': 1, 'type': 'TYPE_UINT32'},
      ];
      expect(
        () => unmarshalJson('{"u":-1}', d),
        throwsA(isA<FormatException>()),
      );
    });

    test('uint32 in range parses', () {
      final d = <Map<String, Object?>>[
        {'name': 'u', 'number': 1, 'type': 'TYPE_FIXED32'},
      ];
      expect(unmarshalJson('{"u":4294967295}', d)['u'], 4294967295);
    });
  });

  group('float / double JSON parsing', () {
    final fd = <Map<String, Object?>>[
      {'name': 'f', 'number': 1, 'type': 'TYPE_FLOAT'},
    ];

    test('numeric string parses', () {
      expect(unmarshalJson('{"f":"1.5"}', fd)['f'], 1.5);
    });

    test('finite overflow string throws', () {
      expect(
        () => unmarshalJson('{"f":"1e400"}', fd),
        throwsA(isA<FormatException>()),
      );
    });

    test('finite overflow number throws', () {
      final dd = <Map<String, Object?>>[
        {'name': 'd', 'number': 1, 'type': 'TYPE_DOUBLE'},
      ];
      // JSON numbers can't be Infinity, but a non-finite double passed via the
      // object API can. Use messageFromJson to feed a raw double.infinity.
      expect(
        () => messageFromJson({'d': double.infinity}, dd),
        throwsA(isA<FormatException>()),
      );
    });

    test('float magnitude out of range throws', () {
      expect(
        () => unmarshalJson('{"f":1e39}', fd),
        throwsA(isA<FormatException>()),
      );
    });

    test('non-number for float throws', () {
      expect(
        () => messageFromJson({'f': true}, fd),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('enum JSON parsing', () {
    final desc = <Map<String, Object?>>[
      {
        'name': 'status',
        'number': 1,
        'type': 'TYPE_ENUM',
        'enumValues': {0: 'UNKNOWN', 1: 'ACTIVE'},
      },
    ];

    test('name -> ordinal via enumValues', () {
      expect(unmarshalJson('{"status":"ACTIVE"}', desc)['status'], 1);
    });

    test('alias name via enumNames', () {
      final d = <Map<String, Object?>>[
        {
          'name': 'status',
          'number': 1,
          'type': 'TYPE_ENUM',
          'enumValues': {1: 'ACTIVE'},
          'enumNames': {'ACTIVE': 1, 'ON': 1},
        },
      ];
      expect(unmarshalJson('{"status":"ON"}', d)['status'], 1);
    });

    test('numeric literal string parses', () {
      expect(unmarshalJson('{"status":"1"}', desc)['status'], 1);
    });

    test('numeric value parses', () {
      expect(unmarshalJson('{"status":1}', desc)['status'], 1);
    });

    test('unknown name under json_format=ALLOW throws', () {
      final d = <Map<String, Object?>>[
        {
          'name': 'status',
          'number': 1,
          'type': 'TYPE_ENUM',
          'enumValues': {0: 'UNKNOWN'},
          'features': {'json_format': 'ALLOW'},
        },
      ];
      expect(
        () => unmarshalJson('{"status":"BOGUS"}', d),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown name without features passes through (legacy)', () {
      expect(unmarshalJson('{"status":"BOGUS"}', desc)['status'], 'BOGUS');
    });
  });

  group('message-field error paths', () {
    test('non-object for a message field throws', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'm',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
          ],
        },
      ];
      expect(
        () => unmarshalJson('{"m":5}', desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('repeated field with a non-array throws', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'r',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
        },
      ];
      expect(
        () => unmarshalJson('{"r":5}', desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('repeated field with null is treated as unset', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'r',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
        },
      ];
      final back = unmarshalJson('{"r":null}', desc);
      expect(back.containsKey('r'), false);
    });
  });

  group('string type checks', () {
    test('non-string for a string field throws', () {
      final desc = <Map<String, Object?>>[
        {'name': 's', 'number': 1, 'type': 'TYPE_STRING'},
      ];
      expect(
        () => unmarshalJson('{"s":5}', desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('UTF-8 validation rejects an unpaired surrogate', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 's',
          'number': 1,
          'type': 'TYPE_STRING',
          'features': {'utf8_validation': 'VERIFY'},
        },
      ];
      // Lone high surrogate \uD800.
      expect(
        () => messageFromJson({'s': '\uD800'}, desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('UTF-8 validation accepts a valid surrogate pair', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 's',
          'number': 1,
          'type': 'TYPE_STRING',
          'features': {'utf8_validation': 'VERIFY'},
        },
      ];
      final back = messageFromJson({'s': '\u{1F600}'}, desc); // emoji
      expect(back['s'], '\u{1F600}');
    });
  });

  group('bool JSON parsing', () {
    final desc = <Map<String, Object?>>[
      {'name': 'b', 'number': 1, 'type': 'TYPE_BOOL'},
    ];

    test('bool from string "true"', () {
      expect(unmarshalJson('{"b":"true"}', desc)['b'], true);
      expect(unmarshalJson('{"b":"false"}', desc)['b'], false);
    });

    test('native bool', () {
      expect(unmarshalJson('{"b":true}', desc)['b'], true);
    });
  });

  group('oneof JSON', () {
    final desc = <Map<String, Object?>>[
      {'name': 'a', 'number': 1, 'type': 'TYPE_INT32', 'oneof': 'choice'},
      {'name': 'b', 'number': 2, 'type': 'TYPE_STRING', 'oneof': 'choice'},
    ];

    test('single oneof member parses', () {
      final back = unmarshalJson('{"a":5}', desc);
      expect(back['a'], 5);
    });

    test('a null oneof member does not claim the oneof', () {
      final back = unmarshalJson('{"a":null,"b":"x"}', desc);
      expect(back['b'], 'x');
    });

    test('two set members of one oneof throws', () {
      expect(
        () => unmarshalJson('{"a":5,"b":"x"}', desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('a set oneof member emits even at the default value', () {
      final json = marshalJson({'a': 0}, desc);
      expect(json, contains('"a":0'));
    });
  });

  group('jsonName override', () {
    test('output key uses jsonName', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'my_field',
          'number': 1,
          'type': 'TYPE_INT32',
          'jsonName': 'customName',
        },
      ];
      final json = marshalJson({'my_field': 5}, desc);
      expect(json, contains('"customName":5'));
    });

    test('input accepts jsonName, camelCase, and snake_case', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'my_field',
          'number': 1,
          'type': 'TYPE_INT32',
          'jsonName': 'customName',
        },
      ];
      expect(unmarshalJson('{"customName":1}', desc)['my_field'], 1);
      expect(unmarshalJson('{"myField":2}', desc)['my_field'], 2);
      expect(unmarshalJson('{"my_field":3}', desc)['my_field'], 3);
    });
  });

  group('top-level type checks', () {
    test('unmarshalJson rejects a non-object top level', () {
      expect(
        () => unmarshalJson('[1,2,3]', const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('messageFromJson rejects a non-map', () {
      expect(
        () => messageFromJson([1, 2], const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('messageToJson equals jsonDecode(marshalJson)', () {
      final desc = <Map<String, Object?>>[
        {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
      ];
      final obj = messageToJson({'x': 5}, desc);
      expect(obj, jsonDecode(marshalJson({'x': 5}, desc)));
    });
  });

  group('explicit-presence singular fields', () {
    test('a default value is emitted under EXPLICIT presence', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'x',
          'number': 1,
          'type': 'TYPE_INT32',
          'features': {'field_presence': 'EXPLICIT'},
        },
      ];
      final json = marshalJson({'x': 0}, desc);
      expect(json, contains('"x":0'));
    });

    test('a null value is omitted under EXPLICIT presence', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'x',
          'number': 1,
          'type': 'TYPE_INT32',
          'features': {'field_presence': 'EXPLICIT'},
        },
      ];
      expect(marshalJson({'x': null}, desc), '{}');
    });
  });
}
