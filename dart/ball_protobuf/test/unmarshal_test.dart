import 'package:ball_protobuf/marshal.dart';
import 'package:ball_protobuf/unmarshal.dart';
import 'package:ball_protobuf/wire_fixed.dart';
import 'package:ball_protobuf/wire_varint.dart';
import 'package:test/test.dart';

void main() {
  group('findFieldByNumber', () {
    final desc = <Map<String, Object?>>[
      {'name': 'a', 'number': 1, 'type': 'int32'},
      {'name': 'b', 'number': 5, 'type': 'string'},
    ];

    test('finds an existing field', () {
      expect(findFieldByNumber(desc, 5)!['name'], 'b');
    });

    test('returns null for an unknown field', () {
      expect(findFieldByNumber(desc, 99), isNull);
    });
  });

  group('skipField', () {
    test('VARINT', () {
      final buf = encodeVarint([], 300);
      expect(skipField(buf, 0, 0), buf.length);
    });

    test('I64 skips 8 bytes', () {
      expect(skipField([0, 0, 0, 0, 0, 0, 0, 0], 0, 1), 8);
    });

    test('I64 truncated throws', () {
      expect(() => skipField([1, 2, 3], 0, 1), throwsA(isA<FormatException>()));
    });

    test('LEN skips length + payload', () {
      final buf = <int>[3, 1, 2, 3];
      expect(skipField(buf, 0, 2), 4);
    });

    test('LEN truncated throws', () {
      expect(() => skipField([5, 1, 2], 0, 2), throwsA(isA<FormatException>()));
    });

    test('I32 skips 4 bytes', () {
      expect(skipField([1, 2, 3, 4], 0, 5), 4);
    });

    test('I32 truncated throws', () {
      expect(() => skipField([1, 2], 0, 5), throwsA(isA<FormatException>()));
    });

    test('unsupported wire type throws', () {
      expect(() => skipField([0], 0, 6), throwsA(isA<FormatException>()));
    });
  });

  group('unmarshalFieldValue — type coverage', () {
    test('uint32 / sint32 / sint64 from varint', () {
      // sint32: zigzag(1) = -1 decoded.
      expect(unmarshalFieldValue([2], 0, 0, 'sint32')['value'], 1);
      expect(unmarshalFieldValue([1], 0, 0, 'sint64')['value'], -1);
      expect(unmarshalFieldValue([5], 0, 0, 'uint32')['value'], 5);
    });

    test('enum varint truncates to int32', () {
      expect(unmarshalFieldValue([5], 0, 0, 'enum')['value'], 5);
    });

    test('int64 / uint64 pass raw varint through', () {
      final buf = encodeVarint([], 12345);
      expect(unmarshalFieldValue(buf, 0, 0, 'int64')['value'], 12345);
      expect(unmarshalFieldValue(buf, 0, 0, 'uint64')['value'], 12345);
    });

    test('I64 sfixed64', () {
      final buf = encodeFixed64([], 42);
      expect(unmarshalFieldValue(buf, 0, 1, 'sfixed64')['value'], 42);
    });

    test('I64 fixed64', () {
      final buf = encodeFixed64([], 42);
      expect(unmarshalFieldValue(buf, 0, 1, 'fixed64')['value'], 42);
    });

    test('I64 double', () {
      final m = marshal(
        {'v': 2.5},
        [
          {
            'name': 'v',
            'number': 1,
            'type': 'TYPE_DOUBLE',
            'label': 'LABEL_OPTIONAL',
          },
        ],
      );
      // Skip the 1-byte tag.
      expect(unmarshalFieldValue(m, 1, 1, 'double')['value'], 2.5);
    });

    test('LEN bytes / string / message return raw / decoded', () {
      final strField = unmarshalFieldValue(
        [3, 0x61, 0x62, 0x63],
        0,
        2,
        'string',
      );
      expect(strField['value'], 'abc');
      final bytesField = unmarshalFieldValue([2, 1, 2], 0, 2, 'bytes');
      expect(bytesField['value'], [1, 2]);
      final msgField = unmarshalFieldValue([2, 1, 2], 0, 2, 'message');
      expect(msgField['value'], [1, 2]);
    });

    test('I32 sfixed32 sign-extends', () {
      final buf = encodeFixed32([], 0xFFFFFFFF);
      expect(unmarshalFieldValue(buf, 0, 5, 'sfixed32')['value'], -1);
    });

    test('I32 fixed32 stays unsigned', () {
      final buf = encodeFixed32([], 0xFFFFFFFF);
      expect(unmarshalFieldValue(buf, 0, 5, 'fixed32')['value'], 0xFFFFFFFF);
    });

    test('I32 float', () {
      final buf = <int>[];
      // 1.5 in IEEE-754 float LE.
      buf.addAll([0, 0, 0xC0, 0x3F]);
      expect(unmarshalFieldValue(buf, 0, 5, 'float')['value'], 1.5);
    });

    test('TYPE_ prefix is normalized', () {
      expect(unmarshalFieldValue([5], 0, 0, 'TYPE_INT32')['value'], 5);
    });

    test('unknown wire type throws', () {
      expect(
        () => unmarshalFieldValue([0], 0, 6, 'int32'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('unmarshalRepeated', () {
    test('packed varints', () {
      final data = <int>[];
      encodeVarint(data, 1);
      encodeVarint(data, 2);
      encodeVarint(data, 3);
      final buf = <int>[data.length, ...data];
      final result = unmarshalRepeated(buf, 0, 2, 'int32');
      expect(result['values'], [1, 2, 3]);
    });

    test('unpacked single element (non-packable type)', () {
      final result = unmarshalRepeated([3, 0x61, 0x62, 0x63], 0, 2, 'string');
      expect(result['values'], ['abc']);
    });
  });

  group('unmarshalMapField', () {
    test('decodes key + value', () {
      // entry: field1=key(int32)=7, field2=value(string)="x"
      final entry = <int>[];
      entry.addAll([0x08, 7]); // field 1 varint 7
      entry.addAll([0x12, 1, 0x78]); // field 2 LEN "x"
      final result = unmarshalMapField(entry, 'int32', 'string');
      expect(result['key'], 7);
      expect(result['value'], 'x');
    });

    test('absent key/value restore type defaults', () {
      final result = unmarshalMapField(<int>[], 'int32', 'string');
      expect(result['key'], 0);
      expect(result['value'], '');
    });

    test('default for bool / float / bytes / message value', () {
      expect(unmarshalMapField(<int>[], 'int32', 'bool')['value'], false);
      expect(unmarshalMapField(<int>[], 'int32', 'double')['value'], 0.0);
      expect(unmarshalMapField(<int>[], 'int32', 'bytes')['value'], <int>[]);
      expect(unmarshalMapField(<int>[], 'int32', 'message')['value'], isNull);
    });

    test('TYPE_ prefix on key/value types', () {
      final entry = [0x08, 7];
      final result = unmarshalMapField(entry, 'TYPE_INT32', 'TYPE_STRING');
      expect(result['key'], 7);
    });

    test('unknown field in entry is skipped', () {
      final entry = <int>[];
      entry.addAll([0x08, 7]); // field 1 key
      entry.addAll([0x18, 9]); // field 3 (unknown) varint
      entry.addAll([0x12, 1, 0x78]); // field 2 value "x"
      final result = unmarshalMapField(entry, 'int32', 'string');
      expect(result['key'], 7);
      expect(result['value'], 'x');
    });
  });

  group('closed-enum routing', () {
    final closedFeatures = {'enum_type': 'CLOSED'};

    test('singular out-of-range closed enum is dropped', () {
      final marshalDesc = <Map<String, Object?>>[
        {
          'name': 'e',
          'number': 1,
          'type': 'TYPE_ENUM',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final bytes = marshal({'e': 99}, marshalDesc); // 99 not in {0,1}
      final back = unmarshal(bytes, [
        {
          'name': 'e',
          'number': 1,
          'type': 'enum',
          'features': closedFeatures,
          'enumValues': {0: 'A', 1: 'B'},
        },
      ]);
      expect(back.containsKey('e'), false);
    });

    test('in-range closed enum is kept', () {
      final bytes = marshal(
        {'e': 1},
        [
          {
            'name': 'e',
            'number': 1,
            'type': 'TYPE_ENUM',
            'label': 'LABEL_OPTIONAL',
          },
        ],
      );
      final back = unmarshal(bytes, [
        {
          'name': 'e',
          'number': 1,
          'type': 'enum',
          'features': closedFeatures,
          'enumValues': {0: 'A', 1: 'B'},
        },
      ]);
      expect(back['e'], 1);
    });

    test('open enum keeps an out-of-range value', () {
      final bytes = marshal(
        {'e': 99},
        [
          {
            'name': 'e',
            'number': 1,
            'type': 'TYPE_ENUM',
            'label': 'LABEL_OPTIONAL',
          },
        ],
      );
      final back = unmarshal(bytes, [
        {'name': 'e', 'number': 1, 'type': 'enum'},
      ]);
      expect(back['e'], 99);
    });

    test('repeated closed enum drops out-of-range elements', () {
      final bytes = marshal(
        {
          'e': [1, 99, 0],
        },
        [
          {
            'name': 'e',
            'number': 1,
            'type': 'TYPE_ENUM',
            'label': 'LABEL_REPEATED',
          },
        ],
      );
      final back = unmarshal(bytes, [
        {
          'name': 'e',
          'number': 1,
          'type': 'enum',
          'repeated': true,
          'features': closedFeatures,
          'enumValues': [0, 1],
        },
      ]);
      expect(back['e'], [1, 0]);
    });

    test('closed enum with List enumValues works', () {
      final bytes = marshal(
        {'e': 1},
        [
          {
            'name': 'e',
            'number': 1,
            'type': 'TYPE_ENUM',
            'label': 'LABEL_OPTIONAL',
          },
        ],
      );
      final back = unmarshal(bytes, [
        {
          'name': 'e',
          'number': 1,
          'type': 'enum',
          'features': closedFeatures,
          'enumValues': [0, 1],
        },
      ]);
      expect(back['e'], 1);
    });
  });

  group('singular message merge across repeated occurrences', () {
    test('two occurrences of a singular message field merge', () {
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
      final first = marshal({'a': 1}, innerMarshal);
      final second = marshal({'b': 2}, innerMarshal);
      // Build outer bytes: field 1 (message) appearing twice.
      final outer = <int>[];
      outer.addAll([0x0A, first.length, ...first]);
      outer.addAll([0x0A, second.length, ...second]);
      final back = unmarshal(outer, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'a', 'number': 1, 'type': 'int32'},
            {'name': 'b', 'number': 2, 'type': 'int32'},
          ],
        },
      ]);
      final m = back['m'] as Map;
      expect(m['a'], 1);
      expect(m['b'], 2);
    });
  });

  group('oneof sibling clearing', () {
    test('last oneof member on the wire wins', () {
      // Encode field 1 (int32) then field 2 (string), both in oneof "choice".
      final bytes = <int>[];
      bytes.addAll([0x08, 5]); // field 1 = 5
      bytes.addAll([0x12, 1, 0x78]); // field 2 = "x"
      final back = unmarshal(bytes, [
        {'name': 'a', 'number': 1, 'type': 'int32', 'oneof': 'choice'},
        {'name': 'b', 'number': 2, 'type': 'string', 'oneof': 'choice'},
      ]);
      expect(back.containsKey('a'), false);
      expect(back['b'], 'x');
    });
  });

  group('unknown group fields', () {
    test('unknown START_GROUP is consumed and retained', () {
      // field 5 START_GROUP, with a nested field, then END_GROUP.
      final bytes = <int>[];
      bytes.add((5 << 3) | 3); // START_GROUP field 5
      bytes.addAll([0x08, 1]); // nested field 1 varint
      bytes.add((5 << 3) | 4); // END_GROUP field 5
      bytes.addAll([0x08, 7]); // known field 1 after the group
      final back = unmarshal(bytes, [
        {'name': 'x', 'number': 1, 'type': 'int32'},
      ]);
      expect(back['x'], 7);
      expect(back.containsKey(unknownFieldsKey), true);
    });

    test('known non-message field with START_GROUP is skipped', () {
      final bytes = <int>[];
      bytes.add((1 << 3) | 3); // START_GROUP for field 1 (declared as int32)
      bytes.addAll([0x10, 2]); // nested field 2 varint
      bytes.add((1 << 3) | 4); // END_GROUP field 1
      bytes.addAll([0x10, 9]); // field 2 varint after
      final back = unmarshal(bytes, [
        {'name': 'a', 'number': 1, 'type': 'int32'},
        {'name': 'b', 'number': 2, 'type': 'int32'},
      ]);
      // The group for field 1 is treated as unknown and skipped; b is decoded.
      expect(back['b'], 9);
      expect(back.containsKey('a'), false);
    });
  });

  group('group structural errors', () {
    test('mismatched END_GROUP throws', () {
      final bytes = <int>[];
      bytes.add((5 << 3) | 3); // START_GROUP field 5
      bytes.add((6 << 3) | 4); // END_GROUP field 6 — mismatch
      expect(
        () => unmarshal(bytes, [
          {'name': 'g', 'number': 5, 'type': 'message'},
        ]),
        throwsA(isA<FormatException>()),
      );
    });

    test('unterminated group throws', () {
      final bytes = <int>[];
      bytes.add((5 << 3) | 3); // START_GROUP field 5, never closed
      bytes.addAll([0x08, 1]);
      expect(
        () => unmarshal(bytes, [
          {'name': 'g', 'number': 5, 'type': 'message'},
        ]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('map<K, message> value unmarshal', () {
    test('message-typed value is unmarshaled with the sub-descriptor', () {
      final innerMarshal = <Map<String, Object?>>[
        {
          'name': 'value',
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
          'mapEntry': true,
          'keyType': 'TYPE_STRING',
          'valueType': 'TYPE_MESSAGE',
          'messageDescriptor': innerMarshal,
        },
      ];
      final bytes = marshal({
        'm': <Object?, Object?>{
          'k': {'value': 5},
        },
      }, desc);
      final back = unmarshal(bytes, [
        {
          'name': 'm',
          'number': 1,
          'type': 'message',
          'repeated': true,
          'mapEntry': true,
          'keyType': 'string',
          'valueType': 'message',
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'value', 'number': 1, 'type': 'int32'},
          ],
        },
      ]);
      expect(((back['m'] as Map)['k'] as Map)['value'], 5);
    });
  });
}
