void main() {
  var m = {'zeta': 1, 'alpha': 2, 'mid': 3};
  var ks = <String>[];
  var vs = <int>[];
  m.forEach((k, v) {
    ks.add(k);
    vs.add(v);
  });
  print(ks.join(','));
  print(vs.join(','));
  print(m['alpha']);
  m['new'] = 9;
  var ks2 = <String>[];
  m.forEach((k, v) {
    ks2.add(k);
  });
  print(ks2.join(','));
  print(m.containsKey('zeta'));
}
