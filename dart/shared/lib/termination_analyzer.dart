/// Static termination and control-flow analysis for Ball programs.
///
/// Walks the expression tree of every function in a [Program] and reports:
/// - Potential infinite loops (while/for without mutation or exit)
/// - Unbounded recursion (direct/mutual recursion without base case)
/// - Unreachable code (statements after return/throw in blocks)
/// - Orphaned labeled break/continue (label not found in enclosing scope)
library;

import 'gen/ball/v1/ball.pb.dart';

/// Analyze a Ball program for termination and control-flow issues.
TerminationReport analyzeTermination(Program program) {
  final analyzer = _TerminationAnalyzer(program);
  return analyzer.analyze();
}

/// Structured report of termination analysis warnings.
class TerminationReport {
  final List<TerminationWarning> warnings;

  const TerminationReport(this.warnings);

  bool get hasErrors => warnings.any((w) => w.severity == 'error');
  bool get hasWarnings =>
      warnings.any((w) => w.severity == 'warning' || w.severity == 'error');
  bool get isEmpty => warnings.isEmpty;
}

/// A single warning from termination analysis.
class TerminationWarning {
  /// 'error', 'warning', or 'info'
  final String severity;

  /// 'infinite_loop', 'unbounded_recursion', 'unreachable_code', 'orphaned_label'
  final String category;

  /// Human-readable description.
  final String message;

  /// Location as "module.function" or "module.function:stmt[N]".
  final String location;

  const TerminationWarning({
    required this.severity,
    required this.category,
    required this.message,
    required this.location,
  });

  @override
  String toString() => '[$severity] $category at $location: $message';
}

/// Format a termination report as human-readable text.
String formatTerminationReport(TerminationReport report) {
  final buf = StringBuffer();
  buf.writeln('Termination Analysis');
  buf.writeln('=' * 60);
  buf.writeln();

  if (report.isEmpty) {
    buf.writeln('No issues found.');
    return buf.toString();
  }

  final byCategory = <String, List<TerminationWarning>>{};
  for (final w in report.warnings) {
    byCategory.putIfAbsent(w.category, () => []).add(w);
  }

  for (final entry in byCategory.entries) {
    buf.writeln('${_categoryLabel(entry.key)} (${entry.value.length}):');
    for (final w in entry.value) {
      final icon = w.severity == 'error'
          ? '\u2716'
          : w.severity == 'warning'
              ? '\u26A0'
              : '\u2139';
      buf.writeln('  $icon ${w.location}: ${w.message}');
    }
    buf.writeln();
  }

  final errors = report.warnings.where((w) => w.severity == 'error').length;
  final warns = report.warnings.where((w) => w.severity == 'warning').length;
  final infos = report.warnings.where((w) => w.severity == 'info').length;
  buf.writeln('Total: $errors error(s), $warns warning(s), $infos info(s)');

  return buf.toString();
}

String _categoryLabel(String category) {
  switch (category) {
    case 'infinite_loop':
      return 'Potential Infinite Loops';
    case 'unbounded_recursion':
      return 'Unbounded Recursion';
    case 'unreachable_code':
      return 'Unreachable Code';
    case 'orphaned_label':
      return 'Orphaned Labels';
    default:
      return category;
  }
}

// ── Analyzer Implementation ──────────────────────────────────────────────────

class _TerminationAnalyzer {
  final Program program;
  final List<TerminationWarning> _warnings = [];

  /// Call graph: "module.function" -> set of "module.function" it calls.
  final Map<String, Set<String>> _callGraph = {};

  /// Base modules (all functions are isBase).
  final Set<String> _baseModules = {};

  _TerminationAnalyzer(this.program);

  TerminationReport analyze() {
    _identifyBaseModules();
    _buildCallGraph();
    _checkLoops();
    _checkRecursion();
    _checkUnreachableCode();
    _checkOrphanedLabels();
    return TerminationReport(_warnings);
  }

  void _identifyBaseModules() {
    for (final module in program.modules) {
      if (module.functions.isNotEmpty &&
          module.functions.every((f) => f.isBase)) {
        _baseModules.add(module.name);
      }
    }
  }

  // ── Call graph construction ──────────────────────────────────────────────

  void _buildCallGraph() {
    for (final module in program.modules) {
      if (_baseModules.contains(module.name)) continue;
      for (final fn in module.functions) {
        if (fn.isBase) continue;
        final key = '${module.name}.${fn.name}';
        final callees = <String>{};
        _collectCallees(fn.body, module.name, callees);
        _callGraph[key] = callees;
      }
    }
  }

  void _collectCallees(
      Expression expr, String contextModule, Set<String> callees) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        final call = expr.call;
        final module = call.module.isEmpty ? contextModule : call.module;
        final fn = call.function;
        // Only track non-base function calls for recursion analysis.
        if (!_baseModules.contains(module)) {
          callees.add('$module.$fn');
        }
        if (call.hasInput()) {
          _collectCallees(call.input, contextModule, callees);
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _collectCallees(stmt.let.value, contextModule, callees);
          }
          if (stmt.hasExpression()) {
            _collectCallees(stmt.expression, contextModule, callees);
          }
        }
        if (expr.block.hasResult()) {
          _collectCallees(expr.block.result, contextModule, callees);
        }
      case Expression_Expr.lambda:
        _collectCallees(expr.lambda.body, contextModule, callees);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _collectCallees(field.value, contextModule, callees);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _collectCallees(expr.fieldAccess.object, contextModule, callees);
        }
      case Expression_Expr.literal:
        if (expr.literal.hasListValue()) {
          for (final elem in expr.literal.listValue.elements) {
            _collectCallees(elem, contextModule, callees);
          }
        }
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
  }

  // ── Infinite loop detection ─────────────────────────────────────────────

  void _checkLoops() {
    for (final module in program.modules) {
      if (_baseModules.contains(module.name)) continue;
      for (final fn in module.functions) {
        if (fn.isBase) continue;
        _checkLoopsInExpr(fn.body, module.name, fn.name);
      }
    }
  }

  void _checkLoopsInExpr(
      Expression expr, String moduleName, String fnName) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        final call = expr.call;
        final callModule = call.module.isEmpty ? 'std' : call.module;
        final callFn = call.function;

        if (callModule == 'std' && callFn == 'while') {
          _checkWhileLoop(call, moduleName, fnName);
        } else if (callModule == 'std' && callFn == 'do_while') {
          _checkDoWhileLoop(call, moduleName, fnName);
        } else if (callModule == 'std' && callFn == 'for') {
          _checkForLoop(call, moduleName, fnName);
        }

        // Recurse into input to find nested loops.
        if (call.hasInput()) {
          _checkLoopsInExpr(call.input, moduleName, fnName);
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _checkLoopsInExpr(stmt.let.value, moduleName, fnName);
          }
          if (stmt.hasExpression()) {
            _checkLoopsInExpr(stmt.expression, moduleName, fnName);
          }
        }
        if (expr.block.hasResult()) {
          _checkLoopsInExpr(expr.block.result, moduleName, fnName);
        }
      case Expression_Expr.lambda:
        _checkLoopsInExpr(expr.lambda.body, moduleName, fnName);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _checkLoopsInExpr(field.value, moduleName, fnName);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _checkLoopsInExpr(expr.fieldAccess.object, moduleName, fnName);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
  }

  void _checkWhileLoop(
      FunctionCall call, String moduleName, String fnName) {
    final location = '$moduleName.$fnName';
    if (!call.hasInput()) return;
    final input = call.input;
    if (input.whichExpr() != Expression_Expr.messageCreation) return;

    final fields = input.messageCreation.fields;
    final condition = _getField(fields, 'condition');
    final body = _getField(fields, 'body');

    if (condition == null || body == null) return;

    // Check if the condition is a literal true.
    final isLiteralTrue = _isLiteralTrue(condition);

    // Collect variables referenced in the condition.
    final condVars = <String>{};
    _collectReferencedVars(condition, condVars);

    // Check if the body modifies any condition variable or has break/return.
    final hasExit = _exprHasExitSignal(body);
    final mutatedVars = <String>{};
    _collectMutatedVars(body, mutatedVars);

    if (isLiteralTrue && !hasExit) {
      _warnings.add(TerminationWarning(
        severity: 'warning',
        category: 'infinite_loop',
        message:
            'while(true) loop without break or return in body',
        location: location,
      ));
    } else if (!isLiteralTrue &&
        condVars.isNotEmpty &&
        !hasExit &&
        condVars.intersection(mutatedVars).isEmpty) {
      _warnings.add(TerminationWarning(
        severity: 'warning',
        category: 'infinite_loop',
        message:
            'while loop condition references ${condVars.join(", ")} but body '
            'does not modify any of them and has no break/return',
        location: location,
      ));
    }
  }

  void _checkDoWhileLoop(
      FunctionCall call, String moduleName, String fnName) {
    final location = '$moduleName.$fnName';
    if (!call.hasInput()) return;
    final input = call.input;
    if (input.whichExpr() != Expression_Expr.messageCreation) return;

    final fields = input.messageCreation.fields;
    final condition = _getField(fields, 'condition');
    final body = _getField(fields, 'body');

    if (condition == null || body == null) return;

    final isLiteralTrue = _isLiteralTrue(condition);
    final condVars = <String>{};
    _collectReferencedVars(condition, condVars);
    final hasExit = _exprHasExitSignal(body);
    final mutatedVars = <String>{};
    _collectMutatedVars(body, mutatedVars);

    if (isLiteralTrue && !hasExit) {
      _warnings.add(TerminationWarning(
        severity: 'warning',
        category: 'infinite_loop',
        message:
            'do-while(true) loop without break or return in body',
        location: location,
      ));
    } else if (!isLiteralTrue &&
        condVars.isNotEmpty &&
        !hasExit &&
        condVars.intersection(mutatedVars).isEmpty) {
      _warnings.add(TerminationWarning(
        severity: 'warning',
        category: 'infinite_loop',
        message:
            'do-while loop condition references ${condVars.join(", ")} but body '
            'does not modify any of them and has no break/return',
        location: location,
      ));
    }
  }

  void _checkForLoop(
      FunctionCall call, String moduleName, String fnName) {
    final location = '$moduleName.$fnName';
    if (!call.hasInput()) return;
    final input = call.input;
    if (input.whichExpr() != Expression_Expr.messageCreation) return;

    final fields = input.messageCreation.fields;
    final update = _getField(fields, 'update');
    final body = _getField(fields, 'body');

    // Missing update expression is suspicious.
    final hasUpdate = update != null && update.whichExpr() != Expression_Expr.notSet;
    final hasExit = body != null && _exprHasExitSignal(body);

    if (!hasUpdate && !hasExit) {
      _warnings.add(TerminationWarning(
        severity: 'warning',
        category: 'infinite_loop',
        message: 'for loop without update expression and no break/return in body',
        location: location,
      ));
    }
  }

  // ── Unbounded recursion detection ───────────────────────────────────────

  void _checkRecursion() {
    // Find all cycles in the call graph.
    final cycles = _findCycles();
    for (final cycle in cycles) {
      // For each function in the cycle, check if it has a base case.
      for (final fnKey in cycle) {
        if (!_hasBaseCase(fnKey)) {
          final cycleDesc =
              cycle.length == 1 ? 'direct recursion' : 'mutual recursion cycle: ${cycle.join(" -> ")}';
          _warnings.add(TerminationWarning(
            severity: 'warning',
            category: 'unbounded_recursion',
            message:
                '$cycleDesc without conditional return (no base case detected)',
            location: fnKey,
          ));
          // Only warn once per cycle, not once per member.
          break;
        }
      }
    }
  }

  /// Find all simple cycles in the call graph using DFS.
  /// Returns list of cycles, each cycle is a list of function keys.
  List<List<String>> _findCycles() {
    final visited = <String>{};
    final inStack = <String>{};
    final stack = <String>[];
    final cycles = <List<String>>[];
    final reportedCycles = <String>{};

    void dfs(String node) {
      if (visited.contains(node)) return;
      visited.add(node);
      inStack.add(node);
      stack.add(node);

      final neighbors = _callGraph[node] ?? {};
      for (final neighbor in neighbors) {
        if (inStack.contains(neighbor)) {
          // Found a cycle — extract it.
          final cycleStart = stack.indexOf(neighbor);
          if (cycleStart >= 0) {
            final cycle = stack.sublist(cycleStart);
            // Normalize for dedup: sort cycle members.
            final normalized = List<String>.from(cycle)..sort();
            final key = normalized.join(',');
            if (!reportedCycles.contains(key)) {
              reportedCycles.add(key);
              cycles.add(cycle);
            }
          }
        } else if (!visited.contains(neighbor)) {
          dfs(neighbor);
        }
      }

      stack.removeLast();
      inStack.remove(node);
    }

    for (final node in _callGraph.keys) {
      dfs(node);
    }
    return cycles;
  }

  /// Check if a function has a base case: an std.if call that contains
  /// an std.return before the recursive call path.
  bool _hasBaseCase(String fnKey) {
    final fn = _findFunction(fnKey);
    if (fn == null) return true; // Can't analyze, assume safe.
    return _exprContainsConditionalReturn(fn.body);
  }

  /// Returns true if the expression tree contains an std.if call that has
  /// an std.return in either its then or else branch.
  bool _exprContainsConditionalReturn(Expression expr) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        final call = expr.call;
        final module = call.module.isEmpty ? 'std' : call.module;
        if (module == 'std' && call.function == 'if' && call.hasInput()) {
          final input = call.input;
          if (input.whichExpr() == Expression_Expr.messageCreation) {
            final thenBranch = _getField(input.messageCreation.fields, 'then');
            final elseBranch = _getField(input.messageCreation.fields, 'else');
            if ((thenBranch != null && _exprContainsReturn(thenBranch)) ||
                (elseBranch != null && _exprContainsReturn(elseBranch))) {
              return true;
            }
          }
        }
        if (call.hasInput()) {
          if (_exprContainsConditionalReturn(call.input)) return true;
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet() &&
              _exprContainsConditionalReturn(stmt.let.value)) {
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
      case Expression_Expr.lambda:
        return _exprContainsConditionalReturn(expr.lambda.body);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          if (_exprContainsConditionalReturn(field.value)) return true;
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          return _exprContainsConditionalReturn(expr.fieldAccess.object);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
    return false;
  }

  /// Check if expression tree contains a return call.
  bool _exprContainsReturn(Expression expr) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        final call = expr.call;
        final module = call.module.isEmpty ? 'std' : call.module;
        if (module == 'std' && call.function == 'return') return true;
        if (call.hasInput()) {
          if (_exprContainsReturn(call.input)) return true;
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet() && _exprContainsReturn(stmt.let.value)) {
            return true;
          }
          if (stmt.hasExpression() &&
              _exprContainsReturn(stmt.expression)) {
            return true;
          }
        }
        if (expr.block.hasResult() &&
            _exprContainsReturn(expr.block.result)) {
          return true;
        }
      case Expression_Expr.lambda:
        return _exprContainsReturn(expr.lambda.body);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          if (_exprContainsReturn(field.value)) return true;
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          return _exprContainsReturn(expr.fieldAccess.object);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
    return false;
  }

  FunctionDefinition? _findFunction(String key) {
    final parts = key.split('.');
    if (parts.length < 2) return null;
    final moduleName = parts[0];
    final fnName = parts.sublist(1).join('.');
    for (final module in program.modules) {
      if (module.name != moduleName) continue;
      for (final fn in module.functions) {
        if (fn.name == fnName) return fn;
      }
    }
    return null;
  }

  // ── Unreachable code detection ──────────────────────────────────────────

  void _checkUnreachableCode() {
    for (final module in program.modules) {
      if (_baseModules.contains(module.name)) continue;
      for (final fn in module.functions) {
        if (fn.isBase) continue;
        _checkUnreachableInExpr(fn.body, module.name, fn.name);
      }
    }
  }

  void _checkUnreachableInExpr(
      Expression expr, String moduleName, String fnName) {
    switch (expr.whichExpr()) {
      case Expression_Expr.block:
        _checkBlockUnreachable(expr.block, moduleName, fnName);
        // Also recurse into each statement's expression.
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _checkUnreachableInExpr(stmt.let.value, moduleName, fnName);
          }
          if (stmt.hasExpression()) {
            _checkUnreachableInExpr(stmt.expression, moduleName, fnName);
          }
        }
        if (expr.block.hasResult()) {
          _checkUnreachableInExpr(expr.block.result, moduleName, fnName);
        }
      case Expression_Expr.call:
        if (expr.call.hasInput()) {
          _checkUnreachableInExpr(expr.call.input, moduleName, fnName);
        }
      case Expression_Expr.lambda:
        _checkUnreachableInExpr(expr.lambda.body, moduleName, fnName);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _checkUnreachableInExpr(field.value, moduleName, fnName);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _checkUnreachableInExpr(
              expr.fieldAccess.object, moduleName, fnName);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
  }

  void _checkBlockUnreachable(
      Block block, String moduleName, String fnName) {
    for (var i = 0; i < block.statements.length; i++) {
      final stmt = block.statements[i];
      if (_isTerminatingStatement(stmt) && i < block.statements.length - 1) {
        // Statements after this one are unreachable.
        final unreachableCount = block.statements.length - 1 - i;
        _warnings.add(TerminationWarning(
          severity: 'warning',
          category: 'unreachable_code',
          message:
              '$unreachableCount statement(s) after ${_terminatingCallName(stmt)} are unreachable',
          location: '$moduleName.$fnName:stmt[${i + 1}]',
        ));
        break;
      }
    }
  }

  /// Check if a statement is a terminating call (return, throw, rethrow).
  bool _isTerminatingStatement(Statement stmt) {
    if (!stmt.hasExpression()) return false;
    return _isTerminatingExpr(stmt.expression);
  }

  bool _isTerminatingExpr(Expression expr) {
    if (expr.whichExpr() != Expression_Expr.call) return false;
    final call = expr.call;
    final module = call.module.isEmpty ? 'std' : call.module;
    return module == 'std' &&
        (call.function == 'return' ||
            call.function == 'throw' ||
            call.function == 'rethrow');
  }

  String _terminatingCallName(Statement stmt) {
    if (!stmt.hasExpression()) return '?';
    final expr = stmt.expression;
    if (expr.whichExpr() != Expression_Expr.call) return '?';
    return 'std.${expr.call.function}';
  }

  // ── Orphaned label detection ────────────────────────────────────────────

  void _checkOrphanedLabels() {
    for (final module in program.modules) {
      if (_baseModules.contains(module.name)) continue;
      for (final fn in module.functions) {
        if (fn.isBase) continue;
        // Collect all labels defined via std.label in this function.
        final definedLabels = <String>{};
        _collectDefinedLabels(fn.body, definedLabels);
        // Collect all labeled break/continue usages.
        final usedLabels = <_LabelUsage>[];
        _collectLabelUsages(fn.body, usedLabels);
        // Report orphans.
        for (final usage in usedLabels) {
          if (usage.label.isNotEmpty &&
              !definedLabels.contains(usage.label)) {
            _warnings.add(TerminationWarning(
              severity: 'error',
              category: 'orphaned_label',
              message:
                  'std.${usage.kind}(label: "${usage.label}") references '
                  'undefined label "${usage.label}"',
              location: '${module.name}.${fn.name}',
            ));
          }
        }
      }
    }
  }

  void _collectDefinedLabels(Expression expr, Set<String> labels) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        final call = expr.call;
        final module = call.module.isEmpty ? 'std' : call.module;
        if (module == 'std' && call.function == 'label' && call.hasInput()) {
          final input = call.input;
          if (input.whichExpr() == Expression_Expr.messageCreation) {
            final name = _getStringField(input.messageCreation.fields, 'name');
            if (name != null && name.isNotEmpty) {
              labels.add(name);
            }
          }
        }
        if (call.hasInput()) {
          _collectDefinedLabels(call.input, labels);
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _collectDefinedLabels(stmt.let.value, labels);
          }
          if (stmt.hasExpression()) {
            _collectDefinedLabels(stmt.expression, labels);
          }
        }
        if (expr.block.hasResult()) {
          _collectDefinedLabels(expr.block.result, labels);
        }
      case Expression_Expr.lambda:
        _collectDefinedLabels(expr.lambda.body, labels);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _collectDefinedLabels(field.value, labels);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _collectDefinedLabels(expr.fieldAccess.object, labels);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
  }

  void _collectLabelUsages(Expression expr, List<_LabelUsage> usages) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        final call = expr.call;
        final module = call.module.isEmpty ? 'std' : call.module;
        if (module == 'std' &&
            (call.function == 'break' || call.function == 'continue') &&
            call.hasInput()) {
          final input = call.input;
          if (input.whichExpr() == Expression_Expr.messageCreation) {
            final label =
                _getStringField(input.messageCreation.fields, 'label');
            if (label != null && label.isNotEmpty) {
              usages.add(_LabelUsage(call.function, label));
            }
          }
        }
        if (call.hasInput()) {
          _collectLabelUsages(call.input, usages);
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _collectLabelUsages(stmt.let.value, usages);
          }
          if (stmt.hasExpression()) {
            _collectLabelUsages(stmt.expression, usages);
          }
        }
        if (expr.block.hasResult()) {
          _collectLabelUsages(expr.block.result, usages);
        }
      case Expression_Expr.lambda:
        _collectLabelUsages(expr.lambda.body, usages);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _collectLabelUsages(field.value, usages);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _collectLabelUsages(expr.fieldAccess.object, usages);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  /// Get a named field's expression value from a list of FieldValuePairs.
  Expression? _getField(List<FieldValuePair> fields, String name) {
    for (final f in fields) {
      if (f.name == name) return f.value;
    }
    return null;
  }

  /// Get a string literal value from a named field.
  String? _getStringField(List<FieldValuePair> fields, String name) {
    for (final f in fields) {
      if (f.name == name) {
        final val = f.value;
        if (val.whichExpr() == Expression_Expr.literal &&
            val.literal.hasStringValue()) {
          return val.literal.stringValue;
        }
      }
    }
    return null;
  }

  /// Check if an expression is literally `true`.
  bool _isLiteralTrue(Expression expr) {
    if (expr.whichExpr() == Expression_Expr.literal) {
      return expr.literal.hasBoolValue() && expr.literal.boolValue;
    }
    return false;
  }

  /// Collect all variable names referenced in an expression.
  void _collectReferencedVars(Expression expr, Set<String> vars) {
    switch (expr.whichExpr()) {
      case Expression_Expr.reference:
        if (expr.reference.name.isNotEmpty) {
          vars.add(expr.reference.name);
        }
      case Expression_Expr.call:
        if (expr.call.hasInput()) {
          _collectReferencedVars(expr.call.input, vars);
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _collectReferencedVars(stmt.let.value, vars);
          }
          if (stmt.hasExpression()) {
            _collectReferencedVars(stmt.expression, vars);
          }
        }
        if (expr.block.hasResult()) {
          _collectReferencedVars(expr.block.result, vars);
        }
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _collectReferencedVars(field.value, vars);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _collectReferencedVars(expr.fieldAccess.object, vars);
        }
      case Expression_Expr.lambda:
        _collectReferencedVars(expr.lambda.body, vars);
      case Expression_Expr.literal:
      case Expression_Expr.notSet:
        break;
    }
  }

  /// Collect variable names mutated via std.assign in an expression.
  void _collectMutatedVars(Expression expr, Set<String> vars) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
        final call = expr.call;
        final module = call.module.isEmpty ? 'std' : call.module;
        if (module == 'std' && call.function == 'assign' && call.hasInput()) {
          final input = call.input;
          if (input.whichExpr() == Expression_Expr.messageCreation) {
            final target = _getField(input.messageCreation.fields, 'target');
            if (target != null &&
                target.whichExpr() == Expression_Expr.reference) {
              vars.add(target.reference.name);
            }
          }
        }
        if (call.hasInput()) {
          _collectMutatedVars(call.input, vars);
        }
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet()) {
            _collectMutatedVars(stmt.let.value, vars);
          }
          if (stmt.hasExpression()) {
            _collectMutatedVars(stmt.expression, vars);
          }
        }
        if (expr.block.hasResult()) {
          _collectMutatedVars(expr.block.result, vars);
        }
      case Expression_Expr.lambda:
        _collectMutatedVars(expr.lambda.body, vars);
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          _collectMutatedVars(field.value, vars);
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          _collectMutatedVars(expr.fieldAccess.object, vars);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
  }

  /// Check if an expression tree contains a break, return, or throw.
  bool _exprHasExitSignal(Expression expr) {
    switch (expr.whichExpr()) {
      case Expression_Expr.call:
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
      case Expression_Expr.block:
        for (final stmt in expr.block.statements) {
          if (stmt.hasLet() && _exprHasExitSignal(stmt.let.value)) return true;
          if (stmt.hasExpression() && _exprHasExitSignal(stmt.expression)) {
            return true;
          }
        }
        if (expr.block.hasResult() && _exprHasExitSignal(expr.block.result)) {
          return true;
        }
      case Expression_Expr.lambda:
        // Lambdas create a new scope; break/return inside won't exit the
        // enclosing loop, so we intentionally do NOT recurse here.
        return false;
      case Expression_Expr.messageCreation:
        for (final field in expr.messageCreation.fields) {
          if (_exprHasExitSignal(field.value)) return true;
        }
      case Expression_Expr.fieldAccess:
        if (expr.fieldAccess.hasObject()) {
          return _exprHasExitSignal(expr.fieldAccess.object);
        }
      case Expression_Expr.literal:
      case Expression_Expr.reference:
      case Expression_Expr.notSet:
        break;
    }
    return false;
  }
}

class _LabelUsage {
  final String kind; // 'break' or 'continue'
  final String label;
  const _LabelUsage(this.kind, this.label);
}
