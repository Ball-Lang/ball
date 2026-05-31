/// protoc/buf plugin protocol for `protoc-gen-ball`.
///
/// A protobuf code-generator plugin is just a program that reads a serialized
/// `google.protobuf.compiler.CodeGeneratorRequest` from stdin and writes a
/// serialized `CodeGeneratorResponse` to stdout (see plugin.proto). This file
/// owns the **process-free core** of that contract:
///
///   * [decodeRequest] / [encodeResponse] decode/encode the plugin messages,
///   * [PluginRequest] / [PluginResponse] / [GeneratedFile] are plain value
///     views over the decoded maps,
///   * [generate] is the pure request->response transform the `bin/` wrapper
///     calls. It is unit-testable without spawning a process.
///
/// **Decode approach (documented per the phase brief):** `ball_base` ships
/// generated bindings for `descriptor.proto` but **not** for
/// `compiler/plugin.proto`, so there is no generated `CodeGeneratorRequest` /
/// `CodeGeneratorResponse` to reuse. Rather than add a protoc-dart codegen step
/// just for two messages, we **dogfood the `ball_protobuf` runtime**: we
/// hand-author the small Map field descriptors for the plugin messages (only
/// the fields this plugin needs) and decode/encode them with
/// [marshal]/[unmarshal]. This is the same descriptor-driven path the runtime is
/// conformance-tested on, and it keeps the generator's only protobuf dependency
/// the one runtime we already trust.
///
/// The `proto_file` entries are decoded as **raw FileDescriptorProto bytes**
/// here; [generate] re-wraps them into a `FileDescriptorSet` and feeds them to
/// the generator (which decodes them via `ball_base`). Keeping them raw at the
/// codec layer means the round-trip is lossless and this layer needs no
/// FileDescriptorProto descriptor of its own.
library;

import 'package:ball_protobuf/ball_protobuf.dart';

import 'generator.dart';

/// `CodeGeneratorResponse.Feature.FEATURE_PROTO3_OPTIONAL` (bit 0).
const int featureProto3Optional = 1;

/// `CodeGeneratorResponse.Feature.FEATURE_SUPPORTS_EDITIONS` (bit 1).
const int featureSupportsEditions = 2;

/// The minimum edition `ball_protobuf` (and therefore this plugin) supports,
/// expressed as the `google.protobuf.Edition` enum value (NOT the edition
/// number), per `CodeGeneratorResponse.minimum_edition`. `ball_protobuf`
/// resolves proto2/proto3 through the same edition-defaults table, so proto2 is
/// the floor.
const int minimumSupportedEdition = editionProto2; // EDITION_PROTO2 = 998

/// The maximum edition this plugin supports. `ball_protobuf`'s FeatureSet
/// defaults table is golden-pinned to protoc 28.2, which tops out at
/// EDITION_2023 (see docs/EDITIONS_SPEC.md "Golden FeatureSet resolution
/// data"); editions 2024+ are not yet golden-verified, so we advertise 2023 as
/// the conservative, correct ceiling.
const int maximumSupportedEdition = edition2023; // EDITION_2023 = 1000

// ---------------------------------------------------------------------------
// Hand-authored Map descriptors for the plugin.proto messages (only the fields
// this plugin reads/writes). Field numbers come straight from plugin.proto.
// ---------------------------------------------------------------------------

/// `CodeGeneratorRequest` descriptor (decode side). `proto_file` /
/// `source_file_descriptors` carry no sub-descriptor, so the runtime leaves each
/// element as raw `List<int>` FileDescriptorProto bytes for a later phase.
const List<Map<String, Object?>> _requestDescriptor = [
  {
    'name': 'file_to_generate',
    'number': 1,
    'type': 'TYPE_STRING',
    'label': 'LABEL_REPEATED',
    'repeated': true,
  },
  {'name': 'parameter', 'number': 2, 'type': 'TYPE_STRING'},
  {
    'name': 'proto_file',
    'number': 15,
    'type': 'TYPE_MESSAGE',
    'label': 'LABEL_REPEATED',
    'repeated': true,
  },
  {
    'name': 'source_file_descriptors',
    'number': 17,
    'type': 'TYPE_MESSAGE',
    'label': 'LABEL_REPEATED',
    'repeated': true,
  },
];

/// `CodeGeneratorResponse.File` descriptor (encode side).
const List<Map<String, Object?>> _responseFileDescriptor = [
  {'name': 'name', 'number': 1, 'type': 'TYPE_STRING'},
  {'name': 'insertion_point', 'number': 2, 'type': 'TYPE_STRING'},
  {'name': 'content', 'number': 15, 'type': 'TYPE_STRING'},
];

/// `CodeGeneratorResponse` descriptor (encode side). `supported_features` is a
/// `uint64` and `minimum_edition`/`maximum_edition` are `int32`; both decode
/// back identically since the runtime stores them as Dart `int`.
const List<Map<String, Object?>> _responseDescriptor = [
  {'name': 'error', 'number': 1, 'type': 'TYPE_STRING'},
  {'name': 'supported_features', 'number': 2, 'type': 'TYPE_UINT64'},
  {'name': 'minimum_edition', 'number': 3, 'type': 'TYPE_INT32'},
  {'name': 'maximum_edition', 'number': 4, 'type': 'TYPE_INT32'},
  {
    'name': 'file',
    'number': 15,
    'type': 'TYPE_MESSAGE',
    'label': 'LABEL_REPEATED',
    'repeated': true,
    'messageDescriptor': _responseFileDescriptor,
  },
];

// ---------------------------------------------------------------------------
// Value views.
// ---------------------------------------------------------------------------

/// A decoded `CodeGeneratorRequest` (the fields this plugin needs).
class PluginRequest {
  /// `.proto` files the user explicitly asked to generate (not imports).
  final List<String> filesToGenerate;

  /// The `opt=...` parameter string (empty if unset).
  final String parameter;

  /// Raw `FileDescriptorProto` bytes for every file + transitive imports, in
  /// topological order. Left undecoded here (see the library doc comment).
  final List<List<int>> protoFiles;

  const PluginRequest({
    required this.filesToGenerate,
    required this.parameter,
    required this.protoFiles,
  });
}

/// A single output file in a `CodeGeneratorResponse`.
class GeneratedFile {
  /// Output path, relative to the generation directory, `/`-separated.
  final String name;

  /// File contents.
  final String content;

  const GeneratedFile({required this.name, required this.content});
}

/// A `CodeGeneratorResponse` ready to encode.
class PluginResponse {
  /// Non-empty ⇒ generation failed (and no files are emitted).
  final String error;

  /// `FEATURE_*` bitset.
  final int supportedFeatures;

  /// `google.protobuf.Edition` enum value.
  final int minimumEdition;

  /// `google.protobuf.Edition` enum value.
  final int maximumEdition;

  /// Generated files.
  final List<GeneratedFile> files;

  const PluginResponse({
    this.error = '',
    required this.supportedFeatures,
    required this.minimumEdition,
    required this.maximumEdition,
    this.files = const [],
  });
}

// ---------------------------------------------------------------------------
// Codec.
// ---------------------------------------------------------------------------

/// Decodes serialized `CodeGeneratorRequest` [bytes] via the `ball_protobuf`
/// runtime.
PluginRequest decodeRequest(List<int> bytes) {
  final map = unmarshal(bytes, _requestDescriptor);

  List<String> strings(Object? v) =>
      (v as List?)?.map((e) => e as String).toList() ?? const <String>[];
  List<List<int>> rawMessages(Object? v) =>
      (v as List?)?.map((e) => (e as List).cast<int>()).toList() ??
      const <List<int>>[];

  return PluginRequest(
    filesToGenerate: strings(map['file_to_generate']),
    parameter: (map['parameter'] as String?) ?? '',
    protoFiles: rawMessages(map['proto_file']),
  );
}

/// Encodes [response] to serialized `CodeGeneratorResponse` bytes.
List<int> encodeResponse(PluginResponse response) {
  final map = <String, Object?>{
    if (response.error.isNotEmpty) 'error': response.error,
    'supported_features': response.supportedFeatures,
    'minimum_edition': response.minimumEdition,
    'maximum_edition': response.maximumEdition,
    if (response.files.isNotEmpty)
      'file': [
        for (final f in response.files)
          <String, Object?>{'name': f.name, 'content': f.content},
      ],
  };
  return marshal(map, _responseDescriptor);
}

// ---------------------------------------------------------------------------
// The core transform.
// ---------------------------------------------------------------------------

/// `FileDescriptorSet` descriptor: a single repeated message field `file = 1`.
/// Used to re-wrap the request's raw `proto_file` bytes back into a
/// `FileDescriptorSet` the generator can decode (each element stays pre-encoded,
/// so no FileDescriptorProto descriptor is needed here).
const List<Map<String, Object?>> _fileDescriptorSetDescriptor = [
  {
    'name': 'file',
    'number': 1,
    'type': 'TYPE_MESSAGE',
    'label': 'LABEL_REPEATED',
    'repeated': true,
  },
];

/// Re-encodes [protoFiles] (raw `FileDescriptorProto` bytes) into a serialized
/// `FileDescriptorSet` (field 1, repeated). Each element is already encoded, so
/// `marshal` writes it as a length-prefixed record verbatim.
List<int> _fileDescriptorSetBytes(List<List<int>> protoFiles) =>
    marshal({'file': protoFiles}, _fileDescriptorSetDescriptor);

/// The pure request->response transform that powers the `bin/` wrapper.
///
/// Reconstructs a `FileDescriptorSet` from the request's `proto_file` entries,
/// runs the message generator over the files named in `file_to_generate`, and
/// returns one `.pb.dart` per requested input — advertising proto3-optional +
/// editions support and `ball_protobuf`'s edition range. A generation failure
/// is reported via [PluginResponse.error] (exit code 0), per plugin.proto.
///
/// Decoupled from stdin/stdout on purpose so it can be unit-tested directly.
PluginResponse generate(PluginRequest request) {
  if (request.filesToGenerate.isEmpty) {
    return const PluginResponse(
      supportedFeatures: featureProto3Optional | featureSupportsEditions,
      minimumEdition: minimumSupportedEdition,
      maximumEdition: maximumSupportedEdition,
    );
  }

  final List<GeneratedDartFile> generated;
  try {
    generated = generateDartModels(
      _fileDescriptorSetBytes(request.protoFiles),
      filesToGenerate: request.filesToGenerate.toSet(),
    );
  } catch (e) {
    return PluginResponse(
      error: 'protoc-gen-ball: $e',
      supportedFeatures: featureProto3Optional | featureSupportsEditions,
      minimumEdition: minimumSupportedEdition,
      maximumEdition: maximumSupportedEdition,
    );
  }

  return PluginResponse(
    supportedFeatures: featureProto3Optional | featureSupportsEditions,
    minimumEdition: minimumSupportedEdition,
    maximumEdition: maximumSupportedEdition,
    files: [
      for (final g in generated)
        GeneratedFile(name: g.path, content: g.content),
    ],
  );
}

/// Convenience: decode → [generate] → encode, the whole stdin->stdout core in
/// one call (used by the `bin/` wrapper and the smoke test).
List<int> runPlugin(List<int> requestBytes) =>
    encodeResponse(generate(decodeRequest(requestBytes)));
