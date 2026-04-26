import 'package:ball_base/protobuf/wire_bytes.dart';
import 'package:test/test.dart';

void main() {
  test('makeBuffer returns empty list', () {
    expect(makeBuffer(), <int>[]);
  });

  group('encodeBytes', () {
    test('encodes [1, 2, 3] with varint length prefix', () {
      expect(encodeBytes([], [1, 2, 3]), [3, 1, 2, 3]);
    });

    test('encodes empty data as single zero byte', () {
      expect(encodeBytes([], []), [0]);
    });

    test('appends to existing buffer', () {
      expect(encodeBytes([99], [1, 2]), [99, 2, 1, 2]);
    });

    test('encodes data longer than 127 bytes with multi-byte varint', () {
      var data = List<int>.generate(300, (i) => i % 256);
      var result = encodeBytes([], data);
      // 300 = 0b100101100 -> varint: [0xAC, 0x02]
      expect(result[0], 0xAC);
      expect(result[1], 0x02);
      expect(result.length, 2 + 300);
      expect(result.sublist(2), data);
    });
  });

  group('decodeBytes', () {
    test('decodes [3, 1, 2, 3] at offset 0', () {
      var result = decodeBytes([3, 1, 2, 3], 0);
      expect(result['data'], [1, 2, 3]);
      expect(result['bytesRead'], 4);
    });

    test('decodes empty bytes', () {
      var result = decodeBytes([0], 0);
      expect(result['data'], <int>[]);
      expect(result['bytesRead'], 1);
    });

    test('decodes at non-zero offset', () {
      var result = decodeBytes([99, 99, 2, 10, 20], 2);
      expect(result['data'], [10, 20]);
      expect(result['bytesRead'], 3);
    });

    test('round-trips with encodeBytes', () {
      var original = [10, 20, 30, 40, 50];
      var encoded = encodeBytes([], original);
      var decoded = decodeBytes(encoded, 0);
      expect(decoded['data'], original);
    });

    test('round-trips multi-byte varint lengths', () {
      var original = List<int>.generate(300, (i) => i % 256);
      var encoded = encodeBytes([], original);
      var decoded = decodeBytes(encoded, 0);
      expect(decoded['data'], original);
      expect(decoded['bytesRead'], 2 + 300);
    });
  });

  group('encodeString', () {
    test('encodes "testing"', () {
      expect(
        encodeString([], 'testing'),
        [7, 116, 101, 115, 116, 105, 110, 103],
      );
    });

    test('encodes empty string', () {
      expect(encodeString([], ''), [0]);
    });

    test('encodes multi-byte UTF-8 characters', () {
      var result = encodeString([], 'é'); // e-acute, 2 UTF-8 bytes
      expect(result[0], 2); // varint length = 2
      expect(result[1], 0xC3);
      expect(result[2], 0xA9);
    });
  });

  group('decodeString', () {
    test('decodes "testing" from bytes', () {
      var result = decodeString(
        [7, 116, 101, 115, 116, 105, 110, 103],
        0,
      );
      expect(result['value'], 'testing');
      expect(result['bytesRead'], 8);
    });

    test('decodes empty string', () {
      var result = decodeString([0], 0);
      expect(result['value'], '');
      expect(result['bytesRead'], 1);
    });

    test('round-trips with encodeString', () {
      var original = 'Hello, 世界!'; // "Hello, 世界!"
      var encoded = encodeString([], original);
      var decoded = decodeString(encoded, 0);
      expect(decoded['value'], original);
    });
  });
}
