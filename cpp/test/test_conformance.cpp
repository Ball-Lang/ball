// Ball C++ Conformance Test Suite
//
// Mirrors dart/engine/test/conformance_test.dart: loads every
// *.ball.json from tests/conformance/, runs it through the C++ engine,
// and compares stdout against the matching .expected_output.txt.
//
// The path to the conformance directory is baked in at configure time
// via the BALL_CONFORMANCE_DIR preprocessor macro, so tests can run from
// any cwd without relying on relative paths.

#include "engine.h"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <google/protobuf/util/json_util.h>

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined by the build system"
#endif

namespace fs = std::filesystem;

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

// Normalize to LF line endings and strip trailing whitespace so the
// comparison is insensitive to platform line-ending differences and to
// whether the expected file has a trailing newline.
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

static bool run_one(const fs::path& program_path, const fs::path& expected_path,
                    std::string& failure_msg) {
    auto json = read_file(program_path);
    ball::v1::Program program;
    google::protobuf::util::JsonParseOptions opts;
    opts.ignore_unknown_fields = true;
    auto status = google::protobuf::util::JsonStringToMessage(json, &program, opts);
    if (!status.ok()) {
        failure_msg = "JSON parse failed: " + std::string(status.message());
        return false;
    }

    std::vector<std::string> captured;
    // Suppress real stdout; only collect lines.
    ball::Engine engine(program, [&](const std::string& line) {
        captured.push_back(line);
    });
    try {
        engine.run();
    } catch (const std::exception& e) {
        failure_msg = std::string("engine threw: ") + e.what();
        return false;
    }

    std::string actual;
    for (size_t i = 0; i < captured.size(); i++) {
        if (i > 0) actual += '\n';
        actual += captured[i];
    }
    actual = normalize(std::move(actual));
    std::string expected = normalize(read_file(expected_path));

    if (actual != expected) {
        failure_msg = "output mismatch\n--- expected ---\n" + expected +
                      "\n--- actual ---\n" + actual + "\n---";
        return false;
    }
    return true;
}

int main() {
    std::cout << "Ball C++ Conformance Tests\n"
              << "==========================\n";

    fs::path dir(BALL_CONFORMANCE_DIR);
    if (!fs::exists(dir)) {
        std::cout << "Conformance directory not found: " << dir.string()
                  << " (skipping)\n";
        return 0;
    }

    std::vector<fs::path> programs;
    for (auto& entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file()) continue;
        auto p = entry.path();
        auto s = p.filename().string();
        if (s.size() >= 10 && s.compare(s.size() - 10, 10, ".ball.json") == 0) {
            programs.push_back(p);
        }
    }
    std::sort(programs.begin(), programs.end());

    for (const auto& program_path : programs) {
        auto name = program_path.filename().string();
        // Strip .ball.json
        name = name.substr(0, name.size() - 10);
        auto expected_path = program_path.parent_path() /
                             (name + ".expected_output.txt");
        if (!fs::exists(expected_path)) continue;

        tests_run++;
        std::cout << "  " << name << "... ";
        std::string failure_msg;
        if (run_one(program_path, expected_path, failure_msg)) {
            std::cout << "PASS\n";
            tests_passed++;
        } else {
            std::cout << "FAIL\n" << failure_msg << "\n";
            tests_failed++;
        }
    }

    std::cout << "\n==========================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";
    return tests_failed > 0 ? 1 : 0;
}
