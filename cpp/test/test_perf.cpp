// Ball C++ Performance Regression Harness
//
// Runs every tests/conformance/*.ball.json program through the C++
// engine `kIterations` times and writes per-program timings to a CSV
// at `<build>/test/perf.csv`. The CSV format is:
//
//   program,min_ms,median_ms,max_ms,mean_ms
//
// Regressions are checked against tests/perf_baseline.csv using the
// ratio `min_ms / reference_min_ms`, where reference is 01_hello_world.
// - RATIO, not absolute time: cancels out machine load / CPU freq / build
//   type. Essential for a checked-in baseline that must work on a
//   contributor's loaded laptop and on idle CI alike.
// - MIN, not median: noise can only make things slower, not faster, so
//   min is the cleanest measurement for micro-benchmarks.
//
// A program is flagged as a regression when its current ratio exceeds
// baseline_ratio * kRegressionTolerance. Regenerate the baseline by
// running `cp build/test/perf.csv tests/perf_baseline.csv`.

#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <numeric>
#include <sstream>
#include <string>
#include <vector>

#include <google/protobuf/util/json_util.h>

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined"
#endif
#ifndef BALL_PERF_CSV_OUT
#error "BALL_PERF_CSV_OUT must be defined"
#endif
#ifndef BALL_PERF_BASELINE
#error "BALL_PERF_BASELINE must be defined"
#endif

namespace fs = std::filesystem;

static constexpr int kIterations = 10;
// A program is flagged as a regression when its current cost-ratio (its
// median / the reference program's median) exceeds baseline_ratio *
// kRegressionTolerance. 1.5x is permissive enough to absorb routine
// noise while still catching material regressions.
static constexpr double kRegressionTolerance = 1.5;
// Reference program used to normalize measurements. Must exist in the
// conformance corpus and be short enough to reflect pure engine
// overhead rather than program workload.
static constexpr const char* kReferenceProgram = "01_hello_world";

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

struct Stats {
    double min_ms;
    double median_ms;
    double max_ms;
    double mean_ms;
};

// Load a baseline CSV into a name → min_ms map. Missing file returns
// an empty map (interpreted as "no baseline — capture only").
static std::map<std::string, double> load_baseline(const fs::path& path) {
    std::map<std::string, double> out;
    if (!fs::exists(path)) return out;
    std::ifstream f(path);
    std::string line;
    std::getline(f, line); // header
    while (std::getline(f, line)) {
        // program,min,median,max,mean — use the min column (index 1).
        size_t comma1 = line.find(',');
        if (comma1 == std::string::npos) continue;
        size_t comma2 = line.find(',', comma1 + 1);
        if (comma2 == std::string::npos) continue;
        auto name = line.substr(0, comma1);
        auto min_str = line.substr(comma1 + 1, comma2 - comma1 - 1);
        try {
            out[name] = std::stod(min_str);
        } catch (...) {
            // Skip malformed rows.
        }
    }
    return out;
}

static Stats compute_stats(std::vector<double> samples) {
    std::sort(samples.begin(), samples.end());
    Stats s{};
    s.min_ms = samples.front();
    s.max_ms = samples.back();
    s.median_ms = samples[samples.size() / 2];
    double sum = std::accumulate(samples.begin(), samples.end(), 0.0);
    s.mean_ms = sum / static_cast<double>(samples.size());
    return s;
}

int main() {
    std::cout << "Ball C++ Performance Harness\n"
              << "============================\n"
              << "Iterations per program: " << kIterations << "\n";

    auto baseline = load_baseline(BALL_PERF_BASELINE);
    if (baseline.empty()) {
        std::cout << "Baseline not found at " << BALL_PERF_BASELINE
                  << " — capture-only mode.\n";
    } else {
        std::cout << "Baseline loaded (" << baseline.size()
                  << " programs). Regression tolerance: "
                  << kRegressionTolerance << "x median.\n";
    }

    fs::path dir(BALL_CONFORMANCE_DIR);
    if (!fs::exists(dir)) {
        std::cout << "Conformance directory not found: " << dir.string() << "\n";
        return 0;
    }

    std::vector<fs::path> programs;
    for (auto& entry : fs::directory_iterator(dir)) {
        if (!entry.is_regular_file()) continue;
        auto s = entry.path().filename().string();
        if (s.size() >= 10 && s.compare(s.size() - 10, 10, ".ball.json") == 0) {
            programs.push_back(entry.path());
        }
    }
    std::sort(programs.begin(), programs.end());

    // Phase 1: run every program and collect stats.
    struct Result {
        std::string name;
        Stats stats;
        bool ok;
        std::string fail_reason;
    };
    std::vector<Result> results;
    int failures = 0;
    for (const auto& path : programs) {
        Result r;
        r.name = path.filename().string();
        r.name = r.name.substr(0, r.name.size() - 10);

        ball::v1::Program program;
        if (!load_program(path, program)) {
            r.ok = false;
            r.fail_reason = "PARSE_FAIL";
            failures++;
            results.push_back(r);
            continue;
        }
        try {
            ball::Engine warm(program, [](const std::string&) {});
            warm.run();
        } catch (...) {
            r.ok = false;
            r.fail_reason = "RUNTIME_FAIL";
            failures++;
            results.push_back(r);
            continue;
        }
        std::vector<double> samples;
        samples.reserve(kIterations);
        for (int i = 0; i < kIterations; i++) {
            auto t0 = std::chrono::steady_clock::now();
            ball::Engine engine(program, [](const std::string&) {});
            engine.run();
            auto t1 = std::chrono::steady_clock::now();
            samples.push_back(
                std::chrono::duration<double, std::milli>(t1 - t0).count());
        }
        r.stats = compute_stats(samples);
        r.ok = true;
        results.push_back(r);
    }

    // Phase 2: find the reference program's min (for ratio normalization).
    double reference_min = 0.0;
    for (const auto& r : results) {
        if (r.ok && r.name == kReferenceProgram) {
            reference_min = r.stats.min_ms;
            break;
        }
    }
    if (reference_min <= 0.0) {
        std::cerr << "ERROR: reference program \"" << kReferenceProgram
                  << "\" not found or zero-cost. Regression check skipped.\n";
    }

    // The baseline CSV stores absolute times; convert it to ratio space
    // using its own reference min.
    double baseline_reference = 0.0;
    if (auto it = baseline.find(kReferenceProgram); it != baseline.end()) {
        baseline_reference = it->second;
    }

    // Phase 3: write the CSV and diff each result.
    std::ofstream csv(BALL_PERF_CSV_OUT);
    csv << "program,min_ms,median_ms,max_ms,mean_ms\n";
    for (const auto& r : results) {
        if (!r.ok) {
            std::cout << "  " << r.name << "... " << r.fail_reason << "\n";
            continue;
        }
        const auto& s = r.stats;
        std::cout << "  " << r.name << "... "
                  << "min=" << s.min_ms << "ms "
                  << "median=" << s.median_ms << "ms "
                  << "max=" << s.max_ms << "ms";

        // Compare (our_min / our_reference) vs (baseline_min / baseline_reference).
        // Using min instead of median is more stable — noise can only
        // slow things down, so the fastest observed run is the cleanest
        // measurement of the engine's intrinsic cost.
        auto it = baseline.find(r.name);
        if (it == baseline.end()) {
            if (!baseline.empty()) std::cout << " [NEW]";
        } else if (reference_min > 0.0 && baseline_reference > 0.0) {
            double now_ratio = s.min_ms / reference_min;
            double base_ratio = it->second / baseline_reference;
            double regression = now_ratio / base_ratio;
            if (regression > kRegressionTolerance) {
                std::cout << " [REGRESSION " << regression
                          << "x ratio " << now_ratio
                          << " vs baseline " << base_ratio << "]";
                failures++;
            } else if (regression < 1.0 / kRegressionTolerance) {
                std::cout << " [IMPROVED " << regression << "x]";
            }
        }
        std::cout << "\n";

        csv << r.name << "," << s.min_ms << "," << s.median_ms << ","
            << s.max_ms << "," << s.mean_ms << "\n";
    }

    csv.close();
    std::cout << "\n============================\n"
              << "CSV written to: " << BALL_PERF_CSV_OUT << "\n"
              << "Reference min (" << kReferenceProgram << "): "
              << reference_min << "ms\n"
              << "Failures: " << failures << "\n";
    return failures > 0 ? 1 : 0;
}
