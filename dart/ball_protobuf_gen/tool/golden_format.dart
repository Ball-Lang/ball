/// Shared formatter for the generated golden, so the regen tool
/// (`gen_golden.dart`) and the drift-guard test produce byte-identical output.
///
/// Uses `package:dart_style` (a dev-dependency — the shipped `protoc-gen-ball`
/// plugin emits unformatted-but-valid source and does NOT pull this in; only
/// the committed golden is formatted, to satisfy `dart format --set-exit-if-changed`).
library;

import 'package:dart_style/dart_style.dart';

/// Formats [source] with the package's language version so the result is
/// stable across runs.
String formatGolden(String source) {
  final formatter = DartFormatter(
    languageVersion: DartFormatter.latestLanguageVersion,
  );
  return formatter.format(source);
}
