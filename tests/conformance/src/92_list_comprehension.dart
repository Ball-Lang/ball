// A genuine list comprehension (this file was previously misnamed — it used an
// imperative for-loop + .add(), which is exactly the false coverage that let
// issue #55's collection-`for` bug hide). Output is unchanged: 0,1,4,...,81.
void main() {
  final squares = [for (var i = 0; i < 10; i++) i * i];
  for (final s in squares) {
    print(s);
  }
}
