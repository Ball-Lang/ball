import 'dart:convert';
import 'dart:io';

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/capability_analyzer.dart';
import 'package:ball_base/capability_table.dart';
import 'package:test/test.dart';

Program _load(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
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
  group('capability_table', () {
    test('std.print is io', () {
      expect(lookupCapability('std', 'print'), Capability.io);
    });

    test('std.add is pure', () {
      expect(lookupCapability('std', 'add'), Capability.pure);
    });

    test('std_fs.file_read is fs', () {
      expect(lookupCapability('std_fs', 'file_read'), Capability.fs);
    });

    test('std_io.exit is process', () {
      expect(lookupCapability('std_io', 'exit'), Capability.process);
    });

    test('std_memory.memory_alloc is memory', () {
      expect(lookupCapability('std_memory', 'memory_alloc'), Capability.memory);
    });

    test('unknown function returns null', () {
      expect(lookupCapability('main', 'my_func'), isNull);
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
                      {'name': 'left', 'value': {'literal': {'intValue': '1'}}},
                      {'name': 'right', 'value': {'literal': {'intValue': '2'}}},
                    ],
                  },
                },
              },
            },
          },
        ],
      );

      final report = analyzeCapabilities(program);
      expect(report.summary.isPure, isTrue);
      expect(report.summary.pureFunctions, 1);
      expect(report.summary.effectfulFunctions, 0);
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
                        'value': {'literal': {'stringValue': 'hello'}},
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
      expect(report.summary.isPure, isFalse);
      expect(report.summary.writesStdout, isTrue);
      expect(report.summary.effectfulFunctions, 1);

      final ioCap = report.capabilities.firstWhere((c) => c.capability == 'io');
      expect(ioCap.callSites, hasLength(1));
      expect(ioCap.callSites.first.calleeFunction, 'print');
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
                        'value': {'literal': {'stringValue': 'x'}},
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
                      {'name': 'left', 'value': {'literal': {'intValue': '1'}}},
                      {'name': 'right', 'value': {'literal': {'intValue': '2'}}},
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
                        'value': {'literal': {'stringValue': 'hi'}},
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
        expect(report.summary.totalFunctions, greaterThan(0));
      });
    }
  });
}
