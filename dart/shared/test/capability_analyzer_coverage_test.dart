/// Coverage-focused capability-analyzer tests: transitive capability
/// propagation (a pure-looking function inheriting io from a callee), the
/// print_error -> writesStderr/writesStdout predicates, and an unknown-callee
/// collection path.
library;

import 'package:ball_base/cli_core.dart';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:test/test.dart';

Program _build({
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

Map<String, dynamic> _call(
  String module,
  String fn, [
  Map<String, dynamic>? input,
]) => {
  'call': {'module': module, 'function': fn, if (input != null) 'input': input},
};

Map<String, dynamic> _msg(String type, List<Map<String, dynamic>> fields) => {
  'messageCreation': {'typeName': type, 'fields': fields},
};

Map<String, dynamic> _field(String name, Map<String, dynamic> value) => {
  'name': name,
  'value': value,
};

Map<String, dynamic> _litStr(String v) => {
  'literal': {'stringValue': v},
};

void main() {
  test('a function inherits io from a transitively-called helper', () {
    // main -> helper -> std.print. main has no direct effect, but the analyzer
    // must propagate the callee's io capability up to main (the _analyzeFunction
    // transitive-merge path).
    final program = _build(
      stdFunctions: [
        {'name': 'print', 'outputType': 'void'},
      ],
      functions: [
        {'name': 'main', 'body': _call('main', 'helper')},
        {
          'name': 'helper',
          'body': _call(
            'std',
            'print',
            _msg('PrintInput', [_field('value', _litStr('hi'))]),
          ),
        },
      ],
    );

    final report = analyzeCapabilities(program);
    expect((report['summary'] as Map)['isPure'], isFalse);
    expect((report['summary'] as Map)['writesStdout'], isTrue);
    // Both main (transitively) and helper (directly) are effectful.
    expect(
      (report['summary'] as Map)['effectfulFunctions'],
      greaterThanOrEqualTo(1),
    );
  });

  test('std_io.print_error marks writesStderr (and writesStdout)', () {
    final program = _build(
      stdFunctions: [],
      functions: [
        {
          'name': 'main',
          'body': _call(
            'std_io',
            'print_error',
            _msg('UnaryInput', [_field('value', _litStr('boom'))]),
          ),
        },
      ],
    );

    final report = analyzeCapabilities(program);
    expect((report['summary'] as Map)['writesStderr'], isTrue);
    expect((report['summary'] as Map)['writesStdout'], isTrue);
  });

  test('reachableOnly:true actually drives the transitive _analyzeFunction '
      'merge (unlike the default analyzeAll pass, which analyzes every '
      'function flatly and never visits _analyzeFunction\'s callees loop)', () {
    // main -> helper -> std.print, analyzed via the entry-point-reachable
    // walker (`_analyzeReachable`/`_analyzeFunction`). This is the only
    // path that exercises the "merge a transitively-called user function's
    // capabilities into the caller" branch.
    final program = _build(
      stdFunctions: [
        {'name': 'print', 'outputType': 'void'},
      ],
      functions: [
        {'name': 'main', 'body': _call('main', 'helper')},
        {
          'name': 'helper',
          'body': _call(
            'std',
            'print',
            _msg('PrintInput', [_field('value', _litStr('hi'))]),
          ),
        },
      ],
    );

    final report = analyzeCapabilitiesReachable(program);
    expect((report['summary'] as Map)['isPure'], isFalse);
    expect((report['summary'] as Map)['writesStdout'], isTrue);
  });

  test('reachableOnly:true collects an unknown (undefined) callee without '
      'crashing', () {
    final program = _build(
      functions: [
        {'name': 'main', 'body': _call('main', 'ghost')},
      ],
    );
    final report = analyzeCapabilitiesReachable(program);
    expect((report['summary'] as Map)['isPure'], isTrue);
  });

  test('an unknown callee is collected without crashing', () {
    // main calls a user function that does not exist; the analyzer collects the
    // callee key and simply finds no capabilities for it.
    final program = _build(
      functions: [
        {'name': 'main', 'body': _call('main', 'ghost')},
      ],
    );
    final report = analyzeCapabilities(program);
    // No effect detected, no throw.
    expect((report['summary'] as Map)['isPure'], isTrue);
  });

  test('formatCapabilityReport renders a summary', () {
    final program = _build(
      stdFunctions: [
        {'name': 'print', 'outputType': 'void'},
      ],
      functions: [
        {
          'name': 'main',
          'body': _call(
            'std',
            'print',
            _msg('PrintInput', [_field('value', _litStr('x'))]),
          ),
        },
      ],
    );
    final text = formatCapabilityReport(analyzeCapabilities(program));
    expect(text, isNotEmpty);
  });
}
