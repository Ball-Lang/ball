/// Data classes that model the "emit plan" shared with
/// `dart/compiler/tool/ts_emit.mjs` (the Node-side ts-morph driver).
///
/// Keep this file in lockstep with the JSON schema documented at the top
/// of `ts_emit.mjs`. Any addition here must also be handled there.
///
/// All classes are immutable and serialize to plain `Map<String, Object?>`
/// via [toJson]. Bodies (function / method / constructor / accessor
/// bodies, property initializers) are raw TypeScript source strings —
/// the Dart compiler builds those with the existing string-based
/// expression emitter; ts-morph handles only the surrounding
/// declarations and formatting.
library;

import 'dart:convert';

sealed class TsStatement {
  Map<String, Object?> toJson();
}

class TsImport extends TsStatement {
  final String moduleSpecifier;
  final List<String>? namedImports;
  final String? defaultImport;
  final String? namespaceImport;

  TsImport({
    required this.moduleSpecifier,
    this.namedImports,
    this.defaultImport,
    this.namespaceImport,
  });

  @override
  Map<String, Object?> toJson() => {
    'kind': 'Import',
    'moduleSpecifier': moduleSpecifier,
    if (namedImports != null) 'namedImports': namedImports,
    if (defaultImport != null) 'defaultImport': defaultImport,
    if (namespaceImport != null) 'namespaceImport': namespaceImport,
  };
}

class TsParameter {
  final String name;
  final String? type;
  final bool isOptional;
  final bool isRest;
  final bool hasDefault;
  final String? defaultValue;

  TsParameter({
    required this.name,
    this.type,
    this.isOptional = false,
    this.isRest = false,
    this.hasDefault = false,
    this.defaultValue,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    if (type != null) 'type': type,
    if (isOptional) 'isOptional': true,
    if (isRest) 'isRest': true,
    if (hasDefault) 'hasDefault': true,
    if (defaultValue != null) 'defaultValue': defaultValue,
  };
}

class TsTypeParameter {
  final String name;
  final String? constraint;
  final String? defaultType;

  TsTypeParameter({required this.name, this.constraint, this.defaultType});

  Object toJson() {
    if (constraint == null && defaultType == null) return name;
    return {
      'name': name,
      if (constraint != null) 'constraint': constraint,
      if (defaultType != null) 'default': defaultType,
    };
  }
}

class TsFunction extends TsStatement {
  final String name;
  final bool isAsync;
  final bool isExported;
  final bool isGenerator;
  final List<TsTypeParameter> typeParameters;
  final List<TsParameter> parameters;
  final String? returnType;

  /// Raw TS body (statements only — no surrounding braces). May be null
  /// for a declaration without body, though TS functions normally need one.
  final String? body;

  TsFunction({
    required this.name,
    this.isAsync = false,
    this.isExported = false,
    this.isGenerator = false,
    this.typeParameters = const [],
    this.parameters = const [],
    this.returnType,
    this.body,
  });

  @override
  Map<String, Object?> toJson() => {
    'kind': 'Function',
    'name': name,
    if (isAsync) 'isAsync': true,
    if (isExported) 'isExported': true,
    if (isGenerator) 'isGenerator': true,
    if (typeParameters.isNotEmpty)
      'typeParameters': typeParameters.map((t) => t.toJson()).toList(),
    'parameters': parameters.map((p) => p.toJson()).toList(),
    if (returnType != null) 'returnType': returnType,
    if (body != null) 'body': body,
  };
}

class TsProperty {
  final String name;
  final String? type;
  final bool isStatic;
  final bool isReadonly;
  final bool isOptional;
  final String? initializer;
  final String? scope; // 'public' | 'private' | 'protected' | null

  TsProperty({
    required this.name,
    this.type,
    this.isStatic = false,
    this.isReadonly = false,
    this.isOptional = false,
    this.initializer,
    this.scope,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    if (type != null) 'type': type,
    if (isStatic) 'isStatic': true,
    if (isReadonly) 'isReadonly': true,
    if (isOptional) 'isOptional': true,
    if (initializer != null) 'initializer': initializer,
    if (scope != null) 'scope': scope,
  };
}

class TsCtor {
  final List<TsParameter> parameters;
  final String? body;
  final String? scope;

  TsCtor({this.parameters = const [], this.body, this.scope});

  Map<String, Object?> toJson() => {
    'parameters': parameters.map((p) => p.toJson()).toList(),
    if (body != null) 'body': body,
    if (scope != null) 'scope': scope,
  };
}

class TsMethod {
  final String name;
  final bool isAsync;
  final bool isStatic;
  final bool isAbstract;
  final List<TsTypeParameter> typeParameters;
  final List<TsParameter> parameters;
  final String? returnType;
  final String? body;
  final String? scope;

  TsMethod({
    required this.name,
    this.isAsync = false,
    this.isStatic = false,
    this.isAbstract = false,
    this.typeParameters = const [],
    this.parameters = const [],
    this.returnType,
    this.body,
    this.scope,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    if (isAsync) 'isAsync': true,
    if (isStatic) 'isStatic': true,
    if (isAbstract) 'isAbstract': true,
    if (typeParameters.isNotEmpty)
      'typeParameters': typeParameters.map((t) => t.toJson()).toList(),
    'parameters': parameters.map((p) => p.toJson()).toList(),
    if (returnType != null) 'returnType': returnType,
    if (body != null) 'body': body,
    if (scope != null) 'scope': scope,
  };
}

class TsGetter {
  final String name;
  final bool isStatic;
  final String? returnType;
  final String? body;
  final String? scope;

  TsGetter({
    required this.name,
    this.isStatic = false,
    this.returnType,
    this.body,
    this.scope,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    if (isStatic) 'isStatic': true,
    if (returnType != null) 'returnType': returnType,
    if (body != null) 'body': body,
    if (scope != null) 'scope': scope,
  };
}

class TsSetter {
  final String name;
  final bool isStatic;
  final List<TsParameter> parameters;
  final String? body;
  final String? scope;

  TsSetter({
    required this.name,
    this.isStatic = false,
    required this.parameters,
    this.body,
    this.scope,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    if (isStatic) 'isStatic': true,
    'parameters': parameters.map((p) => p.toJson()).toList(),
    if (body != null) 'body': body,
    if (scope != null) 'scope': scope,
  };
}

class TsClass extends TsStatement {
  final String name;
  final bool isExported;
  final bool isAbstract;
  final List<TsTypeParameter> typeParameters;
  final String? extendsClause;
  final List<String> implementsClause;
  final List<TsProperty> properties;
  final List<TsCtor> ctors;
  final List<TsMethod> methods;
  final List<TsGetter> getters;
  final List<TsSetter> setters;

  TsClass({
    required this.name,
    this.isExported = false,
    this.isAbstract = false,
    this.typeParameters = const [],
    this.extendsClause,
    this.implementsClause = const [],
    this.properties = const [],
    this.ctors = const [],
    this.methods = const [],
    this.getters = const [],
    this.setters = const [],
  });

  @override
  Map<String, Object?> toJson() => {
    'kind': 'Class',
    'name': name,
    if (isExported) 'isExported': true,
    if (isAbstract) 'isAbstract': true,
    if (typeParameters.isNotEmpty)
      'typeParameters': typeParameters.map((t) => t.toJson()).toList(),
    if (extendsClause != null) 'extends': extendsClause,
    if (implementsClause.isNotEmpty) 'implements': implementsClause,
    if (properties.isNotEmpty)
      'properties': properties.map((p) => p.toJson()).toList(),
    if (ctors.isNotEmpty) 'ctors': ctors.map((c) => c.toJson()).toList(),
    if (methods.isNotEmpty) 'methods': methods.map((m) => m.toJson()).toList(),
    if (getters.isNotEmpty) 'getters': getters.map((g) => g.toJson()).toList(),
    if (setters.isNotEmpty) 'setters': setters.map((s) => s.toJson()).toList(),
  };
}

class TsEnumMember {
  final String name;
  final Object? value; // String or int or null

  TsEnumMember({required this.name, this.value});

  Map<String, Object?> toJson() => {
    'name': name,
    if (value != null) 'value': value,
  };
}

class TsEnum extends TsStatement {
  final String name;
  final bool isExported;
  final List<TsEnumMember> members;

  TsEnum({
    required this.name,
    this.isExported = false,
    this.members = const [],
  });

  @override
  Map<String, Object?> toJson() => {
    'kind': 'Enum',
    'name': name,
    if (isExported) 'isExported': true,
    'members': members.map((m) => m.toJson()).toList(),
  };
}

class TsTypeAlias extends TsStatement {
  final String name;
  final String type;
  final bool isExported;
  final List<TsTypeParameter> typeParameters;

  TsTypeAlias({
    required this.name,
    required this.type,
    this.isExported = false,
    this.typeParameters = const [],
  });

  @override
  Map<String, Object?> toJson() => {
    'kind': 'TypeAlias',
    'name': name,
    'type': type,
    if (isExported) 'isExported': true,
    if (typeParameters.isNotEmpty)
      'typeParameters': typeParameters.map((t) => t.toJson()).toList(),
  };
}

/// Raw escape hatch: inserts a verbatim TS source block as a top-level
/// statement. Use sparingly — anything that could be modeled structurally
/// should be.
class TsRaw extends TsStatement {
  final String text;

  TsRaw(this.text);

  @override
  Map<String, Object?> toJson() => {'kind': 'Raw', 'text': text};
}

class TsEmitPlan {
  final String path;
  final List<TsStatement> statements;

  TsEmitPlan({required this.path, this.statements = const []});

  Map<String, Object?> toJson() => {
    'path': path,
    'statements': statements.map((s) => s.toJson()).toList(),
  };

  String toJsonString() => jsonEncode(toJson());
}
