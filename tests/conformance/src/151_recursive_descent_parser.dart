// Simple expression parser: handles +, -, *, / with integer literals
// Grammar: expr = term (('+' | '-') term)*
//          term = factor (('*' | '/') factor)*
//          factor = number | '(' expr ')'

String input = '';
int pos = 0;

void skipSpaces() {
  while (pos < input.length && input[pos] == ' ') pos++;
}

int parseNumber() {
  skipSpaces();
  int start = pos;
  while (pos < input.length && input.codeUnitAt(pos) >= 48 && input.codeUnitAt(pos) <= 57) {
    pos++;
  }
  return int.parse(input.substring(start, pos));
}

int parseFactor() {
  skipSpaces();
  if (pos < input.length && input[pos] == '(') {
    pos++; // skip '('
    int result = parseExpr();
    skipSpaces();
    pos++; // skip ')'
    return result;
  }
  return parseNumber();
}

int parseTerm() {
  int result = parseFactor();
  skipSpaces();
  while (pos < input.length && (input[pos] == '*' || input[pos] == '/')) {
    String op = input[pos];
    pos++;
    int right = parseFactor();
    if (op == '*') {
      result *= right;
    } else {
      result ~/= right;
    }
    skipSpaces();
  }
  return result;
}

int parseExpr() {
  int result = parseTerm();
  skipSpaces();
  while (pos < input.length && (input[pos] == '+' || input[pos] == '-')) {
    String op = input[pos];
    pos++;
    int right = parseTerm();
    if (op == '+') {
      result += right;
    } else {
      result -= right;
    }
    skipSpaces();
  }
  return result;
}

int evaluate(String expr) {
  input = expr;
  pos = 0;
  return parseExpr();
}

void main() {
  print(evaluate('3 + 4'));
  print(evaluate('3 + 4 * 2'));
  print(evaluate('(3 + 4) * 2'));
  print(evaluate('10 - 2 * 3'));
  print(evaluate('100 / 5 / 4'));
}
