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

#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "ball_file.h"
#include "ball_ir.h"
#include "e2e_fixture_list.h"

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
    ball::ir::Program program;
    try {
        program = ball::DecodeProgram(program_path.string(), json);
    } catch (const ball::BallFileFormatException& e) {
        failure_msg = std::string("ball file decode failed: ") + e.what();
        return false;
    }
    try {
        ball::CppCompiler compiler(std::move(program));
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

// ================================================================
// std_fs direct-compile e2e coverage (issue #319)
// ================================================================
//
// The numbered corpus above loads pre-generated .ball.json fixtures (built
// by the Dart encoder from tests/conformance/src/*.dart), which only
// exercises constructs the encoder currently emits — std_fs byte/append
// operations have no such fixture yet. These two programs are instead built
// directly via the ball::v1 protobuf API (mirroring cpp/test/test_compiler.cpp's
// builder-helper style) and appended to the same `programs` vector so they
// share the single CMake configure+build pass below. Each owns a unique
// temp-file path and deletes it once done; expected stdout is compared
// inline (no on-disk .expected_output.txt) to keep this self-contained.

// #18 Stage 5: build inline programs as proto3-JSON (ball::ir), no libprotobuf.
using json = ball::ir::json;

static json fs_lit_string(const std::string& v) {
    json e; e["literal"]["stringValue"] = v; return e;
}

static json fs_lit_int(int64_t v) {
    json e; e["literal"]["intValue"] = std::to_string(v); return e;
}

// `b64` is the base64-encoded bytes (proto3-JSON bytes form).
static json fs_lit_bytes(const std::string& b64) {
    json e; e["literal"]["bytesValue"] = b64; return e;
}

static json fs_ref(const std::string& name) {
    json e; e["reference"]["name"] = name; return e;
}

static json fs_msg(std::vector<std::pair<std::string, json>> fields) {
    json e;
    e["messageCreation"]["typeName"] = "";
    if (!fields.empty()) {
        json arr = json::array();
        for (auto& [name, value] : fields) {
            json f; f["name"] = name; f["value"] = std::move(value);
            arr.push_back(std::move(f));
        }
        e["messageCreation"]["fields"] = std::move(arr);
    }
    return e;
}

static json fs_call(const std::string& module, const std::string& function,
                    json input) {
    json e;
    e["call"]["module"] = module;
    e["call"]["function"] = function;
    e["call"]["input"] = std::move(input);
    return e;
}

static json fs_print(json message) {
    return fs_call("std", "print", fs_msg({{"message", std::move(message)}}));
}

static json fs_block(std::vector<json> statements, json result) {
    json b = json::object();
    json arr = json::array();
    for (auto& st : statements) arr.push_back(std::move(st));
    b["statements"] = std::move(arr);
    b["result"] = std::move(result);
    json e; e["block"] = std::move(b); return e;
}
static json fs_stmt(json expr) { json s; s["expression"] = std::move(expr); return s; }
static json fs_let(const std::string& name, json value) {
    json s; s["let"]["name"] = name; s["let"]["value"] = std::move(value); return s;
}

static json fs_build_program(json body) {
    json program;
    json mod; mod["name"] = "main";
    json func; func["name"] = "main"; func["body"] = std::move(body);
    mod["functions"].push_back(std::move(func));
    program["modules"].push_back(std::move(mod));
    program["entryModule"] = "main";
    program["entryFunction"] = "main";
    return program;
}

// file_write_bytes -> file_read_bytes round trip. The content includes an
// embedded NUL byte (proves the byte path isn't string/NUL-terminator
// based) followed by a trailing byte (proves the write/read isn't
// truncated at the NUL).
static json fs_build_write_bytes_program(const std::string& path) {
    // base64 of bytes {0x48,0x65,0x00,0x21,0x0A} ("He" NUL "!" LF).
    return fs_build_program(fs_block({
        fs_stmt(fs_call("std_fs", "file_write_bytes", fs_msg({
            {"path", fs_lit_string(path)},
            {"content", fs_lit_bytes("SGUAIQo=")}
        }))),
        fs_let("bytes",
            fs_call("std_fs", "file_read_bytes", fs_msg({{"path", fs_lit_string(path)}}))),
        // bytes[2] is the embedded NUL (0).
        fs_stmt(fs_print(fs_call("std", "index", fs_msg({
            {"target", fs_ref("bytes")}, {"index", fs_lit_int(2)}
        })))),
        // bytes[4] is the trailing byte (10) written after the NUL.
        fs_stmt(fs_print(fs_call("std", "index", fs_msg({
            {"target", fs_ref("bytes")}, {"index", fs_lit_int(4)}
        })))),
        fs_stmt(fs_call("std_fs", "file_delete", fs_msg({{"path", fs_lit_string(path)}}))),
    }, fs_lit_int(0)));
}

// file_write (truncate) then file_append -> file_read proves append
// concatenates onto existing content instead of overwriting it.
static json fs_build_append_program(const std::string& path) {
    return fs_build_program(fs_block({
        fs_stmt(fs_call("std_fs", "file_write", fs_msg({
            {"path", fs_lit_string(path)}, {"content", fs_lit_string("Hello, ")}
        }))),
        fs_stmt(fs_call("std_fs", "file_append", fs_msg({
            {"path", fs_lit_string(path)}, {"content", fs_lit_string("World!")}
        }))),
        fs_let("s", fs_call("std_fs", "file_read", fs_msg({{"path", fs_lit_string(path)}}))),
        fs_stmt(fs_print(fs_ref("s"))),
        fs_stmt(fs_call("std_fs", "file_delete", fs_msg({{"path", fs_lit_string(path)}}))),
    }, fs_lit_int(0)));
}

// ================================================================
// std_time direct-compile e2e coverage (issue #328)
// ================================================================
//
// year/month/day/hour/minute/second are 0-arg getters that read the current
// UTC instant (see dart/shared/lib/std_time.dart's "current UTC time"
// descriptions and dart/engine/lib/engine_std.dart's reference impl,
// `DateTime.now().toUtc().<field>`) -- unlike format_timestamp/
// parse_timestamp there is no timestamp field to pin, so this program can't
// be diffed against a precomputed fixed string the way the std_fs #319
// programs are. Instead, run_and_check_time_components re-derives a UTC
// epoch instant from the six reported components (via timegm/_mkgmtime) and
// checks it lands within a few seconds of a wall-clock reference the test
// harness samples itself right after the subprocess returns -- catching
// wrong-field/off-by-one/local-vs-UTC bugs (which would put the derived
// instant hours/days off) without flaking on build-time variance.
static json time_build_components_program() {
    // fs_print's compiled form already wraps the message in ball_to_string
    // (see compile_std_call's "print" case), so each component call is
    // printed directly -- no separate to_string wrapper needed.
    std::vector<json> stmts;
    for (const char* fn : {"year", "month", "day", "hour", "minute", "second"}) {
        stmts.push_back(fs_stmt(fs_print(fs_call("std_time", fn, fs_msg({})))));
    }
    return fs_build_program(fs_block(std::move(stmts), fs_lit_int(0)));
}

static bool run_and_check_time_components(const std::string& name,
                                          const fs::path& build_dir,
                                          std::string& failure_msg) {
    auto exe_path = locate_binary(build_dir, name);
    if (exe_path.empty()) {
        failure_msg = "built binary not found for " + name;
        return false;
    }
    std::string run_cmd = cmd_wrap(quote(exe_path.string()));
    std::string run_output;
    int run_rc = run_capture(run_cmd, run_output);
    // Sample our own UTC "now" immediately after the subprocess returns --
    // the closest deterministic reference point available (there is no
    // timestamp input to pin).
    std::time_t ref_t =
        std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    if (run_rc != 0) {
        failure_msg = "binary exited rc=" + std::to_string(run_rc) +
                      ", output: " + run_output;
        return false;
    }

    std::istringstream iss(run_output);
    std::vector<int64_t> vals;
    std::string line;
    while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        try {
            vals.push_back(std::stoll(line));
        } catch (...) {
            failure_msg = "non-integer output line: '" + line + "'";
            return false;
        }
    }
    if (vals.size() != 6) {
        failure_msg = "expected 6 output lines (year,month,day,hour,minute,"
                      "second), got " + std::to_string(vals.size()) + ": " +
                      run_output;
        return false;
    }
    int64_t year = vals[0], month = vals[1], day = vals[2],
             hour = vals[3], minute = vals[4], second = vals[5];

    if (month < 1 || month > 12) {
        failure_msg = "month out of range: " + std::to_string(month);
        return false;
    }
    if (day < 1 || day > 31) {
        failure_msg = "day out of range: " + std::to_string(day);
        return false;
    }
    if (hour < 0 || hour > 23) {
        failure_msg = "hour out of range: " + std::to_string(hour);
        return false;
    }
    if (minute < 0 || minute > 59) {
        failure_msg = "minute out of range: " + std::to_string(minute);
        return false;
    }
    if (second < 0 || second > 59) {
        failure_msg = "second out of range: " + std::to_string(second);
        return false;
    }

    std::tm actual_tm{};
    actual_tm.tm_year = static_cast<int>(year - 1900);
    actual_tm.tm_mon = static_cast<int>(month - 1);
    actual_tm.tm_mday = static_cast<int>(day);
    actual_tm.tm_hour = static_cast<int>(hour);
    actual_tm.tm_min = static_cast<int>(minute);
    actual_tm.tm_sec = static_cast<int>(second);
#if defined(_WIN32)
    std::time_t actual_t = _mkgmtime(&actual_tm);
#else
    std::time_t actual_t = timegm(&actual_tm);
#endif
    if (actual_t == static_cast<std::time_t>(-1)) {
        failure_msg = "reported components do not form a valid UTC "
                      "date/time: " + run_output;
        return false;
    }

    int64_t delta_secs = static_cast<int64_t>(ref_t) - static_cast<int64_t>(actual_t);
    // The subprocess samples "now" strictly before our post-run reference
    // sample, so delta should be a small non-negative number of seconds
    // (allow a little slack for clock granularity / scheduling jitter on
    // slow CI machines). Anything hours/days/months off means a real
    // field-mapping or UTC/local bug.
    constexpr int64_t kMinDeltaSecs = -5;
    constexpr int64_t kMaxDeltaSecs = 120;
    if (delta_secs < kMinDeltaSecs || delta_secs > kMaxDeltaSecs) {
        failure_msg = "component-derived instant is " +
                      std::to_string(delta_secs) +
                      "s away from the reference UTC 'now' sample "
                      "(year=" + std::to_string(year) +
                      " month=" + std::to_string(month) +
                      " day=" + std::to_string(day) +
                      " hour=" + std::to_string(hour) +
                      " minute=" + std::to_string(minute) +
                      " second=" + std::to_string(second) + ")";
        return false;
    }
    return true;
}

struct InlineExpectation {
    std::string name;
    std::string expected_stdout;
};

// Compile an in-memory Program (built above, not loaded from a fixture
// file) and append it to `programs`/`expectations` for the shared build +
// run pass. Returns false (and logs a FAIL) if compilation itself throws —
// e.g. exactly the issue #319 regression this coverage guards against.
static bool add_inline_fs_program(const std::string& name,
                                  const json& program,
                                  const std::string& expected_stdout,
                                  std::vector<Program>& programs,
                                  std::vector<InlineExpectation>& expectations,
                                  int& tests_run_ref, int& tests_failed_ref) {
    Program p;
    p.name = name;
    try {
        ball::CppCompiler compiler(ball::ir::parseProgram(program));
        p.cpp_source = compiler.compile();
    } catch (const std::exception& e) {
        tests_run_ref++;
        tests_failed_ref++;
        std::cout << "  " << name << "... FAIL (compile threw: " << e.what() << ")\n";
        return false;
    }
    programs.push_back(std::move(p));
    expectations.push_back({name, expected_stdout});
    return true;
}

static bool run_and_check_inline(const InlineExpectation& exp, const fs::path& build_dir,
                                 std::string& failure_msg) {
    auto exe_path = locate_binary(build_dir, exp.name);
    if (exe_path.empty()) {
        failure_msg = "built binary not found for " + exp.name;
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
    auto expected = normalize(exp.expected_stdout);
    if (actual != expected) {
        failure_msg = "output mismatch\n--- expected ---\n" + expected +
                      "\n--- actual ---\n" + actual + "\n---";
        return false;
    }
    return true;
}

int main() {
    // #18 Stage 5: libprotobuf/abseil are gone — the abseil mutex
    // deadlock-detection workaround (#25) is no longer needed.
    std::cout << "Ball C++ End-to-End Tests\n"
              << "=========================\n"
              << "Using CMake: " << BALL_E2E_CMAKE << "\n"
              << "Generator:  " << BALL_E2E_GENERATOR << "\n";

    // The canonical fixture list now lives in e2e_fixture_list.h so the fast
    // coverage-only corpus_driver can share it (issue #63).
    const std::vector<std::string>& program_names = ball_e2e::program_names();

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

    // Step 1b: build the std_fs direct-compile e2e programs (issue #319).
    // Kept in a separate vector (not `programs`) because their expected
    // output is compared inline rather than via an on-disk
    // .expected_output.txt — see run_and_check_inline.
    std::vector<Program> fs_programs;
    std::vector<InlineExpectation> fs_expectations;
    {
        fs::path fs_scratch = fs::temp_directory_path();
        std::string bytes_path = (fs_scratch / "ball_e2e_319_fs_write_bytes.bin").string();
        std::string append_path = (fs_scratch / "ball_e2e_319_fs_append.txt").string();
        add_inline_fs_program("319_fs_write_bytes_roundtrip",
                              fs_build_write_bytes_program(bytes_path), "0\n10\n",
                              fs_programs, fs_expectations, tests_run, tests_failed);
        add_inline_fs_program("319_fs_append_roundtrip",
                              fs_build_append_program(append_path), "Hello, World!\n",
                              fs_programs, fs_expectations, tests_run, tests_failed);
    }

    // Step 1c: build the std_time direct-compile e2e program (issue #328).
    // Shares the fs_programs build vector (so it rides the single CMake
    // pass below) but is validated separately in step 3c below since its
    // output can't be diffed against a fixed expected string -- see
    // run_and_check_time_components.
    const std::string kTimeProgramName = "328_std_time_components";
    bool time_program_built = false;
    {
        Program p;
        p.name = kTimeProgramName;
        try {
            ball::CppCompiler compiler(ball::ir::parseProgram(time_build_components_program()));
            p.cpp_source = compiler.compile();
            time_program_built = true;
        } catch (const std::exception& e) {
            tests_run++;
            tests_failed++;
            std::cout << "  " << p.name << "... FAIL (compile threw: "
                      << e.what() << ")\n";
        }
        if (time_program_built) fs_programs.push_back(std::move(p));
    }

    if (programs.empty() && fs_programs.empty()) {
        std::cout << "\nNo programs to test.\n";
        return tests_failed > 0 ? 1 : 0;
    }

    // Step 2: build all programs (fixture-loaded + inline) in a single CMake
    // invocation.
    std::vector<Program> build_targets = programs;
    build_targets.insert(build_targets.end(), fs_programs.begin(), fs_programs.end());
    std::string build_msg;
    if (!build_sub_project(proj_dir, build_dir, build_targets, build_msg)) {
        std::cout << "\nBuild of e2e scratch project FAILED:\n"
                  << build_msg << "\n";
        return 1;
    }

    // Step 3: run each fixture-loaded binary and diff against its
    // .expected_output.txt.
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

    // Step 3b: run each inline std_fs binary and diff against its inline
    // expected stdout (issue #319).
    for (const auto& exp : fs_expectations) {
        tests_run++;
        std::cout << "  " << exp.name << "... ";
        std::string failure_msg;
        if (run_and_check_inline(exp, build_dir, failure_msg)) {
            std::cout << "PASS\n";
            tests_passed++;
        } else {
            std::cout << "FAIL\n" << failure_msg << "\n";
            tests_failed++;
        }
    }

    // Step 3c: run the inline std_time components binary and validate its
    // output against a wall-clock UTC reference (issue #328).
    if (time_program_built) {
        tests_run++;
        std::cout << "  " << kTimeProgramName << "... ";
        std::string failure_msg;
        if (run_and_check_time_components(kTimeProgramName, build_dir, failure_msg)) {
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
