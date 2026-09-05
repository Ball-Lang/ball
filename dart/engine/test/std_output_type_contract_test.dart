/// Gate: a base function that DECLARES an `outputType` must actually return a
/// value of that type on the Dart reference engine — and every declaration must
/// have a probe here, so the field can never outrun its guard.
///
/// WHY THIS EXISTS (issue #545). Every std base function declared
/// `outputType: ''` — a deliberately unstated return shape — and nothing
/// cross-checked a base function's return value against anything. So
/// `std_collections.set_add` / `set_remove` were free to drift into three
/// different answers at once: the Dart engine returned the NEW SET from both,
/// the Dart compiler emitted the cascade `s..add(v)` (the set) for `set_add`
/// and `s.remove(v)` (a bool) for `set_remove`, and the TS engine returned an
/// unconditional `true` from `set_add`. A Ball program that did
/// `if (set_remove(s, x)) …` computed something different on each. The
/// declarations said nothing, so there was nowhere for the divergence to be
/// caught — and nowhere for it to even be STATED.
///
/// The fix has two halves. The cross-target half is conformance fixture
/// `459_set_add_remove_bool`, which puts every result in a value position and
/// therefore gates every engine and every compiled target in the matrix. This
/// is the other half: it makes the DECLARATION load-bearing on the reference
/// implementation, so `outputType` is a checked claim rather than decoration —
/// and, unlike the fixture, it also asserts the RUNTIME TYPE, so `'true'` the
/// String could never stand in for `true` the bool.
///
/// The ratchet that matters: a declared function with neither a probe below nor
/// an entry in `_unprobedLegacyDeclarations` is a FAILURE, not a skip. Adding
/// `outputType: '<T>'` to a builder without adding a probe here cannot pass, a
/// universal-module declaration may not be carved out at all, and the carve-out
/// list itself is checked in both directions — so this file can only grow
/// alongside the declarations it guards, and the frozen debt can only shrink.
@TestOn('vm')
library;

import 'package:ball_base/ball_base.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

// ── Probe model ────────────────────────────────────────────────────────────

/// One executable check of a declared `outputType`: a call expression to
/// evaluate, plus what the engine must answer.
typedef _Probe = ({
  String description,
  Map<String, dynamic> call,
  Object? want,
});

/// Probes keyed by `<module>.<function>`. Every base function that declares a
/// non-empty `outputType` MUST appear here.
final Map<String, List<_Probe>> _probes = {
  // `set_add` / `set_remove` mutate the receiver IN PLACE and answer bool —
  // true only on a fresh insert / only when the element was present, exactly
  // like Dart's own `Set.add` / `Set.remove` (issue #545).
  'std_collections.set_add': [
    (
      description: 'a fresh insert answers true',
      call: _setCall('set_add', _setOf([1, 2]), 3),
      want: true,
    ),
    (
      description: 'a duplicate insert answers false',
      call: _setCall('set_add', _setOf([1, 2]), 2),
      want: false,
    ),
  ],
  'std_collections.set_remove': [
    (
      description: 'removing a present element answers true',
      call: _setCall('set_remove', _setOf([1, 2]), 2),
      want: true,
    ),
    (
      description: 'removing an absent element answers false',
      call: _setCall('set_remove', _setOf([1, 2]), 9),
      want: false,
    ),
  ],
};

/// Declarations that predate this gate and are NOT probed yet — a ratchet, not
/// a dumping ground (the same shape as `cpp/test/e2e_fixture_list_known_gaps.txt`).
///
/// Every entry is in `std_time` / `std_fs` / `std_concurrency` / `std_convert`:
/// the host-facing modules, whose returns are non-deterministic (`now`), touch
/// the filesystem, or spawn threads, so probing them needs a fixture harness
/// rather than a one-line expression. Nothing in the universal `std` /
/// `std_collections` modules may appear here — those are the modules a portable
/// Ball program is built from, and they are what issue #545 was about.
///
/// The list is enforced in BOTH directions below: an entry that gains a probe,
/// or that no longer declares an `outputType`, is a failure. So this debt can
/// only shrink, and a NEW declaration cannot join it without editing this file
/// (and tripping the `std`/`std_collections` guard if it belongs there).
const _unprobedLegacyDeclarations = <String>{
  'std_concurrency.thread_spawn',
  'std_concurrency.thread_join',
  'std_concurrency.mutex_create',
  'std_concurrency.mutex_lock',
  'std_concurrency.mutex_unlock',
  'std_concurrency.atomic_store',
  'std_concurrency.atomic_compare_exchange',
  'std_convert.json_encode',
  'std_convert.utf8_encode',
  'std_convert.utf8_decode',
  'std_convert.base64_encode',
  'std_convert.base64_decode',
  'std_fs.file_read',
  'std_fs.file_read_bytes',
  'std_fs.file_exists',
  'std_fs.dir_exists',
  'std_time.now',
  'std_time.now_micros',
  'std_time.format_timestamp',
  'std_time.parse_timestamp',
  'std_time.duration_add',
  'std_time.duration_subtract',
  'std_time.year',
  'std_time.month',
  'std_time.day',
  'std_time.hour',
  'std_time.minute',
  'std_time.second',
};

/// Declared `outputType` -> the Dart runtime predicate it means on the engine.
/// Only the types actually declared today are listed; an unknown one fails
/// loudly rather than silently passing (the issue-#55 silent-degradation rule).
bool _matchesDeclaredType(String outputType, Object? value) =>
    switch (outputType) {
      'bool' => value is bool,
      _ => throw StateError(
        'std_output_type_contract_test has no runtime predicate for the '
        'declared outputType "$outputType". Add one (and a probe) rather than '
        'letting an unchecked declaration through.',
      ),
    };

// ── The gate ───────────────────────────────────────────────────────────────

void main() {
  final declared = _declaredOutputTypes();

  test('at least one base function declares an outputType', () {
    // Positive floor (#439/#444): an empty inventory would make every check
    // below vacuously green, so "nothing was found" must never read as
    // "nothing drifted".
    expect(
      declared,
      isNotEmpty,
      reason:
          'No base function declares an outputType — either the builders '
          'regressed or this gate stopped reading them.',
    );
  });

  test('every declared outputType has a probe (or a listed carve-out)', () {
    final unprobed = declared.keys
        .where(
          (k) =>
              !_probes.containsKey(k) &&
              !_unprobedLegacyDeclarations.contains(k),
        )
        .toSet();
    expect(
      unprobed,
      isEmpty,
      reason:
          'These base functions declare an outputType but nothing here checks '
          'it, so the declaration is decoration: $unprobed. Add a probe to '
          '_probes.',
    );
  });

  test('no universal std / std_collections declaration is carved out', () {
    // The carve-out list exists for the host-facing modules only. A universal
    // module's declaration is exactly the kind #545 was about, so it must be
    // probed, never parked.
    final universal = _unprobedLegacyDeclarations
        .where((k) => k.startsWith('std.') || k.startsWith('std_collections.'))
        .toSet();
    expect(
      universal,
      isEmpty,
      reason:
          'std / std_collections declarations must be probed, not carved out: '
          '$universal.',
    );
  });

  test('every probe names a function that actually declares an outputType', () {
    final stale = _probes.keys.where((k) => !declared.containsKey(k)).toSet();
    expect(
      stale,
      isEmpty,
      reason:
          'These probes name base functions that no longer declare an '
          'outputType (renamed, or the declaration was dropped): $stale.',
    );
  });

  test('the carve-out list is a ratchet, not a dumping ground', () {
    final nowProbed = _unprobedLegacyDeclarations
        .where(_probes.containsKey)
        .toSet();
    expect(
      nowProbed,
      isEmpty,
      reason:
          'These carve-outs now have probes — delete them from '
          '_unprobedLegacyDeclarations so the debt can only shrink: $nowProbed.',
    );
    final vanished = _unprobedLegacyDeclarations
        .where((k) => !declared.containsKey(k))
        .toSet();
    expect(
      vanished,
      isEmpty,
      reason:
          'These carve-outs name base functions that no longer declare an '
          'outputType — remove them: $vanished.',
    );
  });

  group('declared outputType matches the engine', () {
    for (final entry in _probes.entries) {
      final key = entry.key;
      final outputType = declared[key];
      if (outputType == null) continue; // reported by the staleness test above.
      for (final probe in entry.value) {
        test('$key (declared $outputType): ${probe.description}', () async {
          final actual = await _eval(probe.call);
          expect(
            _matchesDeclaredType(outputType, actual),
            isTrue,
            reason:
                '$key declares outputType "$outputType" but the Dart engine '
                'returned ${actual.runtimeType} ($actual).',
          );
          expect(actual, probe.want);
        });
      }
    }
  });
}

// ── Declaration inventory (read from the canonical builders) ────────────────

/// Every `<module>.<function>` whose builder declaration carries a non-empty
/// `outputType`, mapped to that type. Derived from the canonical builders — the
/// same single source of truth `gen_std_coverage.dart` reads — so a declaration
/// added anywhere in `dart/shared/lib/std*.dart` is seen here automatically.
Map<String, String> _declaredOutputTypes() {
  final out = <String, String>{};
  for (final module in <Module>[
    buildStdModule(),
    buildStdCollectionsModule(),
    buildStdIoModule(),
    buildStdMemoryModule(),
    buildStdConcurrencyModule(),
    buildStdConvertModule(),
    buildStdFsModule(),
    buildStdTimeModule(),
  ]) {
    for (final fn in module.functions) {
      if (fn.isBase && fn.outputType.isNotEmpty) {
        out['${module.name}.${fn.name}'] = fn.outputType;
      }
    }
  }
  return out;
}

// ── Minimal program plumbing (mirrors engine_std_coverage_test.dart) ────────

/// Evaluates [expr] as `main`'s only statement and returns the value the engine
/// produced, captured through a tiny custom module handler (so the assertion
/// sees the real runtime value, not its stringification — `'true'` the String
/// and `true` the bool must not be confusable in a type gate).
Future<Object?> _eval(Map<String, dynamic> expr) async {
  Object? captured;
  final handler = _CaptureHandler((v) => captured = v);
  final program = Program()
    ..mergeFromProto3Json({
      'name': 'std_output_type_contract',
      'version': '1.0.0',
      'modules': [
        {
          'name': 'std',
          'functions': [
            {'name': 'set_create', 'isBase': true},
          ],
        },
        {
          'name': 'std_collections',
          'functions': [
            for (final n in ['set_add', 'set_remove'])
              {'name': n, 'isBase': true},
          ],
        },
        {
          'name': 'probe',
          'functions': [
            {'name': 'capture', 'isBase': true},
          ],
        },
        {
          'name': 'main',
          'functions': [
            {
              'name': 'main',
              'outputType': 'void',
              'body': {
                'block': {
                  'statements': [
                    {
                      'expression': {
                        'call': {
                          'module': 'probe',
                          'function': 'capture',
                          'input': {
                            'messageCreation': {
                              'typeName': '',
                              'fields': [
                                {'name': 'value', 'value': expr},
                              ],
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
              'metadata': {'kind': 'function'},
            },
          ],
        },
      ],
      'entryModule': 'main',
      'entryFunction': 'main',
    });
  // `moduleHandlers` REPLACES the default list, so the built-in std handler has
  // to be re-listed alongside the probe module.
  await BallEngine(
    program,
    moduleHandlers: [StdModuleHandler(), handler],
  ).run();
  return captured;
}

/// A one-function module whose `capture` hands the raw runtime value back.
class _CaptureHandler extends BallModuleHandler {
  _CaptureHandler(this.sink);

  final void Function(Object?) sink;

  @override
  bool handles(String module) => module == 'probe';

  @override
  Object? call(String function, Object? input, BallCallable engine) {
    if (function != 'capture') {
      throw StateError('probe module has no function "$function"');
    }
    sink(input is Map ? input['value'] : input);
    return null;
  }
}

// ── Expression builders ────────────────────────────────────────────────────

Map<String, dynamic> _intLit(int v) => {
  'literal': {'intValue': '$v'},
};

Map<String, dynamic> _setOf(List<int> items) => {
  'call': {
    'module': 'std',
    'function': 'set_create',
    'input': {
      'messageCreation': {
        'typeName': '',
        'fields': [
          {
            'name': 'elements',
            'value': {
              'literal': {
                'listValue': {
                  'elements': [for (final i in items) _intLit(i)],
                },
              },
            },
          },
        ],
      },
    },
  },
};

Map<String, dynamic> _setCall(
  String function,
  Map<String, dynamic> set,
  int value,
) => {
  'call': {
    'module': 'std_collections',
    'function': function,
    'input': {
      'messageCreation': {
        'typeName': '',
        'fields': [
          {'name': 'set', 'value': set},
          {'name': 'value', 'value': _intLit(value)},
        ],
      },
    },
  },
};
