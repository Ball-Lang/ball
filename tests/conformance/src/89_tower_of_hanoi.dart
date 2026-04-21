int moves = 0;

void hanoi(int n, String from, String to, String aux) {
  if (n == 1) {
    moves++;
    return;
  }
  hanoi(n - 1, from, aux, to);
  moves++;
  hanoi(n - 1, aux, to, from);
}

void main() {
  hanoi(3, 'A', 'C', 'B');
  print(moves);
  moves = 0;
  hanoi(4, 'A', 'C', 'B');
  print(moves);
}
