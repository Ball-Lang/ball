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

#include "ball_file.h"
#include "ball_ir.h"

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

// Strip the shared runtime preamble (BALL_EMIT_RUNTIME_SOURCE + BALL_DYN_SOURCE
// + the compiler's inline proto-compat/dyn helpers) so pinned snapshots
// contain only the program-specific tail (~2-10 KB) instead of the ~240 KB
// runtime that is byte-identical across every fixture. The compiler emits
// ball::CppCompiler::kRuntimePreambleEndMarker as the last line of the
// preamble (see emit_includes() in compiler.cpp); everything up to and
// including that line is dropped. Returns false (fail loud, no silent
// fallback to the unstripped 240 KB text) if the marker isn't found —
// that would mean emit_includes() changed and this helper needs updating.
static bool strip_runtime_preamble(const std::string& compiled, std::string& tail) {
    const std::string marker = ball::CppCompiler::kRuntimePreambleEndMarker;
    auto marker_pos = compiled.find(marker);
    if (marker_pos == std::string::npos) return false;
    auto line_end = compiled.find('\n', marker_pos);
    tail = (line_end == std::string::npos) ? std::string()
                                            : compiled.substr(line_end + 1);
    return true;
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

        ball::ir::Program program;
        try {
            program = ball::ir::parseProgramString(read_file(jpath));
        } catch (const std::exception& e) {
            std::cout << "PARSE_FAIL: " << e.what() << "\n";
            tests_failed++;
            continue;
        }

        std::string compiled;
        try {
            ball::CppCompiler compiler(std::move(program));
            compiled = compiler.compile();
        } catch (const std::exception& e) {
            std::cout << "COMPILE_FAIL: " << e.what() << "\n";
            tests_failed++;
            continue;
        }

        std::string program_tail;
        if (!strip_runtime_preamble(compiled, program_tail)) {
            std::cout << "PREAMBLE_MARKER_MISSING (compiler.cpp emit_includes() "
                          "no longer emits kRuntimePreambleEndMarker)\n";
            tests_failed++;
            continue;
        }
        compiled = program_tail;

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
