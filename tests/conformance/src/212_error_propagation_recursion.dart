int descend(int depth) {
  if (depth <= 0) {
    throw 'hit-bottom';
  }
  return descend(depth - 1);
}

void main() {
  try {
    descend(5);
  } catch (e) {
    print('caught after recursion: ' + '$e');
  }
}
