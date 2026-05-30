/// Descriptor bridge: turns a protoc-emitted `FileDescriptorSet` into the
/// Map-based field descriptors that `ball_protobuf`'s codecs consume, attaching
/// each field's **resolved Editions FeatureSet** (computed by the editions
/// resolver). This is what lets the upstream protobuf conformance runner drive
/// our descriptor-driven, feature-aware codecs against real messages such as
/// `protobuf_test_messages.editions.TestAllTypesEdition2023`.
///
/// Lives in `tool/` (not `lib/`) on purpose: it depends on `ball_base`'s
/// generated `descriptor.pb.dart` (FileDescriptorSet/FileDescriptorProto/...),
/// which is a dev-dependency only — the `lib/` runtime stays dependency-free.
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

  return registry;
}

/// Per-message context: the descriptor + its resolved message-level features.
class _MsgCtx {
  final DescriptorProto msg;
  final FileDescriptorProto file;
  final int edition; // resolver edition sentinel
  final bool isLegacy; // proto2/proto3 (use legacy inference)
  final Map<String, String> resolvedMessageFeatures;
  _MsgCtx(this.msg, this.file, this.edition, this.isLegacy,
      this.resolvedMessageFeatures);
}

void _indexMessage(
  DescriptorProto m,
  String parentFqn,
  FileDescriptorProto file,
  Map<String, _MsgCtx> messages,
  Map<String, EnumDescriptorProto> enums,
) {
  final fqn = '$parentFqn.${m.name}';

  // File edition / syntax → resolver edition + legacy flag.
  final editionName = file.hasEdition() ? file.edition.name : '';
  final bool isLegacy;
  final int ed;
  if (editionName.isNotEmpty && editionName != 'EDITION_UNKNOWN') {
    ed = editionFromString(editionName);
    isLegacy = false;
  } else {
    // proto2/proto3 (or unset == proto2).
    ed = syntaxToEdition(file.hasSyntax() ? file.syntax : '');
    isLegacy = true;
  }

  // Resolve file → message features.
  final Map<String, String> resolvedMessage;
  if (isLegacy) {
    resolvedMessage = baseFeaturesForEdition(ed);
  } else {
    final fileFeat = (file.hasOptions() && file.options.hasFeatures())
        ? _featureOverrides(file.options.features)
        : null;
    final fileResolved = resolveFileFeatures(ed, fileFeat);
    final msgFeat = (m.hasOptions() && m.options.hasFeatures())
        ? _featureOverrides(m.options.features)
        : null;
    resolvedMessage = mergeChildFeatures(ed, fileResolved, msgFeat);
  }

  messages[fqn] = _MsgCtx(m, file, ed, isLegacy, resolvedMessage);

  for (final e in m.enumType) {
    enums['$fqn.${e.name}'] = e;
  }
  for (final nested in m.nestedType) {
    _indexMessage(nested, fqn, file, messages, enums);
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
  final isMessage = fld.type == FieldDescriptorProto_Type.TYPE_MESSAGE ||
      fld.type == FieldDescriptorProto_Type.TYPE_GROUP;
  final isEnum = fld.type == FieldDescriptorProto_Type.TYPE_ENUM;

  // Resolve this field's features (parent = its message; legacy uses inference).
  final features = _resolveFieldFeatures(fld, ctx);

  // Is this a map field? (repeated message whose type is a map_entry.)
  if (fld.label == FieldDescriptorProto_Label.LABEL_REPEATED && isMessage) {
    final entryCtx = messages[typeName];
    if (entryCtx != null && entryCtx.msg.hasOptions() &&
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
      } else if (valF.type == FieldDescriptorProto_Type.TYPE_ENUM) {
        m['enumValues'] = _enumValues(enums[valF.typeName]);
      }
      return m;
    }
  }

  final m = <String, Object?>{
    'name': fld.name,
    'number': fld.number,
    'type': fld.type.name,
    'label': fld.label.name,
    'features': features,
  };
  if (fld.label == FieldDescriptorProto_Label.LABEL_REPEATED) {
    m['repeated'] = true;
  }
  if (typeName.isNotEmpty) m['typeName'] = _strip(typeName);
  if (isMessage) m['messageDescriptor'] = registry[_strip(typeName)];
  if (isEnum) m['enumValues'] = _enumValues(enums[typeName]);
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
  return mergeChildFeatures(ctx.edition, ctx.resolvedMessageFeatures, fieldFeat);
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

Map<int, String> _enumValues(EnumDescriptorProto? e) {
  final m = <int, String>{};
  if (e == null) return m;
  for (final v in e.value) {
    m[v.number] = v.name;
  }
  return m;
}

String _strip(String fqn) => fqn.startsWith('.') ? fqn.substring(1) : fqn;
