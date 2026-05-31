/// Asserts the canonical [RpcCode] int<->name mapping against the gRPC
/// status-code list and the Connect protocol error table.
library;

import 'package:ball_rpc/ball_rpc.dart';
import 'package:test/test.dart';

void main() {
  group('RpcCode values match the gRPC status-code list (0..16)', () {
    // Verified against https://grpc.github.io/grpc/core/md_doc_statuscodes.html
    const expectedValues = {
      RpcCode.ok: 0,
      RpcCode.cancelled: 1,
      RpcCode.unknown: 2,
      RpcCode.invalidArgument: 3,
      RpcCode.deadlineExceeded: 4,
      RpcCode.notFound: 5,
      RpcCode.alreadyExists: 6,
      RpcCode.permissionDenied: 7,
      RpcCode.resourceExhausted: 8,
      RpcCode.failedPrecondition: 9,
      RpcCode.aborted: 10,
      RpcCode.outOfRange: 11,
      RpcCode.unimplemented: 12,
      RpcCode.internal: 13,
      RpcCode.unavailable: 14,
      RpcCode.dataLoss: 15,
      RpcCode.unauthenticated: 16,
    };

    test('every code carries its canonical integer', () {
      expectedValues.forEach((code, value) {
        expect(code.value, value, reason: '${code.name} value');
      });
    });

    test('values are exactly the contiguous range 0..16', () {
      final values = RpcCode.values.map((c) => c.value).toList()..sort();
      expect(values, List.generate(17, (i) => i));
    });
  });

  group('RpcCode Connect string names (lower_snake_case)', () {
    // Verified against https://connectrpc.com/docs/protocol/#error-codes
    const expectedNames = {
      RpcCode.ok: 'ok',
      // NOTE: Connect spells code 1 "canceled" (single l), unlike gRPC's
      // CANCELLED constant.
      RpcCode.cancelled: 'canceled',
      RpcCode.unknown: 'unknown',
      RpcCode.invalidArgument: 'invalid_argument',
      RpcCode.deadlineExceeded: 'deadline_exceeded',
      RpcCode.notFound: 'not_found',
      RpcCode.alreadyExists: 'already_exists',
      RpcCode.permissionDenied: 'permission_denied',
      RpcCode.resourceExhausted: 'resource_exhausted',
      RpcCode.failedPrecondition: 'failed_precondition',
      RpcCode.aborted: 'aborted',
      RpcCode.outOfRange: 'out_of_range',
      RpcCode.unimplemented: 'unimplemented',
      RpcCode.internal: 'internal',
      RpcCode.unavailable: 'unavailable',
      RpcCode.dataLoss: 'data_loss',
      RpcCode.unauthenticated: 'unauthenticated',
    };

    test('every code carries its canonical Connect name', () {
      expectedNames.forEach((code, name) {
        expect(code.connectName, name, reason: '${code.name} connectName');
      });
    });
  });

  group('int<->name round-trips and lookups', () {
    test('fromValue is the inverse of value for every code', () {
      for (final code in RpcCode.values) {
        expect(RpcCode.fromValue(code.value), code);
      }
    });

    test('fromConnectName is the inverse of connectName for every code', () {
      for (final code in RpcCode.values) {
        expect(RpcCode.fromConnectName(code.connectName), code);
      }
    });

    test('out-of-range integer maps to unknown', () {
      expect(RpcCode.fromValue(99), RpcCode.unknown);
      expect(RpcCode.fromValue(-1), RpcCode.unknown);
    });

    test('unrecognized name maps to unknown', () {
      expect(RpcCode.fromConnectName('bogus'), RpcCode.unknown);
      // gRPC spelling is not a Connect name, so it falls through to unknown.
      expect(RpcCode.fromConnectName('cancelled'), RpcCode.unknown);
    });
  });
}
