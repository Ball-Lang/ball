// Ball C++ End-to-End Compiler Tests
//
// For all conformance programs with .expected_output.txt files:
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
#include "absl/synchronization/mutex.h"

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

#include "ball_file.h"

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
    try {
        program = ball::DecodeProgram(program_path.string(), json);
    } catch (const ball::BallFileFormatException& e) {
        failure_msg = std::string("ball file decode failed: ") + e.what();
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
            << "set(CMAKE_CXX_STANDARD 20)\n"
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
    // Disable abseil mutex deadlock detection — protobuf v34.1's internal
    // descriptor pool initialization triggers a false-positive cycle.
    // Long-term fix: replace Google protobuf with Ball-compiled ball_protobuf.
    absl::SetMutexDeadlockDetectionMode(absl::OnDeadlockCycle::kIgnore);

    std::cout << "Ball C++ End-to-End Tests\n"
              << "=========================\n"
              << "Using CMake: " << BALL_E2E_CMAKE << "\n"
              << "Generator:  " << BALL_E2E_GENERATOR << "\n";

    // All testable programs from tests/fixtures/dart/_generated/ and
    // tests/conformance/ that have .expected_output.txt files. Sorted
    // numerically. Programs that fail to compile are logged and counted
    // as failures — no programs are skipped.
    const std::vector<std::string> program_names = {
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
        "21_typed_catch",
        "22_mutual_recursion",
        "22_rethrow_preserves",
        "23_labeled_break",
        "23_string_ops",
        "24_int_methods",
        "24_throw_value",
        "25_closures",
        "25_nested_closure",
        "26_list_iterate",
        "26_string_ops",
        "27_continue",
        "27_list_ops",
        "28_fibonacci",
        "28_negative_math",
        "29_nested_functions",
        "29_short_circuit",
        "30_deep_recursion",
        "30_math_utils",
        "31_arithmetic_basic",
        "31_closures",
        "32_arithmetic_negative",
        "32_string_ops",
        "33_comparison_chain",
        "33_list_ops",
        "34_boolean_logic",
        "34_fibonacci",
        "35_nested_functions",
        "35_short_circuit",
        "36_catch_stack",
        "36_math_utils",
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
        "76_list_map_filter",
        "77_string_builder",
        "78_map_operations",
        "79_nested_loops_pattern",
        "80_bubble_sort",
        "81_binary_search",
        "82_string_reverse",
        "83_matrix_multiply",
        "84_exception_chain",
        "85_closure_counter",
        "86_linked_list",
        "87_string_count",
        "88_selection_sort",
        "89_tower_of_hanoi",
        "90_number_patterns",
        "91_nested_try_catch",
        "92_list_comprehension",
        "93_multi_return",
        "94_prime_sieve",
        "95_fibonacci_memo",
        "96_roman_numerals",
        "97_stack_operations",
        "98_string_tokenizer",
        "99_type_conversion",
        "100_complex_control_flow",
        "101_simple_class",
        "102_inheritance",
        "103_abstract_class",
        "104_getter_setter",
        "105_static_methods",
        "106_factory_constructor",
        "107_method_override_super",
        "108_class_tostring",
        "109_enum_values",
        "110_mixin",
        "111_cascade_operator",
        "112_named_constructors",
        "113_operator_overloading",
        "114_class_hierarchy",
        "115_generic_class",
        "116_map_iteration",
        "117_list_generate",
        "118_set_operations",
        "119_nested_maps",
        "120_list_of_maps",
        "121_map_from_entries",
        "122_list_sort_comparator",
        "123_queue_simulation",
        "124_frequency_counter",
        "125_group_by",
        "126_flatten_nested_list",
        "127_zip_lists",
        "128_matrix_transpose",
        "129_unique_elements",
        "130_running_average",
        "131_insertion_sort",
        "132_merge_sort",
        "133_quick_sort",
        "134_counting_sort",
        "135_linear_search_sentinel",
        "136_string_pattern_match",
        "137_pascals_triangle",
        "138_matrix_addition",
        "139_decimal_to_binary",
        "140_caesar_cipher",
        "141_palindrome_number",
        "142_armstrong_number",
        "143_perfect_number",
        "144_lcm_computation",
        "145_josephus",
        "146_nested_try_catch_types",
        "147_complex_switch",
        "148_labeled_loops",
        "149_generator_pattern",
        "150_state_machine",
        "151_recursive_descent_parser",
        "152_coroutine_simulation",
        "153_memoized_recursive",
        "154_currying",
        "155_pipeline_compose",
        "160_async_basic",
        "161_async_chained",
        "162_generator_sync",
        "163_generator_async",
        "164_oop_inheritance",
        "165_oop_virtual_dispatch",
        "166_oop_super_call",
        "167_generics_reified",
        "168_generics_type_check",
        "169_pattern_destructure",
        "170_pattern_switch_expr",
        "171_async_error_propagation",
        "172_async_nested_await",
        "173_async_multiple_futures",
        "174_generator_yield_star",
        "175_generator_empty_return",
        "176_generator_early_return",
        "177_oop_diamond",
        "178_oop_abstract",
        "179_oop_deep",
        "180_generic_list_ops",
        "181_generic_map_ops",
        "182_list_patterns",
        "183_type_patterns",
        "184_nested_patterns",
        "185_std_convert",
        "186_list_generate",
        "187_list_filled",
        "188_std_time_now",
        "189_std_time_components",
        "190_utf8_encode_decode",
        "191_base64_encode_decode",
        "192_overflow_and_large_numbers",
        "193_unicode_and_special_characters",
        "194_null_handling",
        "195_deep_nesting",
        "198_large_collection_handling",
        "199_malicious_input_patterns",
        "200_resource_exhaustion_protection",
        "203_closure_in_loop",
        "204_string_operations",
        "205_map_ordering",
        "206_integer_arithmetic_edge",
        "207_record_pattern_destructure",
        "208_async_chain_rethrow",
        "209_generator_filtered_state",
        "210_recursive_tree_sum",
        "211_nested_closures_currying",
        "212_error_propagation_recursion",
        "213_string_edge_cases",
        "214_nan_propagation",
        "215_infinity_arithmetic",
        "216_int_double_truncation",
        "217_modulo_divide_edges",
        "218_list_mutation_aliasing",
        "219_map_mutation_aliasing",
        "220_nested_collection_aliasing",
        "221_rethrow_preserves_chain",
        "222_rethrow_selective_filter",
        "223_closure_loop_capture",
        "224_currying_partial_apply",
        "225_switch_default_exhaustive",
        "226_list_pattern_destructure",
        "227_generic_type_ops",
        "228_unicode_grapheme_edges",
        "229_closure_loop_var_semantics",
        "230_signed_int_boundaries",
        "231_negative_zero_compare",
        "232_double_extreme_values",
        "233_int_arithmetic_edges",
        "234_async_sequential_order",
        "235_async_nested_await",
        "236_async_error_propagation",
        "237_map_pattern_switch",
        "238_switch_or_patterns",
        "239_switch_expr_relational",
        "240_switch_type_guard_patterns",
        "241_generic_list_covariance",
        "242_generic_fn_chains",
        "243_generic_class_ops",
        "244_exception_triple_nest",
        "245_exception_finally_order",
        "246_exception_nested_rethrow",
        "247_string_unicode_escapes",
        "248_string_raw_backslash",
        "249_string_control_char_edges",
        "250_string_interpolation_escape",
        "251_bitwise_signed_edges",
        "252_list_rest_pattern",
        "253_async_parallel_then_combine",
        "254_switch_nullable_exhaustive",
        "255_string_surrogate_astral",
        "256_editions_resolver",
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
