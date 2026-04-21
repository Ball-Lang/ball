void main() {
  Map<String, Map<String, int>> grades = {
    'Alice': {'math': 95, 'science': 88, 'english': 92},
    'Bob': {'math': 78, 'science': 85, 'english': 90},
  };

  grades.forEach((student, subjects) {
    int total = 0;
    subjects.forEach((subject, grade) {
      total += grade;
    });
    print('$student: total=$total');
  });

  print(grades['Alice']!['math']);
  print(grades['Bob']!['english']);
}
