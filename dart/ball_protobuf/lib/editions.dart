/// Protobuf Editions feature resolution.
///
/// Protobuf Editions (starting from Edition 2023) replace the `syntax`
/// keyword with per-feature defaults that can be overridden at file,
/// message, or field level. This module implements the canonical feature
/// model + resolution algorithm (matching protoc's `feature_resolver.cc`),
/// plus proto2/proto3 → editions legacy inference.
///
/// Ball-portable: top-level functions over plain `Map`/`List`/`String`/`int`
/// data, so it encodes into the `ball_protobuf` module and runs on every
/// target engine.
///
/// The edition-defaults table below is the ground truth emitted by
/// `protoc --edition_defaults_out` (see tests/editions/golden/). Refresh it
/// from protoc when upgrading; CI guards against drift.
///
/// References:
///   - https://protobuf.dev/editions/features/
///   - https://protobuf.dev/editions/overview/
///   - google/protobuf/descriptor.proto (FeatureSet, FeatureSetDefaults)
library;

import 'edition.dart';

// ---------------------------------------------------------------------------
// Feature value constants
// ---------------------------------------------------------------------------

/// Field presence: the field is implicitly present (proto3 default for
/// scalar fields — no `has*` method, default value is not serialized).
const String fieldPresenceImplicit = 'IMPLICIT';

/// Field presence: the field has explicit presence tracking (proto2 default
/// for singular fields, proto3 `optional` fields).
const String fieldPresenceExplicit = 'EXPLICIT';

/// Field presence: legacy required semantics (proto2 `required`).
const String fieldPresenceLegacyRequired = 'LEGACY_REQUIRED';

/// Enum type: open — unknown enum values are preserved as their integer
/// value (proto3 default).
const String enumTypeOpen = 'OPEN';

/// Enum type: closed — unknown enum values are treated as the unknown
/// field set (proto2 default).
const String enumTypeClosed = 'CLOSED';

/// Repeated field encoding: packed — scalar repeated fields are encoded
/// as a single length-delimited blob (proto3 default).
const String repeatedFieldEncodingPacked = 'PACKED';

/// Repeated field encoding: expanded — each repeated element gets its own
/// tag-value pair (proto2 default).
const String repeatedFieldEncodingExpanded = 'EXPANDED';

/// UTF-8 validation: verify — string fields must contain valid UTF-8
/// (proto3 default).
const String utf8ValidationVerify = 'VERIFY';

/// UTF-8 validation: none — no validation is performed (proto2 default).
const String utf8ValidationNone = 'NONE';

/// Message encoding: length-prefixed (default for all editions).
const String messageEncodingLengthPrefixed = 'LENGTH_PREFIXED';

/// Message encoding: delimited (group-style encoding).
const String messageEncodingDelimited = 'DELIMITED';

/// JSON format: allow — standard Proto3 JSON.
const String jsonFormatAllow = 'ALLOW';

/// JSON format: legacy best effort — relaxed parsing for compatibility.
const String jsonFormatLegacyBestEffort = 'LEGACY_BEST_EFFORT';

// ---------------------------------------------------------------------------
// Feature keys (proto field names of google.protobuf.FeatureSet)
// ---------------------------------------------------------------------------

const String featureFieldPresence = 'field_presence';
const String featureEnumType = 'enum_type';
const String featureRepeatedFieldEncoding = 'repeated_field_encoding';
const String featureUtf8Validation = 'utf8_validation';
const String featureMessageEncoding = 'message_encoding';
const String featureJsonFormat = 'json_format';

/// All six runtime FeatureSet keys, in descriptor.proto field order.
List<String> featureKeys() => [
  featureFieldPresence,
  featureEnumType,
  featureRepeatedFieldEncoding,
  featureUtf8Validation,
  featureMessageEncoding,
  featureJsonFormat,
];

// ---------------------------------------------------------------------------
// Edition defaults table
// ---------------------------------------------------------------------------
//
// Ground truth from `protoc --edition_defaults_out` (protoc 28.2; see
// tests/editions/golden/featureset_defaults.txtpb). Each entry carries the
// `overridable` and `fixed` feature maps for one edition floor; an edition
// resolves to the highest entry whose `edition` is <= it. A feature present in
// `fixed` cannot be overridden by a file/message/field `features` option.
//
// LEGACY and PROTO3 hold all six features as FIXED (proto2/proto3 files cannot
// use `features`). EDITION_2023 holds all six as OVERRIDABLE. EDITION_2024
// mirrors 2023's six runtime features — edition 2024 only adds
// source-retention features (naming style, symbol visibility) that the runtime
// ignores. Validated against real protoc (35.1, which supports editions
// through 2024) in dart/ball_protobuf/test/editions_test.dart — the golden
// FeatureSetDefaults confirms EDITION_2024's runtime-relevant feature values
// are byte-for-byte identical to EDITION_2023's, matching this table.

List<Map<String, Object?>> _defaultsTable() {
  final legacyFixed = <String, String>{};
  legacyFixed[featureFieldPresence] = fieldPresenceExplicit;
  legacyFixed[featureEnumType] = enumTypeClosed;
  legacyFixed[featureRepeatedFieldEncoding] = repeatedFieldEncodingExpanded;
  legacyFixed[featureUtf8Validation] = utf8ValidationNone;
  legacyFixed[featureMessageEncoding] = messageEncodingLengthPrefixed;
  legacyFixed[featureJsonFormat] = jsonFormatLegacyBestEffort;

  final proto3Fixed = <String, String>{};
  proto3Fixed[featureFieldPresence] = fieldPresenceImplicit;
  proto3Fixed[featureEnumType] = enumTypeOpen;
  proto3Fixed[featureRepeatedFieldEncoding] = repeatedFieldEncodingPacked;
  proto3Fixed[featureUtf8Validation] = utf8ValidationVerify;
  proto3Fixed[featureMessageEncoding] = messageEncodingLengthPrefixed;
  proto3Fixed[featureJsonFormat] = jsonFormatAllow;

  final edition2023Overridable = <String, String>{};
  edition2023Overridable[featureFieldPresence] = fieldPresenceExplicit;
  edition2023Overridable[featureEnumType] = enumTypeOpen;
  edition2023Overridable[featureRepeatedFieldEncoding] =
      repeatedFieldEncodingPacked;
  edition2023Overridable[featureUtf8Validation] = utf8ValidationVerify;
  edition2023Overridable[featureMessageEncoding] =
      messageEncodingLengthPrefixed;
  edition2023Overridable[featureJsonFormat] = jsonFormatAllow;

  // 2024 runtime features identical to 2023.
  final edition2024Overridable = <String, String>{};
  _putAll(edition2024Overridable, edition2023Overridable);

  final table = <Map<String, Object?>>[];
  table.add({
    'edition': editionLegacy,
    'overridable': <String, String>{},
    'fixed': legacyFixed,
  });
  table.add({
    'edition': editionProto3,
    'overridable': <String, String>{},
    'fixed': proto3Fixed,
  });
  table.add({
    'edition': edition2023,
    'overridable': edition2023Overridable,
    'fixed': <String, String>{},
  });
  table.add({
    'edition': edition2024,
    'overridable': edition2024Overridable,
    'fixed': <String, String>{},
  });
  return table;
}

/// Lowest edition the defaults table covers (proto2 resolves via the LEGACY
/// floor entry).
const int minimumEdition = editionProto2;

/// Highest edition this engine supports.
const int maximumEdition = edition2024;

/// Returns the defaults-table entry governing [edition] — the highest entry
/// whose `edition` is `<=` [edition]. Returns the LEGACY entry for editions
/// below the table.
Map<String, Object?> _defaultsEntryFor(int edition) {
  final table = _defaultsTable();
  Map<String, Object?> best = table[0];
  for (final entry in table) {
    final e = entry['edition'] as int;
    if (e <= edition) {
      best = entry;
    }
  }
  return best;
}

/// Validates that [edition] is within the supported `[minimumEdition,
/// maximumEdition]` range (the test-only [editionUnstable] is allowed above the
/// max). Throws [ArgumentError] otherwise.
void validateEditionInRange(int edition) {
  if (edition == editionUnstable) return;
  if (edition < minimumEdition || edition > maximumEdition) {
    throw ArgumentError(
      'Edition ${editionToName(edition)} ($edition) is outside the supported '
      'range [${editionToName(minimumEdition)}, ${editionToName(maximumEdition)}]',
    );
  }
}

/// Returns the fully-resolved BASE FeatureSet for [edition] before any
/// file/message/field overrides: the entry's `overridable` features merged
/// with its `fixed` features (fixed wins on conflict). For every supported
/// edition this yields all six runtime features.
Map<String, String> baseFeaturesForEdition(int edition) {
  final entry = _defaultsEntryFor(edition);
  final result = <String, String>{};
  final overridable = entry['overridable'] as Map<String, String>;
  final fixed = entry['fixed'] as Map<String, String>;
  _putAll(result, overridable);
  _putAll(result, fixed);
  return result;
}

/// Whether [featureKey] is FIXED (non-overridable) at [edition] — i.e. setting
/// it via a `features` option is a hard error.
bool isFixedFeature(int edition, String featureKey) {
  final entry = _defaultsEntryFor(edition);
  final fixed = entry['fixed'] as Map<String, String>;
  return fixed.containsKey(featureKey);
}

// ---------------------------------------------------------------------------
// Feature resolution (matches protoc feature_resolver.cc)
// ---------------------------------------------------------------------------

/// Resolves the file-level FeatureSet for [edition] with the file's explicit
/// `features` overrides applied on top of the edition base.
///
/// [fileFeatures] is the file's `options.features` (a subset of the six keys,
/// string-valued); `null`/absent leaves the base unchanged. Overriding a
/// feature that is FIXED at [edition] throws [ArgumentError].
Map<String, String> resolveFileFeatures(
  int edition,
  Map<String, Object?>? fileFeatures,
) {
  validateEditionInRange(edition);
  final base = baseFeaturesForEdition(edition);
  _applyOverrides(base, fileFeatures, edition);
  return base;
}

/// Merges [overrides] onto a copy of [base] using protobuf `MergeFrom`
/// semantics: a present override key replaces the base value; an absent feature
/// keeps the base value (later-set-wins, unset-leaves-prior). [base] is not
/// mutated — a new map is returned.
///
/// Setting a feature that is FIXED at [edition] is a hard error (matches
/// protoc, which rejects overriding a non-overridable feature). This is the
/// single MergeFrom primitive shared by file- and child-level resolution.
Map<String, String> mergeFeatureSet(
  Map<String, String> base,
  Map<String, Object?>? overrides,
  int edition,
) {
  final result = <String, String>{};
  _putAll(result, base);
  _applyOverrides(result, overrides, edition);
  return result;
}

/// Resolves a child descriptor's FeatureSet: starts from the parent's
/// already-fully-resolved features and applies this descriptor's explicit
/// `features` overrides on top.
///
/// This is the non-file rule from feature_resolver.cc — used for
/// message/field/enum/oneof/extension/service/method, where the parent is the
/// lexical/structural enclosing scope (an extension field's parent is its
/// enclosing scope, NOT the extendee; a field's parent is its oneof when it is
/// in one, else its message).
Map<String, String> mergeChildFeatures(
  int edition,
  Map<String, String> resolvedParent,
  Map<String, Object?>? childFeatures,
) {
  return mergeFeatureSet(resolvedParent, childFeatures, edition);
}

/// Back-compat convenience wrapper: resolves features down the common
/// file → message → field chain for an edition/syntax string.
///
/// [edition] accepts `"proto2"`, `"proto3"`, `"2023"`, `"2024"` (or the
/// `EDITION_*` forms). Each override map may carry any subset of the feature
/// keys; only present keys override the inherited value.
Map<String, String> resolveFeatures(
  String edition,
  Map<String, Object?>? fileFeatures,
  Map<String, Object?>? messageFeatures,
  Map<String, Object?>? fieldFeatures,
) {
  final ed = editionFromString(edition);
  if (ed == editionUnknown) {
    throw ArgumentError('Unrecognized protobuf edition: "$edition"');
  }
  final file = resolveFileFeatures(ed, fileFeatures);
  final message = mergeChildFeatures(ed, file, messageFeatures);
  return mergeChildFeatures(ed, message, fieldFeatures);
}

/// Returns the default feature map for an edition/syntax string (no overrides).
/// Retained for callers that only need the edition base.
Map<String, String> editionDefaults(String edition) {
  final ed = editionFromString(edition);
  if (ed == editionUnknown) {
    throw ArgumentError('Unrecognized protobuf edition: "$edition"');
  }
  return baseFeaturesForEdition(ed);
}

// ---------------------------------------------------------------------------
// Legacy inference (proto2/proto3 → features), applied before resolution
// ---------------------------------------------------------------------------

/// Infers the field-level feature overrides implied by a proto2/proto3 field's
/// shape, so a legacy field resolves identically to its editions equivalent.
///
///   - [label] is the FieldDescriptorProto label: `"LABEL_OPTIONAL"`,
///     `"LABEL_REQUIRED"`, or `"LABEL_REPEATED"`.
///   - [type] is the field type; `"TYPE_GROUP"` implies delimited encoding.
///   - [proto3Optional] is true for a proto3 `optional` field.
///   - [packed] is the explicit `[packed=...]` option: `"true"`, `"false"`, or
///     `null` if unset.
///   - [edition] is the field's file edition sentinel ([editionProto2] or
///     [editionProto3]).
///
/// Returns only the keys this shape pins; everything else inherits the edition
/// base. Mirrors descriptor.cc's `InferLegacyProtoFeatures`.
Map<String, String> inferLegacyFieldFeatures(
  String label,
  String type,
  bool proto3Optional,
  String? packed,
  int edition,
) {
  final inferred = <String, String>{};

  if (label == 'LABEL_REQUIRED') {
    inferred[featureFieldPresence] = fieldPresenceLegacyRequired;
  } else if (edition == editionProto3 &&
      label == 'LABEL_OPTIONAL' &&
      !proto3Optional) {
    // proto3 singular scalar: implicit presence (unless explicitly `optional`).
    inferred[featureFieldPresence] = fieldPresenceImplicit;
  } else if (proto3Optional) {
    inferred[featureFieldPresence] = fieldPresenceExplicit;
  }

  if (type == 'TYPE_GROUP') {
    inferred[featureMessageEncoding] = messageEncodingDelimited;
  }

  if (packed == 'true') {
    inferred[featureRepeatedFieldEncoding] = repeatedFieldEncodingPacked;
  } else if (packed == 'false') {
    inferred[featureRepeatedFieldEncoding] = repeatedFieldEncodingExpanded;
  }

  return inferred;
}

/// Infers the fully-resolved FILE-level FeatureSet for a legacy [syntax]
/// (`"proto2"` / `"proto3"`, or `""` ⇒ proto2).
///
/// In protoc's `descriptor.cc`, the file-level legacy inference is exactly the
/// selection of the syntax's edition floor: proto2 resolves through the LEGACY
/// floor (CLOSED enums, EXPANDED repeated, NONE utf8, LEGACY_BEST_EFFORT json,
/// EXPLICIT presence); proto3 through the PROTO3 floor (OPEN, PACKED, VERIFY,
/// ALLOW, IMPLICIT). The per-field shape adjustments (required/optional/group/
/// packed) are layered on top via [inferLegacyFieldFeatures].
///
/// Returns all six runtime features. Throws nothing for unknown syntax — it
/// floors to proto2 like protoc.
Map<String, String> inferLegacyFileFeatures(String syntax) {
  return baseFeaturesForEdition(syntaxToEdition(syntax));
}

// ---------------------------------------------------------------------------
// Behavior helpers (read a resolved FeatureSet)
// ---------------------------------------------------------------------------

/// True when the field tracks presence (`EXPLICIT` or `LEGACY_REQUIRED`).
bool hasExplicitPresence(Map<String, String> features) {
  final presence = features[featureFieldPresence];
  return presence == fieldPresenceExplicit ||
      presence == fieldPresenceLegacyRequired;
}

/// True when the field has implicit (proto3-style) presence.
bool isImplicitPresence(Map<String, String> features) {
  return features[featureFieldPresence] == fieldPresenceImplicit;
}

/// True when the field is `required` (LEGACY_REQUIRED).
bool isRequired(Map<String, String> features) {
  return features[featureFieldPresence] == fieldPresenceLegacyRequired;
}

/// True when the enum is open (unknown values preserved as integers).
bool isOpenEnum(Map<String, String> features) {
  return features[featureEnumType] == enumTypeOpen;
}

/// True when the enum is closed (unknown values routed to the unknown set).
bool isClosedEnum(Map<String, String> features) {
  return features[featureEnumType] == enumTypeClosed;
}

/// True when repeated scalar fields are packed.
bool isPackedRepeated(Map<String, String> features) {
  return features[featureRepeatedFieldEncoding] == repeatedFieldEncodingPacked;
}

/// True when repeated scalar fields are expanded (one record per element).
bool isExpandedRepeated(Map<String, String> features) {
  return features[featureRepeatedFieldEncoding] ==
      repeatedFieldEncodingExpanded;
}

/// True when message fields use delimited (group) encoding.
bool isDelimited(Map<String, String> features) {
  return features[featureMessageEncoding] == messageEncodingDelimited;
}

/// True when string fields require UTF-8 validation.
bool requiresUtf8Validation(Map<String, String> features) {
  return features[featureUtf8Validation] == utf8ValidationVerify;
}

/// True when JSON encoding uses the standard (ALLOW) format rather than the
/// legacy best-effort path.
bool jsonFormatIsAllow(Map<String, String> features) {
  return features[featureJsonFormat] == jsonFormatAllow;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Copies every entry of [src] into [dest] (later writes win), the portable
/// equivalent of `dest.addAll(src)` for string maps.
///
/// Authored as an explicit `entries` loop rather than `Map.addAll` on purpose:
/// the Dart→Ball encoder is purely syntactic (no static types) and routes a
/// bare `.addAll` to the list operation `list_concat`, which fails on a map.
/// Map index-set over `entries` is a core, portable primitive that compiles and
/// runs identically on every target engine (Dart/TS/C++).
void _putAll(Map<String, String> dest, Map<String, String> src) {
  for (final entry in src.entries) {
    dest[entry.key] = entry.value;
  }
}

/// Applies override entries from [overrides] onto [base].
///
/// Only string-valued entries whose keys are recognized feature keys are
/// applied. Overriding a feature that is FIXED at [edition] is a hard error
/// (matches protoc, which rejects setting a non-overridable feature).
void _applyOverrides(
  Map<String, String> base,
  Map<String, Object?>? overrides,
  int edition,
) {
  if (overrides == null) return;
  for (final entry in overrides.entries) {
    final key = entry.key;
    final value = entry.value;
    if (value is String && base.containsKey(key)) {
      if (isFixedFeature(edition, key)) {
        throw ArgumentError(
          'Feature "$key" is not overridable at edition '
          '${editionToName(edition)}',
        );
      }
      base[key] = value;
    }
  }
}
