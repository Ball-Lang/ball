import 'package:ball_protobuf/field_fixed.dart';
import 'package:ball_protobuf/field_int.dart';
import 'package:ball_protobuf/field_len.dart';
import 'package:ball_protobuf/wire_fixed.dart';
import 'package:ball_protobuf/wire_varint.dart';
import 'package:test/test.dart';

void main() {
  group('field_int encode non-zero values', () {
    test('int64 / uint32 / uint64', () {
      expect(encodeInt64Field([], 1, 5), [0x08, 5]);
      expect(encodeUint32Field([], 1, 5), [0x08, 5]);
      expect(encodeUint64Field([], 1, 5), [0x08, 5]);
    });

    test('int64 / uint32 / uint64 skip default 0', () {
      expect(encodeInt64Field([], 1, 0), isEmpty);
      expect(encodeUint32Field([], 1, 0), isEmpty);
      expect(encodeUint64Field([], 1, 0), isEmpty);
    });

    test('sint64 zigzag', () {
      // zigzag64(-1) = 1.
      expect(encodeSint64Field([], 1, -1), [0x08, 1]);
      expect(encodeSint64Field([], 1, 0), isEmpty);
    });

    test('enum field', () {
      expect(encodeEnumField([], 1, 3), [0x08, 3]);
      expect(encodeEnumField([], 1, 0), isEmpty);
    });

    test('decodeAsSint64', () {
      expect(decodeAsSint64(1), -1);
      expect(decodeAsSint64(2), 1);
    });

    test('decodeAsInt64 / decodeAsUint64 identity', () {
      expect(decodeAsInt64(-7), -7);
      expect(decodeAsUint64(7), 7);
    });
  });

  group('field_fixed', () {
    test('sfixed32 / sfixed64 encode non-zero', () {
      expect(encodeSfixed32Field([], 1, 1), [0x0D, 1, 0, 0, 0]);
      expect(encodeSfixed64Field([], 1, 1), [0x09, 1, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('sfixed32 / sfixed64 skip default 0', () {
      expect(encodeSfixed32Field([], 1, 0), isEmpty);
      expect(encodeSfixed64Field([], 1, 0), isEmpty);
    });

    test('decodeFloat throws on insufficient bytes', () {
      expect(() => decodeFloat([0, 0], 0), throwsA(isA<RangeError>()));
    });

    test('decodeDouble throws on insufficient bytes', () {
      expect(() => decodeDouble([0, 0, 0], 0), throwsA(isA<RangeError>()));
    });

    test('float round-trip via encode/decode', () {
      final buf = encodeFloatField([], 1, 2.5);
      expect(decodeFloat(buf, 1), 2.5);
    });

    test('double round-trip via encode/decode', () {
      final buf = encodeDoubleField([], 1, 2.5);
      expect(decodeDouble(buf, 1), 2.5);
    });
  });

  group('field_len', () {
    test('encodeMessageField with non-empty bytes', () {
      expect(encodeMessageField([], 1, [1, 2, 3]), [0x0A, 3, 1, 2, 3]);
    });

    test('encodeMessageField skips empty bytes', () {
      expect(encodeMessageField([], 1, []), isEmpty);
    });

    test('encodePackedFixed32Field', () {
      final out = encodePackedFixed32Field([], 1, [1, 2]);
      // tag (1<<3)|2 = 0x0A, length 8, then 2x 4-byte LE values.
      expect(out[0], 0x0A);
      expect(out[1], 8);
      expect(out.length, 10);
    });

    test('encodePackedFixed32Field skips empty', () {
      expect(encodePackedFixed32Field([], 1, []), isEmpty);
    });

    test('encodePackedFixed64Field', () {
      final out = encodePackedFixed64Field([], 1, [1, 2]);
      expect(out[0], 0x0A);
      expect(out[1], 16);
      expect(out.length, 18);
    });

    test('encodePackedFixed64Field skips empty', () {
      expect(encodePackedFixed64Field([], 1, []), isEmpty);
    });

    test('encodePackedVarintsField skips empty', () {
      expect(encodePackedVarintsField([], 1, []), isEmpty);
    });

    test('decodeStringValue', () {
      expect(decodeStringValue([0x61, 0x62]), 'ab');
    });

    test('decodePackedFixed32 throws on non-multiple-of-4', () {
      expect(
        () => decodePackedFixed32([1, 2, 3]),
        throwsA(isA<FormatException>()),
      );
    });

    test('decodePackedFixed32 decodes multiple values', () {
      final data = <int>[];
      encodeFixed32(data, 10);
      encodeFixed32(data, 20);
      expect(decodePackedFixed32(data), [10, 20]);
    });
  });

  group('wire_fixed decodeTag validation', () {
    test('overlong (non-minimal) tag throws', () {
      // Tag value 8 encoded as a 2-byte non-minimal varint: [0x88, 0x00].
      expect(() => decodeTag([0x88, 0x00], 0), throwsA(isA<FormatException>()));
    });

    test('field number 0 is illegal', () {
      // Tag 0 -> field 0, wire 0.
      expect(() => decodeTag([0x00], 0), throwsA(isA<FormatException>()));
    });

    test('truncated tag throws', () {
      expect(() => decodeTag([0x80], 0), throwsA(isA<FormatException>()));
    });

    test('high field number round-trips', () {
      final buf = encodeTag([], 536870911, 2); // max 2^29-1
      final decoded = decodeTag(buf, 0);
      expect(decoded['fieldNumber'], 536870911);
    });

    test('tag varint exceeding 10 bytes throws', () {
      // 10 continuation bytes (no terminator) trips the 10-byte cap.
      final buf = List<int>.filled(10, 0x80);
      expect(() => decodeTag(buf, 0), throwsA(isA<FormatException>()));
    });

    test('field number above 2^29-1 throws', () {
      // Field number 2^29 = 536870912 is one past the max; encode its raw tag.
      final tagValue = (536870912 << 3) | 2;
      final buf = encodeVarint([], tagValue);
      expect(() => decodeTag(buf, 0), throwsA(isA<FormatException>()));
    });
  });

  group('wire_fixed 64-bit high bytes', () {
    test('encodeFixed64 emits all 8 little-endian bytes', () {
      final buf = encodeFixed64([], 0x0807060504030201);
      expect(buf, [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('decodeFixed64 reads all 8 bytes', () {
      final result = decodeFixed64([1, 2, 3, 4, 5, 6, 7, 8], 0);
      expect(result['value'], 0x0807060504030201);
    });
  });

  group('wire_varint zigzag', () {
    test('encodeZigZag64 over a range', () {
      for (final n in [0, -1, 1, -2, 2, 1000, -1000]) {
        expect(decodeZigZag(encodeZigZag64(n)), n);
      }
    });

    test('encodeZigZag32 over a range', () {
      for (final n in [0, -1, 1, 2147483647, -2147483648]) {
        expect(decodeZigZag(encodeZigZag32(n)), n);
      }
    });

    test('decodeVarint long-varint cap throws', () {
      // 11 continuation bytes — exceeds the 10-byte cap.
      final buf = List<int>.filled(11, 0x80);
      expect(() => decodeVarint(buf, 0), throwsA(isA<FormatException>()));
    });
  });
}
