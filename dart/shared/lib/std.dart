/// Universal `std` base module builder for the ball programming language.
///
/// The `std` module defines language-agnostic operations that **every** target
/// language compiler implements natively: arithmetic, comparison, logical,
/// control flow, error handling, etc.
///
/// This file is the single source of truth for the universal base. Each
/// language-specific compiler (Dart, Go, Python, …) adds its own extension
/// module on top of `std`.
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

  module.typeDefs.addAll(
    <google.DescriptorProto>[
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
      _type('DoWhileInput', [
        _exprField('body', 1),
        _exprField('condition', 2),
      ]),
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
      _type('TypeCheckInput', [
        _exprField('value', 1),
        _stringField('type', 2),
      ]),
      _type('BreakInput', [_stringField('label', 1)]),
      _type('ContinueInput', [_stringField('label', 1)]),
      _type('ReturnInput', [_exprField('value', 1)]),
      _type('GotoInput', [_stringField('label', 1)]),
      _type('LabelInput', [_stringField('name', 1), _exprField('body', 2)]),

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
      _type('CompareToInput', [_exprField('value', 1), _exprField('other', 2)]),
      // Shared by to_string_as_fixed / to_string_as_exponential (both take
      // `digits`) and to_string_as_precision (`precision`), mirroring how
      // ListInput/MapInput serve a family of related operations.
      _type('NumFormatInput', [
        _exprField('value', 1),
        _exprField('digits', 2),
        _exprField('precision', 3),
      ]),
      _type('MathClampInput', [
        _exprField('value', 1),
        _exprField('min', 2),
        _exprField('max', 3),
      ]),

      // --- Text-sink input types (issue #630) ---
      // A sink is an opaque runtime value, so `sink` is an ordinary expression
      // field (the same shape `UnaryInput.value` uses) rather than a described
      // message. `initial` is optional: absent means an empty sink.
      _type('SinkCreateInput', [_exprField('initial', 1)]),
      _type('SinkWriteInput', [_exprField('sink', 1), _exprField('text', 2)]),
      _type('SinkToStringInput', [_exprField('sink', 1)]),

      // --- Language-construct input types (issue #702) ---
      //
      // Every type below describes a construct the engines have always
      // dispatched and the encoders have always emitted, while no builder
      // declared it — so `std.json` could not list it and no target had a
      // machine-readable contract to implement. Field names are the ones the
      // reference engine (`dart/engine/lib/engine_std.dart`) reads and the
      // encoders write; alternative spellings each handler also accepts are
      // named in the FUNCTION description rather than declared as extra
      // fields, so the descriptor stays the canonical shape.

      // `..` / `?..`. `sections` carries the cascade sections as a list
      // literal; `null_aware` distinguishes `?..` from `..`.
      _type('CascadeInput', [
        _exprField('target', 1),
        _exprField('sections', 2),
        _boolField('null_aware', 3),
      ]),
      _type('NullAwareAccessInput', [
        _exprField('target', 1),
        _stringField('field', 2),
      ]),
      // `target?.method(args)`. The arguments are the input's REMAINING
      // fields (`arg0`, `arg1`, … / named), exactly as an ordinary call
      // carries them — the same open-argument shape `InvokeInput` uses.
      _type('NullAwareCallInput', [
        _exprField('target', 1),
        _stringField('method', 2),
      ]),
      // `callee(args)` where `callee` is an expression. The arguments are the
      // input's remaining fields; a lone argument is passed to the callee
      // directly rather than wrapped.
      _type('InvokeInput', [_exprField('callee', 1)]),
      // A function VALUE, either named directly (`callback`) or as
      // `target`.`method`.
      _type('TearOffInput', [
        _exprField('callback', 1),
        _exprField('target', 2),
        _stringField('method', 3),
      ]),
      _type('SymbolInput', [_stringField('value', 1)]),
      _type('TypeLiteralInput', [_stringField('type', 1)]),
      // `label: <statement>` — distinct from `LabelInput` (`std.label`), whose
      // name field is `name`.
      _type('LabeledInput', [_stringField('label', 1), _exprField('body', 2)]),
      // `<T>[a, b]` — `elements` is one expression holding the list literal.
      _type('TypedListInput', [
        _stringField('type_args', 1),
        _exprField('elements', 2),
      ]),
      // A map literal. Each plain `key: value` pair arrives as its own
      // `entry` field (a `MapCreateEntry`); a spliceable comprehension
      // element (`collection_if` / `collection_for`) arrives as `element`.
      _type('MapCreateInput', [
        _stringField('type_args', 1),
        _exprListField('entry', 2),
        _exprListField('element', 3),
      ]),
      _type('MapCreateEntry', [_exprField('key', 1), _exprField('value', 2)]),
      // A record literal `(a, b, name: c)`. Its components ARE the input's
      // own fields — positional ones named `$1`, `$2`, … (1-based, matching
      // Dart's `record.$1`) and named ones by their own name — so the
      // descriptor declares only the alternative single-message form.
      _type('RecordInput', [_exprField('fields', 1)]),
      // A `for` element inside a collection literal. Carries EITHER the
      // for-each form (`variable` + `iterable`) or the C-style form
      // (`init` + `condition` + `update`); `body` is common to both.
      _type('CollectionForInput', [
        _stringField('variable', 1),
        _exprField('iterable', 2),
        _exprField('init', 3),
        _exprField('condition', 4),
        _exprField('update', 5),
        _exprField('body', 6),
      ]),
      // A switch EXPRESSION. `cases` is one expression holding a list of
      // `SwitchExprCase`, which is not `SwitchCase`: a switch expression
      // carries a structured `pattern_expr` and a `when` `guard`.
      _type('SwitchExprInput', [
        _exprField('subject', 1),
        _exprField('cases', 2),
      ]),
      _type('SwitchExprCase', [
        _stringField('pattern', 1),
        _exprField('body', 2),
        _exprField('pattern_expr', 3),
        _exprField('guard', 4),
        _boolField('is_default', 5),
      ]),
      _type('ListFilledInput', [
        _exprField('length', 1),
        _exprField('value', 2),
      ]),
      _type('ListGenerateInput', [
        _exprField('length', 1),
        _exprField('generator', 2),
      ]),
      // `'a${b}c'` — `parts` holds the alternating literal/expression pieces
      // as a list; each is stringified and concatenated in order.
      _type('StringInterpolationInput', [
        _exprField('parts', 1),
        _exprField('value', 2),
      ]),
    ].map(
      (d) => TypeDefinition()
        ..name = d.name
        ..descriptor = d,
    ),
  );

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
    _fn('to_double', 'UnaryInput', '', 'To double: value.toDouble()'),
    _fn('to_int', 'UnaryInput', '', 'To int: value.toInt()'),
    _fn(
      'int_to_double',
      'UnaryInput',
      '',
      'Int to double: value.toDouble() (statically an int)',
    ),
    _fn(
      'double_to_int',
      'UnaryInput',
      '',
      'Double to int, truncating toward zero: value.toInt()',
    ),
    _fn(
      'compare_to',
      'CompareToInput',
      '',
      'Three-way compare: value.compareTo(other)',
    ),
    _fn(
      'to_string_as_fixed',
      'NumFormatInput',
      '',
      'Fixed-point string: value.toStringAsFixed(digits)',
    ),
    _fn(
      'to_string_as_exponential',
      'NumFormatInput',
      '',
      'Exponential string: value.toStringAsExponential([digits])',
    ),
    _fn(
      'to_string_as_precision',
      'NumFormatInput',
      '',
      'Precision string: value.toStringAsPrecision(precision)',
    ),
    _fn(
      'ceil_to_double',
      'UnaryInput',
      '',
      'Ceiling as a double: value.ceilToDouble()',
    ),
    _fn(
      'floor_to_double',
      'UnaryInput',
      '',
      'Floor as a double: value.floorToDouble()',
    ),
    _fn(
      'round_to_double',
      'UnaryInput',
      '',
      'Round as a double: value.roundToDouble()',
    ),
    _fn(
      'truncate_to_double',
      'UnaryInput',
      '',
      'Truncate as a double: value.truncateToDouble()',
    ),

    // --- Null safety ---
    _fn('null_coalesce', 'BinaryInput', '', 'Null coalescing: left ?? right'),
    _fn('null_check', 'UnaryInput', '', 'Null assertion: value!'),
    _fn(
      'null_aware_access',
      'NullAwareAccessInput',
      '',
      'Null-aware field access: target?.field — null when target is null',
    ),
    _fn(
      'null_aware_call',
      'NullAwareCallInput',
      '',
      'Null-aware method call: target?.method(args) — null when target is '
          'null. The arguments are the input\'s remaining fields.',
    ),

    // --- Grouping ---
    //
    // Parentheses are SEMANTIC here, not cosmetic: the encoder emits `paren`
    // only where dropping them would change precedence, e.g.
    // `(x ??= []).add(y)` vs `x ??= [].add(y)`.
    _fn(
      'paren',
      'UnaryInput',
      '',
      'Parenthesized expression: (value) — preserves operator precedence',
    ),

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

    // --- goto / labels ---
    _fn('goto', 'GotoInput', '', 'Jump to label: goto label_name'),
    _fn(
      'label',
      'LabelInput',
      '',
      'Define a label point: label_name: { body }',
    ),
    _fn(
      'labeled',
      'LabeledInput',
      '',
      'Labeled statement: label: <body> — the target of a labelled '
          'break/continue',
    ),

    // --- Generators & async ---
    _fn('yield', 'UnaryInput', '', 'Yield from generator: yield value'),
    _fn(
      'yield_each',
      'UnaryInput',
      '',
      'Delegate to another generator: yield* value',
    ),
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
    _fn(
      'type_of',
      'UnaryInput',
      '',
      'Runtime type name: value.runtimeType.toString() / JS typeof. '
          'Returns the canonical base type name (int, double, String, bool, '
          "List, Map, Set, Function, Null, or a user class's short name) "
          'with generic type arguments dropped and any module prefix stripped.',
    ),

    _fn(
      'type_literal',
      'TypeLiteralInput',
      '',
      'A type used as a value: int, Box<int> — carries the type source text',
    ),

    // --- Indexing ---
    _fn('index', 'IndexInput', '', 'Index access: target[index]'),

    // --- Cascades (issue #702) ---
    _fn(
      'cascade',
      'CascadeInput',
      '',
      'Cascade: target..a()..b — evaluates each section against target and '
          'returns TARGET, not the last section',
    ),
    _fn(
      'null_aware_cascade',
      'CascadeInput',
      '',
      'Null-aware cascade: target?..a()..b — null when target is null',
    ),

    // --- Functions as values (issue #702) ---
    _fn(
      'invoke',
      'InvokeInput',
      '',
      'Call a function VALUE: callee(args). The arguments are the input\'s '
          'remaining fields; a single argument is passed through directly.',
    ),
    _fn(
      'tear_off',
      'TearOffInput',
      '',
      'Function tear-off: the function value named by callback, or by '
          'target.method — never invoked',
    ),

    // --- Literals the target cannot spell as a plain Literal (issue #702) ---
    _fn('symbol', 'SymbolInput', '', 'Symbol literal: #value'),
    _fn(
      'record',
      'RecordInput',
      '',
      'Record literal: (a, b, name: c). Positional components are the '
          'input\'s \$1, \$2, … fields (1-based, matching Dart\'s record.\$1) '
          'and named components carry their own name.',
    ),
    _fn(
      'typed_list',
      'TypedListInput',
      '',
      'List literal with explicit type arguments: <T>[elements]',
    ),
    _fn(
      'map_create',
      'MapCreateInput',
      '',
      'Map literal: {k: v, …}. Each plain pair is one `entry` field; a '
          'comprehension element is spliced through `element`.',
    ),
    _fn(
      'list_filled',
      'ListFilledInput',
      '',
      'Fixed-size list of one repeated value: List.filled(length, value). '
          'Engines also accept `count` for `length`.',
    ),
    _fn(
      'list_generate',
      'ListGenerateInput',
      '',
      'List built by index: List.generate(length, generator). Engines also '
          'accept `count` for `length` and `callback` for `generator`.',
    ),
    // Dart-flavoured aliases of the two above (same engine handler); a
    // `List.filled(...)` / `List.generate(...)` written as a CONSTRUCTOR call
    // routes here, while the encoder's collection-literal path emits the
    // unprefixed names.
    _fn(
      'dart_list_filled',
      'ListFilledInput',
      '',
      'List.filled(length, value) reached as a constructor call',
    ),
    _fn(
      'dart_list_generate',
      'ListGenerateInput',
      '',
      'List.generate(length, generator) reached as a constructor call',
    ),

    // --- Collection elements (issue #702) ---
    //
    // These four never stand alone: a list/set/map literal evaluator SPLICES
    // them into its elements. Dispatching one as an ordinary call is a bug,
    // and the reference engine throws rather than returning a placeholder
    // (the silent-degradation lesson of issue #55).
    _fn(
      'spread',
      'UnaryInput',
      '',
      'Spread element inside a collection literal: ...value',
    ),
    _fn(
      'null_spread',
      'UnaryInput',
      '',
      'Null-aware spread element: ...?value — contributes nothing when null',
    ),
    _fn(
      'collection_if',
      'IfInput',
      '',
      'Conditional element inside a collection literal: '
          '[if (condition) then else else]',
    ),
    _fn(
      'collection_for',
      'CollectionForInput',
      '',
      'Comprehension element inside a collection literal: '
          '[for (variable in iterable) body] / [for (init; condition; '
          'update) body]',
    ),

    // --- Switch expression (issue #702) ---
    _fn(
      'switch_expr',
      'SwitchExprInput',
      '',
      'Switch EXPRESSION: switch (subject) { pattern => body, … } — yields a '
          'value, unlike the std.switch statement',
    ),

    // --- Strings (pure manipulation, no I/O, universal) ---
    _fn('string_length', 'UnaryInput', '', 'String length: value.length'),
    _fn('string_is_empty', 'UnaryInput', '', 'Is string empty: value.isEmpty'),
    _fn('string_concat', 'BinaryInput', '', 'String concat: left + right'),
    _fn(
      'string_contains',
      'BinaryInput',
      '',
      'String contains: left.contains(right)',
    ),
    _fn(
      'string_starts_with',
      'BinaryInput',
      '',
      'Starts with: left.startsWith(right)',
    ),
    _fn(
      'string_ends_with',
      'BinaryInput',
      '',
      'Ends with: left.endsWith(right)',
    ),
    _fn(
      'string_index_of',
      'BinaryInput',
      '',
      'Index of substring: left.indexOf(right)',
    ),
    _fn(
      'string_last_index_of',
      'BinaryInput',
      '',
      'Last index of: left.lastIndexOf(right)',
    ),
    _fn(
      'string_substring',
      'StringSubstringInput',
      '',
      'Substring: value.substring(start, end)',
    ),
    _fn(
      'string_char_at',
      'IndexInput',
      '',
      'Character at index: target[index]',
    ),
    _fn(
      'string_char_code_at',
      'IndexInput',
      '',
      'Char code at index: target.codeUnitAt(index)',
    ),
    // Dart-flavoured alias of string_char_code_at (same engine handler); the
    // encoder routes `String.codeUnitAt(i)` here.
    _fn(
      'string_code_unit_at',
      'IndexInput',
      '',
      'Code unit at index: target.codeUnitAt(index)',
    ),
    _fn(
      'string_from_char_code',
      'UnaryInput',
      '',
      'String from char code: String.fromCharCode(value)',
    ),
    _fn(
      'string_to_upper',
      'UnaryInput',
      '',
      'To upper case: value.toUpperCase()',
    ),
    _fn(
      'string_to_lower',
      'UnaryInput',
      '',
      'To lower case: value.toLowerCase()',
    ),
    _fn('string_trim', 'UnaryInput', '', 'Trim whitespace: value.trim()'),
    _fn('string_trim_start', 'UnaryInput', '', 'Trim start: value.trimLeft()'),
    _fn('string_trim_end', 'UnaryInput', '', 'Trim end: value.trimRight()'),
    _fn(
      'string_replace',
      'StringReplaceInput',
      '',
      'Replace first: value.replaceFirst(from, to)',
    ),
    _fn(
      'string_replace_all',
      'StringReplaceInput',
      '',
      'Replace all: value.replaceAll(from, to)',
    ),
    _fn('string_split', 'BinaryInput', '', 'Split string: left.split(right)'),
    _fn(
      'string_runes',
      'UnaryInput',
      '',
      'Unicode code points: value.runes.toList()',
    ),
    _fn(
      'string_repeat',
      'StringRepeatInput',
      '',
      'Repeat string: value * count',
    ),
    _fn(
      'string_pad_left',
      'StringPadInput',
      '',
      'Pad left: value.padLeft(width, padding)',
    ),
    _fn(
      'string_pad_right',
      'StringPadInput',
      '',
      'Pad right: value.padRight(width, padding)',
    ),
    _fn(
      'string_interpolation',
      'StringInterpolationInput',
      '',
      'String interpolation: \'a\${b}c\' — stringify each element of `parts` '
          'and concatenate in order',
    ),

    // --- Text sink (issue #630) ---
    //
    // A mutable output sink — the common denominator of Dart's `StringBuffer`/
    // `StringSink`, Rust's `fmt::Write` (`String`, `Formatter`), Go's
    // `strings.Builder`, C#'s `StringBuilder`, Python's `io.StringIO`, C++'s
    // `std::ostringstream` and a TS `string[]` + `join`. Every one of those is
    // append-only text accumulation with a terminal read, so three functions
    // are the whole abstraction: `writeln` is `sink_write` plus `"\n"` (Rust
    // `core` defines `writeln!($dst)` as exactly `write!($dst, "\n")`), and
    // `writeCharCode` is `sink_write` plus `string_from_char_code`.
    //
    // Declared in universal `std`, NOT `std_io`: building a string performs no
    // I/O and works in every runtime, whereas `capability_table.dart` maps
    // `std_io` membership to the `io` capability, so declaring it there would
    // mark every string-building program io-capable in `ball audit`.
    //
    // NORMATIVE runtime contract, and the part that fails silently:
    // a sink is a REFERENCE-SEMANTIC, `__type__`-tagged value. Passing one to a
    // function and appending there must be observable by the caller, and
    // `std.type_of` must answer `"Sink"` on every target — never the host
    // builder's own type name.
    _fn(
      'sink_create',
      'SinkCreateInput',
      '',
      'Create a text sink, optionally seeded: StringBuffer(initial)',
    ),
    _fn(
      'sink_write',
      'SinkWriteInput',
      '',
      'Append text to a sink: sink.write(text)',
    ),
    _fn(
      'sink_to_string',
      'SinkToStringInput',
      'String',
      'Read a sink back: sink.toString()',
    ),

    // --- Regex (universal) ---
    _fn(
      'regex_match',
      'BinaryInput',
      '',
      'Regex match: RegExp(right).hasMatch(left)',
    ),
    _fn(
      'regex_find',
      'BinaryInput',
      '',
      'Regex find first: RegExp(right).firstMatch(left)?.group(0)',
    ),
    _fn(
      'regex_find_all',
      'BinaryInput',
      '',
      'Regex find all: RegExp(right).allMatches(left).map(m => m.group(0))',
    ),
    _fn(
      'regex_replace',
      'StringReplaceInput',
      '',
      'Regex replace first: value.replaceFirst(RegExp(from), to)',
    ),
    _fn(
      'regex_replace_all',
      'StringReplaceInput',
      '',
      'Regex replace all: value.replaceAll(RegExp(from), to)',
    ),

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
    _fn('math_clamp', 'MathClampInput', '', 'Clamp: value.clamp(min, max)'),
    _fn('math_pi', '', '', 'Constant: pi'),
    _fn('math_e', '', '', 'Constant: e'),
    _fn('math_infinity', '', '', 'Constant: infinity'),
    _fn('math_nan', '', '', 'Constant: NaN'),
    _fn('math_is_nan', 'UnaryInput', '', 'Is NaN: value.isNaN'),
    _fn('math_is_finite', 'UnaryInput', '', 'Is finite: value.isFinite'),
    _fn('math_is_infinite', 'UnaryInput', '', 'Is infinite: value.isInfinite'),
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
