String classify(Map<String, int> shape) {
  switch (shape) {
    case {'width': var w, 'height': var h} when w == h:
      return 'square';
    case {'width': var w, 'height': var h}:
      return 'rect:$w,$h';
    default:
      return 'unknown';
  }
}

void main() {
  print(classify({'width': 5, 'height': 5}));
  print(classify({'radius': 3}));
}
