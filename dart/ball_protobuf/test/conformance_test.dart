import 'dart:convert';

import 'package:ball_protobuf/conformance.dart';
import 'package:ball_protobuf/json_codec.dart';
import 'package:ball_protobuf/marshal.dart';
import 'package:ball_protobuf/wire_bytes.dart';
import 'package:ball_protobuf/wire_fixed.dart';
import 'package:ball_protobuf/wire_varint.dart';
import 'package:test/test.dart';

/// Builds a ConformanceRequest's binary protobuf by appending fields, mirroring
/// the conformance.proto schema. (The decoder under test reads exactly this.)
List<int> _buildRequest({
  List<int>? protobufPayload,
  String? jsonPayload,
  String? jspbPayload,
  String? textPayload,
  int? requestedOutputFormat,
  String? messageType,
  int? testCategory,
  bool? printUnknownFields,
}) {
  final buf = <int>[];
  if (protobufPayload != null) {
    encodeTag(buf, 1, 2);
    encodeBytes(buf, protobufPayload);
  }
  if (jsonPayload != null) {
    encodeTag(buf, 2, 2);
    encodeBytes(buf, utf8.encode(jsonPayload));
  }
  if (requestedOutputFormat != null) {
    encodeTag(buf, 3, 0);
    encodeVarint(buf, requestedOutputFormat);
  }
  if (messageType != null) {
    encodeTag(buf, 4, 2);
    encodeBytes(buf, utf8.encode(messageType));
  }
  if (testCategory != null) {
    encodeTag(buf, 5, 0);
    encodeVarint(buf, testCategory);
  }
  if (jspbPayload != null) {
    encodeTag(buf, 7, 2);
    encodeBytes(buf, utf8.encode(jspbPayload));
  }
  if (textPayload != null) {
    encodeTag(buf, 8, 2);
    encodeBytes(buf, utf8.encode(textPayload));
  }
  if (printUnknownFields != null) {
    encodeTag(buf, 9, 0);
    encodeVarint(buf, printUnknownFields ? 1 : 0);
  }
  return buf;
}

void main() {
  group('decodeConformanceRequest / parseConformanceRequest', () {
    test('protobuf_payload field', () {
      final req = _buildRequest(protobufPayload: [10, 20, 30]);
      final decoded = decodeConformanceRequest(req);
      expect(decoded['protobuf_payload'], [10, 20, 30]);
    });

    test('json_payload field', () {
      final req = _buildRequest(jsonPayload: '{"a":1}');
      final decoded = decodeConformanceRequest(req);
      expect(decoded['json_payload'], '{"a":1}');
    });

    test('requested_output_format + message_type', () {
      final req = _buildRequest(
        requestedOutputFormat: wireFormatProtobuf,
        messageType: 'foo.Bar',
      );
      final decoded = decodeConformanceRequest(req);
      expect(decoded['requested_output_format'], wireFormatProtobuf);
      expect(decoded['message_type'], 'foo.Bar');
    });

    test('test_category + print_unknown_fields', () {
      final req = _buildRequest(testCategory: 2, printUnknownFields: true);
      final decoded = decodeConformanceRequest(req);
      expect(decoded['test_category'], 2);
      expect(decoded['print_unknown_fields'], true);
    });

    test('jspb_payload + text_payload', () {
      final req = _buildRequest(jspbPayload: '[1]', textPayload: 'x: 1');
      final decoded = decodeConformanceRequest(req);
      expect(decoded['jspb_payload'], '[1]');
      expect(decoded['text_payload'], 'x: 1');
    });

    test('jspb_encoding_options (field 6) is skipped without crashing', () {
      final buf = <int>[];
      encodeTag(buf, 6, 2); // message, skipped by the decoder
      encodeBytes(buf, [1, 2, 3]);
      encodeTag(buf, 4, 2);
      encodeBytes(buf, utf8.encode('after'));
      final decoded = decodeConformanceRequest(buf);
      expect(decoded.containsKey('jspb_encoding_options'), false);
      expect(decoded['message_type'], 'after');
    });

    test('parseConformanceRequest delegates to decode', () {
      final req = _buildRequest(jsonPayload: '{}');
      expect(parseConformanceRequest(req), decodeConformanceRequest(req));
    });

    test('unknown VARINT field is skipped', () {
      final buf = <int>[];
      encodeTag(buf, 100, 0); // unknown varint field
      encodeVarint(buf, 999);
      encodeTag(buf, 3, 0);
      encodeVarint(buf, wireFormatJson);
      final decoded = decodeConformanceRequest(buf);
      expect(decoded['requested_output_format'], wireFormatJson);
    });

    test('unknown I64 field is skipped', () {
      final buf = <int>[];
      encodeTag(buf, 100, 1); // I64
      buf.addAll([1, 2, 3, 4, 5, 6, 7, 8]);
      encodeTag(buf, 3, 0);
      encodeVarint(buf, wireFormatProtobuf);
      final decoded = decodeConformanceRequest(buf);
      expect(decoded['requested_output_format'], wireFormatProtobuf);
    });

    test('unknown LEN field is skipped', () {
      final buf = <int>[];
      encodeTag(buf, 100, 2); // LEN
      encodeBytes(buf, [9, 9, 9]);
      encodeTag(buf, 4, 2);
      encodeBytes(buf, utf8.encode('kept'));
      final decoded = decodeConformanceRequest(buf);
      expect(decoded['message_type'], 'kept');
    });

    test('unknown I32 field is skipped', () {
      final buf = <int>[];
      encodeTag(buf, 100, 5); // I32
      encodeFixed32(buf, 0xDEADBEEF);
      encodeTag(buf, 3, 0);
      encodeVarint(buf, wireFormatJson);
      final decoded = decodeConformanceRequest(buf);
      expect(decoded['requested_output_format'], wireFormatJson);
    });

    test('unsupported unknown wire type throws', () {
      // Field 100, wire type 6 (illegal) → falls into the default skip branch.
      final buf = <int>[];
      buf.addAll(encodeVarint([], (100 << 3) | 6));
      expect(
        () => decodeConformanceRequest(buf),
        throwsA(isA<FormatException>()),
      );
    });

    test('empty input decodes to an empty map', () {
      expect(decodeConformanceRequest(<int>[]), isEmpty);
    });
  });

  group('encodeConformanceResponse / buildConformanceResponse', () {
    test('parse_error', () {
      final bytes = encodeConformanceResponse({'parse_error': 'bad'});
      // tag for field 1, LEN: (1<<3)|2 = 10
      expect(bytes[0], 10);
      expect(utf8.decode(bytes.sublist(2)), 'bad');
    });

    test('all oneof fields encode under the right tags', () {
      expect(encodeConformanceResponse({'parse_error': 'x'})[0], (1 << 3) | 2);
      expect(
        encodeConformanceResponse({'runtime_error': 'x'})[0],
        (2 << 3) | 2,
      );
      expect(
        encodeConformanceResponse({
          'protobuf_payload': <int>[7],
        })[0],
        (3 << 3) | 2,
      );
      expect(encodeConformanceResponse({'json_payload': 'x'})[0], (4 << 3) | 2);
      expect(encodeConformanceResponse({'skipped': 'x'})[0], (5 << 3) | 2);
      expect(
        encodeConformanceResponse({'serialize_error': 'x'})[0],
        (6 << 3) | 2,
      );
      expect(encodeConformanceResponse({'jspb_payload': 'x'})[0], (7 << 3) | 2);
      expect(encodeConformanceResponse({'text_payload': 'x'})[0], (8 << 3) | 2);
      expect(
        encodeConformanceResponse({'timeout_error': 'x'})[0],
        (9 << 3) | 2,
      );
    });

    test('empty response encodes to empty bytes', () {
      expect(encodeConformanceResponse(<String, Object?>{}), isEmpty);
    });

    test('protobuf_payload only encodes List<int>, ignores other types', () {
      expect(
        encodeConformanceResponse({'protobuf_payload': 'not bytes'}),
        isEmpty,
      );
    });

    test('buildConformanceResponse with parseError', () {
      final bytes = buildConformanceResponse(parseError: 'oops');
      expect(bytes, encodeConformanceResponse({'parse_error': 'oops'}));
    });

    test('buildConformanceResponse with each named arg', () {
      expect(
        buildConformanceResponse(serializeError: 's'),
        encodeConformanceResponse({'serialize_error': 's'}),
      );
      expect(
        buildConformanceResponse(runtimeError: 'r'),
        encodeConformanceResponse({'runtime_error': 'r'}),
      );
      expect(
        buildConformanceResponse(protobufPayload: [1, 2]),
        encodeConformanceResponse({
          'protobuf_payload': [1, 2],
        }),
      );
      expect(
        buildConformanceResponse(jsonPayload: 'j'),
        encodeConformanceResponse({'json_payload': 'j'}),
      );
      expect(
        buildConformanceResponse(skipped: 'k'),
        encodeConformanceResponse({'skipped': 'k'}),
      );
    });

    test('buildConformanceResponse with no args is empty', () {
      expect(buildConformanceResponse(), isEmpty);
    });
  });

  group('processConformanceRequest', () {
    final registry = <String, List<Map<String, Object?>>>{
      'foo.Msg': [
        {
          'name': 'id',
          'number': 1,
          'type': 'TYPE_INT32',
          'label': 'LABEL_OPTIONAL',
        },
        {
          'name': 'name',
          'number': 2,
          'type': 'TYPE_STRING',
          'label': 'LABEL_OPTIONAL',
        },
      ],
    };

    test('JSPB payload is skipped', () {
      final out = processConformanceRequest({
        'jspb_payload': '[]',
        'requested_output_format': wireFormatProtobuf,
      }, registry);
      expect(out.containsKey('skipped'), true);
    });

    test('TEXT payload is skipped', () {
      final out = processConformanceRequest({
        'text_payload': 'x',
        'requested_output_format': wireFormatProtobuf,
      }, registry);
      expect(out.containsKey('skipped'), true);
    });

    test('JSPB output format is skipped', () {
      final out = processConformanceRequest({
        'protobuf_payload': <int>[],
        'requested_output_format': wireFormatJspb,
      }, registry);
      expect(out['skipped'], contains('JSPB'));
    });

    test('TEXT_FORMAT output format is skipped', () {
      final out = processConformanceRequest({
        'protobuf_payload': <int>[],
        'requested_output_format': wireFormatTextFormat,
      }, registry);
      expect(out['skipped'], contains('TEXT_FORMAT'));
    });

    test('UNSPECIFIED output format is skipped', () {
      final out = processConformanceRequest({
        'protobuf_payload': <int>[],
        'requested_output_format': wireFormatUnspecified,
      }, registry);
      expect(out['skipped'], contains('UNSPECIFIED'));
    });

    test('no recognized payload is skipped', () {
      final out = processConformanceRequest({
        'requested_output_format': wireFormatProtobuf,
      }, registry);
      expect(out['skipped'], contains('no recognized payload'));
    });

    test('unknown message type is skipped', () {
      final out = processConformanceRequest({
        'protobuf_payload': <int>[],
        'requested_output_format': wireFormatProtobuf,
        'message_type': 'unknown.Type',
      }, registry);
      expect(out['skipped'], contains('no descriptor'));
    });

    test('protobuf -> protobuf round-trip', () {
      final payload = marshal({'id': 7, 'name': 'hi'}, registry['foo.Msg']!);
      final out = processConformanceRequest({
        'protobuf_payload': payload,
        'requested_output_format': wireFormatProtobuf,
        'message_type': 'foo.Msg',
      }, registry);
      expect(out['protobuf_payload'], payload);
    });

    test('protobuf -> JSON', () {
      final payload = marshal({'id': 7, 'name': 'hi'}, registry['foo.Msg']!);
      final out = processConformanceRequest({
        'protobuf_payload': payload,
        'requested_output_format': wireFormatJson,
        'message_type': 'foo.Msg',
      }, registry);
      final json = out['json_payload'] as String;
      expect(json, contains('"id":7'));
      expect(json, contains('"name":"hi"'));
    });

    test('JSON -> protobuf', () {
      final json = marshalJson({'id': 7, 'name': 'hi'}, registry['foo.Msg']!);
      final out = processConformanceRequest({
        'json_payload': json,
        'requested_output_format': wireFormatProtobuf,
        'message_type': 'foo.Msg',
      }, registry);
      final expected = marshal({'id': 7, 'name': 'hi'}, registry['foo.Msg']!);
      expect(out['protobuf_payload'], expected);
    });

    test('malformed protobuf payload yields a parse_error', () {
      final out = processConformanceRequest({
        // A truncated LEN field (claims more bytes than present).
        'protobuf_payload': <int>[0x12, 0x05, 0x01],
        'requested_output_format': wireFormatProtobuf,
        'message_type': 'foo.Msg',
      }, registry);
      expect(out['parse_error'], contains('parse error'));
    });

    test('malformed JSON payload yields a parse_error', () {
      final out = processConformanceRequest({
        'json_payload': '{not valid json',
        'requested_output_format': wireFormatJson,
        'message_type': 'foo.Msg',
      }, registry);
      expect(out['parse_error'], contains('parse error'));
    });

    test('an output format outside the WireFormat enum is skipped '
        '(post-parse default branch)', () {
      final payload = marshal({'id': 7}, registry['foo.Msg']!);
      final out = processConformanceRequest({
        'protobuf_payload': payload,
        // Not UNSPECIFIED/PROTOBUF/JSON/JSPB/TEXT_FORMAT — reaches the
        // switch's default branch *after* a successful parse.
        'requested_output_format': 99,
        'message_type': 'foo.Msg',
      }, registry);
      expect(out['skipped'], contains('unsupported output format 99'));
    });
  });

  group('wire format constants', () {
    test('have their conformance.proto values', () {
      expect(wireFormatUnspecified, 0);
      expect(wireFormatProtobuf, 1);
      expect(wireFormatJson, 2);
      expect(wireFormatJspb, 3);
      expect(wireFormatTextFormat, 4);
    });
  });
}
