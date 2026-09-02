/// Tier A of the third-party coverage study (issue #493).
///
/// The conformance corpus is 300+ hand-authored, single-file, `main`-shaped
/// programs written to AVOID the encoder's known syntactic traps, and both
/// `check_encoder_completeness.dart` and `conformance-matrix.yml` are scoped to
/// exactly that corpus. Nothing in CI has ever run the pipeline over code the
/// project did not write — which is how a 0%-conversion encoder (#491, #492)
/// and a compiler that emits unparseable Dart on real library files (#494)
/// shipped past every required check.
///
/// Tier A measures the cheapest end of that gap: for every library file of a
/// pinned third-party package, does
///
///     Dart source → DartEncoder → DartCompiler → Dart source → DartEncoder
///
/// come back with the same declarations and the same semantic Ball IR?
///
/// TWO LOAD-BEARING SETTINGS (documented in tests/conformance/COVERAGE_STUDY.md
/// and asserted by tools/coverage-study/test/rq1_study_self_test.dart):
///
///  1. **Per-module `compileModule`, never `compile()`.** Real library files
///     have no `main`, and `DartCompiler.compile()` both requires an entry
///     point and wraps `_format` in a try/catch that falls back to unformatted
///     output — silently turning "emitted Dart that does not parse" into a
///     pass. `compileModule()` has no such fallback.
///  2. **Format before the check.** `compileModule()` runs `dart_style`, so an
///     output that cannot be parsed fails loudly here instead of being scored
///     on its raw text.
///
/// Cleanliness is deliberately STRICT: a file counts as clean only when it
/// encodes, compiles, re-encodes, keeps every declaration, and produces
/// metadata-stripped Ball IR identical to the first pass (metadata is cosmetic
/// by Ball's invariant #2, so stripping it is the project's own definition of
/// semantic equality). The first baselines are expected to be low — measuring
/// that honestly is the point; no floor is enforced until a baseline exists.
///
/// Usage (from the repo root):
///
///   dart run tools/coverage-study/rq1_study.dart \
///       --pins tools/coverage-study/packages/dart.json \
///       --checkouts <dir-with-one-clone-per-package> \
///       [--json <report.json>]
///
///   dart run tools/coverage-study/rq1_study.dart \
///       --package <name> --source-dir <dir> [--json <report.json>]
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart' as analyzer;
import 'package:analyzer/dart/ast/ast.dart' as ast;
import 'package:ball_base/ball_base.dart' show encodeBallFileJson;
import 'package:ball_base/gen/ball/v1/ball.pb.dart' show Module, Program;
import 'package:ball_compiler/compiler.dart';
import 'package:ball_encoder/encoder.dart';

/// One file's verdict.
class FileResult {
  FileResult(
    this.package,
    this.file,
    this.clean,
    this.reason, {
    this.scored = true,
    this.irStable = false,
  });

  final String package;
  final String file;

  /// Survived every scored stage (encode → per-module compile+format →
  /// re-encode → declaration inventory).
  final bool clean;

  /// Taxonomy tag plus detail, e.g. `encode-error: ...`. `clean` when the file
  /// survived every stage, `skipped: ...` when it was not scored.
  final String reason;

  /// False for files with nothing to compile (a directives-only library, a
  /// generated part stub). Not counted in the Tier A denominator — a file with
  /// no declarations is not evidence either way.
  final bool scored;

  /// INFORMATIONAL, not part of [clean]: the metadata-stripped Ball IR of the
  /// re-encoded output is identical to the first pass. Expected false for most
  /// real files today because the compiler rebinds Ball's single `input`
  /// parameter to the source parameter name (`int twice(int input) { int value
  /// = input; … }`), which is a faithful lowering, not a loss. Reported so a
  /// future normalizer can be measured against a real baseline.
  final bool irStable;

  Map<String, Object?> toJson() => {
    'package': package,
    'file': file,
    'scored': scored,
    'clean': clean,
    'irStable': irStable,
    'reason': reason,
  };
}

/// Module names the encoder synthesizes for std base functions; they carry no
/// user code and are not compiled back.
bool _isGeneratedStdModule(Module module) {
  if (!module.name.startsWith('std')) return false;
  return module.functions.every((f) => f.isBase);
}

/// Recursively drops every `metadata` map — metadata is cosmetic (Ball
/// invariant #2), so two programs that differ only there are semantically
/// identical.
Object? stripMetadata(Object? node) {
  if (node is Map) {
    final out = <String, Object?>{};
    for (final entry in node.entries) {
      if (entry.key == 'metadata') continue;
      out[entry.key as String] = stripMetadata(entry.value);
    }
    return out;
  }
  if (node is List) return node.map(stripMetadata).toList();
  return node;
}

/// The declaration inventory of [source]: one entry per top-level declaration,
/// class members included, so a lost method is visible and mere reordering is
/// not.
Set<String> declarationInventory(String source) {
  final unit = analyzer
      .parseString(content: source, throwIfDiagnostics: false)
      .unit;
  final names = <String>{};
  for (final decl in unit.declarations) {
    if (decl is ast.ClassDeclaration) {
      // analyzer 13 moved a class/enum's identifier onto `namePart.typeName`
      // and its members behind `body` (a `BlockClassBody`); mixins still carry
      // a plain `name`. Mirrors dart/encoder/lib/encoder.dart.
      final name = decl.namePart.typeName.lexeme;
      names.add('class $name');
      final body = decl.body;
      if (body is ast.BlockClassBody) {
        names.addAll(_memberNames('class $name', body.members));
      }
    } else if (decl is ast.FunctionDeclaration) {
      names.add('function ${decl.name.lexeme}');
    } else if (decl is ast.TopLevelVariableDeclaration) {
      for (final v in decl.variables.variables) {
        names.add('var ${v.name.lexeme}');
      }
    } else if (decl is ast.EnumDeclaration) {
      final name = decl.namePart.typeName.lexeme;
      names.add('enum $name');
      for (final constant in decl.body.constants) {
        names.add('enum $name.${constant.name.lexeme}');
      }
    } else if (decl is ast.MixinDeclaration) {
      final name = decl.name.lexeme;
      names.add('mixin $name');
      names.addAll(_memberNames('mixin $name', decl.body.members));
    } else if (decl is ast.ExtensionDeclaration) {
      final name = decl.name?.lexeme ?? '<unnamed>';
      names.add('extension $name');
      names.addAll(_memberNames('extension $name', decl.body.members));
    } else if (decl is ast.ExtensionTypeDeclaration) {
      final name = decl.namePart.typeName.lexeme;
      names.add('extension type $name');
      names.addAll(_memberNames('extension type $name', decl.body.members));
    } else if (decl is ast.TypeAlias) {
      names.add('typedef ${decl.name.lexeme}');
    }
  }
  return names;
}

Iterable<String> _memberNames(
  String owner,
  Iterable<ast.ClassMember> members,
) sync* {
  for (final member in members) {
    if (member is ast.MethodDeclaration) {
      yield '$owner.${member.name.lexeme}';
    } else if (member is ast.FieldDeclaration) {
      for (final v in member.fields.variables) {
        yield '$owner.${v.name.lexeme}';
      }
    } else if (member is ast.ConstructorDeclaration) {
      yield '$owner.<init>${member.name?.lexeme ?? ''}';
    }
  }
}

String _firstLine(Object error) {
  final text = error.toString().replaceAll('\r', '');
  final cut = text.indexOf('\n');
  final line = cut == -1 ? text : text.substring(0, cut);
  return line.length > 160 ? '${line.substring(0, 160)}…' : line;
}

/// Runs Tier A over one file's [source] and returns its verdict.
FileResult studyFile(String package, String file, String source) {
  // Stage 1 — encode.
  final Program program;
  final Object? firstIr;
  try {
    program = DartEncoder().encode(source, name: 'main');
    firstIr = stripMetadata(encodeBallFileJson(program));
  } catch (e) {
    return FileResult(package, file, false, 'encode-error: ${_firstLine(e)}');
  }

  // Stage 2 — compile every user module back to Dart, PER MODULE. Real library
  // files have no entry point, so `compile()` is not an option; `compileModule`
  // also has no formatter fallback, so unparseable output fails loudly here.
  final buffer = StringBuffer();
  try {
    final compiler = DartCompiler(program);
    for (final module in program.modules) {
      if (_isGeneratedStdModule(module)) continue;
      buffer.writeln(compiler.compileModule(module.name));
    }
  } catch (e) {
    return FileResult(package, file, false, 'compile-error: ${_firstLine(e)}');
  }
  final compiled = buffer.toString();
  if (compiled.trim().isEmpty) {
    return FileResult(
      package,
      file,
      false,
      'skipped: the file compiles to nothing (no user module)',
      scored: false,
    );
  }

  // Stage 3 — re-encode the compiled Dart.
  final Program program2;
  final Object? secondIr;
  try {
    program2 = DartEncoder().encode(compiled, name: 'main');
    secondIr = stripMetadata(encodeBallFileJson(program2));
  } catch (e) {
    return FileResult(package, file, false, 'reencode-error: ${_firstLine(e)}');
  }

  // Stage 4 — declaration inventory preserved?
  final before = declarationInventory(source);
  final after = declarationInventory(compiled);
  if (before.isEmpty) {
    return FileResult(
      package,
      file,
      false,
      'skipped: no top-level declarations to compile',
      scored: false,
    );
  }
  const jsonEncoder = JsonEncoder();
  final irStable =
      jsonEncoder.convert(firstIr) == jsonEncoder.convert(secondIr);
  final lost = before.difference(after);
  if (lost.isNotEmpty) {
    final shown = (lost.toList()..sort()).take(3).join(', ');
    return FileResult(
      package,
      file,
      false,
      'declaration-drift: lost ${lost.length} declaration(s) — $shown',
      irStable: irStable,
    );
  }

  // Stage 5 — SECOND-GENERATION FIXPOINT. Comparing generation 1 against
  // generation 2 is not a usable signal: the compiler faithfully lowers Ball's
  // single `input` parameter back to a named local (`int twice(int input) {
  // int value = input; … }`), so almost nothing is stable across the FIRST
  // pass. From generation 2 onward that lowering is already applied, so a
  // pipeline that neither loses nor invents meaning must reach a fixpoint:
  // compiling the re-encoded program again must produce the same Dart and the
  // same semantic IR. A file that keeps mutating is losing information on
  // every pass.
  final String compiled2;
  final Object? thirdIr;
  try {
    final compiler2 = DartCompiler(program2);
    final buffer2 = StringBuffer();
    for (final module in program2.modules) {
      if (_isGeneratedStdModule(module)) continue;
      buffer2.writeln(compiler2.compileModule(module.name));
    }
    compiled2 = buffer2.toString();
    thirdIr = stripMetadata(
      encodeBallFileJson(DartEncoder().encode(compiled2, name: 'main')),
    );
  } catch (e) {
    return FileResult(
      package,
      file,
      false,
      'fixpoint-error: generation 2 failed to compile — ${_firstLine(e)}',
      irStable: irStable,
    );
  }
  if (compiled != compiled2 ||
      jsonEncoder.convert(secondIr) != jsonEncoder.convert(thirdIr)) {
    return FileResult(
      package,
      file,
      false,
      'fixpoint-drift: recompiling the re-encoded program changed it again',
      irStable: irStable,
    );
  }

  return FileResult(package, file, true, 'clean', irStable: irStable);
}

/// Every `.dart` file under [dir] (a package checkout's `lib/`, or any tree).
List<File> dartFilesUnder(Directory dir) =>
    dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

List<FileResult> studyDirectory(String package, Directory dir) {
  final results = <FileResult>[];
  for (final file in dartFilesUnder(dir)) {
    final rel = file.path
        .substring(dir.path.length)
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/'), '');
    String source;
    try {
      source = file.readAsStringSync();
    } catch (e) {
      results.add(
        FileResult(package, rel, false, 'read-error: ${_firstLine(e)}'),
      );
      continue;
    }
    results.add(studyFile(package, rel, source));
  }
  return results;
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf('--$name');
  if (i == -1 || i + 1 >= args.length) return null;
  return args[i + 1];
}

void main(List<String> args) {
  final results = <FileResult>[];
  final missingPins = <String>[];

  final pinsPath = _arg(args, 'pins');
  final packageName = _arg(args, 'package');
  final sourceDir = _arg(args, 'source-dir');

  if (pinsPath != null) {
    final checkouts = _arg(args, 'checkouts');
    if (checkouts == null) {
      stderr.writeln('--pins requires --checkouts <dir>');
      exit(2);
    }
    final pins =
        (jsonDecode(File(pinsPath).readAsStringSync())
                as Map<String, Object?>)['packages']
            as List<Object?>;
    for (final raw in pins) {
      final pin = raw as Map<String, Object?>;
      final name = pin['name'] as String;
      final subdir = (pin['lib'] as String?) ?? 'lib';
      final dir = Directory('$checkouts/$name/$subdir');
      if (!dir.existsSync()) {
        // An unreachable pin is NOT an encoder regression — report it as a
        // distinct outcome instead of scoring it as a failure.
        missingPins.add(name);
        continue;
      }
      results.addAll(studyDirectory(name, dir));
    }
  } else if (packageName != null && sourceDir != null) {
    final dir = Directory(sourceDir);
    if (!dir.existsSync()) {
      stderr.writeln('--source-dir does not exist: $sourceDir');
      exit(2);
    }
    results.addAll(studyDirectory(packageName, dir));
  } else {
    stderr.writeln(
      'Usage: rq1_study.dart --pins <file> --checkouts <dir> [--json <out>]\n'
      '       rq1_study.dart --package <name> --source-dir <dir> '
      '[--json <out>]',
    );
    exit(2);
  }

  final jsonOut = _arg(args, 'json');
  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'missingPins': missingPins,
        'files': [for (final r in results) r.toJson()],
      })}\n',
    );
  }

  final scored = results.where((r) => r.scored).toList();
  final total = scored.length;
  final clean = scored.where((r) => r.clean).length;
  final irStable = scored.where((r) => r.irStable).length;
  final skipped = results.length - total;
  final byReason = <String, int>{};
  for (final r in scored) {
    final tag = r.reason.split(':').first;
    byReason[tag] = (byReason[tag] ?? 0) + 1;
  }

  for (final entry
      in (byReason.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)))) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
  if (skipped > 0) {
    stdout.writeln('  skipped (no declarations, not scored): $skipped');
  }
  if (missingPins.isNotEmpty) {
    stdout.writeln(
      '  unreachable pins (not scored): ${missingPins.join(', ')}',
    );
  }
  final pct = total == 0 ? 0 : (clean * 100 / total).round();
  stdout.writeln('Tier A: $clean/$total clean ($pct%)');
  stdout.writeln(
    'Tier A (IR fixpoint, informational): $irStable/$total stable',
  );
  stdout.writeln(
    'Results: $clean passed, ${total - clean} failed, $total total',
  );

  // Positive floor: a run that scored nothing is a harness/checkout failure,
  // not a 0% result.
  if (total < 1) {
    stderr.writeln(
      'ERROR: Tier A scored 0 files — no package checkout was readable.',
    );
    exit(1);
  }
}
