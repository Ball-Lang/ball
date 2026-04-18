# Ball in 5 Minutes — Real-World Pipeline Demo

A self-contained walk-through of Ball's full pipeline on a non-trivial Dart
program. One small command-line tool goes through **Dart → Ball → audit →
Dart → run** and produces byte-identical output on both ends.

Re-run locally:

```bash
cd examples/real_world/wordcount
bash demo.sh
```

Prerequisites: Dart SDK 3.9+. Works offline once dependencies are fetched.

---

## The program

`src/wordcount.dart` — a word counter that:

- uses a **class with mutable fields** (`Counts`),
- uses **control flow** (`if`, `while`, `for-in`),
- uses **`Map<String, int>`** for the report,
- uses **string ops** (`length`, `substring`, indexing, concatenation).

```dart
// src/wordcount.dart  (121 lines, trimmed here)

const sampleText =
    'The quick brown fox jumps over the lazy dog.\n'
    'Pack my box with five dozen liquor jugs.\n'
    'How vexingly quick daft zebras jump!\n'
    'Sphinx of black quartz, judge my vow.\n'
    'The five boxing wizards jump quickly.\n';

class Counts {
  int lines;
  int words;
  int chars;
  int blankLines;
  int longestLine;

  Counts() : lines = 0, words = 0, chars = 0, blankLines = 0, longestLine = 0;

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

// trim, isSpace, countWords, splitLines ...

void main() {
  final counts = Counts();
  final lines = splitLines(sampleText);
  for (final line in lines) {
    counts.observe(line);
  }
  final Map<String, int> report = {};
  report['lines'] = counts.lines;
  report['words'] = counts.words;
  // ...
  print('wordcount report');
  print('----------------');
  print('lines:   ' + report['lines'].toString());
  // ...
}
```

---

## The pipeline

| # | Step                         | Tool                     | Output                      |
|---|------------------------------|--------------------------|-----------------------------|
| 1 | Run original Dart            | `dart run`               | `original.txt`              |
| 2 | Encode Dart → Ball           | `DartEncoder`            | `ball/wordcount.ball.json`  |
| 3 | Audit capabilities           | `ball audit`             | `audit.json`, `audit.txt`   |
| 4 | Compile Ball → Dart          | `DartCompiler`           | `compiled/wordcount.dart`   |
| 5 | Run compiled Dart            | `dart run`               | `compiled.txt`              |
| 6 | Verify                       | `diff`                   | exit code 0                 |

Steps 2 and 4 are a handful of API calls — see
[`encode.dart`](encode.dart) and [`decode.dart`](decode.dart); each is
under 40 lines.

---

## Actual run output

Run on Windows 11 with Dart 3.9 (captured from `bash demo.sh`).

### 1. Original Dart

```
wordcount report
----------------
lines:   5
words:   36
chars:   194
blank:   0
longest: 44
```

### 2. Encoding

```
Encoded 2880 bytes of Dart into a Ball program
  modules:    2
  functions:  26
  output:     ball/wordcount.ball.json (153510 bytes JSON)
```

The Ball program has **two modules**: `std` (26 base functions — `print`,
`add`, `for`, `if`, `while`, `equals`, `and`, `or`, …) and `main` (the user
code). The JSON is larger than the source because every AST node is
spelled out — that's the point: this is what Ball programs *are*.

### 3. Capability audit

`ball audit` statically walks the program and reports every side-effectful
base call. Because every effect in Ball flows through a named base
function, **this analysis is provably complete, not heuristic**.

```
Ball Capability Audit: wordcount v1.0.0
============================================================

Capabilities:
  pure (pure computation)
  io (7 call sites: main.main -> std.print x 7)
  NONE: filesystem, network, process, memory, concurrency, random

Summary: LOW RISK
  8 functions: 7 pure, 1 effectful

Per-function breakdown:
  main.sampleText            -> pure
  main.main:Counts.new       -> pure
  main.main:Counts.observe   -> pure
  main.trim                  -> pure
  main.isSpace               -> pure
  main.countWords            -> pure
  main.splitLines            -> pure
  main.main                  -> io
```

Key signals:

- The only capability escalation is **`io`**, and the report pinpoints the
  7 exact call sites (all `print` in `main`).
- **`filesystem`, `network`, `process`, `memory`, `concurrency`, `random`**
  are explicitly **absent** — the program cannot touch any of them without
  introducing new base function references that would show up here.

A policy gate can enforce this at build time:

```bash
ball audit ball/wordcount.ball.json --deny fs,network,memory --exit-code
```

### 4. Compiling back to Dart

```
Compiled Ball program back to Dart (2728 bytes) -> compiled/wordcount.dart
```

The regenerated source (excerpt) — notice the fidelity to the original:

```dart
// Generated by ball compiler
// Source: wordcount v1.0.0
// Target: Dart

class Counts {
  Counts() : lines = 0, words = 0, chars = 0, blankLines = 0, longestLine = 0;

  int lines;
  int words;
  int chars;
  int blankLines;
  int longestLine;

  void observe(String input) {
    String line = input;
    lines = (lines + 1);
    chars = (chars + line.length);
    final trimmed = trim(line);
    if ((trimmed.length == 0)) {
      blankLines = (blankLines + 1);
    }
    if ((line.length > longestLine)) {
      longestLine = line.length;
    }
    words = (words + countWords(line));
  }
}

// ... trim, isSpace, countWords, splitLines, main ...
```

Visible differences vs. the original are all **cosmetic**:

- Binary operators are always parenthesised (`(lines + 1)` instead of `lines + 1`).
- Each single-input function takes `input` and shadows it with the named
  binding — this is the "one-input, one-output" invariant made explicit
  (see [`CLAUDE.md`](../../../CLAUDE.md) invariant #1).
- Field order inside the class is shuffled (constructor emitted first).

No semantic difference — which is exactly what the diff step checks.

### 5. Run compiled Dart

```
wordcount report
----------------
lines:   5
words:   36
chars:   194
blank:   0
longest: 44
```

### 6. Verify

```
$ diff -u original.txt compiled.txt
(no output)

IDENTICAL   - round-trip preserved program output.
```

---

## Timings (cold pub cache, warm Dart build)

One full end-to-end run on a mid-range laptop:

| Step          | Time |
|---------------|-----:|
| `pub get`     |   4s |
| run original  |   4s |
| encode        |  14s |
| audit         |   5s |
| compile       |  17s |
| run compiled  |   3s |
| **total**     | **~47s** |

Most of this is Dart's process-start overhead (~3 s per `dart run`); the
encoder itself finishes in well under a second on a program this size.
Batch many files through a single process to amortise.

---

## Files in this example

```
examples/real_world/wordcount/
  src/wordcount.dart         # original source
  sample.txt                 # reference input (identical to const in source)
  encode.dart                # Dart -> Ball (uses DartEncoder directly)
  decode.dart                # Ball -> Dart (uses DartCompiler directly)
  demo.sh                    # orchestrator, runs the whole pipeline
  pubspec.yaml               # path-overridden deps on the local ball_* packages
  ball/wordcount.ball.json   # (generated) Ball program
  compiled/wordcount.dart    # (generated) regenerated Dart source
  audit.json                 # (generated) structured audit report
  audit.txt                  # (generated) human-readable audit report
  original.txt, compiled.txt # (generated) stdout captures used by diff
  README.md                  # this file
```

The `(generated)` files are recreated every time you run `demo.sh` — feel
free to delete them and re-run.

---

## What this demonstrates

1. **Round-trip fidelity on a real program** with classes, control flow,
   collections, and string work — not just `print('hi')`.
2. **Static capability analysis that is sound** — every effect is a named
   base call, so you cannot hide filesystem access behind a wrapper.
3. **A workflow that scales** — the same `encode.dart` / `decode.dart` work
   unchanged on any Dart file; swap the source and rerun.
