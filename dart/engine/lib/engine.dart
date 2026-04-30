/// Ball engine — interprets and executes ball programs at runtime.
///
/// The engine walks the expression tree and evaluates it directly,
/// without generating any intermediate source code.
///
/// Fully compliant with the ball.v1 proto schema.
/// Supports all 73 std base functions.
library;

import 'ball_value.dart';
export 'ball_value.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/gen/google/protobuf/descriptor.pb.dart' as google;
import 'package:ball_resolver/ball_resolver.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart'
    as structpb;

part 'engine_types.dart';
part 'engine_invocation.dart';
part 'engine_eval.dart';
part 'engine_control_flow.dart';
part 'engine_std.dart';

class BallEngine {
  final Program program;

  /// Resolved type definitions by name.
  final Map<String, google.DescriptorProto> _types = {};

  /// Resolved functions by "module.function" key.
  final Map<String, FunctionDefinition> _functions = {};

  /// Separate getter function map to avoid setter overwriting getter when they
  /// share the same key.
  final Map<String, FunctionDefinition> _getters = {};

  /// Separate setter function map.
  final Map<String, FunctionDefinition> _setters = {};

  /// Global scope with top-level variable bindings.
  final _Scope _globalScope = _Scope();

  /// Standard output sink (overridable for testing).
  void Function(String) stdout;

  /// Current module context (set during function execution).
  String _currentModule = '';

  /// Pre-resolved parameter name lists, keyed by "module.function".
  /// Built once in [_buildLookupTables] to avoid repeated metadata parsing.
  final Map<String, List<String>> _paramCache = {};

  /// Lazily-populated function resolution cache for module-unqualified calls.
  /// Eliminates O(n) linear scans through all modules on repeated calls.
  final Map<String, ({String module, FunctionDefinition func})> _callCache = {};

  /// Enum type registry: maps enum type names (both qualified "module:Enum"
  /// and bare "Enum") to a map of value name → enum value object.
  /// Each enum value is a Map with __type__, name, index.
  final Map<String, Map<String, Map<String, Object?>>> _enumValues = {};

  /// Constructor registry: maps bare class names (and "module:Class" qualified
  /// names) to the default `.new` constructor function definition.  Populated
  /// during [_buildLookupTables] for every function whose metadata has
  /// `kind: "constructor"`.  Used by [_evalReference] to resolve constructor
  /// tear-offs and by [_resolveAndCallFunction] as a fallback.
  final Map<String, ({String module, FunctionDefinition func})> _constructors =
      {};

  /// Optional per-function call counters. Enabled via [enableProfiling].
  /// Mirrors V8's bytecode dispatch counters (GetDispatchCountersObject).
  Map<String, int>? _callCounts;

  /// Registered module handlers consulted by [_callBaseFunction].
  ///
  /// The list is searched in order; the first handler for which
  /// [BallModuleHandler.handles] returns `true` wins. Defaults to
  /// `[StdModuleHandler()]`, which provides the complete built-in std library.
  final List<BallModuleHandler> moduleHandlers;

  /// Shared random number generator for `random_int` / `random_double`.
  final math.Random _random = math.Random();

  /// Standard error sink (overridable for testing).
  void Function(String) stderr;

  /// Standard input line reader (overridable for testing). `null` = no stdin.
  String Function()? stdinReader;

  /// Environment variable getter (overridable for sandboxing).
  String Function(String) _envGet;

  /// Command-line arguments passed to the program.
  List<String> _args;

  /// Counter for simulated mutex handles (single-threaded mode).
  int _nextMutexId = 0;

  /// The exception currently bound inside an active `catch` block, or `null`.
  /// Used by the `rethrow` base function to re-raise the original exception.
  /// Saved and restored around each catch body so nested tries unwind cleanly.
  Object? _activeException;

  /// Optional module resolver for lazy-loading unresolved module imports.
  /// When set, if a cross-module call targets a module not yet in the
  /// lookup tables, the engine checks `module_imports` and resolves on demand.
  final ModuleResolver? _resolver;

  /// Completes when top-level variable initialisation is done.
  late final Future<void> _initialized;

  BallEngine(
    this.program, {
    void Function(String)? stdout,
    void Function(String)? stderr,
    this.stdinReader,
    String Function(String)? envGet,
    List<String>? args,
    bool enableProfiling = false,
    List<BallModuleHandler>? moduleHandlers,
    ModuleResolver? resolver,
  }) : stdout = stdout ?? print,
       _resolver = resolver,
       stderr = stderr ?? ((s) => io.stderr.writeln(s)),
       _envGet = envGet ?? ((name) => io.Platform.environment[name] ?? ''),
       _args = args ?? [],
       moduleHandlers = moduleHandlers ?? [StdModuleHandler()] {
    if (enableProfiling) _callCounts = {};
    for (final handler in this.moduleHandlers) {
      handler.init(this);
    }
    _buildLookupTables();
    _initialized = _initTopLevelVariables();
  }

  /// Returns an unmodifiable snapshot of profiling call counts.
  /// Keys are std function names; values are invocation counts.
  /// Returns an empty map when profiling was not enabled.
  Map<String, int> profilingReport() => Map.unmodifiable(_callCounts ?? {});

  /// Invoke any ball function by [module] and [function] name with [input].
  Future<Object?> callFunction(String module, String function, Object? input) =>
      _resolveAndCallFunction(module, function, input);

  void _buildLookupTables() {
    for (final module in program.modules) {
      for (final type in module.types) {
        _types[type.name] = type;
        final tc = type.name.indexOf(':');
        if (tc >= 0) _types[type.name.substring(tc + 1)] = type;
      }
      for (final td in module.typeDefs) {
        if (td.hasDescriptor()) {
          _types[td.name] = td.descriptor;
          final tc = td.name.indexOf(':');
          if (tc >= 0) _types[td.name.substring(tc + 1)] = td.descriptor;
        }
      }
      for (final enumDesc in module.enums) {
        final enumName = enumDesc.name;
        final values = <String, Map<String, Object?>>{};
        for (final v in enumDesc.value) {
          values[v.name] = <String, Object?>{
            '__type__': enumName,
            'name': v.name,
            'index': v.number,
          };
        }
        _enumValues[enumName] = values;
        final ec = enumName.indexOf(':');
        if (ec >= 0) _enumValues[enumName.substring(ec + 1)] = values;
      }

      for (final func in module.functions) {
        final key = '${module.name}.${func.name}';
        if (func.hasMetadata()) {
          final isGetterField = func.metadata.fields['is_getter'];
          final isSetterField = func.metadata.fields['is_setter'];
          if (isGetterField != null && isGetterField.boolValue) {
            _getters[key] = func;
          } else if (isSetterField != null && isSetterField.boolValue) {
            _setters[key] = func;
            _setters['$key='] = func;
          }
          if (isSetterField != null && isSetterField.boolValue) {
            _functions.putIfAbsent(key, () => func);
          } else {
            _functions[key] = func;
          }
        } else {
          _functions[key] = func;
        }
        if (func.hasMetadata()) {
          final params = _extractParams(func.metadata);
          if (params.isNotEmpty) _paramCache[key] = params;

          final kindField = func.metadata.fields['kind'];
          if (kindField?.stringValue == 'constructor') {
            final entry = (module: module.name, func: func);
            final dotIdx = func.name.indexOf('.');
            if (dotIdx >= 0) {
              final className = func.name.substring(0, dotIdx);
              final ctorSuffix = func.name.substring(dotIdx + 1);
              if (ctorSuffix == 'new') {
                _constructors[className] = entry;
                _constructors['${module.name}:$className'] = entry;
              }
              _constructors[func.name] = entry;
            }
          }
        }
      }
    }
  }

  /// Initialize top-level variables by evaluating their body expressions.
  Future<void> _initTopLevelVariables() async {
    for (final module in program.modules) {
      if (module.name == 'std' || module.name == 'dart_std') continue;
      for (final func in module.functions) {
        if (!func.hasMetadata()) continue;
        final kindValue = func.metadata.fields['kind'];
        final kindStr = kindValue?.stringValue;
        if (kindStr != 'top_level_variable' && kindStr != 'static_field') continue;
        _currentModule = module.name;
        var value = func.hasBody()
            ? await _evalExpression(func.body, _globalScope)
            : null;
        if (func.outputType.startsWith('Map')) {
          if (value is Set && value.isEmpty) value = <Object?, Object?>{};
          if (value is List && value.isEmpty) value = <Object?, Object?>{};
        }
        _globalScope.bind(func.name, value);
      }
    }
  }

  /// Execute the program starting from the entry point.
  Future<Object?> run() async {
    await _initialized;
    final key = '${program.entryModule}.${program.entryFunction}';
    final entryFunc = _functions[key];
    if (entryFunc == null) {
      throw BallRuntimeError(
        'Entry point "${program.entryFunction}" not found '
        'in module "${program.entryModule}"',
      );
    }
    _currentModule = program.entryModule;
    return _callFunction(program.entryModule, entryFunc, null);
  }
}
