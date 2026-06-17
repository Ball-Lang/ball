// Record patterns match by exact shape: positional arity AND named-field set
// must match. A 2-field pattern must not match a 3- or 4-field record.

String shape(Object rec) => switch (rec) {
  (var a, var b) => 'pair:$a,$b',
  (var a, var b, var c) => 'triple:$a,$b,$c',
  _ => 'other',
};

String named(Object rec) => switch (rec) {
  (x: var x, y: var y) => 'point:$x,$y',
  _ => 'other',
};

void main() {
  print(shape((1, 2)));
  print(shape((1, 2, 3)));
  print(shape((1, 2, 3, 4)));
  print(shape('s'));
  print(named((x: 10, y: 20)));
  print(named((1, 2)));
}
