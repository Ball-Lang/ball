// Mutable text sink (issue #630): `StringBuffer` routes through the declared
// universal base functions `std.sink_create` / `sink_write` / `sink_to_string`.
//
// The load-bearing line is `appendWord(out, 'c')`: a sink is REFERENCE-SEMANTIC,
// so an append performed inside a callee must be visible to the caller. A target
// that backs the sink with a by-value `String` / `strings.Builder` /
// `ostringstream` copy loses exactly that append and nothing else — a silent
// wrong answer, the shape issue #300 hit for list appends.

void appendWord(StringBuffer sink, String word) {
  sink.write(word);
}

void main() {
  StringBuffer out = StringBuffer();
  out.write('a');
  out.write('b');
  appendWord(out, 'c');
  print(out.toString());
  print(out.length);

  StringBuffer seeded = StringBuffer('x');
  seeded.writeln('y');
  seeded.write('z');
  print(seeded.toString());

  StringBuffer blank = StringBuffer();
  print(blank.isEmpty);
  blank.writeCharCode(81);
  print(blank.isNotEmpty);
  print(blank.toString());
}
