// ball_dyn.h -- Dynamic value type for Ball compiled programs.
//
// BallDyn is a JavaScript-like dynamic value type that wraps std::any and
// provides operator overloading for field access, arithmetic, comparison,
// string operations, and iteration. It enables compiled Ball programs that
// use dynamic typing (e.g., the self-hosted Ball engine) to work in C++.
//
// Usage: BallDyn values can hold any type (int64_t, double, std::string,
// bool, vectors, maps, functions, etc.) and support transparent access.

#ifndef BALL_DYN_H
#define BALL_DYN_H

#include <any>
#include <cstdint>
#include <functional>
#include <iostream>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

using BallMap = std::map<std::string, std::any>;
using BallUMap = std::unordered_map<std::string, std::any>;
using BallList = std::vector<std::any>;
using BallFunc = std::function<std::any(std::any)>;

class BallDyn {
public:
    std::any _val;

    // Constructors
    BallDyn() : _val() {}
    BallDyn(std::any v) : _val(std::move(v)) {
        // Auto-unwrap BallDyn-in-std::any to prevent double-wrapping
        if (_val.type() == typeid(BallDyn)) {
            _val = std::any_cast<const BallDyn&>(_val)._val;
        }
    }
    BallDyn(int64_t v) : _val(v) {}
    BallDyn(int v) : _val(static_cast<int64_t>(v)) {}
    BallDyn(double v) : _val(v) {}
    BallDyn(bool v) : _val(v) {}
    BallDyn(const std::string& v) : _val(v) {}
    BallDyn(std::string&& v) : _val(std::move(v)) {}
    BallDyn(const char* v) : _val(std::string(v)) {}
    BallDyn(BallMap v) : _val(std::move(v)) {}
    BallDyn(BallUMap v) : _val(std::move(v)) {}
    BallDyn(BallList v) : _val(std::move(v)) {}
    BallDyn(BallFunc v) : _val(std::move(v)) {}

    // Copy/move
    BallDyn(const BallDyn& o) : _val(o._val) {}
    BallDyn(BallDyn&& o) noexcept : _val(std::move(o._val)) {}
    BallDyn& operator=(const BallDyn& o) { _val = o._val; return *this; }
    BallDyn& operator=(BallDyn&& o) noexcept { _val = std::move(o._val); return *this; }

    // Assign from common types
    BallDyn& operator=(int64_t v) { _val = v; return *this; }
    BallDyn& operator=(int v) { _val = static_cast<int64_t>(v); return *this; }
    BallDyn& operator=(double v) { _val = v; return *this; }
    BallDyn& operator=(bool v) { _val = v; return *this; }
    BallDyn& operator=(const std::string& v) { _val = v; return *this; }
    BallDyn& operator=(const char* v) { _val = std::string(v); return *this; }

    // Implicit conversion to std::any
    operator std::any() const { return _val; }

    // Truthiness (like JavaScript)
    bool has_value() const { return _val.has_value(); }
    explicit operator bool() const {
        if (!_val.has_value()) return false;
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val);
        if (_val.type() == typeid(int64_t)) return std::any_cast<int64_t>(_val) != 0;
        if (_val.type() == typeid(int)) return std::any_cast<int>(_val) != 0;
        if (_val.type() == typeid(double)) return std::any_cast<double>(_val) != 0.0;
        if (_val.type() == typeid(std::string)) return !std::any_cast<const std::string&>(_val).empty();
        return true;  // non-null = truthy
    }

    // Type queries
    const std::type_info& type() const { return _val.type(); }

    // String conversion
    operator std::string() const {
        if (!_val.has_value()) return "null";
        if (_val.type() == typeid(std::string)) return std::any_cast<std::string>(_val);
        if (_val.type() == typeid(const char*)) return std::any_cast<const char*>(_val);
        if (_val.type() == typeid(int64_t)) return std::to_string(std::any_cast<int64_t>(_val));
        if (_val.type() == typeid(int)) return std::to_string(std::any_cast<int>(_val));
        if (_val.type() == typeid(double)) {
            double d = std::any_cast<double>(_val);
            if (d == static_cast<double>(static_cast<long long>(d)))
                return std::to_string(static_cast<long long>(d)) + ".0";
            return std::to_string(d);
        }
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) ? "true" : "false";
        // List: Dart-style [a, b, c]
        if (_val.type() == typeid(BallList)) {
            auto& v = std::any_cast<const BallList&>(_val);
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
        // Map: Dart-style {key: value, ...}
        if (_val.type() == typeid(BallMap)) {
            auto& m = std::any_cast<const BallMap&>(_val);
            std::string out = "{";
            bool first = true;
            for (const auto& [k, v] : m) {
                if (k.find("__") == 0 || k == "type_args") continue;
                if (!first) out += ", ";
                out += k + ": " + ball_to_string(v);
                first = false;
            }
            out += "}";
            return out;
        }
        return "<dynamic>";
    }

    // Numeric conversion
    operator int64_t() const {
        if (_val.type() == typeid(int64_t)) return std::any_cast<int64_t>(_val);
        if (_val.type() == typeid(int)) return std::any_cast<int>(_val);
        if (_val.type() == typeid(double)) return static_cast<int64_t>(std::any_cast<double>(_val));
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) ? 1 : 0;
        return 0;
    }
    operator double() const {
        if (_val.type() == typeid(double)) return std::any_cast<double>(_val);
        if (_val.type() == typeid(int64_t)) return static_cast<double>(std::any_cast<int64_t>(_val));
        if (_val.type() == typeid(int)) return static_cast<double>(std::any_cast<int>(_val));
        return 0.0;
    }

    // Field/index access via operator[]
    // Returns a copy of the field value. For mutation, use the set() method.
    BallDyn operator[](const std::string& key) const {
        if (_val.type() == typeid(BallMap)) {
            auto& m = const_cast<BallMap&>(std::any_cast<const BallMap&>(_val));
            return BallDyn(m[key]);
        }
        if (_val.type() == typeid(BallUMap)) {
            auto& m = const_cast<BallUMap&>(std::any_cast<const BallUMap&>(_val));
            return BallDyn(m[key]);
        }
        return BallDyn();
    }

    // Index access for vectors and strings
    BallDyn operator[](int64_t idx) const {
        if (_val.type() == typeid(BallList)) {
            auto& v = std::any_cast<const BallList&>(_val);
            if (idx >= 0 && static_cast<size_t>(idx) < v.size())
                return BallDyn(v[idx]);
        }
        if (_val.type() == typeid(std::vector<std::string>)) {
            auto& v = std::any_cast<const std::vector<std::string>&>(_val);
            if (idx >= 0 && static_cast<size_t>(idx) < v.size())
                return BallDyn(std::any(v[idx]));
        }
        // String character access (Dart: str[i] returns single-char string)
        if (_val.type() == typeid(std::string)) {
            auto& s = std::any_cast<const std::string&>(_val);
            if (idx >= 0 && static_cast<size_t>(idx) < s.size())
                return BallDyn(std::string(1, s[idx]));
        }
        return BallDyn();
    }

    // Mutation: set a field in the underlying map/list.
    // `obj.set("key", value)` modifies the map entry in-place.
    void set(const std::string& key, const std::any& value) {
        if (_val.type() == typeid(BallMap)) {
            std::any_cast<BallMap&>(_val)[key] = value;
        } else if (_val.type() == typeid(BallUMap)) {
            std::any_cast<BallUMap&>(_val)[key] = value;
        }
    }
    void set(const std::string& key, const BallDyn& value) {
        set(key, value._val);
    }
    void set(int64_t idx, const std::any& value) {
        if (_val.type() == typeid(BallList)) {
            auto& v = std::any_cast<BallList&>(_val);
            if (idx >= 0 && static_cast<size_t>(idx) < v.size())
                v[idx] = value;
        }
    }

    // BallDyn-keyed access: convert key to string and delegate
    BallDyn operator[](const BallDyn& key) const {
        return (*this)[static_cast<std::string>(key)];
    }
    void set(const BallDyn& key, const BallDyn& value) {
        set(static_cast<std::string>(key), value._val);
    }

    // Map operations
    size_t count(const std::string& key) const {
        if (_val.type() == typeid(BallMap))
            return std::any_cast<const BallMap&>(_val).count(key);
        if (_val.type() == typeid(BallUMap))
            return std::any_cast<const BallUMap&>(_val).count(key);
        return 0;
    }

    // Collection operations
    bool empty() const {
        if (!_val.has_value()) return true;
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val).empty();
        if (_val.type() == typeid(BallList)) return std::any_cast<const BallList&>(_val).empty();
        if (_val.type() == typeid(BallMap)) return std::any_cast<const BallMap&>(_val).empty();
        if (_val.type() == typeid(BallUMap)) return std::any_cast<const BallUMap&>(_val).empty();
        return false;
    }

    int64_t size() const {
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val).size();
        if (_val.type() == typeid(BallList)) return std::any_cast<const BallList&>(_val).size();
        if (_val.type() == typeid(BallMap)) return std::any_cast<const BallMap&>(_val).size();
        if (_val.type() == typeid(BallUMap)) return std::any_cast<const BallUMap&>(_val).size();
        return 0;
    }

    void push_back(const BallDyn& v) {
        if (_val.type() == typeid(BallList)) {
            std::any_cast<BallList&>(_val).push_back(v._val);
        }
    }

    BallDyn front() const {
        if (_val.type() == typeid(BallList)) {
            auto& l = std::any_cast<const BallList&>(_val);
            return l.empty() ? BallDyn() : BallDyn(l.front());
        }
        return BallDyn();
    }

    BallDyn back() const {
        if (_val.type() == typeid(BallList)) {
            auto& l = std::any_cast<const BallList&>(_val);
            return l.empty() ? BallDyn() : BallDyn(l.back());
        }
        return BallDyn();
    }

    void erase(const std::string& key) {
        if (_val.type() == typeid(BallMap))
            std::any_cast<BallMap&>(_val).erase(key);
        if (_val.type() == typeid(BallUMap))
            std::any_cast<BallUMap&>(_val).erase(key);
    }

    // String operations
    std::string substr(int64_t pos) const {
        if (_val.type() == typeid(std::string))
            return std::any_cast<const std::string&>(_val).substr(pos);
        return "";
    }
    std::string substr(int64_t pos, int64_t len) const {
        if (_val.type() == typeid(std::string))
            return std::any_cast<const std::string&>(_val).substr(pos, len);
        return "";
    }
    size_t find(const std::string& s, size_t pos = 0) const {
        if (_val.type() == typeid(std::string))
            return std::any_cast<const std::string&>(_val).find(s, pos);
        return std::string::npos;
    }

    // Comparison
    bool operator==(const BallDyn& o) const {
        if (!_val.has_value() && !o._val.has_value()) return true;
        if (!_val.has_value() || !o._val.has_value()) return false;
        if (_val.type() != o._val.type()) return false;
        if (_val.type() == typeid(int64_t)) return std::any_cast<int64_t>(_val) == std::any_cast<int64_t>(o._val);
        if (_val.type() == typeid(double)) return std::any_cast<double>(_val) == std::any_cast<double>(o._val);
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) == std::any_cast<bool>(o._val);
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val) == std::any_cast<const std::string&>(o._val);
        return false;
    }
    bool operator!=(const BallDyn& o) const { return !(*this == o); }
    bool operator==(const std::string& s) const {
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val) == s;
        return false;
    }
    bool operator!=(const std::string& s) const { return !(*this == s); }
    bool operator==(const char* s) const { return *this == std::string(s); }
    bool operator!=(const char* s) const { return !(*this == std::string(s)); }
    bool operator==(int64_t v) const {
        if (_val.type() == typeid(int64_t)) return std::any_cast<int64_t>(_val) == v;
        return false;
    }
    bool operator!=(int64_t v) const { return !(*this == v); }
    bool operator==(int v) const { return *this == static_cast<int64_t>(v); }
    bool operator!=(int v) const { return !(*this == static_cast<int64_t>(v)); }
    bool operator==(bool v) const {
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) == v;
        return false;
    }
    bool operator!=(bool v) const { return !(*this == v); }
    bool operator==(double v) const {
        if (_val.type() == typeid(double)) return std::any_cast<double>(_val) == v;
        return false;
    }
    bool operator!=(double v) const { return !(*this == v); }
    friend bool operator==(const std::string& s, const BallDyn& d) { return d == s; }
    friend bool operator!=(const std::string& s, const BallDyn& d) { return d != s; }
    friend bool operator==(int64_t v, const BallDyn& d) { return d == v; }
    friend bool operator!=(int64_t v, const BallDyn& d) { return d != v; }

    // Arithmetic operators for BallDyn
    BallDyn operator+(const BallDyn& o) const {
        // String concatenation
        if (_val.type() == typeid(std::string) || o._val.type() == typeid(std::string))
            return BallDyn(static_cast<std::string>(*this) + static_cast<std::string>(o));
        // Integer arithmetic
        if (_val.type() == typeid(int64_t) && o._val.type() == typeid(int64_t))
            return BallDyn(std::any_cast<int64_t>(_val) + std::any_cast<int64_t>(o._val));
        // Double arithmetic
        return BallDyn(static_cast<double>(*this) + static_cast<double>(o));
    }
    BallDyn operator-(const BallDyn& o) const {
        if (_val.type() == typeid(int64_t) && o._val.type() == typeid(int64_t))
            return BallDyn(std::any_cast<int64_t>(_val) - std::any_cast<int64_t>(o._val));
        return BallDyn(static_cast<double>(*this) - static_cast<double>(o));
    }
    BallDyn operator*(const BallDyn& o) const {
        if (_val.type() == typeid(int64_t) && o._val.type() == typeid(int64_t))
            return BallDyn(std::any_cast<int64_t>(_val) * std::any_cast<int64_t>(o._val));
        return BallDyn(static_cast<double>(*this) * static_cast<double>(o));
    }
    BallDyn operator/(const BallDyn& o) const {
        return BallDyn(static_cast<double>(*this) / static_cast<double>(o));
    }
    BallDyn operator%(const BallDyn& o) const {
        if (_val.type() == typeid(int64_t) && o._val.type() == typeid(int64_t))
            return BallDyn(std::any_cast<int64_t>(_val) % std::any_cast<int64_t>(o._val));
        return BallDyn(static_cast<int64_t>(static_cast<double>(*this)) %
                       static_cast<int64_t>(static_cast<double>(o)));
    }
    BallDyn operator-() const {
        if (_val.type() == typeid(int64_t)) return BallDyn(-std::any_cast<int64_t>(_val));
        if (_val.type() == typeid(double)) return BallDyn(-std::any_cast<double>(_val));
        return BallDyn();
    }
    // Comparison operators for ordering
    bool operator<(const BallDyn& o) const {
        if (_val.type() == typeid(int64_t) && o._val.type() == typeid(int64_t))
            return std::any_cast<int64_t>(_val) < std::any_cast<int64_t>(o._val);
        if (_val.type() == typeid(std::string) && o._val.type() == typeid(std::string))
            return std::any_cast<const std::string&>(_val) < std::any_cast<const std::string&>(o._val);
        return static_cast<double>(*this) < static_cast<double>(o);
    }
    bool operator>(const BallDyn& o) const { return o < *this; }
    bool operator<=(const BallDyn& o) const { return !(o < *this); }
    bool operator>=(const BallDyn& o) const { return !(*this < o); }

    // Arithmetic with int64_t
    BallDyn operator+(int64_t v) const {
        if (_val.type() == typeid(int64_t)) return BallDyn(std::any_cast<int64_t>(_val) + v);
        return BallDyn(static_cast<double>(*this) + v);
    }
    BallDyn operator-(int64_t v) const {
        if (_val.type() == typeid(int64_t)) return BallDyn(std::any_cast<int64_t>(_val) - v);
        return BallDyn(static_cast<double>(*this) - v);
    }
    friend BallDyn operator+(int64_t v, const BallDyn& d) { return d + v; }

    // String field access (Dart protobuf style: e.g. literal.stringValue)
    // Returns the value as a string, or empty if not a string.
    BallDyn __get_stringValue() const {
        // For protobuf-style access: obj["stringValue"] already works via operator[].
        // This is a convenience for `.stringValue` field access syntax.
        return (*this)["stringValue"s];
    }

    // indexOf: find an element in a BallDyn list, or a substring in a string.
    int64_t indexOf(const BallDyn& needle) const {
        if (_val.type() == typeid(BallList)) {
            auto& v = std::any_cast<const BallList&>(_val);
            for (size_t i = 0; i < v.size(); i++) {
                BallDyn el(v[i]);
                if (el == needle) return static_cast<int64_t>(i);
            }
            return -1;
        }
        if (_val.type() == typeid(std::string) && needle._val.type() == typeid(std::string)) {
            auto& s = std::any_cast<const std::string&>(_val);
            auto& n = std::any_cast<const std::string&>(needle._val);
            auto pos = s.find(n);
            return pos == std::string::npos ? -1 : static_cast<int64_t>(pos);
        }
        return -1;
    }

    // Iteration support (for range-based for loops over lists)
    struct Iterator {
        const BallList* list;
        size_t idx;
        BallDyn operator*() const { return BallDyn((*list)[idx]); }
        Iterator& operator++() { ++idx; return *this; }
        bool operator!=(const Iterator& o) const { return idx != o.idx; }
    };
    Iterator begin() const {
        if (_val.type() == typeid(BallList)) {
            auto& l = std::any_cast<const BallList&>(_val);
            return {&l, 0};
        }
        static BallList empty;
        return {&empty, 0};
    }
    Iterator end() const {
        if (_val.type() == typeid(BallList)) {
            auto& l = std::any_cast<const BallList&>(_val);
            return {&l, l.size()};
        }
        static BallList empty;
        return {&empty, 0};
    }

    // Function call
    BallDyn operator()(const BallDyn& arg) const {
        if (_val.type() == typeid(BallFunc)) {
            return BallDyn(std::any_cast<const BallFunc&>(_val)(arg._val));
        }
        return BallDyn();
    }
};

// Stream output
inline std::ostream& operator<<(std::ostream& os, const BallDyn& d) {
    return os << static_cast<std::string>(d);
}

// ball_to_string overload for BallDyn
inline std::string ball_to_string(const BallDyn& d) {
    return static_cast<std::string>(d);
}

// bind/child/resolve overloads for BallDyn
inline void bind(BallDyn& scope, const std::any& name, const std::any& value) {
    scope.set(ball_to_string(name), value);
}
inline void bind(BallDyn& scope, const BallDyn& name, const BallDyn& value) {
    scope.set(static_cast<std::string>(name), value._val);
}
inline BallDyn child(const BallDyn& scope) {
    BallMap newScope;
    newScope["__parent__"] = scope._val;
    return BallDyn(newScope);
}
inline std::any resolve(const BallDyn& scope, const std::string& name) {
    return resolve(scope._val, name);
}
// nextDouble overload for BallDyn (wrapping RandomType)
inline double nextDouble(const BallDyn&) {
    static RandomType fallback_random;
    return nextDouble(fallback_random);
}
inline int64_t nextInt(const BallDyn&, int64_t max_) {
    static RandomType fallback_random;
    return nextInt(fallback_random, max_);
}
inline int64_t nextInt(const BallDyn& r, const BallDyn& max_) {
    return nextInt(r, static_cast<int64_t>(max_));
}

// ── Self-hosted engine type stubs ──
// Types from the Dart Ball engine that are compiled to C++ but lack
// protobuf descriptors (so the compiler can't emit their struct bodies).
// Defined here as BallDyn wrappers so they inherit all BallDyn operations.
// Macro for defining a BallDyn-derived stub type with all constructors.
#define BALL_DYN_STUB(Name) \
    struct Name : public BallDyn { \
        using BallDyn::BallDyn; \
        using BallDyn::operator=; \
        Name() : BallDyn() {} \
        Name(const BallDyn& d) : BallDyn(d) {} \
        Name(BallDyn&& d) : BallDyn(std::move(d)) {} \
        Name& operator=(const BallDyn& d) { BallDyn::operator=(d); return *this; } \
    }

BALL_DYN_STUB(_FlowSignal);
BALL_DYN_STUB(_Scope);
BALL_DYN_STUB(BallRuntimeError);
BALL_DYN_STUB(BallFuture);
BALL_DYN_STUB(BallGenerator);
BALL_DYN_STUB(_ExitSignal);
BALL_DYN_STUB(BallModuleHandler);
BALL_DYN_STUB(StdModuleHandler);

#undef BALL_DYN_STUB

// ── ball_where / ball_map overloads for BallDyn ──
template<typename F>
inline BallList ball_where(const BallDyn& v, F pred) {
    BallList result;
    for (auto it = v.begin(); it != v.end(); ++it) {
        BallDyn el = *it;
        if (pred(el._val)) result.push_back(el._val);
    }
    return result;
}
template<typename F>
inline BallList ball_map(const BallDyn& v, F fn) {
    BallList result;
    for (auto it = v.begin(); it != v.end(); ++it) {
        BallDyn el = *it;
        result.push_back(fn(el._val));
    }
    return result;
}

// ball_set specialization for BallDyn — uses .set() method
// since BallDyn::operator[] returns by value.
template<>
inline void ball_set<BallDyn>(BallDyn& obj, const std::string& key, const std::any& value) {
    obj.set(key, value);
}
template<>
inline void ball_set<BallDyn>(BallDyn& obj, int64_t idx, const std::any& value) {
    obj.set(idx, value);
}
// ball_set with BallDyn value
inline void ball_set(BallDyn& obj, const std::string& key, const BallDyn& value) {
    obj.set(key, value._val);
}
inline void ball_set(BallDyn& obj, const BallDyn& key, const BallDyn& value) {
    obj.set(static_cast<std::string>(key), value._val);
}
// ball_set for std::map with BallDyn key
inline void ball_set(std::map<std::string, std::any>& m, const BallDyn& key, const std::any& value) {
    m[static_cast<std::string>(key)] = value;
}
inline void ball_set(std::unordered_map<std::string, std::any>& m, const BallDyn& key, const std::any& value) {
    m[static_cast<std::string>(key)] = value;
}

// String concatenation
inline std::string operator+(const std::string& s, const BallDyn& d) {
    return s + static_cast<std::string>(d);
}
inline std::string operator+(const BallDyn& d, const std::string& s) {
    return static_cast<std::string>(d) + s;
}

#endif  // BALL_DYN_H
