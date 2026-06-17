// Switch `when` guards in both expression and statement form. The first arm
// whose pattern matches AND whose guard holds wins; a matching pattern with a
// false guard falls through to later arms.

String classifyExpr(int n) => switch (n) {
  int x when x > 100 => 'huge:$x',
  int x when x > 10 => 'big:$x',
  int x when x > 0 => 'small:$x',
  _ => 'nonpos',
};

String classifyStmt(int n) {
  switch (n) {
    case int x when x > 100:
      return 'huge:$x';
    case int x when x > 10:
      return 'big:$x';
    case int x when x > 0:
      return 'small:$x';
    default:
      return 'nonpos';
  }
}

void main() {
  print(classifyExpr(500));
  print(classifyExpr(50));
  print(classifyExpr(5));
  print(classifyExpr(-1));
  print(classifyStmt(500));
  print(classifyStmt(50));
  print(classifyStmt(5));
  print(classifyStmt(0));
}
