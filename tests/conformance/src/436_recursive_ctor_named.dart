// #499, named-constructor variant. 435 covers the unnamed constructor; the
// engine resolves `Class.name(...)` through a different constructor-lookup key,
// so the self-collapse has to be proven gone for that path too.
//
// Two shapes here that 435 does not have:
//   1. A named constructor building its own class through the SAME named
//      constructor (`Countdown.from`).
//   2. A named constructor delegating to a DIFFERENT named constructor of the
//      same class (`Countdown.pair` -> `Countdown.from`), which is the shape
//      closest to the argument-less self-reference the guard exists for.

class Countdown {
  int value;
  Countdown? tail;

  Countdown.from(this.value) {
    if (value > 0) {
      tail = Countdown.from(value - 1);
    }
  }

  Countdown.pair(int start) : value = start {
    tail = Countdown.from(start - 1);
  }
}

void main() {
  final chain = Countdown.from(4);

  int steps = 0;
  Countdown? cursor = chain;
  while (cursor != null && steps < 100) {
    steps = steps + 1;
    print(cursor.value);
    cursor = cursor.tail;
  }
  print(steps);
  print(identical(chain.tail, chain));

  // The cross-constructor delegation builds a real, distinct successor too.
  final pair = Countdown.pair(3);
  print(pair.value);
  print(pair.tail!.value);
  print(pair.tail!.tail!.value);
  print(identical(pair.tail, pair));

  // Terminal case: no successor is built at all.
  final last = Countdown.from(0);
  print(last.value);
  print(last.tail == null);
}
