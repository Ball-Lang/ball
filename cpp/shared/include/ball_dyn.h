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
    BallDyn(std::any v) : _val(std::move(v)) {}
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
    BallDyn& operator=(std::any v) { _val = std::move(v); return *this; }

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
    // Returns a reference to a field in the underlying map, or creates one.
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

    // Index access for vectors
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
        return BallDyn();
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
    friend bool operator==(const std::string& s, const BallDyn& d) { return d == s; }
    friend bool operator!=(const std::string& s, const BallDyn& d) { return d != s; }

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

// String concatenation
inline std::string operator+(const std::string& s, const BallDyn& d) {
    return s + static_cast<std::string>(d);
}
inline std::string operator+(const BallDyn& d, const std::string& s) {
    return static_cast<std::string>(d) + s;
}

#endif  // BALL_DYN_H
