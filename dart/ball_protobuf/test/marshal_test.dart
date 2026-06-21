import 'package:ball_protobuf/marshal.dart';
import 'package:ball_protobuf/unmarshal.dart';
import 'package:test/test.dart';

void main() {
  group('wireTypeForFieldType — all branches', () {
    test('varint types', () {
      for (final t in [
        'TYPE_INT32',
        'TYPE_INT64',
        'TYPE_UINT32',
        'TYPE_UINT64',
        'TYPE_SINT32',
        'TYPE_SINT64',
        'TYPE_BOOL',
        'TYPE_ENUM',
      ]) {
        expect(wireTypeForFieldType(t), 0, reason: t);
      }
    });

    test('I64 types', () {
      for (final t in ['TYPE_FIXED64', 'TYPE_SFIXED64', 'TYPE_DOUBLE']) {
        expect(wireTypeForFieldType(t), 1, reason: t);
      }
    });

    test('LEN types', () {
      for (final t in ['TYPE_STRING', 'TYPE_BYTES', 'TYPE_MESSAGE']) {
        expect(wireTypeForFieldType(t), 2, reason: t);
      }
    });

    test('I32 types', () {
      for (final t in ['TYPE_FIXED32', 'TYPE_SFIXED32', 'TYPE_FLOAT']) {
        expect(wireTypeForFieldType(t), 5, reason: t);
      }
    });

    test('unknown type throws', () {
      expect(
        () => wireTypeForFieldType('TYPE_X'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('encodeGroupField', () {
    test('wraps body in START_GROUP / END_GROUP', () {
      final out = encodeGroupField([], 1, [0x08, 0x05]);
      // field 1, START_GROUP (wire 3) = (1<<3)|3 = 11; END_GROUP = 12.
      expect(out.first, 11);
      expect(out.last, 12);
      expect(out.sublist(1, out.length - 1), [0x08, 0x05]);
    });
  });

  group('sfixed / fixed singular round-trips', () {
    List<Map<String, Object?>> desc(String type) => [
      {'name': 'v', 'number': 1, 'type': type, 'label': 'LABEL_OPTIONAL'},
    ];

    test('sfixed32 negative round-trips', () {
      final bytes = marshal({'v': -5}, desc('TYPE_SFIXED32'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'sfixed32'},
      ]);
      expect(back['v'], -5);
    });

    test('sfixed64 negative round-trips', () {
      final bytes = marshal({'v': -5}, desc('TYPE_SFIXED64'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'sfixed64'},
      ]);
      expect(back['v'], -5);
    });

    test('fixed32 round-trips', () {
      final bytes = marshal({'v': 0x1234}, desc('TYPE_FIXED32'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'fixed32'},
      ]);
      expect(back['v'], 0x1234);
    });

    test('fixed64 round-trips', () {
      final bytes = marshal({'v': 0x1234}, desc('TYPE_FIXED64'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'fixed64'},
      ]);
      expect(back['v'], 0x1234);
    });

    test('uint32 / uint64 / sint64 / enum singular round-trips', () {
      for (final t in [
        'TYPE_UINT32',
        'TYPE_UINT64',
        'TYPE_SINT64',
        'TYPE_ENUM',
      ]) {
        final bare = t.substring(5).toLowerCase();
        final bytes = marshal({'v': 7}, desc(t));
        final back = unmarshal(bytes, [
          {'name': 'v', 'number': 1, 'type': bare},
        ]);
        expect(back['v'], 7, reason: t);
      }
    });

    test('double singular round-trips', () {
      final bytes = marshal({'v': 2.5}, desc('TYPE_DOUBLE'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'double'},
      ]);
      expect(back['v'], 2.5);
    });

    test('float singular round-trips', () {
      final bytes = marshal({'v': 1.5}, desc('TYPE_FLOAT'));
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'float'},
      ]);
      expect(back['v'], 1.5);
    });
  });

  group('packed repeated scalar round-trips', () {
    List<Map<String, Object?>> desc(String type) => [
      {'name': 'v', 'number': 1, 'type': type, 'label': 'LABEL_REPEATED'},
    ];
    List<Map<String, Object?>> undesc(String type) => [
      {
        'name': 'v',
        'number': 1,
        'type': type.substring(5).toLowerCase(),
        'repeated': true,
      },
    ];

    void check(String type, List<Object?> values) {
      final bytes = marshal({'v': values}, desc(type));
      final back = unmarshal(bytes, undesc(type));
      expect(back['v'], values, reason: type);
    }

    test('sint32 packed', () => check('TYPE_SINT32', [-1, -2, 3]));
    test('sint64 packed', () => check('TYPE_SINT64', [-1, 2, -3]));
    test('bool packed', () => check('TYPE_BOOL', [true, false, true]));
    test('enum packed', () => check('TYPE_ENUM', [1, 2, 3]));
    test('fixed32 packed', () => check('TYPE_FIXED32', [10, 20, 30]));
    test('sfixed32 packed', () => check('TYPE_SFIXED32', [-10, 20, -30]));
    test('fixed64 packed', () => check('TYPE_FIXED64', [100, 200]));
    test('sfixed64 packed', () => check('TYPE_SFIXED64', [100, 200]));
    test('float packed', () => check('TYPE_FLOAT', [1.5, 2.5]));
    test('double packed', () => check('TYPE_DOUBLE', [1.5, 2.5]));
    test('uint32 packed', () => check('TYPE_UINT32', [1, 2, 3]));
    test('uint64 packed', () => check('TYPE_UINT64', [1, 2, 3]));
    test('int64 packed', () => check('TYPE_INT64', [1, 2, 3]));

    test('empty repeated field is skipped', () {
      expect(marshal({'v': <Object?>[]}, desc('TYPE_INT32')), isEmpty);
    });
  });

  group('repeated strings / bytes are not packed', () {
    test('repeated strings emit every element including empty', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 's',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_REPEATED',
        },
      ];
      final bytes = marshal({
        's': ['a', '', 'c'],
      }, desc);
      final back = unmarshal(bytes, [
        {'name': 's', 'number': 1, 'type': 'string', 'repeated': true},
      ]);
      expect(back['s'], ['a', '', 'c']);
    });

    test('repeated bytes round-trip', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'b',
          'number': 1,
          'type': 'TYPE_BYTES',
          'label': 'LABEL_REPEATED',
        },
      ];
      final bytes = marshal({
        'b': [
          [1, 2],
          <int>[],
          [3],
        ],
      }, desc);
      final back = unmarshal(bytes, [
        {'name': 'b', 'number': 1, 'type': 'bytes', 'repeated': true},
      ]);
      expect(back['b'], [
        [1, 2],
        <int>[],
        [3],
      ]);
    });
  });

  group('EXPANDED repeated encoding (proto2 / override)', () {
    test('scalar repeated under EXPANDED round-trips unpacked', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'v',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
          'features': {'repeated_field_encoding': 'EXPANDED'},
        },
      ];
      final bytes = marshal({
        'v': [1, 0, 2],
      }, desc);
      // Unpacked: each element carries its own VARINT tag (0x08).
      expect(bytes.where((b) => b == 0x08).length, 3);
      final back = unmarshal(bytes, [
        {'name': 'v', 'number': 1, 'type': 'int32', 'repeated': true},
      ]);
      expect(back['v'], [1, 0, 2]);
    });
  });

  group('DELIMITED (group) message fields', () {
    final innerMarshal = <Map<String, Object?>>[
      {
        'name': 'value',
        'number': 1,
        'type': 'TYPE_INT32',
        'label': 'LABEL_OPTIONAL',
      },
    ];
    final innerUnmarshal = <Map<String, Object?>>[
      {'name': 'value', 'number': 1, 'type': 'int32'},
    ];

    test('singular delimited message round-trips', () {
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
      final bytes = marshal({
        'g': {'value': 42},
      }, desc);
      // START_GROUP tag for field 1 = (1<<3)|3 = 11.
      expect(bytes.first, 11);
      final back = unmarshal(bytes, [
        {
          'name': 'g',
          'number': 1,
          'type': 'message',
          'messageDescriptor': innerUnmarshal,
          'features': {'message_encoding': 'DELIMITED'},
        },
      ]);
      expect((back['g'] as Map)['value'], 42);
    });

    test('repeated delimited messages round-trip', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'g',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'messageDescriptor': innerMarshal,
          'features': {'message_encoding': 'DELIMITED'},
        },
      ];
      final bytes = marshal({
        'g': [
          {'value': 1},
          {'value': 2},
        ],
      }, desc);
      final back = unmarshal(bytes, [
        {
          'name': 'g',
          'number': 1,
          'type': 'message',
          'repeated': true,
          'messageDescriptor': innerUnmarshal,
          'features': {'message_encoding': 'DELIMITED'},
        },
      ]);
      final list = back['g'] as List;
      expect(list.map((e) => (e as Map)['value']), [1, 2]);
    });
  });

  group('repeated messages (length-prefixed) with pre-encoded bytes', () {
    test('each element emitted even when empty', () {
      final inner = marshal(
        {'value': 0},
        [
          {
            'name': 'value',
            'number': 1,
            'type': 'TYPE_INT32',
            'label': 'LABEL_OPTIONAL',
          },
        ],
      ); // empty (default elided)
      expect(inner, isEmpty);
      final desc = <Map<String, Object?>>[
        {
          'name': 'm',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
        },
      ];
      // Pass pre-encoded bytes (List<int>) per element.
      final bytes = marshal({
        'm': [inner, inner],
      }, desc);
      // Two LEN records (tag 0x0A, length 0).
      expect(bytes, [0x0A, 0x00, 0x0A, 0x00]);
    });
  });

  group('marshalField error paths', () {
    test('TYPE_MESSAGE Map without descriptor throws', () {
      expect(
        () => marshalField([], 1, 'TYPE_MESSAGE', <String, Object?>{'x': 1}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TYPE_MESSAGE with a non-bytes non-map throws', () {
      expect(
        () => marshalField([], 1, 'TYPE_MESSAGE', 42),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('unknown type in marshalField throws', () {
      expect(
        () => marshalField([], 1, 'TYPE_NOPE', 1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('null value is a no-op', () {
      expect(marshalField([9], 1, 'TYPE_INT32', null), [9]);
    });
  });

  group('marshalRepeated', () {
    test('unknown type throws', () {
      expect(
        () => marshalRepeated([], 1, 'TYPE_NOPE', [1]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty list is a no-op', () {
      expect(marshalRepeated([], 1, 'TYPE_INT32', []), isEmpty);
    });

    test('repeated message via marshalRepeated emits each element', () {
      final out = marshalRepeated([], 1, 'TYPE_MESSAGE', [
        [0x08, 0x01],
        [0x08, 0x02],
      ]);
      // Two LEN records.
      expect(out.where((b) => b == 0x0A).length, 2);
    });
  });

  group('sizeOfMessage', () {
    test('equals marshal length', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'id',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final msg = {'id': 300};
      expect(sizeOfMessage(msg, desc), marshal(msg, desc).length);
    });

    test('empty message has size 0', () {
      expect(sizeOfMessage(<String, Object?>{}, const []), 0);
    });
  });

  group('explicit presence singular fields', () {
    test('default int32 is emitted under EXPLICIT presence', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'v',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
          'features': {'field_presence': 'EXPLICIT'},
        },
      ];
      final bytes = marshal({'v': 0}, desc);
      // Tag 0x08 + a single zero payload byte.
      expect(bytes, [0x08, 0x00]);
    });

    test('default string is emitted under EXPLICIT presence', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 's',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
          'features': {'field_presence': 'EXPLICIT'},
        },
      ];
      final bytes = marshal({'s': ''}, desc);
      expect(bytes, [0x0A, 0x00]);
    });

    test('default fixed32 is emitted under EXPLICIT presence', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'v',
          'number': 1,
          'type': 'TYPE_FIXED32',
          'label': 'LABEL_OPTIONAL',
          'features': {'field_presence': 'EXPLICIT'},
        },
      ];
      final bytes = marshal({'v': 0}, desc);
      expect(bytes, [0x0D, 0, 0, 0, 0]);
    });

    test('default fixed64 is emitted under EXPLICIT presence', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'v',
          'number': 1,
          'type': 'TYPE_FIXED64',
          'label': 'LABEL_OPTIONAL',
          'features': {'field_presence': 'EXPLICIT'},
        },
      ];
      final bytes = marshal({'v': 0}, desc);
      expect(bytes, [0x09, 0, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('a non-default value under EXPLICIT presence is written normally', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'v',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
          'features': {'field_presence': 'EXPLICIT'},
        },
      ];
      expect(marshal({'v': 5}, desc), [0x08, 5]);
    });
  });

  group('map field key coercion', () {
    test('int-keyed map with string keys coerces', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'm',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'mapEntry': true,
          'keyType': 'TYPE_INT32',
          'valueType': 'TYPE_STRING',
        },
      ];
      final bytes = marshal({
        'm': <Object?, Object?>{'7': 'seven'},
      }, desc);
      final back = unmarshal(bytes, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'repeated': true,
          'mapEntry': true,
          'keyType': 'int32',
          'valueType': 'string',
        },
      ]);
      expect((back['m'] as Map)[7], 'seven');
    });

    test('bool-keyed map coerces from string', () {
      final desc = <Map<String, Object?>>[
        {
          'name': 'm',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'mapEntry': true,
          'keyType': 'TYPE_BOOL',
          'valueType': 'TYPE_INT32',
        },
      ];
      final bytes = marshal({
        'm': <Object?, Object?>{'true': 1, false: 2},
      }, desc);
      final back = unmarshal(bytes, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'repeated': true,
          'mapEntry': true,
          'keyType': 'bool',
          'valueType': 'int32',
        },
      ]);
      final m = back['m'] as Map;
      expect(m[true], 1);
      expect(m[false], 2);
    });

    test('empty map field is a no-op', () {
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
      expect(marshal({'m': <Object?, Object?>{}}, desc), isEmpty);
    });
  });

  group('unknown-field round-trip', () {
    test(r'$unknown bytes are re-emitted by marshal', () {
      // Marshal a message with two fields, unmarshal with only one declared so
      // the other is retained as unknown, then re-marshal.
      final full = <Map<String, Object?>>[
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
      final bytes = marshal({'a': 1, 'b': 2}, full);
      final partial = <Map<String, Object?>>[
        {'name': 'a', 'number': 1, 'type': 'int32'},
      ];
      final decoded = unmarshal(bytes, partial);
      expect(decoded.containsKey(unknownFieldsKey), true);
      // Re-marshal with the partial descriptor; unknown bytes survive.
      final reMarshalDesc = <Map<String, Object?>>[
        {
          'name': 'a',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final re = marshal(decoded, reMarshalDesc);
      // Decoding the re-marshaled bytes with the full descriptor recovers b.
      final recovered = unmarshal(re, full);
      expect(recovered['a'], 1);
      expect(recovered['b'], 2);
    });
  });
}
