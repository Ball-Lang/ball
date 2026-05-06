#pragma once

// ball/shared — common types and utilities for all C++ ball tooling.
//
// Mirrors the Dart `ball_base` package: re-exports protobuf types and
// provides the universal std module builders.

#include <algorithm>
#include <any>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <random>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <variant>
#include <vector>

using namespace std::string_literals;

// Shared runtime helpers (BallException, ball_to_string). The compiler
// also embeds this file verbatim into every emitted C++ program so the
// runtime functions have one canonical definition.
#include "ball_emit_runtime.h"

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

// BallFuture — wraps a completed value (synchronous simulation of async)
struct BallFuture {
    BallValue value;
    bool completed = true;
};

// BallGenerator — accumulates yielded values (synchronous simulation of sync*)
struct BallGenerator {
    BallList values;
};

// ================================================================
// Value extraction helpers
// ================================================================

inline int64_t to_int(const BallValue& v) {
    if (v.type() == typeid(int64_t)) return std::any_cast<int64_t>(v);
    if (v.type() == typeid(double)) return static_cast<int64_t>(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v) ? 1 : 0;
    if (v.type() == typeid(BallFuture)) return to_int(std::any_cast<const BallFuture&>(v).value);
    return 0;
}

inline double to_double(const BallValue& v) {
    if (v.type() == typeid(double)) return std::any_cast<double>(v);
    if (v.type() == typeid(int64_t)) return static_cast<double>(std::any_cast<int64_t>(v));
    if (v.type() == typeid(BallFuture)) return to_double(std::any_cast<const BallFuture&>(v).value);
    return 0.0;
}

inline bool to_bool(const BallValue& v) {
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v);
    if (v.type() == typeid(int64_t)) return std::any_cast<int64_t>(v) != 0;
    if (v.type() == typeid(double)) return std::any_cast<double>(v) != 0.0;
    if (v.type() == typeid(std::string)) return !std::any_cast<std::string>(v).empty();
    if (v.type() == typeid(BallFuture)) return to_bool(std::any_cast<const BallFuture&>(v).value);
    if (v.type() == typeid(BallGenerator)) return !std::any_cast<const BallGenerator&>(v).values.empty();
    if (!v.has_value()) return false;
    return true;
}

// Back-compat alias: existing call sites used `double_to_dart_string(d)`.
// The canonical implementation lives in ball_emit_runtime.h as the
// `ball_to_string(double)` overload.
inline std::string double_to_dart_string(double d) { return ball_to_string(d); }

inline std::string to_string(const BallValue& v) {
    if (v.type() == typeid(std::string)) return std::any_cast<std::string>(v);
    if (v.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(v));
    if (v.type() == typeid(double)) return ball_to_string(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return ball_to_string(std::any_cast<bool>(v));
    if (!v.has_value()) return "null";
    if (v.type() == typeid(BallFuture)) return to_string(std::any_cast<const BallFuture&>(v).value);
    if (v.type() == typeid(BallGenerator)) {
        const auto& gen = std::any_cast<const BallGenerator&>(v);
        std::string result = "[";
        for (size_t i = 0; i < gen.values.size(); i++) {
            if (i > 0) result += ", ";
            result += to_string(gen.values[i]);
        }
        result += "]";
        return result;
    }
    if (v.type() == typeid(BallList)) {
        const auto& lst = std::any_cast<const BallList&>(v);
        std::string result = "[";
        for (size_t i = 0; i < lst.size(); i++) {
            if (i > 0) result += ", ";
            result += to_string(lst[i]);
        }
        result += "]";
        return result;
    }
    if (v.type() == typeid(BallMap)) {
        const auto& m = std::any_cast<const BallMap&>(v);
        std::string result = "{";
        bool first = true;
        for (const auto& [k, val] : m) {
            if (!first) result += ", ";
            first = false;
            result += k + ": " + to_string(val);
        }
        result += "}";
        return result;
    }
    return "<object>";
}

inline double to_num(const BallValue& v) {
    if (v.type() == typeid(double)) return std::any_cast<double>(v);
    if (v.type() == typeid(int64_t)) return static_cast<double>(std::any_cast<int64_t>(v));
    if (v.type() == typeid(BallFuture)) return to_num(std::any_cast<const BallFuture&>(v).value);
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
inline bool is_future(const BallValue& v) { return v.type() == typeid(BallFuture); }
inline bool is_generator(const BallValue& v) { return v.type() == typeid(BallGenerator); }

// Unwrap BallFuture/BallGenerator to their inner values.
// In the synchronous C++ engine, BallFuture is always completed,
// so unwrapping is safe and immediate.
inline BallValue unwrap(const BallValue& v) {
    if (v.type() == typeid(BallFuture)) return std::any_cast<const BallFuture&>(v).value;
    if (v.type() == typeid(BallGenerator)) return BallList{std::move(std::any_cast<BallGenerator>(v).values)};
    return v;
}

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
    // Map equality: compare all key-value pairs recursively
    if (a.type() == typeid(BallMap) && b.type() == typeid(BallMap)) {
        const auto& ma = std::any_cast<const BallMap&>(a);
        const auto& mb = std::any_cast<const BallMap&>(b);
        if (ma.size() != mb.size()) return false;
        for (const auto& [k, v] : ma) {
            auto it = mb.find(k);
            if (it == mb.end()) return false;
            if (!values_equal(v, it->second)) return false;
        }
        return true;
    }
    // List equality
    if (a.type() == typeid(BallList) && b.type() == typeid(BallList)) {
        const auto& la = std::any_cast<const BallList&>(a);
        const auto& lb = std::any_cast<const BallList&>(b);
        if (la.size() != lb.size()) return false;
        for (size_t i = 0; i < la.size(); ++i) {
            if (!values_equal(la[i], lb[i])) return false;
        }
        return true;
    }
    // BallFuture equality: compare inner values
    if (a.type() == typeid(BallFuture) && b.type() == typeid(BallFuture))
        return values_equal(std::any_cast<const BallFuture&>(a).value,
                           std::any_cast<const BallFuture&>(b).value);
    if (a.type() == typeid(BallFuture))
        return values_equal(std::any_cast<const BallFuture&>(a).value, b);
    if (b.type() == typeid(BallFuture))
        return values_equal(a, std::any_cast<const BallFuture&>(b).value);
    return false;
}

// Extract a field from a BallMap input, returning empty BallValue if not found.
// Auto-unwraps BallFuture values on the input.
inline BallValue extract_field(const BallValue& input, const std::string& name) {
    BallValue val = input;
    if (val.type() == typeid(BallFuture)) val = std::any_cast<const BallFuture&>(val).value;
    if (val.type() != typeid(BallMap)) return {};
    const auto& m = std::any_cast<const BallMap&>(val);
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
