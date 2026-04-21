String reverse(String s) {
  String result = '';
  for (int i = s.length - 1; i >= 0; i--) {
    result += s[i];
  }
  return result;
}

bool isPalindrome(String s) {
  return s == reverse(s);
}

void main() {
  print(reverse('hello'));
  print(reverse('abcde'));
  print(isPalindrome('racecar'));
  print(isPalindrome('hello'));
  print(isPalindrome('level'));
}
