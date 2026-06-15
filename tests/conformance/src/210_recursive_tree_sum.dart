int sumTree(List node) {
  if (node.length == 1) {
    return node[0];
  }
  return node[0] + sumTree(node[1]) + sumTree(node[2]);
}

void main() {
  print(sumTree([
    1,
    [
      2,
      [4],
      [5]
    ],
    [
      3,
      [6],
      [7]
    ]
  ]).toString());
}
