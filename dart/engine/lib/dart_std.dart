/// Dart-specific `dart_std` base module builder.
///
/// The `dart_std` module defines Dart language constructs that are not
/// universally available in all target languages. Each target language
/// compiler provides its own language-specific base module.
///
/// For the universal `std` module, see `package:ball_base/std.dart`.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:ball_base/gen/google/protobuf/descriptor.pb.dart' as google;

/// Builds the Dart-specific base module with Dart-only constructs.
Module buildDartStdModule() {
  final module = Module()
    ..name = 'dart_std'
    ..description =
        'Dart-specific standard library base module. Functions here represent '
        'Dart language constructs that are not universally available in all '
        'target languages. Each target language compiler provides its own '
        'language-specific base module.';

  // ============================================================
  // Types (input message types for Dart-specific functions)
  // ============================================================

  module.types.addAll([
    _type('NullAwareAccessInput', [
      _exprField('target', 1),
      _stringField('field', 2),
    ]),
    _type('NullAwareCallInput', [
      _exprField('target', 1),
      _stringField('method', 2),
      _fieldValuePairListField('args', 3),
    ]),
    _type('InvokeInput', [
      _exprField('callee', 1),
      _fieldValuePairListField('args', 2),
    ]),
    _type('CascadeInput', [
      _exprField('target', 1),
      _exprListField('sections', 2),
    ]),
    _type('MapCreateInput', [
      _fieldValuePairListField('entries', 1),
    ]),
    _type('SetCreateInput', [
      _exprListField('elements', 1),
    ]),
    _type('RecordInput', [
      _fieldValuePairListField('fields', 1),
    ]),
    _type('CollectionIfInput', [
      _exprField('condition', 1),
      _exprField('then', 2),
      _exprField('else', 3),
    ]),
    _type('CollectionForInput', [
      _stringField('variable', 1),
      _exprField('iterable', 2),
      _exprField('body', 3),
    ]),
    _type('SwitchExprInput', [
      _exprField('subject', 1),
      _exprListField('cases', 2),
    ]),
    _type('SwitchExprCase', [
      _stringField('pattern', 1),
      _exprField('body', 2),
    ]),
    _type('SymbolInput', [
      _stringField('value', 1),
    ]),
    _type('TypeLiteralInput', [
      _stringField('type', 1),
    ]),
    _type('LabeledInput', [
      _stringField('label', 1),
      _exprField('body', 2),
    ]),
  ]);

  // ============================================================
  // Functions — Dart-specific
  // ============================================================

  module.functions.addAll([
    // --- Null-aware ---
    _fn('null_aware_access', 'NullAwareAccessInput', '',
        'Null-aware access. Dart: target?.field'),
    _fn('null_aware_call', 'NullAwareCallInput', '',
        'Null-aware call. Dart: target?.method(args)'),

    // --- Cascade ---
    _fn('cascade', 'CascadeInput', '',
        'Cascade operator. Dart: target..a()..b()'),

    // --- Spread ---
    _fn('spread', 'UnaryInput', '', 'Spread element. Dart: ...value'),
    _fn('null_spread', 'UnaryInput', '',
        'Null-aware spread. Dart: ...?value'),

    // --- Invocation ---
    _fn('invoke', 'InvokeInput', '',
        'Invoke a callable expression. Dart: callee(args)'),

    // --- Collection construction ---
    _fn('map_create', 'MapCreateInput', '',
        'Create map literal. Dart: {key: value, ...}'),
    _fn('set_create', 'SetCreateInput', '',
        'Create set literal. Dart: {element, ...}'),
    _fn('record', 'RecordInput', '',
        'Create record. Dart: (positional, named: value)'),
    _fn('collection_if', 'CollectionIfInput', '',
        'Collection if. Dart: [if (cond) then else else]'),
    _fn('collection_for', 'CollectionForInput', '',
        'Collection for. Dart: [for (var x in iter) body]'),

    // --- Switch expression ---
    _fn('switch_expr', 'SwitchExprInput', '',
        'Switch expression (Dart 3+). Dart: subj switch { pattern => expr }'),

    // --- Literals ---
    _fn('symbol', 'SymbolInput', '',
        'Symbol literal. Dart: #symbolName'),
    _fn('type_literal', 'TypeLiteralInput', '',
        'Type literal expression. Dart: int, String as expressions'),

    // --- Labels ---
    _fn('labeled', 'LabeledInput', '',
        'Labeled statement. Dart: label: statement'),

    // --- Generators ---
    _fn('yield_each', 'UnaryInput', '',
        'Yield all from iterable. Dart: yield* value'),
  ]);

  return module;
}

// ============================================================
// Helpers — build protobuf descriptor fields
// ============================================================

const _exprTypeName = '.ball.v1.Expression';
const _fieldValuePairTypeName = '.ball.v1.FieldValuePair';

google.DescriptorProto _type(
  String name,
  List<google.FieldDescriptorProto> fields,
) =>
    google.DescriptorProto()
      ..name = name
      ..field.addAll(fields);

google.FieldDescriptorProto _exprField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_MESSAGE
      ..typeName = _exprTypeName
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

google.FieldDescriptorProto _exprListField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_MESSAGE
      ..typeName = _exprTypeName
      ..label = google.FieldDescriptorProto_Label.LABEL_REPEATED;

google.FieldDescriptorProto _stringField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_STRING
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

google.FieldDescriptorProto _fieldValuePairListField(
  String name,
  int number,
) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_MESSAGE
      ..typeName = _fieldValuePairTypeName
      ..label = google.FieldDescriptorProto_Label.LABEL_REPEATED;

FunctionDefinition _fn(
  String name,
  String inputType,
  String outputType,
  String description,
) =>
    FunctionDefinition()
      ..name = name
      ..inputType = inputType
      ..outputType = outputType
      ..isBase = true
      ..description = description;
