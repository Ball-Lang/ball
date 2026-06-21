import 'package:ball_protobuf/service.dart';
import 'package:test/test.dart';

void main() {
  group('methodKindFromFlags', () {
    test('unary: no streaming', () {
      expect(
        methodKindFromFlags(clientStreaming: false, serverStreaming: false),
        MethodKind.unary,
      );
    });

    test('server streaming', () {
      expect(
        methodKindFromFlags(clientStreaming: false, serverStreaming: true),
        MethodKind.serverStreaming,
      );
    });

    test('client streaming', () {
      expect(
        methodKindFromFlags(clientStreaming: true, serverStreaming: false),
        MethodKind.clientStreaming,
      );
    });

    test('bidi streaming: both flags', () {
      expect(
        methodKindFromFlags(clientStreaming: true, serverStreaming: true),
        MethodKind.bidiStreaming,
      );
    });
  });

  group('MethodDescriptor', () {
    test('construction with defaults', () {
      const m = MethodDescriptor(
        name: 'Say',
        fullName: 'acme.Eliza.Say',
        inputDescriptor: 'acme.SayRequest',
        outputDescriptor: 'acme.SayResponse',
        kind: MethodKind.unary,
      );
      expect(m.name, 'Say');
      expect(m.fullName, 'acme.Eliza.Say');
      expect(m.inputDescriptor, 'acme.SayRequest');
      expect(m.outputDescriptor, 'acme.SayResponse');
      expect(m.kind, MethodKind.unary);
      expect(m.idempotency, IdempotencyLevel.idempotencyUnknown);
    });

    test('explicit idempotency level', () {
      const m = MethodDescriptor(
        name: 'Get',
        fullName: 'acme.Eliza.Get',
        inputDescriptor: 'acme.GetRequest',
        outputDescriptor: 'acme.GetResponse',
        kind: MethodKind.unary,
        idempotency: IdempotencyLevel.noSideEffects,
      );
      expect(m.idempotency, IdempotencyLevel.noSideEffects);
    });
  });

  group('IdempotencyLevel enum', () {
    test('has the three protobuf levels', () {
      expect(IdempotencyLevel.values, hasLength(3));
      expect(
        IdempotencyLevel.values,
        containsAll(<IdempotencyLevel>[
          IdempotencyLevel.idempotencyUnknown,
          IdempotencyLevel.noSideEffects,
          IdempotencyLevel.idempotent,
        ]),
      );
    });
  });

  group('ServiceDescriptor', () {
    final service = ServiceDescriptor(
      fullName: 'acme.Eliza',
      methods: const [
        MethodDescriptor(
          name: 'Say',
          fullName: 'acme.Eliza.Say',
          inputDescriptor: 'acme.SayRequest',
          outputDescriptor: 'acme.SayResponse',
          kind: MethodKind.unary,
        ),
        MethodDescriptor(
          name: 'Converse',
          fullName: 'acme.Eliza.Converse',
          inputDescriptor: 'acme.ConverseRequest',
          outputDescriptor: 'acme.ConverseResponse',
          kind: MethodKind.bidiStreaming,
        ),
      ],
    );

    test('exposes fullName + methods', () {
      expect(service.fullName, 'acme.Eliza');
      expect(service.methods, hasLength(2));
    });

    test('methodByName finds a known method', () {
      final m = service.methodByName('Converse');
      expect(m, isNotNull);
      expect(m!.kind, MethodKind.bidiStreaming);
    });

    test('methodByName returns null for an unknown method', () {
      expect(service.methodByName('Nope'), isNull);
    });

    test('methodByName on an empty service returns null', () {
      const empty = ServiceDescriptor(fullName: 'acme.Empty', methods: []);
      expect(empty.methodByName('Anything'), isNull);
    });
  });
}
