/// Dart-to-ball encoder — translates ANY valid Dart source code into ball programs.
///
/// Uses [package:analyzer] for parsing (official Dart SDK parser), so every
/// valid Dart file is parsed correctly. The encoder maps ALL Dart constructs
/// to ball primitives:
///
///   - Operators       → std.add, std.subtract, std.bitwise_and, etc.
///   - Control flow    → std.if, std.for, std.while, std.try, etc.
///   - Type operations → std.is, std.as, std.null_check, etc.
///   - Dart constructs → std.cascade, std.spread, std.record, etc. (universal std)
///   - Classes         → DescriptorProto (fields) + FunctionDefinition (methods)
///   - Lambdas/closures → FunctionDefinition with name = "" (anonymous)
///   - Everything else → FunctionCall to std module with MessageCreation input
///
/// Language-specific metadata (import URIs, class modifiers, etc.) is preserved
/// in google.protobuf.Struct metadata fields for lossless round-tripping.
library;

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart' show parseString;
import 'package:analyzer/dart/ast/ast.dart' as ast;
import 'package:ball_base/ball_base.dart' show buildStdConvertModule;
import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/gen/google/protobuf/descriptor.pb.dart' as google;
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart'
    as structpb;

/// Error thrown by the encoder in strict mode when it encounters
/// malformed metadata or an unrecoverable encoding problem.
class EncoderError implements Exception {
  EncoderError(this.message, {this.source});
  final String message;
  final String? source;

  @override
  String toString() =>
      'EncoderError: $message${source != null ? ' at $source' : ''}';
}

// All base functions route to the universal `std` module.
// Language-specific base modules have been eliminated — encoders emit only
// universal modules (`std`, `std_collections`, `std_io`, `std_memory`).
// Functions like cascade, null_aware_access, spread, invoke, and record
// are part of the `std` dispatch table.

/// Encodes Dart source code into a ball [Program].
class DartEncoder {
  /// Creates a new encoder.
  ///
  /// When [strict] is `true`, malformed metadata throws an [EncoderError]
  /// instead of being silently swallowed. In permissive mode (default),
  /// problems are collected in [warnings].
  DartEncoder({this.strict = false});

  /// When true, malformed metadata causes an [EncoderError].
  final bool strict;

  /// Warnings emitted during encoding (permissive mode only).
  final List<String> warnings = [];

  /// Maps import prefixes to ball module names.
  final Map<String, String> _prefixToModule = {};

  /// Set of ball module names for all imports.
  final Set<String> _importedModules = {};

  /// Set of std base function names discovered during encoding.
  final Set<String> _usedBaseFunctions = {};

  /// Set of std_collections base function names discovered during encoding.
  final Set<String> _usedCollectionsFunctions = {};

  /// Set of ball_proto base function names discovered during encoding.
  final Set<String> _usedProtoFunctions = {};

  /// Set of std_convert base function names (json/utf8/base64 codecs)
  /// discovered during encoding.
  final Set<String> _usedConvertFunctions = {};

  /// Ball module name for the file currently being encoded.
  /// All user-defined type names are prefixed with `"$_moduleName:"`.
  String _moduleName = 'main';

  /// Counter for generating unique temporary variable names in expansions
  /// (null_aware_access, null_aware_call). Reset in [encode]; intentionally
  /// NOT reset in [encodeModule] so names stay unique across a package.
  int _tempVarCounter = 0;

  /// Used to emit a `__cascade_self__` placeholder for null-target nodes
  /// (PropertyAccess, IndexExpression, MethodInvocation) that implicitly
  /// refer to the cascade receiver.
  bool _inCascadeSection = false;

  static Expression get _cascadeSelfExpr =>
      Expression()..reference = (Reference()..name = '__cascade_self__');

  /// Collected import directives for metadata round-tripping.
  final List<Map<String, Object>> _importDetails = [];

  /// Collected export directives for metadata round-tripping.
  final List<Map<String, Object>> _exportDetails = [];

  /// Collected part directives for metadata round-tripping.
  final List<Map<String, Object>> _partDetails = [];

  /// If this file is a `part of` another library, this stores the URI.
  String? _partOfUri;

  /// Reports a warning/error about malformed metadata.
  /// In strict mode, throws [EncoderError]. Otherwise, adds to [warnings].
  void _warn(String message, {String? source}) {
    if (strict) throw EncoderError(message, source: source);
    warnings.add(source != null ? '$message at $source' : message);
  }

  /// Encode Dart source into a ball program.
  ///
  /// If [partResolver] is provided, the encoder will inline `part 'X.dart';`
  /// directives by calling the resolver with the URI string and parsing the
  /// returned source as additional declarations of the same library. Without
  /// a resolver, parts are recorded as metadata only and their declarations
  /// are silently dropped — which breaks any encode of a multi-file library.
  Program encode(
    String source, {
    String name = 'encoded',
    String version = '1.0.0',
    String Function(String uri)? partResolver,
  }) {
    _prefixToModule.clear();
    _importedModules.clear();
    _usedBaseFunctions.clear();
    _usedCollectionsFunctions.clear();
    _usedProtoFunctions.clear();
    _usedConvertFunctions.clear();
    _importDetails.clear();
    _exportDetails.clear();
    _partDetails.clear();
    _partOfUri = null;
    _tempVarCounter = 0;
    warnings.clear();
    // The encoded output always uses a single module named 'main'.
    _moduleName = 'main';

    final result = parseString(
      content: source,
      throwIfDiagnostics: false,
      featureSet: FeatureSet.latestLanguageVersion(),
    );
    final unit = result.unit;

    _resolveImports(unit);

    final partUnits = <ast.CompilationUnit>[];
    if (partResolver != null) {
      for (final directive in unit.directives) {
        if (directive is ast.PartDirective) {
          final uri = directive.uri.stringValue;
          if (uri == null) continue;
          final partSource = partResolver(uri);
          partUnits.add(
            parseString(
              content: partSource,
              throwIfDiagnostics: false,
              featureSet: FeatureSet.latestLanguageVersion(),
            ).unit,
          );
        }
      }
    }

    return _buildProgram(
      unit,
      name: name,
      version: version,
      partUnits: partUnits,
    );
  }

  /// Encode Dart source into a single ball [Module], accumulating used
  /// base-function names for later use by [buildStdModules].
  ///
  /// Unlike [encode], this does **not** reset [_usedBaseFunctions], so you
  /// can call it for every file in a package and then call [buildStdModules]
  /// once to obtain consolidated std modules for the whole package.
  ///
  /// [moduleName] is the ball module name to assign (e.g. `'lib.src.utils'`).
  ///
  /// [uriToModuleOverrides] maps raw import URI strings to ball module names,
  /// allowing relative and same-package imports to resolve correctly across
  /// files.  For example:
  /// ```dart
  /// {'src/models.dart': 'lib.src.models', '../utils.dart': 'lib.utils'}
  /// ```
  ///
  /// Returns the encoded [Module] plus any external-import stub modules that
  /// were not covered by [uriToModuleOverrides].
  ({Module module, List<Module> importStubs}) encodeModule(
    String source, {
    required String moduleName,
    Map<String, String> uriToModuleOverrides = const {},
  }) {
    final result = parseString(
      content: source,
      throwIfDiagnostics: false,
      featureSet: FeatureSet.latestLanguageVersion(),
    );
    return encodeModuleFromUnit(
      result.unit,
      moduleName: moduleName,
      uriToModuleOverrides: uriToModuleOverrides,
    );
  }

  /// Variant of [encodeModule] that accepts a pre-parsed [ast.CompilationUnit].
  ///
  /// Use this when you have already parsed the source (e.g. to inspect
  /// `part of` directives) and want to avoid parsing it a second time.
  ({Module module, List<Module> importStubs}) encodeModuleFromUnit(
    ast.CompilationUnit unit, {
    required String moduleName,
    Map<String, String> uriToModuleOverrides = const {},
  }) {
    _prefixToModule.clear();
    _importedModules.clear();
    _importDetails.clear();
    _exportDetails.clear();
    _moduleName = moduleName;
    // NOTE: _usedBaseFunctions is intentionally NOT cleared here so
    // PackageEncoder can accumulate across files.

    _resolveImports(unit, uriOverrides: uriToModuleOverrides);
    return _buildModule(unit, moduleName: moduleName);
  }

  /// Build consolidated std [Module]s from all base functions
  /// accumulated since the last [encode] call or manual [clearStdAccumulator].
  ///
  /// Use after a sequence of [encodeModule] calls to obtain the shared base
  /// modules for a whole package.
  ({Module stdModule, Module? collectionsModule, Module? protoModule})
  buildStdModules() => (
    stdModule: _buildStdModule(),
    collectionsModule: _buildCollectionsModule(),
    protoModule: _buildProtoModule(),
  );

  /// Clear the accumulated set of used base functions.
  ///
  /// Call this between encoding independent packages when reusing a single
  /// [DartEncoder] instance.
  void clearStdAccumulator() {
    _usedBaseFunctions.clear();
    _usedCollectionsFunctions.clear();
    _usedProtoFunctions.clear();
    _usedConvertFunctions.clear();
  }

  // ============================================================
  // Import resolution
  // ============================================================

  /// Map a Dart operator lexeme (`[]=`, `==`, `<`, `unary-`/`-`, …) to a
  /// canonical Ball method name. The result is a valid identifier in every
  /// target language Ball compiles to, so compilers don't need to know Dart
  /// operator syntax. Dart roundtripping reads `metadata['operator']` to
  /// recover the original lexeme.
  static String _canonicalOperatorName(String lexeme, {bool unary = false}) {
    switch (lexeme) {
      case '[]=':
        return '__op_set_index__';
      case '[]':
        return '__op_get_index__';
      case '==':
        return '__op_eq__';
      case '<':
        return '__op_lt__';
      case '<=':
        return '__op_le__';
      case '>':
        return '__op_gt__';
      case '>=':
        return '__op_ge__';
      case '<<':
        return '__op_shl__';
      case '>>':
        return '__op_shr__';
      case '>>>':
        return '__op_ushr__';
      case '+':
        return '__op_add__';
      case '-':
        return unary ? '__op_neg__' : '__op_sub__';
      case '*':
        return '__op_mul__';
      case '/':
        return '__op_div__';
      case '~/':
        return '__op_idiv__';
      case '%':
        return '__op_mod__';
      case '&':
        return '__op_band__';
      case '|':
        return '__op_bor__';
      case '^':
        return '__op_bxor__';
      case '~':
        return '__op_bnot__';
      default:
        return '__op_unknown_${lexeme.codeUnits.join('_')}__';
    }
  }

  static String uriToModuleName(String uri) {
    if (uri.startsWith('dart:')) {
      return 'dart.${uri.substring(5)}';
    }
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

  void _resolveImports(
    ast.CompilationUnit unit, {
    Map<String, String> uriOverrides = const {},
  }) {
    for (final directive in unit.directives) {
      if (directive is ast.ImportDirective) {
        final uriValue = directive.uri.stringValue;
        if (uriValue == null) {
          _warn('Import directive has null URI', source: directive.toSource());
        }
        final uri = uriValue ?? '';
        // Prefer an explicit override (e.g. resolved relative import).
        final moduleName = uriOverrides[uri] ?? uriToModuleName(uri);
        _importedModules.add(moduleName);

        final prefix = directive.prefix?.name;
        if (prefix != null) {
          _prefixToModule[prefix] = moduleName;
        }

        // Collect full import details for round-tripping.
        final detail = <String, Object>{'uri': uri};
        if (prefix != null) detail['prefix'] = prefix;
        final show = directive.combinators
            .whereType<ast.ShowCombinator>()
            .expand((c) => c.shownNames.map((n) => n.name))
            .toList();
        final hide = directive.combinators
            .whereType<ast.HideCombinator>()
            .expand((c) => c.hiddenNames.map((n) => n.name))
            .toList();
        if (show.isNotEmpty) detail['show'] = show;
        if (hide.isNotEmpty) detail['hide'] = hide;
        if (directive.deferredKeyword != null) detail['deferred'] = true;

        // Conditional import configurations like:
        //   import 'stub.dart'
        //     if (dart.library.io) 'io.dart'
        //     if (dart.library.js_interop) 'web.dart';
        if (directive.configurations.isNotEmpty) {
          detail['configurations'] = directive.configurations.map((c) {
            final cUri = c.uri.stringValue;
            if (cUri == null) {
              _warn('Configuration URI is null', source: c.toSource());
            }
            final m = <String, Object>{
              'name': c.name.toSource(),
              'uri': cUri ?? '',
            };
            if (c.value != null) {
              final cVal = c.value!.stringValue;
              if (cVal == null) {
                _warn('Configuration value is null', source: c.toSource());
              }
              m['value'] = cVal ?? '';
            }
            return m;
          }).toList();
        }

        _importDetails.add(detail);
      } else if (directive is ast.ExportDirective) {
        final uriValue = directive.uri.stringValue;
        if (uriValue == null) {
          _warn('Export directive has null URI', source: directive.toSource());
        }
        final uri = uriValue ?? '';
        final detail = <String, Object>{'uri': uri};
        final show = directive.combinators
            .whereType<ast.ShowCombinator>()
            .expand((c) => c.shownNames.map((n) => n.name))
            .toList();
        final hide = directive.combinators
            .whereType<ast.HideCombinator>()
            .expand((c) => c.hiddenNames.map((n) => n.name))
            .toList();
        if (show.isNotEmpty) detail['show'] = show;
        if (hide.isNotEmpty) detail['hide'] = hide;
        if (directive.configurations.isNotEmpty) {
          detail['configurations'] = directive.configurations.map((c) {
            final cUri = c.uri.stringValue;
            if (cUri == null) {
              _warn('Configuration URI is null', source: c.toSource());
            }
            final m = <String, Object>{
              'name': c.name.toSource(),
              'uri': cUri ?? '',
            };
            if (c.value != null) {
              final cVal = c.value!.stringValue;
              if (cVal == null) {
                _warn('Configuration value is null', source: c.toSource());
              }
              m['value'] = cVal ?? '';
            }
            return m;
          }).toList();
        }
        _exportDetails.add(detail);
      } else if (directive is ast.PartDirective) {
        final uriValue = directive.uri.stringValue;
        if (uriValue != null) {
          _partDetails.add(<String, Object>{'uri': uriValue});
        } else {
          _warn('Part directive has null URI');
        }
      } else if (directive is ast.PartOfDirective) {
        if (directive.uri != null) {
          _partOfUri = directive.uri?.stringValue;
        } else if (directive.libraryName != null) {
          _partOfUri = directive.libraryName?.toSource();
        } else {
          // Defensive: the Dart grammar requires `part of` to carry
          // either a URI string or an identifier, so valid source can
          // never reach this branch. We keep the warn as a tripwire in
          // case analyzer grammar evolves — strict-mode users will see
          // it immediately rather than getting silent data loss.
          _warn('Part-of directive has neither URI nor library name');
        }
      }
    }
  }

  // ============================================================
  // Program / module building
  // ============================================================

  Program _buildProgram(
    ast.CompilationUnit unit, {
    required String name,
    required String version,
    List<ast.CompilationUnit> partUnits = const [],
  }) {
    final (:module, :importStubs) = _buildModule(
      unit,
      moduleName: 'main',
      partUnits: partUnits,
    );
    final stdModule = _buildStdModule();
    final collectionsModule = _buildCollectionsModule();
    final protoModule = _buildProtoModule();
    final convertModule = _buildConvertModule();

    return Program()
      ..name = name
      ..version = version
      ..entryModule = 'main'
      ..entryFunction = 'main'
      ..modules.addAll([
        stdModule,
        ?collectionsModule,
        ?protoModule,
        ?convertModule,
        ...importStubs,
        module,
      ]);
  }

  /// Builds a single ball [Module] from a parsed compilation unit.
  ///
  /// [importStubs] are empty-body placeholder modules for external imports
  /// that were not resolved via [uriOverrides] in [_resolveImports].
  /// Base-function names used during encoding are **accumulated** into
  /// [_usedBaseFunctions] — call [_buildStdModule] afterwards to materialise
  /// them.
  ({Module module, List<Module> importStubs}) _buildModule(
    ast.CompilationUnit unit, {
    required String moduleName,
    List<ast.CompilationUnit> partUnits = const [],
  }) {
    final moduleTypes = <google.DescriptorProto>[];
    final moduleEnums = <google.EnumDescriptorProto>[];
    final moduleFunctions = <FunctionDefinition>[];
    final moduleTypeDefs = <TypeDefinition>[];
    final moduleTypeAliases = <TypeAlias>[];

    void encodeDecls(Iterable<ast.CompilationUnitMember> decls) {
      for (final decl in decls) {
        if (decl is ast.ClassDeclaration) {
          _encodeClassDeclaration(
            decl,
            moduleTypes,
            moduleFunctions,
            moduleTypeDefs,
          );
        } else if (decl is ast.MixinDeclaration) {
          _encodeMixinDeclaration(
            decl,
            moduleTypes,
            moduleFunctions,
            moduleTypeDefs,
          );
        } else if (decl is ast.EnumDeclaration) {
          _encodeEnumDeclaration(
            decl,
            moduleEnums,
            moduleFunctions,
            moduleTypeDefs,
          );
        } else if (decl is ast.ExtensionDeclaration) {
          _encodeExtensionDeclaration(decl, moduleFunctions, moduleTypeDefs);
        } else if (decl is ast.ExtensionTypeDeclaration) {
          _encodeExtensionTypeDeclaration(
            decl,
            moduleTypes,
            moduleFunctions,
            moduleTypeDefs,
          );
        } else if (decl is ast.FunctionDeclaration) {
          moduleFunctions.add(_encodeFunctionDeclaration(decl));
        } else if (decl is ast.TopLevelVariableDeclaration) {
          _encodeTopLevelVariable(decl, moduleFunctions);
        } else if (decl is ast.GenericTypeAlias) {
          _encodeTypeAlias(decl, moduleFunctions, moduleTypeAliases);
        }
      }
    }

    encodeDecls(unit.declarations);
    for (final partUnit in partUnits) {
      encodeDecls(partUnit.declarations);
    }

    // Stub modules for external imports (not overridden to an in-package module).
    final importStubs = <Module>[];
    final knownModuleNames = {'std', moduleName};
    List<String>? libraryAnnotations;
    for (final directive in unit.directives) {
      if (directive is ast.LibraryDirective && directive.metadata.isNotEmpty) {
        libraryAnnotations = _encodeAnnotations(directive.metadata);
      } else if (directive is ast.ImportDirective) {
        final uri = directive.uri.stringValue ?? '';
        final imName = uriToModuleName(uri);
        // Only emit a stub if not already known from previous stubs / the
        // in-package file map (in-package imports were overridden in
        // _resolveImports, so their uriToModuleName is a file-local name;
        // we rely on the caller — PackageEncoder — to deduplicate them).
        if (!knownModuleNames.contains(imName)) {
          knownModuleNames.add(imName);
          importStubs.add(
            Module()
              ..name = imName
              ..description = 'Imported from $uri',
          );
        }
      }
    }

    final importNames = ['std'];
    importNames.addAll(_importedModules);

    // Wrap legacy bare descriptors as TypeDefinitions, deduping by name in
    // favour of the richer entries already present in moduleTypeDefs (which
    // carry type params and metadata for the same-named type).
    final typeDefNames = moduleTypeDefs.map((td) => td.name).toSet();
    final wrappedModuleTypes = moduleTypes
        .where((d) => !typeDefNames.contains(d.name))
        .map(
          (d) => TypeDefinition()
            ..name = d.name
            ..descriptor = d,
        );

    final module = Module()
      ..name = moduleName
      ..moduleImports.addAll(importNames.map((n) => ModuleImport()..name = n))
      ..enums.addAll(moduleEnums)
      ..functions.addAll(moduleFunctions)
      ..typeDefs.addAll(wrappedModuleTypes)
      ..typeDefs.addAll(moduleTypeDefs)
      ..typeAliases.addAll(moduleTypeAliases);

    if (_importDetails.isNotEmpty ||
        _exportDetails.isNotEmpty ||
        _partDetails.isNotEmpty ||
        _partOfUri != null ||
        libraryAnnotations != null) {
      final meta = <String, Object>{};
      if (_importDetails.isNotEmpty) meta['dart_imports'] = _importDetails;
      if (_exportDetails.isNotEmpty) meta['dart_exports'] = _exportDetails;
      if (_partDetails.isNotEmpty) meta['dart_parts'] = _partDetails;
      if (_partOfUri != null) meta['dart_part_of'] = _partOfUri!;
      if (libraryAnnotations != null) {
        meta['library_annotations'] = libraryAnnotations;
      }
      module.metadata = _toStruct(meta);
    }

    return (module: module, importStubs: importStubs);
  }

  // ============================================================
  // Base module auto-discovery
  // ============================================================

  /// Returns the module name for a base function (always 'std').
  static String _moduleForFunction(String function) => 'std';

  Module _buildStdModule() {
    final types = <String, google.DescriptorProto>{};
    final functions = <FunctionDefinition>[];

    final stdFunctions = _usedBaseFunctions;

    if (stdFunctions.contains('print')) {
      types['PrintInput'] = google.DescriptorProto()
        ..name = 'PrintInput'
        ..field.add(
          google.FieldDescriptorProto()
            ..name = 'message'
            ..number = 1
            ..type = google.FieldDescriptorProto_Type.TYPE_STRING
            ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL,
        );
    }

    const binaryFunctions = {
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
      'concat',
      'bitwise_and',
      'bitwise_or',
      'bitwise_xor',
      'left_shift',
      'right_shift',
      'unsigned_right_shift',
      'null_coalesce',
    };
    if (stdFunctions.any(binaryFunctions.contains)) {
      types['BinaryInput'] = google.DescriptorProto()
        ..name = 'BinaryInput'
        ..field.addAll([
          google.FieldDescriptorProto()
            ..name = 'left'
            ..number = 1
            ..type = google.FieldDescriptorProto_Type.TYPE_INT64
            ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL,
          google.FieldDescriptorProto()
            ..name = 'right'
            ..number = 2
            ..type = google.FieldDescriptorProto_Type.TYPE_INT64
            ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL,
        ]);
    }

    const unaryFunctions = {
      'not',
      'negate',
      'bitwise_not',
      'int_to_string',
      'double_to_string',
      'string_to_int',
      'string_to_double',
      'to_string',
      'length',
      'throw',
      'await',
      'null_check',
      'pre_increment',
      'pre_decrement',
      'post_increment',
      'post_decrement',
      'yield',
    };
    if (stdFunctions.any(unaryFunctions.contains)) {
      types['UnaryInput'] = google.DescriptorProto()
        ..name = 'UnaryInput'
        ..field.add(
          google.FieldDescriptorProto()
            ..name = 'value'
            ..number = 1
            ..type = google.FieldDescriptorProto_Type.TYPE_STRING
            ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL,
        );
    }

    for (final name in stdFunctions) {
      functions.add(
        FunctionDefinition()
          ..name = name
          ..isBase = true,
      );
    }

    return Module()
      ..name = 'std'
      ..description = 'Universal standard library base module'
      ..typeDefs.addAll(
        types.values.map(
          (d) => TypeDefinition()
            ..name = d.name
            ..descriptor = d,
        ),
      )
      ..functions.addAll(functions);
  }

  Module? _buildCollectionsModule() {
    if (_usedCollectionsFunctions.isEmpty) return null;

    final functions = <FunctionDefinition>[];
    for (final name in _usedCollectionsFunctions.toList()..sort()) {
      functions.add(
        FunctionDefinition()
          ..name = name
          ..isBase = true,
      );
    }

    return Module()
      ..name = 'std_collections'
      ..description = 'Collections standard library base module'
      ..functions.addAll(functions);
  }

  Module? _buildProtoModule() {
    if (_usedProtoFunctions.isEmpty) return null;

    final functions = <FunctionDefinition>[];
    for (final name in _usedProtoFunctions.toList()..sort()) {
      functions.add(
        FunctionDefinition()
          ..name = name
          ..isBase = true,
      );
    }

    return Module()
      ..name = 'ball_proto'
      ..description = 'Protobuf compatibility layer for cross-language support'
      ..functions.addAll(functions);
  }

  /// Emits the std_convert base module (json/utf8/base64 codecs), filtered to
  /// the functions actually used. Reuses the canonical [buildStdConvertModule]
  /// so the function signatures + input typeDefs never drift from the runtime.
  Module? _buildConvertModule() {
    if (_usedConvertFunctions.isEmpty) return null;
    final full = buildStdConvertModule();
    final module = Module()
      ..name = full.name
      ..description = full.description;
    final neededTypes = <String>{};
    for (final fn in full.functions) {
      if (_usedConvertFunctions.contains(fn.name)) {
        module.functions.add(fn);
        if (fn.inputType.isNotEmpty) neededTypes.add(fn.inputType);
      }
    }
    for (final td in full.typeDefs) {
      if (neededTypes.contains(td.name)) module.typeDefs.add(td);
    }
    return module;
  }

  // ============================================================
  // Class declarations
  // ============================================================

  void _encodeClassDeclaration(
    ast.ClassDeclaration decl,
    List<google.DescriptorProto> types,
    List<FunctionDefinition> functions,
    List<TypeDefinition> typeDefs,
  ) {
    final className = decl.namePart.typeName.lexeme;
    // Ball convention: all user-defined types are prefixed with their module.
    final ballName = '$_moduleName:$className';
    final descriptor = google.DescriptorProto()..name = ballName;
    final classBody = decl.body as ast.BlockClassBody;

    var fieldNumber = 1;
    for (final member in classBody.members) {
      if (member is ast.FieldDeclaration) {
        if (member.isStatic) {
          _encodeStaticField(ballName, member, functions);
          continue;
        }
        final type = member.fields.type;
        for (final variable in member.fields.variables) {
          descriptor.field.add(
            google.FieldDescriptorProto()
              ..name = variable.name.lexeme
              ..number = fieldNumber++
              ..type = _dartTypeToProtoType(type?.toSource() ?? 'dynamic')
              ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL,
          );
        }
      }
    }

    types.add(descriptor);

    // Encode methods, constructors, getters/setters as functions.
    // Use ballName so FunctionDefinition.name has the form "module:Class.method".
    for (final member in classBody.members) {
      if (member is ast.MethodDeclaration) {
        functions.add(_encodeMethodDeclaration(ballName, member));
      } else if (member is ast.ConstructorDeclaration) {
        functions.add(_encodeConstructorDeclaration(ballName, member));
      }
    }

    // Build class metadata.
    final classMeta = <String, Object>{'kind': 'class'};
    final classAnnots = _encodeAnnotations(decl.metadata);
    if (classAnnots != null) classMeta['annotations'] = classAnnots;
    if (decl.abstractKeyword != null) classMeta['is_abstract'] = true;
    if (decl.sealedKeyword != null) classMeta['is_sealed'] = true;
    if (decl.baseKeyword != null) classMeta['is_base'] = true;
    if (decl.interfaceKeyword != null) classMeta['is_interface'] = true;
    if (decl.finalKeyword != null) classMeta['is_final'] = true;
    if (decl.mixinKeyword != null) classMeta['is_mixin_class'] = true;
    final ext = decl.extendsClause;
    if (ext != null) classMeta['superclass'] = ext.superclass.toSource();
    final impl = decl.implementsClause;
    if (impl != null) {
      classMeta['interfaces'] = impl.interfaces
          .map((t) => t.toSource())
          .toList();
    }
    final with_ = decl.withClause;
    if (with_ != null) {
      classMeta['mixins'] = with_.mixinTypes.map((t) => t.toSource()).toList();
    }
    if (decl.documentationComment != null) {
      classMeta['doc'] = decl.documentationComment!.toSource();
    }

    // Store field metadata for round-tripping.
    final fieldsMeta = <Map<String, Object>>[];
    for (final member in classBody.members) {
      if (member is ast.FieldDeclaration && !member.isStatic) {
        for (final variable in member.fields.variables) {
          final fm = <String, Object>{'name': variable.name.lexeme};
          final type = member.fields.type?.toSource();
          if (type != null) fm['type'] = type;
          if (member.fields.isFinal) fm['is_final'] = true;
          if (member.fields.isConst) fm['is_const'] = true;
          if (member.fields.isLate) fm['is_late'] = true;
          if (member.abstractKeyword != null) fm['is_abstract'] = true;
          if (variable.initializer != null) {
            fm['initializer'] = variable.initializer!.toSource();
          }
          fieldsMeta.add(fm);
        }
      }
    }
    if (fieldsMeta.isNotEmpty) classMeta['fields'] = fieldsMeta;

    // Build type parameters.
    final typeParams = <TypeParameter>[];
    final classTypeParams = decl.namePart.typeParameters;
    if (classTypeParams != null) {
      for (final tp in classTypeParams.typeParameters) {
        typeParams.add(TypeParameter(name: tp.toSource()));
      }
      classMeta['type_params'] = classTypeParams.typeParameters
          .map((t) => t.toSource())
          .toList();
    }

    // Emit first-class TypeDefinition with ball-qualified name.
    typeDefs.add(
      TypeDefinition(
        name: ballName,
        descriptor: descriptor,
        typeParams: typeParams,
        description: 'Class metadata for $ballName',
        metadata: _toStruct(classMeta),
      ),
    );
  }

  /// Encode a static field declaration as a standalone function with metadata.
  void _encodeStaticField(
    String ballClassName,
    ast.FieldDeclaration member,
    List<FunctionDefinition> functions,
  ) {
    for (final variable in member.fields.variables) {
      final varName = variable.name.lexeme;
      final def = FunctionDefinition()..name = '$ballClassName.$varName';

      final varType = member.fields.type?.toSource();
      if (varType != null) def.outputType = varType;

      if (variable.initializer != null) {
        def.body = _encodeExpr(variable.initializer!);
      }

      final meta = <String, Object>{'kind': 'static_field'};
      if (member.fields.isFinal) meta['is_final'] = true;
      if (member.fields.isConst) meta['is_const'] = true;
      if (member.fields.isLate) meta['is_late'] = true;
      def.metadata = _toStruct(meta);

      functions.add(def);
    }
  }

  FunctionDefinition _encodeMethodDeclaration(
    String className,
    ast.MethodDeclaration member,
  ) {
    final rawName = member.name.lexeme;
    // Operator methods (`operator []=`, `operator <`, …) carry Dart-specific
    // syntax in their lexeme. Translate to a canonical, language-agnostic
    // Ball name so target compilers don't have to know Dart's operator
    // grammar. The original lexeme is preserved in metadata['operator']
    // so the Dart compiler can round-trip back to the original syntax.
    String methodName = rawName;
    if (member.isOperator) {
      final isUnaryMinus =
          rawName == '-' && (member.parameters?.parameters.isEmpty ?? false);
      methodName = _canonicalOperatorName(rawName, unary: isUnaryMinus);
    }
    final def = FunctionDefinition()..name = '$className.$methodName';

    final returnType = member.returnType?.toSource();
    if (returnType != null) {
      def.outputType = returnType;
    }

    final params = member.parameters;
    if (params != null && params.parameters.isNotEmpty) {
      final first = params.parameters.first;
      if (first is ast.RegularFormalParameter && first.type != null) {
        def.inputType = first.type!.toSource();
      }
    }

    // Encode method body.
    //
    // Convention: `ExpressionFunctionBody` (e.g. `int f() => x + 1;`)
    // is encoded as a BARE expression, not wrapped in a block. Compilers
    // receiving a Ball program MUST handle both forms at the top-level
    // body position — bare expressions are NOT guaranteed to be blocks.
    // The `expression_body: true` metadata flag distinguishes the two.
    //
    // Known pitfalls if you forget this:
    //   - C++ compiler: bare body expressions needed routing through
    //     compile_statement so control-flow calls (try/if/labeled) hit
    //     their statement-context paths instead of a broken IIFE.
    //   - Dart compiler: must honor `expression_body: true` to emit
    //     `=> expr` form and `_hasNonVoidReturn` handling for the
    //     implicit return.
    final body = member.body;
    if (body is ast.ExpressionFunctionBody) {
      def.body = _encodeExpr(body.expression);
    } else if (body is ast.BlockFunctionBody) {
      def.body = _encodeBlock(
        body.block.statements,
        hasReturn: returnType != null && returnType != 'void',
      );
    }

    // Method metadata.
    final meta = <String, Object>{'kind': 'method'};
    if (member.isStatic) meta['is_static'] = true;
    if (member.isGetter) meta['is_getter'] = true;
    if (member.isSetter) meta['is_setter'] = true;
    if (member.isAbstract) meta['is_abstract'] = true;
    if (member.isOperator) {
      meta['is_operator'] = true;
      meta['operator'] = member.name.lexeme;
    }
    if (body is ast.ExpressionFunctionBody) meta['expression_body'] = true;
    if (member.body.isAsynchronous) meta['is_async'] = true;
    if (member.body.isSynchronous && member.body.star != null) {
      meta['is_sync_star'] = true;
    }
    if (member.body.isAsynchronous && member.body.star != null) {
      meta['is_async_star'] = true;
    }
    if (member.externalKeyword != null) meta['is_external'] = true;
    _encodeParamsMeta(params, meta);
    if (member.typeParameters != null) {
      meta['type_params'] = member.typeParameters!.typeParameters
          .map((t) => t.toSource())
          .toList();
    }
    final annots = _encodeAnnotations(member.metadata);
    if (annots != null) meta['annotations'] = annots;
    if (member.documentationComment != null) {
      meta['doc'] = member.documentationComment!.toSource();
    }
    def.metadata = _toStruct(meta);

    return def;
  }

  FunctionDefinition _encodeConstructorDeclaration(
    String className,
    ast.ConstructorDeclaration member,
  ) {
    final ctorName = member.name?.lexeme;
    final qualName = ctorName != null
        ? '$className.$ctorName'
        : '$className.new';

    final def = FunctionDefinition()
      ..name = qualName
      ..outputType = className;

    final body = member.body;
    if (body is ast.ExpressionFunctionBody) {
      def.body = _encodeExpr(body.expression);
    } else if (body is ast.BlockFunctionBody) {
      def.body = _encodeBlock(body.block.statements, hasReturn: false);
    }

    final meta = <String, Object>{'kind': 'constructor'};
    if (member.constKeyword != null) meta['is_const'] = true;
    if (member.factoryKeyword != null) meta['is_factory'] = true;
    if (member.externalKeyword != null) meta['is_external'] = true;
    if (body is ast.ExpressionFunctionBody) meta['expression_body'] = true;
    if (member.redirectedConstructor != null) {
      meta['redirects_to'] = member.redirectedConstructor!.toSource();
    }
    final ctorAnnots = _encodeAnnotations(member.metadata);
    if (ctorAnnots != null) meta['annotations'] = ctorAnnots;

    // Initializer list.
    if (member.initializers.isNotEmpty) {
      final inits = <Map<String, Object>>[];
      for (final init in member.initializers) {
        if (init is ast.ConstructorFieldInitializer) {
          inits.add({
            'kind': 'field',
            'name': init.fieldName.name,
            'value': init.expression.toSource(),
          });
        } else if (init is ast.SuperConstructorInvocation) {
          final superInit = <String, Object>{'kind': 'super'};
          if (init.constructorName != null) {
            superInit['name'] = init.constructorName!.name;
          }
          superInit['args'] = init.argumentList.toSource();
          inits.add(superInit);
        } else if (init is ast.RedirectingConstructorInvocation) {
          final redir = <String, Object>{'kind': 'redirect'};
          if (init.constructorName != null) {
            redir['name'] = init.constructorName!.name;
          }
          redir['args'] = init.argumentList.toSource();
          inits.add(redir);
        } else if (init is ast.AssertInitializer) {
          inits.add({
            'kind': 'assert',
            'condition': init.condition.toSource(),
            if (init.message != null) 'message': init.message!.toSource(),
          });
        }
      }
      if (inits.isNotEmpty) meta['initializers'] = inits;
    }

    _encodeParamsMeta(member.parameters, meta);
    def.metadata = _toStruct(meta);

    return def;
  }

  // ============================================================
  // Mixin / Enum / Extension / TypeAlias / TopLevelVariable
  // ============================================================

  void _encodeMixinDeclaration(
    ast.MixinDeclaration decl,
    List<google.DescriptorProto> types,
    List<FunctionDefinition> functions,
    List<TypeDefinition> typeDefs,
  ) {
    final mixinName = decl.name.lexeme;
    final ballName = '$_moduleName:$mixinName';
    final descriptor = google.DescriptorProto()..name = ballName;

    var fieldNumber = 1;
    for (final member in decl.body.members) {
      if (member is ast.FieldDeclaration) {
        final type = member.fields.type;
        for (final variable in member.fields.variables) {
          descriptor.field.add(
            google.FieldDescriptorProto()
              ..name = variable.name.lexeme
              ..number = fieldNumber++
              ..type = _dartTypeToProtoType(type?.toSource() ?? 'dynamic')
              ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL,
          );
        }
      }
    }
    types.add(descriptor);

    for (final member in decl.body.members) {
      if (member is ast.MethodDeclaration) {
        functions.add(_encodeMethodDeclaration(ballName, member));
      }
    }

    final meta = <String, Object>{'kind': 'mixin'};
    final mixinAnnots = _encodeAnnotations(decl.metadata);
    if (mixinAnnots != null) meta['annotations'] = mixinAnnots;
    if (decl.onClause != null) {
      meta['on'] = decl.onClause!.superclassConstraints
          .map((t) => t.toSource())
          .toList();
    }
    if (decl.implementsClause != null) {
      meta['interfaces'] = decl.implementsClause!.interfaces
          .map((t) => t.toSource())
          .toList();
    }
    final typeParams = <TypeParameter>[];
    if (decl.typeParameters != null) {
      for (final tp in decl.typeParameters!.typeParameters) {
        typeParams.add(TypeParameter(name: tp.toSource()));
      }
      meta['type_params'] = decl.typeParameters!.typeParameters
          .map((t) => t.toSource())
          .toList();
    }
    if (decl.baseKeyword != null) meta['is_base'] = true;
    if (decl.documentationComment != null) {
      meta['doc'] = decl.documentationComment!.toSource();
    }
    typeDefs.add(
      TypeDefinition(
        name: ballName,
        descriptor: descriptor,
        typeParams: typeParams,
        description: 'Mixin metadata for $ballName',
        metadata: _toStruct(meta),
      ),
    );
  }

  void _encodeEnumDeclaration(
    ast.EnumDeclaration decl,
    List<google.EnumDescriptorProto> enums,
    List<FunctionDefinition> functions,
    List<TypeDefinition> typeDefs,
  ) {
    final enumName = decl.namePart.typeName.lexeme;
    final ballName = '$_moduleName:$enumName';
    final descriptor = google.EnumDescriptorProto()..name = ballName;

    var valueNumber = 0;
    for (final constant in decl.body.constants) {
      descriptor.value.add(
        google.EnumValueDescriptorProto()
          ..name = constant.name.lexeme
          ..number = valueNumber++,
      );
    }
    enums.add(descriptor);

    for (final member in decl.body.members) {
      if (member is ast.MethodDeclaration) {
        functions.add(_encodeMethodDeclaration(ballName, member));
      } else if (member is ast.ConstructorDeclaration) {
        functions.add(_encodeConstructorDeclaration(ballName, member));
      }
    }

    // Encode enum fields (like `final double gravity;`) in metadata.
    final enumFields = <Map<String, Object>>[];
    for (final member in decl.body.members) {
      if (member is ast.FieldDeclaration) {
        for (final variable in member.fields.variables) {
          final fm = <String, Object>{'name': variable.name.lexeme};
          final type = member.fields.type?.toSource();
          if (type != null) fm['type'] = type;
          if (member.fields.isFinal) fm['is_final'] = true;
          if (member.fields.isConst) fm['is_const'] = true;
          if (member.fields.isLate) fm['is_late'] = true;
          if (member.isStatic) fm['is_static'] = true;
          enumFields.add(fm);
        }
      }
    }

    final meta = <String, Object>{'kind': 'enum'};
    if (enumFields.isNotEmpty) meta['fields'] = enumFields;
    if (decl.implementsClause != null) {
      meta['interfaces'] = decl.implementsClause!.interfaces
          .map((t) => t.toSource())
          .toList();
    }
    if (decl.withClause != null) {
      meta['mixins'] = decl.withClause!.mixinTypes
          .map((t) => t.toSource())
          .toList();
    }
    // Enum value constructor arguments.
    final values = <Map<String, Object>>[];
    for (final constant in decl.body.constants) {
      final v = <String, Object>{'name': constant.name.lexeme};
      if (constant.arguments != null) {
        v['args'] = constant.arguments!.toSource();
      }
      if (constant.documentationComment != null) {
        v['doc'] = constant.documentationComment!.toSource();
      }
      values.add(v);
    }
    if (values.isNotEmpty) meta['values'] = values;
    final enumTypeParams = decl.namePart.typeParameters;
    if (enumTypeParams != null) {
      meta['type_params'] = enumTypeParams.typeParameters
          .map((t) => t.toSource())
          .toList();
    }
    if (decl.documentationComment != null) {
      meta['doc'] = decl.documentationComment!.toSource();
    }
    typeDefs.add(
      TypeDefinition(
        name: ballName,
        description: 'Enum metadata for $ballName',
        metadata: _toStruct(meta),
      ),
    );
  }

  /// Counter shared across all unnamed extension declarations within a single
  /// module encoding run, so multiple `extension on T { ... }` clauses
  /// in the same file produce distinct Ball-level names (and therefore
  /// distinct typeDefs + method-to-extension routing).
  int _unnamedExtensionCounter = 0;

  void _encodeExtensionDeclaration(
    ast.ExtensionDeclaration decl,
    List<FunctionDefinition> functions,
    List<TypeDefinition> typeDefs,
  ) {
    String extName;
    if (decl.name == null) {
      final idx = _unnamedExtensionCounter++;
      _warn(
        'Extension declaration has no name; using '
        '"_unnamed_extension_$idx"',
      );
      extName = '_unnamed_extension_$idx';
    } else {
      extName = decl.name!.lexeme;
    }
    // The prefix `_unnamed_extension` (with optional _<n> suffix) signals
    // to the compiler to emit an anonymous `extension on T { ... }`.
    final ballName = extName.startsWith('_unnamed_extension')
        ? extName
        : '$_moduleName:$extName';
    for (final member in decl.body.members) {
      if (member is ast.MethodDeclaration) {
        functions.add(_encodeMethodDeclaration(ballName, member));
      }
    }

    final meta = <String, Object>{'kind': 'extension'};
    final extAnnots = _encodeAnnotations(decl.metadata);
    if (extAnnots != null) meta['annotations'] = extAnnots;
    if (decl.onClause != null) {
      meta['on'] = decl.onClause!.extendedType.toSource();
    }
    final typeParams = <TypeParameter>[];
    if (decl.typeParameters != null) {
      for (final tp in decl.typeParameters!.typeParameters) {
        typeParams.add(TypeParameter(name: tp.toSource()));
      }
      meta['type_params'] = decl.typeParameters!.typeParameters
          .map((t) => t.toSource())
          .toList();
    }
    if (decl.documentationComment != null) {
      meta['doc'] = decl.documentationComment!.toSource();
    }
    typeDefs.add(
      TypeDefinition(
        name: ballName,
        typeParams: typeParams,
        description: 'Extension metadata for $ballName',
        metadata: _toStruct(meta),
      ),
    );
  }

  /// Encode a `extension type Foo(Type field) implements Bar { ... }` declaration.
  void _encodeExtensionTypeDeclaration(
    ast.ExtensionTypeDeclaration decl,
    List<google.DescriptorProto> types,
    List<FunctionDefinition> functions,
    List<TypeDefinition> typeDefs,
  ) {
    final pc = decl.primaryConstructor;
    final typeName = pc.typeName.lexeme;
    final ballName = '$_moduleName:$typeName';
    final descriptor = google.DescriptorProto()..name = ballName;

    // Instance fields (non-representation) stored in the descriptor.
    var fieldNumber = 1;
    for (final member in decl.body.members) {
      if (member is ast.FieldDeclaration && !member.isStatic) {
        final type = member.fields.type;
        for (final variable in member.fields.variables) {
          descriptor.field.add(
            google.FieldDescriptorProto()
              ..name = variable.name.lexeme
              ..number = fieldNumber++
              ..type = _dartTypeToProtoType(type?.toSource() ?? 'dynamic')
              ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL,
          );
        }
      }
    }

    types.add(descriptor);

    // Encode methods / constructors / getters / setters / static fields.
    for (final member in decl.body.members) {
      if (member is ast.MethodDeclaration) {
        functions.add(_encodeMethodDeclaration(ballName, member));
      } else if (member is ast.ConstructorDeclaration) {
        functions.add(_encodeConstructorDeclaration(ballName, member));
      } else if (member is ast.FieldDeclaration && member.isStatic) {
        _encodeStaticField(ballName, member, functions);
      }
    }

    // ── Metadata ────────────────────────────────────────────────────────
    final meta = <String, Object>{'kind': 'extension_type'};
    final etAnnots = _encodeAnnotations(decl.metadata);
    if (etAnnots != null) meta['annotations'] = etAnnots;

    // Representation declaration — extracted from the primary constructor's
    // formal parameters (the single declaring parameter).
    final params = pc.formalParameters.parameters;
    if (params.isNotEmpty) {
      final repParam = params.first;
      meta['rep_type'] = repParam.isNamed
          ? repParam.toSource()
          : (repParam is ast.RegularFormalParameter
                ? (repParam.type?.toSource() ?? 'dynamic')
                : repParam.toSource());
      if (repParam is ast.RegularFormalParameter) {
        if (repParam.name == null) {
          _warn(
            'Representation parameter has no name',
            source: repParam.toSource(),
          );
        }
        meta['rep_field'] = repParam.name?.lexeme ?? '';
      }
    }
    if (pc.constructorName != null) {
      meta['rep_constructor_name'] = pc.constructorName!.name.lexeme;
    }

    if (pc.constKeyword != null) meta['is_const'] = true;

    final impl = decl.implementsClause;
    if (impl != null) {
      meta['interfaces'] = impl.interfaces.map((t) => t.toSource()).toList();
    }

    if (decl.documentationComment != null) {
      meta['doc'] = decl.documentationComment!.toSource();
    }

    // Field metadata for non-representation instance fields.
    final fieldsMeta = <Map<String, Object>>[];
    for (final member in decl.body.members) {
      if (member is ast.FieldDeclaration && !member.isStatic) {
        for (final variable in member.fields.variables) {
          final fm = <String, Object>{'name': variable.name.lexeme};
          final type = member.fields.type?.toSource();
          if (type != null) fm['type'] = type;
          if (member.fields.isFinal) fm['is_final'] = true;
          if (member.fields.isConst) fm['is_const'] = true;
          if (member.fields.isLate) fm['is_late'] = true;
          if (member.abstractKeyword != null) fm['is_abstract'] = true;
          if (variable.initializer != null) {
            fm['initializer'] = variable.initializer!.toSource();
          }
          fieldsMeta.add(fm);
        }
      }
    }
    if (fieldsMeta.isNotEmpty) meta['fields'] = fieldsMeta;

    // Type parameters.
    final typeParams = <TypeParameter>[];
    if (pc.typeParameters != null) {
      for (final tp in pc.typeParameters!.typeParameters) {
        typeParams.add(TypeParameter(name: tp.toSource()));
      }
      meta['type_params'] = pc.typeParameters!.typeParameters
          .map((t) => t.toSource())
          .toList();
    }

    typeDefs.add(
      TypeDefinition(
        name: ballName,
        descriptor: descriptor,
        typeParams: typeParams,
        description: 'Extension type metadata for $ballName',
        metadata: _toStruct(meta),
      ),
    );
  }

  void _encodeTopLevelVariable(
    ast.TopLevelVariableDeclaration decl,
    List<FunctionDefinition> functions,
  ) {
    for (final variable in decl.variables.variables) {
      final varName = variable.name.lexeme;
      final def = FunctionDefinition()..name = varName;

      final varType = decl.variables.type?.toSource();
      if (varType != null) def.outputType = varType;

      if (variable.initializer != null) {
        def.body = _encodeExpr(variable.initializer!);
      }

      final meta = <String, Object>{'kind': 'top_level_variable'};
      if (decl.variables.isFinal) meta['is_final'] = true;
      if (decl.variables.isConst) meta['is_const'] = true;
      if (decl.variables.isLate) meta['is_late'] = true;
      if (decl.documentationComment != null) {
        meta['doc'] = decl.documentationComment!.toSource();
      }
      def.metadata = _toStruct(meta);

      functions.add(def);
    }
  }

  void _encodeTypeAlias(
    ast.GenericTypeAlias decl,
    List<FunctionDefinition> functions,
    List<TypeAlias> typeAliases,
  ) {
    final aliasName = decl.name.lexeme;
    final meta = <String, Object>{
      'kind': 'typedef',
      'aliased_type': decl.type.toSource(),
    };
    final typeParams = <TypeParameter>[];
    if (decl.typeParameters != null) {
      for (final tp in decl.typeParameters!.typeParameters) {
        typeParams.add(TypeParameter(name: tp.toSource()));
      }
      meta['type_params'] = decl.typeParameters!.typeParameters
          .map((t) => t.toSource())
          .toList();
    }
    if (decl.documentationComment != null) {
      meta['doc'] = decl.documentationComment!.toSource();
    }
    // Emit first-class TypeAlias.
    typeAliases.add(
      TypeAlias(
        name: aliasName,
        targetType: decl.type.toSource(),
        typeParams: typeParams,
        metadata: _toStruct(meta),
      ),
    );
  }

  // ============================================================
  // Function declarations
  // ============================================================

  FunctionDefinition _encodeFunctionDeclaration(ast.FunctionDeclaration decl) {
    final def = FunctionDefinition()..name = decl.name.lexeme;

    final returnTypeNode = decl.returnType;
    final returnType = returnTypeNode?.toSource();
    if (returnType != null) {
      def.outputType = returnType;
    }

    final params = decl.functionExpression.parameters;
    if (params != null && params.parameters.isNotEmpty) {
      final first = params.parameters.first;
      if (first is ast.RegularFormalParameter && first.type != null) {
        def.inputType = first.type!.toSource();
      }
    }

    final body = decl.functionExpression.body;
    if (body is ast.ExpressionFunctionBody) {
      def.body = _encodeExpr(body.expression);
    } else if (body is ast.BlockFunctionBody) {
      def.body = _encodeBlock(
        body.block.statements,
        hasReturn: returnType != null && returnType != 'void',
      );
    }

    final meta = <String, Object>{'kind': 'function'};
    if (body is ast.ExpressionFunctionBody) meta['expression_body'] = true;
    if (decl.isGetter) meta['is_getter'] = true;
    if (decl.isSetter) meta['is_setter'] = true;
    if (decl.externalKeyword != null) meta['is_external'] = true;
    if (body.isAsynchronous) meta['is_async'] = true;
    if (body.isSynchronous && body.star != null) meta['is_sync_star'] = true;
    if (body.isAsynchronous && body.star != null) meta['is_async_star'] = true;
    _encodeParamsMeta(params, meta);
    if (decl.functionExpression.typeParameters != null) {
      meta['type_params'] = decl
          .functionExpression
          .typeParameters!
          .typeParameters
          .map((t) => t.toSource())
          .toList();
    }
    if (decl.documentationComment != null) {
      meta['doc'] = decl.documentationComment!.toSource();
    }
    final annots = _encodeAnnotations(decl.metadata);
    if (annots != null) meta['annotations'] = annots;
    def.metadata = _toStruct(meta);

    return def;
  }

  // ============================================================
  // Statement encoding
  // ============================================================

  Expression _encodeBlock(
    List<ast.Statement> statements, {
    required bool hasReturn,
  }) {
    if (statements.length == 1) {
      final s = statements.first;
      // Don't shortcut multi-variable declarations.
      if (s is! ast.VariableDeclarationStatement ||
          s.variables.variables.length <= 1) {
        return _encodeSingleStatement(s, hasReturn: hasReturn);
      }
    }

    final block = Block();
    for (var i = 0; i < statements.length; i++) {
      final stmt = statements[i];
      final isLast = i == statements.length - 1;

      if (isLast && hasReturn && stmt is ast.ReturnStatement) {
        if (stmt.expression != null) {
          block.result = _encodeExpr(stmt.expression!);
        }
      } else if (stmt is ast.VariableDeclarationStatement &&
          stmt.variables.variables.length > 1) {
        // Multi-variable declaration: emit one LetBinding per variable.
        for (final variable in stmt.variables.variables) {
          block.statements.add(_encodeVarDeclEntry(stmt, variable));
        }
      } else if (stmt is ast.PatternVariableDeclarationStatement) {
        // Record destructuring (`final (a, b) = rec;`): splice the temp + bind
        // lets directly into THIS block so the bound names stay visible to
        // later statements (and the block result). Falls back to the wrapped
        // form for patterns we cannot destructure.
        final spliced = _tryEncodePatternVarDeclStatements(stmt.declaration);
        if (spliced != null) {
          block.statements.addAll(spliced);
        } else {
          block.statements.add(_encodeStatement(stmt));
        }
      } else {
        block.statements.add(_encodeStatement(stmt));
      }
    }

    return Expression()..block = block;
  }

  Expression _encodeSingleStatement(
    ast.Statement stmt, {
    required bool hasReturn,
  }) {
    if (stmt is ast.ReturnStatement && stmt.expression != null) {
      if (hasReturn) {
        // Strip the return — value will be used as the implicit block result.
        return _encodeExpr(stmt.expression!);
      }
      // Preserve explicit return as std.return(value: ...).
      _usedBaseFunctions.add('return');
      return _buildStdCall('return', [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(stmt.expression!),
      ]);
    }
    if (stmt is ast.ExpressionStatement) {
      return _encodeExpr(stmt.expression);
    }
    if (stmt is ast.IfStatement) {
      return _encodeIfStatement(stmt, hasReturn: hasReturn);
    }
    if (stmt is ast.VariableDeclarationStatement) {
      final block = Block();
      block.statements.add(_encodeStatement(stmt));
      return Expression()..block = block;
    }
    final block = Block();
    block.statements.add(_encodeStatement(stmt));
    return Expression()..block = block;
  }

  Statement _encodeStatement(ast.Statement stmt) {
    if (stmt is ast.VariableDeclarationStatement) {
      return _encodeVarDeclStatement(stmt);
    }
    if (stmt is ast.ExpressionStatement) {
      return Statement()..expression = _encodeExpr(stmt.expression);
    }
    if (stmt is ast.ReturnStatement) {
      _usedBaseFunctions.add('return');
      return Statement()
        ..expression = _buildStdCall('return', [
          if (stmt.expression != null)
            FieldValuePair()
              ..name = 'value'
              ..value = _encodeExpr(stmt.expression!),
        ]);
    }
    if (stmt is ast.IfStatement) {
      return Statement()
        ..expression = _encodeIfStatement(stmt, hasReturn: false);
    }
    if (stmt is ast.ForStatement) {
      return Statement()..expression = _encodeForStatement(stmt);
    }
    if (stmt is ast.WhileStatement) {
      return Statement()..expression = _encodeWhileStatement(stmt);
    }
    if (stmt is ast.DoStatement) {
      return Statement()..expression = _encodeDoWhileStatement(stmt);
    }
    if (stmt is ast.ForPartsWithDeclarations ||
        stmt is ast.ForPartsWithExpression) {
      // Handled inside _encodeForStatement
    }
    if (stmt is ast.SwitchStatement) {
      return Statement()..expression = _encodeSwitchStatement(stmt);
    }
    if (stmt is ast.TryStatement) {
      return Statement()..expression = _encodeTryStatement(stmt);
    }
    if (stmt is ast.BreakStatement) {
      _usedBaseFunctions.add('break');
      return Statement()
        ..expression = _buildStdCall('break', [
          if (stmt.label != null)
            FieldValuePair()
              ..name = 'label'
              ..value = (Expression()
                ..literal = (Literal()..stringValue = stmt.label!.name.lexeme)),
        ]);
    }
    if (stmt is ast.ContinueStatement) {
      _usedBaseFunctions.add('continue');
      return Statement()
        ..expression = _buildStdCall('continue', [
          if (stmt.label != null)
            FieldValuePair()
              ..name = 'label'
              ..value = (Expression()
                ..literal = (Literal()..stringValue = stmt.label!.name.lexeme)),
        ]);
    }
    if (stmt is ast.AssertStatement) {
      _usedBaseFunctions.add('assert');
      return Statement()
        ..expression = _buildStdCall('assert', [
          FieldValuePair()
            ..name = 'condition'
            ..value = _encodeExpr(stmt.condition),
          if (stmt.message != null)
            FieldValuePair()
              ..name = 'message'
              ..value = _encodeExpr(stmt.message!),
        ]);
    }
    if (stmt is ast.YieldStatement) {
      final fn = stmt.star != null ? 'yield_each' : 'yield';
      _usedBaseFunctions.add(fn);
      return Statement()
        ..expression = _buildStdCall(fn, [
          FieldValuePair()
            ..name = 'value'
            ..value = _encodeExpr(stmt.expression),
        ]);
    }
    if (stmt is ast.LabeledStatement) {
      _usedBaseFunctions.add('labeled');
      return Statement()
        ..expression = _buildStdCall('labeled', [
          FieldValuePair()
            ..name = 'label'
            ..value = (Expression()
              ..literal = (Literal()
                ..stringValue = stmt.labels.first.name.lexeme)),
          FieldValuePair()
            ..name = 'body'
            ..value = (Expression()
              ..block = (Block()
                ..statements.add(_encodeStatement(stmt.statement)))),
        ]);
    }
    if (stmt is ast.FunctionDeclarationStatement) {
      // Local function — encode as a LetBinding with a FunctionDefinition value.
      final funcDecl = stmt.functionDeclaration;
      final funcName = funcDecl.name.lexeme;
      final params = funcDecl.functionExpression.parameters;

      final body = funcDecl.functionExpression.body;
      Expression bodyExpr;
      if (body is ast.ExpressionFunctionBody) {
        bodyExpr = _encodeExpr(body.expression);
      } else if (body is ast.BlockFunctionBody) {
        final returnType = funcDecl.returnType?.toSource();
        bodyExpr = _encodeBlock(
          body.block.statements,
          hasReturn: returnType != null && returnType != 'void',
        );
      } else {
        bodyExpr = Expression()..literal = Literal();
      }

      final lambdaDef = FunctionDefinition()
        ..name = funcName
        ..body = bodyExpr;
      if (funcDecl.returnType != null) {
        lambdaDef.outputType = funcDecl.returnType!.toSource();
      }
      final meta = <String, Object>{'kind': 'local_function'};
      if (body is ast.ExpressionFunctionBody) meta['expression_body'] = true;
      if (body.isAsynchronous) meta['is_async'] = true;
      if (body.isSynchronous && body.star != null) meta['is_sync_star'] = true;
      if (body.isAsynchronous && body.star != null)
        meta['is_async_star'] = true;
      _encodeParamsMeta(params, meta);
      lambdaDef.metadata = _toStruct(meta);

      return Statement()
        ..let = (LetBinding()
          ..name = funcName
          ..value = (Expression()..lambda = lambdaDef));
    }
    if (stmt is ast.Block) {
      final block = Block();
      for (final s in stmt.statements) {
        if (s is ast.PatternVariableDeclarationStatement) {
          // Record destructuring: splice bind lets as siblings so they stay
          // visible to the rest of this block (no extra child scope).
          final spliced = _tryEncodePatternVarDeclStatements(s.declaration);
          if (spliced != null) {
            block.statements.addAll(spliced);
            continue;
          }
        }
        block.statements.add(_encodeStatement(s));
      }
      return Statement()..expression = (Expression()..block = block);
    }
    // Dart 3 pattern-variable declaration:
    //   `var (a, b) = pair;`
    //   `final (x, y: name) = record;`
    // The pattern destructures a record/list/map/object into named
    // variables. We can't faithfully model arbitrary patterns in Ball,
    // but the common record form `(a, b, ..)` can round-trip by
    // (1) evaluating the RHS into a temp,
    // (2) declaring each variable bound to the matching field.
    if (stmt is ast.PatternVariableDeclarationStatement) {
      final decl = stmt.declaration;
      final encoded = _tryEncodePatternVarDecl(decl);
      if (encoded != null) return encoded;
    }
    // Empty statement (bare `;`): encode as a no-op literal null.
    if (stmt is ast.EmptyStatement) {
      return Statement()..expression = (Expression()..literal = Literal());
    }
    // Unsupported statement — store sourc as string literal for round-tripping.
    return Statement()
      ..expression = (Expression()
        ..literal = (Literal()
          ..stringValue =
              '/* unsupported: ${stmt.runtimeType}: ${stmt.toSource()} */'));
  }

  /// Flat-statement form of record destructuring (`var (a, b, ...) = rhs;`).
  /// Returns the temp + bind `let` statements WITHOUT wrapping them in a block,
  /// so callers can splice them directly into the enclosing block — keeping the
  /// bound names visible to later statements (record destructuring introduces
  /// NO child scope, matching Dart semantics and the C++ compiler's all-let
  /// inline emission).
  ///
  /// Returns `null` if the pattern isn't a simple record of simple binds
  /// — in that case the caller falls back to the unsupported-literal path.
  List<Statement>? _tryEncodePatternVarDeclStatements(
    ast.PatternVariableDeclaration decl,
  ) {
    final pat = decl.pattern;
    if (pat is! ast.RecordPattern) return null;

    // Collect positional bind names; fail if anything is non-trivial.
    final binds = <({String name, int? positionalIndex, String? label})>[];
    var positionalIdx = 0;
    for (final f in pat.fields) {
      final inner = f.pattern;
      if (inner is! ast.DeclaredVariablePattern) return null;
      final label = f.name?.name?.lexeme;
      binds.add((
        name: inner.name.lexeme,
        positionalIndex: label == null ? positionalIdx : null,
        label: label,
      ));
      if (label == null) positionalIdx++;
    }

    // Emit:
    //   final __ball_rec_N = <rhs>;
    //   final a = __ball_rec_N.$1;
    //   final b = __ball_rec_N.$2;
    //   final name = __ball_rec_N.name;
    final tempName = '__ball_rec_${_patternVarCounter++}';
    final stmts = <Statement>[
      Statement()
        ..let = (LetBinding()
          ..name = tempName
          ..value = _encodeExpr(decl.expression)),
    ];
    for (final b in binds) {
      // Positional fields are 1-based (`.$1`, `.$2`) — matching
      // _encodeRecordLiteral and Dart's positional record getters.
      final field = b.label ?? '\$${(b.positionalIndex ?? 0) + 1}';
      stmts.add(
        Statement()
          ..let = (LetBinding()
            ..name = b.name
            ..value = (Expression()
              ..fieldAccess = (FieldAccess()
                ..object = (Expression()
                  ..reference = (Reference()..name = tempName))
                ..field_2 = field))),
      );
    }
    return stmts;
  }

  /// Block-wrapped form of [_tryEncodePatternVarDeclStatements], for
  /// single-statement contexts that need a single `Statement`. Prefer splicing
  /// the flat form into the enclosing block (see [_encodeBlock]) so the bound
  /// names stay in scope for later statements.
  Statement? _tryEncodePatternVarDecl(ast.PatternVariableDeclaration decl) {
    final stmts = _tryEncodePatternVarDeclStatements(decl);
    if (stmts == null) return null;
    final block = Block()..statements.addAll(stmts);
    return Statement()..expression = (Expression()..block = block);
  }

  int _patternVarCounter = 0;

  Statement _encodeVarDeclStatement(ast.VariableDeclarationStatement stmt) {
    return _encodeVarDeclEntry(stmt, stmt.variables.variables.first);
  }

  /// Encode a single [variable] from a [VariableDeclarationStatement].
  /// Used for multi-variable declarations like `var a = 1, b = 2;`.
  Statement _encodeVarDeclEntry(
    ast.VariableDeclarationStatement stmt,
    ast.VariableDeclaration variable,
  ) {
    final name = variable.name.lexeme;
    final init = variable.initializer;

    final let = LetBinding()
      ..name = name
      ..value = (init != null
          ? _encodeExpr(init)
          // No initializer: emit a sentinel so the compiler knows not to
          // produce ` = /* unknown expression */`.
          : (Expression()..reference = (Reference()..name = '__no_init__')));

    // Store var/final/const/late and explicit type in metadata.
    final meta = <String, Object>{};
    if (stmt.variables.isFinal) {
      meta['keyword'] = 'final';
    } else if (stmt.variables.isConst) {
      meta['keyword'] = 'const';
    } else {
      meta['keyword'] = 'var';
    }
    if (stmt.variables.isLate) meta['is_late'] = true;
    final typeNode = stmt.variables.type;
    if (typeNode != null) meta['type'] = typeNode.toSource();
    if (meta.isNotEmpty) let.metadata = _toStruct(meta);

    return Statement()..let = let;
  }

  /// Encode a [VariableDeclarationList] (e.g. from a for-loop init like
  /// `int i = 0` or `var a = 1, b = 2`) as a block expression containing
  /// one [LetBinding] per declared variable.  This replaces the old approach
  /// of emitting the raw Dart source as a string literal, which forced every
  /// engine to re-parse Dart syntax.
  Expression _encodeVarDeclListAsBlock(ast.VariableDeclarationList declList) {
    final block = Block();
    for (final variable in declList.variables) {
      final name = variable.name.lexeme;
      final init = variable.initializer;

      final let = LetBinding()
        ..name = name
        ..value = (init != null
            ? _encodeExpr(init)
            : (Expression()..reference = (Reference()..name = '__no_init__')));

      // Store var/final/const and explicit type in metadata (mirrors
      // _encodeVarDeclEntry for regular variable declarations).
      final meta = <String, Object>{};
      if (declList.isFinal) {
        meta['keyword'] = 'final';
      } else if (declList.isConst) {
        meta['keyword'] = 'const';
      } else {
        meta['keyword'] = 'var';
      }
      final typeNode = declList.type;
      if (typeNode != null) meta['type'] = typeNode.toSource();
      if (meta.isNotEmpty) let.metadata = _toStruct(meta);

      block.statements.add(Statement()..let = let);
    }
    return Expression()..block = block;
  }

  // ============================================================
  // Control flow encoding
  // ============================================================

  Expression _encodeIfStatement(
    ast.IfStatement stmt, {
    required bool hasReturn,
  }) {
    _usedBaseFunctions.add('if');

    final fields = <FieldValuePair>[
      FieldValuePair()
        ..name = 'condition'
        ..value = _encodeExpr(stmt.expression),
    ];

    final thenStmt = stmt.thenStatement;
    if (thenStmt is ast.Block) {
      fields.add(
        FieldValuePair()
          ..name = 'then'
          ..value = _encodeBlock(thenStmt.statements, hasReturn: hasReturn),
      );
    } else {
      fields.add(
        FieldValuePair()
          ..name = 'then'
          ..value = _encodeSingleStatement(thenStmt, hasReturn: hasReturn),
      );
    }

    final elseStmt = stmt.elseStatement;
    if (elseStmt != null) {
      if (elseStmt is ast.Block) {
        fields.add(
          FieldValuePair()
            ..name = 'else'
            ..value = _encodeBlock(elseStmt.statements, hasReturn: hasReturn),
        );
      } else {
        fields.add(
          FieldValuePair()
            ..name = 'else'
            ..value = _encodeSingleStatement(elseStmt, hasReturn: hasReturn),
        );
      }
    }

    // If-case pattern support: store in metadata.
    if (stmt.caseClause != null) {
      fields.add(
        FieldValuePair()
          ..name = 'case_pattern'
          ..value = (Expression()
            ..literal = (Literal()
              ..stringValue = stmt.caseClause!.guardedPattern.toSource())),
      );
      // Structured pattern encoding (9.6) for engine interpretation
      final structuredPat = _encodePattern(
        stmt.caseClause!.guardedPattern.pattern,
      );
      if (structuredPat != null) {
        fields.add(
          FieldValuePair()
            ..name = 'case_pattern_expr'
            ..value = structuredPat,
        );
      }
    }

    return _buildStdCall('if', fields);
  }

  Expression _encodeForStatement(ast.ForStatement stmt) {
    _usedBaseFunctions.add('for');
    final loopParts = stmt.forLoopParts;
    final fields = <FieldValuePair>[];

    if (loopParts is ast.ForPartsWithDeclarations) {
      fields.add(
        FieldValuePair()
          ..name = 'init'
          ..value = _encodeVarDeclListAsBlock(loopParts.variables),
      );
      if (loopParts.condition != null) {
        fields.add(
          FieldValuePair()
            ..name = 'condition'
            ..value = _encodeExpr(loopParts.condition!),
        );
      }
      if (loopParts.updaters.isNotEmpty) {
        final updates = loopParts.updaters.map(_encodeExpr).toList();
        if (updates.length == 1) {
          fields.add(
            FieldValuePair()
              ..name = 'update'
              ..value = updates.first,
          );
        } else {
          fields.add(
            FieldValuePair()
              ..name = 'update'
              ..value = (Expression()
                ..literal = (Literal()
                  ..listValue = (ListLiteral()..elements.addAll(updates)))),
          );
        }
      }
    } else if (loopParts is ast.ForPartsWithExpression) {
      if (loopParts.initialization != null) {
        fields.add(
          FieldValuePair()
            ..name = 'init'
            ..value = _encodeExpr(loopParts.initialization!),
        );
      }
      if (loopParts.condition != null) {
        fields.add(
          FieldValuePair()
            ..name = 'condition'
            ..value = _encodeExpr(loopParts.condition!),
        );
      }
      if (loopParts.updaters.isNotEmpty) {
        fields.add(
          FieldValuePair()
            ..name = 'update'
            ..value = _encodeExpr(loopParts.updaters.first),
        );
      }
    } else if (loopParts is ast.ForEachPartsWithDeclaration) {
      _usedBaseFunctions.add('for_in');
      // Preserve `await for` loops.
      if (stmt.awaitKeyword != null) {
        fields.add(
          FieldValuePair()
            ..name = 'is_await'
            ..value = (Expression()..literal = (Literal()..boolValue = true)),
        );
      }
      fields.add(
        FieldValuePair()
          ..name = 'variable'
          ..value = (Expression()
            ..literal = (Literal()
              ..stringValue = loopParts.loopVariable.name.lexeme)),
      );
      // Preserve the declaration keyword so the compiler can round-trip
      // `for (var x in ...)` as `var` (not default `final`). When there's
      // an explicit type, the type overrides the keyword.
      if (loopParts.loopVariable.type != null) {
        fields.add(
          FieldValuePair()
            ..name = 'variable_type'
            ..value = (Expression()
              ..literal = (Literal()
                ..stringValue = loopParts.loopVariable.type!.toSource())),
        );
      } else {
        // Grab the `var`/`final` keyword (if any) from the loopVariable.
        final kw = loopParts.loopVariable.keyword?.lexeme;
        if (kw != null && (kw == 'var' || kw == 'final')) {
          fields.add(
            FieldValuePair()
              ..name = 'variable_keyword'
              ..value = (Expression()..literal = (Literal()..stringValue = kw)),
          );
        }
      }
      fields.add(
        FieldValuePair()
          ..name = 'iterable'
          ..value = _encodeExpr(loopParts.iterable),
      );

      final body = stmt.body;
      if (body is ast.Block) {
        fields.add(
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeBlock(body.statements, hasReturn: false),
        );
      } else {
        fields.add(
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeSingleStatement(body, hasReturn: false),
        );
      }
      return _buildStdCall('for_in', fields);
    } else if (loopParts is ast.ForEachPartsWithIdentifier) {
      _usedBaseFunctions.add('for_in');
      // Preserve `await for` loops.
      if (stmt.awaitKeyword != null) {
        fields.add(
          FieldValuePair()
            ..name = 'is_await'
            ..value = (Expression()..literal = (Literal()..boolValue = true)),
        );
      }
      fields.add(
        FieldValuePair()
          ..name = 'variable'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = loopParts.identifier.name)),
      );
      fields.add(
        FieldValuePair()
          ..name = 'iterable'
          ..value = _encodeExpr(loopParts.iterable),
      );

      final body = stmt.body;
      if (body is ast.Block) {
        fields.add(
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeBlock(body.statements, hasReturn: false),
        );
      } else {
        fields.add(
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeSingleStatement(body, hasReturn: false),
        );
      }
      return _buildStdCall('for_in', fields);
    } else if (loopParts is ast.ForEachPartsWithPattern) {
      // Dart 3 destructuring for-each:
      //   `for (var MapEntry(key: name, value: content) in map.entries) ...`
      // Preserve the keyword + pattern as a raw string under `pattern` so
      // the compiler can emit `for (<pattern> in <iter>) <body>` verbatim.
      _usedBaseFunctions.add('for_in');
      if (stmt.awaitKeyword != null) {
        fields.add(
          FieldValuePair()
            ..name = 'is_await'
            ..value = (Expression()..literal = (Literal()..boolValue = true)),
        );
      }
      final kw = loopParts.keyword.lexeme;
      final patternSrc = loopParts.pattern.toSource();
      fields.add(
        FieldValuePair()
          ..name = 'pattern'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = '$kw $patternSrc')),
      );
      fields.add(
        FieldValuePair()
          ..name = 'iterable'
          ..value = _encodeExpr(loopParts.iterable),
      );
      final body = stmt.body;
      if (body is ast.Block) {
        fields.add(
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeBlock(body.statements, hasReturn: false),
        );
      } else {
        fields.add(
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeSingleStatement(body, hasReturn: false),
        );
      }
      return _buildStdCall('for_in', fields);
    }

    final body = stmt.body;
    if (body is ast.Block) {
      fields.add(
        FieldValuePair()
          ..name = 'body'
          ..value = _encodeBlock(body.statements, hasReturn: false),
      );
    } else {
      fields.add(
        FieldValuePair()
          ..name = 'body'
          ..value = _encodeSingleStatement(body, hasReturn: false),
      );
    }

    return _buildStdCall('for', fields);
  }

  Expression _encodeWhileStatement(ast.WhileStatement stmt) {
    _usedBaseFunctions.add('while');
    final body = stmt.body;
    Expression bodyExpr;
    if (body is ast.Block) {
      bodyExpr = _encodeBlock(body.statements, hasReturn: false);
    } else {
      bodyExpr = _encodeSingleStatement(body, hasReturn: false);
    }
    return _buildStdCall('while', [
      FieldValuePair()
        ..name = 'condition'
        ..value = _encodeExpr(stmt.condition),
      FieldValuePair()
        ..name = 'body'
        ..value = bodyExpr,
    ]);
  }

  Expression _encodeDoWhileStatement(ast.DoStatement stmt) {
    _usedBaseFunctions.add('do_while');
    final body = stmt.body;
    Expression bodyExpr;
    if (body is ast.Block) {
      bodyExpr = _encodeBlock(body.statements, hasReturn: false);
    } else {
      bodyExpr = _encodeSingleStatement(body, hasReturn: false);
    }
    return _buildStdCall('do_while', [
      FieldValuePair()
        ..name = 'body'
        ..value = bodyExpr,
      FieldValuePair()
        ..name = 'condition'
        ..value = _encodeExpr(stmt.condition),
    ]);
  }

  Expression _encodeSwitchStatement(ast.SwitchStatement stmt) {
    _usedBaseFunctions.add('switch');
    final fields = <FieldValuePair>[
      FieldValuePair()
        ..name = 'subject'
        ..value = _encodeExpr(stmt.expression),
    ];

    final cases = <Expression>[];
    for (final member in stmt.members) {
      if (member is ast.SwitchCase) {
        // Flatten case body: if the case has a single Block statement (braces),
        // use its inner statements directly instead of double-wrapping.
        final stmts = _flattenCaseStatements(member.statements);
        final caseFlds = <FieldValuePair>[
          FieldValuePair()
            ..name = 'value'
            ..value = _encodeExpr(member.expression),
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeBlock(stmts, hasReturn: false),
        ];
        cases.add(
          Expression()
            ..messageCreation = (MessageCreation()..fields.addAll(caseFlds)),
        );
      } else if (member is ast.SwitchPatternCase) {
        // Dart 3 pattern case: e.g. `case MyEnum.value: ...`
        // Store the pattern as a raw string under 'pattern' so the compiler
        // emits `case <pattern>:` verbatim.
        // Flatten case body to avoid IIFE wrapping.
        final stmts = _flattenCaseStatements(member.statements);
        final caseFlds = <FieldValuePair>[
          FieldValuePair()
            ..name = 'pattern'
            ..value = (Expression()
              ..literal = (Literal()
                ..stringValue = member.guardedPattern.pattern.toSource())),
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeBlock(stmts, hasReturn: false),
        ];
        // Structured pattern encoding (9.6)
        final structuredPat = _encodePattern(member.guardedPattern.pattern);
        if (structuredPat != null) {
          caseFlds.add(
            FieldValuePair()
              ..name = 'pattern_expr'
              ..value = structuredPat,
          );
        }
        // `when` guard: `case <pattern> when <expr>:`. The engine evaluates it
        // against the case's pattern bindings; compilers re-emit `when <expr>`.
        final whenClause = member.guardedPattern.whenClause;
        if (whenClause != null) {
          caseFlds.add(
            FieldValuePair()
              ..name = 'guard'
              ..value = _encodeExpr(whenClause.expression),
          );
        }
        cases.add(
          Expression()
            ..messageCreation = (MessageCreation()..fields.addAll(caseFlds)),
        );
      } else if (member is ast.SwitchDefault) {
        final stmts = _flattenCaseStatements(member.statements);
        final caseFlds = <FieldValuePair>[
          FieldValuePair()
            ..name = 'is_default'
            ..value = (Expression()..literal = (Literal()..boolValue = true)),
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeBlock(stmts, hasReturn: false),
        ];
        cases.add(
          Expression()
            ..messageCreation = (MessageCreation()..fields.addAll(caseFlds)),
        );
      }
    }

    fields.add(
      FieldValuePair()
        ..name = 'cases'
        ..value = (Expression()
          ..literal = (Literal()
            ..listValue = (ListLiteral()..elements.addAll(cases)))),
    );

    return _buildStdCall('switch', fields);
  }

  /// If a switch case body has a single `Block` statement (explicit braces),
  /// return its inner statements.  Otherwise return the original list.
  List<ast.Statement> _flattenCaseStatements(List<ast.Statement> stmts) {
    if (stmts.length == 1 && stmts.first is ast.Block) {
      return (stmts.first as ast.Block).statements;
    }
    return stmts;
  }

  Expression _encodeTryStatement(ast.TryStatement stmt) {
    _usedBaseFunctions.add('try');
    final fields = <FieldValuePair>[
      FieldValuePair()
        ..name = 'body'
        ..value = _encodeBlock(stmt.body.statements, hasReturn: false),
    ];

    if (stmt.catchClauses.isNotEmpty) {
      final catches = <Expression>[];
      for (final clause in stmt.catchClauses) {
        // Detect compiler-generated catch pattern:
        //   catch (__ball_e) { ... }
        // or catch (__ball_e, __ball_st) { ... }
        final isSyntheticCatch =
            clause.exceptionType == null &&
            clause.exceptionParameter != null &&
            clause.exceptionParameter!.name.lexeme == '__ball_e';

        if (isSyntheticCatch) {
          // Check if the body matches the "tag catch" pattern:
          //   if (__ball_e is Map && __ball_e['__type'] == 'X') { final e = __ball_e; ... }
          //   else if (...) { ... }
          //   else { rethrow; }
          final tagCatches = _tryExtractTagCatches(clause);
          if (tagCatches != null) {
            catches.addAll(tagCatches);
            continue;
          }

          // Simple untyped catch with aliasing:
          //   catch (__ball_e) { final dynamic e = __ball_e; ... }
          // or catch (__ball_e, __ball_st) { final dynamic e = __ball_e; final st = __ball_st; ... }
          final simple = _tryExtractSimpleCatch(clause);
          if (simple != null) {
            catches.add(simple);
            continue;
          }
        }

        // Standard encoding (real Dart on-type catch or unrecognized pattern).
        final catchFields = <FieldValuePair>[];
        if (clause.exceptionType != null) {
          catchFields.add(
            FieldValuePair()
              ..name = 'type'
              ..value = (Expression()
                ..literal = (Literal()
                  ..stringValue = clause.exceptionType!.toSource())),
          );
        }
        if (clause.exceptionParameter != null) {
          catchFields.add(
            FieldValuePair()
              ..name = 'variable'
              ..value = (Expression()
                ..literal = (Literal()
                  ..stringValue = clause.exceptionParameter!.name.lexeme)),
          );
        }
        if (clause.stackTraceParameter != null) {
          catchFields.add(
            FieldValuePair()
              ..name = 'stack_trace'
              ..value = (Expression()
                ..literal = (Literal()
                  ..stringValue = clause.stackTraceParameter!.name.lexeme)),
          );
        }
        catchFields.add(
          FieldValuePair()
            ..name = 'body'
            ..value = _encodeBlock(clause.body.statements, hasReturn: false),
        );
        catches.add(
          Expression()
            ..messageCreation = (MessageCreation()..fields.addAll(catchFields)),
        );
      }
      fields.add(
        FieldValuePair()
          ..name = 'catches'
          ..value = (Expression()
            ..literal = (Literal()
              ..listValue = (ListLiteral()..elements.addAll(catches)))),
      );
    }

    if (stmt.finallyBlock != null) {
      fields.add(
        FieldValuePair()
          ..name = 'finally'
          ..value = _encodeBlock(
            stmt.finallyBlock!.statements,
            hasReturn: false,
          ),
      );
    }

    return _buildStdCall('try', fields);
  }

  /// Try to extract a simple untyped catch from the compiler's aliasing pattern:
  ///   catch (__ball_e) { final dynamic e = __ball_e; <body...> }
  /// Returns the encoded catch expression, or null if the pattern doesn't match.
  Expression? _tryExtractSimpleCatch(ast.CatchClause clause) {
    final stmts = clause.body.statements;
    if (stmts.isEmpty) return null;

    // Look for `final dynamic <name> = __ball_e;` as the first statement.
    String? realVarName;
    int bodyStart = 0;

    final first = stmts[0];
    if (first is ast.VariableDeclarationStatement) {
      final vars = first.variables.variables;
      if (vars.length == 1) {
        final init = vars[0].initializer;
        if (init is ast.SimpleIdentifier && init.name == '__ball_e') {
          realVarName = vars[0].name.lexeme;
          bodyStart = 1;
        }
      }
    }

    if (realVarName == null) return null;

    // Check for stack trace aliasing: `final <st> = __ball_st;`
    String? realStackName;
    if (bodyStart < stmts.length) {
      final next = stmts[bodyStart];
      if (next is ast.VariableDeclarationStatement) {
        final vars = next.variables.variables;
        if (vars.length == 1) {
          final init = vars[0].initializer;
          if (init is ast.SimpleIdentifier && init.name == '__ball_st') {
            realStackName = vars[0].name.lexeme;
            bodyStart++;
          }
        }
      }
    }

    final catchFields = <FieldValuePair>[];
    catchFields.add(
      FieldValuePair()
        ..name = 'variable'
        ..value = (Expression()
          ..literal = (Literal()..stringValue = realVarName)),
    );
    if (realStackName != null) {
      catchFields.add(
        FieldValuePair()
          ..name = 'stack_trace'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = realStackName)),
      );
    }
    catchFields.add(
      FieldValuePair()
        ..name = 'body'
        ..value = _encodeBlock(stmts.sublist(bodyStart), hasReturn: false),
    );
    return Expression()
      ..messageCreation = (MessageCreation()..fields.addAll(catchFields));
  }

  /// Try to extract tag-typed catches from the compiler's pattern:
  ///   catch (__ball_e) {
  ///     if (__ball_e is Map && __ball_e['__type'] == 'TypeA') {
  ///       final e = __ball_e;
  ///       <body...>
  ///     } else if (__ball_e is Map && __ball_e['__type'] == 'TypeB') { ... }
  ///     else { rethrow; }         // implicit fallback
  ///     // -or- else { final dynamic e = __ball_e; <body...> }  // untyped catch
  ///   }
  /// Returns the list of encoded catch expressions, or null if the pattern
  /// doesn't match.
  List<Expression>? _tryExtractTagCatches(ast.CatchClause clause) {
    final stmts = clause.body.statements;
    if (stmts.isEmpty) return null;

    // Possible stack trace alias before the if-chain:
    //   final <st> = __ball_st;
    int ifStart = 0;
    String? stackAlias;
    if (stmts[0] is ast.VariableDeclarationStatement) {
      final decl = stmts[0] as ast.VariableDeclarationStatement;
      final vars = decl.variables.variables;
      if (vars.length == 1) {
        final init = vars[0].initializer;
        if (init is ast.SimpleIdentifier && init.name == '__ball_st') {
          stackAlias = vars[0].name.lexeme;
          ifStart = 1;
        }
      }
    }

    // The body should be a single if/else-if chain.
    if (ifStart >= stmts.length) return null;
    final ifStmt = stmts[ifStart];
    if (ifStmt is! ast.IfStatement) return null;
    // Must be the only statement (aside from the optional stack alias above).
    if (stmts.length > ifStart + 1) return null;

    // Walk the if/else-if chain.
    final results = <Expression>[];
    ast.IfStatement? current = ifStmt;
    while (current != null) {
      // Try to match: __ball_e is Map && __ball_e['__type'] == 'TypeName'
      final tagType = _extractTagType(current.expression);
      if (tagType == null) {
        // If this is an initial if with no tag match, the pattern doesn't
        // match our expectations; bail.
        return null;
      }

      // Extract the then-branch body, stripping `final <name> = __ball_e;`
      // and optional `final <st> = __ball_st;`
      final thenBody = _extractTagBranchBody(current.thenStatement, stackAlias);
      if (thenBody == null) return null;

      final catchFields = <FieldValuePair>[
        FieldValuePair()
          ..name = 'type'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = tagType)),
      ];
      catchFields.add(
        FieldValuePair()
          ..name = 'variable'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = thenBody.varName)),
      );
      if (thenBody.stackName != null) {
        catchFields.add(
          FieldValuePair()
            ..name = 'stack_trace'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = thenBody.stackName!)),
        );
      }
      catchFields.add(
        FieldValuePair()
          ..name = 'body'
          ..value = _encodeBlock(thenBody.bodyStatements, hasReturn: false),
      );
      results.add(
        Expression()
          ..messageCreation = (MessageCreation()..fields.addAll(catchFields)),
      );

      // Move to else branch.
      final elseStmt = current.elseStatement;
      if (elseStmt == null) {
        break;
      } else if (elseStmt is ast.IfStatement) {
        current = elseStmt;
      } else if (elseStmt is ast.Block) {
        // else { rethrow; } — implicit fallback, just stop.
        // else { final dynamic e = __ball_e; <body> } — untyped fallback catch.
        final elseStmts = elseStmt.statements;
        if (elseStmts.length == 1 &&
            elseStmts[0] is ast.ExpressionStatement &&
            (elseStmts[0] as ast.ExpressionStatement).expression
                is ast.RethrowExpression) {
          // Implicit rethrow fallback — no extra catch needed.
          break;
        }
        // Check for untyped catch fallback:
        //   final dynamic e = __ball_e; <body...>
        if (elseStmts.isNotEmpty &&
            elseStmts[0] is ast.VariableDeclarationStatement) {
          final decl = elseStmts[0] as ast.VariableDeclarationStatement;
          final vars = decl.variables.variables;
          if (vars.length == 1) {
            final init = vars[0].initializer;
            if (init is ast.SimpleIdentifier && init.name == '__ball_e') {
              final varName = vars[0].name.lexeme;
              int bodyStart = 1;
              String? st;
              // Check for stack alias
              if (bodyStart < elseStmts.length &&
                  elseStmts[bodyStart] is ast.VariableDeclarationStatement) {
                final sd =
                    elseStmts[bodyStart] as ast.VariableDeclarationStatement;
                final sv = sd.variables.variables;
                if (sv.length == 1) {
                  final si = sv[0].initializer;
                  if (si is ast.SimpleIdentifier && si.name == '__ball_st') {
                    st = sv[0].name.lexeme;
                    bodyStart++;
                  }
                }
              }
              final catchFields2 = <FieldValuePair>[
                FieldValuePair()
                  ..name = 'variable'
                  ..value = (Expression()
                    ..literal = (Literal()..stringValue = varName)),
              ];
              if (st != null) {
                catchFields2.add(
                  FieldValuePair()
                    ..name = 'stack_trace'
                    ..value = (Expression()
                      ..literal = (Literal()..stringValue = st)),
                );
              }
              catchFields2.add(
                FieldValuePair()
                  ..name = 'body'
                  ..value = _encodeBlock(
                    elseStmts.sublist(bodyStart),
                    hasReturn: false,
                  ),
              );
              results.add(
                Expression()
                  ..messageCreation = (MessageCreation()
                    ..fields.addAll(catchFields2)),
              );
              break;
            }
          }
        }
        // Unrecognized else block — bail.
        return null;
      } else {
        // Unrecognized else form — bail.
        return null;
      }
    }

    return results.isEmpty ? null : results;
  }

  /// Extract the type name from a condition like:
  ///   __ball_e is Map && __ball_e['__type'] == 'TypeName'
  /// Returns the type name string, or null if pattern doesn't match.
  String? _extractTagType(ast.Expression condition) {
    // The condition might be parenthesized.
    var cond = condition;
    while (cond is ast.ParenthesizedExpression) {
      cond = cond.expression;
    }
    if (cond is! ast.BinaryExpression) return null;
    if (cond.operator.lexeme != '&&') return null;

    // Left: __ball_e is Map
    var left = cond.leftOperand;
    while (left is ast.ParenthesizedExpression) {
      left = left.expression;
    }
    if (left is! ast.IsExpression) return null;
    final isTarget = left.expression;
    if (isTarget is! ast.SimpleIdentifier || isTarget.name != '__ball_e') {
      return null;
    }

    // Right: __ball_e['__type'] == 'TypeName'
    var right = cond.rightOperand;
    while (right is ast.ParenthesizedExpression) {
      right = right.expression;
    }
    if (right is! ast.BinaryExpression) return null;
    if (right.operator.lexeme != '==') return null;

    // The left side: __ball_e['__type']
    final indexExpr = right.leftOperand;
    if (indexExpr is! ast.IndexExpression) return null;
    final target = indexExpr.target;
    if (target is! ast.SimpleIdentifier || target.name != '__ball_e') {
      return null;
    }
    final index = indexExpr.index;
    if (index is! ast.SimpleStringLiteral || index.value != '__type') {
      return null;
    }

    // The right side: 'TypeName'
    final typeNameExpr = right.rightOperand;
    if (typeNameExpr is! ast.SimpleStringLiteral) return null;
    return typeNameExpr.value;
  }

  /// Extract variable name and body statements from a tag-catch then-branch:
  ///   { final e = __ball_e; <optional stack alias>; <body...> }
  ({String varName, String? stackName, List<ast.Statement> bodyStatements})?
  _extractTagBranchBody(ast.Statement thenStmt, String? outerStackAlias) {
    List<ast.Statement> stmts;
    if (thenStmt is ast.Block) {
      stmts = thenStmt.statements;
    } else {
      // Single statement (unlikely for tag catch, but handle gracefully).
      stmts = [thenStmt];
    }
    if (stmts.isEmpty) return null;

    // First statement should be: final <name> = __ball_e;
    final first = stmts[0];
    if (first is! ast.VariableDeclarationStatement) return null;
    final vars = first.variables.variables;
    if (vars.length != 1) return null;
    final init = vars[0].initializer;
    if (init is! ast.SimpleIdentifier || init.name != '__ball_e') return null;
    final varName = vars[0].name.lexeme;
    int bodyStart = 1;

    // Optional stack alias: final <st> = __ball_st;
    String? stackName;
    if (bodyStart < stmts.length &&
        stmts[bodyStart] is ast.VariableDeclarationStatement) {
      final sd = stmts[bodyStart] as ast.VariableDeclarationStatement;
      final sv = sd.variables.variables;
      if (sv.length == 1) {
        final si = sv[0].initializer;
        if (si is ast.SimpleIdentifier && si.name == '__ball_st') {
          stackName = sv[0].name.lexeme;
          bodyStart++;
        }
      }
    }
    // If there's an outerStackAlias and the branch uses it directly, record it.
    stackName ??= outerStackAlias;
    // Actually only record stack if the branch explicitly aliases it.
    if (stackName == outerStackAlias) stackName = null;

    return (
      varName: varName,
      stackName: stackName,
      bodyStatements: stmts.sublist(bodyStart),
    );
  }

  // ============================================================
  // Expression encoding
  // ============================================================

  Expression _encodeExpr(ast.Expression expr) {
    // ---- Literals ----
    if (expr is ast.IntegerLiteral) {
      // Always encode as an int literal — the analyzer's `expr.value`
      // is Int64 so both decimal and hex source forms fit. Emitting hex
      // literals as references (the old workaround for JS Number
      // precision) broke the engine since there's no variable named
      // "0xF0" in scope.
      return Expression()
        ..literal = (Literal()..intValue = Int64(expr.value ?? 0));
    }
    if (expr is ast.DoubleLiteral) {
      return Expression()..literal = (Literal()..doubleValue = expr.value);
    }
    if (expr is ast.SimpleStringLiteral) {
      return Expression()..literal = (Literal()..stringValue = expr.value);
    }
    if (expr is ast.AdjacentStrings) {
      final parts = expr.strings.map(_encodeExpr).toList();
      return _buildConcatChain(parts);
    }
    if (expr is ast.StringInterpolation) {
      return _encodeStringInterpolation(expr);
    }
    if (expr is ast.BooleanLiteral) {
      return Expression()..literal = (Literal()..boolValue = expr.value);
    }
    if (expr is ast.NullLiteral) {
      return Expression()..literal = Literal();
    }
    if (expr is ast.ListLiteral) {
      return _encodeListLiteral(expr);
    }
    if (expr is ast.SetOrMapLiteral) {
      return _encodeSetOrMapLiteral(expr);
    }
    if (expr is ast.RecordLiteral) {
      return _encodeRecordLiteral(expr);
    }

    // ---- References ----
    if (expr is ast.SimpleIdentifier) {
      // A bare dart:core type name in expression position is a type literal
      // (`print(int)`), not a variable reference. The parser only produces
      // `ast.TypeLiteral` for generic instantiations (`List<int>`), so without
      // resolution a bare `int` parses as a SimpleIdentifier and used to encode
      // as an undefined-variable reference (#66). Restrict to the exact
      // builtin list so user identifiers are never hijacked, and skip
      // value-less positions: static receivers (`List.generate` must keep a
      // `reference("List")` self for the engine's static dispatch) and
      // assignment targets (a pathological local shadowing a type name).
      final typeLiteralName = _builtinTypeLiterals[expr.name];
      if (typeLiteralName != null &&
          _isTypeLiteralPosition(expr) &&
          !_hasEnclosingDeclaration(expr, expr.name)) {
        _usedBaseFunctions.add('type_literal');
        return _buildStdCall('type_literal', [
          FieldValuePair()
            ..name = 'type'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = typeLiteralName)),
        ]);
      }
      return Expression()..reference = (Reference()..name = expr.name);
    }
    if (expr is ast.PrefixedIdentifier) {
      final prefixName = expr.prefix.name;
      final member = expr.identifier.name;
      final module = _prefixToModule[prefixName];
      if (module != null) {
        return Expression()
          ..reference = (Reference()..name = '$prefixName.$member');
      }

      // Well-known getter properties on a simple identifier receiver
      // (e.g. `x.sign`, `nan.isNaN`). Same routes as the PropertyAccess path.
      const getterRoutes = <String, String>{
        'sign': 'math_sign',
        'isNaN': 'math_is_nan',
        'isFinite': 'math_is_finite',
        'isInfinite': 'math_is_infinite',
        'isEmpty': 'string_is_empty',
        'runes': 'string_runes',
        // isNotEmpty is handled separately below (negation of isEmpty).
      };
      final getterFn = getterRoutes[member];
      if (getterFn != null) {
        _usedBaseFunctions.add(getterFn);
        return _buildUnaryStdCall(
          getterFn,
          Expression()..reference = (Reference()..name = prefixName),
        );
      }
      // isNotEmpty → not(string_is_empty(target))
      if (member == 'isNotEmpty') {
        _usedBaseFunctions.addAll(['string_is_empty', 'not']);
        return _buildUnaryStdCall(
          'not',
          _buildUnaryStdCall(
            'string_is_empty',
            Expression()..reference = (Reference()..name = prefixName),
          ),
        );
      }
      // isEven / isOdd → parity check (no std getter; compose modulo+equals).
      if (member == 'isEven' || member == 'isOdd') {
        return _parityCheck(
          Expression()..reference = (Reference()..name = prefixName),
          even: member == 'isEven',
        );
      }

      return Expression()
        ..fieldAccess = (FieldAccess()
          ..object = (Expression()
            ..reference = (Reference()..name = prefixName))
          ..field_2 = member);
    }

    // ---- Property access ----
    if (expr is ast.PropertyAccess) {
      final target = expr.target;
      final field = expr.propertyName.name;

      // Null target inside a cascade section: `..field` or `..field?.sub`
      final targetExpr = target == null
          ? _cascadeSelfExpr
          : _encodeExpr(target);

      if (expr.operator.lexeme == '?.') {
        return _buildNullAwareAccess(targetExpr, field);
      }

      if (target is ast.SimpleIdentifier &&
          _prefixToModule.containsKey(target.name)) {
        return Expression()
          ..reference = (Reference()..name = '${target.name}.$field');
      }

      // Well-known getter properties → std base function calls. Without type
      // resolution, route by name (same risk as the method routes above).
      const getterRoutes = <String, String>{
        'sign': 'math_sign',
        'isNaN': 'math_is_nan',
        'isFinite': 'math_is_finite',
        'isInfinite': 'math_is_infinite',
        'isEmpty': 'string_is_empty',
        'runes': 'string_runes',
        // isNotEmpty is handled separately below (negation of isEmpty).
      };
      final getterFn = getterRoutes[field];
      if (getterFn != null && target != null) {
        _usedBaseFunctions.add(getterFn);
        return _buildUnaryStdCall(getterFn, targetExpr);
      }
      // isNotEmpty → not(string_is_empty(target))
      if (field == 'isNotEmpty' && target != null) {
        _usedBaseFunctions.addAll(['string_is_empty', 'not']);
        return _buildUnaryStdCall(
          'not',
          _buildUnaryStdCall('string_is_empty', targetExpr),
        );
      }
      // isEven / isOdd → parity check (no std getter; compose modulo+equals).
      if ((field == 'isEven' || field == 'isOdd') && target != null) {
        return _parityCheck(targetExpr, even: field == 'isEven');
      }

      return Expression()
        ..fieldAccess = (FieldAccess()
          ..object = targetExpr
          ..field_2 = field);
    }

    // ---- Binary operators ----
    if (expr is ast.BinaryExpression) {
      return _encodeBinaryExpression(expr);
    }

    // ---- Unary prefix operators ----
    if (expr is ast.PrefixExpression) {
      return _encodePrefixExpression(expr);
    }

    // ---- Postfix operators ----
    if (expr is ast.PostfixExpression) {
      return _encodePostfixExpression(expr);
    }

    // ---- Parenthesized ----
    if (expr is ast.ParenthesizedExpression) {
      final inner = expr.expression;
      // Preserve parentheses when they affect operator precedence:
      // e.g. `(x ??= []).add(y)` vs `x ??= [].add(y)`.
      if (inner is ast.AssignmentExpression ||
          inner is ast.ConditionalExpression) {
        _usedBaseFunctions.add('paren');
        return _buildStdCall('paren', [
          FieldValuePair()
            ..name = 'value'
            ..value = _encodeExpr(inner),
        ]);
      }
      if (inner is ast.CascadeExpression) {
        // Single-section cascades that route to a collection call don't need
        // paren wrapping — the result is a plain function call, not a cascade
        // that the compiler would re-wrap in parentheses.
        if (inner.cascadeSections.length == 1 &&
            !inner.isNullAware &&
            inner.cascadeSections[0] is ast.MethodInvocation) {
          final section = inner.cascadeSections[0] as ast.MethodInvocation;
          final result = _tryEncodeCascadeAsCollectionCall(
            inner.target,
            section,
          );
          if (result != null) return result;
        }
        // Multi-section or non-routed cascades still need the paren wrapper.
        _usedBaseFunctions.add('paren');
        return _buildStdCall('paren', [
          FieldValuePair()
            ..name = 'value'
            ..value = _encodeExpr(inner),
        ]);
      }
      return _encodeExpr(inner);
    }

    // ---- Conditional (ternary) ----
    if (expr is ast.ConditionalExpression) {
      _usedBaseFunctions.add('if');
      return _buildStdCall('if', [
        FieldValuePair()
          ..name = 'condition'
          ..value = _encodeExpr(expr.condition),
        FieldValuePair()
          ..name = 'then'
          ..value = _encodeExpr(expr.thenExpression),
        FieldValuePair()
          ..name = 'else'
          ..value = _encodeExpr(expr.elseExpression),
      ]);
    }

    // ---- Type operations ----
    if (expr is ast.IsExpression) {
      _usedBaseFunctions.add(expr.notOperator != null ? 'is_not' : 'is');
      return _buildStdCall(expr.notOperator != null ? 'is_not' : 'is', [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(expr.expression),
        FieldValuePair()
          ..name = 'type'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = expr.type.toSource())),
      ]);
    }
    if (expr is ast.AsExpression) {
      _usedBaseFunctions.add('as');
      return _buildStdCall('as', [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(expr.expression),
        FieldValuePair()
          ..name = 'type'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = expr.type.toSource())),
      ]);
    }

    // ---- Function / method invocations ----
    if (expr is ast.MethodInvocation) {
      return _encodeMethodInvocation(expr);
    }

    // ---- Instance creation: ClassName(...) / const ClassName(...) ----
    if (expr is ast.InstanceCreationExpression) {
      return _encodeInstanceCreation(expr);
    }

    // ---- Index ----
    if (expr is ast.IndexExpression) {
      final isNullAware = expr.isNullAware;
      final funcName = isNullAware ? 'null_aware_index' : 'index';
      _usedBaseFunctions.add(funcName);
      final idxTarget = expr.target == null
          ? _cascadeSelfExpr
          : _encodeExpr(expr.target!);
      return _buildStdCall(funcName, [
        FieldValuePair()
          ..name = 'target'
          ..value = idxTarget,
        FieldValuePair()
          ..name = 'index'
          ..value = _encodeExpr(expr.index),
      ]);
    }

    // ---- Assignment ----
    if (expr is ast.AssignmentExpression) {
      return _encodeAssignment(expr);
    }

    // ---- Cascade ----
    if (expr is ast.CascadeExpression) {
      return _encodeCascade(expr);
    }

    // ---- Throw ----
    if (expr is ast.ThrowExpression) {
      _usedBaseFunctions.add('throw');
      return _buildStdCall('throw', [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(expr.expression),
      ]);
    }

    // ---- Rethrow ----
    if (expr is ast.RethrowExpression) {
      _usedBaseFunctions.add('rethrow');
      return _buildStdCall('rethrow', []);
    }

    // ---- Await ----
    if (expr is ast.AwaitExpression) {
      _usedBaseFunctions.add('await');
      return _buildStdCall('await', [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(expr.expression),
      ]);
    }

    // ---- Lambda / anonymous function ----
    if (expr is ast.FunctionExpression) {
      return _encodeFunctionExpression(expr);
    }

    // ---- FunctionExpressionInvocation: fn(args) where fn is an expr ----
    if (expr is ast.FunctionExpressionInvocation) {
      _usedBaseFunctions.add('invoke');
      final args = _encodeArgList(expr.argumentList);
      return _buildStdCall('invoke', [
        FieldValuePair()
          ..name = 'callee'
          ..value = _encodeExpr(expr.function),
        ...args,
      ]);
    }

    // ---- This / Super ----
    if (expr is ast.ThisExpression) {
      return Expression()..reference = (Reference()..name = 'self');
    }
    if (expr is ast.SuperExpression) {
      return Expression()..reference = (Reference()..name = 'super');
    }

    // Named arguments / record fields are unwrapped to their inner expression
    // by their container encoders (_encodeArgList / _encodeRecordLiteral) before
    // reaching here; analyzer 13 removed NamedExpression, so there is no longer a
    // standalone named-expression node to handle in _encodeExpr.

    // ---- Switch expression ----
    if (expr is ast.SwitchExpression) {
      return _encodeSwitchExpression(expr);
    }

    // ---- Symbol literal ----
    if (expr is ast.SymbolLiteral) {
      _usedBaseFunctions.add('symbol');
      return _buildStdCall('symbol', [
        FieldValuePair()
          ..name = 'value'
          ..value = (Expression()
            ..literal = (Literal()
              ..stringValue = expr.components.map((t) => t.lexeme).join('.'))),
      ]);
    }

    // ---- Type literal ----
    // coverage:ignore-start
    // Unreachable with this encoder's parseString-only pipeline: analyzer
    // only ever rewrites an Identifier into an ast.TypeLiteral node during
    // *resolution* (see ast_rewrite.dart's `_toTypeLiteral`/
    // `_toPatternTypeLiteral` and function_reference_resolver.dart's
    // `_resolveTypeLiteral` in package:analyzer) — a phase this encoder
    // deliberately skips (no static types; see the "Syntactic-encoder
    // gotchas" note in dart.md). A bare type used as a value (`Box<int>`,
    // `int`) is instead parsed as `FunctionReference`/`SimpleIdentifier` and
    // handled by the branches above. Kept for forward-compatibility in case
    // a future encoder path resolves the AST.
    if (expr is ast.TypeLiteral) {
      _usedBaseFunctions.add('type_literal');
      return _buildStdCall('type_literal', [
        FieldValuePair()
          ..name = 'type'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = expr.type.toSource())),
      ]);
    }
    // coverage:ignore-end

    // ---- FunctionReference / ConstructorReference (constructor tear-offs) ----
    // e.g. `CaptureSink<T>.new`, `Result.value`, `int.parse`
    if (expr is ast.FunctionReference || expr is ast.ConstructorReference) {
      // Store as a reference so the compiler emits the source code verbatim
      // (without string-literal quoting).
      return Expression()..reference = (Reference()..name = expr.toSource());
    }

    // ---- Fallback: store source code for round-tripping ----
    return Expression()
      ..literal = (Literal()
        ..stringValue =
            '/* unsupported: ${expr.runtimeType}: ${expr.toSource()} */');
  }

  /// dart:core type names that encode as `std.type_literal` when they appear
  /// bare in expression position, mapped to their canonical `Type.toString()`
  /// (raw generics instantiate to bounds: `List` is the type `List<dynamic>`).
  /// The engines represent a type literal as this string (see the
  /// `type_literal` handler in `engine_std.dart`), so the value must match
  /// what native Dart prints for the same expression.
  static const Map<String, String> _builtinTypeLiterals = {
    'int': 'int',
    'double': 'double',
    'num': 'num',
    'String': 'String',
    'bool': 'bool',
    'List': 'List<dynamic>',
    'Map': 'Map<dynamic, dynamic>',
    'Set': 'Set<dynamic>',
    'Object': 'Object',
    'Symbol': 'Symbol',
    'dynamic': 'dynamic',
  };

  /// True when a bare builtin type name at [expr] is genuinely used as a
  /// first-class value (type literal), i.e. NOT:
  ///   * a static receiver — `List.generate(...)` / `List..gen(...)` must keep
  ///     `reference("List")` as `self` for the engine's static dispatch;
  ///   * an assignment target or increment/decrement operand — those must stay
  ///     `Reference`s so `std.assign` can resolve a mutable target (only
  ///     reachable via a pathological local shadowing a type name).
  static bool _isTypeLiteralPosition(ast.SimpleIdentifier expr) {
    final parent = expr.parent;
    if (parent is ast.MethodInvocation && parent.target == expr) {
      // A type name as a method receiver is usually a static dispatch
      // (`int.parse`, `List.generate`, `String.fromCharCode`) that must stay a
      // `reference`. The exception is `Type`/`Object` instance methods: the
      // compiler lowers a type literal inside string interpolation to
      // `<type>.toString()` (e.g. `'$int'` → `'…' + int.toString()`), which
      // MUST re-encode as `type_literal(...).toString()` — `Type.toString()`
      // yields the type name (`int.toString()` == 'int'), so this round-trips
      // through the engine (#66). Static factory names never collide with
      // `toString`, so only that method promotes the receiver to a type literal.
      return parent.methodName.name == 'toString';
    }
    if (parent is ast.CascadeExpression && parent.target == expr) return false;
    if (parent is ast.AssignmentExpression && parent.leftHandSide == expr) {
      return false;
    }
    if (parent is ast.PrefixExpression &&
        (parent.operator.lexeme == '++' || parent.operator.lexeme == '--')) {
      return false;
    }
    if (parent is ast.PostfixExpression &&
        (parent.operator.lexeme == '++' || parent.operator.lexeme == '--')) {
      return false;
    }
    return true;
  }

  /// True when [name] is (syntactically) declared by a construct enclosing
  /// [expr] — a parameter, local variable, loop/catch variable, local
  /// function, class field, or top-level declaration. `int`, `num`, etc. are
  /// NOT reserved words in Dart, so `String toRoman(int num)` legally shadows
  /// the type; a shadowed name must keep encoding as a plain reference.
  /// Purely syntactic (parseString has no resolution), so it scans whole
  /// blocks rather than only declarations preceding [expr] — over-matching
  /// only re-yields the pre-#66 reference encoding, never a wrong hijack.
  static bool _hasEnclosingDeclaration(ast.SimpleIdentifier expr, String name) {
    bool declaresParam(ast.FormalParameterList? list) {
      if (list == null) return false;
      for (final p in list.parameters) {
        if (p.name?.lexeme == name) return true;
      }
      return false;
    }

    for (ast.AstNode? node = expr.parent; node != null; node = node.parent) {
      if (node is ast.FunctionExpression && declaresParam(node.parameters)) {
        return true;
      }
      if (node is ast.MethodDeclaration && declaresParam(node.parameters)) {
        return true;
      }
      if (node is ast.ConstructorDeclaration &&
          declaresParam(node.parameters)) {
        return true;
      }
      if (node is ast.Block) {
        for (final stmt in node.statements) {
          if (stmt is ast.VariableDeclarationStatement) {
            for (final v in stmt.variables.variables) {
              if (v.name.lexeme == name) return true;
            }
          } else if (stmt is ast.FunctionDeclarationStatement &&
              stmt.functionDeclaration.name.lexeme == name) {
            return true;
          }
        }
      }
      final forParts = node is ast.ForStatement
          ? node.forLoopParts
          : (node is ast.ForElement ? node.forLoopParts : null);
      if (forParts is ast.ForPartsWithDeclarations) {
        for (final v in forParts.variables.variables) {
          if (v.name.lexeme == name) return true;
        }
      } else if (forParts is ast.ForEachPartsWithDeclaration) {
        if (forParts.loopVariable.name.lexeme == name) return true;
      }
      if (node is ast.CatchClause) {
        if (node.exceptionParameter?.name.lexeme == name) return true;
        if (node.stackTraceParameter?.name.lexeme == name) return true;
      }
      if (node is ast.ClassDeclaration) {
        final body = node.body;
        if (body is ast.BlockClassBody) {
          for (final member in body.members) {
            if (member is ast.FieldDeclaration) {
              for (final v in member.fields.variables) {
                if (v.name.lexeme == name) return true;
              }
            }
          }
        }
      }
      if (node is ast.CompilationUnit) {
        for (final decl in node.declarations) {
          if (decl is ast.FunctionDeclaration && decl.name.lexeme == name) {
            return true;
          }
          if (decl is ast.TopLevelVariableDeclaration) {
            for (final v in decl.variables.variables) {
              if (v.name.lexeme == name) return true;
            }
          }
          if (decl is ast.ClassDeclaration &&
              decl.namePart.typeName.lexeme == name) {
            return true;
          }
        }
      }
    }
    return false;
  }

  // ---- Binary expression ----
  Expression _encodeBinaryExpression(ast.BinaryExpression expr) {
    final op = expr.operator.lexeme;
    final ballFn = _dartOpToBallFunction(op);
    if (ballFn != null) {
      _usedBaseFunctions.add(ballFn);
      return _buildStdCall(ballFn, [
        FieldValuePair()
          ..name = 'left'
          ..value = _encodeExpr(expr.leftOperand),
        FieldValuePair()
          ..name = 'right'
          ..value = _encodeExpr(expr.rightOperand),
      ]);
    }
    return Expression()
      ..literal = (Literal()..stringValue = '/* unsupported op: $op */');
  }

  // ---- Prefix expression ----
  Expression _encodePrefixExpression(ast.PrefixExpression expr) {
    final op = expr.operator.lexeme;
    final ballFn = switch (op) {
      '!' => 'not',
      '-' => 'negate',
      '~' => 'bitwise_not',
      '++' => 'pre_increment',
      '--' => 'pre_decrement',
      _ => null,
    };
    if (ballFn != null) {
      _usedBaseFunctions.add(ballFn);
      return _buildStdCall(ballFn, [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(expr.operand),
      ]);
    }
    return _encodeExpr(expr.operand);
  }

  // ---- Postfix expression ----
  Expression _encodePostfixExpression(ast.PostfixExpression expr) {
    final op = expr.operator.lexeme;
    if (op == '!') {
      // Null assertion: expr!
      _usedBaseFunctions.add('null_check');
      return _buildStdCall('null_check', [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(expr.operand),
      ]);
    }
    final ballFn = op == '++' ? 'post_increment' : 'post_decrement';
    _usedBaseFunctions.add(ballFn);
    return _buildStdCall(ballFn, [
      FieldValuePair()
        ..name = 'value'
        ..value = _encodeExpr(expr.operand),
    ]);
  }

  // ---- Method invocation ----
  Expression _encodeMethodInvocation(ast.MethodInvocation expr) {
    final methodName = expr.methodName.name;
    final target = expr.target;
    final realTarget = expr.realTarget;
    final args = _encodeArgList(expr.argumentList);
    final isNullAware = expr.operator?.lexeme == '?.';
    // Preserve explicit type arguments on method calls.
    final typeArgSrc = expr.typeArguments?.toSource();

    // Cascade section method call: `..doSomething()` has null target.
    if (target == null && _inCascadeSection) {
      final call = FunctionCall()..function = methodName;
      final methodArgs = <FieldValuePair>[
        FieldValuePair()
          ..name = 'self'
          ..value = _cascadeSelfExpr,
        ...args,
      ];
      call.input = Expression()
        ..messageCreation = (MessageCreation()..fields.addAll(methodArgs));
      return Expression()..call = call;
    }

    // Top-level function call.
    if (target == null) {
      if (methodName == 'print') {
        _usedBaseFunctions.add('print');
        final fields = <FieldValuePair>[];
        if (args.isNotEmpty) {
          fields.add(
            FieldValuePair()
              ..name = 'message'
              ..value = args.first.value,
          );
        }
        return Expression()
          ..call = (FunctionCall()
            ..module = _moduleForFunction('print')
            ..function = 'print'
            ..input = (Expression()
              ..messageCreation = (MessageCreation()
                ..typeName = 'PrintInput'
                ..fields.addAll(fields))));
      }

      // dart:convert top-level functions → std_convert base functions.
      // `jsonEncode(x)` / `jsonDecode(s)` route to std_convert with a single
      // `value` field (matching the engine's _stdAsMap(i)['value'] read).
      const convertTopLevelRoutes = <String, String>{
        'jsonEncode': 'json_encode',
        'jsonDecode': 'json_decode',
      };
      final convertTopLevelFn = convertTopLevelRoutes[methodName];
      if (convertTopLevelFn != null && args.length == 1) {
        _usedConvertFunctions.add(convertTopLevelFn);
        return Expression()
          ..call = (FunctionCall()
            ..module = 'std_convert'
            ..function = convertTopLevelFn
            ..input = (Expression()
              ..messageCreation = (MessageCreation()
                ..fields.add(
                  FieldValuePair()
                    ..name = 'value'
                    ..value = args.first.value,
                ))));
      }

      // Implicit constructor call (no `new` keyword, uppercase method name):
      // produce a MessageCreation so the engine can construct instances.
      // `parseString` without type resolution emits `MethodInvocation` even
      // for `new`-less constructor calls like `IoEnvironmentVariables()`.
      //
      // Use the first *letter* (skipping any private `_` prefix) and require it
      // to be genuinely upper-cased: a bare `'_'.toUpperCase()` equals `'_'`, so
      // a naive first-char check would mis-classify EVERY private function
      // (`_helper()`, `_putAll()`) as a constructor and emit a bogus
      // MessageCreation instead of a function call. `_Foo()` (private class)
      // still resolves to a constructor; `_foo()` (private function) does not.
      if (_looksLikeTypeName(methodName)) {
        final fullTypeName = '$_moduleName:$methodName';
        final msg = MessageCreation()
          ..typeName = fullTypeName
          ..fields.addAll(args);
        _setTypeArgsMetadata(msg, typeArgSrc);
        _setTypeArgsField(msg, typeArgSrc);
        return Expression()..messageCreation = msg;
      }

      final call = FunctionCall()..function = methodName;
      // Preserve type arguments (e.g. `binarySearchBy<E, E>(...)`).
      call.typeArgs.addAll(_parseTypeArgs(typeArgSrc));
      _setCallInput(call, args);
      return Expression()..call = call;
    }

    // Prefixed call: prefix.function(...)
    if (target is ast.SimpleIdentifier &&
        _prefixToModule.containsKey(target.name)) {
      final module = _prefixToModule[target.name]!;
      final call = FunctionCall()
        ..module = module
        ..function = methodName;
      // Preserve type arguments on prefixed calls.
      call.typeArgs.addAll(_parseTypeArgs(typeArgSrc));
      _setCallInput(call, args);
      return Expression()..call = call;
    }

    // Static method call: int.parse(...), double.parse(...)
    if (target is ast.SimpleIdentifier) {
      final typeName = target.name;
      if (typeName == 'int' && methodName == 'parse') {
        _usedBaseFunctions.add('string_to_int');
        return _buildUnaryStdCall('string_to_int', args.first.value);
      }
      if (typeName == 'double' && methodName == 'parse') {
        _usedBaseFunctions.add('string_to_double');
        return _buildUnaryStdCall('string_to_double', args.first.value);
      }
      // dart:convert codecs: utf8.encode/decode, base64.encode/decode.
      // `utf8`/`base64` are dart:convert top-level consts, so without type
      // resolution they parse as a method target SimpleIdentifier. Route the
      // single-argument codec calls to the universal std_convert module.
      if ((typeName == 'utf8' || typeName == 'base64') &&
          (methodName == 'encode' || methodName == 'decode') &&
          args.length == 1) {
        final convertFn = '${typeName}_$methodName';
        _usedConvertFunctions.add(convertFn);
        return Expression()
          ..call = (FunctionCall()
            ..module = 'std_convert'
            ..function = convertFn
            ..input = (Expression()
              ..messageCreation = (MessageCreation()
                ..fields.add(
                  FieldValuePair()
                    ..name = 'value'
                    ..value = args.first.value,
                ))));
      }
    }

    // .toString() -> std.to_string. Skip the shortcut when the call is
    // null-aware (`v?.toString()`); that must round-trip through
    // `null_aware_call` so the `?.` semantics survive.
    if (methodName == 'toString' &&
        args.isEmpty &&
        realTarget != null &&
        !isNullAware) {
      _usedBaseFunctions.add('to_string');
      return _buildUnaryStdCall('to_string', _encodeExpr(realTarget));
    }

    // Well-known unary method calls route to std base functions.
    // Without type resolution we can't prove the receiver type, so
    // these always route — if a non-matching receiver hits one, the
    // std function throws at runtime (same risk as unconditional
    // `.toString()` routing above). Skip when null-aware for the same
    // reason as the `.toString()` shortcut above.
    if (realTarget != null && args.isEmpty && !isNullAware) {
      const unaryRoutes = <String, String>{
        // Strings
        'toUpperCase': 'string_to_upper',
        'toLowerCase': 'string_to_lower',
        'trim': 'string_trim',
        'trimLeft': 'string_trim_start',
        'trimRight': 'string_trim_end',
        // Numbers
        'abs': 'math_abs',
        'round': 'math_round',
        'floor': 'math_floor',
        'ceil': 'math_ceil',
        'truncate': 'math_trunc',
        // num.{round,floor,ceil,truncate}ToDouble() — no-arg, return double (#100)
        'roundToDouble': 'round_to_double',
        'floorToDouble': 'floor_to_double',
        'ceilToDouble': 'ceil_to_double',
        'truncateToDouble': 'truncate_to_double',
      };
      if (unaryRoutes.containsKey(methodName)) {
        final stdName = unaryRoutes[methodName]!;
        _usedBaseFunctions.add(stdName);
        return _buildUnaryStdCall(stdName, _encodeExpr(realTarget));
      }
    }

    // ── Protobuf API → ball_proto module routing ──
    // Methods like whichExpr(), hasBody(), whichKind() route to ball_proto
    // so every target language gets deterministic protobuf access patterns.
    if (realTarget != null && args.isEmpty && !isNullAware) {
      const protoRoutes = <String, String>{
        'whichExpr': 'whichExpr',
        'whichValue': 'whichValue',
        'whichStmt': 'whichStmt',
        'whichKind': 'whichKind',
        'whichSource': 'whichSource',
        'hasBody': 'hasBody',
        'hasMetadata': 'hasMetadata',
        'hasInput': 'hasInput',
        'hasDescriptor': 'hasDescriptor',
        'hasResult': 'hasResult',
        'hasCall': 'hasCall',
        'hasLiteral': 'hasLiteral',
        'hasReference': 'hasReference',
        'hasFieldAccess': 'hasFieldAccess',
        'hasMessageCreation': 'hasMessageCreation',
        'hasBlock': 'hasBlock',
        'hasLambda': 'hasLambda',
        'hasStringValue': 'hasStringValue',
        'hasBoolValue': 'hasBoolValue',
        'hasNumberValue': 'hasNumberValue',
        'hasListValue': 'hasListValue',
        'hasStructValue': 'hasStructValue',
        'hasNullValue': 'hasNullValue',
        'hasIntValue': 'hasIntValue',
        'hasDoubleValue': 'hasDoubleValue',
        'hasBytesValue': 'hasBytesValue',
        'hasName': 'hasName',
        'hasModule': 'hasModule',
        'hasFunction': 'hasFunction',
      };
      if (protoRoutes.containsKey(methodName)) {
        final protoFn = protoRoutes[methodName]!;
        _usedProtoFunctions.add(protoFn);
        return Expression()
          ..call = (FunctionCall()
            ..module = 'ball_proto'
            ..function = protoFn
            ..input = (Expression()
              ..messageCreation = (MessageCreation()
                ..fields.add(
                  FieldValuePair()
                    ..name = 'obj'
                    ..value = _encodeExpr(realTarget),
                ))));
      }
    }

    // Null-aware method call: target?.method(args) → expanded to Block+std.if
    if (isNullAware && realTarget != null) {
      return _buildNullAwareCall(
        _encodeExpr(realTarget),
        methodName,
        args,
        _parseTypeArgs(typeArgSrc),
      );
    }

    // Collection/built-in method calls route to std_collections or std
    // with explicit module + descriptive function names. This ensures the
    // compiled engine (which dispatches by module.function) handles them
    // correctly instead of conflating e.g. list.add with arithmetic add.
    if (realTarget != null) {
      const collectionRoutes = <String, (String, String, String)>{
        // methodName -> (module, function, selfFieldName)
        // Names MUST match the Dart engine's _buildStdDispatch keys.
        'add': ('std_collections', 'list_push', 'list'),
        'addAll': ('std_collections', 'list_concat', 'list'),
        'removeLast': ('std_collections', 'list_pop', 'list'),
        'removeAt': ('std_collections', 'list_remove_at', 'list'),
        'insert': ('std_collections', 'list_insert', 'list'),
        'clear': ('std_collections', 'list_clear', 'list'),
        'contains': ('std_collections', 'list_contains', 'list'),
        'indexOf': ('std_collections', 'list_index_of', 'list'),
        'join': ('std_collections', 'list_join', 'list'),
        'sublist': ('std_collections', 'list_slice', 'list'),
        'sort': ('std_collections', 'list_sort', 'list'),
        'reversed': ('std_collections', 'list_reverse', 'list'),
        'toList': ('std_collections', 'list_to_list', 'list'),
        'map': ('std_collections', 'list_map', 'list'),
        'where': ('std_collections', 'list_filter', 'list'),
        'forEach': ('std_collections', 'list_foreach', 'list'),
        'any': ('std_collections', 'list_any', 'list'),
        'every': ('std_collections', 'list_all', 'list'),
        'reduce': ('std_collections', 'list_reduce', 'list'),
        'containsKey': ('std_collections', 'map_contains_key', 'map'),
        'containsValue': ('std_collections', 'map_contains_value', 'map'),
        'putIfAbsent': ('std_collections', 'map_put_if_absent', 'map'),
        'toDouble': ('std', 'to_double', 'value'),
        'toInt': ('std', 'to_int', 'value'),
        'clamp': ('std', 'math_clamp', 'value'),
        'compareTo': ('std', 'compare_to', 'value'),
        'toStringAsFixed': ('std', 'to_string_as_fixed', 'value'),
        'toStringAsExponential': ('std', 'to_string_as_exponential', 'value'),
        'toStringAsPrecision': ('std', 'to_string_as_precision', 'value'),
        'substring': ('std', 'string_substring', 'value'),
        'split': ('std', 'string_split', 'value'),
        'replaceAll': ('std', 'string_replace_all', 'value'),
        'replaceFirst': ('std', 'string_replace', 'value'),
        'lastIndexOf': ('std', 'string_last_index_of', 'left'),
        'gcd': ('std', 'math_gcd', 'left'),
        'startsWith': ('std', 'string_starts_with', 'left'),
        'endsWith': ('std', 'string_ends_with', 'left'),
        'padLeft': ('std', 'string_pad_left', 'value'),
        'padRight': ('std', 'string_pad_right', 'value'),
        'codeUnitAt': ('std', 'string_code_unit_at', 'value'),
      };

      final route = collectionRoutes[methodName];
      if (route != null) {
        final (module, fnName, selfField) = route;
        _usedBaseFunctions.add(fnName);
        if (module == 'std_collections') _usedCollectionsFunctions.add(fnName);
        // Rename generic arg0/arg1 to meaningful field names for the
        // target std function so engines can dispatch by field name.
        final renamedArgs = <FieldValuePair>[...args];
        for (var i = 0; i < renamedArgs.length; i++) {
          final a = renamedArgs[i];
          if (a.name == 'arg0') {
            a.name = switch (fnName) {
              'list_reduce' => 'callback',
              'list_add' || 'list_contains' || 'list_index_of' => 'value',
              'list_join' => 'separator',
              'list_insert' => 'index',
              'list_remove_at' => 'index',
              'list_sublist' => 'start',
              'map_contains_key' => 'key',
              'map_contains_value' => 'value',
              'map_remove' => 'key',
              'map_put_if_absent' => 'key',
              'list_slice' => 'start',
              'string_substring' => 'start',
              'string_split' => 'separator',
              'string_replace' || 'string_replace_all' => 'from',
              'string_starts_with' || 'string_ends_with' => 'right',
              'string_last_index_of' => 'right',
              'math_gcd' => 'right',
              'string_pad_left' || 'string_pad_right' => 'width',
              'string_code_unit_at' => 'index',
              'math_clamp' => 'min',
              'compare_to' => 'other',
              'to_string_as_fixed' => 'digits',
              'to_string_as_exponential' => 'digits',
              'to_string_as_precision' => 'precision',
              _ => 'value',
            };
          } else if (a.name == 'arg1') {
            a.name = switch (fnName) {
              'list_insert' => 'value',
              'list_slice' => 'end',
              'list_sublist' => 'end',
              'map_put_if_absent' => 'value',
              'string_substring' => 'end',
              'string_replace' || 'string_replace_all' => 'to',
              'string_pad_left' || 'string_pad_right' => 'padding',
              'math_clamp' => 'max',
              _ => 'value',
            };
          }
        }
        final encodedTarget = _encodeExpr(realTarget);
        final routedFields = <FieldValuePair>[
          FieldValuePair()
            ..name = selfField
            ..value = encodedTarget,
          ...renamedArgs,
        ];
        final callExpr = Expression()
          ..call = (FunctionCall()
            ..module = module
            ..function = fnName
            ..input = (Expression()
              ..messageCreation = (MessageCreation()
                ..fields.addAll(routedFields))));

        // Mutating methods that DO NOT return a meaningful value: wrap in
        // assign(target, value) so non-mutating runtimes hold the new/mutated
        // collection. list_remove_at and list_pop are excluded because in
        // Dart they return the removed element, not the list — wrapping
        // them in assign would corrupt the receiver and lose the return
        // value.
        const mutatingMethods = {
          'list_push',
          'list_clear',
          'list_sort',
          'list_insert',
          'list_concat',
        };
        if (mutatingMethods.contains(fnName) &&
            realTarget is ast.SimpleIdentifier) {
          _usedBaseFunctions.add('assign');
          return Expression()
            ..call = (FunctionCall()
              ..module = _moduleForFunction('assign')
              ..function = 'assign'
              ..input = (Expression()
                ..messageCreation = (MessageCreation()
                  ..fields.addAll([
                    FieldValuePair()
                      ..name = 'target'
                      ..value = encodedTarget,
                    FieldValuePair()
                      ..name = 'value'
                      ..value = callExpr,
                  ]))));
        }
        return callExpr;
      }

      // Generic method call on an object — fallback for unknown methods.
      final call = FunctionCall()..function = methodName;
      final methodArgs = <FieldValuePair>[
        FieldValuePair()
          ..name = 'self'
          ..value = _encodeExpr(realTarget),
        ...args,
      ];
      // Preserve type arguments as structured TypeRef on the FunctionCall.
      call.typeArgs.addAll(_parseTypeArgs(typeArgSrc));
      call.input = Expression()
        ..messageCreation = (MessageCreation()..fields.addAll(methodArgs));
      return Expression()..call = call;
    }

    final call = FunctionCall()..function = methodName;
    // Preserve type arguments (e.g. `binarySearchBy<E, E>(...)`).
    call.typeArgs.addAll(_parseTypeArgs(typeArgSrc));
    _setCallInput(call, args);
    return Expression()..call = call;
  }

  /// Whether [name] syntactically looks like a type/constructor name rather
  /// than a function: its first letter (after any leading private `_`) is an
  /// upper-cased character. Returns false for all-underscore names and for
  /// lower-cased private functions like `_putAll`.
  static bool _looksLikeTypeName(String name) {
    var i = 0;
    while (i < name.length && name[i] == '_') {
      i++;
    }
    if (i >= name.length) return false; // all underscores / empty
    final c = name[i];
    return c == c.toUpperCase() && c != c.toLowerCase();
  }

  // ---- Instance creation ----
  Expression _encodeInstanceCreation(ast.InstanceCreationExpression expr) {
    // Resolve the ball-qualified type name: "module:TypeName".
    // If the Dart constructor has an import prefix (e.g. `foo.Bar()`), map
    // the prefix to the corresponding ball module; otherwise assume the type
    // belongs to the current module being encoded.
    final namedType = expr.constructorName.type;
    final importPrefix = namedType.importPrefix?.name.lexeme;
    final bareTypeName = namedType.name.lexeme;

    // Without type resolution, `parseString` may misinterpret a named
    // constructor like `const SpanStatus.internalError()` as having an
    // import prefix of "SpanStatus" and type name "internalError".
    // Detect this: if the "prefix" is not a known import AND starts with
    // an uppercase letter, it's actually `ClassName.namedCtor`.
    final bool isPrefixMisparse =
        importPrefix != null &&
        !_prefixToModule.containsKey(importPrefix) &&
        importPrefix.isNotEmpty &&
        importPrefix[0] == importPrefix[0].toUpperCase() &&
        importPrefix[0] != importPrefix[0].toLowerCase();

    final String ballModule;
    final String ballTypeName;
    final String? ctorName;
    if (isPrefixMisparse) {
      // Treat as ClassName.namedCtor (importPrefix is really the class name,
      // bareTypeName is really the named constructor).
      ballModule = _moduleName;
      ballTypeName = '$ballModule:$importPrefix';
      ctorName = bareTypeName; // The "type name" is really the ctor name.
    } else {
      ballModule = importPrefix != null
          ? (_prefixToModule[importPrefix] ?? importPrefix)
          : _moduleName;
      ballTypeName = '$ballModule:$bareTypeName';
      ctorName = expr.constructorName.name?.name;
    }

    final args = _encodeArgList(expr.argumentList);

    // Preserve type arguments (e.g. `Map<String,String>.from(...)`)
    // as structured TypeRef in metadata.
    final typeArgSrc = namedType.typeArguments?.toSource();
    final fullTypeName = ctorName != null
        ? '$ballTypeName.$ctorName'
        : ballTypeName;
    final msg = MessageCreation()
      ..typeName = fullTypeName
      ..fields.addAll(args);
    _setTypeArgsMetadata(msg, typeArgSrc);
    _setTypeArgsField(msg, typeArgSrc);
    // Preserve const keyword for const constructor calls in metadata.
    if (expr.keyword?.lexeme == 'const') {
      msg.ensureMetadata().fields['is_const'] = structpb.Value()
        ..boolValue = true;
    }

    return Expression()..messageCreation = msg;
  }

  // ---- Assignment ----
  Expression _encodeAssignment(ast.AssignmentExpression expr) {
    final op = expr.operator.lexeme;
    _usedBaseFunctions.add('assign');

    if (op == '=') {
      return _buildStdCall('assign', [
        FieldValuePair()
          ..name = 'target'
          ..value = _encodeExpr(expr.leftHandSide),
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(expr.rightHandSide),
      ]);
    }

    // Compound assignment: +=, -=, etc.
    return _buildStdCall('assign', [
      FieldValuePair()
        ..name = 'target'
        ..value = _encodeExpr(expr.leftHandSide),
      FieldValuePair()
        ..name = 'op'
        ..value = (Expression()..literal = (Literal()..stringValue = op)),
      FieldValuePair()
        ..name = 'value'
        ..value = _encodeExpr(expr.rightHandSide),
    ]);
  }

  // ---- Cascade ----
  Expression _encodeCascade(ast.CascadeExpression expr) {
    // Optimization: single-section cascades where the section is a method call
    // matching a known collection route can be encoded directly as that route.
    // This avoids the compiler wrapping cascades in parentheses on round-trip,
    // since the compiler generates `target..method(arg)` from collection ops.
    if (expr.cascadeSections.length == 1 &&
        !expr.isNullAware &&
        expr.cascadeSections[0] is ast.MethodInvocation) {
      final section = expr.cascadeSections[0] as ast.MethodInvocation;
      final result = _tryEncodeCascadeAsCollectionCall(expr.target, section);
      if (result != null) return result;
    }

    // Expand cascade to Block: let __cascade_self__ = target; sections; result.
    final wasInCascade = _inCascadeSection;
    _inCascadeSection = true;
    final sections = expr.cascadeSections.map(_encodeExpr).toList();
    _inCascadeSection = wasInCascade;

    final targetExpr = _encodeExpr(expr.target);
    final metaFields = <String, structpb.Value>{
      'kind': structpb.Value()..stringValue = 'cascade',
    };
    if (expr.isNullAware) {
      metaFields['null_aware'] = structpb.Value()..boolValue = true;
    }
    final letStmt = Statement()
      ..let = (LetBinding()
        ..name = '__cascade_self__'
        ..value = targetExpr
        ..metadata = (structpb.Struct()..fields.addAll(metaFields)));

    final sectionStmts = sections
        .map((s) => Statement()..expression = s)
        .toList();

    if (expr.isNullAware) {
      _usedBaseFunctions.addAll(['if', 'equals']);
      return Expression()
        ..block = (Block()
          ..statements.add(letStmt)
          ..result = _buildNullGuard(
            () => _refExpr('__cascade_self__'),
            Expression()
              ..block = (Block()
                ..statements.addAll(sectionStmts)
                ..result = _refExpr('__cascade_self__')),
          ));
    }

    return Expression()
      ..block = (Block()
        ..statements.add(letStmt)
        ..statements.addAll(sectionStmts)
        ..result = _refExpr('__cascade_self__'));
  }

  /// Try to encode a single-section cascade as a collection/std call.
  /// For example, `queue..add('Alice')` → std_collections.list_push.
  /// Returns null if the cascade section doesn't match a known route.
  Expression? _tryEncodeCascadeAsCollectionCall(
    ast.Expression target,
    ast.MethodInvocation section,
  ) {
    final methodName = section.methodName.name;

    // Known mutating methods that the compiler generates as cascades.
    //
    // `addAll` is deliberately NOT routed here: it exists on both `List` and
    // `Map`, and this syntactic encoder cannot tell the receiver's type. The
    // list route (`list_concat`) lowers to a list spread `[...a, ...b]`, which
    // is wrong for a map receiver (e.g. `_ballUserMap()..addAll(fields)` →
    // `[..._ballUserMap(), ...fields]`, a type error, and at runtime
    // `_stdAsList` would mangle the map). Letting the single-section `..addAll`
    // fall through to the general cascade-Block path preserves the literal
    // `target.addAll(other)` method call, which Dart resolves correctly for
    // both List and Map.
    const cascadeCollectionRoutes = <String, (String, String, String)>{
      'add': ('std_collections', 'list_push', 'list'),
      'clear': ('std_collections', 'list_clear', 'list'),
      'insert': ('std_collections', 'list_insert', 'list'),
      'sort': ('std_collections', 'list_sort', 'list'),
    };

    final route = cascadeCollectionRoutes[methodName];
    if (route == null) return null;

    final (module, fnName, selfField) = route;
    _usedBaseFunctions.add(fnName);
    _usedCollectionsFunctions.add(fnName);

    // Encode arguments using the same pattern as _encodeArgList.
    final args = _encodeArgList(section.argumentList);

    // Rename generic arg0/arg1 to meaningful field names.
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.name == 'arg0') {
        a.name = switch (fnName) {
          'list_push' || 'list_contains' || 'list_index_of' => 'value',
          'list_insert' => 'index',
          'list_concat' => 'value',
          _ => 'value',
        };
      } else if (a.name == 'arg1') {
        a.name = switch (fnName) {
          'list_insert' => 'value',
          _ => 'value',
        };
      }
    }

    final encodedTarget = _encodeExpr(target);
    final routedFields = <FieldValuePair>[
      FieldValuePair()
        ..name = selfField
        ..value = encodedTarget,
      ...args,
    ];
    final callExpr = Expression()
      ..call = (FunctionCall()
        ..module = module
        ..function = fnName
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..fields.addAll(routedFields))));

    // Mutating methods: wrap in assign so non-mutating runtimes hold the
    // new/mutated collection.
    const mutatingMethods = {
      'list_push',
      'list_clear',
      'list_sort',
      'list_insert',
      'list_concat',
    };
    if (mutatingMethods.contains(fnName) && target is ast.SimpleIdentifier) {
      _usedBaseFunctions.add('assign');
      return Expression()
        ..call = (FunctionCall()
          ..module = _moduleForFunction('assign')
          ..function = 'assign'
          ..input = (Expression()
            ..messageCreation = (MessageCreation()
              ..fields.addAll([
                FieldValuePair()
                  ..name = 'target'
                  ..value = encodedTarget,
                FieldValuePair()
                  ..name = 'value'
                  ..value = callExpr,
              ]))));
    }
    return callExpr;
  }

  // ---- Lambda / FunctionExpression ----
  Expression _encodeFunctionExpression(ast.FunctionExpression expr) {
    final params = expr.parameters;

    final body = expr.body;
    // Determine hasReturn for lambdas: check if the body contains any
    // explicit return statements with values.  If there are none, the
    // lambda is likely void and we should NOT insert `return` on the last
    // expression.
    final bool hasReturn;
    if (body is ast.BlockFunctionBody) {
      hasReturn = body.block.statements.any(
        (s) => s is ast.ReturnStatement && s.expression != null,
      );
    } else {
      hasReturn = true; // expression bodies always "return"
    }
    Expression bodyExpr;
    if (body is ast.ExpressionFunctionBody) {
      bodyExpr = _encodeExpr(body.expression);
    } else if (body is ast.BlockFunctionBody) {
      bodyExpr = _encodeBlock(body.block.statements, hasReturn: hasReturn);
    } else {
      bodyExpr = Expression()..literal = Literal();
    }

    final lambdaDef = FunctionDefinition()
      ..name =
          '' // anonymous
      ..body = bodyExpr;

    // Store full parameter info in metadata for round-tripping.
    final meta = <String, Object>{'kind': 'lambda'};
    if (body is ast.ExpressionFunctionBody) meta['expression_body'] = true;
    if (hasReturn) meta['has_return'] = true;
    if (body.isAsynchronous) meta['is_async'] = true;
    if (body.isSynchronous && body.star != null) meta['is_sync_star'] = true;
    if (body.isAsynchronous && body.star != null) meta['is_async_star'] = true;
    _encodeParamsMeta(params, meta);
    lambdaDef.metadata = _toStruct(meta);

    return Expression()..lambda = lambdaDef;
  }

  // ---- String interpolation ----
  Expression _encodeStringInterpolation(ast.StringInterpolation expr) {
    _usedBaseFunctions.add('concat');
    _usedBaseFunctions.add('to_string');

    final parts = <Expression>[];
    for (final element in expr.elements) {
      if (element is ast.InterpolationString) {
        if (element.value.isNotEmpty) {
          parts.add(
            Expression()..literal = (Literal()..stringValue = element.value),
          );
        }
      } else if (element is ast.InterpolationExpression) {
        final encoded = _encodeExpr(element.expression);
        // Avoid double to_string wrapping — if the expression already
        // encodes as a base to_string call, don't wrap again.
        if (encoded.whichExpr() == Expression_Expr.call &&
            encoded.call.module == _moduleForFunction('to_string') &&
            encoded.call.function == 'to_string') {
          parts.add(encoded);
        } else {
          parts.add(_buildUnaryStdCall('to_string', encoded));
        }
      }
    }

    if (parts.isEmpty) {
      return Expression()..literal = (Literal()..stringValue = '');
    }
    return _buildConcatChain(parts);
  }

  // ---- Collection literals ----
  Expression _encodeListLiteral(ast.ListLiteral expr) {
    final elements = <Expression>[];
    for (final e in expr.elements) {
      elements.add(_encodeCollectionElement(e));
    }
    final listExpr = Expression()
      ..literal = (Literal()
        ..listValue = (ListLiteral()..elements.addAll(elements)));

    // Preserve explicit type arguments for round-tripping.
    if (expr.typeArguments != null) {
      _usedBaseFunctions.add('typed_list');
      return _buildStdCall('typed_list', [
        FieldValuePair()
          ..name = 'type_args'
          ..value = (Expression()
            ..literal = (Literal()
              ..stringValue = expr.typeArguments!.toSource())),
        FieldValuePair()
          ..name = 'elements'
          ..value = listExpr,
      ]);
    }
    return listExpr;
  }

  /// Whether a collection element ultimately yields a map entry (`key: value`),
  /// looking through `for`/`if` comprehension elements. Spread is ambiguous
  /// without type resolution (could spread a map OR a set), so it abstains.
  bool _collectionElementYieldsMapEntry(ast.CollectionElement e) {
    if (e is ast.MapLiteralEntry) return true;
    if (e is ast.ForElement) return _collectionElementYieldsMapEntry(e.body);
    if (e is ast.IfElement) {
      return _collectionElementYieldsMapEntry(e.thenElement) ||
          (e.elseElement != null &&
              _collectionElementYieldsMapEntry(e.elseElement!));
    }
    return false;
  }

  /// Whether an empty, untyped `{}` collection literal is the initializer of a
  /// variable whose SYNTACTICALLY VISIBLE declared type is `Set<...>` — the only
  /// case where a bare empty braces literal encodes as a Set rather than the Map
  /// default. The encoder is `parseString`-syntactic (no resolution), so this
  /// inspects only the literal's immediate declaration context:
  ///   `Set<int> x = {};`   (local / field / top-level variable declaration)
  ///
  /// Notably NOT honored (verified against the `dart run` oracle):
  ///   - `{} as Set<int>` — Dart infers the bare `{}` as `Map` FIRST, then the
  ///     cast throws `_TypeError` at runtime. Encoding it as a Set would make
  ///     the Ball program silently produce a set where Dart throws, so it stays
  ///     a Map (and the engine's `as` cast then fails, matching Dart).
  ///   - return-position / argument-position context (`Set<int> f() => {}`,
  ///     `takesSet({})`): genuinely sets in Dart, but no Ball-portable source
  ///     relies on them (all empty `{}` in the corpus and the self-hosted engine
  ///     are `Map<..>` declarations or the one `Set<int> seen = {}` var-decl).
  ///     Argument position also needs callee resolution the encoder lacks.
  bool _emptyBracesDeclaredAsSet(ast.SetOrMapLiteral expr) {
    final parent = expr.parent;
    if (parent is ast.VariableDeclaration &&
        identical(parent.initializer, expr)) {
      final list = parent.parent;
      if (list is ast.VariableDeclarationList) {
        final type = list.type;
        if (type != null) {
          final src = type.toSource();
          // Anchor on the `Set` name so `SetLike<int>` cannot false-positive.
          return src == 'Set' || src.startsWith('Set<');
        }
      }
    }
    return false;
  }

  Expression _encodeSetOrMapLiteral(ast.SetOrMapLiteral expr) {
    // Determine if it is a map or a set.
    // Note: isMap on SetOrMapLiteral requires full type resolution and returns
    // false when using parseString (no analysis context). Use heuristics:
    //   1. Two type arguments → always a map  e.g. <String, dynamic>{}
    //   2. Non-empty and first element is MapLiteralEntry → map
    //   3. Otherwise → set
    final typeArgCount = expr.typeArguments?.arguments.length ?? 0;
    final hasDoubleTypeArgs = typeArgCount == 2;
    final hasSingleTypeArg = typeArgCount == 1;
    // A comprehension element (`for`/`if`) whose leaf is a `key: value` entry
    // makes the whole literal a MAP, even though `elements.first` is the
    // For/If element rather than the entry itself. Look THROUGH comprehension
    // elements so `{for (...) k: v}` encodes as a map, not a set (issue #55).
    final hasMapEntry = expr.elements.any(_collectionElementYieldsMapEntry);
    // Decide set-vs-map syntactically (parseString has no static types):
    //   - `<K, V>{...}` (two type args)      -> Map (unambiguous)
    //   - any `key: value` entry             -> Map (even inside a for/if)
    //   - `<T>{...}` (one type arg)          -> Set (unambiguous)
    //   - non-empty bare braces `{a, b}`     -> Set (`{k: v}` took hasMapEntry)
    //   - EMPTY bare braces `{}`             -> AMBIGUOUS: default to Map
    //     (Dart's own default; the `dart run` oracle treats `var x = {}` and
    //     `Map<..> x = {}` as a Map), UNLESS a syntactically visible declared
    //     type says Set (`Set<..> x = {}` / `{} as Set<..>`).
    //
    // An empty `{}` used to be encoded ALWAYS as `set_create`, relying on the
    // engine to coerce it back to a Map by the `let`/field type. That worked on
    // the tree-walkers but mis-tagged the value on the C++ direct-compile path
    // (no such coercion): once an empty set began carrying the portable set tag
    // `{'__ball_set__': []}`, `Map<int,int> m = {}` was constructed as a set and
    // corrupted every subsequent map op (issues #174 / #184 root cause).
    final bool isMap;
    if (hasDoubleTypeArgs || hasMapEntry) {
      isMap = true;
    } else if (hasSingleTypeArg || expr.elements.isNotEmpty) {
      isMap = false; // unambiguous Set literal
    } else {
      isMap = !_emptyBracesDeclaredAsSet(expr);
    }

    if (isMap) {
      _usedBaseFunctions.add('map_create');
      final entries = <FieldValuePair>[];
      // Preserve explicit type args e.g. <String, dynamic>{}.
      if (expr.typeArguments != null) {
        entries.add(
          FieldValuePair()
            ..name = 'type_args'
            ..value = (Expression()
              ..literal = (Literal()
                ..stringValue = expr.typeArguments!.arguments
                    .map((a) => a.toSource())
                    .join(', '))),
        );
      }
      for (final e in expr.elements) {
        if (e is ast.MapLiteralEntry) {
          entries.add(
            FieldValuePair()
              ..name = 'entry'
              ..value = (Expression()
                ..messageCreation = (MessageCreation()
                  ..fields.addAll([
                    FieldValuePair()
                      ..name = 'key'
                      ..value = _encodeExpr(e.key),
                    FieldValuePair()
                      ..name = 'value'
                      ..value = _encodeExpr(e.value),
                  ]))),
          );
        } else {
          entries.add(
            FieldValuePair()
              ..name = 'element'
              ..value = _encodeCollectionElement(e),
          );
        }
      }
      return _buildStdCall('map_create', entries);
    } else {
      _usedBaseFunctions.add('set_create');
      final elements = <Expression>[];
      for (final e in expr.elements) {
        elements.add(_encodeCollectionElement(e));
      }
      final setFields = <FieldValuePair>[];
      // Preserve explicit type arguments for typed set literals, e.g. <T>{}.
      final typeArgs = expr.typeArguments?.arguments;
      if (typeArgs != null && typeArgs.isNotEmpty) {
        setFields.add(
          FieldValuePair()
            ..name = 'type_args'
            ..value = (Expression()
              ..literal = (Literal()
                ..stringValue = typeArgs.map((t) => t.toSource()).join(', '))),
        );
      }
      setFields.add(
        FieldValuePair()
          ..name = 'elements'
          ..value = (Expression()
            ..literal = (Literal()
              ..listValue = (ListLiteral()..elements.addAll(elements)))),
      );
      return _buildStdCall('set_create', setFields);
    }
  }

  Expression _encodeRecordLiteral(ast.RecordLiteral expr) {
    _usedBaseFunctions.add('record');
    final fields = <FieldValuePair>[];
    // Positional record fields are named 1-based (`$1`, `$2`, ...) to match
    // Dart's positional getters (`record.$1`), the pattern-destructure accessor
    // side (_tryEncodePatternVarDeclStatements emits `.$1`/`.$2`), and the
    // C++/TS compilers which lower `.$N` field access as 1-based
    // (`stoi(substr(1)) - 1`). The literal emitters in those compilers are
    // order-based, so the field name number does not affect them.
    var positionalIndex = 1;
    for (final field in expr.fields) {
      // analyzer 13: RecordLiteral.fields are RecordLiteralField; named fields
      // are RecordLiteralNamedField (NamedExpression was removed).
      if (field is ast.RecordLiteralNamedField) {
        fields.add(
          FieldValuePair()
            ..name = field.name.lexeme
            ..value = _encodeExpr(field.fieldExpression),
        );
      } else {
        fields.add(
          FieldValuePair()
            ..name = '\$$positionalIndex'
            ..value = _encodeExpr(field.fieldExpression),
        );
        positionalIndex++;
      }
    }
    return _buildStdCall('record', fields);
  }

  Expression _encodeCollectionElement(ast.CollectionElement element) {
    if (element is ast.Expression) {
      return _encodeExpr(element);
    }
    if (element is ast.SpreadElement) {
      final fn = element.isNullAware ? 'null_spread' : 'spread';
      _usedBaseFunctions.add(fn);
      return _buildStdCall(fn, [
        FieldValuePair()
          ..name = 'value'
          ..value = _encodeExpr(element.expression),
      ]);
    }
    if (element is ast.IfElement) {
      _usedBaseFunctions.add('collection_if');
      // Build the condition expression. For if-case patterns, include the
      // `case <pattern>` clause verbatim so the compiler can round-trip it.
      final Expression conditionExpr;
      if (element.caseClause != null) {
        final condSrc =
            '${element.expression.toSource()} case ${element.caseClause!.guardedPattern.toSource()}';
        conditionExpr = Expression()..reference = (Reference()..name = condSrc);
      } else {
        conditionExpr = _encodeExpr(element.expression);
      }
      final fields = <FieldValuePair>[
        FieldValuePair()
          ..name = 'condition'
          ..value = conditionExpr,
        FieldValuePair()
          ..name = 'then'
          ..value = _encodeCollectionElement(element.thenElement),
      ];
      if (element.elseElement != null) {
        fields.add(
          FieldValuePair()
            ..name = 'else'
            ..value = _encodeCollectionElement(element.elseElement!),
        );
      }
      return _buildStdCall('collection_if', fields);
    }
    if (element is ast.ForElement) {
      _usedBaseFunctions.add('collection_for');
      final fields = <FieldValuePair>[];
      final parts = element.forLoopParts;
      if (parts is ast.ForEachPartsWithDeclaration) {
        fields.add(
          FieldValuePair()
            ..name = 'variable'
            ..value = (Expression()
              ..literal = (Literal()
                ..stringValue = parts.loopVariable.name.lexeme)),
        );
        fields.add(
          FieldValuePair()
            ..name = 'iterable'
            ..value = _encodeExpr(parts.iterable),
        );
      } else if (parts is ast.ForEachPartsWithIdentifier) {
        fields.add(
          FieldValuePair()
            ..name = 'variable'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = parts.identifier.name)),
        );
        fields.add(
          FieldValuePair()
            ..name = 'iterable'
            ..value = _encodeExpr(parts.iterable),
        );
      } else if (parts is ast.ForPartsWithDeclarations ||
          parts is ast.ForPartsWithExpression) {
        // C-style for inside a collection literal — e.g.
        // `[for (var i = 0; i < n; i++) f(i)]`. Store the init as a
        // block with LetBinding statements so engines don't need to
        // parse raw Dart syntax strings.
        if (parts is ast.ForPartsWithDeclarations) {
          fields.add(
            FieldValuePair()
              ..name = 'init'
              ..value = _encodeVarDeclListAsBlock(parts.variables),
          );
          if (parts.condition != null) {
            fields.add(
              FieldValuePair()
                ..name = 'condition'
                ..value = _encodeExpr(parts.condition!),
            );
          }
          if (parts.updaters.isNotEmpty) {
            fields.add(
              FieldValuePair()
                ..name = 'update'
                ..value = _encodeExpr(parts.updaters.first),
            );
          }
        } else if (parts is ast.ForPartsWithExpression) {
          if (parts.initialization != null) {
            fields.add(
              FieldValuePair()
                ..name = 'init'
                ..value = _encodeExpr(parts.initialization!),
            );
          }
          if (parts.condition != null) {
            fields.add(
              FieldValuePair()
                ..name = 'condition'
                ..value = _encodeExpr(parts.condition!),
            );
          }
          if (parts.updaters.isNotEmpty) {
            fields.add(
              FieldValuePair()
                ..name = 'update'
                ..value = _encodeExpr(parts.updaters.first),
            );
          }
        }
      }
      fields.add(
        FieldValuePair()
          ..name = 'body'
          ..value = _encodeCollectionElement(element.body),
      );
      return _buildStdCall('collection_for', fields);
    }
    if (element is ast.MapLiteralEntry) {
      return Expression()
        ..messageCreation = (MessageCreation()
          ..fields.addAll([
            FieldValuePair()
              ..name = 'key'
              ..value = _encodeExpr(element.key),
            FieldValuePair()
              ..name = 'value'
              ..value = _encodeExpr(element.value),
          ]));
    }
    // Fail loud: emitting a placeholder string literal would silently corrupt
    // the program (the comment becomes a runtime value). A new collection
    // element kind must get a real encoding here, not a silent degradation.
    throw UnsupportedError(
      'Encoder: unsupported collection element ${element.runtimeType}. '
      'Add an encoding for it in _encodeCollectionElement.',
    );
  }

  // ---- Switch expression ----
  Expression _encodeSwitchExpression(ast.SwitchExpression expr) {
    _usedBaseFunctions.add('switch_expr');
    final cases = <Expression>[];
    for (final case_ in expr.cases) {
      final caseFields = <FieldValuePair>[
        FieldValuePair()
          ..name = 'pattern'
          ..value = (Expression()
            ..literal = (Literal()
              ..stringValue = case_.guardedPattern.toSource())),
        FieldValuePair()
          ..name = 'body'
          ..value = _encodeExpr(case_.expression),
      ];
      // Structured pattern encoding (9.6)
      final structuredPat = _encodePattern(case_.guardedPattern.pattern);
      if (structuredPat != null) {
        caseFields.add(
          FieldValuePair()
            ..name = 'pattern_expr'
            ..value = structuredPat,
        );
      }
      // `when` guard: `<pattern> when <expr> => …`. The engine evaluates it
      // against the case's pattern bindings; compilers re-emit `when <expr>`.
      final whenClause = case_.guardedPattern.whenClause;
      if (whenClause != null) {
        caseFields.add(
          FieldValuePair()
            ..name = 'guard'
            ..value = _encodeExpr(whenClause.expression),
        );
      }
      cases.add(
        Expression()
          ..messageCreation = (MessageCreation()..fields.addAll(caseFields)),
      );
    }
    return _buildStdCall('switch_expr', [
      FieldValuePair()
        ..name = 'subject'
        ..value = _encodeExpr(expr.expression),
      FieldValuePair()
        ..name = 'cases'
        ..value = (Expression()
          ..literal = (Literal()
            ..listValue = (ListLiteral()..elements.addAll(cases)))),
    ]);
  }

  // ============================================================
  // Pattern Encoding (Tier 9.6)
  // ============================================================

  /// Encode a Dart pattern as a structured Ball expression.
  ///
  /// The result is a MessageCreation with typeName set to the pattern kind
  /// (e.g. `TypeTestPattern`, `VarPattern`, `ListPattern`, etc.) and fields
  /// matching the destructured parts.
  ///
  /// Returns null if the pattern can't be structurally encoded.
  Expression? _encodePattern(ast.DartPattern pattern) {
    if (pattern is ast.DeclaredVariablePattern) {
      // `int x` or `var x`
      final fields = <FieldValuePair>[
        FieldValuePair()
          ..name = 'name'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = pattern.name.lexeme)),
      ];
      if (pattern.type != null) {
        fields.add(
          FieldValuePair()
            ..name = 'type'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = pattern.type!.toSource())),
        );
      }
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'VarPattern'
          ..fields.addAll(fields));
    }
    if (pattern is ast.WildcardPattern) {
      // `_` wildcard
      final fields = <FieldValuePair>[];
      if (pattern.type != null) {
        fields.add(
          FieldValuePair()
            ..name = 'type'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = pattern.type!.toSource())),
        );
      }
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'WildcardPattern'
          ..fields.addAll(fields));
    }
    if (pattern is ast.ConstantPattern) {
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'ConstPattern'
          ..fields.add(
            FieldValuePair()
              ..name = 'value'
              ..value = _encodeExpr(pattern.expression),
          ));
    }
    if (pattern is ast.ListPattern) {
      final elements = <Expression>[];
      for (final elem in pattern.elements) {
        if (elem is ast.DartPattern) {
          final encoded = _encodePattern(elem);
          if (encoded != null) elements.add(encoded);
        } else if (elem is ast.RestPatternElement) {
          final sub = elem.pattern != null
              ? _encodePattern(elem.pattern!)
              : null;
          elements.add(
            Expression()
              ..messageCreation = (MessageCreation()
                ..typeName = 'RestPattern'
                ..fields.addAll([
                  if (sub != null)
                    FieldValuePair()
                      ..name = 'subpattern'
                      ..value = sub,
                ])),
          );
        }
      }
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'ListPattern'
          ..fields.add(
            FieldValuePair()
              ..name = 'elements'
              ..value = (Expression()
                ..literal = (Literal()
                  ..listValue = (ListLiteral()..elements.addAll(elements)))),
          ));
    }
    if (pattern is ast.MapPattern) {
      final entries = <Expression>[];
      for (final entry in pattern.elements) {
        if (entry is ast.MapPatternEntry) {
          final valuePat = _encodePattern(entry.value);
          entries.add(
            Expression()
              ..messageCreation = (MessageCreation()
                ..fields.addAll([
                  FieldValuePair()
                    ..name = 'key'
                    ..value = _encodeExpr(entry.key),
                  if (valuePat != null)
                    FieldValuePair()
                      ..name = 'value'
                      ..value = valuePat,
                ])),
          );
        }
      }
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'MapPattern'
          ..fields.add(
            FieldValuePair()
              ..name = 'entries'
              ..value = (Expression()
                ..literal = (Literal()
                  ..listValue = (ListLiteral()..elements.addAll(entries)))),
          ));
    }
    if (pattern is ast.RecordPattern) {
      final patFields = <Expression>[];
      for (final field in pattern.fields) {
        final sub = _encodePattern(field.pattern);
        if (sub != null) {
          patFields.add(
            Expression()
              ..messageCreation = (MessageCreation()
                ..fields.addAll([
                  if (field.name != null)
                    FieldValuePair()
                      ..name = 'name'
                      ..value = (Expression()
                        ..literal = (Literal()
                          ..stringValue = () {
                            final n = field.name!.name?.lexeme;
                            if (n == null) {
                              _warn(
                                'Record pattern field has null name',
                                source: field.toSource(),
                              );
                            }
                            return n ?? '';
                          }())),
                  FieldValuePair()
                    ..name = 'pattern'
                    ..value = sub,
                ])),
          );
        }
      }
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'RecordPattern'
          ..fields.add(
            FieldValuePair()
              ..name = 'fields'
              ..value = (Expression()
                ..literal = (Literal()
                  ..listValue = (ListLiteral()..elements.addAll(patFields)))),
          ));
    }
    if (pattern is ast.ObjectPattern) {
      final objFields = <Expression>[];
      for (final field in pattern.fields) {
        final sub = _encodePattern(field.pattern);
        if (sub != null) {
          objFields.add(
            Expression()
              ..messageCreation = (MessageCreation()
                ..fields.addAll([
                  FieldValuePair()
                    ..name = 'name'
                    ..value = (Expression()
                      ..literal = (Literal()
                        ..stringValue = field.name?.name?.lexeme ?? '')),
                  FieldValuePair()
                    ..name = 'pattern'
                    ..value = sub,
                ])),
          );
        }
      }
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'ObjectPattern'
          ..fields.addAll([
            FieldValuePair()
              ..name = 'type'
              ..value = (Expression()
                ..literal = (Literal()..stringValue = pattern.type.toSource())),
            FieldValuePair()
              ..name = 'fields'
              ..value = (Expression()
                ..literal = (Literal()
                  ..listValue = (ListLiteral()..elements.addAll(objFields)))),
          ]));
    }
    if (pattern is ast.LogicalAndPattern) {
      final left = _encodePattern(pattern.leftOperand);
      final right = _encodePattern(pattern.rightOperand);
      if (left != null && right != null) {
        return Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = 'LogicalAndPattern'
            ..fields.addAll([
              FieldValuePair()
                ..name = 'left'
                ..value = left,
              FieldValuePair()
                ..name = 'right'
                ..value = right,
            ]));
      }
    }
    if (pattern is ast.LogicalOrPattern) {
      final left = _encodePattern(pattern.leftOperand);
      final right = _encodePattern(pattern.rightOperand);
      if (left != null && right != null) {
        return Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = 'LogicalOrPattern'
            ..fields.addAll([
              FieldValuePair()
                ..name = 'left'
                ..value = left,
              FieldValuePair()
                ..name = 'right'
                ..value = right,
            ]));
      }
    }
    if (pattern is ast.CastPattern) {
      final sub = _encodePattern(pattern.pattern);
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'CastPattern'
          ..fields.addAll([
            if (sub != null)
              FieldValuePair()
                ..name = 'pattern'
                ..value = sub,
            FieldValuePair()
              ..name = 'type'
              ..value = (Expression()
                ..literal = (Literal()..stringValue = pattern.type.toSource())),
          ]));
    }
    if (pattern is ast.NullCheckPattern) {
      final sub = _encodePattern(pattern.pattern);
      if (sub != null) {
        return Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = 'NullCheckPattern'
            ..fields.add(
              FieldValuePair()
                ..name = 'pattern'
                ..value = sub,
            ));
      }
    }
    if (pattern is ast.NullAssertPattern) {
      final sub = _encodePattern(pattern.pattern);
      if (sub != null) {
        return Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = 'NullAssertPattern'
            ..fields.add(
              FieldValuePair()
                ..name = 'pattern'
                ..value = sub,
            ));
      }
    }
    if (pattern is ast.RelationalPattern) {
      return Expression()
        ..messageCreation = (MessageCreation()
          ..typeName = 'RelationalPattern'
          ..fields.addAll([
            FieldValuePair()
              ..name = 'operator'
              ..value = (Expression()
                ..literal = (Literal()..stringValue = pattern.operator.lexeme)),
            FieldValuePair()
              ..name = 'operand'
              ..value = _encodeExpr(pattern.operand),
          ]));
    }
    // Unsupported pattern: return null so caller can fall back to string form
    return null;
  }

  // ============================================================
  // Helpers
  // ============================================================

  /// Parse a Dart type string into a structured [TypeRef].
  ///
  /// Handles generic types (`Box<int>`), nested generics
  /// (`Map<String, List<int>>`), nullable types (`int?`), and
  /// `Function` type syntax (simplified to just the name `Function`).
  static TypeRef _parseTypeRef(String typeStr) {
    typeStr = typeStr.trim();
    if (typeStr.isEmpty) return TypeRef()..name = '';

    // Handle nullable suffix.
    final nullable = typeStr.endsWith('?');
    if (nullable) typeStr = typeStr.substring(0, typeStr.length - 1).trim();

    // Find the top-level '<' that starts generic arguments.
    final angleBracketStart = _findTopLevelAngleBracket(typeStr);
    if (angleBracketStart == -1) {
      // No generics — plain type name.
      return TypeRef()
        ..name = typeStr
        ..nullable = nullable;
    }

    final name = typeStr.substring(0, angleBracketStart).trim();
    // Strip the outer angle brackets: `<int, String>` → `int, String`
    final innerStr = typeStr
        .substring(angleBracketStart + 1, typeStr.length - 1)
        .trim();
    final typeArgs = _splitTopLevelCommas(innerStr).map(_parseTypeRef).toList();

    return TypeRef()
      ..name = name
      ..typeArgs.addAll(typeArgs)
      ..nullable = nullable;
  }

  /// Parse a Dart type-arguments string (e.g. `"<int, String>"`) into a list
  /// of [TypeRef]. Returns an empty list for null/empty input.
  static List<TypeRef> _parseTypeArgs(String? typeArgsSrc) {
    if (typeArgsSrc == null || typeArgsSrc.isEmpty) return [];
    var s = typeArgsSrc.trim();
    // Strip outer angle brackets if present.
    if (s.startsWith('<') && s.endsWith('>')) {
      s = s.substring(1, s.length - 1).trim();
    }
    if (s.isEmpty) return [];
    return _splitTopLevelCommas(s).map(_parseTypeRef).toList();
  }

  /// Find the index of the first `<` that is at nesting depth 0, returning -1
  /// if none exists. Skips any `<` inside nested angle brackets.
  static int _findTopLevelAngleBracket(String s) {
    var depth = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '<') {
        if (depth == 0) return i;
        depth++;
      } else if (c == '>') {
        depth--;
      }
    }
    return -1;
  }

  /// Split a comma-separated type string at top-level commas only (respecting
  /// nested angle brackets). E.g. `"String, List<int>"` → `["String", "List<int>"]`.
  static List<String> _splitTopLevelCommas(String s) {
    final parts = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '<') {
        depth++;
      } else if (c == '>') {
        depth--;
      } else if (c == ',' && depth == 0) {
        parts.add(s.substring(start, i).trim());
        start = i + 1;
      }
    }
    final last = s.substring(start).trim();
    if (last.isNotEmpty) parts.add(last);
    return parts;
  }

  /// Set `type_args` metadata on a [MessageCreation] from a Dart type-arguments
  /// source string. Used for constructor calls (MessageCreation without a
  /// FunctionCall) where the structured TypeRef cannot be placed on
  /// FunctionCall.typeArgs.
  static void _setTypeArgsMetadata(MessageCreation msg, String? typeArgsSrc) {
    if (typeArgsSrc == null || typeArgsSrc.isEmpty) return;
    final refs = _parseTypeArgs(typeArgsSrc);
    if (refs.isEmpty) return;
    if (!msg.hasMetadata()) msg.metadata = structpb.Struct();
    msg.metadata.fields['type_args'] = structpb.Value()
      ..listValue = (structpb.ListValue()
        ..values.addAll(refs.map(_typeRefToStructValue)));
  }

  /// Redundant __type_args__ field for compiled engine compatibility.
  /// The compiled engine's proto3 JSON wrapper cannot resolve the
  /// metadata.type_args structValue chain, so we also store type args
  /// as an evaluated field that ends up in the runtime object's map.
  static void _setTypeArgsField(MessageCreation msg, String? typeArgsSrc) {
    if (typeArgsSrc == null || typeArgsSrc.isEmpty) return;
    msg.fields.insert(
      0,
      FieldValuePair()
        ..name = '__type_args__'
        ..value = (Expression()
          ..literal = (Literal()..stringValue = typeArgsSrc)),
    );
  }

  /// Convert a [TypeRef] into a [structpb.Value] (Struct representation) for
  /// storage in metadata.
  static structpb.Value _typeRefToStructValue(TypeRef ref) {
    final fields = <String, structpb.Value>{
      'name': structpb.Value()..stringValue = ref.name,
    };
    if (ref.typeArgs.isNotEmpty) {
      fields['type_args'] = structpb.Value()
        ..listValue = (structpb.ListValue()
          ..values.addAll(ref.typeArgs.map(_typeRefToStructValue)));
    }
    if (ref.nullable) {
      fields['nullable'] = structpb.Value()..boolValue = true;
    }
    return structpb.Value()
      ..structValue = (structpb.Struct()..fields.addAll(fields));
  }

  // ============================================================
  // Syntax expansion helpers — expand Dart-specific constructs into
  // universal expression trees (Block + std.if + std.equals).
  // ============================================================

  static Expression _refExpr(String name) =>
      Expression()..reference = (Reference()..name = name);

  static Expression _nullExpr() => Expression()..literal = Literal();

  /// Build `std.if(condition: std.equals(ref, null), then: null, else: elseExpr)`.
  /// Each protobuf node is a fresh instance (no aliasing).
  Expression _buildNullGuard(
    Expression Function() refBuilder,
    Expression elseExpr,
  ) {
    return _buildStdCall('if', [
      FieldValuePair()
        ..name = 'condition'
        ..value = _buildStdCall('equals', [
          FieldValuePair()
            ..name = 'left'
            ..value = refBuilder(),
          FieldValuePair()
            ..name = 'right'
            ..value = _nullExpr(),
        ]),
      FieldValuePair()
        ..name = 'then'
        ..value = _nullExpr(),
      FieldValuePair()
        ..name = 'else'
        ..value = elseExpr,
    ]);
  }

  /// Expand `target?.field` to `std.if(equals(target, null), null, target.field)`.
  /// For simple Reference targets, emits the if directly (no temp variable).
  /// For complex targets, wraps in a Block with a LetBinding to avoid
  /// evaluating the target twice.
  Expression _buildNullAwareAccess(Expression targetExpr, String field) {
    _usedBaseFunctions.addAll(['if', 'equals']);

    if (targetExpr.whichExpr() == Expression_Expr.reference) {
      final name = targetExpr.reference.name;
      return _buildNullGuard(
        () => _refExpr(name),
        Expression()
          ..fieldAccess = (FieldAccess()
            ..object = _refExpr(name)
            ..field_2 = field),
      );
    }

    final tempName = '__naa_${_tempVarCounter++}';
    return Expression()
      ..block = (Block()
        ..statements.add(
          Statement()
            ..let = (LetBinding()
              ..name = tempName
              ..value = targetExpr
              ..metadata = (structpb.Struct()
                ..fields['kind'] = (structpb.Value()
                  ..stringValue = 'null_aware_access')
                ..fields['field'] = (structpb.Value()..stringValue = field))),
        )
        ..result = _buildNullGuard(
          () => _refExpr(tempName),
          Expression()
            ..fieldAccess = (FieldAccess()
              ..object = _refExpr(tempName)
              ..field_2 = field),
        ));
  }

  /// Expand `target?.method(args)` to `std.if(equals(target, null), null, target.method(args))`.
  Expression _buildNullAwareCall(
    Expression targetExpr,
    String methodName,
    List<FieldValuePair> args,
    List<TypeRef> typeArgs,
  ) {
    _usedBaseFunctions.addAll(['if', 'equals']);

    Expression buildInnerCall(Expression Function() selfBuilder) {
      final call = FunctionCall()
        ..function = methodName
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = ''
            ..fields.addAll([
              FieldValuePair()
                ..name = 'self'
                ..value = selfBuilder(),
              ...args,
            ])));
      call.typeArgs.addAll(typeArgs);
      return Expression()..call = call;
    }

    if (targetExpr.whichExpr() == Expression_Expr.reference) {
      final name = targetExpr.reference.name;
      return _buildNullGuard(
        () => _refExpr(name),
        buildInnerCall(() => _refExpr(name)),
      );
    }

    final tempName = '__nac_${_tempVarCounter++}';
    return Expression()
      ..block = (Block()
        ..statements.add(
          Statement()
            ..let = (LetBinding()
              ..name = tempName
              ..value = targetExpr
              ..metadata = (structpb.Struct()
                ..fields['kind'] = (structpb.Value()
                  ..stringValue = 'null_aware_call')
                ..fields['method'] = (structpb.Value()
                  ..stringValue = methodName))),
        )
        ..result = _buildNullGuard(
          () => _refExpr(tempName),
          buildInnerCall(() => _refExpr(tempName)),
        ));
  }

  /// `x.isEven` / `x.isOdd` have no std getter, and emitting a raw fieldAccess
  /// crashes the engine (no `isEven` field on int) and breaks the TS/C++
  /// compilers (no such property). Compose from ops every engine + compiler
  /// already implements: `isEven` => `equals(modulo(x, 2), 0)`,
  /// `isOdd` => `not_equals(modulo(x, 2), 0)`. (Dart `%` keeps the divisor's
  /// sign, so this matches `isEven`/`isOdd` for negatives too.)
  Expression _parityCheck(Expression target, {required bool even}) {
    _usedBaseFunctions.addAll(['modulo', even ? 'equals' : 'not_equals']);
    Expression intLit(int v) =>
        Expression()..literal = (Literal()..intValue = Int64(v));
    final mod = _buildStdCall('modulo', [
      FieldValuePair()
        ..name = 'left'
        ..value = target,
      FieldValuePair()
        ..name = 'right'
        ..value = intLit(2),
    ]);
    return _buildStdCall(even ? 'equals' : 'not_equals', [
      FieldValuePair()
        ..name = 'left'
        ..value = mod,
      FieldValuePair()
        ..name = 'right'
        ..value = intLit(0),
    ]);
  }

  /// Build a base function call with named fields in the 'std' module.
  Expression _buildStdCall(String function, List<FieldValuePair> fields) {
    return Expression()
      ..call = (FunctionCall()
        ..module = _moduleForFunction(function)
        ..function = function
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = ''
            ..fields.addAll(fields))));
  }

  Expression _buildUnaryStdCall(String function, Expression value) {
    return Expression()
      ..call = (FunctionCall()
        ..module = _moduleForFunction(function)
        ..function = function
        ..input = (Expression()
          ..messageCreation = (MessageCreation()
            ..typeName = ''
            ..fields.add(
              FieldValuePair()
                ..name = 'value'
                ..value = value,
            ))));
  }

  Expression _buildConcatChain(List<Expression> parts) {
    if (parts.length == 1) return parts.first;
    _usedBaseFunctions.add('concat');
    var result = parts.first;
    for (var i = 1; i < parts.length; i++) {
      result = _buildStdCall('concat', [
        FieldValuePair()
          ..name = 'left'
          ..value = result,
        FieldValuePair()
          ..name = 'right'
          ..value = parts[i],
      ]);
    }
    return result;
  }

  List<FieldValuePair> _encodeArgList(ast.ArgumentList argList) {
    final result = <FieldValuePair>[];
    var positionalIndex = 0;
    for (final arg in argList.arguments) {
      // analyzer 13: ArgumentList.arguments are Argument nodes; named args are
      // NamedArgument (NamedExpression was removed), positional args wrap the
      // value in `.expression`.
      if (arg is ast.NamedArgument) {
        result.add(
          FieldValuePair()
            ..name = arg.name.lexeme
            ..value = _encodeExpr(arg.argumentExpression),
        );
      } else {
        result.add(
          FieldValuePair()
            ..name = 'arg$positionalIndex'
            ..value = _encodeExpr(arg.argumentExpression),
        );
        positionalIndex++;
      }
    }
    return result;
  }

  void _setCallInput(FunctionCall call, List<FieldValuePair> args) {
    if (args.isEmpty) return;
    if (args.length == 1 && args.first.name.startsWith('arg')) {
      call.input = args.first.value;
    } else {
      call.input = Expression()
        ..messageCreation = (MessageCreation()..fields.addAll(args));
    }
  }

  google.FieldDescriptorProto_Type _dartTypeToProtoType(String dartType) {
    final base = dartType.replaceAll('?', '').split('<').first.trim();
    return switch (base) {
      'int' => google.FieldDescriptorProto_Type.TYPE_INT64,
      'double' => google.FieldDescriptorProto_Type.TYPE_DOUBLE,
      'num' => google.FieldDescriptorProto_Type.TYPE_DOUBLE,
      'String' => google.FieldDescriptorProto_Type.TYPE_STRING,
      'bool' => google.FieldDescriptorProto_Type.TYPE_BOOL,
      'List' => google.FieldDescriptorProto_Type.TYPE_BYTES,
      _ => google.FieldDescriptorProto_Type.TYPE_MESSAGE,
    };
  }

  String? _dartOpToBallFunction(String op) {
    return switch (op) {
      '+' => 'add',
      '-' => 'subtract',
      '*' => 'multiply',
      '~/' => 'divide',
      '/' => 'divide_double',
      '%' => 'modulo',
      '==' => 'equals',
      '!=' => 'not_equals',
      '<' => 'less_than',
      '>' => 'greater_than',
      '<=' => 'lte',
      '>=' => 'gte',
      '&&' => 'and',
      '||' => 'or',
      '??' => 'null_coalesce',
      '&' => 'bitwise_and',
      '|' => 'bitwise_or',
      '^' => 'bitwise_xor',
      '<<' => 'left_shift',
      '>>' => 'right_shift',
      '>>>' => 'unsigned_right_shift',
      _ => null,
    };
  }

  void _encodeParamsMeta(
    ast.FormalParameterList? params,
    Map<String, Object> meta,
  ) {
    if (params == null || params.parameters.isEmpty) return;
    final paramList = <Map<String, Object>>[];
    for (final p in params.parameters) {
      final pm = <String, Object>{'name': p.name?.lexeme ?? '_'};
      if (p is ast.RegularFormalParameter && p.type != null) {
        pm['type'] = p.type!.toSource();
      }
      // analyzer 13 removed DefaultFormalParameter; an optional parameter's
      // default value now lives on the FormalParameter's `defaultClause`
      // directly (no wrapper node). The is_this / is_super / type cases are
      // handled by the standalone checks below.
      final defaultClause = p.defaultClause;
      if (defaultClause != null) {
        pm['default'] = defaultClause.value.toSource();
      }
      if (p is ast.FieldFormalParameter) {
        pm['is_this'] = true;
        if (p.type != null) pm['type'] = p.type!.toSource();
      }
      if (p is ast.SuperFormalParameter) {
        pm['is_super'] = true;
      }
      if (p.isNamed) pm['is_named'] = true;
      if (p.isOptionalPositional) pm['is_optional'] = true;
      if (p.isRequiredNamed) pm['is_required_named'] = true;
      if (p.isOptionalNamed) pm['is_optional_named'] = true;
      // `covariant T x` on a method parameter signals that subclass overrides
      // may narrow the parameter's type. Preserve so round-tripped Dart
      // passes override-invariance checks.
      if (p.covariantKeyword != null) pm['is_covariant'] = true;
      paramList.add(pm);
    }
    meta['params'] = paramList;
  }

  /// Convert a Dart map to a google.protobuf.Struct.
  structpb.Struct _toStruct(Map<String, Object> map) {
    final struct = structpb.Struct();
    for (final entry in map.entries) {
      struct.fields[entry.key] = _toStructValue(entry.value);
    }
    return struct;
  }

  structpb.Value _toStructValue(Object value) {
    if (value is String) {
      return structpb.Value()..stringValue = value;
    }
    if (value is bool) {
      return structpb.Value()..boolValue = value;
    }
    if (value is num) {
      return structpb.Value()..numberValue = value.toDouble();
    }
    if (value is List) {
      return structpb.Value()
        ..listValue = (structpb.ListValue()
          ..values.addAll(value.map((v) => _toStructValue(v as Object))));
    }
    if (value is Map<String, Object>) {
      return structpb.Value()..structValue = _toStruct(value);
    }
    return structpb.Value()..stringValue = value.toString();
  }

  /// Returns annotation source strings stripped of the leading '@' ready
  /// to be stored in metadata as `List<String>`.
  ///
  /// Returns `null` (no allocation) when there are no annotations.
  List<String>? _encodeAnnotations(ast.NodeList<ast.Annotation> metadata) {
    if (metadata.isEmpty) return null;
    return metadata.map((a) {
      final src = a.toSource();
      return src.startsWith('@') ? src.substring(1) : src;
    }).toList();
  }
}
