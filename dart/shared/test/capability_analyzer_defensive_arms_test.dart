/// The two defensive arms of the capability analyzer that issue #605 found
/// uncovered.
///
/// Both are real, reachable contracts rather than dead code:
///
///  * `_analyzeReachableFn` must tolerate a **body-less non-base function**.
///    `ball audit --reachable-only` walks whatever `Program` it is handed, and
///    a function declared without `isBase` and without a `body` is a shape the
///    loader accepts (an interface/abstract declaration, or a module assembled
///    by a not-yet-complete encoder). It records "no capabilities" and stops;
///    dereferencing the absent body instead would crash the audit.
///  * `formatCapabilityReport` takes a plain `Map`, so it must render a
///    **hand-built report** that predates the `shadows` key (issue #420) — the
///    renderer is part of the portable CLI core and is called with maps the
///    analyzer did not build (cross-target CLI cores, stored reports).
library;

import 'package:ball_base/cli_core.dart';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:test/test.dart';

Program _program(List<Map<String, dynamic>> mainFunctions) {
  final json = {
    'name': 'test',
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
      {'name': 'main', 'functions': mainFunctions},
    ],
  };
  return Program()..mergeFromProto3Json(json, ignoreUnknownFields: true);
}

Map<String, Object?> _fnEntry(Map<String, Object?> report, String key) {
  final List functions = report['functions'] as List;
  for (final f in functions) {
    final entry = f as Map;
    if ('${entry['module']}.${entry['function']}' == key) {
      return entry.cast<String, Object?>();
    }
  }
  fail('no per-function entry for "$key" in $functions');
}

void main() {
  group('reachability-scoped analysis', () {
    test('a body-less non-base callee contributes no capabilities', () {
      final report = analyzeCapabilitiesReachable(
        _program([
          {
            'name': 'main',
            'body': {
              'block': {
                'statements': [
                  {
                    'expression': {
                      'call': {'module': 'main', 'function': 'declared_only'},
                    },
                  },
                  {
                    'expression': {
                      'call': {'module': 'std', 'function': 'print'},
                    },
                  },
                ],
              },
            },
          },
          // Neither `isBase` nor a `body`: the arm under test.
          {'name': 'declared_only'},
        ]),
      );

      // The body-less callee is still REPORTED (silently dropping it would
      // hide it from the audit) — with an empty capability list.
      expect(_fnEntry(report, 'main.declared_only')['capabilities'], isEmpty);
      // …and the walk continued, so main's own io capability survived.
      expect(_fnEntry(report, 'main.main')['capabilities'], contains('io'));
    });
  });

  group('formatCapabilityReport on a hand-built report', () {
    Map<String, Object?> pureReport({List<Object?>? shadows}) => {
      'programName': 'handbuilt',
      'programVersion': '0.0.1',
      'capabilities': <Object?>[
        {'capability': 'pure', 'riskLevel': 'none', 'callSites': <Object?>[]},
      ],
      'summary': <String, Object?>{
        'isPure': true,
        'readsFilesystem': false,
        'writesFilesystem': false,
        'usesNetwork': false,
        'controlsProcess': false,
        'usesMemory': false,
        'usesConcurrency': false,
        'usesRandom': false,
        'totalFunctions': 1,
        'pureFunctions': 1,
        'effectfulFunctions': 0,
      },
      'functions': <Object?>[
        {
          'module': 'main',
          'function': 'main',
          'capabilities': <Object?>['pure'],
        },
      ],
      if (shadows != null) 'shadows': shadows,
    };

    test('renders when the report carries no "shadows" key at all', () {
      final text = formatCapabilityReport(pureReport());
      expect(text, contains('Ball Capability Audit: handbuilt v0.0.1'));
      expect(text, contains('Summary: NO RISK — pure computation only'));
      // No shadows ⇒ no shadow section.
      expect(text, isNot(contains('Shadowed base functions:')));
    });

    test('renders the shadow section when the key IS present', () {
      final text = formatCapabilityReport(
        pureReport(
          shadows: <Object?>[
            {
              'module': 'main',
              'function': 'print',
              'baseModule': 'std',
              'capability': 'io',
              'riskLevel': 'low',
            },
          ],
        ),
      );
      expect(text, contains('Shadowed base functions:'));
      expect(text, contains('main.print shadows std.print'));
      // A shadow escalates the otherwise-pure verdict.
      expect(
        text,
        contains('Summary: REVIEW REQUIRED — declares base-function shadows'),
      );
    });
  });
}
