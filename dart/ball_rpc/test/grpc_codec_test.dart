/// gRPC framing + grpc-status trailer mapping.
library;

import 'package:ball_protobuf/ball_protobuf.dart'
    show grpcDecodeFrame, grpcEncodeFrame;
import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

void main() {
  group('frame layout (1 flag + 4-byte big-endian length)', () {
    test(
      'encode writes flag 0 + big-endian length, decode recovers payload',
      () {
        final payload = List<int>.generate(300, (i) => i % 256);
        final frame = grpcEncodeFrame(payload);
        expect(frame[0], 0); // uncompressed flag
        // 300 = 0x0000012C big-endian.
        expect(frame.sublist(1, 5), [0x00, 0x00, 0x01, 0x2C]);

        final decoded = grpcDecodeFrame(frame, 0);
        expect(decoded['messageBytes'], payload);
        expect(decoded['compressed'], isFalse);
        expect(decoded['bytesRead'], frame.length);
      },
    );
  });

  group('rpcMethodPath', () {
    test('builds /{package}.{Service}/{Method}', () {
      expect(rpcMethodPath('acme.Eliza', 'Say'), '/acme.Eliza/Say');
    });
  });

  group('grpc-status trailer mapping', () {
    test('absent grpc-status => no error (success)', () {
      expect(grpcStatusFromTrailers(const {}), isNull);
    });

    test('grpc-status: 0 => no error', () {
      expect(grpcStatusFromTrailers({'grpc-status': '0'}), isNull);
    });

    test('non-zero grpc-status => RpcException with mapped code + message', () {
      final err = grpcStatusFromTrailers({
        'grpc-status': '5',
        'grpc-message': 'no such user',
      });
      expect(err, isNotNull);
      expect(err!.code, RpcCode.notFound);
      expect(err.message, 'no such user');
    });

    test('every gRPC code number maps back to its RpcCode', () {
      for (final code in RpcCode.values) {
        if (code == RpcCode.ok) continue;
        final err = grpcStatusFromTrailers({'grpc-status': '${code.value}'});
        expect(err, isNotNull, reason: code.name);
        expect(err!.code, code, reason: code.name);
      }
    });

    test('unparseable grpc-status falls back to unknown', () {
      final err = grpcStatusFromTrailers({'grpc-status': 'nope'});
      expect(err, isNotNull);
      expect(err!.code, RpcCode.unknown);
    });
  });

  group('grpc-message percent-encoding', () {
    test('ASCII message is unchanged', () {
      expect(grpcEncodeMessage('hello world'), 'hello world');
      expect(grpcDecodeMessage('hello world'), 'hello world');
    });

    test('non-ASCII + reserved bytes round-trip through %XX encoding', () {
      const original = 'naïve % café';
      final encoded = grpcEncodeMessage(original);
      // '%' itself must be escaped.
      expect(encoded.contains('%25'), isTrue);
      expect(grpcDecodeMessage(encoded), original);
    });

    test('decode tolerates a bare value with no escapes', () {
      expect(grpcDecodeMessage('plain'), 'plain');
    });
  });
}
