// Ball C++ ball_file.h Tests
//
// Direct unit coverage for cpp/shared/include/ball_file.h — the
// self-describing google.protobuf.Any envelope reader (BallFileFormatException
// paths, the hand-rolled "@type" JSON scanner, binary/JSON dispatch, and the
// Program/Module discrimination helpers). None of this is exercised by
// test_compiler/test_encoder/test_shared (they never feed a malformed or
// wrong-kind ball file through the loader), so its error branches sat almost
// entirely uncovered (issue #63; Phase-1 baseline measured this file at
// 59.73%, the largest easily-reachable gap in cpp/shared after ball_dyn.h/
// ball_emit_runtime.h were closed by test_ball_dyn.cpp).

#include "ball_file.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include <google/protobuf/any.pb.h>
#include <google/protobuf/struct.pb.h>

using namespace ball;
namespace fs = std::filesystem;

// ================================================================
// Test framework (same minimal TEST()/ASSERT_* macros as the sibling
// cpp/test/test_*.cpp files).
// ================================================================

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name)                                                       \
    static void test_##name();                                          \
    struct Register_##name {                                            \
        Register_##name() {                                             \
            std::cout << "  " << #name << "... ";                       \
            try {                                                       \
                test_##name();                                          \
                std::cout << "PASS\n";                                  \
                tests_passed++;                                         \
            } catch (const std::exception& e) {                        \
                std::cout << "FAIL: " << e.what() << "\n";              \
                tests_failed++;                                         \
            }                                                           \
            tests_run++;                                                \
        }                                                                \
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

// ================================================================
// DecodeBallFileJson — the "@type" scanner's error branches.
// ================================================================

TEST(json_not_an_object_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson("123", p, m), "must be an object");
}

TEST(json_missing_type_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson("{}", p, m), "missing \"@type\"");
}

TEST(json_malformed_type_member_missing_colon_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(
        DecodeBallFileJson(R"({"@type" "type.googleapis.com/ball.v1.Program"})", p, m),
        "malformed \"@type\" member");
}

TEST(json_type_value_not_string_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson(R"({"@type": 123})", p, m),
                              "\"@type\" value must be a string");
}

TEST(json_unterminated_type_value_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileJson(R"({"@type": "abc)", p, m),
                              "unterminated");
}

TEST(json_unknown_type_url_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(
        DecodeBallFileJson(R"({"@type": "type.googleapis.com/some.Other", "x": 1})", p, m),
        "unknown ball file @type");
}

TEST(json_valid_program_decodes) {
    ball::v1::Program p;
    ball::v1::Module m;
    auto kind = DecodeBallFileJson(program_json("hello"), p, m);
    ASSERT_TRUE(kind == BallFileKind::kProgram);
    ASSERT_EQ(p.name(), std::string("hello"));
}

TEST(json_valid_module_decodes) {
    ball::v1::Program p;
    ball::v1::Module m;
    auto kind = DecodeBallFileJson(module_json("mymod"), p, m);
    ASSERT_TRUE(kind == BallFileKind::kModule);
    ASSERT_EQ(m.name(), std::string("mymod"));
}

TEST(json_invalid_program_body_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    // "name" is a string field; feeding it a number fails JsonStringToMessage.
    ASSERT_THROWS_CONTAINING(
        DecodeBallFileJson(R"({"@type":"type.googleapis.com/ball.v1.Program","name":123})", p, m),
        "failed to parse Program JSON");
}

TEST(json_invalid_module_body_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(
        DecodeBallFileJson(R"({"@type":"type.googleapis.com/ball.v1.Module","name":123})", p, m),
        "failed to parse Module JSON");
}

// A trailing-member @type (no comma after) exercises the "drop leading
// comma" branch of extract_type_url_and_strip, instead of the "drop trailing
// comma" branch every other test above hits.
TEST(json_type_as_last_member_strips_leading_comma) {
    ball::v1::Program p;
    ball::v1::Module m;
    auto kind = DecodeBallFileJson(
        R"({"name":"trailing","@type":"type.googleapis.com/ball.v1.Program"})", p, m);
    ASSERT_TRUE(kind == BallFileKind::kProgram);
    ASSERT_EQ(p.name(), std::string("trailing"));
}

// ================================================================
// DecodeBallFileBinary — real google.protobuf.Any envelopes.
// ================================================================

TEST(binary_valid_program_decodes) {
    ball::v1::Program src;
    src.set_name("bin_prog");
    google::protobuf::Any any;
    any.PackFrom(src);
    std::string bytes;
    ASSERT_TRUE(any.SerializeToString(&bytes));

    ball::v1::Program p;
    ball::v1::Module m;
    auto kind = DecodeBallFileBinary(bytes, p, m);
    ASSERT_TRUE(kind == BallFileKind::kProgram);
    ASSERT_EQ(p.name(), std::string("bin_prog"));
}

TEST(binary_valid_module_decodes) {
    ball::v1::Module src;
    src.set_name("bin_mod");
    google::protobuf::Any any;
    any.PackFrom(src);
    std::string bytes;
    ASSERT_TRUE(any.SerializeToString(&bytes));

    ball::v1::Program p;
    ball::v1::Module m;
    auto kind = DecodeBallFileBinary(bytes, p, m);
    ASSERT_TRUE(kind == BallFileKind::kModule);
    ASSERT_EQ(m.name(), std::string("bin_mod"));
}

TEST(binary_unknown_type_url_throws) {
    google::protobuf::Struct unrelated;
    google::protobuf::Any any;
    any.PackFrom(unrelated);  // type_url ends in "/google.protobuf.Struct"
    std::string bytes;
    ASSERT_TRUE(any.SerializeToString(&bytes));

    ball::v1::Program p;
    ball::v1::Module m;
    ASSERT_THROWS_CONTAINING(DecodeBallFileBinary(bytes, p, m),
                              "unknown ball file type URL");
}

TEST(binary_malformed_bytes_throws) {
    ball::v1::Program p;
    ball::v1::Module m;
    // Not a valid serialized google.protobuf.Any at all.
    ASSERT_THROWS_CONTAINING(DecodeBallFileBinary(std::string("\xFF\xFF\xFF\xFF\xFF", 5), p, m),
                              "failed to parse binary google.protobuf.Any envelope");
}

// ================================================================
// DecodeBallFile — extension-driven binary/JSON dispatch.
// ================================================================

TEST(decode_ball_file_dispatches_by_extension) {
    ball::v1::Program p1;
    ball::v1::Module m1;
    ASSERT_TRUE(DecodeBallFile("x.ball.json", program_json("j"), p1, m1) ==
                BallFileKind::kProgram);

    ball::v1::Program src;
    src.set_name("bp");
    google::protobuf::Any any;
    any.PackFrom(src);
    std::string bytes;
    ASSERT_TRUE(any.SerializeToString(&bytes));

    ball::v1::Program p2;
    ball::v1::Module m2;
    ASSERT_TRUE(DecodeBallFile("x.ball.pb", bytes, p2, m2) == BallFileKind::kProgram);
    ball::v1::Program p3;
    ball::v1::Module m3;
    ASSERT_TRUE(DecodeBallFile("x.ball.bin", bytes, p3, m3) == BallFileKind::kProgram);
}

// ================================================================
// LoadProgram / LoadModule / DecodeProgram — kind-mismatch + file I/O.
// ================================================================

TEST(load_program_reads_real_file) {
    fs::path path = write_temp_file("load_program.ball.json", program_json("fromfile"));
    ball::v1::Program p = LoadProgram(path.string());
    ASSERT_EQ(p.name(), std::string("fromfile"));
    fs::remove(path);
}

TEST(load_module_reads_real_file) {
    fs::path path = write_temp_file("load_module.ball.json", module_json("modfromfile"));
    ball::v1::Module m = LoadModule(path.string());
    ASSERT_EQ(m.name(), std::string("modfromfile"));
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
    ball::v1::Program p = DecodeProgram("x.ball.json", program_json("direct"));
    ASSERT_EQ(p.name(), std::string("direct"));
}

// ================================================================
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ ball_file.h Tests\n"
              << "==========================\n";

    std::cout << "\n==========================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    return tests_failed > 0 ? 1 : 0;
}
