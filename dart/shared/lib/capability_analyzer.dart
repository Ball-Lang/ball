/// Static capability analysis for Ball programs.
///
/// Walks the expression tree of every function in a [Program] and reports
/// which base functions are called, categorized by side-effect capability.
/// Since every side effect in Ball flows through a named base function,
/// this analysis is provably complete — not heuristic.
///
/// This is a `part of 'cli_core.dart'` and follows its **engine-safe authoring
/// rules**: the report is a plain `Map`/`List` (never a proto message, which
/// throws on unset-field reads when constructed in-engine), expression-kind
/// dispatch uses `hasX()` presence cascades (not the `whichExpr()` enum, which
/// the engine returns as a String), capability categories are Strings (not a
/// Dart `enum`), and every recursive walker takes a **single** `Map` argument
/// (the engine binds one parameter to the whole input map).
///
/// Report shape (`Map<String, Object?>`):
/// ```
/// {
///   'programName': String, 'programVersion': String,
///   'capabilities': [ {'capability','riskLevel','callSites':[
///       {'module','function','calleeModule','calleeFunction'} ]} ],
///   'functions': [ {'module','function','capabilities':[String]} ],
///   'summary': { 'isPure','readsFilesystem',…,'totalFunctions',… },
/// }
/// ```
part of 'cli_core.dart';

/// Analyze a Ball program and return a structured capability report [Map].
/// Every function is analyzed (whole-program view).
Map<String, Object?> analyzeCapabilities(Program program) {
  return _analyzeCapabilitiesCore({
    'modules': program.modules,
    'programName': program.name,
    'programVersion': program.version,
  });
}

/// Analyze a library [module] (e.g. `ball_protobuf`) plus any inline [imports]
/// and return its capability report [Map]. A library has no entry point, so
/// reachability does not apply and every function is analyzed. Native-only (the
/// self-hosted `auditReport` never audits a bare Module).
Map<String, Object?> analyzeModuleCapabilities(
  Module module, {
  Iterable<Module> imports = const [],
}) {
  final modules = <Module>[module];
  for (final m in imports) {
    modules.add(m);
  }
  return _analyzeCapabilitiesCore({
    'modules': modules,
    'programName': module.name,
    'programVersion': '',
  });
}

/// Reachability-scoped capability analysis: analyze only the transitive closure
/// of the program's entry function. Native-only (`ball audit --reachable-only`).
Map<String, Object?> analyzeCapabilitiesReachable(Program program) {
  final table = buildCapabilityTable();
  final baseModules = _identifyBaseModules(program.modules);
  final fnCaps = <String, Object?>{}; // "module.function" -> List<String> caps
  final capSites = <String, Object?>{}; // capName -> List<site>
  final visited = <String>[];
  _analyzeReachableFn({
    'modules': program.modules,
    'baseModules': baseModules,
    'table': table,
    'fnCaps': fnCaps,
    'capSites': capSites,
    'visited': visited,
    'module': program.entryModule,
    'function': program.entryFunction,
  });

  final functionsOut = <Object?>[];
  for (final key in fnCaps.keys) {
    final dot = key.indexOf('.');
    final mod = key.substring(0, dot);
    final fn = key.substring(dot + 1);
    functionsOut.add({
      'module': mod,
      'function': fn,
      'capabilities': fnCaps[key],
    });
  }
  return _buildReportFromFunctions(
    program.name,
    program.version,
    functionsOut,
    capSites,
  );
}

/// Recursively analyze the function `ctx['module'].ctx['function']` and its
/// non-base callees, merging callee capabilities into the caller. Single-arg
/// (engine-safe form, though this reachable path is native-only).
void _analyzeReachableFn(Map ctx) {
  final modules = ctx['modules'];
  final baseModules = ctx['baseModules'];
  final table = ctx['table'];
  final Map fnCaps = ctx['fnCaps'];
  final capSites = ctx['capSites'];
  final List visited = ctx['visited'];
  final String moduleName = ctx['module'];
  final String fnName = ctx['function'];
  final key = '$moduleName.$fnName';
  if (visited.contains(key)) return;
  visited.add(key);

  if (baseModules.contains(moduleName)) return;

  for (final module in modules) {
    if (module.name != moduleName) continue;
    for (final fn in module.functions) {
      if (fn.name != fnName) continue;
      if (fn.isBase) return;
      final caps = <String>[];
      final callees = <Object?>[];
      if (!fn.hasBody()) {
        fnCaps[key] = caps;
        return;
      }
      _walkCap({
        'expr': fn.body,
        'module': moduleName,
        'function': fnName,
        'caps': caps,
        'capSites': capSites,
        'table': table,
        'callees': callees,
      });
      fnCaps[key] = caps;
      for (final dynamic callee in callees) {
        _analyzeReachableFn({
          'modules': modules,
          'baseModules': baseModules,
          'table': table,
          'fnCaps': fnCaps,
          'capSites': capSites,
          'visited': visited,
          'module': callee['module'],
          'function': callee['function'],
        });
        final calleeKey = '${callee['module']}.${callee['function']}';
        if (fnCaps.containsKey(calleeKey)) {
          final List calleeCaps = fnCaps[calleeKey];
          for (final c in calleeCaps) {
            if (!caps.contains(c)) caps.add(c);
          }
        }
      }
      return;
    }
  }
}

/// Whole-program capability analysis core. `ctx` = `{modules, programName,
/// programVersion}`. Single-arg so it self-hosts on the Ball engine.
Map<String, Object?> _analyzeCapabilitiesCore(Map ctx) {
  final modules = ctx['modules'];
  final String programName = ctx['programName'];
  final String programVersion = ctx['programVersion'];

  final table = buildCapabilityTable();
  final baseModules = _identifyBaseModules(modules);
  final functionsOut = <Object?>[];
  final capSites = <String, Object?>{}; // capName -> List<site>

  for (final module in modules) {
    if (baseModules.contains(module.name)) continue;
    for (final fn in module.functions) {
      if (fn.isBase) continue;
      final caps = <String>[];
      // A non-base function may still lack a body (e.g. metadata-only stubs);
      // reading `fn.body` then throws on the engine, whereas native proto
      // getters return a default empty expression — so guard on `hasBody()`
      // (an empty walk contributes no capabilities either way).
      if (fn.hasBody()) {
        _walkCap({
          'expr': fn.body,
          'module': module.name,
          'function': fn.name,
          'caps': caps,
          'capSites': capSites,
          'table': table,
          'callees': null,
        });
      }
      functionsOut.add({
        'module': module.name,
        'function': fn.name,
        'capabilities': caps,
      });
    }
  }

  return _buildReportFromFunctions(
    programName,
    programVersion,
    functionsOut,
    capSites,
  );
}

/// The list of module names whose functions are all base functions.
List<String> _identifyBaseModules(dynamic modules) {
  final baseModules = <String>[];
  for (final module in modules) {
    var allBase = true;
    var hasAny = false;
    for (final f in module.functions) {
      hasAny = true;
      if (!f.isBase) allBase = false;
    }
    if (allBase && hasAny) baseModules.add(module.name);
  }
  return baseModules;
}

/// Walk one expression, accumulating capabilities into `ctx['caps']` and call
/// sites into `ctx['capSites']`. When `ctx['callees']` is a list, non-base
/// function calls are recorded there (reachability mode). Single-arg.
void _walkCap(Map ctx) {
  final expr = ctx['expr'];
  final module = ctx['module'];
  final function = ctx['function'];
  final caps = ctx['caps'];
  final capSites = ctx['capSites'];
  final table = ctx['table'];
  final callees = ctx['callees'];
  if (expr == null) return;

  if (expr.hasCall()) {
    _walkCapCall({
      'call': expr.call,
      'module': module,
      'function': function,
      'caps': caps,
      'capSites': capSites,
      'table': table,
      'callees': callees,
    });
  } else if (expr.hasLiteral()) {
    final lit = expr.literal;
    if (lit.hasListValue()) {
      for (final elem in lit.listValue.elements) {
        _walkCap({
          'expr': elem,
          'module': module,
          'function': function,
          'caps': caps,
          'capSites': capSites,
          'table': table,
          'callees': callees,
        });
      }
    }
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _walkCap({
          'expr': stmt.let.value,
          'module': module,
          'function': function,
          'caps': caps,
          'capSites': capSites,
          'table': table,
          'callees': callees,
        });
      }
      if (stmt.hasExpression()) {
        _walkCap({
          'expr': stmt.expression,
          'module': module,
          'function': function,
          'caps': caps,
          'capSites': capSites,
          'table': table,
          'callees': callees,
        });
      }
    }
    if (expr.block.hasResult()) {
      _walkCap({
        'expr': expr.block.result,
        'module': module,
        'function': function,
        'caps': caps,
        'capSites': capSites,
        'table': table,
        'callees': callees,
      });
    }
  } else if (expr.hasLambda()) {
    _walkCap({
      'expr': expr.lambda.body,
      'module': module,
      'function': function,
      'caps': caps,
      'capSites': capSites,
      'table': table,
      'callees': callees,
    });
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _walkCap({
        'expr': field.value,
        'module': module,
        'function': function,
        'caps': caps,
        'capSites': capSites,
        'table': table,
        'callees': callees,
      });
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _walkCap({
        'expr': expr.fieldAccess.object,
        'module': module,
        'function': function,
        'caps': caps,
        'capSites': capSites,
        'table': table,
        'callees': callees,
      });
    }
  }
}

/// Classify one function call, adding its capability to `ctx['caps']` and its
/// call site to `ctx['capSites']`, then recurse into the call's input. Single-arg.
void _walkCapCall(Map ctx) {
  final call = ctx['call'];
  final contextModule = ctx['module'];
  final contextFunction = ctx['function'];
  final List caps = ctx['caps'];
  final Map capSites = ctx['capSites'];
  final table = ctx['table'];
  final callees = ctx['callees'];

  final module = call.module.isEmpty ? contextModule : call.module;
  final fn = call.function;

  final cap = lookupCapability(table, module, fn);
  if (cap.isNotEmpty) {
    if (!caps.contains(cap)) caps.add(cap);
    if (cap != 'pure') {
      List sites;
      if (capSites.containsKey(cap)) {
        sites = capSites[cap];
      } else {
        sites = <Object?>[];
        capSites[cap] = sites;
      }
      sites.add({
        'module': contextModule,
        'function': contextFunction,
        'calleeModule': module,
        'calleeFunction': fn,
      });
    }
  } else if (callees != null) {
    callees.add({'module': module, 'function': fn});
  }

  if (call.hasInput()) {
    _walkCap({
      'expr': call.input,
      'module': contextModule,
      'function': contextFunction,
      'caps': caps,
      'capSites': capSites,
      'table': table,
      'callees': callees,
    });
  }
}

/// Assemble the final report [Map] from the per-function capability list and
/// the recorded call sites. Single-arg-friendly (four positional args, all
/// values already computed — only ever called natively/from core).
Map<String, Object?> _buildReportFromFunctions(
  String programName,
  String programVersion,
  List functionsOut,
  Map capSites,
) {
  final allCaps = <String>[];
  var totalFns = 0;
  var pureFns = 0;
  var effectfulFns = 0;

  for (final entry in functionsOut) {
    final List entryCaps = entry['capabilities'];
    for (final c in entryCaps) {
      if (!allCaps.contains(c)) allCaps.add(c);
    }
    totalFns++;
    var onlyPure = true;
    for (final c in entryCaps) {
      if (c != 'pure') onlyPure = false;
    }
    if (onlyPure) {
      pureFns++;
    } else {
      effectfulFns++;
    }
  }

  final capabilitiesOut = <Object?>[];
  for (final cap in capabilityNames()) {
    final present = allCaps.contains(cap);
    if (!present && cap != 'pure') continue;
    List sites;
    if (capSites.containsKey(cap)) {
      sites = capSites[cap];
    } else {
      sites = <Object?>[];
    }
    if (cap == 'pure' && sites.isEmpty && present) {
      capabilitiesOut.add({
        'capability': cap,
        'riskLevel': capabilityRisk(cap),
        'callSites': <Object?>[],
      });
      continue;
    }
    if (sites.isNotEmpty) {
      capabilitiesOut.add({
        'capability': cap,
        'riskLevel': capabilityRisk(cap),
        'callSites': sites,
      });
    }
  }

  final ioSites = capSites.containsKey('io') ? capSites['io'] : <Object?>[];
  var readsStdin = false;
  var writesStdout = false;
  var writesStderr = false;
  var readsEnvironment = false;
  for (final s in ioSites) {
    final callee = s['calleeFunction'];
    if (callee == 'read_line') readsStdin = true;
    if (callee == 'print' || callee == 'print_error') writesStdout = true;
    if (callee == 'print_error') writesStderr = true;
    if (callee == 'env_get' || callee == 'args_get') readsEnvironment = true;
  }

  var isPure = true;
  for (final c in allCaps) {
    if (c != 'pure') isPure = false;
  }

  final summary = <String, Object?>{
    'isPure': isPure,
    'readsFilesystem': allCaps.contains('fs'),
    'writesFilesystem': allCaps.contains('fs'),
    'readsStdin': readsStdin,
    'writesStdout': writesStdout,
    'writesStderr': writesStderr,
    'readsEnvironment': readsEnvironment,
    'controlsProcess': allCaps.contains('process'),
    'usesMemory': allCaps.contains('memory'),
    'usesTime': allCaps.contains('time'),
    'usesRandom': allCaps.contains('random'),
    'usesConcurrency': allCaps.contains('concurrency'),
    'usesNetwork': allCaps.contains('network'),
    'totalFunctions': totalFns,
    'pureFunctions': pureFns,
    'effectfulFunctions': effectfulFns,
  };

  return <String, Object?>{
    'programName': programName,
    'programVersion': programVersion,
    'capabilities': capabilitiesOut,
    'functions': functionsOut,
    'summary': summary,
  };
}

/// Format a capability report [Map] as human-readable text (byte-identical to
/// the legacy proto-report renderer). Built from a line list joined with `\n`
/// plus a trailing newline — reproducing `StringBuffer.writeln` semantics — so
/// it self-hosts on the compiled TS/C++/Rust CLIs (which have no StringBuffer).
String formatCapabilityReport(Map report) {
  final lines = <String>[];
  lines.add(
    'Ball Capability Audit: ${report['programName']} v${report['programVersion']}',
  );
  lines.add('============================================================');
  lines.add('');

  lines.add('Capabilities:');
  final List capabilities = report['capabilities'];
  for (final entry in capabilities) {
    final icon = entry['riskLevel'] == 'none' ? '✓' : '⚠';
    final List callSites = entry['callSites'];
    final siteCount = callSites.length;
    if (siteCount == 0) {
      lines.add('  $icon ${entry['capability']} (pure computation)');
    } else {
      final siteStrs = <String>[];
      for (final s in callSites) {
        siteStrs.add(
          '${s['module']}.${s['function']} → ${s['calleeModule']}.${s['calleeFunction']}',
        );
      }
      final sites = siteStrs.join(', ');
      lines.add(
        '  $icon ${entry['capability']} ($siteCount call sites: $sites)',
      );
    }
  }

  final Map s = report['summary'];
  final absent = <String>[];
  final readsFs = s['readsFilesystem'];
  final writesFs = s['writesFilesystem'];
  if (readsFs == false && writesFs == false) absent.add('filesystem');
  if (s['usesNetwork'] == false) absent.add('network');
  if (s['controlsProcess'] == false) absent.add('process');
  if (s['usesMemory'] == false) absent.add('memory');
  if (s['usesConcurrency'] == false) absent.add('concurrency');
  if (s['usesRandom'] == false) absent.add('random');
  if (absent.isNotEmpty) {
    lines.add('  ✗ NONE: ${absent.join(', ')}');
  }

  lines.add('');
  final isPure = s['isPure'] == true;
  final controlsProcess = s['controlsProcess'] == true;
  final usesMemory = s['usesMemory'] == true;
  final usesNetwork = s['usesNetwork'] == true;
  final rFs = s['readsFilesystem'] == true;
  final wFs = s['writesFilesystem'] == true;
  final usesConcurrency = s['usesConcurrency'] == true;
  String risk;
  if (isPure) {
    risk = 'NO RISK — pure computation only';
  } else if (controlsProcess || usesMemory || usesNetwork) {
    risk = 'HIGH RISK';
  } else if (rFs || wFs || usesConcurrency) {
    risk = 'MEDIUM RISK';
  } else {
    risk = 'LOW RISK';
  }
  lines.add('Summary: $risk');
  lines.add(
    '  ${s['totalFunctions']} functions: ${s['pureFunctions']} pure, ${s['effectfulFunctions']} effectful',
  );

  lines.add('');
  lines.add('Per-function breakdown:');
  final List functions = report['functions'];
  for (final fn in functions) {
    final List fnCaps = fn['capabilities'];
    final nonPure = <String>[];
    for (final c in fnCaps) {
      if (c != 'pure') nonPure.add(c);
    }
    final label = nonPure.isEmpty ? 'pure' : nonPure.join(', ');
    lines.add('  ${fn['module']}.${fn['function']} → $label');
  }

  return '${lines.join('\n')}\n';
}

/// Check a report [Map] against a [deny] list of capability names. Returns the
/// list of violation strings (empty = pass). Native-friendly wrapper over the
/// engine-safe [checkPolicyViolations].
List<String> checkPolicy(Map report, {Set<String> deny = const {}}) {
  final denyList = <String>[];
  for (final d in deny) {
    denyList.add(d);
  }
  return checkPolicyViolations({'report': report, 'deny': denyList});
}

/// Engine-safe policy check: `ctx` = `{report, deny(List<String>)}`. Returns a
/// list of violation strings, one per denied call site.
List<String> checkPolicyViolations(Map ctx) {
  final Map report = ctx['report'];
  final List deny = ctx['deny'];
  final violations = <String>[];
  final List capabilities = report['capabilities'];
  for (final entry in capabilities) {
    if (deny.contains(entry['capability'])) {
      final List callSites = entry['callSites'];
      for (final site in callSites) {
        violations.add(
          '${entry['capability']}: ${site['module']}.${site['function']} calls '
          '${site['calleeModule']}.${site['calleeFunction']}',
        );
      }
    }
  }
  return violations;
}
