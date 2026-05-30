/// Protobuf Edition identifiers and string/syntax mapping.
///
/// Editions are represented by their numeric `google.protobuf.Edition` value
/// (time-ordered), so feature resolution can compare editions with `<`/`>=`.
/// This module is Ball-portable: top-level integer constants + plain functions,
/// no `dart:` dependencies, so it encodes into the `ball_protobuf` module and
/// runs on every target engine.
///
/// References:
///   - https://protobuf.dev/editions/overview/
///   - google/protobuf/descriptor.proto (enum Edition)
library;

// ---------------------------------------------------------------------------
// Edition numeric values (mirror google.protobuf.Edition, time-ordered)
// ---------------------------------------------------------------------------

/// Unknown / unset edition.
const int editionUnknown = 0;

/// Pre-editions legacy floor. proto2 and proto3 resolve through edition entries
/// at or below their sentinel value.
const int editionLegacy = 900;

/// Internal sentinel for proto2 syntax (never appears in a file `edition =`).
const int editionProto2 = 998;

/// Internal sentinel for proto3 syntax (never appears in a file `edition =`).
const int editionProto3 = 999;

/// Edition 2023 — the first real edition.
const int edition2023 = 1000;

/// Edition 2024.
const int edition2024 = 1001;

/// Edition 2026 (declared in descriptor.proto; not a published edition yet).
const int edition2026 = 1002;

/// Test-only sentinel above every released edition.
const int editionUnstable = 9999;

/// Maximum representable edition.
const int editionMax = 0x7fffffff;

// ---------------------------------------------------------------------------
// String / syntax mapping
// ---------------------------------------------------------------------------

/// Parses an edition declaration or syntax string into its numeric value.
///
/// Accepts the file `edition = "..."` forms (`"2023"`, `"2024"`, `"2026"`), the
/// fully-qualified enum names (`"EDITION_2023"`), and the legacy `syntax`
/// strings (`"proto2"`, `"proto3"`). Returns [editionUnknown] for anything
/// unrecognized (callers decide whether that is an error).
int editionFromString(String s) {
  switch (s) {
    case 'proto2':
    case 'EDITION_PROTO2':
      return editionProto2;
    case 'proto3':
    case 'EDITION_PROTO3':
      return editionProto3;
    case '2023':
    case 'EDITION_2023':
      return edition2023;
    case '2024':
    case 'EDITION_2024':
      return edition2024;
    case '2026':
    case 'EDITION_2026':
      return edition2026;
    case 'EDITION_LEGACY':
      return editionLegacy;
    default:
      return editionUnknown;
  }
}

/// Maps the legacy `syntax` keyword to its edition sentinel.
///
/// An empty or `"proto2"` syntax is proto2; `"proto3"` is proto3. Used by the
/// legacy-inference path so proto2/proto3 descriptors resolve through the same
/// edition-defaults table as editions files.
int syntaxToEdition(String syntax) {
  if (syntax == 'proto3') return editionProto3;
  return editionProto2;
}

/// Returns the canonical `EDITION_*` enum name for a numeric edition (the form
/// used by proto3-JSON and `protoc --decode`). Returns `"EDITION_UNKNOWN"` for
/// unrecognized values.
String editionToName(int edition) {
  switch (edition) {
    case editionLegacy:
      return 'EDITION_LEGACY';
    case editionProto2:
      return 'EDITION_PROTO2';
    case editionProto3:
      return 'EDITION_PROTO3';
    case edition2023:
      return 'EDITION_2023';
    case edition2024:
      return 'EDITION_2024';
    case edition2026:
      return 'EDITION_2026';
    case editionUnstable:
      return 'EDITION_UNSTABLE';
    default:
      return 'EDITION_UNKNOWN';
  }
}
