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

// std_time format/parse helpers below need C time + formatted I/O.
// The compiler's emit_includes does not bring these in, and they are not
// reliably pulled in elsewhere, so include them here. This header has an
// include guard, so double-inclusion (engine path + spliced-program path)
// is harmless.
#include <ctime>
#include <cstdio>
#include <cstring>
// num.toStringAsExponential()/toStringAsPrecision() byte-exact formatting
// (below) needs C string→number parsing and the shortest-round-trip
// std::to_chars float overload.
#include <cstdlib>
#include <charconv>
// std_fs directory ops (Directory listSync/createSync/existsSync below) do
// real filesystem work via std::filesystem. emit_includes() does not emit
// <filesystem>, and it is not reliably pulled in transitively, so include it
// here (the include guard makes double-inclusion harmless).
#include <filesystem>

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
    // Arbitrary thrown payload (the engine's `BallException(typeName, value)`),
    // preserved so a catch handler can read the real thrown value — not just
    // the stringified message. has_payload distinguishes "no payload" from a
    // payload that happens to be a null/empty value.
    std::any value;
    bool has_payload = false;
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
    if (d == 0.0 && std::signbit(d)) return "-0.0";
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

// ── num.toStringAsExponential / num.toStringAsPrecision (byte-exact Dart) ──
// Dart's (and ECMAScript's) exponential/precision formatting differs from
// C++'s `std::scientific`/`std::setprecision` in three ways that MUST match
// for the self-hosted engine to stay byte-identical with the Dart reference
// (issue #100): a *minimal* exponent (`1.23e+2`, not `1.23e+02`), significant
// digits padded with trailing zeros (`1.0.toStringAsPrecision(3)` → `1.00`,
// which `std::defaultfloat` drops), and round-half-AWAY-from-zero on an exact
// tie (`2.5.toStringAsExponential(0)` → `3e+0`, where C++'s IEEE ties-to-even
// gives `2e+0`). We reproduce all three by extracting the value's EXACT decimal
// digits and rounding the digit string ourselves.

// Round the exact significant digits of `ax` (finite, > 0) to `k` significant
// digits using round-half-away-from-zero, returning the k-digit string.
// `*E` receives the decimal exponent of the leading digit (value =
// D[0].D[1..] × 10^E); a rounding carry (9.99 → 10) bumps it.
//
// snprintf("%.1080e") yields 1081 significant digits — more than the 767 a
// double's exact decimal expansion can ever need — so the printed digits are
// EXACT (trailing zeros, never a rounding artifact). Because the discarded tail
// is therefore exact, "away from zero on a tie" reduces to the simple test
// `D[k] >= '5'` (any exact-half rounds up, matching Dart).
inline std::string ball_round_sig_digits(double ax, int k, int* E) {
    char buf[1200];
    std::snprintf(buf, sizeof(buf), "%.*e", 1080, ax);
    std::string s(buf);
    std::size_t epos = s.find('e');
    int exp = std::atoi(s.c_str() + epos + 1);
    std::string digits;
    digits.push_back(s[0]);
    for (std::size_t i = 2; i < epos; ++i) digits.push_back(s[i]);
    if (static_cast<int>(digits.size()) <= k) {
        digits.append(static_cast<std::size_t>(k) - digits.size(), '0');
        *E = exp;
        return digits;
    }
    const bool round_up = digits[static_cast<std::size_t>(k)] >= '5';
    std::string kept = digits.substr(0, static_cast<std::size_t>(k));
    if (round_up) {
        int i = k - 1;
        for (; i >= 0; --i) {
            if (kept[static_cast<std::size_t>(i)] != '9') { kept[static_cast<std::size_t>(i)]++; break; }
            kept[static_cast<std::size_t>(i)] = '0';
        }
        if (i < 0) { kept = "1" + kept.substr(0, static_cast<std::size_t>(k) - 1); exp += 1; }
    }
    *E = exp;
    return kept;
}

// num.toStringAsExponential(fractionDigits) — `d` fixed fraction digits.
inline std::string ball_to_string_as_exponential(double x, int64_t d) {
    if (std::isnan(x)) return "NaN";
    if (std::isinf(x)) return x < 0 ? "-Infinity" : "Infinity";
    const bool neg = std::signbit(x);
    std::string out;
    if (x == 0.0) {
        out = "0";
        if (d > 0) { out += "."; out.append(static_cast<std::size_t>(d), '0'); }
        out += "e+0";
    } else {
        int E;
        const std::string m = ball_round_sig_digits(std::fabs(x), static_cast<int>(d) + 1, &E);
        out = m.substr(0, 1);
        if (d > 0) { out += "."; out += m.substr(1); }
        out += "e";
        out += (E < 0) ? "-" : "+";
        out += std::to_string(E < 0 ? -E : E);
    }
    return neg ? "-" + out : out;
}

// num.toStringAsExponential() — no fractionDigits: shortest round-trip mantissa
// (Dart uses the minimal digits that uniquely identify the value; std::to_chars
// with chars_format::scientific produces exactly that).
inline std::string ball_to_string_as_exponential(double x) {
    if (std::isnan(x)) return "NaN";
    if (std::isinf(x)) return x < 0 ? "-Infinity" : "Infinity";
    const bool neg = std::signbit(x);
    char buf[64];
    auto res = std::to_chars(buf, buf + sizeof(buf), std::fabs(x), std::chars_format::scientific);
    std::string s(buf, res.ptr);
    const std::size_t epos = s.find('e');
    const std::string mant = s.substr(0, epos);
    const char sign = s[epos + 1];          // '+' or '-'
    const int exp = std::atoi(s.c_str() + epos + 2);
    std::string out = mant + "e" + sign + std::to_string(exp);
    return neg ? "-" + out : out;
}

// num.toStringAsPrecision(precision) — `p` significant digits, choosing fixed
// vs exponential form by ECMAScript's rule (exponent < -6 or >= p ⇒ exponential).
inline std::string ball_to_string_as_precision(double x, int64_t p) {
    if (std::isnan(x)) return "NaN";
    if (std::isinf(x)) return x < 0 ? "-Infinity" : "Infinity";
    const bool neg = std::signbit(x);
    std::string out;
    if (x == 0.0) {
        out = "0";
        if (p > 1) { out += "."; out.append(static_cast<std::size_t>(p) - 1, '0'); }
    } else {
        int E;
        const std::string m = ball_round_sig_digits(std::fabs(x), static_cast<int>(p), &E);
        if (E < -6 || E >= static_cast<int>(p)) {
            out = m.substr(0, 1);
            if (p > 1) { out += "."; out += m.substr(1); }
            out += "e";
            out += (E < 0) ? "-" : "+";
            out += std::to_string(E < 0 ? -E : E);
        } else if (E >= 0) {
            const int intd = E + 1;
            out = m.substr(0, static_cast<std::size_t>(intd));
            if (static_cast<int>(p) > intd) { out += "."; out += m.substr(static_cast<std::size_t>(intd)); }
        } else {
            out = "0.";
            out.append(static_cast<std::size_t>(-E - 1), '0');
            out += m;
        }
    }
    return neg ? "-" + out : out;
}

// ── UTF-16 string semantics (Dart parity) ──
// Dart strings are sequences of UTF-16 code units: `.length`, `s[i]`, and
// `substring(a, b)` index by code unit, NOT by byte. Compiled programs store
// strings as UTF-8 std::string, so length/substring must convert. ASCII strings
// (1 byte == 1 code unit) hit a fast path: when every byte is < 0x80 these are
// no-ops. A BMP char (e.g. CJK 你) is 3 UTF-8 bytes == 1 UTF-16 unit; an astral
// char (e.g. emoji 😀) is 4 UTF-8 bytes == 2 UTF-16 units (a surrogate pair).

// Number of UTF-16 code units in a UTF-8 string.
inline int64_t ball_u16_length(const std::string& s) {
    int64_t units = 0;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x80) { i += 1; units += 1; }
        else if ((c >> 5) == 0x6) { i += 2; units += 1; }
        else if ((c >> 4) == 0xE) { i += 3; units += 1; }
        else if ((c >> 3) == 0x1E) { i += 4; units += 2; }  // astral -> surrogate pair
        else { i += 1; units += 1; }  // invalid byte: treat as 1
    }
    return units;
}

// Map a UTF-16 code-unit index to a byte offset in the UTF-8 string. An index
// that lands in the middle of a surrogate pair (astral char) clamps to the start
// of that char's bytes. An index past the end returns s.size().
inline size_t ball_u16_to_byte(const std::string& s, int64_t u16idx) {
    if (u16idx <= 0) return 0;
    int64_t units = 0;
    for (size_t i = 0; i < s.size();) {
        if (units >= u16idx) return i;
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x80) { i += 1; units += 1; }
        else if ((c >> 5) == 0x6) { i += 2; units += 1; }
        else if ((c >> 4) == 0xE) { i += 3; units += 1; }
        else if ((c >> 3) == 0x1E) { i += 4; units += 2; }
        else { i += 1; units += 1; }
    }
    return s.size();
}

// Dart `s.substring(start[, end])` indexed by UTF-16 code units, returning UTF-8.
// end < 0 means "to end of string".
inline std::string ball_u16_substring(const std::string& s, int64_t start, int64_t end) {
    size_t bstart = ball_u16_to_byte(s, start);
    size_t bend = (end < 0) ? s.size() : ball_u16_to_byte(s, end);
    if (bend < bstart) bend = bstart;
    return s.substr(bstart, bend - bstart);
}

// Dart `s.codeUnitAt(i)` — the UTF-16 code unit at index i. For an astral char
// this returns the high surrogate at its first index and the low surrogate at
// the next; we compute the full code point then derive the surrogate.
inline int64_t ball_u16_code_unit_at(const std::string& s, int64_t u16idx) {
    int64_t units = 0;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        int64_t cp; int adv; int nunits;
        if (c < 0x80) { cp = c; adv = 1; nunits = 1; }
        else if ((c >> 5) == 0x6 && i + 1 < s.size()) {
            cp = ((c & 0x1F) << 6) | (static_cast<unsigned char>(s[i+1]) & 0x3F); adv = 2; nunits = 1;
        } else if ((c >> 4) == 0xE && i + 2 < s.size()) {
            cp = ((c & 0x0F) << 12) | ((static_cast<unsigned char>(s[i+1]) & 0x3F) << 6) |
                 (static_cast<unsigned char>(s[i+2]) & 0x3F); adv = 3; nunits = 1;
        } else if ((c >> 3) == 0x1E && i + 3 < s.size()) {
            cp = ((c & 0x07) << 18) | ((static_cast<unsigned char>(s[i+1]) & 0x3F) << 12) |
                 ((static_cast<unsigned char>(s[i+2]) & 0x3F) << 6) |
                 (static_cast<unsigned char>(s[i+3]) & 0x3F); adv = 4; nunits = 2;
        } else { cp = c; adv = 1; nunits = 1; }
        if (nunits == 1) {
            if (units == u16idx) return cp;
        } else {
            // Astral: high surrogate at `units`, low surrogate at `units+1`.
            int64_t v = cp - 0x10000;
            if (units == u16idx) return 0xD800 + (v >> 10);
            if (units + 1 == u16idx) return 0xDC00 + (v & 0x3FF);
        }
        units += nunits;
        i += adv;
    }
    return 0;
}

// Dart double.toInt()/truncate() with int64 clamping (matches cpp/engine).
inline int64_t ball_double_to_int64(double d) {
    constexpr double kMaxD = 9223372036854775808.0;
    constexpr double kMinD = -9223372036854775808.0;
    if (d >= kMaxD) return static_cast<int64_t>(9223372036854775807LL);
    if (d <= kMinD) return (std::numeric_limits<int64_t>::min)();
    int64_t r = static_cast<int64_t>(d);
    if (d > 0.0 && r < 0) return static_cast<int64_t>(9223372036854775807LL);
    return r;
}

// ── Dart double property helpers (isNaN, isInfinite, isFinite, isNegative) ──
// These accept double/int64_t directly. BallDyn overloads are in ball_dyn.h.
inline bool ball_isNaN(double d) { return d != d; }
inline bool ball_isInfinite(double d) { return !ball_isNaN(d) && (d > 1e308 || d < -1e308); }
inline bool ball_isFinite(double d) { return !ball_isNaN(d) && !ball_isInfinite(d); }
inline bool ball_isNegative(double d) { return std::signbit(d) != 0; }
// int overloads (Dart: int is never NaN/Infinite)
inline bool ball_isNaN(int64_t) { return false; }
inline bool ball_isInfinite(int64_t) { return false; }
inline bool ball_isFinite(int64_t) { return true; }
inline bool ball_isNegative(int64_t v) { return v < 0; }

// Forward declare for vector recursion before the template catch-all.
template<typename T> inline std::string ball_to_string(const std::vector<T>& v);

template<typename T> inline std::string ball_to_string(T v) { return std::to_string(v); }

// Type aliases needed by ball_to_string(const std::any&) below.
using BallValue_RT = std::any;
using BallMap_RT = std::map<std::string, std::any>;
using BallList_RT = std::vector<std::any>;
using BallFunc_RT = std::function<std::any(std::any)>;

// Dart StringBuffer: a growable text buffer. shared_ptr-backed so that
// `..write(a)..write(b)` cascades and writes through aliases accumulate into
// the same string (reference semantics, like Dart). Defined before
// ball_to_string so the stringify path can read it. (conformance 140/150)
struct BallStringBuffer {
    std::shared_ptr<std::string> buf = std::make_shared<std::string>();
    BallStringBuffer() = default;
    explicit BallStringBuffer(const std::string& initial)
        : buf(std::make_shared<std::string>(initial)) {}
    // Catch-all for types with operator std::string() (like BallDyn). Uses
    // SFINAE to only participate when T is convertible to std::string but is
    // NOT std::string itself (to avoid ambiguity with the overload above).
    template<typename T, std::enable_if_t<
        std::is_convertible_v<T, std::string> &&
        !std::is_same_v<std::decay_t<T>, std::string> &&
        !std::is_same_v<std::decay_t<T>, const char*> &&
        !std::is_same_v<std::decay_t<T>, BallStringBuffer>, int> = 0>
    explicit BallStringBuffer(const T& v)
        : buf(std::make_shared<std::string>(static_cast<std::string>(v))) {}
};

// Helper to unwrap the inner std::any from a BallDyn stored in std::any.
// On MSVC, implicit conversion of BallDyn to const std::any& may use
// std::any's template constructor, wrapping the BallDyn object in std::any
// instead of extracting BallDyn::_val. This helper detects and unwraps.
struct _BallDynUnwrapper {
    // Unwrap a BallDyn stored inside std::any (MSVC's BallDyn-in-any quirk).
    // RECURSIVE: a value can be wrapped more than once
    // (std::any(BallDyn(std::any(BallDyn(x))))) when a BallDyn is round-tripped
    // through std::any multiple times (e.g. bind -> scope -> lookup -> field
    // access). A single unwrap would leave a still-BallDyn-typed value, so every
    // typeid check downstream would miss and unguarded any_casts would throw
    // bad_any_cast. Peel every BallDyn layer until the real underlying value.
    static const std::any& unwrap(const std::any& v) {
        const std::any* cur = &v;
        while (cur->has_value() && _unwrap_fn) {
            auto* result = _unwrap_fn(*cur);
            if (!result) break;
            cur = result;
        }
        return *cur;
    }
    using UnwrapFn = const std::any* (*)(const std::any&);
    static inline UnwrapFn _unwrap_fn = nullptr;
};

// Coerce a predicate result (filter/where/any/all callbacks) to bool WITHOUT
// throwing. The compiled filter lambdas previously did
// `std::any_cast<bool>(std::any(fn(e)))`, which throws bad_any_cast whenever the
// predicate returns a non-bool (a BallDyn wrapping a bool, an int, etc.) — a
// recurring MSVC BallDyn-in-any hazard. This unwraps and accepts bool / int /
// double / non-empty truthiness, returning false for empty/unknown.
inline bool _ball_pred_true(const std::any& raw) {
    const std::any& v = _BallDynUnwrapper::unwrap(raw);
    if (!v.has_value()) return false;
    if (v.type() == typeid(bool)) return std::any_cast<bool>(v);
    if (v.type() == typeid(int64_t)) return std::any_cast<int64_t>(v) != 0;
    if (v.type() == typeid(int)) return std::any_cast<int>(v) != 0;
    if (v.type() == typeid(double)) return std::any_cast<double>(v) != 0.0;
    return true;  // non-null, non-numeric → truthy (matches Dart-ish coercion)
}


// Reference-semantic program lists are stored shared_ptr-backed (BallListRef)
// inside BallDyn. That handle type is declared only in ball_dyn.h (compiled
// programs), NOT in the native engine, so this header cannot name it. It instead
// consults a registered function pointer (populated by ball_dyn.h) that maps a
// std::any holding a handle to a pointer to the underlying std::vector. In the
// native engine the pointer stays null and every call is a no-op, so native
// behavior is identical. Returns nullptr when `v` is not a list handle.
struct _BallRefDeref {
    using ListFn = const std::vector<std::any>* (*)(const std::any&);
    static inline ListFn _list_fn = nullptr;
    static const std::vector<std::any>* list(const std::any& v) {
        return _list_fn ? _list_fn(v) : nullptr;
    }
    // Reference-semantic OOP instances. A BallObjectRef (shared_ptr<BallObject>)
    // lets every holder of a copied BallDyn observe in-place field mutations
    // (e.g. a setter writing `self._celsius`). The deref function maps a std::any
    // holding a BallObjectRef handle to its underlying field map (the BallObject's
    // base BallMap, refreshed with __type__/__super__). Registered by ball_dyn.h;
    // null and a no-op in the native engine.
    using ObjMapFn = const std::map<std::string, std::any>* (*)(const std::any&);
    static inline ObjMapFn _obj_map_fn = nullptr;
    static const std::map<std::string, std::any>* obj_map(const std::any& v) {
        return _obj_map_fn ? _obj_map_fn(v) : nullptr;
    }
    // Portable ordered-set backing list (issue #174): a Ball `Set` value is
    // the one-key `{'__ball_set__': [...]}` map (see ball_is_ball_set in
    // ball_dyn.h). This extracts the WRAPPED list from that shape, or
    // nullptr if `v` isn't it. Registered by ball_dyn.h; null (no-op) in
    // contexts that don't compile it.
    using SetListFn = const std::vector<std::any>* (*)(const std::any&);
    static inline SetListFn _set_list_fn = nullptr;
    static const std::vector<std::any>* set_list(const std::any& v) {
        return _set_list_fn ? _set_list_fn(v) : nullptr;
    }
};

// std::any — attempt known types, fallback to type name.
// Extension point for BallOrderedMap string conversion (set by ball_dyn.h).
inline std::string (*_ball_to_string_ext)(const std::any&) = nullptr;

inline std::string ball_to_string(const std::any& v) {
    if (!v.has_value()) return "null";
    // Unwrap BallDyn if present (MSVC wrapping issue)
    auto& u = _BallDynUnwrapper::unwrap(v);
    if (&u != &v) return ball_to_string(u);
    if (v.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(v));
    if (v.type() == typeid(int)) return std::to_string(std::any_cast<int>(v));
    if (v.type() == typeid(double)) return ball_to_string(std::any_cast<double>(v));
    if (v.type() == typeid(bool)) return ball_to_string(std::any_cast<bool>(v));
    if (v.type() == typeid(std::string)) return std::any_cast<std::string>(v);
    if (v.type() == typeid(const char*)) return std::any_cast<const char*>(v);
    if (v.type() == typeid(BallStringBuffer))
        return *std::any_cast<const BallStringBuffer&>(v).buf;
    if (v.type() == typeid(BallList_RT)) return ball_to_string(std::any_cast<const BallList_RT&>(v));
    if (const BallList_RT* lp = _BallRefDeref::list(v)) return ball_to_string(*lp);
    if (v.type() == typeid(BallMap_RT)) {
        auto& m = std::any_cast<const BallMap_RT&>(v);
        // A reified BallException (bound by `catch(e)` via _ball_exception_to_dyn)
        // stringifies to its original thrown value: Dart's `print(e)` / "$e"
        // shows the thrown object, not the internal
        // {typeName, value, message} reification. The map shape is retained so
        // `e["value"]`, `e["typeName"]` and `e is BallException` still work for
        // code (including the self-host engine) that inspects it.
        {
            auto tit = m.find("__type__");
            if (tit != m.end()) {
                const std::any& tu = _BallDynUnwrapper::unwrap(tit->second);
                if (tu.type() == typeid(std::string) &&
                    std::any_cast<const std::string&>(tu) == "BallException") {
                    auto vit = m.find("value");
                    if (vit != m.end()) return ball_to_string(vit->second);
                    auto mit = m.find("message");
                    if (mit != m.end()) return ball_to_string(mit->second);
                }
            }
        }
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
    if (_ball_to_string_ext) {
        auto ext = _ball_to_string_ext(v);
        if (!ext.empty()) return ext;
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

inline bool ball_is_int(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    return u.has_value() && u.type() == typeid(int64_t);
}
inline bool ball_is_double(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    return u.has_value() && u.type() == typeid(double);
}
inline bool ball_is_string(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    return u.has_value() && u.type() == typeid(std::string);
}
inline bool ball_is_bool(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    return u.has_value() && u.type() == typeid(bool);
}
inline bool ball_is_list(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    return u.has_value() &&
           (u.type() == typeid(BallList_RT) || _BallRefDeref::list(u) != nullptr);
}
// BallObject is defined later in this header (it `extends BallMap`). These
// accessors let the type-predicate helpers below treat a BallObject as the
// map it is, even though they are compiled before BallObject's definition.
bool _ball_any_is_object(const std::any& u);
const std::map<std::string, std::any>* _ball_object_base_map(const std::any& u);

// Extension point for BallOrderedMap map-type check (set by ball_dyn.h).
inline bool (*_ball_is_map_ext)(const std::any&) = nullptr;

inline bool ball_is_map(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    // A BallObject IS-A BallMap (Dart: `class BallObject extends BallMap`), so
    // the engine's `v is Map<String,Object?>` / `_asMap` paths must see it as a
    // map. Without this, instance fields never bind into method scopes.
    if (u.has_value() &&
        (u.type() == typeid(BallMap_RT) || _ball_any_is_object(u)))
        return true;
    if (_ball_is_map_ext && u.has_value() && _ball_is_map_ext(u)) return true;
    return false;
}
inline bool ball_is_function(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    return u.has_value() && u.type() == typeid(BallFunc_RT);
}

// Dart Object.runtimeType.toString() for primitives. Uses std::any so this
// header stays self-contained (no BallDyn dependency). BallDyn values convert
// to std::any via operator std::any() before reaching here.
inline std::string ball_runtime_type_name(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    if (ball_is_int(u)) return "int";
    if (ball_is_double(u)) return "double";
    if (ball_is_string(u)) return "String";
    if (ball_is_bool(u)) return "bool";
    if (ball_is_list(u)) return "List";
    if (ball_is_map(u)) return "Map";
    if (!u.has_value()) return "Null";
    return "Object";
}

inline bool ball_natural_less(const std::any& a, const std::any& b) {
    auto& ua = _BallDynUnwrapper::unwrap(a);
    auto& ub = _BallDynUnwrapper::unwrap(b);
    bool a_num = ua.type() == typeid(int64_t) || ua.type() == typeid(double);
    bool b_num = ub.type() == typeid(int64_t) || ub.type() == typeid(double);
    if (a_num && b_num) {
        double da = ua.type() == typeid(int64_t) ? static_cast<double>(std::any_cast<int64_t>(ua)) : std::any_cast<double>(ua);
        double db = ub.type() == typeid(int64_t) ? static_cast<double>(std::any_cast<int64_t>(ub)) : std::any_cast<double>(ub);
        return da < db;
    }
    return ball_to_string(a) < ball_to_string(b);
}

// RAII guard implementing Dart `finally` semantics. The cleanup callable runs
// when the guard leaves scope — on EVERY exit path: normal fall-through, a
// `return` inside the guarded block, or exception unwinding. C++ has no
// `finally`, so the compiler wraps try/finally bodies in one of these. Using a
// guard (rather than emitting the cleanup after the try/catch) is essential:
// a `return` inside the body would otherwise skip post-block cleanup entirely.
template <class F>
struct BallFinallyGuard {
    F fn;
    bool active;
    explicit BallFinallyGuard(F f) : fn(std::move(f)), active(true) {}
    ~BallFinallyGuard() { if (active) fn(); }
    BallFinallyGuard(BallFinallyGuard&& o) noexcept
        : fn(std::move(o.fn)), active(o.active) { o.active = false; }
    BallFinallyGuard(const BallFinallyGuard&) = delete;
    BallFinallyGuard& operator=(const BallFinallyGuard&) = delete;
};
template <class F>
BallFinallyGuard<F> make_ball_finally(F f) { return BallFinallyGuard<F>(std::move(f)); }

// Construct a BallException carrying an arbitrary payload (the engine's
// `BallException(typeName, value)`). The payload is unwrapped first so the
// stored value is the real underlying object (string/map/...), not a BallDyn
// re-wrapped inside std::any (MSVC's static_cast<std::any>(BallDyn) quirk). A
// matching catch handler reads the value back via _ball_exception_to_dyn.
inline BallException _ball_make_exception(const std::string& type_name,
                                          const std::any& value) {
    const std::any& u = _BallDynUnwrapper::unwrap(value);
    // `rethrow` (compiled as `throw <caught-var>`) hands us an exception that
    // was already reconstructed into a DYN map by _ball_exception_to_dyn:
    // {__type__: "BallException", typeName: ..., value: ...}. Re-wrapping the
    // whole map would double-nest it (a catch would then see the map as the
    // thrown value). Detect that shape and re-raise the ORIGINAL typeName +
    // value so the payload survives an arbitrary number of rethrows.
    if (u.has_value() && u.type() == typeid(BallMap_RT)) {
        const auto& m = std::any_cast<const BallMap_RT&>(u);
        auto tit = m.find("__type__");
        if (tit != m.end()) {
            const std::any& tv = _BallDynUnwrapper::unwrap(tit->second);
            if (tv.type() == typeid(std::string) &&
                std::any_cast<const std::string&>(tv) == "BallException") {
                std::string inner_type = type_name;
                auto nit = m.find("typeName");
                if (nit != m.end()) {
                    const std::any& nv = _BallDynUnwrapper::unwrap(nit->second);
                    if (nv.type() == typeid(std::string))
                        inner_type = std::any_cast<const std::string&>(nv);
                }
                std::any inner_val;
                bool has_inner = false;
                auto vit = m.find("value");
                if (vit != m.end()) { inner_val = _BallDynUnwrapper::unwrap(vit->second); has_inner = true; }
                BallException e(inner_type, ball_to_string(inner_val));
                e.value = inner_val;
                e.has_payload = has_inner;
                return e;
            }
        }
    }
    BallException e(type_name, ball_to_string(u));
    e.value = u;
    e.has_payload = true;
    return e;
}

// Check if a value is a FlowSignal (a map with a "kind" field).
inline bool ball_is_flow_signal(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    if (!u.has_value() || u.type() != typeid(BallMap_RT)) return false;
    const auto& m = std::any_cast<const BallMap_RT&>(u);
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

// Generator: sync*/async* functions collect yielded values here. Reference
// semantics via shared_ptr so that binding the generator into a scope and
// yielding into it later both mutate the same underlying list (matching the
// Dart engine's object-reference model). See yield_ / yieldAll in ball_dyn.h.
struct BallGenerator {
    std::shared_ptr<std::vector<std::any>> values =
        std::make_shared<std::vector<std::any>>();
    bool completed = false;
};

// Extension point for BallOrderedMap type matching (set by ball_dyn.h).
inline bool (*_ball_object_type_matches_ext)(const std::any&, const std::string&) = nullptr;

// Extension point for BallOrderedMap typed-map check (set by ball_dyn.h).
// Inspects the first value's type so `is Map<K, V>` discriminates correctly
// on insertion-ordered maps (used by ball_is_typed_map below).
inline bool (*_ball_typed_map_ext)(const std::any&, const std::string&) = nullptr;

// Check if a map value's __type__ matches a type name (walks __super__ chain).
inline bool ball_object_type_matches(const std::any& value, const std::string& type) {
    auto& u = _BallDynUnwrapper::unwrap(value);
    if (u.has_value() && u.type() == typeid(BallGenerator)) {
        return ball_type_name_matches("BallGenerator", type);
    }
    if (!u.has_value()) return false;
    // Accept both a raw BallMap and a BallObject (a user class instance) — the
    // BallObject's base map carries `__type__`/`__super__`, so `x is Point`
    // resolves through the same walk. We deliberately do NOT report a match for
    // the literal name "BallMap" here: `_asMap` checks `is BallMap` first and
    // expects a raw-map shape, which the second (`ball_is_map`) branch supplies.
    const BallMap_RT* mptr = nullptr;
    if (u.type() == typeid(BallMap_RT)) {
        mptr = &std::any_cast<const BallMap_RT&>(u);
    } else {
        mptr = _ball_object_base_map(u);
    }
    if (!mptr) {
        if (_ball_object_type_matches_ext)
            return _ball_object_type_matches_ext(u, type);
        return false;
    }
    const auto& m = *mptr;
    auto it = m.find("__type__");
    if (it != m.end() && it->second.has_value()) {
        auto& tv = _BallDynUnwrapper::unwrap(it->second);
        if (tv.type() == typeid(std::string)) {
            if (ball_type_name_matches(std::any_cast<const std::string&>(tv), type)) return true;
        }
    }
    auto sit = m.find("__super__");
    std::any super_obj = (sit != m.end()) ? sit->second : std::any{};
    while (super_obj.has_value()) {
        auto& su = _BallDynUnwrapper::unwrap(super_obj);
        const BallMap_RT* smptr = (su.type() == typeid(BallMap_RT))
            ? &std::any_cast<const BallMap_RT&>(su)
            : _ball_object_base_map(su);
        if (!smptr) break;
        const auto& sm = *smptr;
        auto st = sm.find("__type__");
        if (st != sm.end() && st->second.has_value()) {
            auto& stv = _BallDynUnwrapper::unwrap(st->second);
            if (stv.type() == typeid(std::string)) {
                if (ball_type_name_matches(std::any_cast<const std::string&>(stv), type)) return true;
            }
        }
        auto ss = sm.find("__super__");
        super_obj = (ss != sm.end()) ? ss->second : std::any{};
    }
    return false;
}

// ── Concrete-struct type matching ──
// Compiled classes are emitted as plain C++ structs (not BallMap-backed
// objects), so `x is Vec2` on a concrete struct receiver cannot consult a
// runtime `__type__` field. Each emitted struct exposes a static
// `__ball_type_name()`; this template overload is a better match than the
// `const std::any&` overload for any value carrying that trait, so a concrete
// struct compares its declared type name against the requested type (walking
// the same colon-stripping rules as map-backed objects). conformance 113.
template <typename T>
auto ball_object_type_matches(const T& value, const std::string& type)
    -> decltype(T::__ball_type_name(), bool()) {
    (void)value;
    return ball_type_name_matches(T::__ball_type_name(), type);
}

// ── Reified generics: check __type_args__ on a map-backed object ──
inline bool ball_type_args_match(const std::any& value, const std::string& expected) {
    const auto& u = _BallDynUnwrapper::unwrap(value);
    const BallMap_RT* mptr = nullptr;
    if (u.type() == typeid(BallMap_RT)) {
        mptr = &std::any_cast<const BallMap_RT&>(u);
    } else {
        mptr = _ball_object_base_map(u);
    }
    if (!mptr) return false;
    auto it = mptr->find("__type_args__");
    if (it == mptr->end()) return false;
    const auto& tav = _BallDynUnwrapper::unwrap(it->second);
    if (tav.type() == typeid(std::string)) {
        return std::any_cast<const std::string&>(tav) == expected;
    }
    return false;
}

// Forward declaration so ball_identical (below) can compare BallObjectRef
// (shared_ptr<BallObject>) pointer identity. The full BallObject definition
// appears later in this header; shared_ptr<BallObject>.get() needs only an
// incomplete type, so the forward declaration is sufficient here.
struct BallObject;

// ── Dart `identical(a, b)` — identity check, NOT equality ──
// For doubles: identical(NaN, NaN) is true, identical(-0.0, 0.0) is false.
// For ints/strings/bools: value equality. For objects: reference equality.
inline bool ball_identical(const std::any& a, const std::any& b) {
    const auto& ua = _BallDynUnwrapper::unwrap(a);
    const auto& ub = _BallDynUnwrapper::unwrap(b);
    if (!ua.has_value() && !ub.has_value()) return true;
    if (!ua.has_value() || !ub.has_value()) return false;
    // doubles: bitwise identity (NaN == NaN, -0.0 != 0.0)
    if (ua.type() == typeid(double) && ub.type() == typeid(double)) {
        double da = std::any_cast<double>(ua);
        double db = std::any_cast<double>(ub);
        // Use memcmp for bitwise comparison: NaN == NaN, -0.0 != 0.0
        return std::memcmp(&da, &db, sizeof(double)) == 0;
    }
    // int: value equality
    if (ua.type() == typeid(int64_t) && ub.type() == typeid(int64_t))
        return std::any_cast<int64_t>(ua) == std::any_cast<int64_t>(ub);
    // bool: value equality
    if (ua.type() == typeid(bool) && ub.type() == typeid(bool))
        return std::any_cast<bool>(ua) == std::any_cast<bool>(ub);
    // string: value equality
    if (ua.type() == typeid(std::string) && ub.type() == typeid(std::string))
        return std::any_cast<const std::string&>(ua) == std::any_cast<const std::string&>(ub);
    // Different types → not identical
    if (ua.type() != ub.type()) return false;
    // BallUserRef (shared_ptr<std::any>): compare pointer identity.
    // Concrete user-class struct instances stored reference-semantically
    // through BallUserRef share the same std::any when they originate from
    // the same Dart object; `identical` must reflect that.
    if (ua.type() == typeid(std::shared_ptr<std::any>)) {
        return std::any_cast<const std::shared_ptr<std::any>&>(ua).get() ==
               std::any_cast<const std::shared_ptr<std::any>&>(ub).get();
    }
    // BallObjectRef (shared_ptr<BallObject>): the engine represents map-backed
    // user-class instances reference-semantically — copies of the BallDyn share
    // the same BallObject through the shared_ptr, so `identical` is pointer
    // identity on the shared_ptr. Without this, two references to the SAME
    // instance (e.g. a factory constructor returning its cached object twice)
    // fell through to the object default below and compared false. (self-host 106)
    if (ua.type() == typeid(std::shared_ptr<BallObject>)) {
        return std::any_cast<const std::shared_ptr<BallObject>&>(ua).get() ==
               std::any_cast<const std::shared_ptr<BallObject>&>(ub).get();
    }
    // For objects, fall back to pointer identity
    return false;
}

// ── Reified generics: typed map check ──
// Check if value is a map whose values match the given type name.
// Checks the first entry's value type. Empty maps match any type.
inline bool ball_is_typed_map(const std::any& value, const std::string& val_type) {
    const auto& u = _BallDynUnwrapper::unwrap(value);
    if (!u.has_value()) return false;
    // Object?/Object/dynamic is Dart's top type — it matches a map with ANY
    // value type, so once the value is confirmed to be a map we accept it.
    // Without this, `is Map<String, Object?>` (and the _asMap/_stdAsMap/_cfAsMap
    // coercions that rely on it) returned false for maps whose first value is
    // not a primitive (nested maps/lists/objects), making field access /
    // iteration throw BallRuntimeError.
    const bool topType = (val_type == "Object?" || val_type == "Object" || val_type == "dynamic");
    // Must be a map first
    const BallMap_RT* mptr = nullptr;
    if (u.type() == typeid(BallMap_RT)) {
        mptr = &std::any_cast<const BallMap_RT&>(u);
    } else {
        mptr = _ball_object_base_map(u);
    }
    // BallOrderedMap (+Ref) and other extension-provided maps. The extension
    // inspects the first value's type; the top type short-circuits that.
    if (!mptr) {
        if (_ball_is_map_ext && _ball_is_map_ext(u)) {
            if (topType) return true;
            if (_ball_typed_map_ext) return _ball_typed_map_ext(u, val_type);
            return true;
        }
        if (_ball_typed_map_ext) return _ball_typed_map_ext(u, val_type);
        return false;
    }
    if (mptr->empty()) return true;  // empty map matches any type
    if (topType) return true;        // top type matches any value
    // Check the first value's type
    const auto& first_val = _BallDynUnwrapper::unwrap(mptr->begin()->second);
    if (val_type == "int") return first_val.type() == typeid(int64_t);
    if (val_type == "double") return first_val.type() == typeid(double);
    if (val_type == "num") return first_val.type() == typeid(int64_t) || first_val.type() == typeid(double);
    if (val_type == "String") return first_val.type() == typeid(std::string);
    if (val_type == "bool") return first_val.type() == typeid(bool);
    return ball_object_type_matches(first_val, val_type);
}

// ── Reified generics: typed list check ──
// Check if value is a list whose elements match the given type name.
// For homogeneous typed vectors (std::vector<int64_t>, etc.) check the C++
// element type; for heterogeneous BallList (std::vector<std::any>) check the
// first element's runtime type. Empty lists match any type.
inline bool ball_is_typed_list(const std::any& value, const std::string& elem_type) {
    const auto& u = _BallDynUnwrapper::unwrap(value);
    if (!u.has_value()) return false;
    // Object?/Object/dynamic is Dart's top type — it matches a list with ANY
    // element type. Without this `is List<Object?>` (and _asList/_stdAsList
    // coercions) returned false for lists of non-primitives, throwing
    // BallRuntimeError on populated nested collections.
    const bool topType = (elem_type == "Object?" || elem_type == "Object" || elem_type == "dynamic");
    // Homogeneous typed vectors
    if (u.type() == typeid(std::vector<int64_t>))
        return topType || elem_type == "int" || elem_type == "num";
    if (u.type() == typeid(std::vector<double>))
        return topType || elem_type == "double" || elem_type == "num";
    if (u.type() == typeid(std::vector<std::string>))
        return topType || elem_type == "String";
    if (u.type() == typeid(std::vector<bool>))
        return topType || elem_type == "bool";
    // Heterogeneous BallList — check first element
    const BallList_RT* lp = nullptr;
    if (u.type() == typeid(BallList_RT)) {
        lp = &std::any_cast<const BallList_RT&>(u);
    } else {
        lp = _BallRefDeref::list(u);
    }
    if (!lp) return false;
    if (lp->empty()) return true;  // empty list matches any type
    if (topType) return true;      // top type matches any element
    const auto& first = _BallDynUnwrapper::unwrap((*lp)[0]);
    if (elem_type == "int") return first.type() == typeid(int64_t);
    if (elem_type == "double") return first.type() == typeid(double);
    if (elem_type == "num") return first.type() == typeid(int64_t) || first.type() == typeid(double);
    if (elem_type == "String") return first.type() == typeid(std::string);
    if (elem_type == "bool") return first.type() == typeid(bool);
    // For object types, check __type__ on the first element
    return ball_object_type_matches(first, elem_type);
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
inline std::vector<std::any> ball_to_list(const std::any& raw) {
    // A rest pattern lowers its subject to `ball_to_list(static_cast<std::any>(
    // BallDyn(__subj)))`, which hands us a std::any wrapping a *BallDyn* (not a
    // bare BallList). Without unwrapping, the type checks below all miss, the
    // function returns {}, and `BallList(__l.begin()+1, __l.end())` underflows
    // into a multi-exabyte allocation (std::length_error). conformance 252.
    const std::any& v = _BallDynUnwrapper::unwrap(raw);
    if (v.type() == typeid(std::vector<std::any>))
        return std::any_cast<std::vector<std::any>>(v);
    if (const std::vector<std::any>* lp = _BallRefDeref::list(v))
        return *lp;
    // Portable ordered-set value (issue #174): unwrap to its backing list.
    if (const std::vector<std::any>* sp = _BallRefDeref::set_list(v))
        return *sp;
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
// GCC defines __const__ as a macro alias for `const`, which breaks a field
// literally named __const__. Use json_const instead; self-host init sites use
// designated initializers with .json_const = true.
struct JsonEncoder {
    bool json_const = false;
};
struct JsonDecoder {
    bool json_const = false;
};

// Escape a string per JSON rules (quotes, backslash, control chars).
inline std::string _ball_json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    out += '"';
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    static const char* hex = "0123456789abcdef";
                    unsigned char uc = static_cast<unsigned char>(c);
                    out += "\\u00";
                    out += hex[(uc >> 4) & 0xF];
                    out += hex[uc & 0xF];
                } else {
                    out += c;
                }
        }
    }
    out += '"';
    return out;
}

// Extension point for ordered-map JSON encoding. Set by ball_dyn.h after
// BallOrderedMap is defined. Returns non-empty string if the type was handled.
inline std::string (*_ball_json_encode_ext_fn)(const std::any&) = nullptr;

// Recursively serialize a (already _toJsonSafe-processed) BallDyn/std::any to
// JSON. Maps -> {"k":v}, lists -> [..], strings quoted+escaped, ints without a
// trailing .0, doubles via ball_to_string, bools/null literally. Internal keys
// (starting with "__" or "type_args") are skipped to match the Dart engine.
inline std::string _ball_json_encode(const std::any& v) {
    auto& u = _BallDynUnwrapper::unwrap(v);
    if (!u.has_value()) return "null";
    if (u.type() == typeid(bool)) return std::any_cast<bool>(u) ? "true" : "false";
    if (u.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(u));
    if (u.type() == typeid(int)) return std::to_string(std::any_cast<int>(u));
    if (u.type() == typeid(double)) return ball_to_string(std::any_cast<double>(u));
    if (u.type() == typeid(std::string)) return _ball_json_escape(std::any_cast<const std::string&>(u));
    if (u.type() == typeid(const char*)) return _ball_json_escape(std::string(std::any_cast<const char*>(u)));
    auto encode_list = [](const BallList_RT& list) {
        std::string out = "[";
        bool first = true;
        for (const auto& e : list) {
            if (!first) out += ",";
            out += _ball_json_encode(e);
            first = false;
        }
        out += "]";
        return out;
    };
    if (u.type() == typeid(BallList_RT)) return encode_list(std::any_cast<const BallList_RT&>(u));
    if (const BallList_RT* lp = _BallRefDeref::list(u)) return encode_list(*lp);
    if (u.type() == typeid(BallMap_RT)) {
        auto& m = std::any_cast<const BallMap_RT&>(u);
        std::string out = "{";
        bool first = true;
        for (auto it = m.begin(); it != m.end(); ++it) {
            if (it->first.rfind("__", 0) == 0 || it->first == "type_args") continue;
            if (!first) out += ",";
            out += _ball_json_escape(it->first) + ":" + _ball_json_encode(it->second);
            first = false;
        }
        out += "}";
        return out;
    }
    if (_ball_json_encode_ext_fn) {
        auto ext = _ball_json_encode_ext_fn(u);
        if (!ext.empty()) return ext;
    }
    return _ball_json_escape(ball_to_string(u));
}

// Bounded recursive-descent JSON parser. Produces BallMap_RT for objects,
// BallList_RT for arrays, int64_t/double/bool/std::string/empty for scalars.
inline std::any _ball_json_parse(const std::string& s, size_t& i, int depth);
inline void _ball_json_skip_ws(const std::string& s, size_t& i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
}
inline std::string _ball_json_parse_string(const std::string& s, size_t& i) {
    std::string out;
    ++i;  // opening quote
    while (i < s.size() && s[i] != '"') {
        char c = s[i++];
        if (c == '\\' && i < s.size()) {
            char e = s[i++];
            switch (e) {
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case '/': out += '/'; break;
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case 'u': {
                    if (i + 4 <= s.size()) {
                        unsigned code = static_cast<unsigned>(std::stoul(s.substr(i, 4), nullptr, 16));
                        i += 4;
                        // Encode as UTF-8 (BMP only; matches the common cases).
                        if (code < 0x80) out += static_cast<char>(code);
                        else if (code < 0x800) {
                            out += static_cast<char>(0xC0 | (code >> 6));
                            out += static_cast<char>(0x80 | (code & 0x3F));
                        } else {
                            out += static_cast<char>(0xE0 | (code >> 12));
                            out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
                            out += static_cast<char>(0x80 | (code & 0x3F));
                        }
                    }
                    break;
                }
                default: out += e;
            }
        } else {
            out += c;
        }
    }
    if (i < s.size()) ++i;  // closing quote
    return out;
}
inline std::any _ball_json_parse(const std::string& s, size_t& i, int depth) {
    if (depth > 256) return std::any{};
    _ball_json_skip_ws(s, i);
    if (i >= s.size()) return std::any{};
    char c = s[i];
    if (c == '{') {
        ++i;
        BallMap_RT obj;
        _ball_json_skip_ws(s, i);
        if (i < s.size() && s[i] == '}') { ++i; return std::any(std::move(obj)); }
        while (i < s.size()) {
            _ball_json_skip_ws(s, i);
            std::string key = (i < s.size() && s[i] == '"') ? _ball_json_parse_string(s, i) : std::string();
            _ball_json_skip_ws(s, i);
            if (i < s.size() && s[i] == ':') ++i;
            obj[key] = _ball_json_parse(s, i, depth + 1);
            _ball_json_skip_ws(s, i);
            if (i < s.size() && s[i] == ',') { ++i; continue; }
            if (i < s.size() && s[i] == '}') { ++i; break; }
            break;
        }
        return std::any(std::move(obj));
    }
    if (c == '[') {
        ++i;
        BallList_RT arr;
        _ball_json_skip_ws(s, i);
        if (i < s.size() && s[i] == ']') { ++i; return std::any(std::move(arr)); }
        while (i < s.size()) {
            arr.push_back(_ball_json_parse(s, i, depth + 1));
            _ball_json_skip_ws(s, i);
            if (i < s.size() && s[i] == ',') { ++i; continue; }
            if (i < s.size() && s[i] == ']') { ++i; break; }
            break;
        }
        return std::any(std::move(arr));
    }
    if (c == '"') return std::any(_ball_json_parse_string(s, i));
    if (s.compare(i, 4, "true") == 0) { i += 4; return std::any(true); }
    if (s.compare(i, 5, "false") == 0) { i += 5; return std::any(false); }
    if (s.compare(i, 4, "null") == 0) { i += 4; return std::any{}; }
    // Number.
    size_t start = i;
    bool is_double = false;
    if (i < s.size() && (s[i] == '-' || s[i] == '+')) ++i;
    while (i < s.size() && ((s[i] >= '0' && s[i] <= '9') ||
                            s[i] == '.' || s[i] == 'e' || s[i] == 'E' ||
                            s[i] == '+' || s[i] == '-')) {
        if (s[i] == '.' || s[i] == 'e' || s[i] == 'E') is_double = true;
        ++i;
    }
    std::string num = s.substr(start, i - start);
    if (num.empty()) { ++i; return std::any{}; }
    try {
        if (is_double) return std::any(std::stod(num));
        return std::any(static_cast<int64_t>(std::stoll(num)));
    } catch (...) {
        try { return std::any(std::stod(num)); } catch (...) {}
    }
    return std::any{};
}

inline std::string convert(const JsonEncoder&, const std::any& value) {
    return _ball_json_encode(value);
}
inline std::any convert(const JsonDecoder&, const std::string& text) {
    size_t i = 0;
    return _ball_json_parse(text, i, 0);
}

// Single-argument JSON decode used by emitted std_convert.json_decode.
// Parses numbers->int64/double, strings, bools, null, arrays->BallList_RT,
// objects->BallMap_RT (mirrors _ball_json_encode's value model).
inline std::any _ball_json_decode(const std::string& text) {
    size_t i = 0;
    return _ball_json_parse(text, i, 0);
}

// ── std_time helpers ──
// Self-contained ISO-8601 (UTC, millisecond) format/parse matching the Dart
// engine's DateTime.fromMillisecondsSinceEpoch(ms, isUtc:true).toIso8601String()
// and DateTime.parse(value).millisecondsSinceEpoch. Uses only <ctime>/<cstdio>
// (included above).
inline std::string _ball_format_timestamp(int64_t ms) {
    int64_t secs = ms / 1000;
    int millis = static_cast<int>(ms % 1000);
    if (millis < 0) { millis += 1000; secs -= 1; }
    std::time_t t = static_cast<std::time_t>(secs);
    std::tm g{};
#if defined(_WIN32)
    gmtime_s(&g, &t);
#else
    gmtime_r(&t, &g);
#endif
    char buf[40];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
        g.tm_year + 1900, g.tm_mon + 1, g.tm_mday,
        g.tm_hour, g.tm_min, g.tm_sec, millis);
    return std::string(buf);
}
inline int64_t _ball_parse_timestamp(const std::string& iso) {
    int Y = 0, Mo = 0, D = 0, H = 0, Mi = 0, S = 0, frac = 0;
    std::sscanf(iso.c_str(), "%d-%d-%dT%d:%d:%d", &Y, &Mo, &D, &H, &Mi, &S);
    auto dot = iso.find('.');
    if (dot != std::string::npos) {
        std::string f;
        size_t j = dot + 1;
        while (j < iso.size() && iso[j] >= '0' && iso[j] <= '9') { f += iso[j]; ++j; }
        while (f.size() < 3) f += '0';
        frac = std::stoi(f.substr(0, 3));
    }
    std::tm g{};
    g.tm_year = Y - 1900; g.tm_mon = Mo - 1; g.tm_mday = D;
    g.tm_hour = H; g.tm_min = Mi; g.tm_sec = S;
#if defined(_WIN32)
    std::time_t t = _mkgmtime(&g);
#else
    std::time_t t = timegm(&g);
#endif
    return static_cast<int64_t>(t) * 1000 + frac;
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

// BallDyn overloads for codec functions
class BallDyn;
inline std::vector<std::any> encode(const Utf8Codec& c, const BallDyn& s);
inline std::string decode(const Utf8Codec& c, const BallDyn& bytes);
inline std::string encode(const Base64Codec& c, const BallDyn& bytes);
inline std::vector<std::any> decode(const Base64Codec& c, const BallDyn& s);

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
    // Unwrap first: under MSVC a BallDyn passed where a std::any is expected is
    // stored as typeid(BallDyn) rather than its inner std::function, so checking
    // the type directly on `callee` would miss every dynamically-stored closure
    // (e.g. lambdas pushed into a list and called via dart_std.invoke). The
    // unwrapper yields the real underlying std::function. Mirror the unwrap on
    // the arguments too, so the callee receives a clean value rather than a
    // doubly-wrapped BallDyn.
    const std::any& fnAny = _BallDynUnwrapper::unwrap(callee);
    if (fnAny.type() == typeid(std::function<std::any(std::any)>)) {
        auto& fn = std::any_cast<const std::function<std::any(std::any)>&>(fnAny);
        if (args.empty()) return fn(std::any{});
        return fn(_BallDynUnwrapper::unwrap(args[0]));
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

// Determine whether a `writeAsStringSync`/`writeAsBytesSync` FileMode arg
// requests append semantics. The self-hosted engine's `_stdFileAppend`
// (engine_std.dart) compiles `File(path).writeAsStringSync(content, mode:
// FileMode.append)` — through the generic method-call fallback in
// compile_method_call — into `writeAsStringSync(File(path), content,
// io_FileMode["append"s])`, so `mode` materializes as a std::any wrapping
// the string "append"/"write"/"read". `file_write`'s 2-arg call passes no
// third argument at all (defaults to an empty std::any), meaning
// truncate/write. Any other value fails loud instead of silently guessing
// truncate-vs-append (issue #310).
inline bool _ball_file_mode_is_append(const std::any& mode) {
    const std::any& v = _BallDynUnwrapper::unwrap(mode);
    if (!v.has_value()) return false;  // no mode arg supplied -> write/truncate
    std::string s = ball_to_string(v);
    if (s == "append") return true;
    if (s == "write" || s == "read") return false;
    throw std::runtime_error(
        "writeAsStringSync: unsupported FileMode value: " + s);
}

// ── File I/O stubs ──
// The self-hosted engine calls `File(path)`, `readAsStringSync(file)`,
// `writeAsStringSync(file, content)`, etc. Provide stubs.
struct File {
    std::string path;
    File(const std::string& p) : path(p) {}
    File(const std::any& p) : path(ball_to_string(p)) {}
    File(const BallDyn& p);  // defined in ball_dyn.h
};
inline std::string readAsStringSync(const File& f) {
    std::ifstream ifs(f.path);
    return std::string((std::istreambuf_iterator<char>(ifs)),
                        std::istreambuf_iterator<char>());
}
inline void writeAsStringSync(const File& f, const std::string& content, const std::any& mode = {}) {
    auto flags = std::ios::out | (_ball_file_mode_is_append(mode) ? std::ios::app : std::ios::trunc);
    std::ofstream ofs(f.path, flags);
    ofs << content;
}
inline void writeAsStringSync(const File& f, const std::any& content, const std::any& mode = {}) {
    auto flags = std::ios::out | (_ball_file_mode_is_append(mode) ? std::ios::app : std::ios::trunc);
    std::ofstream ofs(f.path, flags);
    ofs << ball_to_string(content);
}
inline std::vector<std::any> readAsBytesSync(const File& f) {
    std::ifstream ifs(f.path, std::ios::binary);
    std::vector<std::any> result;
    char c;
    while (ifs.get(c)) result.push_back(std::any(static_cast<int64_t>(static_cast<unsigned char>(c))));
    return result;
}
// Real byte write: `content` arrives as a Ball List<int> — either a bare
// std::vector<std::any> or a wrapped/ref-deref'd list (ball_to_list handles
// both) — each element an int64_t byte value 0-255, the same shape
// readAsBytesSync produces and a `bytes` literal materializes to (see
// TYPE_BYTES handling in test_selfhost_conformance.cpp's proto_msg_to_any).
// The prior stub wrote nothing, silently dropping every byte written via
// `std_fs.file_write_bytes` (fail-loud-invariant violation, issue #310).
inline void writeAsBytesSync(const File& f, const std::any& content) {
    std::vector<std::any> bytes = ball_to_list(content);
    std::ofstream ofs(f.path, std::ios::binary | std::ios::trunc);
    for (const auto& raw : bytes) {
        const std::any& v = _BallDynUnwrapper::unwrap(raw);
        int64_t byteVal;
        if (v.type() == typeid(int64_t)) byteVal = std::any_cast<int64_t>(v);
        else if (v.type() == typeid(int)) byteVal = static_cast<int64_t>(std::any_cast<int>(v));
        else throw std::runtime_error(
            "writeAsBytesSync: non-integer byte element in content list");
        ofs.put(static_cast<char>(static_cast<unsigned char>(byteVal & 0xff)));
    }
}
inline bool existsSync(const File& f) {
    std::ifstream ifs(f.path);
    return ifs.good();
}
// BallDyn overload in ball_dyn.h
inline void writeAsStringSync(const File& f, const BallDyn& content, const std::any& mode = {});

// ── Directory operations ──
// Mirror Dart's dart:io Directory API. The self-hosted engine's std_fs
// handlers (engine_std.dart) call these as:
//   io.Directory(path).listSync().map((e) => e.path).toList()   // dir_list
//   io.Directory(path).createSync(recursive: true)              // dir_create
//   io.Directory(path).existsSync()                             // dir_exists
// These MUST do real filesystem work: returning {}/false silently degraded
// dir_list to [] and dir_exists to false (a fail-loud-invariant violation —
// the program computed wrong results with no error). Semantics match the
// compiler's direct-compile std_fs emission (compile_fs_call in compiler.cpp):
// dir_list → directory_iterator entry paths, dir_create → create_directories
// (recursive), dir_exists → is_directory.
struct Directory {
    std::string path;
    Directory(const std::string& p) : path(p) {}
    Directory(const std::any& p) : path(ball_to_string(p)) {}
    Directory(const BallDyn& p);  // defined in ball_dyn.h
};
inline std::vector<std::any> listSync(const Directory& d) {
    // Dart's listSync() yields FileSystemEntity objects; the engine then
    // reads `.path` on each. Field access `e.path` compiles to
    // `static_cast<BallDyn>(e)["path"s]`, so each element must be a map
    // carrying a "path" key (a directory-entry view). Like Dart's listSync
    // (and the direct-compile path), a missing/non-dir path throws.
    std::vector<std::any> result;
    for (const auto& entry : std::filesystem::directory_iterator(d.path)) {
        std::map<std::string, std::any> e;
        e["path"] = std::any(entry.path().string());
        result.push_back(std::any(e));
    }
    return result;
}
inline void createSync(const Directory& d, bool recursive = false) {
    // recursive:true (the engine's dir_create) creates missing parents, like
    // Dart's createSync(recursive: true); recursive:false creates only the leaf
    // and throws if a parent is missing (Dart createSync() parity).
    if (recursive) {
        std::filesystem::create_directories(d.path);
    } else {
        std::filesystem::create_directory(d.path);
    }
}
inline bool existsSync(const Directory& d) {
    // Dart existsSync() is false for a missing path; the error_code overload of
    // is_directory returns false (no throw) for not-found instead of raising.
    std::error_code ec;
    return std::filesystem::is_directory(d.path, ec);
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
inline std::any bind(std::any& scope, const std::any& name, const std::any& value) {
    if (scope.type() == typeid(std::map<std::string, std::any>)) {
        std::any_cast<std::map<std::string, std::any>&>(scope)[ball_to_string(name)] = value;
    }
    return std::any{};
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

// ── registerScopeExit stub ──
inline void registerScopeExit(const std::any&, const std::any&, const std::any&) {}

// ── Future.then stub ──
// Dart's Future.then(callback) — in synchronous C++ simulation, just call immediately
template<typename F>
inline void then(const std::any&, F callback) {
    // Synchronous stub: ignore (future already resolved)
}

// _envGet stub — wraps std::getenv
inline std::string _envGet(const std::string& name) {
    auto v = std::getenv(name.c_str());
    return v ? std::string(v) : std::string();
}
inline std::string _envGet(const std::any& name) {
    return _envGet(ball_to_string(name));
}

// ── List.generate ──
// Dart's List.generate(count, generator) → builds a list by calling generator(i) for i in 0..count-1.
// The type argument (e.g. "List") is ignored.
// List.generate defined in ball_dyn.h after BallDyn class

// ── ball_to_set / set ops for BallDyn ──
// Defined in ball_dyn.h after BallDyn class definition.

// ── String.fromCharCode ──
inline std::string fromCharCode(const std::string&, int64_t code) {
    return std::string(1, static_cast<char>(code));
}
inline std::string fromCharCode(const std::string& tag, const std::any& code_val) {
    int64_t code = 0;
    if (code_val.type() == typeid(int64_t)) code = std::any_cast<int64_t>(code_val);
    else if (code_val.type() == typeid(double)) code = static_cast<int64_t>(std::any_cast<double>(code_val));
    return fromCharCode(tag, code);
}

// ── DateTime methods ──
// fromMillisecondsSinceEpoch(DateTime, ms, isUtc)
inline std::map<std::string, std::any> fromMillisecondsSinceEpoch(const DateTimeType&, int64_t ms, bool = false) {
    return {{"millisecondsSinceEpoch", std::any(ms)}};
}
inline std::map<std::string, std::any> fromMillisecondsSinceEpoch(const DateTimeType& dt, const std::any& ms_val, const std::any& = {}) {
    int64_t ms = 0;
    if (ms_val.type() == typeid(int64_t)) ms = std::any_cast<int64_t>(ms_val);
    else if (ms_val.type() == typeid(double)) ms = static_cast<int64_t>(std::any_cast<double>(ms_val));
    return fromMillisecondsSinceEpoch(dt, ms);
}

// toIso8601String(dt_map) — format DateTime as ISO 8601
inline std::string toIso8601String(const std::map<std::string, std::any>& dt) {
    auto it = dt.find("millisecondsSinceEpoch");
    if (it == dt.end()) return "1970-01-01T00:00:00.000Z";
    int64_t ms = 0;
    if (it->second.type() == typeid(int64_t)) ms = std::any_cast<int64_t>(it->second);
    time_t secs = ms / 1000;
    int millis = static_cast<int>(ms % 1000);
    struct tm t;
#ifdef _WIN32
    gmtime_s(&t, &secs);
#else
    gmtime_r(&secs, &t);
#endif
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &t);
    char out[40];
    std::snprintf(out, sizeof(out), "%s.%03dZ", buf, millis);
    return std::string(out);
}
inline std::string toIso8601String(const std::any& dt_val) {
    if (dt_val.type() == typeid(std::map<std::string, std::any>))
        return toIso8601String(std::any_cast<const std::map<std::string, std::any>&>(dt_val));
    return "1970-01-01T00:00:00.000Z";
}

// parse(DateTime, str) — parse ISO 8601 string to DateTime map
inline std::map<std::string, std::any> parse(const DateTimeType&, const std::string& str) {
    struct tm t = {};
    int millis = 0;
    // Try parsing ISO 8601 format
    if (sscanf(str.c_str(), "%d-%d-%dT%d:%d:%d.%dZ",
               &t.tm_year, &t.tm_mon, &t.tm_mday,
               &t.tm_hour, &t.tm_min, &t.tm_sec, &millis) >= 6) {
        t.tm_year -= 1900;
        t.tm_mon -= 1;
#ifdef _WIN32
        time_t secs = _mkgmtime(&t);
#else
        time_t secs = timegm(&t);
#endif
        int64_t ms = static_cast<int64_t>(secs) * 1000 + millis;
        return {{"millisecondsSinceEpoch", std::any(ms)}};
    }
    return {{"millisecondsSinceEpoch", std::any(static_cast<int64_t>(0))}};
}
inline std::map<std::string, std::any> parse(const DateTimeType& dt, const std::any& str_val) {
    return parse(dt, ball_to_string(str_val));
}

// ── jsonEncode / toProto3Json stubs ──
// Dart's `jsonEncode(x)` serialises a value to a JSON string.
// `toProto3Json(program)` converts a proto message to its proto3-JSON shape;
// since our C++ representation is already in map form, we just return it.
//
// jsonEncode is used in _validateProgramLimits to compute the byte size of
// the serialised program. A best-effort ball_to_string conversion is fine.
class BallDyn;
inline std::string jsonEncode(const std::any& value) {
    return ball_to_string(value);
}
inline std::string jsonEncode(const BallDyn& value);  // defined in ball_dyn.h
inline std::any toProto3Json(const std::any& program) {
    return program;
}
inline std::any toProto3Json(const BallDyn& program);  // defined in ball_dyn.h

// ── fold free function ──
// Dart's Iterable.fold(initialValue, combine) — reduce over a list.
// Used in _trackMemoryAllocation for string_split result.
// fold() templates are defined in ball_dyn.h after the BallDyn class.
template<typename Iter, typename Init, typename Fn>
BallDyn fold(const Iter& iter, const std::string& type_tag, Init init, Fn fn);
template<typename Iter, typename Init, typename Fn>
BallDyn fold(const Iter& iter, Init init, Fn fn);
inline BallDyn ball_fold(const BallDyn& iter, const BallDyn& init, const BallDyn& fn);

// ── ball_container_size ──
// Returns the size() of containers; returns 0 for non-container types
// (e.g., when a stub produces `int(0)` as a placeholder).
// Used so _trackMemoryAllocation(ball_container_size(result) * N) compiles
// even when result is an int stub rather than a real string/list.
template<typename T>
inline int64_t ball_container_size(const T& v) {
    if constexpr (requires { v.size(); }) {
        return static_cast<int64_t>(v.size());
    } else {
        return 0LL;
    }
}

// ── List_filled struct ──
// Dart's List.filled(length, value) creates a fixed-length list.
// The compiler emits: List_filled{.__type_args__=..., .arg0=length, .arg1=fill}
// We provide a struct that constructs and acts as a BallList.
struct List_filled {
    std::string __type_args__;
    std::any arg0;  // length
    std::any arg1;  // fill value

    // Length of arg0, unwrapping the BallDyn-in-std::any case (MSVC stores a
    // BallDyn inside std::any rather than its underlying int, so a bare
    // type-check on arg0 misses every int and yields 0 → empty list).
    int64_t _len() const {
        const std::any& a0 = _BallDynUnwrapper::unwrap(arg0);
        if (a0.type() == typeid(int64_t)) return std::any_cast<int64_t>(a0);
        if (a0.type() == typeid(double)) return static_cast<int64_t>(std::any_cast<double>(a0));
        return 0;
    }
    // Convert to a vector<any> of the requested length filled with arg1.
    operator std::vector<std::any>() const {
        int64_t n = _len();
        return std::vector<std::any>(static_cast<size_t>(n < 0 ? 0 : n),
                                     _BallDynUnwrapper::unwrap(arg1));
    }
    // Size query — needed for _trackMemoryAllocation expressions.
    int64_t size() const {
        int64_t n = _len();
        return n < 0 ? 0 : n;
    }
};
// BallDyn overload for List_filled — defined in ball_dyn.h after BallDyn class

// ── Endian constants ──
// Dart's `Endian.little` / `Endian.big` from dart:typed_data.
// Represented as simple bool: true = little-endian, false = big-endian.
struct EndianType {
    bool isLittle;
};
// Dart's `Endian.little` and `Endian.big` are accessed as field accesses on
// the `Endian` reference. The compiled code emits `Endian.little` / `Endian.big`.
// We define a struct with non-static member constants so `Endian.little` works.
struct EndianNamespace_ {
    EndianType little{true};
    EndianType big{false};
    // Dart also has `Endian.host` — use platform endianness.
    EndianType host() const {
        uint16_t test = 1;
        return EndianType{*reinterpret_cast<uint8_t*>(&test) == 1};
    }
};
inline EndianNamespace_ Endian;

// ── BallByteData ──
// Dart's `ByteData` from dart:typed_data — a fixed-size byte buffer with
// typed accessors for reading/writing integers and IEEE 754 floats at
// arbitrary offsets with explicit endianness.
//
// Used by ball_protobuf for binary wire encoding of float/double fields.
struct BallByteData {
    std::vector<uint8_t> _bytes;

    BallByteData() = default;
    explicit BallByteData(int64_t size) : _bytes(static_cast<size_t>(size < 0 ? 0 : size), 0) {}
    BallByteData(const std::any& size_val) {
        int64_t n = 0;
        const std::any& u = _BallDynUnwrapper::unwrap(size_val);
        if (u.type() == typeid(int64_t)) n = std::any_cast<int64_t>(u);
        else if (u.type() == typeid(double)) n = static_cast<int64_t>(std::any_cast<double>(u));
        _bytes.resize(static_cast<size_t>(n < 0 ? 0 : n), 0);
    }

    int64_t lengthInBytes() const { return static_cast<int64_t>(_bytes.size()); }

    // ── Single-byte access ──
    void setUint8(int64_t offset, int64_t value) {
        if (offset >= 0 && static_cast<size_t>(offset) < _bytes.size())
            _bytes[static_cast<size_t>(offset)] = static_cast<uint8_t>(value & 0xFF);
    }
    int64_t getUint8(int64_t offset) const {
        if (offset >= 0 && static_cast<size_t>(offset) < _bytes.size())
            return static_cast<int64_t>(_bytes[static_cast<size_t>(offset)]);
        return 0;
    }

    // ── 16-bit access ──
    void setUint16(int64_t offset, int64_t value, EndianType endian = EndianType{false}) {
        if (offset < 0 || static_cast<size_t>(offset) + 2 > _bytes.size()) return;
        uint16_t v = static_cast<uint16_t>(value);
        if (endian.isLittle) {
            _bytes[offset] = static_cast<uint8_t>(v & 0xFF);
            _bytes[offset + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
        } else {
            _bytes[offset] = static_cast<uint8_t>((v >> 8) & 0xFF);
            _bytes[offset + 1] = static_cast<uint8_t>(v & 0xFF);
        }
    }
    int64_t getUint16(int64_t offset, EndianType endian = EndianType{false}) const {
        if (offset < 0 || static_cast<size_t>(offset) + 2 > _bytes.size()) return 0;
        if (endian.isLittle) {
            return static_cast<int64_t>(_bytes[offset]) |
                   (static_cast<int64_t>(_bytes[offset + 1]) << 8);
        } else {
            return (static_cast<int64_t>(_bytes[offset]) << 8) |
                   static_cast<int64_t>(_bytes[offset + 1]);
        }
    }

    // ── 32-bit unsigned access ──
    void setUint32(int64_t offset, int64_t value, EndianType endian = EndianType{false}) {
        if (offset < 0 || static_cast<size_t>(offset) + 4 > _bytes.size()) return;
        uint32_t v = static_cast<uint32_t>(value);
        if (endian.isLittle) {
            _bytes[offset]     = static_cast<uint8_t>(v & 0xFF);
            _bytes[offset + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
            _bytes[offset + 2] = static_cast<uint8_t>((v >> 16) & 0xFF);
            _bytes[offset + 3] = static_cast<uint8_t>((v >> 24) & 0xFF);
        } else {
            _bytes[offset]     = static_cast<uint8_t>((v >> 24) & 0xFF);
            _bytes[offset + 1] = static_cast<uint8_t>((v >> 16) & 0xFF);
            _bytes[offset + 2] = static_cast<uint8_t>((v >> 8) & 0xFF);
            _bytes[offset + 3] = static_cast<uint8_t>(v & 0xFF);
        }
    }
    int64_t getUint32(int64_t offset, EndianType endian = EndianType{false}) const {
        if (offset < 0 || static_cast<size_t>(offset) + 4 > _bytes.size()) return 0;
        uint32_t v;
        if (endian.isLittle) {
            v = static_cast<uint32_t>(_bytes[offset]) |
                (static_cast<uint32_t>(_bytes[offset + 1]) << 8) |
                (static_cast<uint32_t>(_bytes[offset + 2]) << 16) |
                (static_cast<uint32_t>(_bytes[offset + 3]) << 24);
        } else {
            v = (static_cast<uint32_t>(_bytes[offset]) << 24) |
                (static_cast<uint32_t>(_bytes[offset + 1]) << 16) |
                (static_cast<uint32_t>(_bytes[offset + 2]) << 8) |
                static_cast<uint32_t>(_bytes[offset + 3]);
        }
        return static_cast<int64_t>(v);
    }

    // ── 32-bit signed access ──
    void setInt32(int64_t offset, int64_t value, EndianType endian = EndianType{false}) {
        setUint32(offset, value, endian);
    }
    int64_t getInt32(int64_t offset, EndianType endian = EndianType{false}) const {
        int64_t u = getUint32(offset, endian);
        // Sign-extend from 32 bits
        if (u & 0x80000000LL) u |= ~0xFFFFFFFFLL;
        return u;
    }

    // ── 64-bit unsigned access ──
    void setUint64(int64_t offset, int64_t value, EndianType endian = EndianType{false}) {
        if (offset < 0 || static_cast<size_t>(offset) + 8 > _bytes.size()) return;
        uint64_t v = static_cast<uint64_t>(value);
        if (endian.isLittle) {
            for (int i = 0; i < 8; ++i)
                _bytes[offset + i] = static_cast<uint8_t>((v >> (i * 8)) & 0xFF);
        } else {
            for (int i = 0; i < 8; ++i)
                _bytes[offset + i] = static_cast<uint8_t>((v >> ((7 - i) * 8)) & 0xFF);
        }
    }
    int64_t getUint64(int64_t offset, EndianType endian = EndianType{false}) const {
        if (offset < 0 || static_cast<size_t>(offset) + 8 > _bytes.size()) return 0;
        uint64_t v = 0;
        if (endian.isLittle) {
            for (int i = 0; i < 8; ++i)
                v |= static_cast<uint64_t>(_bytes[offset + i]) << (i * 8);
        } else {
            for (int i = 0; i < 8; ++i)
                v |= static_cast<uint64_t>(_bytes[offset + i]) << ((7 - i) * 8);
        }
        return static_cast<int64_t>(v);
    }

    // ── IEEE 754 float (32-bit) ──
    void setFloat32(int64_t offset, double value, EndianType endian = EndianType{false}) {
        if (offset < 0 || static_cast<size_t>(offset) + 4 > _bytes.size()) return;
        float f = static_cast<float>(value);
        uint8_t raw[4];
        std::memcpy(raw, &f, 4);
        if (endian.isLittle) {
            // Native float is stored in platform endianness; we need little-endian.
            // On little-endian platforms (x86/ARM): raw is already LE.
            // On big-endian platforms: reverse the bytes.
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            _bytes[offset]     = raw[3];
            _bytes[offset + 1] = raw[2];
            _bytes[offset + 2] = raw[1];
            _bytes[offset + 3] = raw[0];
#else
            _bytes[offset]     = raw[0];
            _bytes[offset + 1] = raw[1];
            _bytes[offset + 2] = raw[2];
            _bytes[offset + 3] = raw[3];
#endif
        } else {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            _bytes[offset]     = raw[0];
            _bytes[offset + 1] = raw[1];
            _bytes[offset + 2] = raw[2];
            _bytes[offset + 3] = raw[3];
#else
            _bytes[offset]     = raw[3];
            _bytes[offset + 1] = raw[2];
            _bytes[offset + 2] = raw[1];
            _bytes[offset + 3] = raw[0];
#endif
        }
    }
    double getFloat32(int64_t offset, EndianType endian = EndianType{false}) const {
        if (offset < 0 || static_cast<size_t>(offset) + 4 > _bytes.size()) return 0.0;
        uint8_t raw[4];
        if (endian.isLittle) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            raw[0] = _bytes[offset + 3];
            raw[1] = _bytes[offset + 2];
            raw[2] = _bytes[offset + 1];
            raw[3] = _bytes[offset];
#else
            raw[0] = _bytes[offset];
            raw[1] = _bytes[offset + 1];
            raw[2] = _bytes[offset + 2];
            raw[3] = _bytes[offset + 3];
#endif
        } else {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            raw[0] = _bytes[offset];
            raw[1] = _bytes[offset + 1];
            raw[2] = _bytes[offset + 2];
            raw[3] = _bytes[offset + 3];
#else
            raw[0] = _bytes[offset + 3];
            raw[1] = _bytes[offset + 2];
            raw[2] = _bytes[offset + 1];
            raw[3] = _bytes[offset];
#endif
        }
        float f;
        std::memcpy(&f, raw, 4);
        return static_cast<double>(f);
    }

    // ── IEEE 754 double (64-bit) ──
    void setFloat64(int64_t offset, double value, EndianType endian = EndianType{false}) {
        if (offset < 0 || static_cast<size_t>(offset) + 8 > _bytes.size()) return;
        uint8_t raw[8];
        std::memcpy(raw, &value, 8);
        if (endian.isLittle) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            for (int i = 0; i < 8; ++i) _bytes[offset + i] = raw[7 - i];
#else
            for (int i = 0; i < 8; ++i) _bytes[offset + i] = raw[i];
#endif
        } else {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            for (int i = 0; i < 8; ++i) _bytes[offset + i] = raw[i];
#else
            for (int i = 0; i < 8; ++i) _bytes[offset + i] = raw[7 - i];
#endif
        }
    }
    double getFloat64(int64_t offset, EndianType endian = EndianType{false}) const {
        if (offset < 0 || static_cast<size_t>(offset) + 8 > _bytes.size()) return 0.0;
        uint8_t raw[8];
        if (endian.isLittle) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            for (int i = 0; i < 8; ++i) raw[i] = _bytes[offset + 7 - i];
#else
            for (int i = 0; i < 8; ++i) raw[i] = _bytes[offset + i];
#endif
        } else {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
            for (int i = 0; i < 8; ++i) raw[i] = _bytes[offset + i];
#else
            for (int i = 0; i < 8; ++i) raw[i] = _bytes[offset + 7 - i];
#endif
        }
        double d;
        std::memcpy(&d, raw, 8);
        return d;
    }

    // ── BallDyn overloads for dynamic args ──
    void setUint8(const std::any& offset, const std::any& value) {
        int64_t o = 0, v = 0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        const std::any& vu = _BallDynUnwrapper::unwrap(value);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        if (vu.type() == typeid(int64_t)) v = std::any_cast<int64_t>(vu);
        else if (vu.type() == typeid(double)) v = static_cast<int64_t>(std::any_cast<double>(vu));
        setUint8(o, v);
    }
    int64_t getUint8(const std::any& offset) const {
        int64_t o = 0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        return getUint8(o);
    }
    // Helper: extract EndianType from std::any (supports EndianType directly,
    // or a BallDyn-wrapped EndianType, or a bool isLittle flag).
    static EndianType _endianFromAny(const std::any& e) {
        const std::any& eu = _BallDynUnwrapper::unwrap(e);
        if (eu.type() == typeid(EndianType)) return std::any_cast<EndianType>(eu);
        if (eu.type() == typeid(bool)) return EndianType{std::any_cast<bool>(eu)};
        // Default: big-endian (matches proto wire format)
        return EndianType{false};
    }
    void setFloat32(const std::any& offset, const std::any& value, const std::any& endian) {
        setFloat32(offset, value, _endianFromAny(endian));
    }
    void setFloat32(const std::any& offset, const std::any& value, EndianType endian = EndianType{false}) {
        int64_t o = 0;
        double v = 0.0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        const std::any& vu = _BallDynUnwrapper::unwrap(value);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        if (vu.type() == typeid(double)) v = std::any_cast<double>(vu);
        else if (vu.type() == typeid(int64_t)) v = static_cast<double>(std::any_cast<int64_t>(vu));
        setFloat32(o, v, endian);
    }
    double getFloat32(const std::any& offset, const std::any& endian) const {
        return getFloat32(offset, _endianFromAny(endian));
    }
    double getFloat32(const std::any& offset, EndianType endian = EndianType{false}) const {
        int64_t o = 0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        return getFloat32(o, endian);
    }
    void setFloat64(const std::any& offset, const std::any& value, const std::any& endian) {
        setFloat64(offset, value, _endianFromAny(endian));
    }
    void setFloat64(const std::any& offset, const std::any& value, EndianType endian = EndianType{false}) {
        int64_t o = 0;
        double v = 0.0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        const std::any& vu = _BallDynUnwrapper::unwrap(value);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        if (vu.type() == typeid(double)) v = std::any_cast<double>(vu);
        else if (vu.type() == typeid(int64_t)) v = static_cast<double>(std::any_cast<int64_t>(vu));
        setFloat64(o, v, endian);
    }
    double getFloat64(const std::any& offset, const std::any& endian) const {
        return getFloat64(offset, _endianFromAny(endian));
    }
    double getFloat64(const std::any& offset, EndianType endian = EndianType{false}) const {
        int64_t o = 0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        return getFloat64(o, endian);
    }
    void setUint32(const std::any& offset, const std::any& value, EndianType endian = EndianType{false}) {
        int64_t o = 0, v = 0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        const std::any& vu = _BallDynUnwrapper::unwrap(value);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        if (vu.type() == typeid(int64_t)) v = std::any_cast<int64_t>(vu);
        else if (vu.type() == typeid(double)) v = static_cast<int64_t>(std::any_cast<double>(vu));
        setUint32(o, v, endian);
    }
    int64_t getUint32(const std::any& offset, EndianType endian = EndianType{false}) const {
        int64_t o = 0;
        const std::any& ou = _BallDynUnwrapper::unwrap(offset);
        if (ou.type() == typeid(int64_t)) o = std::any_cast<int64_t>(ou);
        else if (ou.type() == typeid(double)) o = static_cast<int64_t>(std::any_cast<double>(ou));
        return getUint32(o, endian);
    }

    // ── buffer property (mimics Dart's ByteData.buffer) ──
    // In Dart, `byteData.buffer.asUint8List()` returns a Uint8List view.
    // We provide a nested struct with asUint8List() that returns the bytes as
    // a BallList (vector<any> of int64_t byte values).
    struct BufferView {
        const std::vector<uint8_t>& bytes;
        std::vector<std::any> asUint8List() const {
            std::vector<std::any> result;
            result.reserve(bytes.size());
            for (uint8_t b : bytes) result.push_back(std::any(static_cast<int64_t>(b)));
            return result;
        }
        std::vector<std::any> asUint8List(int64_t start, int64_t length) const {
            std::vector<std::any> result;
            size_t end = static_cast<size_t>(start + length);
            if (end > bytes.size()) end = bytes.size();
            for (size_t i = static_cast<size_t>(start); i < end; ++i)
                result.push_back(std::any(static_cast<int64_t>(bytes[i])));
            return result;
        }
    };
    BufferView buffer() const { return BufferView{_bytes}; }
    // Also support direct access pattern: `bd.buffer.asUint8List()` when compiled
    // as a field access chain (the compiler emits `.buffer` then `.asUint8List()`).
    BufferView get_buffer() const { return BufferView{_bytes}; }
};

// Free-function overloads so the compiled code `ByteData(n)` resolves.
// The compiler emits `BallByteData{.arg0 = n}` or `BallByteData(n)`.
inline BallByteData ByteData(int64_t size) { return BallByteData(size); }
inline BallByteData ByteData(const std::any& size) { return BallByteData(size); }

// ── BallObject ──
// Dart: class BallObject extends BallMap { ... }
// BallMap is std::map<std::string, std::any>.  We provide a correct C++
// version where `entries` refers to the base std::map storage via `*this`.
// The compiler skips generating this type (it's in runtime_types).
using BallMap = std::map<std::string, std::any>;
// Coerces a std::any (possibly a BallDyn wrapping a map, due to MSVC's
// BallDyn-in-std::any quirk) into a BallMap. Forward-declared here; defined in
// ball_dyn.h after BallDyn / _BallDynUnwrapper are complete.
BallMap _ballAnyToMap(const std::any& v);
struct BallObject : public BallMap {
    std::string typeName;
    std::any superObject;
    BallMap fields;
    BallMap methods;

    BallObject() = default;
    // Accept std::any for every field so the compiler can pass BallDyn values
    // (which carry maps/strings) without needing per-field BallDyn conversions.
    BallObject(std::any tn,
               std::any super_obj = std::any{},
               std::any flds = std::any{},
               std::any meths = std::any{})
        : typeName(ball_to_string(tn)),
          superObject(std::move(super_obj)),
          fields(_ballAnyToMap(flds)),
          methods(_ballAnyToMap(meths))
    {
        _refreshEntries();
    }

    // `entries` in Dart refers to the Map's own entries (i.e., *this in C++).
    // Methods that set entries do so via (*this)[key] = value.
    BallMap& _refreshEntries() {
        this->clear();
        this->insert(fields.begin(), fields.end());
        (*this)["__type__"] = std::any(typeName);
        (*this)["__super__"] = superObject;
        (*this)["__fields__"] = std::any(fields);
        (*this)["__methods__"] = std::any(methods);
        return *this;
    }

    void setField(const std::string& name, const std::any& value) {
        fields[name] = value;
        (*this)[name] = value;
    }
    void setField(const std::any& name, const std::any& value) {
        setField(ball_to_string(name), value);
    }

    void __op_set_index__(const std::string& key, const std::any& value) {
        if (key == "__super__") {
            superObject = value;
            (*this)[key] = value;
            return;
        }
        if (key == "__methods__") {
            methods.clear();
            if (value.type() == typeid(BallMap)) {
                methods = std::any_cast<const BallMap&>(value);
            }
            (*this)[key] = std::any(methods);
            return;
        }
        if (!key.empty() && !(key.size() >= 2 && key[0] == '_' && key[1] == '_')) {
            fields[key] = value;
        }
        (*this)[key] = value;
    }
    void __op_set_index__(const std::any& key, const std::any& value) {
        __op_set_index__(ball_to_string(key), value);
    }
};

// Reference-semantic OOP instance handle. Mirrors BallListRef: a copied BallDyn
// shares the underlying BallObject, so a setter mutating `self._celsius` is
// visible to every other holder of the instance (the caller's variable, etc.).
// `self` is bound only in the method SCOPE (never as an owning instance-map
// entry), so there is no self-referential cycle.
using BallObjectRef = std::shared_ptr<BallObject>;

// Definitions for the forward-declared accessors used by ball_is_map /
// ball_object_type_matches above. `u` is already an unwrapped std::any.
inline bool _ball_any_is_object(const std::any& u) {
    return u.has_value() &&
           (u.type() == typeid(BallObject) ||
            u.type() == typeid(BallObjectRef) ||
            _BallRefDeref::obj_map(u) != nullptr);
}
inline const std::map<std::string, std::any>* _ball_object_base_map(
    const std::any& u) {
    if (u.has_value() && u.type() == typeid(BallObject)) {
        // BallObject's base IS the field map (refreshed with __type__/__super__).
        return &static_cast<const BallMap&>(std::any_cast<const BallObject&>(u));
    }
    if (u.has_value() && u.type() == typeid(BallObjectRef)) {
        const BallObjectRef& ref = std::any_cast<const BallObjectRef&>(u);
        if (ref) return &static_cast<const BallMap&>(*ref);
    }
    if (const std::map<std::string, std::any>* m = _BallRefDeref::obj_map(u))
        return m;
    return nullptr;
}

#endif  // BALL_EMIT_RUNTIME_H
