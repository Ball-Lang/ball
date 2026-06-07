void main() {
  try {
    throw 'boom';
  } catch (e, stack) {
    print(e.toString());
    print(stack.toString().length > 0 ? 'has-stack' : 'no-stack');
  }
}
