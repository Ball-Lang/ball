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
import 'package:code_builder/code_builder.dart' as cb;
import 'package:dart_style/dart_style.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart'
    as structpb;

/// Compiles a ball [Program] into formatted Dart source code.
class DartCompiler {
  final Program program;

  /// When `true`, the compiler skips the `dart_style` formatting step and
  /// returns raw (unformatted) Dart source.  Use this when the compiled output
  /// is known to confuse the formatter (e.g. deeply nested expressions from
  /// large inputs) or when formatting is intentionally unwanted.
  final bool noFormat;

  // ── Lookup tables ───────────────────────────────────────────
  final Map<String, google.DescriptorProto> _types = {};
  final Map<String, FunctionDefinition> _functions = {};
  final Set<String> _baseModules = {};

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
      for (final type in module.types) {
        _types[type.name] = type;
        // Also index by bare name (strip module: prefix) for backward compat.
        final typeColon = type.name.indexOf(':');
        if (typeColon >= 0) _types[type.name.substring(typeColon + 1)] = type;
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
    return noFormat ? _emitRaw(lib) : _format(lib);
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

      if (kind == 'method' || kind == 'constructor' || kind == 'static_field') {
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
            ? func.name.substring(colonIdx + 1)
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
        if (dotIdx >= 0) {
          final classKey = func.name.substring(0, dotIdx);
          classMethods.putIfAbsent(classKey, () => []).add(func);
          continue;
        }
      }
      if (kind == 'top_level_variable') {
        topLevelVars.add(func);
        continue;
      }
      standaloneFunctions.add(func);
    }

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

      for (final method in methods) {
        final mMeta = _readMeta(method);
        if ((mMeta['kind'] as String?) == 'constructor') {
          b.constructors.add(_buildConstructor(enumDef.name, method, mMeta));
        } else {
          b.methods.add(_buildMethod(enumDef.name, method, mMeta));
        }
      }
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
      for (final method in methods) {
        b.methods.add(_buildMethod(td.name, method, _readMeta(method)));
      }
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

      for (final method in methods) {
        final mMeta = _readMeta(method);
        final mKind = mMeta['kind'] as String? ?? 'method';
        if (mKind == 'static_field') continue;
        if (mKind == 'constructor') {
          b.constructors.add(_buildConstructor(descriptor.name, method, mMeta));
        } else {
          b.methods.add(_buildMethod(descriptor.name, method, mMeta));
        }
      }
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
            fb.late = isLate;
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
    final displayName = td.name == '_unnamed_extension'
        ? ''
        : _dartType(td.name);

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
      for (final method in methods) {
        b.methods.add(_buildMethod(td.name, method, _readMeta(method)));
      }
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

      for (final method in methods) {
        final mMeta = _readMeta(method);
        final mKind = mMeta['kind'] as String? ?? 'method';
        if (mKind == 'static_field') {
          b.fields.add(_buildStaticField(method));
        } else if (mKind == 'constructor') {
          b.constructors.add(_buildConstructor(td.name, method, mMeta));
        } else {
          b.methods.add(_buildMethod(td.name, method, mMeta));
        }
      }
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
      b.name = isOperator
          ? 'operator $name$typeParamsStr'
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

      if (func.outputType.isNotEmpty)
        b.returns = cb.refer(_dartType(func.outputType));

      if (isAsync && !isAsyncStar) b.modifier = cb.MethodModifier.async;
      if (isAsyncStar) b.modifier = cb.MethodModifier.asyncStar;
      if (isSyncStar) b.modifier = cb.MethodModifier.syncStar;

      _addParameters(b, meta);

      if (!isAbstract && !isExternal && func.hasBody()) {
        if (isExpressionBody) {
          b.lambda = true;
          b.body = _compileExpression(func.body).code;
        } else {
          b.body = cb.Code(
            _captureBody(
              () => _generateFunctionBody(func.body, _hasNonVoidReturn(func)),
            ),
          );
        }
      }
    });
  }

  cb.Constructor _buildConstructor(
    String className,
    FunctionDefinition func,
    Map<String, Object?> meta,
  ) {
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

      if (redirectsTo != null) {
        b.redirect = cb.refer(redirectsTo);
      } else if (initializers != null && initializers.isNotEmpty) {
        b.initializers.addAll(
          _buildInitializerList(initializers).map(cb.Code.new),
        );
      }

      if (!b.external && func.hasBody() && !_isEmptyBody(func.body)) {
        if (isExpressionBody) {
          b.lambda = true;
          b.body = _compileExpression(func.body).code;
        } else {
          b.body = cb.Code(
            _captureBody(() => _generateFunctionBody(func.body, false)),
          );
        }
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

  void _addParameters(dynamic builder, Map<String, Object?> meta) {
    final params = meta['params'];
    if (params == null || params is! List) return;

    for (final p in params) {
      if (p is! Map) continue;
      final paramName = p['name'] as String? ?? '_';
      final paramType = p['type'] as String?;
      final isNamed =
          p['is_named'] == true ||
          p['is_required_named'] == true ||
          p['is_optional_named'] == true;
      final isOptional = p['is_optional'] == true;
      final isRequiredNamed = p['is_required_named'] == true;
      final defaultValue = p['default'] as String?;

      final param = cb.Parameter((pb) {
        pb.name = paramName;
        if (paramType != null) pb.type = cb.refer(paramType);
        if (p['is_this'] == true) pb.toThis = true;
        if (p['is_super'] == true) pb.toSuper = true;
        if (isNamed) pb.named = true;
        if (isRequiredNamed) pb.required = true;
        if (defaultValue != null) pb.defaultTo = cb.Code(defaultValue);
      });

      if (isNamed || isOptional) {
        (builder as dynamic).optionalParameters.add(param);
      } else {
        (builder as dynamic).requiredParameters.add(param);
      }
    }
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

    return cb.Method((b) {
      b.name = 'main';
      b.returns = cb.refer('void');
      if (isAsync) b.modifier = cb.MethodModifier.async;
      b.body = func.hasBody()
          ? cb.Code(_captureBody(() => _generateFunctionBody(func.body, false)))
          : const cb.Code('');
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
    for (final stmt in block.statements) {
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
    var inSwitch = false;

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
      inSwitch = true;
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
            '${_letDeclKeyword(stmt.let)} ${stmt.let.name} = '
            '${_e(letExpr)};',
          );
        }
      case Statement_Stmt.expression:
        final expr = stmt.expression;
        if (_isStdControl(expr)) {
          _generateStdStatement(expr.call, false);
        } else {
          _wl('${_e(expr)};');
        }
      case Statement_Stmt.notSet:
        break;
    }
  }

  void _generateLocalFunction(String name, FunctionDefinition func) {
    final meta = _readMeta(func);
    // If the function has no explicit return type, omit the return type
    // annotation so Dart can infer it (e.g. `async` lambdas return `Future`).
    final returnType = func.outputType.isEmpty
        ? null
        : _dartType(func.outputType);
    final isAsync = meta['is_async'] == true;
    final isAsyncStar = meta['is_async_star'] == true;
    final isSyncStar = meta['is_sync_star'] == true;
    final isExprBody = meta['expression_body'] == true;

    final typePart = returnType != null ? '$returnType ' : '';
    final sig = StringBuffer('$typePart$name(${_buildParamList(meta)})');
    if (isAsync && !isAsyncStar) sig.write(' async');
    if (isAsyncStar) sig.write(' async*');
    if (isSyncStar) sig.write(' sync*');

    if (isExprBody && func.hasBody()) {
      _wl('$sig => ${_e(func.body)};');
    } else {
      _wl('$sig {');
      _depth++;
      if (func.hasBody()) {
        _generateFunctionBody(func.body, _hasNonVoidReturn(func));
      }
      _depth--;
      _wl('}');
    }
  }

  // ── std control-flow ────────────────────────────────────────

  static bool _isBaseModule(String module) =>
      module == 'std' ||
      module == 'dart_std' ||
      module == 'std_memory' ||
      module == 'std_collections' ||
      module == 'std_io' ||
      module == 'std_convert' ||
      module == 'std_fs' ||
      module == 'std_time';

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
        _wl(v != null ? 'return ${_e(v)};' : 'return;');
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
        _wl('throw ${v != null ? _e(v) : "null"};');
      case 'rethrow':
        _wl('rethrow;');
      default:
        _wl('/* unsupported statement: std.${call.function} */');
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
        return 'throw ${v != null ? _e(v) : "null"};\n';
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
    _generateBranchBody(then, hasReturn);
    _depth--;
    if (els != null) {
      if (_isStdCall(els, 'if')) {
        _wr('} else ');
        _generateIf(_extractFields(els.call), hasReturn);
        return;
      }
      _wl('} else {');
      _depth++;
      _generateBranchBody(els, hasReturn);
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
    // 'init' may be a string literal (ForPartsWithDeclarations) or an
    // expression (ForPartsWithExpression — e.g. `numArgs = args.length`).
    final initExpr = fields['init'];
    final init = initExpr != null
        ? (_stringFieldValue(fields, 'init') ?? _e(initExpr))
        : '';
    final condStr = fields['condition'] != null ? _e(fields['condition']!) : '';
    final updateStr = fields['update'] != null ? _e(fields['update']!) : '';
    final body = fields['body'];
    _wl('for ($init; $condStr; $updateStr) {');
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _depth--;
    _wl('}');
  }

  void _generateForIn(Map<String, Expression> fields) {
    final variable = _stringFieldValue(fields, 'variable') ?? 'item';
    final variableType = _stringFieldValue(fields, 'variable_type') ?? 'final';
    final typeDecl = variableType == 'final' || variableType.isEmpty
        ? 'final $variable'
        : '$variableType $variable';
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
    final pattern = _stringFieldValue(cf, 'pattern');
    final value = cf['value'];
    final body = cf['body'];

    if (isDefault) {
      _wl('default:');
    } else if (pattern != null && pattern.isNotEmpty) {
      _wl('case $pattern:');
    } else if (value != null) {
      _wl('case ${_e(value)}:');
    } else {
      return;
    }
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _wl('break;');
    _depth--;
  }

  void _generateTry(Map<String, Expression> fields) {
    final body = fields['body'];
    final catches = fields['catches'];
    final fin = fields['finally'];

    _wl('try {');
    _depth++;
    if (body != null) _generateBranchBody(body, false);
    _depth--;

    if (catches != null &&
        catches.whichExpr() == Expression_Expr.literal &&
        catches.literal.whichValue() == Literal_Value.listValue) {
      for (final ce in catches.literal.listValue.elements) {
        _generateCatchClause(ce);
      }
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
      clause.write('} catch ($variable');
    }
    if (stackTrace != null && stackTrace.isNotEmpty) {
      clause.write(', $stackTrace');
    }
    clause.write(') {');
    _wl(clause.toString());
    _depth++;
    if (body != null) _generateBranchBody(body, false);
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
        Expression_Expr.reference => cb.refer(expr.reference.name),
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
    // a cascade section — emit just the field name.
    if (_emit(obj) == '__cascade_self__') return cb.refer(fa.field_2);
    return obj.property(fa.field_2);
  }

  String _compileCall(FunctionCall call) {
    if (_isBaseModule(call.module)) return _compileBaseCall(call);

    if (call.hasInput() &&
        call.input.whichExpr() == Expression_Expr.messageCreation) {
      final fields = call.input.messageCreation.fields;
      final selfField = fields.where((f) => f.name == 'self').firstOrNull;
      if (selfField != null) {
        // Extract __type_args__ if present (e.g. results.whereType<Future>()).
        final typeArgsField = fields
            .where((f) => f.name == '__type_args__')
            .firstOrNull;
        final typeArgs = typeArgsField != null
            ? typeArgsField.value.literal.stringValue
            : '';
        final remaining = fields
            .where((f) => f.name != 'self' && f.name != '__type_args__')
            .toList();
        final selfStr = _e(selfField.value);
        // __cascade_self__ is a sentinel for "no explicit receiver" inside
        // a cascade section — emit just the method call without a target so
        // the outer `..` prefix is sufficient.
        if (selfStr == '__cascade_self__') {
          return remaining.isEmpty
              ? '${call.function}$typeArgs()'
              : '${call.function}$typeArgs(${_compileArgs(remaining)})';
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
    if (call.hasInput()) {
      final inp = call.input;
      if (inp.whichExpr() == Expression_Expr.messageCreation &&
          inp.messageCreation.typeName.isEmpty) {
        // Argument-list message: emit named / positional args properly.
        // Extract __type_args__ if present (e.g. registerCallback<OnBeforeCaptureLog>(...)).
        final allFields = inp.messageCreation.fields;
        final typeArgsField = allFields
            .where((f) => f.name == '__type_args__')
            .firstOrNull;
        final typeArgs = typeArgsField != null
            ? typeArgsField.value.literal.stringValue
            : '';
        final args = allFields.where((f) => f.name != '__type_args__').toList();
        return args.isEmpty
            ? '$modulePrefix${call.function}$typeArgs()'
            : '$modulePrefix${call.function}$typeArgs(${_compileArgs(args)})';
      }
      return '$modulePrefix${call.function}(${_e(inp)})';
    }
    return '$modulePrefix${call.function}()';
  }

  String _compileBaseCall(FunctionCall call) {
    if (call.module == 'std_memory') return _compileMemoryCall(call);
    if (call.module == 'std_collections') return _compileCollectionsCall(call);
    if (call.module == 'std_io') return _compileIoCall(call);
    if (call.module == 'std_convert') return _compileConvertCall(call);
    if (call.module == 'std_fs') return _compileFsCall(call);
    if (call.module == 'std_time') return _compileTimeCall(call);
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
      'type_literal' => _stringFieldValue(f, 'type') ?? 'dynamic',
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
      'string_repeat' => _binOp(f, '*'),
      'string_pad_left' => _compileStringPad(f, 'padLeft'),
      'string_pad_right' => _compileStringPad(f, 'padRight'),
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
      // ── Dart-specific ───────────────────────────────────────
      'dart_list_generate' =>
        'List.generate(${_e(f['count']!)}, ${_e(f['generator']!)})',
      'dart_list_filled' =>
        'List.filled(${_e(f['count']!)}, ${_e(f['value']!)})',
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
      'memory_realloc' => _memAlloc(f), // simplified: just alloc new
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

  // ── std_collections compilation ────────────────────────────

  String _compileCollectionsCall(FunctionCall call) {
    final f = _extractFields(call);
    return switch (call.function) {
      // List operations
      'list_push' => '${_e(f['list']!)}..add(${_e(f['value']!)})',
      'list_pop' => '${_e(f['list']!)}..removeLast()',
      'list_insert' =>
        '${_e(f['list']!)}..insert(${_e(f['index']!)}, ${_e(f['value']!)})',
      'list_remove_at' => '${_e(f['list']!)}..removeAt(${_e(f['index']!)})',
      'list_get' => '${_e(f['list']!)}[${_e(f['index']!)}]',
      'list_set' =>
        '(${_e(f['list']!)}[${_e(f['index']!)}] = ${_e(f['value']!)})',
      'list_length' => '${_e(f['list']!)}.length',
      'list_is_empty' => '${_e(f['list']!)}.isEmpty',
      'list_first' => '${_e(f['list']!)}.first',
      'list_last' => '${_e(f['list']!)}.last',
      'list_contains' => '${_e(f['list']!)}.contains(${_e(f['value']!)})',
      'list_index_of' => '${_e(f['list']!)}.indexOf(${_e(f['value']!)})',
      'list_map' => '${_e(f['list']!)}.map(${_e(f['callback']!)}).toList()',
      'list_filter' =>
        '${_e(f['list']!)}.where(${_e(f['callback']!)}).toList()',
      'list_reduce' => '${_e(f['list']!)}.reduce(${_e(f['callback']!)})',
      'list_any' => '${_e(f['list']!)}.any(${_e(f['callback']!)})',
      'list_all' ||
      'list_every' => '${_e(f['list']!)}.every(${_e(f['callback']!)})',
      'list_sort' => '(${_e(f['list']!)}..sort())',
      'list_reverse' => '${_e(f['list']!)}.reversed.toList()',
      'list_slice' =>
        '${_e(f['list']!)}.sublist(${_e(f['start']!)}${f.containsKey('end') ? ', ${_e(f['end']!)}' : ''})',
      'list_concat' => '[...${_e(f['left']!)}, ...${_e(f['right']!)}]',
      'list_flat_map' =>
        '${_e(f['list']!)}.expand(${_e(f['callback']!)}).toList()',
      'string_join' => '${_e(f['list']!)}.join(${_e(f['separator']!)})',
      // Map operations
      'map_get' => '${_e(f['map']!)}[${_e(f['key']!)}]',
      'map_set' => '(${_e(f['map']!)}[${_e(f['key']!)}] = ${_e(f['value']!)})',
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
      'json_decode' => 'jsonDecode(${_e(f['source']!)})',
      'utf8_encode' => 'utf8.encode(${_e(f['source']!)})',
      'utf8_decode' => 'utf8.decode(${_e(f['bytes']!)})',
      'base64_encode' => 'base64Encode(${_e(f['bytes']!)})',
      'base64_decode' => 'base64Decode(${_e(f['source']!)})',
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
        'DateTime.fromMillisecondsSinceEpoch(${_e(f['timestamp']!)}).toIso8601String()',
      'parse_timestamp' =>
        'DateTime.parse(${_e(f['source']!)}).millisecondsSinceEpoch',
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
      _ => _raw('(${_emit(le)} $op ${_emit(re)})'),
    };
    return _emit(expr.parenthesized);
  }

  String _prefixOp(Map<String, Expression> f, String op) {
    final v = f['value'];
    if (v == null) return '/* invalid $op */';
    final ve = _compileExpression(v);
    final expr = switch (op) {
      '-' => ve.operatorUnaryMinus(),
      '!' => ve.negate(),
      '~' => ve.operatorUnaryBitwiseComplement(),
      _ => _raw('($op${_emit(ve)})'),
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
      _ => _raw('($op${_emit(ve)})'),
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
      _ => _raw('(${_emit(ve)}$op)'),
    };
    return _emit(expr);
  }

  String _awaitExpr(Map<String, Expression> f) {
    final v = f['value'];
    return v != null ? _emit(_compileExpression(v).awaited) : 'await null';
  }

  String _throwExpr(Map<String, Expression> f) {
    final v = f['value'];
    return v != null ? _emit(_compileExpression(v).thrown) : '(throw null)';
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
    return '${_e(v)}.toString()';
  }

  String _methodCallExpr(Map<String, Expression> f, String method) {
    final v = f['value'];
    if (v == null) return '/* invalid .$method */';
    // method may include trailing () — strip it for code_builder
    final name = method.endsWith('()')
        ? method.substring(0, method.length - 2)
        : method;
    return _emit(_compileExpression(v).property(name).call([]));
  }

  String _propertyAccess(Map<String, Expression> f, String prop) {
    final v = f['value'];
    if (v == null) return '/* invalid .$prop */';
    return _emit(_compileExpression(v).property(prop));
  }

  String _staticCallExpr(Map<String, Expression> f, String method) {
    final v = f['value'];
    if (v == null) return '/* invalid $method() */';
    return _emit(cb.refer(method).call([_compileExpression(v)]));
  }

  String _methodCall2(Map<String, Expression> f, String method) {
    final l = f['left'] ?? f['target'];
    final r = f['right'] ?? f['index'];
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
      _ => _raw('(${_emit(ve)} $op $t)'),
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
      _ => _raw('$targetStr $op ${_emit(ve)}'),
    };
    return _emit(expr);
  }

  /// Compile a target expression, stripping the `__cascade_self__.` prefix
  /// that is emitted by the encoder for cascade property-access sections.
  ///
  /// `__cascade_self__.field`  →  `field`
  /// `__cascade_self__[i]`     →  `[i]` (rare, handled separately)
  /// anything else             →  normal compile
  String _compileCascadeAwareTarget(Expression target) {
    if (target.whichExpr() == Expression_Expr.fieldAccess) {
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
    final te = _compileExpression(t);
    final ee = e != null ? _compileExpression(e) : cb.literalNull;
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
    if (sections != null &&
        sections.whichExpr() == Expression_Expr.literal &&
        sections.literal.whichValue() == Literal_Value.listValue) {
      var isFirst = true;
      for (final s in sections.literal.listValue.elements) {
        // The `?..` null-aware operator is only valid for the first section;
        // subsequent sections always use `..`.
        final prefix = (nullAware && isFirst) ? '?..' : '..';
        isFirst = false;
        // Compile the section, then strip the __cascade_self__ placeholder
        // that the encoder inserts so that cascade receiver is represented.
        final raw = _e(s);
        final section = _stripCascadeSelf(raw);
        buf.write('$prefix$section');
      }
    }
    // Wrap cascades in parentheses so they can safely appear as sub-
    // expressions (e.g. `(completer..complete(v)).operation`).
    return '(${buf.toString()})';
  }

  /// string.  The encoder emits this sentinel so that the decoder can
  /// restore `..member` syntax.
  static String _stripCascadeSelf(String s) {
    const prefix = '__cascade_self__.';
    if (s.startsWith(prefix)) return s.substring(prefix.length);
    // Also handle things like `(__cascade_self__.field = value)` if the
    // assign already stripped it via _compileCascadeAwareTarget — nothing to do.
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
    final entries = allFields.where((f) => f.name != 'type_args').toList();
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
    final variable = _stringFieldValue(f, 'variable') ?? 'item';
    final iterable = f['iterable'], body = f['body'];
    if (iterable == null || body == null) return '/* invalid collection for */';
    return 'for (final $variable in ${_e(iterable)}) '
        '${_e(body)}';
  }

  String _compileSwitchExpr(Map<String, Expression> f) {
    final subject = f['subject'];
    if (subject == null) return '/* invalid switch expr */';
    final buf = StringBuffer('switch (${_e(subject)}) {\n');
    final cases = f['cases'];
    if (cases != null &&
        cases.whichExpr() == Expression_Expr.literal &&
        cases.literal.whichValue() == Literal_Value.listValue) {
      for (final c in cases.literal.listValue.elements) {
        if (c.whichExpr() != Expression_Expr.messageCreation) continue;
        final cf = _fieldsToMap(c.messageCreation.fields);
        final pattern = _stringFieldValue(cf, 'pattern');
        final body = cf['body'];
        if (pattern != null && body != null) {
          buf.write('$pattern => ${_e(body)},\n');
        }
      }
    }
    buf.write('}');
    return buf.toString();
  }

  String _compileSubstring(Map<String, Expression> f) {
    final v = f['value'], s = f['start'], e = f['end'];
    if (v == null || s == null) return '/* invalid substring */';
    final endStr = e != null ? ', ${_e(e)}' : '';
    return '${_e(v)}.substring(${_e(s)}$endStr)';
  }

  String _compileStringCharCodeAt(Map<String, Expression> f) {
    final t = f['target'], i = f['index'];
    return t != null && i != null
        ? '${_e(t)}.codeUnitAt(${_e(i)})'
        : '/* invalid codeUnitAt */';
  }

  String _compileStringReplace(Map<String, Expression> f, String method) {
    final v = f['value'], from = f['from'], to = f['to'];
    return v != null && from != null && to != null
        ? '${_e(v)}.$method(${_e(from)}, ${_e(to)})'
        : '/* invalid $method */';
  }

  String _compileStringPad(Map<String, Expression> f, String method) {
    final v = f['value'], w = f['width'], p = f['padding'];
    if (v == null || w == null) return '/* invalid $method */';
    final padStr = p != null ? ', ${_e(p)}' : '';
    return '${_e(v)}.$method(${_e(w)}$padStr)';
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
        ? '${_e(v)}.$method(RegExp(${_e(from)}), ${_e(to)})'
        : '/* invalid regex $method */';
  }

  String _compileMathClamp(Map<String, Expression> f) {
    final v = f['value'], mn = f['min'], mx = f['max'];
    return v != null && mn != null && mx != null
        ? '${_e(v)}'
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

  cb.Expression _compileLiteral(Literal lit) => switch (lit.whichValue()) {
    Literal_Value.intValue => cb.literalNum(lit.intValue.toInt()),
    Literal_Value.doubleValue => cb.literalNum(lit.doubleValue),
    Literal_Value.stringValue => cb.literalString(lit.stringValue),
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

  String _formatDouble(double d) {
    final s = d.toString();
    return (!s.contains('.') && !s.contains('e') && !s.contains('E'))
        ? '$s.0'
        : s;
  }

  String _escapeDartString(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r')
      .replaceAll('\t', '\\t')
      .replaceAll('\$', '\\\$');

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

    // Check for instance type arguments stored as `__type_args__` field.
    // e.g. `Map<String,String>.from(...)` → typeName='module:Map.from',
    //       fields: [{name:'__type_args__', value:'<String,String>'}, ...]
    final typeArgsField = msg.fields
        .where((f) => f.name == '__type_args__')
        .firstOrNull;
    final typeArgs = typeArgsField != null
        ? typeArgsField.value.literal.stringValue
        : '';
    // Check for __const__ flag stored by the encoder.
    final constField = msg.fields
        .where((f) => f.name == '__const__')
        .firstOrNull;
    final isConst =
        constField != null &&
        constField.value.whichExpr() == Expression_Expr.literal &&
        constField.value.literal.boolValue == true;
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
    for (final stmt in block.statements) {
      if (stmt.whichStmt() == Statement_Stmt.let) {
        buf.write(
          '${_letDeclKeyword(stmt.let)} ${stmt.let.name} = '
          '${_e(stmt.let.value)};\n',
        );
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

  String _letDeclKeyword(LetBinding let) {
    if (!let.hasMetadata()) return 'final';
    final meta = _structToMap(let.metadata);
    final keyword = meta['keyword'] as String? ?? 'final';
    final isLate = meta['is_late'] == true;

    final type = meta['type'] as String?;
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
