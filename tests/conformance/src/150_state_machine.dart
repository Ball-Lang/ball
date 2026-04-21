String processInput(String input) {
  String state = 'START';
  StringBuffer output = StringBuffer();
  for (int i = 0; i < input.length; i++) {
    String c = input[i];
    switch (state) {
      case 'START':
        if (c == '"') {
          state = 'IN_STRING';
        } else if (c == ' ') {
          // skip whitespace
        } else {
          output.write(c);
          state = 'IN_WORD';
        }
        break;
      case 'IN_WORD':
        if (c == ' ') {
          output.write('|');
          state = 'START';
        } else if (c == '"') {
          state = 'IN_STRING';
        } else {
          output.write(c);
        }
        break;
      case 'IN_STRING':
        if (c == '"') {
          state = 'IN_WORD';
        } else {
          output.write(c);
        }
        break;
    }
  }
  return output.toString();
}

void main() {
  print(processInput('hello world'));
  print(processInput('"hello world"'));
  print(processInput('a "b c" d'));
  print(processInput('  spaces  between  '));
}
