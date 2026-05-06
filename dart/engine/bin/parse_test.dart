import 'dart:io';
import 'dart:convert';
import 'package:ball_base/ball_base.dart';

void main() async {
  final jsonStr = File('../../tests/conformance/160_async_basic.ball.json').readAsStringSync();
  final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
  final program = Program()
    ..mergeFromProto3Json(jsonMap, ignoreUnknownFields: true);
  for (final mod in program.modules) {
    for (final func in mod.functions) {
      if (func.name == 'delayedAdd') {
        print('Function: ${func.name}');
        print('Has body: ${func.hasBody()}');
        if (func.hasBody() && func.body.hasBlock()) {
          final block = func.body.block;
          print('Statements count: ${block.statements.length}');
          for (int i = 0; i < block.statements.length; i++) {
            final stmt = block.statements[i];
            print('  Statement $i: whichStmt=${stmt.whichStmt()}, hasLet=${stmt.hasLet()}, hasExpression=${stmt.hasExpression()}');
            if (stmt.hasLet()) {
              print('    Let name=${stmt.let.name}');
            }
            if (stmt.hasExpression()) {
              print('    Expression type: ${stmt.expression.whichExpr()}');
            }
          }
          print('Has result: ${block.hasResult()}');
          if (block.hasResult()) {
            print('Result type: ${block.result.whichExpr()}');
          }
        }
      }
    }
  }
}