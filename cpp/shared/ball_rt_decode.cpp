// #18 Stage 3 — descriptor-driven binary decode via ball_protobuf_rt.h.
//
// Confines the entire `ball_protobuf` global-`BallDyn` universe to this one TU.
// The public interface (ball_rt_decode.h) is pure std::string, so `ball_file.h`
// and its consumers never see a second `BallDyn` definition.

#include "ball_rt_decode.h"

#include <cstdint>
#include <stdexcept>
#include <string>

#include "ball_protobuf_rt.h"       // Ball's compiled protobuf runtime (global BallDyn).
#include "ball_program_descriptor.h"  // ball.v1 message descriptors (generated).

namespace ball {
namespace rt {
namespace {

// google.protobuf.Any wire shape: type_url = 1 (string), value = 2 (bytes).
BallDyn anyDescriptor() {
    BallMap type_url;
    type_url["name"s] = std::any(std::string("type_url"));
    type_url["number"s] = std::any(static_cast<int64_t>(1));
    type_url["type"s] = std::any(std::string("TYPE_STRING"));

    BallMap value;
    value["name"s] = std::any(std::string("value"));
    value["number"s] = std::any(static_cast<int64_t>(2));
    value["type"s] = std::any(std::string("TYPE_BYTES"));

    BallList fields;
    fields.push_back(std::any(BallDyn(std::move(type_url))));
    fields.push_back(std::any(BallDyn(std::move(value))));
    return BallDyn(std::move(fields));
}

// Raw bytes → a ball_protobuf "buffer" (a list of 0..255 int byte values).
BallDyn bytesToBuffer(const std::string& bytes) {
    BallList buf;
    buf.reserve(bytes.size());
    for (unsigned char c : bytes) {
        buf.push_back(std::any(static_cast<int64_t>(c)));
    }
    return BallDyn(std::move(buf));
}

// A ball_protobuf buffer (list of int byte values) → raw bytes.
std::string bufferToBytes(BallDyn buffer) {
    const int64_t n = ball_length(buffer);
    std::string out;
    out.reserve(static_cast<std::size_t>(n));
    for (int64_t i = 0; i < n; ++i) {
        out.push_back(static_cast<char>(
            static_cast<unsigned char>(static_cast<int64_t>(buffer[i]))));
    }
    return out;
}

bool ends_with(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() &&
           s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

}  // namespace

std::string DecodeAnyPayload(const std::string& any_bytes, bool& out_is_program) {
    // 1. Decode the google.protobuf.Any envelope via ball_protobuf.
    BallDyn any = ball_protobuf::unmarshal(bytesToBuffer(any_bytes), anyDescriptor());
    BallDyn type_url_dyn = any["type_url"s];
    const std::string type_url =
        type_url_dyn.has_value() ? static_cast<std::string>(type_url_dyn)
                                 : std::string();

    // 2. Pick the payload descriptor from the type URL.
    BallDyn payload_descriptor;
    if (ends_with(type_url, "/ball.v1.Program")) {
        out_is_program = true;
        payload_descriptor = ball_protobuf::descriptor::programDescriptor();
    } else if (ends_with(type_url, "/ball.v1.Module")) {
        out_is_program = false;
        payload_descriptor = ball_protobuf::descriptor::moduleDescriptor();
    } else {
        throw std::runtime_error(
            "ball_protobuf DecodeAnyPayload: unknown Any type_url \"" + type_url +
            "\"");
    }

    // 3. Descriptor-driven unmarshal of the payload, then re-marshal to bare
    //    Program/Module wire bytes (opaque google.protobuf.* fields and any
    //    unknown fields are preserved verbatim — see ball_program_descriptor.h).
    BallDyn value_buf = any["value"s];  // list-of-int payload bytes (may be empty)
    BallDyn message = ball_protobuf::unmarshal(value_buf, payload_descriptor);
    BallDyn re_marshaled = ball_protobuf::marshal(message, payload_descriptor);
    return bufferToBytes(re_marshaled);
}

std::string DecodeAnyPayloadJson(const std::string& any_bytes,
                                 bool& out_is_program) {
    // 1. Decode the google.protobuf.Any envelope via ball_protobuf.
    BallDyn any = ball_protobuf::unmarshal(bytesToBuffer(any_bytes), anyDescriptor());
    BallDyn type_url_dyn = any["type_url"s];
    const std::string type_url =
        type_url_dyn.has_value() ? static_cast<std::string>(type_url_dyn)
                                 : std::string();

    // 2. Pick the payload descriptor from the type URL.
    BallDyn payload_descriptor;
    if (ends_with(type_url, "/ball.v1.Program")) {
        out_is_program = true;
        payload_descriptor = ball_protobuf::descriptor::programDescriptor();
    } else if (ends_with(type_url, "/ball.v1.Module")) {
        out_is_program = false;
        payload_descriptor = ball_protobuf::descriptor::moduleDescriptor();
    } else {
        throw std::runtime_error(
            "ball_protobuf DecodeAnyPayloadJson: unknown Any type_url \"" +
            type_url + "\"");
    }

    // 3. Descriptor-driven unmarshal, then serialize to proto3-JSON via
    //    ball_protobuf's own JSON codec (WKT-aware). The opaque
    //    google.protobuf.* fields serialize as base64 strings (they are
    //    TYPE_BYTES in the runtime descriptor); ball_file.h strips those.
    BallDyn value_buf = any["value"s];  // list-of-int payload bytes (may be empty)
    BallDyn message = ball_protobuf::unmarshal(value_buf, payload_descriptor);
    BallDyn json_dyn = ball_protobuf::marshalJson(message, payload_descriptor);
    return json_dyn.has_value() ? static_cast<std::string>(json_dyn)
                                : std::string("{}");
}

}  // namespace rt
}  // namespace ball
