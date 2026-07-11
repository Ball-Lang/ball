import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/cli_core.dart';
import 'package:test/test.dart';

// The capability analyzer now produces plain Map/List reports (it self-hosts
// through the Ball engine — see cli_core.dart's engine-safe authoring rules).
// These helpers read the Map report shape.
Map _sum(Map report) => report['summary'] as Map;
List _caps(Map report) => report['capabilities'] as List;
Map _findCap(Map report, String name) =>
    _caps(report).firstWhere((c) => (c as Map)['capability'] == name) as Map;

Program _load(String path) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return Program()..mergeFromProto3Json(json, ignoreUnknownFields: true);
}

Program _buildMinimal({
  required List<Map<String, dynamic>> functions,
  List<Map<String, dynamic>> stdFunctions = const [],
}) {
  final json = {
    'name': 'test',
    'version': '1.0.0',
    'entryModule': 'main',
    'entryFunction': 'main',
    'modules': [
      {
        'name': 'std',
        'functions': [
          for (final f in stdFunctions) {...f, 'isBase': true},
        ],
      },
      {'name': 'main', 'functions': functions},
    ],
  };
  return Program()..mergeFromProto3Json(json, ignoreUnknownFields: true);
}

void main() {
  final table = buildCapabilityTable();

  group('capability_table', () {
    test('std.print is io', () {
      expect(lookupCapability(table, 'std', 'print'), 'io');
    });

    test('std.add is pure', () {
      expect(lookupCapability(table, 'std', 'add'), 'pure');
    });

    test('std_fs.file_read is fs', () {
      expect(lookupCapability(table, 'std_fs', 'file_read'), 'fs');
    });

    test('std_io.exit is process', () {
      expect(lookupCapability(table, 'std_io', 'exit'), 'process');
    });

    test('std_memory.memory_alloc is memory', () {
      expect(lookupCapability(table, 'std_memory', 'memory_alloc'), 'memory');
    });

    test('unknown function returns empty string', () {
      expect(lookupCapability(table, 'main', 'my_func'), '');
    });

    test('capabilityRisk maps categories to risk levels', () {
      expect(capabilityRisk('pure'), 'none');
      expect(capabilityRisk('io'), 'low');
      expect(capabilityRisk('fs'), 'medium');
      expect(capabilityRisk('process'), 'high');
      expect(capabilityRisk('memory'), 'high');
    });

    // ── #402: bare-name fallback support ──────────────────────────────────
    //
    // `lookupCapabilityByName` backstops the audit when a call's `module`
    // string is spoofed. These guard its two preconditions: (1) every module
    // keyed in the table is scanned, and (2) bare names are globally unique so
    // the by-name resolution is unambiguous.

    test('capabilityModuleNames covers every module keyed in the table', () {
      final declared = capabilityModuleNames();
      final tableModules = <String>{};
      for (final key in table.keys) {
        tableModules.add(key.split('.').first);
      }
      for (final m in tableModules) {
        expect(
          declared,
          contains(m),
          reason:
              'table has module "$m" not in capabilityModuleNames() — the '
              'bare-name fallback would miss its functions (#402)',
        );
      }
    });

    test('every base-function bare name is globally unique', () {
      // A collision would make lookupCapabilityByName ambiguous. Verify each
      // bare name appears under exactly one module.
      final byBareName = <String, List<String>>{};
      for (final k in table.keys) {
        final dot = k.indexOf('.');
        final module = k.substring(0, dot);
        final fn = k.substring(dot + 1);
        (byBareName[fn] ??= <String>[]).add(module);
      }
      final collisions = <String, List<String>>{
        for (final e in byBareName.entries)
          if (e.value.length > 1) e.key: e.value,
      };
      expect(
        collisions,
        isEmpty,
        reason: 'bare-name collisions break the #402 fallback: $collisions',
      );
    });

    test('lookupCapabilityByName resolves base fns ignoring the module', () {
      expect(lookupCapabilityByName(table, 'mutex_create'), 'concurrency');
      expect(lookupCapabilityByName(table, 'file_read'), 'fs');
      expect(lookupCapabilityByName(table, 'memory_alloc'), 'memory');
      expect(lookupCapabilityByName(table, 'print'), 'io');
      expect(lookupCapabilityByName(table, 'add'), 'pure');
    });

    test('lookupCapabilityByName returns empty for non-base names', () {
      expect(lookupCapabilityByName(table, 'my_user_helper'), '');
      expect(lookupCapabilityByName(table, ''), '');
    });

    test('by-name resolution agrees with the qualified lookup', () {
      // For every table entry, resolving by bare name yields the same
      // capability as the qualified (module, fn) lookup — proving the fallback
      // never changes the categorization of a correctly-attributed call.
      for (final k in table.keys) {
        final dot = k.indexOf('.');
        final module = k.substring(0, dot);
        final fn = k.substring(dot + 1);
        expect(
          lookupCapabilityByName(table, fn),
          lookupCapability(table, module, fn),
          reason: 'by-name vs qualified diverged for $k',
        );
      }
    });
  });

  group('analyzeCapabilities', () {
    test('pure program reports is_pure=true', () {
      final program = _buildMinimal(
        stdFunctions: [
          {'name': 'add', 'outputType': 'int'},
        ],
        functions: [
          {
            'name': 'main',
            'body': {
              'call': {
                'module': 'std',
                'function': 'add',
                'input': {
                  'messageCreation': {
                    'fields': [
                      {
                        'name': 'left',
                        'value': {
                          'literal': {'intValue': '1'},
                        },
                      },
                      {
                        'name': 'right',
                        'value': {
                          'literal': {'intValue': '2'},
                        },
                      },
                    ],
                  },
                },
              },
            },
          },
        ],
      );

      final report = analyzeCapabilities(program);
      expect(_sum(report)['isPure'], isTrue);
      expect(_sum(report)['pureFunctions'], 1);
      expect(_sum(report)['effectfulFunctions'], 0);
    });

    test('program with print reports io capability', () {
      final program = _buildMinimal(
        stdFunctions: [
          {'name': 'print', 'outputType': 'void'},
        ],
        functions: [
          {
            'name': 'main',
            'body': {
              'call': {
                'module': 'std',
                'function': 'print',
                'input': {
                  'messageCreation': {
                    'fields': [
                      {
                        'name': 'value',
                        'value': {
                          'literal': {'stringValue': 'hello'},
                        },
                      },
                    ],
                  },
                },
              },
            },
          },
        ],
      );

      final report = analyzeCapabilities(program);
      expect(_sum(report)['isPure'], isFalse);
      expect(_sum(report)['writesStdout'], isTrue);
      expect(_sum(report)['effectfulFunctions'], 1);

      final ioCap = _findCap(report, 'io');
      final sites = ioCap['callSites'] as List;
      expect(sites, hasLength(1));
      expect((sites.first as Map)['calleeFunction'], 'print');
    });

    test('checkPolicy denies forbidden capabilities', () {
      final program = _buildMinimal(
        stdFunctions: [
          {'name': 'print', 'outputType': 'void'},
        ],
        functions: [
          {
            'name': 'main',
            'body': {
              'call': {
                'module': 'std',
                'function': 'print',
                'input': {
                  'messageCreation': {
                    'fields': [
                      {
                        'name': 'value',
                        'value': {
                          'literal': {'stringValue': 'x'},
                        },
                      },
                    ],
                  },
                },
              },
            },
          },
        ],
      );

      final report = analyzeCapabilities(program);
      final violations = checkPolicy(report, deny: {'io'});
      expect(violations, isNotEmpty);
      expect(violations.first, contains('print'));

      // The engine-safe entry point must agree with the native wrapper.
      final viaEngineForm = checkPolicyViolations({
        'report': report,
        'deny': ['io'],
      });
      expect(viaEngineForm, equals(violations));
    });

    test('checkPolicy passes for allowed capabilities', () {
      final program = _buildMinimal(
        stdFunctions: [
          {'name': 'add', 'outputType': 'int'},
        ],
        functions: [
          {
            'name': 'main',
            'body': {
              'call': {
                'module': 'std',
                'function': 'add',
                'input': {
                  'messageCreation': {
                    'fields': [
                      {
                        'name': 'left',
                        'value': {
                          'literal': {'intValue': '1'},
                        },
                      },
                      {
                        'name': 'right',
                        'value': {
                          'literal': {'intValue': '2'},
                        },
                      },
                    ],
                  },
                },
              },
            },
          },
        ],
      );

      final report = analyzeCapabilities(program);
      final violations = checkPolicy(report, deny: {'fs', 'memory', 'process'});
      expect(violations, isEmpty);
    });

    test('formatCapabilityReport produces readable output', () {
      final program = _buildMinimal(
        stdFunctions: [
          {'name': 'print', 'outputType': 'void'},
          {'name': 'add', 'outputType': 'int'},
        ],
        functions: [
          {
            'name': 'main',
            'body': {
              'call': {
                'module': 'std',
                'function': 'print',
                'input': {
                  'messageCreation': {
                    'fields': [
                      {
                        'name': 'value',
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
      );

      final report = analyzeCapabilities(program);
      final text = formatCapabilityReport(report);
      expect(text, contains('Ball Capability Audit'));
      expect(text, contains('io'));
      expect(text, contains('LOW RISK'));
    });
  });

  // ── #402: module-spoofing capability bypass ─────────────────────────────
  //
  // A call is categorized by the base-function identity the engine dispatches,
  // not by the spoofable call-site `module` string. Programs mirror the
  // investigation's repro (sec-dispatch: c_spoofed / d_spoofed_declared).
  group('#402 module-spoofing', () {
    // Builds a program whose entry calls `mutex_create` under [callModule].
    // When [declareConcurrency] is true the real std_concurrency base module is
    // also present (row d); otherwise it is absent (row c).
    Program buildSpoof({
      required String callModule,
      required bool declareConcurrency,
    }) {
      final modules = <Map<String, dynamic>>[
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
                  'module': callModule,
                  'function': 'mutex_create',
                  'input': {
                    'messageCreation': {'fields': <dynamic>[]},
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

    test('honest std_concurrency call is flagged (baseline)', () {
      final report = buildSpoof(
        callModule: 'std_concurrency',
        declareConcurrency: true,
      );
      final r = analyzeCapabilities(report);
      expect(_sum(r)['usesConcurrency'], isTrue);
      expect(checkPolicy(r, deny: {'concurrency'}), isNotEmpty);
    });

    test('spoofed module, concurrency undeclared (row c) is flagged', () {
      final r = analyzeCapabilities(
        buildSpoof(
          callModule: 'harmless_looking_module',
          declareConcurrency: false,
        ),
      );
      expect(_sum(r)['usesConcurrency'], isTrue);
      expect(checkPolicy(r, deny: {'concurrency'}), isNotEmpty);
    });

    test('spoofed module, concurrency declared (row d) is flagged', () {
      final r = analyzeCapabilities(
        buildSpoof(
          callModule: 'harmless_looking_module',
          declareConcurrency: true,
        ),
      );
      expect(_sum(r)['usesConcurrency'], isTrue);
      expect(checkPolicy(r, deny: {'concurrency'}), isNotEmpty);
    });

    test('a user function that shadows a base name is NOT flagged', () {
      // The program defines its OWN non-base `mutex_create` and calls it. The
      // bare-name fallback must stay silent (no false positive) — only a
      // MISSING declaration triggers by-name resolution.
      final program = Program()
        ..mergeFromProto3Json({
          'name': 'shadow',
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
                        'messageCreation': {'fields': <dynamic>[]},
                      },
                    },
                  },
                },
                // The user's own harmless helper, sharing a base fn's name.
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
      final r = analyzeCapabilities(program);
      expect(_sum(r)['usesConcurrency'], isFalse);
      expect(checkPolicy(r, deny: {'concurrency'}), isEmpty);
    });
  });

  group('conformance programs', () {
    final conformanceDir = Directory('../../tests/conformance');
    if (!conformanceDir.existsSync()) return;

    for (final file in conformanceDir.listSync().whereType<File>()) {
      if (!file.path.endsWith('.ball.json')) continue;
      final name = file.uri.pathSegments.last.replaceAll('.ball.json', '');

      test('audit $name completes without error', () {
        final program = _load(file.path);
        final report = analyzeCapabilities(program);
        expect(_sum(report)['totalFunctions'], greaterThan(0));
      });
    }
  });
}
