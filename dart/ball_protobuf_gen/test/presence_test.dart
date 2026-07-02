/// #140 regression: presence accessors on the generated typed view.
///
/// Proto3 singular MESSAGE fields and oneof members always track presence
/// (`hasX()` / `clearX()`), even though their resolved `field_presence`
/// feature says IMPLICIT — the feature only governs scalars. Plain proto3
/// scalars stay implicit: no presence accessors at all.
///
/// The old presence chain in gen_model.dart collapsed everything
/// non-explicit to implicit (both arms of its final ternary were
/// identical), which silently dropped hasX()/clearX() from exactly these
/// fields. This test compiles against the golden — if the rule regresses,
/// the golden drift guard forces a regeneration without these methods and
/// this file stops compiling.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'golden/test_messages.pb.dart';

void main() {
  group('proto3 presence (#140)', () {
    test('singular message field tracks presence', () {
      final m = TestAllTypesProto3({});
      expect(m.hasOptionalNestedMessage(), isFalse);
      expect(m.optionalNestedMessage, isNull);

      m.optionalNestedMessage = TestAllTypesProto3_NestedMessage({})..a = 7;
      expect(m.hasOptionalNestedMessage(), isTrue);
      expect(m.optionalNestedMessage!.a, 7);

      m.clearOptionalNestedMessage();
      expect(m.hasOptionalNestedMessage(), isFalse);
    });

    test('oneof members track presence (scalar and message)', () {
      final m = TestAllTypesProto3({});
      expect(m.hasOneofUint32(), isFalse);
      m.oneofUint32 = 42;
      expect(m.hasOneofUint32(), isTrue);

      expect(m.hasOneofNestedMessage(), isFalse);
      m.oneofNestedMessage = TestAllTypesProto3_NestedMessage({})..a = 1;
      expect(m.hasOneofNestedMessage(), isTrue);
    });

    test('plain proto3 scalar stays implicit — no presence accessors', () {
      // Method absence can't be asserted at runtime without mirrors; scan the
      // TestAllTypesProto3 class body in the golden source instead.
      final src = File(
        'test/golden/test_messages.pb.dart',
      ).readAsStringSync();
      final start = src.indexOf('class TestAllTypesProto3 ');
      expect(start, greaterThanOrEqualTo(0));
      final end = src.indexOf('\nclass ', start + 1);
      final body = src.substring(start, end < 0 ? src.length : end);
      // optional_int32 is a plain proto3 scalar (implicit presence). Match
      // with the call parens — `hasOptionalInt32Wrapper()` (the Int32Value
      // wrapper field, a MESSAGE, correctly presence-tracked) would
      // substring-match the bare name.
      expect(body.contains('int get optionalInt32 '), isTrue);
      expect(body.contains('hasOptionalInt32()'), isFalse);
      // Sanity: the same class body DOES carry the message-field accessor.
      expect(body.contains('hasOptionalNestedMessage'), isTrue);
    });
  });
}
