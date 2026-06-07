void main() {
  var a = 0xF0;
  var b = 0x0F;
  print((a & b).toString()); // 0
  print((a | b).toString()); // 255
  print((a ^ b).toString()); // 255
  print((a >> 4).toString()); // 15
  print((b << 4).toString()); // 240
  print((~0).toString()); // -1
}
