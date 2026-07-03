// Fixture for issue #166: an implicit (no-arg) default constructor must run a
// superclass's OWN inline field initializers when synthesizing `__super__`, so
// an inherited-only field (declared with an initializer on a superclass and
// never set by the subclass) is READABLE — both qualified with `this.` and
// unqualified — instead of throwing `Field "X" not found`.
//
// Also covers direct instantiation of the base (its own inline initializers
// must apply, previously they were silently left null) and a three-level
// implicit-constructor chain so a grandparent's initializers are visible.
//
// Contrast fixture 345, which covers a builtin-type-named inherited field.

class Base {
  var widgets = [10, 20, 30];
  int count = 7;
  String label = 'base';
}

class Sub extends Base {
  // No explicit constructor: relies on the compiler-synthesized implicit
  // no-arg constructor — the exact path that failed in #166.
  String describe() {
    return 'widgets=${this.widgets} count=$count label=$label';
  }
}

class Leaf extends Sub {
  String describeLeaf() {
    return 'leaf widgets=$widgets count=${this.count} label=$label';
  }
}

void main() {
  // Direct base instantiation: inline field initializers must apply.
  final b = Base();
  print(b.widgets);
  print(b.count);
  print(b.label);

  // Inherited-only reads through an implicit constructor (the #166 bug):
  // qualified `this.widgets` and unqualified `count` / `label`.
  print(Sub().describe());

  // Grandparent initializers visible through a two-level implicit chain.
  print(Leaf().describeLeaf());
}
