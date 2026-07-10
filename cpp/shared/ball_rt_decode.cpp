// #18 Stage 3 — descriptor-driven binary decode via ball_protobuf_rt.h.
//
// Confines the entire `ball_protobuf` global-`BallDyn` universe to this one TU.
// The public interface (ball_rt_decode.h) is pure std::string, so `ball_file.h`
// and its consumers never see a second `BallDyn` definition.

#include "ball_rt_decode.h"

#include <cstdint>
#include <stdexcept>
#include <string>

#include "ball_protobuf_rt.h"       // Ball's compiled protobuf runtime (global BallDyn).
#include "ball_program_descriptor.h"  // ball.v1 message descriptors (generated).

namespace ball {
namespace rt {
namespace {

// google.protobuf.Any wire shape: type_url = 1 (string), value = 2 (bytes).
BallDyn anyDescriptor() {
    BallMap type_url;
    type_url["name"s] = std::any(std::string("type_url"));
    type_url["number"s] = std::any(static_cast<int64_t>(1));
    type_url["type"s] = std::any(std::string("TYPE_STRING"));

    BallMap value;
    value["name"s] = std::any(std::string("value"));
    value["number"s] = std::any(static_cast<int64_t>(2));
    value["type"s] = std::any(std::string("TYPE_BYTES"));

    BallList fields;
    fields.push_back(std::any(BallDyn(std::move(type_url))));
    fields.push_back(std::any(BallDyn(std::move(value))));
    return BallDyn(std::move(fields));
}

// Raw bytes → a ball_protobuf "buffer" (a list of 0..255 int byte values).
BallDyn bytesToBuffer(const std::string& bytes) {
    BallList buf;
    buf.reserve(bytes.size());
    for (unsigned char c : bytes) {
        buf.push_back(std::any(static_cast<int64_t>(c)));
    }
    return BallDyn(std::move(buf));
}

// A ball_protobuf buffer (list of int byte values) → raw bytes.
std::string bufferToBytes(BallDyn buffer) {
    const int64_t n = ball_length(buffer);
    std::string out;
    out.reserve(static_cast<std::size_t>(n));
    for (int64_t i = 0; i < n; ++i) {
        out.push_back(static_cast<char>(
            static_cast<unsigned char>(static_cast<int64_t>(buffer[i]))));
    }
    return out;
}

bool ends_with(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() &&
           s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// ── Hand-written wire descriptors for the embedded google.protobuf types ────
//
// ball.proto embeds exactly three google.protobuf shapes: `Struct metadata`,
// `DescriptorProto descriptor`, and `repeated EnumDescriptorProto enums`. The
// generated runtime descriptor deliberately carries them as opaque TYPE_BYTES
// (wire-identical), so decoding them to JSON needs these small descriptors.
// Field maps mirror cpp/shared/ball_program_descriptor.h's `_push` shape (the
// keys ball_protobuf's unmarshal/_marshalToMap read: name/number/type/label/
// repeated/typeName/messageDescriptor/oneof/mapEntry/keyType/valueType, plus
// jsonName/enumValues/features consumed by the JSON codec).

// Minimal field-descriptor builder.
BallMap fd(const char* name, int64_t number, const char* type) {
    BallMap m;
    m["name"s] = std::any(std::string(name));
    m["number"s] = std::any(number);
    m["type"s] = std::any(std::string(type));
    return m;
}

// proto2 explicit presence (descriptor.proto is proto2): a set-on-the-wire
// field is emitted even at its zero value (e.g. EnumValueDescriptorProto
// {name:"RED", number:0} must keep its "number": 0 in JSON).
void mark_explicit(BallMap& m) {
    BallMap features;
    features["field_presence"s] = std::any(std::string("EXPLICIT"));
    m["features"s] = std::any(BallDyn(std::move(features)));
}

void push_field(BallDyn& msg, BallMap field) {
    msg._listPtr()->push_back(std::any(BallDyn(std::move(field))));
}

// google.protobuf.{Struct,Value,ListValue} — mutually recursive, expressed via
// shared_ptr-backed BallList sharing (a copied BallDyn shares the SAME
// underlying vector — the two-phase build mirrors ball_program_descriptor.h).
struct WktDescriptors {
    BallDyn structD{BallList{}};
    BallDyn valueD{BallList{}};
    BallDyn listValueD{BallList{}};
};

const WktDescriptors& wkt() {
    static const WktDescriptors d = [] {
        WktDescriptors w;
        // Struct: map<string, Value> fields = 1;
        {
            BallMap f = fd("fields", 1, "TYPE_MESSAGE");
            f["mapEntry"s] = std::any(true);
            f["keyType"s] = std::any(std::string("TYPE_STRING"));
            f["valueType"s] = std::any(std::string("TYPE_MESSAGE"));
            f["messageDescriptor"s] = std::any(w.valueD);
            push_field(w.structD, std::move(f));
        }
        // Value: oneof kind { null_value=1 enum; number_value=2 double;
        //   string_value=3; bool_value=4; struct_value=5; list_value=6; }
        // Field NAMES are the proto snake_case names — ball_protobuf's native
        // _valueMsgToJson/_structMsgToJson read exactly these keys.
        {
            BallMap f = fd("null_value", 1, "TYPE_ENUM");
            f["oneof"s] = std::any(std::string("kind"));
            push_field(w.valueD, std::move(f));
        }
        {
            BallMap f = fd("number_value", 2, "TYPE_DOUBLE");
            f["oneof"s] = std::any(std::string("kind"));
            push_field(w.valueD, std::move(f));
        }
        {
            BallMap f = fd("string_value", 3, "TYPE_STRING");
            f["oneof"s] = std::any(std::string("kind"));
            push_field(w.valueD, std::move(f));
        }
        {
            BallMap f = fd("bool_value", 4, "TYPE_BOOL");
            f["oneof"s] = std::any(std::string("kind"));
            push_field(w.valueD, std::move(f));
        }
        {
            BallMap f = fd("struct_value", 5, "TYPE_MESSAGE");
            f["oneof"s] = std::any(std::string("kind"));
            f["typeName"s] = std::any(std::string("google.protobuf.Struct"));
            f["messageDescriptor"s] = std::any(w.structD);
            push_field(w.valueD, std::move(f));
        }
        {
            BallMap f = fd("list_value", 6, "TYPE_MESSAGE");
            f["oneof"s] = std::any(std::string("kind"));
            f["typeName"s] = std::any(std::string("google.protobuf.ListValue"));
            f["messageDescriptor"s] = std::any(w.listValueD);
            push_field(w.valueD, std::move(f));
        }
        // ListValue: repeated Value values = 1;
        {
            BallMap f = fd("values", 1, "TYPE_MESSAGE");
            f["label"s] = std::any(std::string("LABEL_REPEATED"));
            f["repeated"s] = std::any(true);
            f["typeName"s] = std::any(std::string("google.protobuf.Value"));
            f["messageDescriptor"s] = std::any(w.valueD);
            push_field(w.listValueD, std::move(f));
        }
        return w;
    }();
    return d;
}

// FieldDescriptorProto.Type / .Label enum value→NAME tables (proto3-JSON emits
// enums as NAME strings). Keys are stringified ints — BallDyn maps are
// string-keyed and fieldToJson's `enumValues[value]` lookup stringifies ints.
BallDyn field_type_enum_values() {
    static const char* const names[] = {
        "TYPE_DOUBLE", "TYPE_FLOAT", "TYPE_INT64", "TYPE_UINT64",
        "TYPE_INT32", "TYPE_FIXED64", "TYPE_FIXED32", "TYPE_BOOL",
        "TYPE_STRING", "TYPE_GROUP", "TYPE_MESSAGE", "TYPE_BYTES",
        "TYPE_UINT32", "TYPE_ENUM", "TYPE_SFIXED32", "TYPE_SFIXED64",
        "TYPE_SINT32", "TYPE_SINT64"};
    BallMap m;
    for (int i = 0; i < 18; ++i) {
        m[std::to_string(i + 1)] = std::any(std::string(names[i]));
    }
    return BallDyn(std::move(m));
}

BallDyn field_label_enum_values() {
    BallMap m;
    m["1"s] = std::any(std::string("LABEL_OPTIONAL"));
    m["2"s] = std::any(std::string("LABEL_REQUIRED"));
    m["3"s] = std::any(std::string("LABEL_REPEATED"));
    return BallDyn(std::move(m));
}

// google.protobuf.DescriptorProto (the subset the Ball encoders emit: name +
// field[]{name, number, label, type, type_name}). Fields outside this subset
// land in ball_protobuf's $unknown capture and are omitted from JSON.
const BallDyn& descriptor_proto_descriptor() {
    static const BallDyn d = [] {
        BallDyn fieldD{BallList{}};
        // FieldDescriptorProto
        {
            BallMap f = fd("name", 1, "TYPE_STRING");
            mark_explicit(f);
            push_field(fieldD, std::move(f));
        }
        {
            BallMap f = fd("number", 3, "TYPE_INT32");
            mark_explicit(f);
            push_field(fieldD, std::move(f));
        }
        {
            BallMap f = fd("label", 4, "TYPE_ENUM");
            f["enumValues"s] = std::any(field_label_enum_values());
            mark_explicit(f);
            push_field(fieldD, std::move(f));
        }
        {
            BallMap f = fd("type", 5, "TYPE_ENUM");
            f["enumValues"s] = std::any(field_type_enum_values());
            mark_explicit(f);
            push_field(fieldD, std::move(f));
        }
        {
            BallMap f = fd("type_name", 6, "TYPE_STRING");
            // Canonical Ball JSON keeps the snake_case key (the encoder
            // serialized descriptors with preserve_proto_field_names) — pin it
            // via jsonName so marshalJson does not camelCase it to `typeName`.
            f["jsonName"s] = std::any(std::string("type_name"));
            mark_explicit(f);
            push_field(fieldD, std::move(f));
        }
        BallDyn descD{BallList{}};
        {
            BallMap f = fd("name", 1, "TYPE_STRING");
            mark_explicit(f);
            push_field(descD, std::move(f));
        }
        {
            BallMap f = fd("field", 2, "TYPE_MESSAGE");
            f["label"s] = std::any(std::string("LABEL_REPEATED"));
            f["repeated"s] = std::any(true);
            f["typeName"s] =
                std::any(std::string("google.protobuf.FieldDescriptorProto"));
            f["messageDescriptor"s] = std::any(fieldD);
            push_field(descD, std::move(f));
        }
        return descD;
    }();
    return d;
}

// google.protobuf.EnumDescriptorProto (subset: name + value[]{name, number}).
const BallDyn& enum_descriptor_proto_descriptor() {
    static const BallDyn d = [] {
        BallDyn valueD{BallList{}};
        {
            BallMap f = fd("name", 1, "TYPE_STRING");
            mark_explicit(f);
            push_field(valueD, std::move(f));
        }
        {
            // number:0 (e.g. the first enum value) MUST keep its explicit
            // "number": 0 in JSON — proto2 explicit presence.
            BallMap f = fd("number", 2, "TYPE_INT32");
            mark_explicit(f);
            push_field(valueD, std::move(f));
        }
        BallDyn enumD{BallList{}};
        {
            BallMap f = fd("name", 1, "TYPE_STRING");
            mark_explicit(f);
            push_field(enumD, std::move(f));
        }
        {
            BallMap f = fd("value", 2, "TYPE_MESSAGE");
            f["label"s] = std::any(std::string("LABEL_REPEATED"));
            f["repeated"s] = std::any(true);
            f["typeName"s] =
                std::any(std::string("google.protobuf.EnumValueDescriptorProto"));
            f["messageDescriptor"s] = std::any(valueD);
            push_field(enumD, std::move(f));
        }
        return enumD;
    }();
    return d;
}

// base64 text → ball_protobuf byte-list buffer (the runtime's own codec).
BallDyn b64ToBuffer(const std::string& b64) {
    return BallDyn(decode(base64, BallDyn(b64)));
}

// Faithful JSON writer for the native value tree `_structMsgToJson` returns
// (null/bool/double/string/list/ordered-map). The runtime's own
// `_ball_json_encode` SKIPS `__`-prefixed and `type_args` map keys (a
// Ball-internal rendering rule for runtime objects) — fine for message maps
// whose keys are proto field names, but a user metadata Struct may carry any
// key, and silently dropping one would corrupt the decode. Reuses the
// runtime's `_ball_json_escape` (string escaping) and `ball_to_string(double)`
// (Dart-style, shortest-round-trip) so the output matches the canonical
// Dart-encoded `.ball.json` byte-for-byte.
void write_struct_json(const std::any& v, std::string& out) {
    const std::any& u = _BallDynUnwrapper::unwrap(v);
    if (!u.has_value()) {
        out += "null";
        return;
    }
    if (u.type() == typeid(bool)) {
        out += std::any_cast<bool>(u) ? "true" : "false";
        return;
    }
    if (u.type() == typeid(int64_t)) {
        out += std::to_string(std::any_cast<int64_t>(u));
        return;
    }
    if (u.type() == typeid(double)) {
        out += ball_to_string(std::any_cast<double>(u));
        return;
    }
    if (u.type() == typeid(std::string)) {
        out += _ball_json_escape(std::any_cast<const std::string&>(u));
        return;
    }
    BallDyn dyn(u);
    if (const BallList* lp = dyn._listPtr()) {
        out += '[';
        bool first = true;
        for (const auto& e : *lp) {
            if (!first) out += ',';
            first = false;
            write_struct_json(e, out);
        }
        out += ']';
        return;
    }
    if (const BallOrderedMap* mp = dyn._orderedMapPtr()) {
        out += '{';
        bool first = true;
        for (const auto& [k, val] : mp->entries_) {
            if (!first) out += ',';
            first = false;
            out += _ball_json_escape(k);
            out += ':';
            write_struct_json(val, out);
        }
        out += '}';
        return;
    }
    throw std::runtime_error(
        "DecodeStructJsonB64: unexpected value kind in decoded Struct");
}

}  // namespace

std::string DecodeAnyPayload(const std::string& any_bytes, bool& out_is_program) {
    // 1. Decode the google.protobuf.Any envelope via ball_protobuf.
    BallDyn any = ball_protobuf::unmarshal(bytesToBuffer(any_bytes), anyDescriptor());
    BallDyn type_url_dyn = any["type_url"s];
    const std::string type_url =
        type_url_dyn.has_value() ? static_cast<std::string>(type_url_dyn)
                                 : std::string();

    // 2. Pick the payload descriptor from the type URL.
    BallDyn payload_descriptor;
    if (ends_with(type_url, "/ball.v1.Program")) {
        out_is_program = true;
        payload_descriptor = ball_protobuf::descriptor::programDescriptor();
    } else if (ends_with(type_url, "/ball.v1.Module")) {
        out_is_program = false;
        payload_descriptor = ball_protobuf::descriptor::moduleDescriptor();
    } else {
        throw std::runtime_error(
            "ball_protobuf DecodeAnyPayload: unknown Any type_url \"" + type_url +
            "\"");
    }

    // 3. Descriptor-driven unmarshal of the payload, then re-marshal to bare
    //    Program/Module wire bytes (opaque google.protobuf.* fields and any
    //    unknown fields are preserved verbatim — see ball_program_descriptor.h).
    BallDyn value_buf = any["value"s];  // list-of-int payload bytes (may be empty)
    BallDyn message = ball_protobuf::unmarshal(value_buf, payload_descriptor);
    BallDyn re_marshaled = ball_protobuf::marshal(message, payload_descriptor);
    return bufferToBytes(re_marshaled);
}

std::string DecodeAnyPayloadJson(const std::string& any_bytes,
                                 bool& out_is_program) {
    // 1. Decode the google.protobuf.Any envelope via ball_protobuf.
    BallDyn any = ball_protobuf::unmarshal(bytesToBuffer(any_bytes), anyDescriptor());
    BallDyn type_url_dyn = any["type_url"s];
    const std::string type_url =
        type_url_dyn.has_value() ? static_cast<std::string>(type_url_dyn)
                                 : std::string();

    // 2. Pick the payload descriptor from the type URL.
    BallDyn payload_descriptor;
    if (ends_with(type_url, "/ball.v1.Program")) {
        out_is_program = true;
        payload_descriptor = ball_protobuf::descriptor::programDescriptor();
    } else if (ends_with(type_url, "/ball.v1.Module")) {
        out_is_program = false;
        payload_descriptor = ball_protobuf::descriptor::moduleDescriptor();
    } else {
        throw std::runtime_error(
            "ball_protobuf DecodeAnyPayloadJson: unknown Any type_url \"" +
            type_url + "\"");
    }

    // 3. Descriptor-driven unmarshal, then serialize to proto3-JSON via
    //    ball_protobuf's own JSON codec (WKT-aware). The google.protobuf.*
    //    fields serialize as base64 strings (they are TYPE_BYTES in the
    //    runtime descriptor); ball_file.h decodes them via the helpers below.
    BallDyn value_buf = any["value"s];  // list-of-int payload bytes (may be empty)
    BallDyn message = ball_protobuf::unmarshal(value_buf, payload_descriptor);
    BallDyn json_dyn = ball_protobuf::marshalJson(message, payload_descriptor);
    return json_dyn.has_value() ? static_cast<std::string>(json_dyn)
                                : std::string("{}");
}

std::string DecodeStructJsonB64(const std::string& b64) {
    // Wire → Struct message (map field `fields` of Value messages) → native
    // values via ball_protobuf's own Struct-WKT converter → JSON text via the
    // faithful writer above (NOT `jsonEncode`, a Dart-toString stub, and NOT
    // `_ball_json_encode`, which skips `__`-prefixed / `type_args` map keys).
    BallDyn msg = ball_protobuf::unmarshal(b64ToBuffer(b64), wkt().structD);
    BallDyn native = ball_protobuf::_structMsgToJson(msg);
    std::string out;
    write_struct_json(native._val, out);
    return out;
}

std::string DecodeDescriptorProtoJsonB64(const std::string& b64) {
    const BallDyn& d = descriptor_proto_descriptor();
    BallDyn msg = ball_protobuf::unmarshal(b64ToBuffer(b64), d);
    BallDyn json_dyn = ball_protobuf::marshalJson(msg, d);
    return json_dyn.has_value() ? static_cast<std::string>(json_dyn)
                                : std::string("{}");
}

std::string DecodeEnumDescriptorProtoJsonB64(const std::string& b64) {
    const BallDyn& d = enum_descriptor_proto_descriptor();
    BallDyn msg = ball_protobuf::unmarshal(b64ToBuffer(b64), d);
    BallDyn json_dyn = ball_protobuf::marshalJson(msg, d);
    return json_dyn.has_value() ? static_cast<std::string>(json_dyn)
                                : std::string("{}");
}

}  // namespace rt
}  // namespace ball
