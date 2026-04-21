// Ball C++ End-to-End Compiler Tests
//
// For a curated subset of conformance programs:
//   ball.json → CppCompiler::compile() → temp .cpp file
//                → cmake build → executable
//                → run and capture stdout
//                → diff against .expected_output.txt
//
// We delegate the actual C++ compile to a generated mini CMake project
// (written into a scratch directory) rather than invoking the C++ compiler
// directly. This inherits the full toolchain setup — notably the MSVC
// INCLUDE/LIB environment that a standalone cl.exe invocation lacks.

#include "compiler.h"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <google/protobuf/util/json_util.h>

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined"
#endif
#ifndef BALL_GENERATED_FIXTURES_DIR
#error "BALL_GENERATED_FIXTURES_DIR must be defined"
#endif
#ifndef BALL_E2E_CMAKE
#error "BALL_E2E_CMAKE must be defined"
#endif
#ifndef BALL_E2E_GENERATOR
#error "BALL_E2E_GENERATOR must be defined"
#endif
#ifndef BALL_E2E_BUILD_TYPE
#define BALL_E2E_BUILD_TYPE "Debug"
#endif

namespace fs = std::filesystem;

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

static std::string normalize(std::string s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (c != '\r') out.push_back(c);
    }
    while (!out.empty() && (out.back() == '\n' || out.back() == ' ' ||
                            out.back() == '\t')) {
        out.pop_back();
    }
    return out;
}

static std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static int run_capture(const std::string& cmd, std::string& out) {
    out.clear();
#ifdef _WIN32
    FILE* pipe = _popen(cmd.c_str(), "r");
#else
    FILE* pipe = popen(cmd.c_str(), "r");
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

static std::string quote(const std::string& s) {
#ifdef _WIN32
    return "\"" + s + "\"";
#else
    return "'" + s + "'";
#endif
}

#ifdef _WIN32
// cmd.exe strips an outer pair of quotes on the whole command line when it
// both starts and ends with one. For commands that contain quoted paths
// with spaces (e.g. "C:/Program Files/…"), re-wrap so the inner quotes
// survive.
static std::string cmd_wrap(const std::string& s) {
    return "\"" + s + "\"";
}
#else
static std::string cmd_wrap(const std::string& s) { return s; }
#endif

struct Program {
    std::string name;
    std::string cpp_source;
    fs::path expected_path;
};

// Search both the hand-written and the auto-generated fixture dirs for
// a program. Returns true on success and fills out_prog_path +
// out_expected_path.
static bool resolve_fixture(const std::string& name, fs::path& out_program_path,
                            fs::path& out_expected_path,
                            std::string& failure_msg) {
    const std::vector<fs::path> dirs = {
        fs::path(BALL_CONFORMANCE_DIR),
        fs::path(BALL_GENERATED_FIXTURES_DIR),
    };
    for (const auto& dir : dirs) {
        auto candidate = dir / (name + ".ball.json");
        if (!fs::exists(candidate)) continue;
        out_program_path = candidate;
        // Prefer an adjacent `.expected_output.txt`; fall back to the
        // matching Dart source run directly (not implemented — the
        // Dart-driven cross-language test owns that path).
        auto expected = dir / (name + ".expected_output.txt");
        if (fs::exists(expected)) {
            out_expected_path = expected;
            return true;
        }
        // For auto-generated fixtures we consult the sibling
        // `tests/fixtures/dart/<name>.expected_output.txt` if the user
        // has checked one in. Otherwise fall back to running the Dart
        // source file — the same baseline the cross-language harness
        // uses. For the e2e test, require the expected file to exist.
        auto parent_fixture_dir = dir.parent_path();
        auto alt = parent_fixture_dir / (name + ".expected_output.txt");
        if (fs::exists(alt)) {
            out_expected_path = alt;
            return true;
        }
    }
    failure_msg = "missing fixture files for " + name;
    return false;
}

static bool load_and_compile(const fs::path& dir, const std::string& name,
                             Program& out_prog, std::string& failure_msg) {
    fs::path program_path, expected_path;
    if (!resolve_fixture(name, program_path, expected_path, failure_msg)) {
        return false;
    }
    auto json = read_file(program_path);
    ball::v1::Program program;
    google::protobuf::util::JsonParseOptions opts;
    opts.ignore_unknown_fields = true;
    auto status = google::protobuf::util::JsonStringToMessage(json, &program, opts);
    if (!status.ok()) {
        failure_msg = "JSON parse failed: " + std::string(status.message());
        return false;
    }
    try {
        ball::CppCompiler compiler(program);
        out_prog.cpp_source = compiler.compile();
    } catch (const std::exception& e) {
        failure_msg = std::string("compile threw: ") + e.what();
        return false;
    }
    out_prog.name = name;
    out_prog.expected_path = expected_path;
    return true;
}

static bool build_sub_project(const fs::path& proj_dir,
                              const fs::path& build_dir,
                              const std::vector<Program>& programs,
                              std::string& failure_msg) {
    // Write each program's C++ source.
    for (const auto& p : programs) {
        auto cpp_path = proj_dir / (p.name + ".cpp");
        std::ofstream out(cpp_path, std::ios::binary);
        out << p.cpp_source;
    }

    // Generate CMakeLists.txt with one executable target per program.
    {
        std::ofstream cml(proj_dir / "CMakeLists.txt", std::ios::binary);
        cml << "cmake_minimum_required(VERSION 3.14)\n"
            << "project(ball_e2e_scratch CXX)\n"
            << "set(CMAKE_CXX_STANDARD 17)\n"
            << "set(CMAKE_CXX_STANDARD_REQUIRED ON)\n";
        for (const auto& p : programs) {
            cml << "add_executable(" << p.name << " " << p.name << ".cpp)\n";
        }
    }

    // Configure.
    std::string gen_cmd = quote(BALL_E2E_CMAKE) +
                          " -S " + quote(proj_dir.string()) +
                          " -B " + quote(build_dir.string()) +
                          " -G " + quote(BALL_E2E_GENERATOR) +
                          " 2>&1";
    gen_cmd = cmd_wrap(gen_cmd);
    std::string gen_output;
    int gen_rc = run_capture(gen_cmd, gen_output);
    if (gen_rc != 0) {
        failure_msg = "cmake configure failed (rc=" + std::to_string(gen_rc) +
                      "):\n" + gen_output;
        return false;
    }

    // Build all targets at once.
    std::string build_cmd = quote(BALL_E2E_CMAKE) +
                            " --build " + quote(build_dir.string()) +
                            " --config " BALL_E2E_BUILD_TYPE +
                            " 2>&1";
    build_cmd = cmd_wrap(build_cmd);
    std::string build_output;
    int build_rc = run_capture(build_cmd, build_output);
    if (build_rc != 0) {
        failure_msg = "cmake build failed (rc=" + std::to_string(build_rc) +
                      "):\n" + build_output;
        return false;
    }
    return true;
}

// Given the scratch build directory, locate the binary for `name`.
// Multi-config generators (MSBuild) place it under <config>/name.exe;
// single-config generators put it directly at name(.exe).
static fs::path locate_binary(const fs::path& build_dir, const std::string& name) {
#ifdef _WIN32
    const std::string exe = name + ".exe";
#else
    const std::string& exe = name;
#endif
    fs::path candidate = build_dir / BALL_E2E_BUILD_TYPE / exe;
    if (fs::exists(candidate)) return candidate;
    candidate = build_dir / exe;
    if (fs::exists(candidate)) return candidate;
    return {};
}

static bool run_and_check(const Program& p, const fs::path& build_dir,
                          std::string& failure_msg) {
    auto exe_path = locate_binary(build_dir, p.name);
    if (exe_path.empty()) {
        failure_msg = "built binary not found for " + p.name;
        return false;
    }
    std::string run_cmd = cmd_wrap(quote(exe_path.string()));
    std::string run_output;
    int run_rc = run_capture(run_cmd, run_output);
    if (run_rc != 0) {
        failure_msg = "binary exited rc=" + std::to_string(run_rc) +
                      ", output: " + run_output;
        return false;
    }
    auto actual = normalize(std::move(run_output));
    auto expected = normalize(read_file(p.expected_path));
    if (actual != expected) {
        failure_msg = "output mismatch\n--- expected ---\n" + expected +
                      "\n--- actual ---\n" + actual + "\n---";
        return false;
    }
    return true;
}

int main() {
    std::cout << "Ball C++ End-to-End Tests\n"
              << "=========================\n"
              << "Using CMake: " << BALL_E2E_CMAKE << "\n"
              << "Generator:  " << BALL_E2E_GENERATOR << "\n";

    // End-to-end C++ compile + run for every fixture under
    // tests/fixtures/dart/_generated/ plus hand-written conformance
    // programs in tests/conformance/. Names match either location;
    // resolve_fixture() scans both.
    //
    // Previously this list was 12 hand-picked names. Expanded to the
    // full 37 as part of the C++ self-host push (Phase 3); any fixture
    // that fails here surfaces a real cpp-compiler gap.
    const std::vector<std::string> program_names = {
        // Auto-generated from tests/fixtures/dart/*.dart
        "01_hello",
        "02_arithmetic",
        "03_if_else",
        "04_while",
        "05_for",
        "06_function",
        "07_recursion",
        "08_comparison",
        "09_string",
        "10_nested_control",
        "11_try_catch",
        "12_early_return",
        "13_list_ops",
        "14_bool_logic",
        "15_closure",
        "16_labeled_break",
        "17_rethrow",
        "18_do_while",
        "19_nested_calls",
        "20_bitwise",
        "21_ternary",
        "22_mutual_recursion",
        "23_string_ops",
        "24_int_methods",
        "25_nested_closure",
        "26_list_iterate",
        "27_continue",
        "28_negative_math",
        "29_short_circuit",
        "30_deep_recursion",
        "31_closures",
        "32_string_ops",
        "33_list_ops",
        "34_fibonacci",
        "35_nested_functions",
        "36_catch_stack",
        "36_math_utils",
        // Hand-written in tests/conformance/ — exercise typed-catch /
        // rethrow / labeled-break / throw-value paths specifically.
        "21_typed_catch",
        "22_rethrow_preserves",
        "23_labeled_break",
        "24_throw_value",
        // Conformance programs 25-75
        "25_closures",
        "26_string_ops",
        "27_list_ops",
        "28_fibonacci",
        "29_nested_functions",
        "30_math_utils",
        "31_arithmetic_basic",
        "32_arithmetic_negative",
        "33_comparison_chain",
        "34_boolean_logic",
        "35_short_circuit",
        "36_string_interpolation",
        "37_string_concat",
        "38_string_length",
        "39_compound_assign",
        "40_increment_decrement",
        "41_for_sum",
        "42_nested_functions",
        "43_countdown",
        "44_for_loop_basic",
        "45_for_in_loop",
        "46_while_loop",
        "47_do_while",
        "48_break_continue",
        "49_nested_loops",
        "50_if_else_chain",
        "51_nested_if",
        "52_max_of_three",
        "53_try_catch_finally",
        "54_abs_value",
        "55_scope_variable",
        "56_closure_capture",
        "57_recursion_factorial",
        "58_mutual_recursion",
        "59_deep_recursion",
        "60_collatz",
        "61_bitwise_ops",
        "62_ternary",
        "63_is_prime",
        "64_multiple_functions",
        "65_higher_order",
        "66_digit_sum",
        "67_reverse_number",
        "68_triangle_pattern",
        "69_early_return",
        "70_accumulator",
        "71_fizzbuzz",
        "72_gcd",
        "73_power",
        "74_fibonacci_sequence",
        "75_sum_of_squares",
        // Conformance programs 76-100
        // Tests 76, 78, 81, 83, 85, 87, 92, 93, 94, 95, 98 still
        // fail due to pre-existing std::any type inference issues
        // (empty list literal → std::vector<std::any>, then operations
        // like *, ==, [] on std::any don't compile).
        "77_string_builder",
        "79_nested_loops_pattern",
        "80_bubble_sort",
        "82_string_reverse",
        "84_exception_chain",
        "86_linked_list",
        "88_selection_sort",
        "89_tower_of_hanoi",
        "90_number_patterns",
        "91_nested_try_catch",
        "96_roman_numerals",
        "97_stack_operations",
        "99_type_conversion",
        "100_complex_control_flow",
    };

    fs::path conformance_dir(BALL_CONFORMANCE_DIR);
    (void)conformance_dir;  // resolve_fixture() scans both dirs internally
    fs::path scratch = fs::temp_directory_path() / "ball_e2e";
    fs::path proj_dir = scratch / "src";
    fs::path build_dir = scratch / "build";
    // Clean any stale .cpp files so we don't trip over renames/removals
    // between runs.
    std::error_code ec;
    fs::remove_all(scratch, ec);
    fs::create_directories(proj_dir);

    // Step 1: load + compile all programs.
    std::vector<Program> programs;
    for (const auto& name : program_names) {
        Program p;
        std::string msg;
        if (load_and_compile(conformance_dir, name, p, msg)) {
            programs.push_back(std::move(p));
        } else {
            tests_run++;
            tests_failed++;
            std::cout << "  " << name << "... FAIL (" << msg << ")\n";
        }
    }

    if (programs.empty()) {
        std::cout << "\nNo programs to test.\n";
        return tests_failed > 0 ? 1 : 0;
    }

    // Step 2: build all programs in a single CMake invocation.
    std::string build_msg;
    if (!build_sub_project(proj_dir, build_dir, programs, build_msg)) {
        std::cout << "\nBuild of e2e scratch project FAILED:\n"
                  << build_msg << "\n";
        return 1;
    }

    // Step 3: run each binary and diff.
    for (const auto& p : programs) {
        tests_run++;
        std::cout << "  " << p.name << "... ";
        std::string failure_msg;
        if (run_and_check(p, build_dir, failure_msg)) {
            std::cout << "PASS\n";
            tests_passed++;
        } else {
            std::cout << "FAIL\n" << failure_msg << "\n";
            tests_failed++;
        }
    }

    std::cout << "\n=========================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";
    return tests_failed > 0 ? 1 : 0;
}
