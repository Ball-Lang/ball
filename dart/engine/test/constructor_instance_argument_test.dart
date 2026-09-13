/// A constructor argument that is itself a freshly-constructed user-class
/// instance must be bound as the single POSITIONAL argument, not read as this
/// constructor's argument bag (issue #555, fixed in #563).
///
/// The engine's calling convention is "one input, one output": a constructor's
/// input is normally a map whose keys are that constructor's parameter names
/// (plus `arg0`, `arg1`, … for positionals). An inline-constructed instance is
/// ALSO a map — but its keys are the *other* class's FIELDS. Reading it as an
/// argument bag both mis-binds a same-named parameter and copies the foreign
/// class's fields onto the instance under construction.
///
/// `_buildConstructorInstance` (the BODY-LESS constructor path in
/// engine_invocation.dart) is the arm issue #605 found uncovered: a body-less
/// NAMED constructor is the only shape that reaches it with a whole instance as
/// its input, because an unnamed `Holder(p)` is a `messageCreation` and takes
/// the `_evalMessageCreation` path instead. The oracle is native `dart run` —
/// every expectation below is what real Dart prints.
@TestOn('vm')
library;

import 'package:ball_encoder/encoder.dart';
import 'package:ball_engine/engine.dart';
import 'package:test/test.dart';

Future<List<String>> runSource(String source) async {
  final program = DartEncoder().encode(source, name: 'main');
  final lines = <String>[];
  final engine = BallEngine(program, stdout: lines.add);
  await engine.run();
  return lines;
}

void main() {
  group('engine: an instance passed to a body-less named constructor', () {
    test('binds as the single positional argument', () async {
      // `Holder.of` is body-less and takes one `this.`-formal, so the instance
      // must land in `p` whole.
      expect(
        await runSource('''
class Point {
  int x = 0;
  int y = 0;
  Point(this.x, this.y);
}

class Holder {
  Point? p;
  Holder.of(this.p);
}

void main() {
  final h = Holder.of(Point(1, 2));
  print(h.p!.x + h.p!.y);
}
'''),
        ['3'],
      );
    });

    test(
      'does not let the argument instance overwrite a same-named field',
      () async {
        // `Wrapper` declares its OWN `x`; the argument instance also carries an
        // `x`. Reading the argument as this constructor's field bag would copy
        // the foreign `x` (7) over the declared default (99) — the #555 shape.
        expect(
          await runSource('''
class Point {
  int x = 0;
  Point(this.x);
}

class Wrapper {
  int x = 99;
  Point? inner;
  Wrapper.around(this.inner);
}

void main() {
  final w = Wrapper.around(Point(7));
  print(w.x);
  print(w.inner!.x);
}
'''),
          ['99', '7'],
        );
      },
    );

    test('through a constructor TEAR-OFF, where the input IS the '
        'instance', () async {
      // `[…].map(Holder.of)` hands the callback ONE value — the element — so
      // the constructor's input is the Point instance itself, with no `argN`
      // argument bag around it. That is the shape the guard exists for: read
      // as a bag, the Point's own `x`/`y` fields would be copied onto the
      // Holder and `p` left null.
      expect(
        await runSource('''
class Point {
  int x = 0;
  int y = 0;
  Point(this.x, this.y);
}

class Holder {
  Point? p;
  Holder.of(this.p);
}

class Wrap {
  int x = 99;
  Point? inner;
  Wrap.around(this.inner);
}

void main() {
  final holders = [Point(1, 2), Point(3, 4)].map(Holder.of).toList();
  for (final h in holders) {
    print(h.p!.x + h.p!.y);
  }
  // Same shape, with a field name that COLLIDES with the argument's own.
  final wraps = [Point(7, 8)].map(Wrap.around).toList();
  print(wraps[0].x);
  print(wraps[0].inner!.x);
}
'''),
        ['3', '7', '99', '7'],
      );
    });

    test('an ordinary argument bag still binds by parameter name', () async {
      // The guard must not fire for a normal call: a plain value input still
      // takes the argument-bag path.
      expect(
        await runSource('''
class Holder {
  int n = 0;
  Holder.of(this.n);
}

void main() {
  print(Holder.of(5).n);
}
'''),
        ['5'],
      );
    });
  });
}
