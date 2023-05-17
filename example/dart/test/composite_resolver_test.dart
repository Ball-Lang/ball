import 'package:ball/ball.dart';
import 'package:test/test.dart';

void main() {
  final repository = BallRepository();
  //my functions

  setUp(() => repository.init());

  test('Infer Root', () {
    final newType = CompositeCallHandler.inferNewType(
      original: SchemaTypeInfo(root: 'T'),
      genericArgumentAssignments: {
        'T': SchemaTypeInfo.$int,
      },
    );
    expect(newType.root, SchemaTypeInfo.$int.root);
  });
  test('Infer Generic List', () {
    final newType = CompositeCallHandler.inferNewType(
      original: SchemaTypeInfo.listOf(SchemaTypeInfo(root: 'T')),
      genericArgumentAssignments: {
        'T': SchemaTypeInfo.$int,
      },
    );

    expect(newType, SchemaTypeInfo.listOf(SchemaTypeInfo.$int));
  });
  test('Infer Generic Map', () {
    final newType = CompositeCallHandler.inferNewType(
      original: SchemaTypeInfo.mapOf(
          SchemaTypeInfo(root: 'TKey'), SchemaTypeInfo(root: 'TValue')),
      genericArgumentAssignments: {
        'TKey': SchemaTypeInfo.string,
        'TValue': SchemaTypeInfo.$int,
      },
    );

    expect(newType,
        SchemaTypeInfo.mapOf(SchemaTypeInfo.string, SchemaTypeInfo.$int));
  });
}
