#pragma once

// ball/shared — common types and utilities for all C++ ball tooling.
//
// Mirrors the Dart `ball_base` package: re-exports protobuf types and
// provides the universal std module builders.

#include <any>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "ball/v1/ball.pb.h"
#include "google/protobuf/descriptor.pb.h"
#include "google/protobuf/struct.pb.h"

namespace ball {

// ================================================================
// BallValue — runtime value representation
// ================================================================
//
// Every ball value at runtime is one of:
//   - int64_t          (integer)
//   - double           (float)
//   - std::string      (string)
//   - bool             (boolean)
//   - std::vector<uint8_t>  (bytes)
//   - BallList         (list literal)
//   - BallMap          (message instance — field name → value)
//   - BallFunction     (lambda / closure)
//   - std::monostate   (null / void)

using BallValue = std::any;

// Convenience aliases
using BallList = std::vector<BallValue>;
using BallMap = std::map<std::string, BallValue>;
using BallFunction = std::function<BallValue(BallValue)>;

// Callable signature: (module, function, input) → result
using BallCallable = std::function<BallValue(
    const std::string&, const std::string&, BallValue)>;

// ================================================================
// Value extraction helpers
// ================================================================

inline int64_t to_int(const BallValue& v) {
    if (v.type() == typeid(int64_t)) return std::any_cast<int64_t>(v);
    if (v.type() == typeid(double)) return static_cast<int64_t>(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v) ? 1 : 0;
    return 0;
}

inline double to_double(const BallValue& v) {
    if (v.type() == typeid(double)) return std::any_cast<double>(v);
    if (v.type() == typeid(int64_t)) return static_cast<double>(std::any_cast<int64_t>(v));
    return 0.0;
}

inline bool to_bool(const BallValue& v) {
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v);
    if (v.type() == typeid(int64_t)) return std::any_cast<int64_t>(v) != 0;
    if (v.type() == typeid(double)) return std::any_cast<double>(v) != 0.0;
    if (v.type() == typeid(std::string)) return !std::any_cast<std::string>(v).empty();
    if (!v.has_value()) return false;
    return true;
}

inline std::string to_string(const BallValue& v) {
    if (v.type() == typeid(std::string)) return std::any_cast<std::string>(v);
    if (v.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(v));
    if (v.type() == typeid(double)) return std::to_string(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v) ? "true" : "false";
    if (!v.has_value()) return "null";
    return "<object>";
}

inline double to_num(const BallValue& v) {
    if (v.type() == typeid(double)) return std::any_cast<double>(v);
    if (v.type() == typeid(int64_t)) return static_cast<double>(std::any_cast<int64_t>(v));
    return 0.0;
}

inline bool is_int(const BallValue& v) { return v.type() == typeid(int64_t); }
inline bool is_double(const BallValue& v) { return v.type() == typeid(double); }
inline bool is_string(const BallValue& v) { return v.type() == typeid(std::string); }
inline bool is_bool(const BallValue& v) { return v.type() == typeid(bool); }
inline bool is_null(const BallValue& v) { return !v.has_value(); }
inline bool is_list(const BallValue& v) { return v.type() == typeid(BallList); }
inline bool is_map(const BallValue& v) { return v.type() == typeid(BallMap); }
inline bool is_function(const BallValue& v) { return v.type() == typeid(BallFunction); }

// Type-aware value equality: compares by type first, then by value.
inline bool values_equal(const BallValue& a, const BallValue& b) {
    if (!a.has_value() && !b.has_value()) return true;
    if (!a.has_value() || !b.has_value()) return false;
    if (a.type() == typeid(int64_t) && b.type() == typeid(int64_t))
        return std::any_cast<int64_t>(a) == std::any_cast<int64_t>(b);
    if (a.type() == typeid(double) && b.type() == typeid(double))
        return std::any_cast<double>(a) == std::any_cast<double>(b);
    if (a.type() == typeid(int64_t) && b.type() == typeid(double))
        return static_cast<double>(std::any_cast<int64_t>(a)) == std::any_cast<double>(b);
    if (a.type() == typeid(double) && b.type() == typeid(int64_t))
        return std::any_cast<double>(a) == static_cast<double>(std::any_cast<int64_t>(b));
    if (a.type() == typeid(std::string) && b.type() == typeid(std::string))
        return std::any_cast<std::string>(a) == std::any_cast<std::string>(b);
    if (a.type() == typeid(bool) && b.type() == typeid(bool))
        return std::any_cast<bool>(a) == std::any_cast<bool>(b);
    return false;
}

// Extract a field from a BallMap input, returning empty BallValue if not found
inline BallValue extract_field(const BallValue& input, const std::string& name) {
    if (input.type() != typeid(BallMap)) return {};
    const auto& m = std::any_cast<const BallMap&>(input);
    auto it = m.find(name);
    return it != m.end() ? it->second : BallValue{};
}

// Extract the "value" field from a UnaryInput
inline BallValue extract_unary(const BallValue& input) {
    return extract_field(input, "value");
}

// Extract "left" and "right" from a BinaryInput
inline std::pair<BallValue, BallValue> extract_binary(const BallValue& input) {
    return {extract_field(input, "left"), extract_field(input, "right")};
}

// ================================================================
// Struct ↔ map helpers (google.protobuf.Struct)
// ================================================================

BallMap struct_to_map(const google::protobuf::Struct& s);
BallValue value_proto_to_ball(const google::protobuf::Value& v);

// ================================================================
// std module builders
// ================================================================

// Build the universal std base module
ball::v1::Module build_std_module();

// Build the std_memory base module
ball::v1::Module build_std_memory_module();

// Build the std_collections base module
ball::v1::Module build_std_collections_module();

// Build the std_io base module
ball::v1::Module build_std_io_module();

}  // namespace ball
