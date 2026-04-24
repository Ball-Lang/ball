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

// std::any — attempt known types, fallback to type name.
inline std::string ball_to_string(const std::any& v) {
    if (!v.has_value()) return "null";
    if (v.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(v));
    if (v.type() == typeid(int)) return std::to_string(std::any_cast<int>(v));
    if (v.type() == typeid(double)) return ball_to_string(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return ball_to_string(std::any_cast<bool>(v));
    if (v.type() == typeid(std::string)) return std::any_cast<std::string>(v);
    if (v.type() == typeid(const char*)) return std::any_cast<const char*>(v);
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

#endif  // BALL_EMIT_RUNTIME_H
