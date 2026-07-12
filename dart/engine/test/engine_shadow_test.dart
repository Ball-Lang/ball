import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// Engine defense-in-depth for base-function shadows (issue #420).
///
/// When a program declares a non-base user function whose bare name collides
/// with a base function, an *unqualified* call that misses its exact
/// `(module, function)` key is resolved by a bare-name scan across all modules.
/// If that name is declared as BOTH a base function and a user function the
/// intended target is genuinely ambiguous — the scan would otherwise dispatch
/// whichever module is indexed first, so a same-named decoy could silently hide
/// (or, on a different module order, expose) a spoofed base call. The engine
/// must fail loud on that ambiguity rather than guess.
///
/// The guard is scoped to the actual ambiguity class: a *qualified* call (exact
/// key hit) and an unqualified call whose name is borne by only base OR only
/// user functions still resolve exactly as before — verified against the whole
/// conformance corpus + engine suite (which exercise unqualified `std`
/// control-flow calls like `if`/`and`/`switch_expr` reached by this same scan,
/// none of which are shadowed).
void main() {
  Program build({
    required String callModule,
    required bool declareDecoy,
    required bool declareBase,
  }) {
    final modules = <Map<String, dynamic>>[
      {
        'name': 'std',
        'functions': [
          {'name': 'print', 'isBase': true},
        ],
      },
      if (declareBase)
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
          if (declareDecoy)
            {
              'name': 'mutex_create',
              'outputType': 'void',
              'body': {
                'call': {
                  'module': 'std',
                  'function': 'print',
                  'input': {
                    'literal': {'stringValue': 'DECOY'},
                  },
                },
              },
            },
        ],
      },
    ];
    return Program()..mergeFromProto3Json({
      'name': 'shadow',
      'version': '1.0.0',
      'entryModule': 'main',
      'entryFunction': 'main',
      'modules': modules,
    }, ignoreUnknownFields: true);
  }

  Future<List<String>> run(Program p) async {
    final out = <String>[];
    await BallEngine(p, stdout: out.add, stderr: (_) {}).run();
    return out;
  }

  test('unqualified bare-name call that is BOTH base and user fails loud', () {
    // Spoofed/undeclared call-site module ⇒ exact key misses ⇒ the bare-name
    // scan finds both the base fn and the decoy ⇒ ambiguous ⇒ throw.
    expect(
      () => run(
        build(callModule: 'bogus', declareDecoy: true, declareBase: true),
      ),
      throwsA(
        isA<BallRuntimeError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('Ambiguous unqualified call'), contains('#420')),
        ),
      ),
    );
  });

  test(
    'call qualified to the user module dispatches the decoy (unchanged)',
    () async {
      // `main.mutex_create` hits the exact key — unambiguous, so the decoy runs;
      // the shadow is a static-audit concern, not a dispatch error here.
      final out = await run(
        build(callModule: 'main', declareDecoy: true, declareBase: true),
      );
      expect(out, ['DECOY']);
    },
  );

  test(
    'empty-module call from the declaring module hits the decoy key',
    () async {
      // Empty module resolves to the current module (`main`), whose exact key
      // holds the decoy — no bare-name scan, no ambiguity.
      final out = await run(
        build(callModule: '', declareDecoy: true, declareBase: true),
      );
      expect(out, ['DECOY']);
    },
  );

  test('unqualified user call with no base collision still resolves', () async {
    // Only the decoy bears the name — the bare-name scan is unambiguous.
    final out = await run(
      build(callModule: 'bogus', declareDecoy: true, declareBase: false),
    );
    expect(out, ['DECOY']);
  });
}
