/// Universal `std` base module builder for the ball programming language.
///
/// The `std` module defines language-agnostic operations that **every** target
/// language compiler implements natively: arithmetic, comparison, logical,
/// control flow, error handling, etc.
///
/// This file is the single source of truth for the universal base. Each
/// language-specific compiler (Dart, Go, Python, …) adds its own extension
/// module (e.g. `dart_std`, `go_std`) on top of `std`.
library;

import 'gen/google/protobuf/descriptor.pb.dart' as google;
import 'gen/ball/v1/ball.pb.dart';

/// Builds the universal std base module with language-agnostic types and functions.
Module buildStdModule() {
  final module = Module()
    ..name = 'std'
    ..description =
        'Universal standard library base module. Every function here '
        'represents a language-agnostic operation that all target languages '
        'implement natively. Types use protobuf descriptors so they map to '
        'every target language.';

  // ============================================================
  // Types (input message types for universal base functions)
  // ============================================================

  module.types.addAll([
    _type('BinaryInput', [_exprField('left', 1), _exprField('right', 2)]),
    _type('UnaryInput', [_exprField('value', 1)]),
    _type('PrintInput', [_stringField('message', 1)]),
    _type('IfInput', [
      _exprField('condition', 1),
      _exprField('then', 2),
      _exprField('else', 3),
      _stringField('case_pattern', 4),
    ]),
    _type('ForInput', [
      _exprField('init', 1),
      _exprField('condition', 2),
      _exprField('update', 3),
      _exprField('body', 4),
    ]),
    _type('ForInInput', [
      _stringField('variable', 1),
      _stringField('variable_type', 2),
      _exprField('iterable', 3),
      _exprField('body', 4),
    ]),
    _type('WhileInput', [_exprField('condition', 1), _exprField('body', 2)]),
    _type('DoWhileInput', [_exprField('body', 1), _exprField('condition', 2)]),
    _type('SwitchInput', [
      _exprField('subject', 1),
      _exprListField('cases', 2),
    ]),
    _type('SwitchCase', [
      _exprField('value', 1),
      _boolField('is_default', 2),
      _exprField('body', 3),
      _stringField('pattern', 4),
    ]),
    _type('TryInput', [
      _exprField('body', 1),
      _exprListField('catches', 2),
      _exprField('finally', 3),
    ]),
    _type('CatchClause', [
      _stringField('type', 1),
      _stringField('variable', 2),
      _stringField('stack_trace', 3),
      _exprField('body', 4),
    ]),
    _type('AssertInput', [
      _exprField('condition', 1),
      _exprField('message', 2),
    ]),
    _type('AssignInput', [
      _exprField('target', 1),
      _exprField('value', 2),
      _stringField('op', 3),
    ]),
    _type('IndexInput', [_exprField('target', 1), _exprField('index', 2)]),
    _type('TypeCheckInput', [_exprField('value', 1), _stringField('type', 2)]),
    _type('BreakInput', [_stringField('label', 1)]),
    _type('ContinueInput', [_stringField('label', 1)]),
    _type('ReturnInput', [_exprField('value', 1)]),

    // --- String operation input types ---
    _type('StringSubstringInput', [
      _exprField('value', 1),
      _exprField('start', 2),
      _exprField('end', 3),
    ]),
    _type('StringReplaceInput', [
      _exprField('value', 1),
      _exprField('from', 2),
      _exprField('to', 3),
    ]),
    _type('StringRepeatInput', [
      _exprField('value', 1),
      _exprField('count', 2),
    ]),
    _type('StringPadInput', [
      _exprField('value', 1),
      _exprField('width', 2),
      _exprField('padding', 3),
    ]),

    // --- Math input types ---
    _type('MathClampInput', [
      _exprField('value', 1),
      _exprField('min', 2),
      _exprField('max', 3),
    ]),
  ]);

  // ============================================================
  // Functions — universal, language-agnostic
  // ============================================================

  module.functions.addAll([
    // --- I/O ---
    _fn('print', 'PrintInput', '', 'Print to stdout: print(message)'),

    // --- Arithmetic ---
    _fn('add', 'BinaryInput', '', 'Addition: left + right'),
    _fn('subtract', 'BinaryInput', '', 'Subtraction: left - right'),
    _fn('multiply', 'BinaryInput', '', 'Multiplication: left * right'),
    _fn('divide', 'BinaryInput', '', 'Integer division: left ~/ right'),
    _fn('divide_double', 'BinaryInput', '', 'Double division: left / right'),
    _fn('modulo', 'BinaryInput', '', 'Modulo: left % right'),
    _fn('negate', 'UnaryInput', '', 'Unary negation: -value'),

    // --- Comparison ---
    _fn('equals', 'BinaryInput', '', 'Equality: left == right'),
    _fn('not_equals', 'BinaryInput', '', 'Inequality: left != right'),
    _fn('less_than', 'BinaryInput', '', 'Less than: left < right'),
    _fn('greater_than', 'BinaryInput', '', 'Greater than: left > right'),
    _fn('lte', 'BinaryInput', '', 'Less or equal: left <= right'),
    _fn('gte', 'BinaryInput', '', 'Greater or equal: left >= right'),

    // --- Logical ---
    _fn('and', 'BinaryInput', '', 'Logical AND: left && right'),
    _fn('or', 'BinaryInput', '', 'Logical OR: left || right'),
    _fn('not', 'UnaryInput', '', 'Logical NOT: !value'),

    // --- Bitwise ---
    _fn('bitwise_and', 'BinaryInput', '', 'Bitwise AND: left & right'),
    _fn('bitwise_or', 'BinaryInput', '', 'Bitwise OR: left | right'),
    _fn('bitwise_xor', 'BinaryInput', '', 'Bitwise XOR: left ^ right'),
    _fn('bitwise_not', 'UnaryInput', '', 'Bitwise NOT: ~value'),
    _fn('left_shift', 'BinaryInput', '', 'Left shift: left << right'),
    _fn('right_shift', 'BinaryInput', '', 'Right shift: left >> right'),
    _fn(
      'unsigned_right_shift',
      'BinaryInput',
      '',
      'Unsigned right shift: left >>> right',
    ),

    // --- Increment/Decrement ---
    _fn('pre_increment', 'UnaryInput', '', 'Prefix increment: ++value'),
    _fn('pre_decrement', 'UnaryInput', '', 'Prefix decrement: --value'),
    _fn('post_increment', 'UnaryInput', '', 'Postfix increment: value++'),
    _fn('post_decrement', 'UnaryInput', '', 'Postfix decrement: value--'),

    // --- String & Conversion ---
    _fn(
      'concat',
      'BinaryInput',
      '',
      'String concatenation: left + right (strings)',
    ),
    _fn('to_string', 'UnaryInput', '', 'Convert to string: value.toString()'),
    _fn('length', 'UnaryInput', '', 'Get length: value.length'),
    _fn('int_to_string', 'UnaryInput', '', 'Int to string: value.toString()'),
    _fn(
      'double_to_string',
      'UnaryInput',
      '',
      'Double to string: value.toString()',
    ),
    _fn(
      'string_to_int',
      'UnaryInput',
      '',
      'Parse int from string: int.parse(value)',
    ),
    _fn(
      'string_to_double',
      'UnaryInput',
      '',
      'Parse double from string: double.parse(value)',
    ),

    // --- Null safety ---
    _fn('null_coalesce', 'BinaryInput', '', 'Null coalescing: left ?? right'),
    _fn('null_check', 'UnaryInput', '', 'Null assertion: value!'),

    // --- Control flow ---
    _fn('if', 'IfInput', '', 'Conditional: if (cond) { then } else { else }'),
    _fn(
      'for',
      'ForInput',
      '',
      'C-style for loop: for (init; cond; update) { body }',
    ),
    _fn(
      'for_in',
      'ForInInput',
      '',
      'For-in loop: for (var x in iterable) { body }',
    ),
    _fn('while', 'WhileInput', '', 'While loop: while (cond) { body }'),
    _fn(
      'do_while',
      'DoWhileInput',
      '',
      'Do-while loop: do { body } while (cond)',
    ),
    _fn(
      'switch',
      'SwitchInput',
      '',
      'Switch statement: switch (subj) { case ... }',
    ),

    // --- Error handling ---
    _fn(
      'try',
      'TryInput',
      '',
      'Try-catch-finally: try { } catch (e) { } finally { }',
    ),
    _fn('throw', 'UnaryInput', '', 'Throw exception: throw value'),
    _fn('rethrow', '', '', 'Rethrow current exception: rethrow'),

    // --- Assertions ---
    _fn('assert', 'AssertInput', '', 'Debug assertion: assert(cond, msg)'),

    // --- Flow control ---
    _fn('return', 'ReturnInput', '', 'Return from function: return value'),
    _fn('break', 'BreakInput', '', 'Break from loop/switch: break [label]'),
    _fn(
      'continue',
      'ContinueInput',
      '',
      'Continue to next iteration: continue [label]',
    ),

    // --- Generators & async ---
    _fn('yield', 'UnaryInput', '', 'Yield from generator: yield value'),
    _fn('await', 'UnaryInput', '', 'Await a future: await value'),

    // --- Assignment ---
    _fn(
      'assign',
      'AssignInput',
      '',
      'Assignment (simple or compound): target = value, target += value',
    ),

    // --- Type operations ---
    _fn('is', 'TypeCheckInput', '', 'Type test: value is Type'),
    _fn('is_not', 'TypeCheckInput', '', 'Negated type test: value is! Type'),
    _fn('as', 'TypeCheckInput', '', 'Type cast: value as Type'),

    // --- Indexing ---
    _fn('index', 'IndexInput', '', 'Index access: target[index]'),

    // --- Strings (pure manipulation, no I/O, universal) ---
    _fn('string_length', 'UnaryInput', '', 'String length: value.length'),
    _fn('string_is_empty', 'UnaryInput', '', 'Is string empty: value.isEmpty'),
    _fn('string_concat', 'BinaryInput', '', 'String concat: left + right'),
    _fn('string_contains', 'BinaryInput', '',
        'String contains: left.contains(right)'),
    _fn('string_starts_with', 'BinaryInput', '',
        'Starts with: left.startsWith(right)'),
    _fn('string_ends_with', 'BinaryInput', '',
        'Ends with: left.endsWith(right)'),
    _fn('string_index_of', 'BinaryInput', '',
        'Index of substring: left.indexOf(right)'),
    _fn('string_last_index_of', 'BinaryInput', '',
        'Last index of: left.lastIndexOf(right)'),
    _fn('string_substring', 'StringSubstringInput', '',
        'Substring: value.substring(start, end)'),
    _fn('string_char_at', 'IndexInput', '',
        'Character at index: target[index]'),
    _fn('string_char_code_at', 'IndexInput', '',
        'Char code at index: target.codeUnitAt(index)'),
    _fn('string_from_char_code', 'UnaryInput', '',
        'String from char code: String.fromCharCode(value)'),
    _fn('string_to_upper', 'UnaryInput', '',
        'To upper case: value.toUpperCase()'),
    _fn('string_to_lower', 'UnaryInput', '',
        'To lower case: value.toLowerCase()'),
    _fn('string_trim', 'UnaryInput', '', 'Trim whitespace: value.trim()'),
    _fn('string_trim_start', 'UnaryInput', '',
        'Trim start: value.trimLeft()'),
    _fn('string_trim_end', 'UnaryInput', '', 'Trim end: value.trimRight()'),
    _fn('string_replace', 'StringReplaceInput', '',
        'Replace first: value.replaceFirst(from, to)'),
    _fn('string_replace_all', 'StringReplaceInput', '',
        'Replace all: value.replaceAll(from, to)'),
    _fn('string_split', 'BinaryInput', '',
        'Split string: left.split(right)'),
    _fn('string_repeat', 'StringRepeatInput', '',
        'Repeat string: value * count'),
    _fn('string_pad_left', 'StringPadInput', '',
        'Pad left: value.padLeft(width, padding)'),
    _fn('string_pad_right', 'StringPadInput', '',
        'Pad right: value.padRight(width, padding)'),

    // --- Regex (universal) ---
    _fn('regex_match', 'BinaryInput', '',
        'Regex match: RegExp(right).hasMatch(left)'),
    _fn('regex_find', 'BinaryInput', '',
        'Regex find first: RegExp(right).firstMatch(left)?.group(0)'),
    _fn('regex_find_all', 'BinaryInput', '',
        'Regex find all: RegExp(right).allMatches(left).map(m => m.group(0))'),
    _fn('regex_replace', 'StringReplaceInput', '',
        'Regex replace first: value.replaceFirst(RegExp(from), to)'),
    _fn('regex_replace_all', 'StringReplaceInput', '',
        'Regex replace all: value.replaceAll(RegExp(from), to)'),

    // --- Math (pure numeric, universal) ---
    _fn('math_abs', 'UnaryInput', '', 'Absolute value: value.abs()'),
    _fn('math_floor', 'UnaryInput', '', 'Floor: value.floor()'),
    _fn('math_ceil', 'UnaryInput', '', 'Ceiling: value.ceil()'),
    _fn('math_round', 'UnaryInput', '', 'Round: value.round()'),
    _fn('math_trunc', 'UnaryInput', '', 'Truncate: value.truncate()'),
    _fn('math_sqrt', 'UnaryInput', '', 'Square root: sqrt(value)'),
    _fn('math_pow', 'BinaryInput', '', 'Power: pow(left, right)'),
    _fn('math_log', 'UnaryInput', '', 'Natural log: log(value)'),
    _fn('math_log2', 'UnaryInput', '', 'Log base 2: log2(value)'),
    _fn('math_log10', 'UnaryInput', '', 'Log base 10: log10(value)'),
    _fn('math_exp', 'UnaryInput', '', 'Exponential: exp(value)'),
    _fn('math_sin', 'UnaryInput', '', 'Sine: sin(value)'),
    _fn('math_cos', 'UnaryInput', '', 'Cosine: cos(value)'),
    _fn('math_tan', 'UnaryInput', '', 'Tangent: tan(value)'),
    _fn('math_asin', 'UnaryInput', '', 'Arc sine: asin(value)'),
    _fn('math_acos', 'UnaryInput', '', 'Arc cosine: acos(value)'),
    _fn('math_atan', 'UnaryInput', '', 'Arc tangent: atan(value)'),
    _fn('math_atan2', 'BinaryInput', '', 'Arc tangent 2: atan2(left, right)'),
    _fn('math_min', 'BinaryInput', '', 'Minimum: min(left, right)'),
    _fn('math_max', 'BinaryInput', '', 'Maximum: max(left, right)'),
    _fn('math_clamp', 'MathClampInput', '',
        'Clamp: value.clamp(min, max)'),
    _fn('math_pi', '', '', 'Constant: pi'),
    _fn('math_e', '', '', 'Constant: e'),
    _fn('math_infinity', '', '', 'Constant: infinity'),
    _fn('math_nan', '', '', 'Constant: NaN'),
    _fn('math_is_nan', 'UnaryInput', '', 'Is NaN: value.isNaN'),
    _fn('math_is_finite', 'UnaryInput', '', 'Is finite: value.isFinite'),
    _fn('math_is_infinite', 'UnaryInput', '',
        'Is infinite: value.isInfinite'),
    _fn('math_sign', 'UnaryInput', '', 'Sign: value.sign'),
    _fn('math_gcd', 'BinaryInput', '', 'GCD: gcd(left, right)'),
    _fn('math_lcm', 'BinaryInput', '', 'LCM: lcm(left, right)'),
  ]);

  return module;
}

// ============================================================
// Helpers — build protobuf descriptor fields
// ============================================================

const _exprTypeName = '.ball.v1.Expression';

google.DescriptorProto _type(
  String name,
  List<google.FieldDescriptorProto> fields,
) => google.DescriptorProto()
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

google.FieldDescriptorProto _boolField(String name, int number) =>
    google.FieldDescriptorProto()
      ..name = name
      ..number = number
      ..type = google.FieldDescriptorProto_Type.TYPE_BOOL
      ..label = google.FieldDescriptorProto_Label.LABEL_OPTIONAL;

FunctionDefinition _fn(
  String name,
  String inputType,
  String outputType,
  String description,
) => FunctionDefinition()
  ..name = name
  ..inputType = inputType
  ..outputType = outputType
  ..isBase = true
  ..description = description;
