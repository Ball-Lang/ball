/// Ball-to-Dart compiler.
///
/// Translates a ball [Program] AST into valid Dart source code.
///
/// Uses [code_builder] for structural AST construction and [DartFormatter]
/// for output. Expression / statement bodies are compiled to strings and
/// wrapped in [Code] nodes; the formatter handles all indentation.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/gen/google/protobuf/descriptor.pb.dart' as google;
import 'package:ball_resolver/ball_resolver.dart';
import 'package:code_builder/code_builder.dart' as cb;
import 'package:dart_style/dart_style.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart'
    as structpb;

/// Compiles a ball [Program] into formatted Dart source code.
class DartCompiler {
  final Program program;

  /// Pre-resolve all `ModuleImport` entries in [program], returning a
  /// self-contained [Program] with every import inlined as a concrete module.
  /// Compilers need full type/function signatures upfront — no lazy loading.
  static Future<Program> resolveImports(
    Program program,
    ModuleResolver resolver,
  ) => resolver.resolveAll(program);

  /// When `true`, the compiler skips the `dart_style` formatting step and
  /// returns raw (unformatted) Dart source.  Use this when the compiled output
  /// is known to confuse the formatter (e.g. deeply nested expressions from
  /// large inputs) or when formatting is intentionally unwanted.
  final bool noFormat;

  // ── Lookup tables ───────────────────────────────────────────
  final Map<String, google.DescriptorProto> _types = {};
  final Map<String, FunctionDefinition> _functions = {};
  final Set<String> _baseModules = {};

  /// Functions known to be async (by their unqualified name within
  /// the entry module). Used to auto-insert `await` when calling them
  /// and to auto-mark callers as `async`.
  final Set<String> _asyncFunctions = {};

  /// Functions known to be sync* generators (by unqualified name).
  final Set<String> _syncStarFunctions = {};

  /// Functions known to be async* generators (by unqualified name).
  final Set<String> _asyncStarFunctions = {};

  /// Variables bound to thrown Ball values (maps) — inside a catch body
  /// their `fieldAccess` expressions compile to subscript `e['field']`
  /// rather than dotted `e.field`, because Ball throws Maps and Dart
  /// Maps don't support dotted access. Populated by [_generateTry] and
  /// read by [_compileFieldAccess].
  final Set<String> _catchBoundVars = {};

  /// References proven non-null within the current branch — e.g. the `else`
  /// arm of a `x == null ? null : …` null-guard (the lowered form of a Dart
  /// `x?.method()` on a nullable field). Dart never promotes *fields*, so the
  /// guard alone doesn't make `x.call()` legal; we emit `x!.call()` instead.
  /// Populated by [_compileInlineIf] / [_generateIf]; read by [_compileCall].
  final Set<String> _nonNullRefs = {};

  /// Param-name aliases for the function currently being compiled.
  ///
  /// Ball's calling convention is "one input per function" with the
  /// canonical name `input`. The Dart encoder (and hand-written conformance
  /// programs) stash the original Dart parameter names in
  /// `metadata.params[].name` so the emitted Dart source can still declare
  /// them as `int fibonacci(int n)`. But function bodies reference `input`
  /// internally (that's the Ball convention), so we rename the declared
  /// parameter to `input` and inject `final n = input;` at the top of the
  /// body. This list is populated by [_addParameters] and consumed by
  /// [_generateFunctionBody].
  List<({String name, String? type})> _pendingParamAliases = const [];

  /// Field/getter/method names of the currently-compiled class-like
  /// container (class, mixin, extension, extension_type, enum). Used to
  /// avoid renaming a positional parameter to `input` when the class has a
  /// member named `input` — such a rename would shadow the member and
  /// change `return input;` from "return the field" to "return the param".
  Set<String> _currentClassMemberNames = const {};

  /// Top-level variable/function names — used to prevent the `input` rename
  /// from shadowing a module-level variable also named `input`.
  Set<String> _topLevelNames = const {};

  /// Collect the instance member names of a class-like container:
  /// descriptor fields + declared methods/getters/setters/fields.
  /// Static members are excluded (they don't shadow instance refs).
  Set<String> _collectClassMemberNames(
    google.DescriptorProto? descriptor,
    List<FunctionDefinition> methods,
  ) {
    final names = <String>{};
    if (descriptor != null) {
      for (final f in descriptor.field) {
        names.add(_dartFieldName(f.name));
      }
    }
    for (final m in methods) {
      final mMeta = _readMeta(m);
      if (mMeta['is_static'] == true) continue;
      names.add(_memberName(m.name));
    }
    return names;
  }

  /// Run [body] with the class member name set in scope. Ensures the
  /// previous context is restored even if [body] throws.
  T _withClassContext<T>(Set<String> members, T Function() body) {
    final saved = _currentClassMemberNames;
    _currentClassMemberNames = members;
    try {
      return body();
    } finally {
      _currentClassMemberNames = saved;
    }
  }

  // ── Per-module import alias mapping ────────────────────────
  // Maps dart module ball-names (e.g. 'dart.developer') to their import
  // alias (e.g. 'dev') for the module currently being compiled.
  Map<String, String> _dartModuleAliases = {};

  // ── Conditional import/export directives ───────────────────
  // Stored as raw strings because code_builder doesn't support them.
  // Post-processed into the output to replace the plain import.
  List<String> _conditionalDirectives = [];

  // ── Body-compilation scratch buffer ────────────────────────
  // Used ONLY inside _captureBody() — never for structural output.
  final StringBuffer _out = StringBuffer();
  int _depth = 0;

  DartCompiler(this.program, {this.noFormat = false}) {
    _buildLookupTables();
  }

  // ── code_builder ↔ string bridge ───────────────────────────
  /// Cached emitter for converting [cb.Expression] to string.
  static final _exprEmitter = cb.DartEmitter(useNullSafetySyntax: true);

  /// Convert a [cb.Expression] to its Dart source string.
  String _emit(cb.Expression expr) => expr.accept(_exprEmitter).toString();

  /// Shorthand: compile a Ball [Expression] to its Dart source string.
  String _e(Expression expr) => _emit(_compileExpression(expr));

  /// Wrap a raw Dart source [code] string as a [cb.Expression].
  cb.Expression _raw(String code) => cb.CodeExpression(cb.Code(code));

  // ════════════════════════════════════════════════════════════
  // Lookup-table construction
  // ════════════════════════════════════════════════════════════

  void _buildLookupTables() {
    for (final module in program.modules) {
      final allBase = module.functions.every((f) => f.isBase);
      if (allBase && module.functions.isNotEmpty) {
        _baseModules.add(module.name);
      }
      for (final td in module.typeDefs) {
        if (td.hasDescriptor()) {
          _types[td.name] = td.descriptor;
          final tdColon = td.name.indexOf(':');
          if (tdColon >= 0) {
            _types[td.name.substring(tdColon + 1)] = td.descriptor;
          }
        }
      }
      for (final func in module.functions) {
        _functions['${module.name}.${func.name}'] = func;
        // Track async/generator functions for auto-await/return-type fixing.
        if (func.hasMetadata()) {
          final meta = _structToMap(func.metadata);
          if (meta['is_async'] == true && meta['is_async_star'] != true) {
            _asyncFunctions.add(func.name);
          }
          if (meta['is_sync_star'] == true) {
            _syncStarFunctions.add(func.name);
          }
          if (meta['is_async_star'] == true) {
            _asyncStarFunctions.add(func.name);
          }
        }
      }
    }
  }

  // ════════════════════════════════════════════════════════════
  // Public API
  // ════════════════════════════════════════════════════════════

  /// Compile the program entry module and return formatted Dart source.
  String compile() {
    final mainModule = program.modules.firstWhere(
      (m) => m.name == program.entryModule,
      orElse: () =>
          throw StateError('Entry module "${program.entryModule}" not found'),
    );

    final entryFunc = mainModule.functions.firstWhere(
      (f) => f.name == program.entryFunction,
      orElse: () => throw StateError(
        'Entry function "${program.entryFunction}" not found',
      ),
    );

    final lib = _buildLibrary(mainModule, entryFunc);
    if (noFormat) return _emitRaw(lib);
    try {
      return _format(lib);
    } catch (_) {
      // Defensive: the dart_style formatter can choke on pathological output
      // (e.g. deeply nested expressions); fall back to raw, unformatted source.
      // No deterministic input triggers this in the test corpus.
      return _emitRaw(lib); // coverage:ignore-line
    }
  }

  /// Compile a single non-entry [moduleName] to formatted Dart source.
  ///
  /// Use this when the [Program] contains multiple user-defined modules
  /// (e.g. one per file, as produced by [PackageEncoder]) and you want to
  /// emit each module as its own independent Dart file.
  ///
  /// The module is compiled without a `main()` entry point.  All
  /// classes, enums, mixins, extensions, top-level variables, and
  /// standalone functions defined in the module are emitted, with
  /// import directives reconstructed from the module's metadata.
  ///
  /// Throws [StateError] when [moduleName] is not found in the program.
  String compileModule(String moduleName) {
    final module = program.modules.firstWhere(
      (m) => m.name == moduleName,
      orElse: () =>
          throw StateError('Module "$moduleName" not found in program'),
    );
    final lib = _buildLibrary(module, null);
    return noFormat ? _emitRaw(lib) : _format(lib);
  }

  /// Module names that [compileAllModules] failed to compile on its last run.
  ///
  /// Maps `moduleName → error` for every module that threw during both the
  /// formatted and the raw fallback compile. Callers can inspect this to
  /// detect partial output instead of silently shipping an incomplete package.
  /// Reset at the start of each [compileAllModules] call.
  final Map<String, Object> failedModules = {};

  /// Compile every non-base module in the program, returning a map
  /// of `moduleName → dartSource`.
  ///
  /// Use for library packages that have no entry point.  Base modules
  /// (std, std_collections, etc.) are skipped.  Each module is compiled
  /// independently, so the result can be written to separate files.
  ///
  /// Modules that fail to compile (even after the raw fallback) are omitted
  /// from the result and recorded in [failedModules]; check that map to
  /// detect partial output.
  Map<String, String> compileAllModules() {
    failedModules.clear();
    final result = <String, String>{};
    for (final module in program.modules) {
      // Skip base modules and empty stubs.
      final allBase = module.functions.every((f) => f.isBase);
      if (allBase && module.functions.isNotEmpty) continue;
      // A module with no local declarations is a stub UNLESS it carries
      // re-export directives in its metadata — those facades (e.g.
      // `matcher.dart`, `shelf.dart`) must still be emitted so downstream
      // imports resolve.
      final hasExports = _moduleHasExports(module);
      if (module.functions.isEmpty &&
          module.typeDefs.isEmpty &&
          module.typeAliases.isEmpty &&
          module.enums.isEmpty &&
          !hasExports &&
          module.name != program.entryModule) {
        continue;
      }
      try {
        result[module.name] = compileModule(module.name);
        // coverage:ignore-start
        // Defensive double-fallback: only fires if the dart_style formatter
        // throws (then retry raw), and the raw emit ALSO throws (then record
        // the failure). No deterministic input triggers either in the corpus.
      } catch (e) {
        // If formatting fails, try raw.
        try {
          result[module.name] = compileModuleRaw(module.name);
        } catch (rawError) {
          // Module failed both formatted and raw compilation. Record it so
          // callers can detect partial output rather than dropping it silently.
          failedModules[module.name] = rawError;
        }
      }
      // coverage:ignore-end
    }
    return result;
  }

  bool _moduleHasExports(Module module) {
    if (!module.hasMetadata()) return false;
    final exports = module.metadata.fields['dart_exports'];
    if (exports == null) return false;
    return exports.hasListValue() && exports.listValue.values.isNotEmpty;
  }

  /// Compile a single module to raw (unformatted) Dart source.
  ///
  /// Useful for diagnostics when formatting fails due to parser errors.
  String compileModuleRaw(String moduleName) {
    final module = program.modules.firstWhere(
      (m) => m.name == moduleName,
      orElse: () =>
          throw StateError('Module "$moduleName" not found in program'),
    );
    return _emitRaw(_buildLibrary(module, null));
  }

  String _format(cb.Library library) {
    final raw = _emitRaw(library);
    return DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
    ).format(raw);
  }

  String _emitRaw(cb.Library library) {
    final emitter = cb.DartEmitter.scoped(
      orderDirectives: true,
      useNullSafetySyntax: true,
    );

    var raw =
        '// Generated by ball compiler\n'
        '// Source: ${program.name} v${program.version}\n'
        '// Target: Dart\n\n'
        '${library.accept(emitter)}';

    // Post-process: replace plain import/export directives with their
    // conditional equivalents.
    for (final cond in _conditionalDirectives) {
      // Extract the base URI from the conditional directive.
      // e.g. "import 'client_stub.dart'\n    if ..." → 'client_stub.dart'
      final match = RegExp(r"^(import|export)\s+'([^']+)'").firstMatch(cond);
      if (match == null) continue;
      final kind = match.group(1)!; // import or export
      final uri = match.group(2)!;
      // Replace the plain directive (import/export 'uri' [as prefix]...)
      // with the conditional one.
      final plainPattern = RegExp(
        "$kind\\s+'${RegExp.escape(uri)}'[^;]*;",
        multiLine: true,
      );
      raw = raw.replaceFirst(plainPattern, cond);
    }
    _conditionalDirectives = [];
    return raw;
  }

  // ════════════════════════════════════════════════════════════
  // Library
  // ════════════════════════════════════════════════════════════

  /// Helper to check whether a function's output type represents a
  /// non-void return (i.e. the compiler should emit `return <expr>;`).
  static bool _hasNonVoidReturn(FunctionDefinition func) =>
      func.outputType.isNotEmpty && func.outputType != 'void';

  /// Wraps the raw return type for async/generator functions:
  /// - `async` → `Future<T>` (unless already `Future<...>` or `void`)
  /// - `sync*` → `Iterable<T>` (unless already `Iterable<...>` or `List<...>`)
  /// - `async*` → `Stream<T>` (unless already `Stream<...>` or collection)
  ///
  /// The Ball encoder often stores the "apparent" collection type
  /// (e.g. `List<int>` for a sync* generator that yields ints). In those
  /// cases we rewrite to the correct Dart generator return type.
  static String _wrapReturnType(
    String dartType, {
    required bool isAsync,
    required bool isAsyncStar,
    required bool isSyncStar,
  }) {
    if (isSyncStar) {
      if (dartType.startsWith('Iterable<') || dartType == 'Iterable') {
        return dartType;
      }
      // List<T> → Iterable<T>: extract inner type
      if (dartType.startsWith('List<') && dartType.endsWith('>')) {
        final inner = dartType.substring(5, dartType.length - 1);
        return 'Iterable<$inner>';
      }
      return 'Iterable<$dartType>';
    }
    if (isAsyncStar) {
      if (dartType.startsWith('Stream<') || dartType == 'Stream') {
        return dartType;
      }
      // List<T> → Stream<T>
      if (dartType.startsWith('List<') && dartType.endsWith('>')) {
        final inner = dartType.substring(5, dartType.length - 1);
        return 'Stream<$inner>';
      }
      return 'Stream<$dartType>';
    }
    if (isAsync) {
      if (dartType == 'void' ||
          dartType.startsWith('Future<') ||
          dartType == 'Future') {
        return dartType;
      }
      return 'Future<$dartType>';
    }
    return dartType;
  }

  cb.Library _buildLibrary(Module mainModule, FunctionDefinition? entryFunc) {
    // Build dart module → import alias mapping for this module.
    _dartModuleAliases = _buildDartModuleAliases(mainModule);

    final typeDefsByName = <String, TypeDefinition>{
      for (final td in mainModule.typeDefs) td.name: td,
    };

    // Partition functions into class members vs top-level.
    final classMethods = <String, List<FunctionDefinition>>{};
    final standaloneFunctions = <FunctionDefinition>[];
    final topLevelVars = <FunctionDefinition>[];

    for (final func in mainModule.functions) {
      if (func.isBase) continue;
      // Skip entry function — it is emitted separately at the bottom.
      if (entryFunc != null && func.name == program.entryFunction) continue;

      final meta = _readMeta(func);
      final kind = meta['kind'] as String? ?? 'function';

      // Detect class members: explicit metadata kind OR name pattern
      // (e.g. "main:Animal.new" → constructor, "main:Animal.speak" → method).
      final isClassMemberByName =
          func.name.contains(':') &&
          func.name.substring(func.name.lastIndexOf(':') + 1).contains('.');
      if (kind == 'method' ||
          kind == 'constructor' ||
          kind == 'static_field' ||
          isClassMemberByName) {
        // Class members have the form '.module:ClassName.memberName'.
        // Find the dot that separates ClassName from memberName by first
        // locating the colon (module:class boundary), then the first dot
        // after the colon.
        final colonIdx = func.name.lastIndexOf(':');
        if (colonIdx >= 0) {
          final afterColon = func.name.substring(colonIdx + 1);
          final dotIdx = afterColon.indexOf('.');
          if (dotIdx >= 0) {
            // classKey = everything before the final '.memberName'
            final classKey = func.name.substring(0, colonIdx + 1 + dotIdx);
            classMethods.putIfAbsent(classKey, () => []).add(func);
            continue;
          }
        }

        final afterColon = colonIdx >= 0
            ? func.name.substring(colonIdx + 1) // coverage:ignore-line
            : func.name;
        final dotIdx = afterColon.indexOf('.');
        if (dotIdx >= 0) {
          final classKey = func.name.substring(
            0,
            (colonIdx >= 0 ? colonIdx + 1 : 0) + dotIdx,
          );
          classMethods.putIfAbsent(classKey, () => []).add(func);
          continue;
        }
        // coverage:ignore-start
        // Unreachable: identical to the `if (dotIdx >= 0)` above — when that
        // is false, dotIdx is still < 0 here. Kept as a defensive duplicate.
        if (dotIdx >= 0) {
          final classKey = func.name.substring(0, dotIdx);
          classMethods.putIfAbsent(classKey, () => []).add(func);
          continue;
        }
        // coverage:ignore-end
      }
      if (kind == 'top_level_variable') {
        topLevelVars.add(func);
        continue;
      }
      standaloneFunctions.add(func);
    }

    // Collect top-level names for shadowing detection in _addParameters.
    _topLevelNames = {
      for (final f in standaloneFunctions) f.name,
      for (final f in topLevelVars) f.name,
    };

    return cb.Library((b) {
      // Library-level annotations (e.g. `@JS()` for JS interop libraries).
      if (mainModule.hasMetadata()) {
        final modMeta = _structToMap(mainModule.metadata);
        final libAnnots = (modMeta['library_annotations'] as List?)
            ?.cast<String>();
        if (libAnnots != null) {
          for (final ann in libAnnots) {
            b.annotations.add(cb.refer(ann));
          }
        }
      }

      b.directives.addAll(_buildDirectives(mainModule));

      // ── Auto-imports for std_* modules ──
      // If the program uses `std_convert`, inject `dart:convert` import.
      if (_baseModules.contains('std_convert')) {
        b.directives.add(cb.Directive.import('dart:convert'));
      }

      // ── Linear memory runtime preamble ──
      // If the program uses `std_memory` (linear memory simulation),
      // inject the dart:typed_data import and runtime variables.
      if (_baseModules.contains('std_memory')) {
        b.directives.add(cb.Directive.import('dart:typed_data'));
        b.body.add(
          cb.Code(
            '// Ball linear memory runtime\n'
            'final _ballMemory = ByteData(65536);\n'
            'int _ballHeapPtr = 0;\n'
            'final _ballStackFrames = <int>[];\n'
            'int _ballStackPtr = 65536;\n',
          ),
        );
      }

      // Type aliases — code_builder has no general typedef spec, emit as Code.
      for (final alias in mainModule.typeAliases) {
        b.body.add(cb.Code(_buildTypeAliasStr(alias)));
      }

      // Enums
      for (final enumDef in mainModule.enums) {
        b.body.add(
          _buildEnum(
            enumDef,
            typeDefsByName[enumDef.name],
            classMethods.remove(enumDef.name) ?? [],
          ),
        );
      }

      // Mixins
      for (final td in mainModule.typeDefs) {
        if (_kindOf(td) != 'mixin') continue;
        b.body.add(_buildMixin(td, classMethods.remove(td.name) ?? []));
      }

      // Classes (all except mixin / extension / extension_type)
      for (final td in mainModule.typeDefs) {
        final kind = _kindOf(td);
        if (kind == 'mixin' ||
            kind == 'extension' ||
            kind == 'extension_type') {
          continue;
        }
        if (!td.hasDescriptor()) continue;
        b.body.add(_buildClass(td, classMethods.remove(td.name) ?? []));
      }

      // Extensions
      for (final td in mainModule.typeDefs) {
        if (_kindOf(td) != 'extension') continue;
        b.body.add(_buildExtension(td, classMethods.remove(td.name) ?? []));
      }

      // Extension types
      for (final td in mainModule.typeDefs) {
        if (_kindOf(td) != 'extension_type') continue;
        b.body.add(_buildExtensionType(td, classMethods.remove(td.name) ?? []));
      }

      // Top-level variables (complex modifiers → raw Code)
      for (final func in topLevelVars) {
        b.body.add(cb.Code(_buildTopLevelVarStr(func)));
      }

      // Standalone functions
      for (final func in standaloneFunctions) {
        b.body.add(_buildFunction(func));
      }

      // Entry point — only for entry module compilation.
      if (entryFunc != null) {
        b.body.add(_buildMainFunction(entryFunc));
      }
    });
  }

  // ════════════════════════════════════════════════════════════
  // Directives
  // ════════════════════════════════════════════════════════════

  /// Build a map from ball module names to their original import alias.
  /// Covers both dart:* imports (e.g. 'dart.developer' → 'dev') and
  /// package:* imports (e.g. 'path' → 'p').
  Map<String, String> _buildDartModuleAliases(Module module) {
    if (!module.hasMetadata()) return const {};
    final meta = _structToMap(module.metadata);
    final imports = meta['dart_imports'];
    if (imports is! List) return const {};
    final aliases = <String, String>{};
    for (final imp in imports) {
      if (imp is! Map) continue;
      final uri = imp['uri'] as String? ?? '';
      final prefix = imp['prefix'] as String?;
      if (prefix != null) {
        final ballName = _uriToModuleName(uri);
        aliases[ballName] = prefix;
        // Also resolve relative imports to full module paths.
        // E.g. 'algorithms.dart' in module 'lib.src.list_extensions'
        // → 'lib.src.algorithms'.
        if (!uri.startsWith('dart:') && !uri.startsWith('package:')) {
          final resolvedModule = _resolveRelativeModule(module.name, uri);
          if (resolvedModule != null) aliases[resolvedModule] = prefix;
        }
      }
    }
    return aliases;
  }

  /// Resolve a relative import [uri] against the current module [moduleName].
  /// E.g. moduleName='lib.src.list_extensions', uri='algorithms.dart'
  ///   → 'lib.src.algorithms'
  static String? _resolveRelativeModule(String moduleName, String uri) {
    // Convert module name to a directory path: 'lib.src.list_extensions' → 'lib/src/'
    final parts = moduleName.split('.');
    if (parts.length < 2) return null;
    final dir = parts.sublist(0, parts.length - 1).join('/');
    final resolved = Uri.parse('$dir/dummy.dart').resolve(uri);
    var path = resolved.path;
    if (path.startsWith('/')) path = path.substring(1);
    if (path.endsWith('.dart')) path = path.substring(0, path.length - 5);
    return path.replaceAll('/', '.');
  }

  /// Converts a Dart import URI to its ball module name, matching the
  /// encoder's `uriToModuleName` convention.
  static String _uriToModuleName(String uri) {
    if (uri.startsWith('dart:')) return 'dart.${uri.substring(5)}';
    if (uri.startsWith('package:')) {
      final withoutScheme = uri.substring(8);
      final slashIndex = withoutScheme.indexOf('/');
      if (slashIndex == -1) return withoutScheme;
      return withoutScheme.substring(0, slashIndex);
    }
    var n = uri;
    final lastSlash = n.lastIndexOf('/');
    if (lastSlash != -1) n = n.substring(lastSlash + 1);
    if (n.endsWith('.dart')) n = n.substring(0, n.length - 5);
    return n;
  }

  List<cb.Directive> _buildDirectives(Module mainModule) {
    if (!mainModule.hasMetadata()) return const [];
    final meta = _structToMap(mainModule.metadata);
    final result = <cb.Directive>[];

    final imports = meta['dart_imports'];
    if (imports is List) {
      for (final imp in imports) {
        if (imp is! Map) continue;
        final uri = imp['uri'] as String? ?? '';
        final prefix = imp['prefix'] as String?;
        final show = (imp['show'] as List?)?.cast<String>() ?? const <String>[];
        final hide = (imp['hide'] as List?)?.cast<String>() ?? const <String>[];
        final configurations = imp['configurations'] as List?;

        if (configurations != null && configurations.isNotEmpty) {
          // code_builder doesn't support conditional imports, so we store them
          // for later injection into the raw output.
          final buf = StringBuffer("import '$uri'");
          for (final conf in configurations) {
            if (conf is! Map) continue;
            final name = conf['name'] as String? ?? '';
            final value = conf['value'] as String?;
            final confUri = conf['uri'] as String? ?? '';
            if (value != null) {
              buf.write("\n    if ($name == '$value') '$confUri'");
            } else {
              buf.write("\n    if ($name) '$confUri'");
            }
          }
          if (prefix != null) buf.write('\n    as $prefix');
          if (show.isNotEmpty) buf.write('\n    show ${show.join(', ')}');
          if (hide.isNotEmpty) buf.write('\n    hide ${hide.join(', ')}');
          buf.write(';');
          _conditionalDirectives.add(buf.toString());
          // Also add a regular import for code_builder's tracking (will be
          // replaced in post-processing).
          result.add(
            cb.Directive.import(uri, as: prefix, show: show, hide: hide),
          );
        } else if (imp['deferred'] == true && prefix != null) {
          result.add(cb.Directive.importDeferredAs(uri, prefix));
        } else {
          result.add(
            cb.Directive.import(uri, as: prefix, show: show, hide: hide),
          );
        }
      }
    }

    final exports = meta['dart_exports'];
    if (exports is List) {
      for (final exp in exports) {
        if (exp is! Map) continue;
        final configurations = exp['configurations'] as List?;
        final show = (exp['show'] as List?)?.cast<String>() ?? const [];
        final hide = (exp['hide'] as List?)?.cast<String>() ?? const [];
        final uri = exp['uri'] as String? ?? '';

        if (configurations != null && configurations.isNotEmpty) {
          final buf = StringBuffer("export '$uri'");
          for (final conf in configurations) {
            if (conf is! Map) continue;
            final name = conf['name'] as String? ?? '';
            final value = conf['value'] as String?;
            final confUri = conf['uri'] as String? ?? '';
            if (value != null) {
              buf.write("\n    if ($name == '$value') '$confUri'");
            } else {
              buf.write("\n    if ($name) '$confUri'");
            }
          }
          if (show.isNotEmpty) buf.write('\n    show ${show.join(', ')}');
          if (hide.isNotEmpty) buf.write('\n    hide ${hide.join(', ')}');
          buf.write(';');
          _conditionalDirectives.add(buf.toString());
          // Add a regular export for code_builder tracking.
          result.add(cb.Directive.export(uri, show: show, hide: hide));
        } else {
          result.add(cb.Directive.export(uri, show: show, hide: hide));
        }
      }
    }

    return result;
  }

  // ════════════════════════════════════════════════════════════
  // Type aliases
  // ════════════════════════════════════════════════════════════

  String _buildTypeAliasStr(TypeAlias alias) {
    final meta = alias.hasMetadata()
        ? _structToMap(alias.metadata)
        : <String, Object?>{};
    final doc = meta['doc'] as String?;
    final typeParams = alias.typeParams.isEmpty
        ? ''
        : '<${alias.typeParams.map((tp) => tp.name).join(', ')}>';
    final buf = StringBuffer();
    if (doc != null) buf.writeln(doc);
    buf.write('typedef ${alias.name}$typeParams = ${alias.targetType};');
    return buf.toString();
  }

  // ════════════════════════════════════════════════════════════
  // Enums
  // ════════════════════════════════════════════════════════════

  cb.Enum _buildEnum(
    google.EnumDescriptorProto enumDef,
    TypeDefinition? td,
    List<FunctionDefinition> methods,
  ) {
    final meta = td != null ? _metaFromTd(td) : <String, Object?>{};
    final interfaces = (meta['interfaces'] as List?)?.cast<String>();
    final mixins = (meta['mixins'] as List?)?.cast<String>();
    final doc = meta['doc'] as String?;
    final values = (meta['values'] as List?)?.cast<Object?>();
    final enumFields = (meta['fields'] as List?)?.cast<Map<dynamic, dynamic>>();

    return cb.Enum((b) {
      b.name = _dartType(enumDef.name);
      _addTypeParams(b.types.add, meta);
      if (doc != null) b.docs.add(doc);
      if (mixins != null) {
        for (final m in mixins) {
          b.mixins.add(cb.refer(m));
        }
      }
      if (interfaces != null) {
        for (final i in interfaces) {
          b.implements.add(cb.refer(i));
        }
      }

      for (final v in enumDef.value) {
        final vmeta = values != null ? _findInList(values, v.name) : null;
        b.values.add(
          cb.EnumValue((ev) {
            ev.name = v.name;
            final vDoc = vmeta?['doc'] as String?;
            if (vDoc != null) ev.docs.add(vDoc);
            // Restore constructor args stored as raw source string, e.g.
            // "('nanosecond')" → arguments: [literalString('nanosecond')].
            final argsRaw = vmeta?['args'] as String?;
            if (argsRaw != null) {
              final inner = argsRaw.trim();
              // Strip outer parens if present.
              final stripped = (inner.startsWith('(') && inner.endsWith(')'))
                  ? inner.substring(1, inner.length - 1)
                  : inner;
              if (stripped.isNotEmpty) {
                ev.arguments.add(cb.CodeExpression(cb.Code(stripped)));
              }
            }
          }),
        );
      }

      if (enumFields != null) {
        for (final f in enumFields) {
          final fName = f['name'] as String? ?? '';
          final fType = f['type'] as String? ?? 'dynamic';
          b.fields.add(
            cb.Field((fb) {
              fb.name = fName;
              fb.type = cb.refer(fType);
              if (f['is_static'] == true) fb.static = true;
              if (f['is_final'] == true) fb.modifier = cb.FieldModifier.final$;
            }),
          );
        }
      }

      final memberNames = _collectClassMemberNames(null, methods);
      _withClassContext(memberNames, () {
        for (final method in methods) {
          final mMeta = _readMeta(method);
          if ((mMeta['kind'] as String?) == 'constructor') {
            b.constructors.add(_buildConstructor(enumDef.name, method, mMeta));
          } else {
            b.methods.add(_buildMethod(enumDef.name, method, mMeta));
          }
        }
      });
    });
  }

  // ════════════════════════════════════════════════════════════
  // Mixins
  // ════════════════════════════════════════════════════════════

  cb.Mixin _buildMixin(TypeDefinition td, List<FunctionDefinition> methods) {
    final descriptor = td.hasDescriptor() ? td.descriptor : null;
    final meta = _metaFromTd(td);
    final onTypes = (meta['on'] as List?)?.cast<String>();
    final interfaces = (meta['interfaces'] as List?)?.cast<String>();
    final doc = meta['doc'] as String?;

    return cb.Mixin((b) {
      b.name = _dartType(td.name);
      _addTypeParams(b.types.add, meta);
      if (doc != null) b.docs.add(doc);
      final mixinAnnots = (meta['annotations'] as List?)?.cast<String>();
      if (mixinAnnots != null) {
        for (final ann in mixinAnnots) {
          b.annotations.add(cb.refer(ann));
        }
      }
      if (meta['is_base'] == true) b.base = true;
      // code_builder supports a single 'on' type constraint per mixin.
      if (onTypes != null && onTypes.isNotEmpty) {
        b.on = cb.refer(onTypes.first);
      }
      if (interfaces != null) {
        for (final i in interfaces) {
          b.implements.add(cb.refer(i));
        }
      }
      if (descriptor != null) {
        for (final field in descriptor.field) {
          b.fields.add(
            cb.Field((fb) {
              fb.name = _dartFieldName(field.name);
              fb.type = cb.refer(_protoFieldToDartType(field));
              fb.modifier = cb.FieldModifier.final$;
            }),
          );
        }
      }
      final memberNames = _collectClassMemberNames(descriptor, methods);
      _withClassContext(memberNames, () {
        for (final method in methods) {
          b.methods.add(_buildMethod(td.name, method, _readMeta(method)));
        }
      });
    });
  }

  // ════════════════════════════════════════════════════════════
  // Classes
  // ════════════════════════════════════════════════════════════

  cb.Class _buildClass(TypeDefinition td, List<FunctionDefinition> methods) {
    final descriptor = td.descriptor;
    final meta = _metaFromTd(td);

    final isAbstract = meta['is_abstract'] == true;
    final isSealed = meta['is_sealed'] == true;
    final isBase = meta['is_base'] == true;
    final isInterface = meta['is_interface'] == true;
    final isFinal = meta['is_final'] == true;
    final isMixinClass = meta['is_mixin_class'] == true;
    final superclass = meta['superclass'] as String?;
    final interfaces = (meta['interfaces'] as List?)?.cast<String>();
    final mixins = (meta['mixins'] as List?)?.cast<String>();
    final doc = meta['doc'] as String?;
    final kind = meta['kind'] as String?;
    final classAnnots = (meta['annotations'] as List?)?.cast<String>();

    // Simple data class (no decoration, no methods)
    final isPlain =
        (kind == null || kind == 'class') &&
        !isAbstract &&
        !isSealed &&
        !isFinal &&
        !isBase &&
        !isInterface &&
        !isMixinClass &&
        superclass == null &&
        interfaces == null &&
        mixins == null &&
        doc == null &&
        classAnnots == null &&
        methods.isEmpty;
    if (isPlain) return _buildSimpleClass(descriptor);

    return cb.Class((b) {
      b.name = _dartType(descriptor.name);
      _addTypeParams(b.types.add, meta);
      if (doc != null) b.docs.add(doc);
      if (classAnnots != null) {
        for (final ann in classAnnots) {
          b.annotations.add(cb.refer(ann));
        }
      }
      if (isAbstract) b.abstract = true;
      // ClassModifier only has base/final$/interface; sealed and mixin-class
      // are separate boolean properties on ClassBuilder.
      if (isSealed) {
        b.sealed = true;
      } else if (isBase) {
        b.modifier = cb.ClassModifier.base;
      } else if (isInterface) {
        b.modifier = cb.ClassModifier.interface;
      } else if (isFinal) {
        b.modifier = cb.ClassModifier.final$;
      }
      if (isMixinClass) b.mixin = true;

      if (superclass != null) b.extend = cb.refer(superclass);
      if (mixins != null) {
        for (final m in mixins) {
          b.mixins.add(cb.refer(m));
        }
      }
      if (interfaces != null) {
        for (final i in interfaces) {
          b.implements.add(cb.refer(i));
        }
      }

      _addClassFields(b, descriptor, meta);

      final staticFields = methods
          .where((m) => (_readMeta(m)['kind'] as String?) == 'static_field')
          .toList();
      for (final sf in staticFields) {
        b.fields.add(_buildStaticField(sf));
      }

      final memberNames = _collectClassMemberNames(descriptor, methods);
      _withClassContext(memberNames, () {
        for (final method in methods) {
          final mMeta = _readMeta(method);
          var mKind = mMeta['kind'] as String? ?? 'method';
          // Detect constructors by name pattern (.new suffix) when metadata
          // doesn't explicitly mark them as constructors.
          if (mKind == 'method' && _memberName(method.name) == 'new') {
            mKind = 'constructor';
          }
          if (mKind == 'static_field') continue;
          if (mKind == 'constructor') {
            b.constructors.add(
              _buildConstructor(
                descriptor.name,
                method,
                mMeta,
                classFields: meta['fields'] as List?,
              ),
            );
          } else {
            b.methods.add(_buildMethod(descriptor.name, method, mMeta));
          }
        }
      });
    });
  }

  cb.Class _buildSimpleClass(google.DescriptorProto type) {
    return cb.Class((b) {
      b.name = _dartType(type.name);

      for (final field in type.field) {
        b.fields.add(
          cb.Field((fb) {
            fb.name = _dartFieldName(field.name);
            fb.type = cb.refer(_protoFieldToDartType(field));
            fb.modifier = cb.FieldModifier.final$;
          }),
        );
      }

      if (type.field.isNotEmpty) {
        b.constructors.add(
          cb.Constructor((c) {
            for (final field in type.field) {
              c.optionalParameters.add(
                cb.Parameter((p) {
                  p.name = _dartFieldName(field.name);
                  p.toThis = true;
                  p.named = true;
                  p.required = true;
                }),
              );
            }
          }),
        );
      }

      final fieldStr = type.field
          .map((f) => '${f.name}: \$${_dartFieldName(f.name)}')
          .join(', ');
      b.methods.add(
        cb.Method((m) {
          m.name = 'toString';
          m.returns = cb.refer('String');
          m.annotations.add(cb.refer('override'));
          m.lambda = true;
          m.body = cb.Code("'${type.name}($fieldStr)'");
        }),
      );
    });
  }

  void _addClassFields(
    cb.ClassBuilder b,
    google.DescriptorProto type,
    Map<String, Object?> meta,
  ) {
    _addInstanceFields(
      (f) => b.fields.add(f),
      (m) => b.methods.add(m),
      type,
      meta,
    );
  }

  /// Generic field-adder used by both [_addClassFields] and
  /// [_buildExtensionType] (which has an [ExtensionTypeBuilder]).
  void _addInstanceFields(
    void Function(cb.Field) addField,
    void Function(cb.Method) addMethod,
    google.DescriptorProto type,
    Map<String, Object?> meta,
  ) {
    final fieldsMeta = meta['fields'] as List?;

    for (final field in type.field) {
      final fieldName = _dartFieldName(field.name);
      String? fieldType = _protoFieldToDartType(field);
      String modifier = 'final';
      bool isLate = false;
      bool isAbstract = false;
      bool hasExplicitType = true;

      String? initializer;

      if (fieldsMeta != null) {
        for (final fm in fieldsMeta) {
          if (fm is! Map || fm['name'] != field.name) continue;
          final metaType = fm['type'] as String?;
          if (metaType != null) {
            fieldType = metaType;
            hasExplicitType = true;
          } else {
            // Source had no explicit type annotation — let Dart infer it.
            hasExplicitType = false;
          }
          if (fm['is_const'] == true) {
            modifier = 'const';
          } else if (fm['is_final'] == true) {
            modifier = 'final';
          } else {
            modifier = '';
          }
          isLate = fm['is_late'] == true;
          isAbstract = fm['is_abstract'] == true;
          initializer = fm['initializer'] as String?;
          break;
        }
      }

      if (isAbstract) {
        // Abstract fields are really abstract getters/setters.
        // Emit as abstract getter (and setter if non-final).
        addMethod(
          cb.Method((mb) {
            mb.name = fieldName;
            mb.type = cb.MethodType.getter;
            if (hasExplicitType && fieldType != null) {
              mb.returns = cb.refer(fieldType);
            }
          }),
        );
        if (modifier != 'final' && modifier != 'const') {
          addMethod(
            cb.Method((mb) {
              mb.name = fieldName;
              mb.type = cb.MethodType.setter;
              mb.requiredParameters.add(
                cb.Parameter((p) {
                  p.name = 'value';
                  if (hasExplicitType && fieldType != null) {
                    p.type = cb.refer(fieldType);
                  }
                }),
              );
            }),
          );
        }
      } else {
        addField(
          cb.Field((fb) {
            fb.name = fieldName;
            if (hasExplicitType && fieldType != null) {
              fb.type = cb.refer(fieldType);
            }
            // Non-nullable fields without an initializer need `late` in
            // null-safe Dart (they're set in the constructor body).
            fb.late =
                isLate ||
                (initializer == null &&
                    hasExplicitType &&
                    fieldType != null &&
                    !fieldType.endsWith('?') &&
                    modifier != 'const');
            if (initializer != null) fb.assignment = cb.Code(initializer);
            switch (modifier) {
              case 'final':
                fb.modifier = cb.FieldModifier.final$;
              case 'const':
                fb.modifier = cb.FieldModifier.constant;
              // '' → mutable, no modifier
            }
          }),
        );
      }
    }
  }

  cb.Field _buildStaticField(FunctionDefinition func) {
    final meta = _readMeta(func);
    final fieldName = _memberName(func.name);

    return cb.Field((fb) {
      fb.name = fieldName;
      fb.static = true;
      if (func.outputType.isNotEmpty)
        fb.type = cb.refer(_dartType(func.outputType));
      if (meta['is_const'] == true) {
        fb.modifier = cb.FieldModifier.constant;
      } else if (meta['is_final'] == true) {
        fb.modifier = cb.FieldModifier.final$;
      }
      if (meta['is_late'] == true) fb.late = true;
      if (func.hasBody()) fb.assignment = _compileExpression(func.body).code;
    });
  }

  // ════════════════════════════════════════════════════════════
  // Extensions
  // ════════════════════════════════════════════════════════════

  cb.Extension _buildExtension(
    TypeDefinition td,
    List<FunctionDefinition> methods,
  ) {
    final meta = _metaFromTd(td);
    final on = meta['on'] as String?;
    final typeParamsStr = _typeParamsStr(meta);
    final doc = meta['doc'] as String?;
    // Unnamed extensions are encoded with names like `_unnamed_extension`,
    // `_unnamed_extension_0`, `_unnamed_extension_1`, etc. so multiple
    // unnamed extensions in one file don't collide. Emit them all as
    // anonymous `extension on T { ... }`.
    final isUnnamed = td.name.startsWith('_unnamed_extension');
    final displayName = isUnnamed ? '' : _dartType(td.name);

    return cb.Extension((b) {
      b.name = '$displayName$typeParamsStr';
      if (doc != null) b.docs.add(doc);
      final extAnnots = (meta['annotations'] as List?)?.cast<String>();
      if (extAnnots != null) {
        for (final ann in extAnnots) {
          b.annotations.add(cb.refer(ann));
        }
      }
      b.on = cb.refer(on ?? 'dynamic');
      final memberNames = _collectClassMemberNames(null, methods);
      _withClassContext(memberNames, () {
        for (final method in methods) {
          b.methods.add(_buildMethod(td.name, method, _readMeta(method)));
        }
      });
    });
  }

  // ════════════════════════════════════════════════════════════
  // Extension types
  // ════════════════════════════════════════════════════════════

  cb.ExtensionType _buildExtensionType(
    TypeDefinition td,
    List<FunctionDefinition> methods,
  ) {
    final meta = _metaFromTd(td);
    final repType = meta['rep_type'] as String? ?? 'dynamic';
    final repField = meta['rep_field'] as String? ?? '_it';
    final repConstructorName = meta['rep_constructor_name'] as String?;
    final repAnnotations =
        (meta['rep_annotations'] as List?)?.cast<String>() ?? const [];
    final isConst = meta['is_const'] == true;
    final interfaces = (meta['interfaces'] as List?)?.cast<String>();
    final doc = meta['doc'] as String?;
    final displayName = _dartType(td.name);

    return cb.ExtensionType((b) {
      b.name = displayName;
      _addTypeParams(b.types.add, meta);
      if (doc != null) b.docs.add(doc);
      b.constant = isConst;
      final etAnnots = (meta['annotations'] as List?)?.cast<String>();
      if (etAnnots != null) {
        for (final ann in etAnnots) {
          b.annotations.add(cb.refer(ann));
        }
      }
      b.primaryConstructorName = repConstructorName ?? '';
      b.representationDeclaration = cb.RepresentationDeclaration((rb) {
        rb.name = repField;
        rb.declaredRepresentationType = cb.refer(repType);
        for (final ann in repAnnotations) {
          rb.annotations.add(cb.refer(ann));
        }
      });
      if (interfaces != null) {
        for (final i in interfaces) {
          b.implements.add(cb.refer(i));
        }
      }

      // Add descriptors' non-representation instance fields.
      if (td.hasDescriptor()) {
        _addInstanceFields(
          (f) => b.fields.add(f),
          (m) => b.methods.add(m),
          td.descriptor,
          meta,
        );
      }

      final memberNames = _collectClassMemberNames(
        td.hasDescriptor() ? td.descriptor : null,
        methods,
      );
      _withClassContext(memberNames, () {
        for (final method in methods) {
          final mMeta = _readMeta(method);
          final mKind = mMeta['kind'] as String? ?? 'method';
          if (mKind == 'static_field') {
            b.fields.add(_buildStaticField(method));
          } else if (mKind == 'constructor') {
            b.constructors.add(
              _buildConstructor(
                td.name,
                method,
                mMeta,
                classFields: meta['fields'] as List?,
              ),
            );
          } else {
            b.methods.add(_buildMethod(td.name, method, mMeta));
          }
        }
      });
    });
  }

  // ════════════════════════════════════════════════════════════
  // Functions & methods
  // ════════════════════════════════════════════════════════════

  cb.Method _buildFunction(FunctionDefinition func) =>
      _buildMethodFromMeta(func.name, func, _readMeta(func));

  cb.Method _buildMethod(
    String className,
    FunctionDefinition func,
    Map<String, Object?> meta,
  ) {
    return _buildMethodFromMeta(_memberName(func.name), func, meta);
  }

  cb.Method _buildMethodFromMeta(
    String name,
    FunctionDefinition func,
    Map<String, Object?> meta,
  ) {
    final isAbstract = meta['is_abstract'] == true;
    final isStatic = meta['is_static'] == true;
    final isGetter = meta['is_getter'] == true;
    final isSetter = meta['is_setter'] == true;
    final isOperator = meta['is_operator'] == true;
    final isAsync = meta['is_async'] == true;
    final isSyncStar = meta['is_sync_star'] == true;
    final isAsyncStar = meta['is_async_star'] == true;
    final isExternal = meta['is_external'] == true;
    final isExpressionBody = meta['expression_body'] == true;
    final isOverride = meta['is_override'] == true;
    final typeParamsStr = _typeParamsStr(meta);
    final doc = meta['doc'] as String?;

    const overrideNames = {'toString', 'hashCode', 'noSuchMethod', '=='};
    final annotations = (meta['annotations'] as List?)?.cast<String>();

    return cb.Method((b) {
      // Operators are emitted by prefixing the name with 'operator '.
      // code_builder MethodType only has getter/setter; there is no operator$ value.
      // The encoder stores canonical Ball names like `__op_set_index__`
      // in `func.name` and the original Dart lexeme (`[]=`, `==`, …) in
      // `meta['operator']` so we can recover the source-form here.
      final operatorLexeme = meta['operator'] as String?;
      b.name = isOperator
          ? 'operator ${operatorLexeme ?? name}$typeParamsStr'
          : '$name$typeParamsStr';
      if (doc != null) b.docs.add(doc);
      if (annotations != null) {
        for (final ann in annotations) {
          b.annotations.add(cb.refer(ann));
        }
      } else if (isOverride || overrideNames.contains(name)) {
        b.annotations.add(cb.refer('override'));
      }
      b.static = isStatic;
      b.external = isExternal;
      // code_builder MethodBuilder has no 'abstract' property; abstract methods
      // are indicated by the absence of a body (emits 'name();').

      if (isGetter) b.type = cb.MethodType.getter;
      if (isSetter) b.type = cb.MethodType.setter;

      if (func.outputType.isNotEmpty) {
        var dartRetType = _dartType(func.outputType);
        // Note: do NOT make async return types nullable (int→int?) here —
        // it causes cascading type errors in callers (int? can't be assigned
        // to int). Instead, individual functions that don't return in all
        // paths get a safety return in _generateLocalFunction.
        b.returns = cb.refer(
          _wrapReturnType(
            dartRetType,
            isAsync: isAsync,
            isAsyncStar: isAsyncStar,
            isSyncStar: isSyncStar,
          ),
        );
      }

      if (isAsync && !isAsyncStar) b.modifier = cb.MethodModifier.async;
      if (isAsyncStar) b.modifier = cb.MethodModifier.asyncStar;
      if (isSyncStar) b.modifier = cb.MethodModifier.syncStar;

      _addParameters(b, meta);

      if (!isAbstract && !isExternal && func.hasBody()) {
        // If `_addParameters` stashed renames (e.g. original param `n`
        // became `input`), we can't use `=> expr` form since the
        // expression references `n` which no longer exists. Demote to
        // block form so `_generateFunctionBody` emits the alias prologue.
        final mustUseBlockForm = _pendingParamAliases.isNotEmpty;
        final savedInGen = _inGenerator;
        final savedInsideInstance = _insideInstanceMethod;
        _inGenerator = isSyncStar || isAsyncStar;
        _insideInstanceMethod = !isStatic;
        // A parameter literally named `self` shadows the implicit receiver for
        // the whole body, so `self` references must stay `self`, not `this`.
        final selfParamShadow = _paramsDeclareSelf(meta);
        if (selfParamShadow) _selfShadowDepth++;
        if (isExpressionBody && !mustUseBlockForm) {
          b.lambda = true;
          b.body = _compileExpression(func.body).code;
        } else {
          b.body = cb.Code(
            _captureBody(() {
              _generateFunctionBody(func.body, _hasNonVoidReturn(func));
              // Async/generator functions: safety return for null-safety
              // Async (not generator) non-void: safety return
              if (isAsync &&
                  !isAsyncStar &&
                  func.outputType.isNotEmpty &&
                  _dartType(func.outputType) != 'void') {
                _wl('return null as dynamic;');
              }
            }),
          );
        }
        if (selfParamShadow) _selfShadowDepth--;
        _inGenerator = savedInGen;
        _insideInstanceMethod = savedInsideInstance;
      } else {
        // Abstract/external/body-less methods must still clear stashed
        // aliases so they don't leak into the NEXT method's body and
        // produce spurious `<Type> <name> = input;` prologues there.
        _pendingParamAliases = const [];
      }
    });
  }

  cb.Constructor _buildConstructor(
    String className,
    FunctionDefinition func,
    Map<String, Object?> meta, {
    List<dynamic>? classFields,
  }) {
    final isExpressionBody = meta['expression_body'] == true;
    final redirectsTo = meta['redirects_to'] as String?;
    final initializers = meta['initializers'] as List?;
    final doc = meta['doc'] as String?;

    // Extract the constructor name from '.module:ClassName.ctorName'.
    // For the default constructor the stored name ends with '.new'.
    final rawMemberName = _memberName(func.name);
    final ctorName = rawMemberName.isEmpty ? '' : rawMemberName;
    final isDefault = ctorName.isEmpty || ctorName == 'new';

    return cb.Constructor((b) {
      if (doc != null) b.docs.add(doc);
      if (!isDefault) b.name = ctorName;
      b.constant = meta['is_const'] == true;
      b.factory = meta['is_factory'] == true;
      b.external = meta['is_external'] == true;
      final ctorAnnots = (meta['annotations'] as List?)?.cast<String>();
      if (ctorAnnots != null) {
        for (final ann in ctorAnnots) {
          b.annotations.add(cb.refer(ann));
        }
      }

      _addParameters(b, meta);

      // When the constructor uses Ball's single-input convention (one param
      // named "input") and the class has fields, replace with `this.fieldName`
      // initializing formals. This handles the common encoding pattern where
      // `MyClass(this.name)` becomes `params: [{name: 'input', type: 'String'}]`.
      final params = meta['params'];
      final isSingleInput =
          params is List &&
          params.length == 1 &&
          params[0] is Map &&
          (params[0] as Map)['name'] == 'input';
      if (isSingleInput &&
          classFields != null &&
          classFields.isNotEmpty &&
          meta['is_factory'] != true) {
        b.requiredParameters.clear();
        b.optionalParameters.clear();
        for (final f in classFields) {
          if (f is Map) {
            final fieldName = f['name'] as String? ?? '';
            b.requiredParameters.add(
              cb.Parameter((p) {
                p.name = fieldName;
                p.toThis = true;
              }),
            );
          }
        }
      }

      if (redirectsTo != null) {
        b.redirect = cb.refer(redirectsTo);
      } else if (initializers != null && initializers.isNotEmpty) {
        b.initializers.addAll(
          _buildInitializerList(initializers).map(cb.Code.new),
        );
      }

      final isFactory = meta['is_factory'] == true;
      if (!b.external &&
          func.hasBody() &&
          !_isEmptyBody(func.body) &&
          // Non-factory constructors: strip the Ball "create self + return"
          // boilerplate and simple reference bodies that are artifacts of the
          // Ball IR encoding and have no meaning in Dart.
          (isFactory || !_isConstructorBoilerplateBody(func.body))) {
        // If `_addParameters` stashed renames (e.g. original param `n`
        // became `input`), we can't use `=> expr` form since the
        // expression references `n` which no longer exists. Demote to
        // block form so `_generateFunctionBody` emits the alias prologue.
        final mustUseBlockForm = _pendingParamAliases.isNotEmpty;
        // A constructor body runs in instance context, so a `self` reference
        // (the encoder's spelling of the `this` keyword) resolves to `this`.
        // Factory constructors are an exception: they have no instance, so
        // `self` there is the locally-created instance variable, not `this`.
        final savedInsideInstance = _insideInstanceMethod;
        _insideInstanceMethod = !isFactory;
        final selfParamShadow = _paramsDeclareSelf(meta);
        if (selfParamShadow) _selfShadowDepth++;
        if (isExpressionBody && !mustUseBlockForm) {
          b.lambda = true;
          b.body = _compileExpression(func.body).code;
        } else {
          b.body = cb.Code(
            _captureBody(() => _generateFunctionBody(func.body, isFactory)),
          );
        }
        if (selfParamShadow) _selfShadowDepth--;
        _insideInstanceMethod = savedInsideInstance;
      } else {
        // External/body-less/empty-body constructors must still clear
        // stashed aliases so they don't leak into the next member.
        _pendingParamAliases = const [];
      }
    });
  }

  List<String> _buildInitializerList(List<dynamic> initializers) {
    final parts = <String>[];
    for (final init in initializers) {
      if (init is! Map) continue;
      switch (init['kind'] as String? ?? '') {
        case 'field':
          parts.add('${init['name']} = ${init['value']}');
        case 'super':
          final n = init['name'] as String?;
          final args = init['args'] ?? '()';
          parts.add(n != null ? 'super.$n$args' : 'super$args');
        case 'redirect':
          final n = init['name'] as String?;
          final args = init['args'] ?? '()';
          parts.add(n != null ? 'this.$n$args' : 'this$args');
        case 'assert':
          final cond = init['condition'] ?? 'true';
          final msg = init['message'] as String?;
          parts.add(msg != null ? 'assert($cond, $msg)' : 'assert($cond)');
      }
    }
    return parts;
  }

  /// True when the function's encoded parameter list contains a parameter
  /// literally named `self`. Such a parameter shadows the implicit instance
  /// receiver, so `self` references in the body must resolve to it (stay
  /// `self`) rather than being rewritten to `this`.
  bool _paramsDeclareSelf(Map<String, Object?> meta) {
    final params = meta['params'];
    if (params is! List) return false;
    for (final p in params) {
      if (p is Map && p['name'] == 'self') return true;
    }
    return false;
  }

  void _addParameters(dynamic builder, Map<String, Object?> meta) {
    final params = meta['params'];
    if (params == null || params is! List) return;

    // Reset aliases. Populated below for positional Ball params so that
    // [_generateFunctionBody] can prepend `final <orig> = input;` lines
    // and the function body's references to `input` resolve.
    final aliases = <({String name, String? type})>[];

    // Bug fix: constructors with initializer lists or redirecting constructors
    // store raw source references to original parameter names. Renaming the
    // param to `input` would leave those references dangling (e.g.
    // `MyClass(Foo input) : _foo = foo` where `foo` is undefined).
    // Skip the rename entirely when initializers or redirects are present.
    final hasInitializers = (meta['initializers'] as List?)?.isNotEmpty == true;
    final hasRedirect = meta['redirects_to'] != null;

    // Count positional (non-named, non-optional) params. If there's
    // exactly one, rename it to `input` so the Ball body's `input`
    // reference works; stash the original name so we can alias it
    // inside the body.
    int positionalCount = 0;
    for (final p in params) {
      if (p is! Map) continue;
      final isNamed =
          p['is_named'] == true ||
          p['is_required_named'] == true ||
          p['is_optional_named'] == true;
      final isOptional = p['is_optional'] == true;
      if (!isNamed && !isOptional) positionalCount++;
    }
    // Don't rename to `input` if the enclosing class has a member named
    // `input` — the rename would shadow the member, changing the meaning
    // of any `input` reference in the body from "field" to "parameter".
    final classHasInputMember = _currentClassMemberNames.contains('input');
    final topLevelHasInput = _topLevelNames.contains('input');
    final renameSinglePositional =
        positionalCount == 1 &&
        !hasInitializers &&
        !hasRedirect &&
        !classHasInputMember &&
        !topLevelHasInput;

    for (final p in params) {
      if (p is! Map) continue;
      final rawName = p['name'] as String? ?? '_';
      final paramType = p['type'] as String?;
      final isNamed =
          p['is_named'] == true ||
          p['is_required_named'] == true ||
          p['is_optional_named'] == true;
      final isOptional = p['is_optional'] == true;
      final isRequiredNamed = p['is_required_named'] == true;
      final defaultValue = p['default'] as String?;

      // Bug fix: never rename initializing formals (this.x) or super formals
      // (super.x) to `input` — doing so emits `this.input` which references
      // a non-existent field, causing initializing_formal_for_non_existent_field.
      final isThis = p['is_this'] == true;
      final isSuper = p['is_super'] == true;
      String paramName = rawName;
      if (!isNamed &&
          !isOptional &&
          !isThis &&
          !isSuper &&
          renameSinglePositional &&
          rawName != 'input') {
        paramName = 'input';
        aliases.add((name: rawName, type: paramType));
      }

      final param = cb.Parameter((pb) {
        pb.name = paramName;
        final isThis = p['is_this'] == true;
        if (paramType != null && !isThis) pb.type = cb.refer(paramType);
        if (isThis) pb.toThis = true;
        if (p['is_super'] == true) pb.toSuper = true;
        if (isNamed) pb.named = true;
        if (isRequiredNamed) pb.required = true;
        if (p['is_covariant'] == true) pb.covariant = true;
        if (defaultValue != null) pb.defaultTo = cb.Code(defaultValue);
      });

      if (isNamed || isOptional) {
        (builder as dynamic).optionalParameters.add(param);
      } else {
        (builder as dynamic).requiredParameters.add(param);
      }
    }
    _pendingParamAliases = aliases;
  }

  // ════════════════════════════════════════════════════════════
  // Top-level variables & main()
  // ════════════════════════════════════════════════════════════

  String _buildTopLevelVarStr(FunctionDefinition func) {
    final meta = _readMeta(func);
    final doc = meta['doc'] as String?;
    final isConst = meta['is_const'] == true;
    final isFinal = meta['is_final'] == true;
    final isLate = meta['is_late'] == true;

    final buf = StringBuffer();
    if (doc != null) buf.writeln(doc);
    if (isLate) buf.write('late ');
    if (isConst) {
      buf.write('const ');
    } else if (isFinal) {
      buf.write('final ');
    }
    if (func.outputType.isNotEmpty) {
      buf.write('${_dartType(func.outputType)} ');
    } else if (!isConst && !isFinal) {
      buf.write('var ');
    }
    buf.write(func.name);
    if (func.hasBody()) buf.write(' = ${_e(func.body)}');
    buf.write(';');
    return buf.toString();
  }

  cb.Method _buildMainFunction(FunctionDefinition func) {
    final meta = _readMeta(func);
    final isAsync = meta['is_async'] == true;

    // Compile the body first so _needsAsync can be set by auto-await.
    _needsAsync = false;
    final bodyCode = func.hasBody()
        ? cb.Code(_captureBody(() => _generateFunctionBody(func.body, false)))
        : const cb.Code('');
    final shouldBeAsync = isAsync || _needsAsync;

    return cb.Method((b) {
      b.name = 'main';
      b.returns = cb.refer('void');
      if (shouldBeAsync) b.modifier = cb.MethodModifier.async;
      b.body = bodyCode;
    });
  }

  // ════════════════════════════════════════════════════════════
  // TypeDefinition metadata helpers
  // ════════════════════════════════════════════════════════════

  Map<String, Object?> _metaFromTd(TypeDefinition td) {
    final meta = td.hasMetadata()
        ? _structToMap(td.metadata)
        : <String, Object?>{};
    if (td.typeParams.isNotEmpty && meta['type_params'] == null) {
      meta['type_params'] = td.typeParams.map((tp) => tp.name).toList();
    }
    return meta;
  }

  String _kindOf(TypeDefinition td) {
    if (!td.hasMetadata()) return 'class';
    return _structToMap(td.metadata)['kind'] as String? ?? 'class';
  }

  // ════════════════════════════════════════════════════════════
  // Body capture
  // ════════════════════════════════════════════════════════════

  /// Runs [fn] against [_out], returns the produced string, then restores.
  String _captureBody(void Function() fn) {
    final savedContent = _out.toString();
    final savedDepth = _depth;
    _out.clear();
    _depth = 0;
    fn();
    final result = _out.toString();
    _out.clear();
    _out.write(savedContent);
    _depth = savedDepth;
    return result;
  }

  // ════════════════════════════════════════════════════════════
  // Body / statement generation
  // ════════════════════════════════════════════════════════════

  void _generateFunctionBody(Expression body, bool hasReturn) {
    // Emit `<type> <orig> = input;` aliases for any renamed positional
    // parameters so the body's original-name references resolve. Consumed
    // on entry so nested lambdas don't inherit the parent's aliases.
    // Bug fix: use the typed form (no keyword) instead of `final` so that
    // the alias variable can be reassigned if the body mutates it. Using
    // `final` caused assignment_to_final_local errors in round-trip output.
    final aliases = _pendingParamAliases;
    _pendingParamAliases = const [];
    for (final a in aliases) {
      if (a.type != null) {
        _wl('${a.type} ${a.name} = input;');
      } else {
        _wl('var ${a.name} = input;');
      }
    }

    if (body.whichExpr() == Expression_Expr.block) {
      _generateBlockStatements(body.block, hasReturn);
      return;
    }
    // Assignment expressions need `return` when they are the body of a
    // non-void function (e.g. `return _x ??= SomeType()`).
    if (_isStdControl(body) && !(hasReturn && body.call.function == 'assign')) {
      _generateStdStatement(body.call, hasReturn);
      return;
    }
    _wl(hasReturn ? 'return ${_e(body)};' : '${_e(body)};');
  }

  /// Check if a statement is a std.label call.
  bool _isLabelStmt(Statement stmt) {
    if (!stmt.hasExpression()) return false;
    final e = stmt.expression;
    return e.whichExpr() == Expression_Expr.call &&
        (e.call.module == 'std' || e.call.module.isEmpty) &&
        e.call.function == 'label';
  }

  /// Check if a statement is a std.goto call.
  bool _isGotoStmt(Statement stmt) {
    if (!stmt.hasExpression()) return false;
    final e = stmt.expression;
    return e.whichExpr() == Expression_Expr.call &&
        (e.call.module == 'std' || e.call.module.isEmpty) &&
        e.call.function == 'goto';
  }

  /// Check if an expression is a std.label or std.goto call.
  bool _isLabelOrGoto(Expression e) {
    if (e.whichExpr() != Expression_Expr.call) return false;
    final fn = e.call.function;
    return (e.call.module == 'std' || e.call.module.isEmpty) &&
        (fn == 'label' || fn == 'goto');
  }

  void _generateBlockStatements(Block block, bool hasReturn) {
    // Check if any statements use goto/label — if so, emit a switch-based
    // goto workaround (Dart has no native goto).
    final hasLabels = block.statements.any(_isLabelStmt);
    final resultIsLabel = block.hasResult() && _isLabelOrGoto(block.result);

    if (hasLabels || resultIsLabel) {
      _generateGotoSwitchBlock(block, hasReturn);
      return;
    }

    // Normal block generation (no goto/label).
    // A `let self = …` binding shadows the implicit receiver from that point
    // on, so increment the shadow depth for subsequent statements (and the
    // result) and restore it after the block. Mirrors the engine's lexical
    // scope chain, where the local `self` shadows the bound receiver.
    var selfBindings = 0;
    for (final stmt in block.statements) {
      if (stmt.whichStmt() == Statement_Stmt.let && stmt.let.name == 'self') {
        // The binding's value is compiled with the *outer* `self` still in
        // scope, so emit the let first, then begin shadowing.
        _generateStatement(stmt);
        _selfShadowDepth++;
        selfBindings++;
        continue;
      }
      _generateStatement(stmt);
    }
    if (block.hasResult()) {
      if (_isStdControl(block.result) &&
          !(hasReturn && block.result.call.function == 'assign')) {
        _generateStdStatement(block.result.call, hasReturn);
      } else {
        _wl(hasReturn ? 'return ${_e(block.result)};' : '${_e(block.result)};');
      }
    }
    _selfShadowDepth -= selfBindings;
  }

  /// Emits a goto-simulating switch block:
  /// ```dart
  /// switch (0) {
  ///   case 0:
  ///     // pre-label statements
  ///     continue labelA;
  ///   labelA:
  ///   case 1:
  ///     // label body
  ///     continue labelB;   // or break; if last
  ///   labelB:
  ///   case 2:
  ///     // label body
  ///     break;
  /// }
  /// ```
  void _generateGotoSwitchBlock(Block block, bool hasReturn) {
    // Collect all labels in order.
    final labels = <String>[];
    for (final stmt in block.statements) {
      if (_isLabelStmt(stmt)) {
        final fields = _extractFields(stmt.expression.call);
        labels.add(_stringFieldValue(fields, 'name') ?? '');
      }
    }
    if (block.hasResult() &&
        block.result.whichExpr() == Expression_Expr.call &&
        block.result.call.function == 'label') {
      final fields = _extractFields(block.result.call);
      labels.add(_stringFieldValue(fields, 'name') ?? '');
    }

    _wl('switch (0) {');
    _depth++;

    var caseIdx = 0;

    // Emit pre-label statements in case 0.
    // Find where first label is.
    var firstLabelIdx = block.statements.indexWhere(_isLabelStmt);
    if (firstLabelIdx < 0 && !labels.isNotEmpty)
      firstLabelIdx = block.statements.length;

    // Emit case 0 for pre-label statements.
    if (firstLabelIdx > 0 ||
        (firstLabelIdx == -1 && block.statements.isNotEmpty)) {
      _wl('case $caseIdx:');
      _depth++;
      final preEnd = firstLabelIdx >= 0
          ? firstLabelIdx
          : block.statements.length;
      for (var i = 0; i < preEnd; i++) {
        _generateStatement(block.statements[i]);
      }
      // Fall through to next label or break.
      if (labels.isNotEmpty) {
        _wl('continue ${labels.first};');
      } else {
        _wl('break;');
      }
      _depth--;
      caseIdx++;
    }

    // Emit each label as a case.
    var labelOrdinal = 0;
    for (
      var i = (firstLabelIdx >= 0 ? firstLabelIdx : block.statements.length);
      i < block.statements.length;
      i++
    ) {
      final stmt = block.statements[i];
      if (_isLabelStmt(stmt)) {
        final fields = _extractFields(stmt.expression.call);
        final name = _stringFieldValue(fields, 'name') ?? '';
        final body = fields['body'];

        _wl('$name:');
        _wl('case $caseIdx:');
        _depth++;
        if (body != null) {
          _wl('${_e(body)};');
        }
        // Fall through to next label or break.
        final nextLabel = labelOrdinal + 1 < labels.length
            ? labels[labelOrdinal + 1]
            : null;
        if (nextLabel != null) {
          _wl('continue $nextLabel;');
        } else {
          _wl('break;');
        }
        _depth--;
        caseIdx++;
        labelOrdinal++;
      } else if (_isGotoStmt(stmt)) {
        // goto inside switch — just emit continue.
        final fields = _extractFields(stmt.expression.call);
        final target = _stringFieldValue(fields, 'label') ?? '';
        _wl('continue $target;');
      } else {
        _generateStatement(stmt);
      }
    }

    // Handle result expression if it's a label.
    if (block.hasResult()) {
      final res = block.result;
      if (res.whichExpr() == Expression_Expr.call &&
          res.call.function == 'label') {
        final fields = _extractFields(res.call);
        final name = _stringFieldValue(fields, 'name') ?? '';
        final body = fields['body'];
        _wl('$name:');
        _wl('case $caseIdx:');
        _depth++;
        if (body != null) {
          _wl(hasReturn ? 'return ${_e(body)};' : '${_e(body)};');
        }
        _wl('break;');
        _depth--;
      } else if (res.whichExpr() == Expression_Expr.call &&
          res.call.function == 'goto') {
        final fields = _extractFields(res.call);
        final target = _stringFieldValue(fields, 'label') ?? '';
        _wl('continue $target;');
      } else {
        if (_isStdControl(res) &&
            !(hasReturn && res.call.function == 'assign')) {
          _generateStdStatement(res.call, hasReturn);
        } else {
          _wl(hasReturn ? 'return ${_e(res)};' : '${_e(res)};');
        }
      }
    }

    _depth--;
    _wl('}');
  }

  void _generateStatement(Statement stmt) {
    switch (stmt.whichStmt()) {
      case Statement_Stmt.let:
        final letExpr = stmt.let.value;
        if (letExpr.whichExpr() == Expression_Expr.lambda) {
          _generateLocalFunction(stmt.let.name, letExpr.lambda);
        } else if (_isNoInit(letExpr)) {
          // Uninitialized variable: `Type? x;`
          _wl('${_letDeclKeyword(stmt.let)} ${stmt.let.name};');
        } else {
          _wl(
            '${_letDeclKeyword(stmt.let, letExpr)} ${stmt.let.name} = '
            '${_e(letExpr)};',
          );
        }
      case Statement_Stmt.expression:
        final expr = stmt.expression;
        if (_isStdControl(expr)) {
          _generateStdStatement(expr.call, false);
        } else if (expr.whichExpr() == Expression_Expr.block &&
            !expr.block.hasResult()) {
          // A block-as-statement with no result. Two sub-cases:
          // 1. Pattern-var destructuring (encoded with __ball_rec_ temp vars):
          //    must be inlined so its `let` bindings are visible to subsequent
          //    statements in the enclosing block.
          // 2. Scope blocks (e.g. `{ var x = 20; print(x); }`): must be
          //    wrapped in `{ }` to create a new Dart scope, otherwise
          //    re-declarations of outer variables cause compile errors.
          final isDestructure = expr.block.statements.any(
            (s) =>
                s.whichStmt() == Statement_Stmt.let &&
                s.let.name.startsWith('__ball_rec_'),
          );
          if (isDestructure) {
            for (final s in expr.block.statements) {
              _generateStatement(s);
            }
          } else {
            _wl('{');
            _depth++;
            for (final s in expr.block.statements) {
              _generateStatement(s);
            }
            _depth--;
            _wl('}');
          }
        } else {
          _wl('${_e(expr)};');
        }
      case Statement_Stmt.notSet:
        break;
    }
  }

  void _generateLocalFunction(String name, FunctionDefinition func) {
    final meta = _readMeta(func);
    final isAsync = meta['is_async'] == true;
    final isAsyncStar = meta['is_async_star'] == true;
    final isSyncStar = meta['is_sync_star'] == true;
    final isExprBody = meta['expression_body'] == true;

    // If the function has no explicit return type, omit the return type
    // annotation so Dart can infer it (e.g. `async` lambdas return `Future`).
    final rawReturnType = func.outputType.isEmpty
        ? null
        : _dartType(func.outputType);
    // For async functions with non-void/non-dynamic return types, make the
    // inner type nullable (int → int?) so Dart null-safety allows implicit
    // null returns in paths that always throw/rethrow.
    final returnType = rawReturnType != null
        ? _wrapReturnType(
            rawReturnType,
            isAsync: isAsync,
            isAsyncStar: isAsyncStar,
            isSyncStar: isSyncStar,
          )
        : null;

    final typePart = returnType != null ? '$returnType ' : '';
    final sig = StringBuffer('$typePart$name(${_buildParamList(meta)})');
    if (isAsync && !isAsyncStar) sig.write(' async');
    if (isAsyncStar) sig.write(' async*');
    if (isSyncStar) sig.write(' sync*');

    final savedInGen = _inGenerator;
    _inGenerator = isSyncStar || isAsyncStar;
    if (isExprBody && func.hasBody()) {
      _wl('$sig => ${_e(func.body)};');
    } else {
      _wl('$sig {');
      _depth++;
      if (func.hasBody()) {
        // Honour the encoder's `has_return` flag: a lambda assigned to a
        // local (`final f = (x) { ... };`) carries no `outputType`, so
        // `_hasNonVoidReturn` alone would drop the implicit return value of
        // its final expression. Mirror `_compileLambda` here.
        final hasReturn = meta['has_return'] == true || _hasNonVoidReturn(func);
        _generateFunctionBody(func.body, hasReturn);
      }
      // Async/generator functions with non-void return types need a safety
      // return to satisfy Dart null-safety when not all paths return.
      // Async (not generator) non-void: safety return
      if (isAsync &&
          !isAsyncStar &&
          rawReturnType != null &&
          rawReturnType != 'void') {
        _wl('return null as dynamic;');
      }
      _depth--;
      _wl('}');
    }
    _inGenerator = savedInGen;
  }

  // ── std control-flow ────────────────────────────────────────

  static bool _isBaseModule(String module) =>
      module == 'std' ||
      module == 'std_memory' ||
      module == 'std_collections' ||
      module == 'std_io' ||
      module == 'std_convert' ||
      module == 'std_fs' ||
      module == 'std_time' ||
      module == 'ball_proto';

  bool _isStdCall(Expression expr, String function) =>
      expr.whichExpr() == Expression_Expr.call &&
      _isBaseModule(expr.call.module) &&
      expr.call.function == function;

  bool _isStdControl(Expression expr) {
    if (expr.whichExpr() != Expression_Expr.call) return false;
    if (!_isBaseModule(expr.call.module)) return false;
    return const {
      'if',
      'for',
      'for_in',
      'while',
      'do_while',
      'switch',
      'try',
      'return',
      'break',
      'continue',
      'assert',
      'yield',
      'yield_each',
      'assign',
      'labeled',
      'throw',
      'rethrow',
      'goto',
      'label',
    }.contains(expr.call.function);
  }

  void _generateStdStatement(FunctionCall call, bool hasReturn) {
    final fields = _extractFields(call);
    switch (call.function) {
      case 'if':
        _generateIf(fields, hasReturn);
      case 'for':
        _generateFor(fields);
      case 'for_in':
        _generateForIn(fields);
      case 'while':
        _generateWhile(fields);
      case 'do_while':
        _generateDoWhile(fields);
      case 'switch':
        _generateSwitch(fields);
      case 'try':
        _generateTry(fields);
      case 'return':
        final v = fields['value'];
        // Generators (sync*/async*) cannot return a value in Dart.
        _wl(v != null && !_inGenerator ? 'return ${_e(v)};' : 'return;');
      case 'break':
        final label = _stringFieldValue(fields, 'label');
        _wl(label != null && label.isNotEmpty ? 'break $label;' : 'break;');
      case 'continue':
        final label = _stringFieldValue(fields, 'label');
        _wl(
          label != null && label.isNotEmpty ? 'continue $label;' : 'continue;',
        );
      case 'assert':
        _generateAssert(fields);
      case 'yield':
        final v = fields['value'];
        _wl('yield ${v != null ? _e(v) : "null"};');
      case 'yield_each':
        final v = fields['value'];
        _wl('yield* ${v != null ? _e(v) : "null"};');
      case 'assign':
        _generateAssign(fields);
      case 'labeled':
        _generateLabeled(fields);
      case 'throw':
        final v = fields['value'];
        if (v == null) {
          _wl('throw null;');
        } else {
          final special = _compileThrowValue(v);
          _wl('throw ${special ?? _e(v)};');
        }
      case 'rethrow':
        _wl('rethrow;');
      case 'goto':
        // A `goto` reached in statement context (e.g. among the pre-label
        // statements of `case 0:` inside the goto-simulating switch) lowers
        // to a labelled `continue` targeting the matching switch label —
        // exactly as the block-expression form does. Without this case it
        // leaked a `/* unsupported statement: std.goto */` marker.
        final gotoLabel = _stringFieldValue(fields, 'label') ?? '';
        _wl('continue $gotoLabel;');
      case 'label':
        // A standalone `label` statement (not folded into a sibling-label
        // block by _generateGotoSwitchBlock) emits its own switch case so
        // gotos can target it. Mirrors _compileStdStatementToString.
        _wl('${_compileStdStatementToString(call, hasReturn)}');
      // Unreachable: _generateStdStatement is only called for functions that
      // pass _isStdControl, every one of which is cased above.
      // coverage:ignore-start
      default:
        _wl('/* unsupported statement: std.${call.function} */');
      // coverage:ignore-end
    }
  }

  /// Compile a std control-flow call to a string (for use in block expressions).
  /// Handles simple statements like return, break, continue, throw, assign.
  String _compileStdStatementToString(FunctionCall call, bool hasReturn) {
    final fields = _extractFields(call);
    switch (call.function) {
      case 'return':
        final v = fields['value'];
        return v != null ? 'return ${_e(v)};\n' : 'return;\n';
      case 'break':
        final label = _stringFieldValue(fields, 'label');
        return (label != null && label.isNotEmpty
            ? 'break $label;\n'
            : 'break;\n');
      case 'continue':
        final label = _stringFieldValue(fields, 'label');
        return (label != null && label.isNotEmpty
            ? 'continue $label;\n'
            : 'continue;\n');
      case 'throw':
        final v = fields['value'];
        if (v == null) return 'throw null;\n';
        final special = _compileThrowValue(v);
        return 'throw ${special ?? _e(v)};\n';
      case 'rethrow':
        return 'rethrow;\n';
      case 'assign':
        return '${_compileAssign(fields)};\n';
      case 'goto':
        // `continue labelName` jumps to the matching label inside the
        // enclosing switch emitted by _generateGotoSwitchBlock.
        final gotoLabel = _stringFieldValue(fields, 'label') ?? '';
        return 'continue $gotoLabel;\n';
      case 'label':
        // Standalone label (not grouped in a block with other labels).
        // Emit as a switch case so goto (continue) can target it.
        final labelName = _stringFieldValue(fields, 'name') ?? '';
        final labelBody = fields['body'];
        final buf = StringBuffer();
        buf.writeln('switch (0) {');
        buf.writeln('  $labelName:');
        buf.writeln('  case 0:');
        if (labelBody != null) {
          buf.writeln('    ${_e(labelBody)};');
        }
        buf.writeln('    break;');
        buf.writeln('}');
        return buf.toString();
      default:
        return '/* unsupported block-expr statement: std.${call.function} */\n';
    }
  }

  void _generateIf(Map<String, Expression> fields, bool hasReturn) {
    final cond = fields['condition'];
    final then = fields['then'];
    final els = fields['else'];
    final casePattern = _stringFieldValue(fields, 'case_pattern');
    if (cond == null || then == null) {
      _wl('// ERROR: std.if missing condition or then');
      return;
    }
    if (casePattern != null && casePattern.isNotEmpty) {
      _wl('if (${_e(cond)} case $casePattern) {');
    } else {
      _wl('if (${_e(cond)}) {');
    }
    _depth++;
    // `if (e is SomeClass)` promotes catch-bound `e` to a real object inside
    // the then-branch; field accesses there are members, not map keys.
    _withCatchVarPromoted(
      _isPromotedCatchVar(cond),
      () => _generateBranchBody(then, hasReturn),
    );
    _depth--;
    if (els != null) {
      if (_isStdCall(els, 'if')) {
        _wr('} else ');
        _generateIf(_extractFields(els.call), hasReturn);
        return;
      }
      _wl('} else {');
      _depth++;
      // The `else` arm of `if (X == null)` knows `X` is non-null.
      _withNonNullRef(
        _nullEqualityGuardRef(cond),
        () => _generateBranchBody(els, hasReturn),
      );
      _depth--;
    }
    _wl('}');
  }

  void _generateBranchBody(Expression expr, bool hasReturn) {
    if (expr.whichExpr() == Expression_Expr.block) {
      _generateBlockStatements(expr.block, hasReturn);
    } else if (_isStdControl(expr)) {
      _generateStdStatement(expr.call, hasReturn);
    } else {
      _wl(hasReturn ? 'return ${_e(expr)};' : '${_e(expr)};');
    }
  }

  void _generateFor(Map<String, Expression> fields) {
    // 'init' may be:
    //   1. a string literal (legacy human-readable form)
    //   2. a block of let-bindings (encoder emits this for `for (var i = 0, j = 1; ...)`)
    //   3. an expression statement (`numArgs = args.length`)
    final initExpr = fields['init'];
    final body = fields['body'];

    // Detect closure capture: if the for-body contains a lambda that
    // references a loop variable declared in init, hoist the variable
    // declaration before the for-loop. This implements Ball's shared-
    // variable semantics (unlike Dart's per-iteration binding).
    final initVarNames = _extractForInitVarNames(initExpr);
    final needsHoist =
        initVarNames.isNotEmpty &&
        body != null &&
        _bodyContainsLambdaCapturing(body, initVarNames);

    if (needsHoist &&
        initExpr != null &&
        initExpr.whichExpr() == Expression_Expr.block) {
      // Hoist variable declarations before the loop.
      for (final s in initExpr.block.statements) {
        if (s.whichStmt() == Statement_Stmt.let) {
          _wl('${_letDeclKeyword(s.let)} ${s.let.name} = ${_e(s.let.value)};');
        }
      }
      final condStr = fields['condition'] != null
          ? _e(fields['condition']!)
          : '';
      final updateStr = fields['update'] != null ? _e(fields['update']!) : '';
      _wl('for (; $condStr; $updateStr) {');
    } else {
      final init = initExpr != null
          ? (_stringFieldValue(fields, 'init') ??
                _renderForInit(initExpr) ??
                _e(initExpr))
          : '';
      final condStr = fields['condition'] != null
          ? _e(fields['condition']!)
          : '';
      final updateStr = fields['update'] != null ? _e(fields['update']!) : '';
      _wl('for ($init; $condStr; $updateStr) {');
    }
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _depth--;
    _wl('}');
  }

  /// Extract variable names declared in a for-loop init block.
  Set<String> _extractForInitVarNames(Expression? initExpr) {
    if (initExpr == null) return const {};
    if (initExpr.whichExpr() != Expression_Expr.block) return const {};
    final names = <String>{};
    for (final s in initExpr.block.statements) {
      if (s.whichStmt() == Statement_Stmt.let) names.add(s.let.name);
    }
    return names;
  }

  /// Returns true if [expr] contains any lambda that references one of [varNames].
  bool _bodyContainsLambdaCapturing(Expression expr, Set<String> varNames) {
    switch (expr.whichExpr()) {
      case Expression_Expr.lambda:
        // Check if the lambda body references any of the varNames.
        return _exprReferences(
          Expression()..lambda = expr.lambda,
          varNames,
          insideLambda: true,
        );
      case Expression_Expr.call:
        if (expr.call.hasInput()) {
          if (_bodyContainsLambdaCapturing(expr.call.input, varNames)) {
            return true;
          }
        }
        return false;
      case Expression_Expr.messageCreation:
        for (final f in expr.messageCreation.fields) {
          if (_bodyContainsLambdaCapturing(f.value, varNames)) return true;
        }
        return false;
      case Expression_Expr.block:
        for (final s in expr.block.statements) {
          if (s.whichStmt() == Statement_Stmt.expression) {
            if (_bodyContainsLambdaCapturing(s.expression, varNames)) {
              return true;
            }
          } else if (s.whichStmt() == Statement_Stmt.let && s.let.hasValue()) {
            if (_bodyContainsLambdaCapturing(s.let.value, varNames)) {
              return true;
            }
          }
        }
        if (expr.block.hasResult()) {
          return _bodyContainsLambdaCapturing(expr.block.result, varNames);
        }
        return false;
      default:
        return false;
    }
  }

  /// Returns true if [expr] references any name in [varNames].
  /// When [insideLambda] is true, we're already inside a lambda and any
  /// reference to varNames counts as a capture.
  bool _exprReferences(
    Expression expr,
    Set<String> varNames, {
    bool insideLambda = false,
  }) {
    switch (expr.whichExpr()) {
      case Expression_Expr.reference:
        return insideLambda && varNames.contains(expr.reference.name);
      case Expression_Expr.lambda:
        // Recurse into the lambda body with insideLambda=true.
        final func = expr.lambda;
        if (func.hasBody()) {
          return _exprReferences(func.body, varNames, insideLambda: true);
        }
        return false;
      case Expression_Expr.call:
        if (expr.call.hasInput()) {
          return _exprReferences(
            expr.call.input,
            varNames,
            insideLambda: insideLambda,
          );
        }
        return false;
      case Expression_Expr.messageCreation:
        for (final f in expr.messageCreation.fields) {
          if (_exprReferences(f.value, varNames, insideLambda: insideLambda)) {
            return true;
          }
        }
        return false;
      case Expression_Expr.block:
        for (final s in expr.block.statements) {
          if (s.whichStmt() == Statement_Stmt.expression) {
            if (_exprReferences(
              s.expression,
              varNames,
              insideLambda: insideLambda,
            )) {
              return true;
            }
          } else if (s.whichStmt() == Statement_Stmt.let && s.let.hasValue()) {
            if (_exprReferences(
              s.let.value,
              varNames,
              insideLambda: insideLambda,
            )) {
              return true;
            }
          }
        }
        if (expr.block.hasResult()) {
          return _exprReferences(
            expr.block.result,
            varNames,
            insideLambda: insideLambda,
          );
        }
        return false;
      case Expression_Expr.fieldAccess:
        return _exprReferences(
          expr.fieldAccess.object,
          varNames,
          insideLambda: insideLambda,
        );
      default:
        return false;
    }
  }

  /// Render a Ball for-loop `init` block as a Dart `for` initialiser
  /// declaration (e.g. `var i = 0, j = 1`). Returns `null` when [initExpr]
  /// is not the recognised block-of-let-bindings shape, so the caller can
  /// fall back to the generic expression compiler.
  String? _renderForInit(Expression initExpr) {
    if (initExpr.whichExpr() != Expression_Expr.block) return null;
    final block = initExpr.block;
    if (block.statements.isEmpty || block.hasResult()) return null;

    final keywords = <String>{};
    final types = <String>{};
    final bindings = <String>[];
    for (final s in block.statements) {
      if (s.whichStmt() != Statement_Stmt.let) return null;
      final let = s.let;
      final meta = let.metadata;
      String keyword = 'var';
      String? typeStr;
      if (meta.fields.containsKey('keyword')) {
        keyword = meta.fields['keyword']!.stringValue;
      }
      if (meta.fields.containsKey('type')) {
        typeStr = meta.fields['type']!.stringValue;
      }
      keywords.add(keyword);
      if (typeStr != null) types.add(typeStr);

      String binding = let.name;
      if (let.hasValue() &&
          !(let.value.whichExpr() == Expression_Expr.reference &&
              let.value.reference.name == '__no_init__')) {
        binding = '${let.name} = ${_e(let.value)}';
      }
      bindings.add(binding);
    }

    if (keywords.length != 1) return null;
    if (types.length > 1) return null;
    final keyword = keywords.first;
    final prefix = types.isEmpty ? keyword : types.first;
    return '$prefix ${bindings.join(', ')}';
  }

  void _generateForIn(Map<String, Expression> fields) {
    // Pattern form (Dart 3 destructuring): the encoder stores the whole
    // `<kw> <pattern>` verbatim under `pattern` — splice directly into
    // `for (<pattern> in <iter>) <body>`.
    final patternStr = _stringFieldValue(fields, 'pattern');
    final String typeDecl;
    if (patternStr != null && patternStr.isNotEmpty) {
      typeDecl = patternStr;
    } else {
      final variable = _stringFieldValue(fields, 'variable') ?? 'item';
      final variableType = _stringFieldValue(fields, 'variable_type');
      final variableKeyword = _stringFieldValue(fields, 'variable_keyword');
      if (variableType != null && variableType.isNotEmpty) {
        typeDecl = '$variableType $variable';
      } else if (variableKeyword == 'var') {
        typeDecl = 'var $variable';
      } else {
        // Default: `final` (matches pre-existing behaviour for programs that
        // omit the keyword; most Ball-constructed loops want final anyway).
        typeDecl = 'final $variable';
      }
    }
    final iterable = fields['iterable'];
    final body = fields['body'];
    final isAwait = _boolFieldValue(fields, 'is_await');
    final awaitKw = isAwait ? 'await ' : '';
    _wl(
      '${awaitKw}for ($typeDecl in '
      '${iterable != null ? _e(iterable) : "[]"}) {',
    );
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _depth--;
    _wl('}');
  }

  void _generateWhile(Map<String, Expression> fields) {
    final cond = fields['condition'];
    final body = fields['body'];
    _wl('while (${cond != null ? _e(cond) : "true"}) {');
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _depth--;
    _wl('}');
  }

  void _generateDoWhile(Map<String, Expression> fields) {
    final body = fields['body'];
    final cond = fields['condition'];
    _wl('do {');
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _depth--;
    _wl('} while (${cond != null ? _e(cond) : "true"});');
  }

  void _generateSwitch(Map<String, Expression> fields) {
    final subject = fields['subject'];
    final cases = fields['cases'];
    _wl('switch (${subject != null ? _e(subject) : "null"}) {');
    _depth++;
    if (cases != null &&
        cases.whichExpr() == Expression_Expr.literal &&
        cases.literal.whichValue() == Literal_Value.listValue) {
      for (final c in cases.literal.listValue.elements) {
        _generateSwitchCase(c);
      }
    }
    _depth--;
    _wl('}');
  }

  void _generateSwitchCase(Expression caseExpr) {
    if (caseExpr.whichExpr() != Expression_Expr.messageCreation) return;
    final cf = _fieldsToMap(caseExpr.messageCreation.fields);
    final isDefault = _boolFieldValue(cf, 'is_default');
    final body = cf['body'];

    if (isDefault) {
      _wl('default:');
    } else {
      // Prefer the semantic `pattern_expr` (the cosmetic `pattern` for a switch
      // STATEMENT omits the `when` clause, so all guarded arms would collapse to
      // the same label). Append the guard separately.
      final guard = cf['guard'];
      var label = cf['pattern_expr'] != null
          ? _compilePatternExpr(cf['pattern_expr']!)
          : null;
      var labelHasGuard = false;
      if (label == null) {
        final cosmetic = _stringFieldValue(cf, 'pattern');
        if (cosmetic != null && cosmetic.isNotEmpty) {
          label = cosmetic;
          labelHasGuard = cosmetic.contains(' when ');
        }
      }
      if (label == null) {
        final value = cf['value'];
        if (value == null) return;
        label = _e(value);
      }
      final guardStr = (guard != null && !labelHasGuard)
          ? ' when ${_e(guard)}'
          : '';
      _wl('case $label$guardStr:');
    }
    // Fall-through: an empty case body means the original Dart source used
    // label fall-through (`case A: case B: body;`). Emit NO `break` so Dart
    // falls through to the next case. Also, if the body already ends with
    // `return`/`throw`/`continue`/`break`, skip the trailing `break`.
    if (body == null || _isEmptyBody(body)) {
      // Empty body: fall-through. No break, no body.
      return;
    }
    _depth++;
    _generateBranchBody(body, false);
    if (!_bodyEndsWithControlFlow(body)) {
      _wl('break;');
    }
    _depth--;
  }

  /// Returns true if the body expression ends with a terminating statement
  /// (return, throw, continue, break) that would make a trailing `break;`
  /// dead code. Used by switch-case generation.
  bool _bodyEndsWithControlFlow(Expression body) {
    Expression last = body;
    if (body.whichExpr() == Expression_Expr.block) {
      final stmts = body.block.statements;
      if (stmts.isEmpty) return false;
      final lastStmt = stmts.last;
      if (lastStmt.whichStmt() != Statement_Stmt.expression) return false;
      last = lastStmt.expression;
    }
    if (last.whichExpr() != Expression_Expr.call) return false;
    final fn = last.call.function;
    return fn == 'return' || fn == 'throw' || fn == 'continue' || fn == 'break';
  }

  /// Common Dart exception class names. When a typed catch's `type` is
  /// one of these, we emit `on Type catch` so existing Dart programs
  /// (e.g. `try { ... } on FormatException catch (e) { ... }`) round-trip
  /// unchanged. For any other type name — including user types and Ball
  /// tag strings — we emit a catch-all with runtime dispatch that
  /// matches the Ball engine's semantics.
  static const _dartBuiltinExceptions = {
    'Exception',
    'Error',
    'FormatException',
    'RangeError',
    'ArgumentError',
    'StateError',
    'UnsupportedError',
    'UnimplementedError',
    'TypeError',
    'NoSuchMethodError',
    'OutOfMemoryError',
    'StackOverflowError',
    'IntegerDivisionByZeroException',
    'ConcurrentModificationError',
    'IndexError',
    'IOException',
    'FileSystemException',
    'HttpException',
    'SocketException',
  };

  void _generateTry(Map<String, Expression> fields) {
    final body = fields['body'];
    final catches = fields['catches'];
    final fin = fields['finally'];

    // Partition catches into "real Dart class" vs "Ball tag / untyped".
    // Real Dart classes emit as `} on T catch (e) { ... }`; everything
    // else goes into a single catch-all that dispatches via if-else on
    // `e['__type']` so the Ball engine's semantics round-trip.
    final dartClassCatches = <Expression>[];
    final tagCatches = <Expression>[];
    Expression? untypedCatch;

    if (catches != null &&
        catches.whichExpr() == Expression_Expr.literal &&
        catches.literal.whichValue() == Literal_Value.listValue) {
      for (final ce in catches.literal.listValue.elements) {
        if (ce.whichExpr() != Expression_Expr.messageCreation) continue;
        final cf = _fieldsToMap(ce.messageCreation.fields);
        final type = _stringFieldValue(cf, 'type');
        if (type == null || type.isEmpty) {
          untypedCatch ??= ce;
        } else if (_dartBuiltinExceptions.contains(type)) {
          dartClassCatches.add(ce);
        } else {
          tagCatches.add(ce);
        }
      }
    }

    _wl('try {');
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _depth--;

    // Emit each real-Dart-class catch as a standalone `on T catch`.
    for (final ce in dartClassCatches) {
      _generateCatchClause(ce);
    }

    // If we have tag-typed catches or an untyped catch, emit a single
    // catch-all that dispatches. Otherwise nothing (unhandled
    // exceptions propagate naturally).
    if (tagCatches.isNotEmpty || untypedCatch != null) {
      // Preserve stack_trace bindings from any catch clause that had one.
      // Dart-source `catch (e, stack)` or `on T catch (e, stack)` encodes
      // a `stack_trace` field per clause; without this, `stack` would be
      // undefined in the body. We union the stack names across clauses
      // and emit ONE catch-all stack parameter so every branch can see it,
      // aliasing to each clause's requested name inside its branch.
      String? untypedStack;
      if (untypedCatch != null) {
        final cf = _fieldsToMap(untypedCatch.messageCreation.fields);
        final s = _stringFieldValue(cf, 'stack_trace');
        if (s != null && s.isNotEmpty) untypedStack = s;
      }
      // Collect stack_trace names requested by tag catches.
      final tagStackNames = <String>{};
      for (final ce in tagCatches) {
        final cf = _fieldsToMap(ce.messageCreation.fields);
        final s = _stringFieldValue(cf, 'stack_trace');
        if (s != null && s.isNotEmpty) tagStackNames.add(s);
      }
      final anyNeedsStack = untypedStack != null || tagStackNames.isNotEmpty;
      // Use a stable catch-level name; alias per-branch.
      const catchAllStack = '__ball_st';
      if (anyNeedsStack) {
        _wl('} catch (__ball_e, $catchAllStack) {');
      } else {
        _wl('} catch (__ball_e) {');
      }
      _depth++;
      bool first = true;
      for (final ce in tagCatches) {
        final cf = _fieldsToMap(ce.messageCreation.fields);
        final type = _stringFieldValue(cf, 'type')!;
        final variable = _stringFieldValue(cf, 'variable') ?? 'e';
        final stackName = _stringFieldValue(cf, 'stack_trace');
        final cbody = cf['body'];
        final keyword = first ? 'if' : 'else if';
        _wl("$keyword (__ball_e is Map && __ball_e['__type'] == '$type') {");
        _depth++;
        _wl('final $variable = __ball_e;');
        if (stackName != null &&
            stackName.isNotEmpty &&
            stackName != catchAllStack) {
          _wl('final $stackName = $catchAllStack;');
        }
        _catchBoundVars.add(variable);
        if (cbody != null) _generateBranchBody(cbody, false);
        _catchBoundVars.remove(variable);
        _depth--;
        _wl('}');
        first = false;
      }
      // Fallback: the untyped catch body, or rethrow to propagate.
      if (untypedCatch != null) {
        final cf = _fieldsToMap(untypedCatch.messageCreation.fields);
        final variable = _stringFieldValue(cf, 'variable') ?? 'e';
        final cbody = cf['body'];
        if (tagCatches.isNotEmpty) {
          _wl('else {');
          _depth++;
        }
        // Use `dynamic` so the variable can be used freely (e.g. in
        // string concatenation) without Dart type errors.
        _wl('final dynamic $variable = __ball_e;');
        if (untypedStack != null && untypedStack != catchAllStack) {
          _wl('final $untypedStack = $catchAllStack;');
        }
        _catchBoundVars.add(variable);
        if (cbody != null) _generateBranchBody(cbody, false);
        _catchBoundVars.remove(variable);
        if (tagCatches.isNotEmpty) {
          _depth--;
          _wl('}');
        }
      } else {
        _wl('else { rethrow; }');
      }
      _depth--;
    }

    if (fin != null) {
      _wl('} finally {');
      _depth++;
      _generateBranchBody(fin, false);
      _depth--;
    }
    _wl('}');
  }

  void _generateCatchClause(Expression catchExpr) {
    if (catchExpr.whichExpr() != Expression_Expr.messageCreation) return;
    final cf = _fieldsToMap(catchExpr.messageCreation.fields);
    final type = _stringFieldValue(cf, 'type');
    final variable = _stringFieldValue(cf, 'variable') ?? 'e';
    final stackTrace = _stringFieldValue(cf, 'stack_trace');
    final body = cf['body'];

    final clause = StringBuffer();
    if (type != null && type.isNotEmpty) {
      clause.write('} on $type catch ($variable');
    } else {
      // Unreachable: _generateCatchClause is only called for `dartClassCatches`
      // (real Dart-builtin exception types), so `type` is always non-empty.
      // Untyped / Ball-tag catches are handled by the catch-all dispatcher in
      // _generateTry, never here.
      clause.write('} catch ($variable'); // coverage:ignore-line
    }
    if (stackTrace != null && stackTrace.isNotEmpty) {
      clause.write(', $stackTrace');
    }
    clause.write(') {');
    _wl(clause.toString());
    _depth++;
    // Only treat the caught variable as a Map when there's no explicit type
    // annotation. When the user caught a specific Dart exception class
    // (e.g. `on FileSystemException catch (e)`), `e.message` must stay dotted.
    // treatAsMap is always false here (see above) — the bodies of these guards
    // are unreachable defensive code.
    final treatAsMap = type == null || type.isEmpty;
    if (treatAsMap) _catchBoundVars.add(variable); // coverage:ignore-line
    if (body != null) _generateBranchBody(body, false);
    if (treatAsMap) _catchBoundVars.remove(variable); // coverage:ignore-line
    _depth--;
  }

  void _generateAssert(Map<String, Expression> fields) {
    final cond = fields['condition'];
    final msg = fields['message'];
    if (cond == null) return;
    _wl(
      msg != null ? 'assert(${_e(cond)}, ${_e(msg)});' : 'assert(${_e(cond)});',
    );
  }

  void _generateAssign(Map<String, Expression> fields) {
    final target = fields['target'], value = fields['value'];
    final op = _stringFieldValue(fields, 'op');
    if (target == null || value == null) return;
    final assignOp = (op != null && op.isNotEmpty) ? op : '=';

    // Encoder wraps `list.add(x)` as `assign(target=list, value=list_push(list=list, value=x))`
    // so non-mutating runtimes hold the new collection. Dart's
    // List.add()/.clear()/etc already mutate in place, so emit just the
    // call (the cascade already evaluates to the receiver) and skip the
    // re-binding (which would also fail when the variable was declared
    // `final`). Mirrors the same elision in [_compileAssign].
    if (assignOp == '=' &&
        target.whichExpr() == Expression_Expr.reference &&
        value.whichExpr() == Expression_Expr.call) {
      final inner = value.call;
      // Methods that mutate the receiver in place in Dart, so the encoder's
      // wrap-in-assign(target=x, value=op(list=x, ...)) can be elided.
      const inPlaceMutations = <(String, String)>{
        ('std_collections', 'list_push'),
        ('std_collections', 'list_clear'),
        ('std_collections', 'list_sort'),
        ('std_collections', 'list_insert'),
      };
      if (inPlaceMutations.contains((inner.module, inner.function))) {
        final innerFields = _extractFields(inner);
        final mutated = innerFields['list'];
        if (mutated != null &&
            mutated.whichExpr() == Expression_Expr.reference &&
            mutated.reference.name == target.reference.name) {
          _wl('${_e(value)};');
          return;
        }
      }
      // list_concat creates a new list (encoder uses it for `addAll`) — the
      // assign would fail on a `final` receiver. When the receiver of the
      // concat *is* the assign target, the original was an addAll() call;
      // emit `target.addAll(other);` (in-place) instead of reassigning.
      if (inner.module == 'std_collections' &&
          inner.function == 'list_concat') {
        final innerFields = _extractFields(inner);
        final left = innerFields['left'] ?? innerFields['list'];
        final right = innerFields['right'] ?? innerFields['value'];
        if (left != null &&
            left.whichExpr() == Expression_Expr.reference &&
            left.reference.name == target.reference.name &&
            right != null) {
          _wl('${_e(target)}.addAll(${_e(right)});');
          return;
        }
      }
    }

    _wl('${_e(target)} $assignOp ${_e(value)};');
  }

  void _generateLabeled(Map<String, Expression> fields) {
    final label = _stringFieldValue(fields, 'label');
    final body = fields['body'];
    if (label == null || body == null) return;
    _wl('$label:');
    _generateBranchBody(body, false);
  }

  // ════════════════════════════════════════════════════════════
  // Expression compilation
  // ════════════════════════════════════════════════════════════

  cb.Expression _compileExpression(Expression expr) =>
      switch (expr.whichExpr()) {
        Expression_Expr.call => _raw(_compileCall(expr.call)),
        Expression_Expr.literal => _compileLiteral(expr.literal),
        Expression_Expr.reference => cb.refer(
          (_insideInstanceMethod &&
                  _selfShadowDepth == 0 &&
                  expr.reference.name == 'self')
              ? 'this'
              : expr.reference.name,
        ),
        Expression_Expr.fieldAccess => _compileFieldAccess(expr.fieldAccess),
        Expression_Expr.messageCreation => _raw(
          _compileMessageCreation(expr.messageCreation),
        ),
        Expression_Expr.block => _raw(_compileBlockExpression(expr.block)),
        Expression_Expr.lambda => _raw(_compileLambda(expr.lambda)),
        Expression_Expr.notSet => _raw('/* unknown expression */'),
      };

  cb.Expression _compileFieldAccess(FieldAccess fa) {
    final obj = _compileExpression(fa.object);
    // __cascade_self__ is a sentinel that means "no explicit receiver" inside
    // a cascade section — emit just the field name. Only applies in old-format
    // cascade compilation; in Block-based expansions it's a real variable.
    if (_inCascadeCompilation && _emit(obj) == '__cascade_self__') {
      return cb.refer(fa.field_2);
    }
    // When the receiver is a catch-bound variable from a Ball tag-typed catch,
    // the caught value is a Map. Dart Maps don't support dotted access so we
    // emit `e['field']` instead of `e.field`. Universal `Object` members
    // (`runtimeType`, `hashCode`) exist on every value — including Maps — so
    // they must stay dotted: `e['runtimeType']` would read a (missing) map key
    // and yield null, breaking e.g. `e.runtimeType.toString() == catchType`.
    const universalObjectMembers = {'runtimeType', 'hashCode'};
    if (fa.object.whichExpr() == Expression_Expr.reference &&
        _catchBoundVars.contains(fa.object.reference.name) &&
        !universalObjectMembers.contains(fa.field_2)) {
      return _raw("${_emit(obj)}['${fa.field_2}']");
    }
    // Parenthesize an operator receiver so `.field` binds to it, not the
    // operand: `(-2.5).isNegative`, not `-2.5.isNegative` (= `-(2.5.isNegative)`).
    final inner = _emit(obj);
    if (_needsParensAsReceiver(fa.object, inner)) {
      return _raw('($inner).${fa.field_2}');
    }
    return obj.property(fa.field_2);
  }

  /// If [condition] is an `is`-check that promotes a catch-bound variable to a
  /// concrete (non-Map) class — e.g. `e is BallException` — returns that
  /// variable's name; otherwise null.
  ///
  /// A catch variable is treated as a thrown Map by default (so `e.field`
  /// lowers to `e['field']`). But inside an `is <ClassType>` guard, Dart
  /// promotes the variable to that class, where the throwing language really
  /// did access a *member* (`e.typeName`), not a map key. We therefore
  /// suppress the map-subscript rewrite within the promoted branch. `Map`/
  /// `List`/`Set` promotions are excluded — those keep subscript semantics.
  String? _isPromotedCatchVar(Expression condition) {
    if (condition.whichExpr() != Expression_Expr.call) return null;
    final call = condition.call;
    if (!_isStdCall(condition, 'is')) return null;
    final fields = _extractFields(call);
    final value = fields['value'];
    final type = _stringFieldValue(fields, 'type');
    if (value == null || type == null) return null;
    if (value.whichExpr() != Expression_Expr.reference) return null;
    final name = value.reference.name;
    if (!_catchBoundVars.contains(name)) return null;
    // Collection types keep map/subscript semantics; only class promotions
    // (real objects with real members) suppress the rewrite.
    final bareType = type.split('<').first.trim();
    if (bareType == 'Map' || bareType == 'List' || bareType == 'Set') {
      return null;
    }
    return name;
  }

  /// Runs [body] with [varName] temporarily removed from [_catchBoundVars] so
  /// field accesses on it compile to dotted member access. Restores afterward.
  T _withCatchVarPromoted<T>(String? varName, T Function() body) {
    if (varName == null || !_catchBoundVars.contains(varName)) return body();
    _catchBoundVars.remove(varName);
    try {
      return body();
    } finally {
      _catchBoundVars.add(varName);
    }
  }

  /// If [condition] is `X == null` (the lowered guard for a `?.` call), returns
  /// the reference name `X` — known non-null in the `else` arm. Otherwise null.
  String? _nullEqualityGuardRef(Expression condition) {
    if (!_isStdCall(condition, 'equals')) return null;
    final fields = _extractFields(condition.call);
    final left = fields['left'], right = fields['right'];
    if (left == null || right == null) return null;
    final leftIsNull = _isNullLiteral(left);
    final rightIsNull = _isNullLiteral(right);
    // Exactly one side is the null literal; the other must be a reference.
    final Expression other;
    if (rightIsNull && !leftIsNull) {
      other = left;
    } else if (leftIsNull && !rightIsNull) {
      other = right;
    } else {
      return null;
    }
    if (other.whichExpr() != Expression_Expr.reference) return null;
    return other.reference.name;
  }

  bool _isNullLiteral(Expression e) =>
      e.whichExpr() == Expression_Expr.literal &&
      e.literal.whichValue() == Literal_Value.notSet;

  /// Runs [body] with [varName] marked non-null (for the `else` arm of a
  /// null-guard). Restores the prior membership afterward.
  T _withNonNullRef<T>(String? varName, T Function() body) {
    if (varName == null || _nonNullRefs.contains(varName)) return body();
    _nonNullRefs.add(varName);
    try {
      return body();
    } finally {
      _nonNullRefs.remove(varName);
    }
  }

  String _compileCall(FunctionCall call) {
    if (_isBaseModule(call.module)) return _compileBaseCall(call);

    if (call.hasInput() &&
        call.input.whichExpr() == Expression_Expr.messageCreation) {
      final fields = call.input.messageCreation.fields;
      final selfField = fields.where((f) => f.name == 'self').firstOrNull;
      if (selfField != null) {
        final typeArgs = _callTypeArgsStr(call).isNotEmpty
            ? _callTypeArgsStr(call)
            : (fields
                      .where((f) => f.name == '__type_args__')
                      .firstOrNull
                      ?.value
                      .literal
                      .stringValue ??
                  '');
        final remaining = fields
            .where((f) => f.name != 'self' && f.name != '__type_args__')
            .toList();
        var selfStr = _e(selfField.value);
        if (_inCascadeCompilation && selfStr == '__cascade_self__') {
          return remaining.isEmpty
              ? '${call.function}$typeArgs()'
              : '${call.function}$typeArgs(${_compileArgs(remaining)})';
        }
        // When the receiver was proven non-null in this branch (the `else`
        // arm of a lowered `X?.call()` guard), assert it so invoking it
        // type-checks: `X!.call()`. Dart promotes nullable *locals* in the
        // guard's else arm but never *fields*; `.call()` (the `invoke` base
        // function) is the construct that surfaces this — a field holding a
        // nullable function. Restricting to `call` avoids redundant `!` on
        // already-promoted locals (e.g. `local?.toString()`).
        if (call.function == 'call' &&
            selfField.value.whichExpr() == Expression_Expr.reference &&
            _nonNullRefs.contains(selfField.value.reference.name)) {
          selfStr = '$selfStr!';
        }
        return remaining.isEmpty
            ? '$selfStr.${call.function}$typeArgs()'
            : '$selfStr.${call.function}$typeArgs(${_compileArgs(remaining)})';
      }
    }

    // Generate the call: use _compileArgs for an argument-list message,
    // or _compileExpression for a single-value input.
    // Restore the import-alias prefix for prefixed calls:
    //  - dart:developer as dev → dev.log()
    //  - package:path/path.dart as p → p.prettyUri()
    final String modulePrefix;
    final alias = _dartModuleAliases[call.module];
    if (alias != null) {
      modulePrefix = '$alias.';
    } else if (call.module.startsWith('dart.')) {
      // Fallback for dart:* imports without an explicit alias:
      // use the library name directly (e.g. dart.math → math.).
      modulePrefix = '${call.module.substring(5)}.';
    } else {
      modulePrefix = '';
    }
    // Strip module prefix from function name when it's a qualified constructor
    // call encoded as FunctionCall (e.g. "main:Dog.new" → "Dog.new").
    final fnName = call.function.contains(':')
        ? call.function.substring(call.function.lastIndexOf(':') + 1)
        : call.function;
    String result;
    if (call.hasInput()) {
      final inp = call.input;
      if (inp.whichExpr() == Expression_Expr.messageCreation &&
          inp.messageCreation.typeName.isEmpty) {
        // Argument-list message: emit named / positional args properly.
        final allFields = inp.messageCreation.fields;
        final typeArgs = _callTypeArgsStr(call).isNotEmpty
            ? _callTypeArgsStr(call)
            : (allFields
                      .where((f) => f.name == '__type_args__')
                      .firstOrNull
                      ?.value
                      .literal
                      .stringValue ??
                  '');
        final args = allFields.where((f) => f.name != '__type_args__').toList();
        result = args.isEmpty
            ? '$modulePrefix$fnName$typeArgs()'
            : '$modulePrefix$fnName$typeArgs(${_compileArgs(args)})';
      } else {
        result = '$modulePrefix$fnName(${_e(inp)})';
      }
    } else {
      result = '$modulePrefix$fnName()';
    }

    // Auto-await: if the called function is known to be async, wrap the call
    // in `await` so callers get the resolved value instead of a Future.
    // Skip if we're already inside an explicit `std.await(...)` wrapper.
    if (!_insideExplicitAwait &&
        _asyncFunctions.contains(call.function) &&
        (call.module.isEmpty || call.module == program.entryModule)) {
      _needsAsync = true;
      return 'await $result';
    }
    return result;
  }

  /// Flag set by [_compileCall] when an auto-await is inserted.
  /// Read by [_buildMainFunction] to decide whether to mark `main` as async.
  bool _needsAsync = false;

  /// True when the currently compiled function is a generator (`sync*` or
  /// `async*`). Generators cannot `return <value>;` in Dart — only bare
  /// `return;` — so the compiler drops the value from `std.return`.
  bool _inGenerator = false;
  bool _inCascadeCompilation = false;
  bool _insideInstanceMethod = false;

  /// Depth count of lexical scopes (parameters or `let` bindings) that declare
  /// a local variable literally named `self`, shadowing the implicit instance
  /// receiver. While > 0, a `self` reference resolves to that local — NOT to
  /// `this` — so the `self → this` rewrite in [_compileExpression] is
  /// suppressed. This mirrors the engine, which resolves `self` through the
  /// lexical scope chain (so a `let self = …` shadows the bound receiver).
  ///
  /// The encoder maps both the `this` keyword and any identifier named `self`
  /// to `reference("self")`, so without this guard the compiler cannot tell a
  /// genuine receiver from a user variable that happens to be named `self`
  /// (e.g. `_dispatchBuiltinInstanceMethod(Object? self, …)` in the engine).
  int _selfShadowDepth = 0;

  /// True when we're inside a `std.await(value: ...)` expression. Suppresses
  /// auto-await to avoid emitting `await await fn()`.
  bool _insideExplicitAwait = false;

  String _compileBaseCall(FunctionCall call) {
    if (call.module == 'std_memory') return _compileMemoryCall(call);
    if (call.module == 'std_collections') return _compileCollectionsCall(call);
    if (call.module == 'std_io') return _compileIoCall(call);
    if (call.module == 'std_convert') return _compileConvertCall(call);
    if (call.module == 'std_fs') return _compileFsCall(call);
    if (call.module == 'std_time') return _compileTimeCall(call);
    if (call.module == 'ball_proto') return _compileBallProtoCall(call);
    final f = _extractFields(call);
    return switch (call.function) {
      'print' => _compileBasePrint(f),
      // Arithmetic
      'add' => _binOp(f, '+'),
      'subtract' => _binOp(f, '-'),
      'multiply' => _binOp(f, '*'),
      'divide' => _binOp(f, '~/'),
      'divide_double' => _binOp(f, '/'),
      'modulo' => _binOp(f, '%'),
      'negate' => _prefixOp(f, '-'),
      // Comparison
      'equals' => _binOp(f, '=='),
      'not_equals' => _binOp(f, '!='),
      'less_than' => _binOp(f, '<'),
      'greater_than' => _binOp(f, '>'),
      'lte' => _binOp(f, '<='),
      'gte' => _binOp(f, '>='),
      // Logical
      'and' => _binOp(f, '&&'),
      'or' => _binOp(f, '||'),
      'not' => _prefixOp(f, '!'),
      // Bitwise
      'bitwise_and' => _binOp(f, '&'),
      'bitwise_or' => _binOp(f, '|'),
      'bitwise_xor' => _binOp(f, '^'),
      'bitwise_not' => _prefixOp(f, '~'),
      'left_shift' => _binOp(f, '<<'),
      'right_shift' => _binOp(f, '>>'),
      'unsigned_right_shift' => _binOp(f, '>>>'),
      // Increment / decrement
      'pre_increment' => _prefixMut(f, '++'),
      'pre_decrement' => _prefixMut(f, '--'),
      'post_increment' => _postfixMut(f, '++'),
      'post_decrement' => _postfixMut(f, '--'),
      // String & conversion
      'concat' => _binOp(f, '+'),
      'to_string' => _compileToString(f),
      'length' => _propertyAccess(f, 'length'),
      'int_to_string' => _methodCallExpr(f, 'toString()'),
      'double_to_string' => _methodCallExpr(f, 'toString()'),
      'string_to_int' => _staticCallExpr(f, 'int.parse'),
      'string_to_double' => _staticCallExpr(f, 'double.parse'),
      // Null safety
      'null_coalesce' => _binOp(f, '??'),
      'null_check' => _postfixMut(f, '!'),
      'null_aware_access' => _compileNullAwareAccess(f),
      'null_aware_call' => _compileNullAwareCall(call),
      // Conditional (ternary)
      'if' => _compileInlineIf(f),
      // Type ops
      'is' => _typeOp(f, 'is'),
      'is_not' => _typeOp(f, 'is!'),
      'as' => _typeOp(f, 'as'),
      // Assignment (simple and compound)
      'assign' => _compileAssign(f),
      // Indexing / collections / etc.
      'index' => _compileIndex(f),
      'null_aware_index' => _compileNullAwareIndex(f),
      'cascade' => _compileCascade(f),
      'null_aware_cascade' => _compileCascade(f),
      'paren' => '(${_e(f['value']!)})',
      'spread' => _compileSpread(f, '...'),
      'null_spread' => _compileSpread(f, '...?'),
      'invoke' => _compileInvoke(call),
      'tear_off' => _compileTearOff(f),
      'map_create' => _compileMapCreate(call),
      'set_create' => _compileSetCreate(f),
      'typed_list' => _compileTypedList(f),
      'record' => _compileRecord(call),
      'collection_if' => _compileCollectionIf(f),
      'collection_for' => _compileCollectionFor(f),
      'switch_expr' => _compileSwitchExpr(f),
      // Misc
      'symbol' => '#${_stringFieldValue(f, "value") ?? ""}',
      'type_literal' => _compileTypeLiteral(_stringFieldValue(f, 'type')),
      'await' => _awaitExpr(f),
      'throw' => _throwExpr(f),
      // ── Strings ─────────────────────────────────────────────
      'string_length' => _propertyAccess(f, 'length'),
      'string_is_empty' => _propertyAccess(f, 'isEmpty'),
      'string_concat' => _binOp(f, '+'),
      'string_contains' => _methodCall2(f, 'contains'),
      'string_starts_with' => _methodCall2(f, 'startsWith'),
      'string_ends_with' => _methodCall2(f, 'endsWith'),
      'string_index_of' => _methodCall2(f, 'indexOf'),
      'string_last_index_of' => _methodCall2(f, 'lastIndexOf'),
      'string_substring' => _compileSubstring(f),
      'string_char_at' => _compileIndex(f),
      'string_char_code_at' => _compileStringCharCodeAt(f),
      'string_from_char_code' => _staticCallExpr(f, 'String.fromCharCode'),
      'string_to_upper' => _methodCallExpr(f, 'toUpperCase()'),
      'string_to_lower' => _methodCallExpr(f, 'toLowerCase()'),
      'string_trim' => _methodCallExpr(f, 'trim()'),
      'string_trim_start' => _methodCallExpr(f, 'trimLeft()'),
      'string_trim_end' => _methodCallExpr(f, 'trimRight()'),
      'string_replace' => _compileStringReplace(f, 'replaceFirst'),
      'string_replace_all' => _compileStringReplace(f, 'replaceAll'),
      'string_split' => _methodCall2(f, 'split'),
      'string_runes' => '(${_e(f['value']!)}).runes.toList()',
      'string_repeat' =>
        '(${_e(f['value'] ?? f['left']!)} * ${_e(f['count'] ?? f['right']!)})',
      'string_pad_left' => _compileStringPad(f, 'padLeft'),
      'string_pad_right' => _compileStringPad(f, 'padRight'),
      'string_join' =>
        f.containsKey('separator')
            ? '${_e(f['list']!)}.join(${_e(f['separator']!)})'
            : '${_e(f['list']!)}.join()',
      // ── Regex ───────────────────────────────────────────────
      'regex_match' => _compileRegexMatch(f),
      'regex_find' => _compileRegexFind(f, all: false),
      'regex_find_all' => _compileRegexFind(f, all: true),
      'regex_replace' => _compileRegexReplace(f, 'replaceFirst'),
      'regex_replace_all' => _compileRegexReplace(f, 'replaceAll'),
      // ── Math ────────────────────────────────────────────────
      'math_abs' => _methodCallExpr(f, 'abs()'),
      'math_floor' => _methodCallExpr(f, 'floor()'),
      'math_ceil' => _methodCallExpr(f, 'ceil()'),
      'math_round' => _methodCallExpr(f, 'round()'),
      'math_trunc' => _methodCallExpr(f, 'truncate()'),
      'math_sqrt' => _mathFunc(f, 'sqrt'),
      'math_pow' => _mathBinary(f, 'pow'),
      'math_log' => _mathFunc(f, 'log'),
      'math_log2' => '(${_mathFunc(f, "log")} / ln2)',
      'math_log10' => '(${_mathFunc(f, "log")} / ln10)',
      'math_exp' => _mathFunc(f, 'exp'),
      'math_sin' => _mathFunc(f, 'sin'),
      'math_cos' => _mathFunc(f, 'cos'),
      'math_tan' => _mathFunc(f, 'tan'),
      'math_asin' => _mathFunc(f, 'asin'),
      'math_acos' => _mathFunc(f, 'acos'),
      'math_atan' => _mathFunc(f, 'atan'),
      'math_atan2' => _mathBinary(f, 'atan2'),
      'math_min' => _mathBinary(f, 'min'),
      'math_max' => _mathBinary(f, 'max'),
      'math_clamp' => _compileMathClamp(f),
      'math_pi' => 'pi',
      'math_e' => 'e',
      'math_infinity' => 'double.infinity',
      'math_nan' => 'double.nan',
      'math_is_nan' => _propertyAccess(f, 'isNaN'),
      'math_is_finite' => _propertyAccess(f, 'isFinite'),
      'math_is_infinite' => _propertyAccess(f, 'isInfinite'),
      'math_sign' => _propertyAccess(f, 'sign'),
      'math_gcd' => _methodCall2(f, 'gcd'),
      'math_lcm' => _compileMathLcm(f),
      // ── Numeric / comparison sugar ─────────────────────────
      'compare_to' => _methodCall2(f, 'compareTo'),
      'to_double' => _methodCallExpr(f, 'toDouble()'),
      'to_int' => _methodCallExpr(f, 'toInt()'),
      'to_string_as_fixed' => _methodCall2(f, 'toStringAsFixed'),
      'string_code_unit_at' => _methodCall2(f, 'codeUnitAt'),
      // ── Dart-specific ───────────────────────────────────────
      'dart_list_generate' || 'list_generate' =>
        'List.generate(${_e(f['count'] ?? f['length']!)}, ${_e(f['generator']!)})',
      'dart_list_filled' || 'list_filled' =>
        'List.filled(${_e(f['count'] ?? f['length']!)}, ${_e(f['value'] ?? f['fill']!)})',
      // DateTime component accessors — value from field or implicit `input`
      'year' => '${_e(f['value'] ?? f['self'] ?? call.input)}.year',
      'month' => '${_e(f['value'] ?? f['self'] ?? call.input)}.month',
      'day' => '${_e(f['value'] ?? f['self'] ?? call.input)}.day',
      'hour' => '${_e(f['value'] ?? f['self'] ?? call.input)}.hour',
      'minute' => '${_e(f['value'] ?? f['self'] ?? call.input)}.minute',
      'second' => '${_e(f['value'] ?? f['self'] ?? call.input)}.second',
      'millisecond' =>
        '${_e(f['value'] ?? f['self'] ?? call.input)}.millisecond',
      'weekday' => '${_e(f['value'] ?? f['self'] ?? call.input)}.weekday',
      _ => '/* unsupported: std.${call.function} */',
    };
  }

  // ── std_memory → Dart ByteData compilation ──────────────────

  /// Compiles std_memory base calls to Dart code using a `ByteData`-backed
  /// linear memory simulation.
  ///
  /// The generated code assumes a top-level `_ballMemory` variable:
  /// ```dart
  /// import 'dart:typed_data';
  /// final _ballMemory = ByteData(65536); // 64 KB default heap
  /// int _ballHeapPtr = 0;
  /// final _ballStackFrames = <int>[];
  /// int _ballStackPtr = 65536; // grows downward from top
  /// ```
  String _compileMemoryCall(FunctionCall call) {
    final f = _extractFields(call);
    return switch (call.function) {
      // ── Allocation ──
      'memory_alloc' => _memAlloc(f),
      'memory_free' => '/* free(${_addrExpr(f)}) — noop in Dart */',
      // NOTE: aliases _memAlloc — allocates a fresh block but does NOT copy the
      // old contents or free the old block, so compiled `realloc` can lose data.
      'memory_realloc' => _memAlloc(f),
      // ── Typed reads ──
      'memory_read_i8' => '_ballMemory.getInt8(${_addrExpr(f)})',
      'memory_read_u8' => '_ballMemory.getUint8(${_addrExpr(f)})',
      'memory_read_i16' =>
        '_ballMemory.getInt16(${_addrExpr(f)}, Endian.little)',
      'memory_read_u16' =>
        '_ballMemory.getUint16(${_addrExpr(f)}, Endian.little)',
      'memory_read_i32' =>
        '_ballMemory.getInt32(${_addrExpr(f)}, Endian.little)',
      'memory_read_u32' =>
        '_ballMemory.getUint32(${_addrExpr(f)}, Endian.little)',
      'memory_read_i64' =>
        '_ballMemory.getInt64(${_addrExpr(f)}, Endian.little)',
      'memory_read_u64' =>
        '_ballMemory.getUint64(${_addrExpr(f)}, Endian.little)',
      'memory_read_f32' =>
        '_ballMemory.getFloat32(${_addrExpr(f)}, Endian.little)',
      'memory_read_f64' =>
        '_ballMemory.getFloat64(${_addrExpr(f)}, Endian.little)',

      // ── Typed writes ──
      'memory_write_i8' =>
        '_ballMemory.setInt8(${_addrExpr(f)}, ${_valExpr(f)})',
      'memory_write_u8' =>
        '_ballMemory.setUint8(${_addrExpr(f)}, ${_valExpr(f)})',
      'memory_write_i16' =>
        '_ballMemory.setInt16(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',
      'memory_write_u16' =>
        '_ballMemory.setUint16(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',
      'memory_write_i32' =>
        '_ballMemory.setInt32(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',
      'memory_write_u32' =>
        '_ballMemory.setUint32(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',
      'memory_write_i64' =>
        '_ballMemory.setInt64(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',
      'memory_write_u64' =>
        '_ballMemory.setUint64(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',
      'memory_write_f32' =>
        '_ballMemory.setFloat32(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',
      'memory_write_f64' =>
        '_ballMemory.setFloat64(${_addrExpr(f)}, ${_valExpr(f)}, Endian.little)',

      // ── Bulk operations ──
      'memory_copy' => _memCopy(f),
      'memory_set' => _memSet(f),
      'memory_compare' => _memCompare(f),

      // ── Pointer arithmetic ──
      'ptr_add' => _ptrArith(f, '+'),
      'ptr_sub' => _ptrArith(f, '-'),
      'ptr_diff' => _ptrDiff(f),

      // ── Stack frame ──
      'stack_alloc' => _stackAlloc(f),
      'stack_push_frame' => '_ballStackFrames.add(_ballStackPtr)',
      'stack_pop_frame' => '_ballStackPtr = _ballStackFrames.removeLast()',

      // ── Sizeof ──
      'memory_sizeof' => _memSizeof(f),

      // ── Address-of / deref (should be resolved by normalizer) ──
      'address_of' => '/* address_of: ${_valExpr(f)} */',
      'deref' => _memDeref(f),

      // ── Null pointer ──
      'nullptr' => '0',

      // ── Info ──
      'memory_heap_size' => '_ballMemory.lengthInBytes',
      'memory_stack_size' => '(_ballMemory.lengthInBytes - _ballStackPtr)',

      _ => '/* unsupported: std_memory.${call.function} */',
    };
  }

  String _addrExpr(Map<String, Expression> f) {
    final a = f['address'] ?? f['dest'] ?? f['a'];
    return a != null ? _e(a) : '0';
  }

  String _valExpr(Map<String, Expression> f) {
    final v = f['value'];
    return v != null ? _e(v) : '0';
  }

  String _memAlloc(Map<String, Expression> f) {
    final size = f['size'];
    final sizeStr = size != null ? _e(size) : '0';
    return '(() { final __addr = _ballHeapPtr; _ballHeapPtr += $sizeStr; return __addr; })()';
  }

  String _memCopy(Map<String, Expression> f) {
    final dest = f['dest'], src = f['src'], size = f['size'];
    final d = dest != null ? _e(dest) : '0';
    final s = src != null ? _e(src) : '0';
    final n = size != null ? _e(size) : '0';
    return '(() { for (var __i = 0; __i < $n; __i++) '
        '_ballMemory.setUint8($d + __i, _ballMemory.getUint8($s + __i)); })()';
  }

  String _memSet(Map<String, Expression> f) {
    final addr = f['address'], val = f['value'], size = f['size'];
    final a = addr != null ? _e(addr) : '0';
    final v = val != null ? _e(val) : '0';
    final n = size != null ? _e(size) : '0';
    return '(() { for (var __i = 0; __i < $n; __i++) '
        '_ballMemory.setUint8($a + __i, $v); })()';
  }

  String _memCompare(Map<String, Expression> f) {
    final a = f['a'], b = f['b'], size = f['size'];
    final aStr = a != null ? _e(a) : '0';
    final bStr = b != null ? _e(b) : '0';
    final n = size != null ? _e(size) : '0';
    return '(() { for (var __i = 0; __i < $n; __i++) { '
        'final __d = _ballMemory.getUint8($aStr + __i) - '
        '_ballMemory.getUint8($bStr + __i); '
        'if (__d != 0) return __d; } return 0; })()';
  }

  String _ptrArith(Map<String, Expression> f, String op) {
    final addr = f['address'],
        offset = f['offset'],
        elemSize = f['element_size'];
    final a = addr != null ? _e(addr) : '0';
    final o = offset != null ? _e(offset) : '0';
    final es = elemSize != null ? _e(elemSize) : '1';
    return '($a $op ($o * $es))';
  }

  String _ptrDiff(Map<String, Expression> f) {
    final a = f['address'], b = f['offset'], elemSize = f['element_size'];
    final aStr = a != null ? _e(a) : '0';
    final bStr = b != null ? _e(b) : '0';
    final es = elemSize != null ? _e(elemSize) : '1';
    return '(($aStr - $bStr) ~/ $es)';
  }

  String _stackAlloc(Map<String, Expression> f) {
    final size = f['size'];
    final sizeStr = size != null ? _e(size) : '0';
    return '(() { _ballStackPtr -= $sizeStr; return _ballStackPtr; })()';
  }

  String _memSizeof(Map<String, Expression> f) {
    final typeName = _stringFieldValue(f, 'type_name') ?? 'int';
    return switch (typeName) {
      'int8' || 'uint8' || 'char' || 'bool' => '1',
      'int16' || 'uint16' || 'short' => '2',
      'int32' || 'uint32' || 'int' || 'float' => '4',
      'int64' || 'uint64' || 'long' || 'double' || 'long long' => '8',
      'void' => '1',
      _ => '8', // default pointer-size
    };
  }

  String _memDeref(Map<String, Expression> f) {
    final ptr = f['pointer'];
    final ptrStr = ptr != null ? _e(ptr) : '0';
    // Default: read as 64-bit int (pointer-sized).
    return '_ballMemory.getInt64($ptrStr, Endian.little)';
  }

  // ── ball_proto compilation (proto reflection helpers) ─────
  // The encoder routes calls like `expr.whichExpr()` / `func.hasBody()`
  // to `ball_proto.whichExpr(obj=expr)` / `ball_proto.hasBody(obj=func)`
  // so every target language can implement them deterministically. In
  // Dart these map straight onto the protobuf-generated method on the
  // receiver.
  String _compileBallProtoCall(FunctionCall call) {
    final f = _extractFields(call);
    final obj = f['obj'] ?? f['value'] ?? f['target'] ?? f['receiver'];
    if (obj == null) return '/* invalid ball_proto.${call.function}() */';
    final receiver = _e(obj);
    return '$receiver.${call.function}()';
  }

  // ── std_collections compilation ────────────────────────────

  String _compileCollectionsCall(FunctionCall call) {
    final f = _extractFields(call);
    Expression _cb() => f['callback'] ?? f['function'] ?? f['value']!;
    Expression _val() => f['value'] ?? f['arg0']!;
    Expression _left() => f['left'] ?? f['list']!;
    Expression _right() => f['right'] ?? f['value']!;
    // Unreachable in practice: only `list_slice`'s one-arg fallback calls
    // `_start()`, and that path requires a non-message input — but `list_slice`
    // then dereferences `f['list']!` (always present via the message input), so
    // the fallback never runs with a bare `{value: …}` map.
    // coverage:ignore-start
    Expression _start() => f['start'] ?? f['index'] ?? f['value']!;
    // coverage:ignore-end
    return switch (call.function) {
      // List operations
      'list_push' => '${_e(f['list']!)}..add(${_e(_val())})',
      'list_pop' => '${_e(f['list']!)}.removeLast()',
      'list_insert' =>
        '${_e(f['list']!)}..insert(${_e(f['index'] ?? f['value']!)}, ${_e(f['value'] ?? f['arg1']!)})',
      'list_remove_at' =>
        '${_e(f['list']!)}.removeAt(${_e(f['index'] ?? f['value']!)})',
      'list_get' => '${_e(f['list']!)}[${_e(f['index'] ?? f['value']!)}]',
      'list_set' =>
        '(${_e(f['list']!)}[${_e(f['index']!)}] = ${_e(f['value']!)})',
      'list_length' => '${_e(f['list']!)}.length',
      'list_is_empty' => '${_e(f['list']!)}.isEmpty',
      'list_first' => '${_e(f['list']!)}.first',
      'list_last' => '${_e(f['list']!)}.last',
      'list_contains' => '${_e(f['list']!)}.contains(${_e(_val())})',
      'list_index_of' => '${_e(f['list']!)}.indexOf(${_e(_val())})',
      'list_map' => '${_e(f['list']!)}.map(${_e(_cb())}).toList()',
      'list_filter' => '${_e(f['list']!)}.where(${_e(_cb())}).toList()',
      'list_reduce' => '${_e(f['list']!)}.reduce(${_e(_cb())})',
      'list_any' => '${_e(f['list']!)}.any(${_e(_cb())})',
      'list_all' || 'list_every' => '${_e(f['list']!)}.every(${_e(_cb())})',
      'list_sort' =>
        f.containsKey('value') || f.containsKey('comparator')
            ? '(${_e(f['list']!)}..sort(${_e(_cb())}))'
            : '(${_e(f['list']!)}..sort())',
      'list_reverse' => '${_e(f['list']!)}.reversed.toList()',
      'list_slice' => () {
        // Use the raw field list (not the deduplicated map) because the
        // encoder may emit duplicate 'value' keys for start and end args.
        final rawFields =
            call.hasInput() &&
                call.input.whichExpr() == Expression_Expr.messageCreation
            ? call.input.messageCreation.fields
                  .where((fld) => fld.name != 'list')
                  .toList()
            // Unreachable: list_slice always carries a message input (it needs
            // a `list` field, dereferenced below); a non-message input would
            // already have crashed on `f['list']!`.
            : <FieldValuePair>[]; // coverage:ignore-line
        if (rawFields.length >= 2) {
          return '${_e(f['list']!)}.sublist(${_e(rawFields[0].value)}, ${_e(rawFields[1].value)})';
        }
        return '${_e(f['list']!)}.sublist(${rawFields.isNotEmpty ? _e(rawFields[0].value) : _e(_start())})';
      }(),
      'list_concat' => '[...${_e(_left())}, ...${_e(_right())}]',
      'list_flat_map' => '${_e(f['list']!)}.expand(${_e(_cb())}).toList()',
      'list_clear' => '${_e(f['list']!)}..clear()',
      'list_foreach' => '${_e(f['list']!)}.forEach(${_e(_cb())})',
      'list_to_list' => '${_e(f['list']!)}.toList()',
      'string_join' || 'list_join' =>
        f.containsKey('separator')
            ? '${_e(f['list']!)}.join(${_e(f['separator']!)})'
            : '${_e(f['list']!)}.join()',
      // Map operations
      'map_get' => '${_e(f['map']!)}[${_e(f['key']!)}]',
      'map_set' => '(${_e(f['map']!)}[${_e(f['key']!)}] = ${_e(f['value']!)})',
      'map_put_if_absent' =>
        '${_e(f['map']!)}.putIfAbsent(${_e(f['key']!)}, ${_e(f['value']!)})',
      'map_delete' => '${_e(f['map']!)}.remove(${_e(f['key']!)})',
      'map_contains_key' => '${_e(f['map']!)}.containsKey(${_e(f['key']!)})',
      'map_keys' => '${_e(f['map']!)}.keys.toList()',
      'map_values' => '${_e(f['map']!)}.values.toList()',
      'map_entries' => '${_e(f['map']!)}.entries.toList()',
      'map_is_empty' => '${_e(f['map']!)}.isEmpty',
      'map_length' => '${_e(f['map']!)}.length',
      // Set operations
      'set_add' => '${_e(f['set']!)}..add(${_e(f['value']!)})',
      'set_remove' => '${_e(f['set']!)}.remove(${_e(f['value']!)})',
      'set_contains' => '${_e(f['set']!)}.contains(${_e(f['value']!)})',
      'set_union' => '${_e(f['left']!)}.union(${_e(f['right']!)})',
      'set_intersection' =>
        '${_e(f['left']!)}.intersection(${_e(f['right']!)})',
      'set_difference' => '${_e(f['left']!)}.difference(${_e(f['right']!)})',
      'set_length' => '${_e(f['set']!)}.length',
      'set_is_empty' => '${_e(f['set']!)}.isEmpty',
      'set_to_list' => '${_e(f['set']!)}.toList()',
      _ => '/* unsupported: std_collections.${call.function} */',
    };
  }

  // ── std_io compilation ────────────────────────────────────

  String _compileIoCall(FunctionCall call) {
    final f = _extractFields(call);
    return switch (call.function) {
      'print_error' => "stderr.writeln(${_e(f['message']!)})",
      'read_line' => 'stdin.readLineSync() ?? ""',
      'exit' => 'exit(${_e(f['code']!)})',
      'panic' => '(stderr.writeln(${_e(f['message']!)}), exit(1))',
      'sleep_ms' =>
        'Future.delayed(Duration(milliseconds: ${_e(f['milliseconds']!)}))',
      'timestamp_ms' => 'DateTime.now().millisecondsSinceEpoch',
      'random_int' =>
        '(Random().nextInt(${_e(f['max']!)} - ${_e(f['min']!)}) + ${_e(f['min']!)})',
      'random_double' => 'Random().nextDouble()',
      'env_get' => 'Platform.environment[${_e(f['name']!)}] ?? ""',
      'args_get' => '[]',
      _ => '/* unsupported: std_io.${call.function} */',
    };
  }

  // ── std_convert compilation ────────────────────────────────

  String _compileConvertCall(FunctionCall call) {
    final f = _extractFields(call);
    return switch (call.function) {
      'json_encode' => 'jsonEncode(${_e(f['value']!)})',
      'json_decode' => 'jsonDecode(${_e(f['source'] ?? f['value']!)})',
      'utf8_encode' => 'utf8.encode(${_e(f['source'] ?? f['value']!)})',
      'utf8_decode' => 'utf8.decode(${_e(f['bytes'] ?? f['value']!)})',
      // Member form (base64.encode/decode), consistent with utf8 above and
      // symmetric with the encoder (which reads `base64.encode` but not the
      // top-level `base64Encode`) so the compiled Dart round-trips.
      'base64_encode' => 'base64.encode(${_e(f['bytes'] ?? f['value']!)})',
      'base64_decode' => 'base64.decode(${_e(f['source'] ?? f['value']!)})',
      _ => '/* unsupported: std_convert.${call.function} */',
    };
  }

  // ── std_fs compilation ─────────────────────────────────────

  String _compileFsCall(FunctionCall call) {
    final f = _extractFields(call);
    return switch (call.function) {
      'file_read' => 'File(${_e(f['path']!)}).readAsStringSync()',
      'file_read_bytes' => 'File(${_e(f['path']!)}).readAsBytesSync()',
      'file_write' =>
        'File(${_e(f['path']!)}).writeAsStringSync(${_e(f['content']!)})',
      'file_write_bytes' =>
        'File(${_e(f['path']!)}).writeAsBytesSync(${_e(f['content']!)})',
      'file_append' =>
        'File(${_e(f['path']!)}).writeAsStringSync(${_e(f['content']!)}, mode: FileMode.append)',
      'file_exists' => 'File(${_e(f['path']!)}).existsSync()',
      'file_delete' => 'File(${_e(f['path']!)}).deleteSync()',
      'dir_list' =>
        'Directory(${_e(f['path']!)}).listSync().map((e) => e.path).toList()',
      'dir_create' =>
        'Directory(${_e(f['path']!)}).createSync(recursive: true)',
      'dir_exists' => 'Directory(${_e(f['path']!)}).existsSync()',
      _ => '/* unsupported: std_fs.${call.function} */',
    };
  }

  // ── std_time compilation ───────────────────────────────────

  String _compileTimeCall(FunctionCall call) {
    final f = _extractFields(call);
    return switch (call.function) {
      'now' => 'DateTime.now().millisecondsSinceEpoch',
      'now_micros' => 'DateTime.now().microsecondsSinceEpoch',
      'format_timestamp' =>
        'DateTime.fromMillisecondsSinceEpoch(${_e(f['timestamp'] ?? f['timestamp_ms'] ?? f['value']!)}, isUtc: true).toIso8601String()',
      'parse_timestamp' =>
        'DateTime.parse(${_e(f['source'] ?? f['value']!)}).millisecondsSinceEpoch',
      'duration_add' => '(${_e(f['left']!)} + ${_e(f['right']!)})',
      'duration_subtract' => '(${_e(f['left']!)} - ${_e(f['right']!)})',
      'year' => 'DateTime.now().year',
      'month' => 'DateTime.now().month',
      'day' => 'DateTime.now().day',
      'hour' => 'DateTime.now().hour',
      'minute' => 'DateTime.now().minute',
      'second' => 'DateTime.now().second',
      _ => '/* unsupported: std_time.${call.function} */',
    };
  }

  // ── Compact expression helpers ───────────────────────────────

  String _compileBasePrint(Map<String, Expression> f) {
    final msg = f['message'];
    return msg != null ? 'print(${_e(msg)})' : 'print()';
  }

  String _binOp(Map<String, Expression> f, String op) {
    final l = f['left'], r = f['right'];
    if (l == null || r == null) return '/* invalid $op */';
    final le = _compileExpression(l), re = _compileExpression(r);
    final expr = switch (op) {
      '+' => le.operatorAdd(re),
      '-' => le.operatorSubtract(re),
      '*' => le.operatorMultiply(re),
      '/' => le.operatorDivide(re),
      '~/' => le.operatorIntDivide(re),
      '%' => le.operatorEuclideanModulo(re),
      '==' => le.equalTo(re),
      '!=' => le.notEqualTo(re),
      '<' => le.lessThan(re),
      '>' => le.greaterThan(re),
      '<=' => le.lessOrEqualTo(re),
      '>=' => le.greaterOrEqualTo(re),
      '&&' => le.and(re),
      '||' => le.or(re),
      '&' => le.operatorBitwiseAnd(re),
      '|' => le.operatorBitwiseOr(re),
      '^' => le.operatorBitwiseXor(re),
      '<<' => le.operatorShiftLeft(re),
      '>>' => le.operatorShiftRight(re),
      '>>>' => le.operatorShiftRightUnsigned(re),
      '??' => le.ifNullThen(re),
      // Unreachable: _binOp is only ever invoked with the operator literals
      // cased above (from the _compileBaseCall dispatch table).
      _ => _raw('(${_emit(le)} $op ${_emit(re)})'), // coverage:ignore-line
    };
    return _emit(expr.parenthesized);
  }

  String _prefixOp(Map<String, Expression> f, String op) {
    final v = f['value'];
    if (v == null) return '/* invalid $op */';
    // Stacked unary minus / bitwise complement / logical-not render as
    // `--5` / `~~5` / `!!5` which Dart misparses as pre-decrement etc.
    // Wrap the operand in parens when its rendering starts with the
    // same operator character.
    final inner = _e(v);
    final needsParen =
        inner.isNotEmpty &&
        ((op == '-' && inner.startsWith('-')) ||
            (op == '!' && inner.startsWith('!')) ||
            (op == '~' && inner.startsWith('~')));
    if (needsParen) {
      return '$op($inner)';
    }
    final ve = _compileExpression(v);
    final expr = switch (op) {
      '-' => ve.operatorUnaryMinus(),
      '!' => ve.negate(),
      '~' => ve.operatorUnaryBitwiseComplement(),
      // Unreachable: _prefixOp is only called with '-' / '!' / '~'.
      _ => _raw('($op${_emit(ve)})'), // coverage:ignore-line
    };
    return _emit(expr);
  }

  String _prefixMut(Map<String, Expression> f, String op) {
    final v = f['value'];
    if (v == null) return '/* invalid $op */';
    final ve = _compileExpression(v);
    final expr = switch (op) {
      '++' => ve.operatorUnaryPrefixIncrement(),
      '--' => ve.operatorUnaryPrefixDecrement(),
      // Unreachable: _prefixMut is only called with '++' / '--'.
      _ => _raw('($op${_emit(ve)})'), // coverage:ignore-line
    };
    return _emit(expr);
  }

  String _postfixMut(Map<String, Expression> f, String op) {
    final v = f['value'];
    if (v == null) return '/* invalid $op */';
    final ve = _compileExpression(v);
    final expr = switch (op) {
      '++' => ve.operatorUnaryPostfixIncrement(),
      '--' => ve.operatorUnaryPostfixDecrement(),
      '!' => ve.nullChecked,
      // Unreachable: _postfixMut is only called with '++' / '--' / '!'.
      _ => _raw('(${_emit(ve)}$op)'), // coverage:ignore-line
    };
    return _emit(expr);
  }

  String _awaitExpr(Map<String, Expression> f) {
    final v = f['value'];
    if (v == null) return 'await null';
    // Set flag to suppress auto-await inside this explicit await expression.
    final saved = _insideExplicitAwait;
    _insideExplicitAwait = true;
    _needsAsync = true;
    final result = _emit(_compileExpression(v).awaited);
    _insideExplicitAwait = saved;
    return result;
  }

  String _throwExpr(Map<String, Expression> f) {
    final v = f['value'];
    if (v == null) return '(throw null)';
    final valStr = _compileThrowValue(v);
    // Bug fix: wrap throw-expression in parentheses so it's valid in
    // expression positions (e.g. `x ?? (throw Error())`). Dart's grammar
    // requires parens around `throw` when used as a sub-expression.
    if (valStr != null) return '(throw $valStr)';
    // code_builder's `.thrown` emits `throw expr` without parens, so we
    // must wrap the result ourselves.
    return '(${_emit(_compileExpression(v).thrown)})';
  }

  /// If [v] is an empty-typeName messageCreation, render it as a Dart
  /// map literal so `throw` / catch dispatch can read the `__type` field.
  /// The default messageCreation path emits it as an inline arg list
  /// (`__type: 'NotFound'`), which is illegal after `throw`.
  ///
  /// Returns `null` when no special handling is needed — the caller
  /// should fall back to its default expression compilation.
  String? _compileThrowValue(Expression v) {
    if (v.whichExpr() != Expression_Expr.messageCreation) return null;
    if (v.messageCreation.typeName.isNotEmpty) return null;
    final entries = <String>[];
    for (final field in v.messageCreation.fields) {
      entries.add("'${field.name}': ${_e(field.value)}");
    }
    return '{${entries.join(', ')}}';
  }

  String _compileSpread(Map<String, Expression> f, String op) {
    final v = f['value'];
    if (v == null) return '${op}null';
    final ve = _compileExpression(v);
    return op == '...?' ? _emit(ve.nullSafeSpread) : _emit(ve.spread);
  }

  /// Emits `.toString()`, but avoids the invalid `TypeName.toString()` form
  /// for type-literal references by using `'$TypeName'` interpolation instead.
  String _compileToString(Map<String, Expression> f) {
    final v = f['value'];
    if (v == null) return '/* invalid .toString */';
    // When the value is a simple reference (e.g. FeatureFlagsIntegration as a
    // Type), emit string-interpolation form `'$TypeName'` rather than
    // `TypeName.toString()` which the Dart analyzer rejects as a missing static
    // method.
    if (v.whichExpr() == Expression_Expr.reference) {
      final name = v.reference.name;
      if (name.isNotEmpty && name[0] == name[0].toUpperCase()) {
        // Use `'\$TypeName'` string interpolation which Dart evaluates via
        // `Type.toString()` and avoids the static-method error.
        return "'\$$name'";
      }
    }
    // Receivers of `.toString()` must bind tighter than method call.
    // `!f.toString()` parses as `!(f.toString())`, not `(!f).toString()`.
    // std calls to unary/binary operators render as prefix / infix
    // strings, which need explicit parens to bind correctly.
    final inner = _e(v);
    return _needsParensAsReceiver(v, inner)
        ? '($inner).toString()'
        : '$inner.toString()';
  }

  /// Returns true if emitting `$inner.method()` would misparse because
  /// the inner expression's rendering starts with an operator (prefix
  /// `!`/`-`/`~`) or contains unparenthesized infix operators.
  bool _needsParensAsReceiver(Expression v, String inner) {
    if (inner.isEmpty) return false;
    // Prefix operators.
    final first = inner.codeUnitAt(0);
    if (first == 0x21 /* ! */ ||
        first == 0x7E /* ~ */ ||
        first == 0x2D /* - */ ) {
      return true;
    }
    // Binary op calls via std render as infix (`a + b`, `a == b`, etc.)
    // without outer parens. Detect by checking if the value is one of
    // those std calls.
    if (v.whichExpr() == Expression_Expr.call) {
      const infixOps = {
        'add',
        'subtract',
        'multiply',
        'divide',
        'divide_double',
        'modulo',
        'equals',
        'not_equals',
        'less_than',
        'greater_than',
        'lte',
        'gte',
        'and',
        'or',
        'bitwise_and',
        'bitwise_or',
        'bitwise_xor',
        'left_shift',
        'right_shift',
        'unsigned_right_shift',
        'null_coalesce',
      };
      const prefixOps = {
        'not',
        'negate',
        'bitwise_not',
        'pre_increment',
        'pre_decrement',
      };
      // Postfix operators also misparse when used as a method receiver:
      // `i++.toString()` is invalid Dart (the `.toString()` never binds).
      // Wrap the whole expression in parens: `(i++).toString()`.
      const postfixOps = {'post_increment', 'post_decrement'};
      final fn = v.call.function;
      if (infixOps.contains(fn) ||
          prefixOps.contains(fn) ||
          postfixOps.contains(fn)) {
        return true;
      }
    }
    return false;
  }

  /// Renders [v] as a method-call receiver, parenthesizing when its emitted
  /// form would otherwise misparse — a prefix/infix/postfix operator binds
  /// looser than `.method()`, so `-3.clamp(0,10)` is `-(3.clamp(0,10))` not
  /// `(-3).clamp(0,10)`. Use this anywhere a receiver is emitted via raw
  /// string interpolation (`${_recv(v)}.foo(...)`) instead of code_builder's
  /// `.property().call()` (which never needs it). Mirrors [_methodCallExpr].
  String _recv(Expression v) {
    final inner = _e(v);
    return _needsParensAsReceiver(v, inner) ? '($inner)' : inner;
  }

  String _methodCallExpr(Map<String, Expression> f, String method) {
    final v = f['value'];
    if (v == null) return '/* invalid .$method */';
    // method may include trailing () — strip it for code_builder
    final name = method.endsWith('()')
        ? method.substring(0, method.length - 2)
        : method;
    // Receivers of `.method()` must bind tighter than method call.
    // `-n.abs()` parses as `-(n.abs())`, not `(-n).abs()`. Wrap unary
    // / infix operands in parens (same logic as `_compileToString`).
    final inner = _e(v);
    if (_needsParensAsReceiver(v, inner)) {
      return '($inner).$name()';
    }
    return _emit(_compileExpression(v).property(name).call([]));
  }

  String _propertyAccess(Map<String, Expression> f, String prop) {
    final v = f['value'];
    if (v == null) return '/* invalid .$prop */';
    // Parenthesize an operator receiver: `(-3.14).isFinite`, not
    // `-3.14.isFinite` (which parses as `-(3.14.isFinite)`).
    return '${_recv(v)}.$prop';
  }

  String _staticCallExpr(Map<String, Expression> f, String method) {
    final v = f['value'];
    if (v == null) return '/* invalid $method() */';
    return _emit(cb.refer(method).call([_compileExpression(v)]));
  }

  String _methodCall2(Map<String, Expression> f, String method) {
    // Encoder produces several field-name conventions for two-arg method
    // calls. Tolerate all of them so the compiler doesn't drop method
    // calls into invalid placeholders during round-trip.
    final l = f['left'] ?? f['target'] ?? f['value'] ?? f['receiver'];
    final r =
        f['right'] ??
        f['index'] ??
        f['pattern'] ??
        f['separator'] ??
        f['from'] ??
        f['digits'] ??
        f['arg'] ??
        f['other'] ??
        f['arg0'];
    if (l == null || r == null) return '/* invalid $method() */';
    return _emit(
      _compileExpression(l).property(method).call([_compileExpression(r)]),
    );
  }

  String _typeOp(Map<String, Expression> f, String op) {
    final v = f['value'], t = _stringFieldValue(f, 'type');
    if (v == null || t == null) return '/* invalid $op */';
    final ve = _compileExpression(v);
    final te = cb.refer(t);
    final expr = switch (op) {
      'is' => ve.isA(te),
      'is!' => ve.isNotA(te),
      'as' => ve.asA(te),
      // Unreachable: _typeOp is only called with 'is' / 'is!' / 'as'.
      _ => _raw('(${_emit(ve)} $op $t)'), // coverage:ignore-line
    };
    return _emit(expr.parenthesized);
  }

  String _mathFunc(Map<String, Expression> f, String func) {
    final v = f['value'];
    if (v == null) return '/* invalid $func */';
    return _emit(cb.refer(func).call([_compileExpression(v)]));
  }

  String _mathBinary(Map<String, Expression> f, String func) {
    final l = f['left'], r = f['right'];
    if (l == null || r == null) return '/* invalid $func */';
    return _emit(
      cb.refer(func).call([_compileExpression(l), _compileExpression(r)]),
    );
  }

  /// Compile std.assign(target, value) / std.assign(target, op, value).
  ///
  /// The target may be:
  ///  * A reference: `x`
  ///  * A fieldAccess: `obj.field`
  ///  * A call (index): `arr[i]`       <- also used for __cascade_self__
  ///
  /// When the target is a reference named `__cascade_self__` (from a cascade
  /// section like `..field = 1`) we emit just `field = 1` so that the outer
  /// `..` prefix supplied by [_compileCascade] produces `..field = 1`.
  String _compileAssign(Map<String, Expression> f) {
    final target = f['target'];
    final value = f['value'];
    final op = _stringFieldValue(f, 'op') ?? '=';
    if (target == null || value == null) return '/* invalid assign */';

    // Encoder wraps mutating list/map ops (list_push, list_clear, ...) in
    // assign(target=x, value=op(list=x, ...)) so non-mutating runtimes can
    // hold the new collection. Dart's List.add() / .clear() / .sort() / ...
    // already mutate in place, so emit just the cascade and skip the
    // re-binding (which would also fail when `x` was declared `final`).
    if (op == '=' &&
        target.whichExpr() == Expression_Expr.reference &&
        value.whichExpr() == Expression_Expr.call) {
      final inner = value.call;
      // Methods that mutate the receiver in place in Dart, so the encoder's
      // wrap-in-assign(target=x, value=op(list=x, ...)) can be elided. Only
      // list_concat / list_remove_at create or return new structures, so
      // those are deliberately NOT elided here.
      const inPlaceMutations = <(String, String)>{
        ('std_collections', 'list_push'),
        ('std_collections', 'list_clear'),
        ('std_collections', 'list_sort'),
        ('std_collections', 'list_insert'),
      };
      if (inPlaceMutations.contains((inner.module, inner.function))) {
        final innerFields = _extractFields(inner);
        final mutated = innerFields['list'];
        if (mutated != null &&
            mutated.whichExpr() == Expression_Expr.reference &&
            mutated.reference.name == target.reference.name) {
          return _e(value);
        }
      }
    }

    final targetStr = _compileCascadeAwareTarget(target);
    final ve = _compileExpression(value);
    final te = _raw(targetStr);
    final expr = switch (op) {
      '=' => te.assign(ve),
      '+=' => te.addAssign(ve),
      '-=' => te.subtractAssign(ve),
      '*=' => te.multiplyAssign(ve),
      '/=' => te.divideAssign(ve),
      '~/=' => te.intDivideAssign(ve),
      '%=' => te.euclideanModuloAssign(ve),
      '&=' => te.bitwiseAndAssign(ve),
      '|=' => te.bitwiseOrAssign(ve),
      '^=' => te.bitwiseXorAssign(ve),
      '<<=' => te.shiftLeftAssign(ve),
      '>>=' => te.shiftRightAssign(ve),
      '>>>=' => te.shiftRightUnsignedAssign(ve),
      '??=' => te.assignNullAware(ve),
      // Unreachable: every compound-assignment operator the encoder/IR can
      // produce is cased above (see _generateAssign / the assign dispatch).
      _ => _raw('$targetStr $op ${_emit(ve)}'), // coverage:ignore-line
    };
    return _emit(expr);
  }

  /// Compile a target expression, stripping the `__cascade_self__.` prefix
  /// that is emitted by the encoder for cascade property-access sections.
  ///
  /// `__cascade_self__.field`  →  `field`
  /// `__cascade_self__[i]`     →  `[i]` (rare, handled separately)
  /// anything else             →  normal compile
  ///
  /// The strip ONLY applies inside true `..` cascade emission
  /// ([_inCascadeCompilation], set by [_compileCascade]). When a cascade is
  /// instead lowered to a Block — `{ let __cascade_self__ = target; …; result }`
  /// (the encoder's [_encodeCascade] path) — `__cascade_self__` is a *real*
  /// local variable, so `__cascade_self__.field = v` must stay intact rather
  /// than collapse to a bare `field = v` (which would dangle, e.g. the
  /// `Expression()..call = loopCall` cascade in the engine). Mirrors the same
  /// `_inCascadeCompilation` guard in [_compileFieldAccess].
  String _compileCascadeAwareTarget(Expression target) {
    if (_inCascadeCompilation &&
        target.whichExpr() == Expression_Expr.fieldAccess) {
      final fa = target.fieldAccess;
      if (fa.object.whichExpr() == Expression_Expr.reference &&
          fa.object.reference.name == '__cascade_self__') {
        return fa.field_2; // just the field name for cascade
      }
    }
    return _e(target);
  }

  String _compileNullAwareAccess(Map<String, Expression> f) {
    final t = f['target'], field = _stringFieldValue(f, 'field');
    if (t == null || field == null) return '/* invalid ?. */';
    return _emit(_compileExpression(t).nullSafeProperty(field));
  }

  String _compileNullAwareCall(FunctionCall call) {
    final all = _extractFields(call);
    final t = all['target'], method = _stringFieldValue(all, 'method');
    if (t == null || method == null) return '/* invalid ?. call */';
    final typeArgs = _stringFieldValue(all, '__type_args__') ?? '';
    final args = call.input.messageCreation.fields
        .where(
          (f) =>
              f.name != 'target' &&
              f.name != 'method' &&
              f.name != '__type_args__',
        )
        .toList();
    return '${_e(t)}?.$method$typeArgs(${_compileArgs(args)})';
  }

  String _compileInlineIf(Map<String, Expression> f) {
    final c = f['condition'], t = f['then'], e = f['else'];
    if (c == null || t == null) return '/* invalid inline if */';
    final ce = _compileExpression(c);
    // `e is SomeClass ? e.member : ...` promotes `e` in the then-branch only,
    // mirroring [_generateIf]; suppress the catch-var map-subscript rewrite
    // there so member access stays dotted.
    final te = _withCatchVarPromoted(
      _isPromotedCatchVar(c),
      () => _compileExpression(t),
    );
    // The `else` arm of `X == null ? null : …` knows `X` is non-null — the
    // lowered form of a `X?.call()` null-aware call on a (non-promotable)
    // field. Mark `X` non-null there so its receiver emits `X!`.
    final ee = e != null
        ? _withNonNullRef(_nullEqualityGuardRef(c), () => _compileExpression(e))
        : cb.literalNull;
    return _emit(ce.conditional(te, ee).parenthesized);
  }

  String _compileIndex(Map<String, Expression> f) {
    final t = f['target'], i = f['index'];
    if (t == null || i == null) return '/* invalid [] */';
    return _emit(_compileExpression(t).index(_compileExpression(i)));
  }

  String _compileNullAwareIndex(Map<String, Expression> f) {
    final t = f['target'], i = f['index'];
    return t != null && i != null ? '${_e(t)}?[${_e(i)}]' : '/* invalid ?[] */';
  }

  String _compileCascade(Map<String, Expression> f) {
    final t = f['target'];
    if (t == null) return '/* invalid cascade */';
    final buf = StringBuffer(_e(t));
    final nullAware = _boolFieldValue(f, 'null_aware');
    final sections = f['sections'];
    final savedCascade = _inCascadeCompilation;
    _inCascadeCompilation = true;
    if (sections != null &&
        sections.whichExpr() == Expression_Expr.literal &&
        sections.literal.whichValue() == Literal_Value.listValue) {
      var isFirst = true;
      for (final s in sections.literal.listValue.elements) {
        final prefix = (nullAware && isFirst) ? '?..' : '..';
        isFirst = false;
        final raw = _e(s);
        final section = _stripCascadeSelf(raw);
        buf.write('$prefix$section');
      }
    }
    _inCascadeCompilation = savedCascade;
    return '(${buf.toString()})';
  }

  /// Strips a leading `__cascade_self__` sentinel from a compiled cascade
  /// section string.  The encoder emits this sentinel so that the decoder can
  /// restore `..member` syntax.
  static String _stripCascadeSelf(String s) {
    const sentinel = '__cascade_self__';
    if (!s.startsWith(sentinel)) return s;
    var i = sentinel.length;
    // Skip any whitespace inserted by code_builder between the sentinel
    // and the following `.`/`[`/`?.`/`?[` operator.
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
    if (i >= s.length) return s;
    final ch = s[i];
    if (ch == '.') return s.substring(i + 1);
    if (ch == '[') return s.substring(i);
    if (ch == '?' && i + 1 < s.length) {
      final next = s[i + 1];
      if (next == '.' || next == '[') return s.substring(i);
    }
    return s;
  }

  String _compileTearOff(Map<String, Expression> f) {
    final target = f['target'];
    final method = _stringFieldValue(f, 'method') ?? '';
    if (target != null) {
      final targetStr = _e(target);
      return '$targetStr.$method';
    }
    // Static / constructor tear-off: just the method name
    return method;
  }

  String _compileInvoke(FunctionCall call) {
    final all = _extractFields(call);
    final callee = all['callee'];
    if (callee == null) return '/* invalid invoke */';
    final args = call.input.messageCreation.fields
        .where((f) => f.name != 'callee')
        .toList();
    return '${_e(callee)}(${_compileArgs(args)})';
  }

  String _compileMapCreate(FunctionCall call) {
    final allFields =
        call.hasInput() &&
            call.input.whichExpr() == Expression_Expr.messageCreation
        ? call.input.messageCreation.fields
        : <FieldValuePair>[];
    // Extract optional type args field (not a real entry).
    final typeArgsField = allFields
        .where((f) => f.name == 'type_args')
        .firstOrNull;
    final typeArgs = typeArgsField != null
        ? '<${typeArgsField.value.literal.stringValue}>'
        : '';
    final entries = allFields
        .where((f) => f.name != 'type_args' && f.name != 'elements')
        .toList();
    if (entries.isEmpty) return '$typeArgs{}';
    final buf = StringBuffer('$typeArgs{');
    var first = true;
    for (final field in entries) {
      if (!first) buf.write(', ');
      first = false;
      if (field.name == 'entry' &&
          field.value.whichExpr() == Expression_Expr.messageCreation) {
        final ef = _fieldsToMap(field.value.messageCreation.fields);
        final k = ef['key'], v = ef['value'];
        if (k != null && v != null) {
          buf.write('${_e(k)}: ${_e(v)}');
        }
      } else {
        buf.write(_e(field.value));
      }
    }
    buf.write('}');
    return buf.toString();
  }

  String _compileSetCreate(Map<String, Expression> f) {
    final typeArgs = _stringFieldValue(f, 'type_args');
    final typePrefix = typeArgs != null ? '<$typeArgs>' : '';
    final elements = f['elements'];
    if (elements == null) {
      // No type args and no elements: emit bare `{}` and let Dart infer.
      return typePrefix.isEmpty
          ? '{}'
          : typePrefix == 'Set<dynamic>' ||
                typePrefix == 'Map<dynamic, dynamic>'
          ? '{}'
          : '$typePrefix{}';
    }
    if (elements.whichExpr() == Expression_Expr.literal &&
        elements.literal.whichValue() == Literal_Value.listValue) {
      final items = elements.literal.listValue.elements.map(_e).join(', ');
      if (items.isEmpty) {
        return typePrefix.isEmpty
            ? '{}'
            : typePrefix == 'Set<dynamic>' ||
                  typePrefix == 'Map<dynamic, dynamic>'
            ? '{}'
            : '$typePrefix{}';
      }
      return '$typePrefix{$items}';
    }
    return typePrefix.isEmpty
        ? '{}'
        : typePrefix == 'Set<dynamic>' || typePrefix == 'Map<dynamic, dynamic>'
        ? '{}'
        : '$typePrefix{}';
  }

  String _compileTypedList(Map<String, Expression> f) {
    final typeArgs = _stringFieldValue(f, 'type_args') ?? '';
    final elements = f['elements'];
    if (elements != null &&
        elements.whichExpr() == Expression_Expr.literal &&
        elements.literal.whichValue() == Literal_Value.listValue) {
      return '$typeArgs[${elements.literal.listValue.elements.map(_e).join(', ')}]';
    }
    return '$typeArgs[]';
  }

  String _compileRecord(FunctionCall call) {
    final allFields =
        call.hasInput() &&
            call.input.whichExpr() == Expression_Expr.messageCreation
        ? call.input.messageCreation.fields
        : <FieldValuePair>[];
    if (allFields.isEmpty) return '()';

    // Format 1 (encoder.dart _encodeRecordLiteral): fields are flat on the
    // MessageCreation input. Positional fields use names `$0`, `$1`, ...;
    // named fields use the literal name. This is what the Dart encoder
    // currently produces.
    final isFlatRecord = allFields.every((f) {
      final n = f.name;
      return n == r'$0' ||
          n == r'$1' ||
          n == r'$2' ||
          n == r'$3' ||
          n == r'$4' ||
          n == r'$5' ||
          n == r'$6' ||
          n == r'$7' ||
          RegExp(r'^\$\d+$').hasMatch(n) ||
          (n.isNotEmpty && !n.startsWith(r'$'));
    });
    if (isFlatRecord && !allFields.any((f) => f.name == 'fields')) {
      final positionalPattern = RegExp(r'^\$\d+$');
      final positional = <({int i, Expression v})>[];
      final named = <({String k, Expression v})>[];
      for (final f in allFields) {
        if (positionalPattern.hasMatch(f.name)) {
          positional.add((i: int.parse(f.name.substring(1)), v: f.value));
        } else {
          named.add((k: f.name, v: f.value));
        }
      }
      positional.sort((a, b) => a.i.compareTo(b.i));
      final parts = <String>[];
      for (final p in positional) {
        parts.add(_e(p.v));
      }
      for (final n in named) {
        parts.add('${n.k}: ${_e(n.v)}');
      }
      // Dart requires a trailing comma for single-positional records to
      // disambiguate from a parenthesized expression, e.g. `(x,)`.
      if (positional.length == 1 && named.isEmpty) {
        return '(${parts.first},)';
      }
      return '(${parts.join(', ')})';
    }

    // Format 2 (legacy): wrapped under a single `fields` list.
    final fieldsValue = allFields
        .firstWhere((f) => f.name == 'fields', orElse: FieldValuePair.new)
        .value;
    if (fieldsValue.whichExpr() == Expression_Expr.literal &&
        fieldsValue.literal.whichValue() == Literal_Value.listValue) {
      final parts = <String>[];
      for (final entry in fieldsValue.literal.listValue.elements) {
        if (entry.whichExpr() != Expression_Expr.messageCreation) continue;
        final ef = _fieldsToMap(entry.messageCreation.fields);
        final nameExpr = entry.messageCreation.fields
            .firstWhere((f) => f.name == 'name', orElse: FieldValuePair.new)
            .value;
        final val = ef['value'];
        if (nameExpr.whichExpr() != Expression_Expr.notSet && val != null) {
          final nameStr = _compileLiteralValue(nameExpr);
          parts.add(
            nameStr.startsWith('arg') ? _e(val) : '$nameStr: ${_e(val)}',
          );
        }
      }
      return '(${parts.join(', ')})';
    }
    return '()';
  }

  String _compileCollectionIf(Map<String, Expression> f) {
    final c = f['condition'], t = f['then'], e = f['else'];
    if (c == null || t == null) return '/* invalid collection if */';
    final buf = StringBuffer('if (${_e(c)}) ${_e(t)}');
    if (e != null) buf.write(' else ${_e(e)}');
    return buf.toString();
  }

  String _compileCollectionFor(Map<String, Expression> f) {
    final body = f['body'];
    if (body == null) return '/* invalid collection for */';
    // For-each form: `for (variable in iterable) body`.
    final iterable = f['iterable'];
    if (iterable != null) {
      final variable = _stringFieldValue(f, 'variable') ?? 'item';
      return 'for (final $variable in ${_e(iterable)}) ${_e(body)}';
    }
    // C-style form: `for (init; condition; update) body`. The encoder sends
    // `init` as a block of let-declarations (current) or, historically, a raw
    // string. Render the block INLINE as `var i = 0` via _renderForInit — NOT
    // through _e(), which would lower the block to an IIFE `(() {var i=0;})()`
    // whose `i` is out of scope in the condition/update (issue #55).
    final initField = f['init'];
    final cond = f['condition'];
    final update = f['update'];
    if (initField != null || cond != null || update != null) {
      final initStr =
          _stringFieldValue(f, 'init') ??
          (initField != null
              ? (_renderForInit(initField) ?? _e(initField))
              : '');
      final condStr = cond != null ? _e(cond) : '';
      final updStr = update != null ? _e(update) : '';
      return 'for ($initStr; $condStr; $updStr) ${_e(body)}';
    }
    return '/* invalid collection for */';
  }

  String _compileSwitchExpr(Map<String, Expression> f) {
    final subject = f['subject'];
    if (subject == null) return '/* invalid switch expr */';
    final buf = StringBuffer('switch (${_e(subject)}) {\n');
    final cases = f['cases'];
    var hasDefault = false;
    if (cases != null &&
        cases.whichExpr() == Expression_Expr.literal &&
        cases.literal.whichValue() == Literal_Value.listValue) {
      for (final c in cases.literal.listValue.elements) {
        if (c.whichExpr() != Expression_Expr.messageCreation) continue;
        final cf = _fieldsToMap(c.messageCreation.fields);
        final body = cf['body'];
        if (body == null) continue;
        final isDefault = _boolFieldValue(cf, 'is_default');
        if (isDefault) {
          buf.write('_ => ${_e(body)},\n');
          hasDefault = true;
          continue;
        }
        // Prefer the SEMANTIC pattern (`pattern_expr`) and append the guard
        // separately; fall back to the cosmetic string only when a pattern
        // can't be transcribed. The cosmetic switch-expr label already bakes in
        // any `when` clause, so don't double-append the guard there.
        final guard = cf['guard'];
        var label = cf['pattern_expr'] != null
            ? _compilePatternExpr(cf['pattern_expr']!)
            : null;
        var labelHasGuard = false;
        if (label == null) {
          final cosmetic = _stringFieldValue(cf, 'pattern');
          if (cosmetic != null) {
            label = cosmetic;
            labelHasGuard = cosmetic.contains(' when ');
          }
        }
        if (label == null && cf['value'] != null) {
          buf.write('${_e(cf['value']!)} => ${_e(body)},\n');
          continue;
        }
        if (label == null) continue;
        final guardStr = (guard != null && !labelHasGuard)
            ? ' when ${_e(guard)}'
            : '';
        // A bare `_` is the catch-all only when it has no guard.
        if (label == '_' && guard == null && !labelHasGuard) hasDefault = true;
        buf.write('$label$guardStr => ${_e(body)},\n');
      }
    }
    // Ensure exhaustiveness for Dart null-safety (only when cases exist)
    if (!hasDefault && buf.length > 20)
      buf.write("_ => throw StateError('non-exhaustive'),\n");
    buf.write('}');
    return buf.toString();
  }

  /// Compile a structured pattern (`pattern_expr`) to native Dart pattern
  /// syntax. The pattern kind is the MessageCreation `typeName` the encoder
  /// sets (`VarPattern`, `RecordPattern`, …) — NOT a `__pattern_kind__` field
  /// (that field never existed; `_fieldsToMap` also drops `typeName`, so we read
  /// it straight off the MessageCreation). Dart natively supports every pattern
  /// form, so this is a direct syntactic transcription; arity/shape/null
  /// semantics are enforced by the Dart runtime. Returns null for shapes we
  /// can't transcribe, so the caller can fall back to the cosmetic string.
  String? _compilePatternExpr(Expression expr) {
    if (expr.whichExpr() != Expression_Expr.messageCreation) return null;
    final mc = expr.messageCreation;
    final fields = _fieldsToMap(mc.fields);
    String? sub(String key) {
      final p = fields[key];
      return p != null ? _compilePatternExpr(p) : null;
    }

    switch (mc.typeName) {
      case 'VarPattern':
        final name = _stringFieldValue(fields, 'name') ?? '_';
        final type = _stringFieldValue(fields, 'type');
        // `int x` / `int? x` keeps the (possibly nullable) type; bare `var x`.
        return type != null ? '$type $name' : 'var $name';
      case 'WildcardPattern':
        final type = _stringFieldValue(fields, 'type');
        return type != null ? '$type _' : '_';
      case 'ConstPattern':
        final value = fields['value'];
        return value != null ? _e(value) : 'null';
      case 'RecordPattern':
        return '(${_compilePatternFields(fields['fields']).join(', ')})';
      case 'ObjectPattern':
        final type = _stringFieldValue(fields, 'type') ?? 'Object';
        return '$type(${_compilePatternFields(fields['fields']).join(', ')})';
      case 'ListPattern':
        return '[${_compilePatternElements(fields['elements']).join(', ')}]';
      case 'MapPattern':
        final entries = <String>[];
        final list = fields['entries'];
        if (list != null &&
            list.whichExpr() == Expression_Expr.literal &&
            list.literal.whichValue() == Literal_Value.listValue) {
          for (final e in list.literal.listValue.elements) {
            if (e.whichExpr() != Expression_Expr.messageCreation) continue;
            final ef = _fieldsToMap(e.messageCreation.fields);
            final key = ef['key'];
            final valuePat = ef['value'];
            final valStr = valuePat != null
                ? _compilePatternExpr(valuePat)
                : null;
            if (key != null && valStr != null) {
              entries.add('${_e(key)}: $valStr');
            }
          }
        }
        return '{${entries.join(', ')}}';
      case 'NullCheckPattern':
        final s = sub('pattern');
        return s != null ? '$s?' : null;
      case 'NullAssertPattern':
        final s = sub('pattern');
        return s != null ? '$s!' : null;
      case 'CastPattern':
        final s = sub('pattern');
        final type = _stringFieldValue(fields, 'type') ?? 'Object';
        return s != null ? '$s as $type' : null;
      case 'LogicalAndPattern':
        final l = sub('left'), r = sub('right');
        return (l != null && r != null) ? '$l && $r' : null;
      case 'LogicalOrPattern':
        final l = sub('left'), r = sub('right');
        return (l != null && r != null) ? '$l || $r' : null;
      case 'RelationalPattern':
        final op = _stringFieldValue(fields, 'operator') ?? '==';
        final operand = fields['operand'];
        return operand != null ? '$op ${_e(operand)}' : null;
      case 'RestPattern':
        final s = sub('subpattern');
        return s != null ? '...$s' : '...';
      default:
        return null;
    }
  }

  /// Compile a list of record/object pattern fields (`{name?, pattern}`) to
  /// `name: subpattern` (named) or `subpattern` (positional) fragments.
  List<String> _compilePatternFields(Expression? fieldsList) {
    final parts = <String>[];
    if (fieldsList == null ||
        fieldsList.whichExpr() != Expression_Expr.literal ||
        fieldsList.literal.whichValue() != Literal_Value.listValue) {
      return parts;
    }
    for (final elem in fieldsList.literal.listValue.elements) {
      if (elem.whichExpr() != Expression_Expr.messageCreation) continue;
      final ef = _fieldsToMap(elem.messageCreation.fields);
      final name = _stringFieldValue(ef, 'name');
      final patternExpr = ef['pattern'];
      final subPattern = patternExpr != null
          ? _compilePatternExpr(patternExpr)
          : null;
      if (subPattern == null) continue;
      parts.add(
        name != null && name.isNotEmpty ? '$name: $subPattern' : subPattern,
      );
    }
    return parts;
  }

  /// Compile a list of list-pattern elements (each a pattern, incl. RestPattern).
  List<String> _compilePatternElements(Expression? elements) {
    final parts = <String>[];
    if (elements == null ||
        elements.whichExpr() != Expression_Expr.literal ||
        elements.literal.whichValue() != Literal_Value.listValue) {
      return parts;
    }
    for (final elem in elements.literal.listValue.elements) {
      final sub = _compilePatternExpr(elem);
      if (sub != null) parts.add(sub);
    }
    return parts;
  }

  String _compileSubstring(Map<String, Expression> f) {
    final v = f['value'], s = f['start'], e = f['end'];
    if (v == null || s == null) return '/* invalid substring */';
    final endStr = e != null ? ', ${_e(e)}' : '';
    return '${_recv(v)}.substring(${_e(s)}$endStr)';
  }

  String _compileStringCharCodeAt(Map<String, Expression> f) {
    final t = f['target'], i = f['index'];
    return t != null && i != null
        ? '${_recv(t)}.codeUnitAt(${_e(i)})'
        : '/* invalid codeUnitAt */';
  }

  String _compileStringReplace(Map<String, Expression> f, String method) {
    final v = f['value'], from = f['from'], to = f['to'];
    return v != null && from != null && to != null
        ? '${_recv(v)}.$method(${_e(from)}, ${_e(to)})'
        : '/* invalid $method */';
  }

  String _compileStringPad(Map<String, Expression> f, String method) {
    final v = f['value'], w = f['width'];
    // The encoder names the padding character `fill` (METADATA_SPEC) while
    // older fixtures use `padding`; accept either so the pad char isn't lost.
    final p = f['fill'] ?? f['padding'];
    if (v == null || w == null) return '/* invalid $method */';
    final padStr = p != null ? ', ${_e(p)}' : '';
    return '${_recv(v)}.$method(${_e(w)}$padStr)';
  }

  String _compileRegexMatch(Map<String, Expression> f) {
    final input = f['left'] ?? f['value'];
    final pattern = f['right'] ?? f['pattern'];
    return input != null && pattern != null
        ? 'RegExp(${_e(pattern)}).hasMatch(${_e(input)})'
        : '/* invalid regex_match */';
  }

  String _compileRegexFind(Map<String, Expression> f, {required bool all}) {
    final input = f['left'] ?? f['value'];
    final pattern = f['right'] ?? f['pattern'];
    if (input == null || pattern == null) return '/* invalid regex_find */';
    if (all) {
      return 'RegExp(${_e(pattern)})'
          '.allMatches(${_e(input)})'
          '.map((m) => m.group(0)!).toList()';
    }
    return 'RegExp(${_e(pattern)})'
        '.firstMatch(${_e(input)})?.group(0)';
  }

  String _compileRegexReplace(Map<String, Expression> f, String method) {
    final v = f['value'], from = f['from'], to = f['to'];
    return v != null && from != null && to != null
        ? '${_recv(v)}.$method(RegExp(${_e(from)}), ${_e(to)})'
        : '/* invalid regex $method */';
  }

  String _compileMathClamp(Map<String, Expression> f) {
    final v = f['value'], mn = f['min'], mx = f['max'];
    // When the encoder misroutes a user static method (e.g. MathUtils.clamp)
    // as math_clamp, 'value' is the class reference and the actual args are
    // in min/max/arg2. Detect this and emit a proper static method call.
    final arg2 = f['arg2'];
    if (v != null && mn != null && mx != null && arg2 != null) {
      return '${_recv(v)}.clamp(${_e(mn)}, ${_e(mx)}, ${_e(arg2)})';
    }
    return v != null && mn != null && mx != null
        ? '${_recv(v)}'
              '.clamp(${_e(mn)}, ${_e(mx)})'
        : '/* invalid clamp */';
  }

  String _compileMathLcm(Map<String, Expression> f) {
    final l = f['left'], r = f['right'];
    if (l == null || r == null) return '/* invalid lcm */';
    final ls = _e(l), rs = _e(r);
    return '(($ls * $rs).abs() ~/ $ls.gcd($rs))';
  }

  // ── Literals ─────────────────────────────────────────────────

  /// Escape a Dart string value and wrap it with single quotes so it can be
  /// safely emitted as source code. Handles all common control characters
  /// that a raw [cb.literalString] would not (e.g. `\r`, `\b`, `\f`, `\v`,
  /// `\x7f`) as well as backslash, single quote, `$`, and any other
  /// non-printable code units via `\x..` / `\u..`.
  String _dartStringLiteral(String s) {
    final sb = StringBuffer("'");
    for (var i = 0; i < s.length; i++) {
      final unit = s.codeUnitAt(i);
      switch (unit) {
        case 0x08:
          sb.write(r'\b');
          break;
        case 0x09:
          sb.write(r'\t');
          break;
        case 0x0a:
          sb.write(r'\n');
          break;
        case 0x0b:
          sb.write(r'\v');
          break;
        case 0x0c:
          sb.write(r'\f');
          break;
        case 0x0d:
          sb.write(r'\r');
          break;
        case 0x22: // "
          sb.writeCharCode(unit);
          break;
        case 0x24: // $
          sb.write(r'\$');
          break;
        case 0x27: // '
          sb.write(r"\'");
          break;
        case 0x5c: // \
          sb.write(r'\\');
          break;
        default:
          if (unit < 0x20 || unit == 0x7f) {
            sb.write(
              '\\x${unit.toRadixString(16).toUpperCase().padLeft(2, '0')}',
            );
          } else if (unit > 0x7f && unit < 0xa0) {
            sb.write(
              '\\u${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}',
            );
          } else {
            sb.writeCharCode(unit);
          }
      }
    }
    sb.write("'");
    return sb.toString();
  }

  cb.Expression _compileLiteral(Literal lit) => switch (lit.whichValue()) {
    Literal_Value.intValue => cb.literalNum(lit.intValue.toInt()),
    Literal_Value.doubleValue => cb.literalNum(lit.doubleValue),
    // Bug fix: code_builder's literalString only escapes single quotes and
    // newlines, not backslashes or other control characters. Pre-escape
    // backslashes plus control chars like `\r`, `\b`, `\f`, `\v`, `\x7f`
    // so strings round-trip correctly.
    Literal_Value.stringValue => _raw(_dartStringLiteral(lit.stringValue)),
    Literal_Value.boolValue => cb.literalBool(lit.boolValue),
    Literal_Value.bytesValue => _raw('${lit.bytesValue}'),
    Literal_Value.listValue => cb.literalList(
      lit.listValue.elements.map(_compileExpression).toList(),
    ),
    Literal_Value.notSet => cb.literalNull,
  };

  String _compileLiteralValue(Expression expr) {
    if (expr.whichExpr() == Expression_Expr.literal) {
      final lit = expr.literal;
      return switch (lit.whichValue()) {
        Literal_Value.stringValue => lit.stringValue,
        Literal_Value.intValue => '${lit.intValue.toInt()}',
        _ => _e(expr),
      };
    }
    return _e(expr);
  }

  // ── Message creation & blocks & lambda ───────────────────────

  String _compileMessageCreation(MessageCreation msg) {
    if (msg.typeName.isEmpty) {
      if (msg.fields.isEmpty) return '/* empty message */';
      // MapLiteralEntry sentinel: exactly two fields named 'key' and 'value'.
      if (msg.fields.length == 2 &&
          msg.fields[0].name == 'key' &&
          msg.fields[1].name == 'value') {
        final k = _e(msg.fields[0].value);
        final v = _e(msg.fields[1].value);
        return '$k: $v';
      }
      // When typeName is empty this is an inline argument message—compile
      // fields respecting named vs positional convention so it can be used
      // directly as an argument list string.
      return _compileArgs(msg.fields.toList());
    }
    final rawTypeName = msg.typeName;
    // Special case: Dart built-in type named constructors encoded as
    // "bool:hasEnvironment", "String:fromEnvironment", etc.
    // _dartType would strip the class prefix, losing the receiver type.
    // Restore as "bool.hasEnvironment", etc.
    final colonIdx = rawTypeName.lastIndexOf(':');
    final moduleOrClass = colonIdx >= 0
        ? rawTypeName.substring(0, colonIdx)
        : '';
    final afterColon = colonIdx >= 0
        ? rawTypeName.substring(colonIdx + 1)
        : rawTypeName;
    const builtinTypes = {'bool', 'String', 'int', 'double', 'num'};
    final isBuiltinConst = builtinTypes.contains(moduleOrClass);
    final dartName = isBuiltinConst
        ? 'const $moduleOrClass.$afterColon'
        : _dartType(rawTypeName);

    // Type arguments: prefer structured metadata.type_args, fall back to
    // legacy __type_args__ field.
    String typeArgs = '';
    if (msg.hasMetadata() && msg.metadata.fields.containsKey('type_args')) {
      final refs = msg.metadata.fields['type_args']!.listValue.values;
      typeArgs = '<${refs.map(_metadataTypeArgToStr).join(', ')}>';
    } else {
      final typeArgsField = msg.fields
          .where((f) => f.name == '__type_args__')
          .firstOrNull;
      typeArgs = typeArgsField?.value.literal.stringValue ?? '';
    }
    // Const: prefer metadata.is_const, fall back to legacy __const__ field.
    final isConst =
        (msg.hasMetadata() &&
            msg.metadata.fields['is_const']?.boolValue == true) ||
        msg.fields.any(
          (f) =>
              f.name == '__const__' &&
              f.value.whichExpr() == Expression_Expr.literal &&
              f.value.literal.boolValue == true,
        );
    final actualFields = msg.fields
        .where((f) => f.name != '__type_args__' && f.name != '__const__')
        .toList();

    // Reconstruct the correct Dart constructor form:
    // `Map<String,String>.from(...)` uses `TypeName<T>.ctorName(...)` syntax.
    // Split dartName at the first dot when there are type args.
    String dartConstructorName;
    if (typeArgs.isNotEmpty && dartName.contains('.')) {
      final dotIdx = dartName.indexOf('.');
      final className = dartName.substring(0, dotIdx);
      final ctorPart = dartName.substring(dotIdx); // includes the dot
      dartConstructorName = '$className$typeArgs$ctorPart';
    } else if (typeArgs.isNotEmpty) {
      dartConstructorName = '$dartName$typeArgs';
    } else {
      dartConstructorName = dartName;
    }

    // Don't double-prefix: builtin types already get 'const' from the
    // isBuiltinConst path above.
    final constPrefix = (isConst && !isBuiltinConst) ? 'const ' : '';
    if (actualFields.isEmpty) return '$constPrefix$dartConstructorName()';
    return '$constPrefix$dartConstructorName(${_compileArgs(actualFields)})';
  }

  String _compileBlockExpression(Block block) {
    final buf = StringBuffer('(() {\n');
    // A `let self = …` binding shadows the implicit receiver for the rest of
    // the block (see [_generateBlockStatements]).
    var selfBindings = 0;
    for (final stmt in block.statements) {
      if (stmt.whichStmt() == Statement_Stmt.let) {
        buf.write(
          '${_letDeclKeyword(stmt.let)} ${stmt.let.name} = '
          '${_e(stmt.let.value)};\n',
        );
        if (stmt.let.name == 'self') {
          _selfShadowDepth++;
          selfBindings++;
        }
      } else if (stmt.whichStmt() == Statement_Stmt.expression) {
        final expr = stmt.expression;
        if (_isStdControl(expr)) {
          // Handle control-flow statements (return, if, for, etc.) inside
          // block expressions by compiling them inline.
          buf.write(_compileStdStatementToString(expr.call, false));
        } else {
          buf.write('${_e(expr)};\n');
        }
      }
    }
    if (block.hasResult()) {
      buf.write('return ${_e(block.result)};\n');
    }
    _selfShadowDepth -= selfBindings;
    buf.write('})()');
    return buf.toString();
  }

  String _compileLambda(FunctionDefinition func) {
    final meta = _readMeta(func);
    final isExprBody = meta['expression_body'] == true;
    final isAsync = meta['is_async'] == true;
    final isAsyncStar = meta['is_async_star'] == true;
    final isSyncStar = meta['is_sync_star'] == true;

    final buf = StringBuffer('(${_buildParamList(meta)})');
    if (isAsync && !isAsyncStar) buf.write(' async');
    if (isAsyncStar) buf.write(' async*');
    if (isSyncStar) buf.write(' sync*');

    if (!func.hasBody()) return buf.toString();

    if (isExprBody) {
      buf.write(' => ${_e(func.body)}');
    } else {
      // Use the encoder's `has_return` flag to determine if the body
      // should emit `return` for its last expression.
      final hasReturn = meta['has_return'] == true;
      final bodyStr = _captureBody(
        () => _generateFunctionBody(func.body, hasReturn),
      );
      buf.write(' {\n$bodyStr}');
    }
    return buf.toString();
  }

  // ════════════════════════════════════════════════════════════
  // Argument list compilation
  // ════════════════════════════════════════════════════════════

  String _compileArgs(List<FieldValuePair> fields) {
    final parts = <String>[];
    for (final field in fields) {
      parts.add(
        field.name.startsWith('arg')
            ? _e(field.value)
            : '${field.name}: ${_e(field.value)}',
      );
    }
    return parts.join(', ');
  }

  // ════════════════════════════════════════════════════════════
  // Protobuf → Dart type helpers
  // ════════════════════════════════════════════════════════════

  String _protoFieldToDartType(google.FieldDescriptorProto field) {
    String base;
    if (field.type == google.FieldDescriptorProto_Type.TYPE_MESSAGE &&
        field.typeName.isNotEmpty) {
      base = field.typeName.startsWith('.')
          ? field.typeName.split('.').last
          : field.typeName;
    } else {
      base = _protoTypeToDartType(field.type);
    }
    if (field.label == google.FieldDescriptorProto_Label.LABEL_REPEATED) {
      return 'List<$base>';
    }
    return base;
  }

  String _protoTypeToDartType(google.FieldDescriptorProto_Type type) =>
      switch (type) {
        google.FieldDescriptorProto_Type.TYPE_DOUBLE ||
        google.FieldDescriptorProto_Type.TYPE_FLOAT => 'double',
        google.FieldDescriptorProto_Type.TYPE_INT64 ||
        google.FieldDescriptorProto_Type.TYPE_UINT64 ||
        google.FieldDescriptorProto_Type.TYPE_INT32 ||
        google.FieldDescriptorProto_Type.TYPE_FIXED64 ||
        google.FieldDescriptorProto_Type.TYPE_FIXED32 ||
        google.FieldDescriptorProto_Type.TYPE_UINT32 ||
        google.FieldDescriptorProto_Type.TYPE_SFIXED32 ||
        google.FieldDescriptorProto_Type.TYPE_SFIXED64 ||
        google.FieldDescriptorProto_Type.TYPE_SINT32 ||
        google.FieldDescriptorProto_Type.TYPE_SINT64 => 'int',
        google.FieldDescriptorProto_Type.TYPE_BOOL => 'bool',
        google.FieldDescriptorProto_Type.TYPE_STRING => 'String',
        google.FieldDescriptorProto_Type.TYPE_BYTES => 'List<int>',
        google.FieldDescriptorProto_Type.TYPE_ENUM => 'int',
        _ => 'dynamic',
      };

  String _dartFieldName(String name) {
    const reserved = {
      'class',
      'extends',
      'implements',
      'import',
      'export',
      'part',
      'return',
      'this',
      'super',
      'new',
      'null',
      'true',
      'false',
      'var',
      'final',
      'const',
      'void',
      'if',
      'else',
      'for',
      'while',
      'do',
      'switch',
      'case',
      'default',
      'break',
      'continue',
      'try',
      'catch',
      'finally',
      'throw',
      'assert',
      'in',
      'is',
      'as',
    };
    return reserved.contains(name) ? '$name\$' : name;
  }

  // ════════════════════════════════════════════════════════════
  // Metadata helpers
  // ════════════════════════════════════════════════════════════

  Map<String, Object?> _readMeta(FunctionDefinition func) =>
      func.hasMetadata() ? _structToMap(func.metadata) : {};

  Map<String, Object?> _structToMap(structpb.Struct struct) => {
    for (final e in struct.fields.entries) e.key: _structValueToObject(e.value),
  };

  Object? _structValueToObject(structpb.Value value) {
    if (value.hasStringValue()) return value.stringValue;
    if (value.hasBoolValue()) return value.boolValue;
    if (value.hasNumberValue()) return value.numberValue;
    if (value.hasListValue()) {
      return value.listValue.values.map(_structValueToObject).toList();
    }
    if (value.hasStructValue()) return _structToMap(value.structValue);
    return null;
  }

  String _buildParamList(Map<String, Object?> meta) {
    final params = meta['params'];
    if (params == null || params is! List) return '';

    final positional = <String>[];
    final optional = <String>[];
    final named = <String>[];

    for (final p in params) {
      if (p is! Map) continue;
      final name = p['name'] ?? '_';
      final type = p['type'] as String?;
      final isNamed =
          p['is_named'] == true ||
          p['is_required_named'] == true ||
          p['is_optional_named'] == true;
      final isOptional = p['is_optional'] == true;
      final isRequiredNamed = p['is_required_named'] == true;
      final defaultValue = p['default'] as String?;

      final buf = StringBuffer();
      if (isRequiredNamed) buf.write('required ');
      if (p['is_this'] == true) {
        buf.write('this.$name');
      } else if (p['is_super'] == true) {
        buf.write('super.$name');
      } else {
        if (type != null) buf.write('$type ');
        buf.write(name);
      }
      if (defaultValue != null) buf.write(' = $defaultValue');

      if (isNamed) {
        named.add(buf.toString());
      } else if (isOptional) {
        optional.add(buf.toString());
      } else {
        positional.add(buf.toString());
      }
    }

    final out = <String>[...positional];
    if (optional.isNotEmpty) out.add('[${optional.join(', ')}]');
    if (named.isNotEmpty) out.add('{${named.join(', ')}}');
    return out.join(', ');
  }

  String _metadataTypeArgToStr(structpb.Value v) {
    final s = v.structValue;
    final name = s.fields['name']?.stringValue ?? '';
    final args = s.fields['type_args']?.listValue.values;
    final nullable = s.fields['nullable']?.boolValue ?? false;
    final buf = StringBuffer(name);
    if (args != null && args.isNotEmpty) {
      buf.write('<');
      buf.write(args.map((a) => _metadataTypeArgToStr(a)).join(', '));
      buf.write('>');
    }
    if (nullable) buf.write('?');
    return buf.toString();
  }

  String _typeRefToStr(TypeRef ref) {
    final buf = StringBuffer(ref.name);
    if (ref.typeArgs.isNotEmpty) {
      buf.write('<');
      buf.write(ref.typeArgs.map(_typeRefToStr).join(', '));
      buf.write('>');
    }
    if (ref.nullable) buf.write('?');
    return buf.toString();
  }

  String _callTypeArgsStr(FunctionCall call) {
    if (call.typeArgs.isEmpty) return '';
    return '<${call.typeArgs.map(_typeRefToStr).join(', ')}>';
  }

  String _typeParamsStr(Map<String, Object?> meta) {
    final tp = meta['type_params'];
    if (tp == null || tp is! List || tp.isEmpty) return '';
    return '<${tp.join(', ')}>';
  }

  /// Add generic type parameters from [meta] to a class/mixin/enum builder.
  /// The consumer must pass the add callback from `b.types.add`.
  void _addTypeParams(
    void Function(cb.Reference) addFn,
    Map<String, Object?> meta,
  ) {
    final tp = meta['type_params'];
    if (tp == null || tp is! List) return;
    for (final param in tp) {
      addFn(cb.refer(param as String));
    }
  }

  /// True when the [letExpr] was encoded with the `__no_init__` sentinel:
  /// i.e. the original Dart variable had no initializer (`Type? x;`).
  static bool _isNoInit(Expression letExpr) =>
      letExpr.whichExpr() == Expression_Expr.reference &&
      letExpr.reference.name == '__no_init__';

  String _letDeclKeyword(LetBinding let, [Expression? valueExpr]) {
    if (!let.hasMetadata()) return 'final';
    final meta = _structToMap(let.metadata);
    final keyword = meta['keyword'] as String? ?? 'final';
    final isLate = meta['is_late'] == true;

    var type = meta['type'] as String?;
    // Ball is dynamically typed; 'Object' in generic type parameters should
    // be 'dynamic' so map/list access returns dynamic (implicitly castable)
    // instead of Object (which requires explicit casts in null-safe Dart).
    if (type != null) {
      type = type
          .replaceAll('Object>', 'dynamic>')
          .replaceAll('Object,', 'dynamic,');
    }

    // When the value is a call to a sync*/async* generator function, the
    // declared variable type may be `List<T>` but the actual return is
    // `Iterable<T>` or `Stream<T>`. Rewrite the type to match.
    if (type != null &&
        valueExpr != null &&
        valueExpr.whichExpr() == Expression_Expr.call &&
        !_isBaseModule(valueExpr.call.module)) {
      final calledFn = valueExpr.call.function;
      if (_syncStarFunctions.contains(calledFn)) {
        if (type.startsWith('List<') && type.endsWith('>')) {
          type = 'Iterable<${type.substring(5, type.length - 1)}>';
        }
      } else if (_asyncStarFunctions.contains(calledFn)) {
        if (type.startsWith('List<') && type.endsWith('>')) {
          type = 'Stream<${type.substring(5, type.length - 1)}>';
        }
      }
    }

    final buf = StringBuffer();
    if (isLate) buf.write('late ');
    if (type != null) {
      if (keyword == 'const') {
        buf.write('const $type');
      } else if (keyword == 'final') {
        buf.write('final $type');
      } else {
        buf.write(type);
      }
    } else {
      buf.write(keyword);
    }
    return buf.toString();
  }

  bool _isEmptyBody(Expression body) {
    if (body.whichExpr() == Expression_Expr.block) {
      return body.block.statements.isEmpty && !body.block.hasResult();
    }
    return body.whichExpr() == Expression_Expr.literal &&
        body.literal.whichValue() == Literal_Value.notSet;
  }

  /// Detects Ball IR constructor boilerplate patterns that have no meaningful
  /// Dart equivalent and should be stripped from non-factory constructor bodies.
  ///
  /// Patterns detected:
  /// 1. A single `reference` expression (references a param or `input`).
  /// 2. A block with `let self = TypeName(); return self;` (create-self idiom).
  /// 3. A block with only `let v = input/param; [v;]` (param alias artifact).
  bool _isConstructorBoilerplateBody(Expression body) {
    // Pattern 1: bare reference (e.g. `input` or a param name).
    if (body.whichExpr() == Expression_Expr.reference) {
      return true;
    }

    if (body.whichExpr() != Expression_Expr.block) return false;
    final stmts = body.block.statements;
    if (stmts.isEmpty) return false;

    // Pattern 2: `let self = TypeName(); return self;`
    // A block of exactly 2 statements where the first is a `let` whose value
    // is a `messageCreation` and the second is a `return` of that variable.
    if (stmts.length == 2) {
      final first = stmts[0];
      final second = stmts[1];
      if (first.whichStmt() == Statement_Stmt.let &&
          second.whichStmt() == Statement_Stmt.expression) {
        final letStmt = first.let;
        final expr = second.expression;
        // Check let value is a messageCreation (object construction).
        if (letStmt.hasValue() &&
            letStmt.value.whichExpr() == Expression_Expr.messageCreation) {
          // Check the second statement is `return self`.
          if (expr.whichExpr() == Expression_Expr.call &&
              expr.call.function == 'return' &&
              expr.call.module == 'std') {
            return true;
          }
        }
        // Also: let + bare reference to the let variable.
        if (letStmt.hasValue() &&
            expr.whichExpr() == Expression_Expr.reference &&
            expr.reference.name == letStmt.name) {
          return true;
        }
      }
    }

    // Pattern 3: single `let v = input;` (possibly followed by a bare
    // reference to v). The let value is a `reference` to `input` or a param.
    if (stmts.length == 1) {
      final first = stmts[0];
      if (first.whichStmt() == Statement_Stmt.let) {
        final letStmt = first.let;
        if (letStmt.hasValue() &&
            letStmt.value.whichExpr() == Expression_Expr.reference) {
          return true;
        }
      }
      // Single expression statement that is just a reference (passthrough).
      if (first.whichStmt() == Statement_Stmt.expression &&
          first.expression.whichExpr() == Expression_Expr.reference) {
        return true;
      }
    }

    return false;
  }

  // ════════════════════════════════════════════════════════════
  // Field extraction helpers
  // ════════════════════════════════════════════════════════════

  Map<String, Expression> _extractFields(FunctionCall call) {
    if (!call.hasInput()) return {};
    if (call.input.whichExpr() == Expression_Expr.messageCreation) {
      return _fieldsToMap(call.input.messageCreation.fields);
    }
    return {'value': call.input};
  }

  Map<String, Expression> _fieldsToMap(Iterable<FieldValuePair> fields) => {
    for (final f in fields) f.name: f.value,
  };

  String? _stringFieldValue(Map<String, Expression> fields, String name) {
    final expr = fields[name];
    if (expr == null) return null;
    if (expr.whichExpr() == Expression_Expr.literal &&
        expr.literal.whichValue() == Literal_Value.stringValue) {
      return expr.literal.stringValue;
    }
    return null;
  }

  /// A `type_literal`'s stored value is the canonical `Type.toString()` (e.g.
  /// `List<dynamic>`), but that string is NOT valid Dart in expression position:
  /// `print(List<dynamic>)` re-parses as a generic function instantiation
  /// (`ast.FunctionReference`), not a type literal. Emit the bare source name
  /// for the raw-generic builtins so the encoder re-reads them via the
  /// `SimpleIdentifier` → `type_literal` path (#66). Non-builtin/explicitly
  /// parameterized types (`List<int>`) fall through unchanged.
  String _compileTypeLiteral(String? type) => switch (type) {
    null => 'dynamic',
    'List<dynamic>' => 'List',
    'Map<dynamic, dynamic>' => 'Map',
    'Set<dynamic>' => 'Set',
    _ => type,
  };

  bool _boolFieldValue(Map<String, Expression> fields, String name) {
    final expr = fields[name];
    return expr != null &&
        expr.whichExpr() == Expression_Expr.literal &&
        expr.literal.whichValue() == Literal_Value.boolValue &&
        expr.literal.boolValue;
  }

  /// Strips the `module:` prefix from a ball type name for Dart output.
  /// `"main:A"` → `"A"`, `"List<main:A>"` → `"List<A>"`, `"String"` → `"String"`.
  /// Works on arbitrary type expressions with nested generics.
  static String _dartType(String ballType) {
    // Strip module prefix: everything up to and including the last ':'.
    // e.g. '.lib.src.foo:Bar' → 'Bar'
    //       '.lib.src.foo:Bar.fromJson' → 'Bar.fromJson'
    //       'Bar' (no prefix) → 'Bar'
    final colonIdx = ballType.lastIndexOf(':');
    return colonIdx >= 0 ? ballType.substring(colonIdx + 1) : ballType;
  }

  /// Extract the member name (method, constructor, field) from a full ball
  /// function name of the form '.module:ClassName.memberName'.
  ///
  /// For standalone (top-level) functions the name contains no colon/dot
  /// class prefix and is returned as-is.
  ///
  /// Examples:
  ///   '.lib.meta:Required.new'      → 'new'
  ///   '.lib.meta:Required.fromJson' → 'fromJson'
  ///   '.lib.meta:Required.toString' → 'toString'
  ///   'topLevelFn'                  → 'topLevelFn'
  static String _memberName(String funcName) {
    final colonIdx = funcName.lastIndexOf(':');
    final afterColon = colonIdx >= 0
        ? funcName.substring(colonIdx + 1)
        : funcName;
    final dotIdx = afterColon.indexOf('.');
    return dotIdx >= 0 ? afterColon.substring(dotIdx + 1) : '';
  }

  /// Finds a metadata entry in [list] whose 'name' field matches [name].
  Map<String, Object?>? _findInList(List<Object?> list, String name) {
    for (final item in list) {
      if (item is Map && item['name'] == name) {
        return item.cast<String, Object?>();
      }
    }
    return null;
  }

  // ════════════════════════════════════════════════════════════
  // Output helpers (body scratch buffer)
  // ════════════════════════════════════════════════════════════

  void _wl(String line) => _out.writeln('${'  ' * _depth}$line');
  void _wr(String text) => _out.write('${'  ' * _depth}$text');
}
