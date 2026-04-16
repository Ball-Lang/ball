/// Static capability analysis for Ball programs.
///
/// Walks the expression tree of every function in a [Program] and reports
/// which base functions are called, categorized by side-effect capability.
/// Since every side effect in Ball flows through a named base function,
/// this analysis is provably complete — not heuristic.
library;

import 'gen/ball/v1/ball.pb.dart';
import 'capability_table.dart';

/// Analyze a Ball program and return a structured capability report.
BallCapabilityReport analyzeCapabilities(
  Program program, {
  bool reachableOnly = false,
}) {
  final analyzer = _Analyzer(program, reachableOnly: reachableOnly);
  return analyzer.analyze();
}

class _Analyzer {
  final Program program;
  final bool reachableOnly;

  final Map<String, Set<Capability>> _fnCaps = {};
  final Map<String, List<CallSite>> _capCallSites = {};
  final Set<String> _baseModules = {};

  _Analyzer(this.program, {this.reachableOnly = false});

  BallCapabilityReport analyze() {
    _identifyBaseModules();

    if (reachableOnly) {
      _analyzeReachable();
    } else {
      _analyzeAll();
    }

    return _buildReport();
  }

  void _identifyBaseModules() {
    for (final module in program.modules) {
      final allBase = module.functions.every((f) => f.isBase);
      if (allBase && module.functions.isNotEmpty) {
        _baseModules.add(module.name);
      }
    }
  }

  void _analyzeAll() {
    for (final module in program.modules) {
      if (_baseModules.contains(module.name)) continue;
      for (final fn in module.functions) {
        if (fn.isBase) continue;
        final caps = <Capability>{};
        _walkExpression(fn.body, module.name, fn.name, caps);
        _fnCaps['${module.name}.${fn.name}'] = caps;
      }
    }
  }

  void _analyzeReachable() {
    final visited = <String>{};
    final entryKey = '${program.entryModule}.${program.entryFunction}';
    _analyzeFunction(entryKey, visited);
  }

  void _analyzeFunction(String key, Set<String> visited) {
    if (visited.contains(key)) return;
    visited.add(key);

    final parts = key.split('.');
    if (parts.length < 2) return;
    final moduleName = parts[0];
    final fnName = parts.sublist(1).join('.');

    if (_baseModules.contains(moduleName)) return;

    for (final module in program.modules) {
      if (module.name != moduleName) continue;
      for (final fn in module.functions) {
        if (fn.name != fnName) continue;
        if (fn.isBase) return;
        final caps = <Capability>{};
        final callees = <String>{};
        _walkExpression(fn.body, moduleName, fnName, caps, callees: callees);
        _fnCaps[key] = caps;
        for (final callee in callees) {
          _analyzeFunction(callee, visited);
          final calleeCaps = _fnCaps[callee];
          if (calleeCaps != null) caps.addAll(calleeCaps);
        }
        return;
      }
    }
  }

  void _walkExpression(
    Expression expr,
    String contextModule,
    String contextFunction,
    Set<Capability> caps, {
    Set<String>? callees,
  }) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        _walkCall(expr.call, contextModule, contextFunction, caps,
            callees: callees);
      case Expression_Expr.literal:
        _walkLiteral(expr.literal, contextModule, contextFunction, caps,
            callees: callees);
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _walkExpression(stmt.let.value, contextModule, contextFunction,
                caps, callees: callees);
          }
          if (stmt.hasExpression()) {
            _walkExpression(stmt.expression, contextModule, contextFunction,
                caps, callees: callees);
          }
        }
        if (expr.block.hasResult()) {
          _walkExpression(expr.block.result, contextModule, contextFunction,
              caps, callees: callees);
        }
      case Expression_Expr.lambda:
        _walkExpression(expr.lambda.body, contextModule, contextFunction, caps,
            callees: callees);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _walkExpression(field.value, contextModule, contextFunction, caps,
              callees: callees);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _walkExpression(expr.fieldAccess.object, contextModule,
              contextFunction, caps, callees: callees);
        }
      case Expression_Expr.reference:
        break;
      case Expression_Expr.notSet:
        break;
    }
  }

  void _walkCall(
    FunctionCall call,
    String contextModule,
    String contextFunction,
    Set<Capability> caps, {
    Set<String>? callees,
  }) {
    final module = call.module.isEmpty ? contextModule : call.module;
    final fn = call.function;

    final cap = lookupCapability(module, fn);
    if (cap != null) {
      caps.add(cap);
      if (cap != Capability.pure) {
        _capCallSites.putIfAbsent(cap.name, () => []).add(CallSite()
          ..module = contextModule
          ..function = contextFunction
          ..calleeModule = module
          ..calleeFunction = fn);
      }
    } else {
      callees?.add('$module.$fn');
    }

    if (call.hasInput()) {
      _walkExpression(
          call.input, contextModule, contextFunction, caps,
          callees: callees);
    }
  }

  void _walkLiteral(
    Literal lit,
    String contextModule,
    String contextFunction,
    Set<Capability> caps, {
    Set<String>? callees,
  }) {
    if (lit.hasListValue()) {
      for (final elem in lit.listValue.elements) {
        _walkExpression(elem, contextModule, contextFunction, caps,
            callees: callees);
      }
    }
  }

  BallCapabilityReport _buildReport() {
    final report = BallCapabilityReport()
      ..programName = program.name
      ..programVersion = program.version;

    final allCaps = <Capability>{};
    var totalFns = 0;
    var pureFns = 0;
    var effectfulFns = 0;

    for (final entry in _fnCaps.entries) {
      final parts = entry.key.split('.');
      final fnCap = FunctionCapability()
        ..module = parts[0]
        ..function = parts.sublist(1).join('.');
      fnCap.capabilities.addAll(entry.value.map((c) => c.name));
      report.functions.add(fnCap);

      allCaps.addAll(entry.value);
      totalFns++;
      if (entry.value.every((c) => c == Capability.pure)) {
        pureFns++;
      } else {
        effectfulFns++;
      }
    }

    for (final cap in Capability.values) {
      if (!allCaps.contains(cap) && cap != Capability.pure) continue;
      final sites = _capCallSites[cap.name] ?? [];
      if (cap == Capability.pure && sites.isEmpty && allCaps.contains(cap)) {
        report.capabilities.add(CapabilityEntry()
          ..capability = cap.name
          ..riskLevel = capabilityRiskLevel[cap]!);
        continue;
      }
      if (sites.isNotEmpty) {
        final entry = CapabilityEntry()
          ..capability = cap.name
          ..riskLevel = capabilityRiskLevel[cap]!;
        entry.callSites.addAll(sites);
        report.capabilities.add(entry);
      }
    }

    report.summary = CapabilitySummary()
      ..isPure = allCaps.every((c) => c == Capability.pure)
      ..readsFilesystem = allCaps.contains(Capability.fs)
      ..writesFilesystem = allCaps.contains(Capability.fs)
      ..readsStdin = _capCallSites['io']?.any(
              (s) => s.calleeFunction == 'read_line') ??
          false
      ..writesStdout = _capCallSites['io']?.any(
              (s) => s.calleeFunction == 'print' ||
                  s.calleeFunction == 'print_error') ??
          false
      ..writesStderr = _capCallSites['io']?.any(
              (s) => s.calleeFunction == 'print_error') ??
          false
      ..readsEnvironment = _capCallSites['io']?.any(
              (s) => s.calleeFunction == 'env_get' ||
                  s.calleeFunction == 'args_get') ??
          false
      ..controlsProcess = allCaps.contains(Capability.process)
      ..usesMemory = allCaps.contains(Capability.memory)
      ..usesTime = allCaps.contains(Capability.time)
      ..usesRandom = allCaps.contains(Capability.random)
      ..usesConcurrency = allCaps.contains(Capability.concurrency)
      ..usesNetwork = allCaps.contains(Capability.network)
      ..totalFunctions = totalFns
      ..pureFunctions = pureFns
      ..effectfulFunctions = effectfulFns;

    return report;
  }
}

/// Format a capability report as human-readable text.
String formatCapabilityReport(BallCapabilityReport report) {
  final buf = StringBuffer();
  buf.writeln('Ball Capability Audit: ${report.programName} v${report.programVersion}');
  buf.writeln('=' * 60);
  buf.writeln();

  buf.writeln('Capabilities:');
  for (final entry in report.capabilities) {
    final icon = entry.riskLevel == 'none' ? '\u2713' : '\u26A0';
    final siteCount = entry.callSites.length;
    if (siteCount == 0) {
      buf.writeln('  $icon ${entry.capability} (pure computation)');
    } else {
      final sites = entry.callSites
          .map((s) => '${s.module}.${s.function} \u2192 ${s.calleeModule}.${s.calleeFunction}')
          .join(', ');
      buf.writeln('  $icon ${entry.capability} ($siteCount call sites: $sites)');
    }
  }

  final absent = <String>[];
  final s = report.summary;
  if (!s.readsFilesystem && !s.writesFilesystem) absent.add('filesystem');
  if (!s.usesNetwork) absent.add('network');
  if (!s.controlsProcess) absent.add('process');
  if (!s.usesMemory) absent.add('memory');
  if (!s.usesConcurrency) absent.add('concurrency');
  if (!s.usesRandom) absent.add('random');
  if (absent.isNotEmpty) {
    buf.writeln('  \u2717 NONE: ${absent.join(', ')}');
  }

  buf.writeln();
  final risk = s.isPure
      ? 'NO RISK \u2014 pure computation only'
      : s.controlsProcess || s.usesMemory || s.usesNetwork
          ? 'HIGH RISK'
          : s.readsFilesystem || s.writesFilesystem || s.usesConcurrency
              ? 'MEDIUM RISK'
              : 'LOW RISK';
  buf.writeln('Summary: $risk');
  buf.writeln('  ${s.totalFunctions} functions: ${s.pureFunctions} pure, ${s.effectfulFunctions} effectful');

  buf.writeln();
  buf.writeln('Per-function breakdown:');
  for (final fn in report.functions) {
    final caps = fn.capabilities.where((c) => c != 'pure').toList();
    final label = caps.isEmpty ? 'pure' : caps.join(', ');
    buf.writeln('  ${fn.module}.${fn.function} \u2192 $label');
  }

  return buf.toString();
}

/// Check a report against a deny list. Returns list of violations (empty = pass).
List<String> checkPolicy(
  BallCapabilityReport report, {
  Set<String> deny = const {},
}) {
  final violations = <String>[];
  for (final entry in report.capabilities) {
    if (deny.contains(entry.capability)) {
      for (final site in entry.callSites) {
        violations.add(
          '${entry.capability}: ${site.module}.${site.function} calls '
          '${site.calleeModule}.${site.calleeFunction}',
        );
      }
    }
  }
  return violations;
}
