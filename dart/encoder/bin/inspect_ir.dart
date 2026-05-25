import 'dart:io';
import 'package:ball_base/gen/ball/v1/ball.pb.dart';

void main() {
  final p = Program.fromBuffer(
    File('D:/packages/ball/dart/self_host/engine.ball.pb').readAsBytesSync(),
  );
  for (final m in p.modules) {
    for (final f in m.functions) {
      if (f.name.contains('_ballPointer') ||
          f.name.contains('_ballString') ||
          f.name.contains('_ballMap') ||
          f.name.contains('Bytes')) {
        print(
          '${m.name}.${f.name} kind=${f.metadata.fields['kind']?.stringValue} hasBody=${f.hasBody()}',
        );
      }
    }
  }
}
