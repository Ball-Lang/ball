// Ball C++ ball_file.h Tests
//
// Direct unit coverage for cpp/shared/include/ball_file.h — the
// self-describing google.protobuf.Any envelope reader (BallFileFormatException
// paths, the hand-rolled "@type" JSON scanner, binary/JSON dispatch, and the
// Program/Module discrimination helpers).
//
// #18 Stage 5: the loader is now libprotobuf-free — it returns `ball::ir`
// Program/Module (loaded via nlohmann/json for JSON, and via Ball's OWN
// compiled protobuf runtime for the binary `.ball.pb`/`.ball.bin` Any form).
// The binary tests here no longer construct their `google.protobuf.Any`
// envelopes with libprotobuf; instead they encode the Any wire bytes with a
// minimal, self-contained protobuf encoder (the wire format is a stable spec —
// these are golden vectors that pin the rt binary path without linking google).

#include "ball_file.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

using namespace ball;
namespace fs = std::filesystem;

// ================================================================
// Test framework. Unlike the sibling cpp/test/test_*.cpp files, tests are
// DEFERRED to main() rather than run in the static-init Register constructor:
// the binary-decode tests call into ball_protobuf's cross-TU global descriptors
// (in ball_shared/ball_rt_decode.cpp), and running at static-init time risks the
// static-initialization-order fiasco (those globals may not be constructed yet
// → an empty decode). Registering a function pointer at static-init and running
// it from main() sidesteps that entirely.
// ================================================================

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

using BallTestFn = void (*)();
struct BallTestCase { const char* name; BallTestFn fn; };
static std::vector<BallTestCase>& test_registry() {
    static std::vector<BallTestCase> r;
    return r;
}

#define TEST(name)                                                       \
    static void test_##name();                                          \
    struct Register_##name {                                            \
        Register_##name() { test_registry().push_back({#name, test_##name}); } \
    } register_##name;                                                  \
    static void test_##name()

#define ASSERT_TRUE(cond)                                                \
    do {                                                                 \
        if (!(cond)) {                                                   \
            throw std::runtime_error("ASSERT_TRUE failed: " #cond);      \
        }                                                                \
    } while (0)

#define ASSERT_EQ(a, b)                                                  \
    do {                                                                 \
        if (!((a) == (b))) {                                             \
            std::ostringstream oss;                                     \
            oss << "ASSERT_EQ failed: " #a " != " #b << " (got \""       \
                << (a) << "\" vs \"" << (b) << "\")";                    \
            throw std::runtime_error(oss.str());                        \
        }                                                                \
    } while (0)

// Expects `expr` to throw ball::BallFileFormatException whose what() contains
// `needle`.
#define ASSERT_THROWS_CONTAINING(expr, needle)                           \
    do {                                                                  \
        bool threw = false;                                              \
        try {                                                            \
            (void)(expr);                                                \
        } catch (const ball::BallFileFormatException& e) {               \
            threw = true;                                                \
            std::string msg = e.what();                                  \
            if (msg.find(needle) == std::string::npos) {                 \
                throw std::runtime_error(                                \
                    "wrong exception message: \"" + msg +                \
                    "\" does not contain \"" + (needle) + "\"");         \
            }                                                            \
        }                                                                \
        if (!threw) {                                                    \
            throw std::runtime_error(                                    \
                "expected BallFileFormatException, none thrown");        \
        }                                                                 \
    } while (0)

// Expects `expr` to throw SOME std::exception (message text not pinned — the
// exact error string of a malformed-wire failure is an implementation detail of
// Ball's protobuf runtime, unlike the loader's own BallFileFormatException).
#define ASSERT_THROWS_ANY(expr)                                           \
    do {                                                                  \
        bool threw = false;                                              \
        try {                                                            \
            (void)(expr);                                                \
        } catch (const std::exception&) {                                \
            threw = true;                                                \
        }                                                                \
        if (!threw) {                                                    \
            throw std::runtime_error("expected an exception, none thrown"); \
        }                                                                 \
    } while (0)

// ================================================================
// Helpers
// ================================================================

static fs::path write_temp_file(const std::string& stem, const std::string& content) {
    fs::path p = fs::temp_directory_path() / ("ball_file_test_" + stem);
    std::ofstream out(p, std::ios::binary);
    out << content;
    out.close();
    return p;
}

static std::string program_json(const std::string& name) {
    return "{\"@type\":\"type.googleapis.com/ball.v1.Program\",\"name\":\"" +
           name + "\"}";
}

static std::string module_json(const std::string& name) {
    return "{\"@type\":\"type.googleapis.com/ball.v1.Module\",\"name\":\"" +
           name + "\"}";
}

// ── Minimal protobuf wire encoder (golden-vector generator) ────────────────
// Enough to build a google.protobuf.Any wrapping a {name} message. The wire
// format is a fixed spec, so these bytes ARE the golden inputs captured from
// the oracle — they pin ball_file.h's binary path without linking libprotobuf.

static std::string encode_varint(uint64_t v) {
    std::string out;
    do {
        uint8_t b = static_cast<uint8_t>(v & 0x7F);
        v >>= 7;
        if (v) b |= 0x80;
        out.push_back(static_cast<char>(b));
    } while (v);
    return out;
}

// A length-delimited field (wiretype 2): tag + varint(len) + payload.
static std::string encode_len_delim(int field_number, const std::string& payload) {
    std::string out;
    out += encode_varint((static_cast<uint64_t>(field_number) << 3) | 2);
    out += encode_varint(payload.size());
    out += payload;
    return out;
}

// A ball.v1.Program/Module with only `name` set (field 1, string).
static std::string make_named_message_bytes(const std::string& name) {
    return encode_len_delim(1, name);
}

// A serialized google.protobuf.Any: type_url (field 1) + value bytes (field 2).
static std::string make_any_bytes(const std::string& type_url,
                                  const std::string& payload) {
    return encode_len_delim(1, type_url) + encode_len_delim(2, payload);
}

static std::string program_any_bytes(const std::string& name) {
    return make_any_bytes("type.googleapis.com/ball.v1.Program",
                          make_named_message_bytes(name));
}
static std::string module_any_bytes(const std::string& name) {
    return make_any_bytes("type.googleapis.com/ball.v1.Module",
                          make_named_message_bytes(name));
}

// ================================================================
// DecodeBallFileJson — the "@type" scanner's error branches.
// ================================================================

TEST(json_not_an_object_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson("123", p, m), "must be an object");
}

TEST(json_missing_type_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson("{}", p, m), "missing \"@type\"");
}

TEST(json_malformed_type_member_missing_colon_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    ASSERT_THROWS_CONTAINING(
        DecodeBallFileJson(R"({"@type" "type.googleapis.com/ball.v1.Program"})", p, m),
        "malformed \"@type\" member");
}

TEST(json_type_value_not_string_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson(R"({"@type": 123})", p, m),
                              "\"@type\" value must be a string");
}

TEST(json_unterminated_type_value_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson(R"({"@type": "abc)", p, m),
                              "unterminated");
}

TEST(json_unknown_type_url_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    ASSERT_THROWS_CONTAINING(
        DecodeBallFileJson(R"({"@type": "type.googleapis.com/some.Other", "x": 1})", p, m),
        "unknown ball file @type");
}

TEST(json_valid_program_decodes) {
    ball::ir::Program p;
    ball::ir::Module m;
    auto kind = DecodeBallFileJson(program_json("hello"), p, m);
    ASSERT_TRUE(kind == BallFileKind::kProgram);
    ASSERT_EQ(p.name, std::string("hello"));
}

TEST(json_valid_module_decodes) {
    ball::ir::Program p;
    ball::ir::Module m;
    auto kind = DecodeBallFileJson(module_json("mymod"), p, m);
    ASSERT_TRUE(kind == BallFileKind::kModule);
    ASSERT_EQ(m.name, std::string("mymod"));
}

// #18 Stage 5: ball::ir's proto3-JSON loader is intentionally lenient about a
// scalar field carried at the wrong JSON type (a robustness property the former
// google JsonStringToMessage did not share) — a numeric `name` reads back as
// the string default "" rather than throwing. (Malformed JSON — e.g. truncated
// braces — still throws from nlohmann's parser; the @type scanner guards the
// envelope shape.)
TEST(json_wrong_typed_field_tolerated) {
    ball::ir::Program p;
    ball::ir::Module m;
    auto kind = DecodeBallFileJson(
        R"({"@type":"type.googleapis.com/ball.v1.Program","name":123})", p, m);
    ASSERT_TRUE(kind == BallFileKind::kProgram);
    ASSERT_EQ(p.name, std::string(""));
}

TEST(json_wrong_typed_module_field_tolerated) {
    ball::ir::Program p;
    ball::ir::Module m;
    auto kind = DecodeBallFileJson(
        R"({"@type":"type.googleapis.com/ball.v1.Module","name":123})", p, m);
    ASSERT_TRUE(kind == BallFileKind::kModule);
    ASSERT_EQ(m.name, std::string(""));
}

// A trailing-member @type (no comma after) exercises the "drop leading
// comma" branch of extract_type_url_and_strip, instead of the "drop trailing
// comma" branch every other test above hits.
TEST(json_type_as_last_member_strips_leading_comma) {
    ball::ir::Program p;
    ball::ir::Module m;
    auto kind = DecodeBallFileJson(
        R"({"name":"trailing","@type":"type.googleapis.com/ball.v1.Program"})", p, m);
    ASSERT_TRUE(kind == BallFileKind::kProgram);
    ASSERT_EQ(p.name, std::string("trailing"));
}

// ================================================================
// DecodeBallFileBinary — google.protobuf.Any envelopes decoded by Ball's own
// compiled protobuf runtime (golden wire vectors, no libprotobuf).
// ================================================================

TEST(binary_valid_program_decodes) {
    ball::ir::Program p;
    ball::ir::Module m;
    auto kind = DecodeBallFileBinary(program_any_bytes("bin_prog"), p, m);
    ASSERT_TRUE(kind == BallFileKind::kProgram);
    ASSERT_EQ(p.name, std::string("bin_prog"));
}

TEST(binary_valid_module_decodes) {
    ball::ir::Program p;
    ball::ir::Module m;
    auto kind = DecodeBallFileBinary(module_any_bytes("bin_mod"), p, m);
    ASSERT_TRUE(kind == BallFileKind::kModule);
    ASSERT_EQ(m.name, std::string("bin_mod"));
}

TEST(binary_unknown_type_url_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    // An Any whose type_url is neither ball.v1.Program nor ball.v1.Module.
    std::string bytes =
        make_any_bytes("type.googleapis.com/google.protobuf.Struct", "");
    ASSERT_THROWS_CONTAINING(DecodeBallFileBinary(bytes, p, m), "unknown");
}

TEST(binary_malformed_bytes_throws) {
    ball::ir::Program p;
    ball::ir::Module m;
    // A well-formed Any whose Program payload is a truncated length-delimited
    // field (field 1 declares 5 bytes but only 2 follow) — the rt unmarshal
    // must reject it rather than silently return a half-decoded message.
    std::string bad_payload = encode_len_delim(1, "xx");  // len 2
    bad_payload[1] = 0x05;  // lie: claim length 5
    std::string bytes =
        make_any_bytes("type.googleapis.com/ball.v1.Program", bad_payload);
    ASSERT_THROWS_ANY(DecodeBallFileBinary(bytes, p, m));
}

// ================================================================
// DecodeBallFile — extension-driven binary/JSON dispatch.
// ================================================================

TEST(decode_ball_file_dispatches_by_extension) {
    ball::ir::Program p1;
    ball::ir::Module m1;
    ASSERT_TRUE(DecodeBallFile("x.ball.json", program_json("j"), p1, m1) ==
                BallFileKind::kProgram);

    std::string bytes = program_any_bytes("bp");
    ball::ir::Program p2;
    ball::ir::Module m2;
    ASSERT_TRUE(DecodeBallFile("x.ball.pb", bytes, p2, m2) == BallFileKind::kProgram);
    ASSERT_EQ(p2.name, std::string("bp"));
    ball::ir::Program p3;
    ball::ir::Module m3;
    ASSERT_TRUE(DecodeBallFile("x.ball.bin", bytes, p3, m3) == BallFileKind::kProgram);
}

// ================================================================
// LoadProgram / LoadModule / DecodeProgram — kind-mismatch + file I/O.
// ================================================================

TEST(load_program_reads_real_file) {
    fs::path path = write_temp_file("load_program.ball.json", program_json("fromfile"));
    ball::ir::Program p = LoadProgram(path.string());
    ASSERT_EQ(p.name, std::string("fromfile"));
    fs::remove(path);
}

TEST(load_module_reads_real_file) {
    fs::path path = write_temp_file("load_module.ball.json", module_json("modfromfile"));
    ball::ir::Module m = LoadModule(path.string());
    ASSERT_EQ(m.name, std::string("modfromfile"));
    fs::remove(path);
}

TEST(load_program_on_module_file_throws) {
    fs::path path = write_temp_file("wrong_kind.ball.json", module_json("m"));
    bool threw = false;
    try {
        LoadProgram(path.string());
    } catch (const BallFileFormatException& e) {
        threw = true;
        std::string msg = e.what();
        ASSERT_TRUE(msg.find("expected a Program ball file but got a Module") !=
                    std::string::npos);
    }
    ASSERT_TRUE(threw);
    fs::remove(path);
}

TEST(load_module_on_program_file_throws) {
    fs::path path = write_temp_file("wrong_kind2.ball.json", program_json("p"));
    bool threw = false;
    try {
        LoadModule(path.string());
    } catch (const BallFileFormatException& e) {
        threw = true;
        std::string msg = e.what();
        ASSERT_TRUE(msg.find("expected a Module ball file but got a Program") !=
                    std::string::npos);
    }
    ASSERT_TRUE(threw);
    fs::remove(path);
}

TEST(load_program_missing_file_throws) {
    ASSERT_THROWS_CONTAINING(LoadProgram("/no/such/path/does_not_exist.ball.json"),
                              "could not open");
}

TEST(decode_program_on_module_content_throws) {
    ASSERT_THROWS_CONTAINING(DecodeProgram("x.ball.json", module_json("m")),
                              "expected a Program ball file but got a Module");
}

TEST(decode_program_valid_program_content) {
    ball::ir::Program p = DecodeProgram("x.ball.json", program_json("direct"));
    ASSERT_EQ(p.name, std::string("direct"));
}

// ================================================================
// ball_rt_decode's opaque-payload helpers — DecodeStructJsonB64 /
// DecodeDescriptorProtoJsonB64 / DecodeEnumDescriptorProtoJsonB64 — direct
// golden-vector coverage (issue #63). These are ball_file.h's materialization
// seams for `Struct metadata` / `DescriptorProto descriptor` /
// `EnumDescriptorProto enums[i]`, carried as opaque TYPE_BYTES by the runtime
// descriptor and emitted by marshalJson as base64 strings. Before these tests,
// their entire hand-written machinery in cpp/shared/ball_rt_decode.cpp (the
// WKT Struct/Value/ListValue wire descriptors, the DescriptorProto/
// EnumDescriptorProto descriptors with their proto2 explicit-presence marks,
// and the faithful write_struct_json JSON writer) was exercised only when a
// binary .ball.pb happened to carry metadata — i.e. never, in any instrumented
// build. Wire bytes are hand-encoded with the same minimal golden-vector
// encoder as the Any tests above; base64 TEXT in, JSON text out.
// ================================================================

// Standard base64 with padding — produces the TEXT form the helpers take
// (the inverse of the runtime's own `decode(base64, …)`).
static std::string b64_encode(const std::string& bytes) {
    static const char* const tbl =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    std::size_t i = 0;
    while (i + 2 < bytes.size()) {
        uint32_t v = (static_cast<uint8_t>(bytes[i]) << 16) |
                     (static_cast<uint8_t>(bytes[i + 1]) << 8) |
                     static_cast<uint8_t>(bytes[i + 2]);
        out += tbl[(v >> 18) & 63];
        out += tbl[(v >> 12) & 63];
        out += tbl[(v >> 6) & 63];
        out += tbl[v & 63];
        i += 3;
    }
    if (i + 1 == bytes.size()) {
        uint32_t v = static_cast<uint8_t>(bytes[i]) << 16;
        out += tbl[(v >> 18) & 63];
        out += tbl[(v >> 12) & 63];
        out += "==";
    } else if (i + 2 == bytes.size()) {
        uint32_t v = (static_cast<uint8_t>(bytes[i]) << 16) |
                     (static_cast<uint8_t>(bytes[i + 1]) << 8);
        out += tbl[(v >> 18) & 63];
        out += tbl[(v >> 12) & 63];
        out += tbl[(v >> 6) & 63];
        out += '=';
    }
    return out;
}

// A varint-typed field (wiretype 0): tag + varint(value).
static std::string encode_varint_field(int field_number, uint64_t v) {
    return encode_varint((static_cast<uint64_t>(field_number) << 3) | 0) +
           encode_varint(v);
}

// A fixed64 double field (wiretype 1): tag + 8 little-endian IEEE-754 bytes.
static std::string encode_double_field(int field_number, double v) {
    std::string out =
        encode_varint((static_cast<uint64_t>(field_number) << 3) | 1);
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(v), "double must be 64-bit");
    std::memcpy(&bits, &v, sizeof(bits));
    for (int b = 0; b < 8; ++b) {
        out.push_back(static_cast<char>((bits >> (8 * b)) & 0xFF));
    }
    return out;
}

// One google.protobuf.Struct `fields` map entry (field 1, message):
// MapEntry{ key = 1 (string), value = 2 (google.protobuf.Value message) }.
static std::string struct_entry(const std::string& key,
                                const std::string& value_msg) {
    return encode_len_delim(
        1, encode_len_delim(1, key) + encode_len_delim(2, value_msg));
}

TEST(rt_decode_struct_b64_scalar_values) {
    // {"s":"hi","d":1.5,"b":true,"n":null} — one entry per Value oneof scalar
    // arm: string_value=3, number_value=2 (fixed64 double), bool_value=4,
    // null_value=1 (enum, varint 0).
    std::string s = struct_entry("s", encode_len_delim(3, "hi")) +
                    struct_entry("d", encode_double_field(2, 1.5)) +
                    struct_entry("b", encode_varint_field(4, 1)) +
                    struct_entry("n", encode_varint_field(1, 0));
    ASSERT_EQ(ball::rt::DecodeStructJsonB64(b64_encode(s)),
              std::string(R"({"s":"hi","d":1.5,"b":true,"n":null})"));
}

TEST(rt_decode_struct_b64_nested_list_and_object) {
    // {"l":[2.5,"x"],"o":{"k":"v"}} — the recursive arms: list_value=6
    // (ListValue{repeated Value values=1}) and struct_value=5 (nested Struct).
    std::string list_value_msg =
        encode_len_delim(1, encode_double_field(2, 2.5)) +
        encode_len_delim(1, encode_len_delim(3, "x"));
    std::string inner_struct = struct_entry("k", encode_len_delim(3, "v"));
    std::string s = struct_entry("l", encode_len_delim(6, list_value_msg)) +
                    struct_entry("o", encode_len_delim(5, inner_struct));
    ASSERT_EQ(ball::rt::DecodeStructJsonB64(b64_encode(s)),
              std::string(R"({"l":[2.5,"x"],"o":{"k":"v"}})"));
}

TEST(rt_decode_struct_b64_empty_is_empty_object) {
    ASSERT_EQ(ball::rt::DecodeStructJsonB64(b64_encode(std::string())),
              std::string("{}"));
}

TEST(rt_decode_struct_b64_malformed_wire_throws) {
    // VALID base64 of INVALID wire — a length-delimited field that claims 5
    // payload bytes but carries 2. The rt unmarshal must reject it, not return
    // a half-decoded Struct (same fail-loud contract binary_malformed_bytes
    // pins for the Any path above).
    std::string bad = encode_len_delim(1, "xx");
    bad[1] = 0x05;  // lie about the length
    ASSERT_THROWS_ANY(ball::rt::DecodeStructJsonB64(b64_encode(bad)));
}

TEST(rt_decode_descriptor_proto_b64) {
    // DescriptorProto{name:"Point", field:[
    //   {name:"x",    number:1, label:LABEL_OPTIONAL(1), type:TYPE_INT32(5)},
    //   {name:"next", number:2, label:LABEL_OPTIONAL(1), type:TYPE_MESSAGE(11),
    //    type_name:".Point"}]}
    // Pins: enum value→NAME rendering (label/type), the jsonName pin that keeps
    // `type_name` snake_case (the shape the encoder/corpus carries), and
    // message/field key order.
    std::string f1 = encode_len_delim(1, "x") + encode_varint_field(3, 1) +
                     encode_varint_field(4, 1) + encode_varint_field(5, 5);
    std::string f2 = encode_len_delim(1, "next") + encode_varint_field(3, 2) +
                     encode_varint_field(4, 1) + encode_varint_field(5, 11) +
                     encode_len_delim(6, ".Point");
    std::string d = encode_len_delim(1, "Point") + encode_len_delim(2, f1) +
                    encode_len_delim(2, f2);
    ASSERT_EQ(
        ball::rt::DecodeDescriptorProtoJsonB64(b64_encode(d)),
        std::string(
            R"({"name":"Point","field":[{"name":"x","number":1,"label":"LABEL_OPTIONAL","type":"TYPE_INT32"},{"name":"next","number":2,"label":"LABEL_OPTIONAL","type":"TYPE_MESSAGE","type_name":".Point"}]})"));
}

TEST(rt_decode_enum_descriptor_proto_b64_keeps_explicit_zero) {
    // EnumDescriptorProto{name:"Color", value:[{RED,0},{GREEN,1}]} — RED's
    // number:0 must SURVIVE to JSON: descriptor.proto is proto2, so the
    // hand-written descriptor marks number with explicit presence
    // (features.field_presence=EXPLICIT) precisely so a set-on-the-wire zero
    // is emitted rather than dropped as a proto3 default.
    std::string v1 = encode_len_delim(1, "RED") + encode_varint_field(2, 0);
    std::string v2 = encode_len_delim(1, "GREEN") + encode_varint_field(2, 1);
    std::string e = encode_len_delim(1, "Color") + encode_len_delim(2, v1) +
                    encode_len_delim(2, v2);
    ASSERT_EQ(
        ball::rt::DecodeEnumDescriptorProtoJsonB64(b64_encode(e)),
        std::string(
            R"({"name":"Color","value":[{"name":"RED","number":0},{"name":"GREEN","number":1}]})"));
}

// ================================================================
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ ball_file.h Tests\n"
              << "==========================\n";

    // Run the deferred tests AFTER static init (so ball_protobuf's cross-TU
    // global descriptors are constructed — see the framework note above).
    for (const auto& tc : test_registry()) {
        std::cout << "  " << tc.name << "... ";
        try {
            tc.fn();
            std::cout << "PASS\n";
            ++tests_passed;
        } catch (const std::exception& e) {
            std::cout << "FAIL: " << e.what() << "\n";
            ++tests_failed;
        }
        ++tests_run;
    }

    std::cout << "\n==========================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    return tests_failed > 0 ? 1 : 0;
}
