class NotFound {}

void main() {
  try {
    throw NotFound();
  } on NotFound catch (e) {
    print('caught-NotFound');
  }
}
