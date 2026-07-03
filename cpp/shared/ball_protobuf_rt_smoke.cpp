// #18/#25 canary: exercises the Ball-compiled `ball_protobuf` runtime
// (ball_protobuf_rt.h) standalone — no libprotobuf, no abseil, no
// nlohmann/json. Round-trips a handful of values through the real wire
// codecs (varint, zigzag, fixed32) so a regression in the Ball->C++
// compiler or in `dart/ball_protobuf/lib/wire_*.dart` fails THIS target
// instead of only surfacing during the eventual #18 cutover.
//
// Built only behind -DBALL_BUILD_PROTOBUF_RT=ON (see cpp/shared/CMakeLists.txt
// and cpp/shared/AGENTS.md for the full #18/#25 status).
#include "ball_protobuf_rt.h"

#include <cstdlib>
#include <iostream>

namespace {

int failures = 0;

void expect_eq(int64_t actual, int64_t expected, const char* what) {
    if (actual != expected) {
        std::cerr << "FAIL " << what << ": expected " << expected
                   << ", got " << actual << "\n";
        ++failures;
    }
}

// Varint round-trip across the boundary values that exercise every extra
// continuation byte (0, 1-byte max, 2-byte min, and a multi-byte value).
void check_varint(int64_t value) {
    using namespace ball_protobuf;
    BallDyn buf = makeBuffer();
    BallDyn encoded = encodeVarint(buf, value);
    BallDyn decoded = decodeVarint(encoded, static_cast<int64_t>(0));
    expect_eq(static_cast<int64_t>(decoded["value"s]), value, "varint round-trip");
    expect_eq(static_cast<int64_t>(decoded["bytesRead"s]),
              static_cast<int64_t>(ball_length(encoded)), "varint bytesRead");
}

// ZigZag round-trip (including negative values, the whole point of zigzag).
void check_zigzag(int64_t value) {
    using namespace ball_protobuf;
    BallDyn encoded = encodeZigZag64(value);
    BallDyn decoded = decodeZigZag(static_cast<int64_t>(encoded));
    expect_eq(static_cast<int64_t>(decoded), value, "zigzag round-trip");
}

// Fixed32 round-trip (little-endian 4-byte layout).
void check_fixed32(int64_t value) {
    using namespace ball_protobuf;
    BallDyn buf = makeBuffer();
    BallDyn encoded = encodeFixed32(buf, value);
    BallDyn decoded = decodeFixed32(encoded, static_cast<int64_t>(0));
    expect_eq(static_cast<int64_t>(decoded["value"s]), value, "fixed32 round-trip");
}

}  // namespace

int main() {
    check_varint(0);
    check_varint(1);
    check_varint(127);   // last 1-byte value
    check_varint(128);   // first 2-byte value
    check_varint(300);
    check_varint(16384); // first 3-byte value
    check_varint(123456789);

    check_zigzag(0);
    check_zigzag(1);
    check_zigzag(-1);
    check_zigzag(300);
    check_zigzag(-300);

    check_fixed32(0);
    check_fixed32(1);
    check_fixed32(4294967295LL); // uint32 max

    if (failures != 0) {
        std::cerr << failures << " ball_protobuf_rt smoke check(s) failed\n";
        return 1;
    }
    std::cout << "ball_protobuf_rt smoke: all round-trips OK\n";
    return 0;
}
