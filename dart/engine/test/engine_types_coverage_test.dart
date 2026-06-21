/// Coverage-focused tests for engine_types.dart + the BallEngine public
/// surface: StdModuleHandler register/registerComposer/unregister/subset, the
/// BallObject runtime instance shape, value toStrings, and the engine resource
/// limits (modules / program size / memory / expression depth) + profiling.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Builds a tiny program whose `main` calls `std.<fn>` once. Used to drive the
/// engine through its dispatch/limit paths.
Program _programCalling(String fn, {int extraModules = 0}) {
  final json = {
    'name': 'test',
    'version': '1.0.0',
    'entryModule': 'main',
    'entryFunction': 'main',
    'modules': [
      {
        'name': 'std',
        'functions': [
          {'name': fn, 'isBase': true},
          {'name': 'add', 'isBase': true},
        ],
      },
      {
        'name': 'main',
        'functions': [
          {
            'name': 'main',
            'body': {
              'call': {'module': 'std', 'function': fn},
            },
          },
        ],
      },
      for (var i = 0; i < extraModules; i++)
        {'name': 'extra$i', 'functions': []},
    ],
  };
  return Program()..mergeFromProto3Json(json);
}

void main() {
  group('StdModuleHandler dispatch table management', () {
    test('register adds a custom function (overrides builtins on call)', () {
      final std = StdModuleHandler()..register('greet', (_) => 'hi');
      // init() is normally called by the engine; here we just check the table.
      expect(std.registeredFunctions, contains('greet'));
    });

    test('registerComposer registers a composition-aware function', () {
      final std = StdModuleHandler()
        ..registerComposer('compose', (input, engine) => 'composed');
      expect(std.registeredFunctions, contains('compose'));
    });

    test('unregister removes a registered function', () {
      final std = StdModuleHandler()
        ..register('temp', (_) => 1)
        ..unregister('temp');
      expect(std.registeredFunctions, isNot(contains('temp')));
    });

    test(
      'register then call returns the custom value (after engine init)',
      () async {
        final std = StdModuleHandler()..register('greet', (_) => 'custom');
        final program = _programCalling('greet');
        final lines = <String>[];
        final engine = BallEngine(
          program,
          stdout: lines.add,
          moduleHandlers: [std],
        );
        // greet isn't printed; just assert it runs without throwing + returns.
        final result = await engine.run();
        expect(result, 'custom');
      },
    );

    test('registerComposer call can delegate to the engine', () async {
      final std = StdModuleHandler()
        ..registerComposer('compose', (input, engine) async {
          return engine('std', 'add', {'left': 2, 'right': 3});
        });
      final program = _programCalling('compose');
      final engine = BallEngine(program, moduleHandlers: [std]);
      expect(await engine.run(), 5);
    });

    test('subset exposes only the allow-listed builtins', () async {
      // 'add' is allow-listed and present in the table after init.
      final allowed = StdModuleHandler.subset({'add'});
      final program = _programCalling('add');
      BallEngine(program, moduleHandlers: [allowed]); // triggers init()
      expect(allowed.registeredFunctions, contains('add'));
      // A function NOT in the subset is never registered, and calling it throws.
      final blocked = StdModuleHandler.subset({'add'});
      final program2 = _programCalling('print');
      final engine2 = BallEngine(program2, moduleHandlers: [blocked]);
      expect(blocked.registeredFunctions, isNot(contains('print')));
      expect(engine2.run(), throwsA(isA<BallRuntimeError>()));
    });

    test('handles() recognizes every std submodule', () {
      final std = StdModuleHandler();
      for (final m in [
        'std',
        'std_collections',
        'std_io',
        'std_memory',
        'std_convert',
        'std_fs',
        'std_time',
        'std_concurrency',
      ]) {
        expect(std.handles(m), isTrue, reason: m);
      }
      expect(std.handles('not_std'), isFalse);
    });

    test('calling an unknown std function throws', () async {
      // 'print' is referenced but unregistered via tombstone.
      final std = StdModuleHandler()..unregister('print');
      final program = _programCalling('print');
      final engine = BallEngine(program, moduleHandlers: [std]);
      expect(engine.run(), throwsA(isA<BallRuntimeError>()));
    });
  });

  group('BallObject runtime shape', () {
    test('constructor populates fields, type, and virtual metadata keys', () {
      final obj = BallObject(
        typeName: 'main:Point',
        fields: {'x': 1, 'y': 2},
        methods: {'dist': 'fn'},
      );
      expect(obj.typeName, 'main:Point');
      expect(obj['x'], 1);
      expect(obj['__type__'], 'main:Point');
      expect(obj['__fields__'], {'x': 1, 'y': 2});
      expect(obj['__methods__'], {'dist': 'fn'});
    });

    test('setField updates both fields and the flat entries view', () {
      final obj = BallObject(typeName: 'T', fields: {'a': 1});
      obj.setField('a', 99);
      expect(obj['a'], 99);
      expect(obj.fields['a'], 99);
    });

    test('operator[]= routes __super__ / __methods__ / fields correctly', () {
      final obj = BallObject(typeName: 'T', fields: {});
      final superObj = BallObject(typeName: 'S', fields: {'base': 1});
      obj['__super__'] = superObj;
      expect(obj.superObject, same(superObj));
      expect(obj['__super__'], same(superObj));

      obj['__methods__'] = {'m': 'fn'};
      expect(obj.methods['m'], 'fn');

      obj['plain'] = 7;
      expect(obj.fields['plain'], 7);
      expect(obj['plain'], 7);

      // A non-map __methods__ value resets to empty.
      obj['__methods__'] = 'not a map';
      expect(obj.methods, isEmpty);
    });

    test('defaults to empty fields/methods when omitted', () {
      final obj = BallObject(typeName: 'T');
      expect(obj.fields, isEmpty);
      expect(obj.methods, isEmpty);
    });
  });

  group('value toStrings + exceptions', () {
    test('BallRuntimeError.toString includes the message', () {
      expect(BallRuntimeError('boom').toString(), 'BallRuntimeError: boom');
    });

    test(
      'BallException.toString prefers the value, falls back to typeName',
      () {
        expect(
          BallException('FormatException', 'bad input').toString(),
          'bad input',
        );
        expect(BallException('StateError', null).toString(), 'StateError');
      },
    );

    test('BallGenerator.toString reports its value count', () {
      final g = BallGenerator()
        ..yield_(1)
        ..yield_(2);
      expect(g.toString(), 'BallGenerator(2 values)');
      g.yieldAll([3, 4, 5]);
      expect(g.values, [1, 2, 3, 4, 5]);
    });
  });

  group('BallEngine resource limits', () {
    test('too many modules throws at construction', () {
      final program = _programCalling('add', extraModules: 5);
      expect(
        () => BallEngine(program, maxModules: 3),
        throwsA(
          isA<BallRuntimeError>().having(
            (e) => e.message,
            'm',
            contains('Too many modules'),
          ),
        ),
      );
    });

    test('program-size limit throws at construction', () {
      final program = _programCalling('add');
      expect(
        () => BallEngine(program, maxProgramSizeBytes: 1),
        throwsA(
          isA<BallRuntimeError>().having(
            (e) => e.message,
            'm',
            contains('Program too large'),
          ),
        ),
      );
    });

    test('expression-depth limit throws at construction', () {
      // A deeply-nested add chain blows the static depth check.
      Map<String, dynamic> nest(int n) {
        Map<String, dynamic> e = {
          'literal': {'intValue': '1'},
        };
        for (var i = 0; i < n; i++) {
          e = {
            'call': {
              'module': 'std',
              'function': 'negate',
              'input': {
                'messageCreation': {
                  'fields': [
                    {'name': 'value', 'value': e},
                  ],
                },
              },
            },
          };
        }
        return e;
      }

      final program = Program()
        ..mergeFromProto3Json({
          'name': 't',
          'entryModule': 'main',
          'entryFunction': 'main',
          'modules': [
            {
              'name': 'std',
              'functions': [
                {'name': 'negate', 'isBase': true},
              ],
            },
            {
              'name': 'main',
              'functions': [
                {'name': 'main', 'body': nest(50)},
              ],
            },
          ],
        });
      expect(
        () => BallEngine(program, maxExpressionDepth: 10),
        throwsA(
          isA<BallRuntimeError>().having(
            (e) => e.message,
            'm',
            contains('Expression too deep'),
          ),
        ),
      );
    });

    test('profilingReport is empty unless profiling is enabled', () {
      final program = _programCalling('add');
      final engine = BallEngine(program);
      expect(engine.profilingReport(), isEmpty);
    });

    test('run throws when the entry point is missing', () {
      final program = Program()
        ..mergeFromProto3Json({
          'name': 't',
          'entryModule': 'main',
          'entryFunction': 'nonexistent',
          'modules': [
            {'name': 'main', 'functions': []},
          ],
        });
      final engine = BallEngine(program);
      expect(
        engine.run(),
        throwsA(
          isA<BallRuntimeError>().having(
            (e) => e.message,
            'm',
            contains('Entry point'),
          ),
        ),
      );
    });
  });
}
