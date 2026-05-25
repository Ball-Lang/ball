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
#include "ball_ordered_map_impl.h"

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
// Reference-semantic lists: copies of a BallValue share the underlying vector
// (Dart BallList / BallDyn BallListRef parity). Literal and scope-bound lists
// use BallListRef; legacy by-value BallList remains for interop copies.
using BallListRef = std::shared_ptr<BallList>;
// Insertion-ordered runtime maps (Dart LinkedHashMap parity).
using BallMap = BallOrderedMap;
// Reference-semantic ordered maps: copies of a BallValue share the underlying map.
using BallOrderedMapRef = std::shared_ptr<BallMap>;
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
    std::shared_ptr<BallList> values = std::make_shared<BallList>();
    bool completed = false;
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
    if (v.type() == typeid(BallGenerator)) return !std::any_cast<const BallGenerator&>(v).values->empty();
    if (!v.has_value()) return false;
    return true;
}

// Back-compat alias: existing call sites used `double_to_dart_string(d)`.
// The canonical implementation lives in ball_emit_runtime.h as the
// `ball_to_string(double)` overload.
inline std::string double_to_dart_string(double d) { return ball_to_string(d); }

inline BallList* ball_list_ptr(BallValue& v) {
    if (v.type() == typeid(BallListRef)) return std::any_cast<BallListRef&>(v).get();
    if (v.type() == typeid(BallList)) return &std::any_cast<BallList&>(v);
    return nullptr;
}
inline const BallList* ball_list_ptr(const BallValue& v) {
    if (v.type() == typeid(BallListRef)) return std::any_cast<const BallListRef&>(v).get();
    if (v.type() == typeid(BallList)) return &std::any_cast<const BallList&>(v);
    return nullptr;
}
inline BallList ball_list_copy(const BallValue& v) {
    if (const BallList* lp = ball_list_ptr(v)) return *lp;
    return {};
}
inline BallValue ball_list_value(BallList list) {
    return BallValue(BallListRef(std::make_shared<BallList>(std::move(list))));
}
inline BallValue ball_list_at(const BallValue& v, int64_t idx) {
    if (const BallList* lp = ball_list_ptr(v)) {
        if (idx >= 0 && static_cast<size_t>(idx) < lp->size()) return (*lp)[static_cast<size_t>(idx)];
    }
    return {};
}
inline int64_t ball_list_length(const BallValue& v) {
    if (const BallList* lp = ball_list_ptr(v)) return static_cast<int64_t>(lp->size());
    return 0;
}
inline bool is_list(const BallValue& v) {
    return v.type() == typeid(BallListRef) || v.type() == typeid(BallList);
}

inline BallMap* ball_map_ptr(BallValue& v) {
    if (v.type() == typeid(BallOrderedMapRef)) return std::any_cast<BallOrderedMapRef&>(v).get();
    if (v.type() == typeid(BallMap)) return &std::any_cast<BallMap&>(v);
    return nullptr;
}
inline const BallMap* ball_map_ptr(const BallValue& v) {
    if (v.type() == typeid(BallOrderedMapRef)) return std::any_cast<const BallOrderedMapRef&>(v).get();
    if (v.type() == typeid(BallMap)) return &std::any_cast<const BallMap&>(v);
    return nullptr;
}
inline BallMap ball_map_copy(const BallValue& v) {
    if (const BallMap* mp = ball_map_ptr(v)) return *mp;
    return {};
}
inline BallValue ball_map_value(BallMap map) {
    return BallValue(BallOrderedMapRef(std::make_shared<BallMap>(std::move(map))));
}

inline BallMap ball_map_make(std::initializer_list<std::pair<std::string, BallValue>> items) {
    BallMap map;
    for (const auto& [k, v] : items) map[k] = v;
    return map;
}
inline int64_t ball_map_length(const BallValue& v) {
    if (const BallMap* mp = ball_map_ptr(v)) return static_cast<int64_t>(mp->size());
    return 0;
}
inline bool ball_map_contains_key(const BallValue& v, const std::string& key) {
    if (const BallMap* mp = ball_map_ptr(v)) return mp->count(key) > 0;
    return false;
}

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
        for (size_t i = 0; i < gen.values->size(); i++) {
            if (i > 0) result += ", ";
            result += to_string((*gen.values)[i]);
        }
        result += "]";
        return result;
    }
    if (const BallList* lp = ball_list_ptr(v)) {
        std::string result = "[";
        for (size_t i = 0; i < lp->size(); i++) {
            if (i > 0) result += ", ";
            result += to_string((*lp)[i]);
        }
        result += "]";
        return result;
    }
    if (const BallMap* mp = ball_map_ptr(v)) {
        std::string result = "{";
        bool first = true;
        for (const auto& [k, val] : *mp) {
            if (k.rfind("__", 0) == 0 || k == "type_args") continue;
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
inline bool is_map(const BallValue& v) {
    return v.type() == typeid(BallOrderedMapRef) || v.type() == typeid(BallMap);
}
inline bool is_function(const BallValue& v) { return v.type() == typeid(BallFunction); }
inline bool is_future(const BallValue& v) { return v.type() == typeid(BallFuture); }
inline bool is_generator(const BallValue& v) { return v.type() == typeid(BallGenerator); }

// Unwrap BallFuture/BallGenerator to their inner values.
// In the synchronous C++ engine, BallFuture is always completed,
// so unwrapping is safe and immediate.
inline BallValue unwrap(const BallValue& v) {
    if (v.type() == typeid(BallFuture)) return std::any_cast<const BallFuture&>(v).value;
    if (v.type() == typeid(BallGenerator)) return ball_list_value(BallList(*std::any_cast<const BallGenerator&>(v).values));
    return v;
}

// Type-aware value equality: compares by type first, then by value.
inline bool values_equal(const BallValue& a, const BallValue& b) {
    if (!a.has_value() && !b.has_value()) return true;
    if (!a.has_value() || !b.has_value()) return false;
    if (a.type() == typeid(int64_t) && b.type() == typeid(int64_t))
        return std::any_cast<int64_t>(a) == std::any_cast<int64_t>(b);
    if (a.type() == typeid(double) && b.type() == typeid(double)) {
        double da = std::any_cast<double>(a);
        double db = std::any_cast<double>(b);
        if (std::isnan(da) || std::isnan(db)) return false;
        return da == db;
    }
    if (a.type() == typeid(int64_t) && b.type() == typeid(double)) {
        double db = std::any_cast<double>(b);
        if (std::isnan(db)) return false;
        return static_cast<double>(std::any_cast<int64_t>(a)) == db;
    }
    if (a.type() == typeid(double) && b.type() == typeid(int64_t)) {
        double da = std::any_cast<double>(a);
        if (std::isnan(da)) return false;
        return da == static_cast<double>(std::any_cast<int64_t>(b));
    }
    if (a.type() == typeid(std::string) && b.type() == typeid(std::string))
        return std::any_cast<std::string>(a) == std::any_cast<std::string>(b);
    if (a.type() == typeid(bool) && b.type() == typeid(bool))
        return std::any_cast<bool>(a) == std::any_cast<bool>(b);
    // Map equality: compare all key-value pairs recursively (by value, not pointer identity)
    if (is_map(a) && is_map(b)) {
        const BallMap* ma = ball_map_ptr(a);
        const BallMap* mb = ball_map_ptr(b);
        if (!ma || !mb || ma->size() != mb->size()) return false;
        for (const auto& [k, v] : *ma) {
            auto it = mb->find(k);
            if (it == mb->end()) return false;
            if (!values_equal(v, it->second)) return false;
        }
        return true;
    }
    // List equality (by value, not pointer identity)
    if (is_list(a) && is_list(b)) {
        const BallList* la = ball_list_ptr(a);
        const BallList* lb = ball_list_ptr(b);
        if (!la || !lb || la->size() != lb->size()) return false;
        for (size_t i = 0; i < la->size(); ++i) {
            if (!values_equal((*la)[i], (*lb)[i])) return false;
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
    if (!is_map(val)) return {};
    const BallMap* mp = ball_map_ptr(val);
    if (!mp) return {};
    auto it = mp->find(name);
    return it != mp->end() ? it->second : BallValue{};
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
