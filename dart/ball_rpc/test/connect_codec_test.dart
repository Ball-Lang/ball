/// Connect-protocol envelope encode/decode: data frames, the end-of-stream
/// bit, the EndStreamResponse JSON, and the unary error JSON.
library;

import 'dart:convert';

import 'package:ball_protobuf/ball_protobuf.dart'
    show grpcDecodeFrameWithFlags, grpcFlagIsEndOfStream;
import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

void main() {
  group('streaming envelope (data frame)', () {
    test('encode then decode round-trips the payload, end-of-stream clear', () {
      final payload = [1, 2, 3, 250, 0, 99];
      final frame = connectEncodeMessage(payload);
      // Flag byte 0 (no compression, not end-of-stream); 4-byte length header.
      expect(frame[0], 0);
      expect(grpcFlagIsEndOfStream(frame[0]), isFalse);

      final env = connectDecodeEnvelope(frame, 0);
      expect(env.endOfStream, isFalse);
      expect(env.payload, payload);
      expect(env.bytesRead, frame.length);
      expect(env.error, isNull);
    });
  });

  group('end-of-stream envelope', () {
    test('success: end-of-stream bit set, empty error', () {
      final frame = connectEncodeEndStream();
      // Flag bit 1 (end-of-stream) is set.
      expect(grpcFlagIsEndOfStream(frame[0]), isTrue);

      final env = connectDecodeEnvelope(frame, 0);
      expect(env.endOfStream, isTrue);
      expect(env.error, isNull);
    });

    test('error: end-of-stream carries the Connect error JSON', () {
      final frame = connectEncodeEndStream(
        error: RpcException(
          RpcCode.unavailable,
          'overloaded: back off and retry',
        ),
        metadata: {'acme-operation-cost': '237'},
      );
      expect(grpcFlagIsEndOfStream(frame[0]), isTrue);

      // The payload (after the 5-byte header) is the EndStreamResponse JSON.
      final decodedFrame = grpcDecodeFrameWithFlags(frame, 0);
      final json =
          jsonDecode(utf8.decode(decodedFrame['messageBytes'] as List<int>))
              as Map<String, Object?>;
      expect((json['error'] as Map)['code'], 'unavailable');
      expect(
        (json['error'] as Map)['message'],
        'overloaded: back off and retry',
      );
      // metadata values are arrays of strings per the spec.
      expect((json['metadata'] as Map)['acme-operation-cost'], ['237']);

      // And the high-level decoder reconstructs the RpcException + metadata.
      final env = connectDecodeEnvelope(frame, 0);
      expect(env.endOfStream, isTrue);
      expect(env.error, isNotNull);
      expect(env.error!.code, RpcCode.unavailable);
      expect(env.error!.message, 'overloaded: back off and retry');
      expect(env.metadata?['acme-operation-cost'], '237');
    });
  });

  group('multiple envelopes in a stream body', () {
    test('decodes a sequence of data frames + a trailing end-of-stream', () {
      final body = <int>[
        ...connectEncodeMessage([10]),
        ...connectEncodeMessage([20, 21]),
        ...connectEncodeEndStream(),
      ];
      final envs = connectDecodeEnvelopes(body);
      expect(envs.length, 3);
      expect(envs[0].payload, [10]);
      expect(envs[1].payload, [20, 21]);
      expect(envs[2].endOfStream, isTrue);
      expect(envs[2].error, isNull);
    });
  });

  group('unary error JSON', () {
    test('errorFromJson parses {code, message, details}', () {
      final json = {
        'code': 'invalid_argument',
        'message': 'bad field',
        'details': [
          {'type': 'google.rpc.BadRequest', 'value': 'CgIIPA'},
        ],
      };
      final e = errorFromJson(json);
      expect(e.code, RpcCode.invalidArgument);
      expect(e.message, 'bad field');
      expect(e.details.length, 1);
      expect((e.details.first as Map)['type'], 'google.rpc.BadRequest');
    });

    test('errorFromJson tolerates an unrecognized / absent code', () {
      expect(errorFromJson({'code': 'mystery'}).code, RpcCode.unknown);
      expect(errorFromJson(const {}).code, RpcCode.unknown);
      expect(errorFromJson(const {}).message, '');
    });
  });

  test('connect protocol version constant is "1"', () {
    expect(connectProtocolVersion, '1');
  });
}
