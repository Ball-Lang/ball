/// Descriptor bridge: turns a protoc-emitted `FileDescriptorSet` into the
/// Map-based field descriptors that `ball_protobuf`'s codecs consume, attaching
/// each field's **resolved Editions FeatureSet** (computed by the editions
/// resolver). This is what lets the upstream protobuf conformance runner drive
/// our descriptor-driven, feature-aware codecs against real messages such as
/// `protobuf_test_messages.editions.TestAllTypesEdition2023`.
///
/// Lives in `ball_protobuf_gen` (not the `ball_protobuf` runtime `lib/`) on
/// purpose: it depends on `ball_base`'s generated `descriptor.pb.dart`
/// (FileDescriptorSet/FileDescriptorProto/...), so it is not Ball-portable —
/// while the `ball_protobuf` `lib/` runtime stays dependency-free. The green
/// conformance harness keeps its own copy under `ball_protobuf/tool/`.
///
/// ## Intentional fork — see `dart/ball_protobuf/tool/descriptor_bridge.dart`
///
/// This file is an **intentional fork** of
/// `dart/ball_protobuf/tool/descriptor_bridge.dart`. The two CANNOT share one
/// copy: the conformance copy lives in `ball_protobuf`'s own `tool/` (so the
/// runtime package has no dependency on `ball_protobuf_gen`), while this copy
/// lives in `ball_protobuf_gen` (which depends on `ball_protobuf`). A single
/// shared copy would require one package to depend on the other in both
/// directions — a dependency cycle — so the fork is deliberate.
///
/// There are TWO intentional behavioral differences between the copies:
///   1. **Group handling.** This (gen) copy normalizes `TYPE_GROUP` ->
///      `TYPE_MESSAGE` (a group is a DELIMITED-encoded message — the
///      editions-canonical form; see `_buildField` below and `marshal.dart`'s
///      `wireTypeForFieldType`), so generated typed views emit a single
///      message-shaped accessor. The conformance copy keeps bare `TYPE_GROUP`
///      because the upstream runner is pinned at 2769/2769 with that
///      representation; changing it there would risk that pinned result.
///   2. **Extension JSON name.** This copy overrides a folded extension's
///      `jsonName` to the bracketed `[fully.qualified.name]` (the canonical
///      proto3-JSON key for an extension), so generated models round-trip
///      extensions through JSON. The conformance copy leaves protoc's
///      camelCased simple `json_name` untouched.
/// Keep the two in sync for everything EXCEPT these two divergences.
library;

import 'package:ball_base/ball_base.dart'
    show
        DescriptorProto,
        EnumDescriptorProto,
        FeatureSet,
        FieldDescriptorProto,
        FieldDescriptorProto_Label,
        FieldDescriptorProto_Type,
        FileDescriptorProto,
        FileDescriptorSet;
import 'package:ball_protobuf/ball_protobuf.dart';

/// Message FQN (no leading dot) → its resolved field-descriptor list.
typedef DescriptorRegistry = Map<String, List<Map<String, Object?>>>;

/// Builds a [DescriptorRegistry] from a binary `FileDescriptorSet`.
///
/// Every message type across every file (including nested types) is indexed by
/// its fully-qualified name. Message/enum/map cross-references resolve to the
/// shared registry lists, so recursive types (`recursive_message`,
/// `NestedMessage.corecursive`) work without infinite expansion.
DescriptorRegistry buildRegistry(List<int> fdsBytes) {
  final fds = FileDescriptorSet.fromBuffer(fdsBytes);

  // Pass 0: index every message + enum by FQN, and remember each message's
  // owning file (for edition/syntax + file-level features) and its lexical
  // parent feature context.
  final messages = <String, _MsgCtx>{};
  final enums = <String, EnumDescriptorProto>{};
  for (final file in fds.file) {
    final pkg = file.package;
    for (final m in file.messageType) {
      _indexMessage(m, pkg.isEmpty ? '' : '.$pkg', file, messages, enums);
    }
    for (final e in file.enumType) {
      enums['${pkg.isEmpty ? '' : '.$pkg'}.${e.name}'] = e;
    }
  }

  // Pass 1: create an empty list per message FQN (placeholders for cycles).
  final registry = <String, List<Map<String, Object?>>>{};
  for (final fqn in messages.keys) {
    registry[fqn.startsWith('.') ? fqn.substring(1) : fqn] =
        <Map<String, Object?>>[];
  }

  // Pass 2: populate each message's field descriptors.
  for (final entry in messages.entries) {
    final fqn = entry.key;
    final ctx = entry.value;
    final fields = registry[fqn.startsWith('.') ? fqn.substring(1) : fqn]!;
    for (final fld in ctx.msg.field) {
      // Skip fields that are members of a *real* (non-synthetic) oneof? No —
      // oneof members are still regular wire fields; only the resolution parent
      // differs. Synthetic proto3-optional oneofs are not relevant for editions.
      fields.add(_buildField(fld, ctx, messages, enums, registry));
    }
  }

  // Pass 3: extensions. An extension field is wire-indistinguishable from a
  // regular field of the same number, so we append each to its extendee
  // message's field list (resolved against the extension's lexical scope: the
  // file for top-level `extend`, or the containing message for a nested one).
  // This is what lets conformance round-trip extension fields such as the
  // group-encoded `groupliketype`/`delimited_ext` and `extension_bytes`.
  for (final file in fds.file) {
    final scope = _fileScope(file);
    final pkgFqn = file.package.isEmpty ? '' : '.${file.package}';
    for (final ext in file.extension) {
      _appendExtension(
        ext,
        file,
        scope.ed,
        scope.isLegacy,
        scope.fileResolved,
        file.package,
        messages,
        enums,
        registry,
      );
    }
    for (final m in file.messageType) {
      _indexNestedExtensions(m, pkgFqn, messages, enums, registry);
    }
  }

  return registry;
}

/// Per-message context: the descriptor + its resolved message-level features.
class _MsgCtx {
  final DescriptorProto msg;
  final FileDescriptorProto file;
  final int edition; // resolver edition sentinel
  final bool isLegacy; // proto2/proto3 (use legacy inference)
  final Map<String, String> resolvedMessageFeatures;
  _MsgCtx(
    this.msg,
    this.file,
    this.edition,
    this.isLegacy,
    this.resolvedMessageFeatures,
  );
}

void _indexMessage(
  DescriptorProto m,
  String parentFqn,
  FileDescriptorProto file,
  Map<String, _MsgCtx> messages,
  Map<String, EnumDescriptorProto> enums,
) {
  final fqn = '$parentFqn.${m.name}';

  // File edition / syntax → resolver edition + legacy flag + base features.
  final scope = _fileScope(file);

  // Resolve file → message features.
  final Map<String, String> resolvedMessage;
  if (scope.isLegacy) {
    resolvedMessage = scope.fileResolved;
  } else {
    final msgFeat = (m.hasOptions() && m.options.hasFeatures())
        ? _featureOverrides(m.options.features)
        : null;
    resolvedMessage = mergeChildFeatures(scope.ed, scope.fileResolved, msgFeat);
  }

  messages[fqn] = _MsgCtx(m, file, scope.ed, scope.isLegacy, resolvedMessage);

  for (final e in m.enumType) {
    enums['$fqn.${e.name}'] = e;
  }
  for (final nested in m.nestedType) {
    _indexMessage(nested, fqn, file, messages, enums);
  }
}

/// A file's resolver edition, legacy flag, and resolved file-level features —
/// the shared parent scope for both messages and top-level extensions.
typedef _FileScope = ({
  int ed,
  bool isLegacy,
  Map<String, String> fileResolved,
});

_FileScope _fileScope(FileDescriptorProto file) {
  final editionName = file.hasEdition() ? file.edition.name : '';
  if (editionName.isNotEmpty && editionName != 'EDITION_UNKNOWN') {
    final ed = editionFromString(editionName);
    final fileFeat = (file.hasOptions() && file.options.hasFeatures())
        ? _featureOverrides(file.options.features)
        : null;
    return (
      ed: ed,
      isLegacy: false,
      fileResolved: resolveFileFeatures(ed, fileFeat),
    );
  }
  // proto2/proto3 (or unset == proto2): legacy inference, base = edition base.
  final ed = syntaxToEdition(file.hasSyntax() ? file.syntax : '');
  return (ed: ed, isLegacy: true, fileResolved: baseFeaturesForEdition(ed));
}

/// Appends a single extension [ext] to its extendee message's field list (if
/// that message is in the registry). [parentFeatures] is the resolved feature
/// set of the extension's lexical scope (file, or containing message). On the
/// wire an extension is just a numbered field, so the codecs treat it like any
/// other once it lives in the extendee's descriptor.
void _appendExtension(
  FieldDescriptorProto ext,
  FileDescriptorProto file,
  int ed,
  bool isLegacy,
  Map<String, String> parentFeatures,
  String scopeFqn,
  Map<String, _MsgCtx> messages,
  Map<String, EnumDescriptorProto> enums,
  DescriptorRegistry registry,
) {
  final extendee = _strip(ext.extendee);
  final fields = registry[extendee];
  if (fields == null) return; // extendee not in this registry — skip.
  // Safe to pass an empty placeholder message: the only `ctx.msg` use in
  // _buildField is the oneof branch (reads ctx.msg.oneofDecl), and an extension
  // field never has hasOneofIndex() true, so that branch is unreachable here.
  // Everything else _buildField needs comes from the edition/feature scope.
  // Enforce that invariant loudly (#142): if some future path ever produces an
  // extension carrying a oneof_index, fail here instead of letting _buildField
  // index into the placeholder's empty oneofDecl (crash or silently-wrong
  // descriptor).
  if (ext.hasOneofIndex()) {
    throw StateError(
      'extension ${ext.name} on $extendee unexpectedly carries '
      'oneof_index ${ext.oneofIndex}; the placeholder _MsgCtx cannot '
      'resolve oneofs',
    );
  }
  final ctx = _MsgCtx(DescriptorProto(), file, ed, isLegacy, parentFeatures);
  final f = _buildField(ext, ctx, messages, enums, registry);
  // Store under the canonical `[fully.qualified.name]` key. Extensions live in
  // a separate namespace from regular fields, so an extension may reuse a
  // sibling field's simple name (e.g. both field 201 and extension 121 are
  // named `groupliketype`). Keying by simple name would alias the two; the
  // bracketed FQN is both collision-free and the correct protobuf-JSON key.
  final fullName = scopeFqn.isEmpty ? ext.name : '$scopeFqn.${ext.name}';
  final key = '[$fullName]';
  f['name'] = key;
  // The canonical proto3-JSON key for an extension is the same bracketed
  // `[fully.qualified.name]`, NOT the camelCased simple name protoc records in
  // `json_name`. `_buildField` copied that simple `json_name`; override it so
  // the JSON codec emits (and accepts) the bracketed form and the generated
  // typed view's JSON round-trips exactly. (This gen-copy divergence does not
  // touch the pinned conformance copy under `ball_protobuf/tool/`.)
  f['jsonName'] = key;
  fields.add(f);
}

/// Recurses into nested message types, appending each message's locally-scoped
/// `extend` blocks to their extendees. The parent feature scope for a nested
/// extension is the containing message's resolved features.
void _indexNestedExtensions(
  DescriptorProto m,
  String parentFqn,
  Map<String, _MsgCtx> messages,
  Map<String, EnumDescriptorProto> enums,
  DescriptorRegistry registry,
) {
  final fqn = '$parentFqn.${m.name}';
  final ctx = messages[fqn];
  if (ctx != null) {
    for (final ext in m.extension) {
      _appendExtension(
        ext,
        ctx.file,
        ctx.edition,
        ctx.isLegacy,
        ctx.resolvedMessageFeatures,
        _strip(fqn),
        messages,
        enums,
        registry,
      );
    }
  }
  for (final nested in m.nestedType) {
    _indexNestedExtensions(nested, fqn, messages, enums, registry);
  }
}

Map<String, Object?> _buildField(
  FieldDescriptorProto fld,
  _MsgCtx ctx,
  Map<String, _MsgCtx> messages,
  Map<String, EnumDescriptorProto> enums,
  DescriptorRegistry registry,
) {
  final typeName = fld.typeName; // leading-dot FQN for message/enum
  final isMessage =
      fld.type == FieldDescriptorProto_Type.TYPE_MESSAGE ||
      fld.type == FieldDescriptorProto_Type.TYPE_GROUP;
  final isEnum = fld.type == FieldDescriptorProto_Type.TYPE_ENUM;

  // Resolve this field's features (parent = its message; legacy uses inference).
  final features = _resolveFieldFeatures(fld, ctx);

  // Is this a map field? (repeated message whose type is a map_entry.)
  if (fld.label == FieldDescriptorProto_Label.LABEL_REPEATED && isMessage) {
    final entryCtx = messages[typeName];
    if (entryCtx != null &&
        entryCtx.msg.hasOptions() &&
        entryCtx.msg.options.mapEntry) {
      final keyF = entryCtx.msg.field[0];
      final valF = entryCtx.msg.field[1];
      final m = <String, Object?>{
        'name': fld.name,
        'number': fld.number,
        'type': 'TYPE_MESSAGE',
        'label': 'LABEL_REPEATED',
        'repeated': true,
        'mapEntry': true,
        'keyType': keyF.type.name,
        'valueType': valF.type.name,
        'features': features,
      };
      if (valF.type == FieldDescriptorProto_Type.TYPE_MESSAGE) {
        m['messageDescriptor'] = registry[_strip(valF.typeName)];
        m['valueTypeName'] = _strip(valF.typeName);
      } else if (valF.type == FieldDescriptorProto_Type.TYPE_ENUM) {
        m['enumValues'] = _enumValues(enums[valF.typeName]);
        m['enumNames'] = _enumNames(enums[valF.typeName]);
      }
      return m;
    }
  }

  // Normalize TYPE_GROUP to TYPE_MESSAGE. On the wire a group is just a
  // DELIMITED-encoded message; the runtime codecs only key on TYPE_MESSAGE +
  // the resolved `message_encoding = DELIMITED` feature (which the editions
  // resolver / legacy inference already sets for groups). Emitting the bare
  // 'TYPE_GROUP' string instead makes marshalField throw ("Unknown protobuf
  // field type") and makes unmarshal mis-skip the field as an unknown group,
  // so the typed group accessor would not round-trip.
  final m = <String, Object?>{
    'name': fld.name,
    'number': fld.number,
    'type': isMessage ? 'TYPE_MESSAGE' : fld.type.name,
    'label': fld.label.name,
    'features': features,
  };
  if (fld.label == FieldDescriptorProto_Label.LABEL_REPEATED) {
    m['repeated'] = true;
  }
  if (typeName.isNotEmpty) m['typeName'] = _strip(typeName);
  if (isMessage) m['messageDescriptor'] = registry[_strip(typeName)];
  if (isEnum) {
    m['enumValues'] = _enumValues(enums[typeName]);
    m['enumNames'] = _enumNames(enums[typeName]);
  }
  // protoc's JSON name (lowerCamelCase by default, or an explicit json_name).
  // Used as the JSON output key; the codec also accepts the proto field name.
  if (fld.jsonName.isNotEmpty) m['jsonName'] = fld.jsonName;
  // Real (non-synthetic) oneof membership. A proto3 `optional` field is placed
  // in its own synthetic single-member oneof — that is NOT a real oneof, so we
  // skip it. Members of a real oneof carry the oneof's name so the codecs can
  // clear siblings on decode and always serialize a set member.
  if (fld.hasOneofIndex() &&
      !fld.proto3Optional &&
      fld.oneofIndex < ctx.msg.oneofDecl.length) {
    m['oneof'] = ctx.msg.oneofDecl[fld.oneofIndex].name;
  }
  return m;
}

/// The resolved 6-key FeatureSet for [fld] within message [ctx].
Map<String, String> _resolveFieldFeatures(
  FieldDescriptorProto fld,
  _MsgCtx ctx,
) {
  if (ctx.isLegacy) {
    // proto2/proto3: base (already in resolvedMessageFeatures) overlaid with
    // inferred field-shape features (LEGACY_REQUIRED / IMPLICIT / DELIMITED /
    // packed) — a direct overlay, bypassing FIXED-feature rejection.
    final packed = (fld.hasOptions() && fld.options.hasPacked())
        ? (fld.options.packed ? 'true' : 'false')
        : null;
    final inferred = inferLegacyFieldFeatures(
      fld.label.name,
      fld.type.name,
      fld.proto3Optional,
      packed,
      ctx.edition,
    );
    final out = <String, String>{}
      ..addAll(ctx.resolvedMessageFeatures)
      ..addAll(inferred);
    return out;
  }
  // Editions: parent (message; oneof options are rare and skipped here) merged
  // with this field's explicit options.features.
  final fieldFeat = (fld.hasOptions() && fld.options.hasFeatures())
      ? _featureOverrides(fld.options.features)
      : null;
  return mergeChildFeatures(
    ctx.edition,
    ctx.resolvedMessageFeatures,
    fieldFeat,
  );
}

/// Extracts the *set* fields of a [FeatureSet] as `{feature_key: VALUE}` (the
/// override subset the resolver applies on top of the edition base).
Map<String, Object?> _featureOverrides(FeatureSet fs) {
  final m = <String, Object?>{};
  if (fs.hasFieldPresence()) m[featureFieldPresence] = fs.fieldPresence.name;
  if (fs.hasEnumType()) m[featureEnumType] = fs.enumType.name;
  if (fs.hasRepeatedFieldEncoding()) {
    m[featureRepeatedFieldEncoding] = fs.repeatedFieldEncoding.name;
  }
  if (fs.hasUtf8Validation()) m[featureUtf8Validation] = fs.utf8Validation.name;
  if (fs.hasMessageEncoding()) {
    m[featureMessageEncoding] = fs.messageEncoding.name;
  }
  if (fs.hasJsonFormat()) m[featureJsonFormat] = fs.jsonFormat.name;
  return m;
}

/// Number -> canonical name. With `allow_alias`, several names share a number;
/// the FIRST declared name is canonical (used for JSON output).
Map<int, String> _enumValues(EnumDescriptorProto? e) {
  final m = <int, String>{};
  if (e == null) return m;
  for (final v in e.value) {
    m.putIfAbsent(v.number, () => v.name);
  }
  return m;
}

/// Every enum name -> its number, including `allow_alias` aliases. Used to
/// accept any alias spelling on JSON input.
Map<String, int> _enumNames(EnumDescriptorProto? e) {
  final m = <String, int>{};
  if (e == null) return m;
  for (final v in e.value) {
    m[v.name] = v.number;
  }
  return m;
}

String _strip(String fqn) => fqn.startsWith('.') ? fqn.substring(1) : fqn;
