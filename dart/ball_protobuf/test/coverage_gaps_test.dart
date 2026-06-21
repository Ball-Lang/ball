import 'dart:convert';

import 'package:ball_protobuf/json_codec.dart';
import 'package:ball_protobuf/marshal.dart';
import 'package:ball_protobuf/unmarshal.dart';
import 'package:test/test.dart';

/// Targeted tests for code paths the broader suites leave uncovered. Each test
/// names the file + behavior it exercises.
void main() {
  group('marshal — singular scalar default elision (all int types)', () {
    List<Map<String, Object?>> desc(String type) => [
      {'name': 'v', 'number': 1, 'type': type, 'label': 'LABEL_OPTIONAL'},
    ];

    test('int64 / sint32 non-default singular emit', () {
      expect(marshal({'v': 5}, desc('TYPE_INT64')), isNotEmpty);
      expect(marshal({'v': 5}, desc('TYPE_SINT32')), isNotEmpty);
    });

    test('int64 / sint32 default singular skipped', () {
      expect(marshal({'v': 0}, desc('TYPE_INT64')), isEmpty);
      expect(marshal({'v': 0}, desc('TYPE_SINT32')), isEmpty);
    });

    test('empty bytes singular is skipped', () {
      expect(marshal({'v': <int>[]}, desc('TYPE_BYTES')), isEmpty);
    });

    test('non-empty bytes singular emits', () {
      expect(
        marshal({
          'v': [1, 2],
        }, desc('TYPE_BYTES')),
        isNotEmpty,
      );
    });

    test('_toInt accepts a num (double) for an int field', () {
      // 5.0 is a double; the int field marshals via _toInt's num branch.
      final bytes = marshal({'v': 5.0}, desc('TYPE_INT32'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'int32'},
      ]);
      expect(back['v'], 5);
    });

    test('_toDouble accepts a num (int) for a float field', () {
      // 2 is an int; the float field marshals via _toDouble's num branch.
      final bytes = marshal({'v': 2}, desc('TYPE_FLOAT'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'float'},
      ]);
      expect(back['v'], 2.0);
    });

    test('_toInt throws on a non-numeric int field', () {
      expect(
        () => marshalField([], 1, 'TYPE_INT32', 'oops', repeated: true),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('_toDouble throws on a non-numeric float field', () {
      expect(
        () => marshalField([], 1, 'TYPE_FLOAT', 'oops', repeated: true),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('marshalRepeated — string/bytes skip null elements', () {
    test('repeated strings via marshalRepeated skip nulls', () {
      final out = marshalRepeated([], 1, 'TYPE_STRING', ['a', null, 'b']);
      // Two LEN string records survive.
      expect(out.where((b) => b == 0x0A).length, 2);
    });

    test('repeated bytes via marshalRepeated skip nulls', () {
      final out = marshalRepeated([], 1, 'TYPE_BYTES', [
        [1],
        null,
        [2],
      ]);
      expect(out.where((b) => b == 0x0A).length, 2);
    });
  });

  group('unmarshal — singular message merge (nested + repeated subfield)', () {
    test('_mergeMessages recurses and concatenates lists', () {
      // Inner message has a nested message subfield (n) and a repeated int (r).
      final deepMarshal = <Map<String, Object?>>[
        {
          'name': 'x',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final innerMarshal = <Map<String, Object?>>[
        {
          'name': 'n',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_OPTIONAL',
          'messageDescriptor': deepMarshal,
        },
        {
          'name': 'r',
          'number': 2,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
        },
      ];
      // First occurrence: n={x:1}, r=[1]
      final first = marshal({
        'n': {'x': 1},
        'r': [1],
      }, innerMarshal);
      // Second occurrence: r=[2] (merges into the first's r)
      final second = marshal({
        'r': [2],
      }, innerMarshal);
      final outer = <int>[];
      outer.addAll([0x0A, first.length, ...first]);
      outer.addAll([0x0A, second.length, ...second]);

      final innerUnmarshal = <Map<String, Object?>>[
        {
          'name': 'n',
          'number': 1,
          'type': 'message',
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'x', 'number': 1, 'type': 'int32'},
          ],
        },
        {'name': 'r', 'number': 2, 'type': 'int32', 'repeated': true},
      ];
      final back = unmarshal(outer, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'messageDescriptor': innerUnmarshal,
        },
      ]);
      final m = back['m'] as Map;
      expect((m['n'] as Map)['x'], 1);
      expect(m['r'], [1, 2]); // list concat
    });
  });

  group('unmarshal — _mergeMessages nested sub-message recursion', () {
    test('two occurrences both carrying a sub-message merge recursively', () {
      final deepMarshal = <Map<String, Object?>>[
        {
          'name': 'p',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'q',
          'number': 2,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final innerMarshal = <Map<String, Object?>>[
        {
          'name': 'n',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_OPTIONAL',
          'messageDescriptor': deepMarshal,
        },
      ];
      // Both occurrences set n, with disjoint sub-fields, so the nested merge
      // (existing Map + incoming Map -> _mergeMessages recursion) fires.
      final first = marshal({
        'n': {'p': 1},
      }, innerMarshal);
      final second = marshal({
        'n': {'q': 2},
      }, innerMarshal);
      final outer = <int>[];
      outer.addAll([0x0A, first.length, ...first]);
      outer.addAll([0x0A, second.length, ...second]);

      final back = unmarshal(outer, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'messageDescriptor': <Map<String, Object?>>[
            {
              'name': 'n',
              'number': 1,
              'type': 'message',
              'messageDescriptor': <Map<String, Object?>>[
                {'name': 'p', 'number': 1, 'type': 'int32'},
                {'name': 'q', 'number': 2, 'type': 'int32'},
              ],
            },
          ],
        },
      ]);
      final n = (back['m'] as Map)['n'] as Map;
      expect(n['p'], 1);
      expect(n['q'], 2);
    });
  });

  group('unmarshal — repeated message element that is not raw bytes', () {
    test('a varint-wire-type element on a repeated message field is kept', () {
      // A malformed/legacy producer sends a VARINT (wire type 0) for a repeated
      // message field. unmarshalRepeated decodes it as a raw int, and the
      // message-element loop keeps the non-bytes value verbatim (the else
      // branch) rather than recursing into unmarshal.
      final bytes = <int>[0x08, 0x05]; // field 1, VARINT, value 5
      final back = unmarshal(bytes, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'repeated': true,
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'x', 'number': 1, 'type': 'int32'},
          ],
        },
      ]);
      expect(back['m'], [5]);
    });
  });

  group('unmarshal — repeated LEN message decoded via sub-descriptor', () {
    test('each LEN element is recursively unmarshaled', () {
      final innerMarshal = <Map<String, Object?>>[
        {
          'name': 'x',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final desc = <Map<String, Object?>>[
        {
          'name': 'm',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'messageDescriptor': innerMarshal,
        },
      ];
      // Pass Maps so marshal length-prefixes each element via the descriptor.
      final bytes = marshal({
        'm': [
          {'x': 1},
          {'x': 2},
        ],
      }, desc);
      final back = unmarshal(bytes, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'repeated': true,
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'x', 'number': 1, 'type': 'int32'},
          ],
        },
      ]);
      final list = back['m'] as List;
      expect(list.map((e) => (e as Map)['x']), [1, 2]);
    });
  });

  group('unmarshal — delimited singular message merge', () {
    test('two delimited occurrences of a singular field merge', () {
      final innerMarshal = <Map<String, Object?>>[
        {
          'name': 'a',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'b',
          'number': 2,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final desc = <Map<String, Object?>>[
        {
          'name': 'g',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_OPTIONAL',
          'messageDescriptor': innerMarshal,
          'features': {'message_encoding': 'DELIMITED'},
        },
      ];
      final firstBytes = marshal({
        'g': {'a': 1},
      }, desc);
      final secondBytes = marshal({
        'g': {'b': 2},
      }, desc);
      final combined = [...firstBytes, ...secondBytes];
      final back = unmarshal(combined, [
        {
          'name': 'g',
          'number': 1,
          'type': 'message',
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'a', 'number': 1, 'type': 'int32'},
            {'name': 'b', 'number': 2, 'type': 'int32'},
          ],
          'features': {'message_encoding': 'DELIMITED'},
        },
      ]);
      final g = back['g'] as Map;
      expect(g['a'], 1);
      expect(g['b'], 2);
    });
  });

  group('unmarshalRepeated — TYPE_ prefix normalization', () {
    test('packed values with a TYPE_ prefixed element type', () {
      final data = <int>[];
      // Two varints 1, 2.
      data.addAll([1, 2]);
      final buf = <int>[data.length, ...data];
      final result = unmarshalRepeated(buf, 0, 2, 'TYPE_INT32');
      expect(result['values'], [1, 2]);
    });
  });

  group('json_codec — nested message field via JSON', () {
    test('object value parses through fieldFromJson messageDescriptor', () {
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
      final back = unmarshalJson('{"m":{"x":5}}', desc);
      expect((back['m'] as Map)['x'], 5);
    });

    test('nested message round-trips through marshalJson', () {
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
      final json = marshalJson({
        'm': {'x': 7},
      }, desc);
      expect(json, contains('"x":7'));
    });
  });

  group('json_codec — map field JSON round-trip', () {
    test('scalar map field to/from JSON', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'labels',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'mapEntry': true,
          'keyType': 'TYPE_STRING',
          'valueType': 'TYPE_STRING',
        },
      ];
      final json = marshalJson({
        'labels': {'env': 'prod'},
      }, desc);
      expect(json, contains('"labels"'));
      expect(json, contains('"env":"prod"'));
      final back = unmarshalJson(json, desc);
      expect((back['labels'] as Map)['env'], 'prod');
    });

    test('empty map field is omitted from JSON', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'labels',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'mapEntry': true,
          'keyType': 'TYPE_STRING',
          'valueType': 'TYPE_STRING',
        },
      ];
      expect(marshalJson({'labels': <String, Object?>{}}, desc), '{}');
    });

    test('map field with a non-object JSON value passes through', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'labels',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'mapEntry': true,
          'keyType': 'TYPE_STRING',
          'valueType': 'TYPE_STRING',
        },
      ];
      final back = unmarshalJson('{"labels":null}', desc);
      expect(back['labels'], isNull);
    });

    test('int-valued map field to/from JSON', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'counts',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'mapEntry': true,
          'keyType': 'TYPE_STRING',
          'valueType': 'TYPE_INT32',
        },
      ];
      final json = marshalJson({
        'counts': {'a': 1, 'b': 2},
      }, desc);
      final back = unmarshalJson(json, desc);
      expect((back['counts'] as Map)['a'], 1);
      expect((back['counts'] as Map)['b'], 2);
    });
  });

  group('json_codec — uint64 positive value >= 2^63', () {
    test('renders as a plain decimal string', () {
      // A BigInt value of 2^63 stored as a Dart int is negative; but a small
      // positive int uses the non-negative branch (value.toString()).
      final desc = <Map<String, Object?>>[
        {'name': 'u', 'number': 1, 'type': 'TYPE_UINT64'},
      ];
      final json = marshalJson({'u': 100}, desc);
      expect(json, contains('"100"'));
    });
  });

  group('json_codec — ensureDefaults map + bytes/message defaults', () {
    test('fills a map field with an empty map', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'm',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'mapEntry': true,
          'keyType': 'TYPE_STRING',
          'valueType': 'TYPE_STRING',
        },
      ];
      final out = ensureDefaults(<String, Object?>{}, desc);
      expect(out['m'], <String, Object?>{});
    });

    test('fills bytes/message defaults', () {
      final desc = <Map<String, Object?>>[
        {'name': 'b', 'number': 1, 'type': 'TYPE_BYTES'},
        {'name': 'm', 'number': 2, 'type': 'TYPE_MESSAGE'},
        {
          'name': 'r',
          'number': 3,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
        },
      ];
      final out = ensureDefaults(<String, Object?>{}, desc);
      expect(out['b'], <int>[]);
      expect(out['m'], isNull);
      expect(out['r'], <Object?>[]);
    });
  });

  group('json_codec — Value/duration/bigint error edges', () {
    test('_valueMsgFromJson rejects an unsupported type', () {
      // A google.protobuf.Value field fed a non-JSON-native value via the
      // object API surfaces the conversion error.
      final desc = <Map<String, Object?>>[
        {
          'name': 'v',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'typeName': 'google.protobuf.Value',
        },
      ];
      expect(
        () => messageFromJson({'v': DateTime(2020)}, desc),
        throwsA(isA<FormatException>()),
      );
    });

    test('Duration nanos out of range', () {
      expect(
        () => wktToJson('google.protobuf.Duration', {
          'seconds': 0,
          'nanos': 1000000000,
        }, null),
        throwsA(isA<FormatException>()),
      );
    });

    test('UTF-8 lone low surrogate is rejected', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 's',
          'number': 1,
          'type': 'TYPE_STRING',
          'features': {'utf8_validation': 'VERIFY'},
        },
      ];
      // \uDC00 is a lone low surrogate.
      expect(
        () => messageFromJson({'s': '\uDC00'}, desc),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('json_codec — Any error + nesting paths', () {
    final innerDesc = <Map<String, Object?>>[
      {'name': 'value', 'number': 1, 'type': 'TYPE_INT32'},
    ];
    final anyField = <Map<String, Object?>>[
      {
        'name': 'a',
        'number': 1,
        'type': 'TYPE_MESSAGE',
        'typeName': 'google.protobuf.Any',
      },
    ];

    test('_anyToJson throws on an unknown embedded type', () {
      AnyTypeResolver resolver = (_) => null; // resolves nothing
      expect(
        () => messageToJson(
          {
            'a': {
              'type_url': 'type.googleapis.com/foo.Unknown',
              'value': <int>[],
            },
          },
          anyField,
          anyTypeResolver: resolver,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('Any with an empty type_url renders as an empty object', () {
      AnyTypeResolver resolver = (name) =>
          name == 'foo.Inner' ? innerDesc : null;
      final obj = messageToJson(
        {
          'a': {'type_url': '', 'value': <int>[]},
        },
        anyField,
        anyTypeResolver: resolver,
      );
      // An Any with no type_url collapses to {} (a present, non-default message).
      expect((obj as Map)['a'], <String, Object?>{});
    });

    test('Any nested in Any round-trips (to + from JSON)', () {
      AnyTypeResolver resolver = (name) {
        if (name == 'foo.Inner') return innerDesc;
        if (name == 'google.protobuf.Any') {
          return <Map<String, Object?>>[
            {'name': 'type_url', 'number': 1, 'type': 'TYPE_STRING'},
            {'name': 'value', 'number': 2, 'type': 'TYPE_BYTES'},
          ];
        }
        return null;
      };
      // Build an inner Any { @type: foo.Inner, value: 7 } then wrap it.
      final innerAny = messageFromJson(
        {
          'a': {'@type': 'type.googleapis.com/foo.Inner', 'value': 7},
        },
        anyField,
        anyTypeResolver: resolver,
      );
      final innerAnyMsg = innerAny['a'] as Map<String, Object?>;

      // Now decode an Any-in-Any from JSON.
      final outerJson = {
        'a': {
          '@type': 'type.googleapis.com/google.protobuf.Any',
          'value': {'@type': 'type.googleapis.com/foo.Inner', 'value': 7},
        },
      };
      final decoded = messageFromJson(
        outerJson,
        anyField,
        anyTypeResolver: resolver,
      );
      expect((decoded['a'] as Map)['type_url'], contains('Any'));

      // And encode an Any-in-Any back to JSON.
      final encoded = messageToJson(
        {
          'a': {
            'type_url': 'type.googleapis.com/google.protobuf.Any',
            'value': marshal(innerAnyMsg, resolver('google.protobuf.Any')!),
          },
        },
        anyField,
        anyTypeResolver: resolver,
      );
      final a = (encoded as Map)['a'] as Map;
      expect(a['@type'], contains('Any'));
      expect(a['value'], isA<Map>());
    });

    test('WKT nested in Any round-trips from JSON', () {
      AnyTypeResolver resolver = (name) => name == 'google.protobuf.Duration'
          ? <Map<String, Object?>>[
              {'name': 'seconds', 'number': 1, 'type': 'TYPE_INT64'},
              {'name': 'nanos', 'number': 2, 'type': 'TYPE_INT32'},
            ]
          : null;
      final decoded = messageFromJson(
        {
          'a': {
            '@type': 'type.googleapis.com/google.protobuf.Duration',
            'value': '5s',
          },
        },
        anyField,
        anyTypeResolver: resolver,
      );
      final a = decoded['a'] as Map;
      expect(a['type_url'], contains('Duration'));
      expect(a['value'], isA<List<int>>());
    });
  });

  group('json_codec — _jsonBigInt unexpected type', () {
    test('a list for an integer field throws', () {
      // Feed a List to an int64 field via the object API → _jsonBigInt default.
      final desc = <Map<String, Object?>>[
        {'name': 'i', 'number': 1, 'type': 'TYPE_INT64'},
      ];
      expect(
        () => messageFromJson({
          'i': [1, 2],
        }, desc),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group(
    'json_codec — messageToJson equals jsonEncode(marshalJson) for maps',
    () {
      test('map field stays JSON-stable', () {
        final desc = <Map<String, Object?>>[
          {
            'name': 'm',
            'number': 1,
            'type': 'TYPE_MESSAGE',
            'label': 'LABEL_REPEATED',
            'mapEntry': true,
            'keyType': 'TYPE_STRING',
            'valueType': 'TYPE_INT32',
          },
        ];
        final msg = {
          'm': {'a': 1},
        };
        expect(jsonEncode(messageToJson(msg, desc)), marshalJson(msg, desc));
      });
    },
  );
}
