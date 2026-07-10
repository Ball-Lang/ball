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
// #18 Stage 5: always compiled — this is the SOLE binary `.ball.pb`/`.ball.bin`
// decoder (libprotobuf is gone).

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

// #18 Stage 5 — the final flip. Decodes a serialized `google.protobuf.Any`
// wrapping a `ball.v1.Program`/`ball.v1.Module` and returns its payload as a
// proto3-JSON string, using ONLY `ball_protobuf`'s descriptor-driven codecs
// (no libprotobuf). The caller (`ball_file.h`) parses the JSON straight into
// `ball::ir` — so the `.ball.pb`/`.ball.bin` binary path is now end-to-end
// libprotobuf-free.
//
// The full semantic tree (expression trees, signatures, module structure) is
// emitted with exact proto3-JSON fidelity. The `google.protobuf.*` payloads
// (`Struct metadata`, `DescriptorProto`/`EnumDescriptorProto`) are carried as
// opaque bytes by the runtime descriptor, so `marshalJson` emits them as base64
// strings; `ball_file.h` DECODES those via the three helpers below (the C++
// compiler reads metadata/descriptors for emission, so they must materialize —
// stripping them broke class/method emission in the self-host engine regen).
// `out_is_program` is set true for a Program payload, false for a Module.
std::string DecodeAnyPayloadJson(const std::string& any_bytes,
                                 bool& out_is_program);

// #18 Stage 5 — decoders for the opaque `google.protobuf.*` payloads that
// `DecodeAnyPayloadJson` leaves as base64 strings. Each takes the base64 TEXT
// and returns the payload's proto3-JSON, decoded with hand-written wire
// descriptors + ball_protobuf's own native WKT/JSON machinery (no libprotobuf):
//   - `metadata`   → google.protobuf.Struct        → JSON object
//   - `descriptor` → google.protobuf.DescriptorProto (snake_case keys,
//                    enum NAME-strings — the shape the encoder/corpus carries)
//   - `enums[i]`   → google.protobuf.EnumDescriptorProto
// Throw on malformed input.
std::string DecodeStructJsonB64(const std::string& b64);
std::string DecodeDescriptorProtoJsonB64(const std::string& b64);
std::string DecodeEnumDescriptorProtoJsonB64(const std::string& b64);

}  // namespace rt
}  // namespace ball
