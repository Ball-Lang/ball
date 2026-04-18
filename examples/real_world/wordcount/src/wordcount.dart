// A small word counter CLI.
//
// Demonstrates OOP (class with fields), control flow (if/while/for),
// Map operations, and string operations — a realistic tour of the
// constructs a typical CLI tool uses.

const sampleText =
    'The quick brown fox jumps over the lazy dog.\n'
    'Pack my box with five dozen liquor jugs.\n'
    'How vexingly quick daft zebras jump!\n'
    'Sphinx of black quartz, judge my vow.\n'
    'The five boxing wizards jump quickly.\n';

// --- Domain model -----------------------------------------------

class Counts {
  int lines;
  int words;
  int chars;
  int blankLines;
  int longestLine;

  Counts()
      : lines = 0,
        words = 0,
        chars = 0,
        blankLines = 0,
        longestLine = 0;

  void observe(String line) {
    lines = lines + 1;
    chars = chars + line.length;
    final trimmed = trim(line);
    if (trimmed.length == 0) {
      blankLines = blankLines + 1;
    }
    if (line.length > longestLine) {
      longestLine = line.length;
    }
    words = words + countWords(line);
  }
}

// --- String helpers ---------------------------------------------

String trim(String s) {
  var start = 0;
  var end = s.length;
  while (start < end && isSpace(s[start])) {
    start = start + 1;
  }
  while (end > start && isSpace(s[end - 1])) {
    end = end - 1;
  }
  return s.substring(start, end);
}

bool isSpace(String ch) {
  return ch == ' ' || ch == '\t' || ch == '\r';
}

int countWords(String line) {
  var count = 0;
  var inWord = false;
  var i = 0;
  while (i < line.length) {
    final ch = line[i];
    final space = isSpace(ch);
    if (!space && !inWord) {
      count = count + 1;
      inWord = true;
    } else if (space) {
      inWord = false;
    }
    i = i + 1;
  }
  return count;
}

List<String> splitLines(String text) {
  final List<String> result = [];
  var start = 0;
  var i = 0;
  while (i < text.length) {
    if (text[i] == '\n') {
      result.add(text.substring(start, i));
      start = i + 1;
    }
    i = i + 1;
  }
  if (start < text.length) {
    result.add(text.substring(start, text.length));
  }
  return result;
}

// --- Main -------------------------------------------------------

void main() {
  final counts = Counts();
  final lines = splitLines(sampleText);
  for (final line in lines) {
    counts.observe(line);
  }

  final Map<String, int> report = {};
  report['lines'] = counts.lines;
  report['words'] = counts.words;
  report['chars'] = counts.chars;
  report['blank'] = counts.blankLines;
  report['longest'] = counts.longestLine;

  print('wordcount report');
  print('----------------');
  print('lines:   ' + report['lines'].toString());
  print('words:   ' + report['words'].toString());
  print('chars:   ' + report['chars'].toString());
  print('blank:   ' + report['blank'].toString());
  print('longest: ' + report['longest'].toString());
}
