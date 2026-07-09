#pragma once

// #18 Stage 3 — descriptor-driven binary decode via Ball's own protobuf runtime.
//
// This is the pure-`std` seam between `ball_file.h` (which knows only
// google.protobuf types) and `ball_protobuf_rt.h` (Ball's compiled protobuf
// runtime, which brings its own global `BallDyn`/`BallMap`/`BallList` universe).
// Those two `BallDyn` definitions MUST NOT meet in one translation unit, so all
// `ball_protobuf` usage is confined to `ball_rt_decode.cpp`; this header exposes
// only a `std::string`-in / `std::string`-out interface.
//
// Only compiled when `BALL_USE_BALL_PROTOBUF=ON` (see cpp/shared/CMakeLists.txt).

#include <string>

namespace ball {
namespace rt {

// Decodes a serialized `google.protobuf.Any` (`type_url` + `value`) that wraps a
// `ball.v1.Program` or `ball.v1.Module`, using ONLY `ball_protobuf`'s
// descriptor-driven codecs (no libprotobuf). The Any envelope AND its payload
// are unmarshaled with the runtime descriptors, then the payload message is
// re-marshaled to canonical protobuf binary (the bare Program/Module wire bytes,
// no Any wrapper) and returned.
//
// `out_is_program` is set true for a `ball.v1.Program` payload, false for a
// `ball.v1.Module`. Throws `std::runtime_error` on an unrecognized `type_url`.
//
// The returned bytes are handed to google's `ParseFromString` by `ball_file.h`
// as a Stage-4 bridge (google's binary parse of a message it did not itself
// serialize); Stage 4 replaces that final materialization with `ball::ir`.
std::string DecodeAnyPayload(const std::string& any_bytes, bool& out_is_program);

}  // namespace rt
}  // namespace ball
