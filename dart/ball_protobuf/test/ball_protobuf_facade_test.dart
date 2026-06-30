/// Verifies the generated `ball_protobuf` artifact is a well-formed, self-
/// contained facade [Module] (see docs/EDITIONS_SPEC.md) carrying the editions
/// engine — the structural prerequisite for the cross-target portability proof.
///
/// This guards the shape produced by `dart/encoder/bin/gen_ball_protobuf.dart`:
/// a `ball.v1.Module` (not a `Program`), with no functions of its own, whose
/// `module_imports[]` embed each implementation module inline. If the generator
/// or any protobuf source changes the surface, regenerate and update here.
library;

import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show InlineSource, Module, decodeModuleBinary, decodeModuleJson;
import 'package:test/test.dart';

/// Decodes an embedded module from whichever `InlineSource` oneof variant the
/// generator emitted. `gen_ball_protobuf.dart` inlines each module as
/// `jsonEncode(m.toProto3Json())` (the `inline.json` variant — a BARE proto3
/// module, not a self-describing `@type` envelope, so `decodeModuleJson` does
/// not apply); tolerate the binary (`inline.protoBytes`) variant too so the
/// test tracks the artifact rather than one encoding.
Module _decodeInline(InlineSource inline) => inline.hasJson()
    ? (Module()..mergeFromProto3Json(jsonDecode(inline.json)))
    : decodeModuleBinary(inline.protoBytes);

/// Locates `ball_protobuf.{json,bin}` (committed under dart/shared) from the
/// test CWD (the package root under `dart test`).
File _artifact(String name) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/$name');
    if (f.existsSync()) return f;
    final g = File('${dir.path}/dart/shared/$name');
    if (g.existsSync()) return g;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate $name from ${Directory.current.path}');
}

void main() {
  group('ball_protobuf facade Module', () {
    late Module facade;
    late Map<String, Module> inlineModules;

    setUpAll(() {
      facade = decodeModuleJson(
        jsonDecode(_artifact('ball_protobuf.json').readAsStringSync()),
      );
      inlineModules = {
        for (final imp in facade.moduleImports)
          _decodeInline(imp.inline).name: _decodeInline(imp.inline),
      };
    });

    test('decodes as ball.v1.Module named ball_protobuf', () {
      expect(facade.name, 'ball_protobuf');
    });

    test('is a pure facade — no functions of its own', () {
      expect(facade.functions, isEmpty);
    });

    test('embeds every implementation module inline (no std bundled)', () {
      expect(facade.moduleImports, isNotEmpty);
      for (final imp in facade.moduleImports) {
        expect(imp.hasInline(), isTrue, reason: '${imp.name} not inline');
        expect(
          imp.inline.hasJson() || imp.inline.protoBytes.isNotEmpty,
          isTrue,
          reason: '${imp.name} has no inline content',
        );
        // The import alias matches the embedded module's own name.
        expect(_decodeInline(imp.inline).name, imp.name);
      }
      // A library does not ship std / std_collections / proto.
      for (final name in inlineModules.keys) {
        expect(name, startsWith('ball_protobuf.'));
      }
    });

    test('carries the editions resolver + feature-aware codec modules', () {
      expect(
        inlineModules.keys,
        containsAll(<String>[
          'ball_protobuf.edition',
          'ball_protobuf.editions',
          'ball_protobuf.marshal',
          'ball_protobuf.unmarshal',
          'ball_protobuf.json_codec',
        ]),
      );
    });

    test('editions module exposes the resolution + behavior API', () {
      final editions = inlineModules['ball_protobuf.editions']!;
      final fnNames = editions.functions.map((f) => f.name).toSet();
      expect(
        fnNames,
        containsAll(<String>[
          'resolveFileFeatures',
          'mergeChildFeatures',
          'mergeFeatureSet',
          'baseFeaturesForEdition',
          'isFixedFeature',
          'inferLegacyFieldFeatures',
          'inferLegacyFileFeatures',
          'hasExplicitPresence',
          'isClosedEnum',
          'isDelimited',
          'requiresUtf8Validation',
          'jsonFormatIsAllow',
        ]),
      );
    });

    test('JSON and binary artifacts decode to the same module set', () {
      final fromBin = decodeModuleBinary(
        _artifact('ball_protobuf.bin').readAsBytesSync(),
      );
      expect(fromBin.name, facade.name);
      expect(
        fromBin.moduleImports.map((i) => i.name).toSet(),
        facade.moduleImports.map((i) => i.name).toSet(),
      );
    });
  });
}
