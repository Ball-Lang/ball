class TypeInfo {
  static const TypeInfo $null = TypeInfo(root: 'null');
  static const TypeInfo $any = TypeInfo(root: 'Object');
  static const TypeInfo $num = TypeInfo(root: 'num');
  factory TypeInfo.listOf(TypeInfo sub) => TypeInfo(
        root: 'list',
        arguments: [sub],
      );
  factory TypeInfo.mapOf(TypeInfo key, TypeInfo value) => TypeInfo(
        root: 'map',
        arguments: [key, value],
      );

  final String root;
  final List<TypeInfo> arguments;

  const TypeInfo({
    required this.root,
    this.arguments = const [],
  });
}
