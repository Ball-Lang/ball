// Ball C++ CLI Tests — ball_cpp_compile / ball_cpp_encode entry points.
//
// Subprocess coverage for cpp/compiler/src/main.cpp and
// cpp/encoder/src/main.cpp — the CLI argv-parsing / file I/O / mode-dispatch
// logic in each `main()`/`run_compile()`. Neither is reachable from any other
// test binary: test_e2e/test_snapshot/test_compiler drive `CppCompiler`
// directly in-process, and test_encoder drives `CppEncoder` directly — the
// CLI executables themselves are never invoked. Both main.cpp files sat at
// 0% coverage through every prior coverage sweep (issue #63; confirmed by
// the Phase-1 Codecov baseline). Runs the REAL built executables as
// subprocesses (mirroring test_e2e.cpp's popen-based run_capture helper) so
// their own gcov counters get written to build-cov.

#include <array>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#ifndef BALL_CPP_COMPILE_EXE
#error "BALL_CPP_COMPILE_EXE must be defined"
#endif
#ifndef BALL_CPP_ENCODE_EXE
#error "BALL_CPP_ENCODE_EXE must be defined"
#endif
#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined"
#endif
#ifndef BALL_CLANG_AST_DIR
#error "BALL_CLANG_AST_DIR must be defined"
#endif

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

// ================================================================
// Subprocess helpers (mirrors cpp/test/test_e2e.cpp's run_capture/quote/
// cmd_wrap — kept as a local copy since each cpp/test/test_*.cpp binary is
// self-contained, per this suite's established pattern).
// ================================================================

static std::string quote(const std::string& s) {
#ifdef _WIN32
    return "\"" + s + "\"";
#else
    return "'" + s + "'";
#endif
}

// Windows: cmake's $<TARGET_FILE:> emits a forward-slash path, which cmd.exe
// (invoked by _popen) mis-locates as a quoted command. Convert to backslashes.
static std::string to_native(std::string s) {
#ifdef _WIN32
    for (auto& c : s) { if (c == '/') c = '\\'; }
#endif
    return s;
}

// Runs `cmd`, capturing merged stdout+stderr into `out`. Returns the raw
// pclose()/_pclose() status (only ever compared against/to zero below, never
// decoded to a specific exit-code value — see POSIX pclose()'s wait-status
// caveat).
static int run_capture(const std::string& cmd, std::string& out) {
    out.clear();
#ifdef _WIN32
    // _popen runs `cmd /c <str>`; cmd strips the outer quote pair, so wrap the
    // whole command (quoted exe + args + redirection) in a single outer pair.
    std::string full = "\"" + cmd + " 2>&1\"";
    FILE* pipe = _popen(full.c_str(), "r");
#else
    std::string full = cmd + " 2>&1";
    FILE* pipe = popen(full.c_str(), "r");
#endif
    if (!pipe) return -1;
    std::array<char, 4096> buf{};
    while (fgets(buf.data(), static_cast<int>(buf.size()), pipe)) {
        out += buf.data();
    }
#ifdef _WIN32
    return _pclose(pipe);
#else
    return pclose(pipe);
#endif
}

static std::string compile_exe() { return quote(to_native(BALL_CPP_COMPILE_EXE)); }
static std::string encode_exe() { return quote(to_native(BALL_CPP_ENCODE_EXE)); }

// ================================================================
// ball_cpp_compile — usage / error / success / library / split modes.
// ================================================================

TEST(compile_no_args_prints_usage) {
    std::string out;
    int rc = run_capture(compile_exe(), out);
    ASSERT_TRUE(rc != 0);
    ASSERT_TRUE(out.find("Usage:") != std::string::npos);
}

TEST(compile_missing_file_errors) {
    std::string out;
    std::string cmd = compile_exe() + " " + quote("/no/such/file.ball.json");
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc != 0);
    ASSERT_TRUE(out.find("Could not open") != std::string::npos);
}

TEST(compile_valid_program_to_stdout) {
    std::string program = std::string(BALL_CONFORMANCE_DIR) + "/202_sandbox_mode.ball.json";
    std::string out;
    int rc = run_capture(compile_exe() + " " + quote(program), out);
    ASSERT_TRUE(rc == 0);
    ASSERT_TRUE(out.find("int main(") != std::string::npos);
}

TEST(compile_valid_program_to_output_file) {
    std::string program = std::string(BALL_CONFORMANCE_DIR) + "/202_sandbox_mode.ball.json";
    fs::path out_path = fs::temp_directory_path() / "ball_cli_test_output.cpp";
    std::error_code ec;
    fs::remove(out_path, ec);
    std::string out;
    std::string cmd = compile_exe() + " " + quote(program) + " " + quote(out_path.string());
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc == 0);
    ASSERT_TRUE(out.find("Compiled to") != std::string::npos);
    ASSERT_TRUE(fs::exists(out_path));
    ASSERT_TRUE(fs::file_size(out_path) > 0);
    fs::remove(out_path, ec);
}

TEST(compile_library_mode_success) {
    // Minimal hand-written Module — library mode expects a Module (not a
    // Program), so this doesn't need a full ball_protobuf-sized fixture.
    fs::path mod_path = fs::temp_directory_path() / "ball_cli_test_module.ball.json";
    {
        std::ofstream f(mod_path, std::ios::binary);
        f << R"({"@type":"type.googleapis.com/ball.v1.Module","name":"tiny_lib"})";
    }
    std::string out;
    std::string cmd = compile_exe() + " " + quote(mod_path.string()) + " --library";
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc == 0);
    ASSERT_TRUE(!out.empty());  // the compiled header text, printed to stdout
    std::error_code ec;
    fs::remove(mod_path, ec);
}

TEST(compile_library_mode_rejects_program_file) {
    std::string program = std::string(BALL_CONFORMANCE_DIR) + "/202_sandbox_mode.ball.json";
    std::string out;
    std::string cmd = compile_exe() + " " + quote(program) + " --library";
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc != 0);
    ASSERT_TRUE(out.find("Library mode expects a Module") != std::string::npos);
}

TEST(compile_split_mode_writes_directory) {
    std::string program = std::string(BALL_CONFORMANCE_DIR) + "/202_sandbox_mode.ball.json";
    fs::path split_dir = fs::temp_directory_path() / "ball_cli_test_split";
    std::error_code ec;
    fs::remove_all(split_dir, ec);
    std::string out;
    std::string cmd = compile_exe() + " " + quote(program) + " --split " +
                       quote(split_dir.string()) + " --shards 2";
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc == 0);
    ASSERT_TRUE(out.find("Compiled split output to") != std::string::npos);
    fs::remove_all(split_dir, ec);
}

// ================================================================
// ball_cpp_encode — usage / error / success / --normalize / --binary.
// ================================================================

TEST(encode_no_args_prints_usage) {
    std::string out;
    int rc = run_capture(encode_exe(), out);
    ASSERT_TRUE(rc != 0);
    ASSERT_TRUE(out.find("Usage:") != std::string::npos);
}

TEST(encode_missing_file_errors) {
    std::string out;
    std::string cmd = encode_exe() + " " + quote("/no/such/ast.json");
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc != 0);
    ASSERT_TRUE(out.find("Could not open") != std::string::npos);
}

TEST(encode_valid_ast_to_stdout) {
    std::string ast = std::string(BALL_CLANG_AST_DIR) + "/01_hello.ast.json";
    std::string out;
    int rc = run_capture(encode_exe() + " " + quote(ast), out);
    ASSERT_TRUE(rc == 0);
    ASSERT_TRUE(out.find("\"@type\"") != std::string::npos);
}

TEST(encode_normalize_flag_prints_deprecated_warning) {
    std::string ast = std::string(BALL_CLANG_AST_DIR) + "/01_hello.ast.json";
    fs::path out_path = fs::temp_directory_path() / "ball_cli_test_encode_out.ball.json";
    std::error_code ec;
    fs::remove(out_path, ec);
    std::string out;
    std::string cmd = encode_exe() + " " + quote(ast) + " " + quote(out_path.string()) +
                       " --normalize";
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc == 0);
    ASSERT_TRUE(out.find("--normalize is deprecated") != std::string::npos);
    fs::remove(out_path, ec);
}

TEST(encode_binary_flag_errors) {
    std::string ast = std::string(BALL_CLANG_AST_DIR) + "/01_hello.ast.json";
    std::string out;
    std::string cmd = encode_exe() + " " + quote(ast) + " --binary";
    int rc = run_capture(cmd, out);
    ASSERT_TRUE(rc != 0);
    ASSERT_TRUE(out.find("--binary output is no longer supported") != std::string::npos);
}

// ================================================================
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ CLI Tests\n"
              << "==================\n";

    std::cout << "\n==================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    return tests_failed > 0 ? 1 : 0;
}
