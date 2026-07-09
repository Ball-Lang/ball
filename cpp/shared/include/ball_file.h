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
// #18 Stage 5 — the final flip: libprotobuf is GONE. The loader now produces
// the protobuf-free `ball::ir` IR end-to-end:
//   - JSON form: the `@type` is extracted with a minimal (google-free) scanner
//     to discriminate Program vs Module, then the whole proto3-JSON object is
//     parsed straight into `ball::ir` via nlohmann/json.
//   - Binary form (`.ball.pb`/`.ball.bin`): decoded to proto3-JSON by Ball's
//     OWN compiled protobuf runtime (`ball::rt::DecodeAnyPayloadJson`, confined
//     to ball_rt_decode.cpp so its `BallDyn` universe never leaks here), then
//     parsed into `ball::ir` — no libprotobuf anywhere.

#include <cstdint>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

#include "ball_ir.h"        // ball::ir::Program/Module + proto3-JSON loader (nlohmann only)
#include "ball_rt_decode.h"  // google-free binary Any → proto3-JSON (links from ball_shared)

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

// Strips the cosmetic base64 remnants of opaque `google.protobuf.*` payloads
// left by the binary path's proto3-JSON serialization. The runtime protobuf
// descriptor carries `Struct metadata` and `DescriptorProto`/
// `EnumDescriptorProto` fields as opaque TYPE_BYTES (a message and a bytes
// field are byte-identical on the wire), so `marshalJson` emits them as base64
// strings (or arrays of base64 strings for the repeated `enums`). Metadata is
// cosmetic (Core Invariant 2) and proto3-JSON is the canonical full-fidelity
// input, so we drop these remnants rather than mis-parse a base64 string as a
// structured field. Recurses through the whole tree (metadata appears on every
// definition-like node).
inline void strip_opaque_wkt(ball::ir::json& j) {
    if (j.is_object()) {
        for (auto it = j.begin(); it != j.end();) {
            const std::string& k = it.key();
            ball::ir::json& v = it.value();
            if ((k == "metadata" || k == "descriptor") && v.is_string()) {
                it = j.erase(it);
                continue;
            }
            if (k == "enums" && v.is_array() && !v.empty() && v.front().is_string()) {
                it = j.erase(it);
                continue;
            }
            strip_opaque_wkt(v);
            ++it;
        }
    } else if (j.is_array()) {
        for (auto& e : j) strip_opaque_wkt(e);
    }
}

}  // namespace detail

// ── Binary decode ────────────────────────────────────────────────────────

// Parses a binary ball file (serialized google.protobuf.Any) and returns its
// kind. Fills `out_program` or `out_module` accordingly. Fully libprotobuf-free:
// Ball's own compiled protobuf runtime decodes the Any → proto3-JSON, which is
// parsed straight into `ball::ir`.
inline BallFileKind DecodeBallFileBinary(const std::string& bytes,
                                         ball::ir::Program& out_program,
                                         ball::ir::Module& out_module) {
    bool is_program = false;
    std::string js;
    try {
        js = ball::rt::DecodeAnyPayloadJson(bytes, is_program);
    } catch (const std::exception& e) {
        throw BallFileFormatException(
            std::string("ball_protobuf binary decode failed: ") + e.what());
    }
    ball::ir::json j;
    try {
        j = ball::ir::json::parse(js);
    } catch (const std::exception& e) {
        throw BallFileFormatException(
            std::string("ball_protobuf produced invalid JSON: ") + e.what());
    }
    detail::strip_opaque_wkt(j);
    if (is_program) {
        out_program = ball::ir::parseProgram(j);
        return BallFileKind::kProgram;
    }
    out_module = ball::ir::parseModule(j);
    return BallFileKind::kModule;
}

// ── JSON decode ──────────────────────────────────────────────────────────

// Parses a proto3-JSON ball file (an Any envelope with an "@type" field) and
// returns its kind. Fills `out_program` or `out_module` accordingly. The
// google-free `@type` scanner discriminates Program vs Module; the whole
// proto3-JSON object is then parsed into `ball::ir` via nlohmann/json (which
// ignores the unrecognized `@type` key).
inline BallFileKind DecodeBallFileJson(const std::string& json,
                                       ball::ir::Program& out_program,
                                       ball::ir::Module& out_module) {
    std::string type_url;
    // Reuse the strict scanner purely for @type extraction/validation (its
    // error messages — "must be an object", "missing \"@type\"", "malformed
    // \"@type\" member", …). The returned stripped body is unused: ball::ir
    // parses the original object and simply skips @type.
    (void)detail::extract_type_url_and_strip(json, type_url);

    if (detail::is_program_url(type_url)) {
        out_program = ball::ir::parseProgramString(json);
        return BallFileKind::kProgram;
    }
    if (detail::is_module_url(type_url)) {
        out_module = ball::ir::parseModule(ball::ir::json::parse(json));
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
                                   ball::ir::Program& out_program,
                                   ball::ir::Module& out_module) {
    if (detail::is_binary_path(path)) {
        return DecodeBallFileBinary(content, out_program, out_module);
    }
    return DecodeBallFileJson(content, out_program, out_module);
}

// ── Convenience loaders (from path, with type discrimination) ──────────────

// Loads a ball file from `path` and returns its Program, or throws if the
// file is a Module (or not a valid envelope).
inline ball::ir::Program LoadProgram(const std::string& path) {
    std::string content = detail::read_file_bytes(path);
    ball::ir::Program program;
    ball::ir::Module module;
    if (DecodeBallFile(path, content, program, module) !=
        BallFileKind::kProgram) {
        throw BallFileFormatException(
            "expected a Program ball file but got a Module: " + path);
    }
    return program;
}

// Loads a ball file from `path` and returns its Module, or throws if the file
// is a Program (or not a valid envelope).
inline ball::ir::Module LoadModule(const std::string& path) {
    std::string content = detail::read_file_bytes(path);
    ball::ir::Program program;
    ball::ir::Module module;
    if (DecodeBallFile(path, content, program, module) !=
        BallFileKind::kModule) {
        throw BallFileFormatException(
            "expected a Module ball file but got a Program: " + path);
    }
    return module;
}

// Decodes a Program directly from in-memory ball-file content, throwing if it
// wraps a Module. `path` drives only binary-vs-JSON detection.
inline ball::ir::Program DecodeProgram(const std::string& path,
                                       const std::string& content) {
    ball::ir::Program program;
    ball::ir::Module module;
    if (DecodeBallFile(path, content, program, module) !=
        BallFileKind::kProgram) {
        throw BallFileFormatException(
            "expected a Program ball file but got a Module");
    }
    return program;
}

}  // namespace ball
