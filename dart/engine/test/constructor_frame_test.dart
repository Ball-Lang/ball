/// A constructor invocation must hold its recursion frame until construction
/// completes.
///
/// `_callFunction` (dart/engine/lib/engine_invocation.dart) increments
/// `_recursionDepth` before its `try` and decrements it in the `finally`. The
/// two constructor paths inside that `try` returned a *Future*
/// (`return _callObjectConstructor(...)` / `return _buildConstructorInstance(...)`)
/// without awaiting it — so the `finally` ran as soon as the future was
/// *returned*, i.e. before the constructor body executed, and the frame was
/// released while user code was still running underneath it. Every other path
/// in the same function awaits before returning. Dart's
/// `unawaited_return_in_try_block` lint (newer stable SDKs) flags exactly this
/// shape; CI's `dart analyze dart/` (warnings fatal) went red on it the first
/// time a PR ran after the pinned `stable` SDK moved.
///
/// Why no existing test caught it: nothing exercised `maxRecursionDepth` at
/// all, and the two un-awaited paths are only reached when a constructor is
/// invoked through a `call` expression with no `self` bound — a NAMED
/// constructor such as `Chain.of(...)`. An unnamed `Chain(...)` is a
/// `messageCreation`, which `_evalMessageCreation` dispatches with a shell
/// `self` already bound, so it takes the ordinary (awaited) path and never
/// touched the bug. The depth at which the limit trips is not observable
/// through the conformance goldens (native Dart has no such limit), so this
/// test pins the frame accounting directly by choosing a limit that sits
/// between the two behaviours.
@TestOn('vm')
library;

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

/// A named constructor whose body recurses through the same named
/// constructor. Each level enters `_callFunction` twice: once for the
/// `Chain.of` call (no `self` yet → `_callObjectConstructor`), then once more
/// for the body with `self` bound. With the constructor frame held, 40 nested
/// constructions need ~81 frames (measured: throws at a limit of 80, completes
/// at 85); with the frame released early they needed only ~41 (measured on the
/// pre-fix engine: completed at 60).
const _source = '''
class Chain {
  int n = 0;
  Chain? next;
  Chain.of(int depth) {
    n = depth;
    if (depth > 0) {
      next = Chain.of(depth - 1);
    }
  }
}

void main() {
  final c = Chain.of(40);
  print(c.n);
}
''';

void main() {
  group('engine: constructor recursion frames', () {
    test('a named constructor holds its frame while its body runs', () async {
      final program = DartEncoder().encode(_source, name: 'main');
      final lines = <String>[];
      final engine = BallEngine(
        program,
        stdout: lines.add,
        maxRecursionDepth: 60,
      );

      await expectLater(
        engine.run(),
        throwsA(
          isA<BallRuntimeError>().having(
            (error) => error.message,
            'message',
            equals('Maximum recursion depth exceeded: 60'),
          ),
        ),
      );
      expect(lines, isEmpty);
    });

    test(
      'the same program completes under a limit that fits both frames',
      () async {
        final program = DartEncoder().encode(_source, name: 'main');
        final lines = <String>[];
        final engine = BallEngine(
          program,
          stdout: lines.add,
          maxRecursionDepth: 200,
        );
        await engine.run();
        expect(lines, ['40']);
      },
    );
  });
}
