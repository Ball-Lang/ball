/// Static termination and control-flow analysis for Ball programs.
///
/// Walks the expression tree of every function in a [Program] and reports:
/// - Potential infinite loops (while/for without mutation or exit)
/// - Unbounded recursion (direct/mutual recursion without base case)
/// - Unreachable code (statements after return/throw in blocks)
/// - Orphaned labeled break/continue (label not found in enclosing scope)
///
/// This is a `part of 'cli_core.dart'` and follows its **engine-safe authoring
/// rules**: warnings are plain `Map`s (`{severity, category, message,
/// location}`) collected in a `List`, expression-kind dispatch uses `hasX()`
/// presence cascades, sets are modeled as dedup `List`s, the call graph is a
/// `List` of `{key, callees}` entries (no `.keys`/`map[k]`), and every
/// recursive walker takes a **single** argument (a `Map` context, or a bare
/// `Expression` for the pure boolean probes).
part of 'cli_core.dart';

/// Analyze a Ball program for termination and control-flow issues. Returns the
/// list of warning [Map]s (empty ⇒ no issues).
List<Object?> analyzeTermination(Program program) {
  return _analyzeTerminationCore({'modules': program.modules});
}

/// Analyze a library [module] (and any inline [imports]) for termination and
/// control-flow issues — audited as the Module it is. Native-only.
List<Object?> analyzeModuleTermination(
  Module module, {
  Iterable<Module> imports = const [],
}) {
  final modules = <Module>[module];
  for (final m in imports) {
    modules.add(m);
  }
  return _analyzeTerminationCore({'modules': modules});
}

/// Core termination analysis. `ctx` = `{modules}`. Single-arg (engine-safe).
List<Object?> _analyzeTerminationCore(Map ctx) {
  final modules = ctx['modules'];
  final baseModules = _identifyBaseModules(modules);
  final warnings = <Object?>[];
  final callGraph = _buildCallGraph({
    'modules': modules,
    'baseModules': baseModules,
  });
  _checkLoops({
    'modules': modules,
    'baseModules': baseModules,
    'warnings': warnings,
  });
  _checkRecursion({
    'modules': modules,
    'callGraph': callGraph,
    'warnings': warnings,
  });
  _checkUnreachableCode({
    'modules': modules,
    'baseModules': baseModules,
    'warnings': warnings,
  });
  _checkOrphanedLabels({
    'modules': modules,
    'baseModules': baseModules,
    'warnings': warnings,
  });
  return warnings;
}

/// Format a termination warning [List] as human-readable text. Built from a
/// line list joined with `\n` plus a trailing newline (reproducing
/// `StringBuffer.writeln`) so it self-hosts on the StringBuffer-less compiled
/// TS/C++/Rust CLIs.
String formatTerminationReport(List warnings) {
  final lines = <String>[];
  lines.add('Termination Analysis');
  lines.add('============================================================');
  lines.add('');

  if (warnings.isEmpty) {
    lines.add('No issues found.');
    return '${lines.join('\n')}\n';
  }

  // Group by category, preserving first-seen order.
  final categoryOrder = <String>[];
  final byCategory = <String, Object?>{};
  for (final w in warnings) {
    final cat = w['category'];
    if (!byCategory.containsKey(cat)) {
      categoryOrder.add(cat);
      byCategory[cat] = <Object?>[];
    }
    final dynamic bucket = byCategory[cat];
    bucket.add(w);
  }

  for (final cat in categoryOrder) {
    final dynamic bucket = byCategory[cat];
    lines.add('${_categoryLabel(cat)} (${bucket.length}):');
    for (final w in bucket) {
      final sev = w['severity'];
      final icon = sev == 'error' ? '✖' : (sev == 'warning' ? '⚠' : 'ℹ');
      lines.add('  $icon ${w['location']}: ${w['message']}');
    }
    lines.add('');
  }

  var errors = 0;
  var warns = 0;
  var infos = 0;
  for (final w in warnings) {
    final sev = w['severity'];
    if (sev == 'error') errors++;
    if (sev == 'warning') warns++;
    if (sev == 'info') infos++;
  }
  lines.add('Total: $errors error(s), $warns warning(s), $infos info(s)');

  return '${lines.join('\n')}\n';
}

String _categoryLabel(String category) {
  if (category == 'infinite_loop') return 'Potential Infinite Loops';
  if (category == 'unbounded_recursion') return 'Unbounded Recursion';
  if (category == 'unreachable_code') return 'Unreachable Code';
  if (category == 'orphaned_label') return 'Orphaned Labels';
  return category;
}

/// Whether every warning has `severity == 'error'` in the list (helper for the
/// native `--exit-code` gate).
bool terminationHasErrors(List warnings) {
  for (final w in warnings) {
    if (w['severity'] == 'error') return true;
  }
  return false;
}

// ── Call graph construction ────────────────────────────────────────────────

/// Build the call graph as a `List` of `{key, callees}` entries. `ctx` =
/// `{modules, baseModules}`.
List<Object?> _buildCallGraph(Map ctx) {
  final modules = ctx['modules'];
  final baseModules = ctx['baseModules'];
  final graph = <Object?>[];
  for (final module in modules) {
    if (baseModules.contains(module.name)) continue;
    for (final fn in module.functions) {
      if (fn.isBase) continue;
      if (!fn.hasBody()) continue;
      final key = '${module.name}.${fn.name}';
      final callees = <String>[];
      _collectCallees({
        'expr': fn.body,
        'contextModule': module.name,
        'baseModules': baseModules,
        'callees': callees,
      });
      graph.add({'key': key, 'callees': callees});
    }
  }
  return graph;
}

/// Collect the non-base callee keys reachable from `ctx['expr']`. `ctx` =
/// `{expr, contextModule, baseModules, callees}`. Single-arg.
void _collectCallees(Map ctx) {
  final expr = ctx['expr'];
  final contextModule = ctx['contextModule'];
  final baseModules = ctx['baseModules'];
  final List callees = ctx['callees'];
  if (expr == null) return;

  if (expr.hasCall()) {
    final call = expr.call;
    final module = call.module.isEmpty ? contextModule : call.module;
    final fn = call.function;
    if (!baseModules.contains(module)) {
      final ck = '$module.$fn';
      if (!callees.contains(ck)) callees.add(ck);
    }
    if (call.hasInput()) {
      _collectCallees({
        'expr': call.input,
        'contextModule': contextModule,
        'baseModules': baseModules,
        'callees': callees,
      });
    }
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _collectCallees({
          'expr': stmt.let.value,
          'contextModule': contextModule,
          'baseModules': baseModules,
          'callees': callees,
        });
      }
      if (stmt.hasExpression()) {
        _collectCallees({
          'expr': stmt.expression,
          'contextModule': contextModule,
          'baseModules': baseModules,
          'callees': callees,
        });
      }
    }
    if (expr.block.hasResult()) {
      _collectCallees({
        'expr': expr.block.result,
        'contextModule': contextModule,
        'baseModules': baseModules,
        'callees': callees,
      });
    }
  } else if (expr.hasLambda()) {
    _collectCallees({
      'expr': expr.lambda.body,
      'contextModule': contextModule,
      'baseModules': baseModules,
      'callees': callees,
    });
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _collectCallees({
        'expr': field.value,
        'contextModule': contextModule,
        'baseModules': baseModules,
        'callees': callees,
      });
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _collectCallees({
        'expr': expr.fieldAccess.object,
        'contextModule': contextModule,
        'baseModules': baseModules,
        'callees': callees,
      });
    }
  } else if (expr.hasLiteral()) {
    if (expr.literal.hasListValue()) {
      for (final elem in expr.literal.listValue.elements) {
        _collectCallees({
          'expr': elem,
          'contextModule': contextModule,
          'baseModules': baseModules,
          'callees': callees,
        });
      }
    }
  }
}

// ── Infinite loop detection ─────────────────────────────────────────────────

void _checkLoops(Map ctx) {
  final modules = ctx['modules'];
  final baseModules = ctx['baseModules'];
  final warnings = ctx['warnings'];
  for (final module in modules) {
    if (baseModules.contains(module.name)) continue;
    for (final fn in module.functions) {
      if (fn.isBase) continue;
      if (!fn.hasBody()) continue;
      _checkLoopsInExpr({
        'expr': fn.body,
        'moduleName': module.name,
        'fnName': fn.name,
        'warnings': warnings,
      });
    }
  }
}

void _checkLoopsInExpr(Map ctx) {
  final expr = ctx['expr'];
  final moduleName = ctx['moduleName'];
  final fnName = ctx['fnName'];
  final warnings = ctx['warnings'];
  if (expr == null) return;

  if (expr.hasCall()) {
    final call = expr.call;
    final callModule = call.module.isEmpty ? 'std' : call.module;
    final callFn = call.function;
    if (callModule == 'std' && callFn == 'while') {
      _checkWhileLoop({
        'call': call,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
        'kind': 'while',
      });
    } else if (callModule == 'std' && callFn == 'do_while') {
      _checkWhileLoop({
        'call': call,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
        'kind': 'do-while',
      });
    } else if (callModule == 'std' && callFn == 'for') {
      _checkForLoop({
        'call': call,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
    if (call.hasInput()) {
      _checkLoopsInExpr({
        'expr': call.input,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _checkLoopsInExpr({
          'expr': stmt.let.value,
          'moduleName': moduleName,
          'fnName': fnName,
          'warnings': warnings,
        });
      }
      if (stmt.hasExpression()) {
        _checkLoopsInExpr({
          'expr': stmt.expression,
          'moduleName': moduleName,
          'fnName': fnName,
          'warnings': warnings,
        });
      }
    }
    if (expr.block.hasResult()) {
      _checkLoopsInExpr({
        'expr': expr.block.result,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  } else if (expr.hasLambda()) {
    _checkLoopsInExpr({
      'expr': expr.lambda.body,
      'moduleName': moduleName,
      'fnName': fnName,
      'warnings': warnings,
    });
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _checkLoopsInExpr({
        'expr': field.value,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _checkLoopsInExpr({
        'expr': expr.fieldAccess.object,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  }
}

/// Shared while / do-while checker; `ctx['kind']` is `'while'` or `'do-while'`.
void _checkWhileLoop(Map ctx) {
  final call = ctx['call'];
  final moduleName = ctx['moduleName'];
  final fnName = ctx['fnName'];
  final List warnings = ctx['warnings'];
  final String kind = ctx['kind'];
  final location = '$moduleName.$fnName';
  if (!call.hasInput()) return;
  final callInput = call.input;
  if (!callInput.hasMessageCreation()) return;

  final fields = callInput.messageCreation.fields;
  final condition = _getFieldValue({'fields': fields, 'name': 'condition'});
  final body = _getFieldValue({'fields': fields, 'name': 'body'});
  if (condition == null || body == null) return;

  final isLiteralTrue = _isLiteralTrue(condition);
  final condVars = <String>[];
  _collectReferencedVars({'expr': condition, 'vars': condVars});
  final hasExit = _exprHasExitSignal(body);
  final mutatedVars = <String>[];
  _collectMutatedVars({'expr': body, 'vars': mutatedVars});

  if (isLiteralTrue && !hasExit) {
    warnings.add({
      'severity': 'warning',
      'category': 'infinite_loop',
      'message': '$kind(true) loop without break or return in body',
      'location': location,
    });
    return;
  }

  var intersects = false;
  for (final v in condVars) {
    if (mutatedVars.contains(v)) intersects = true;
  }
  if (!isLiteralTrue && condVars.isNotEmpty && !hasExit && !intersects) {
    warnings.add({
      'severity': 'warning',
      'category': 'infinite_loop',
      'message':
          '$kind loop condition references ${condVars.join(", ")} but body '
          'does not modify any of them and has no break/return',
      'location': location,
    });
  }
}

void _checkForLoop(Map ctx) {
  final call = ctx['call'];
  final moduleName = ctx['moduleName'];
  final fnName = ctx['fnName'];
  final List warnings = ctx['warnings'];
  final location = '$moduleName.$fnName';
  if (!call.hasInput()) return;
  final callInput = call.input;
  if (!callInput.hasMessageCreation()) return;

  final fields = callInput.messageCreation.fields;
  final update = _getFieldValue({'fields': fields, 'name': 'update'});
  final body = _getFieldValue({'fields': fields, 'name': 'body'});

  final hasUpdate = update != null && _exprIsSet(update);
  final hasExit = body != null && _exprHasExitSignal(body);

  if (!hasUpdate && !hasExit) {
    warnings.add({
      'severity': 'warning',
      'category': 'infinite_loop',
      'message':
          'for loop without update expression and no break/return in body',
      'location': location,
    });
  }
}

// ── Unbounded recursion detection ───────────────────────────────────────────

void _checkRecursion(Map ctx) {
  final modules = ctx['modules'];
  final callGraph = ctx['callGraph'];
  final List warnings = ctx['warnings'];
  final cycles = _findCycles({'callGraph': callGraph});
  for (final dynamic cycle in cycles) {
    final List cycleList = cycle;
    for (final fnKey in cycleList) {
      if (!_hasBaseCase({'modules': modules, 'fnKey': fnKey})) {
        final cycleDesc = cycleList.length == 1
            ? 'direct recursion'
            : 'mutual recursion cycle: ${cycleList.join(" -> ")}';
        warnings.add({
          'severity': 'warning',
          'category': 'unbounded_recursion',
          'message':
              '$cycleDesc without conditional return (no base case detected)',
          'location': fnKey,
        });
        break;
      }
    }
  }
}

/// Find all simple cycles in the call graph via DFS. `ctx` = `{callGraph}`
/// (a `List` of `{key, callees}`). Returns a `List` of cycles (each a `List`
/// of function keys).
List<Object?> _findCycles(Map ctx) {
  final List callGraph = ctx['callGraph'];
  final visited = <String>[];
  final stack = <String>[];
  final cycles = <Object?>[];
  final reportedCycles = <String>[];
  for (final entry in callGraph) {
    _dfsCycles({
      'callGraph': callGraph,
      'visited': visited,
      'stack': stack,
      'cycles': cycles,
      'reportedCycles': reportedCycles,
      'node': entry['key'],
    });
  }
  return cycles;
}

void _dfsCycles(Map ctx) {
  final List callGraph = ctx['callGraph'];
  final List visited = ctx['visited'];
  final List stack = ctx['stack'];
  final List cycles = ctx['cycles'];
  final List reportedCycles = ctx['reportedCycles'];
  final String node = ctx['node'];

  if (visited.contains(node)) return;
  visited.add(node);
  stack.add(node);

  // `stack` doubles as the in-recursion set: a node is "in stack" iff present.
  final neighbors = _calleesOf(callGraph, node);
  for (final neighbor in neighbors) {
    if (stack.contains(neighbor)) {
      final cycleStart = stack.indexOf(neighbor);
      if (cycleStart >= 0) {
        final cycle = stack.sublist(cycleStart);
        final normalized = <String>[];
        for (final c in cycle) {
          normalized.add(c);
        }
        normalized.sort();
        final key = normalized.join(',');
        if (!reportedCycles.contains(key)) {
          reportedCycles.add(key);
          cycles.add(cycle);
        }
      }
    } else if (!visited.contains(neighbor)) {
      _dfsCycles({
        'callGraph': callGraph,
        'visited': visited,
        'stack': stack,
        'cycles': cycles,
        'reportedCycles': reportedCycles,
        'node': neighbor,
      });
    }
  }

  stack.removeLast();
}

/// Look up a node's callees in the `List` call graph (linear scan; the graph is
/// small). Returns an empty list when the node has no entry.
List _calleesOf(List callGraph, String node) {
  for (final entry in callGraph) {
    if (entry['key'] == node) {
      return entry['callees'];
    }
  }
  return <String>[];
}

/// Whether the function `ctx['fnKey']` has a base case (an `std.if` containing
/// an `std.return` in a branch). `ctx` = `{modules, fnKey}`.
bool _hasBaseCase(Map ctx) {
  final modules = ctx['modules'];
  final String fnKey = ctx['fnKey'];
  final fn = _findFunction(modules, fnKey);
  if (fn == null) return true; // Can't analyze, assume safe.
  if (!fn.hasBody()) return true;
  return _exprContainsConditionalReturn(fn.body);
}

bool _exprContainsConditionalReturn(dynamic expr) {
  if (expr == null) return false;
  if (expr.hasCall()) {
    final call = expr.call;
    final module = call.module.isEmpty ? 'std' : call.module;
    if (module == 'std' && call.function == 'if' && call.hasInput()) {
      final callInput = call.input;
      if (callInput.hasMessageCreation()) {
        final thenBranch = _getFieldValue({
          'fields': callInput.messageCreation.fields,
          'name': 'then',
        });
        final elseBranch = _getFieldValue({
          'fields': callInput.messageCreation.fields,
          'name': 'else',
        });
        if (thenBranch != null && _exprContainsReturn(thenBranch)) return true;
        if (elseBranch != null && _exprContainsReturn(elseBranch)) return true;
      }
    }
    if (call.hasInput()) {
      if (_exprContainsConditionalReturn(call.input)) return true;
    }
    return false;
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet() && _exprContainsConditionalReturn(stmt.let.value)) {
        return true;
      }
      if (stmt.hasExpression() &&
          _exprContainsConditionalReturn(stmt.expression)) {
        return true;
      }
    }
    if (expr.block.hasResult() &&
        _exprContainsConditionalReturn(expr.block.result)) {
      return true;
    }
    return false;
  } else if (expr.hasLambda()) {
    return _exprContainsConditionalReturn(expr.lambda.body);
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      if (_exprContainsConditionalReturn(field.value)) return true;
    }
    return false;
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      return _exprContainsConditionalReturn(expr.fieldAccess.object);
    }
    return false;
  }
  return false;
}

bool _exprContainsReturn(dynamic expr) {
  if (expr == null) return false;
  if (expr.hasCall()) {
    final call = expr.call;
    final module = call.module.isEmpty ? 'std' : call.module;
    if (module == 'std' && call.function == 'return') return true;
    if (call.hasInput()) {
      if (_exprContainsReturn(call.input)) return true;
    }
    return false;
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet() && _exprContainsReturn(stmt.let.value)) return true;
      if (stmt.hasExpression() && _exprContainsReturn(stmt.expression)) {
        return true;
      }
    }
    if (expr.block.hasResult() && _exprContainsReturn(expr.block.result)) {
      return true;
    }
    return false;
  } else if (expr.hasLambda()) {
    return _exprContainsReturn(expr.lambda.body);
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      if (_exprContainsReturn(field.value)) return true;
    }
    return false;
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      return _exprContainsReturn(expr.fieldAccess.object);
    }
    return false;
  }
  return false;
}

/// Find the function named by `key` (`"module.function"`) in [modules].
dynamic _findFunction(dynamic modules, String key) {
  final dot = key.indexOf('.');
  if (dot < 0) return null;
  final moduleName = key.substring(0, dot);
  final fnName = key.substring(dot + 1);
  for (final module in modules) {
    if (module.name != moduleName) continue;
    for (final fn in module.functions) {
      if (fn.name == fnName) return fn;
    }
  }
  return null;
}

// ── Unreachable code detection ──────────────────────────────────────────────

void _checkUnreachableCode(Map ctx) {
  final modules = ctx['modules'];
  final baseModules = ctx['baseModules'];
  final warnings = ctx['warnings'];
  for (final module in modules) {
    if (baseModules.contains(module.name)) continue;
    for (final fn in module.functions) {
      if (fn.isBase) continue;
      if (!fn.hasBody()) continue;
      _checkUnreachableInExpr({
        'expr': fn.body,
        'moduleName': module.name,
        'fnName': fn.name,
        'warnings': warnings,
      });
    }
  }
}

void _checkUnreachableInExpr(Map ctx) {
  final expr = ctx['expr'];
  final moduleName = ctx['moduleName'];
  final fnName = ctx['fnName'];
  final warnings = ctx['warnings'];
  if (expr == null) return;

  if (expr.hasBlock()) {
    _checkBlockUnreachable({
      'block': expr.block,
      'moduleName': moduleName,
      'fnName': fnName,
      'warnings': warnings,
    });
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _checkUnreachableInExpr({
          'expr': stmt.let.value,
          'moduleName': moduleName,
          'fnName': fnName,
          'warnings': warnings,
        });
      }
      if (stmt.hasExpression()) {
        _checkUnreachableInExpr({
          'expr': stmt.expression,
          'moduleName': moduleName,
          'fnName': fnName,
          'warnings': warnings,
        });
      }
    }
    if (expr.block.hasResult()) {
      _checkUnreachableInExpr({
        'expr': expr.block.result,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  } else if (expr.hasCall()) {
    if (expr.call.hasInput()) {
      _checkUnreachableInExpr({
        'expr': expr.call.input,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  } else if (expr.hasLambda()) {
    _checkUnreachableInExpr({
      'expr': expr.lambda.body,
      'moduleName': moduleName,
      'fnName': fnName,
      'warnings': warnings,
    });
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _checkUnreachableInExpr({
        'expr': field.value,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _checkUnreachableInExpr({
        'expr': expr.fieldAccess.object,
        'moduleName': moduleName,
        'fnName': fnName,
        'warnings': warnings,
      });
    }
  }
}

void _checkBlockUnreachable(Map ctx) {
  final block = ctx['block'];
  final moduleName = ctx['moduleName'];
  final fnName = ctx['fnName'];
  final List warnings = ctx['warnings'];
  final statements = block.statements;
  final count = statements.length;
  for (var i = 0; i < count; i++) {
    final stmt = statements[i];
    if (_isTerminatingStatement(stmt) && i < count - 1) {
      final unreachableCount = count - 1 - i;
      warnings.add({
        'severity': 'warning',
        'category': 'unreachable_code',
        'message':
            '$unreachableCount statement(s) after ${_terminatingCallName(stmt)} are unreachable',
        'location': '$moduleName.$fnName:stmt[${i + 1}]',
      });
      break;
    }
  }
}

bool _isTerminatingStatement(dynamic stmt) {
  if (!stmt.hasExpression()) return false;
  return _isTerminatingExpr(stmt.expression);
}

bool _isTerminatingExpr(dynamic expr) {
  if (!expr.hasCall()) return false;
  final call = expr.call;
  final module = call.module.isEmpty ? 'std' : call.module;
  return module == 'std' &&
      (call.function == 'return' ||
          call.function == 'throw' ||
          call.function == 'rethrow');
}

String _terminatingCallName(dynamic stmt) {
  if (!stmt.hasExpression()) return '?';
  final expr = stmt.expression;
  if (!expr.hasCall()) return '?';
  return 'std.${expr.call.function}';
}

// ── Orphaned label detection ────────────────────────────────────────────────

void _checkOrphanedLabels(Map ctx) {
  final modules = ctx['modules'];
  final baseModules = ctx['baseModules'];
  final List warnings = ctx['warnings'];
  for (final module in modules) {
    if (baseModules.contains(module.name)) continue;
    for (final fn in module.functions) {
      if (fn.isBase) continue;
      if (!fn.hasBody()) continue;
      final definedLabels = <String>[];
      _collectDefinedLabels({'expr': fn.body, 'labels': definedLabels});
      final usedLabels = <Object?>[];
      _collectLabelUsages({'expr': fn.body, 'usages': usedLabels});
      for (final dynamic usage in usedLabels) {
        final label = usage['label'];
        if (label.isNotEmpty && !definedLabels.contains(label)) {
          warnings.add({
            'severity': 'error',
            'category': 'orphaned_label',
            'message':
                'std.${usage['kind']}(label: "$label") references '
                'undefined label "$label"',
            'location': '${module.name}.${fn.name}',
          });
        }
      }
    }
  }
}

void _collectDefinedLabels(Map ctx) {
  final expr = ctx['expr'];
  final List labels = ctx['labels'];
  if (expr == null) return;

  if (expr.hasCall()) {
    final call = expr.call;
    final module = call.module.isEmpty ? 'std' : call.module;
    if (module == 'std' && call.function == 'label' && call.hasInput()) {
      final callInput = call.input;
      if (callInput.hasMessageCreation()) {
        final name = _getStringFieldValue({
          'fields': callInput.messageCreation.fields,
          'name': 'name',
        });
        if (name != null && name.isNotEmpty) {
          if (!labels.contains(name)) labels.add(name);
        }
      }
    }
    if (call.hasInput()) {
      _collectDefinedLabels({'expr': call.input, 'labels': labels});
    }
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _collectDefinedLabels({'expr': stmt.let.value, 'labels': labels});
      }
      if (stmt.hasExpression()) {
        _collectDefinedLabels({'expr': stmt.expression, 'labels': labels});
      }
    }
    if (expr.block.hasResult()) {
      _collectDefinedLabels({'expr': expr.block.result, 'labels': labels});
    }
  } else if (expr.hasLambda()) {
    _collectDefinedLabels({'expr': expr.lambda.body, 'labels': labels});
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _collectDefinedLabels({'expr': field.value, 'labels': labels});
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _collectDefinedLabels({
        'expr': expr.fieldAccess.object,
        'labels': labels,
      });
    }
  }
}

void _collectLabelUsages(Map ctx) {
  final expr = ctx['expr'];
  final List usages = ctx['usages'];
  if (expr == null) return;

  if (expr.hasCall()) {
    final call = expr.call;
    final module = call.module.isEmpty ? 'std' : call.module;
    if (module == 'std' &&
        (call.function == 'break' || call.function == 'continue') &&
        call.hasInput()) {
      final callInput = call.input;
      if (callInput.hasMessageCreation()) {
        final label = _getStringFieldValue({
          'fields': callInput.messageCreation.fields,
          'name': 'label',
        });
        if (label != null && label.isNotEmpty) {
          usages.add({'kind': call.function, 'label': label});
        }
      }
    }
    if (call.hasInput()) {
      _collectLabelUsages({'expr': call.input, 'usages': usages});
    }
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _collectLabelUsages({'expr': stmt.let.value, 'usages': usages});
      }
      if (stmt.hasExpression()) {
        _collectLabelUsages({'expr': stmt.expression, 'usages': usages});
      }
    }
    if (expr.block.hasResult()) {
      _collectLabelUsages({'expr': expr.block.result, 'usages': usages});
    }
  } else if (expr.hasLambda()) {
    _collectLabelUsages({'expr': expr.lambda.body, 'usages': usages});
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _collectLabelUsages({'expr': field.value, 'usages': usages});
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _collectLabelUsages({'expr': expr.fieldAccess.object, 'usages': usages});
    }
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Get a named field's expression value from `ctx['fields']` (a list of
/// FieldValuePairs); returns `null` when absent. `ctx` = `{fields, name}`.
dynamic _getFieldValue(Map ctx) {
  final fields = ctx['fields'];
  final name = ctx['name'];
  for (final f in fields) {
    if (f.name == name) return f.value;
  }
  return null;
}

/// Get a string-literal value from a named field, or `null`. `ctx` =
/// `{fields, name}`.
String? _getStringFieldValue(Map ctx) {
  final fields = ctx['fields'];
  final name = ctx['name'];
  for (final f in fields) {
    if (f.name == name) {
      final val = f.value;
      if (val.hasLiteral() && val.literal.hasStringValue()) {
        return val.literal.stringValue;
      }
    }
  }
  return null;
}

/// Whether `expr` is literally `true`.
bool _isLiteralTrue(dynamic expr) {
  if (expr == null) return false;
  if (expr.hasLiteral()) {
    return expr.literal.hasBoolValue() && expr.literal.boolValue;
  }
  return false;
}

/// Whether `expr` has any expression-kind set (i.e. is not `notSet`).
bool _exprIsSet(dynamic expr) {
  if (expr == null) return false;
  return expr.hasCall() ||
      expr.hasLiteral() ||
      expr.hasReference() ||
      expr.hasFieldAccess() ||
      expr.hasMessageCreation() ||
      expr.hasBlock() ||
      expr.hasLambda();
}

/// Collect all variable names referenced in `ctx['expr']` into `ctx['vars']`.
void _collectReferencedVars(Map ctx) {
  final expr = ctx['expr'];
  final List vars = ctx['vars'];
  if (expr == null) return;

  if (expr.hasReference()) {
    if (expr.reference.name.isNotEmpty) {
      if (!vars.contains(expr.reference.name)) vars.add(expr.reference.name);
    }
  } else if (expr.hasCall()) {
    if (expr.call.hasInput()) {
      _collectReferencedVars({'expr': expr.call.input, 'vars': vars});
    }
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _collectReferencedVars({'expr': stmt.let.value, 'vars': vars});
      }
      if (stmt.hasExpression()) {
        _collectReferencedVars({'expr': stmt.expression, 'vars': vars});
      }
    }
    if (expr.block.hasResult()) {
      _collectReferencedVars({'expr': expr.block.result, 'vars': vars});
    }
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _collectReferencedVars({'expr': field.value, 'vars': vars});
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _collectReferencedVars({'expr': expr.fieldAccess.object, 'vars': vars});
    }
  } else if (expr.hasLambda()) {
    _collectReferencedVars({'expr': expr.lambda.body, 'vars': vars});
  }
}

/// Collect variable names mutated via `std.assign` in `ctx['expr']` into
/// `ctx['vars']`.
void _collectMutatedVars(Map ctx) {
  final expr = ctx['expr'];
  final List vars = ctx['vars'];
  if (expr == null) return;

  if (expr.hasCall()) {
    final call = expr.call;
    final module = call.module.isEmpty ? 'std' : call.module;
    if (module == 'std' && call.function == 'assign' && call.hasInput()) {
      final callInput = call.input;
      if (callInput.hasMessageCreation()) {
        final target = _getFieldValue({
          'fields': callInput.messageCreation.fields,
          'name': 'target',
        });
        if (target != null && target.hasReference()) {
          if (!vars.contains(target.reference.name)) {
            vars.add(target.reference.name);
          }
        }
      }
    }
    if (call.hasInput()) {
      _collectMutatedVars({'expr': call.input, 'vars': vars});
    }
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet()) {
        _collectMutatedVars({'expr': stmt.let.value, 'vars': vars});
      }
      if (stmt.hasExpression()) {
        _collectMutatedVars({'expr': stmt.expression, 'vars': vars});
      }
    }
    if (expr.block.hasResult()) {
      _collectMutatedVars({'expr': expr.block.result, 'vars': vars});
    }
  } else if (expr.hasLambda()) {
    _collectMutatedVars({'expr': expr.lambda.body, 'vars': vars});
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      _collectMutatedVars({'expr': field.value, 'vars': vars});
    }
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      _collectMutatedVars({'expr': expr.fieldAccess.object, 'vars': vars});
    }
  }
}

/// Whether the expression tree `expr` contains a break, return, or throw
/// (not descending into lambdas — a new scope).
bool _exprHasExitSignal(dynamic expr) {
  if (expr == null) return false;
  if (expr.hasCall()) {
    final call = expr.call;
    final module = call.module.isEmpty ? 'std' : call.module;
    if (module == 'std' &&
        (call.function == 'break' ||
            call.function == 'return' ||
            call.function == 'throw')) {
      return true;
    }
    if (call.hasInput()) {
      if (_exprHasExitSignal(call.input)) return true;
    }
    return false;
  } else if (expr.hasBlock()) {
    for (final stmt in expr.block.statements) {
      if (stmt.hasLet() && _exprHasExitSignal(stmt.let.value)) return true;
      if (stmt.hasExpression() && _exprHasExitSignal(stmt.expression)) {
        return true;
      }
    }
    if (expr.block.hasResult() && _exprHasExitSignal(expr.block.result)) {
      return true;
    }
    return false;
  } else if (expr.hasLambda()) {
    return false;
  } else if (expr.hasMessageCreation()) {
    for (final field in expr.messageCreation.fields) {
      if (_exprHasExitSignal(field.value)) return true;
    }
    return false;
  } else if (expr.hasFieldAccess()) {
    if (expr.fieldAccess.hasObject()) {
      return _exprHasExitSignal(expr.fieldAccess.object);
    }
    return false;
  }
  return false;
}
