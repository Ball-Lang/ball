// Typed `catch` clause selection. A `try`'s clause list is walked in SOURCE
// ORDER; an `on T catch` clause runs only when the thrown value's type matches
// T, and the first untyped `catch (e)` is the fallback. A compiler that always
// dispatches the FIRST clause prints "wrong" on every case below (issue #615).

void main() {
  // 1. Only the SECOND typed clause matches.
  try {
    throw StateError('boom');
  } on ArgumentError {
    print('1: wrong (ArgumentError clause ran)');
  } on StateError catch (e) {
    print('1: right (StateError) - ${e.message}');
  } catch (e) {
    // Prints a constant, not '$e': a caught exception's string form is not part
    // of the contract under test, and interpolating it is a separate
    // cross-target portability question (the C++ compiler has no
    // `ball_to_string(BallException)` overload, so the emitted program does not
    // even build).
    print('1: wrong (untyped fallback ran)');
  }

  // 2. No typed clause matches — the untyped catch-all is the fallback.
  try {
    throw ArgumentError('nope');
  } on FormatException {
    print('2: wrong (FormatException clause ran)');
  } on StateError {
    print('2: wrong (StateError clause ran)');
  } catch (e) {
    print('2: right (untyped fallback)');
  }

  // 3. A non-matching clause must NOT run: the inner `on ArgumentError` does
  //    not match a thrown StateError, so the throw propagates to the outer try.
  try {
    try {
      throw StateError('inner');
    } on ArgumentError {
      print('3: wrong (inner ArgumentError clause ran)');
    }
  } on StateError catch (e) {
    print('3: right (outer StateError) - ${e.message}');
  }

  // 4. `rethrow` from a MATCHING clause re-raises the original value, so the
  //    outer clause list is walked against the same type in source order.
  //    (`FormatException` and `StateError` are unrelated types — neither is a
  //    subtype of the other — so exact-name matching and Dart's subtype
  //    matching agree on every clause here.)
  try {
    try {
      throw FormatException('bad');
    } on StateError {
      print('4: wrong (inner StateError clause ran)');
    } on FormatException {
      print('4: inner FormatException, rethrowing');
      rethrow;
    }
  } on StateError {
    print('4: wrong (outer StateError clause ran)');
  } on FormatException {
    print('4: right (outer FormatException)');
  }
}
