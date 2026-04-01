// This is a generated file - do not edit.
//
// Generated from ball/v1/ball.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use moduleEncodingDescriptor instead')
const ModuleEncoding$json = {
  '1': 'ModuleEncoding',
  '2': [
    {'1': 'MODULE_ENCODING_UNSPECIFIED', '2': 0},
    {'1': 'MODULE_ENCODING_PROTO', '2': 1},
    {'1': 'MODULE_ENCODING_JSON', '2': 2},
  ],
};

/// Descriptor for `ModuleEncoding`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List moduleEncodingDescriptor = $convert.base64Decode(
    'Cg5Nb2R1bGVFbmNvZGluZxIfChtNT0RVTEVfRU5DT0RJTkdfVU5TUEVDSUZJRUQQABIZChVNT0'
    'RVTEVfRU5DT0RJTkdfUFJPVE8QARIYChRNT0RVTEVfRU5DT0RJTkdfSlNPThAC');

@$core.Deprecated('Use programDescriptor instead')
const Program$json = {
  '1': 'Program',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'version', '3': 2, '4': 1, '5': 9, '10': 'version'},
    {
      '1': 'modules',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.Module',
      '10': 'modules'
    },
    {'1': 'entry_module', '3': 4, '4': 1, '5': 9, '10': 'entryModule'},
    {'1': 'entry_function', '3': 5, '4': 1, '5': 9, '10': 'entryFunction'},
    {
      '1': 'metadata',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `Program`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List programDescriptor = $convert.base64Decode(
    'CgdQcm9ncmFtEhIKBG5hbWUYASABKAlSBG5hbWUSGAoHdmVyc2lvbhgCIAEoCVIHdmVyc2lvbh'
    'IpCgdtb2R1bGVzGAMgAygLMg8uYmFsbC52MS5Nb2R1bGVSB21vZHVsZXMSIQoMZW50cnlfbW9k'
    'dWxlGAQgASgJUgtlbnRyeU1vZHVsZRIlCg5lbnRyeV9mdW5jdGlvbhgFIAEoCVINZW50cnlGdW'
    '5jdGlvbhIzCghtZXRhZGF0YRgGIAEoCzIXLmdvb2dsZS5wcm90b2J1Zi5TdHJ1Y3RSCG1ldGFk'
    'YXRh');

@$core.Deprecated('Use moduleDescriptor instead')
const Module$json = {
  '1': 'Module',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'types',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.google.protobuf.DescriptorProto',
      '10': 'types'
    },
    {
      '1': 'enums',
      '3': 7,
      '4': 3,
      '5': 11,
      '6': '.google.protobuf.EnumDescriptorProto',
      '10': 'enums'
    },
    {
      '1': 'functions',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.FunctionDefinition',
      '10': 'functions'
    },
    {'1': 'description', '3': 5, '4': 1, '5': 9, '10': 'description'},
    {
      '1': 'metadata',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
    {
      '1': 'module_imports',
      '3': 4,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.ModuleImport',
      '10': 'moduleImports'
    },
    {
      '1': 'type_defs',
      '3': 8,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.TypeDefinition',
      '10': 'typeDefs'
    },
    {
      '1': 'type_aliases',
      '3': 11,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.TypeAlias',
      '10': 'typeAliases'
    },
    {
      '1': 'module_constants',
      '3': 12,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.Constant',
      '10': 'moduleConstants'
    },
    {
      '1': 'assets',
      '3': 13,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.ModuleAsset',
      '10': 'assets'
    },
  ],
};

/// Descriptor for `Module`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List moduleDescriptor = $convert.base64Decode(
    'CgZNb2R1bGUSEgoEbmFtZRgBIAEoCVIEbmFtZRI2CgV0eXBlcxgCIAMoCzIgLmdvb2dsZS5wcm'
    '90b2J1Zi5EZXNjcmlwdG9yUHJvdG9SBXR5cGVzEjoKBWVudW1zGAcgAygLMiQuZ29vZ2xlLnBy'
    'b3RvYnVmLkVudW1EZXNjcmlwdG9yUHJvdG9SBWVudW1zEjkKCWZ1bmN0aW9ucxgDIAMoCzIbLm'
    'JhbGwudjEuRnVuY3Rpb25EZWZpbml0aW9uUglmdW5jdGlvbnMSIAoLZGVzY3JpcHRpb24YBSAB'
    'KAlSC2Rlc2NyaXB0aW9uEjMKCG1ldGFkYXRhGAYgASgLMhcuZ29vZ2xlLnByb3RvYnVmLlN0cn'
    'VjdFIIbWV0YWRhdGESPAoObW9kdWxlX2ltcG9ydHMYBCADKAsyFS5iYWxsLnYxLk1vZHVsZUlt'
    'cG9ydFINbW9kdWxlSW1wb3J0cxI0Cgl0eXBlX2RlZnMYCCADKAsyFy5iYWxsLnYxLlR5cGVEZW'
    'Zpbml0aW9uUgh0eXBlRGVmcxI1Cgx0eXBlX2FsaWFzZXMYCyADKAsyEi5iYWxsLnYxLlR5cGVB'
    'bGlhc1ILdHlwZUFsaWFzZXMSPAoQbW9kdWxlX2NvbnN0YW50cxgMIAMoCzIRLmJhbGwudjEuQ2'
    '9uc3RhbnRSD21vZHVsZUNvbnN0YW50cxIsCgZhc3NldHMYDSADKAsyFC5iYWxsLnYxLk1vZHVs'
    'ZUFzc2V0UgZhc3NldHM=');

@$core.Deprecated('Use moduleAssetDescriptor instead')
const ModuleAsset$json = {
  '1': 'ModuleAsset',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'content', '3': 2, '4': 1, '5': 12, '10': 'content'},
    {'1': 'media_type', '3': 3, '4': 1, '5': 9, '10': 'mediaType'},
    {
      '1': 'metadata',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `ModuleAsset`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List moduleAssetDescriptor = $convert.base64Decode(
    'CgtNb2R1bGVBc3NldBISCgRwYXRoGAEgASgJUgRwYXRoEhgKB2NvbnRlbnQYAiABKAxSB2Nvbn'
    'RlbnQSHQoKbWVkaWFfdHlwZRgDIAEoCVIJbWVkaWFUeXBlEjMKCG1ldGFkYXRhGAQgASgLMhcu'
    'Z29vZ2xlLnByb3RvYnVmLlN0cnVjdFIIbWV0YWRhdGE=');

@$core.Deprecated('Use moduleImportDescriptor instead')
const ModuleImport$json = {
  '1': 'ModuleImport',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'integrity', '3': 2, '4': 1, '5': 9, '10': 'integrity'},
    {
      '1': 'metadata',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
    {
      '1': 'http',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.HttpSource',
      '9': 0,
      '10': 'http'
    },
    {
      '1': 'file',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.FileSource',
      '9': 0,
      '10': 'file'
    },
    {
      '1': 'inline',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.InlineSource',
      '9': 0,
      '10': 'inline'
    },
    {
      '1': 'git',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.GitSource',
      '9': 0,
      '10': 'git'
    },
  ],
  '8': [
    {'1': 'source'},
  ],
};

/// Descriptor for `ModuleImport`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List moduleImportDescriptor = $convert.base64Decode(
    'CgxNb2R1bGVJbXBvcnQSEgoEbmFtZRgBIAEoCVIEbmFtZRIcCglpbnRlZ3JpdHkYAiABKAlSCW'
    'ludGVncml0eRIzCghtZXRhZGF0YRgDIAEoCzIXLmdvb2dsZS5wcm90b2J1Zi5TdHJ1Y3RSCG1l'
    'dGFkYXRhEikKBGh0dHAYBCABKAsyEy5iYWxsLnYxLkh0dHBTb3VyY2VIAFIEaHR0cBIpCgRmaW'
    'xlGAUgASgLMhMuYmFsbC52MS5GaWxlU291cmNlSABSBGZpbGUSLwoGaW5saW5lGAYgASgLMhUu'
    'YmFsbC52MS5JbmxpbmVTb3VyY2VIAFIGaW5saW5lEiYKA2dpdBgHIAEoCzISLmJhbGwudjEuR2'
    'l0U291cmNlSABSA2dpdEIICgZzb3VyY2U=');

@$core.Deprecated('Use httpSourceDescriptor instead')
const HttpSource$json = {
  '1': 'HttpSource',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
    {
      '1': 'encoding',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.ball.v1.ModuleEncoding',
      '10': 'encoding'
    },
    {
      '1': 'headers',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.HttpSource.HeadersEntry',
      '10': 'headers'
    },
  ],
  '3': [HttpSource_HeadersEntry$json],
};

@$core.Deprecated('Use httpSourceDescriptor instead')
const HttpSource_HeadersEntry$json = {
  '1': 'HeadersEntry',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 9, '10': 'value'},
  ],
  '7': {'7': true},
};

/// Descriptor for `HttpSource`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List httpSourceDescriptor = $convert.base64Decode(
    'CgpIdHRwU291cmNlEhAKA3VybBgBIAEoCVIDdXJsEjMKCGVuY29kaW5nGAIgASgOMhcuYmFsbC'
    '52MS5Nb2R1bGVFbmNvZGluZ1IIZW5jb2RpbmcSOgoHaGVhZGVycxgDIAMoCzIgLmJhbGwudjEu'
    'SHR0cFNvdXJjZS5IZWFkZXJzRW50cnlSB2hlYWRlcnMaOgoMSGVhZGVyc0VudHJ5EhAKA2tleR'
    'gBIAEoCVIDa2V5EhQKBXZhbHVlGAIgASgJUgV2YWx1ZToCOAE=');

@$core.Deprecated('Use fileSourceDescriptor instead')
const FileSource$json = {
  '1': 'FileSource',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {
      '1': 'encoding',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.ball.v1.ModuleEncoding',
      '10': 'encoding'
    },
  ],
};

/// Descriptor for `FileSource`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileSourceDescriptor = $convert.base64Decode(
    'CgpGaWxlU291cmNlEhIKBHBhdGgYASABKAlSBHBhdGgSMwoIZW5jb2RpbmcYAiABKA4yFy5iYW'
    'xsLnYxLk1vZHVsZUVuY29kaW5nUghlbmNvZGluZw==');

@$core.Deprecated('Use inlineSourceDescriptor instead')
const InlineSource$json = {
  '1': 'InlineSource',
  '2': [
    {'1': 'proto_bytes', '3': 1, '4': 1, '5': 12, '9': 0, '10': 'protoBytes'},
    {'1': 'json', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'json'},
  ],
  '8': [
    {'1': 'content'},
  ],
};

/// Descriptor for `InlineSource`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List inlineSourceDescriptor = $convert.base64Decode(
    'CgxJbmxpbmVTb3VyY2USIQoLcHJvdG9fYnl0ZXMYASABKAxIAFIKcHJvdG9CeXRlcxIUCgRqc2'
    '9uGAIgASgJSABSBGpzb25CCQoHY29udGVudA==');

@$core.Deprecated('Use gitSourceDescriptor instead')
const GitSource$json = {
  '1': 'GitSource',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
    {'1': 'ref', '3': 2, '4': 1, '5': 9, '10': 'ref'},
    {'1': 'path', '3': 3, '4': 1, '5': 9, '10': 'path'},
    {
      '1': 'encoding',
      '3': 4,
      '4': 1,
      '5': 14,
      '6': '.ball.v1.ModuleEncoding',
      '10': 'encoding'
    },
  ],
};

/// Descriptor for `GitSource`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List gitSourceDescriptor = $convert.base64Decode(
    'CglHaXRTb3VyY2USEAoDdXJsGAEgASgJUgN1cmwSEAoDcmVmGAIgASgJUgNyZWYSEgoEcGF0aB'
    'gDIAEoCVIEcGF0aBIzCghlbmNvZGluZxgEIAEoDjIXLmJhbGwudjEuTW9kdWxlRW5jb2RpbmdS'
    'CGVuY29kaW5n');

@$core.Deprecated('Use typeParameterDescriptor instead')
const TypeParameter$json = {
  '1': 'TypeParameter',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'metadata',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `TypeParameter`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List typeParameterDescriptor = $convert.base64Decode(
    'Cg1UeXBlUGFyYW1ldGVyEhIKBG5hbWUYASABKAlSBG5hbWUSMwoIbWV0YWRhdGEYAiABKAsyFy'
    '5nb29nbGUucHJvdG9idWYuU3RydWN0UghtZXRhZGF0YQ==');

@$core.Deprecated('Use typeDefinitionDescriptor instead')
const TypeDefinition$json = {
  '1': 'TypeDefinition',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'descriptor',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.DescriptorProto',
      '10': 'descriptor'
    },
    {
      '1': 'type_params',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.TypeParameter',
      '10': 'typeParams'
    },
    {'1': 'description', '3': 4, '4': 1, '5': 9, '10': 'description'},
    {
      '1': 'metadata',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `TypeDefinition`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List typeDefinitionDescriptor = $convert.base64Decode(
    'Cg5UeXBlRGVmaW5pdGlvbhISCgRuYW1lGAEgASgJUgRuYW1lEkAKCmRlc2NyaXB0b3IYAiABKA'
    'syIC5nb29nbGUucHJvdG9idWYuRGVzY3JpcHRvclByb3RvUgpkZXNjcmlwdG9yEjcKC3R5cGVf'
    'cGFyYW1zGAMgAygLMhYuYmFsbC52MS5UeXBlUGFyYW1ldGVyUgp0eXBlUGFyYW1zEiAKC2Rlc2'
    'NyaXB0aW9uGAQgASgJUgtkZXNjcmlwdGlvbhIzCghtZXRhZGF0YRgFIAEoCzIXLmdvb2dsZS5w'
    'cm90b2J1Zi5TdHJ1Y3RSCG1ldGFkYXRh');

@$core.Deprecated('Use typeAliasDescriptor instead')
const TypeAlias$json = {
  '1': 'TypeAlias',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'target_type', '3': 2, '4': 1, '5': 9, '10': 'targetType'},
    {
      '1': 'type_params',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.TypeParameter',
      '10': 'typeParams'
    },
    {
      '1': 'metadata',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `TypeAlias`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List typeAliasDescriptor = $convert.base64Decode(
    'CglUeXBlQWxpYXMSEgoEbmFtZRgBIAEoCVIEbmFtZRIfCgt0YXJnZXRfdHlwZRgCIAEoCVIKdG'
    'FyZ2V0VHlwZRI3Cgt0eXBlX3BhcmFtcxgDIAMoCzIWLmJhbGwudjEuVHlwZVBhcmFtZXRlclIK'
    'dHlwZVBhcmFtcxIzCghtZXRhZGF0YRgEIAEoCzIXLmdvb2dsZS5wcm90b2J1Zi5TdHJ1Y3RSCG'
    '1ldGFkYXRh');

@$core.Deprecated('Use constantDescriptor instead')
const Constant$json = {
  '1': 'Constant',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'type', '3': 2, '4': 1, '5': 9, '10': 'type'},
    {
      '1': 'value',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'value'
    },
    {
      '1': 'metadata',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `Constant`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List constantDescriptor = $convert.base64Decode(
    'CghDb25zdGFudBISCgRuYW1lGAEgASgJUgRuYW1lEhIKBHR5cGUYAiABKAlSBHR5cGUSKQoFdm'
    'FsdWUYAyABKAsyEy5iYWxsLnYxLkV4cHJlc3Npb25SBXZhbHVlEjMKCG1ldGFkYXRhGAQgASgL'
    'MhcuZ29vZ2xlLnByb3RvYnVmLlN0cnVjdFIIbWV0YWRhdGE=');

@$core.Deprecated('Use functionDefinitionDescriptor instead')
const FunctionDefinition$json = {
  '1': 'FunctionDefinition',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'input_type', '3': 2, '4': 1, '5': 9, '10': 'inputType'},
    {'1': 'output_type', '3': 3, '4': 1, '5': 9, '10': 'outputType'},
    {
      '1': 'body',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'body'
    },
    {'1': 'description', '3': 5, '4': 1, '5': 9, '10': 'description'},
    {'1': 'is_base', '3': 6, '4': 1, '5': 8, '10': 'isBase'},
    {
      '1': 'metadata',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `FunctionDefinition`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List functionDefinitionDescriptor = $convert.base64Decode(
    'ChJGdW5jdGlvbkRlZmluaXRpb24SEgoEbmFtZRgBIAEoCVIEbmFtZRIdCgppbnB1dF90eXBlGA'
    'IgASgJUglpbnB1dFR5cGUSHwoLb3V0cHV0X3R5cGUYAyABKAlSCm91dHB1dFR5cGUSJwoEYm9k'
    'eRgEIAEoCzITLmJhbGwudjEuRXhwcmVzc2lvblIEYm9keRIgCgtkZXNjcmlwdGlvbhgFIAEoCV'
    'ILZGVzY3JpcHRpb24SFwoHaXNfYmFzZRgGIAEoCFIGaXNCYXNlEjMKCG1ldGFkYXRhGAcgASgL'
    'MhcuZ29vZ2xlLnByb3RvYnVmLlN0cnVjdFIIbWV0YWRhdGE=');

@$core.Deprecated('Use expressionDescriptor instead')
const Expression$json = {
  '1': 'Expression',
  '2': [
    {
      '1': 'call',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.FunctionCall',
      '9': 0,
      '10': 'call'
    },
    {
      '1': 'literal',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Literal',
      '9': 0,
      '10': 'literal'
    },
    {
      '1': 'reference',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Reference',
      '9': 0,
      '10': 'reference'
    },
    {
      '1': 'field_access',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.FieldAccess',
      '9': 0,
      '10': 'fieldAccess'
    },
    {
      '1': 'message_creation',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.MessageCreation',
      '9': 0,
      '10': 'messageCreation'
    },
    {
      '1': 'block',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Block',
      '9': 0,
      '10': 'block'
    },
    {
      '1': 'lambda',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.FunctionDefinition',
      '9': 0,
      '10': 'lambda'
    },
  ],
  '8': [
    {'1': 'expr'},
  ],
};

/// Descriptor for `Expression`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List expressionDescriptor = $convert.base64Decode(
    'CgpFeHByZXNzaW9uEisKBGNhbGwYASABKAsyFS5iYWxsLnYxLkZ1bmN0aW9uQ2FsbEgAUgRjYW'
    'xsEiwKB2xpdGVyYWwYAiABKAsyEC5iYWxsLnYxLkxpdGVyYWxIAFIHbGl0ZXJhbBIyCglyZWZl'
    'cmVuY2UYAyABKAsyEi5iYWxsLnYxLlJlZmVyZW5jZUgAUglyZWZlcmVuY2USOQoMZmllbGRfYW'
    'NjZXNzGAQgASgLMhQuYmFsbC52MS5GaWVsZEFjY2Vzc0gAUgtmaWVsZEFjY2VzcxJFChBtZXNz'
    'YWdlX2NyZWF0aW9uGAUgASgLMhguYmFsbC52MS5NZXNzYWdlQ3JlYXRpb25IAFIPbWVzc2FnZU'
    'NyZWF0aW9uEiYKBWJsb2NrGAYgASgLMg4uYmFsbC52MS5CbG9ja0gAUgVibG9jaxI1CgZsYW1i'
    'ZGEYByABKAsyGy5iYWxsLnYxLkZ1bmN0aW9uRGVmaW5pdGlvbkgAUgZsYW1iZGFCBgoEZXhwcg'
    '==');

@$core.Deprecated('Use functionCallDescriptor instead')
const FunctionCall$json = {
  '1': 'FunctionCall',
  '2': [
    {'1': 'module', '3': 1, '4': 1, '5': 9, '10': 'module'},
    {'1': 'function', '3': 2, '4': 1, '5': 9, '10': 'function'},
    {
      '1': 'input',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'input'
    },
  ],
};

/// Descriptor for `FunctionCall`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List functionCallDescriptor = $convert.base64Decode(
    'CgxGdW5jdGlvbkNhbGwSFgoGbW9kdWxlGAEgASgJUgZtb2R1bGUSGgoIZnVuY3Rpb24YAiABKA'
    'lSCGZ1bmN0aW9uEikKBWlucHV0GAMgASgLMhMuYmFsbC52MS5FeHByZXNzaW9uUgVpbnB1dA==');

@$core.Deprecated('Use literalDescriptor instead')
const Literal$json = {
  '1': 'Literal',
  '2': [
    {'1': 'int_value', '3': 1, '4': 1, '5': 3, '9': 0, '10': 'intValue'},
    {'1': 'double_value', '3': 2, '4': 1, '5': 1, '9': 0, '10': 'doubleValue'},
    {'1': 'string_value', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'stringValue'},
    {'1': 'bool_value', '3': 4, '4': 1, '5': 8, '9': 0, '10': 'boolValue'},
    {'1': 'bytes_value', '3': 5, '4': 1, '5': 12, '9': 0, '10': 'bytesValue'},
    {
      '1': 'list_value',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.ListLiteral',
      '9': 0,
      '10': 'listValue'
    },
  ],
  '8': [
    {'1': 'value'},
  ],
};

/// Descriptor for `Literal`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List literalDescriptor = $convert.base64Decode(
    'CgdMaXRlcmFsEh0KCWludF92YWx1ZRgBIAEoA0gAUghpbnRWYWx1ZRIjCgxkb3VibGVfdmFsdW'
    'UYAiABKAFIAFILZG91YmxlVmFsdWUSIwoMc3RyaW5nX3ZhbHVlGAMgASgJSABSC3N0cmluZ1Zh'
    'bHVlEh8KCmJvb2xfdmFsdWUYBCABKAhIAFIJYm9vbFZhbHVlEiEKC2J5dGVzX3ZhbHVlGAUgAS'
    'gMSABSCmJ5dGVzVmFsdWUSNQoKbGlzdF92YWx1ZRgGIAEoCzIULmJhbGwudjEuTGlzdExpdGVy'
    'YWxIAFIJbGlzdFZhbHVlQgcKBXZhbHVl');

@$core.Deprecated('Use listLiteralDescriptor instead')
const ListLiteral$json = {
  '1': 'ListLiteral',
  '2': [
    {
      '1': 'elements',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'elements'
    },
  ],
};

/// Descriptor for `ListLiteral`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List listLiteralDescriptor = $convert.base64Decode(
    'CgtMaXN0TGl0ZXJhbBIvCghlbGVtZW50cxgBIAMoCzITLmJhbGwudjEuRXhwcmVzc2lvblIIZW'
    'xlbWVudHM=');

@$core.Deprecated('Use referenceDescriptor instead')
const Reference$json = {
  '1': 'Reference',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
  ],
};

/// Descriptor for `Reference`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List referenceDescriptor =
    $convert.base64Decode('CglSZWZlcmVuY2USEgoEbmFtZRgBIAEoCVIEbmFtZQ==');

@$core.Deprecated('Use fieldAccessDescriptor instead')
const FieldAccess$json = {
  '1': 'FieldAccess',
  '2': [
    {
      '1': 'object',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'object'
    },
    {'1': 'field', '3': 2, '4': 1, '5': 9, '10': 'field'},
  ],
};

/// Descriptor for `FieldAccess`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fieldAccessDescriptor = $convert.base64Decode(
    'CgtGaWVsZEFjY2VzcxIrCgZvYmplY3QYASABKAsyEy5iYWxsLnYxLkV4cHJlc3Npb25SBm9iam'
    'VjdBIUCgVmaWVsZBgCIAEoCVIFZmllbGQ=');

@$core.Deprecated('Use messageCreationDescriptor instead')
const MessageCreation$json = {
  '1': 'MessageCreation',
  '2': [
    {'1': 'type_name', '3': 1, '4': 1, '5': 9, '10': 'typeName'},
    {
      '1': 'fields',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.FieldValuePair',
      '10': 'fields'
    },
  ],
};

/// Descriptor for `MessageCreation`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List messageCreationDescriptor = $convert.base64Decode(
    'Cg9NZXNzYWdlQ3JlYXRpb24SGwoJdHlwZV9uYW1lGAEgASgJUgh0eXBlTmFtZRIvCgZmaWVsZH'
    'MYAiADKAsyFy5iYWxsLnYxLkZpZWxkVmFsdWVQYWlyUgZmaWVsZHM=');

@$core.Deprecated('Use fieldValuePairDescriptor instead')
const FieldValuePair$json = {
  '1': 'FieldValuePair',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'value',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'value'
    },
  ],
};

/// Descriptor for `FieldValuePair`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fieldValuePairDescriptor = $convert.base64Decode(
    'Cg5GaWVsZFZhbHVlUGFpchISCgRuYW1lGAEgASgJUgRuYW1lEikKBXZhbHVlGAIgASgLMhMuYm'
    'FsbC52MS5FeHByZXNzaW9uUgV2YWx1ZQ==');

@$core.Deprecated('Use blockDescriptor instead')
const Block$json = {
  '1': 'Block',
  '2': [
    {
      '1': 'statements',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.ball.v1.Statement',
      '10': 'statements'
    },
    {
      '1': 'result',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'result'
    },
  ],
};

/// Descriptor for `Block`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List blockDescriptor = $convert.base64Decode(
    'CgVCbG9jaxIyCgpzdGF0ZW1lbnRzGAEgAygLMhIuYmFsbC52MS5TdGF0ZW1lbnRSCnN0YXRlbW'
    'VudHMSKwoGcmVzdWx0GAIgASgLMhMuYmFsbC52MS5FeHByZXNzaW9uUgZyZXN1bHQ=');

@$core.Deprecated('Use statementDescriptor instead')
const Statement$json = {
  '1': 'Statement',
  '2': [
    {
      '1': 'let',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.LetBinding',
      '9': 0,
      '10': 'let'
    },
    {
      '1': 'expression',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '9': 0,
      '10': 'expression'
    },
  ],
  '8': [
    {'1': 'stmt'},
  ],
};

/// Descriptor for `Statement`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List statementDescriptor = $convert.base64Decode(
    'CglTdGF0ZW1lbnQSJwoDbGV0GAEgASgLMhMuYmFsbC52MS5MZXRCaW5kaW5nSABSA2xldBI1Cg'
    'pleHByZXNzaW9uGAIgASgLMhMuYmFsbC52MS5FeHByZXNzaW9uSABSCmV4cHJlc3Npb25CBgoE'
    'c3RtdA==');

@$core.Deprecated('Use letBindingDescriptor instead')
const LetBinding$json = {
  '1': 'LetBinding',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'value',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.ball.v1.Expression',
      '10': 'value'
    },
    {
      '1': 'metadata',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.google.protobuf.Struct',
      '10': 'metadata'
    },
  ],
};

/// Descriptor for `LetBinding`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List letBindingDescriptor = $convert.base64Decode(
    'CgpMZXRCaW5kaW5nEhIKBG5hbWUYASABKAlSBG5hbWUSKQoFdmFsdWUYAiABKAsyEy5iYWxsLn'
    'YxLkV4cHJlc3Npb25SBXZhbHVlEjMKCG1ldGFkYXRhGAMgASgLMhcuZ29vZ2xlLnByb3RvYnVm'
    'LlN0cnVjdFIIbWV0YWRhdGE=');
