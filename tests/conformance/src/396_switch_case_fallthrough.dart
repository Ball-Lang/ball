// #211: a switch-case whose body is a CONDITIONAL return must FALL THROUGH to
// the code after the switch when the guard is false — not return null. The C++
// compiler previously lowered `case X: if (c) return Y;` as an always-returning
// IIFE (`return [&]{ if(c) return Y; return BallDyn(); }()`), so the case
// returned null on the else and the post-switch statement was never reached.
String classify(int n) {
  switch (n % 3) {
    case 0:
      if (n > 10) return 'big-zero';
    // guard false → fall through
    case 1:
      if (n > 10) return 'big-one';
  }
  return 'fell-through:$n';
}

void main() {
  print(classify(0)); // 0>10 false  → fell-through:0
  print(classify(30)); // 30>10 true  → big-zero
  print(classify(1)); // 1>10 false  → fell-through:1
  print(classify(31)); // 31>10 true  → big-one
  print(classify(2)); // no case      → fell-through:2
}
