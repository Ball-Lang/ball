// #499, branching variant. 435/436 build one successor per constructor call,
// so a single collapsed `self` was enough to explain them. A binary tree builds
// TWO same-class children from one constructor body, which additionally proves
// the two children are distinct from each other, not just from their parent -
// under the old type-name-only guard `left`, `right` and the parent were all
// the very same object.

class Node {
  int level;
  String tag;
  Node? left;
  Node? right;

  Node(this.level, this.tag) {
    if (level > 0) {
      left = Node(level - 1, tag + 'L');
      right = Node(level - 1, tag + 'R');
    }
  }
}

int countNodes(Node? node) {
  if (node == null) {
    return 0;
  }
  return 1 + countNodes(node.left) + countNodes(node.right);
}

int depthOf(Node? node) {
  if (node == null) {
    return 0;
  }
  int leftDepth = depthOf(node.left);
  int rightDepth = depthOf(node.right);
  if (leftDepth > rightDepth) {
    return 1 + leftDepth;
  }
  return 1 + rightDepth;
}

void main() {
  final root = Node(3, 'r');

  print(countNodes(root));
  print(depthOf(root));

  // Neither child is the parent, and the two children are not each other.
  print(identical(root.left, root));
  print(identical(root.right, root));
  print(identical(root.left, root.right));

  // Each subtree carries its own accumulated tag, so the children really were
  // built from their own constructor arguments.
  print(root.tag);
  print(root.left!.tag);
  print(root.right!.tag);
  print(root.left!.right!.tag);
  print(root.right!.left!.left!.tag);

  // Levels decrease along every path and the leaves have no children.
  print(root.level);
  print(root.left!.level);
  print(root.left!.left!.level);
  print(root.left!.left!.left!.level);
  print(root.left!.left!.left!.left == null);
}
