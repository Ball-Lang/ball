/// Self-describing ball-file envelope.
///
/// A ball file on disk (`.ball.json` or `.ball.bin`) is a serialized
/// `google.protobuf.Any` wrapping exactly one top-level message — today a
/// [Program] or a [Module]. Readers never guess the contained type: it is
/// carried explicitly by the Any type URL, which in proto3 JSON is the
/// `@type` field. New top-level types can be added without changing any
/// reader's discrimination logic.
///
/// Binary form uses the real `google.protobuf.Any` (type_url + value bytes).
/// JSON form is the proto3-JSON representation of an Any:
/// `{"@type": "type.googleapis.com/ball.v1.Program", <message fields…>}` — so
/// it round-trips through the message's own proto3-JSON codec plus the one
/// `@type` key, with no type registry required.
library;

import 'dart:typed_data';

import 'package:protobuf/protobuf.dart';
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';

import 'gen/ball/v1/ball.pb.dart';

const String _typeUrlPrefix = 'type.googleapis.com';
const String programTypeUrl = '$_typeUrlPrefix/ball.v1.Program';
const String moduleTypeUrl = '$_typeUrlPrefix/ball.v1.Module';

/// The decoded contents of a ball file: exactly one top-level message.
sealed class BallFile {
  const BallFile();
}

/// A ball file wrapping a [Program].
final class BallProgramFile extends BallFile {
  final Program program;
  const BallProgramFile(this.program);
}

/// A ball file wrapping a [Module].
final class BallModuleFile extends BallFile {
  final Module module;
  const BallModuleFile(this.module);
}

/// Thrown when a ball file is not a recognized self-describing envelope.
class BallFileFormatException implements Exception {
  final String message;
  BallFileFormatException(this.message);
  @override
  String toString() => 'BallFileFormatException: $message';
}

bool _isProgramUrl(String url) => url.endsWith('/ball.v1.Program');
bool _isModuleUrl(String url) => url.endsWith('/ball.v1.Module');

// ── Decode ──────────────────────────────────────────────────────────────

/// Decodes a binary ball file (serialized `google.protobuf.Any`).
BallFile decodeBallFileBinary(List<int> bytes) {
  final any = Any.fromBuffer(bytes);
  if (_isProgramUrl(any.typeUrl)) {
    final p = Program();
    any.unpackInto(p);
    return BallProgramFile(p);
  }
  if (_isModuleUrl(any.typeUrl)) {
    final m = Module();
    any.unpackInto(m);
    return BallModuleFile(m);
  }
  throw BallFileFormatException('unknown ball file type URL: "${any.typeUrl}"');
}

/// Decodes a proto3-JSON ball file (an Any with an `@type` field).
BallFile decodeBallFileJson(Object? json) {
  if (json is! Map) {
    throw BallFileFormatException('ball file JSON must be an object');
  }
  final type = json['@type'];
  if (type is! String) {
    throw BallFileFormatException(
      'ball file JSON is not self-describing: missing "@type" '
      '(expected a google.protobuf.Any envelope)',
    );
  }
  final body = Map<String, dynamic>.from(json)..remove('@type');
  if (_isProgramUrl(type)) {
    return BallProgramFile(
      Program()..mergeFromProto3Json(body, ignoreUnknownFields: true),
    );
  }
  if (_isModuleUrl(type)) {
    return BallModuleFile(
      Module()..mergeFromProto3Json(body, ignoreUnknownFields: true),
    );
  }
  throw BallFileFormatException('unknown ball file @type: "$type"');
}

/// Decodes a [Program] from a ball file, or throws if it wraps a [Module].
Program decodeProgramJson(Object? json) => switch (decodeBallFileJson(json)) {
  BallProgramFile(:final program) => program,
  BallModuleFile() => throw BallFileFormatException(
    'expected a Program ball file but got a Module',
  ),
};

/// Decodes a [Module] from a ball file, or throws if it wraps a [Program].
Module decodeModuleJson(Object? json) => switch (decodeBallFileJson(json)) {
  BallModuleFile(:final module) => module,
  BallProgramFile() => throw BallFileFormatException(
    'expected a Module ball file but got a Program',
  ),
};

/// Decodes a [Program] from a binary ball file, or throws if it wraps a [Module].
Program decodeProgramBinary(List<int> bytes) =>
    switch (decodeBallFileBinary(bytes)) {
      BallProgramFile(:final program) => program,
      BallModuleFile() => throw BallFileFormatException(
        'expected a Program ball file but got a Module',
      ),
    };

/// Decodes a [Module] from a binary ball file, or throws if it wraps a [Program].
Module decodeModuleBinary(List<int> bytes) =>
    switch (decodeBallFileBinary(bytes)) {
      BallModuleFile(:final module) => module,
      BallProgramFile() => throw BallFileFormatException(
        'expected a Module ball file but got a Program',
      ),
    };

// ── Encode ──────────────────────────────────────────────────────────────

String _typeUrlFor(GeneratedMessage message) {
  if (message is Program) return programTypeUrl;
  if (message is Module) return moduleTypeUrl;
  throw ArgumentError(
    'cannot wrap ${message.runtimeType} as a ball file '
    '(only Program and Module are top-level)',
  );
}

/// Encodes a [Program] or [Module] as a binary ball file
/// (a serialized `google.protobuf.Any`).
Uint8List encodeBallFileBinary(GeneratedMessage message) {
  // Validate the type up front for a clear error.
  _typeUrlFor(message);
  return Any.pack(message, typeUrlPrefix: _typeUrlPrefix).writeToBuffer();
}

/// Encodes a [Program] or [Module] as a proto3-JSON ball file: the message's
/// own proto3 JSON with the Any `@type` key prepended.
Map<String, dynamic> encodeBallFileJson(GeneratedMessage message) {
  final type = _typeUrlFor(message);
  final body = message.toProto3Json() as Map<String, dynamic>;
  return <String, dynamic>{'@type': type, ...body};
}
