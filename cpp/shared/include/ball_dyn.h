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
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

using BallMap = std::map<std::string, std::any>;
using BallUMap = std::unordered_map<std::string, std::any>;
using BallList = std::vector<std::any>;
using BallFunc = std::function<std::any(std::any)>;
// BallScope: shared-pointer-based scope for reference semantics in scope chains.
// Scopes created via child() use this so parent mutations are visible to children.
using BallScope = std::shared_ptr<BallMap>;

class BallDyn {
public:
    std::any _val;

    // Constructors
    BallDyn() : _val() {}
    BallDyn(std::any v) : _val(std::move(v)) {
        // Recursively unwrap nested BallDyn to prevent double-wrapping.
        // e.g. std::any(BallDyn(std::any(BallDyn(x)))) -> x
        while (_val.type() == typeid(BallDyn)) {
            _val = std::any_cast<const BallDyn&>(_val)._val;
        }
    }
    // Constructor from callable (wraps as BallFunc for std::any storage)
    template<typename F, std::enable_if_t<
        !std::is_same_v<std::decay_t<F>, BallDyn> &&
        !std::is_same_v<std::decay_t<F>, std::any> &&
        !std::is_same_v<std::decay_t<F>, BallFunc> &&
        !std::is_same_v<std::decay_t<F>, const char*> &&
        !std::is_same_v<std::decay_t<F>, std::string> &&
        !std::is_arithmetic_v<std::decay_t<F>> &&
        !std::is_same_v<std::decay_t<F>, BallMap> &&
        !std::is_same_v<std::decay_t<F>, BallList> &&
        !std::is_same_v<std::decay_t<F>, std::regex> &&
        !std::is_base_of_v<BallDyn, std::decay_t<F>> &&
        std::is_class_v<std::decay_t<F>> &&
        (std::is_invocable_v<std::decay_t<F>, std::any> ||
         std::is_invocable_v<std::decay_t<F>, BallDyn>), int> = 0>
    BallDyn(F&& f) {
        _val = BallFunc([fn = std::forward<F>(f)](std::any arg) mutable -> std::any {
            if constexpr (std::is_invocable_v<std::decay_t<F>, std::any>) {
                if constexpr (std::is_void_v<std::invoke_result_t<std::decay_t<F>, std::any>>) {
                    fn(arg);
                    return std::any{};
                } else {
                    return std::any(fn(arg));
                }
            } else if constexpr (std::is_void_v<std::invoke_result_t<std::decay_t<F>, BallDyn>>) {
                fn(BallDyn(arg));
                return std::any{};
            } else {
                return std::any(BallDyn(fn(BallDyn(arg)))._val);
            }
        });
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

    // Copy/move — BallScope (shared_ptr<BallMap>) deep-copies ONLY when the scope
    // has NO __parent__ key (i.e., it's a root/function scope being copied for a
    // new function call). Scopes WITH __parent__ (child scopes) share via shared_ptr
    // to maintain parent-child reference links.
    BallDyn(const BallDyn& o) : _val(o._val) {
        if (_val.type() == typeid(BallScope)) {
            auto& sp = std::any_cast<const BallScope&>(_val);
            // Deep-copy root scopes (no __parent__) to prevent function param leakage.
            // Child scopes (with __parent__) keep sharing for reference semantics.
            if (sp && sp->find("__parent__") == sp->end()) {
                _val = std::any(std::make_shared<BallMap>(*sp));
            }
        }
    }
    BallDyn(BallDyn&& o) noexcept : _val(std::move(o._val)) {}
    BallDyn& operator=(const BallDyn& o) {
        _val = o._val;
        if (_val.type() == typeid(BallScope)) {
            auto& sp = std::any_cast<const BallScope&>(_val);
            if (sp && sp->find("__parent__") == sp->end()) {
                _val = std::any(std::make_shared<BallMap>(*sp));
            }
        }
        return *this;
    }
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
    // Conversion to size_t (for substr etc.)
    operator size_t() const { return static_cast<size_t>(static_cast<int64_t>(*this)); }

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
        // Map/Scope: Dart-style {key: value, ...}
        if (_val.type() == typeid(BallScope)) {
            auto& sp = std::any_cast<const BallScope&>(_val);
            std::string out = "{";
            bool first = true;
            for (const auto& [k, v] : *sp) {
                if (k.find("__") == 0 || k == "type_args") continue;
                if (!first) out += ", ";
                out += k + ": " + ball_to_string(v);
                first = false;
            }
            out += "}";
            return out;
        }
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
        if (_val.type() == typeid(BallScope)) {
            auto& sp = std::any_cast<const BallScope&>(_val);
            auto it = sp->find(key);
            if (it != sp->end()) return BallDyn(it->second);
            return BallDyn();
        }
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
        if (_val.type() == typeid(BallScope)) {
            (*std::any_cast<BallScope&>(_val))[key] = value;
        } else if (_val.type() == typeid(BallMap)) {
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
        if (_val.type() == typeid(BallScope))
            return std::any_cast<const BallScope&>(_val)->count(key);
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
        if (_val.type() == typeid(BallScope)) return std::any_cast<const BallScope&>(_val)->empty();
        if (_val.type() == typeid(BallMap)) return std::any_cast<const BallMap&>(_val).empty();
        if (_val.type() == typeid(BallUMap)) return std::any_cast<const BallUMap&>(_val).empty();
        return false;
    }

    int64_t size() const {
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val).size();
        if (_val.type() == typeid(BallList)) return std::any_cast<const BallList&>(_val).size();
        if (_val.type() == typeid(BallScope)) return std::any_cast<const BallScope&>(_val)->size();
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
        if (_val.type() == typeid(BallScope))
            std::any_cast<BallScope&>(_val)->erase(key);
        else if (_val.type() == typeid(BallMap))
            std::any_cast<BallMap&>(_val).erase(key);
        else if (_val.type() == typeid(BallUMap))
            std::any_cast<BallUMap&>(_val).erase(key);
    }
    void push_back(const std::any& val) {
        if (_val.type() == typeid(BallList)) {
            std::any_cast<BallList&>(_val).push_back(val);
        }
    }
    void pop_back() {
        if (_val.type() == typeid(BallList)) {
            auto& v = std::any_cast<BallList&>(_val);
            if (!v.empty()) v.pop_back();
        }
    }
    void erase(const BallDyn& val) {
        if (_val.type() == typeid(BallList)) {
            auto& v = std::any_cast<BallList&>(_val);
            auto s = ball_to_string(val._val);
            v.erase(std::remove_if(v.begin(), v.end(), [&](const std::any& x) {
                return ball_to_string(x) == s;
            }), v.end());
        } else if (_val.type() == typeid(BallMap)) {
            std::any_cast<BallMap&>(_val).erase(static_cast<std::string>(val));
        }
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
        if (_val.type() == typeid(int64_t) && o._val.type() == typeid(int64_t))
            return BallDyn(std::any_cast<int64_t>(_val) / std::any_cast<int64_t>(o._val));
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
    BallDyn operator*(int64_t v) const {
        if (_val.type() == typeid(int64_t)) return BallDyn(std::any_cast<int64_t>(_val) * v);
        return BallDyn(static_cast<double>(*this) * v);
    }
    BallDyn operator/(int64_t v) const {
        if (_val.type() == typeid(int64_t)) return BallDyn(std::any_cast<int64_t>(_val) / v);
        return BallDyn(static_cast<double>(*this) / v);
    }
    BallDyn operator%(int64_t v) const {
        if (_val.type() == typeid(int64_t)) return BallDyn(std::any_cast<int64_t>(_val) % v);
        return BallDyn(static_cast<int64_t>(static_cast<double>(*this)) % v);
    }
    BallDyn operator/(double v) const {
        return BallDyn(static_cast<double>(*this) / v);
    }
    friend BallDyn operator+(int64_t v, const BallDyn& d) { return d + v; }
    friend BallDyn operator-(int64_t v, const BallDyn& d) { return BallDyn(v) - d; }
    friend BallDyn operator*(int64_t v, const BallDyn& d) { return d * v; }
    friend BallDyn operator/(int64_t v, const BallDyn& d) { return BallDyn(v) / d; }
    friend BallDyn operator/(double v, const BallDyn& d) { return BallDyn(v / static_cast<double>(d)); }
    friend BallDyn operator%(int64_t v, const BallDyn& d) { return BallDyn(v) % d; }

    // Comparison with int64_t
    bool operator<(int64_t v) const { return *this < BallDyn(v); }
    bool operator>(int64_t v) const { return *this > BallDyn(v); }
    bool operator<=(int64_t v) const { return *this <= BallDyn(v); }
    bool operator>=(int64_t v) const { return *this >= BallDyn(v); }
    friend bool operator<(int64_t v, const BallDyn& d) { return BallDyn(v) < d; }
    friend bool operator>(int64_t v, const BallDyn& d) { return BallDyn(v) > d; }

    // Increment/decrement
    BallDyn& operator++() {
        if (_val.type() == typeid(int64_t)) _val = std::any_cast<int64_t>(_val) + 1;
        else if (_val.type() == typeid(double)) _val = std::any_cast<double>(_val) + 1.0;
        return *this;
    }
    BallDyn operator++(int) { auto old = *this; ++(*this); return old; }
    BallDyn& operator--() {
        if (_val.type() == typeid(int64_t)) _val = std::any_cast<int64_t>(_val) - 1;
        else if (_val.type() == typeid(double)) _val = std::any_cast<double>(_val) - 1.0;
        return *this;
    }
    BallDyn operator--(int) { auto old = *this; --(*this); return old; }

    // Bitwise operators
    BallDyn operator&(const BallDyn& o) const { return BallDyn(static_cast<int64_t>(*this) & static_cast<int64_t>(o)); }
    BallDyn operator|(const BallDyn& o) const { return BallDyn(static_cast<int64_t>(*this) | static_cast<int64_t>(o)); }
    BallDyn operator^(const BallDyn& o) const { return BallDyn(static_cast<int64_t>(*this) ^ static_cast<int64_t>(o)); }
    BallDyn operator~() const { return BallDyn(~static_cast<int64_t>(*this)); }
    BallDyn operator<<(const BallDyn& o) const { return BallDyn(static_cast<int64_t>(*this) << static_cast<int64_t>(o)); }
    BallDyn operator>>(const BallDyn& o) const { return BallDyn(static_cast<int64_t>(*this) >> static_cast<int64_t>(o)); }
    BallDyn operator&(int64_t v) const { return BallDyn(static_cast<int64_t>(*this) & v); }
    BallDyn operator|(int64_t v) const { return BallDyn(static_cast<int64_t>(*this) | v); }
    BallDyn operator^(int64_t v) const { return BallDyn(static_cast<int64_t>(*this) ^ v); }
    BallDyn operator<<(int64_t v) const { return BallDyn(static_cast<int64_t>(*this) << v); }
    BallDyn operator>>(int64_t v) const { return BallDyn(static_cast<int64_t>(*this) >> v); }

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
    BallDyn operator()() const {
        if (_val.type() == typeid(BallFunc)) {
            return BallDyn(std::any_cast<const BallFunc&>(_val)(std::any{}));
        }
        return BallDyn();
    }
    BallDyn operator()(const BallDyn& arg) const {
        if (_val.type() == typeid(BallFunc)) {
            return BallDyn(std::any_cast<const BallFunc&>(_val)(arg._val));
        }
        return BallDyn();
    }
};

// Register BallDyn unwrapper so ball_is_* functions can detect BallDyn
// stored inside std::any (MSVC implicit conversion issue).
namespace {
struct _BallDynUnwrapRegistrar {
    _BallDynUnwrapRegistrar() {
        _BallDynUnwrapper::_unwrap_fn = [](const std::any& v) -> const std::any* {
            if (v.type() == typeid(BallDyn)) {
                return &std::any_cast<const BallDyn&>(v)._val;
            }
            return nullptr;
        };
        // Registration complete - ball_is_* functions can now detect BallDyn in std::any
    }
};
static _BallDynUnwrapRegistrar _ball_dyn_unwrap_registrar;
}

// Stream output
inline std::ostream& operator<<(std::ostream& os, const BallDyn& d) {
    return os << static_cast<std::string>(d);
}

// ball_to_string overload for BallDyn
inline std::string ball_to_string(const BallDyn& d) {
    return static_cast<std::string>(d);
}

// Allow std::regex(BallDyn) by providing conversion helper
inline std::regex ball_to_regex(const BallDyn& d) { return std::regex(ball_to_string(d)); }
inline std::regex ball_to_regex(const std::string& s) { return std::regex(s); }
inline const std::regex& ball_to_regex(const std::regex& r) { return r; }
// Alias for Dart's RegExp constructor — returns BallDyn wrapping the string
// so it can be used both as regex (via ball_to_regex) and as string
inline BallDyn RegExp(const BallDyn& d) { return d; }
inline BallDyn RegExp(const std::string& s) { return BallDyn(s); }

// Regex overloads for BallDyn
inline std::any ball_first_match(const BallDyn& pattern, const BallDyn& input) {
    return ball_first_match(std::regex(ball_to_string(pattern)), ball_to_string(input));
}
inline std::any ball_first_match(const std::regex& re, const BallDyn& input) {
    return ball_first_match(re, ball_to_string(input));
}
inline std::vector<std::any> ball_all_matches(const BallDyn& pattern, const BallDyn& input) {
    return ball_all_matches(std::regex(ball_to_string(pattern)), ball_to_string(input));
}
inline std::vector<std::any> ball_all_matches(const std::regex& re, const BallDyn& input) {
    return ball_all_matches(re, ball_to_string(input));
}
inline std::string ball_group(const BallDyn& match, int64_t idx) {
    return ball_group(match._val, idx);
}

// bind/child/resolve overloads for BallDyn
inline BallDyn bind(BallDyn& scope, const std::any& name, const std::any& value) {
    scope.set(ball_to_string(name), value);
    return BallDyn();
}
inline BallDyn bind(BallDyn& scope, const BallDyn& name, const BallDyn& value) {
    scope.set(static_cast<std::string>(name), value._val);
    return BallDyn();
}
// child() creates a new scope linked to the parent with reference semantics.
// The parent is "upgraded" to BallScope (shared_ptr<BallMap>) on first use,
// so that parent mutations are visible through the child's __parent__ link.
inline BallDyn child(BallDyn& scope) {
    // Ensure the parent uses BallScope (shared_ptr<BallMap>) for reference semantics
    if (scope._val.type() == typeid(BallMap)) {
        // Upgrade: move the BallMap content into a shared_ptr
        auto sp = std::make_shared<BallMap>(std::move(std::any_cast<BallMap&>(scope._val)));
        scope._val = std::any(sp);
    }
    // Now scope._val is BallScope — extract the shared_ptr
    BallScope parentScope;
    if (scope._val.type() == typeid(BallScope)) {
        parentScope = std::any_cast<const BallScope&>(scope._val);
    }
    // Create child scope backed by BallScope
    auto childMap = std::make_shared<BallMap>();
    if (parentScope) {
        (*childMap)["__parent__"] = std::any(parentScope);
    }
    return BallDyn(std::any(childMap));
}
// const overload for cases where the parent can't be upgraded (read-only)
inline BallDyn child(const BallDyn& scope) {
    if (scope._val.type() == typeid(BallScope)) {
        auto parentScope = std::any_cast<const BallScope&>(scope._val);
        auto childMap = std::make_shared<BallMap>();
        (*childMap)["__parent__"] = std::any(parentScope);
        return BallDyn(std::any(childMap));
    }
    // Fallback: copy-based (legacy behavior)
    BallMap newScope;
    newScope["__parent__"] = scope._val;
    return BallDyn(newScope);
}

// Helper: get the parent BallScope from a scope's __parent__ entry.
// Returns the shared_ptr (or empty if not found).
inline BallScope _ball_get_parent_scope(const BallDyn& scope) {
    BallMap* m = nullptr;
    if (scope._val.type() == typeid(BallScope)) {
        m = std::any_cast<const BallScope&>(scope._val).get();
    } else if (scope._val.type() == typeid(BallMap)) {
        m = &const_cast<BallMap&>(std::any_cast<const BallMap&>(scope._val));
    }
    if (!m) return nullptr;
    auto it = m->find("__parent__");
    if (it == m->end()) return nullptr;
    if (it->second.type() == typeid(BallScope)) {
        return std::any_cast<const BallScope&>(it->second);
    }
    return nullptr;
}

// Helper: check if a key exists in a scope (without inserting default entry)
inline bool _ball_scope_has_key(const BallDyn& scope, const std::string& key) {
    if (scope._val.type() == typeid(BallScope)) {
        auto& sp = std::any_cast<const BallScope&>(scope._val);
        return sp->count(key) > 0;
    }
    if (scope._val.type() == typeid(BallMap)) {
        return std::any_cast<const BallMap&>(scope._val).count(key) > 0;
    }
    return false;
}

// Helper: mutate a key in a scope's underlying BallMap
inline void _ball_scope_set(const BallDyn& scope, const std::string& key, const std::any& value) {
    if (scope._val.type() == typeid(BallScope)) {
        (*std::any_cast<const BallScope&>(scope._val))[key] = value;
    }
    // BallMap case handled by BallDyn::set()
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
    // Unwrap BallDyn stored in std::any (MSVC wrapping issue)
    auto& u = _BallDynUnwrapper::unwrap(value);
    obj.set(key, u);
}
template<>
inline void ball_set<BallDyn>(BallDyn& obj, int64_t idx, const std::any& value) {
    auto& u = _BallDynUnwrapper::unwrap(value);
    obj.set(idx, u);
}
// ball_set accepting temporary BallDyn (modifies a copy — use for side-effect contexts)
inline void ball_set(BallDyn&& obj, const std::string& key, const std::any& value) {
    auto& u = _BallDynUnwrapper::unwrap(value);
    obj.set(key, u);
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
    auto& u = _BallDynUnwrapper::unwrap(value);
    m[static_cast<std::string>(key)] = u;
}
inline void ball_set(std::unordered_map<std::string, std::any>& m, const BallDyn& key, const std::any& value) {
    auto& u = _BallDynUnwrapper::unwrap(value);
    m[static_cast<std::string>(key)] = u;
}

// ball_is_* BallDyn overloads are in the C++ compiler preamble only
// (to avoid ambiguity with the native engine)

// ── handles/call for module handlers (override stubs from ball_emit_runtime.h) ──
inline bool handles(const BallDyn& handler, const BallDyn& module) {
    auto mod = ball_to_string(BallDyn(module));
    return mod == "std" || mod == "dart_std" || mod == "std_collections" ||
           mod == "std_io" || mod == "std_memory" || mod == "std_convert" ||
           mod == "std_fs" || mod == "std_time" || mod == "std_concurrency" ||
           mod == "cpp_std" || mod.empty();
}
template<typename E>
inline BallDyn call(const BallDyn& handler, const BallDyn& function, const BallDyn& input, E&& engine_fn) {
    auto fn = ball_to_string(BallDyn(function));
    auto dispatch = handler["_dispatch"s];
    if (dispatch.has_value()) {
        auto func = dispatch[fn];
        if (func.has_value()) return func(input);
    }
    throw std::runtime_error("Unknown std function: " + fn);
}


// 3-arg set() — Dart's scope.set(name, val) compiled as free function.
// Mirrors Dart _Scope.set(): if the variable exists in the current scope,
// update it there. Otherwise walk the parent chain (via BallScope shared_ptr)
// to find the scope that owns it and update in-place. If not found anywhere,
// bind in the current scope.
inline BallDyn set(BallDyn& scope, const BallDyn& name, const BallDyn& value) {
    auto key = static_cast<std::string>(name);
    // Check if current scope has the key (without inserting)
    if (_ball_scope_has_key(scope, key)) {
        scope.set(key, value._val);
        return BallDyn();
    }
    // Walk parent chain via BallScope (shared_ptr<BallMap>) for mutable access
    BallScope parent = _ball_get_parent_scope(scope);
    while (parent) {
        if (parent->count(key) > 0) {
            (*parent)[key] = value._val;
            return BallDyn();
        }
        // Get next parent
        auto it = parent->find("__parent__");
        if (it != parent->end() && it->second.type() == typeid(BallScope)) {
            parent = std::any_cast<const BallScope&>(it->second);
        } else {
            break;
        }
    }
    // Not found in any parent — create in current scope
    scope.set(key, value._val);
    return BallDyn();
}
inline std::any set(std::any& scope, const std::any& name, const std::any& value) {
    if (scope.type() == typeid(BallMap)) {
        std::any_cast<BallMap&>(scope)[ball_to_string(name)] = value;
    }
    return std::any{};
}

// identical — Dart's identity comparison
inline bool identical(const BallDyn& a, const BallDyn& b) { return a == b; }
inline bool identical(const std::any& a, const std::any& b) { return ball_to_string(a) == ball_to_string(b); }

// File/Directory constructors from BallDyn
inline File::File(const BallDyn& p) : path(ball_to_string(p)) {}
inline Directory::Directory(const BallDyn& p) : path(ball_to_string(p)) {}
inline void writeAsStringSync(const File& f, const BallDyn& content, const std::any&) {
    std::ofstream ofs(f.path);
    ofs << ball_to_string(content);
}

// setAll — Dart's List.setAll(index, iterable): copy elements into list
inline void setAll(BallDyn& target, int64_t index, const BallDyn& source) {
    if (target._val.type() == typeid(BallList) && source._val.type() == typeid(BallList)) {
        auto& dst = std::any_cast<BallList&>(target._val);
        auto& src = std::any_cast<const BallList&>(source._val);
        for (size_t i = 0; i < src.size() && (index + i) < dst.size(); i++) {
            dst[index + i] = src[i];
        }
    }
}

// String substr helper — handles BallDyn args for length
inline std::string ball_substr(const std::string& s, int64_t pos, const BallDyn& len = BallDyn()) {
    if (len.has_value()) return s.substr(pos, static_cast<size_t>(static_cast<int64_t>(len)));
    return s.substr(pos);
}

// String concatenation
inline std::string operator+(const std::string& s, const BallDyn& d) {
    return s + static_cast<std::string>(d);
}
inline std::string operator+(const BallDyn& d, const std::string& s) {
    return static_cast<std::string>(d) + s;
}

// ── Codec BallDyn overloads ──
inline std::vector<std::any> encode(const Utf8Codec& c, const BallDyn& s) {
    return c.encode(static_cast<std::string>(s));
}
inline std::string decode(const Utf8Codec& c, const BallDyn& bytes) {
    if (bytes._val.type() == typeid(BallList))
        return c.decode(std::any_cast<const BallList&>(bytes._val));
    return "";
}
inline std::string encode(const Base64Codec& c, const BallDyn& bytes) {
    if (bytes._val.type() == typeid(BallList))
        return c.encode(std::any_cast<const BallList&>(bytes._val));
    return "";
}
inline std::vector<std::any> decode(const Base64Codec& c, const BallDyn& s) {
    return c.decode(static_cast<std::string>(s));
}

// ── ball_to_set(BallDyn) ──
inline BallDyn ball_to_set(const BallDyn& d) {
    if (d._val.type() == typeid(BallList)) {
        return BallDyn(ball_to_set(std::any_cast<const BallList&>(d._val)));
    }
    return d;
}

// ── Set operations on BallDyn ──
inline BallDyn union_(const BallDyn& a, const BallDyn& b) {
    BallList sa, sb;
    if (a._val.type() == typeid(BallList)) sa = std::any_cast<const BallList&>(a._val);
    if (b._val.type() == typeid(BallList)) sb = std::any_cast<const BallList&>(b._val);
    for (auto& e : sb) {
        bool found = false;
        for (auto& x : sa) { if (ball_to_string(x) == ball_to_string(e)) { found = true; break; } }
        if (!found) sa.push_back(e);
    }
    return BallDyn(sa);
}
inline BallDyn intersection(const BallDyn& a, const BallDyn& b) {
    BallList sa, sb;
    if (a._val.type() == typeid(BallList)) sa = std::any_cast<const BallList&>(a._val);
    if (b._val.type() == typeid(BallList)) sb = std::any_cast<const BallList&>(b._val);
    BallList result;
    for (auto& e : sa) {
        for (auto& x : sb) { if (ball_to_string(x) == ball_to_string(e)) { result.push_back(e); break; } }
    }
    return BallDyn(result);
}
inline BallDyn difference(const BallDyn& a, const BallDyn& b) {
    BallList sa, sb;
    if (a._val.type() == typeid(BallList)) sa = std::any_cast<const BallList&>(a._val);
    if (b._val.type() == typeid(BallList)) sb = std::any_cast<const BallList&>(b._val);
    BallList result;
    for (auto& e : sa) {
        bool found = false;
        for (auto& x : sb) { if (ball_to_string(x) == ball_to_string(e)) { found = true; break; } }
        if (!found) result.push_back(e);
    }
    return BallDyn(result);
}

// ── fromCharCode / toIso8601String BallDyn overloads ──
inline std::string fromCharCode(const std::string& tag, const BallDyn& code) {
    return fromCharCode(tag, static_cast<int64_t>(code));
}
inline std::string toIso8601String(const BallDyn& dt) {
    return toIso8601String(dt._val);
}
inline std::map<std::string, std::any> fromMillisecondsSinceEpoch(const DateTimeType& dt, const BallDyn& ms, bool = false) {
    return fromMillisecondsSinceEpoch(dt, static_cast<int64_t>(ms));
}
inline std::map<std::string, std::any> fromMillisecondsSinceEpoch(const DateTimeType& dt, const BallDyn& ms, const BallDyn&) {
    return fromMillisecondsSinceEpoch(dt, static_cast<int64_t>(ms));
}
inline std::map<std::string, std::any> parse(const DateTimeType& dt, const BallDyn& str) {
    return parse(dt, static_cast<std::string>(str));
}

// ── List.generate ──
template<typename F>
inline BallDyn generate(const std::string&, int64_t count, F fn) {
    BallList result;
    result.reserve(count);
    for (int64_t i = 0; i < count; ++i) {
        result.push_back(std::any(fn(BallDyn(i))));
    }
    return BallDyn(result);
}
template<typename F>
inline BallDyn generate(const std::string& tag, const BallDyn& count, F fn) {
    return generate(tag, static_cast<int64_t>(count), fn);
}
template<typename F>
inline BallDyn generate(const std::string& tag, const std::any& count_val, F fn) {
    int64_t count = 0;
    if (count_val.type() == typeid(int64_t)) count = std::any_cast<int64_t>(count_val);
    else if (count_val.type() == typeid(double)) count = static_cast<int64_t>(std::any_cast<double>(count_val));
    return generate(tag, count, fn);
}

// ── ball_take / ball_skip for BallDyn ──
inline BallDyn ball_take(const BallDyn& v, int64_t n) {
    if (v._val.type() == typeid(BallList)) {
        return BallDyn(ball_take(std::any_cast<const BallList&>(v._val), n));
    }
    return v;
}
inline BallDyn ball_skip(const BallDyn& v, int64_t n) {
    if (v._val.type() == typeid(BallList)) {
        return BallDyn(ball_skip(std::any_cast<const BallList&>(v._val), n));
    }
    return v;
}

// ================================================================
#endif  // BALL_DYN_H
