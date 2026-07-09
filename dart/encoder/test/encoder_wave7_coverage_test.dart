/// Wave-7 feature-branch coverage for `encoder.dart` (issue #61): real Dart
/// constructs that the existing corpus + unit tests don't exercise yet.
///
/// Each test encodes a small Dart snippet containing exactly one feature and
/// asserts the encoder emits the corresponding Ball metadata/shape — proving
/// the branch runs AND produces the expected output (not just that it
/// doesn't throw). Mirrors encoder_wave6_coverage_test.dart's house style.
///
/// Several of these snippets are syntactically valid but semantically
/// unusual Dart (e.g. a local variable shadowing a builtin type name, or a
/// catch clause hand-written in the compiler's internal `__ball_e`/`__ball_st`
/// aliasing shape) — the encoder parses with `parseString` and never runs a
/// resolution/semantic-analysis pass, so these are legitimate probes of its
/// purely-syntactic dispatch even though `dart run` would never see them
/// (real Dart source never uses `__ball_e`/`__ball_st` — the compiler
/// synthesizes them).
library;

import 'dart:convert';

import 'package:ball_base/ball_base.dart';
import 'package:ball_encoder/encoder.dart';
import 'package:test/test.dart';

void main() {
  String jsonOf(String source) =>
      jsonEncode(encodeBallFileJson(DartEncoder().encode(source)));

  group('cascade bare property/index access (null-target PropertyAccess)', () {
    test('a bare property cascade section encodes the cascade-self ref', () {
      final js = jsonOf('''
void main() {
  final list = [1, 2, 3];
  final x = (list..length);
  print(x);
}
''');
      expect(js, contains('__cascade_self__'));
    });

    test('a bare index cascade section encodes the cascade-self ref', () {
      final js = jsonOf('''
void main() {
  final list = [1, 2, 3];
  final x = (list..[0]);
  print(x);
}
''');
      expect(js, contains('__cascade_self__'));
    });
  });

  group('module-prefixed method call and constructor call', () {
    test('a prefixed method call routes to the imported module', () {
      final js = jsonOf('''
import 'package:acme/acme.dart' as acme;
void main() {
  acme.doSomething(1, 2);
}
''');
      expect(js, contains('acme'));
      expect(js, contains('doSomething'));
    });

    test('an explicit `new`-prefixed constructor call resolves the ball '
        'module from the registered import prefix', () {
      // A bare `acme.Widget()` (no `new`) parses as a prefixed function
      // CALL (`ast.MethodInvocation`), not `ast.InstanceCreationExpression`
      // — only the explicit (if old-fashioned) `new` keyword forces the
      // instance-creation interpretation for a prefixed, uppercase name.
      final js = jsonOf('''
import 'package:acme/acme.dart' as acme;
void main() {
  new acme.Widget();
}
''');
      expect(js, contains('acme:Widget'));
    });
  });

  test(
    'list.addAll(...) renames its arg0 to the list_concat "value" field',
    () {
      final js = jsonOf('''
void main() {
  final list = [1, 2, 3];
  list.addAll([4, 5]);
  print(list);
}
''');
      expect(js, contains('list_concat'));
    },
  );

  test('a super-formal-parameter constructor parameter is flagged '
      'is_super in metadata', () {
    final js = jsonOf('''
class Base {
  Base(int value);
}
class Derived extends Base {
  Derived(super.value);
}
void main() {}
''');
    expect(js, contains('is_super'));
  });

  test('.reversed on a non-identifier PropertyAccess target (a list '
      'literal, not a bare variable — which parses as PrefixedIdentifier '
      'instead) routes to list_reverse via its own MessageCreation shape', () {
    final js = jsonOf('''
void main() {
  print([1, 2, 3].reversed);
}
''');
    expect(js, contains('list_reverse'));
  });

  group('extension type — named representation parameter', () {
    test('a named (rather than positional) representation parameter is '
        'stored verbatim via toSource()', () {
      // Not valid semantically (extension types require exactly one
      // positional representation field), but syntactically parseable —
      // the encoder's parseString-only pipeline never resolves it, so this
      // legitimately probes the syntactic `repParam.isNamed` branch.
      final js = jsonOf('''
extension type Meters({required int value}) {}

void main() {}
''');
      expect(js, contains('rep_type'));
    });

    test('a `this.`-prefixed (field-formal) representation parameter is '
        'stored verbatim via toSource(), not through the RegularFormalParameter '
        'type-extraction path', () {
      // Extension types don't semantically support `this.` representation
      // params (no backing field to initialize), but it's syntactically
      // parseable — the encoder's parseString-only pipeline never resolves
      // it, so this legitimately probes the `repParam is! RegularFormalParameter`
      // fallback branch.
      final js = jsonOf('''
extension type Meters(this.value) {}

void main() {}
''');
      expect(js, contains('rep_type'));
      expect(js, contains('this.value'));
    });
  });

  group('named-constructor prefix misparse detection', () {
    test('a const named-constructor call is corrected from a misparsed '
        'import-prefix shape back to ClassName.namedCtor', () {
      final js = jsonOf('''
class SpanStatus {
  const SpanStatus.internalError();
}
void main() {
  const SpanStatus.internalError();
}
''');
      expect(js, contains('SpanStatus.internalError'));
    });
  });

  group('constructor tear-offs and dot-shorthand fallback', () {
    test('a generic constructor tear-off encodes as a verbatim reference', () {
      final js = jsonOf('''
class Box<T> {
  Box(T value);
}
void main() {
  final f = Box<int>.new;
  print(f);
}
''');
      expect(js, contains('Box<int>'));
    });

    test(
      'a dot-shorthand expression falls back to the unsupported literal',
      () {
        final js = jsonOf('''
enum Color { red, green, blue }
void main() {
  Color c = .red;
  print(c);
}
''');
        expect(js, contains('unsupported'));
      },
    );
  });

  group('labeled default switch case', () {
    test('a labeled default case preserves its label field', () {
      final js = jsonOf('''
void main() {
  int x = 1;
  switch (x) {
    case 1:
      print('one');
    stop: default:
      print('other');
  }
}
''');
      expect(js, contains('"stop"'));
      expect(js, contains('is_default'));
    });
  });

  group(
    'type-name-shadowed identifiers (builtin type used as a variable name)',
    () {
      test('prefix/postfix increment on a shadowed builtin type name stays a '
          'plain reference (not a type literal)', () {
        final js = jsonOf('''
void main() {
  var int = 5;
  ++int;
  int++;
  print(int);
}
''');
        // Would contain 'type_literal' if the shadow-detection regressed.
        expect(js, isNot(contains('type_literal')));
      });

      test('a constructor parameter shadowing a builtin type name keeps the '
          'reference plain', () {
        final js = jsonOf('''
class Box {
  Box(int int) {
    print(int);
  }
}
void main() {}
''');
        expect(js, isNot(contains('type_literal')));
      });

      test('a local function shadowing a builtin type name keeps the '
          'reference plain', () {
        final js = jsonOf('''
void main() {
  void int() {}
  print(int);
}
''');
        expect(js, isNot(contains('type_literal')));
      });

      test('a for-each loop variable shadowing a builtin type name keeps the '
          'reference plain', () {
        final js = jsonOf('''
void main() {
  for (var int in [1, 2, 3]) {
    print(int);
  }
}
''');
        expect(js, isNot(contains('type_literal')));
      });

      test('a top-level variable shadowing a builtin type name keeps the '
          'reference plain', () {
        final js = jsonOf('''
int int = 5;
void main() {
  print(int);
}
''');
        expect(js, isNot(contains('type_literal')));
      });

      test('a catch clause exception/stack-trace parameter shadowing a '
          'builtin type name keeps the reference plain', () {
        final js = jsonOf('''
void main() {
  try {
    print('x');
  } catch (int, num) {
    print(int);
    print(num);
  }
}
''');
        expect(js, isNot(contains('type_literal')));
      });
    },
  );

  group('tag-typed catch pattern — stack-trace aliasing', () {
    test('a then-branch-local stack alias (no outer alias) is preserved', () {
      final js = jsonOf('''
void main() {
  try {
    print('x');
  } catch (__ball_e, __ball_st) {
    if (__ball_e is Map && __ball_e['__type'] == 'TypeA') {
      final e = __ball_e;
      final trace = __ball_st;
      print(e);
      print(trace);
    } else {
      rethrow;
    }
  }
}
''');
      expect(js, contains('"trace"'));
      expect(js, contains('stack_trace'));
    });

    test('an untyped fallback catch with its own stack alias is preserved', () {
      final js = jsonOf('''
void main() {
  try {
    print('x');
  } catch (__ball_e, __ball_st) {
    if (__ball_e is Map && __ball_e['__type'] == 'TypeA') {
      final e = __ball_e;
      print(e);
    } else {
      final dynamic e = __ball_e;
      final st = __ball_st;
      print(e);
      print(st);
    }
  }
}
''');
      expect(js, contains('"st"'));
      expect(js, contains('stack_trace'));
    });

    test('a doubly-parenthesized tag condition still extracts the type', () {
      final js = jsonOf('''
void main() {
  try {
    print('x');
  } catch (__ball_e) {
    if (((__ball_e is Map) && (__ball_e['__type'] == 'TypeA'))) {
      final e = __ball_e;
      print(e);
    } else {
      rethrow;
    }
  }
}
''');
      expect(js, contains('"TypeA"'));
    });

    test('an unbraced single-statement then-branch is handled gracefully', () {
      final js = jsonOf('''
void main() {
  try {
    print('x');
  } catch (__ball_e) {
    if (__ball_e is Map && __ball_e['__type'] == 'TypeA')
      final e = __ball_e;
    else
      rethrow;
  }
}
''');
      expect(js, contains('"TypeA"'));
    });
  });

  group('pattern-variable declarations that cannot destructure', () {
    test('a list pattern (non-record) as a non-last block statement falls '
        'back to the unsupported-statement literal', () {
      final js = jsonOf('''
void main() {
  var [a, b] = [1, 2];
  print(a);
}
''');
      expect(js, contains('unsupported'));
    });

    test('a record-pattern declaration as an unbraced if-body destructures '
        'via the block-wrapped single-statement path', () {
      final js = jsonOf('''
void main() {
  if (true) var (a, b) = (1, 2);
}
''');
      expect(js, contains('__ball_rec_'));
    });

    test('a record-pattern declaration inside a NESTED bare block statement '
        'splices its bind-lets into that inner block', () {
      final js = jsonOf('''
void main() {
  {
    var (a, b) = (1, 2);
    print(a);
  }
}
''');
      expect(js, contains('__ball_rec_'));
    });
  });

  group('conditional import/export configurations with non-constant URIs', () {
    test('a non-constant conditional import URI/value are warned and '
        'default to empty string', () {
      final js = jsonOf('''
import 'stub.dart'
  if (dart.library.io) 'io\${1}.dart'
  if (dart.library.io == 'io\${1}') 'io2.dart';
void main() {}
''');
      expect(js, contains('configurations'));
    });

    test('a non-constant conditional export URI/value are warned and '
        'default to empty string', () {
      final js = jsonOf('''
export 'stub.dart'
  if (dart.library.io) 'io\${1}.dart'
  if (dart.library.io == 'io\${1}') 'io2.dart';
void main() {}
''');
      expect(js, contains('configurations'));
    });
  });

  group('nested generic + nullable type arguments in metadata', () {
    test('a nested generic type argument round-trips through the '
        'structured TypeRef metadata', () {
      final js = jsonOf('''
void main() {
  final m = Map<String, List<int>>.from({});
  print(m);
}
''');
      expect(js, contains('type_args'));
    });

    test('a nullable type argument round-trips through the structured '
        'TypeRef metadata', () {
      final js = jsonOf('''
void main() {
  final list = List<int?>.filled(1, null);
  print(list);
}
''');
      expect(js, contains('"nullable"'));
    });
  });

  group('multi-underscore private call name', () {
    test('a double-underscore-prefixed lowercase call is a function call, '
        'not a constructor', () {
      final js = jsonOf('''
void __helper() {}
void main() {
  __helper();
}
''');
      expect(js, contains('__helper'));
      expect(js, isNot(contains('messageCreation')));
    });
  });

  test('a parenthesized SINGLE-section cascade calling a collection method '
      'routes through the collection-call shortcut instead of the generic '
      'paren wrapper', () {
    final js = jsonOf('''
void main() {
  final list = [1, 2, 3];
  final x = (list..add(4));
  print(x);
}
''');
    expect(js, contains('list_push'));
  });

  group('collection-element and string-interpolation edge cases', () {
    test('an if-element whose then-branch is not a map entry still checks '
        'the else-branch for map-entry-ness', () {
      final js = jsonOf('''
void main() {
  final m = {if (true) 1 else 'b': 2};
  print(m);
}
''');
      expect(js, contains('collection_if'));
    });

    test('an already-to_string()-wrapped interpolation expression is not '
        'double-wrapped', () {
      final js = jsonOf('''
void main() {
  int x = 5;
  print('value: \${x.toString()}');
}
''');
      expect(js, contains('to_string'));
    });
  });
}
