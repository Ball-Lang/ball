/// CI gate: every Expression NODE SHAPE in the required set below MUST be
/// exercised by at least one executed conformance fixture (a
/// `tests/conformance/<name>.ball.json` that has a golden sibling
/// `<name>.expected_output.txt`), OR be a documented carve-out in
/// `tests/conformance/NODE_SHAPE_COVERAGE_CARVEOUTS.md`.
///
/// This is the STRUCTURAL analogue of `check_encoder_completeness.dart`. That
/// gate guarantees every encoder-emittable std base FUNCTION is exercised; it
/// says nothing about the language's node shapes — the seven `Expression.expr`
/// variants (`proto/ball/v1/ball.proto`) and their meaningful sub-variants. So
/// a whole node shape could silently stop being exercised (e.g. the last
/// fixture using it is deleted) with no gate noticing. Issue #64 (Phase 1
/// audit) found the std surface effectively closed but the node-shape surface
/// ungated; this closes that gap and makes the remaining shape gaps explicit
/// and tracked.
///
/// How it works:
///   * "Covered" = the shape appears in ≥1 executed fixture's Ball JSON. We
///     read the COMMITTED `.ball.json` directly (not a live re-encode), so
///     hand-authored fixtures count too — mirroring `gen_std_coverage.dart`'s
///     fixture scan.
///   * "Executed" = the fixture has a golden `expected_output.txt`. The
///     host-policy behavioral fixtures without one (196/197/201/202) are
///     asserted separately by the engine harnesses and excluded here, matching
///     every golden-diff conformance runner.
///   * Gate fails if any required shape is neither covered nor carved out, or
///     if a carve-out is now covered (stale — remove it so the shape becomes
///     required again), or if a carve-out names a shape not in the required set
///     (typo guard).
///
/// Run from `dart/encoder`:
///   dart run bin/check_node_shape_coverage.dart
library;

import 'dart:convert';
import 'dart:io';

/// The required structural surface: the 7 Expression node types + the
/// meaningful sub-variants identified by the issue #64 Phase-1 audit. Keep in
/// sync with `proto/ball/v1/ball.proto` `Expression` / `Literal`.
const _requiredShapes = <String>[
  // ── The 7 Expression.expr node types ──
  'call',
  'literal',
  'reference',
  'field_access',
  'message_creation',
  'block',
  'lambda',
  // ── Literal.value kinds ──
  'literal.int_value',
  'literal.double_value',
  'literal.string_value',
  'literal.bool_value',
  'literal.list_value',
  'literal.bytes_value',
  // ── Meaningful sub-variants ──
  'call.type_args', // FunctionCall.type_args (a generic / parameterized call)
  'message_creation.const', // MessageCreation with is_const metadata
  'reference.input', // the special "input" parameter reference
  'block.result_only', // a Block with no statements (result expression only)
  'lambda.typed_param', // a lambda (FunctionDefinition name="") with a declared input_type
];

void main() {
  final repoRoot = _findRepoRoot();
  final confDir = Directory('$repoRoot/tests/conformance');
  final carveoutsFile = File(
    '$repoRoot/tests/conformance/NODE_SHAPE_COVERAGE_CARVEOUTS.md',
  );

  if (!confDir.existsSync()) {
    stderr.writeln('Conformance directory not found: ${confDir.path}');
    exit(2);
  }

  // ── Executed fixtures: a *.ball.json with a golden *.expected_output.txt ──
  final fixtures =
      confDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.ball.json'))
          .where(
            (f) => File(
              f.path.replaceAll('.ball.json', '.expected_output.txt'),
            ).existsSync(),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  // ── Covered: node shapes present across every executed fixture ──
  final covered = <String>{};
  var parseFailures = 0;
  for (final f in fixtures) {
    try {
      _walk(jsonDecode(f.readAsStringSync()), covered);
    } catch (e) {
      parseFailures++;
      stderr.writeln('  parse failed: ${f.uri.pathSegments.last}: $e');
    }
  }
  if (parseFailures > 0) {
    stderr.writeln('ERROR: $parseFailures fixture(s) failed to parse.');
    exit(1);
  }

  // ── Carve-outs (leading backticked token on a `-` bullet) ──
  final carveouts = <String>{};
  if (carveoutsFile.existsSync()) {
    final re = RegExp(r'^-\s+`([a-z][a-z0-9_.]*)`');
    for (final line in carveoutsFile.readAsLinesSync()) {
      final m = re.firstMatch(line.trim());
      if (m != null) carveouts.add(m.group(1)!);
    }
  }

  final required = _requiredShapes.toSet();
  final missing = required.difference(covered).difference(carveouts).toList()
    ..sort();
  final staleCarveouts = carveouts.intersection(covered).toList()..sort();
  final unknownCarveouts = carveouts.difference(required).toList()..sort();

  var failed = false;
  if (missing.isNotEmpty) {
    failed = true;
    stderr.writeln(
      'ERROR: ${missing.length} required node shape(s) are NOT exercised by any '
      'executed conformance fixture and are not carved out:',
    );
    for (final shape in missing) {
      stderr.writeln(
        "  - $shape  (add a fixture that exercises it, or list it in "
        "NODE_SHAPE_COVERAGE_CARVEOUTS.md with a justification)",
      );
    }
  }
  if (staleCarveouts.isNotEmpty) {
    failed = true;
    stderr.writeln(
      'ERROR: ${staleCarveouts.length} NODE_SHAPE_COVERAGE_CARVEOUTS.md '
      'entr(y/ies) are now covered by a fixture — remove them:',
    );
    for (final shape in staleCarveouts) {
      stderr.writeln('  - $shape');
    }
  }
  if (unknownCarveouts.isNotEmpty) {
    failed = true;
    stderr.writeln(
      'ERROR: ${unknownCarveouts.length} NODE_SHAPE_COVERAGE_CARVEOUTS.md '
      'entr(y/ies) name a shape not in the required set (typo?):',
    );
    for (final shape in unknownCarveouts) {
      stderr.writeln('  - $shape');
    }
  }

  if (failed) exit(1);

  final coveredRequired = required.difference(carveouts).length;
  stdout.writeln(
    'OK: $coveredRequired/${required.length} required node shapes covered by '
    '${fixtures.length} executed fixtures; ${carveouts.length} documented '
    'carve-outs. No node-shape coverage gaps.',
  );
}

/// Normalize a proto3-JSON field key so both camelCase (canonical) and
/// snake_case (hand-authored) spellings match: `fieldAccess`/`field_access`
/// both become `fieldaccess`.
String _norm(String k) => k.replaceAll('_', '').toLowerCase();

/// Recursively walk decoded Ball JSON, recording every required node shape it
/// contains into [covered]. Detection is by structural key, tolerant of both
/// key spellings; over-detection is impossible here because each shape maps to
/// a distinct discriminator key.
void _walk(Object? node, Set<String> covered) {
  if (node is Map) {
    final nk = <String, String>{
      for (final k in node.keys) _norm(k as String): k,
    };

    // The 7 Expression.expr node types.
    const exprTypes = {
      'call': 'call',
      'literal': 'literal',
      'reference': 'reference',
      'fieldaccess': 'field_access',
      'messagecreation': 'message_creation',
      'block': 'block',
      'lambda': 'lambda',
    };
    exprTypes.forEach((key, shape) {
      if (nk.containsKey(key)) covered.add(shape);
    });

    // FunctionCall with generic type_args.
    if (nk.containsKey('function') && nk.containsKey('typeargs')) {
      final ta = node[nk['typeargs']];
      if (ta is List && ta.isNotEmpty) covered.add('call.type_args');
    }

    // Literal value kinds.
    if (nk.containsKey('literal')) {
      final lit = node[nk['literal']];
      if (lit is Map) {
        final lnk = {for (final k in lit.keys) _norm(k as String): k};
        const litKinds = {
          'intvalue': 'literal.int_value',
          'doublevalue': 'literal.double_value',
          'stringvalue': 'literal.string_value',
          'boolvalue': 'literal.bool_value',
          'bytesvalue': 'literal.bytes_value',
          'listvalue': 'literal.list_value',
        };
        litKinds.forEach((key, shape) {
          if (lnk.containsKey(key)) covered.add(shape);
        });
      }
    }

    // The special "input" parameter reference.
    if (nk.containsKey('reference')) {
      final r = node[nk['reference']];
      if (r is Map && r['name'] == 'input') covered.add('reference.input');
    }

    // MessageCreation carrying is_const metadata.
    if (nk.containsKey('messagecreation')) {
      final mc = node[nk['messagecreation']];
      if (mc is Map) {
        final mnk = {for (final k in mc.keys) _norm(k as String): k};
        final md = mnk.containsKey('metadata') ? mc[mnk['metadata']] : null;
        if (md is Map && md.keys.any((k) => _norm(k as String) == 'isconst')) {
          covered.add('message_creation.const');
        }
      }
    }

    // Block with no statements (result expression only).
    if (nk.containsKey('block')) {
      final b = node[nk['block']];
      if (b is Map) {
        final bnk = {for (final k in b.keys) _norm(k as String): k};
        final st = bnk.containsKey('statements') ? b[bnk['statements']] : null;
        if (st == null || (st is List && st.isEmpty)) {
          covered.add('block.result_only');
        }
      }
    }

    // Lambda (FunctionDefinition name="") with a declared input_type.
    if (nk.containsKey('lambda')) {
      final lam = node[nk['lambda']];
      if (lam is Map) {
        final lnk = {for (final k in lam.keys) _norm(k as String): k};
        final it = lnk.containsKey('inputtype') ? lam[lnk['inputtype']] : null;
        if (it is String && it.isNotEmpty) covered.add('lambda.typed_param');
      }
    }

    for (final v in node.values) {
      _walk(v, covered);
    }
  } else if (node is List) {
    for (final v in node) {
      _walk(v, covered);
    }
  }
}

String _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/proto/ball/v1/ball.proto').existsSync()) {
      return dir.path.replaceAll('\\', '/');
    }
    dir = dir.parent;
  }
  throw StateError('Cannot find repo root from ${Directory.current.path}');
}
