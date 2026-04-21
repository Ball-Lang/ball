#pragma once

// ball_runtime.h — Single-header C++ runtime compatibility layer for
// compiled Ball programs (Ball → C++ via the Dart compiler).
//
// Provides Dart-like APIs as free functions so the emitted C++ can compile
// with minimal modifications. Targets C++20.
//
// Namespace: ball::runtime (with a `using namespace ball::runtime;` at bottom
// for convenient inclusion in emitted code).

#ifndef BALL_RUNTIME_H
#define BALL_RUNTIME_H

// Suppress MSVC warnings for getenv (we use it for Platform.environment)
#ifdef _MSC_VER
#pragma warning(push)
#pragma warning(disable: 4996)
#endif

#include <algorithm>
#include <any>
#include <cassert>
#include <chrono>
#include <cmath>
#include <thread>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <map>
#include <random>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <variant>
#include <vector>

// ================================================================
// std::any comparison operators
// ================================================================
// The Ball C++ compiler emits `val != std::any{}` for null checks (Dart: val != null).
// std::any has no built-in comparison operators, so we provide them.
// `std::any{}` (empty) is treated as null; any non-empty any is "not null".
// Comparing two non-empty any values: only true if same address (identity).

inline bool operator==(const std::any& a, const std::any& b) {
    // Both empty → equal (both null)
    if (!a.has_value() && !b.has_value()) return true;
    // One empty, one not → not equal
    if (!a.has_value() || !b.has_value()) return false;
    // Both have values: compare as strings if both are strings
    if (a.type() == typeid(std::string) && b.type() == typeid(std::string))
        return std::any_cast<std::string>(a) == std::any_cast<std::string>(b);
    if (a.type() == typeid(int64_t) && b.type() == typeid(int64_t))
        return std::any_cast<int64_t>(a) == std::any_cast<int64_t>(b);
    if (a.type() == typeid(double) && b.type() == typeid(double))
        return std::any_cast<double>(a) == std::any_cast<double>(b);
    if (a.type() == typeid(bool) && b.type() == typeid(bool))
        return std::any_cast<bool>(a) == std::any_cast<bool>(b);
    // Numeric cross-type
    if (a.type() == typeid(int64_t) && b.type() == typeid(double))
        return static_cast<double>(std::any_cast<int64_t>(a)) == std::any_cast<double>(b);
    if (a.type() == typeid(double) && b.type() == typeid(int64_t))
        return std::any_cast<double>(a) == static_cast<double>(std::any_cast<int64_t>(b));
    // Fallback: different types or non-comparable → not equal
    return false;
}

inline bool operator!=(const std::any& a, const std::any& b) {
    return !(a == b);
}

// Comparison with specific types (emitted code uses `val == true`, `val == "str"s`, etc.)
inline bool operator==(const std::any& a, bool b) {
    if (!a.has_value()) return false;
    if (a.type() == typeid(bool)) return std::any_cast<bool>(a) == b;
    return false;
}
inline bool operator!=(const std::any& a, bool b) { return !(a == b); }
inline bool operator==(bool b, const std::any& a) { return a == b; }
inline bool operator!=(bool b, const std::any& a) { return !(a == b); }

inline bool operator==(const std::any& a, const std::string& b) {
    if (!a.has_value()) return false;
    if (a.type() == typeid(std::string)) return std::any_cast<std::string>(a) == b;
    return false;
}
inline bool operator!=(const std::any& a, const std::string& b) { return !(a == b); }
inline bool operator==(const std::string& b, const std::any& a) { return a == b; }
inline bool operator!=(const std::string& b, const std::any& a) { return !(a == b); }

inline bool operator==(const std::any& a, const char* b) {
    return a == std::string(b);
}
inline bool operator!=(const std::any& a, const char* b) { return !(a == b); }

inline bool operator==(const std::any& a, int64_t b) {
    if (!a.has_value()) return false;
    if (a.type() == typeid(int64_t)) return std::any_cast<int64_t>(a) == b;
    if (a.type() == typeid(double)) return std::any_cast<double>(a) == static_cast<double>(b);
    return false;
}
inline bool operator!=(const std::any& a, int64_t b) { return !(a == b); }
inline bool operator==(int64_t b, const std::any& a) { return a == b; }
inline bool operator!=(int64_t b, const std::any& a) { return !(a == b); }

// Ternary/bool conversion: `if (val)` means `val != null && val != false`
inline bool operator!(const std::any& a) {
    if (!a.has_value()) return true;
    if (a.type() == typeid(bool)) return !std::any_cast<bool>(a);
    return false;
}

// Implicit bool conversion for `std::any` in conditions
// (The emitted code uses patterns like `if (value) { ... }`)
// This is achieved via the ! operator above; !! gives truthiness.

namespace ball { namespace runtime {

// ================================================================
// Type Aliases
// ================================================================

/// Dart: dynamic / Object? — runtime polymorphic value
using BallValue = std::any;

/// Dart: List<dynamic>
using BallList = std::vector<BallValue>;

/// Dart: Map<String, dynamic> (ordered for deterministic iteration)
using BallMap = std::map<std::string, BallValue>;

/// Dart: Function(dynamic) -> dynamic
using BallFunction = std::function<BallValue(BallValue)>;

/// Dart: (module, function, input) -> result — callable for base dispatch
using BallCallable = std::function<BallValue(
    const std::string&, const std::string&, BallValue)>;

/// Dart: FutureOr<T> — synchronous simulation (no event loop)
template<typename T>
using FutureOr = T;

/// Dart: Set<T>
template<typename T>
using Set = std::set<T>;

/// Dart: String typedef for readability in emitted code
using String = std::string;

// ================================================================
// Exception Base Class
// ================================================================

/// Dart: Exception — base class for all exceptions
class Exception : public std::runtime_error {
public:
    Exception() : std::runtime_error("Exception") {}
    explicit Exception(const std::string& msg) : std::runtime_error(msg) {}
    virtual std::string toString() const { return what(); }
};

// ================================================================
// BallFuture / BallGenerator (sync simulation)
// ================================================================

/// Dart: Future<T> — synchronous wrapper
struct BallFuture {
    BallValue value;
    bool completed = true;
};

/// Dart: sync* generator — accumulates yielded values
struct BallGenerator {
    BallList values;
    bool completed = false;

    void yield_(BallValue v) { values.push_back(std::move(v)); }
    void yieldAll(const BallList& items) {
        values.insert(values.end(), items.begin(), items.end());
    }
};

// ================================================================
// Sentinel value for "not found" returns
// ================================================================

struct _SentinelType {};
inline const _SentinelType _sentinel_instance{};

/// Unique sentinel object (Dart: Object())
inline BallValue make_sentinel() {
    return BallValue(std::in_place_type<_SentinelType>);
}

// Simple Object type alias for `const auto _sentinel = Object{};`
struct Object {};

// ================================================================
// String Polyfills (free functions matching emitted call patterns)
// ================================================================

/// Dart: s.isEmpty
inline bool isEmpty(const std::string& s) { return s.empty(); }

/// Dart: s.isNotEmpty
inline bool isNotEmpty(const std::string& s) { return !s.empty(); }

/// Dart: s.contains(sub)
inline bool contains(const std::string& s, const std::string& sub) {
    return s.find(sub) != std::string::npos;
}

/// Dart: s.startsWith(prefix)
inline bool startsWith(const std::string& s, const std::string& prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

/// Dart: s.endsWith(suffix)
inline bool endsWith(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() &&
           s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

/// Dart: s.substring(start) or s.substring(start, end)
inline std::string substring(const std::string& s, int64_t start) {
    if (start < 0) start = 0;
    if (start >= static_cast<int64_t>(s.size())) return "";
    return s.substr(static_cast<size_t>(start));
}

inline std::string substring(const std::string& s, int64_t start, int64_t end) {
    if (start < 0) start = 0;
    if (end < start) return "";
    if (end > static_cast<int64_t>(s.size())) end = static_cast<int64_t>(s.size());
    return s.substr(static_cast<size_t>(start), static_cast<size_t>(end - start));
}

/// Dart: s.split(delimiter)
inline std::vector<std::string> split(const std::string& s, const std::string& delim) {
    std::vector<std::string> result;
    if (delim.empty()) {
        for (char c : s) result.push_back(std::string(1, c));
        return result;
    }
    size_t pos = 0, found;
    while ((found = s.find(delim, pos)) != std::string::npos) {
        result.push_back(s.substr(pos, found - pos));
        pos = found + delim.size();
    }
    result.push_back(s.substr(pos));
    return result;
}

/// Dart: s.trim()
inline std::string trim(const std::string& s) {
    auto a = s.find_first_not_of(" \t\n\r");
    auto b = s.find_last_not_of(" \t\n\r");
    return a == std::string::npos ? std::string() : s.substr(a, b - a + 1);
}

/// Dart: s.trimLeft()
inline std::string trimLeft(const std::string& s) {
    auto a = s.find_first_not_of(" \t\n\r");
    return a == std::string::npos ? std::string() : s.substr(a);
}

/// Dart: s.trimRight()
inline std::string trimRight(const std::string& s) {
    auto b = s.find_last_not_of(" \t\n\r");
    return b == std::string::npos ? std::string() : s.substr(0, b + 1);
}

/// Dart: s.toUpperCase()
inline std::string toUpperCase(const std::string& s) {
    std::string r = s;
    std::transform(r.begin(), r.end(), r.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return r;
}

/// Dart: s.toLowerCase()
inline std::string toLowerCase(const std::string& s) {
    std::string r = s;
    std::transform(r.begin(), r.end(), r.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return r;
}

/// Dart: s.replaceAll(from, to)
inline std::string replaceAll(const std::string& s, const std::string& from, const std::string& to) {
    if (from.empty()) return s;
    std::string result = s;
    size_t pos = 0;
    while ((pos = result.find(from, pos)) != std::string::npos) {
        result.replace(pos, from.size(), to);
        pos += to.size();
    }
    return result;
}

/// Dart: s.replaceFirst(from, to)
inline std::string replaceFirst(const std::string& s, const std::string& from, const std::string& to) {
    auto pos = s.find(from);
    if (pos == std::string::npos) return s;
    std::string result = s;
    result.replace(pos, from.size(), to);
    return result;
}

/// Dart: s.codeUnitAt(index)
inline int64_t codeUnitAt(const std::string& s, int64_t index) {
    if (index < 0 || index >= static_cast<int64_t>(s.size())) return 0;
    return static_cast<int64_t>(static_cast<unsigned char>(s[static_cast<size_t>(index)]));
}

/// Dart: s.compareTo(other)
inline int64_t compareTo(const std::string& a, const std::string& b) {
    int r = a.compare(b);
    return r < 0 ? -1 : (r > 0 ? 1 : 0);
}

/// Dart: s.indexOf(sub) / s.indexOf(sub, start)
inline int64_t indexOf(const std::string& s, const std::string& sub, int64_t start = 0) {
    if (start < 0) start = 0;
    auto pos = s.find(sub, static_cast<size_t>(start));
    return pos == std::string::npos ? -1 : static_cast<int64_t>(pos);
}

/// Dart: s.lastIndexOf(sub)
inline int64_t lastIndexOf(const std::string& s, const std::string& sub) {
    auto pos = s.rfind(sub);
    return pos == std::string::npos ? -1 : static_cast<int64_t>(pos);
}

/// Dart: s.padLeft(width, padding)
inline std::string padLeft(const std::string& s, int64_t width, const std::string& padding = " ") {
    if (static_cast<int64_t>(s.size()) >= width) return s;
    std::string result;
    while (static_cast<int64_t>(result.size() + s.size()) < width) {
        result += padding;
    }
    result = result.substr(0, static_cast<size_t>(width - static_cast<int64_t>(s.size())));
    return result + s;
}

/// Dart: s.padRight(width, padding)
inline std::string padRight(const std::string& s, int64_t width, const std::string& padding = " ") {
    if (static_cast<int64_t>(s.size()) >= width) return s;
    std::string result = s;
    while (static_cast<int64_t>(result.size()) < width) {
        result += padding;
    }
    return result.substr(0, static_cast<size_t>(width));
}

/// Dart: s.length (as a function since emitted code calls it)
inline int64_t length(const std::string& s) { return static_cast<int64_t>(s.size()); }

// ================================================================
// Map Polyfills (free functions operating on BallMap / unordered_map)
// ================================================================

/// Dart: map.containsKey(key)
template<typename M>
inline bool containsKey(const M& m, const std::string& key) {
    return m.find(key) != m.end();
}

/// Dart: map.putIfAbsent(key, ifAbsent)
template<typename M, typename F>
inline auto putIfAbsent(M& m, const std::string& key, F ifAbsent) -> decltype(m[key]) {
    auto it = m.find(key);
    if (it == m.end()) {
        m[key] = ifAbsent();
    }
    return m[key];
}

/// Dart: map.remove(key) — for maps
template<typename M>
inline void remove(M& m, const std::string& key) {
    m.erase(key);
}

/// Dart: map.addAll(other)
template<typename M>
inline void addAll(M& dest, const M& src) {
    for (const auto& [k, v] : src) {
        dest[k] = v;
    }
}

/// Dart: map.keys (as a vector of strings)
template<typename M>
inline std::vector<std::string> keys(const M& m) {
    std::vector<std::string> result;
    result.reserve(m.size());
    for (const auto& [k, v] : m) {
        result.push_back(k);
    }
    return result;
}

/// Dart: map.values (as a vector of BallValue)
template<typename M>
inline BallList values(const M& m) {
    BallList result;
    result.reserve(m.size());
    for (const auto& [k, v] : m) {
        result.push_back(v);
    }
    return result;
}

/// Helper struct for map entry iteration (Dart: MapEntry)
struct MapEntry {
    std::string key;
    BallValue value;
};

/// Dart: map.entries (as iterable of MapEntry)
template<typename M>
inline std::vector<MapEntry> entries(const M& m) {
    std::vector<MapEntry> result;
    result.reserve(m.size());
    for (const auto& [k, v] : m) {
        result.push_back(MapEntry{k, v});
    }
    return result;
}

/// Property-style .entries access for maps — enables `for (auto& entry : m.entries)` pattern
/// Since C++ maps don't have .entries, the emitted code uses the free function above.
/// But for the `full.entries` pattern we provide this wrapper:
template<typename M>
struct EntriesView {
    const M& map_ref;
    auto begin() const { return map_ref.begin(); }
    auto end() const { return map_ref.end(); }
};

// ================================================================
// List/Vector Polyfills
// ================================================================

/// Dart: list.add(element)
template<typename T>
inline void add(std::vector<T>& v, T elem) {
    v.push_back(std::move(elem));
}

/// Overload for BallValue containers (avoids template deduction issues)
inline void add(BallList& v, BallValue elem) {
    v.push_back(std::move(elem));
}

/// Dart: list.addAll(other)
template<typename T>
inline void addAll(std::vector<T>& dest, const std::vector<T>& src) {
    dest.insert(dest.end(), src.begin(), src.end());
}

/// Dart: list.removeLast()
template<typename T>
inline T removeLast(std::vector<T>& v) {
    if (v.empty()) throw Exception("removeLast on empty list");
    T last = std::move(v.back());
    v.pop_back();
    return last;
}

/// Dart: list.contains(element) — for vectors
template<typename T, typename U>
inline bool contains(const std::vector<T>& v, const U& elem) {
    return std::find(v.begin(), v.end(), elem) != v.end();
}

/// Dart: set.contains(element)
template<typename T, typename U>
inline bool contains(const std::set<T>& s, const U& elem) {
    return s.find(elem) != s.end();
}

/// Dart: set.add(element)
template<typename T>
inline void add(std::set<T>& s, const T& elem) {
    s.insert(elem);
}

/// Dart: set.remove(element)
template<typename T>
inline void remove(std::set<T>& s, const T& elem) {
    s.erase(elem);
}

/// Dart: set.toList()
template<typename T>
inline std::vector<T> toList(const std::set<T>& s) {
    return std::vector<T>(s.begin(), s.end());
}

/// Dart: iterable.toList() — identity for vectors
template<typename T>
inline std::vector<T> toList(const std::vector<T>& v) {
    return v;
}

/// Dart: iterable.toList() — move overload
template<typename T>
inline std::vector<T> toList(std::vector<T>&& v) {
    return std::move(v);
}

/// Dart: iterable.toSet()
template<typename T>
inline std::set<T> toSet(const std::vector<T>& v) {
    return std::set<T>(v.begin(), v.end());
}

/// Dart: list.where(predicate)
template<typename T, typename Pred>
inline std::vector<T> where(const std::vector<T>& v, Pred pred) {
    std::vector<T> result;
    for (const auto& elem : v) {
        if (pred(elem)) result.push_back(elem);
    }
    return result;
}

/// Dart: list.map(transform)
template<typename T, typename Fn>
inline auto map(const std::vector<T>& v, Fn fn) -> std::vector<decltype(fn(v[0]))> {
    using R = decltype(fn(v[0]));
    std::vector<R> result;
    result.reserve(v.size());
    for (const auto& elem : v) {
        result.push_back(fn(elem));
    }
    return result;
}

/// Dart: list.fold(init, combine)
template<typename T, typename R, typename Fn>
inline R fold(const std::vector<T>& v, R init, Fn combine) {
    R acc = std::move(init);
    for (const auto& elem : v) {
        acc = combine(acc, elem);
    }
    return acc;
}

/// Dart: list.join(separator)
template<typename T>
inline std::string join(const std::vector<T>& v, const std::string& sep = "") {
    std::ostringstream oss;
    bool first = true;
    for (const auto& elem : v) {
        if (!first) oss << sep;
        oss << elem;
        first = false;
    }
    return oss.str();
}

/// Specialization for BallValue join (uses ball_to_string)
inline std::string join(const BallList& v, const std::string& sep = "") {
    std::ostringstream oss;
    bool first = true;
    for (const auto& elem : v) {
        if (!first) oss << sep;
        if (elem.type() == typeid(std::string)) {
            oss << std::any_cast<std::string>(elem);
        } else if (elem.type() == typeid(int64_t)) {
            oss << std::any_cast<int64_t>(elem);
        } else if (elem.type() == typeid(double)) {
            oss << std::any_cast<double>(elem);
        } else if (elem.type() == typeid(bool)) {
            oss << (std::any_cast<bool>(elem) ? "true" : "false");
        } else {
            oss << "<value>";
        }
        first = false;
    }
    return oss.str();
}

/// Dart: list.first
template<typename T>
inline T& first(std::vector<T>& v) {
    return v.front();
}

/// Dart: list.last
template<typename T>
inline T& last(std::vector<T>& v) {
    return v.back();
}

/// Dart: list.reversed (returns a reversed copy)
template<typename T>
inline std::vector<T> reversed(const std::vector<T>& v) {
    return std::vector<T>(v.rbegin(), v.rend());
}

/// Dart: list.isEmpty
template<typename T>
inline bool isEmpty(const std::vector<T>& v) { return v.empty(); }

/// Dart: list.isNotEmpty
template<typename T>
inline bool isNotEmpty(const std::vector<T>& v) { return !v.empty(); }

/// Dart: list.length (free function)
template<typename T>
inline int64_t length(const std::vector<T>& v) { return static_cast<int64_t>(v.size()); }

/// Dart: Map.length
template<typename M>
inline int64_t length(const M& m) requires requires { m.size(); typename M::mapped_type; } {
    return static_cast<int64_t>(m.size());
}

// ================================================================
// unmodifiable — Dart: UnmodifiableMapView / UnmodifiableListView
// (In C++ we just return a copy; there's no runtime immutability enforcement)
// ================================================================

template<typename T>
inline T unmodifiable(T v) { return v; }

/// Two-arg form: unmodifiable(Map, val) or unmodifiable(Set, val)
struct _MapTag {};
struct _SetTag {};
inline constexpr _MapTag Map{};
// Note: 'Set' is already a template alias above, use _SetTag for the tag
inline constexpr _SetTag SetTag{};

template<typename T>
inline T unmodifiable(_MapTag, T v) { return v; }

template<typename T>
inline T unmodifiable(_SetTag, T v) { return v; }

// ================================================================
// Regex
// ================================================================

/// Dart: RegExp(pattern)
struct RegExp {
    std::string pattern;
    std::regex compiled;
    RegExp() = default;
    explicit RegExp(const std::string& p) : pattern(p) {
        try {
            compiled = std::regex(p);
        } catch (...) {}
    }
    // Support aggregate-init style from emitted code: RegExp{.arg0 = "pattern"}
    // (handled via constructor below)
};

/// Dart: RegExp(pattern).firstMatch(input)
struct RegExpMatch {
    std::smatch match;
    std::string group(int n) const {
        if (n < 0 || n >= static_cast<int>(match.size())) return "";
        return match[n].str();
    }
    operator bool() const { return !match.empty(); }
};

/// Dart: firstMatch(regexp, input) or regexp.firstMatch(input)
inline BallValue firstMatch(const std::string& pattern, const std::string& input) {
    try {
        std::regex re(pattern);
        std::smatch m;
        if (std::regex_search(input, m, re)) {
            // Return as a BallMap with group indices
            BallMap result;
            for (size_t i = 0; i < m.size(); i++) {
                result[std::to_string(i)] = BallValue(m[i].str());
            }
            return result;
        }
    } catch (...) {}
    return BallValue{};
}

/// Overload taking a RegExp struct
inline BallValue firstMatch(const RegExp& re, const std::string& input) {
    return firstMatch(re.pattern, input);
}

// ================================================================
// Numeric parsing
// ================================================================

/// Dart: int.tryParse(s) — returns the number or BallValue{} (null)
inline BallValue tryParse_int(const std::string& s) {
    try {
        size_t pos;
        int64_t v = std::stoll(s, &pos);
        if (pos == s.size()) return BallValue(v);
    } catch (...) {}
    return BallValue{};
}

/// Dart: double.tryParse(s)
inline BallValue tryParse_double(const std::string& s) {
    try {
        size_t pos;
        double v = std::stod(s, &pos);
        if (pos == s.size()) return BallValue(v);
    } catch (...) {}
    return BallValue{};
}

/// Dart: num.tryParse(s) — try int first, then double
struct _NumTag {};
inline constexpr _NumTag num{};

inline BallValue tryParse(_NumTag, const std::string& s) {
    auto v = tryParse_int(s);
    if (v.has_value()) return v;
    return tryParse_double(s);
}

/// Dart: int.parse(s)
inline int64_t parseInt(const std::string& s) {
    return std::stoll(s);
}

/// Dart: double.parse(s)
inline double parseDouble(const std::string& s) {
    return std::stod(s);
}

/// Dart: .toDouble()
inline double toDouble(auto v) { return static_cast<double>(v); }

/// Dart: .toInt()
inline int64_t toInt(auto v) { return static_cast<int64_t>(v); }

// ================================================================
// dart:math
// ================================================================

inline constexpr double pi = 3.14159265358979323846;
inline constexpr double e = 2.71828182845904523536;

/// Dart: sqrt — using sqrt_ to avoid collision with std::sqrt
inline double sqrt_(double v) { return std::sqrt(v); }

/// Dart: pow
inline double pow_(double a, double b) { return std::pow(a, b); }

/// Dart: log
inline double log_(double v) { return std::log(v); }

/// Dart: exp
inline double exp_(double v) { return std::exp(v); }

/// Dart: sin
inline double sin_(double v) { return std::sin(v); }

/// Dart: cos
inline double cos_(double v) { return std::cos(v); }

/// Dart: tan
inline double tan_(double v) { return std::tan(v); }

/// Dart: atan
inline double atan_(double v) { return std::atan(v); }

/// Dart: atan2
inline double atan2_(double a, double b) { return std::atan2(a, b); }

/// Dart: min
template<typename T>
inline T min(T a, T b) { return a < b ? a : b; }

/// Dart: max
template<typename T>
inline T max(T a, T b) { return a > b ? a : b; }

/// Dart: Random class
class Random {
    std::mt19937_64 _engine;
public:
    Random() : _engine(std::random_device{}()) {}
    explicit Random(int64_t seed) : _engine(static_cast<uint64_t>(seed)) {}

    /// Dart: Random().nextInt(max)
    int64_t nextInt(int64_t max) {
        std::uniform_int_distribution<int64_t> dist(0, max - 1);
        return dist(_engine);
    }

    /// Dart: Random().nextDouble()
    double nextDouble() {
        std::uniform_real_distribution<double> dist(0.0, 1.0);
        return dist(_engine);
    }

    /// Dart: Random().nextBool()
    bool nextBool() {
        return nextInt(2) == 1;
    }
};

// ================================================================
// dart:io stubs
// ================================================================

/// Dart: print(value) — prints to stdout with newline
inline void print(const std::string& s) {
    std::cout << s << "\n";
}

inline void print(const BallValue& v) {
    if (v.type() == typeid(std::string)) {
        std::cout << std::any_cast<std::string>(v) << "\n";
    } else if (v.type() == typeid(int64_t)) {
        std::cout << std::any_cast<int64_t>(v) << "\n";
    } else if (v.type() == typeid(double)) {
        std::cout << std::any_cast<double>(v) << "\n";
    } else if (v.type() == typeid(bool)) {
        std::cout << (std::any_cast<bool>(v) ? "true" : "false") << "\n";
    } else if (!v.has_value()) {
        std::cout << "null\n";
    } else {
        std::cout << "<object>\n";
    }
}

/// Dart: stderr — provide a writeln method
struct _Stderr {
    void writeln(const std::string& s) { std::cerr << s << "\n"; }
    void write(const std::string& s) { std::cerr << s; }
};
inline _Stderr stderr_stream;

/// Dart: stdout
struct _Stdout {
    void writeln(const std::string& s) { std::cout << s << "\n"; }
    void write(const std::string& s) { std::cout << s; }
};
inline _Stdout stdout_stream;

/// Dart: Platform.environment
struct _Platform {
    std::string operator[](const std::string& key) const {
        const char* val = std::getenv(key.c_str());
        return val ? std::string(val) : std::string();
    }
    bool containsKey(const std::string& key) const {
        return std::getenv(key.c_str()) != nullptr;
    }
    // Make it accessible as Platform.environment[key]
    struct _Environment {
        std::string operator[](const std::string& key) const {
            const char* val = std::getenv(key.c_str());
            return val ? std::string(val) : std::string();
        }
        bool containsKey(const std::string& key) const {
            return std::getenv(key.c_str()) != nullptr;
        }
    };
    _Environment environment;
};
inline _Platform Platform;

/// Dart: exit(code)
[[noreturn]] inline void exit(int code) {
    std::exit(code);
}

// ================================================================
// dart:io File operations
// ================================================================

/// Dart: File(path)
struct File {
    std::string path;
    explicit File(const std::string& p) : path(p) {}
    File(const BallValue& v) : path(v.type() == typeid(std::string) ? std::any_cast<std::string>(v) : "") {}
};

/// Dart: File(path).readAsStringSync()
inline std::string readAsStringSync(const File& f) {
    std::ifstream ifs(f.path);
    if (!ifs) throw Exception("Cannot read file: " + f.path);
    return std::string((std::istreambuf_iterator<char>(ifs)),
                        std::istreambuf_iterator<char>());
}

/// Dart: File(path).readAsBytesSync()
inline std::vector<uint8_t> readAsBytesSync(const File& f) {
    std::ifstream ifs(f.path, std::ios::binary);
    if (!ifs) throw Exception("Cannot read file: " + f.path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(ifs)),
                                 std::istreambuf_iterator<char>());
}

/// Dart: File(path).writeAsStringSync(content)
enum class io_FileMode { write, append };

inline void writeAsStringSync(const File& f, const std::string& content, io_FileMode mode = io_FileMode::write) {
    auto flags = (mode == io_FileMode::append) ? (std::ios::out | std::ios::app) : std::ios::out;
    std::ofstream ofs(f.path, flags);
    if (!ofs) throw Exception("Cannot write file: " + f.path);
    ofs << content;
}

/// Dart: File(path).writeAsBytesSync(bytes)
inline void writeAsBytesSync(const File& f, const std::vector<uint8_t>& bytes) {
    std::ofstream ofs(f.path, std::ios::binary);
    if (!ofs) throw Exception("Cannot write file: " + f.path);
    ofs.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}

/// Overload for BallList bytes
inline void writeAsBytesSync(const File& f, const BallList& bytes) {
    std::ofstream ofs(f.path, std::ios::binary);
    if (!ofs) throw Exception("Cannot write file: " + f.path);
    for (const auto& b : bytes) {
        if (b.type() == typeid(int64_t)) {
            char c = static_cast<char>(std::any_cast<int64_t>(b));
            ofs.write(&c, 1);
        }
    }
}

/// Dart: File(path).existsSync()
inline bool existsSync(const File& f) {
    return std::filesystem::exists(f.path);
}

/// Dart: File(path).deleteSync()
inline void deleteSync(const File& f) {
    std::filesystem::remove(f.path);
}

/// Dart: Directory(path)
struct Directory {
    std::string path;
    explicit Directory(const std::string& p) : path(p) {}
    Directory(const BallValue& v) : path(v.type() == typeid(std::string) ? std::any_cast<std::string>(v) : "") {}
};

/// Dart: Directory(path).listSync()
struct _DirEntry {
    std::string path;
};

inline std::vector<_DirEntry> listSync(const Directory& d) {
    std::vector<_DirEntry> result;
    try {
        for (const auto& entry : std::filesystem::directory_iterator(d.path)) {
            result.push_back(_DirEntry{entry.path().string()});
        }
    } catch (...) {}
    return result;
}

/// Dart: Directory(path).createSync(recursive)
inline void createSync(const Directory& d, bool recursive = false) {
    if (recursive) {
        std::filesystem::create_directories(d.path);
    } else {
        std::filesystem::create_directory(d.path);
    }
}

/// Dart: Directory(path).existsSync()
inline bool existsSync(const Directory& d) {
    return std::filesystem::exists(d.path) && std::filesystem::is_directory(d.path);
}

// ================================================================
// dart:convert stubs
// ================================================================

/// Dart: jsonDecode(string) — minimal JSON parser (returns BallMap or BallList)
/// For a production version, integrate nlohmann/json. This is a stub.
struct _JsonDecoder {
    bool __const__ = false;
};
inline constexpr _JsonDecoder JsonDecoder{};

/// Dart: convert(codec, data) — stub that returns the string as-is for json
inline BallValue convert(const _JsonDecoder&, const std::string& text) {
    // Minimal stub: returns the raw string. Real impl needs nlohmann/json.
    return BallValue(text);
}

/// Dart: jsonEncode(value)
inline std::string jsonEncode(const BallValue& v) {
    if (v.type() == typeid(std::string)) return "\"" + std::any_cast<std::string>(v) + "\"";
    if (v.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(v));
    if (v.type() == typeid(double)) return std::to_string(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v) ? "true" : "false";
    if (!v.has_value()) return "null";
    return "{}";
}

/// Dart: utf8 codec
struct _Utf8Codec {};
inline constexpr _Utf8Codec utf8{};

inline std::vector<uint8_t> encode(const _Utf8Codec&, const std::string& s) {
    return std::vector<uint8_t>(s.begin(), s.end());
}

inline std::string decode(const _Utf8Codec&, const std::vector<uint8_t>& bytes) {
    return std::string(bytes.begin(), bytes.end());
}

inline std::string decode(const _Utf8Codec&, const BallList& bytes) {
    std::string result;
    for (const auto& b : bytes) {
        if (b.type() == typeid(int64_t)) {
            result += static_cast<char>(std::any_cast<int64_t>(b));
        }
    }
    return result;
}

/// Dart: base64 codec
struct _Base64Codec {};
inline constexpr _Base64Codec base64{};

// Minimal base64 encode
inline std::string encode(const _Base64Codec&, const std::vector<uint8_t>& bytes) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    int i = 0, n = static_cast<int>(bytes.size());
    while (i < n) {
        uint32_t a = bytes[i++];
        uint32_t b = (i < n) ? bytes[i++] : 0;
        uint32_t c = (i < n) ? bytes[i++] : 0;
        uint32_t triple = (a << 16) | (b << 8) | c;
        result += table[(triple >> 18) & 0x3F];
        result += table[(triple >> 12) & 0x3F];
        result += (i - 2 < n) ? table[(triple >> 6) & 0x3F] : '=';
        result += (i - 1 < n) ? table[triple & 0x3F] : '=';
    }
    return result;
}

inline std::string encode(const _Base64Codec&, const BallList& bytes) {
    std::vector<uint8_t> raw;
    for (const auto& b : bytes) {
        if (b.type() == typeid(int64_t)) raw.push_back(static_cast<uint8_t>(std::any_cast<int64_t>(b)));
    }
    return encode(_Base64Codec{}, raw);
}

// Minimal base64 decode
inline std::vector<uint8_t> decode(const _Base64Codec&, const std::string& s) {
    static const int lookup[256] = {
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
        -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
        -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
        -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
    };
    std::vector<uint8_t> result;
    uint32_t buf = 0;
    int bits = 0;
    for (char c : s) {
        if (c == '=' || c == '\n' || c == '\r') continue;
        int val = lookup[static_cast<unsigned char>(c)];
        if (val < 0) continue;
        buf = (buf << 6) | val;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            result.push_back(static_cast<uint8_t>((buf >> bits) & 0xFF));
        }
    }
    return result;
}

// ================================================================
// Protobuf struct helpers (for the emitted engine code that accesses
// protobuf Value/Struct fields directly)
// ================================================================

/// Dart: value.hasStringValue — check if a protobuf Value has a string
inline bool hasStringValue(const BallValue& v) {
    return v.has_value() && v.type() == typeid(std::string);
}

/// Dart: hasMetadata, hasBody, hasCall, hasInput, hasDescriptor, hasResult
/// These are proto "has" checks — in the emitted code they're called on
/// arbitrary objects. We stub them to check for non-empty/non-null fields.
template<typename T>
inline bool hasMetadata(const T&) { return false; }

template<typename T>
inline bool hasBody(const T&) { return false; }

template<typename T>
inline bool hasCall(const T&) { return false; }

template<typename T>
inline bool hasInput(const T&) { return false; }

template<typename T>
inline bool hasDescriptor(const T&) { return false; }

template<typename T>
inline bool hasResult(const T&) { return false; }

/// For BallMap-based objects, check if key exists
inline bool hasMetadata(const BallMap& m) { return m.find("metadata") != m.end(); }
inline bool hasBody(const BallMap& m) { return m.find("body") != m.end(); }
inline bool hasCall(const BallMap& m) { return m.find("call") != m.end(); }
inline bool hasInput(const BallMap& m) { return m.find("input") != m.end(); }
inline bool hasDescriptor(const BallMap& m) { return m.find("descriptor") != m.end(); }
inline bool hasResult(const BallMap& m) { return m.find("result") != m.end(); }

// ================================================================
// whichKind / whichExpr / whichStmt / whichSource — enum dispatch
// ================================================================

/// Stub enum tags for protobuf oneof dispatching
struct structpb_Value_Kind_t {
    static constexpr int listValue = 1;
    static constexpr int structValue = 2;
    static constexpr int stringValue = 3;
    static constexpr int numberValue = 4;
    static constexpr int boolValue = 5;
    static constexpr int nullValue = 6;
};
inline constexpr structpb_Value_Kind_t structpb_Value_Kind{};

struct Expression_Expr_t {
    static constexpr int call = 1;
    static constexpr int literal = 2;
    static constexpr int reference = 3;
    static constexpr int fieldAccess = 4;
    static constexpr int messageCreation = 5;
    static constexpr int block = 6;
    static constexpr int lambda = 7;
    static constexpr int notSet = 0;
};
inline constexpr Expression_Expr_t Expression_Expr{};

struct ModuleImport_Source_t {
    static constexpr int notSet = 0;
    static constexpr int uri = 1;
    static constexpr int inline_ = 2;
};
inline constexpr ModuleImport_Source_t ModuleImport_Source{};

/// Generic dispatch stubs — the emitted code calls these but the real
/// implementation needs the actual protobuf message types
template<typename T>
inline int whichKind(const T&) { return 0; }

template<typename T>
inline int whichExpr(const T&) { return 0; }

template<typename T>
inline int whichStmt(const T&) { return 0; }

template<typename T>
inline int whichSource(const T&) { return 0; }

// ================================================================
// Scope helper — child()
// ================================================================

/// Dart: scope.child() — used as free function in some emitted patterns
template<typename T>
inline T child(const T& scope) {
    // This is a placeholder; the actual emitted _Scope class has its own child()
    return T{};
}

/// Dart: scope.bind(name, value) — free function form
template<typename Scope>
inline void bind(Scope& scope, const std::string& name, BallValue value) {
    scope.bind(name, std::move(value));
}

/// Dart: scope.lookup(name) — free function form
template<typename Scope>
inline BallValue lookup(Scope& scope, const std::string& name) {
    return scope.lookup(name);
}

/// Dart: scope.has(name) — free function form
template<typename Scope>
inline bool has(Scope& scope, const std::string& name) {
    return scope.has(name);
}

// ================================================================
// __no_init__ — placeholder for uninitialized variables
// ================================================================
inline BallValue __no_init__;

// ================================================================
// Dart: DateTime
// ================================================================

struct DateTime {
    static int64_t now_millisecondsSinceEpoch() {
        auto now = std::chrono::system_clock::now();
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
    }
};

// ================================================================
// Dart: Stopwatch
// ================================================================

class Stopwatch {
    std::chrono::steady_clock::time_point _start;
    std::chrono::steady_clock::time_point _stop;
    bool _running = false;
    int64_t _elapsed_us = 0;
public:
    void start() {
        _start = std::chrono::steady_clock::now();
        _running = true;
    }
    void stop() {
        if (_running) {
            _stop = std::chrono::steady_clock::now();
            _elapsed_us += std::chrono::duration_cast<std::chrono::microseconds>(_stop - _start).count();
            _running = false;
        }
    }
    void reset() { _elapsed_us = 0; _running = false; }
    int64_t elapsedMilliseconds() const {
        auto total = _elapsed_us;
        if (_running) {
            total += std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - _start).count();
        }
        return total / 1000;
    }
    int64_t elapsedMicroseconds() const {
        auto total = _elapsed_us;
        if (_running) {
            total += std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - _start).count();
        }
        return total;
    }
};

// ================================================================
// Sleep
// ================================================================

/// Dart: sleep(Duration(milliseconds: ms))
inline void sleep_ms(int64_t ms) {
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// ================================================================
// Type checking / casting helpers
// ================================================================

/// Dart: value is Type — returns true if BallValue holds the given type
inline bool is_string(const BallValue& v) { return v.type() == typeid(std::string); }
inline bool is_int(const BallValue& v) { return v.type() == typeid(int64_t); }
inline bool is_double(const BallValue& v) { return v.type() == typeid(double); }
inline bool is_bool(const BallValue& v) { return v.type() == typeid(bool); }
inline bool is_null(const BallValue& v) { return !v.has_value(); }
inline bool is_list(const BallValue& v) { return v.type() == typeid(BallList); }
inline bool is_map(const BallValue& v) { return v.type() == typeid(BallMap); }
inline bool is_function(const BallValue& v) { return v.type() == typeid(BallFunction); }

// ================================================================
// BallValue extraction
// ================================================================

inline std::string as_string(const BallValue& v) {
    if (v.type() == typeid(std::string)) return std::any_cast<std::string>(v);
    return "";
}

inline int64_t as_int(const BallValue& v) {
    if (v.type() == typeid(int64_t)) return std::any_cast<int64_t>(v);
    if (v.type() == typeid(double)) return static_cast<int64_t>(std::any_cast<double>(v));
    return 0;
}

inline double as_double(const BallValue& v) {
    if (v.type() == typeid(double)) return std::any_cast<double>(v);
    if (v.type() == typeid(int64_t)) return static_cast<double>(std::any_cast<int64_t>(v));
    return 0.0;
}

inline bool as_bool(const BallValue& v) {
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v);
    return false;
}

}} // namespace ball::runtime

// Pull everything into global namespace for emitted code convenience
using namespace ball::runtime;

#ifdef _MSC_VER
#pragma warning(pop)
#endif

#endif // BALL_RUNTIME_H
