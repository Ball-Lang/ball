// #18/#25 canary: exercises the Ball-compiled `ball_protobuf` runtime
// (ball_protobuf_rt.h) standalone — no libprotobuf, no abseil, no
// nlohmann/json. Round-trips a handful of values through the real wire
// codecs (varint, zigzag, fixed32) so a regression in the Ball->C++
// compiler or in `dart/ball_protobuf/lib/wire_*.dart` fails THIS target
// instead of only surfacing during the eventual #18 cutover.
//
// Beyond the primitive codecs it drives the full descriptor-driven
// marshal → unmarshal round-trip on a nested message (scalar + string +
// sub-message), which is the real guard for the two defects PR #331
// documented but could not verify without a working regen:
//   1. singular TYPE_MESSAGE marshaling (compiler named→positional arg
//      alignment: `messageDescriptor` was mis-slotted so a message field
//      threw "no messageDescriptor was provided"), and
//   2. the portable wire-buffer append fix (per-item `.add`, not the
//      non-mutating `addAll`) — a dropped string/sub-message payload makes
//      the round-trip lose data even though marshal doesn't throw.
// The unmarshal side re-checks every field, so offset mis-tracking would
// also surface here.
//
// Built only behind -DBALL_BUILD_PROTOBUF_RT=ON (see cpp/shared/CMakeLists.txt
// and cpp/shared/AGENTS.md for the full #18/#25 status).
#include "ball_protobuf_rt.h"

#include <any>
#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <vector>

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

// ── Descriptor-driven marshal/unmarshal round-trip ───────────────────────────
// BallDyn / BallMap / BallList / ball_length are GLOBAL: the runtime preamble
// is spliced at global scope — only the compiled ball_protobuf FUNCTIONS live
// in `namespace ball_protobuf`. BallDyn's operator[] transparently unwraps a
// BallDyn stored inside a std::any (see _BallDynUnwrapper), so wrapping every
// descriptor/message value in BallDyn is safe and mirrors how the engine
// threads values around.
std::any dyn(BallDyn v) { return std::any(std::move(v)); }

BallDyn scalarField(const char* name, int64_t number, const char* type) {
    BallMap m;
    m["name"s] = dyn(BallDyn(std::string(name)));
    m["number"s] = dyn(BallDyn(static_cast<int64_t>(number)));
    m["type"s] = dyn(BallDyn(std::string(type)));
    return BallDyn(std::move(m));
}

BallDyn messageField(const char* name, int64_t number, BallDyn subDescriptor) {
    BallMap m;
    m["name"s] = dyn(BallDyn(std::string(name)));
    m["number"s] = dyn(BallDyn(static_cast<int64_t>(number)));
    m["type"s] = dyn(BallDyn(std::string("TYPE_MESSAGE")));
    m["messageDescriptor"s] = dyn(std::move(subDescriptor));
    return BallDyn(std::move(m));
}

void check_message_roundtrip() {
    // Sub-message descriptor: { b: int32 #1 }.
    BallList subDesc;
    subDesc.push_back(dyn(scalarField("b", 1, "TYPE_INT32")));
    BallDyn subDescriptor(std::move(subDesc));

    // Top descriptor: { a: int32 #1, s: string #2, sub: message #3 }.
    BallList desc;
    desc.push_back(dyn(scalarField("a", 1, "TYPE_INT32")));
    desc.push_back(dyn(scalarField("s", 2, "TYPE_STRING")));
    desc.push_back(dyn(messageField("sub", 3, subDescriptor)));
    BallDyn descriptor(std::move(desc));

    // Message: { a: 42, s: "hi", sub: { b: 7 } }.
    BallMap subMsg;
    subMsg["b"s] = dyn(BallDyn(static_cast<int64_t>(7)));
    BallMap msg;
    msg["a"s] = dyn(BallDyn(static_cast<int64_t>(42)));
    msg["s"s] = dyn(BallDyn(std::string("hi")));
    msg["sub"s] = dyn(BallDyn(std::move(subMsg)));
    BallDyn message(std::move(msg));

    // Marshal. Before the compiler named-argument alignment fix this THREW on
    // the singular message field (messageDescriptor mis-slotted into
    // `delimited`, then defaulted to null in marshalField's TYPE_MESSAGE path).
    BallDyn bytes = ball_protobuf::marshal(message, descriptor);
    if (ball_length(bytes) == 0) {
        std::cerr << "FAIL roundtrip: marshal produced empty output\n";
        ++failures;
        return;
    }

    // Unmarshal and re-check every field. A dropped string payload (the
    // non-mutating-`addAll` wire bug) or a mis-tracked unmarshal offset would
    // corrupt one of these.
    BallDyn back = ball_protobuf::unmarshal(bytes, descriptor);
    expect_eq(static_cast<int64_t>(back["a"s]), 42, "roundtrip a");
    const std::string s = static_cast<std::string>(back["s"s]);
    if (s != "hi") {
        std::cerr << "FAIL roundtrip s: expected 'hi', got '" << s << "'\n";
        ++failures;
    }
    expect_eq(static_cast<int64_t>(back["sub"s]["b"s]), 7, "roundtrip sub.b");
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

    check_message_roundtrip();

    if (failures != 0) {
        std::cerr << failures << " ball_protobuf_rt smoke check(s) failed\n";
        return 1;
    }
    std::cout << "ball_protobuf_rt smoke: all round-trips OK\n";
    return 0;
}
