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

/// A sibling-file import emitted into a generated `.pb.dart` so that
/// cross-file message/enum references resolve. [path] is the imported file's
/// generated output path (`/`-separated, e.g. `a/a.pb.dart`) expressed relative
/// to the importing file's directory; [prefix] is the stable Dart import prefix
/// (`$import0`, `$import1`, …) the emitter uses to reach that file's
/// cross-file descriptor lookup.
class GenImport {
  /// The `import '...'` target — the sibling's output path, relative to the
  /// importing file's directory.
  final String path;

  /// The stable Dart import prefix (`$import0`, `$import1`, …).
  final String prefix;

  const GenImport({required this.path, required this.prefix});
}

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

  /// Every `extend` field declared in this file (top-level and nested),
  /// in declaration order. Empty when the file declares no extensions.
  final List<GenExtension> extensions;

  /// Sibling `.pb.dart` files this file references (cross-file message/enum
  /// types), each with a stable import prefix. Empty for the self-contained
  /// combined golden (every type lives in one file).
  final List<GenImport> imports;

  /// Referenced-type FQN -> the import prefix of the sibling file that defines
  /// it. A type defined in *this* file is absent (resolved locally). Used by the
  /// emitter to route a cross-file `$descriptorFor` to the right sibling.
  final Map<String, String> crossFilePrefixByFqn;

  GenFile({
    required this.protoPath,
    required this.package,
    required this.messages,
    required this.enums,
    this.extensions = const [],
    this.imports = const [],
    this.crossFilePrefixByFqn = const {},
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

/// A generated protobuf extension (`extend SomeMessage { ... = N; }`).
///
/// On the wire an extension is wire-indistinguishable from a regular field of
/// the same number; the descriptor bridge folds each one into its extendee's
/// field list keyed by the bracketed `[fully.qualified.name]` (so it never
/// aliases a sibling field of the same simple name). This carries the typed-view
/// metadata an emitter needs to produce an `Extension` handle plus
/// `get/set/has/clear` helpers that read/write that bracketed key in the
/// extended message's backing map.
class GenExtension {
  /// Fully-qualified extension name, no leading dot (e.g.
  /// `protobuf_test_messages.proto2.extension_int32`).
  final String fullName;

  /// The lowerCamelCase Dart identifier for this extension's handle/helpers
  /// (keyword-escaped, collision-disambiguated within the file).
  final String dartName;

  /// The extended message's fully-qualified name, no leading dot.
  final String extendeeFullName;

  /// The bracketed storage key under which the runtime stores this extension's
  /// value in the extendee's backing map, e.g. `[acme.user_email]`.
  final String fieldKey;

  /// The extension's field number.
  final int number;

  /// The extension's protobuf type string (e.g. `TYPE_STRING`,
  /// `TYPE_MESSAGE`). Groups are normalized to `TYPE_MESSAGE` by the bridge.
  final String protoType;

  /// For a message-typed extension, the referenced message's FQN (registry
  /// key); null for scalar/enum extensions.
  final String? messageTypeName;

  /// For an enum-typed extension, the referenced enum's FQN; null otherwise.
  final String? enumTypeName;

  /// The bridge-built field descriptor for this extension (the same map that
  /// lives in the extendee's field list), embedded verbatim into the handle.
  final Map<String, Object?> descriptor;

  GenExtension({
    required this.fullName,
    required this.dartName,
    required this.extendeeFullName,
    required this.fieldKey,
    required this.number,
    required this.protoType,
    required this.descriptor,
    this.messageTypeName,
    this.enumTypeName,
  });

  bool get isMessage =>
      protoType == 'TYPE_MESSAGE' || protoType == 'TYPE_GROUP';
  bool get isEnum => protoType == 'TYPE_ENUM';
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

  /// Message/enum FQN (no leading dot) -> the generated output path
  /// (`foo/bar.pb.dart`) of the file that defines it. Drives cross-file import
  /// emission so a reference into a sibling `.pb.dart` resolves.
  final Map<String, String> _outputPathByFqn = {};

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
  ///
  /// Each emitted file is wired with the sibling-file imports it needs so that
  /// a message/enum reference into a *different* generated `.pb.dart` resolves
  /// across files (cross-file `$descriptorFor`).
  List<GenFile> buildFiles(Set<String> filesToGenerate) {
    final out = <GenFile>[];
    for (final file in _fds.file) {
      if (filesToGenerate.isNotEmpty && !filesToGenerate.contains(file.name)) {
        continue;
      }
      out.add(_withCrossFileImports(_buildFile(file)));
    }
    return out;
  }

  /// Returns a copy of [file] whose [GenFile.imports] / [GenFile.crossFilePrefixByFqn]
  /// cover every message/enum type the file references that is defined in a
  /// *different* generated file.
  ///
  /// References come from the file's field descriptors: any field carrying a
  /// `messageDescriptor` names a message FQN (`valueTypeName` for map values,
  /// else `typeName`); enum-typed fields name an enum FQN via `typeName` /
  /// `valueTypeName`. A reference whose defining file differs from this file's
  /// own output path becomes a sibling import with a stable `$importN` prefix.
  GenFile _withCrossFileImports(GenFile file) {
    final ownPath = file.outputPath;
    // Stable order: sort referenced sibling output paths, assign $import0..N.
    final externalPaths = <String>{};
    final prefixByFqn = <String, String>{};
    final externalFqns = <String, String>{}; // fqn -> defining output path

    void note(String? ref) {
      if (ref == null) return;
      final defPath = _outputPathByFqn[ref];
      if (defPath == null || defPath == ownPath) return; // local or unknown
      externalPaths.add(defPath);
      externalFqns[ref] = defPath;
    }

    for (final m in file.messages) {
      // Descriptor-level message references drive the cross-file
      // `$descriptorFor` link (so a sibling message's field list resolves).
      for (final fld in m.descriptor) {
        if (fld['messageDescriptor'] != null || fld['type'] == 'TYPE_MESSAGE') {
          note(
            (fld['valueTypeName'] as String?) ?? (fld['typeName'] as String?),
          );
        }
      }
      // Typed-view references drive the Dart class import (message AND enum,
      // including map values whose enum FQN the descriptor does not carry).
      for (final fld in m.fields) {
        note(fld.messageTypeName);
        note(fld.enumTypeName);
      }
    }
    // Extension handles/helpers reference the extendee message and, for message/
    // enum-typed extensions, the embedded value type — any of which may live in
    // a sibling file.
    for (final ext in file.extensions) {
      note(ext.extendeeFullName);
      note(ext.messageTypeName);
      note(ext.enumTypeName);
    }

    final sortedPaths = externalPaths.toList()..sort();
    final prefixByPath = <String, String>{};
    final imports = <GenImport>[];
    for (var i = 0; i < sortedPaths.length; i++) {
      final prefix = '\$import$i';
      prefixByPath[sortedPaths[i]] = prefix;
      imports.add(
        GenImport(
          path: _relativeImport(ownPath, sortedPaths[i]),
          prefix: prefix,
        ),
      );
    }
    for (final entry in externalFqns.entries) {
      prefixByFqn[entry.key] = prefixByPath[entry.value]!;
    }

    return GenFile(
      protoPath: file.protoPath,
      package: file.package,
      messages: file.messages,
      enums: file.enums,
      extensions: file.extensions,
      imports: imports,
      crossFilePrefixByFqn: prefixByFqn,
    );
  }

  /// Builds a relative `import` path from [fromOutputPath] to [toOutputPath]
  /// (both `/`-separated generated paths). Sibling files in the same directory
  /// import by bare filename; otherwise a `../`-prefixed relative path is used.
  static String _relativeImport(String fromOutputPath, String toOutputPath) {
    final fromParts = fromOutputPath.split('/');
    final toParts = toOutputPath.split('/');
    // Drop the file name from the importer's path to get its directory.
    final fromDir = fromParts.sublist(0, fromParts.length - 1);
    // Common prefix of the directories.
    final toDir = toParts.sublist(0, toParts.length - 1);
    var common = 0;
    while (common < fromDir.length &&
        common < toDir.length &&
        fromDir[common] == toDir[common]) {
      common++;
    }
    final ups = List.filled(fromDir.length - common, '..');
    final downs = toParts.sublist(common);
    final rel = [...ups, ...downs].join('/');
    return rel.isEmpty ? toParts.last : rel;
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
    final extensions = <GenExtension>[];
    for (final file in _fds.file) {
      final f = _buildFile(file);
      messages.addAll(f.messages);
      enums.addAll(f.enums);
      extensions.addAll(f.extensions);
    }
    return GenFile(
      protoPath: outputPath,
      package: '',
      messages: messages,
      enums: enums,
      extensions: extensions,
    );
  }

  // -------------------------------------------------------------------------
  // Name indexing (pass 0): assign a flat Dart name to every message + enum.
  // -------------------------------------------------------------------------

  void _indexNames() {
    for (final file in _fds.file) {
      final out = _outputPathOf(file.name);
      final pkgPrefix = file.package.isEmpty ? '' : '${file.package}.';
      for (final m in file.messageType) {
        _indexMessageNames(m, pkgPrefix, '', out);
      }
      for (final e in file.enumType) {
        final fqn = '$pkgPrefix${e.name}';
        _enums[fqn] = e;
        _dartNames[fqn] = e.name;
        _outputPathByFqn[fqn] = out;
      }
    }
  }

  /// `foo/bar.proto` -> `foo/bar.pb.dart` (the file's generated output path).
  static String _outputPathOf(String protoPath) {
    final base = protoPath.endsWith('.proto')
        ? protoPath.substring(0, protoPath.length - '.proto'.length)
        : protoPath;
    return '$base.pb.dart';
  }

  void _indexMessageNames(
    DescriptorProto m,
    String pkgPrefix,
    String parentDart,
    String outputPath,
  ) {
    final fqn = '$pkgPrefix${m.name}';
    final dart = parentDart.isEmpty ? m.name : '${parentDart}_${m.name}';
    _dartNames[fqn] = dart;
    _outputPathByFqn[fqn] = outputPath;
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
      _outputPathByFqn[efqn] = outputPath;
    }
    for (final n in m.nestedType) {
      _indexMessageNames(n, '$fqn.', dart, outputPath);
    }
  }

  // -------------------------------------------------------------------------
  // File / message / enum construction.
  // -------------------------------------------------------------------------

  GenFile _buildFile(FileDescriptorProto file) {
    final pkgPrefix = file.package.isEmpty ? '' : '${file.package}.';
    final messages = <GenMessage>[];
    final enums = <GenEnum>[];
    final extensions = <GenExtension>[];

    for (final m in file.messageType) {
      _collectMessage(m, pkgPrefix, messages, enums);
    }
    for (final e in file.enumType) {
      enums.add(_buildEnum('$pkgPrefix${e.name}', e));
    }
    // Extensions: file-level `extend` blocks (scoped to the package) plus any
    // declared inside a message (scoped to that message's FQN).
    final scope = file.package;
    for (final ext in file.extension) {
      final g = _buildExtension(ext, scope);
      if (g != null) extensions.add(g);
    }
    for (final m in file.messageType) {
      _collectExtensions(m, pkgPrefix.isEmpty ? '' : file.package, extensions);
    }

    return GenFile(
      protoPath: file.name,
      package: file.package,
      messages: messages,
      enums: enums,
      extensions: extensions,
    );
  }

  /// Recurses into nested message types, collecting each message's locally
  /// scoped `extend` blocks (whose lexical scope is the containing message FQN).
  void _collectExtensions(
    DescriptorProto m,
    String parentScope,
    List<GenExtension> out,
  ) {
    final fqn = parentScope.isEmpty ? m.name : '$parentScope.${m.name}';
    for (final ext in m.extension) {
      final g = _buildExtension(ext, fqn);
      if (g != null) out.add(g);
    }
    for (final n in m.nestedType) {
      _collectExtensions(n, fqn, out);
    }
  }

  /// Builds a [GenExtension] for [ext] declared in lexical [scope] (the package
  /// for a file-level `extend`, or the containing message FQN for a nested one).
  ///
  /// The bridge already folded this extension into the extendee's registry list
  /// keyed by the bracketed `[fqn]`; we look that descriptor up so the handle
  /// embeds the exact same map the runtime marshals against. An extension whose
  /// extendee is not in the registry (out of scope) is skipped.
  GenExtension? _buildExtension(FieldDescriptorProto ext, String scope) {
    final extendee = _strip(ext.extendee);
    final extendeeFields = _registry[extendee];
    if (extendeeFields == null) return null;
    final fullName = scope.isEmpty ? ext.name : '$scope.${ext.name}';
    final fieldKey = '[$fullName]';
    // Find the bridge's folded-in descriptor entry by its `[fqn]` key.
    Map<String, Object?>? descriptor;
    for (final d in extendeeFields) {
      if (d['name'] == fieldKey && d['number'] == ext.number) {
        descriptor = d;
        break;
      }
    }
    // The bridge did not fold this extension in (extendee out of scope).
    if (descriptor == null) return null;

    final isMsg =
        ext.type == FieldDescriptorProto_Type.TYPE_MESSAGE ||
        ext.type == FieldDescriptorProto_Type.TYPE_GROUP;
    final isEnum = ext.type == FieldDescriptorProto_Type.TYPE_ENUM;

    return GenExtension(
      fullName: fullName,
      dartName: _extensionDartName(fullName),
      extendeeFullName: extendee,
      fieldKey: fieldKey,
      number: ext.number,
      // Mirror the bridge: groups are normalized to TYPE_MESSAGE.
      protoType: isMsg ? 'TYPE_MESSAGE' : ext.type.name,
      descriptor: descriptor,
      messageTypeName: isMsg ? _strip(ext.typeName) : null,
      enumTypeName: isEnum ? _strip(ext.typeName) : null,
    );
  }

  /// A unique lowerCamelCase Dart identifier for an extension handle/helpers.
  /// Built from the extension's FQN tail so two extensions named the same simple
  /// name in different scopes (e.g. nested `message_set_extension`) don't clash.
  final Set<String> _usedExtensionNames = {};
  String _extensionDartName(String fullName) {
    final base = _escapeIdentifier(toLowerCamel(fullName.split('.').last));
    var name = base;
    var i = 2;
    while (_usedExtensionNames.contains(name)) {
      name = '$base$i';
      i++;
    }
    _usedExtensionNames.add(name);
    return name;
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
