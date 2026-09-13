/// The FAIL-LOUD half of `std_concurrency`'s single-threaded model (issue #608).
///
/// The happy path is pinned across every engine and every compiled target by
/// conformance fixture `466_std_concurrency_handles`. What a fixture cannot
/// pin is MISUSE: joining a thread twice, unlocking a mutex nobody locked,
/// naming a handle that was never minted. Those raise a host
/// [BallRuntimeError], and what a caught host error READS AS is a separate
/// cross-target contract (issue #616 / `465_state_error_message`), so mixing it
/// into the fixture would make that fixture about error rendering rather than
/// concurrency semantics. It is asserted here instead, on the reference engine.
///
/// Before #608 none of these could even be WRONG, because none of them looked:
/// `thread_join` / `mutex_lock` / `mutex_unlock` ignored their argument
/// entirely, `atomic_load` echoed its own input, and `atomic_store` /
/// `atomic_compare_exchange` answered `null` / an unconditional `true`.
@TestOn('vm')
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Program plumbing ───────────────────────────────────────────────────────

Map<String, dynamic> _intLit(int v) => {
  'literal': {'intValue': '$v'},
};

Map<String, dynamic> _strLit(String v) => {
  'literal': {'stringValue': v},
};

Map<String, dynamic> _ref(String name) => {
  'reference': {'name': name},
};

Map<String, dynamic> _conc(
  String function,
  Map<String, Map<String, dynamic>> fields,
) => {
  'call': {
    'module': 'std_concurrency',
    'function': function,
    'input': {
      'messageCreation': {
        'typeName': '',
        'fields': [
          for (final e in fields.entries) {'name': e.key, 'value': e.value},
        ],
      },
    },
  },
};

/// `(_) => 0` in the shape every encoder emits for a one-parameter lambda.
Map<String, dynamic> _noopLambda() => {
  'lambda': {
    'name': '',
    'body': _intLit(0),
    'metadata': {
      'kind': 'lambda',
      'expression_body': true,
      'has_return': true,
      'params': [
        {'name': '_'},
      ],
    },
  },
};

Map<String, dynamic> _let(String name, Map<String, dynamic> value) => {
  'let': {
    'name': name,
    'value': value,
    'metadata': {'keyword': 'final'},
  },
};

Map<String, dynamic> _stmt(Map<String, dynamic> expr) => {'expression': expr};

/// Runs [statements] as `main`'s body and returns the captured stdout.
Future<List<String>> _run(List<Map<String, dynamic>> statements) async {
  final program = Program()
    ..mergeFromProto3Json({
      'name': 'std_concurrency_test',
      'version': '1.0.0',
      'modules': [
        {
          'name': 'std',
          'functions': [
            {'name': 'print', 'isBase': true},
            {'name': 'to_string', 'isBase': true},
          ],
        },
        {
          'name': 'std_concurrency',
          'functions': [
            for (final n in [
              'thread_spawn',
              'thread_join',
              'mutex_create',
              'mutex_lock',
              'mutex_unlock',
              'scoped_lock',
              'atomic_create',
              'atomic_load',
              'atomic_store',
              'atomic_compare_exchange',
            ])
              {'name': n, 'isBase': true},
          ],
        },
        {
          'name': 'main',
          'functions': [
            {
              'name': 'main',
              'outputType': 'void',
              'body': {
                'block': {'statements': statements},
              },
              'metadata': {'kind': 'function'},
            },
          ],
        },
      ],
      'entryModule': 'main',
      'entryFunction': 'main',
    });
  final lines = <String>[];
  await BallEngine(program, stdout: lines.add).run();
  return lines;
}

/// Asserts running [statements] raises a [BallRuntimeError] whose message
/// contains [fragment].
Future<void> _expectFails(
  List<Map<String, dynamic>> statements,
  String fragment,
) async {
  await expectLater(
    _run(statements),
    throwsA(
      isA<BallRuntimeError>().having(
        (e) => '$e',
        'message',
        contains(fragment),
      ),
    ),
  );
}

void main() {
  group('std_concurrency handles are real (issue #608)', () {
    test('each spawned thread gets its own handle', () async {
      final out = await _run([
        _let('a', _conc('thread_spawn', {'body': _noopLambda()})),
        _let('b', _conc('thread_spawn', {'body': _noopLambda()})),
        _stmt({
          'call': {
            'module': 'std',
            'function': 'print',
            'input': {
              'messageCreation': {
                'typeName': 'PrintInput',
                'fields': [
                  {
                    'name': 'message',
                    'value': {
                      'call': {
                        'module': 'std',
                        'function': 'to_string',
                        'input': {
                          'messageCreation': {
                            'typeName': '',
                            'fields': [
                              {'name': 'value', 'value': _ref('a')},
                            ],
                          },
                        },
                      },
                    },
                  },
                ],
              },
            },
          },
        }),
      ]);
      // The reference engine mints 1, 2, 3…; a portable program may only rely
      // on distinctness (fixture 466 asserts that), but the FIRST handle must
      // never be the `0` the old placeholder returned.
      expect(out, ['1']);
    });

    test('a mutex round-trips lock -> unlock -> lock', () async {
      await _run([
        _let('m', _conc('mutex_create', const {})),
        _stmt(_conc('mutex_lock', {'value': _ref('m')})),
        _stmt(_conc('mutex_unlock', {'value': _ref('m')})),
        _stmt(_conc('mutex_lock', {'value': _ref('m')})),
      ]);
    });
  });

  group('std_concurrency fails loud on misuse (issue #608)', () {
    test('thread_spawn rejects a non-function body', () async {
      await _expectFails([
        _stmt(_conc('thread_spawn', {'body': _strLit('not a function')})),
      ], 'thread_spawn: `body` must be a function');
    });

    test('thread_join rejects a second join of the same handle', () async {
      await _expectFails([
        _let('t', _conc('thread_spawn', {'body': _noopLambda()})),
        _stmt(_conc('thread_join', {'value': _ref('t')})),
        _stmt(_conc('thread_join', {'value': _ref('t')})),
      ], 'was already joined');
    });

    test('thread_join rejects a handle that was never minted', () async {
      await _expectFails([
        _stmt(_conc('thread_join', {'value': _intLit(7)})),
      ], '7 is not a live handle');
    });

    test('thread_join rejects a non-int handle', () async {
      await _expectFails([
        _stmt(_conc('thread_join', {'value': _strLit('t')})),
      ], '`value` must be an int handle');
    });

    test('thread_join rejects a missing handle field', () async {
      await _expectFails([
        _stmt(_conc('thread_join', const {})),
      ], '`value` must be an int handle, got null');
    });

    test('mutex_lock rejects locking an already-locked mutex', () async {
      await _expectFails([
        _let('m', _conc('mutex_create', const {})),
        _stmt(_conc('mutex_lock', {'value': _ref('m')})),
        _stmt(_conc('mutex_lock', {'value': _ref('m')})),
      ], 'is already locked');
    });

    test('mutex_unlock rejects unlocking a mutex nobody locked', () async {
      await _expectFails([
        _let('m', _conc('mutex_create', const {})),
        _stmt(_conc('mutex_unlock', {'value': _ref('m')})),
      ], 'is not locked');
    });

    test('scoped_lock rejects a non-function body', () async {
      await _expectFails([
        _let('m', _conc('mutex_create', const {})),
        _stmt(_conc('scoped_lock', {'mutex': _ref('m'), 'body': _intLit(1)})),
      ], 'scoped_lock: `body` must be a function');
    });

    test('scoped_lock rejects a mutex that is already locked', () async {
      await _expectFails([
        _let('m', _conc('mutex_create', const {})),
        _stmt(_conc('mutex_lock', {'value': _ref('m')})),
        _stmt(
          _conc('scoped_lock', {'mutex': _ref('m'), 'body': _noopLambda()}),
        ),
      ], 'is already locked');
    });

    test('atomic_load rejects a handle that was never minted', () async {
      await _expectFails([
        _stmt(_conc('atomic_load', {'value': _intLit(1)})),
      ], 'atomic_load: 1 is not a live handle');
    });

    test('atomic_store rejects a handle that was never minted', () async {
      await _expectFails([
        _stmt(
          _conc('atomic_store', {'atomic': _intLit(1), 'value': _intLit(2)}),
        ),
      ], 'atomic_store: 1 is not a live handle');
    });

    test('atomic_compare_exchange rejects an unminted handle', () async {
      await _expectFails([
        _stmt(
          _conc('atomic_compare_exchange', {
            'atomic': _intLit(1),
            'expected': _intLit(2),
            'value': _intLit(3),
          }),
        ),
      ], 'atomic_compare_exchange: 1 is not a live handle');
    });
  });
}
