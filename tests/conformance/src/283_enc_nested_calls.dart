int triple(int x) => x * 3;
int addOne(int x) => x + 1;
int pipeline(int x) => triple(addOne(triple(x)));
void main() {
  print(pipeline(2).toString());   // triple(addOne(triple(2))) = triple(addOne(6)) = triple(7) = 21
  print(pipeline(0).toString());   // triple(addOne(0)) = triple(1) = 3
  print(triple(triple(triple(1))).toString()); // 27
}
