/// Portable Ball CLI verbs — the single source of truth for the report text
/// produced by `ball info`, `ball validate`, `ball tree`, `ball audit`, and
/// `ball version`.
///
/// Every function here is a pure `Program`/`Module`-IR → report-`String`
/// transform with **no `dart:io`**: the native CLI shells own argv and stream
/// I/O, and this library owns the report text. Because it depends only on the
/// generated proto types (plus the equally-portable capability/termination
/// analyzers), it round-trips through `DartEncoder` into
/// `dart/self_host/cli.ball.json` and executes on the Ball engine, so the CLI
/// verbs run identically whether invoked natively or self-hosted (see the
/// parity gate in `dart/cli/test/cli_core_parity_test.dart`).
///
/// **Engine-safe authoring rules** (this file is round-tripped and executed by
/// the tree-walking engine over proto3-JSON maps, per `.claude/rules/dart.md`):
///   - Prefer explicit `for` loops over `.every`/`.fold`/`.where`/`.firstOrNull`.
///   - Never mutate a collection via `.addAll` (mis-routed to `list_concat`);
///     append per-item with `.add`.
///   - Access a presence-sensitive message/oneof field only after a
///     `hasX()`/`whichX()` guard (these route to the `ball_proto` module).
library;

import 'gen/ball/v1/ball.pb.dart';

part 'capability_table.dart';
part 'capability_analyzer.dart';
part 'termination_analyzer.dart';

// ── version ──────────────────────────────────────────────────────────────

/// The line printed by `ball version`: `ball <version>`.
String versionLine(String version) {
  return 'ball $version';
}

// ── info ─────────────────────────────────────────────────────────────────

/// The report printed by `ball info <input.ball.json>` (no trailing newline).
String infoReport(Program program) {
  final lines = <String>[];
  lines.add('Program: ${program.name} v${program.version}');
  lines.add('Entry:   ${program.entryModule}.${program.entryFunction}');
  lines.add('Modules: ${program.modules.length}');
  lines.add('');

  for (final module in program.modules) {
    final isBase = _allBase(module.functions);
    lines.add('  ${module.name}${isBase ? " (base)" : ""}');
    if (module.typeDefs.isNotEmpty) {
      lines.add('    typeDefs:  ${module.typeDefs.length}');
    }
    if (module.typeAliases.isNotEmpty) {
      lines.add('    aliases:   ${module.typeAliases.length}');
    }
    if (module.enums.isNotEmpty) {
      lines.add('    enums:     ${module.enums.length}');
    }
    lines.add('    functions: ${module.functions.length}');
    if (module.description.isNotEmpty) {
      lines.add('    desc:      ${module.description}');
    }
  }

  return lines.join('\n');
}

// ── validate ─────────────────────────────────────────────────────────────

/// The validation errors for [program] (empty ⇒ valid). Mirrors the checks the
/// native `ball validate` verb historically inlined.
List<String> validationErrors(Program program) {
  final errors = <String>[];

  if (program.entryModule.isEmpty) {
    errors.add('Missing entry_module');
  }
  if (program.entryFunction.isEmpty) {
    errors.add('Missing entry_function');
  }

  if (program.entryModule.isNotEmpty && program.entryFunction.isNotEmpty) {
    Module? entryMod;
    for (final m in program.modules) {
      if (m.name == program.entryModule) {
        entryMod = m;
        break;
      }
    }
    if (entryMod == null) {
      errors.add('Entry module "${program.entryModule}" not found in modules');
    } else {
      FunctionDefinition? entryFunc;
      for (final f in entryMod.functions) {
        if (f.name == program.entryFunction) {
          entryFunc = f;
          break;
        }
      }
      if (entryFunc == null) {
        errors.add(
          'Entry function "${program.entryFunction}" not found '
          'in module "${program.entryModule}"',
        );
      }
    }
  }

  for (var i = 0; i < program.modules.length; i++) {
    final m = program.modules[i];
    if (m.name.isEmpty) {
      errors.add('Module at index $i has no name');
    }
  }

  final seen = <String>[];
  for (final m in program.modules) {
    if (m.name.isNotEmpty) {
      if (seen.contains(m.name)) {
        errors.add('Duplicate module name: "${m.name}"');
      } else {
        seen.add(m.name);
      }
    }
  }

  for (final m in program.modules) {
    for (final f in m.functions) {
      if (!f.isBase && !f.hasBody() && !f.hasMetadata()) {
        errors.add(
          '${m.name}.${f.name}: non-base function with no body or metadata',
        );
      }
    }
  }

  return errors;
}

/// Whether [program] is valid (no validation errors) — drives the native
/// verb's exit code and stream selection.
bool validateOk(Program program) {
  return validationErrors(program).isEmpty;
}

/// The report printed by `ball validate <input.ball.json>` (no trailing
/// newline). On the valid path this is the `Valid: …` block; on the invalid
/// path the `Invalid: …` block. The native verb routes it to stdout/stderr and
/// picks the exit code via [validateOk].
String validateReport(Program program) {
  final errors = validationErrors(program);
  if (errors.isEmpty) {
    var totalFns = 0;
    for (final m in program.modules) {
      totalFns += m.functions.length;
    }
    return 'Valid: "${program.name}" v${program.version}\n'
        '  ${program.modules.length} modules, $totalFns functions';
  }

  final lines = <String>[];
  lines.add('Invalid: ${errors.length} error(s) found');
  for (final e in errors) {
    lines.add('  - $e');
  }
  return lines.join('\n');
}

// ── tree ─────────────────────────────────────────────────────────────────

/// The report printed by `ball tree <input.ball.json>` (no trailing newline).
String treeReport(Program program) {
  final lines = <String>[];
  lines.add('${program.name} v${program.version}');

  for (final m in program.modules) {
    final isBase = _allBase(m.functions) && m.functions.isNotEmpty;
    final tag = isBase ? ' (base)' : '';
    final fnCount = m.functions.length;
    lines.add('  ${m.name}$tag — $fnCount functions');
    for (final imp in m.moduleImports) {
      lines.add('    → ${imp.name} (${_importSource(imp)})');
    }
  }

  return lines.join('\n');
}

/// Human-readable source descriptor for a module import (matches the native
/// `ball tree` rendering). Uses per-branch `hasX()` presence checks (all routed
/// to `ball_proto`) rather than the `whichSource()` discriminator: the Dart
/// engine represents proto oneof-case enums as maps, so a `whichSource() ==
/// ModuleImport_Source.x` comparison cannot self-host, whereas the boolean
/// `hasX()` accessors round-trip cleanly.
String _importSource(ModuleImport imp) {
  if (imp.hasHttp()) {
    return 'http: ${imp.http.url}';
  }
  if (imp.hasFile()) {
    return 'file: ${imp.file.path}';
  }
  if (imp.hasGit()) {
    return 'git: ${imp.git.url}@${imp.git.ref}';
  }
  if (imp.hasRegistry()) {
    return '${imp.registry.registry.name}: '
        '${imp.registry.package}@${imp.registry.version}';
  }
  if (imp.hasInline()) {
    return 'inline';
  }
  return 'ref only';
}

// ── audit ────────────────────────────────────────────────────────────────

/// The report printed by `ball audit <input.ball.json>` for a [program] with
/// default options (all functions analyzed, termination check on). Reuses the
/// shared capability + termination analyzers so the native verb and this
/// function are a single implementation.
///
/// Returns the exact byte sequence the native verb appends to stdout: the
/// capability report, then — only when termination warnings exist — a blank
/// line and the termination report.
String auditReport(Program program) {
  final report = analyzeCapabilities(program);
  final buf = StringBuffer();
  buf.writeln(formatCapabilityReport(report));

  final termWarnings = analyzeTermination(program);
  if (termWarnings.isNotEmpty) {
    buf.writeln('');
    buf.writeln(formatTerminationReport(termWarnings));
  }
  return buf.toString();
}

// ── helpers ──────────────────────────────────────────────────────────────

/// Whether every function in [functions] is a base function. Matches
/// `functions.every((f) => f.isBase)` — an empty list yields `true`.
bool _allBase(List<FunctionDefinition> functions) {
  for (final f in functions) {
    if (!f.isBase) return false;
  }
  return true;
}
