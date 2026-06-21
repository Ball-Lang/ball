import 'package:ball_protobuf/grpc_frame.dart';
import 'package:test/test.dart';

void main() {
  group('flag-byte helpers', () {
    test('grpcFlagIsCompressed', () {
      expect(grpcFlagIsCompressed(0x00), false);
      expect(grpcFlagIsCompressed(grpcFlagCompressed), true);
      expect(
        grpcFlagIsCompressed(grpcFlagCompressed | grpcFlagEndOfStream),
        true,
      );
    });

    test('grpcFlagIsEndOfStream', () {
      expect(grpcFlagIsEndOfStream(0x00), false);
      expect(grpcFlagIsEndOfStream(grpcFlagEndOfStream), true);
      expect(grpcFlagIsEndOfStream(grpcFlagCompressed), false);
    });

    test('grpcMakeFlags builds the bitset', () {
      expect(grpcMakeFlags(), 0);
      expect(grpcMakeFlags(compressed: true), grpcFlagCompressed);
      expect(grpcMakeFlags(endOfStream: true), grpcFlagEndOfStream);
      expect(
        grpcMakeFlags(compressed: true, endOfStream: true),
        grpcFlagCompressed | grpcFlagEndOfStream,
      );
    });
  });

  group('grpcEncodeFrameWithFlags / grpcDecodeFrameWithFlags', () {
    test('round-trip with end-of-stream flag', () {
      final flags = grpcMakeFlags(endOfStream: true);
      final frame = grpcEncodeFrameWithFlags([7, 8, 9], flags);
      expect(frame[0], grpcFlagEndOfStream);
      // Big-endian length 3.
      expect(frame.sublist(1, 5), [0, 0, 0, 3]);

      final decoded = grpcDecodeFrameWithFlags(frame, 0);
      expect(decoded['messageBytes'], [7, 8, 9]);
      expect(decoded['flags'], grpcFlagEndOfStream);
      expect(decoded['compressed'], false);
      expect(decoded['endOfStream'], true);
      expect(decoded['bytesRead'], 8);
    });

    test('round-trip with combined compressed + end-of-stream', () {
      final flags = grpcMakeFlags(compressed: true, endOfStream: true);
      final frame = grpcEncodeFrameWithFlags([1, 2], flags);
      final decoded = grpcDecodeFrameWithFlags(frame, 0);
      expect(decoded['compressed'], true);
      expect(decoded['endOfStream'], true);
      expect(decoded['messageBytes'], [1, 2]);
    });

    test('empty payload', () {
      final frame = grpcEncodeFrameWithFlags([], 0);
      expect(frame.length, 5);
      final decoded = grpcDecodeFrameWithFlags(frame, 0);
      expect(decoded['messageBytes'], <int>[]);
      expect(decoded['flags'], 0);
    });

    test('decode at non-zero offset', () {
      final prefix = [0xAA, 0xBB];
      final frame = grpcEncodeFrameWithFlags([42], grpcFlagCompressed);
      final buffer = [...prefix, ...frame];
      final decoded = grpcDecodeFrameWithFlags(buffer, 2);
      expect(decoded['messageBytes'], [42]);
      expect(decoded['compressed'], true);
    });

    test('grpcDecodeFrameWithFlags throws on incomplete header', () {
      expect(
        () => grpcDecodeFrameWithFlags([0, 0, 0], 0),
        throwsA(isA<RangeError>()),
      );
    });

    test('grpcDecodeFrameWithFlags throws on incomplete payload', () {
      expect(
        () => grpcDecodeFrameWithFlags([0, 0, 0, 0, 50, 1], 0),
        throwsA(isA<RangeError>()),
      );
    });

    test('grpcEncodeFrame equals grpcEncodeFrameWithFlags(compressed bit)', () {
      final a = grpcEncodeFrame([5, 6, 7], compressed: true);
      final b = grpcEncodeFrameWithFlags([5, 6, 7], grpcFlagCompressed);
      expect(a, b);
    });
  });

  group('extractServiceMethods edge cases', () {
    test('missing methods key returns empty', () {
      expect(extractServiceMethods(<String, Object?>{}), isEmpty);
    });

    test('non-list methods value returns empty', () {
      expect(
        extractServiceMethods(<String, Object?>{'methods': 'oops'}),
        isEmpty,
      );
    });

    test('skips non-map method entries', () {
      final methods = extractServiceMethods(<String, Object?>{
        'methods': <Object?>[
          'not-a-map',
          <String, Object?>{'name': 'Real'},
        ],
      });
      expect(methods, hasLength(1));
      expect(methods[0]['name'], 'Real');
    });

    test('defaults missing fields', () {
      final methods = extractServiceMethods(<String, Object?>{
        'methods': <Object?>[
          <String, Object?>{'name': 'Bare'},
        ],
      });
      expect(methods[0]['inputType'], '');
      expect(methods[0]['outputType'], '');
      expect(methods[0]['clientStreaming'], false);
      expect(methods[0]['serverStreaming'], false);
    });

    test('client streaming flag is honored', () {
      final methods = extractServiceMethods(<String, Object?>{
        'methods': <Object?>[
          <String, Object?>{
            'name': 'Upload',
            'inputType': '.pkg.Chunk',
            'outputType': '.pkg.Ack',
            'clientStreaming': true,
          },
        ],
      });
      expect(methods[0]['clientStreaming'], true);
      expect(methods[0]['serverStreaming'], false);
    });
  });
}
