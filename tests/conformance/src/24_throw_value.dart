class NotFound {
  final String detail;
  NotFound(this.detail);
}

void main() {
  try {
    throw NotFound('missing-key');
  } on NotFound catch (e) {
    print(e.detail);
  }
}
