// A bare `continue` directly inside a switch `case`, nested inside a `for`
// loop, is legal Dart — it targets the ENCLOSING LOOP, never the switch
// (unlike a bare `break`, which ends only the switch). This pins the
// distinction on every target: case 1's `continue` must skip `after1` and
// advance the loop, while case 3's `break` must end only the switch, letting
// `after3` still run.
void main() {
  final out = <String>[];
  for (int i = 0; i < 5; i++) {
    switch (i) {
      case 1:
        out.add('skip$i');
        continue;
      case 3:
        out.add('stop$i');
        break;
      default:
        out.add('d$i');
    }
    out.add('after$i');
  }
  print(out.join(','));
}
