/// Tests for protobuf Editions feature resolution.
///
/// The edition-defaults expectations below are the ground truth emitted by
/// `protoc --edition_defaults_out` (protoc 35.1, covering editions through
/// EDITION_2024) and checked into tests/editions/golden/featureset_defaults.txtpb.
/// If protoc's defaults change, regenerate that golden AND update these
/// expectations together.
///
/// protoc 35.1 also emits an EDITION_UNSTABLE floor (used for in-development
/// features beyond the last released edition; its enforce_naming_style value
/// of STYLE2026 hints at what EDITION_2026 will carry, but EDITION_2026 does
/// not yet have its own dedicated row in FeatureSetDefaults — see
/// docs/EDITIONS_SPEC.md §8). The golden-driven loop below iterates whatever
/// entries protoc emits, so EDITION_UNSTABLE is verified too: our resolver
/// falls through to the highest defined floor (EDITION_2024) for any edition
/// above it, which happens to carry identical runtime-feature values to what
/// protoc reports for EDITION_UNSTABLE.
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart' show FeatureSet, FeatureSetDefaults;
import 'package:ball_protobuf/edition.dart';
import 'package:ball_protobuf/editions.dart';
import 'package:ball_protobuf/json_codec.dart';
import 'package:ball_protobuf/marshal.dart';
import 'package:ball_protobuf/unmarshal.dart';
import 'package:test/test.dart';

/// Locates the checked-in protoc golden by walking up from the test's CWD
/// (`dart/shared` under `dart test`) until `tests/editions/` is found.
File _goldenBinpb() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final f = File('${dir.path}/tests/editions/featureset_defaults.binpb');
    if (f.existsSync()) return f;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate tests/editions/featureset_defaults.binpb from '
    '${Directory.current.path}',
  );
}

/// Extracts the set fields of a [FeatureSet] message as the same
/// `{feature_key: VALUE_NAME}` map shape the resolver produces.
Map<String, String> _featureSetToMap(FeatureSet fs) {
  final m = <String, String>{};
  if (fs.hasFieldPresence()) m[featureFieldPresence] = fs.fieldPresence.name;
  if (fs.hasEnumType()) m[featureEnumType] = fs.enumType.name;
  if (fs.hasRepeatedFieldEncoding()) {
    m[featureRepeatedFieldEncoding] = fs.repeatedFieldEncoding.name;
  }
  if (fs.hasUtf8Validation()) {
    m[featureUtf8Validation] = fs.utf8Validation.name;
  }
  if (fs.hasMessageEncoding()) {
    m[featureMessageEncoding] = fs.messageEncoding.name;
  }
  if (fs.hasJsonFormat()) m[featureJsonFormat] = fs.jsonFormat.name;
  return m;
}

void main() {
  group('edition string/int mapping', () {
    test('editionFromString', () {
      expect(editionFromString('proto2'), editionProto2);
      expect(editionFromString('proto3'), editionProto3);
      expect(editionFromString('2023'), edition2023);
      expect(editionFromString('2024'), edition2024);
      expect(editionFromString('EDITION_2023'), edition2023);
      expect(editionFromString('nope'), editionUnknown);
    });

    test('editionToName', () {
      expect(editionToName(edition2023), 'EDITION_2023');
      expect(editionToName(editionProto3), 'EDITION_PROTO3');
      expect(editionToName(123456), 'EDITION_UNKNOWN');
    });

    test('syntaxToEdition', () {
      expect(syntaxToEdition('proto3'), editionProto3);
      expect(syntaxToEdition('proto2'), editionProto2);
      expect(syntaxToEdition(''), editionProto2);
    });

    test('editions are time-ordered', () {
      expect(editionLegacy < editionProto2, isTrue);
      expect(editionProto2 < editionProto3, isTrue);
      expect(editionProto3 < edition2023, isTrue);
      expect(edition2023 < edition2024, isTrue);
    });
  });

  group('baseFeaturesForEdition matches protoc --edition_defaults_out', () {
    // LEGACY / proto2 (proto2 resolves through the LEGACY floor entry).
    test('LEGACY', () {
      final f = baseFeaturesForEdition(editionLegacy);
      expect(f[featureFieldPresence], fieldPresenceExplicit);
      expect(f[featureEnumType], enumTypeClosed);
      expect(f[featureRepeatedFieldEncoding], repeatedFieldEncodingExpanded);
      expect(f[featureUtf8Validation], utf8ValidationNone);
      expect(f[featureMessageEncoding], messageEncodingLengthPrefixed);
      expect(f[featureJsonFormat], jsonFormatLegacyBestEffort);
    });

    test('PROTO2 resolves via LEGACY', () {
      expect(
        baseFeaturesForEdition(editionProto2),
        baseFeaturesForEdition(editionLegacy),
      );
    });

    test('PROTO3', () {
      final f = baseFeaturesForEdition(editionProto3);
      expect(f[featureFieldPresence], fieldPresenceImplicit);
      expect(f[featureEnumType], enumTypeOpen);
      expect(f[featureRepeatedFieldEncoding], repeatedFieldEncodingPacked);
      expect(f[featureUtf8Validation], utf8ValidationVerify);
      expect(f[featureMessageEncoding], messageEncodingLengthPrefixed);
      expect(f[featureJsonFormat], jsonFormatAllow);
    });

    test('EDITION_2023', () {
      final f = baseFeaturesForEdition(edition2023);
      expect(f[featureFieldPresence], fieldPresenceExplicit);
      expect(f[featureEnumType], enumTypeOpen);
      expect(f[featureRepeatedFieldEncoding], repeatedFieldEncodingPacked);
      expect(f[featureUtf8Validation], utf8ValidationVerify);
      expect(f[featureMessageEncoding], messageEncodingLengthPrefixed);
      expect(f[featureJsonFormat], jsonFormatAllow);
    });

    test('EDITION_2024 runtime features identical to 2023', () {
      expect(
        baseFeaturesForEdition(edition2024),
        baseFeaturesForEdition(edition2023),
      );
    });

    test('every edition resolves all six runtime features', () {
      for (final ed in [
        editionLegacy,
        editionProto2,
        editionProto3,
        edition2023,
        edition2024,
      ]) {
        final f = baseFeaturesForEdition(ed);
        for (final key in featureKeys()) {
          expect(
            f.containsKey(key),
            isTrue,
            reason: '$key missing for ${editionToName(ed)}',
          );
        }
      }
    });
  });

  group('fixed vs overridable', () {
    test('all six are FIXED at proto3 (legacy syntax cannot use features)', () {
      for (final key in featureKeys()) {
        expect(isFixedFeature(editionProto3, key), isTrue);
      }
    });

    test('all six are OVERRIDABLE at edition 2023', () {
      for (final key in featureKeys()) {
        expect(isFixedFeature(edition2023, key), isFalse);
      }
    });
  });

  // The PRIMARY correctness gate (plan §6.1): parse the protoc-generated
  // FeatureSetDefaults binary and drive the resolver through it, so the
  // hand-authored defaults table is verified against protoc ground truth
  // rather than against our own transcription.
  group('golden FeatureSetDefaults (protoc 35.1) drives the resolver', () {
    final defaults = FeatureSetDefaults.fromBuffer(
      _goldenBinpb().readAsBytesSync(),
    );

    test('golden carries the expected edition floors', () {
      final editions = defaults.defaults.map((d) => d.edition.value).toList();
      // protoc 35.1 (max edition 2024) emits LEGACY / PROTO3 / 2023 / 2024
      // floors, plus a trailing EDITION_UNSTABLE floor for in-development
      // features.
      expect(
        editions,
        containsAll([
          editionLegacy,
          editionProto3,
          edition2023,
          edition2024,
          editionUnstable,
        ]),
      );
    });

    // The specific validation this issue set out to do: EDITION_2024's
    // runtime-relevant FeatureSet values (the six fields our resolver acts
    // on) were previously *asserted* identical to EDITION_2023 by
    // construction (protoc 28.2 never emitted a 2024 row to check against).
    // protoc 35.1 confirms the assumption was correct — no code fix needed.
    test('EDITION_2024 golden overridable features match protoc ground truth '
        '(validates the by-construction assumption)', () {
      final entry2024 = defaults.defaults.firstWhere(
        (d) => d.edition.value == edition2024,
      );
      final goldenOverridable = _featureSetToMap(entry2024.overridableFeatures);
      expect(goldenOverridable, baseFeaturesForEdition(edition2023));
      expect(baseFeaturesForEdition(edition2024), goldenOverridable);
    });

    for (final entry in defaults.defaults) {
      final ed = entry.edition.value;
      final name = editionToName(ed);

      test('$name base == protoc merged(overridable, fixed)', () {
        final expected = <String, String>{};
        expected.addAll(_featureSetToMap(entry.overridableFeatures));
        // fixed wins on conflict (matches baseFeaturesForEdition merge order).
        expected.addAll(_featureSetToMap(entry.fixedFeatures));
        expect(baseFeaturesForEdition(ed), expected);
      });

      test('$name fixed features are non-overridable', () {
        final fixed = _featureSetToMap(entry.fixedFeatures);
        for (final key in fixed.keys) {
          expect(
            isFixedFeature(ed, key),
            isTrue,
            reason: '$key should be FIXED at $name',
          );
        }
        // Conversely, an overridable-only feature is not fixed.
        final overridableOnly = _featureSetToMap(
          entry.overridableFeatures,
        ).keys.where((k) => !fixed.containsKey(k));
        for (final key in overridableOnly) {
          expect(
            isFixedFeature(ed, key),
            isFalse,
            reason: '$key should be OVERRIDABLE at $name',
          );
        }
      });
    }

    test('minimum/maximum edition match the golden exactly', () {
      expect(defaults.minimumEdition.value, minimumEdition); // EDITION_PROTO2
      // Golden max (2024, protoc 35.1) now equals our supported ceiling
      // exactly — previously (protoc 28.2, max 2023) we hand-extended past
      // the golden; that gap is now closed and golden-verified.
      expect(defaults.maximumEdition.value, maximumEdition);
      expect(defaults.maximumEdition.value, edition2024);
    });
  });

  group('resolveFileFeatures', () {
    test('no overrides == base', () {
      expect(
        resolveFileFeatures(edition2023, null),
        baseFeaturesForEdition(edition2023),
      );
    });

    test('overriding an overridable feature applies', () {
      final f = resolveFileFeatures(edition2023, {
        featureFieldPresence: fieldPresenceImplicit,
      });
      expect(f[featureFieldPresence], fieldPresenceImplicit);
      // others unchanged
      expect(f[featureEnumType], enumTypeOpen);
    });

    test('overriding a FIXED feature is a hard error', () {
      expect(
        () => resolveFileFeatures(editionProto3, {
          featureFieldPresence: fieldPresenceExplicit,
        }),
        throwsArgumentError,
      );
    });

    test('edition out of range throws', () {
      expect(
        () => resolveFileFeatures(editionUnknown, null),
        throwsArgumentError,
      );
      expect(() => resolveFileFeatures(editionUnstable, null), returnsNormally);
    });
  });

  group('mergeChildFeatures (inheritance)', () {
    test('child inherits parent then overrides', () {
      final file = resolveFileFeatures(edition2023, null);
      final message = mergeChildFeatures(edition2023, file, {
        featureEnumType: enumTypeClosed,
      });
      final field = mergeChildFeatures(edition2023, message, {
        featureFieldPresence: fieldPresenceImplicit,
      });
      expect(field[featureEnumType], enumTypeClosed); // inherited from message
      expect(
        field[featureFieldPresence],
        fieldPresenceImplicit,
      ); // own override
      expect(
        field[featureRepeatedFieldEncoding],
        repeatedFieldEncodingPacked,
      ); // from edition base
    });

    test('message-level FIXED override is a hard error', () {
      final file = resolveFileFeatures(editionProto3, null);
      expect(
        () => mergeChildFeatures(editionProto3, file, {
          featureEnumType: enumTypeClosed,
        }),
        throwsArgumentError,
      );
    });

    test('field-level FIXED override is a hard error', () {
      final file = baseFeaturesForEdition(editionProto3);
      final message = file; // proto3 has no message-level overrides
      expect(
        () => mergeChildFeatures(editionProto3, message, {
          featureUtf8Validation: utf8ValidationNone,
        }),
        throwsArgumentError,
      );
    });
  });

  group('mergeFeatureSet (MergeFrom semantics)', () {
    test('present override replaces, absent keeps base, base not mutated', () {
      final base = baseFeaturesForEdition(edition2023);
      final baseCopy = Map<String, String>.from(base);
      final merged = mergeFeatureSet(base, {
        featureFieldPresence: fieldPresenceImplicit,
      }, edition2023);
      expect(merged[featureFieldPresence], fieldPresenceImplicit); // replaced
      expect(merged[featureEnumType], base[featureEnumType]); // kept
      expect(base, baseCopy); // base untouched (returns a new map)
    });

    test('null/empty overrides yield a copy equal to base', () {
      final base = baseFeaturesForEdition(edition2023);
      expect(mergeFeatureSet(base, null, edition2023), base);
      expect(mergeFeatureSet(base, <String, Object?>{}, edition2023), base);
    });

    test('overriding a FIXED feature throws', () {
      final base = baseFeaturesForEdition(editionProto3);
      expect(
        () => mergeFeatureSet(base, {
          featureEnumType: enumTypeClosed,
        }, editionProto3),
        throwsArgumentError,
      );
    });
  });

  group('inferLegacyFileFeatures (file-level legacy inference)', () {
    test('proto2 file resolves through the LEGACY floor', () {
      expect(
        inferLegacyFileFeatures('proto2'),
        baseFeaturesForEdition(editionProto2),
      );
      // Spot-check the proto2-defining values.
      final f = inferLegacyFileFeatures('proto2');
      expect(f[featureEnumType], enumTypeClosed);
      expect(f[featureRepeatedFieldEncoding], repeatedFieldEncodingExpanded);
      expect(f[featureUtf8Validation], utf8ValidationNone);
      expect(f[featureJsonFormat], jsonFormatLegacyBestEffort);
    });

    test('proto3 file resolves through the PROTO3 floor', () {
      expect(
        inferLegacyFileFeatures('proto3'),
        baseFeaturesForEdition(editionProto3),
      );
      final f = inferLegacyFileFeatures('proto3');
      expect(f[featureEnumType], enumTypeOpen);
      expect(f[featureFieldPresence], fieldPresenceImplicit);
    });

    test('empty/unknown syntax floors to proto2', () {
      expect(
        inferLegacyFileFeatures(''),
        baseFeaturesForEdition(editionProto2),
      );
    });
  });

  group('resolveFeatures convenience wrapper', () {
    test('file -> message -> field chain', () {
      final f = resolveFeatures(
        '2023',
        {featureUtf8Validation: utf8ValidationNone},
        null,
        {featureFieldPresence: fieldPresenceImplicit},
      );
      expect(f[featureUtf8Validation], utf8ValidationNone);
      expect(f[featureFieldPresence], fieldPresenceImplicit);
    });

    test('unknown edition throws', () {
      expect(
        () => resolveFeatures('proto9', null, null, null),
        throwsArgumentError,
      );
    });
  });

  group('legacy inference', () {
    test('proto2 required -> LEGACY_REQUIRED', () {
      final f = inferLegacyFieldFeatures(
        'LABEL_REQUIRED',
        'TYPE_INT32',
        false,
        null,
        editionProto2,
      );
      expect(f[featureFieldPresence], fieldPresenceLegacyRequired);
    });

    test('proto3 singular scalar -> IMPLICIT', () {
      final f = inferLegacyFieldFeatures(
        'LABEL_OPTIONAL',
        'TYPE_INT32',
        false,
        null,
        editionProto3,
      );
      expect(f[featureFieldPresence], fieldPresenceImplicit);
    });

    test('proto3 optional -> EXPLICIT', () {
      final f = inferLegacyFieldFeatures(
        'LABEL_OPTIONAL',
        'TYPE_INT32',
        true,
        null,
        editionProto3,
      );
      expect(f[featureFieldPresence], fieldPresenceExplicit);
    });

    test('group type -> DELIMITED', () {
      final f = inferLegacyFieldFeatures(
        'LABEL_OPTIONAL',
        'TYPE_GROUP',
        false,
        null,
        editionProto2,
      );
      expect(f[featureMessageEncoding], messageEncodingDelimited);
    });

    test('packed option', () {
      expect(
        inferLegacyFieldFeatures(
          'LABEL_REPEATED',
          'TYPE_INT32',
          false,
          'true',
          editionProto2,
        )[featureRepeatedFieldEncoding],
        repeatedFieldEncodingPacked,
      );
      expect(
        inferLegacyFieldFeatures(
          'LABEL_REPEATED',
          'TYPE_INT32',
          false,
          'false',
          editionProto3,
        )[featureRepeatedFieldEncoding],
        repeatedFieldEncodingExpanded,
      );
    });

    test('proto2 field inference == editions equivalence (presence)', () {
      // A proto2 required field, fully resolved, must have LEGACY_REQUIRED
      // presence on top of the proto2 (LEGACY) base.
      final base = resolveFileFeatures(editionProto2, null);
      final inferred = inferLegacyFieldFeatures(
        'LABEL_REQUIRED',
        'TYPE_STRING',
        false,
        null,
        editionProto2,
      );
      // Legacy inference is applied as the field's own (fixed-exempt) features:
      final resolved = <String, String>{};
      resolved.addAll(base);
      resolved.addAll(inferred);
      expect(resolved[featureFieldPresence], fieldPresenceLegacyRequired);
      expect(resolved[featureEnumType], enumTypeClosed);
    });
  });

  group('behavior helpers', () {
    test('presence helpers', () {
      final explicit = {featureFieldPresence: fieldPresenceExplicit};
      final implicit = {featureFieldPresence: fieldPresenceImplicit};
      final required = {featureFieldPresence: fieldPresenceLegacyRequired};
      expect(hasExplicitPresence(explicit), isTrue);
      expect(hasExplicitPresence(required), isTrue);
      expect(hasExplicitPresence(implicit), isFalse);
      expect(isImplicitPresence(implicit), isTrue);
      expect(isRequired(required), isTrue);
      expect(isRequired(explicit), isFalse);
    });

    test('enum / repeated / delimited / utf8 / json helpers', () {
      expect(isOpenEnum({featureEnumType: enumTypeOpen}), isTrue);
      expect(isClosedEnum({featureEnumType: enumTypeClosed}), isTrue);
      expect(
        isPackedRepeated({
          featureRepeatedFieldEncoding: repeatedFieldEncodingPacked,
        }),
        isTrue,
      );
      expect(
        isExpandedRepeated({
          featureRepeatedFieldEncoding: repeatedFieldEncodingExpanded,
        }),
        isTrue,
      );
      expect(
        isDelimited({featureMessageEncoding: messageEncodingDelimited}),
        isTrue,
      );
      expect(
        requiresUtf8Validation({featureUtf8Validation: utf8ValidationVerify}),
        isTrue,
      );
      expect(jsonFormatIsAllow({featureJsonFormat: jsonFormatAllow}), isTrue);
    });
  });

  group('marshal honors resolved features (Phase 3)', () {
    test(
      'EXPLICIT presence serializes a default scalar; IMPLICIT elides it',
      () {
        final explicit = [
          {
            'name': 'x',
            'number': 1,
            'type': 'TYPE_INT32',
            'features': {featureFieldPresence: fieldPresenceExplicit},
          },
        ];
        final implicit = [
          {
            'name': 'x',
            'number': 1,
            'type': 'TYPE_INT32',
            'features': {featureFieldPresence: fieldPresenceImplicit},
          },
        ];
        final none = [
          {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
        ];

        // Explicit presence: a set-but-default (0) value IS on the wire.
        expect(marshal({'x': 0}, explicit), isNotEmpty);
        // Implicit presence (proto3): default elided.
        expect(marshal({'x': 0}, implicit), isEmpty);
        // No features key → unchanged proto3 behavior (back-compat).
        expect(marshal({'x': 0}, none), isEmpty);
        // Non-default value always serialized regardless.
        expect(marshal({'x': 7}, implicit), isNotEmpty);
      },
    );

    test('PACKED vs EXPANDED differ on the wire; readers accept both', () {
      List<Map<String, Object?>> desc(String enc) => [
        {
          'name': 'a',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
          'repeated': true,
          'features': {featureRepeatedFieldEncoding: enc},
        },
      ];
      final packedDesc = desc(repeatedFieldEncodingPacked);
      final expandedDesc = desc(repeatedFieldEncodingExpanded);

      final packed = marshal({
        'a': [1, 2, 3],
      }, packedDesc);
      final expanded = marshal({
        'a': [1, 2, 3],
      }, expandedDesc);

      // Different wire encodings (one LEN blob vs three tagged records).
      expect(packed, isNot(equals(expanded)));

      // A reader accepts EITHER encoding regardless of its own feature.
      expect(unmarshal(packed, expandedDesc)['a'], [1, 2, 3]);
      expect(unmarshal(expanded, packedDesc)['a'], [1, 2, 3]);
    });

    test('EXPANDED repeated keeps default-valued (0) elements on the wire', () {
      final desc = [
        {
          'name': 'a',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_REPEATED',
          'repeated': true,
          'features': {
            featureRepeatedFieldEncoding: repeatedFieldEncodingExpanded,
          },
        },
      ];
      // The 0 element must survive (proto3 elision would drop it).
      expect(
        unmarshal(
          marshal({
            'a': [1, 0, 3],
          }, desc),
          desc,
        )['a'],
        [1, 0, 3],
      );
    });

    test('EXPLICIT default scalar round-trips as a present 0', () {
      final desc = [
        {
          'name': 'x',
          'number': 1,
          'type': 'TYPE_INT32',
          'features': {featureFieldPresence: fieldPresenceExplicit},
        },
      ];
      final bytes = marshal({'x': 0}, desc);
      expect(bytes, isNotEmpty);
      expect(unmarshal(bytes, desc)['x'], 0);
    });
  });

  group('DELIMITED (group) message encoding (Phase 3)', () {
    final subDesc = [
      {'name': 'n', 'number': 1, 'type': 'TYPE_INT32'},
    ];
    List<Map<String, Object?>> msgDesc({required bool delimited}) => [
      {
        'name': 'm',
        'number': 1,
        'type': 'TYPE_MESSAGE',
        'messageDescriptor': subDesc,
        if (delimited)
          'features': {featureMessageEncoding: messageEncodingDelimited},
      },
    ];

    test(
      'singular: emits START_GROUP/END_GROUP, differs from LEN, round-trips',
      () {
        final delimited = msgDesc(delimited: true);
        final lengthPrefixed = msgDesc(delimited: false);

        final groupBytes = marshal({
          'm': {'n': 42},
        }, delimited);
        final lenBytes = marshal({
          'm': {'n': 42},
        }, lengthPrefixed);

        // START_GROUP tag for field 1 = (1<<3)|3 = 11; END_GROUP = (1<<3)|4 = 12.
        expect(groupBytes, [11, 8, 42, 12]);
        // LEN tag = (1<<3)|2 = 10, length 2.
        expect(lenBytes, [10, 2, 8, 42]);
        expect(groupBytes, isNot(equals(lenBytes)));

        // Round-trips through the group decoder.
        expect(unmarshal(groupBytes, delimited)['m'], {'n': 42});
        // A reader decodes a group by its wire type regardless of its own
        // message_encoding feature (readers accept both encodings).
        expect(unmarshal(groupBytes, lengthPrefixed)['m'], {'n': 42});
      },
    );

    test('present empty submessage survives (group and length-prefixed)', () {
      final delimited = msgDesc(delimited: true);
      final lengthPrefixed = msgDesc(delimited: false);
      final groupBytes = marshal({'m': <String, Object?>{}}, delimited);
      expect(groupBytes, [11, 12]); // START + END, empty body
      expect(unmarshal(groupBytes, delimited)['m'], <String, Object?>{});
      // A present length-prefixed submessage is emitted even when empty (tag +
      // length 0) — message fields carry presence, so eliding it would drop the
      // field on round-trip (cf. upstream conformance ValidDataScalar.MESSAGE).
      expect(marshal({'m': <String, Object?>{}}, lengthPrefixed), [10, 0]);
      expect(unmarshal([10, 0], lengthPrefixed)['m'], <String, Object?>{});
    });

    test('repeated delimited messages round-trip', () {
      final desc = [
        {
          'name': 'ms',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'label': 'LABEL_REPEATED',
          'repeated': true,
          'messageDescriptor': subDesc,
          'features': {featureMessageEncoding: messageEncodingDelimited},
        },
      ];
      final data = {
        'ms': [
          {'n': 1},
          {'n': 2},
        ],
      };
      expect(unmarshal(marshal(data, desc), desc)['ms'], [
        {'n': 1},
        {'n': 2},
      ]);
    });

    test('nested delimited groups round-trip', () {
      final innerDesc = [
        {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
      ];
      final midDesc = [
        {
          'name': 'inner',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'messageDescriptor': innerDesc,
          'features': {featureMessageEncoding: messageEncodingDelimited},
        },
      ];
      final outerDesc = [
        {
          'name': 'mid',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'messageDescriptor': midDesc,
          'features': {featureMessageEncoding: messageEncodingDelimited},
        },
      ];
      final data = {
        'mid': {
          'inner': {'x': 7},
        },
      };
      expect(unmarshal(marshal(data, outerDesc), outerDesc), data);
    });

    test('skipping an unknown group does not corrupt following fields', () {
      // Field 1 is an unknown delimited group; field 2 is a known int we must
      // still decode after consuming the group.
      final writer = [
        {
          'name': 'g',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'messageDescriptor': [
            {'name': 'n', 'number': 1, 'type': 'TYPE_INT32'},
          ],
          'features': {featureMessageEncoding: messageEncodingDelimited},
        },
        {'name': 'tail', 'number': 2, 'type': 'TYPE_INT32'},
      ];
      final bytes = marshal({
        'g': {'n': 5},
        'tail': 9,
      }, writer);
      // Reader that doesn't know field 1 at all must skip the whole group.
      final reader = [
        {'name': 'tail', 'number': 2, 'type': 'TYPE_INT32'},
      ];
      final decoded = unmarshal(bytes, reader);
      expect(decoded.containsKey('g'), isFalse);
      expect(decoded['tail'], 9);
    });
  });

  group('CLOSED enum unknown-value routing (Phase 3)', () {
    final openDesc = [
      {'name': 'e', 'number': 1, 'type': 'TYPE_ENUM'},
    ];
    final closedDesc = [
      {
        'name': 'e',
        'number': 1,
        'type': 'TYPE_ENUM',
        'features': {featureEnumType: enumTypeClosed},
        'enumValues': [0, 1, 2],
      },
    ];

    test(
      'singular: out-of-range value routed to unknown (CLOSED); kept (OPEN)',
      () {
        final bytes = marshal({'e': 99}, openDesc);
        // CLOSED: 99 ∉ {0,1,2} → dropped, field stays unset.
        expect(unmarshal(bytes, closedDesc).containsKey('e'), isFalse);
        // OPEN: preserved.
        expect(unmarshal(bytes, openDesc)['e'], 99);
      },
    );

    test('singular: in-range value kept under CLOSED', () {
      final bytes = marshal({'e': 2}, openDesc);
      expect(unmarshal(bytes, closedDesc)['e'], 2);
    });

    test('no features / no enumValues → value kept (back-compat)', () {
      final bytes = marshal({'e': 99}, openDesc);
      expect(unmarshal(bytes, openDesc)['e'], 99);
      // CLOSED features but no known value set → cannot judge range → keep.
      final closedNoValues = [
        {
          'name': 'e',
          'number': 1,
          'type': 'TYPE_ENUM',
          'features': {featureEnumType: enumTypeClosed},
        },
      ];
      expect(unmarshal(bytes, closedNoValues)['e'], 99);
    });

    test('repeated: out-of-range elements filtered under CLOSED', () {
      final openRep = [
        {
          'name': 'es',
          'number': 1,
          'type': 'TYPE_ENUM',
          'label': 'LABEL_REPEATED',
          'repeated': true,
        },
      ];
      final closedRep = [
        {
          'name': 'es',
          'number': 1,
          'type': 'TYPE_ENUM',
          'label': 'LABEL_REPEATED',
          'repeated': true,
          'features': {featureEnumType: enumTypeClosed},
          'enumValues': [0, 1, 2],
        },
      ];
      final bytes = marshal({
        'es': [1, 99, 2],
      }, openRep);
      expect(unmarshal(bytes, closedRep)['es'], [1, 2]); // 99 filtered
      expect(unmarshal(bytes, openRep)['es'], [1, 99, 2]); // open keeps all
    });
  });

  group('JSON codec honors resolved features (Phase 4)', () {
    group('presence-aware default omission', () {
      List<Map<String, Object?>> desc(String presence) => [
        {
          'name': 'x',
          'number': 1,
          'type': 'TYPE_INT32',
          'features': {featureFieldPresence: presence},
        },
      ];
      final explicit = desc(fieldPresenceExplicit);
      final implicit = desc(fieldPresenceImplicit);
      final none = [
        {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
      ];

      test('EXPLICIT presence emits a present default scalar', () {
        expect(marshalJson({'x': 0}, explicit), '{"x":0}');
      });
      test('EXPLICIT presence omits an unset (absent) field', () {
        expect(marshalJson(<String, Object?>{}, explicit), '{}');
      });
      test('IMPLICIT presence omits a default scalar (proto3)', () {
        expect(marshalJson({'x': 0}, implicit), '{}');
      });
      test('no features → omits default (back-compat firewall)', () {
        expect(marshalJson({'x': 0}, none), '{}');
      });
      test('non-default value always emitted', () {
        expect(marshalJson({'x': 7}, implicit), '{"x":7}');
        expect(marshalJson({'x': 7}, none), '{"x":7}');
      });
    });

    group('json_format strict vs best-effort enum decoding', () {
      final enumMap = {0: 'A', 1: 'B'};
      List<Map<String, Object?>> desc(String? jsonFormat) => [
        {
          'name': 'e',
          'number': 1,
          'type': 'TYPE_ENUM',
          'enumValues': enumMap,
          if (jsonFormat != null) 'features': {featureJsonFormat: jsonFormat},
        },
      ];
      final allow = desc(jsonFormatAllow);
      final bestEffort = desc(jsonFormatLegacyBestEffort);
      final noFeatures = desc(null);

      test('known name and numeric literal decode under ALLOW', () {
        expect(unmarshalJson('{"e":"B"}', allow)['e'], 1);
        expect(unmarshalJson('{"e":"1"}', allow)['e'], 1);
      });
      test('unknown enum name is rejected under ALLOW', () {
        expect(
          () => unmarshalJson('{"e":"NOPE"}', allow),
          throwsFormatException,
        );
      });
      test('unknown enum name tolerated under LEGACY_BEST_EFFORT', () {
        expect(unmarshalJson('{"e":"NOPE"}', bestEffort)['e'], 'NOPE');
      });
      test(
        'unknown enum name tolerated when features absent (back-compat)',
        () {
          expect(unmarshalJson('{"e":"NOPE"}', noFeatures)['e'], 'NOPE');
        },
      );
    });

    group('utf8_validation = VERIFY', () {
      final loneSurrogate = String.fromCharCode(0xD800);
      List<Map<String, Object?>> desc(String? utf8) => [
        {
          'name': 's',
          'number': 1,
          'type': 'TYPE_STRING',
          if (utf8 != null) 'features': {featureUtf8Validation: utf8},
        },
      ];
      final verify = desc(utf8ValidationVerify);
      final none = desc(utf8ValidationNone);
      final noFeatures = desc(null);

      test('encode rejects an ill-formed string under VERIFY', () {
        expect(
          () => marshalJson({'s': loneSurrogate}, verify),
          throwsFormatException,
        );
      });
      test('encode tolerates it under NONE / no features', () {
        expect(marshalJson({'s': loneSurrogate}, none), isNotEmpty);
        expect(marshalJson({'s': loneSurrogate}, noFeatures), isNotEmpty);
      });
      test('decode rejects an ill-formed string under VERIFY', () {
        expect(
          () => unmarshalJson('{"s":"\\uD800"}', verify),
          throwsFormatException,
        );
      });
      test('decode tolerates it under NONE', () {
        expect(unmarshalJson('{"s":"\\uD800"}', none)['s'], isA<String>());
      });
      test('a well-formed (paired-surrogate) string passes VERIFY', () {
        // U+1F600 😀 = surrogate pair D83D DE00 — valid.
        final emoji = String.fromCharCodes([0xD83D, 0xDE00]);
        expect(marshalJson({'s': emoji}, verify), isNotEmpty);
        expect(
          unmarshalJson(marshalJson({'s': emoji}, verify), verify)['s'],
          emoji,
        );
      });
    });

    test('cross-format presence consistency (binary EXPLICIT 0 ↔ JSON)', () {
      final desc = [
        {
          'name': 'x',
          'number': 1,
          'type': 'TYPE_INT32',
          'features': {featureFieldPresence: fieldPresenceExplicit},
        },
      ];
      // A present default (0) survives a binary round-trip...
      final decoded = unmarshal(marshal({'x': 0}, desc), desc);
      expect(decoded['x'], 0);
      // ...and is then emitted in JSON (presence preserved across formats).
      expect(marshalJson(decoded, desc), '{"x":0}');
    });
  });

  // Regressions surfaced by the Phase 3 adversarial review.
  group('Phase 3 review regressions', () {
    test('unknown group field inside a map entry is skipped, not fatal', () {
      // map<int,int> entry {1:2} carrying an unknown field 3 as an empty group.
      // Bytes: f1 LEN len6 = [key f1=1][value f2=2][f3 START_GROUP][f3 END_GROUP]
      final mapDesc = [
        {
          'name': 'mp',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'mapEntry': true,
          'keyType': 'TYPE_INT32',
          'valueType': 'TYPE_INT32',
        },
      ];
      final bytes = [10, 6, 8, 1, 16, 2, 27, 28];
      expect(unmarshal(bytes, mapDesc)['mp'], {1: 2});
    });

    test('map<int, DELIMITED-message> value decodes (group-valued map)', () {
      final mapMsgDesc = [
        {
          'name': 'mp',
          'number': 1,
          'type': 'TYPE_MESSAGE',
          'mapEntry': true,
          'keyType': 'TYPE_INT32',
          'valueType': 'TYPE_MESSAGE',
          'messageDescriptor': [
            {'name': 'n', 'number': 1, 'type': 'TYPE_INT32'},
          ],
        },
      ];
      // entry: key f1=1; value f2 as group {n:5} = START_GROUP [8,5] END_GROUP.
      final bytes = [10, 6, 8, 1, 19, 8, 5, 20];
      expect(unmarshal(bytes, mapMsgDesc)['mp'], {
        1: {'n': 5},
      });
    });

    test('CLOSED routing works with the JSON-codec Map enumValues shape', () {
      final open = [
        {'name': 'e', 'number': 1, 'type': 'TYPE_ENUM'},
      ];
      final closedMap = [
        {
          'name': 'e',
          'number': 1,
          'type': 'TYPE_ENUM',
          'features': {featureEnumType: enumTypeClosed},
          'enumValues': {
            0: 'A',
            1: 'B',
            2: 'C',
          }, // Map<int,String> (JSON shape)
        },
      ];
      expect(
        unmarshal(marshal({'e': 99}, open), closedMap).containsKey('e'),
        isFalse,
      );
      expect(unmarshal(marshal({'e': 2}, open), closedMap)['e'], 2);
    });

    test('START_GROUP on a known non-message field is skipped, not fatal', () {
      final desc = [
        {'name': 'x', 'number': 1, 'type': 'TYPE_INT32'},
        {'name': 'y', 'number': 2, 'type': 'TYPE_INT32'},
      ];
      // field 1 (an int32) arrives as a group; field 2 = 7 must still decode.
      final bytes = [11, 8, 42, 12, 16, 7];
      final decoded = unmarshal(bytes, desc);
      expect(decoded.containsKey('x'), isFalse);
      expect(decoded['y'], 7);
    });

    test('truncated LEN length throws FormatException (not RangeError)', () {
      final desc = [
        {'name': 's', 'number': 1, 'type': 'TYPE_STRING'},
      ];
      // tag f1 LEN, declared length 99, but only 1 payload byte present.
      expect(() => unmarshal([10, 99, 65], desc), throwsFormatException);
    });
  });
}
