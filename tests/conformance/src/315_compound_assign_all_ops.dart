// Exercises the FULL compound-assignment operator surface. The bitwise
// compound ops (&= |= ^= <<= >>= >>>=) and double divide-assign (/=) were
// absent from the corpus; /= in particular fell through the engine's
// _applyCompoundOp default and silently assigned the RHS (10.0 /= 4 => 4).
void main() {
  // Arithmetic
  int n = 20;
  n += 5;
  print(n);
  n -= 3;
  print(n);
  n *= 2;
  print(n);
  n ~/= 5;
  print(n);
  n %= 6;
  print(n);

  // True (double) division-assign — must be 2.5, not 4.
  double d = 10.0;
  d /= 4;
  print(d);

  // Bitwise
  int b = 0xF0;
  b &= 0x3C;
  print(b);
  b |= 0x05;
  print(b);
  b ^= 0x0F;
  print(b);
  b <<= 2;
  print(b);
  b >>= 1;
  print(b);

  // Unsigned right-shift assign
  int u = -16;
  u >>>= 60;
  print(u);

  // Null-aware assign (null receiver → assigns)
  int? maybe;
  maybe ??= 7;
  print(maybe);

  // String concat compound
  String s = 'a';
  s += 'bc';
  print(s);
}
