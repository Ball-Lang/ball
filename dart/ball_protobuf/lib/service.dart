/// Service / method descriptors for gRPC + Connect RPC codegen.
///
/// Pure, Ball-portable value types (no `package:` imports — `dart:core` only):
/// a [ServiceDescriptor] is a list of [MethodDescriptor]s, each naming its
/// input/output message types, its streaming [MethodKind], and its idempotency
/// level. This generalizes the dynamic `extractServiceMethods()` map shape in
/// `grpc_frame.dart` into typed values that generated service stubs consume,
/// following the connect-es precedent: message codegen produces schemas, service
/// codegen produces a transport-agnostic service descriptor.
library;

/// How an RPC method streams, matching protobuf's
/// `client_streaming`/`server_streaming` flag combination on a `MethodProto`.
enum MethodKind {
  /// One request, one response.
  unary,

  /// One request, a stream of responses (`server_streaming = true`).
  serverStreaming,

  /// A stream of requests, one response (`client_streaming = true`).
  clientStreaming,

  /// A stream of requests and a stream of responses (both flags `true`).
  bidiStreaming,
}

/// Maps a `(clientStreaming, serverStreaming)` flag pair to a [MethodKind].
///
/// This is the typed counterpart of the boolean flags carried by
/// `MethodDescriptorProto` (and by `extractServiceMethods()` in
/// `grpc_frame.dart`).
MethodKind methodKindFromFlags({
  required bool clientStreaming,
  required bool serverStreaming,
}) {
  if (clientStreaming && serverStreaming) return MethodKind.bidiStreaming;
  if (clientStreaming) return MethodKind.clientStreaming;
  if (serverStreaming) return MethodKind.serverStreaming;
  return MethodKind.unary;
}

/// A method's side-effect contract, mirroring protobuf's
/// `MethodOptions.IdempotencyLevel`. Connect uses [noSideEffects] to allow GET
/// for unary calls; gRPC carries it as method metadata.
enum IdempotencyLevel {
  /// Default: no idempotency guarantee.
  idempotencyUnknown,

  /// Safe to retry; no observable side effects (allows Connect GET).
  noSideEffects,

  /// Idempotent: repeated calls have the same effect as one.
  idempotent,
}

/// A single RPC method: its name, its fully-qualified name
/// (`package.Service.Method`), the message type names of its input and output,
/// its streaming [kind], and its [idempotency] level.
///
/// Input/output are referenced by message type name (stripped FQN, the same key
/// the descriptor registry uses) so a method descriptor stays independent of any
/// particular message representation.
class MethodDescriptor {
  /// The method's short name (e.g. `Say`).
  final String name;

  /// The method's fully-qualified name (e.g. `acme.Eliza.Say`).
  final String fullName;

  /// Fully-qualified type name of the request message (stripped FQN).
  final String inputDescriptor;

  /// Fully-qualified type name of the response message (stripped FQN).
  final String outputDescriptor;

  /// How the method streams.
  final MethodKind kind;

  /// The method's idempotency contract.
  final IdempotencyLevel idempotency;

  const MethodDescriptor({
    required this.name,
    required this.fullName,
    required this.inputDescriptor,
    required this.outputDescriptor,
    required this.kind,
    this.idempotency = IdempotencyLevel.idempotencyUnknown,
  });
}

/// A service: its fully-qualified name (`package.Service`) and its ordered list
/// of [methods]. A transport (gRPC / Connect) consumes this to build a client or
/// dispatch on the server.
class ServiceDescriptor {
  /// The service's fully-qualified name (e.g. `acme.Eliza`).
  final String fullName;

  /// The service's methods, in declaration order.
  final List<MethodDescriptor> methods;

  const ServiceDescriptor({required this.fullName, required this.methods});

  /// Looks up a method by its short [name], or `null` when absent.
  MethodDescriptor? methodByName(String name) {
    for (final m in methods) {
      if (m.name == name) return m;
    }
    return null;
  }
}
