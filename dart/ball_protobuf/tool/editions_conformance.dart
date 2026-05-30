/// Editions conformance harness for Ball's portable protobuf engine.
///
/// This is the executable counterpart to the official protobuf conformance
/// runner for the parts Ball can self-check without embedding the upstream
/// `TestAllTypes*` descriptors: it proves that
///
///   1. the LEGACY (proto2/proto3) resolution path and the equivalent EDITIONS
///      path produce identical resolved FeatureSets, and
///   2. feature-aware binary + JSON codecs encode/decode identically for both
///      paths and round-trip cleanly across the feature matrix.
///
/// It prints `Results: N passed, M failed, T total` (the format the conformance
/// CI matrix scrapes) and exits non-zero on any failure, so it can gate CI.
///
/// Run: `cd dart/shared && dart run tool/editions_conformance.dart`
/// (wrappers: `tests/editions/conformance_runner.ps1` / `.sh`).
library;

import 'dart:io';

import 'package:ball_protobuf/edition.dart';
import 'package:ball_protobuf/editions.dart';
import 'package:ball_protobuf/json_codec.dart';
import 'package:ball_protobuf/marshal.dart';
import 'package:ball_protobuf/unmarshal.dart';

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];

void _check(String name, bool Function() body) {
  try {
    if (body()) {
      _passed++;
    } else {
      _failed++;
      _failures.add(name);
    }
  } catch (e) {
    _failed++;
    _failures.add('$name (threw: $e)');
  }
}

bool _bytesEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEq(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// Resolved features for a legacy (proto2/proto3) field: the syntax's edition
/// floor overlaid with the inferred field-shape features. Legacy inference is
/// applied directly (not as a user `features` override), so FIXED-feature
/// validation does not apply — matching descriptor.cc.
Map<String, String> _legacyField(int edition, Map<String, String> inferred) {
  return <String, String>{}
    ..addAll(baseFeaturesForEdition(edition))
    ..addAll(inferred);
}

List<Map<String, Object?>> _field(
  String type,
  Map<String, String> features, {
  bool repeated = false,
  List<Map<String, Object?>>? messageDescriptor,
}) {
  final field = <String, Object?>{
    'name': 'f',
    'number': 1,
    'type': type,
    'features': features,
  };
  if (repeated) {
    field['label'] = 'LABEL_REPEATED';
    field['repeated'] = true;
  }
  if (messageDescriptor != null) {
    field['messageDescriptor'] = messageDescriptor;
  }
  return [field];
}

void main() {
  // ---- Resolved-features equivalence (legacy path == editions overrides) ----

  _check(
    'proto3 singular int32 resolves == edition2023[field_presence=IMPLICIT]',
    () {
      final legacy = _legacyField(
        editionProto3,
        inferLegacyFieldFeatures(
          'LABEL_OPTIONAL',
          'TYPE_INT32',
          false,
          null,
          editionProto3,
        ),
      );
      final editions = mergeFeatureSet(baseFeaturesForEdition(edition2023), {
        featureFieldPresence: fieldPresenceImplicit,
      }, edition2023);
      return _mapEq(legacy, editions);
    },
  );

  _check('proto2 file features == edition2023 overridden to legacy values', () {
    final proto2 = baseFeaturesForEdition(editionProto2);
    final editions = mergeFeatureSet(baseFeaturesForEdition(edition2023), {
      featureFieldPresence: fieldPresenceExplicit,
      featureEnumType: enumTypeClosed,
      featureRepeatedFieldEncoding: repeatedFieldEncodingExpanded,
      featureUtf8Validation: utf8ValidationNone,
      featureJsonFormat: jsonFormatLegacyBestEffort,
    }, edition2023);
    return _mapEq(proto2, editions);
  });

  // ---- Wire equivalence: legacy path encodes identically to editions path ----

  _check('proto3 IMPLICIT int32 wire == edition2023[IMPLICIT] wire', () {
    final legacy = _field(
      'TYPE_INT32',
      _legacyField(
        editionProto3,
        inferLegacyFieldFeatures(
          'LABEL_OPTIONAL',
          'TYPE_INT32',
          false,
          null,
          editionProto3,
        ),
      ),
    );
    final editions = _field(
      'TYPE_INT32',
      mergeFeatureSet(baseFeaturesForEdition(edition2023), {
        featureFieldPresence: fieldPresenceImplicit,
      }, edition2023),
    );
    return _bytesEq(marshal({'f': 0}, legacy), marshal({'f': 0}, editions)) &&
        _bytesEq(marshal({'f': 5}, legacy), marshal({'f': 5}, editions)) &&
        marshal({'f': 0}, legacy).isEmpty; // IMPLICIT elides default
  });

  _check('proto2 EXPLICIT int32 serializes default 0 (both paths)', () {
    final legacy = _field(
      'TYPE_INT32',
      _legacyField(
        editionProto2,
        inferLegacyFieldFeatures(
          'LABEL_OPTIONAL',
          'TYPE_INT32',
          false,
          null,
          editionProto2,
        ),
      ),
    );
    final editions = _field(
      'TYPE_INT32',
      mergeFeatureSet(baseFeaturesForEdition(edition2023), {
        featureFieldPresence: fieldPresenceExplicit,
      }, edition2023),
    );
    return _bytesEq(marshal({'f': 0}, legacy), marshal({'f': 0}, editions)) &&
        marshal({'f': 0}, legacy).isNotEmpty; // EXPLICIT keeps default 0
  });

  _check('proto2 required int32 == edition2023[LEGACY_REQUIRED] wire', () {
    final legacy = _field(
      'TYPE_INT32',
      _legacyField(
        editionProto2,
        inferLegacyFieldFeatures(
          'LABEL_REQUIRED',
          'TYPE_INT32',
          false,
          null,
          editionProto2,
        ),
      ),
    );
    final editions = _field(
      'TYPE_INT32',
      mergeFeatureSet(baseFeaturesForEdition(edition2023), {
        featureFieldPresence: fieldPresenceLegacyRequired,
      }, edition2023),
    );
    return _bytesEq(marshal({'f': 0}, legacy), marshal({'f': 0}, editions));
  });

  _check('proto2 repeated EXPANDED == edition2023[EXPANDED] wire', () {
    final legacy = _field(
      'TYPE_INT32',
      _legacyField(
        editionProto2,
        inferLegacyFieldFeatures(
          'LABEL_REPEATED',
          'TYPE_INT32',
          false,
          null,
          editionProto2,
        ),
      ),
      repeated: true,
    );
    final editions = _field(
      'TYPE_INT32',
      mergeFeatureSet(baseFeaturesForEdition(edition2023), {
        featureRepeatedFieldEncoding: repeatedFieldEncodingExpanded,
      }, edition2023),
      repeated: true,
    );
    final data = {
      'f': [1, 2, 3],
    };
    return _bytesEq(marshal(data, legacy), marshal(data, editions));
  });

  _check('proto2 group == edition2023[DELIMITED] wire', () {
    final sub = [
      {'name': 'n', 'number': 1, 'type': 'TYPE_INT32'},
    ];
    final legacy = _field(
      'TYPE_MESSAGE',
      _legacyField(
        editionProto2,
        inferLegacyFieldFeatures(
          'LABEL_OPTIONAL',
          'TYPE_GROUP',
          false,
          null,
          editionProto2,
        ),
      ),
      messageDescriptor: sub,
    );
    final editions = _field(
      'TYPE_MESSAGE',
      mergeFeatureSet(baseFeaturesForEdition(edition2023), {
        featureMessageEncoding: messageEncodingDelimited,
      }, edition2023),
      messageDescriptor: sub,
    );
    final data = {
      'f': {'n': 7},
    };
    return _bytesEq(marshal(data, legacy), marshal(data, editions));
  });

  // ---- Feature-matrix round-trips (binary) ----

  _check('EXPLICIT scalar binary round-trip preserves present default', () {
    final desc = _field('TYPE_INT32', {
      featureFieldPresence: fieldPresenceExplicit,
    });
    return unmarshal(marshal({'f': 0}, desc), desc)['f'] == 0;
  });

  _check('EXPANDED repeated binary round-trip keeps 0 elements', () {
    final desc = _field('TYPE_INT32', {
      featureRepeatedFieldEncoding: repeatedFieldEncodingExpanded,
    }, repeated: true);
    final rt = unmarshal(
      marshal({
        'f': [1, 0, 3],
      }, desc),
      desc,
    )['f'];
    return rt is List && _bytesEq(rt.cast<int>(), [1, 0, 3]);
  });

  _check('DELIMITED message binary round-trip', () {
    final sub = [
      {'name': 'n', 'number': 1, 'type': 'TYPE_INT32'},
    ];
    final desc = _field('TYPE_MESSAGE', {
      featureMessageEncoding: messageEncodingDelimited,
    }, messageDescriptor: sub);
    final data = {
      'f': {'n': 9},
    };
    final rt = unmarshal(marshal(data, desc), desc)['f'];
    return rt is Map && rt['n'] == 9;
  });

  _check('CLOSED enum drops out-of-range value on decode', () {
    final open = _field('TYPE_ENUM', {featureEnumType: enumTypeOpen});
    final closed = [
      {
        'name': 'f',
        'number': 1,
        'type': 'TYPE_ENUM',
        'features': {featureEnumType: enumTypeClosed},
        'enumValues': {0: 'A', 1: 'B'},
      },
    ];
    final bytes = marshal({'f': 99}, open);
    return !unmarshal(bytes, closed).containsKey('f') &&
        unmarshal(bytes, open)['f'] == 99;
  });

  // ---- Feature-matrix round-trips (JSON) ----

  _check('EXPLICIT presence emits present default in JSON; IMPLICIT omits', () {
    final explicit = _field('TYPE_INT32', {
      featureFieldPresence: fieldPresenceExplicit,
    });
    final implicit = _field('TYPE_INT32', {
      featureFieldPresence: fieldPresenceImplicit,
    });
    return marshalJson({'f': 0}, explicit) == '{"f":0}' &&
        marshalJson({'f': 0}, implicit) == '{}';
  });

  _check('utf8_validation=VERIFY rejects ill-formed string in JSON', () {
    final verify = _field('TYPE_STRING', {
      featureUtf8Validation: utf8ValidationVerify,
    });
    try {
      marshalJson({'f': String.fromCharCode(0xD800)}, verify);
      return false; // should have thrown
    } on FormatException {
      return true;
    }
  });

  _check('json_format=ALLOW rejects unknown enum name', () {
    final allow = [
      {
        'name': 'f',
        'number': 1,
        'type': 'TYPE_ENUM',
        'enumValues': {0: 'A', 1: 'B'},
        'features': {featureJsonFormat: jsonFormatAllow},
      },
    ];
    try {
      unmarshalJson('{"f":"NOPE"}', allow);
      return false;
    } on FormatException {
      return true;
    }
  });

  // ---- Report ----
  for (final f in _failures) {
    stderr.writeln('FAIL: $f');
  }
  final total = _passed + _failed;
  stdout.writeln('Results: $_passed passed, $_failed failed, $total total');
  if (_failed > 0) exit(1);
}
