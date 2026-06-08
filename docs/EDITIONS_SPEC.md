# Protobuf Editions Feature Model — Specification

> Reviewer-facing spec for Ball's protobuf Editions support.
> Canonical source: [Protobuf Editions Overview](https://protobuf.dev/editions/overview/),
> [Features](https://protobuf.dev/editions/features/),
> [Implementation](https://protobuf.dev/editions/implementation/),
> [Programming Guides](https://protobuf.dev/programming-guides/editions/).
> Descriptor schema: [descriptor.proto](https://raw.githubusercontent.com/protocolbuffers/protobuf/main/src/google/protobuf/descriptor.proto).

---

## 1. Edition Enum (Numeric, Time-Ordered)

```
EDITION_UNKNOWN = 0
EDITION_LEGACY = 900
EDITION_PROTO2 = 998
EDITION_PROTO3 = 999
EDITION_2023 = 1000
EDITION_2024 = 1001
EDITION_2026 = 1002
EDITION_UNSTABLE = 9999
EDITION_MAX = 0x7FFFFFFF
```

**Key invariants:**
- There is **no EDITION_2025**.
- `EDITION_PROTO2` and `EDITION_PROTO3` are **internal sentinels** — they cannot appear in a `.proto` file's `edition =` declaration; they exist so legacy proto2/proto3 files can resolve through the same 5-step algorithm as explicit-edition files (via legacy inference; see §3).
- In proto3 JSON, `edition` serializes as the string name (e.g., `"EDITION_2023"`).
- `EDITION_UNSTABLE` is allowed above `maximum_edition` in the defaults table; regular files must validate `minimum_edition ≤ file.edition ≤ maximum_edition`.

---

## 2. Core Runtime FeatureSet Fields

All fields in this table have `RETENTION_RUNTIME` and `edition_introduced = EDITION_2023`.

| # | Feature | Values | LEGACY | PROTO2 | PROTO3 | 2023 | 2024 |
|---|---------|--------|--------|--------|--------|------|------|
| 1 | `field_presence` | EXPLICIT / IMPLICIT / LEGACY_REQUIRED | EXPLICIT | EXPLICIT | IMPLICIT | EXPLICIT | EXPLICIT |
| 2 | `enum_type` | OPEN / CLOSED | CLOSED | CLOSED | OPEN | OPEN | OPEN |
| 3 | `repeated_field_encoding` | PACKED / EXPANDED | EXPANDED | EXPANDED | PACKED | PACKED | PACKED |
| 4 | `utf8_validation` | VERIFY / NONE | NONE | NONE | VERIFY | VERIFY | VERIFY |
| 5 | `message_encoding` | LENGTH_PREFIXED / DELIMITED | LENGTH_PREFIXED | LENGTH_PREFIXED | LENGTH_PREFIXED | LENGTH_PREFIXED | LENGTH_PREFIXED |
| 6 | `json_format` | ALLOW / LEGACY_BEST_EFFORT | LEGACY_BEST_EFFORT | LEGACY_BEST_EFFORT | ALLOW | ALLOW | ALLOW |

**Feature set locations in descriptor messages:**
- `FileOptions`, field **#50** (note: `edition` field is FileOptions **#14**)
- `MessageOptions`, field **#12**
- `FieldOptions`, field **#21**
- `EnumOptions`, field **#7**
- (Also `OneofOptions`, `ServiceOptions`, `MethodOptions` — see descriptor.proto)

---

## 3. Source-Retention Features (Compiler-Only, Runtime Ignores)

The following features have `RETENTION_SOURCE`, meaning they are stripped from binary descriptors and never reach the runtime engine:

| Feature | Field # | Introduced |
|---------|---------|------------|
| `enforce_naming_style` | 7 | EDITION_2024 |
| `default_symbol_visibility` | 8 | EDITION_2024 |
| `enforce_proto_limits` | 9 | EDITION_2026 |

**Runtime behavior:** The engine must **recognize and discard** these fields if present in source; they are never acted upon during marshal, unmarshal, or JSON codecs.

---

## 4. Language-Specific FeatureSet Extensions (Engine Must Ignore Gracefully)

FeatureSet extensions in the range **1000–9994** are language-specific:

```
pb.cpp       = 1000
pb.java      = 1001
pb.go        = 1002
pb.python    = 1003
pb.csharp    = 1004
```

Third-party extensions start at **≥10000**.

**Runtime behavior:** Ball's editions engine processes only base fields (1–9). Unknown FeatureSet extensions are **skipped silently, never fatal**.

---

## 5. Field-Level Runtime Semantics

### field_presence
- **IMPLICIT** → singular scalar field has no presence tracking; default value (0, false, "", empty) is **not serialized** and **omitted from JSON** (proto3 semantics).
- **EXPLICIT** → presence is tracked; set values always serialized and included in JSON; presence can be queried via `has_*()` methods.
- **LEGACY_REQUIRED** → field **must be present** on unmarshal (error if missing) and always serialized on marshal.
- **Applies to:** singular non-repeated, non-map fields only.

### enum_type
- **OPEN** → out-of-range integer values are **preserved** in the field (not routed to unknown fields).
- **CLOSED** → out-of-range integer values are **routed to the message's unknown-field set** and not stored in the enum field itself.

### repeated_field_encoding
- **PACKED** → repeated scalar fields are encoded as a single wiretype-2 record containing all varint-encoded elements (more efficient).
- **EXPANDED** → each repeated scalar element is encoded as a separate record.
- **Decoder requirement:** readers must accept **both** packed and expanded regardless of the feature (for forward compatibility).
- **Encoder requirement:** writers emit per the feature value.

### utf8_validation
- **VERIFY** → string fields (both repeated and singular) **reject non-UTF-8 byte sequences** during unmarshal; error on invalid UTF-8.
- **NONE** → string bytes pass through unchanged (no validation).

### message_encoding
- **LENGTH_PREFIXED** → message fields use wiretype 2 (standard proto3 length-delimited encoding).
- **DELIMITED** → message fields use group encoding (wiretype 3/4, deprecated but still valid and required in proto2 groups).

### json_format
- **ALLOW** → JSON codec uses strict semantics: default values are **omitted** unless explicitly set; unknown fields are **ignored**.
- **LEGACY_BEST_EFFORT** → JSON codec is lenient: omitted fields are treated as defaults; unknown fields are preserved in a special `unknown_fields` container (proto2 semantics).

---

## 6. The 5-Step Resolution Algorithm

The feature-resolution process is driven by a `FeatureSetDefaults` structure:

```protobuf
message FeatureSetDefaults {
  Edition minimum_edition = 1;
  Edition maximum_edition = 2;
  repeated FeatureSetEditionDefault defaults = 3;
}

message FeatureSetEditionDefault {
  Edition edition = 1;
  FeatureSet overridable_features = 2;
  FeatureSet fixed_features = 3;
}
```

### For File Descriptors (FileDescriptorProto)

**Step 1:** Validate range.
- Assert `minimum_edition ≤ file.edition ≤ maximum_edition`. `EDITION_UNSTABLE` is allowed above `maximum_edition`.

**Step 2:** Find the base default.
- Binary-search `defaults[]` for the **highest entry** with `edition ≤ file.edition` (equivalent to `upper_bound` then step back one).
- If not found, use the first entry.

**Step 3:** Merge fixed and overridable.
- Base FeatureSet = `fixed_features` merged-under `overridable_features`.
- "Merged under" uses proto `MergeFrom` semantics: unset fields in the left operand are filled from the right; set fields in the left are preserved.

**Step 4:** Apply file-level overrides.
- Merge `file.options.features` (if present) on top of Base.
- This is a normal `MergeFrom`: any field set in `file.options.features` overrides Base; unset fields leave Base unchanged.

**Result:** `resolvedFeatures[file]` = fully resolved FeatureSet for the file.

### For Non-File Descriptors (Message, Field, Enum, OneOf, Extension, Service, Method)

**Step 1:** Start from parent.
- Begin with the **parent's already-fully-resolved** FeatureSet (from the 4-step file resolution or a prior descriptor's resolution).

**Step 2:** Merge child overrides.
- Merge this descriptor's explicit `options.features` on top of parent's resolved FeatureSet.

**Step 3:** Validate no UNKNOWN enums.
- Assert that no enum-type feature is `UNKNOWN` (uninitialized).

**Result:** `resolvedFeatures[descriptor]` = resolved FeatureSet for this descriptor (inherited and optionally overridden).

### Parent Rules (Must Be Exact)

The "parent" of a descriptor is:
- **Field** → its enclosing `OneOf` if the field is in a oneof; otherwise its enclosing **Message**.
- **Extension field** → its **lexical enclosing scope** (message or file), **NOT the extendee** (the message it extends).
- **Nested Message or Enum** → its enclosing **Message**, or the **File** if not nested.
- **Enum value** → its enclosing **Enum**.
- **Method** → its enclosing **Service**.
- **Service** → the **File**.
- **File** → the `FeatureSetDefaults` table (step 1–4 above).

### Fixed vs. Overridable

A feature is **fixed** (user cannot override) when:
- `file.edition < edition_introduced`, OR
- `file.edition ≥ edition_removed` (if the feature is deprecated/removed).

Otherwise, it is **overridable** (user can set it).

**Error condition:** Attempting to set a fixed feature is a **hard error**; reject the descriptor.

---

## 7. Legacy Inference (Proto2/Proto3 → Features)

When a file has `syntax = "proto2"` or `syntax = "proto3"` (no explicit `edition` field), the resolver applies inference rules **before** the 5-step algorithm:

### File-Level Inference

- **proto2 file** → apply as if `edition = EDITION_PROTO2` (internal sentinel).
  - Inferred file defaults: `enum_type=CLOSED`, `repeated_field_encoding=EXPANDED`, `utf8_validation=NONE`, `json_format=LEGACY_BEST_EFFORT`. (Other features follow the EDITION_PROTO2 row from the defaults table.)
- **proto3 file** → apply as if `edition = EDITION_2023`.
  - Inferred file defaults: the EDITION_2023 row from the defaults table above.

### Field-Level Inference

Apply **before** step 1 of the file resolution, for each field in the file:

- **`label = LABEL_REQUIRED`** (proto2 only) → `field_presence=LEGACY_REQUIRED`.
- **proto3 singular scalar** (no label, not repeated) → `field_presence=IMPLICIT`.
- **proto3 `optional`** → `field_presence=EXPLICIT`.
- **proto2 `optional`** or `required`** → `field_presence=EXPLICIT`.
- **`type = TYPE_GROUP`** (proto2 only) → `message_encoding=DELIMITED`.
- **`[packed=true]`** (option on repeated field) → `repeated_field_encoding=PACKED`.
- **proto3 `[packed=false]`** (option on repeated field, proto3 only) → `repeated_field_encoding=EXPANDED`.

**Equivalence property:** A proto2 file with carefully chosen field-level settings, when resolved via inference, must produce the **same resolved FeatureSet** and **identical wire output** as an equivalent `edition=2023` file with matching features set explicitly.

---

## 8. Known Limitations

### Golden Data Pinning

Golden FeatureSet resolution data (in `tests/editions/golden/`) is **pinned to protoc 28.2**, which supports editions up to **2023** (see `tests/editions/golden/PROTOC_VERSION.txt`). Protoc ≥29 is required to generate golden data for EDITION_2024 and EDITION_2026; such versions are **not yet golden-verified** against the reference implementation.

### EDITION_2024 and Later

- The EDITION_2024 row in the FeatureSet defaults table (section 2 above) has **identical runtime feature values** to EDITION_2023 by construction: EDITION_2024 only adds `RETENTION_SOURCE` features (`enforce_naming_style`, `default_symbol_visibility`) which the runtime ignores.
- EDITION_2024 and EDITION_2026 runtime semantics are **not yet validated against protoc ≥29** golden data.

### DELIMITED (Group) Message Encoding

Support for `message_encoding=DELIMITED` (wiretype 3/4, group-style encoding) is **implemented** in the `ball_protobuf` runtime. `marshal.dart` emits START_GROUP/END_GROUP tags and `unmarshal.dart` consumes them, honoring the resolved `message_encoding` feature. This covers proto2 groups and editions `message_encoding = DELIMITED`.

### Closed Enum Unknown Field Handling

The semantics of routing out-of-range enum values to the unknown-field set (when `enum_type=CLOSED`) are **context-dependent**: during JSON unmarshal, JSON-layer unknown fields and proto-level unknown fields have different precedence rules. This is **not yet fully harmonized** with all target implementations.

---

## 9. Refreshing the Defaults from Protoc

### Tools

The canonical FeatureSet defaults table is generated by the protobuf compiler and checked in under `tests/editions/featureset_defaults.binpb`:

- **Windows:** `tools/gen_edition_defaults.ps1` — wraps `protoc --edition_defaults_out=...` to emit `featureset_defaults.binpb` (binary) and `.json` (human-readable).
- **Unix:** `tools/gen_edition_defaults.sh` — POSIX equivalent.

### Workflow

1. Install a specific protoc version (pinned in CI configuration).
2. Run `tools/gen_edition_defaults.ps1` (Windows) or `tools/gen_edition_defaults.sh` (Unix).
3. The script regenerates:
   - `tests/editions/featureset_defaults.binpb` (binary FeatureSetDefaults)
   - `tests/editions/featureset_defaults.json` (human-readable dump)
4. Commit the regenerated files if protoc was updated.
5. **CI drift check:** On every build, re-run the generation and diff against the checked-in files. Fail loudly if they diverge (indicates upstream protobuf defaults changed or a different protoc version was used).

### Location

- Tool scripts: `tools/gen_edition_defaults.*`
- Checked-in defaults: `tests/editions/featureset_defaults.binpb`, `tests/editions/featureset_defaults.json`
- Pinned protoc version: `tests/editions/golden/PROTOC_VERSION.txt`

---

## 10. References

Official Protobuf Editions Documentation:
- https://protobuf.dev/editions/overview/
- https://protobuf.dev/editions/features/
- https://protobuf.dev/editions/implementation/
- https://protobuf.dev/programming-guides/editions/

Descriptor Schema:
- https://raw.githubusercontent.com/protocolbuffers/protobuf/main/src/google/protobuf/descriptor.proto

Feature Resolver Reference Implementation:
- https://github.com/protocolbuffers/protobuf/blob/main/src/google/protobuf/feature_resolver.cc
- https://github.com/protocolbuffers/protobuf/blob/main/src/google/protobuf/feature_resolver.h

Ball Implementation:
- Editions resolver + FeatureSet model: `dart/ball_protobuf/lib/editions.dart`
- Edition enum constants and conversion: `dart/ball_protobuf/lib/edition.dart`
- Legacy inference: integrated into `dart/ball_protobuf/lib/editions.dart` (the former `legacy_features.dart` was merged)
- Codecs (marshal/unmarshal/JSON): `dart/ball_protobuf/lib/{marshal,unmarshal,json_codec}.dart`
- Encoder generator: `dart/encoder/bin/gen_ball_protobuf.dart`
- Published Ball program: `dart/shared/ball_protobuf.json` / `dart/shared/ball_protobuf.bin`
- Cross-target portability proof: `tests/conformance/256_editions_resolver.ball.json` (passes on Dart, TS, and C++ engines)
