// #499 - a constructor that builds ANOTHER instance of its own class must run
// the real constructor, not silently get `self` back.
//
// The engine binds `__constructor_type__` for every `kind: constructor` call
// and used a type-name-only guard to stop a constructor's own synthetic
// zero-argument self-reference (`class Foo {}`'s implicit `Foo.new` body is
// `messageCreation Foo{}`) from recursing forever. Keying on the NAME alone
// also swallowed this shape - a linked list whose constructor builds its own
// successor - so `next` came back as the node itself: an infinite self-cycle
// that walked until the loop's own safety cap and reported `nextIsSelf=true`.
//
// The guard now additionally requires the construction to carry no real
// constructor argument, so `Chain(depth - 1)` invokes the constructor while the
// argument-less self-reference still resolves to `self`.

class Chain {
  int depth;
  Chain? next;

  Chain(this.depth) {
    if (depth > 0) {
      next = Chain(depth - 1);
    }
  }
}

void main() {
  final head = Chain(5);

  // Walking the list terminates at a real tail, and every node carries its own
  // decreasing depth. The `< 100` cap is what turned the bug into a visible
  // wrong number instead of a hang.
  int length = 0;
  Chain? cursor = head;
  while (cursor != null && length < 100) {
    length = length + 1;
    print(cursor.depth);
    cursor = cursor.next;
  }
  print(length);

  // The successor is a genuinely distinct object, not the node itself.
  print(identical(head.next, head));

  // Two independent chains do not share nodes either.
  final other = Chain(2);
  print(identical(other.next, head.next));
  print(other.next!.depth);
  print(other.next!.next!.depth);
  print(other.next!.next!.next == null);

  // A zero-depth chain never enters the branch at all.
  final leaf = Chain(0);
  print(leaf.depth);
  print(leaf.next == null);
}
