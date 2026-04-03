/// Dart-to-ball encoder — translates ANY valid Dart source code into ball programs.
///
/// Uses [package:analyzer] for parsing (official Dart SDK parser), so every
/// valid Dart file is parsed correctly. The encoder maps ALL Dart constructs
/// to ball primitives:
///
///   - Operators       → std.add, std.subtract, std.bitwise_and, etc.
///   - Control flow    → std.if, std.for, std.while, std.try, etc.
///   - Type operations → std.is, std.as, std.null_check, etc.
///   - Dart-specific   → dart_std.cascade, dart_std.spread, dart_std.record, etc.
///   - Classes         → DescriptorProto (fields) + FunctionDefinition (methods)
///   - Lambdas/closures → FunctionDefinition with name = "" (anonymous)
///   - Everything else → FunctionCall to std module with MessageCreation input
///
/// Language-specific metadata (import URIs, class modifiers, etc.) is preserved
/// in google.protobuf.Struct metadata fields for lossless round-tripping.
library;

import 'package:analyzer/dart/analysis/utilities.dart' show parseString;
import 'package:analyzer/dart/ast/ast.dart' as ast;
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

/// Functions that belong to the Dart-specific `dart_std` module rather than
/// the universal `std` module.
const _dartStdFunctions = {
  'null_aware_access',
  'null_aware_call',
  'cascade',
  'spread',
  'null_spread',
  'invoke',
  'map_create',
  'set_create',
  'record',
  'collection_if',
  'collection_for',
  'switch_expr',
  'symbol',
  'type_literal',
  'labeled',
  'yield_each',
  'typed_list',
};

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

  /// Ball module name for the file currently being encoded.
  /// All user-defined type names are prefixed with `"$_moduleName:"`.
  String _moduleName = 'main';

  /// True while encoding the sections of a [ast.CascadeExpression].
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
  Program encode(
    String source, {
    String name = 'encoded',
    String version = '1.0.0',
  }) {
    _prefixToModule.clear();
    _importedModules.clear();
    _usedBaseFunctions.clear();
    _importDetails.clear();
    _exportDetails.clear();
    _partDetails.clear();
    _partOfUri = null;
    warnings.clear();
    // The encoded output always uses a single module named 'main'.
    _moduleName = 'main';

    final result = parseString(content: source);
    final unit = result.unit;

    _resolveImports(unit);

    return _buildProgram(unit, name: name, version: version);
  }

  /// Encode Dart source into a single ball [Module], accumulating used
  /// base-function names for later use by [buildStdModules].
  ///
  /// Unlike [encode], this does **not** reset [_usedBaseFunctions], so you
  /// can call it for every file in a package and then call [buildStdModules]
  /// once to obtain consolidated std/dart_std modules for the whole package.
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
    final result = parseString(content: source, throwIfDiagnostics: false);
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

  /// Build consolidated std and dart_std [Module]s from all base functions
  /// accumulated since the last [encode] call or manual [clearStdAccumulator].
  ///
  /// Use after a sequence of [encodeModule] calls to obtain the shared base
  /// modules for a whole package.
  ({Module stdModule, Module? dartStdModule}) buildStdModules() =>
      (stdModule: _buildStdModule(), dartStdModule: _buildDartStdModule());

  /// Clear the accumulated set of used base functions.
  ///
  /// Call this between encoding independent packages when reusing a single
  /// [DartEncoder] instance.
  void clearStdAccumulator() => _usedBaseFunctions.clear();

  // ============================================================
  // Import resolution
  // ============================================================

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
            final m = <String, Object>{
              'name': c.name.toSource(),
              'uri': c.uri.stringValue ?? '',
            };
            if (c.value != null) m['value'] = c.value!.stringValue ?? '';
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
            final m = <String, Object>{
              'name': c.name.toSource(),
              'uri': c.uri.stringValue ?? '',
            };
            if (c.value != null) m['value'] = c.value!.stringValue ?? '';
            return m;
          }).toList();
        }
        _exportDetails.add(detail);
      } else if (directive is ast.PartDirective) {
        final uriValue = directive.uri.stringValue;
        if (uriValue != null) {
          _partDetails.add(<String, Object>{'uri': uriValue});
        }
      } else if (directive is ast.PartOfDirective) {
        if (directive.uri != null) {
          _partOfUri = directive.uri?.stringValue;
        } else if (directive.libraryName != null) {
          _partOfUri = directive.libraryName?.toSource();
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
  }) {
    final (:module, :importStubs) = _buildModule(unit, moduleName: 'main');
    final stdModule = _buildStdModule();
    final dartStdModule = _buildDartStdModule();

    return Program()
      ..name = name
      ..version = version
      ..entryModule = 'main'
      ..entryFunction = 'main'
      ..modules.addAll([stdModule, ?dartStdModule, ...importStubs, module]);
  }

  /// Builds a single ball [Module] from a parsed compilation unit.
  ///
  /// [importStubs] are empty-body placeholder modules for external imports
  /// that were not resolved via [uriOverrides] in [_resolveImports].
  /// Base-function names used during encoding are **accumulated** into
  /// [_usedBaseFunctions] — call [_buildStdModule] / [_buildDartStdModule]
  /// afterwards to materialise them.
  ({Module module, List<Module> importStubs}) _buildModule(
    ast.CompilationUnit unit, {
    required String moduleName,
  }) {
    final moduleTypes = <google.DescriptorProto>[];
    final moduleEnums = <google.EnumDescriptorProto>[];
    final moduleFunctions = <FunctionDefinition>[];
    final moduleTypeDefs = <TypeDefinition>[];
    final moduleTypeAliases = <TypeAlias>[];

    for (final decl in unit.declarations) {
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

    // Stub modules for external imports (not overridden to an in-package module).
    final importStubs = <Module>[];
    final knownModuleNames = {'std', 'dart_std', moduleName};
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
    if (_usedBaseFunctions.any((f) => _dartStdFunctions.contains(f))) {
      importNames.add('dart_std');
    }
    importNames.addAll(_importedModules);

    final module = Module()
      ..name = moduleName
      ..moduleImports.addAll(importNames.map((n) => ModuleImport()..name = n))
      ..types.addAll(moduleTypes)
      ..enums.addAll(moduleEnums)
      ..functions.addAll(moduleFunctions)
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

  /// Returns the module name for a base function ('std' or 'dart_std').
  static String _moduleForFunction(String function) =>
      _dartStdFunctions.contains(function) ? 'dart_std' : 'std';

  Module _buildStdModule() {
    final types = <String, google.DescriptorProto>{};
    final functions = <FunctionDefinition>[];

    // Only include functions that belong to the universal std module.
    final stdFunctions = _usedBaseFunctions.where(
      (f) => !_dartStdFunctions.contains(f),
    );

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
      ..types.addAll(types.values)
      ..functions.addAll(functions);
  }

  /// Build the Dart-specific dart_std module, or null if nothing was used.
  Module? _buildDartStdModule() {
    final dartFunctions = _usedBaseFunctions
        .where((f) => _dartStdFunctions.contains(f))
        .toList();

    if (dartFunctions.isEmpty) return null;

    final functions = <FunctionDefinition>[];
    for (final name in dartFunctions) {
      functions.add(
        FunctionDefinition()
          ..name = name
          ..isBase = true,
      );
    }

    return Module()
      ..name = 'dart_std'
      ..description = 'Dart-specific standard library base module'
      ..functions.addAll(functions);
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
    final methodName = member.name.lexeme;
    final def = FunctionDefinition()..name = '$className.$methodName';

    final returnType = member.returnType?.toSource();
    if (returnType != null) {
      def.outputType = returnType;
    }

    final params = member.parameters;
    if (params != null && params.parameters.isNotEmpty) {
      final first = params.parameters.first;
      if (first is ast.SimpleFormalParameter && first.type != null) {
        def.inputType = first.type!.toSource();
      }
    }

    // Encode method body.
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

  void _encodeExtensionDeclaration(
    ast.ExtensionDeclaration decl,
    List<FunctionDefinition> functions,
    List<TypeDefinition> typeDefs,
  ) {
    final extName = decl.name?.lexeme ?? '_unnamed_extension';
    final ballName = extName == '_unnamed_extension'
        ? '_unnamed_extension'
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
          : (repParam is ast.SimpleFormalParameter
                ? (repParam.type?.toSource() ?? 'dynamic')
                : repParam.toSource());
      if (repParam is ast.SimpleFormalParameter) {
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
      if (first is ast.SimpleFormalParameter && first.type != null) {
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
                ..literal = (Literal()..stringValue = stmt.label!.name)),
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
                ..literal = (Literal()..stringValue = stmt.label!.name)),
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
                ..stringValue = stmt.labels.first.label.name)),
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
        block.statements.add(_encodeStatement(s));
      }
      return Statement()..expression = (Expression()..block = block);
    }
    // Unsupported statement — store sourc as string literal for round-tripping.
    return Statement()
      ..expression = (Expression()
        ..literal = (Literal()
          ..stringValue =
              '/* unsupported: ${stmt.runtimeType}: ${stmt.toSource()} */'));
  }

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
          ..value = (Expression()
            ..literal = (Literal()
              ..stringValue = loopParts.variables.toSource())),
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
      if (loopParts.loopVariable.type != null) {
        fields.add(
          FieldValuePair()
            ..name = 'variable_type'
            ..value = (Expression()
              ..literal = (Literal()
                ..stringValue = loopParts.loopVariable.type!.toSource())),
        );
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

  // ============================================================
  // Expression encoding
  // ============================================================

  Expression _encodeExpr(ast.Expression expr) {
    // ---- Literals ----
    if (expr is ast.IntegerLiteral) {
      final lexeme = expr.literal.lexeme;
      // Preserve hex literals verbatim: dart2js / DDC reject large decimal
      // integer literals that exceed the JavaScript Number precision limit
      // (2^53).  Hex notation round-trips correctly.
      if (lexeme.startsWith('0x') || lexeme.startsWith('0X')) {
        return Expression()..reference = (Reference()..name = lexeme);
      }
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
        _usedBaseFunctions.add('null_aware_access');
        return _buildStdCall('null_aware_access', [
          FieldValuePair()
            ..name = 'target'
            ..value = targetExpr,
          FieldValuePair()
            ..name = 'field'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = field)),
        ]);
      }

      if (target is ast.SimpleIdentifier &&
          _prefixToModule.containsKey(target.name)) {
        return Expression()
          ..reference = (Reference()..name = '${target.name}.$field');
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
          inner is ast.CascadeExpression ||
          inner is ast.ConditionalExpression) {
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
      return Expression()..reference = (Reference()..name = 'this');
    }
    if (expr is ast.SuperExpression) {
      return Expression()..reference = (Reference()..name = 'super');
    }

    // ---- Named expression (in argument lists) ----
    if (expr is ast.NamedExpression) {
      return _encodeExpr(expr.expression);
    }

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
    if (expr is ast.TypeLiteral) {
      _usedBaseFunctions.add('type_literal');
      return _buildStdCall('type_literal', [
        FieldValuePair()
          ..name = 'type'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = expr.type.toSource())),
      ]);
    }

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

      // Implicit constructor call (no `new` keyword, uppercase method name):
      // produce a MessageCreation so the engine can construct instances.
      // `parseString` without type resolution emits `MethodInvocation` even
      // for `new`-less constructor calls like `IoEnvironmentVariables()`.
      if (methodName.isNotEmpty &&
          methodName[0] == methodName[0].toUpperCase()) {
        final fullTypeName = '$_moduleName:$methodName';
        final msg = MessageCreation()
          ..typeName = fullTypeName
          ..fields.addAll(args);
        // Preserve type arguments (e.g. `CancelableCompleter<void>()`).
        if (typeArgSrc != null && typeArgSrc.isNotEmpty) {
          msg.fields.insert(
            0,
            FieldValuePair()
              ..name = '__type_args__'
              ..value = (Expression()
                ..literal = (Literal()..stringValue = typeArgSrc)),
          );
        }
        return Expression()..messageCreation = msg;
      }

      final call = FunctionCall()..function = methodName;
      // Preserve type arguments (e.g. `binarySearchBy<E, E>(...)`).
      if (typeArgSrc != null && typeArgSrc.isNotEmpty) {
        args.insert(
          0,
          FieldValuePair()
            ..name = '__type_args__'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = typeArgSrc)),
        );
      }
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
      if (typeArgSrc != null && typeArgSrc.isNotEmpty) {
        args.insert(
          0,
          FieldValuePair()
            ..name = '__type_args__'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = typeArgSrc)),
        );
      }
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
    }

    // .toString() -> std.to_string
    if (methodName == 'toString' && args.isEmpty && realTarget != null) {
      _usedBaseFunctions.add('to_string');
      return _buildUnaryStdCall('to_string', _encodeExpr(realTarget));
    }

    // .length -> std.length  (only for actual property access, not method calls;
    // MethodInvocation with .length() is a real call – e.g. File.length())
    // This case is unreachable for MethodInvocation; length getters arrive
    // via PropertyAccess / PrefixedIdentifier handling, not here.

    // Null-aware method call: target?.method(args)
    if (isNullAware && realTarget != null) {
      _usedBaseFunctions.add('null_aware_call');
      final naFields = <FieldValuePair>[
        FieldValuePair()
          ..name = 'target'
          ..value = _encodeExpr(realTarget),
        FieldValuePair()
          ..name = 'method'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = methodName)),
      ];
      if (typeArgSrc != null && typeArgSrc.isNotEmpty) {
        naFields.add(
          FieldValuePair()
            ..name = '__type_args__'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = typeArgSrc)),
        );
      }
      naFields.addAll(args);
      return _buildStdCall('null_aware_call', naFields);
    }

    // Generic method call on an object.
    if (realTarget != null) {
      final call = FunctionCall()..function = methodName;
      final methodArgs = <FieldValuePair>[
        FieldValuePair()
          ..name = 'self'
          ..value = _encodeExpr(realTarget),
        ...args,
      ];
      if (typeArgSrc != null && typeArgSrc.isNotEmpty) {
        methodArgs.insert(
          1,
          FieldValuePair()
            ..name = '__type_args__'
            ..value = (Expression()
              ..literal = (Literal()..stringValue = typeArgSrc)),
        );
      }
      call.input = Expression()
        ..messageCreation = (MessageCreation()..fields.addAll(methodArgs));
      return Expression()..call = call;
    }

    final call = FunctionCall()..function = methodName;
    // Preserve type arguments (e.g. `binarySearchBy<E, E>(...)`).
    if (typeArgSrc != null && typeArgSrc.isNotEmpty) {
      args.insert(
        0,
        FieldValuePair()
          ..name = '__type_args__'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = typeArgSrc)),
      );
    }
    _setCallInput(call, args);
    return Expression()..call = call;
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
    // stored as a synthetic `__type_args__` field.
    final typeArgSrc = namedType.typeArguments?.toSource();
    final fullTypeName = ctorName != null
        ? '$ballTypeName.$ctorName'
        : ballTypeName;
    final msg = MessageCreation()
      ..typeName = fullTypeName
      ..fields.addAll(args);
    if (typeArgSrc != null && typeArgSrc.isNotEmpty) {
      msg.fields.insert(
        0,
        FieldValuePair()
          ..name = '__type_args__'
          ..value = (Expression()
            ..literal = (Literal()..stringValue = typeArgSrc)),
      );
    }
    // Preserve const keyword for const constructor calls.
    if (expr.keyword?.lexeme == 'const') {
      msg.fields.insert(
        0,
        FieldValuePair()
          ..name = '__const__'
          ..value = (Expression()..literal = (Literal()..boolValue = true)),
      );
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
    _usedBaseFunctions.add('cascade');
    // Mark sections so null-target nodes (PropertyAccess, IndexExpression,
    // MethodInvocation) emit __cascade_self__ instead of crashing.
    final wasInCascade = _inCascadeSection;
    _inCascadeSection = true;
    final sections = expr.cascadeSections.map(_encodeExpr).toList();
    _inCascadeSection = wasInCascade;
    final fields = <FieldValuePair>[
      FieldValuePair()
        ..name = 'target'
        ..value = _encodeExpr(expr.target),
      FieldValuePair()
        ..name = 'sections'
        ..value = (Expression()
          ..literal = (Literal()
            ..listValue = (ListLiteral()..elements.addAll(sections)))),
    ];
    // Preserve null-awareness: `scopeUser?..id = ...` uses `?..`
    if (expr.cascadeSections.isNotEmpty &&
        expr.target is ast.SimpleIdentifier) {
      // The first cascade section's operator determines if it's null-aware.
    }
    // Use the isNullAware flag from the cascade expression (Dart 3 AST).
    if (expr.isNullAware) {
      fields.add(
        FieldValuePair()
          ..name = 'null_aware'
          ..value = (Expression()..literal = (Literal()..boolValue = true)),
      );
    }
    return _buildStdCall('cascade', fields);
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

  Expression _encodeSetOrMapLiteral(ast.SetOrMapLiteral expr) {
    // Determine if it is a map or a set.
    // Note: isMap on SetOrMapLiteral requires full type resolution and returns
    // false when using parseString (no analysis context). Use heuristics:
    //   1. Two type arguments → always a map  e.g. <String, dynamic>{}
    //   2. Non-empty and first element is MapLiteralEntry → map
    //   3. Otherwise → set
    final hasDoubleTypeArgs = (expr.typeArguments?.arguments.length ?? 0) == 2;
    final hasMapEntry =
        expr.elements.isNotEmpty && expr.elements.first is ast.MapLiteralEntry;
    final isMap = hasDoubleTypeArgs || hasMapEntry;

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
    var positionalIndex = 0;
    for (final field in expr.fields) {
      if (field is ast.NamedExpression) {
        fields.add(
          FieldValuePair()
            ..name = field.name.label.name
            ..value = _encodeExpr(field.expression),
        );
      } else {
        fields.add(
          FieldValuePair()
            ..name = '\$$positionalIndex'
            ..value = _encodeExpr(field),
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
    return Expression()
      ..literal = (Literal()
        ..stringValue = '/* unsupported element: ${element.runtimeType} */');
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
                          ..stringValue = field.name!.name?.lexeme ?? '')),
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

  /// Build a base function call with named fields.
  /// Automatically routes to 'std' or 'dart_std' based on the function name.
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
      if (arg is ast.NamedExpression) {
        result.add(
          FieldValuePair()
            ..name = arg.name.label.name
            ..value = _encodeExpr(arg.expression),
        );
      } else {
        result.add(
          FieldValuePair()
            ..name = 'arg$positionalIndex'
            ..value = _encodeExpr(arg),
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
      if (p is ast.SimpleFormalParameter && p.type != null) {
        pm['type'] = p.type!.toSource();
      } else if (p is ast.DefaultFormalParameter) {
        final inner = p.parameter;
        if (inner is ast.SimpleFormalParameter && inner.type != null) {
          pm['type'] = inner.type!.toSource();
        }
        if (p.defaultValue != null) {
          pm['default'] = p.defaultValue!.toSource();
        }
        if (inner is ast.FieldFormalParameter) {
          pm['is_this'] = true;
          if (inner.type != null) pm['type'] = inner.type!.toSource();
        }
        if (inner is ast.SuperFormalParameter) {
          pm['is_super'] = true;
        }
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
