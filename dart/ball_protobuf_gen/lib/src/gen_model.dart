/// Intermediate "GenModel" tree built from a protoc `FileDescriptorSet`.
///
/// This is the target-independent half of the generator (§9 of
/// `docs/PROTOBUF_CODEGEN_PLAN.md`): it walks the `FileDescriptorProto`s for
/// **structure** (which messages/enums exist, their names, nesting, package)
/// and pairs each message with the **resolved, Editions-aware field-descriptor
/// list** the [DescriptorRegistry] (descriptor bridge) already produces. The
/// emitters (`dart_emitter.dart`, and future C++/TS) consume this tree and only
/// differ in syntax.
///
/// Why reuse the registry's field maps verbatim: they are exactly the
/// `Map<String, Object?>` descriptors the conformance-pinned `ball_protobuf`
/// runtime marshals/unmarshals — so the generated code embeds them unchanged
/// and **cannot drift from spec**. The GenModel only adds the typed-view
/// metadata the emitter needs (Dart identifiers, presence kind, cross-type
/// references).
library;

import 'package:ball_base/ball_base.dart'
    show
        DescriptorProto,
        EnumDescriptorProto,
        FieldDescriptorProto,
        FieldDescriptorProto_Label,
        FieldDescriptorProto_Type,
        FileDescriptorProto,
        FileDescriptorSet;
import 'package:ball_protobuf/ball_protobuf.dart'
    show hasExplicitPresence, isImplicitPresence, isRequired;

import 'descriptor_bridge.dart';

/// Field presence kind, resolved from the field's Editions FeatureSet.
enum PresenceKind {
  /// EXPLICIT presence — emit `hasX()` / `clearX()`; absent reads as default.
  explicit,

  /// IMPLICIT (proto3-style) presence — plain getter with type-default fallback.
  implicit,

  /// LEGACY_REQUIRED — like explicit, but validated on `toBytes`.
  required,
}

/// The Dart category of a field, deciding which accessor shape the emitter
/// produces.
enum FieldCardinality { singular, repeated, map }

/// One generated file (one input `.proto`).
class GenFile {
  /// The source `.proto` path (e.g. `google/protobuf/test_messages_proto3.proto`).
  final String protoPath;

  /// The proto package (e.g. `protobuf_test_messages.proto3`), possibly empty.
  final String package;

  /// Top-level (and, flattened, all nested) messages in declaration order.
  final List<GenMessage> messages;

  /// Top-level (and nested) enums in declaration order.
  final List<GenEnum> enums;

  GenFile({
    required this.protoPath,
    required this.package,
    required this.messages,
    required this.enums,
  });

  /// The generated output path (`foo/bar.proto` -> `foo/bar.pb.dart`).
  String get outputPath {
    final base = protoPath.endsWith('.proto')
        ? protoPath.substring(0, protoPath.length - '.proto'.length)
        : protoPath;
    return '$base.pb.dart';
  }
}

/// A generated message type.
class GenMessage {
  /// Fully-qualified protobuf name, no leading dot (registry key).
  final String fullName;

  /// The Dart class name (nested types are flattened with `_` joins so the
  /// whole file stays a flat list of top-level classes).
  final String dartName;

  /// The resolved field-descriptor list for this message, as produced by the
  /// descriptor bridge — embedded verbatim (cross-references rewritten to
  /// descriptor-getter calls by the emitter).
  final List<Map<String, Object?>> descriptor;

  /// Typed-view metadata per *wire* field (map-entry helper messages are not
  /// emitted as classes; their fields are absorbed into the map field).
  final List<GenField> fields;

  /// `true` for synthetic `map<K,V>` entry messages — not emitted as a class.
  final bool isMapEntry;

  GenMessage({
    required this.fullName,
    required this.dartName,
    required this.descriptor,
    required this.fields,
    required this.isMapEntry,
  });
}

/// A generated field accessor.
class GenField {
  /// The proto field name (snake_case) — the backing-map key and descriptor
  /// `'name'`. For extensions this is the bracketed `[fqn]` key.
  final String protoName;

  /// The Dart accessor name (lowerCamelCase, keyword-escaped).
  final String dartName;

  /// `'TYPE_*'` string.
  final String protoType;

  final FieldCardinality cardinality;

  final PresenceKind presence;

  /// For singular/repeated message fields and map *values* of message type:
  /// the referenced message's FQN (registry key). Null for scalar fields.
  final String? messageTypeName;

  /// For enum fields and map values of enum type: the referenced enum FQN.
  final String? enumTypeName;

  /// For map fields: the key/value protobuf types.
  final String? mapKeyType;
  final String? mapValueType;

  /// Real (non-synthetic) oneof name this field belongs to, or null.
  final String? oneofName;

  GenField({
    required this.protoName,
    required this.dartName,
    required this.protoType,
    required this.cardinality,
    required this.presence,
    this.messageTypeName,
    this.enumTypeName,
    this.mapKeyType,
    this.mapValueType,
    this.oneofName,
  });

  bool get isMessage =>
      protoType == 'TYPE_MESSAGE' || protoType == 'TYPE_GROUP';
  bool get isEnum => protoType == 'TYPE_ENUM';
}

/// A generated enum type.
class GenEnum {
  /// Fully-qualified protobuf name, no leading dot.
  final String fullName;

  /// The Dart enum class name (nested enums flattened with `_`).
  final String dartName;

  /// Ordered (value-number, name) pairs as declared. The first declared name
  /// for a number is canonical; `allow_alias` duplicates follow.
  final List<GenEnumValue> values;

  GenEnum({
    required this.fullName,
    required this.dartName,
    required this.values,
  });
}

/// One enum constant.
class GenEnumValue {
  final String protoName;
  final String dartName;
  final int number;

  GenEnumValue({
    required this.protoName,
    required this.dartName,
    required this.number,
  });
}

/// Builds the per-file [GenModel] from a binary `FileDescriptorSet`.
///
/// The registry (descriptor bridge) is built once over the whole set so
/// cross-file message/enum references resolve. Each requested file is then
/// turned into a [GenFile] with its messages and enums.
class GenModelBuilder {
  final FileDescriptorSet _fds;
  final DescriptorRegistry _registry;

  /// FQN (no leading dot) -> the enum descriptor, for value emission.
  final Map<String, EnumDescriptorProto> _enums = {};

  /// FQN (no leading dot) -> Dart class/enum name.
  final Map<String, String> _dartNames = {};

  /// Map-entry message FQN -> the enum FQN of its `value` field, for
  /// `map<K, enum>` fields whose value enum type the bridge does not name.
  final Map<String, String> _mapValueEnumType = {};

  GenModelBuilder._(this._fds, this._registry);

  /// Builds a model builder from raw `FileDescriptorSet` bytes.
  factory GenModelBuilder.fromBytes(List<int> fdsBytes) {
    final fds = FileDescriptorSet.fromBuffer(fdsBytes);
    final registry = buildRegistry(fdsBytes);
    final b = GenModelBuilder._(fds, registry);
    b._indexNames();
    return b;
  }

  /// The shared resolved descriptor registry (message FQN -> field list).
  DescriptorRegistry get registry => _registry;

  /// Builds [GenFile]s for every file in the set whose name is in
  /// [filesToGenerate]. An empty [filesToGenerate] generates every file.
  List<GenFile> buildFiles(Set<String> filesToGenerate) {
    final out = <GenFile>[];
    for (final file in _fds.file) {
      if (filesToGenerate.isNotEmpty && !filesToGenerate.contains(file.name)) {
        continue;
      }
      out.add(_buildFile(file));
    }
    return out;
  }

  /// Builds ONE [GenFile] holding every message and enum across the whole set,
  /// in file/declaration order. Used by the golden test (and any single-file
  /// regeneration) so the emitted file is fully self-contained — every
  /// cross-message reference resolves within one shared descriptor registry,
  /// with no cross-file imports.
  ///
  /// [outputPath] is the synthetic path stamped into the header / output name.
  GenFile buildCombined(String outputPath) {
    final messages = <GenMessage>[];
    final enums = <GenEnum>[];
    for (final file in _fds.file) {
      final f = _buildFile(file);
      messages.addAll(f.messages);
      enums.addAll(f.enums);
    }
    return GenFile(
      protoPath: outputPath,
      package: '',
      messages: messages,
      enums: enums,
    );
  }

  // -------------------------------------------------------------------------
  // Name indexing (pass 0): assign a flat Dart name to every message + enum.
  // -------------------------------------------------------------------------

  void _indexNames() {
    for (final file in _fds.file) {
      final pkgPrefix = file.package.isEmpty ? '' : '${file.package}.';
      for (final m in file.messageType) {
        _indexMessageNames(m, pkgPrefix, '');
      }
      for (final e in file.enumType) {
        final fqn = '$pkgPrefix${e.name}';
        _enums[fqn] = e;
        _dartNames[fqn] = e.name;
      }
    }
  }

  void _indexMessageNames(
    DescriptorProto m,
    String pkgPrefix,
    String parentDart,
  ) {
    final fqn = '$pkgPrefix${m.name}';
    final dart = parentDart.isEmpty ? m.name : '${parentDart}_${m.name}';
    _dartNames[fqn] = dart;
    // For a map<K, enum> entry message, record the value field's enum FQN: the
    // bridge stores enumValues/enumNames on the map field but not the enum's
    // own name, so the typed view recovers it here.
    if (m.hasOptions() && m.options.mapEntry && m.field.length == 2) {
      final valF = m.field[1];
      if (valF.type == FieldDescriptorProto_Type.TYPE_ENUM) {
        _mapValueEnumType[fqn] = _strip(valF.typeName);
      }
    }
    for (final e in m.enumType) {
      final efqn = '$fqn.${e.name}';
      _enums[efqn] = e;
      _dartNames[efqn] = '${dart}_${e.name}';
    }
    for (final n in m.nestedType) {
      _indexMessageNames(n, '$fqn.', dart);
    }
  }

  // -------------------------------------------------------------------------
  // File / message / enum construction.
  // -------------------------------------------------------------------------

  GenFile _buildFile(FileDescriptorProto file) {
    final pkgPrefix = file.package.isEmpty ? '' : '${file.package}.';
    final messages = <GenMessage>[];
    final enums = <GenEnum>[];

    for (final m in file.messageType) {
      _collectMessage(m, pkgPrefix, messages, enums);
    }
    for (final e in file.enumType) {
      enums.add(_buildEnum('$pkgPrefix${e.name}', e));
    }

    return GenFile(
      protoPath: file.name,
      package: file.package,
      messages: messages,
      enums: enums,
    );
  }

  void _collectMessage(
    DescriptorProto m,
    String pkgPrefix,
    List<GenMessage> messages,
    List<GenEnum> enums,
  ) {
    final fqn = '$pkgPrefix${m.name}';
    final isMapEntry = m.hasOptions() && m.options.mapEntry;

    messages.add(
      GenMessage(
        fullName: fqn,
        dartName: _dartNames[fqn]!,
        descriptor: _registry[fqn] ?? const <Map<String, Object?>>[],
        fields: isMapEntry ? const [] : _buildFields(m, fqn),
        isMapEntry: isMapEntry,
      ),
    );

    for (final e in m.enumType) {
      enums.add(_buildEnum('$fqn.${e.name}', e));
    }
    for (final n in m.nestedType) {
      _collectMessage(n, '$fqn.', messages, enums);
    }
  }

  /// Builds the typed-view [GenField]s for message [m] (whose FQN is [fqn]),
  /// pulling the resolved presence / type info out of the bridge's
  /// already-computed descriptor list so the typed view and the embedded
  /// descriptor never disagree.
  List<GenField> _buildFields(DescriptorProto m, String fqn) {
    final descriptor = _registry[fqn] ?? const <Map<String, Object?>>[];
    // The bridge emits one descriptor entry per wire field, in field order,
    // PLUS any folded-in extensions at the end (keyed `[fqn]`). The typed view
    // only covers this message's own declared fields, matched by name.
    final byName = <String, Map<String, Object?>>{};
    for (final d in descriptor) {
      byName[d['name'] as String] = d;
    }

    final fields = <GenField>[];
    for (final fld in m.field) {
      final d = byName[fld.name];
      if (d == null) continue; // defensive — should never happen
      fields.add(_buildField(fld, d, m));
    }
    return fields;
  }

  GenField _buildField(
    FieldDescriptorProto fld,
    Map<String, Object?> d,
    DescriptorProto owner,
  ) {
    final features = (d['features'] as Map<String, String>?) ?? const {};
    final presence = isRequired(features)
        ? PresenceKind.required
        : (hasExplicitPresence(features)
              ? PresenceKind.explicit
              : (isImplicitPresence(features)
                    ? PresenceKind.implicit
                    : PresenceKind.implicit));

    final cardinality = d['mapEntry'] == true
        ? FieldCardinality.map
        : (fld.label == FieldDescriptorProto_Label.LABEL_REPEATED
              ? FieldCardinality.repeated
              : FieldCardinality.singular);

    String? oneof = d['oneof'] as String?;

    String? messageTypeName;
    String? enumTypeName;
    String? mapKeyType;
    String? mapValueType;

    if (cardinality == FieldCardinality.map) {
      mapKeyType = d['keyType'] as String?;
      mapValueType = d['valueType'] as String?;
      if (mapValueType == 'TYPE_MESSAGE') {
        messageTypeName = d['valueTypeName'] as String?;
      } else if (mapValueType == 'TYPE_ENUM') {
        // The value enum FQN: indexed from the map-entry message's value field
        // (`fld.typeName` is the entry message FQN, not the enum).
        enumTypeName = _mapValueEnumType[_strip(fld.typeName)];
      }
    } else {
      final isMsg =
          fld.type == FieldDescriptorProto_Type.TYPE_MESSAGE ||
          fld.type == FieldDescriptorProto_Type.TYPE_GROUP;
      final isEnum = fld.type == FieldDescriptorProto_Type.TYPE_ENUM;
      if (isMsg) messageTypeName = _strip(fld.typeName);
      if (isEnum) enumTypeName = _strip(fld.typeName);
    }

    return GenField(
      protoName: fld.name,
      dartName: _escapeIdentifier(toLowerCamel(fld.name)),
      protoType: fld.type.name,
      cardinality: cardinality,
      presence: presence,
      messageTypeName: messageTypeName,
      enumTypeName: enumTypeName,
      mapKeyType: mapKeyType,
      mapValueType: mapValueType,
      oneofName: oneof,
    );
  }

  GenEnum _buildEnum(String fqn, EnumDescriptorProto e) {
    return GenEnum(
      fullName: fqn,
      dartName: _dartNames[fqn]!,
      values: [
        for (final v in e.value)
          GenEnumValue(
            protoName: v.name,
            dartName: _escapeIdentifier(_enumValueToDart(v.name)),
            number: v.number,
          ),
      ],
    );
  }

  String _strip(String fqn) => fqn.startsWith('.') ? fqn.substring(1) : fqn;
}

// ---------------------------------------------------------------------------
// Identifier helpers (shared by emitters via the GenModel — but the
// conversions live here since they shape the model's Dart names).
// ---------------------------------------------------------------------------

/// snake_case (or already-camel) proto name -> lowerCamelCase Dart name.
String toLowerCamel(String name) {
  if (name.isEmpty) return name;
  final parts = name.split('_');
  final buf = StringBuffer();
  var first = true;
  for (final p in parts) {
    if (p.isEmpty) continue;
    if (first) {
      buf.write(p[0].toLowerCase());
      if (p.length > 1) buf.write(p.substring(1));
      first = false;
    } else {
      buf.write(p[0].toUpperCase());
      if (p.length > 1) buf.write(p.substring(1));
    }
  }
  final s = buf.toString();
  return s.isEmpty ? name : s;
}

/// Enum constant proto name (UPPER_SNAKE) -> lowerCamelCase Dart enum constant.
String _enumValueToDart(String name) => toLowerCamel(name.toLowerCase());

/// Dart reserved words that cannot be used as identifiers — suffixed with `_`.
const Set<String> _dartKeywords = {
  'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
  'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do',
  'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external',
  'factory', 'false', 'final', 'finally', 'for', 'function', 'get', 'hide',
  'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
  'mixin', 'new', 'null', 'of', 'on', 'operator', 'part', 'required', 'rethrow',
  'return', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this', 'throw',
  'true', 'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
  // Not reserved but collide with generated members / Object.
  'hashCode', 'runtimeType', 'noSuchMethod', 'toString', 'values', 'index',
};

/// Escapes a Dart [name] that collides with a reserved word or generated
/// member by appending `_`.
String _escapeIdentifier(String name) =>
    _dartKeywords.contains(name) ? '${name}_' : name;
