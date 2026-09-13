// #664 - a setter declared NEXT TO a same-named `final` field must run.
//
// A `final` field contributes a getter and NOTHING else, so an explicit setter
// declared alongside it is the only setter for that name. `collection`'s
// `ListSlice` is the real-world shape (see #651).
//
// The engine's write path suppressed setter dispatch whenever the instance
// carried a field of that name (`_trySetterDispatch`'s
// `if (object.containsKey(fieldName)) return _sentinel;`, added by #501). That
// guard asks "does the instance carry a field of this name" where Dart asks
// "does that field's own DECLARATION contribute a setter" - so `slice.length =
// 5` silently overwrote the `final` field instead of running the declared
// setter, on every target (every self-hosted engine is that same Dart source
// compiled through the pipeline).
//
// The second half is the guard's other direction: a NON-final field DOES
// contribute a setter, which shadows the inherited one, so the plain field
// write must keep winning (the shape #501 fixed, pinned by
// 432_shadowed_getter_setter_write - kept here so a fix for one direction
// cannot silently undo the other).

class FixedSlice {
  final List<int> source;
  final int length;

  FixedSlice(this.source, int end) : length = end;

  set length(int newLength) {
    throw UnsupportedError('Cannot resize a FixedSlice');
  }

  int readLength() {
    return length;
  }
}

class Scaler {
  int _stored = 1;

  int get amount => _stored;

  set amount(int value) {
    _stored = value * 10;
  }
}

class Plain extends Scaler {
  @override
  int amount = 5;
}

void main() {
  // The final field reads back through its implicit getter.
  final slice = FixedSlice([10, 20, 30], 3);
  print(slice.length);

  // Writing must run the DECLARED setter, which throws - and must NOT
  // overwrite the final field.
  try {
    slice.length = 5;
    print('setter did not throw');
  } catch (e) {
    print('setter threw');
  }
  print(slice.length);
  print(slice.readLength());
  print(slice.source.length);

  // The other direction: an inherited setter that a subclass's own non-final
  // field shadows. The plain map write must still win, verbatim.
  final scaler = Scaler();
  scaler.amount = 3;
  print(scaler.amount);

  final plain = Plain();
  plain.amount = 7;
  print(plain.amount);
}
