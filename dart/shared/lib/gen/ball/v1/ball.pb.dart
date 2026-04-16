// This is a generated file - do not edit.
//
// Generated from ball/v1/ball.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart' as $0;

import '../../google/protobuf/descriptor.pb.dart' as $1;
import 'ball.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'ball.pbenum.dart';

/// A complete ball program containing all modules, types, and functions.
class Program extends $pb.GeneratedMessage {
  factory Program({
    $core.String? name,
    $core.String? version,
    $core.Iterable<Module>? modules,
    $core.String? entryModule,
    $core.String? entryFunction,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (version != null) result.version = version;
    if (modules != null) result.modules.addAll(modules);
    if (entryModule != null) result.entryModule = entryModule;
    if (entryFunction != null) result.entryFunction = entryFunction;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  Program._();

  factory Program.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Program.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Program',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'version')
    ..pPM<Module>(3, _omitFieldNames ? '' : 'modules',
        subBuilder: Module.create)
    ..aOS(4, _omitFieldNames ? '' : 'entryModule')
    ..aOS(5, _omitFieldNames ? '' : 'entryFunction')
    ..aOM<$0.Struct>(6, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create);

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Program clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Program copyWith(void Function(Program) updates) =>
      super.copyWith((message) => updates(message as Program)) as Program;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Program create() => Program._();
  @$core.override
  Program createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Program getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Program>(create);
  static Program? _defaultInstance;

  /// Human-readable program name
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Semantic version string (e.g., "1.0.0")
  @$pb.TagNumber(2)
  $core.String get version => $_getSZ(1);
  @$pb.TagNumber(2)
  set version($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearVersion() => $_clearField(2);

  /// All modules in this program (including base modules like "std")
  @$pb.TagNumber(3)
  $pb.PbList<Module> get modules => $_getList(2);

  /// The module containing the entry point function
  @$pb.TagNumber(4)
  $core.String get entryModule => $_getSZ(3);
  @$pb.TagNumber(4)
  set entryModule($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasEntryModule() => $_has(3);
  @$pb.TagNumber(4)
  void clearEntryModule() => $_clearField(4);

  /// The function to execute as the program's entry point
  @$pb.TagNumber(5)
  $core.String get entryFunction => $_getSZ(4);
  @$pb.TagNumber(5)
  set entryFunction($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasEntryFunction() => $_has(4);
  @$pb.TagNumber(5)
  void clearEntryFunction() => $_clearField(5);

  /// Arbitrary metadata (author, license, etc.) — supports infinite nesting.
  @$pb.TagNumber(6)
  $0.Struct get metadata => $_getN(5);
  @$pb.TagNumber(6)
  set metadata($0.Struct value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasMetadata() => $_has(5);
  @$pb.TagNumber(6)
  void clearMetadata() => $_clearField(6);
  @$pb.TagNumber(6)
  $0.Struct ensureMetadata() => $_ensure(5);
}

/// A module groups related type definitions and functions.
/// Modules can import other modules to use their types and functions.
/// Base modules (like "std") provide platform-specific implementations.
class Module extends $pb.GeneratedMessage {
  factory Module({
    $core.String? name,
    $core.Iterable<$1.DescriptorProto>? types,
    $core.Iterable<FunctionDefinition>? functions,
    $core.Iterable<ModuleImport>? moduleImports,
    $core.String? description,
    $0.Struct? metadata,
    $core.Iterable<$1.EnumDescriptorProto>? enums,
    $core.Iterable<TypeDefinition>? typeDefs,
    $core.Iterable<TypeAlias>? typeAliases,
    $core.Iterable<Constant>? moduleConstants,
    $core.Iterable<ModuleAsset>? assets,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (types != null) result.types.addAll(types);
    if (functions != null) result.functions.addAll(functions);
    if (moduleImports != null) result.moduleImports.addAll(moduleImports);
    if (description != null) result.description = description;
    if (metadata != null) result.metadata = metadata;
    if (enums != null) result.enums.addAll(enums);
    if (typeDefs != null) result.typeDefs.addAll(typeDefs);
    if (typeAliases != null) result.typeAliases.addAll(typeAliases);
    if (moduleConstants != null) result.moduleConstants.addAll(moduleConstants);
    if (assets != null) result.assets.addAll(assets);
    return result;
  }

  Module._();

  factory Module.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Module.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Module',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..pPM<$1.DescriptorProto>(2, _omitFieldNames ? '' : 'types',
        subBuilder: $1.DescriptorProto.create)
    ..pPM<FunctionDefinition>(3, _omitFieldNames ? '' : 'functions',
        subBuilder: FunctionDefinition.create)
    ..pPM<ModuleImport>(4, _omitFieldNames ? '' : 'moduleImports',
        subBuilder: ModuleImport.create)
    ..aOS(5, _omitFieldNames ? '' : 'description')
    ..aOM<$0.Struct>(6, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..pPM<$1.EnumDescriptorProto>(7, _omitFieldNames ? '' : 'enums',
        subBuilder: $1.EnumDescriptorProto.create)
    ..pPM<TypeDefinition>(8, _omitFieldNames ? '' : 'typeDefs',
        subBuilder: TypeDefinition.create)
    ..pPM<TypeAlias>(11, _omitFieldNames ? '' : 'typeAliases',
        subBuilder: TypeAlias.create)
    ..pPM<Constant>(12, _omitFieldNames ? '' : 'moduleConstants',
        subBuilder: Constant.create)
    ..pPM<ModuleAsset>(13, _omitFieldNames ? '' : 'assets',
        subBuilder: ModuleAsset.create);

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Module clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Module copyWith(void Function(Module) updates) =>
      super.copyWith((message) => updates(message as Module)) as Module;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Module create() => Module._();
  @$core.override
  Module createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Module getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Module>(create);
  static Module? _defaultInstance;

  /// Unique module name (e.g., "std", "main", "my_lib")
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Message types defined using protobuf's own descriptor format.
  /// This ensures types are truly language-agnostic — protobuf already
  /// defines how each type maps to every target language's native types
  /// (e.g. int32 → int in Dart, int in Python, int32_t in C++, number in JS).
  /// See: https://protobuf.dev/reference/protobuf/google.protobuf/#DescriptorProto
  @$pb.TagNumber(2)
  $pb.PbList<$1.DescriptorProto> get types => $_getList(1);

  /// Function definitions in this module
  @$pb.TagNumber(3)
  $pb.PbList<FunctionDefinition> get functions => $_getList(2);

  /// Structured module imports with source resolution and integrity verification.
  ///
  /// Each ModuleImport specifies where to find the module (HTTP URL,
  /// local file, inline bytes/JSON, or git repo) and an optional
  /// content hash for integrity verification.
  @$pb.TagNumber(4)
  $pb.PbList<ModuleImport> get moduleImports => $_getList(3);

  /// Human-readable description
  @$pb.TagNumber(5)
  $core.String get description => $_getSZ(4);
  @$pb.TagNumber(5)
  set description($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasDescription() => $_has(4);
  @$pb.TagNumber(5)
  void clearDescription() => $_clearField(5);

  /// Arbitrary metadata — supports infinite nesting.
  @$pb.TagNumber(6)
  $0.Struct get metadata => $_getN(5);
  @$pb.TagNumber(6)
  set metadata($0.Struct value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasMetadata() => $_has(5);
  @$pb.TagNumber(6)
  void clearMetadata() => $_clearField(6);
  @$pb.TagNumber(6)
  $0.Struct ensureMetadata() => $_ensure(5);

  /// Enum types defined using protobuf's own enum descriptor format.
  @$pb.TagNumber(7)
  $pb.PbList<$1.EnumDescriptorProto> get enums => $_getList(6);

  /// First-class type definitions (replaces the _meta_ function hack).
  /// Each TypeDefinition has a name, protobuf descriptor for fields,
  /// generic type parameters, and a metadata bag for cosmetic hints
  /// (kind, superclass, interfaces, mixins, visibility, etc.).
  @$pb.TagNumber(8)
  $pb.PbList<TypeDefinition> get typeDefs => $_getList(7);

  /// Type aliases (e.g., C++ `using`, Rust `type`, TypeScript `type`).
  @$pb.TagNumber(11)
  $pb.PbList<TypeAlias> get typeAliases => $_getList(8);

  /// Module-level constants (e.g., `const pi = 3.14159`).
  @$pb.TagNumber(12)
  $pb.PbList<Constant> get moduleConstants => $_getList(9);

  /// Asset files embedded in this module (images, JSON fixtures, etc.).
  /// Any file can be stored as an asset; the path is relative to the
  /// package root.
  @$pb.TagNumber(13)
  $pb.PbList<ModuleAsset> get assets => $_getList(10);
}

/// An asset file embedded in a ball module.
///
/// Assets can be any file (images, JSON fixtures, templates, etc.) and are
/// stored as raw bytes alongside the module's code.  The path is relative to
/// the package root (e.g. "test/fixtures/users.json", "assets/logo.png").
class ModuleAsset extends $pb.GeneratedMessage {
  factory ModuleAsset({
    $core.String? path,
    $core.List<$core.int>? content,
    $core.String? mediaType,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (path != null) result.path = path;
    if (content != null) result.content = content;
    if (mediaType != null) result.mediaType = mediaType;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  ModuleAsset._();

  factory ModuleAsset.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ModuleAsset.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ModuleAsset',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'content', $pb.PbFieldType.OY)
    ..aOS(3, _omitFieldNames ? '' : 'mediaType')
    ..aOM<$0.Struct>(4, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModuleAsset clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModuleAsset copyWith(void Function(ModuleAsset) updates) =>
      super.copyWith((message) => updates(message as ModuleAsset))
          as ModuleAsset;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ModuleAsset create() => ModuleAsset._();
  @$core.override
  ModuleAsset createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ModuleAsset getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ModuleAsset>(create);
  static ModuleAsset? _defaultInstance;

  /// Relative path of the asset within the package (forward-slash separated).
  /// Example: "test/fixtures/users.json", "web/icons/favicon.ico"
  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  /// Raw file content.
  @$pb.TagNumber(2)
  $core.List<$core.int> get content => $_getN(1);
  @$pb.TagNumber(2)
  set content($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasContent() => $_has(1);
  @$pb.TagNumber(2)
  void clearContent() => $_clearField(2);

  /// MIME type hint (e.g. "application/json", "image/png", "text/plain").
  /// Empty = infer from file extension.
  @$pb.TagNumber(3)
  $core.String get mediaType => $_getSZ(2);
  @$pb.TagNumber(3)
  set mediaType($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMediaType() => $_has(2);
  @$pb.TagNumber(3)
  void clearMediaType() => $_clearField(3);

  /// Arbitrary metadata (e.g. encoding hints, generation source).
  @$pb.TagNumber(4)
  $0.Struct get metadata => $_getN(3);
  @$pb.TagNumber(4)
  set metadata($0.Struct value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasMetadata() => $_has(3);
  @$pb.TagNumber(4)
  void clearMetadata() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Struct ensureMetadata() => $_ensure(3);
}

enum ModuleImport_Source { http, file, inline, git, registry, notSet }

/// Specifies how to resolve and load a module dependency.
class ModuleImport extends $pb.GeneratedMessage {
  factory ModuleImport({
    $core.String? name,
    $core.String? integrity,
    $0.Struct? metadata,
    HttpSource? http,
    FileSource? file,
    InlineSource? inline,
    GitSource? git,
    RegistrySource? registry,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (integrity != null) result.integrity = integrity;
    if (metadata != null) result.metadata = metadata;
    if (http != null) result.http = http;
    if (file != null) result.file = file;
    if (inline != null) result.inline = inline;
    if (git != null) result.git = git;
    if (registry != null) result.registry = registry;
    return result;
  }

  ModuleImport._();

  factory ModuleImport.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ModuleImport.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ModuleImport_Source>
      _ModuleImport_SourceByTag = {
    4: ModuleImport_Source.http,
    5: ModuleImport_Source.file,
    6: ModuleImport_Source.inline,
    7: ModuleImport_Source.git,
    8: ModuleImport_Source.registry,
    0: ModuleImport_Source.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ModuleImport',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..oo(0, [4, 5, 6, 7, 8])
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'integrity')
    ..aOM<$0.Struct>(3, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..aOM<HttpSource>(4, _omitFieldNames ? '' : 'http',
        subBuilder: HttpSource.create)
    ..aOM<FileSource>(5, _omitFieldNames ? '' : 'file',
        subBuilder: FileSource.create)
    ..aOM<InlineSource>(6, _omitFieldNames ? '' : 'inline',
        subBuilder: InlineSource.create)
    ..aOM<GitSource>(7, _omitFieldNames ? '' : 'git',
        subBuilder: GitSource.create)
    ..aOM<RegistrySource>(8, _omitFieldNames ? '' : 'registry',
        subBuilder: RegistrySource.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModuleImport clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ModuleImport copyWith(void Function(ModuleImport) updates) =>
      super.copyWith((message) => updates(message as ModuleImport))
          as ModuleImport;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ModuleImport create() => ModuleImport._();
  @$core.override
  ModuleImport createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ModuleImport getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ModuleImport>(create);
  static ModuleImport? _defaultInstance;

  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  ModuleImport_Source whichSource() =>
      _ModuleImport_SourceByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  void clearSource() => $_clearField($_whichOneof(0));

  /// Local alias used to reference this module in FunctionCall.module.
  /// Freely chosen by the importing module — does not need to match
  /// the imported module's own Module.name.
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Content integrity hash for verification.
  ///
  /// Format: "<algorithm>:<hex-encoded-hash>"
  /// Example: "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  ///
  /// When present, the resolver serializes the resolved Module to
  /// canonical protobuf binary format and compares its SHA-256 hash.
  /// A mismatch causes resolution failure, protecting against
  /// supply-chain attacks and accidental corruption.
  ///
  /// When absent, no integrity check is performed.
  @$pb.TagNumber(2)
  $core.String get integrity => $_getSZ(1);
  @$pb.TagNumber(2)
  set integrity($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasIntegrity() => $_has(1);
  @$pb.TagNumber(2)
  void clearIntegrity() => $_clearField(2);

  /// Arbitrary metadata (e.g., reason for dependency, override notes).
  @$pb.TagNumber(3)
  $0.Struct get metadata => $_getN(2);
  @$pb.TagNumber(3)
  set metadata($0.Struct value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasMetadata() => $_has(2);
  @$pb.TagNumber(3)
  void clearMetadata() => $_clearField(3);
  @$pb.TagNumber(3)
  $0.Struct ensureMetadata() => $_ensure(2);

  /// Download from an HTTP/HTTPS URL.
  @$pb.TagNumber(4)
  HttpSource get http => $_getN(3);
  @$pb.TagNumber(4)
  set http(HttpSource value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasHttp() => $_has(3);
  @$pb.TagNumber(4)
  void clearHttp() => $_clearField(4);
  @$pb.TagNumber(4)
  HttpSource ensureHttp() => $_ensure(3);

  /// Load from a local filesystem path.
  @$pb.TagNumber(5)
  FileSource get file => $_getN(4);
  @$pb.TagNumber(5)
  set file(FileSource value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasFile() => $_has(4);
  @$pb.TagNumber(5)
  void clearFile() => $_clearField(5);
  @$pb.TagNumber(5)
  FileSource ensureFile() => $_ensure(4);

  /// Embedded directly in the import (raw protobuf or JSON).
  @$pb.TagNumber(6)
  InlineSource get inline => $_getN(5);
  @$pb.TagNumber(6)
  set inline(InlineSource value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasInline() => $_has(5);
  @$pb.TagNumber(6)
  void clearInline() => $_clearField(6);
  @$pb.TagNumber(6)
  InlineSource ensureInline() => $_ensure(5);

  /// Resolve from a git repository.
  @$pb.TagNumber(7)
  GitSource get git => $_getN(6);
  @$pb.TagNumber(7)
  set git(GitSource value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasGit() => $_has(6);
  @$pb.TagNumber(7)
  void clearGit() => $_clearField(7);
  @$pb.TagNumber(7)
  GitSource ensureGit() => $_ensure(6);

  /// Resolve from a language-native package registry (pub, npm, nuget, etc.).
  @$pb.TagNumber(8)
  RegistrySource get registry => $_getN(7);
  @$pb.TagNumber(8)
  set registry(RegistrySource value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasRegistry() => $_has(7);
  @$pb.TagNumber(8)
  void clearRegistry() => $_clearField(8);
  @$pb.TagNumber(8)
  RegistrySource ensureRegistry() => $_ensure(7);
}

/// An HTTP/HTTPS source for direct module download.
///
/// The URL must point to a valid serialized ball Module in either
/// protobuf binary or JSON format.
///
/// Example:
///   url: "https://example.com/modules/my_lib/v1.0.0/module.ball.bin"
///   encoding: MODULE_ENCODING_PROTO
class HttpSource extends $pb.GeneratedMessage {
  factory HttpSource({
    $core.String? url,
    ModuleEncoding? encoding,
    $core.Iterable<$core.MapEntry<$core.String, $core.String>>? headers,
  }) {
    final result = create();
    if (url != null) result.url = url;
    if (encoding != null) result.encoding = encoding;
    if (headers != null) result.headers.addEntries(headers);
    return result;
  }

  HttpSource._();

  factory HttpSource.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory HttpSource.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'HttpSource',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'url')
    ..aE<ModuleEncoding>(2, _omitFieldNames ? '' : 'encoding',
        enumValues: ModuleEncoding.values)
    ..m<$core.String, $core.String>(3, _omitFieldNames ? '' : 'headers',
        entryClassName: 'HttpSource.HeadersEntry',
        keyFieldType: $pb.PbFieldType.OS,
        valueFieldType: $pb.PbFieldType.OS,
        packageName: const $pb.PackageName('ball.v1'))
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HttpSource clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  HttpSource copyWith(void Function(HttpSource) updates) =>
      super.copyWith((message) => updates(message as HttpSource)) as HttpSource;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static HttpSource create() => HttpSource._();
  @$core.override
  HttpSource createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static HttpSource getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<HttpSource>(create);
  static HttpSource? _defaultInstance;

  /// Full URL to the module file.
  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => $_clearField(1);

  /// Expected serialization format of the response body.
  /// MODULE_ENCODING_UNSPECIFIED = auto-detect from Content-Type or extension.
  @$pb.TagNumber(2)
  ModuleEncoding get encoding => $_getN(1);
  @$pb.TagNumber(2)
  set encoding(ModuleEncoding value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasEncoding() => $_has(1);
  @$pb.TagNumber(2)
  void clearEncoding() => $_clearField(2);

  /// Optional HTTP headers for authentication or custom routing.
  /// Example: {"Authorization": "Bearer ${TOKEN}"}
  @$pb.TagNumber(3)
  $pb.PbMap<$core.String, $core.String> get headers => $_getMap(2);
}

/// A local filesystem source for development dependencies.
///
/// Paths can be absolute or relative to the importing module's location.
/// This source type is intended for local development — production
/// programs should use registry or HTTP sources.
///
/// Example:
///   path: "../my_lib/module.ball.json"
///   encoding: MODULE_ENCODING_JSON
class FileSource extends $pb.GeneratedMessage {
  factory FileSource({
    $core.String? path,
    ModuleEncoding? encoding,
  }) {
    final result = create();
    if (path != null) result.path = path;
    if (encoding != null) result.encoding = encoding;
    return result;
  }

  FileSource._();

  factory FileSource.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FileSource.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FileSource',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..aE<ModuleEncoding>(2, _omitFieldNames ? '' : 'encoding',
        enumValues: ModuleEncoding.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileSource clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileSource copyWith(void Function(FileSource) updates) =>
      super.copyWith((message) => updates(message as FileSource)) as FileSource;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FileSource create() => FileSource._();
  @$core.override
  FileSource createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FileSource getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FileSource>(create);
  static FileSource? _defaultInstance;

  /// Path to the module file.
  /// Absolute or relative to the importing program/module location.
  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  /// Expected serialization format.
  /// MODULE_ENCODING_UNSPECIFIED = auto-detect from file extension or first few bytes of the file.
  @$pb.TagNumber(2)
  ModuleEncoding get encoding => $_getN(1);
  @$pb.TagNumber(2)
  set encoding(ModuleEncoding value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasEncoding() => $_has(1);
  @$pb.TagNumber(2)
  void clearEncoding() => $_clearField(2);
}

enum InlineSource_Content { protoBytes, json, notSet }

/// An inline/embedded module source.
///
/// The entire module is embedded directly in the import, either as
/// raw protobuf binary bytes or as a JSON string. Useful for:
///   - Self-contained programs (single-file distribution)
///   - Code generation pipelines (embed generated modules)
///   - Testing (inline test fixtures)
class InlineSource extends $pb.GeneratedMessage {
  factory InlineSource({
    $core.List<$core.int>? protoBytes,
    $core.String? json,
  }) {
    final result = create();
    if (protoBytes != null) result.protoBytes = protoBytes;
    if (json != null) result.json = json;
    return result;
  }

  InlineSource._();

  factory InlineSource.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory InlineSource.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, InlineSource_Content>
      _InlineSource_ContentByTag = {
    1: InlineSource_Content.protoBytes,
    2: InlineSource_Content.json,
    0: InlineSource_Content.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InlineSource',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'protoBytes', $pb.PbFieldType.OY)
    ..aOS(2, _omitFieldNames ? '' : 'json')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InlineSource clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InlineSource copyWith(void Function(InlineSource) updates) =>
      super.copyWith((message) => updates(message as InlineSource))
          as InlineSource;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static InlineSource create() => InlineSource._();
  @$core.override
  InlineSource createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static InlineSource getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InlineSource>(create);
  static InlineSource? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  InlineSource_Content whichContent() =>
      _InlineSource_ContentByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearContent() => $_clearField($_whichOneof(0));

  /// Raw protobuf binary-encoded Module.
  @$pb.TagNumber(1)
  $core.List<$core.int> get protoBytes => $_getN(0);
  @$pb.TagNumber(1)
  set protoBytes($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasProtoBytes() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtoBytes() => $_clearField(1);

  /// JSON-encoded Module string (protobuf JSON mapping).
  @$pb.TagNumber(2)
  $core.String get json => $_getSZ(1);
  @$pb.TagNumber(2)
  set json($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasJson() => $_has(1);
  @$pb.TagNumber(2)
  void clearJson() => $_clearField(2);
}

/// A git repository source for importing modules from version control.
///
/// The resolver clones (or shallow-fetches) the repository at the
/// specified ref and reads the module file at the given path.
///
/// Example:
///   url: "https://github.com/ball-lang/std-extended.git"
///   ref: "v1.2.0"
///   path: "modules/std_extended/module.ball.json"
class GitSource extends $pb.GeneratedMessage {
  factory GitSource({
    $core.String? url,
    $core.String? ref,
    $core.String? path,
    ModuleEncoding? encoding,
  }) {
    final result = create();
    if (url != null) result.url = url;
    if (ref != null) result.ref = ref;
    if (path != null) result.path = path;
    if (encoding != null) result.encoding = encoding;
    return result;
  }

  GitSource._();

  factory GitSource.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory GitSource.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GitSource',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'url')
    ..aOS(2, _omitFieldNames ? '' : 'ref')
    ..aOS(3, _omitFieldNames ? '' : 'path')
    ..aE<ModuleEncoding>(4, _omitFieldNames ? '' : 'encoding',
        enumValues: ModuleEncoding.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GitSource clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GitSource copyWith(void Function(GitSource) updates) =>
      super.copyWith((message) => updates(message as GitSource)) as GitSource;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static GitSource create() => GitSource._();
  @$core.override
  GitSource createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static GitSource getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<GitSource>(create);
  static GitSource? _defaultInstance;

  /// Git repository URL (HTTPS or SSH).
  /// Example: "https://github.com/ball-lang/std.git"
  ///          "git@github.com:ball-lang/std.git"
  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => $_clearField(1);

  /// Git ref to resolve: branch name, tag, or full commit SHA.
  /// Tags are preferred for versioned releases.
  /// Example: "v1.2.0", "main", "abc123def456..."
  @$pb.TagNumber(2)
  $core.String get ref => $_getSZ(1);
  @$pb.TagNumber(2)
  set ref($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasRef() => $_has(1);
  @$pb.TagNumber(2)
  void clearRef() => $_clearField(2);

  /// Path within the repository to the module file.
  /// Example: "src/module.ball.json"
  @$pb.TagNumber(3)
  $core.String get path => $_getSZ(2);
  @$pb.TagNumber(3)
  set path($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPath() => $_has(2);
  @$pb.TagNumber(3)
  void clearPath() => $_clearField(3);

  /// Expected serialization format of the file.
  /// MODULE_ENCODING_UNSPECIFIED = auto-detect from file extension.
  @$pb.TagNumber(4)
  ModuleEncoding get encoding => $_getN(3);
  @$pb.TagNumber(4)
  set encoding(ModuleEncoding value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasEncoding() => $_has(3);
  @$pb.TagNumber(4)
  void clearEncoding() => $_clearField(4);
}

/// A language-native package registry source.
///
/// Ball modules can be published inside native packages on any supported
/// registry. The resolver fetches the package archive, extracts the Ball
/// module file at `module_path`, and inlines it into the program.
///
/// Example:
///   registry: REGISTRY_PUB
///   package: "ball_std_extended"
///   version: "^1.0.0"
///   module_path: "lib/module.ball.bin"
class RegistrySource extends $pb.GeneratedMessage {
  factory RegistrySource({
    Registry? registry,
    $core.String? package,
    $core.String? version,
    $core.String? modulePath,
    ModuleEncoding? encoding,
    $core.String? registryUrl,
  }) {
    final result = create();
    if (registry != null) result.registry = registry;
    if (package != null) result.package = package;
    if (version != null) result.version = version;
    if (modulePath != null) result.modulePath = modulePath;
    if (encoding != null) result.encoding = encoding;
    if (registryUrl != null) result.registryUrl = registryUrl;
    return result;
  }

  RegistrySource._();

  factory RegistrySource.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RegistrySource.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RegistrySource',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aE<Registry>(1, _omitFieldNames ? '' : 'registry',
        enumValues: Registry.values)
    ..aOS(2, _omitFieldNames ? '' : 'package')
    ..aOS(3, _omitFieldNames ? '' : 'version')
    ..aOS(4, _omitFieldNames ? '' : 'modulePath')
    ..aE<ModuleEncoding>(5, _omitFieldNames ? '' : 'encoding',
        enumValues: ModuleEncoding.values)
    ..aOS(6, _omitFieldNames ? '' : 'registryUrl')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegistrySource clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RegistrySource copyWith(void Function(RegistrySource) updates) =>
      super.copyWith((message) => updates(message as RegistrySource))
          as RegistrySource;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RegistrySource create() => RegistrySource._();
  @$core.override
  RegistrySource createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RegistrySource getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RegistrySource>(create);
  static RegistrySource? _defaultInstance;

  /// Which registry to resolve from.
  @$pb.TagNumber(1)
  Registry get registry => $_getN(0);
  @$pb.TagNumber(1)
  set registry(Registry value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasRegistry() => $_has(0);
  @$pb.TagNumber(1)
  void clearRegistry() => $_clearField(1);

  /// Package name as it appears on the registry.
  /// Examples: "ball_math_utils" (pub), "@ball/my-module" (npm),
  ///           "Ball.MyModule" (nuget), "dev.ball:my-module" (maven).
  @$pb.TagNumber(2)
  $core.String get package => $_getSZ(1);
  @$pb.TagNumber(2)
  set package($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPackage() => $_has(1);
  @$pb.TagNumber(2)
  void clearPackage() => $_clearField(2);

  /// Semver version constraint.
  /// Examples: "1.0.0", "^1.0.0", ">=1.0.0 <2.0.0"
  /// Empty = latest stable.
  @$pb.TagNumber(3)
  $core.String get version => $_getSZ(2);
  @$pb.TagNumber(3)
  set version($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasVersion() => $_has(2);
  @$pb.TagNumber(3)
  void clearVersion() => $_clearField(3);

  /// Path to the .ball.bin or .ball.json file inside the package archive.
  /// If empty, the resolver uses the registry-specific default path convention
  /// (e.g. "lib/module.ball.bin" for pub, "package/module.ball.bin" for npm).
  @$pb.TagNumber(4)
  $core.String get modulePath => $_getSZ(3);
  @$pb.TagNumber(4)
  set modulePath($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasModulePath() => $_has(3);
  @$pb.TagNumber(4)
  void clearModulePath() => $_clearField(4);

  /// Expected serialization format of the module file.
  @$pb.TagNumber(5)
  ModuleEncoding get encoding => $_getN(4);
  @$pb.TagNumber(5)
  set encoding(ModuleEncoding value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasEncoding() => $_has(4);
  @$pb.TagNumber(5)
  void clearEncoding() => $_clearField(5);

  /// Custom registry URL (overrides the default for the registry type).
  /// Use for private or self-hosted registries.
  /// Example: "https://pub.my-company.com"
  @$pb.TagNumber(6)
  $core.String get registryUrl => $_getSZ(5);
  @$pb.TagNumber(6)
  set registryUrl($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasRegistryUrl() => $_has(5);
  @$pb.TagNumber(6)
  void clearRegistryUrl() => $_clearField(6);
}

/// A type parameter placeholder for generic types (e.g. T, K, V).
/// Bounds, variance, and other constraints are cosmetic hints in metadata.
class TypeParameter extends $pb.GeneratedMessage {
  factory TypeParameter({
    $core.String? name,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  TypeParameter._();

  factory TypeParameter.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TypeParameter.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TypeParameter',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOM<$0.Struct>(2, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypeParameter clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypeParameter copyWith(void Function(TypeParameter) updates) =>
      super.copyWith((message) => updates(message as TypeParameter))
          as TypeParameter;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TypeParameter create() => TypeParameter._();
  @$core.override
  TypeParameter createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TypeParameter getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TypeParameter>(create);
  static TypeParameter? _defaultInstance;

  /// Type parameter name (e.g. "T", "K", "V")
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Cosmetic hints: bounds ("extends Comparable"), variance, covariance, etc.
  @$pb.TagNumber(2)
  $0.Struct get metadata => $_getN(1);
  @$pb.TagNumber(2)
  set metadata($0.Struct value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasMetadata() => $_has(1);
  @$pb.TagNumber(2)
  void clearMetadata() => $_clearField(2);
  @$pb.TagNumber(2)
  $0.Struct ensureMetadata() => $_ensure(1);
}

/// Defines a named type, mirroring the structure of FunctionDefinition.
///
/// TypeDefinition replaces the `_meta_Foo` function convention with a
/// proper schema-level construct. All cosmetic hints (kind, superclass,
/// interfaces, mixins, visibility, annotations, etc.) go in metadata.
class TypeDefinition extends $pb.GeneratedMessage {
  factory TypeDefinition({
    $core.String? name,
    $1.DescriptorProto? descriptor,
    $core.Iterable<TypeParameter>? typeParams,
    $core.String? description,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (descriptor != null) result.descriptor = descriptor;
    if (typeParams != null) result.typeParams.addAll(typeParams);
    if (description != null) result.description = description;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  TypeDefinition._();

  factory TypeDefinition.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TypeDefinition.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TypeDefinition',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOM<$1.DescriptorProto>(2, _omitFieldNames ? '' : 'descriptor',
        subBuilder: $1.DescriptorProto.create)
    ..pPM<TypeParameter>(3, _omitFieldNames ? '' : 'typeParams',
        subBuilder: TypeParameter.create)
    ..aOS(4, _omitFieldNames ? '' : 'description')
    ..aOM<$0.Struct>(5, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create);

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypeDefinition clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypeDefinition copyWith(void Function(TypeDefinition) updates) =>
      super.copyWith((message) => updates(message as TypeDefinition))
          as TypeDefinition;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TypeDefinition create() => TypeDefinition._();
  @$core.override
  TypeDefinition createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TypeDefinition getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TypeDefinition>(create);
  static TypeDefinition? _defaultInstance;

  /// Type name (unique within its module)
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Field definitions using protobuf's own descriptor format
  @$pb.TagNumber(2)
  $1.DescriptorProto get descriptor => $_getN(1);
  @$pb.TagNumber(2)
  set descriptor($1.DescriptorProto value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasDescriptor() => $_has(1);
  @$pb.TagNumber(2)
  void clearDescriptor() => $_clearField(2);
  @$pb.TagNumber(2)
  $1.DescriptorProto ensureDescriptor() => $_ensure(1);

  /// Generic type parameter names (e.g. T, K, V)
  @$pb.TagNumber(3)
  $pb.PbList<TypeParameter> get typeParams => $_getList(2);

  /// Human-readable description
  @$pb.TagNumber(4)
  $core.String get description => $_getSZ(3);
  @$pb.TagNumber(4)
  set description($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasDescription() => $_has(3);
  @$pb.TagNumber(4)
  void clearDescription() => $_clearField(4);

  /// All cosmetic hints: kind ("class"|"struct"|"trait"|"interface"|...),
  /// superclass, interfaces, mixins, visibility, is_abstract, is_sealed,
  /// is_final, annotations, fields metadata, etc.
  @$pb.TagNumber(5)
  $0.Struct get metadata => $_getN(4);
  @$pb.TagNumber(5)
  set metadata($0.Struct value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasMetadata() => $_has(4);
  @$pb.TagNumber(5)
  void clearMetadata() => $_clearField(5);
  @$pb.TagNumber(5)
  $0.Struct ensureMetadata() => $_ensure(4);
}

/// A type alias (e.g., C++ `using`, Rust `type`, TypeScript `type`, Dart `typedef`).
class TypeAlias extends $pb.GeneratedMessage {
  factory TypeAlias({
    $core.String? name,
    $core.String? targetType,
    $core.Iterable<TypeParameter>? typeParams,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (targetType != null) result.targetType = targetType;
    if (typeParams != null) result.typeParams.addAll(typeParams);
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  TypeAlias._();

  factory TypeAlias.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TypeAlias.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TypeAlias',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'targetType')
    ..pPM<TypeParameter>(3, _omitFieldNames ? '' : 'typeParams',
        subBuilder: TypeParameter.create)
    ..aOM<$0.Struct>(4, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypeAlias clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypeAlias copyWith(void Function(TypeAlias) updates) =>
      super.copyWith((message) => updates(message as TypeAlias)) as TypeAlias;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TypeAlias create() => TypeAlias._();
  @$core.override
  TypeAlias createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TypeAlias getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<TypeAlias>(create);
  static TypeAlias? _defaultInstance;

  /// Alias name
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// The aliased type name
  @$pb.TagNumber(2)
  $core.String get targetType => $_getSZ(1);
  @$pb.TagNumber(2)
  set targetType($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTargetType() => $_has(1);
  @$pb.TagNumber(2)
  void clearTargetType() => $_clearField(2);

  /// Generic type parameters
  @$pb.TagNumber(3)
  $pb.PbList<TypeParameter> get typeParams => $_getList(2);

  /// Cosmetic hints: visibility, language-specific keywords
  @$pb.TagNumber(4)
  $0.Struct get metadata => $_getN(3);
  @$pb.TagNumber(4)
  set metadata($0.Struct value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasMetadata() => $_has(3);
  @$pb.TagNumber(4)
  void clearMetadata() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Struct ensureMetadata() => $_ensure(3);
}

/// A module-level constant value.
class Constant extends $pb.GeneratedMessage {
  factory Constant({
    $core.String? name,
    $core.String? type,
    Expression? value,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (type != null) result.type = type;
    if (value != null) result.value = value;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  Constant._();

  factory Constant.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Constant.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Constant',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'type')
    ..aOM<Expression>(3, _omitFieldNames ? '' : 'value',
        subBuilder: Expression.create)
    ..aOM<$0.Struct>(4, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Constant clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Constant copyWith(void Function(Constant) updates) =>
      super.copyWith((message) => updates(message as Constant)) as Constant;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Constant create() => Constant._();
  @$core.override
  Constant createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Constant getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Constant>(create);
  static Constant? _defaultInstance;

  /// Constant name
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Type name (empty = infer from value)
  @$pb.TagNumber(2)
  $core.String get type => $_getSZ(1);
  @$pb.TagNumber(2)
  set type($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasType() => $_has(1);
  @$pb.TagNumber(2)
  void clearType() => $_clearField(2);

  /// Constant value expression
  @$pb.TagNumber(3)
  Expression get value => $_getN(2);
  @$pb.TagNumber(3)
  set value(Expression value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasValue() => $_has(2);
  @$pb.TagNumber(3)
  void clearValue() => $_clearField(3);
  @$pb.TagNumber(3)
  Expression ensureValue() => $_ensure(2);

  /// Cosmetic hints: visibility, annotations
  @$pb.TagNumber(4)
  $0.Struct get metadata => $_getN(3);
  @$pb.TagNumber(4)
  set metadata($0.Struct value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasMetadata() => $_has(3);
  @$pb.TagNumber(4)
  void clearMetadata() => $_clearField(4);
  @$pb.TagNumber(4)
  $0.Struct ensureMetadata() => $_ensure(3);
}

/// Defines a function with a single input type and single output type,
/// following the gRPC pattern. Base functions have no body — their
/// implementation is provided by each target language's compiler.
class FunctionDefinition extends $pb.GeneratedMessage {
  factory FunctionDefinition({
    $core.String? name,
    $core.String? inputType,
    $core.String? outputType,
    Expression? body,
    $core.String? description,
    $core.bool? isBase,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (inputType != null) result.inputType = inputType;
    if (outputType != null) result.outputType = outputType;
    if (body != null) result.body = body;
    if (description != null) result.description = description;
    if (isBase != null) result.isBase = isBase;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  FunctionDefinition._();

  factory FunctionDefinition.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FunctionDefinition.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FunctionDefinition',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'inputType')
    ..aOS(3, _omitFieldNames ? '' : 'outputType')
    ..aOM<Expression>(4, _omitFieldNames ? '' : 'body',
        subBuilder: Expression.create)
    ..aOS(5, _omitFieldNames ? '' : 'description')
    ..aOB(6, _omitFieldNames ? '' : 'isBase')
    ..aOM<$0.Struct>(7, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionDefinition clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionDefinition copyWith(void Function(FunctionDefinition) updates) =>
      super.copyWith((message) => updates(message as FunctionDefinition))
          as FunctionDefinition;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FunctionDefinition create() => FunctionDefinition._();
  @$core.override
  FunctionDefinition createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FunctionDefinition getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FunctionDefinition>(create);
  static FunctionDefinition? _defaultInstance;

  /// Function name (must be unique within its module)
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Input type name (empty string = no input / void)
  @$pb.TagNumber(2)
  $core.String get inputType => $_getSZ(1);
  @$pb.TagNumber(2)
  set inputType($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasInputType() => $_has(1);
  @$pb.TagNumber(2)
  void clearInputType() => $_clearField(2);

  /// Output type name (empty string = no output / void)
  @$pb.TagNumber(3)
  $core.String get outputType => $_getSZ(2);
  @$pb.TagNumber(3)
  set outputType($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasOutputType() => $_has(2);
  @$pb.TagNumber(3)
  void clearOutputType() => $_clearField(3);

  /// Function body expression (absent for base functions)
  @$pb.TagNumber(4)
  Expression get body => $_getN(3);
  @$pb.TagNumber(4)
  set body(Expression value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasBody() => $_has(3);
  @$pb.TagNumber(4)
  void clearBody() => $_clearField(4);
  @$pb.TagNumber(4)
  Expression ensureBody() => $_ensure(3);

  /// Human-readable description
  @$pb.TagNumber(5)
  $core.String get description => $_getSZ(4);
  @$pb.TagNumber(5)
  set description($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasDescription() => $_has(4);
  @$pb.TagNumber(5)
  void clearDescription() => $_clearField(5);

  /// If true, this function's implementation is provided by the
  /// target platform compiler, not by a ball expression body.
  @$pb.TagNumber(6)
  $core.bool get isBase => $_getBF(5);
  @$pb.TagNumber(6)
  set isBase($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasIsBase() => $_has(5);
  @$pb.TagNumber(6)
  void clearIsBase() => $_clearField(6);

  /// Arbitrary metadata — supports infinite nesting.
  @$pb.TagNumber(7)
  $0.Struct get metadata => $_getN(6);
  @$pb.TagNumber(7)
  set metadata($0.Struct value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasMetadata() => $_has(6);
  @$pb.TagNumber(7)
  void clearMetadata() => $_clearField(7);
  @$pb.TagNumber(7)
  $0.Struct ensureMetadata() => $_ensure(6);
}

enum Expression_Expr {
  call,
  literal,
  reference,
  fieldAccess,
  messageCreation,
  block,
  lambda,
  notSet
}

/// An expression is the fundamental unit of computation in ball.
/// Every computation is represented as an expression tree.
class Expression extends $pb.GeneratedMessage {
  factory Expression({
    FunctionCall? call,
    Literal? literal,
    Reference? reference,
    FieldAccess? fieldAccess,
    MessageCreation? messageCreation,
    Block? block,
    FunctionDefinition? lambda,
  }) {
    final result = create();
    if (call != null) result.call = call;
    if (literal != null) result.literal = literal;
    if (reference != null) result.reference = reference;
    if (fieldAccess != null) result.fieldAccess = fieldAccess;
    if (messageCreation != null) result.messageCreation = messageCreation;
    if (block != null) result.block = block;
    if (lambda != null) result.lambda = lambda;
    return result;
  }

  Expression._();

  factory Expression.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Expression.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, Expression_Expr> _Expression_ExprByTag = {
    1: Expression_Expr.call,
    2: Expression_Expr.literal,
    3: Expression_Expr.reference,
    4: Expression_Expr.fieldAccess,
    5: Expression_Expr.messageCreation,
    6: Expression_Expr.block,
    7: Expression_Expr.lambda,
    0: Expression_Expr.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Expression',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4, 5, 6, 7])
    ..aOM<FunctionCall>(1, _omitFieldNames ? '' : 'call',
        subBuilder: FunctionCall.create)
    ..aOM<Literal>(2, _omitFieldNames ? '' : 'literal',
        subBuilder: Literal.create)
    ..aOM<Reference>(3, _omitFieldNames ? '' : 'reference',
        subBuilder: Reference.create)
    ..aOM<FieldAccess>(4, _omitFieldNames ? '' : 'fieldAccess',
        subBuilder: FieldAccess.create)
    ..aOM<MessageCreation>(5, _omitFieldNames ? '' : 'messageCreation',
        subBuilder: MessageCreation.create)
    ..aOM<Block>(6, _omitFieldNames ? '' : 'block', subBuilder: Block.create)
    ..aOM<FunctionDefinition>(7, _omitFieldNames ? '' : 'lambda',
        subBuilder: FunctionDefinition.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Expression clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Expression copyWith(void Function(Expression) updates) =>
      super.copyWith((message) => updates(message as Expression)) as Expression;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Expression create() => Expression._();
  @$core.override
  Expression createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Expression getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Expression>(create);
  static Expression? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  Expression_Expr whichExpr() => _Expression_ExprByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  void clearExpr() => $_clearField($_whichOneof(0));

  /// Call a function with an input expression
  @$pb.TagNumber(1)
  FunctionCall get call => $_getN(0);
  @$pb.TagNumber(1)
  set call(FunctionCall value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasCall() => $_has(0);
  @$pb.TagNumber(1)
  void clearCall() => $_clearField(1);
  @$pb.TagNumber(1)
  FunctionCall ensureCall() => $_ensure(0);

  /// A literal value (int, double, string, bool, list)
  @$pb.TagNumber(2)
  Literal get literal => $_getN(1);
  @$pb.TagNumber(2)
  set literal(Literal value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasLiteral() => $_has(1);
  @$pb.TagNumber(2)
  void clearLiteral() => $_clearField(2);
  @$pb.TagNumber(2)
  Literal ensureLiteral() => $_ensure(1);

  /// A reference to a variable by name
  @$pb.TagNumber(3)
  Reference get reference => $_getN(2);
  @$pb.TagNumber(3)
  set reference(Reference value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasReference() => $_has(2);
  @$pb.TagNumber(3)
  void clearReference() => $_clearField(3);
  @$pb.TagNumber(3)
  Reference ensureReference() => $_ensure(2);

  /// Access a field of a message expression
  @$pb.TagNumber(4)
  FieldAccess get fieldAccess => $_getN(3);
  @$pb.TagNumber(4)
  set fieldAccess(FieldAccess value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasFieldAccess() => $_has(3);
  @$pb.TagNumber(4)
  void clearFieldAccess() => $_clearField(4);
  @$pb.TagNumber(4)
  FieldAccess ensureFieldAccess() => $_ensure(3);

  /// Construct a new message instance
  @$pb.TagNumber(5)
  MessageCreation get messageCreation => $_getN(4);
  @$pb.TagNumber(5)
  set messageCreation(MessageCreation value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasMessageCreation() => $_has(4);
  @$pb.TagNumber(5)
  void clearMessageCreation() => $_clearField(5);
  @$pb.TagNumber(5)
  MessageCreation ensureMessageCreation() => $_ensure(4);

  /// A block of statements with a result expression
  @$pb.TagNumber(6)
  Block get block => $_getN(5);
  @$pb.TagNumber(6)
  set block(Block value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasBlock() => $_has(5);
  @$pb.TagNumber(6)
  void clearBlock() => $_clearField(6);
  @$pb.TagNumber(6)
  Block ensureBlock() => $_ensure(5);

  /// An anonymous function / closure (name is empty).
  /// Cross-language: JS arrow functions, Python lambdas, Kotlin lambdas,
  /// Swift closures, C# delegates/lambdas, Rust closures, etc.
  /// A lambda is just a FunctionDefinition with name = "".
  @$pb.TagNumber(7)
  FunctionDefinition get lambda => $_getN(6);
  @$pb.TagNumber(7)
  set lambda(FunctionDefinition value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasLambda() => $_has(6);
  @$pb.TagNumber(7)
  void clearLambda() => $_clearField(7);
  @$pb.TagNumber(7)
  FunctionDefinition ensureLambda() => $_ensure(6);
}

/// Calls a function with a single input expression.
/// The input expression must evaluate to the function's declared input type.
class FunctionCall extends $pb.GeneratedMessage {
  factory FunctionCall({
    $core.String? module,
    $core.String? function,
    Expression? input,
  }) {
    final result = create();
    if (module != null) result.module = module;
    if (function != null) result.function = function;
    if (input != null) result.input = input;
    return result;
  }

  FunctionCall._();

  factory FunctionCall.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FunctionCall.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FunctionCall',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'module')
    ..aOS(2, _omitFieldNames ? '' : 'function')
    ..aOM<Expression>(3, _omitFieldNames ? '' : 'input',
        subBuilder: Expression.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionCall clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionCall copyWith(void Function(FunctionCall) updates) =>
      super.copyWith((message) => updates(message as FunctionCall))
          as FunctionCall;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FunctionCall create() => FunctionCall._();
  @$core.override
  FunctionCall createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FunctionCall getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FunctionCall>(create);
  static FunctionCall? _defaultInstance;

  /// Module name (empty string = current module)
  @$pb.TagNumber(1)
  $core.String get module => $_getSZ(0);
  @$pb.TagNumber(1)
  set module($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasModule() => $_has(0);
  @$pb.TagNumber(1)
  void clearModule() => $_clearField(1);

  /// Function name to call
  @$pb.TagNumber(2)
  $core.String get function => $_getSZ(1);
  @$pb.TagNumber(2)
  set function($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFunction() => $_has(1);
  @$pb.TagNumber(2)
  void clearFunction() => $_clearField(2);

  /// Input expression (evaluates to the function's input type)
  @$pb.TagNumber(3)
  Expression get input => $_getN(2);
  @$pb.TagNumber(3)
  set input(Expression value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasInput() => $_has(2);
  @$pb.TagNumber(3)
  void clearInput() => $_clearField(3);
  @$pb.TagNumber(3)
  Expression ensureInput() => $_ensure(2);
}

enum Literal_Value {
  intValue,
  doubleValue,
  stringValue,
  boolValue,
  bytesValue,
  listValue,
  notSet
}

/// A literal value. Uses oneof for type-safe value representation.
class Literal extends $pb.GeneratedMessage {
  factory Literal({
    $fixnum.Int64? intValue,
    $core.double? doubleValue,
    $core.String? stringValue,
    $core.bool? boolValue,
    $core.List<$core.int>? bytesValue,
    ListLiteral? listValue,
  }) {
    final result = create();
    if (intValue != null) result.intValue = intValue;
    if (doubleValue != null) result.doubleValue = doubleValue;
    if (stringValue != null) result.stringValue = stringValue;
    if (boolValue != null) result.boolValue = boolValue;
    if (bytesValue != null) result.bytesValue = bytesValue;
    if (listValue != null) result.listValue = listValue;
    return result;
  }

  Literal._();

  factory Literal.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Literal.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, Literal_Value> _Literal_ValueByTag = {
    1: Literal_Value.intValue,
    2: Literal_Value.doubleValue,
    3: Literal_Value.stringValue,
    4: Literal_Value.boolValue,
    5: Literal_Value.bytesValue,
    6: Literal_Value.listValue,
    0: Literal_Value.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Literal',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..oo(0, [1, 2, 3, 4, 5, 6])
    ..aInt64(1, _omitFieldNames ? '' : 'intValue')
    ..aD(2, _omitFieldNames ? '' : 'doubleValue')
    ..aOS(3, _omitFieldNames ? '' : 'stringValue')
    ..aOB(4, _omitFieldNames ? '' : 'boolValue')
    ..a<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'bytesValue', $pb.PbFieldType.OY)
    ..aOM<ListLiteral>(6, _omitFieldNames ? '' : 'listValue',
        subBuilder: ListLiteral.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Literal clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Literal copyWith(void Function(Literal) updates) =>
      super.copyWith((message) => updates(message as Literal)) as Literal;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Literal create() => Literal._();
  @$core.override
  Literal createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Literal getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Literal>(create);
  static Literal? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  Literal_Value whichValue() => _Literal_ValueByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  void clearValue() => $_clearField($_whichOneof(0));

  /// Integer literal
  @$pb.TagNumber(1)
  $fixnum.Int64 get intValue => $_getI64(0);
  @$pb.TagNumber(1)
  set intValue($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIntValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearIntValue() => $_clearField(1);

  /// Floating-point literal
  @$pb.TagNumber(2)
  $core.double get doubleValue => $_getN(1);
  @$pb.TagNumber(2)
  set doubleValue($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDoubleValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearDoubleValue() => $_clearField(2);

  /// String literal
  @$pb.TagNumber(3)
  $core.String get stringValue => $_getSZ(2);
  @$pb.TagNumber(3)
  set stringValue($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasStringValue() => $_has(2);
  @$pb.TagNumber(3)
  void clearStringValue() => $_clearField(3);

  /// Boolean literal
  @$pb.TagNumber(4)
  $core.bool get boolValue => $_getBF(3);
  @$pb.TagNumber(4)
  set boolValue($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasBoolValue() => $_has(3);
  @$pb.TagNumber(4)
  void clearBoolValue() => $_clearField(4);

  /// Raw bytes literal
  @$pb.TagNumber(5)
  $core.List<$core.int> get bytesValue => $_getN(4);
  @$pb.TagNumber(5)
  set bytesValue($core.List<$core.int> value) => $_setBytes(4, value);
  @$pb.TagNumber(5)
  $core.bool hasBytesValue() => $_has(4);
  @$pb.TagNumber(5)
  void clearBytesValue() => $_clearField(5);

  /// List literal with element expressions
  @$pb.TagNumber(6)
  ListLiteral get listValue => $_getN(5);
  @$pb.TagNumber(6)
  set listValue(ListLiteral value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasListValue() => $_has(5);
  @$pb.TagNumber(6)
  void clearListValue() => $_clearField(6);
  @$pb.TagNumber(6)
  ListLiteral ensureListValue() => $_ensure(5);
}

/// A list of expressions forming a list literal.
class ListLiteral extends $pb.GeneratedMessage {
  factory ListLiteral({
    $core.Iterable<Expression>? elements,
  }) {
    final result = create();
    if (elements != null) result.elements.addAll(elements);
    return result;
  }

  ListLiteral._();

  factory ListLiteral.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ListLiteral.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ListLiteral',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..pPM<Expression>(1, _omitFieldNames ? '' : 'elements',
        subBuilder: Expression.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListLiteral clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ListLiteral copyWith(void Function(ListLiteral) updates) =>
      super.copyWith((message) => updates(message as ListLiteral))
          as ListLiteral;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ListLiteral create() => ListLiteral._();
  @$core.override
  ListLiteral createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ListLiteral getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ListLiteral>(create);
  static ListLiteral? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<Expression> get elements => $_getList(0);
}

/// A reference to a named variable.
/// The special name "input" refers to the current function's input parameter.
class Reference extends $pb.GeneratedMessage {
  factory Reference({
    $core.String? name,
  }) {
    final result = create();
    if (name != null) result.name = name;
    return result;
  }

  Reference._();

  factory Reference.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Reference.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Reference',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Reference clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Reference copyWith(void Function(Reference) updates) =>
      super.copyWith((message) => updates(message as Reference)) as Reference;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Reference create() => Reference._();
  @$core.override
  Reference createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Reference getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Reference>(create);
  static Reference? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);
}

/// Accesses a field of a message-typed expression.
/// Equivalent to `object.field` in most languages.
class FieldAccess extends $pb.GeneratedMessage {
  factory FieldAccess({
    Expression? object,
    $core.String? field_2,
  }) {
    final result = create();
    if (object != null) result.object = object;
    if (field_2 != null) result.field_2 = field_2;
    return result;
  }

  FieldAccess._();

  factory FieldAccess.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FieldAccess.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FieldAccess',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOM<Expression>(1, _omitFieldNames ? '' : 'object',
        subBuilder: Expression.create)
    ..aOS(2, _omitFieldNames ? '' : 'field')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FieldAccess clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FieldAccess copyWith(void Function(FieldAccess) updates) =>
      super.copyWith((message) => updates(message as FieldAccess))
          as FieldAccess;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FieldAccess create() => FieldAccess._();
  @$core.override
  FieldAccess createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FieldAccess getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FieldAccess>(create);
  static FieldAccess? _defaultInstance;

  /// The expression that evaluates to a message
  @$pb.TagNumber(1)
  Expression get object => $_getN(0);
  @$pb.TagNumber(1)
  set object(Expression value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasObject() => $_has(0);
  @$pb.TagNumber(1)
  void clearObject() => $_clearField(1);
  @$pb.TagNumber(1)
  Expression ensureObject() => $_ensure(0);

  /// The field name to access
  @$pb.TagNumber(2)
  $core.String get field_2 => $_getSZ(1);
  @$pb.TagNumber(2)
  set field_2($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasField_2() => $_has(1);
  @$pb.TagNumber(2)
  void clearField_2() => $_clearField(2);
}

/// Constructs a new message instance with field values.
/// Equivalent to a constructor call or struct literal.
class MessageCreation extends $pb.GeneratedMessage {
  factory MessageCreation({
    $core.String? typeName,
    $core.Iterable<FieldValuePair>? fields,
  }) {
    final result = create();
    if (typeName != null) result.typeName = typeName;
    if (fields != null) result.fields.addAll(fields);
    return result;
  }

  MessageCreation._();

  factory MessageCreation.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MessageCreation.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MessageCreation',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'typeName')
    ..pPM<FieldValuePair>(2, _omitFieldNames ? '' : 'fields',
        subBuilder: FieldValuePair.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessageCreation clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MessageCreation copyWith(void Function(MessageCreation) updates) =>
      super.copyWith((message) => updates(message as MessageCreation))
          as MessageCreation;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MessageCreation create() => MessageCreation._();
  @$core.override
  MessageCreation createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MessageCreation getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MessageCreation>(create);
  static MessageCreation? _defaultInstance;

  /// The TypeDefinition name to instantiate (empty for anonymous/inline)
  @$pb.TagNumber(1)
  $core.String get typeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set typeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTypeName() => $_has(0);
  @$pb.TagNumber(1)
  void clearTypeName() => $_clearField(1);

  /// Field values for the new message
  @$pb.TagNumber(2)
  $pb.PbList<FieldValuePair> get fields => $_getList(1);
}

/// A name-value pair for MessageCreation fields.
class FieldValuePair extends $pb.GeneratedMessage {
  factory FieldValuePair({
    $core.String? name,
    Expression? value,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (value != null) result.value = value;
    return result;
  }

  FieldValuePair._();

  factory FieldValuePair.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FieldValuePair.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FieldValuePair',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOM<Expression>(2, _omitFieldNames ? '' : 'value',
        subBuilder: Expression.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FieldValuePair clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FieldValuePair copyWith(void Function(FieldValuePair) updates) =>
      super.copyWith((message) => updates(message as FieldValuePair))
          as FieldValuePair;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FieldValuePair create() => FieldValuePair._();
  @$core.override
  FieldValuePair createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FieldValuePair getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FieldValuePair>(create);
  static FieldValuePair? _defaultInstance;

  /// Field name
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Expression that evaluates to the field's value
  @$pb.TagNumber(2)
  Expression get value => $_getN(1);
  @$pb.TagNumber(2)
  set value(Expression value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);
  @$pb.TagNumber(2)
  Expression ensureValue() => $_ensure(1);
}

/// A block of sequential statements followed by a result expression.
/// The result expression's value is the value of the entire block.
class Block extends $pb.GeneratedMessage {
  factory Block({
    $core.Iterable<Statement>? statements,
    Expression? result,
  }) {
    final result$ = create();
    if (statements != null) result$.statements.addAll(statements);
    if (result != null) result$.result = result;
    return result$;
  }

  Block._();

  factory Block.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Block.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Block',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..pPM<Statement>(1, _omitFieldNames ? '' : 'statements',
        subBuilder: Statement.create)
    ..aOM<Expression>(2, _omitFieldNames ? '' : 'result',
        subBuilder: Expression.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Block clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Block copyWith(void Function(Block) updates) =>
      super.copyWith((message) => updates(message as Block)) as Block;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Block create() => Block._();
  @$core.override
  Block createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Block getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Block>(create);
  static Block? _defaultInstance;

  /// Statements executed in order
  @$pb.TagNumber(1)
  $pb.PbList<Statement> get statements => $_getList(0);

  /// The final expression whose value is returned
  @$pb.TagNumber(2)
  Expression get result => $_getN(1);
  @$pb.TagNumber(2)
  set result(Expression value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasResult() => $_has(1);
  @$pb.TagNumber(2)
  void clearResult() => $_clearField(2);
  @$pb.TagNumber(2)
  Expression ensureResult() => $_ensure(1);
}

enum Statement_Stmt { let, expression, notSet }

/// A statement within a Block. Either a let-binding or a bare expression.
class Statement extends $pb.GeneratedMessage {
  factory Statement({
    LetBinding? let,
    Expression? expression,
  }) {
    final result = create();
    if (let != null) result.let = let;
    if (expression != null) result.expression = expression;
    return result;
  }

  Statement._();

  factory Statement.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory Statement.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, Statement_Stmt> _Statement_StmtByTag = {
    1: Statement_Stmt.let,
    2: Statement_Stmt.expression,
    0: Statement_Stmt.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Statement',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..oo(0, [1, 2])
    ..aOM<LetBinding>(1, _omitFieldNames ? '' : 'let',
        subBuilder: LetBinding.create)
    ..aOM<Expression>(2, _omitFieldNames ? '' : 'expression',
        subBuilder: Expression.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Statement clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Statement copyWith(void Function(Statement) updates) =>
      super.copyWith((message) => updates(message as Statement)) as Statement;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Statement create() => Statement._();
  @$core.override
  Statement createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static Statement getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Statement>(create);
  static Statement? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  Statement_Stmt whichStmt() => _Statement_StmtByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearStmt() => $_clearField($_whichOneof(0));

  /// Bind a value to a name for use in subsequent statements/result
  @$pb.TagNumber(1)
  LetBinding get let => $_getN(0);
  @$pb.TagNumber(1)
  set let(LetBinding value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasLet() => $_has(0);
  @$pb.TagNumber(1)
  void clearLet() => $_clearField(1);
  @$pb.TagNumber(1)
  LetBinding ensureLet() => $_ensure(0);

  /// Evaluate an expression for its side effects
  @$pb.TagNumber(2)
  Expression get expression => $_getN(1);
  @$pb.TagNumber(2)
  set expression(Expression value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasExpression() => $_has(1);
  @$pb.TagNumber(2)
  void clearExpression() => $_clearField(2);
  @$pb.TagNumber(2)
  Expression ensureExpression() => $_ensure(1);
}

/// Binds a name to the value of an expression.
/// The name is available in all subsequent statements and the block's result.
class LetBinding extends $pb.GeneratedMessage {
  factory LetBinding({
    $core.String? name,
    Expression? value,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (value != null) result.value = value;
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  LetBinding._();

  factory LetBinding.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory LetBinding.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LetBinding',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOM<Expression>(2, _omitFieldNames ? '' : 'value',
        subBuilder: Expression.create)
    ..aOM<$0.Struct>(3, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LetBinding clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LetBinding copyWith(void Function(LetBinding) updates) =>
      super.copyWith((message) => updates(message as LetBinding)) as LetBinding;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LetBinding create() => LetBinding._();
  @$core.override
  LetBinding createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static LetBinding getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LetBinding>(create);
  static LetBinding? _defaultInstance;

  /// Variable name to bind
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Expression whose value is bound to the name
  @$pb.TagNumber(2)
  Expression get value => $_getN(1);
  @$pb.TagNumber(2)
  set value(Expression value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);
  @$pb.TagNumber(2)
  Expression ensureValue() => $_ensure(1);

  /// Arbitrary metadata for language-specific info (var/final/const, type, etc.)
  @$pb.TagNumber(3)
  $0.Struct get metadata => $_getN(2);
  @$pb.TagNumber(3)
  set metadata($0.Struct value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasMetadata() => $_has(2);
  @$pb.TagNumber(3)
  void clearMetadata() => $_clearField(3);
  @$pb.TagNumber(3)
  $0.Struct ensureMetadata() => $_ensure(2);
}

/// A manifest declares a Ball package's identity, entry point, and dependencies.
/// Analogous to pubspec.yaml, package.json, Cargo.toml.
/// Serialized as `ball.yaml` (human-friendly) or `ball.manifest.json` (proto JSON).
class BallManifest extends $pb.GeneratedMessage {
  factory BallManifest({
    $core.String? name,
    $core.String? version,
    $core.String? description,
    $core.String? entryModule,
    $core.String? entryFunction,
    $core.Iterable<ModuleImport>? dependencies,
    $core.Iterable<ModuleImport>? devDependencies,
    $0.Struct? metadata,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (version != null) result.version = version;
    if (description != null) result.description = description;
    if (entryModule != null) result.entryModule = entryModule;
    if (entryFunction != null) result.entryFunction = entryFunction;
    if (dependencies != null) result.dependencies.addAll(dependencies);
    if (devDependencies != null) result.devDependencies.addAll(devDependencies);
    if (metadata != null) result.metadata = metadata;
    return result;
  }

  BallManifest._();

  factory BallManifest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BallManifest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BallManifest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'version')
    ..aOS(3, _omitFieldNames ? '' : 'description')
    ..aOS(4, _omitFieldNames ? '' : 'entryModule')
    ..aOS(5, _omitFieldNames ? '' : 'entryFunction')
    ..pPM<ModuleImport>(6, _omitFieldNames ? '' : 'dependencies',
        subBuilder: ModuleImport.create)
    ..pPM<ModuleImport>(7, _omitFieldNames ? '' : 'devDependencies',
        subBuilder: ModuleImport.create)
    ..aOM<$0.Struct>(8, _omitFieldNames ? '' : 'metadata',
        subBuilder: $0.Struct.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BallManifest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BallManifest copyWith(void Function(BallManifest) updates) =>
      super.copyWith((message) => updates(message as BallManifest))
          as BallManifest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BallManifest create() => BallManifest._();
  @$core.override
  BallManifest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BallManifest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BallManifest>(create);
  static BallManifest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get version => $_getSZ(1);
  @$pb.TagNumber(2)
  set version($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearVersion() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get description => $_getSZ(2);
  @$pb.TagNumber(3)
  set description($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDescription() => $_has(2);
  @$pb.TagNumber(3)
  void clearDescription() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get entryModule => $_getSZ(3);
  @$pb.TagNumber(4)
  set entryModule($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasEntryModule() => $_has(3);
  @$pb.TagNumber(4)
  void clearEntryModule() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get entryFunction => $_getSZ(4);
  @$pb.TagNumber(5)
  set entryFunction($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasEntryFunction() => $_has(4);
  @$pb.TagNumber(5)
  void clearEntryFunction() => $_clearField(5);

  /// Direct dependencies required at runtime.
  @$pb.TagNumber(6)
  $pb.PbList<ModuleImport> get dependencies => $_getList(5);

  /// Dependencies only needed during development/testing.
  @$pb.TagNumber(7)
  $pb.PbList<ModuleImport> get devDependencies => $_getList(6);

  /// Arbitrary metadata (authors, license, homepage, repository, etc.).
  @$pb.TagNumber(8)
  $0.Struct get metadata => $_getN(7);
  @$pb.TagNumber(8)
  set metadata($0.Struct value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasMetadata() => $_has(7);
  @$pb.TagNumber(8)
  void clearMetadata() => $_clearField(8);
  @$pb.TagNumber(8)
  $0.Struct ensureMetadata() => $_ensure(7);
}

/// A lockfile pins every transitive dependency to an exact resolved version
/// and content hash. Ensures reproducible builds across machines and time.
/// Serialized as `ball.lock.json` (proto3 JSON, human-readable and diffable).
class BallLockfile extends $pb.GeneratedMessage {
  factory BallLockfile({
    $core.Iterable<ResolvedDependency>? packages,
    $core.String? lockVersion,
  }) {
    final result = create();
    if (packages != null) result.packages.addAll(packages);
    if (lockVersion != null) result.lockVersion = lockVersion;
    return result;
  }

  BallLockfile._();

  factory BallLockfile.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BallLockfile.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BallLockfile',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..pPM<ResolvedDependency>(1, _omitFieldNames ? '' : 'packages',
        subBuilder: ResolvedDependency.create)
    ..aOS(2, _omitFieldNames ? '' : 'lockVersion')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BallLockfile clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BallLockfile copyWith(void Function(BallLockfile) updates) =>
      super.copyWith((message) => updates(message as BallLockfile))
          as BallLockfile;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BallLockfile create() => BallLockfile._();
  @$core.override
  BallLockfile createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BallLockfile getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BallLockfile>(create);
  static BallLockfile? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<ResolvedDependency> get packages => $_getList(0);

  /// Lockfile format version (for forward compatibility).
  @$pb.TagNumber(2)
  $core.String get lockVersion => $_getSZ(1);
  @$pb.TagNumber(2)
  set lockVersion($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLockVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearLockVersion() => $_clearField(2);
}

enum ResolvedDependency_ResolvedSource { http, git, file, registry, notSet }

/// A single resolved dependency in the lockfile.
class ResolvedDependency extends $pb.GeneratedMessage {
  factory ResolvedDependency({
    $core.String? name,
    $core.String? resolvedVersion,
    $core.String? integrity,
    HttpSource? http,
    GitSource? git,
    FileSource? file,
    RegistrySource? registry,
    $core.Iterable<$core.String>? dependencyNames,
  }) {
    final result = create();
    if (name != null) result.name = name;
    if (resolvedVersion != null) result.resolvedVersion = resolvedVersion;
    if (integrity != null) result.integrity = integrity;
    if (http != null) result.http = http;
    if (git != null) result.git = git;
    if (file != null) result.file = file;
    if (registry != null) result.registry = registry;
    if (dependencyNames != null) result.dependencyNames.addAll(dependencyNames);
    return result;
  }

  ResolvedDependency._();

  factory ResolvedDependency.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ResolvedDependency.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ResolvedDependency_ResolvedSource>
      _ResolvedDependency_ResolvedSourceByTag = {
    4: ResolvedDependency_ResolvedSource.http,
    5: ResolvedDependency_ResolvedSource.git,
    6: ResolvedDependency_ResolvedSource.file,
    7: ResolvedDependency_ResolvedSource.registry,
    0: ResolvedDependency_ResolvedSource.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ResolvedDependency',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..oo(0, [4, 5, 6, 7])
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'resolvedVersion')
    ..aOS(3, _omitFieldNames ? '' : 'integrity')
    ..aOM<HttpSource>(4, _omitFieldNames ? '' : 'http',
        subBuilder: HttpSource.create)
    ..aOM<GitSource>(5, _omitFieldNames ? '' : 'git',
        subBuilder: GitSource.create)
    ..aOM<FileSource>(6, _omitFieldNames ? '' : 'file',
        subBuilder: FileSource.create)
    ..aOM<RegistrySource>(7, _omitFieldNames ? '' : 'registry',
        subBuilder: RegistrySource.create)
    ..pPS(8, _omitFieldNames ? '' : 'dependencyNames')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResolvedDependency clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResolvedDependency copyWith(void Function(ResolvedDependency) updates) =>
      super.copyWith((message) => updates(message as ResolvedDependency))
          as ResolvedDependency;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ResolvedDependency create() => ResolvedDependency._();
  @$core.override
  ResolvedDependency createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ResolvedDependency getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ResolvedDependency>(create);
  static ResolvedDependency? _defaultInstance;

  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  ResolvedDependency_ResolvedSource whichResolvedSource() =>
      _ResolvedDependency_ResolvedSourceByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  void clearResolvedSource() => $_clearField($_whichOneof(0));

  /// Package name (matches ModuleImport.name).
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Exact resolved version (not a constraint).
  @$pb.TagNumber(2)
  $core.String get resolvedVersion => $_getSZ(1);
  @$pb.TagNumber(2)
  set resolvedVersion($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasResolvedVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearResolvedVersion() => $_clearField(2);

  /// Content integrity hash: "sha256:<hex>".
  @$pb.TagNumber(3)
  $core.String get integrity => $_getSZ(2);
  @$pb.TagNumber(3)
  set integrity($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasIntegrity() => $_has(2);
  @$pb.TagNumber(3)
  void clearIntegrity() => $_clearField(3);

  @$pb.TagNumber(4)
  HttpSource get http => $_getN(3);
  @$pb.TagNumber(4)
  set http(HttpSource value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasHttp() => $_has(3);
  @$pb.TagNumber(4)
  void clearHttp() => $_clearField(4);
  @$pb.TagNumber(4)
  HttpSource ensureHttp() => $_ensure(3);

  @$pb.TagNumber(5)
  GitSource get git => $_getN(4);
  @$pb.TagNumber(5)
  set git(GitSource value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasGit() => $_has(4);
  @$pb.TagNumber(5)
  void clearGit() => $_clearField(5);
  @$pb.TagNumber(5)
  GitSource ensureGit() => $_ensure(4);

  @$pb.TagNumber(6)
  FileSource get file => $_getN(5);
  @$pb.TagNumber(6)
  set file(FileSource value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasFile() => $_has(5);
  @$pb.TagNumber(6)
  void clearFile() => $_clearField(6);
  @$pb.TagNumber(6)
  FileSource ensureFile() => $_ensure(5);

  @$pb.TagNumber(7)
  RegistrySource get registry => $_getN(6);
  @$pb.TagNumber(7)
  set registry(RegistrySource value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasRegistry() => $_has(6);
  @$pb.TagNumber(7)
  void clearRegistry() => $_clearField(7);
  @$pb.TagNumber(7)
  RegistrySource ensureRegistry() => $_ensure(6);

  /// Names of this package's own dependencies (for the dep graph).
  @$pb.TagNumber(8)
  $pb.PbList<$core.String> get dependencyNames => $_getList(7);
}

/// The output of `ball audit`: a structured report of every side effect
/// a Ball program can perform. Since every side effect in Ball flows
/// through a named base function in a known module, this analysis is
/// provably complete — not heuristic.
class BallCapabilityReport extends $pb.GeneratedMessage {
  factory BallCapabilityReport({
    $core.String? programName,
    $core.String? programVersion,
    $core.Iterable<CapabilityEntry>? capabilities,
    $core.Iterable<FunctionCapability>? functions,
    CapabilitySummary? summary,
  }) {
    final result = create();
    if (programName != null) result.programName = programName;
    if (programVersion != null) result.programVersion = programVersion;
    if (capabilities != null) result.capabilities.addAll(capabilities);
    if (functions != null) result.functions.addAll(functions);
    if (summary != null) result.summary = summary;
    return result;
  }

  BallCapabilityReport._();

  factory BallCapabilityReport.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory BallCapabilityReport.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BallCapabilityReport',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'programName')
    ..aOS(2, _omitFieldNames ? '' : 'programVersion')
    ..pPM<CapabilityEntry>(3, _omitFieldNames ? '' : 'capabilities',
        subBuilder: CapabilityEntry.create)
    ..pPM<FunctionCapability>(4, _omitFieldNames ? '' : 'functions',
        subBuilder: FunctionCapability.create)
    ..aOM<CapabilitySummary>(5, _omitFieldNames ? '' : 'summary',
        subBuilder: CapabilitySummary.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BallCapabilityReport clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BallCapabilityReport copyWith(void Function(BallCapabilityReport) updates) =>
      super.copyWith((message) => updates(message as BallCapabilityReport))
          as BallCapabilityReport;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BallCapabilityReport create() => BallCapabilityReport._();
  @$core.override
  BallCapabilityReport createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static BallCapabilityReport getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BallCapabilityReport>(create);
  static BallCapabilityReport? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get programName => $_getSZ(0);
  @$pb.TagNumber(1)
  set programName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasProgramName() => $_has(0);
  @$pb.TagNumber(1)
  void clearProgramName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get programVersion => $_getSZ(1);
  @$pb.TagNumber(2)
  set programVersion($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasProgramVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearProgramVersion() => $_clearField(2);

  /// One entry per capability category found in the program.
  @$pb.TagNumber(3)
  $pb.PbList<CapabilityEntry> get capabilities => $_getList(2);

  /// Per-function capability breakdown.
  @$pb.TagNumber(4)
  $pb.PbList<FunctionCapability> get functions => $_getList(3);

  /// Aggregate summary flags.
  @$pb.TagNumber(5)
  CapabilitySummary get summary => $_getN(4);
  @$pb.TagNumber(5)
  set summary(CapabilitySummary value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasSummary() => $_has(4);
  @$pb.TagNumber(5)
  void clearSummary() => $_clearField(5);
  @$pb.TagNumber(5)
  CapabilitySummary ensureSummary() => $_ensure(4);
}

/// A single capability category (e.g. "fs", "io", "memory") with all
/// call sites in the program that trigger it.
class CapabilityEntry extends $pb.GeneratedMessage {
  factory CapabilityEntry({
    $core.String? capability,
    $core.String? riskLevel,
    $core.Iterable<CallSite>? callSites,
  }) {
    final result = create();
    if (capability != null) result.capability = capability;
    if (riskLevel != null) result.riskLevel = riskLevel;
    if (callSites != null) result.callSites.addAll(callSites);
    return result;
  }

  CapabilityEntry._();

  factory CapabilityEntry.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CapabilityEntry.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CapabilityEntry',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'capability')
    ..aOS(2, _omitFieldNames ? '' : 'riskLevel')
    ..pPM<CallSite>(3, _omitFieldNames ? '' : 'callSites',
        subBuilder: CallSite.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CapabilityEntry clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CapabilityEntry copyWith(void Function(CapabilityEntry) updates) =>
      super.copyWith((message) => updates(message as CapabilityEntry))
          as CapabilityEntry;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CapabilityEntry create() => CapabilityEntry._();
  @$core.override
  CapabilityEntry createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CapabilityEntry getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CapabilityEntry>(create);
  static CapabilityEntry? _defaultInstance;

  /// Category name: "pure", "io", "fs", "process", "time", "random",
  ///                "memory", "concurrency", "network".
  @$pb.TagNumber(1)
  $core.String get capability => $_getSZ(0);
  @$pb.TagNumber(1)
  set capability($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCapability() => $_has(0);
  @$pb.TagNumber(1)
  void clearCapability() => $_clearField(1);

  /// Risk level: "none", "low", "medium", "high".
  @$pb.TagNumber(2)
  $core.String get riskLevel => $_getSZ(1);
  @$pb.TagNumber(2)
  set riskLevel($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasRiskLevel() => $_has(1);
  @$pb.TagNumber(2)
  void clearRiskLevel() => $_clearField(2);

  /// Every call site in the program that triggers this capability.
  @$pb.TagNumber(3)
  $pb.PbList<CallSite> get callSites => $_getList(2);
}

/// A specific location in the program where a capability-bearing base
/// function is called.
class CallSite extends $pb.GeneratedMessage {
  factory CallSite({
    $core.String? module,
    $core.String? function,
    $core.String? calleeModule,
    $core.String? calleeFunction,
  }) {
    final result = create();
    if (module != null) result.module = module;
    if (function != null) result.function = function;
    if (calleeModule != null) result.calleeModule = calleeModule;
    if (calleeFunction != null) result.calleeFunction = calleeFunction;
    return result;
  }

  CallSite._();

  factory CallSite.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CallSite.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CallSite',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'module')
    ..aOS(2, _omitFieldNames ? '' : 'function')
    ..aOS(3, _omitFieldNames ? '' : 'calleeModule')
    ..aOS(4, _omitFieldNames ? '' : 'calleeFunction')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CallSite clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CallSite copyWith(void Function(CallSite) updates) =>
      super.copyWith((message) => updates(message as CallSite)) as CallSite;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CallSite create() => CallSite._();
  @$core.override
  CallSite createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CallSite getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<CallSite>(create);
  static CallSite? _defaultInstance;

  /// The user module containing the call.
  @$pb.TagNumber(1)
  $core.String get module => $_getSZ(0);
  @$pb.TagNumber(1)
  set module($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasModule() => $_has(0);
  @$pb.TagNumber(1)
  void clearModule() => $_clearField(1);

  /// The user function containing the call.
  @$pb.TagNumber(2)
  $core.String get function => $_getSZ(1);
  @$pb.TagNumber(2)
  set function($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFunction() => $_has(1);
  @$pb.TagNumber(2)
  void clearFunction() => $_clearField(2);

  /// The base module being called (e.g. "std_fs").
  @$pb.TagNumber(3)
  $core.String get calleeModule => $_getSZ(2);
  @$pb.TagNumber(3)
  set calleeModule($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasCalleeModule() => $_has(2);
  @$pb.TagNumber(3)
  void clearCalleeModule() => $_clearField(3);

  /// The base function being called (e.g. "file_read").
  @$pb.TagNumber(4)
  $core.String get calleeFunction => $_getSZ(3);
  @$pb.TagNumber(4)
  set calleeFunction($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCalleeFunction() => $_has(3);
  @$pb.TagNumber(4)
  void clearCalleeFunction() => $_clearField(4);
}

/// The capabilities a single function transitively requires.
class FunctionCapability extends $pb.GeneratedMessage {
  factory FunctionCapability({
    $core.String? module,
    $core.String? function,
    $core.Iterable<$core.String>? capabilities,
  }) {
    final result = create();
    if (module != null) result.module = module;
    if (function != null) result.function = function;
    if (capabilities != null) result.capabilities.addAll(capabilities);
    return result;
  }

  FunctionCapability._();

  factory FunctionCapability.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory FunctionCapability.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FunctionCapability',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'module')
    ..aOS(2, _omitFieldNames ? '' : 'function')
    ..pPS(3, _omitFieldNames ? '' : 'capabilities')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionCapability clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionCapability copyWith(void Function(FunctionCapability) updates) =>
      super.copyWith((message) => updates(message as FunctionCapability))
          as FunctionCapability;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FunctionCapability create() => FunctionCapability._();
  @$core.override
  FunctionCapability createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static FunctionCapability getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FunctionCapability>(create);
  static FunctionCapability? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get module => $_getSZ(0);
  @$pb.TagNumber(1)
  set module($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasModule() => $_has(0);
  @$pb.TagNumber(1)
  void clearModule() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get function => $_getSZ(1);
  @$pb.TagNumber(2)
  set function($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFunction() => $_has(1);
  @$pb.TagNumber(2)
  void clearFunction() => $_clearField(2);

  /// All capability categories this function (transitively) uses.
  @$pb.TagNumber(3)
  $pb.PbList<$core.String> get capabilities => $_getList(2);
}

/// Aggregate boolean summary of a program's capabilities.
class CapabilitySummary extends $pb.GeneratedMessage {
  factory CapabilitySummary({
    $core.bool? isPure,
    $core.bool? readsFilesystem,
    $core.bool? writesFilesystem,
    $core.bool? readsStdin,
    $core.bool? writesStdout,
    $core.bool? writesStderr,
    $core.bool? readsEnvironment,
    $core.bool? controlsProcess,
    $core.bool? usesMemory,
    $core.bool? usesTime,
    $core.bool? usesRandom,
    $core.bool? usesConcurrency,
    $core.bool? usesNetwork,
    $core.int? totalFunctions,
    $core.int? pureFunctions,
    $core.int? effectfulFunctions,
  }) {
    final result = create();
    if (isPure != null) result.isPure = isPure;
    if (readsFilesystem != null) result.readsFilesystem = readsFilesystem;
    if (writesFilesystem != null) result.writesFilesystem = writesFilesystem;
    if (readsStdin != null) result.readsStdin = readsStdin;
    if (writesStdout != null) result.writesStdout = writesStdout;
    if (writesStderr != null) result.writesStderr = writesStderr;
    if (readsEnvironment != null) result.readsEnvironment = readsEnvironment;
    if (controlsProcess != null) result.controlsProcess = controlsProcess;
    if (usesMemory != null) result.usesMemory = usesMemory;
    if (usesTime != null) result.usesTime = usesTime;
    if (usesRandom != null) result.usesRandom = usesRandom;
    if (usesConcurrency != null) result.usesConcurrency = usesConcurrency;
    if (usesNetwork != null) result.usesNetwork = usesNetwork;
    if (totalFunctions != null) result.totalFunctions = totalFunctions;
    if (pureFunctions != null) result.pureFunctions = pureFunctions;
    if (effectfulFunctions != null)
      result.effectfulFunctions = effectfulFunctions;
    return result;
  }

  CapabilitySummary._();

  factory CapabilitySummary.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CapabilitySummary.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CapabilitySummary',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'ball.v1'),
      createEmptyInstance: create)
    ..aOB(1, _omitFieldNames ? '' : 'isPure')
    ..aOB(2, _omitFieldNames ? '' : 'readsFilesystem')
    ..aOB(3, _omitFieldNames ? '' : 'writesFilesystem')
    ..aOB(4, _omitFieldNames ? '' : 'readsStdin')
    ..aOB(5, _omitFieldNames ? '' : 'writesStdout')
    ..aOB(6, _omitFieldNames ? '' : 'writesStderr')
    ..aOB(7, _omitFieldNames ? '' : 'readsEnvironment')
    ..aOB(8, _omitFieldNames ? '' : 'controlsProcess')
    ..aOB(9, _omitFieldNames ? '' : 'usesMemory')
    ..aOB(10, _omitFieldNames ? '' : 'usesTime')
    ..aOB(11, _omitFieldNames ? '' : 'usesRandom')
    ..aOB(12, _omitFieldNames ? '' : 'usesConcurrency')
    ..aOB(13, _omitFieldNames ? '' : 'usesNetwork')
    ..aI(14, _omitFieldNames ? '' : 'totalFunctions')
    ..aI(15, _omitFieldNames ? '' : 'pureFunctions')
    ..aI(16, _omitFieldNames ? '' : 'effectfulFunctions')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CapabilitySummary clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CapabilitySummary copyWith(void Function(CapabilitySummary) updates) =>
      super.copyWith((message) => updates(message as CapabilitySummary))
          as CapabilitySummary;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CapabilitySummary create() => CapabilitySummary._();
  @$core.override
  CapabilitySummary createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CapabilitySummary getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CapabilitySummary>(create);
  static CapabilitySummary? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get isPure => $_getBF(0);
  @$pb.TagNumber(1)
  set isPure($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIsPure() => $_has(0);
  @$pb.TagNumber(1)
  void clearIsPure() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get readsFilesystem => $_getBF(1);
  @$pb.TagNumber(2)
  set readsFilesystem($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasReadsFilesystem() => $_has(1);
  @$pb.TagNumber(2)
  void clearReadsFilesystem() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get writesFilesystem => $_getBF(2);
  @$pb.TagNumber(3)
  set writesFilesystem($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasWritesFilesystem() => $_has(2);
  @$pb.TagNumber(3)
  void clearWritesFilesystem() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.bool get readsStdin => $_getBF(3);
  @$pb.TagNumber(4)
  set readsStdin($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasReadsStdin() => $_has(3);
  @$pb.TagNumber(4)
  void clearReadsStdin() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.bool get writesStdout => $_getBF(4);
  @$pb.TagNumber(5)
  set writesStdout($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasWritesStdout() => $_has(4);
  @$pb.TagNumber(5)
  void clearWritesStdout() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get writesStderr => $_getBF(5);
  @$pb.TagNumber(6)
  set writesStderr($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasWritesStderr() => $_has(5);
  @$pb.TagNumber(6)
  void clearWritesStderr() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.bool get readsEnvironment => $_getBF(6);
  @$pb.TagNumber(7)
  set readsEnvironment($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasReadsEnvironment() => $_has(6);
  @$pb.TagNumber(7)
  void clearReadsEnvironment() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.bool get controlsProcess => $_getBF(7);
  @$pb.TagNumber(8)
  set controlsProcess($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasControlsProcess() => $_has(7);
  @$pb.TagNumber(8)
  void clearControlsProcess() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.bool get usesMemory => $_getBF(8);
  @$pb.TagNumber(9)
  set usesMemory($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(9)
  $core.bool hasUsesMemory() => $_has(8);
  @$pb.TagNumber(9)
  void clearUsesMemory() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.bool get usesTime => $_getBF(9);
  @$pb.TagNumber(10)
  set usesTime($core.bool value) => $_setBool(9, value);
  @$pb.TagNumber(10)
  $core.bool hasUsesTime() => $_has(9);
  @$pb.TagNumber(10)
  void clearUsesTime() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.bool get usesRandom => $_getBF(10);
  @$pb.TagNumber(11)
  set usesRandom($core.bool value) => $_setBool(10, value);
  @$pb.TagNumber(11)
  $core.bool hasUsesRandom() => $_has(10);
  @$pb.TagNumber(11)
  void clearUsesRandom() => $_clearField(11);

  @$pb.TagNumber(12)
  $core.bool get usesConcurrency => $_getBF(11);
  @$pb.TagNumber(12)
  set usesConcurrency($core.bool value) => $_setBool(11, value);
  @$pb.TagNumber(12)
  $core.bool hasUsesConcurrency() => $_has(11);
  @$pb.TagNumber(12)
  void clearUsesConcurrency() => $_clearField(12);

  @$pb.TagNumber(13)
  $core.bool get usesNetwork => $_getBF(12);
  @$pb.TagNumber(13)
  set usesNetwork($core.bool value) => $_setBool(12, value);
  @$pb.TagNumber(13)
  $core.bool hasUsesNetwork() => $_has(12);
  @$pb.TagNumber(13)
  void clearUsesNetwork() => $_clearField(13);

  @$pb.TagNumber(14)
  $core.int get totalFunctions => $_getIZ(13);
  @$pb.TagNumber(14)
  set totalFunctions($core.int value) => $_setSignedInt32(13, value);
  @$pb.TagNumber(14)
  $core.bool hasTotalFunctions() => $_has(13);
  @$pb.TagNumber(14)
  void clearTotalFunctions() => $_clearField(14);

  @$pb.TagNumber(15)
  $core.int get pureFunctions => $_getIZ(14);
  @$pb.TagNumber(15)
  set pureFunctions($core.int value) => $_setSignedInt32(14, value);
  @$pb.TagNumber(15)
  $core.bool hasPureFunctions() => $_has(14);
  @$pb.TagNumber(15)
  void clearPureFunctions() => $_clearField(15);

  @$pb.TagNumber(16)
  $core.int get effectfulFunctions => $_getIZ(15);
  @$pb.TagNumber(16)
  set effectfulFunctions($core.int value) => $_setSignedInt32(15, value);
  @$pb.TagNumber(16)
  $core.bool hasEffectfulFunctions() => $_has(15);
  @$pb.TagNumber(16)
  void clearEffectfulFunctions() => $_clearField(16);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
