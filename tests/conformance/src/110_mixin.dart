mixin Printable {
  String get label;
  void printLabel() {
    print('Label: $label');
  }
}

mixin Serializable {
  String serialize() {
    return 'serialized';
  }
}

class Document with Printable, Serializable {
  String title;
  Document(this.title);

  String get label => title;
}

void main() {
  Document doc = Document('My Report');
  doc.printLabel();
  print(doc.serialize());
  print(doc.label);
}
