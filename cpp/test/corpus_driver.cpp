// Coverage-only corpus driver (issue #63).
//
// Compiles every conformance/generated fixture in ball_e2e::program_names()
// through CppCompiler::compile() WITHOUT the nested per-fixture g++ builds that
// test_e2e performs. Those inner builds run in a separate, non-instrumented
// subprocess and contribute ZERO coverage to the instrumented compiler.cpp, so
// this driver produces byte-identical instrumented compiler.cpp coverage to
// test_e2e's compile phase in ~11s instead of ~40min. Used by build-cov-run.sh
// to get a CI-equivalent compiler.cpp number cheaply.
//
// EXCLUDE_FROM_ALL: not built by the default `cmake --build`, only when named
// explicitly (build-cov-build.sh's target list). Never registered as a ctest
// test, so CI's `ctest` never runs it.

#include "compiler.h"

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

namespace fs = std::filesystem;

static std::string read_file(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

static bool resolve_fixture(const std::string& name, fs::path& out_path) {
    const std::vector<fs::path> dirs = {
        fs::path(BALL_CONFORMANCE_DIR),
        fs::path(BALL_GENERATED_FIXTURES_DIR),
    };
    for (const auto& dir : dirs) {
        auto candidate = dir / (name + ".ball.json");
        if (fs::exists(candidate)) {
            out_path = candidate;
            return true;
        }
    }
    return false;
}

int main() {
    int compiled = 0, failed = 0, missing = 0;
    for (const auto& name : ball_e2e::program_names()) {
        fs::path path;
        if (!resolve_fixture(name, path)) {
            ++missing;
            std::cerr << "MISSING " << name << "\n";
            continue;
        }
        std::string json = read_file(path);
        try {
            ball::ir::Program program = ball::DecodeProgram(path.string(), json);
            ball::CppCompiler compiler(std::move(program));
            volatile size_t sink = compiler.compile().size();
            (void)sink;
            ++compiled;
        } catch (const std::exception& e) {
            ++failed;
            std::cerr << "FAIL " << name << ": " << e.what() << "\n";
        }
    }
    std::cout << "corpus_driver: compiled=" << compiled << " failed=" << failed
              << " missing=" << missing << "\n";
    // Coverage tool: a fixture that fails to compile is a real regression, but
    // we still want the run to complete so gcov captures every arm it did hit.
    return (failed == 0 && missing == 0) ? 0 : 1;
}
