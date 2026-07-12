/// Self-host parity gate for the portable CLI verbs (issue #362).
///
/// For a golden set of `tests/conformance/*.ball.json` inputs, this asserts the
/// Dart-native `cli_core` verb output is **byte-identical** to the output of
/// the same verb executed by the Ball engine over the generated
/// `dart/self_host/cli.ball.json`. It is the hard proof that `cli_core`
/// genuinely self-hosts: the CLI a user runs natively and the CLI compiled to a
/// Ball program compute the same reports.
///
/// Regenerate `cli.ball.json` first (CI does this before running the suite):
///   cd dart && dart run compiler/tool/gen_cli_json.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ball_base/ball_base.dart'
    show BallProgramFile, Program, decodeBallFileJson, decodeProgramJson;
import 'package:ball_base/cli_core.dart' as cli;
import 'package:ball_engine/engine.dart';
import 'package:protobuf/protobuf.dart';
import 'package:test/test.dart';

/// Golden fixtures exercised by the parity gate. A deliberately varied slice of
/// the conformance corpus (control flow, classes, collections, strings) — each
/// a real Ball `Program` the verbs must render identically native vs. engine.
const _goldenFixtures = <String>[
  '100_complex_control_flow',
  '101_simple_class',
  '111_cascade_operator',
  '116_map_iteration',
  '118_set_operations',
];

/// Verbs whose full transitive call graph self-hosts on the Dart engine today.
/// This now includes `audit` (issue #362 residual): the capability +
/// termination analyzers were rewritten into engine-safe procedural Dart
/// (`part of cli_core.dart`, Map/List reports, `hasX()` presence cascades,
/// single-argument walkers) so `auditReport` — and the `analyzeCapabilities` +
/// `checkPolicyViolations` it composes — execute byte-identically native vs.
/// engine.
void main() {
  final repoRoot = _findRepoRoot();
  final cliProgram = _loadCliProgram(repoRoot);

  BallEngine newEngine() => BallEngine(
    cliProgram,
    moduleHandlers: [StdModuleHandler(), BallProtoHandler()],
    stdout: (_) {},
    stderr: (_) {},
  );

  group('cli_core self-host parity', () {
    for (final name in _goldenFixtures) {
      final file = File('$repoRoot/tests/conformance/$name.ball.json');
      test(name, () async {
        final program = decodeProgramJson(jsonDecode(file.readAsStringSync()));
        final input = protoToEngineMap(program);
        final engine = newEngine();

        for (final verb in [
          'infoReport',
          'validateReport',
          'treeReport',
          'auditReport',
        ]) {
          final native = _native(verb, program);
          final hosted = await engine.callFunction('main', verb, input);
          expect(
            hosted,
            equals(native),
            reason: 'verb "$verb" diverged on fixture "$name"',
          );
        }
      });
    }

    // Policy enforcement (`ball audit --deny io`): the capability report and
    // the violation list must match native vs. engine. Every golden fixture
    // calls `std.print` (io), so `deny: [io]` yields a non-empty violation set.
    for (final name in _goldenFixtures) {
      final file = File('$repoRoot/tests/conformance/$name.ball.json');
      test('$name deny-policy', () async {
        final program = decodeProgramJson(jsonDecode(file.readAsStringSync()));
        final input = protoToEngineMap(program);
        final engine = newEngine();

        final nativeViolations = cli.checkPolicy(
          cli.analyzeCapabilities(program),
          deny: {'io'},
        );
        expect(
          nativeViolations,
          isNotEmpty,
          reason: 'fixture "$name" should call std.print (io)',
        );

        final hostedReport = await engine.callFunction(
          'main',
          'analyzeCapabilities',
          input,
        );
        final hostedViolations = await engine.callFunction(
          'main',
          'checkPolicyViolations',
          {
            'report': hostedReport,
            'deny': ['io'],
          },
        );
        expect(
          hostedViolations,
          equals(nativeViolations),
          reason: 'deny-policy violations diverged on fixture "$name"',
        );
      });
    }

    // #402 regression: a base call whose call-site `module` string is spoofed
    // must still be categorized by its resolved base-fn identity — native AND
    // on the engine (a single audit implementation closes the bypass on every
    // target). Mirrors the investigation's repro (sec-dispatch c_spoofed /
    // d_spoofed_declared): `mutex_create` invoked under a benign-looking module.
    Program spoofProgram({required bool declareConcurrency}) {
      final modules = <Map<String, Object?>>[
        {
          'name': 'std',
          'functions': [
            {'name': 'print', 'isBase': true},
          ],
        },
        if (declareConcurrency)
          {
            'name': 'std_concurrency',
            'functions': [
              {'name': 'mutex_create', 'isBase': true},
            ],
          },
        {
          'name': 'main',
          'functions': [
            {
              'name': 'main',
              'outputType': 'void',
              'body': {
                'call': {
                  'module': 'harmless_looking_module',
                  'function': 'mutex_create',
                  'input': {
                    'messageCreation': {'fields': <Object?>[]},
                  },
                },
              },
            },
          ],
        },
      ];
      return Program()..mergeFromProto3Json({
        'name': 'spoof',
        'version': '1.0.0',
        'entryModule': 'main',
        'entryFunction': 'main',
        'modules': modules,
      }, ignoreUnknownFields: true);
    }

    for (final row in ['c_undeclared', 'd_declared']) {
      test('$row spoofed concurrency is denied — native == engine', () async {
        final program = spoofProgram(declareConcurrency: row == 'd_declared');
        final input = protoToEngineMap(program);
        final engine = newEngine();

        // Native: the spoofed call is now categorized as concurrency.
        final nativeViolations = cli.checkPolicy(
          cli.analyzeCapabilities(program),
          deny: {'concurrency'},
        );
        expect(
          nativeViolations,
          isNotEmpty,
          reason: 'spoofed mutex_create ($row) must trip --deny concurrency',
        );

        // Engine: same report, same violations (byte-identical audit).
        final hostedReport = await engine.callFunction(
          'main',
          'analyzeCapabilities',
          input,
        );
        final hostedViolations = await engine.callFunction(
          'main',
          'checkPolicyViolations',
          {
            'report': hostedReport,
            'deny': ['concurrency'],
          },
        );
        expect(
          hostedViolations,
          equals(nativeViolations),
          reason: 'spoof ($row) audit diverged native vs engine',
        );

        // And the full audit report text self-hosts identically.
        final nativeText = cli.auditReport(program);
        final hostedText = await engine.callFunction(
          'main',
          'auditReport',
          input,
        );
        expect(hostedText, equals(nativeText));
      });
    }

    // #420 regression: a program declaring a non-base user function whose bare
    // name collides with a capability base fn (a decoy `mutex_create`) must be
    // surfaced as a base-function shadow, not read as clean "NO RISK" — and the
    // shadow section + escalated summary must self-host byte-identically.
    test('decoy shadow is surfaced — native == engine (#420)', () async {
      final program = Program()
        ..mergeFromProto3Json({
          'name': 'decoy',
          'version': '1.0.0',
          'entryModule': 'main',
          'entryFunction': 'main',
          'modules': [
            {
              'name': 'std',
              'functions': [
                {'name': 'print', 'isBase': true},
              ],
            },
            {
              'name': 'main',
              'functions': [
                {
                  'name': 'main',
                  'outputType': 'void',
                  'body': {
                    'call': {
                      'module': 'main',
                      'function': 'mutex_create',
                      'input': {
                        'messageCreation': {'fields': <Object?>[]},
                      },
                    },
                  },
                },
                {
                  'name': 'mutex_create',
                  'outputType': 'void',
                  'body': {
                    'literal': {'intValue': '0'},
                  },
                },
              ],
            },
          ],
        }, ignoreUnknownFields: true);
      final input = protoToEngineMap(program);
      final engine = newEngine();

      final nativeText = cli.auditReport(program);
      // The shadow is visible and the pure summary is escalated.
      expect(nativeText, contains('Shadowed base functions:'));
      expect(
        nativeText,
        contains(
          'main.mutex_create shadows std_concurrency.mutex_create '
          '(concurrency, medium risk)',
        ),
      );
      expect(
        nativeText,
        contains('REVIEW REQUIRED — declares base-function shadows'),
      );

      final hostedText = await engine.callFunction(
        'main',
        'auditReport',
        input,
      );
      expect(hostedText, equals(nativeText));
    });

    test(
      'benign concurrency-free program stays clean — native == engine',
      () async {
        // Same shape but the entry only calls std.print — no concurrency.
        final program = Program()
          ..mergeFromProto3Json({
            'name': 'benign',
            'version': '1.0.0',
            'entryModule': 'main',
            'entryFunction': 'main',
            'modules': [
              {
                'name': 'std',
                'functions': [
                  {'name': 'print', 'isBase': true},
                ],
              },
              {
                'name': 'main',
                'functions': [
                  {
                    'name': 'main',
                    'outputType': 'void',
                    'body': {
                      'call': {
                        'module': 'std',
                        'function': 'print',
                        'input': {
                          'messageCreation': {
                            'fields': [
                              {
                                'name': 'message',
                                'value': {
                                  'literal': {'stringValue': 'hi'},
                                },
                              },
                            ],
                          },
                        },
                      },
                    },
                  },
                ],
              },
            ],
          }, ignoreUnknownFields: true);
        final input = protoToEngineMap(program);
        final engine = newEngine();

        final nativeViolations = cli.checkPolicy(
          cli.analyzeCapabilities(program),
          deny: {'concurrency'},
        );
        expect(nativeViolations, isEmpty);

        final hostedReport = await engine.callFunction(
          'main',
          'analyzeCapabilities',
          input,
        );
        final hostedViolations = await engine.callFunction(
          'main',
          'checkPolicyViolations',
          {
            'report': hostedReport,
            'deny': ['concurrency'],
          },
        );
        expect(hostedViolations, equals(nativeViolations));
        expect(hostedViolations, isEmpty);
      },
    );

    test('versionReport', () async {
      final engine = newEngine();
      for (final v in ['0.3.0+6', '1.0.0', '0.1.0']) {
        final hosted = await engine.callFunction('main', 'versionLine', v);
        expect(hosted, equals(cli.versionLine(v)));
      }
    });
  });
}

String _native(String verb, Program program) => switch (verb) {
  'infoReport' => cli.infoReport(program),
  'validateReport' => cli.validateReport(program),
  'treeReport' => cli.treeReport(program),
  'auditReport' => cli.auditReport(program),
  _ => throw ArgumentError('unknown verb $verb'),
};

Program _loadCliProgram(String repoRoot) {
  final path = '$repoRoot/dart/self_host/cli.ball.json';
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      'Missing $path — run `cd dart && dart run '
      'compiler/tool/gen_cli_json.dart` first.',
    );
  }
  final decoded = decodeBallFileJson(jsonDecode(file.readAsStringSync()));
  if (decoded is BallProgramFile) return decoded.program;
  throw StateError('cli.ball.json is not a Program');
}

// ── proto → engine-map normalizer ─────────────────────────────────────────
//
// The engine represents messages as `Map<String, Object?>` and *throws* on
// access to an absent field, while native proto getters return typed defaults
// and proto3 JSON omits defaults. So a faithful engine input must be a fully
// materialized map: every scalar/repeated field present with its default, and
// every presence-sensitive (message/oneof) field present iff actually set (so
// `hasX()`/`whichX()` stay faithful). Keys are the camelCase proto field names
// the encoder emits for field access.

Object? protoToEngineMap(Object? value) {
  if (value is GeneratedMessage) {
    final info = value.info_;
    final out = <String, Object?>{};
    for (final fi in info.fieldInfo.values) {
      final tag = fi.tagNumber;
      final presenceSensitive =
          info.oneofs.containsKey(tag) ||
          (!fi.isRepeated && !fi.isMapField && fi.subBuilder != null);
      if (presenceSensitive) {
        if (value.hasField(tag)) {
          out[fi.name] = protoToEngineMap(value.getField(tag));
        }
      } else {
        out[fi.name] = protoToEngineMap(value.getField(tag));
      }
    }
    return out;
  }
  if (value is List) {
    return value.map(protoToEngineMap).toList();
  }
  if (value is PbMap) {
    final out = <String, Object?>{};
    value.forEach((k, v) => out['$k'] = protoToEngineMap(v));
    return out;
  }
  if (value is ProtobufEnum) return value.name;
  return value;
}

// ── ball_proto handler ────────────────────────────────────────────────────
//
// The Dart engine ships only `StdModuleHandler`; it has never needed to run a
// self-hosted program that manipulates proto messages. This handler supplies
// the `ball_proto` presence/oneof accessors over the normalized maps so
// self-hosted verbs (`validate`, `tree`, …) execute on the engine. Inputs
// arrive as `{'obj': <messageMap>}` (the encoder's calling convention).

/// oneof discriminator → ordered variant field names (from `ball_proto.dart`).
const _oneofVariants = <String, List<String>>{
  'whichExpr': [
    'call',
    'literal',
    'reference',
    'fieldAccess',
    'messageCreation',
    'block',
    'lambda',
  ],
  'whichValue': [
    'intValue',
    'doubleValue',
    'stringValue',
    'boolValue',
    'bytesValue',
    'listValue',
  ],
  'whichStmt': ['let', 'expression'],
  'whichKind': [
    'nullValue',
    'numberValue',
    'stringValue',
    'boolValue',
    'structValue',
    'listValue',
  ],
  'whichSource': ['http', 'file', 'git', 'registry', 'inline'],
};

class BallProtoHandler extends BallModuleHandler {
  @override
  bool handles(String module) => module == 'ball_proto';

  @override
  FutureOr<Object?> call(String function, Object? input, BallCallable engine) {
    final obj = input is Map ? input['obj'] : null;
    final map = obj is Map ? obj : null;

    final variants = _oneofVariants[function];
    if (variants != null) {
      if (map != null) {
        for (final v in variants) {
          if (_present(map[v])) return v;
        }
      }
      return 'notSet';
    }

    if (function.startsWith('has') && function.length > 3) {
      final field = _lowerFirst(function.substring(3));
      return map != null && _present(map[field]);
    }

    throw StateError('ball_proto.$function is not implemented');
  }
}

bool _present(Object? v) {
  if (v == null) return false;
  if (v is String) return v.isNotEmpty;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

String _lowerFirst(String s) =>
    s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';

String _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate repo root');
    }
    dir = parent;
  }
}
