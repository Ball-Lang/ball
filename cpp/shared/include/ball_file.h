#pragma once

// ball/shared — self-describing ball-file envelope reader.
//
// Mirrors the Dart `dart/shared/lib/ball_file.dart` semantics.
//
// A ball file on disk (`.ball.json`, `.ball.bin`, or `.ball.pb`) is a
// serialized `google.protobuf.Any` wrapping exactly one top-level message —
// today a `ball.v1.Program` or a `ball.v1.Module`. Readers never guess the
// contained type: it is carried explicitly by the Any type URL, which in
// proto3 JSON is the `@type` field. New top-level types can be added without
// changing any reader's discrimination logic.
//
// Binary form uses the real `google.protobuf.Any` (type_url + value bytes).
// JSON form is the proto3-JSON representation of an Any:
//   {"@type": "type.googleapis.com/ball.v1.Program", <message fields…>}
// so it round-trips through the message's own proto3-JSON codec plus the one
// `@type` key — no type registry required.
//
// File-extension detection (binary vs JSON) is orthogonal to Program/Module,
// which the Any envelope carries explicitly:
//   `.ball.pb` / `.ball.bin`  → binary serialized google.protobuf.Any
//   anything else             → proto3-JSON Any envelope
//
// Header-only so it can be used by tooling that does not link nlohmann/json
// (e.g. the compiler) — the JSON `@type` is extracted with a minimal scanner,
// then the remaining JSON is handed to protobuf's own JsonStringToMessage.

#include <cstdint>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

#include <google/protobuf/any.pb.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl_lite.h>
#include <google/protobuf/util/json_util.h>

#include "ball/v1/ball.pb.h"

namespace ball {

inline constexpr const char* kTypeUrlPrefix = "type.googleapis.com";
inline constexpr const char* kProgramTypeUrl =
    "type.googleapis.com/ball.v1.Program";
inline constexpr const char* kModuleTypeUrl =
    "type.googleapis.com/ball.v1.Module";

// Thrown when a ball file is not a recognized self-describing envelope.
class BallFileFormatException : public std::runtime_error {
public:
    explicit BallFileFormatException(const std::string& message)
        : std::runtime_error("BallFileFormatException: " + message) {}
};

// Which top-level message a ball file carries.
enum class BallFileKind { kProgram, kModule };

namespace detail {

inline bool ends_with(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() &&
           s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

inline bool is_program_url(const std::string& url) {
    return ends_with(url, "/ball.v1.Program");
}
inline bool is_module_url(const std::string& url) {
    return ends_with(url, "/ball.v1.Module");
}

// True when the path names a binary ball file by extension.
inline bool is_binary_path(const std::string& path) {
    return ends_with(path, ".ball.pb") || ends_with(path, ".ball.bin");
}

// Extracts the top-level "@type" string value from a proto3-JSON Any object
// and returns the JSON with that member removed (so it can be parsed straight
// into the payload message). Minimal scanner — sufficient for the well-formed
// proto3-JSON our tools emit, and registry-free so the compiler need not link
// a full JSON parser.
//
// Throws BallFileFormatException if the JSON is not an object or has no
// top-level "@type" member.
inline std::string extract_type_url_and_strip(const std::string& json,
                                              std::string& out_type_url) {
    // Find the opening brace of the top-level object.
    size_t i = 0;
    while (i < json.size() && (json[i] == ' ' || json[i] == '\t' ||
                               json[i] == '\n' || json[i] == '\r')) {
        ++i;
    }
    if (i >= json.size() || json[i] != '{') {
        throw BallFileFormatException("ball file JSON must be an object");
    }

    // Scan the top-level object's members, tracking string/escape state so we
    // never match a "@type" key that appears nested inside a value.
    const std::string key = "\"@type\"";
    size_t depth = 0;
    bool in_string = false;
    bool escaped = false;
    size_t key_start = std::string::npos;  // index of opening quote of @type key
    for (size_t p = i; p < json.size(); ++p) {
        char c = json[p];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            case '"':
                in_string = true;
                // Only a member key at the top level (depth == 1) can be @type.
                if (depth == 1 &&
                    json.compare(p, key.size(), key) == 0) {
                    key_start = p;
                    p += key.size() - 1;  // skip past the matched key
                    in_string = false;
                }
                break;
            case '{':
            case '[':
                ++depth;
                break;
            case '}':
            case ']':
                --depth;
                break;
            default:
                break;
        }
        if (key_start != std::string::npos) break;
    }

    if (key_start == std::string::npos) {
        throw BallFileFormatException(
            "ball file JSON is not self-describing: missing \"@type\" "
            "(expected a google.protobuf.Any envelope)");
    }

    // Parse:  "@type"  :  "<url>"
    size_t p = key_start + key.size();
    auto skip_ws = [&]() {
        while (p < json.size() && (json[p] == ' ' || json[p] == '\t' ||
                                   json[p] == '\n' || json[p] == '\r')) {
            ++p;
        }
    };
    skip_ws();
    if (p >= json.size() || json[p] != ':') {
        throw BallFileFormatException("malformed \"@type\" member");
    }
    ++p;  // ':'
    skip_ws();
    if (p >= json.size() || json[p] != '"') {
        throw BallFileFormatException("\"@type\" value must be a string");
    }
    size_t val_start = ++p;  // first char of url
    std::string url;
    bool val_escaped = false;
    for (; p < json.size(); ++p) {
        char c = json[p];
        if (val_escaped) {
            url.push_back(c);
            val_escaped = false;
        } else if (c == '\\') {
            val_escaped = true;
        } else if (c == '"') {
            break;
        } else {
            url.push_back(c);
        }
    }
    if (p >= json.size()) {
        throw BallFileFormatException("unterminated \"@type\" value");
    }
    size_t val_end = p;  // index of closing quote
    (void)val_start;
    out_type_url = url;

    // Remove the "@type" member from the object: span [key_start, member_end),
    // where member_end consumes a trailing comma (and surrounding whitespace)
    // if present, otherwise a leading comma.
    size_t member_start = key_start;
    size_t member_end = val_end + 1;  // just past closing quote of the value

    // Look for a trailing comma after the value.
    size_t q = member_end;
    while (q < json.size() && (json[q] == ' ' || json[q] == '\t' ||
                               json[q] == '\n' || json[q] == '\r')) {
        ++q;
    }
    if (q < json.size() && json[q] == ',') {
        member_end = q + 1;  // drop the trailing comma too
    } else {
        // No trailing comma (e.g. @type was the last member): drop a leading
        // comma instead so the object stays well-formed.
        size_t r = member_start;
        while (r > 0) {
            char c = json[r - 1];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                --r;
                continue;
            }
            if (c == ',') {
                member_start = r - 1;
            }
            break;
        }
    }

    std::string out;
    out.reserve(json.size());
    out.append(json, 0, member_start);
    out.append(json, member_end, std::string::npos);
    return out;
}

inline std::string read_file_bytes(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        throw BallFileFormatException("could not open " + path);
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

}  // namespace detail

// ── Binary decode ────────────────────────────────────────────────────────

// Parses a binary ball file (serialized google.protobuf.Any) and returns its
// kind. Unpacks the payload into `out_program` or `out_module` accordingly.
inline BallFileKind DecodeBallFileBinary(const std::string& bytes,
                                         ball::v1::Program& out_program,
                                         ball::v1::Module& out_module) {
    google::protobuf::Any any;
    google::protobuf::io::ArrayInputStream raw(
        bytes.data(), static_cast<int>(bytes.size()));
    google::protobuf::io::CodedInputStream coded(&raw);
    coded.SetRecursionLimit(10000);
    if (!any.ParseFromCodedStream(&coded)) {
        throw BallFileFormatException(
            "failed to parse binary google.protobuf.Any envelope");
    }
    if (detail::is_program_url(any.type_url())) {
        if (!any.UnpackTo(&out_program)) {
            throw BallFileFormatException(
                "failed to unpack Program from Any (type_url=\"" +
                any.type_url() + "\")");
        }
        return BallFileKind::kProgram;
    }
    if (detail::is_module_url(any.type_url())) {
        if (!any.UnpackTo(&out_module)) {
            throw BallFileFormatException(
                "failed to unpack Module from Any (type_url=\"" +
                any.type_url() + "\")");
        }
        return BallFileKind::kModule;
    }
    throw BallFileFormatException(
        "unknown ball file type URL: \"" + any.type_url() + "\"");
}

// ── JSON decode ──────────────────────────────────────────────────────────

// Parses a proto3-JSON ball file (an Any envelope with an "@type" field) and
// returns its kind. Fills `out_program` or `out_module` accordingly.
inline BallFileKind DecodeBallFileJson(const std::string& json,
                                       ball::v1::Program& out_program,
                                       ball::v1::Module& out_module) {
    std::string type_url;
    std::string body = detail::extract_type_url_and_strip(json, type_url);

    google::protobuf::util::JsonParseOptions opts;
    opts.ignore_unknown_fields = true;

    if (detail::is_program_url(type_url)) {
        auto status =
            google::protobuf::util::JsonStringToMessage(body, &out_program, opts);
        if (!status.ok()) {
            throw BallFileFormatException(
                "failed to parse Program JSON: " + std::string(status.message()));
        }
        return BallFileKind::kProgram;
    }
    if (detail::is_module_url(type_url)) {
        auto status =
            google::protobuf::util::JsonStringToMessage(body, &out_module, opts);
        if (!status.ok()) {
            throw BallFileFormatException(
                "failed to parse Module JSON: " + std::string(status.message()));
        }
        return BallFileKind::kModule;
    }
    throw BallFileFormatException("unknown ball file @type: \"" + type_url + "\"");
}

// ── Content decode (extension-driven binary/JSON detection) ────────────────

// Decodes ball-file content. `path` is used only for binary-vs-JSON detection
// by extension (`.ball.pb`/`.ball.bin` = binary, else JSON); the Program/Module
// discrimination comes from the Any envelope.
inline BallFileKind DecodeBallFile(const std::string& path,
                                   const std::string& content,
                                   ball::v1::Program& out_program,
                                   ball::v1::Module& out_module) {
    if (detail::is_binary_path(path)) {
        return DecodeBallFileBinary(content, out_program, out_module);
    }
    return DecodeBallFileJson(content, out_program, out_module);
}

// ── Convenience loaders (from path, with type discrimination) ──────────────

// Loads a ball file from `path` and returns its Program, or throws if the
// file is a Module (or not a valid envelope).
inline ball::v1::Program LoadProgram(const std::string& path) {
    std::string content = detail::read_file_bytes(path);
    ball::v1::Program program;
    ball::v1::Module module;
    if (DecodeBallFile(path, content, program, module) !=
        BallFileKind::kProgram) {
        throw BallFileFormatException(
            "expected a Program ball file but got a Module: " + path);
    }
    return program;
}

// Loads a ball file from `path` and returns its Module, or throws if the file
// is a Program (or not a valid envelope).
inline ball::v1::Module LoadModule(const std::string& path) {
    std::string content = detail::read_file_bytes(path);
    ball::v1::Program program;
    ball::v1::Module module;
    if (DecodeBallFile(path, content, program, module) !=
        BallFileKind::kModule) {
        throw BallFileFormatException(
            "expected a Module ball file but got a Program: " + path);
    }
    return module;
}

// Decodes a Program directly from in-memory ball-file content, throwing if it
// wraps a Module. `path` drives only binary-vs-JSON detection.
inline ball::v1::Program DecodeProgram(const std::string& path,
                                       const std::string& content) {
    ball::v1::Program program;
    ball::v1::Module module;
    if (DecodeBallFile(path, content, program, module) !=
        BallFileKind::kProgram) {
        throw BallFileFormatException(
            "expected a Program ball file but got a Module");
    }
    return program;
}

}  // namespace ball
