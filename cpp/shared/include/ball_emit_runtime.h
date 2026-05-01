// ball_emit_runtime.h — single source of truth for the small runtime
// helpers that are embedded into every compiler-emitted C++ program.
//
// This file is:
//   1. #included by the ball C++ engine (via ball_shared.h) so the
//      interpreter uses the same formatting as compiled programs.
//   2. Slurped verbatim at CMake configure time and embedded as a
//      C++ string constant in `ball_emit_runtime_embed.h`, which the
//      compiler splices into the preamble of every emitted program.
//
// Changes here automatically propagate to both sides. Keep the file
// self-contained: the compiler's emit_includes already brings in
// <string>, <sstream>, <stdexcept>, <cmath> — don't add #includes.

#ifndef BALL_EMIT_RUNTIME_H
#define BALL_EMIT_RUNTIME_H

// Minimal Ball exception type used by `throw` / `try` to preserve
// typed-catch semantics. Derives from std::exception so untyped
// `catch (const std::exception&)` clauses still match.
//
// `fields` holds the individual field values when the thrown Ball
// value was a messageCreation (e.g. `{__type: 'NotFound', detail: 'x'}`).
// Catch-side field access (`e.detail` in Ball IR) compiles to
// `e.fields.at("detail")` so the original structured payload round-trips.
struct BallException : public std::runtime_error {
    std::string type_name;
    std::map<std::string, std::string> fields;
    BallException(std::string t, std::string msg)
        : std::runtime_error(msg), type_name(std::move(t)) {}
    BallException(std::string t, std::string msg,
                  std::map<std::string, std::string> f)
        : std::runtime_error(msg), type_name(std::move(t)),
          fields(std::move(f)) {}
};

// Stream inserter so `print(e)` on a catch-bound BallException works
// (it falls through to printing `.what()`, matching the old
// string-binding behavior for plain-string throws).
inline std::ostream& operator<<(std::ostream& os, const BallException& e) {
    return os << e.what();
}

// Dart-compatible string conversion. Handles bool and doubles so
// compiled programs produce the same output as the Dart engine
// (e.g. `true` instead of `1`, `6.0` instead of `6.000000`).
inline std::string ball_to_string(bool b) { return b ? std::string("true") : std::string("false"); }
inline std::string ball_to_string(const std::string& s) { return s; }
inline std::string ball_to_string(const char* s) { return s; }
inline std::string ball_to_string(double d) {
    if (d != d) return "NaN";
    if (d > 1e308 || d < -1e308) return d < 0 ? "-Infinity" : "Infinity";
    if (d == static_cast<double>(static_cast<long long>(d)) && d < 1e16 && d > -1e16) {
        return std::to_string(static_cast<long long>(d)) + ".0";
    }
    std::ostringstream oss;
    oss.precision(15);
    oss << d;
    auto s = oss.str();
    if (s.find('.') != std::string::npos) {
        while (s.size() > 1 && s.back() == '0') s.pop_back();
        if (s.back() == '.') s.push_back('0');
    }
    return s;
}

// Forward declare for vector recursion before the template catch-all.
template<typename T> inline std::string ball_to_string(const std::vector<T>& v);

template<typename T> inline std::string ball_to_string(T v) { return std::to_string(v); }

// Type aliases needed by ball_to_string(const std::any&) below.
using BallValue_RT = std::any;
using BallMap_RT = std::map<std::string, std::any>;
using BallList_RT = std::vector<std::any>;
using BallFunc_RT = std::function<std::any(std::any)>;

// std::any — attempt known types, fallback to type name.
inline std::string ball_to_string(const std::any& v) {
    if (!v.has_value()) return "null";
    if (v.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(v));
    if (v.type() == typeid(int)) return std::to_string(std::any_cast<int>(v));
    if (v.type() == typeid(double)) return ball_to_string(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return ball_to_string(std::any_cast<bool>(v));
    if (v.type() == typeid(std::string)) return std::any_cast<std::string>(v);
    if (v.type() == typeid(const char*)) return std::any_cast<const char*>(v);
    if (v.type() == typeid(BallList_RT)) return ball_to_string(std::any_cast<const BallList_RT&>(v));
    if (v.type() == typeid(BallMap_RT)) {
        auto& m = std::any_cast<const BallMap_RT&>(v);
        std::string out = "{";
        bool first = true;
        for (auto it = m.begin(); it != m.end(); ++it) {
            if (it->first.find("__") == 0 || it->first == "type_args") continue;
            if (!first) out += ", ";
            out += it->first + ": " + ball_to_string(it->second);
            first = false;
        }
        out += "}";
        return out;
    }
    return "<any>";
}

// Lists render as Dart-style `[a, b, c]`. Each element uses
// ball_to_string so nested structures / bools / doubles all follow
// the Dart conventions.
template<typename T>
inline std::string ball_to_string(const std::vector<T>& v) {
    std::string out = "[";
    bool first = true;
    for (const auto& el : v) {
        if (!first) out += ", ";
        out += ball_to_string(el);
        first = false;
    }
    out += "]";
    return out;
}

// ================================================================
// Type-check helpers for compiled Ball programs
// ================================================================
//
// These free functions mirror ball::is_map, ball::is_list, etc. from
// ball_shared.h but live in the global namespace so compiled programs
// (which embed this header, not ball_shared.h) can use them.

inline bool ball_is_int(const std::any& v) { return v.has_value() && v.type() == typeid(int64_t); }
inline bool ball_is_double(const std::any& v) { return v.has_value() && v.type() == typeid(double); }
inline bool ball_is_string(const std::any& v) { return v.has_value() && v.type() == typeid(std::string); }
inline bool ball_is_bool(const std::any& v) { return v.has_value() && v.type() == typeid(bool); }
inline bool ball_is_list(const std::any& v) { return v.has_value() && v.type() == typeid(BallList_RT); }
inline bool ball_is_map(const std::any& v) {
    return v.has_value() && v.type() == typeid(BallMap_RT);
}
inline bool ball_is_function(const std::any& v) { return v.has_value() && v.type() == typeid(BallFunc_RT); }

// Check if a value is a FlowSignal (a map with a "kind" field).
inline bool ball_is_flow_signal(const std::any& v) {
    if (!v.has_value() || v.type() != typeid(BallMap_RT)) return false;
    const auto& m = std::any_cast<const BallMap_RT&>(v);
    return m.count("kind") > 0;
}

// Compare type names accounting for module-qualified forms.
inline bool ball_type_name_matches(const std::string& obj_type, const std::string& check_type) {
    if (obj_type == check_type) return true;
    auto colon1 = obj_type.find(':');
    if (colon1 != std::string::npos && obj_type.substr(colon1 + 1) == check_type) return true;
    auto colon2 = check_type.find(':');
    if (colon2 != std::string::npos && check_type.substr(colon2 + 1) == obj_type) return true;
    if (colon1 != std::string::npos && colon2 != std::string::npos) {
        return obj_type.substr(colon1 + 1) == check_type.substr(colon2 + 1);
    }
    return false;
}

// Check if a map value's __type__ matches a type name (walks __super__ chain).
inline bool ball_object_type_matches(const std::any& value, const std::string& type) {
    if (!value.has_value() || value.type() != typeid(BallMap_RT)) return false;
    const auto& m = std::any_cast<const BallMap_RT&>(value);
    auto it = m.find("__type__");
    if (it != m.end() && it->second.has_value() && it->second.type() == typeid(std::string)) {
        if (ball_type_name_matches(std::any_cast<const std::string&>(it->second), type)) return true;
    }
    auto sit = m.find("__super__");
    std::any super_obj = (sit != m.end()) ? sit->second : std::any{};
    while (super_obj.has_value() && super_obj.type() == typeid(BallMap_RT)) {
        const auto& sm = std::any_cast<const BallMap_RT&>(super_obj);
        auto st = sm.find("__type__");
        if (st != sm.end() && st->second.has_value() && st->second.type() == typeid(std::string)) {
            if (ball_type_name_matches(std::any_cast<const std::string&>(st->second), type)) return true;
        }
        auto ss = sm.find("__super__");
        super_obj = (ss != sm.end()) ? ss->second : std::any{};
    }
    return false;
}

// ================================================================
// Dart protobuf API bridge helpers
// ================================================================
//
// The Dart Ball engine (self-hosted) uses Dart protobuf APIs like
// `expr.whichExpr()`, `func.hasBody()`, `Expression_Expr.call`, etc.
// When the Dart engine is compiled to Ball IR and then to C++, these
// calls appear in the generated code. The functions below provide C++
// implementations that work on the `std::any`-based map representation
// that the Ball compiler uses for all unknown types.
//
// All Ball objects at runtime are either primitive values or
// std::map<std::string, std::any> / std::unordered_map<std::string, std::any>.

// Helper to check if a std::any holds a map with a given key that has a value.
// Mirrors Dart protobuf `hasX()` methods.
inline bool ball_has_field(const std::any& obj, const std::string& field) {
    if (!obj.has_value()) return false;
    if (obj.type() == typeid(std::map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::map<std::string, std::any>&>(obj);
        auto it = m.find(field);
        return it != m.end() && it->second.has_value();
    }
    if (obj.type() == typeid(std::unordered_map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::unordered_map<std::string, std::any>&>(obj);
        auto it = m.find(field);
        return it != m.end() && it->second.has_value();
    }
    return false;
}

// Dart protobuf oneof discriminators — return a string tag indicating which
// oneof variant is set. These operate on the map representation used by the
// Ball interpreter for Expression, Literal, Value, etc. objects.
inline std::string ball_which_expr(const std::any& obj) {
    if (!obj.has_value()) return "notSet";
    if (obj.type() == typeid(std::map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::map<std::string, std::any>&>(obj);
        if (m.count("call") && m.at("call").has_value()) return "call";
        if (m.count("literal") && m.at("literal").has_value()) return "literal";
        if (m.count("reference") && m.at("reference").has_value()) return "reference";
        if (m.count("fieldAccess") && m.at("fieldAccess").has_value()) return "fieldAccess";
        if (m.count("messageCreation") && m.at("messageCreation").has_value()) return "messageCreation";
        if (m.count("block") && m.at("block").has_value()) return "block";
        if (m.count("lambda") && m.at("lambda").has_value()) return "lambda";
    }
    if (obj.type() == typeid(std::unordered_map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::unordered_map<std::string, std::any>&>(obj);
        if (m.count("call") && m.at("call").has_value()) return "call";
        if (m.count("literal") && m.at("literal").has_value()) return "literal";
        if (m.count("reference") && m.at("reference").has_value()) return "reference";
        if (m.count("fieldAccess") && m.at("fieldAccess").has_value()) return "fieldAccess";
        if (m.count("messageCreation") && m.at("messageCreation").has_value()) return "messageCreation";
        if (m.count("block") && m.at("block").has_value()) return "block";
        if (m.count("lambda") && m.at("lambda").has_value()) return "lambda";
    }
    return "notSet";
}

inline std::string ball_which_value(const std::any& obj) {
    if (!obj.has_value()) return "notSet";
    if (obj.type() == typeid(std::map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::map<std::string, std::any>&>(obj);
        if (m.count("intValue") && m.at("intValue").has_value()) return "intValue";
        if (m.count("doubleValue") && m.at("doubleValue").has_value()) return "doubleValue";
        if (m.count("stringValue") && m.at("stringValue").has_value()) return "stringValue";
        if (m.count("boolValue") && m.at("boolValue").has_value()) return "boolValue";
        if (m.count("bytesValue") && m.at("bytesValue").has_value()) return "bytesValue";
        if (m.count("listValue") && m.at("listValue").has_value()) return "listValue";
    }
    if (obj.type() == typeid(std::unordered_map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::unordered_map<std::string, std::any>&>(obj);
        if (m.count("intValue") && m.at("intValue").has_value()) return "intValue";
        if (m.count("doubleValue") && m.at("doubleValue").has_value()) return "doubleValue";
        if (m.count("stringValue") && m.at("stringValue").has_value()) return "stringValue";
        if (m.count("boolValue") && m.at("boolValue").has_value()) return "boolValue";
        if (m.count("bytesValue") && m.at("bytesValue").has_value()) return "bytesValue";
        if (m.count("listValue") && m.at("listValue").has_value()) return "listValue";
    }
    return "notSet";
}

inline std::string ball_which_kind(const std::any& obj) {
    if (!obj.has_value()) return "notSet";
    if (obj.type() == typeid(std::map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::map<std::string, std::any>&>(obj);
        if (m.count("nullValue") && m.at("nullValue").has_value()) return "nullValue";
        if (m.count("numberValue") && m.at("numberValue").has_value()) return "numberValue";
        if (m.count("stringValue") && m.at("stringValue").has_value()) return "stringValue";
        if (m.count("boolValue") && m.at("boolValue").has_value()) return "boolValue";
        if (m.count("structValue") && m.at("structValue").has_value()) return "structValue";
        if (m.count("listValue") && m.at("listValue").has_value()) return "listValue";
    }
    if (obj.type() == typeid(std::unordered_map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::unordered_map<std::string, std::any>&>(obj);
        if (m.count("nullValue") && m.at("nullValue").has_value()) return "nullValue";
        if (m.count("numberValue") && m.at("numberValue").has_value()) return "numberValue";
        if (m.count("stringValue") && m.at("stringValue").has_value()) return "stringValue";
        if (m.count("boolValue") && m.at("boolValue").has_value()) return "boolValue";
        if (m.count("structValue") && m.at("structValue").has_value()) return "structValue";
        if (m.count("listValue") && m.at("listValue").has_value()) return "listValue";
    }
    return "notSet";
}

inline std::string ball_which_source(const std::any& obj) {
    if (!obj.has_value()) return "notSet";
    if (obj.type() == typeid(std::map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::map<std::string, std::any>&>(obj);
        if (m.count("httpSource") && m.at("httpSource").has_value()) return "httpSource";
        if (m.count("fileSource") && m.at("fileSource").has_value()) return "fileSource";
        if (m.count("inlineSource") && m.at("inlineSource").has_value()) return "inlineSource";
        if (m.count("gitSource") && m.at("gitSource").has_value()) return "gitSource";
    }
    if (obj.type() == typeid(std::unordered_map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::unordered_map<std::string, std::any>&>(obj);
        if (m.count("httpSource") && m.at("httpSource").has_value()) return "httpSource";
        if (m.count("fileSource") && m.at("fileSource").has_value()) return "fileSource";
        if (m.count("inlineSource") && m.at("inlineSource").has_value()) return "inlineSource";
        if (m.count("gitSource") && m.at("gitSource").has_value()) return "gitSource";
    }
    return "notSet";
}

inline std::string ball_which_stmt(const std::any& obj) {
    if (!obj.has_value()) return "notSet";
    if (obj.type() == typeid(std::map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::map<std::string, std::any>&>(obj);
        if (m.count("let") && m.at("let").has_value()) return "let";
        if (m.count("expression") && m.at("expression").has_value()) return "expression";
    }
    if (obj.type() == typeid(std::unordered_map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::unordered_map<std::string, std::any>&>(obj);
        if (m.count("let") && m.at("let").has_value()) return "let";
        if (m.count("expression") && m.at("expression").has_value()) return "expression";
    }
    return "notSet";
}

// ── Collection helpers ──

// Convert any iterable-like value to a std::vector<std::any>.
template<typename T>
inline std::vector<std::any> ball_to_list(const std::vector<T>& v) {
    std::vector<std::any> result;
    result.reserve(v.size());
    for (const auto& el : v) result.push_back(std::any(el));
    return result;
}
inline std::vector<std::any> ball_to_list(const std::any& v) {
    if (v.type() == typeid(std::vector<std::any>))
        return std::any_cast<std::vector<std::any>>(v);
    if (v.type() == typeid(std::vector<std::string>)) {
        auto& sv = std::any_cast<const std::vector<std::string>&>(v);
        std::vector<std::any> r;
        for (auto& s : sv) r.push_back(std::any(s));
        return r;
    }
    return {};
}

// Remove duplicates (set-like).
template<typename T>
inline std::vector<T> ball_to_set(const std::vector<T>& v) {
    std::vector<T> result;
    for (const auto& el : v) {
        bool found = false;
        for (const auto& r : result) {
            // Simple equality for common types
            if constexpr (std::is_same_v<T, std::any>) {
                // For std::any, compare by string representation
                if (ball_to_string(el) == ball_to_string(r)) { found = true; break; }
            } else {
                if (el == r) { found = true; break; }
            }
        }
        if (!found) result.push_back(el);
    }
    return result;
}

// Filter elements.
template<typename T, typename F>
inline std::vector<T> ball_where(const std::vector<T>& v, F pred) {
    std::vector<T> result;
    for (const auto& el : v) {
        if (pred(el)) result.push_back(el);
    }
    return result;
}

// Transform elements.
template<typename T, typename F>
inline auto ball_map(const std::vector<T>& v, F fn) {
    using R = decltype(fn(std::declval<T>()));
    std::vector<R> result;
    result.reserve(v.size());
    for (const auto& el : v) result.push_back(fn(el));
    return result;
}

// Check if all elements satisfy a predicate.
template<typename T, typename F>
inline bool ball_every(const std::vector<T>& v, F pred) {
    for (const auto& el : v) {
        if (!pred(el)) return false;
    }
    return true;
}

// Append all elements from src to dst.
template<typename T>
inline void ball_add_all(std::vector<T>& dst, const std::vector<T>& src) {
    dst.insert(dst.end(), src.begin(), src.end());
}
// Overload for maps.
template<typename K, typename V>
inline void ball_add_all(std::map<K, V>& dst, const std::map<K, V>& src) {
    for (const auto& [k, v] : src) dst[k] = v;
}
template<typename K, typename V>
inline void ball_add_all(std::unordered_map<K, V>& dst, const std::unordered_map<K, V>& src) {
    for (const auto& [k, v] : src) dst[k] = v;
}

// Put a value in a map only if the key is absent.
template<typename M, typename K, typename F>
inline void ball_put_if_absent(M& m, const K& key, F factory) {
    if (m.count(key) == 0) m[key] = factory();
}

// Take first N elements.
template<typename T>
inline std::vector<T> ball_take(const std::vector<T>& v, int64_t n) {
    auto end = std::min(static_cast<size_t>(n), v.size());
    return std::vector<T>(v.begin(), v.begin() + end);
}

// Skip first N elements.
template<typename T>
inline std::vector<T> ball_skip(const std::vector<T>& v, int64_t n) {
    auto start = std::min(static_cast<size_t>(n), v.size());
    return std::vector<T>(v.begin() + start, v.end());
}

// Build a map from a list of key-value pairs.
inline std::map<std::string, std::any> ball_from_entries(const std::vector<std::any>& entries) {
    std::map<std::string, std::any> result;
    for (const auto& e : entries) {
        if (e.type() == typeid(std::map<std::string, std::any>)) {
            auto& m = std::any_cast<const std::map<std::string, std::any>&>(e);
            auto kit = m.find("key");
            auto vit = m.find("value");
            if (kit != m.end() && vit != m.end()) {
                result[std::any_cast<std::string>(kit->second)] = vit->second;
            }
        }
    }
    return result;
}

// ── Regex helpers ──

// Find first regex match — returns a std::any wrapping match data or empty.
inline std::any ball_first_match(const std::regex& re, const std::string& s) {
    std::smatch m;
    if (std::regex_search(s, m, re)) {
        std::vector<std::any> groups;
        for (size_t i = 0; i < m.size(); ++i) {
            groups.push_back(std::any(m[i].str()));
        }
        return std::any(groups);
    }
    return std::any{};
}

// Extract a capture group from a match result.
inline std::string ball_group(const std::any& match, int64_t idx) {
    if (!match.has_value()) return "";
    if (match.type() == typeid(std::vector<std::any>)) {
        auto& groups = std::any_cast<const std::vector<std::any>&>(match);
        if (idx >= 0 && static_cast<size_t>(idx) < groups.size()) {
            return std::any_cast<std::string>(groups[idx]);
        }
    }
    return "";
}

// Find all regex matches — returns a vector of match data.
inline std::vector<std::any> ball_all_matches(const std::regex& re, const std::string& s) {
    std::vector<std::any> results;
    auto it = std::sregex_iterator(s.begin(), s.end(), re);
    for (; it != std::sregex_iterator(); ++it) {
        std::vector<std::any> groups;
        for (size_t i = 0; i < it->size(); ++i) {
            groups.push_back(std::any((*it)[i].str()));
        }
        results.push_back(std::any(groups));
    }
    return results;
}

// ── Dart tryParse ──
// tryParse(type, str) — attempt to parse a string as int or double.
// Returns the parsed value on success, or std::any{} on failure.
inline std::any ball_try_parse(const std::any& type_tag, const std::string& s) {
    std::string tag;
    if (type_tag.type() == typeid(std::string))
        tag = std::any_cast<std::string>(type_tag);
    else
        tag = ball_to_string(type_tag);
    if (tag == "int" || tag == "int_") {
        try { return std::any(static_cast<int64_t>(std::stoll(s))); }
        catch (...) { return std::any{}; }
    }
    if (tag == "double" || tag == "double_" || tag == "num") {
        try { return std::any(std::stod(s)); }
        catch (...) { return std::any{}; }
    }
    return std::any{};
}

// ── Generic field-set helper ──
// Works for both BallDyn (uses .set()) and std::map<std::string, std::any>
// (uses operator[]=).
class BallDyn;  // forward
template<typename T>
inline void ball_set(T& obj, const std::string& key, const std::any& value) {
    obj[key] = value;
}
// BallDyn specialization uses the .set() method
// (defined after BallDyn class definition, see ball_dyn.h)
template<typename T>
inline void ball_set(T& obj, int64_t idx, const std::any& value) {
    obj[idx] = value;
}

// ── BallDyn overload for ball_to_string ──
// (forward declared; BallDyn must be defined before this is used)
// Placed here so it's available in both engine and compiled programs.
class BallDyn;
inline std::string ball_to_string(const BallDyn& d);
// Implemented after BallDyn is defined — see ball_dyn.h or the
// generated preamble where both headers are spliced in sequence.

// ================================================================
// Self-hosted engine compatibility stubs
// ================================================================
//
// The self-hosted Ball engine (compiled from Dart → Ball → C++)
// references Dart-specific types and functions that don't exist in
// C++. These stubs provide minimal implementations so the generated
// code compiles. They are only used by the self-hosted engine, not
// by normal compiled Ball programs.

// ── JSON encode/decode stubs ──
// Dart's `JsonEncoder` / `JsonDecoder` classes with a `convert()`
// method. In compiled C++ we stub them to do basic
// ball_to_string / passthrough.
struct JsonEncoder {
    bool __const__ = false;
};
struct JsonDecoder {
    bool __const__ = false;
};
inline std::string convert(const JsonEncoder&, const std::any& value) {
    return ball_to_string(value);
}
inline std::any convert(const JsonDecoder&, const std::string& text) {
    // Minimal JSON decode: try to parse as number, bool, null, or return as string.
    if (text == "null") return std::any{};
    if (text == "true") return std::any(true);
    if (text == "false") return std::any(false);
    try { return std::any(static_cast<int64_t>(std::stoll(text))); } catch (...) {}
    try { return std::any(std::stod(text)); } catch (...) {}
    // Strip surrounding quotes if present
    if (text.size() >= 2 && text.front() == '"' && text.back() == '"')
        return std::any(text.substr(1, text.size() - 2));
    return std::any(text);
}

// ── utf8 / base64 codec stubs ──
// Dart uses `utf8.encode(s)` / `utf8.decode(bytes)` and
// `base64.encode(bytes)` / `base64.decode(s)`.
struct Utf8Codec {
    std::vector<std::any> encode(const std::string& s) const {
        std::vector<std::any> result;
        for (unsigned char c : s) result.push_back(std::any(static_cast<int64_t>(c)));
        return result;
    }
    std::string decode(const std::vector<std::any>& bytes) const {
        std::string result;
        for (const auto& b : bytes) {
            if (b.type() == typeid(int64_t))
                result += static_cast<char>(std::any_cast<int64_t>(b));
        }
        return result;
    }
};
inline std::vector<std::any> encode(const Utf8Codec& c, const std::string& s) { return c.encode(s); }
inline std::string decode(const Utf8Codec& c, const std::vector<std::any>& b) { return c.decode(b); }

struct Base64Codec {
    std::string encode(const std::vector<std::any>& bytes) const {
        static const char* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::vector<uint8_t> raw;
        for (const auto& b : bytes) {
            if (b.type() == typeid(int64_t)) raw.push_back(static_cast<uint8_t>(std::any_cast<int64_t>(b)));
        }
        std::string o;
        size_t i = 0;
        for (; i + 3 <= raw.size(); i += 3) {
            o += alphabet[(raw[i] >> 2) & 0x3f];
            o += alphabet[((raw[i] & 0x3) << 4) | ((raw[i+1] >> 4) & 0xf)];
            o += alphabet[((raw[i+1] & 0xf) << 2) | ((raw[i+2] >> 6) & 0x3)];
            o += alphabet[raw[i+2] & 0x3f];
        }
        if (i < raw.size()) {
            o += alphabet[(raw[i] >> 2) & 0x3f];
            if (i + 1 == raw.size()) {
                o += alphabet[(raw[i] & 0x3) << 4]; o += "==";
            } else {
                o += alphabet[((raw[i] & 0x3) << 4) | ((raw[i+1] >> 4) & 0xf)];
                o += alphabet[(raw[i+1] & 0xf) << 2]; o += '=';
            }
        }
        return o;
    }
    std::vector<std::any> decode(const std::string& s) const {
        static int tbl[256] = {};
        static bool inited = false;
        if (!inited) {
            for (int j = 0; j < 256; j++) tbl[j] = -1;
            const char* a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            for (int j = 0; j < 64; j++) tbl[(unsigned char)a[j]] = j;
            inited = true;
        }
        std::vector<std::any> o;
        int v = 0, bits = 0;
        for (char c : s) {
            if (c == '=' || c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
            int d = tbl[(unsigned char)c]; if (d < 0) continue;
            v = (v << 6) | d; bits += 6;
            if (bits >= 8) { bits -= 8; o.push_back(std::any(static_cast<int64_t>((v >> bits) & 0xff))); }
        }
        return o;
    }
};
inline std::string encode(const Base64Codec& c, const std::vector<std::any>& b) { return c.encode(b); }
inline std::vector<std::any> decode(const Base64Codec& c, const std::string& s) { return c.decode(s); }

// Global instances matching Dart's top-level `utf8` and `base64`.
inline Utf8Codec utf8;
inline Base64Codec base64;

// ── Function type stub ──
// Dart code references `Function` as a type. In C++ it doesn't exist
// as a standalone identifier. `apply(Function, callee, args)` in the
// self-hosted engine wraps a dynamic function call.
struct FunctionType {};
inline FunctionType Function;
inline std::any apply(const FunctionType&, const std::any& callee, const std::vector<std::any>& args) {
    // Attempt to call the callee as a BallFunc with the first argument (or null).
    if (callee.type() == typeid(std::function<std::any(std::any)>)) {
        auto& fn = std::any_cast<const std::function<std::any(std::any)>&>(callee);
        return fn(args.empty() ? std::any{} : args[0]);
    }
    return std::any{};
}

// ── Map.from stub ──
// Dart `Map.from(otherMap)` creates a copy. The encoder emits it as
// `Map_from{.__type_args__=..., .arg0=input}` — a struct constructor.
// We provide a minimal struct that extracts the map from the input.
struct Map_from {
    std::string __type_args__;
    std::any arg0;

    // Forward map-like operations to the underlying value
    int64_t size() const {
        if (arg0.type() == typeid(std::map<std::string, std::any>))
            return std::any_cast<const std::map<std::string, std::any>&>(arg0).size();
        if (arg0.type() == typeid(std::unordered_map<std::string, std::any>))
            return std::any_cast<const std::unordered_map<std::string, std::any>&>(arg0).size();
        return 0;
    }
    bool empty() const { return size() == 0; }
    std::any operator[](const std::string& key) const {
        if (arg0.type() == typeid(std::map<std::string, std::any>)) {
            auto& m = std::any_cast<const std::map<std::string, std::any>&>(arg0);
            auto it = m.find(key); return it != m.end() ? it->second : std::any{};
        }
        if (arg0.type() == typeid(std::unordered_map<std::string, std::any>)) {
            auto& m = std::any_cast<const std::unordered_map<std::string, std::any>&>(arg0);
            auto it = m.find(key); return it != m.end() ? it->second : std::any{};
        }
        return std::any{};
    }
};

// ── io.FileMode stub ──
// Dart's `FileMode.append` etc. The self-hosted engine references
// `io_FileMode["append"]`. Provide as a map.
inline std::map<std::string, std::any> io_FileMode = {
    {"append", std::any(std::string("append"))},
    {"write", std::any(std::string("write"))},
    {"read", std::any(std::string("read"))},
};

// ── File I/O stubs ──
// The self-hosted engine calls `File(path)`, `readAsStringSync(file)`,
// `writeAsStringSync(file, content)`, etc. Provide stubs.
struct File {
    std::string path;
    File(const std::string& p) : path(p) {}
    File(const std::any& p) : path(ball_to_string(p)) {}
};
inline std::string readAsStringSync(const File& f) {
    std::ifstream ifs(f.path);
    return std::string((std::istreambuf_iterator<char>(ifs)),
                        std::istreambuf_iterator<char>());
}
inline void writeAsStringSync(const File& f, const std::string& content, const std::any& = {}) {
    std::ofstream ofs(f.path);
    ofs << content;
}
inline void writeAsStringSync(const File& f, const std::any& content, const std::any& = {}) {
    std::ofstream ofs(f.path);
    ofs << ball_to_string(content);
}
inline void writeAsBytesSync(const File& f, const std::any&) {
    // Stub — byte write not fully implemented
}
inline bool existsSync(const File& f) {
    std::ifstream ifs(f.path);
    return ifs.good();
}
inline void deleteSync(const File& f) {
    std::remove(f.path.c_str());
}

// ── Scope/bind/child stubs ──
// The self-hosted engine uses `child(scope)`, `bind(scope, name, value)`,
// `resolve(scope, name)` for scope chain management. These are methods
// on the BallEngine class, but sometimes the compiler emits them as
// free function calls. We provide free-function overloads.
inline std::any child(const std::any& scope) {
    // Create a new scope with the parent set
    std::map<std::string, std::any> newScope;
    newScope["__parent__"] = scope;
    return std::any(newScope);
}
inline void bind(std::any& scope, const std::any& name, const std::any& value) {
    if (scope.type() == typeid(std::map<std::string, std::any>)) {
        std::any_cast<std::map<std::string, std::any>&>(scope)[ball_to_string(name)] = value;
    }
}
// Forward declaration; BallDyn defined later
class BallDyn;
// Overloads for BallDyn arguments — defined after BallDyn class
inline std::any resolve(const std::any& scope, const std::string& name) {
    if (scope.type() == typeid(std::map<std::string, std::any>)) {
        auto& m = std::any_cast<const std::map<std::string, std::any>&>(scope);
        auto it = m.find(name);
        if (it != m.end()) return it->second;
        auto pit = m.find("__parent__");
        if (pit != m.end()) return resolve(pit->second, name);
    }
    return std::any{};
}
// Overload for BallDyn resolver + import
inline std::any resolve(const std::any&, const std::any&) {
    return std::any{};  // Stub: lazy module resolution not supported in compiled mode
}

// ── Scope exit stubs ──
// The Ball IR for _runScopeExits has a bug where it references `expr` and
// `evalScope` which are not defined. Declare dummies so the code compiles.
// The actual scope exit evaluation won't work correctly but the engine
// will compile without errors.
inline std::any expr;
inline std::any evalScope;

// ── has_value / empty free functions ──
// Some generated code calls .has_value() or .empty() on std::string,
// which doesn't have has_value(). Provide free-function overloads.
// (These are found by ADL only if needed)

// ── toUtc stub ──
// Dart's DateTime.now().toUtc() — returns the same map (already UTC in C++)
inline std::map<std::string, std::any> toUtc(const std::map<std::string, std::any>& dt) {
    return dt;
}
inline std::any toUtc(const std::any& dt) {
    if (dt.type() == typeid(std::map<std::string, std::any>))
        return dt;
    return std::any{};
}

// ── Object type stub ──
// Dart uses `Object` as a base type. Emit as a string.
inline std::string Object = "Object";

// ── Math function aliases ──
// The sanitize_name function appends _ to stdlib collision names,
// so user code references sqrt_, pow_, etc. These wrap the real functions.
inline double sqrt_(double v) { return std::sqrt(v); }
inline double pow_(double a, double b) { return std::pow(a, b); }
inline double log_(double v) { return std::log(v); }
inline double exp_(double v) { return std::exp(v); }
inline double sin_(double v) { return std::sin(v); }
inline double cos_(double v) { return std::cos(v); }
inline double tan_(double v) { return std::tan(v); }
inline double atan_(double v) { return std::atan(v); }
inline double atan2_(double a, double b) { return std::atan2(a, b); }
// BallDyn overloads for math
inline double sqrt_(const std::any& v) { return std::sqrt(v.type() == typeid(double) ? std::any_cast<double>(v) : static_cast<double>(std::any_cast<int64_t>(v))); }
inline double pow_(const std::any& a, const std::any& b) {
    double da = a.type() == typeid(double) ? std::any_cast<double>(a) : static_cast<double>(std::any_cast<int64_t>(a));
    double db = b.type() == typeid(double) ? std::any_cast<double>(b) : static_cast<double>(std::any_cast<int64_t>(b));
    return std::pow(da, db);
}
inline double log_(const std::any& v) { return log_(v.type() == typeid(double) ? std::any_cast<double>(v) : static_cast<double>(std::any_cast<int64_t>(v))); }
inline double exp_(const std::any& v) { return exp_(v.type() == typeid(double) ? std::any_cast<double>(v) : static_cast<double>(std::any_cast<int64_t>(v))); }
inline double sin_(const std::any& v) { return sin_(v.type() == typeid(double) ? std::any_cast<double>(v) : static_cast<double>(std::any_cast<int64_t>(v))); }
inline double cos_(const std::any& v) { return cos_(v.type() == typeid(double) ? std::any_cast<double>(v) : static_cast<double>(std::any_cast<int64_t>(v))); }
inline double tan_(const std::any& v) { return tan_(v.type() == typeid(double) ? std::any_cast<double>(v) : static_cast<double>(std::any_cast<int64_t>(v))); }
inline double atan_(const std::any& v) { return atan_(v.type() == typeid(double) ? std::any_cast<double>(v) : static_cast<double>(std::any_cast<int64_t>(v))); }
inline double atan2_(const std::any& a, const std::any& b) {
    double da = a.type() == typeid(double) ? std::any_cast<double>(a) : static_cast<double>(std::any_cast<int64_t>(a));
    double db = b.type() == typeid(double) ? std::any_cast<double>(b) : static_cast<double>(std::any_cast<int64_t>(b));
    return std::atan2(da, db);
}

// ── handles/call: defined in ball_dyn.h after BallDyn class ──
// Forward declarations only (no stubs — BallDyn overloads are the only implementations)
class BallDyn; // forward declare
inline bool handles(const BallDyn& handler, const BallDyn& module);
template<typename E>
inline BallDyn call(const BallDyn& handler, const BallDyn& function, const BallDyn& input, E&& engine_fn);

// ── Dart async/time/math stubs ──
// Future.delayed — just sleep synchronously
struct DurationType { int64_t milliseconds = 0; };
using Duration = DurationType;
struct FutureType {};
inline FutureType Future;
inline std::any delayed(const FutureType&, const DurationType& d) {
    std::this_thread::sleep_for(std::chrono::milliseconds(d.milliseconds));
    return std::any{};
}

// DateTime.now() — returns a map with millisecondsSinceEpoch
struct DateTimeType {};
inline DateTimeType DateTime;
inline std::map<std::string, std::any> now(const DateTimeType&) {
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    return {{"millisecondsSinceEpoch", std::any(static_cast<int64_t>(ms))}};
}

// Random — simple wrappers around C++ random
struct RandomType {
    mutable std::mt19937_64 gen{std::random_device{}()};
};
inline int64_t nextInt(const RandomType& r, int64_t max_) {
    return std::uniform_int_distribution<int64_t>(0, max_ - 1)(r.gen);
}
// Overload for BallDyn max
inline int64_t nextInt(const RandomType& r, const std::any& max_val) {
    int64_t mx = 100;
    if (max_val.type() == typeid(int64_t)) mx = std::any_cast<int64_t>(max_val);
    return nextInt(r, mx);
}
inline double nextDouble(const RandomType& r) {
    return std::uniform_real_distribution<double>(0.0, 1.0)(r.gen);
}

// stderr_ — print to stderr (name collision avoidance with C macro)
inline void stderr_(const std::string& msg) {
    std::cerr << msg << std::endl;
}
inline void stderr_(const std::any& msg) {
    std::cerr << ball_to_string(msg) << std::endl;
}

// _envGet stub — wraps std::getenv
inline std::string _envGet(const std::string& name) {
    auto v = std::getenv(name.c_str());
    return v ? std::string(v) : std::string();
}
inline std::string _envGet(const std::any& name) {
    return _envGet(ball_to_string(name));
}

#endif  // BALL_EMIT_RUNTIME_H
