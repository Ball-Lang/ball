import 'package:ball_protobuf/extension.dart';
import 'package:test/test.dart';

void main() {
  group('Extension', () {
    test('construction exposes all fields', () {
      const ext = Extension(
        extendeeFullName: 'acme.User',
        fieldKey: '[acme.user_email]',
        number: 100,
        type: 'TYPE_STRING',
      );
      expect(ext.extendeeFullName, 'acme.User');
      expect(ext.fieldKey, '[acme.user_email]');
      expect(ext.number, 100);
      expect(ext.type, 'TYPE_STRING');
      expect(ext.descriptor, isNull);
    });

    test('fullName strips surrounding brackets', () {
      const ext = Extension(
        extendeeFullName: 'acme.User',
        fieldKey: '[acme.user_email]',
        number: 100,
        type: 'TYPE_STRING',
      );
      expect(ext.fullName, 'acme.user_email');
    });

    test('fullName passes through an unbracketed key', () {
      const ext = Extension(
        extendeeFullName: 'acme.User',
        fieldKey: 'acme.user_email',
        number: 100,
        type: 'TYPE_STRING',
      );
      expect(ext.fullName, 'acme.user_email');
    });

    test('message extension carries a descriptor', () {
      const desc = <Map<String, Object?>>[
        {'name': 'value', 'number': 1, 'type': 'TYPE_INT32'},
      ];
      const ext = Extension(
        extendeeFullName: 'acme.User',
        fieldKey: '[acme.meta]',
        number: 200,
        type: 'TYPE_MESSAGE',
        descriptor: desc,
      );
      expect(ext.type, 'TYPE_MESSAGE');
      expect(ext.descriptor, same(desc));
    });
  });

  group('ExtensionRegistry', () {
    Extension makeExt(
      String name,
      int number, {
      String extendee = 'acme.User',
    }) {
      return Extension(
        extendeeFullName: extendee,
        fieldKey: '[$name]',
        number: number,
        type: 'TYPE_STRING',
      );
    }

    test('empty registry has no extensions', () {
      final r = ExtensionRegistry();
      expect(r.extensions, isEmpty);
      expect(r.lookup('acme.User', 1), isNull);
      expect(r.lookupByTypeUrl('type.googleapis.com/acme.foo'), isNull);
    });

    test('register + lookup by (extendee, number)', () {
      final r = ExtensionRegistry();
      final ext = makeExt('acme.user_email', 100);
      r.register(ext);
      expect(r.lookup('acme.User', 100), same(ext));
      expect(r.lookup('acme.User', 101), isNull);
      expect(r.lookup('other.Message', 100), isNull);
    });

    test('lookupByTypeUrl resolves full type-url', () {
      final r = ExtensionRegistry();
      final ext = makeExt('acme.user_email', 100);
      r.register(ext);
      expect(
        r.lookupByTypeUrl('type.googleapis.com/acme.user_email'),
        same(ext),
      );
    });

    test('lookupByTypeUrl accepts a bare fully-qualified name', () {
      final r = ExtensionRegistry();
      final ext = makeExt('acme.user_email', 100);
      r.register(ext);
      expect(r.lookupByTypeUrl('acme.user_email'), same(ext));
    });

    test('lookupByTypeUrl resolves a custom host prefix via FQN fallback', () {
      final r = ExtensionRegistry();
      final ext = makeExt('acme.user_email', 100);
      r.register(ext);
      expect(r.lookupByTypeUrl('example.com/acme.user_email'), same(ext));
    });

    test('lookupByTypeUrl returns null for an unknown url', () {
      final r = ExtensionRegistry();
      r.register(makeExt('acme.user_email', 100));
      expect(r.lookupByTypeUrl('type.googleapis.com/acme.unknown'), isNull);
    });

    test('factory ExtensionRegistry.of pre-populates', () {
      final a = makeExt('acme.a', 1);
      final b = makeExt('acme.b', 2);
      final r = ExtensionRegistry.of([a, b]);
      expect(r.lookup('acme.User', 1), same(a));
      expect(r.lookup('acme.User', 2), same(b));
      expect(r.extensions.length, 2);
    });

    test('merge takes entries from the other registry', () {
      final r1 = ExtensionRegistry.of([makeExt('acme.a', 1)]);
      final r2 = ExtensionRegistry.of([makeExt('acme.b', 2)]);
      r1.merge(r2);
      expect(r1.lookup('acme.User', 1), isNotNull);
      expect(r1.lookup('acme.User', 2), isNotNull);
    });

    test('merge: other wins on (extendee, number) conflict', () {
      final original = makeExt('acme.a', 1);
      final replacement = Extension(
        extendeeFullName: 'acme.User',
        fieldKey: '[acme.a_replacement]',
        number: 1,
        type: 'TYPE_INT32',
      );
      final r1 = ExtensionRegistry.of([original]);
      final r2 = ExtensionRegistry.of([replacement]);
      r1.merge(r2);
      expect(r1.lookup('acme.User', 1), same(replacement));
    });
  });

  group('mergeRegistries', () {
    Extension makeExt(String name, int number) => Extension(
      extendeeFullName: 'acme.User',
      fieldKey: '[$name]',
      number: number,
      type: 'TYPE_STRING',
    );

    test('combines multiple registries', () {
      final r1 = ExtensionRegistry.of([makeExt('acme.a', 1)]);
      final r2 = ExtensionRegistry.of([makeExt('acme.b', 2)]);
      final r3 = ExtensionRegistry.of([makeExt('acme.c', 3)]);
      final out = mergeRegistries([r1, r2, r3]);
      expect(out.lookup('acme.User', 1), isNotNull);
      expect(out.lookup('acme.User', 2), isNotNull);
      expect(out.lookup('acme.User', 3), isNotNull);
      expect(out.extensions.length, 3);
    });

    test('empty iterable yields an empty registry', () {
      final out = mergeRegistries([]);
      expect(out.extensions, isEmpty);
    });
  });
}
