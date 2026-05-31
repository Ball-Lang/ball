/// The canonical RPC status codes shared by gRPC and Connect.
///
/// The 17 codes (`0`..`16`) are identical to the gRPC status-code set
/// (`OK`..`UNAUTHENTICATED`); see the gRPC status-code list
/// <https://grpc.github.io/grpc/core/md_doc_statuscodes.html>. Connect uses the
/// exact same codes but identifies them on the wire by a `lower_snake_case`
/// string name (e.g. `invalid_argument`); see the Connect protocol error table
/// <https://connectrpc.com/docs/protocol/#error-codes>. The one spelling quirk
/// worth noting: Connect spells code `1` **`canceled`** (single `l`) — see
/// [connectName]/[fromConnectName].
library;

/// A canonical RPC status code (`0`..`16`), shared by gRPC and Connect.
///
/// The integer [value] is the gRPC status code; [connectName] is the
/// Connect-protocol `lower_snake_case` string for the same code.
enum RpcCode {
  /// `0` — not an error; returned on success.
  ok(0, 'ok'),

  /// `1` — the operation was cancelled (typically by the caller).
  ///
  /// gRPC spells the constant `CANCELLED`; Connect spells it `canceled`.
  cancelled(1, 'canceled'),

  /// `2` — unknown error.
  unknown(2, 'unknown'),

  /// `3` — the client specified an invalid argument.
  invalidArgument(3, 'invalid_argument'),

  /// `4` — the deadline expired before the operation could complete.
  deadlineExceeded(4, 'deadline_exceeded'),

  /// `5` — a requested entity was not found.
  notFound(5, 'not_found'),

  /// `6` — the entity a client attempted to create already exists.
  alreadyExists(6, 'already_exists'),

  /// `7` — the caller does not have permission to execute the operation.
  permissionDenied(7, 'permission_denied'),

  /// `8` — a resource has been exhausted (quota, disk, ...).
  resourceExhausted(8, 'resource_exhausted'),

  /// `9` — the system is not in a state required for the operation.
  failedPrecondition(9, 'failed_precondition'),

  /// `10` — the operation was aborted (e.g. a concurrency conflict).
  aborted(10, 'aborted'),

  /// `11` — the operation was attempted past the valid range.
  outOfRange(11, 'out_of_range'),

  /// `12` — the operation is not implemented / not supported.
  unimplemented(12, 'unimplemented'),

  /// `13` — an internal invariant was broken.
  internal(13, 'internal'),

  /// `14` — the service is currently unavailable (retry with backoff).
  unavailable(14, 'unavailable'),

  /// `15` — unrecoverable data loss or corruption.
  dataLoss(15, 'data_loss'),

  /// `16` — the request does not have valid authentication credentials.
  unauthenticated(16, 'unauthenticated');

  const RpcCode(this.value, this.connectName);

  /// The integer status code (`0`..`16`), identical to the gRPC status code.
  final int value;

  /// The Connect-protocol `lower_snake_case` string name for this code.
  final String connectName;

  /// The [RpcCode] for an integer [value] (`0`..`16`).
  ///
  /// Any value outside that range maps to [RpcCode.unknown], matching the
  /// gRPC/Connect convention of treating an unrecognized code as `unknown`.
  static RpcCode fromValue(int value) {
    for (final c in RpcCode.values) {
      if (c.value == value) return c;
    }
    return RpcCode.unknown;
  }

  /// The [RpcCode] for a Connect `lower_snake_case` string [name].
  ///
  /// An unrecognized name maps to [RpcCode.unknown] (the Connect convention for
  /// a code a peer does not understand).
  static RpcCode fromConnectName(String name) {
    for (final c in RpcCode.values) {
      if (c.connectName == name) return c;
    }
    return RpcCode.unknown;
  }
}
