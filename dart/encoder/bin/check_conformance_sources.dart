/// CI gate: every `tests/conformance/*.ball.json` must be regenerable from a
/// `src/<name>.dart` source, OR be an explicitly documented carve-out in
/// `tests/conformance/CARVEOUTS.md`. This prevents new hand-maintained orphan
/// fixtures from creeping in (every Ball file must be sourced from a generator).
///
/// Run from `dart/encoder`:
///   dart run bin/check_conformance_sources.dart
library;

import 'dart:io';

void main() {
  final confDir = Directory('../../tests/conformance');
  final srcDir = Directory('../../tests/conformance/src');
  final carveoutsFile = File('../../tests/conformance/CARVEOUTS.md');

  if (!confDir.existsSync()) {
    stderr.writeln('Conformance directory not found: ${confDir.path}');
    exit(2);
  }
  if (!carveoutsFile.existsSync()) {
    stderr.writeln('Carve-out manifest not found: ${carveoutsFile.path}');
    exit(2);
  }

  // Parse carve-out names: the leading backticked token on each `-` bullet.
  // e.g. "- `196_timeout` — ...".
  final carveoutRe = RegExp(r'^-\s+`([^`]+)`');
  final carveouts = <String>{};
  for (final line in carveoutsFile.readAsLinesSync()) {
    final m = carveoutRe.firstMatch(line.trim());
    if (m != null) carveouts.add(m.group(1)!);
  }

  final ballFiles = confDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ball.json'))
      .map((f) => f.uri.pathSegments.last.replaceAll('.ball.json', ''))
      .toSet();

  final orphans = <String>[];
  final usedCarveouts = <String>{};
  for (final name in ballFiles) {
    final hasSrc = File('${srcDir.path}/$name.dart').existsSync();
    if (hasSrc) continue;
    if (carveouts.contains(name)) {
      usedCarveouts.add(name);
      continue;
    }
    orphans.add(name);
  }

  // Carve-outs that no longer correspond to a real fixture (stale manifest).
  final staleCarveouts = carveouts.difference(usedCarveouts).toList()..sort();

  var failed = false;
  if (orphans.isNotEmpty) {
    failed = true;
    orphans.sort();
    stderr.writeln(
      'ERROR: ${orphans.length} conformance fixture(s) have neither a '
      'src/<name>.dart nor a CARVEOUTS.md entry:',
    );
    for (final o in orphans) {
      stderr.writeln(
        '  - $o  (add tests/conformance/src/$o.dart, or list it '
        'in CARVEOUTS.md with a justification)',
      );
    }
  }
  if (staleCarveouts.isNotEmpty) {
    failed = true;
    stderr.writeln(
      'ERROR: ${staleCarveouts.length} CARVEOUTS.md entr(y/ies) reference a '
      'fixture that no longer exists:',
    );
    for (final s in staleCarveouts) {
      stderr.writeln('  - $s  (remove it from CARVEOUTS.md)');
    }
  }

  if (failed) exit(1);

  stdout.writeln(
    'OK: ${ballFiles.length} conformance fixtures '
    '(${ballFiles.length - usedCarveouts.length} generated from src, '
    '${usedCarveouts.length} documented carve-outs).',
  );
}
