// A `?.` in the MIDDLE of a postfix chain short-circuits EVERYTHING to its
// right, not just its own link: `x?.a.b()` is `x == null ? null : x.a.b()`,
// never `(x == null ? null : x.a).b()` (issue #488,
// `async/lib/src/cancelable_operation.dart`).
//
// The difference is only observable when the receiver IS null: the wrong
// lowering evaluates the guard to null and then invokes the next link ON null,
// which is a runtime error on every engine — so every `absent` line below
// would fail, not merely print something else.

class Leaf {
  final int value;
  Leaf(this.value);
  int twice() => value * 2;
}

class Node {
  final Leaf leaf;
  final Leaf? maybeLeaf;
  Node(this.leaf, this.maybeLeaf);
}

class Holder {
  // A mutable FIELD: Dart's flow analysis never promotes one, so the lowering
  // has to bind it to a temporary before naming it twice.
  Node? node;
  Holder(this.node);

  int? readChain() {
    return node?.leaf.value;
  }

  int? callChain() {
    return node?.leaf.twice();
  }

  // TWO short-circuiting links in one chain: each guards the rest of the chain
  // to ITS right, deepest first.
  int? doubleChain() {
    return node?.maybeLeaf?.twice();
  }
}

void main() {
  final present = Holder(Node(Leaf(21), Leaf(5)));
  final noLeaf = Holder(Node(Leaf(1), null));
  final absent = Holder(null);

  print(present.readChain());
  print(present.callChain());
  print(present.doubleChain());

  print(noLeaf.readChain());
  print(noLeaf.doubleChain());

  print(absent.readChain());
  print(absent.callChain());
  print(absent.doubleChain());

  // A LOCAL receiver promotes, so the lowering may name it directly instead of
  // binding a temporary — the other half of the same branch.
  final Node? localPresent = present.node;
  final Node? localAbsent = absent.node;
  print(localPresent?.leaf.twice());
  print(localAbsent?.leaf.twice());

  // The chain's value flows into real control flow, so a wrong result is not
  // merely a different print.
  if (absent.callChain() == null) {
    print('absent short-circuited');
  } else {
    print('absent did NOT short-circuit');
  }
}
