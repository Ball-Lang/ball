/// ISSUE A regression gate: the **per-file** plugin path emits SEPARATE
/// `.pb.dart` files (not one combined file), and a message in `b.proto` whose
/// fields reference types defined in `a.proto` (a sibling generated file) AND a
/// `google.protobuf.Any` packing an `a.proto` type both round-trip — binary
/// (`toBytes`/`fromBytes`) and proto3-JSON (`toProto3Json`/`fromProto3Json`) —
/// AND the emitted files compile (analyze clean).
///
/// Before the fix, each emitted `.pb.dart`'s descriptor registry only held its
/// own file's types and emitted no sibling imports, so `$descriptorFor(ref)` for
/// a cross-file message field threw at runtime and cross-file Any-in-JSON failed.
///
/// We build a small `FileDescriptorSet` programmatically (no protoc needed):
///   * `cf/a.proto`   — package `cf.a`: `enum Color`, `message Inner`.
///   * `google/protobuf/any.proto` — the stock `Any` message.
///   * `cf/b.proto`   — package `cf.b`, imports both: `message Outer` with an
///                      `Inner` field, a `Color` field, and an `Any` field.
/// The plugin generates three separate files. We write them to a temp dir,
/// emit a tiny driver that imports `b.pb.dart` (which transitively imports the
/// siblings) and exercises the round-trips, then run it with `dart run`. The
/// driver only compiles + runs green if cross-file resolution works — proving
/// "analyze clean" and "round-trips" in one shot, CWD-independent.
@TestOn('vm')
library;

import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show
        DescriptorProto,
        EnumDescriptorProto,
        EnumValueDescriptorProto,
        FieldDescriptorProto,
        FieldDescriptorProto_Label,
        FieldDescriptorProto_Type,
        FileDescriptorProto,
        FileDescriptorSet;
import 'package:ball_protobuf_gen/ball_protobuf_gen.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Programmatic FileDescriptorSet for the two cross-referencing protos + Any.
// ---------------------------------------------------------------------------

FieldDescriptorProto _field(
  String name,
  int number,
  FieldDescriptorProto_Type type, {
  String? typeName,
  FieldDescriptorProto_Label label = FieldDescriptorProto_Label.LABEL_OPTIONAL,
}) {
  final f = FieldDescriptorProto()
    ..name = name
    ..number = number
    ..type = type
    ..label = label;
  if (typeName != null) f.typeName = typeName;
  return f;
}

/// `cf/a.proto` (proto3): enum Color + message Inner.
FileDescriptorProto _aProto() {
  final color = EnumDescriptorProto()
    ..name = 'Color'
    ..value.addAll([
      EnumValueDescriptorProto()
        ..name = 'COLOR_UNKNOWN'
        ..number = 0,
      EnumValueDescriptorProto()
        ..name = 'RED'
        ..number = 1,
      EnumValueDescriptorProto()
        ..name = 'GREEN'
        ..number = 2,
    ]);
  final inner = DescriptorProto()
    ..name = 'Inner'
    ..field.addAll([
      _field('label', 1, FieldDescriptorProto_Type.TYPE_STRING),
      _field('score', 2, FieldDescriptorProto_Type.TYPE_INT32),
      _field(
        'color',
        3,
        FieldDescriptorProto_Type.TYPE_ENUM,
        typeName: '.cf.a.Color',
      ),
    ]);
  return FileDescriptorProto()
    ..name = 'cf/a.proto'
    ..package = 'cf.a'
    ..syntax = 'proto3'
    ..messageType.add(inner)
    ..enumType.add(color);
}

/// `google/protobuf/any.proto`: the stock Any message ({type_url, value}).
FileDescriptorProto _anyProto() {
  final any = DescriptorProto()
    ..name = 'Any'
    ..field.addAll([
      _field('type_url', 1, FieldDescriptorProto_Type.TYPE_STRING),
      _field('value', 2, FieldDescriptorProto_Type.TYPE_BYTES),
    ]);
  return FileDescriptorProto()
    ..name = 'google/protobuf/any.proto'
    ..package = 'google.protobuf'
    ..syntax = 'proto3'
    ..messageType.add(any);
}

/// `cf/b.proto` (proto3): message Outer referencing cf.a.Inner, cf.a.Color, and
/// google.protobuf.Any — all defined in sibling generated files.
FileDescriptorProto _bProto() {
  final outer = DescriptorProto()
    ..name = 'Outer'
    ..field.addAll([
      _field(
        'inner',
        1,
        FieldDescriptorProto_Type.TYPE_MESSAGE,
        typeName: '.cf.a.Inner',
      ),
      _field(
        'color',
        2,
        FieldDescriptorProto_Type.TYPE_ENUM,
        typeName: '.cf.a.Color',
      ),
      _field(
        'payload',
        3,
        FieldDescriptorProto_Type.TYPE_MESSAGE,
        typeName: '.google.protobuf.Any',
      ),
    ]);
  return FileDescriptorProto()
    ..name = 'cf/b.proto'
    ..package = 'cf.b'
    ..syntax = 'proto3'
    ..dependency.addAll(['cf/a.proto', 'google/protobuf/any.proto'])
    ..messageType.add(outer);
}

List<int> _buildFds() =>
    (FileDescriptorSet()..file.addAll([_aProto(), _anyProto(), _bProto()]))
        .writeToBuffer();

/// Locates the active `.dart_tool/package_config.json` (the Dart workspace
/// resolves all packages through a single one at the **workspace** root, not
/// per package), so the generated-driver subprocess can resolve
/// `package:ball_protobuf` / `package:ball_base`. Walks up from the CWD.
String _packageConfigPath() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    final f = File('${dir.path}/.dart_tool/package_config.json');
    if (f.existsSync()) return f.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate .dart_tool/package_config.json from '
    '${Directory.current.path}; run `dart pub get` in dart/ first.',
  );
}

void main() {
  late List<GeneratedDartFile> generated;

  setUpAll(() {
    generated = generateDartModels(
      _buildFds(),
      filesToGenerate: {
        'cf/a.proto',
        'cf/b.proto',
        'google/protobuf/any.proto',
      },
    );
  });

  group('per-file emission', () {
    test('emits SEPARATE files, one per .proto (not combined)', () {
      final paths = {for (final g in generated) g.path};
      expect(paths, {
        'cf/a.pb.dart',
        'cf/b.pb.dart',
        'google/protobuf/any.pb.dart',
      });
    });

    test('b.pb.dart imports its sibling a.pb.dart and any.pb.dart', () {
      final b = generated.firstWhere((g) => g.path == 'cf/b.pb.dart').content;
      // Sibling imports with stable $importN prefixes, relative to cf/.
      expect(b, contains("import 'a.pb.dart' as \$import"));
      expect(
        b,
        contains("import '../google/protobuf/any.pb.dart' as \$import"),
      );
      // The cross-file descriptor link is routed through $descriptorFor, which
      // now consults imported resolvers.
      expect(b, contains('\$importedResolvers'));
      // The Outer.inner getter is typed against the imported Inner class.
      expect(b, contains('.Inner? get inner'));
    });

    test('a.pb.dart is self-contained (no imports, no imported resolvers)', () {
      final a = generated.firstWhere((g) => g.path == 'cf/a.pb.dart').content;
      expect(a, isNot(contains("import 'b.pb.dart'")));
      expect(a, isNot(contains('\$importedResolvers')));
    });
  });

  group('cross-file round-trip + analyze clean (subprocess driver)', () {
    test('generated files compile and a cross-file message round-trips', () {
      final tmp = Directory.systemTemp.createTempSync('ball_cross_file_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });

      // 1) Write the three generated files under a `gen/` package-uri-resolvable
      //    layout that mirrors their `/`-separated output paths.
      final genDir = Directory('${tmp.path}/gen')..createSync(recursive: true);
      for (final g in generated) {
        final outFile = File('${genDir.path}/${g.path}');
        outFile.parent.createSync(recursive: true);
        outFile.writeAsStringSync(g.content);
      }

      // 2) A driver that imports b.pb.dart (which transitively imports the
      //    siblings) and exercises every cross-file path. It returns a non-zero
      //    exit code (via thrown assertion) on any failure.
      final driver = File('${tmp.path}/driver.dart');
      driver.writeAsStringSync(_driverSource);

      // 3) The driver imports the generated files by relative path and
      //    package:ball_protobuf via the workspace's package_config — so run it
      //    with `--packages` pointed at the active workspace package_config.
      final pkgConfig = _packageConfigPath();

      final result = Process.runSync('dart', [
        'run',
        '--packages=$pkgConfig',
        driver.path,
      ], workingDirectory: tmp.path);

      // The driver prints diagnostics on stdout; surface them on failure.
      expect(
        result.exitCode,
        0,
        reason:
            'driver failed.\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('CROSS_FILE_OK'));
    });
  });
}

/// The subprocess driver source. It imports the generated `b.pb.dart` by
/// relative path (which pulls in `a.pb.dart` + `any.pb.dart`), builds an
/// `Outer` whose fields reference the sibling-defined `Inner`/`Color` and an
/// `Any` packing an `Inner`, and asserts binary + JSON round-trips. Any failure
/// throws (non-zero exit); success prints `CROSS_FILE_OK`.
const String _driverSource = r'''
import 'gen/cf/b.pb.dart' as b;
import 'gen/cf/a.pb.dart' as a;
import 'gen/google/protobuf/any.pb.dart' as wkt;

void check(bool cond, String msg) {
  if (!cond) throw StateError('FAILED: $msg');
}

void main() {
  // Build the inner (sibling-file) message + enum.
  final inner = a.Inner()
    ..label = 'hi'
    ..score = 7
    ..color = a.Color.green;

  // An Any packing the sibling Inner.
  final any = wkt.Any()
    ..typeUrl = 'type.googleapis.com/cf.a.Inner'
    ..value = inner.toBytes();

  final outer = b.Outer()
    ..inner = inner
    ..color = a.Color.red
    ..payload = any;

  // (1) Binary round-trip through the cross-file descriptor graph.
  final bytes = outer.toBytes();
  final decoded = b.Outer.fromBytes(bytes);
  check(decoded.inner != null, 'inner present after fromBytes');
  check(decoded.inner!.label == 'hi', 'inner.label');
  check(decoded.inner!.score == 7, 'inner.score');
  check(decoded.inner!.color == a.Color.green, 'inner.color (cross-file enum)');
  check(decoded.color == a.Color.red, 'outer.color (cross-file enum)');
  check(decoded.payload != null, 'payload present');
  // Unpack the Any value back into the sibling Inner.
  final unpacked = a.Inner.fromBytes(decoded.payload!.value);
  check(unpacked.label == 'hi', 'unpacked Any inner.label');
  check(unpacked.color == a.Color.green, 'unpacked Any inner.color');

  // (2) proto3-JSON round-trip, including Any whose embedded type lives in a
  //     sibling file (resolved via the cross-file $descriptorForOrNull).
  final json = outer.toProto3Json() as Map<String, Object?>;
  check(json['color'] == 'RED', 'JSON cross-file enum name');
  final innerJson = json['inner'] as Map<String, Object?>;
  check(innerJson['label'] == 'hi', 'JSON cross-file message field');
  check(innerJson['color'] == 'GREEN', 'JSON cross-file nested enum name');
  final payloadJson = json['payload'] as Map<String, Object?>;
  check(payloadJson['@type'] == 'type.googleapis.com/cf.a.Inner',
      'Any @type in JSON');
  check(payloadJson['label'] == 'hi', 'Any embedded (sibling) field in JSON');
  check(payloadJson['color'] == 'GREEN', 'Any embedded sibling enum in JSON');

  final back = b.Outer.fromProto3Json(json);
  check(back.inner!.label == 'hi', 'JSON->msg cross-file inner.label');
  check(back.color == a.Color.red, 'JSON->msg cross-file color');
  final backInner = a.Inner.fromBytes(back.payload!.value);
  check(backInner.label == 'hi', 'JSON->msg Any embedded inner.label');

  print('CROSS_FILE_OK');
}
''';
