/// Tests for protobuf Editions feature resolution.
///
/// The edition-defaults expectations below are the ground truth emitted by
/// `protoc --edition_defaults_out` (protoc 28.2) and checked into
/// tests/editions/golden/featureset_defaults.txtpb. If protoc's defaults
/// change, regenerate that golden AND update these expectations together.
library;

import 'package:ball_base/protobuf/edition.dart';
import 'package:ball_base/protobuf/editions.dart';
import 'package:test/test.dart';

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
      expect(baseFeaturesForEdition(editionProto2),
          baseFeaturesForEdition(editionLegacy));
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
      expect(baseFeaturesForEdition(edition2024),
          baseFeaturesForEdition(edition2023));
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
          expect(f.containsKey(key), isTrue,
              reason: '$key missing for ${editionToName(ed)}');
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

  group('resolveFileFeatures', () {
    test('no overrides == base', () {
      expect(resolveFileFeatures(edition2023, null),
          baseFeaturesForEdition(edition2023));
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
      expect(() => resolveFileFeatures(editionUnknown, null),
          throwsArgumentError);
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
      expect(field[featureFieldPresence], fieldPresenceImplicit); // own override
      expect(field[featureRepeatedFieldEncoding],
          repeatedFieldEncodingPacked); // from edition base
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
      expect(() => resolveFeatures('proto9', null, null, null),
          throwsArgumentError);
    });
  });

  group('legacy inference', () {
    test('proto2 required -> LEGACY_REQUIRED', () {
      final f = inferLegacyFieldFeatures(
          'LABEL_REQUIRED', 'TYPE_INT32', false, null, editionProto2);
      expect(f[featureFieldPresence], fieldPresenceLegacyRequired);
    });

    test('proto3 singular scalar -> IMPLICIT', () {
      final f = inferLegacyFieldFeatures(
          'LABEL_OPTIONAL', 'TYPE_INT32', false, null, editionProto3);
      expect(f[featureFieldPresence], fieldPresenceImplicit);
    });

    test('proto3 optional -> EXPLICIT', () {
      final f = inferLegacyFieldFeatures(
          'LABEL_OPTIONAL', 'TYPE_INT32', true, null, editionProto3);
      expect(f[featureFieldPresence], fieldPresenceExplicit);
    });

    test('group type -> DELIMITED', () {
      final f = inferLegacyFieldFeatures(
          'LABEL_OPTIONAL', 'TYPE_GROUP', false, null, editionProto2);
      expect(f[featureMessageEncoding], messageEncodingDelimited);
    });

    test('packed option', () {
      expect(
        inferLegacyFieldFeatures(
            'LABEL_REPEATED', 'TYPE_INT32', false, 'true', editionProto2)[
                featureRepeatedFieldEncoding],
        repeatedFieldEncodingPacked,
      );
      expect(
        inferLegacyFieldFeatures(
            'LABEL_REPEATED', 'TYPE_INT32', false, 'false', editionProto3)[
                featureRepeatedFieldEncoding],
        repeatedFieldEncodingExpanded,
      );
    });

    test('proto2 field inference == editions equivalence (presence)', () {
      // A proto2 required field, fully resolved, must have LEGACY_REQUIRED
      // presence on top of the proto2 (LEGACY) base.
      final base = resolveFileFeatures(editionProto2, null);
      final inferred = inferLegacyFieldFeatures(
          'LABEL_REQUIRED', 'TYPE_STRING', false, null, editionProto2);
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
          isPackedRepeated(
              {featureRepeatedFieldEncoding: repeatedFieldEncodingPacked}),
          isTrue);
      expect(
          isExpandedRepeated(
              {featureRepeatedFieldEncoding: repeatedFieldEncodingExpanded}),
          isTrue);
      expect(isDelimited({featureMessageEncoding: messageEncodingDelimited}),
          isTrue);
      expect(
          requiresUtf8Validation({featureUtf8Validation: utf8ValidationVerify}),
          isTrue);
      expect(jsonFormatIsAllow({featureJsonFormat: jsonFormatAllow}), isTrue);
    });
  });
}
