// #18 Stage 3 — byte-equivalence harness for the ball_protobuf binary path.
//
// Proves that routing `.ball.pb`/`.ball.bin` loading through Ball's own compiled
// protobuf runtime (`ball_protobuf_rt.h` + the generated
// `ball_program_descriptor.h`, behind `BALL_USE_BALL_PROTOBUF=ON`) yields a
// Program IN-MEMORY EQUIVALENT to google's Any/Program parser, across the whole
// conformance corpus.
//
// For each `tests/conformance/*.ball.json` fixture:
//   1. google:  JSON  → ball::v1::Program  (ground truth, via ball_file.h)
//   2. google:  Program → google.protobuf.Any → serialized bytes  (a real
//      `.ball.bin`)
//   3. ball:    Any bytes → DecodeBallFileBinary (routed through
//      ball::rt::DecodeAnyPayload: ball_protobuf unmarshals the Any envelope AND
//      the Program payload, re-marshals to bare wire bytes, google materializes)
//   4. assert:  MessageDifferencer::Equals(google_program, ball_program)
//
// Built + registered as the ctest `ball_rt_equivalence` only when
// BALL_USE_BALL_PROTOBUF is ON (see cpp/test/CMakeLists.txt).

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <google/protobuf/any.pb.h>
#include <google/protobuf/util/message_differencer.h>

#include "ball_file.h"

namespace fs = std::filesystem;
using google::protobuf::util::MessageDifferencer;

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined"
#endif

namespace {

std::string read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

struct Result {
    std::string name;
    bool ok = false;
    std::string detail;
};

Result check_fixture(const fs::path& path) {
    Result r;
    r.name = path.filename().string();
    try {
        const std::string json = read_file(path.string());

        // 1. Ground truth: google JSON → Program (ball_file.h JSON path).
        ball::v1::Program prog_google;
        ball::v1::Module mod_unused;
        ball::BallFileKind kind =
            ball::DecodeBallFileJson(json, prog_google, mod_unused);
        if (kind != ball::BallFileKind::kProgram) {
            r.detail = "fixture is not a Program";
            return r;
        }

        // 2. Serialize to a real google.protobuf.Any (.ball.bin) envelope.
        google::protobuf::Any any;
        any.PackFrom(prog_google);
        std::string any_bytes;
        if (!any.SerializeToString(&any_bytes)) {
            r.detail = "google Any serialization failed";
            return r;
        }

        // 3. ball_protobuf binary path (BALL_USE_BALL_PROTOBUF routes
        //    DecodeBallFileBinary through ball::rt::DecodeAnyPayload).
        ball::v1::Program prog_ball;
        ball::v1::Module mod_ball;
        ball::BallFileKind kind_ball =
            ball::DecodeBallFileBinary(any_bytes, prog_ball, mod_ball);
        if (kind_ball != ball::BallFileKind::kProgram) {
            r.detail = "ball_protobuf decoded a non-Program";
            return r;
        }

        // 4. In-memory equivalence.
        std::string diff;
        MessageDifferencer differ;
        differ.ReportDifferencesToString(&diff);
        if (!differ.Compare(prog_google, prog_ball)) {
            // Trim the diff to keep the failure log readable.
            if (diff.size() > 400) diff = diff.substr(0, 400) + " …";
            r.detail = "MessageDifferencer: " + diff;
            return r;
        }
        r.ok = true;
    } catch (const std::exception& e) {
        r.detail = std::string("exception: ") + e.what();
    }
    return r;
}

}  // namespace

int main() {
    const fs::path dir(BALL_CONFORMANCE_DIR);
    std::vector<fs::path> fixtures;
    for (const auto& entry : fs::directory_iterator(dir)) {
        const auto p = entry.path();
        const std::string name = p.filename().string();
        // *.ball.json only (skip *.expected, *.cpp sources, etc.).
        if (name.size() > 10 &&
            name.compare(name.size() - 10, 10, ".ball.json") == 0) {
            fixtures.push_back(p);
        }
    }
    std::sort(fixtures.begin(), fixtures.end());

    int passed = 0;
    int failed = 0;
    std::vector<Result> failures;
    for (const auto& f : fixtures) {
        Result r = check_fixture(f);
        if (r.ok) {
            ++passed;
        } else {
            ++failed;
            failures.push_back(r);
        }
    }

    for (const auto& r : failures) {
        std::cout << "FAIL " << r.name << ": " << r.detail << "\n";
    }

    const int total = passed + failed;
    std::cout << "Results: " << passed << " passed, " << failed << " failed, "
              << total << " total\n";

    // Strict gate: every fixture must be byte-equivalent through both paths.
    return failed == 0 ? 0 : 1;
}
