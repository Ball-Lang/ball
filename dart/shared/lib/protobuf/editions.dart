/// Protobuf Editions feature resolution.
///
/// Protobuf Editions (starting from Edition 2023) replace the `syntax`
/// keyword with per-feature defaults that can be overridden at file,
/// message, or field level. This module provides constants and resolution
/// logic for the core feature set.
///
/// References:
///   - https://protobuf.dev/editions/features/
///   - https://protobuf.dev/editions/overview/
library;

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

// ---------------------------------------------------------------------------
// Feature keys
// ---------------------------------------------------------------------------

/// Feature key for field presence behavior.
const String _keyFieldPresence = 'field_presence';

/// Feature key for enum openness.
const String _keyEnumType = 'enum_type';

/// Feature key for repeated field wire encoding.
const String _keyRepeatedFieldEncoding = 'repeated_field_encoding';

/// Feature key for UTF-8 validation on string fields.
const String _keyUtf8Validation = 'utf8_validation';

// ---------------------------------------------------------------------------
// Edition defaults
// ---------------------------------------------------------------------------

/// Default feature set for proto2 syntax.
///
/// Proto2 uses explicit presence, closed enums, expanded repeated encoding,
/// and no UTF-8 validation.
final Map<String, String> _proto2Defaults = {
  _keyFieldPresence: fieldPresenceExplicit,
  _keyEnumType: enumTypeClosed,
  _keyRepeatedFieldEncoding: repeatedFieldEncodingExpanded,
  _keyUtf8Validation: utf8ValidationNone,
};

/// Default feature set for proto3 syntax.
///
/// Proto3 uses implicit presence, open enums, packed repeated encoding,
/// and UTF-8 verification.
final Map<String, String> _proto3Defaults = {
  _keyFieldPresence: fieldPresenceImplicit,
  _keyEnumType: enumTypeOpen,
  _keyRepeatedFieldEncoding: repeatedFieldEncodingPacked,
  _keyUtf8Validation: utf8ValidationVerify,
};

/// Default feature set for Edition 2023.
///
/// Edition 2023 starts from proto3 defaults but switches field presence
/// to explicit by default (matching the direction of the editions migration).
final Map<String, String> _edition2023Defaults = {
  _keyFieldPresence: fieldPresenceExplicit,
  _keyEnumType: enumTypeOpen,
  _keyRepeatedFieldEncoding: repeatedFieldEncodingPacked,
  _keyUtf8Validation: utf8ValidationVerify,
};

/// Returns the default feature map for [edition].
///
/// Recognized edition strings:
///   - `"proto2"` — proto2 syntax defaults
///   - `"proto3"` — proto3 syntax defaults
///   - `"2023"`   — Edition 2023 defaults
///
/// Throws [ArgumentError] for unrecognized editions.
Map<String, String> editionDefaults(String edition) {
  switch (edition) {
    case 'proto2':
      return Map.of(_proto2Defaults);
    case 'proto3':
      return Map.of(_proto3Defaults);
    case '2023':
      return Map.of(_edition2023Defaults);
    default:
      throw ArgumentError('Unrecognized protobuf edition: "$edition"');
  }
}

// ---------------------------------------------------------------------------
// Feature resolution
// ---------------------------------------------------------------------------

/// Resolves the effective feature set for a specific descriptor element.
///
/// Feature resolution follows the protobuf editions inheritance chain:
///   edition defaults → file-level overrides → message-level overrides →
///   field-level overrides.
///
/// Each override map may contain any subset of the feature keys
/// (`"field_presence"`, `"enum_type"`, `"repeated_field_encoding"`,
/// `"utf8_validation"`). Only present keys override the inherited value.
///
/// [edition] is the edition string (e.g. `"proto3"`, `"2023"`).
/// [fileFeatures], [messageFeatures], and [fieldFeatures] are optional
/// override maps at each scope level.
Map<String, String> resolveFeatures(
  String edition,
  Map<String, Object?>? fileFeatures,
  Map<String, Object?>? messageFeatures,
  Map<String, Object?>? fieldFeatures,
) {
  final result = editionDefaults(edition);
  _applyOverrides(result, fileFeatures);
  _applyOverrides(result, messageFeatures);
  _applyOverrides(result, fieldFeatures);
  return result;
}

/// Checks whether the resolved [features] indicate explicit presence
/// tracking for a field.
///
/// Returns `true` for both `EXPLICIT` and `LEGACY_REQUIRED` presence modes,
/// since both track whether the field has been set.
bool hasExplicitPresence(Map<String, String> features) {
  final presence = features[_keyFieldPresence];
  return presence == fieldPresenceExplicit ||
      presence == fieldPresenceLegacyRequired;
}

/// Checks whether the resolved [features] indicate packed encoding for
/// repeated scalar fields.
bool isPackedRepeated(Map<String, String> features) {
  return features[_keyRepeatedFieldEncoding] == repeatedFieldEncodingPacked;
}

/// Checks whether the resolved [features] indicate an open enum type
/// (unknown values are preserved as integers rather than rejected).
bool isOpenEnum(Map<String, String> features) {
  return features[_keyEnumType] == enumTypeOpen;
}

/// Checks whether the resolved [features] require UTF-8 validation on
/// string fields.
bool requiresUtf8Validation(Map<String, String> features) {
  return features[_keyUtf8Validation] == utf8ValidationVerify;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Applies override entries from [overrides] onto [base].
///
/// Only string-valued entries whose keys are recognized feature keys are
/// applied. All other entries are ignored.
void _applyOverrides(Map<String, String> base, Map<String, Object?>? overrides) {
  if (overrides == null) return;
  for (final entry in overrides.entries) {
    if (entry.value is String && base.containsKey(entry.key)) {
      base[entry.key] = entry.value as String;
    }
  }
}
