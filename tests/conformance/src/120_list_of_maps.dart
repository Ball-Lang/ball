void main() {
  List<Map<String, String>> people = [
    {'name': 'Alice', 'city': 'NYC'},
    {'name': 'Bob', 'city': 'LA'},
    {'name': 'Charlie', 'city': 'NYC'},
    {'name': 'Diana', 'city': 'LA'},
    {'name': 'Eve', 'city': 'Chicago'},
  ];

  for (Map<String, String> person in people) {
    print('${person['name']} lives in ${person['city']}');
  }

  List<Map<String, String>> nycPeople = [];
  for (Map<String, String> person in people) {
    if (person['city'] == 'NYC') {
      nycPeople.add(person);
    }
  }
  print('NYC residents: ${nycPeople.length}');
}
