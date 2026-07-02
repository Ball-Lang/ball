void main() {
  // Bare dart:core type names in expression position are type literals (#66).
  print(int);
  print(double);
  print(num);
  print(String);
  print(bool);
  print(List);
  print(Map);
  print(Set);
  print(Object);
  print(Symbol);
  print(dynamic);
  // Type literals compare with ==.
  print(int == int);
  print(int == double);
  // Type literals in string interpolation.
  print('the type is $int');
  // A type literal is a first-class value.
  Object t = String;
  print(t);
}
