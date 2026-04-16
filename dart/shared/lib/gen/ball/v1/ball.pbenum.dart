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

import 'package:protobuf/protobuf.dart' as $pb;

/// Supported package registries for RegistrySource.
class Registry extends $pb.ProtobufEnum {
  static const Registry REGISTRY_UNSPECIFIED =
      Registry._(0, _omitEnumNames ? '' : 'REGISTRY_UNSPECIFIED');
  static const Registry REGISTRY_PUB =
      Registry._(1, _omitEnumNames ? '' : 'REGISTRY_PUB');
  static const Registry REGISTRY_NPM =
      Registry._(2, _omitEnumNames ? '' : 'REGISTRY_NPM');
  static const Registry REGISTRY_NUGET =
      Registry._(3, _omitEnumNames ? '' : 'REGISTRY_NUGET');
  static const Registry REGISTRY_CARGO =
      Registry._(4, _omitEnumNames ? '' : 'REGISTRY_CARGO');
  static const Registry REGISTRY_PYPI =
      Registry._(5, _omitEnumNames ? '' : 'REGISTRY_PYPI');
  static const Registry REGISTRY_MAVEN =
      Registry._(6, _omitEnumNames ? '' : 'REGISTRY_MAVEN');

  static const $core.List<Registry> values = <Registry>[
    REGISTRY_UNSPECIFIED,
    REGISTRY_PUB,
    REGISTRY_NPM,
    REGISTRY_NUGET,
    REGISTRY_CARGO,
    REGISTRY_PYPI,
    REGISTRY_MAVEN,
  ];

  static final $core.List<Registry?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static Registry? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Registry._(super.value, super.name);
}

/// Serialization format for ball Module data.
class ModuleEncoding extends $pb.ProtobufEnum {
  /// Auto-detect from file extension, Content-Type header, or content.
  ///   .ball.bin / .ball  → PROTO
  ///   .ball.json / .json → JSON
  ///   application/x-protobuf → PROTO
  ///   application/json → JSON
  static const ModuleEncoding MODULE_ENCODING_UNSPECIFIED =
      ModuleEncoding._(0, _omitEnumNames ? '' : 'MODULE_ENCODING_UNSPECIFIED');

  /// Protobuf binary wire format.
  static const ModuleEncoding MODULE_ENCODING_PROTO =
      ModuleEncoding._(1, _omitEnumNames ? '' : 'MODULE_ENCODING_PROTO');

  /// JSON format (protobuf canonical JSON mapping).
  static const ModuleEncoding MODULE_ENCODING_JSON =
      ModuleEncoding._(2, _omitEnumNames ? '' : 'MODULE_ENCODING_JSON');

  static const $core.List<ModuleEncoding> values = <ModuleEncoding>[
    MODULE_ENCODING_UNSPECIFIED,
    MODULE_ENCODING_PROTO,
    MODULE_ENCODING_JSON,
  ];

  static final $core.List<ModuleEncoding?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static ModuleEncoding? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const ModuleEncoding._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
