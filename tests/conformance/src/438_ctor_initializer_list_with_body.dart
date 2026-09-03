// A constructor's initializer list is executed even when the constructor also
// has a BODY. Dart runs the initializer list first, then the body.
//
// Surfaced while adding 436_recursive_ctor_named for #499: the engine applied
// `metadata.initializers` only to constructors with NO body, on both paths that
// build an instance — the `messageCreation` path (an unnamed constructor) and
// the named-call path (`Class.name(...)`, which the Dart encoder emits as a
// method call on the class reference, not as a messageCreation). A constructor
// with both an initializer list and a body therefore left every
// initializer-list field `null`, silently, on both paths.
//
// Every shape below carries a body, so none of them was covered before.

class Point {
  int x;
  int y;
  String label;

  // Unnamed constructor: initializer list + body (the messageCreation path).
  Point(int a, int b)
      : x = a,
        y = b,
        label = 'pt' {
    label = label + '!';
  }

  // Named constructor: initializer list + body (the named-call path).
  Point.origin()
      : x = 0,
        y = 0,
        label = 'origin' {
    label = label + '?';
  }

  // Named constructor mixing a `this.`-param with an initializer list.
  Point.onXAxis(this.x)
      : y = 0,
        label = 'axis' {
    label = label + '-done';
  }

  // Literal initializers of every scalar shape the engine special-cases.
  Point.constants()
      : x = 7,
        y = -3,
        label = 'constants' {
    y = y - 1;
  }
}

class Flags {
  bool on;
  bool off;
  double ratio;

  Flags()
      : on = true,
        off = false,
        ratio = 0.5 {
    ratio = ratio + 0.25;
  }
}

void main() {
  final p = Point(3, 4);
  print(p.x);
  print(p.y);
  print(p.label);

  final o = Point.origin();
  print(o.x);
  print(o.y);
  print(o.label);

  final a = Point.onXAxis(9);
  print(a.x);
  print(a.y);
  print(a.label);

  final c = Point.constants();
  print(c.x);
  print(c.y);
  print(c.label);

  final f = Flags();
  print(f.on);
  print(f.off);
  print(f.ratio);
}
