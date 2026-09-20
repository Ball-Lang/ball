// The observable STRING FORM of a USER-THROWN built-in Dart error — the value a
// literal `throw StateError('boom')` binds into a `catch` clause (issue #658).
//
// `463`/`464` print hardcoded literals or `e.message`; `465` (#616's guard) and
// `467` (#641's) print the caught value, but only for a RUNTIME-raised error,
// where the payload the runtime built already carries the canonical
// `toString()` string. The LITERAL-throw path — by far the more common one in
// user code — had never been in a value position anywhere in the corpus, which
// is exactly how three different renderings of one program survived:
//
//   real Dart              untyped state: Bad state: boom
//   Dart reference engine  untyped state: boom              (message, not toString)
//   Go compiler            untyped state: main:StateError   (bare type tag)
//
// Dart's own renderings, measured against the SDK (3.12.0) and NOT assumed:
//
//   StateError('boom').toString()      -> "Bad state: boom"
//   FormatException('bad').toString()  -> "FormatException: bad"
//   ArgumentError('nope').toString()   -> "Invalid argument(s): nope"
//
// `ArgumentError` is the third one on purpose: #616's cross-target table covers
// `StateError`/`FormatException`/`RangeError` only, so it is the name that
// proves the table LEARNED an entry rather than merely already having one.
//
// `.message` is asserted alongside `'$e'` because both are observable and they
// are DIFFERENT strings: the caught value has to render as Dart's `toString()`
// while still exposing the raw constructor argument under `.message` (which is
// what `464` reads). A fix that rewrites the stored field to the prefixed form
// would pass the `'$e'` half and break the `.message` half.
//
// The golden is produced by running THIS FILE on the Dart SDK
// (`generate_conformance.dart` captures `dart run`'s stdout), so the reference
// is real Dart, not any engine's current string.

void untyped() {
  try {
    throw StateError('boom');
  } catch (e) {
    print('untyped state: $e');
  }
  try {
    throw FormatException('bad');
  } catch (e) {
    print('untyped format: $e');
  }
  try {
    throw ArgumentError('nope');
  } catch (e) {
    print('untyped argument: $e');
  }
}

void typed() {
  try {
    throw StateError('one');
  } on StateError catch (e) {
    print('on StateError: $e');
    print('state message: ${e.message}');
  }
  try {
    throw FormatException('two');
  } on FormatException catch (e) {
    print('on FormatException: $e');
    print('format message: ${e.message}');
  }
  try {
    throw ArgumentError('three');
  } on ArgumentError catch (e) {
    print('on ArgumentError: $e');
    print('argument message: ${e.message}');
  }
}

// A typed clause that does NOT match still has to fall through to the untyped
// one, and the value it binds there renders the same way.
void mismatch() {
  try {
    throw FormatException('unmatched');
  } on StateError catch (e) {
    print('wrong: $e');
  } catch (e) {
    print('fallback: $e');
  }
}

void main() {
  untyped();
  typed();
  mismatch();
}
