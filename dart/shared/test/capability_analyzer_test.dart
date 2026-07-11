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
