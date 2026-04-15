// Ball C++ Compiler Snapshot Tests
//
// Pins the exact emitted C++ source for each Dart fixture. On first
// run (or when BALL_UPDATE_SNAPSHOTS is set) writes the snapshot file;
// on subsequent runs diffs against it.
//
// Catches emission drift that behavioral tests can miss: whitespace,
// re-ordering, helper restructuring, etc. Any diff is a reviewable
// artifact in the PR rather than silent change.

#include "compiler.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <google/protobuf/util/json_util.h>

#ifndef BALL_SNAPSHOT_DIR
#error "BALL_SNAPSHOT_DIR must be defined"
#endif
#ifndef BALL_GENERATED_JSON_DIR
#error "BALL_GENERATED_JSON_DIR must be defined"
#endif

namespace fs = std::filesystem;

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

static std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static void write_file(const fs::path& p, const std::string& content) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary);
    f << content;
}

static std::string normalize_line_endings(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (c != '\r') out.push_back(c);
    }
    return out;
}

int main() {
    std::cout << "Ball C++ Compiler Snapshot Tests\n"
              << "================================\n";

    fs::path json_dir(BALL_GENERATED_JSON_DIR);
    fs::path snap_dir(BALL_SNAPSHOT_DIR);
    if (!fs::exists(json_dir)) {
        std::cout << "Generated ball.json dir not found: "
                  << json_dir.string() << "\n"
                  << "Run the Dart cross-language test first to produce "
                     "the fixture JSONs.\n";
        return 0;
    }
    if (!fs::exists(snap_dir)) fs::create_directories(snap_dir);

    const char* update = std::getenv("BALL_UPDATE_SNAPSHOTS");
    const bool update_mode = update && std::string(update) == "1";

    std::vector<fs::path> json_files;
    for (auto& e : fs::directory_iterator(json_dir)) {
        if (!e.is_regular_file()) continue;
        auto s = e.path().filename().string();
        if (s.size() >= 10 && s.compare(s.size() - 10, 10, ".ball.json") == 0) {
            json_files.push_back(e.path());
        }
    }
    std::sort(json_files.begin(), json_files.end());

    for (const auto& jpath : json_files) {
        auto name = jpath.filename().string();
        name = name.substr(0, name.size() - 10);

        tests_run++;
        std::cout << "  " << name << "... ";

        ball::v1::Program program;
        google::protobuf::util::JsonParseOptions opts;
        opts.ignore_unknown_fields = true;
        auto status = google::protobuf::util::JsonStringToMessage(
            read_file(jpath), &program, opts);
        if (!status.ok()) {
            std::cout << "PARSE_FAIL: " << status.message() << "\n";
            tests_failed++;
            continue;
        }

        std::string compiled;
        try {
            ball::CppCompiler compiler(program);
            compiled = compiler.compile();
        } catch (const std::exception& e) {
            std::cout << "COMPILE_FAIL: " << e.what() << "\n";
            tests_failed++;
            continue;
        }

        auto snap_file = snap_dir / (name + ".snapshot.cpp");
        if (update_mode || !fs::exists(snap_file)) {
            write_file(snap_file, compiled);
            std::cout << "WROTE\n";
            tests_passed++;
            continue;
        }

        auto expected = normalize_line_endings(read_file(snap_file));
        auto actual = normalize_line_endings(compiled);
        if (actual == expected) {
            std::cout << "PASS\n";
            tests_passed++;
        } else {
            std::cout << "DIFF (rerun with BALL_UPDATE_SNAPSHOTS=1 if intended)\n";
            tests_failed++;
        }
    }

    std::cout << "\n================================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";
    return tests_failed > 0 ? 1 : 0;
}
