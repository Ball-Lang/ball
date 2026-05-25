// Focused micro-benchmark for the C++ native engine.
//
// Loads a fixed set of call/dispatch-heavy conformance fixtures once,
// then constructs + runs the engine many times each, reporting the
// median wall-clock ms. Unlike test_perf (10 iters over all 221
// fixtures), this runs few fixtures at high iteration count so the
// median is stable enough to measure single-digit-% perf changes in
// seconds. Capture-only; no budget enforcement.
//
// Override the iteration count with BALL_MICRO_ITERS and the fixture
// list with BALL_MICRO_FIXTURES (comma-separated basenames).

#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <numeric>
#include <sstream>
#include <string>
#include <vector>

#include <google/protobuf/util/json_util.h>

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined"
#endif

namespace fs = std::filesystem;

static std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static bool load_program(const fs::path& path, ball::v1::Program& out) {
    auto json = read_file(path);
    google::protobuf::util::JsonParseOptions opts;
    opts.ignore_unknown_fields = true;
    return google::protobuf::util::JsonStringToMessage(json, &out, opts).ok();
}

int main() {
    // Default fixture set: exercises calls, recursion, OOP dispatch,
    // closures, sorting (list/map mutation).
    std::vector<std::string> fixtures = {
        "10_fibonacci",
        "101_simple_class",
        "107_method_override_super",
        "132_merge_sort",
        "133_quick_sort",
        "203_closure_in_loop",
        "59_deep_recursion",
        "114_class_hierarchy",
    };
    if (const char* f = std::getenv("BALL_MICRO_FIXTURES")) {
        fixtures.clear();
        std::stringstream ss(f);
        std::string item;
        while (std::getline(ss, item, ',')) if (!item.empty()) fixtures.push_back(item);
    }

    int iters = 200;
    if (const char* it = std::getenv("BALL_MICRO_ITERS")) {
        int v = std::atoi(it);
        if (v > 0) iters = v;
    }

    fs::path dir(BALL_CONFORMANCE_DIR);
    std::cout << "Ball C++ Micro-Benchmark (iters=" << iters << ")\n";
    std::cout << "=========================================\n";

    double grand_total = 0.0;
    for (const auto& name : fixtures) {
        fs::path path = dir / (name + ".ball.json");
        if (!fs::exists(path)) {
            std::cout << "  " << name << "... MISSING\n";
            continue;
        }
        ball::v1::Program program;
        if (!load_program(path, program)) {
            std::cout << "  " << name << "... PARSE_FAIL\n";
            continue;
        }
        // Warm-up.
        try {
            ball::Engine warm(program, [](const std::string&) {});
            warm.run();
        } catch (...) {
            std::cout << "  " << name << "... RUNTIME_FAIL\n";
            continue;
        }
        std::vector<double> samples;
        samples.reserve(iters);
        for (int i = 0; i < iters; i++) {
            auto t0 = std::chrono::steady_clock::now();
            ball::Engine engine(program, [](const std::string&) {});
            engine.run();
            auto t1 = std::chrono::steady_clock::now();
            samples.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
        std::sort(samples.begin(), samples.end());
        double med = samples[samples.size() / 2];
        double mn = samples.front();
        double total = std::accumulate(samples.begin(), samples.end(), 0.0);
        grand_total += total;
        std::cout << "  " << name << ": median=" << med << "ms min=" << mn
                  << "ms total=" << total << "ms\n";
    }
    std::cout << "-----------------------------------------\n";
    std::cout << "GRAND TOTAL: " << grand_total << "ms\n";
    return 0;
}
