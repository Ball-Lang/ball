import 'dart:convert';

import 'package:ball_base/protobuf/editions.dart';
import 'package:ball_base/protobuf/field_fixed.dart';
import 'package:ball_base/protobuf/field_int.dart';
import 'package:ball_base/protobuf/field_len.dart';
import 'package:ball_base/protobuf/grpc_frame.dart';
import 'package:ball_base/protobuf/json_codec.dart';
import 'package:ball_base/protobuf/marshal.dart';
import 'package:ball_base/protobuf/unmarshal.dart';
import 'package:ball_base/protobuf/well_known.dart';
import 'package:ball_base/protobuf/wire_bytes.dart';
import 'package:ball_base/protobuf/wire_fixed.dart';
import 'package:ball_base/protobuf/wire_varint.dart';
import 'package:test/test.dart';

void main() {
  // =========================================================================
  // 1. Varint round-trips
  // =========================================================================
  group('varint', () {
    test('encode/decode 0', () {
      final buf = encodeVarint([], 0);
      expect(buf, [0]);
      final result = decodeVarint(buf, 0);
      expect(result['value'], 0);
      expect(result['bytesRead'], 1);
    });

    test('encode/decode 1', () {
      final buf = encodeVarint([], 1);
      expect(buf, [1]);
      final result = decodeVarint(buf, 0);
      expect(result['value'], 1);
    });

    test('encode/decode 127', () {
      final buf = encodeVarint([], 127);
      expect(buf, [127]);
      final result = decodeVarint(buf, 0);
      expect(result['value'], 127);
    });

    test('encode/decode 128', () {
      final buf = encodeVarint([], 128);
      expect(buf, [128, 1]);
      final result = decodeVarint(buf, 0);
      expect(result['value'], 128);
      expect(result['bytesRead'], 2);
    });

    test('encode/decode 300', () {
      final buf = encodeVarint([], 300);
      expect(buf, [172, 2]);
      final result = decodeVarint(buf, 0);
      expect(result['value'], 300);
    });

    test('encode/decode 150 (official protobuf docs example)', () {
      final buf = encodeVarint([], 150);
      expect(buf, [150, 1]);
      final result = decodeVarint(buf, 0);
      expect(result['value'], 150);
    });

    test('encode/decode 2^31 - 1 (max int32)', () {
      final val = 0x7FFFFFFF; // 2147483647
      final buf = encodeVarint([], val);
      final result = decodeVarint(buf, 0);
      expect(result['value'], val);
    });

    test('encode/decode 2^32 - 1 (max uint32)', () {
      final val = 0xFFFFFFFF; // 4294967295
      final buf = encodeVarint([], val);
      final result = decodeVarint(buf, 0);
      expect(result['value'], val);
    });

    test('decode at non-zero offset', () {
      final buf = [0xFF, 0xFF, ...encodeVarint([], 42)];
      final result = decodeVarint(buf, 2);
      expect(result['value'], 42);
    });

    test('throws on truncated varint', () {
      expect(
        () => decodeVarint([0x80], 0), // continuation bit set, no more bytes
        throwsA(isA<FormatException>()),
      );
    });
  });

  // =========================================================================
  // 2. ZigZag round-trips
  // =========================================================================
  group('zigzag', () {
    test('zigzag 0', () {
      expect(encodeZigZag32(0), 0);
      expect(decodeZigZag(0), 0);
    });

    test('zigzag -1', () {
      expect(encodeZigZag32(-1), 1);
      expect(decodeZigZag(1), -1);
    });

    test('zigzag 1', () {
      expect(encodeZigZag32(1), 2);
      expect(decodeZigZag(2), 1);
    });

    test('zigzag -2', () {
      expect(encodeZigZag32(-2), 3);
      expect(decodeZigZag(3), -2);
    });

    test('zigzag 2147483647 (max int32)', () {
      final encoded = encodeZigZag32(2147483647);
      expect(encoded, 4294967294);
      expect(decodeZigZag(encoded), 2147483647);
    });

    test('zigzag -2147483648 (min int32)', () {
      final encoded = encodeZigZag32(-2147483648);
      expect(encoded, 4294967295);
      expect(decodeZigZag(encoded), -2147483648);
    });

    test('zigzag64 round-trips', () {
      for (final val in [0, 1, -1, 100, -100, 0x7FFFFFFFFFFFFFFF]) {
        final encoded = encodeZigZag64(val);
        expect(decodeZigZag(encoded), val);
      }
    });
  });

  // =========================================================================
  // 3. Fixed32/64 round-trips
  // =========================================================================
  group('fixed32', () {
    test('encode 0x12345678 little-endian', () {
      final buf = encodeFixed32([], 0x12345678);
      expect(buf, [0x78, 0x56, 0x34, 0x12]);
      final result = decodeFixed32(buf, 0);
      expect(result['value'], 0x12345678);
      expect(result['bytesRead'], 4);
    });

    test('encode 0', () {
      final buf = encodeFixed32([], 0);
      expect(buf, [0, 0, 0, 0]);
      expect(decodeFixed32(buf, 0)['value'], 0);
    });

    test('encode 1', () {
      final buf = encodeFixed32([], 1);
      expect(buf, [1, 0, 0, 0]);
      expect(decodeFixed32(buf, 0)['value'], 1);
    });

    test('encode 0xFFFFFFFF', () {
      final buf = encodeFixed32([], 0xFFFFFFFF);
      expect(buf, [255, 255, 255, 255]);
      expect(decodeFixed32(buf, 0)['value'], 0xFFFFFFFF);
    });

    test('decode at non-zero offset', () {
      final buf = [0x00, 0x00, 0x78, 0x56, 0x34, 0x12];
      final result = decodeFixed32(buf, 2);
      expect(result['value'], 0x12345678);
    });

    test('throws on insufficient bytes', () {
      expect(
        () => decodeFixed32([1, 2], 0),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('fixed64', () {
    test('encode 0', () {
      final buf = encodeFixed64([], 0);
      expect(buf, [0, 0, 0, 0, 0, 0, 0, 0]);
      expect(decodeFixed64(buf, 0)['value'], 0);
    });

    test('encode 1', () {
      final buf = encodeFixed64([], 1);
      expect(buf, [1, 0, 0, 0, 0, 0, 0, 0]);
      expect(decodeFixed64(buf, 0)['value'], 1);
    });

    test('encode 256', () {
      final buf = encodeFixed64([], 256);
      expect(buf, [0, 1, 0, 0, 0, 0, 0, 0]);
      expect(decodeFixed64(buf, 0)['value'], 256);
    });

    test('round-trip large value', () {
      final val = 0x0102030405060708;
      final buf = encodeFixed64([], val);
      expect(decodeFixed64(buf, 0)['value'], val);
      expect(buf.length, 8);
    });

    test('throws on insufficient bytes', () {
      expect(
        () => decodeFixed64([1, 2, 3], 0),
        throwsA(isA<RangeError>()),
      );
    });
  });

  // =========================================================================
  // 4. Tag encoding
  // =========================================================================
  group('tag', () {
    test('field 1 varint (wire type 0)', () {
      final buf = encodeTag([], 1, 0);
      expect(buf, [0x08]); // (1 << 3) | 0 = 8
    });

    test('field 2 length-delimited (wire type 2)', () {
      final buf = encodeTag([], 2, 2);
      expect(buf, [18]); // (2 << 3) | 2 = 18
    });

    test('field 1 I32 (wire type 5)', () {
      final buf = encodeTag([], 1, 5);
      expect(buf, [13]); // (1 << 3) | 5 = 13
    });

    test('field 1 I64 (wire type 1)', () {
      final buf = encodeTag([], 1, 1);
      expect(buf, [9]); // (1 << 3) | 1 = 9
    });

    test('decode tag field 1 varint', () {
      final result = decodeTag([0x08], 0);
      expect(result['fieldNumber'], 1);
      expect(result['wireType'], 0);
      expect(result['bytesRead'], 1);
    });

    test('decode tag field 2 LEN', () {
      final result = decodeTag([18], 0);
      expect(result['fieldNumber'], 2);
      expect(result['wireType'], 2);
    });

    test('round-trip high field number', () {
      // Field number 1000 requires a multi-byte varint tag.
      final buf = encodeTag([], 1000, 2);
      final result = decodeTag(buf, 0);
      expect(result['fieldNumber'], 1000);
      expect(result['wireType'], 2);
    });
  });

  // =========================================================================
  // 5. String/bytes encoding (wire_bytes.dart)
  // =========================================================================
  group('string/bytes', () {
    test('encodeString "testing"', () {
      final buf = encodeString([], 'testing');
      expect(buf, [7, 116, 101, 115, 116, 105, 110, 103]);
    });

    test('decodeString "testing"', () {
      final result = decodeString(
        [7, 116, 101, 115, 116, 105, 110, 103],
        0,
      );
      expect(result['value'], 'testing');
      expect(result['bytesRead'], 8);
    });

    test('string round-trip with Unicode', () {
      const original = 'Hello, 世界!'; // Hello, 世界!
      final encoded = encodeString([], original);
      final decoded = decodeString(encoded, 0);
      expect(decoded['value'], original);
    });

    test('empty string', () {
      final buf = encodeString([], '');
      expect(buf, [0]);
      final decoded = decodeString(buf, 0);
      expect(decoded['value'], '');
    });

    test('bytes round-trip', () {
      final data = [1, 2, 3, 4, 5];
      final encoded = encodeBytes([], data);
      expect(encoded, [5, 1, 2, 3, 4, 5]);
      final decoded = decodeBytes(encoded, 0);
      expect(decoded['data'], data);
    });
  });

  // =========================================================================
  // 6. Field-level encoding (field_int, field_fixed, field_len)
  // =========================================================================
  group('field-level int encoding', () {
    test('encodeInt32Field field 1 value 150', () {
      final buf = encodeInt32Field([], 1, 150);
      // tag(1, varint=0) = 0x08, varint(150) = [150, 1]
      expect(buf, [0x08, 150, 1]);
    });

    test('encodeInt32Field skips default 0', () {
      expect(encodeInt32Field([], 1, 0), isEmpty);
    });

    test('encodeBoolField true', () {
      final buf = encodeBoolField([], 1, true);
      expect(buf, [0x08, 1]);
    });

    test('encodeBoolField false skips default', () {
      expect(encodeBoolField([], 1, false), isEmpty);
    });

    test('encodeSint32Field -1', () {
      final buf = encodeSint32Field([], 1, -1);
      // tag(1, varint) = 0x08, zigzag(-1) = 1
      expect(buf, [0x08, 1]);
    });

    test('decodeAsInt32 from 0xFFFFFFFF', () {
      // 0xFFFFFFFF as 32-bit signed = -1
      expect(decodeAsInt32(0xFFFFFFFF), -1);
    });

    test('decodeAsUint32 masks to 32 bits', () {
      expect(decodeAsUint32(0x1FFFFFFFF), 0xFFFFFFFF);
    });

    test('decodeAsSint32 from 1', () {
      expect(decodeAsSint32(1), -1);
    });

    test('decodeAsBool 0 and 1', () {
      expect(decodeAsBool(0), false);
      expect(decodeAsBool(1), true);
      expect(decodeAsBool(42), true);
    });
  });

  group('field-level fixed encoding', () {
    test('encodeFixed32Field field 1 value 1', () {
      final buf = encodeFixed32Field([], 1, 1);
      // tag(1, wire_type=5) = 13, then 4 LE bytes
      expect(buf, [13, 1, 0, 0, 0]);
    });

    test('encodeFixed32Field skips default 0', () {
      expect(encodeFixed32Field([], 1, 0), isEmpty);
    });

    test('encodeFixed64Field field 1 value 1', () {
      final buf = encodeFixed64Field([], 1, 1);
      // tag(1, wire_type=1) = 9, then 8 LE bytes
      expect(buf, [9, 1, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('encodeFloatField 1.0', () {
      final buf = encodeFloatField([], 1, 1.0);
      // tag(1, wire_type=5) = 13, IEEE 754 float 1.0 = [0, 0, 128, 63]
      expect(buf, [13, 0, 0, 128, 63]);
    });

    test('encodeFloatField skips default 0.0', () {
      expect(encodeFloatField([], 1, 0.0), isEmpty);
    });

    test('encodeDoubleField 1.0', () {
      final buf = encodeDoubleField([], 1, 1.0);
      // tag(1, wire_type=1) = 9, IEEE 754 double 1.0
      expect(buf, [9, 0, 0, 0, 0, 0, 0, 240, 63]);
    });

    test('decodeFloat 1.0', () {
      expect(decodeFloat([0, 0, 128, 63], 0), 1.0);
    });

    test('decodeDouble 1.0', () {
      expect(decodeDouble([0, 0, 0, 0, 0, 0, 240, 63], 0), 1.0);
    });
  });

  group('field-level LEN encoding', () {
    test('encodeStringField', () {
      final buf = encodeStringField([], 2, 'hi');
      // tag(2, LEN=2) = 18, varint(2), 'h', 'i'
      expect(buf, [18, 2, 104, 105]);
    });

    test('encodeStringField skips empty string', () {
      expect(encodeStringField([], 2, ''), isEmpty);
    });

    test('encodeBytesField', () {
      final buf = encodeBytesField([], 3, [0xAB, 0xCD]);
      // tag(3, LEN=2) = 26, varint(2), 0xAB, 0xCD
      expect(buf, [26, 2, 0xAB, 0xCD]);
    });

    test('encodePackedVarintsField', () {
      final buf = encodePackedVarintsField([], 4, [3, 270, 86942]);
      // tag(4, LEN=2) = 34
      // payload: varint(3)=[3], varint(270)=[142,2], varint(86942)=[158,167,5]
      // total payload length = 1 + 2 + 3 = 6
      expect(buf[0], 34); // tag
      expect(buf[1], 6); // length
      expect(buf.length, 8); // 1 tag + 1 length + 6 payload
    });

    test('decodePackedVarints', () {
      // Encode then decode packed varints
      final buf = <int>[];
      encodeVarint(buf, 3);
      encodeVarint(buf, 270);
      encodeVarint(buf, 86942);
      final decoded = decodePackedVarints(buf);
      expect(decoded, [3, 270, 86942]);
    });

    test('decodePackedFixed32', () {
      final buf = <int>[];
      encodeFixed32(buf, 1);
      encodeFixed32(buf, 2);
      encodeFixed32(buf, 3);
      final decoded = decodePackedFixed32(buf);
      expect(decoded, [1, 2, 3]);
    });
  });

  // =========================================================================
  // 7. Marshal/Unmarshal round-trip
  // =========================================================================
  group('marshal/unmarshal', () {
    test('simple message with int32 and string', () {
      final marshalDescriptor = <Map<String, Object?>>[
        {
          'name': 'id',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'name',
          'number': 2,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final message = <String, Object?>{'id': 42, 'name': 'hello'};
      final bytes = marshal(message, marshalDescriptor);
      expect(bytes, isNotEmpty);

      // Unmarshal uses lowercase type names.
      final unmarshalDescriptor = <Map<String, Object?>>[
        {'name': 'id', 'number': 1, 'type': 'int32'},
        {'name': 'name', 'number': 2, 'type': 'string'},
      ];
      final decoded = unmarshal(bytes, unmarshalDescriptor);
      expect(decoded['id'], 42);
      expect(decoded['name'], 'hello');
    });

    test('skips default values in proto3', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'id',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'name',
          'number': 2,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      // Both fields at default: id=0, name=""
      final message = <String, Object?>{'id': 0, 'name': ''};
      final bytes = marshal(message, descriptor);
      expect(bytes, isEmpty);
    });

    test('bool field round-trip', () {
      final marshalDesc = <Map<String, Object?>>[
        {
          'name': 'active',
          'number': 1,
          'type': 'TYPE_BOOL',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final bytes = marshal({'active': true}, marshalDesc);
      expect(bytes, isNotEmpty);

      final unmarshalDesc = <Map<String, Object?>>[
        {'name': 'active', 'number': 1, 'type': 'bool'},
      ];
      final decoded = unmarshal(bytes, unmarshalDesc);
      expect(decoded['active'], true);
    });

    test('repeated int32 (packed) round-trip', () {
      final marshalDesc = <Map<String, Object?>>[
        {
          'name': 'values',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
        },
      ];
      final bytes = marshal({
        'values': [1, 2, 3, 4, 5],
      }, marshalDesc);

      final unmarshalDesc = <Map<String, Object?>>[
        {'name': 'values', 'number': 1, 'type': 'int32', 'repeated': true},
      ];
      final decoded = unmarshal(bytes, unmarshalDesc);
      expect(decoded['values'], [1, 2, 3, 4, 5]);
    });

    test('nested message round-trip', () {
      final innerMarshalDesc = <Map<String, Object?>>[
        {
          'name': 'value',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final innerUnmarshalDesc = <Map<String, Object?>>[
        {'name': 'value', 'number': 1, 'type': 'int32'},
      ];

      // First marshal the inner message to bytes.
      final innerBytes = marshal({'value': 99}, innerMarshalDesc);

      final outerMarshalDesc = <Map<String, Object?>>[
        {
          'name': 'label',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'inner',
          'number': 2,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final outerBytes = marshal({
        'label': 'test',
        'inner': innerBytes,
      }, outerMarshalDesc);

      final outerUnmarshalDesc = <Map<String, Object?>>[
        {'name': 'label', 'number': 1, 'type': 'string'},
        {
          'name': 'inner',
          'number': 2,
          'type': 'message',
          'messageDescriptor': innerUnmarshalDesc,
        },
      ];
      final decoded = unmarshal(outerBytes, outerUnmarshalDesc);
      expect(decoded['label'], 'test');
      expect((decoded['inner'] as Map)['value'], 99);
    });

    test('unknown fields are silently skipped during unmarshal', () {
      final marshalDesc = <Map<String, Object?>>[
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
      final bytes = marshal({'a': 10, 'b': 20}, marshalDesc);

      // Only declare field 1 in unmarshal descriptor; field 2 is unknown.
      final unmarshalDesc = <Map<String, Object?>>[
        {'name': 'a', 'number': 1, 'type': 'int32'},
      ];
      final decoded = unmarshal(bytes, unmarshalDesc);
      expect(decoded['a'], 10);
      expect(decoded.containsKey('b'), false);
    });

    test('wireTypeForFieldType returns correct wire types', () {
      expect(wireTypeForFieldType('TYPE_INT32'), 0);
      expect(wireTypeForFieldType('TYPE_STRING'), 2);
      expect(wireTypeForFieldType('TYPE_FIXED32'), 5);
      expect(wireTypeForFieldType('TYPE_DOUBLE'), 1);
      expect(
        () => wireTypeForFieldType('TYPE_UNKNOWN'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // =========================================================================
  // 8. JSON codec
  // =========================================================================
  group('JSON codec', () {
    test('toCamelCase conversions', () {
      expect(toCamelCase('foo_bar'), 'fooBar');
      expect(toCamelCase('foo_bar_baz'), 'fooBarBaz');
      expect(toCamelCase('foo'), 'foo');
      expect(toCamelCase(''), '');
      expect(toCamelCase('single'), 'single');
    });

    test('toSnakeCase conversions', () {
      expect(toSnakeCase('fooBar'), 'foo_bar');
      expect(toSnakeCase('fooBarBaz'), 'foo_bar_baz');
      expect(toSnakeCase('foo'), 'foo');
      expect(toSnakeCase(''), '');
    });

    test('marshalJson simple message', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'field_name',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'count',
          'number': 2,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final message = <String, Object?>{'field_name': 'value', 'count': 42};
      final jsonStr = marshalJson(message, descriptor);
      expect(jsonStr, contains('"fieldName"'));
      expect(jsonStr, contains('"value"'));
      expect(jsonStr, contains('"count"'));
      expect(jsonStr, contains('42'));
    });

    test('marshalJson omits default values', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'name',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'age',
          'number': 2,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final message = <String, Object?>{'name': '', 'age': 0};
      final jsonStr = marshalJson(message, descriptor);
      expect(jsonStr, '{}');
    });

    test('unmarshalJson accepts camelCase', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'field_name',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final result = unmarshalJson('{"fieldName":"hello"}', descriptor);
      expect(result['field_name'], 'hello');
    });

    test('unmarshalJson accepts snake_case', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'field_name',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final result = unmarshalJson('{"field_name":"hello"}', descriptor);
      expect(result['field_name'], 'hello');
    });

    test('marshalJson int64 as string', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'big_num',
          'number': 1,
          'type': 'TYPE_INT64',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final message = <String, Object?>{'big_num': 9007199254740993};
      final jsonStr = marshalJson(message, descriptor);
      // int64 should be encoded as a string in JSON.
      expect(jsonStr, contains('"9007199254740993"'));
    });

    test('unmarshalJson int64 from string', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'big_num',
          'number': 1,
          'type': 'TYPE_INT64',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final result = unmarshalJson('{"bigNum":"9007199254740993"}', descriptor);
      expect(result['big_num'], 9007199254740993);
    });

    test('marshalJson bytes as base64', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'data',
          'number': 1,
          'type': 'TYPE_BYTES',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final message = <String, Object?>{
        'data': [72, 101, 108, 108, 111], // "Hello"
      };
      final jsonStr = marshalJson(message, descriptor);
      final decoded = jsonDecode(jsonStr) as Map;
      // base64 of [72, 101, 108, 108, 111] = "SGVsbG8="
      expect(decoded['data'], base64.encode([72, 101, 108, 108, 111]));
    });

    test('marshalJson enum as string name', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'status',
          'number': 1,
          'type': 'TYPE_ENUM',
          'label': 'LABEL_OPTIONAL',
          'enumValues': {0: 'UNKNOWN', 1: 'ACTIVE', 2: 'INACTIVE'},
        },
      ];
      final message = <String, Object?>{'status': 1};
      final jsonStr = marshalJson(message, descriptor);
      expect(jsonStr, contains('"ACTIVE"'));
    });

    test('marshalJson/unmarshalJson round-trip with repeated', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'tags',
          'number': 1,
          'type': 'TYPE_STRING',
          'label': 'LABEL_REPEATED',
        },
      ];
      final message = <String, Object?>{
        'tags': ['a', 'b', 'c'],
      };
      final jsonStr = marshalJson(message, descriptor);
      final decoded = unmarshalJson(jsonStr, descriptor);
      expect(decoded['tags'], ['a', 'b', 'c']);
    });

    test('isDefaultValue correctness', () {
      expect(isDefaultValue(0, 'TYPE_INT32'), true);
      expect(isDefaultValue(1, 'TYPE_INT32'), false);
      expect(isDefaultValue(false, 'TYPE_BOOL'), true);
      expect(isDefaultValue(true, 'TYPE_BOOL'), false);
      expect(isDefaultValue('', 'TYPE_STRING'), true);
      expect(isDefaultValue('x', 'TYPE_STRING'), false);
      expect(isDefaultValue(null, 'TYPE_MESSAGE'), true);
      expect(isDefaultValue(<int>[], 'TYPE_BYTES'), true);
    });

    test('ensureDefaults fills missing fields', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'id',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'name',
          'number': 2,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'active',
          'number': 3,
          'type': 'TYPE_BOOL',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final result = ensureDefaults({'id': 5}, descriptor);
      expect(result['id'], 5);
      expect(result['name'], '');
      expect(result['active'], false);
    });
  });

  // =========================================================================
  // 9. Well-known types
  // =========================================================================
  group('well-known types', () {
    test('timestamp to RFC 3339', () {
      final ts = <String, Object?>{'seconds': 63072000, 'nanos': 21000000};
      final rfc = timestampToRfc3339(ts);
      expect(rfc, contains('1972'));
      expect(rfc, contains('.021'));
    });

    test('timestamp zero nanos', () {
      final ts = <String, Object?>{'seconds': 0, 'nanos': 0};
      final rfc = timestampToRfc3339(ts);
      expect(rfc, '1970-01-01T00:00:00Z');
    });

    test('rfc3339 to timestamp', () {
      final ts = rfc3339ToTimestamp('1972-01-01T10:00:20.021Z');
      expect(ts['seconds'], isA<int>());
      final nanos = ts['nanos'] as int;
      expect(nanos, 21000000);
    });

    test('timestamp round-trip', () {
      final original = <String, Object?>{'seconds': 1700000000, 'nanos': 0};
      final rfc = timestampToRfc3339(original);
      final back = rfc3339ToTimestamp(rfc);
      expect(back['seconds'], original['seconds']);
      expect(back['nanos'], 0);
    });

    test('duration to string', () {
      expect(
        durationToString({'seconds': 1, 'nanos': 340012}),
        '1.000340012s',
      );
      expect(durationToString({'seconds': 0, 'nanos': 0}), '0s');
      expect(
        durationToString({'seconds': -1, 'nanos': -500000000}),
        '-1.5s',
      );
    });

    test('string to duration', () {
      final d = stringToDuration('1.5s');
      expect(d['seconds'], 1);
      expect(d['nanos'], 500000000);
    });

    test('string to duration negative', () {
      final d = stringToDuration('-0.5s');
      expect(d['seconds'], 0);
      expect(d['nanos'], -500000000);
    });

    test('duration round-trip', () {
      final original = <String, Object?>{'seconds': 42, 'nanos': 100000000};
      final str = durationToString(original);
      final back = stringToDuration(str);
      expect(back['seconds'], 42);
      expect(back['nanos'], 100000000);
    });

    test('struct round-trip', () {
      final original = <String, Object?>{'key': 'value', 'num': 42};
      final struct = mapToStruct(original);
      expect(struct.containsKey('fields'), true);
      final back = structToMap(struct);
      expect(back['key'], 'value');
      expect(back['num'], 42);
    });

    test('struct with nested types', () {
      final original = <String, Object?>{
        'str': 'hello',
        'num': 3.14,
        'flag': true,
        'nothing': null,
      };
      final struct = mapToStruct(original);
      final back = structToMap(struct);
      expect(back['str'], 'hello');
      expect(back['num'], 3.14);
      expect(back['flag'], true);
      expect(back['nothing'], null);
    });

    test('nativeToValue and valueToNative for all types', () {
      // null
      final nullVal = nativeToValue(null);
      expect(nullVal['nullValue'], 'NULL_VALUE');
      expect(valueToNative(nullVal), null);

      // number
      final numVal = nativeToValue(42);
      expect(numVal['numberValue'], 42);
      expect(valueToNative(numVal), 42);

      // string
      final strVal = nativeToValue('hello');
      expect(strVal['stringValue'], 'hello');
      expect(valueToNative(strVal), 'hello');

      // bool
      final boolVal = nativeToValue(true);
      expect(boolVal['boolValue'], true);
      expect(valueToNative(boolVal), true);
    });

    test('packAny and unpackAny', () {
      final packed = packAny(
        'type.googleapis.com/my.Type',
        {'field1': 'value1'},
      );
      expect(packed['@type'], 'type.googleapis.com/my.Type');
      expect(packed['field1'], 'value1');

      final unpacked = unpackAny(packed);
      expect(unpacked['typeUrl'], 'type.googleapis.com/my.Type');
      expect((unpacked['message'] as Map)['field1'], 'value1');
    });

    test('unpackAny throws on missing @type', () {
      expect(
        () => unpackAny({'field1': 'value1'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // =========================================================================
  // 10. gRPC framing
  // =========================================================================
  group('gRPC framing', () {
    test('single frame round-trip', () {
      final msg = [1, 2, 3, 4, 5];
      final frame = grpcEncodeFrame(msg);
      expect(frame.length, 10); // 5 header + 5 payload
      expect(frame[0], 0); // not compressed
      // Big-endian length: 0, 0, 0, 5
      expect(frame.sublist(1, 5), [0, 0, 0, 5]);

      final decoded = grpcDecodeFrame(frame, 0);
      expect(decoded['messageBytes'], msg);
      expect(decoded['compressed'], false);
      expect(decoded['bytesRead'], 10);
    });

    test('compressed flag', () {
      final frame = grpcEncodeFrame([1, 2], compressed: true);
      expect(frame[0], 1); // compressed
      final decoded = grpcDecodeFrame(frame, 0);
      expect(decoded['compressed'], true);
      expect(decoded['messageBytes'], [1, 2]);
    });

    test('empty payload', () {
      final frame = grpcEncodeFrame([]);
      expect(frame.length, 5); // header only
      expect(frame.sublist(1, 5), [0, 0, 0, 0]);
      final decoded = grpcDecodeFrame(frame, 0);
      expect(decoded['messageBytes'], <int>[]);
    });

    test('multiple frames round-trip', () {
      final messages = [
        [10, 20],
        [30, 40, 50],
        [60],
      ];
      final framed = grpcEncodeFrames(messages);
      // Frame 1: 5 + 2 = 7 bytes
      // Frame 2: 5 + 3 = 8 bytes
      // Frame 3: 5 + 1 = 6 bytes
      expect(framed.length, 7 + 8 + 6);

      final decoded = grpcDecodeFrames(framed);
      expect(decoded.length, 3);
      expect(decoded[0]['messageBytes'], [10, 20]);
      expect(decoded[1]['messageBytes'], [30, 40, 50]);
      expect(decoded[2]['messageBytes'], [60]);
    });

    test('throws on incomplete header', () {
      expect(
        () => grpcDecodeFrame([0, 0], 0),
        throwsA(isA<RangeError>()),
      );
    });

    test('throws on incomplete payload', () {
      // Header says 100 bytes but only 2 available.
      expect(
        () => grpcDecodeFrame([0, 0, 0, 0, 100, 1, 2], 0),
        throwsA(isA<RangeError>()),
      );
    });

    test('extractServiceMethods', () {
      final service = <String, Object?>{
        'methods': [
          {
            'name': 'SayHello',
            'inputType': '.helloworld.HelloRequest',
            'outputType': '.helloworld.HelloReply',
          },
          {
            'name': 'StreamGreeting',
            'inputType': '.helloworld.HelloRequest',
            'outputType': '.helloworld.HelloReply',
            'serverStreaming': true,
          },
        ],
      };
      final methods = extractServiceMethods(service);
      expect(methods.length, 2);
      expect(methods[0]['name'], 'SayHello');
      expect(methods[0]['clientStreaming'], false);
      expect(methods[0]['serverStreaming'], false);
      expect(methods[1]['serverStreaming'], true);
    });
  });

  // =========================================================================
  // 11. Edition features
  // =========================================================================
  group('edition features', () {
    test('proto3 defaults', () {
      final features = editionDefaults('proto3');
      expect(features['field_presence'], 'IMPLICIT');
      expect(features['enum_type'], 'OPEN');
      expect(features['repeated_field_encoding'], 'PACKED');
      expect(features['utf8_validation'], 'VERIFY');
    });

    test('proto2 defaults', () {
      final features = editionDefaults('proto2');
      expect(features['field_presence'], 'EXPLICIT');
      expect(features['enum_type'], 'CLOSED');
      expect(features['repeated_field_encoding'], 'EXPANDED');
      expect(features['utf8_validation'], 'NONE');
    });

    test('edition 2023 defaults', () {
      final features = editionDefaults('2023');
      expect(features['field_presence'], 'EXPLICIT');
      expect(features['enum_type'], 'OPEN');
      expect(features['repeated_field_encoding'], 'PACKED');
      expect(features['utf8_validation'], 'VERIFY');
    });

    test('unrecognized edition throws', () {
      expect(
        () => editionDefaults('unknown'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('resolveFeatures applies overrides', () {
      final resolved = resolveFeatures(
        'proto3',
        {'field_presence': 'EXPLICIT'},
        null,
        null,
      );
      expect(resolved['field_presence'], 'EXPLICIT');
      // Others still proto3 default.
      expect(resolved['enum_type'], 'OPEN');
    });

    test('resolveFeatures field-level overrides win', () {
      final resolved = resolveFeatures(
        'proto3',
        {'field_presence': 'EXPLICIT'},
        {'field_presence': 'IMPLICIT'},
        {'field_presence': 'LEGACY_REQUIRED'},
      );
      expect(resolved['field_presence'], 'LEGACY_REQUIRED');
    });

    test('hasExplicitPresence', () {
      expect(hasExplicitPresence(editionDefaults('proto3')), false);
      expect(hasExplicitPresence(editionDefaults('proto2')), true);
      expect(
        hasExplicitPresence({'field_presence': 'LEGACY_REQUIRED'}),
        true,
      );
    });

    test('isPackedRepeated', () {
      expect(isPackedRepeated(editionDefaults('proto3')), true);
      expect(isPackedRepeated(editionDefaults('proto2')), false);
    });

    test('isOpenEnum', () {
      expect(isOpenEnum(editionDefaults('proto3')), true);
      expect(isOpenEnum(editionDefaults('proto2')), false);
    });

    test('requiresUtf8Validation', () {
      expect(requiresUtf8Validation(editionDefaults('proto3')), true);
      expect(requiresUtf8Validation(editionDefaults('proto2')), false);
    });

    test('edition 2024 defaults include message_encoding and json_format', () {
      final features = editionDefaults('2024');
      expect(features['field_presence'], 'EXPLICIT');
      expect(features['enum_type'], 'OPEN');
      expect(features['repeated_field_encoding'], 'PACKED');
      expect(features['utf8_validation'], 'VERIFY');
      expect(features['message_encoding'], 'LENGTH_PREFIXED');
      expect(features['json_format'], 'ALLOW');
    });
  });

  // =========================================================================
  // 12. Bug fix regression tests
  // =========================================================================
  group('bug fix regressions', () {
    test('negative int32 encoding produces 10-byte varint', () {
      // Protobuf encodes negative int32 as sign-extended 64-bit, which
      // requires 10 bytes in varint encoding.
      final buf = encodeVarint([], -1);
      expect(buf.length, 10);
      // All continuation bytes should have bit 7 set except the last.
      for (int i = 0; i < 9; i++) {
        expect(buf[i] & 0x80, 0x80, reason: 'byte $i should have continuation bit');
      }
      expect(buf[9] & 0x80, 0, reason: 'last byte should not have continuation bit');
      // Round-trip: decode should give back the original negative value.
      final result = decodeVarint(buf, 0);
      expect(result['value'], -1);
      expect(result['bytesRead'], 10);
    });

    test('negative zero float encoding (not skipped)', () {
      // Negative zero (-0.0) is NOT the proto3 default (positive 0.0),
      // so it must be serialized. The `identical` check distinguishes them.
      final buf = encodeFloatField([], 1, -0.0);
      expect(buf, isNotEmpty, reason: '-0.0 must not be elided as default');
      // Verify the tag is present (field 1, wire type 5 = I32 -> tag byte 13).
      expect(buf[0], 13);
    });

    test('negative zero double encoding (not skipped)', () {
      final buf = encodeDoubleField([], 1, -0.0);
      expect(buf, isNotEmpty, reason: '-0.0 must not be elided as default');
      expect(buf[0], 9); // field 1, wire type 1 = I64
    });

    test('positive zero float encoding IS skipped', () {
      final buf = encodeFloatField([], 1, 0.0);
      expect(buf, isEmpty, reason: 'positive 0.0 is proto3 default');
    });

    test('positive zero double encoding IS skipped', () {
      final buf = encodeDoubleField([], 1, 0.0);
      expect(buf, isEmpty, reason: 'positive 0.0 is proto3 default');
    });

    test('map field marshal/unmarshal round-trip', () {
      final marshalDesc = <Map<String, Object?>>[
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
      final message = <String, Object?>{
        'labels': <String, Object?>{'env': 'prod', 'team': 'infra'},
      };
      final bytes = marshal(message, marshalDesc);
      expect(bytes, isNotEmpty);

      // Unmarshal with the same descriptor format (TYPE_ prefix).
      final unmarshalDesc = <Map<String, Object?>>[
        {
          'name': 'labels',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'mapEntry': true,
          'keyType': 'TYPE_STRING',
          'valueType': 'TYPE_STRING',
        },
      ];
      final decoded = unmarshal(bytes, unmarshalDesc);
      final labels = decoded['labels'] as Map;
      expect(labels['env'], 'prod');
      expect(labels['team'], 'infra');
    });

    test('map field unmarshal with bare type names', () {
      final marshalDesc = <Map<String, Object?>>[
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
      final message = <String, Object?>{
        'labels': <String, Object?>{'a': 'b'},
      };
      final bytes = marshal(message, marshalDesc);

      // Unmarshal with bare type names (the old format).
      final unmarshalDesc = <Map<String, Object?>>[
        {
          'name': 'labels',
          'number': 1,
          'type': 'message',
          'mapEntry': true,
          'keyType': 'string',
          'valueType': 'string',
        },
      ];
      final decoded = unmarshal(bytes, unmarshalDesc);
      final labels = decoded['labels'] as Map;
      expect(labels['a'], 'b');
    });

    test('float/double NaN JSON round-trip', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'f',
          'number': 1,
          'type': 'TYPE_FLOAT',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'd',
          'number': 2,
          'type': 'TYPE_DOUBLE',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final message = <String, Object?>{'f': double.nan, 'd': double.nan};
      final jsonStr = marshalJson(message, descriptor);
      expect(jsonStr, contains('"NaN"'));
      final decoded = unmarshalJson(jsonStr, descriptor);
      expect((decoded['f'] as double).isNaN, true);
      expect((decoded['d'] as double).isNaN, true);
    });

    test('float/double Infinity JSON round-trip', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'f',
          'number': 1,
          'type': 'TYPE_FLOAT',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'd',
          'number': 2,
          'type': 'TYPE_DOUBLE',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final message = <String, Object?>{
        'f': double.infinity,
        'd': double.negativeInfinity,
      };
      final jsonStr = marshalJson(message, descriptor);
      expect(jsonStr, contains('"Infinity"'));
      expect(jsonStr, contains('"-Infinity"'));
      final decoded = unmarshalJson(jsonStr, descriptor);
      expect(decoded['f'], double.infinity);
      expect(decoded['d'], double.negativeInfinity);
    });

    test('bytes base64 unmarshal from JSON', () {
      final descriptor = <Map<String, Object?>>[
        {
          'name': 'data',
          'number': 1,
          'type': 'TYPE_BYTES',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      // base64 of [1, 2, 3] = "AQID"
      final decoded = unmarshalJson('{"data":"AQID"}', descriptor);
      expect(decoded['data'], [1, 2, 3]);
    });

    test('unmarshal accepts TYPE_ prefix in descriptor type field', () {
      // Marshal with TYPE_ prefix format.
      final marshalDesc = <Map<String, Object?>>[
        {
          'name': 'id',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'name',
          'number': 2,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final bytes = marshal({'id': 42, 'name': 'hello'}, marshalDesc);

      // Unmarshal with the SAME TYPE_ prefix descriptors.
      final decoded = unmarshal(bytes, marshalDesc);
      expect(decoded['id'], 42);
      expect(decoded['name'], 'hello');
    });

    test('wire_bytes decodeBytes bounds check', () {
      // Create a buffer where the length prefix claims more bytes than exist.
      final buf = <int>[];
      encodeVarint(buf, 100); // claims 100 bytes follow
      buf.add(0x01); // but only 1 byte follows
      expect(
        () => decodeBytes(buf, 0),
        throwsA(isA<FormatException>()),
      );
    });

    test('toCamelCase preserves leading underscores', () {
      expect(toCamelCase('_private_field'), '_privateField');
      expect(toCamelCase('__double_under'), '__doubleUnder');
      expect(toCamelCase('___triple'), '___triple');
      expect(toCamelCase('_'), '_');
      expect(toCamelCase('__'), '__');
    });

    test('marshal TYPE_MESSAGE auto-marshals Map with descriptor', () {
      final innerDesc = <Map<String, Object?>>[
        {
          'name': 'value',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final outerDesc = <Map<String, Object?>>[
        {
          'name': 'inner',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_OPTIONAL',
          'messageDescriptor': innerDesc,
        },
      ];
      // Pass a Map instead of pre-encoded bytes for the inner message.
      final bytes = marshal({
        'inner': <String, Object?>{'value': 42},
      }, outerDesc);
      expect(bytes, isNotEmpty);

      // Verify by unmarshalling.
      final unmarshalDesc = <Map<String, Object?>>[
        {
          'name': 'inner',
          'number': 1,
          'type': 'message',
          'messageDescriptor': <Map<String, Object?>>[
            {'name': 'value', 'number': 1, 'type': 'int32'},
          ],
        },
      ];
      final decoded = unmarshal(bytes, unmarshalDesc);
      expect((decoded['inner'] as Map)['value'], 42);
    });

    test('decodeAsInt64 identity', () {
      expect(decodeAsInt64(0), 0);
      expect(decodeAsInt64(42), 42);
      expect(decodeAsInt64(-1), -1);
    });

    test('decodeAsUint64 identity', () {
      expect(decodeAsUint64(0), 0);
      expect(decodeAsUint64(42), 42);
      expect(decodeAsUint64(0x7FFFFFFFFFFFFFFF), 0x7FFFFFFFFFFFFFFF);
    });

    test('negative zero marshal.dart float/double not skipped', () {
      // Verify that marshal.dart also handles -0.0 correctly via marshalField.
      final desc = <Map<String, Object?>>[
        {
          'name': 'f',
          'number': 1,
          'type': 'TYPE_FLOAT',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'd',
          'number': 2,
          'type': 'TYPE_DOUBLE',
          'label': 'LABEL_OPTIONAL',
        },
      ];
      final bytes = marshal({'f': -0.0, 'd': -0.0}, desc);
      expect(bytes, isNotEmpty,
          reason: '-0.0 fields must not be skipped by marshal');
    });
  });
}
