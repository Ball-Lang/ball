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

// Insertion-ordered string map (Dart LinkedHashMap semantics).
struct BallOrderedMap {
    std::vector<std::pair<std::string, std::any>> entries_;
    std::map<std::string, size_t> index_;

    using key_type = std::string;
    using mapped_type = std::any;
    using value_type = std::pair<std::string, std::any>;
    using iterator = std::vector<value_type>::iterator;
    using const_iterator = std::vector<value_type>::const_iterator;

    std::any& operator[](const std::string& key) {
        auto it = index_.find(key);
        if (it == index_.end()) {
            index_[key] = entries_.size();
            entries_.emplace_back(key, std::any{});
        }
        return entries_[index_[key]].second;
    }

    const std::any& operator[](const std::string& key) const {
        return entries_.at(index_.at(key)).second;
    }

    const std::any& at(const std::string& key) const {
        return entries_.at(index_.at(key)).second;
    }

    iterator begin() { return entries_.begin(); }
    iterator end() { return entries_.end(); }
    const_iterator begin() const { return entries_.begin(); }
    const_iterator end() const { return entries_.end(); }

    size_t size() const { return entries_.size(); }
    bool empty() const { return entries_.empty(); }
    void clear() { entries_.clear(); index_.clear(); }
    size_t count(const std::string& key) const { return index_.count(key); }

    iterator find(const std::string& key) {
        auto it = index_.find(key);
        return it == index_.end() ? end() : entries_.begin() + static_cast<std::ptrdiff_t>(it->second);
    }
    const_iterator find(const std::string& key) const {
        auto it = index_.find(key);
        return it == index_.end() ? end() : entries_.begin() + static_cast<std::ptrdiff_t>(it->second);
    }

    void erase(const std::string& key) {
        auto it = index_.find(key);
        if (it == index_.end()) return;
        size_t idx = it->second;
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(idx));
        index_.erase(it);
        for (size_t i = idx; i < entries_.size(); ++i)
            index_[entries_[i].first] = i;
    }

    template<class InputIt>
    void insert(InputIt first, InputIt last) {
        for (; first != last; ++first)
            (*this)[first->first] = first->second;
    }
};

using BallMap = std::map<std::string, std::any>;
using BallUMap = std::unordered_map<std::string, std::any>;
using BallList = std::vector<std::any>;
// Reference-semantic PROGRAM ordered maps (_ballUserMap / _stdMapCreate). Mirrors
// BallListRef: copies of a BallDyn share the underlying map so map_set mutations
// on a passed reference are visible to the caller's scoped variable.
using BallOrderedMapRef = std::shared_ptr<BallOrderedMap>;
using BallFunc = std::function<std::any(std::any)>;
// BallScope: shared-pointer-based scope for reference semantics in scope chains.
// Scopes created via child() use this so parent mutations are visible to children.
using BallScope = std::shared_ptr<BallMap>;

// Reference-semantic PROGRAM lists. The Dart reference engine wraps lists in a
// BallList object (a reference type), so `list[i]=v` / push / sort mutate in place
// and every holder observes it. A by-value std::vector inside BallDyn::_val is
// copied whenever a BallDyn is copied (e.g. reading a variable out of a scope, or
// passing a list to a helper function), so in-place mutation is lost. Storing the
// vector shared_ptr-backed (BallListRef) restores reference semantics — copies of
// the BallDyn share the underlying vector. Mirrors the BallScope precedent. This is
// confined to BallDyn (compiled programs); the native C++ engine never produces a
// BallListRef, so its behavior and the direct-conformance baseline are unaffected.
using BallListRef = std::shared_ptr<BallList>;

// Reference-semantic user-class struct instances. Concrete (non-generic,
// non-abstract) user classes are compiled as plain C++ structs — value types.
// In Dart all objects are reference types, so two variables pointing at the same
// object share mutations and `identical()` returns true. Wrapping the struct in
// a shared_ptr<std::any> inside BallDyn gives Dart-compatible reference
// semantics: copies of the BallDyn share the underlying struct, `ball_obj_as<T>`
// dereferences transparently, and `ball_identical` compares pointers.
using BallUserRef = std::shared_ptr<std::any>;

// Unique marker for Dart engine `_sentinel` (dispatch not found). Must not
// compare equal to null/empty BallDyn() returned by void builtin methods.
struct BallDispatchNotFound {};

// Forward declaration: Dart-style stringify for an ordered map, recognizing
// the portable ordered-set tag (see ball_is_ball_set) and rendering it as a
// Set literal (`{a, b, c}`) instead of the generic `{key: value}` map shape.
// Defined below (after BallListRef / ball_to_string(any) are visible) —
// shared by BallDyn::operator std::string() and the _ball_to_string_ext hook
// used for bare std::any elements nested inside lists/maps (issue #174).
inline std::string _ball_ordered_map_to_string(const BallOrderedMap& omp);

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
        !std::is_same_v<std::decay_t<F>, BallOrderedMap> &&
        !std::is_same_v<std::decay_t<F>, BallOrderedMapRef> &&
        !std::is_same_v<std::decay_t<F>, BallList> &&
        !std::is_same_v<std::decay_t<F>, std::regex> &&
        !std::is_base_of_v<BallDyn, std::decay_t<F>> &&
        std::is_class_v<std::decay_t<F>> &&
        (std::is_invocable_v<std::decay_t<F>, std::any> ||
         std::is_invocable_v<std::decay_t<F>, BallDyn> ||
         std::is_invocable_v<std::decay_t<F>>), int> = 0>
    BallDyn(F&& f) {
        _val = BallFunc([fn = std::forward<F>(f)](std::any arg) mutable -> std::any {
            if constexpr (std::is_invocable_v<std::decay_t<F>, std::any>) {
                if constexpr (std::is_void_v<std::invoke_result_t<std::decay_t<F>, std::any>>) {
                    fn(arg);
                    return std::any{};
                } else {
                    return std::any(fn(arg));
                }
            } else if constexpr (std::is_invocable_v<std::decay_t<F>, BallDyn>) {
                if constexpr (std::is_void_v<std::invoke_result_t<std::decay_t<F>, BallDyn>>) {
                    fn(BallDyn(arg));
                    return std::any{};
                } else {
                    return std::any(BallDyn(fn(BallDyn(arg)))._val);
                }
            } else {
                // Zero-argument closure (Dart `() => …` / `() { … }`): every Ball
                // callable is stored as a one-input BallFunc, so ignore the
                // supplied argument and invoke with none.
                (void)arg;
                if constexpr (std::is_void_v<std::invoke_result_t<std::decay_t<F>>>) {
                    fn();
                    return std::any{};
                } else {
                    return std::any(BallDyn(fn())._val);
                }
            }
        });
    }
    BallDyn(int64_t v) : _val(v) {}
    BallDyn(int v) : _val(static_cast<int64_t>(v)) {}
    // Any other integral type widens to int64_t. Crucially this covers
    // `long long` on platforms where `int64_t` is `long` (gcc/Linux): there a
    // `long long` argument matches none of the int64_t/int/double/bool ctors
    // exactly and gcc reports the construction (and every `BallDyn == long long`
    // comparison, which routes through this conversion) as ambiguous. The
    // enable_if excludes the types already handled above, so on MSVC — where
    // `int64_t` IS `long long` — this template never collides with BallDyn(int64_t).
    template <typename T,
              std::enable_if_t<std::is_integral_v<T> &&
                                   !std::is_same_v<T, bool> &&
                                   !std::is_same_v<T, int> &&
                                   !std::is_same_v<T, int64_t>,
                               int> = 0>
    BallDyn(T v) : _val(static_cast<int64_t>(v)) {}
    BallDyn(double v) : _val(v) {}
    BallDyn(bool v) : _val(v) {}
    BallDyn(const std::string& v) : _val(v) {}
    BallDyn(std::string&& v) : _val(std::move(v)) {}
    BallDyn(const char* v) : _val(std::string(v)) {}
    BallDyn(BallMap v) : _val(std::move(v)) {}
    BallDyn(BallOrderedMap v)
        : _val(BallOrderedMapRef(std::make_shared<BallOrderedMap>(std::move(v)))) {}
    BallDyn(BallOrderedMapRef v) : _val(std::move(v)) {}
    BallDyn(BallUMap v) : _val(std::move(v)) {}
    // A program LIST is stored shared_ptr-backed: a fresh handle is allocated at
    // construction; subsequent BallDyn copies share it, so in-place mutation
    // (sort, push/pop, index-assign) is visible to every holder.
    BallDyn(BallList v) : _val(BallListRef(std::make_shared<BallList>(std::move(v)))) {}
    BallDyn(BallListRef v) : _val(std::move(v)) {}
    // Homogeneous list literals are emitted by the compiler as a typed vector
    // (`std::vector<int64_t/double/std::string/bool>`). Normalize them to a
    // BallList at construction so every list operation (length, index,
    // iterate, sort, …) recognizes them — `_listPtr()` only matches BallList /
    // BallListRef, so a raw typed vector otherwise reads as a non-list and
    // `ball_length`/`[]` silently yield 0/empty.
    BallDyn(const std::vector<int64_t>& v) {
        BallList l; l.reserve(v.size());
        for (int64_t x : v) l.emplace_back(std::any(x));
        _val = BallListRef(std::make_shared<BallList>(std::move(l)));
    }
    BallDyn(const std::vector<double>& v) {
        BallList l; l.reserve(v.size());
        for (double x : v) l.emplace_back(std::any(x));
        _val = BallListRef(std::make_shared<BallList>(std::move(l)));
    }
    BallDyn(const std::vector<std::string>& v) {
        BallList l; l.reserve(v.size());
        for (const auto& x : v) l.emplace_back(std::any(x));
        _val = BallListRef(std::make_shared<BallList>(std::move(l)));
    }
    BallDyn(const std::vector<bool>& v) {
        BallList l; l.reserve(v.size());
        for (bool x : v) l.emplace_back(std::any(x));
        _val = BallListRef(std::make_shared<BallList>(std::move(l)));
    }
    BallDyn(BallFunc v) : _val(std::move(v)) {}
    // StringBuffer — stored shared_ptr-backed (BallStringBuffer holds the
    // shared_ptr) so writes through any alias accumulate (conformance 140/150).
    BallDyn(BallStringBuffer v) : _val(std::move(v)) {}
    // List.filled(length, value) lowers to a List_filled aggregate (defined in
    // ball_emit_runtime.h, always spliced before this header in compiled programs).
    BallDyn(const List_filled& lf)
        : _val(BallListRef(std::make_shared<BallList>(std::vector<std::any>(lf)))) {}
    // A user-class INSTANCE is stored shared_ptr-backed (BallObjectRef): a fresh
    // handle is allocated at construction; subsequent BallDyn copies share it, so
    // a setter mutating `self._field` is visible to every holder (caller's var,
    // aliases). Mirrors BallListRef. Maps stay by-value (a shared instance map
    // would create self-referential `self` cycles).
    BallDyn(BallObject v) : _val(BallObjectRef(std::make_shared<BallObject>(std::move(v)))) {}
    BallDyn(BallObjectRef v) : _val(std::move(v)) {}
    // Reference-semantic concrete user-class struct instance (BallUserRef).
    // The shared_ptr<std::any> wraps the struct; copies of BallDyn share it.
    BallDyn(BallUserRef v) : _val(std::move(v)) {}

    // ── Reference-semantic list accessors ──
    // Return a pointer to the underlying vector whether stored by-value (legacy /
    // native interop) or shared_ptr-backed (BallListRef). nullptr if not a list.
    BallList* _listPtr() {
        if (_val.type() == typeid(BallListRef)) return std::any_cast<BallListRef&>(_val).get();
        if (_val.type() == typeid(BallList)) return &std::any_cast<BallList&>(_val);
        return nullptr;
    }
    const BallList* _listPtr() const {
        if (_val.type() == typeid(BallListRef)) return std::any_cast<const BallListRef&>(_val).get();
        if (_val.type() == typeid(BallList)) return &std::any_cast<const BallList&>(_val);
        return nullptr;
    }
    bool _isList() const { return _val.type() == typeid(BallListRef) || _val.type() == typeid(BallList); }

    // ── Reference-semantic ordered-map accessors ──
    BallOrderedMap* _orderedMapPtr() {
        if (_val.type() == typeid(BallOrderedMapRef))
            return std::any_cast<BallOrderedMapRef&>(_val).get();
        if (_val.type() == typeid(BallOrderedMap))
            return &std::any_cast<BallOrderedMap&>(_val);
        return nullptr;
    }
    const BallOrderedMap* _orderedMapPtr() const {
        if (_val.type() == typeid(BallOrderedMapRef))
            return std::any_cast<const BallOrderedMapRef&>(_val).get();
        if (_val.type() == typeid(BallOrderedMap))
            return &std::any_cast<const BallOrderedMap&>(_val);
        return nullptr;
    }

    // ── Portable ordered-set backing-list accessor (issue #174) ──
    // A Ball `Set` value compiled by the direct-compile C++ path is the
    // portable one-key `{'__ball_set__': [...]}` map (mirrors the Dart/self-
    // hosted engine representation from issue #68 — see ball_is_ball_set
    // below). Every list-shaped BallDyn operation (size/empty/push_back/
    // iteration/indexing) must also recognize this shape and operate on the
    // WRAPPED list, or a Set silently behaves like a 1-entry map. Returns
    // nullptr for anything that isn't exactly that shape.
    // The backing list is stored two ways depending on who built the Set:
    //   • direct-compile (`ball_make_set`): a BallListRef (shared_ptr<BallList>)
    //     stored directly as the map value; and
    //   • the self-host: engine.dart's `_ballSetOf` builds the list as a
    //     `<Object?>[]` literal, which compiles to a plain BallList, wrapped in
    //     a BallDyn (`__m[tag] = std::any(BallDyn(BallList))`).
    // Accept BOTH (unwrapping any BallDyn layers first) so `is Set`/size/
    // rendering/iteration work on every path — otherwise self-host Sets were
    // invisible to `ball_is_ball_set`, and `{1,2} is Map` was true / nested
    // Sets mis-rendered (issue #174 self-host leg).
    BallList* _setBackingList() {
        BallOrderedMap* omp = _orderedMapPtr();
        if (!omp || omp->size() != 1) return nullptr;
        auto it = omp->find("__ball_set__");
        if (it == omp->end()) return nullptr;
        std::any* raw = &it->second;
        while (raw->type() == typeid(BallDyn)) raw = &std::any_cast<BallDyn&>(*raw)._val;
        if (raw->type() == typeid(BallListRef))
            return std::any_cast<BallListRef&>(*raw).get();
        if (raw->type() == typeid(BallList)) return &std::any_cast<BallList&>(*raw);
        return nullptr;
    }
    const BallList* _setBackingList() const {
        const BallOrderedMap* omp = _orderedMapPtr();
        if (!omp || omp->size() != 1) return nullptr;
        auto it = omp->find("__ball_set__");
        if (it == omp->end()) return nullptr;
        const std::any* raw = &it->second;
        while (raw->type() == typeid(BallDyn))
            raw = &std::any_cast<const BallDyn&>(*raw)._val;
        if (raw->type() == typeid(BallListRef))
            return std::any_cast<const BallListRef&>(*raw).get();
        if (raw->type() == typeid(BallList))
            return &std::any_cast<const BallList&>(*raw);
        return nullptr;
    }

    // ── Reference-semantic instance accessors ──
    BallObject* _objPtr() {
        if (_val.type() == typeid(BallObjectRef)) return std::any_cast<BallObjectRef&>(_val).get();
        if (_val.type() == typeid(BallObject)) return &std::any_cast<BallObject&>(_val);
        return nullptr;
    }
    const BallObject* _objPtr() const {
        if (_val.type() == typeid(BallObjectRef)) return std::any_cast<const BallObjectRef&>(_val).get();
        if (_val.type() == typeid(BallObject)) return &std::any_cast<const BallObject&>(_val);
        return nullptr;
    }

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
    // Other integral types (e.g. `long long` on gcc/clang where int64_t is
    // `long`): widen to int64_t. Without this, `BallDyn = <long long>` is
    // ambiguous between operator=(int64_t) and operator=(int).
    template <typename T,
              std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool> &&
                                   !std::is_same_v<T, int> &&
                                   !std::is_same_v<T, int64_t>,
                               int> = 0>
    BallDyn& operator=(T v) { _val = static_cast<int64_t>(v); return *this; }
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
    // Non-explicit so BallDyn→bool is unambiguous (preferred over the two-step
    // BallDyn→int64_t→bool or BallDyn→double→bool narrowing paths).
    operator bool() const {
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
            // Delegate to ball_to_string(double) so NaN/Infinity and Dart-style
            // formatting (e.g. `6.0`, trailing-zero trimming) are handled in one
            // place. The naive `static_cast<long long>` guard below mis-handled
            // Infinity (UB cast) and printed "inf".
            return ball_to_string(std::any_cast<double>(_val));
        }
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) ? "true" : "false";
        // Dynamic (map-backed) user-class instance: if it carries a "__methods__"
        // table with a "toString" closure, invoke it (Dart's toString()). This is
        // how a generic/abstract class instance stringifies (e.g. Pair.toString).
        if (const BallObject* op = _objPtr()) {
            const BallMap& base = static_cast<const BallMap&>(*op);
            auto mit = base.find("__methods__");
            if (mit != base.end() && mit->second.type() == typeid(BallMap)) {
                const BallMap& methods = std::any_cast<const BallMap&>(mit->second);
                auto fit = methods.find("toString");
                if (fit != methods.end() && fit->second.type() == typeid(BallFunc)) {
                    std::any r = std::any_cast<const BallFunc&>(fit->second)(std::any{});
                    return ball_to_string(r);
                }
            }
            // No toString: fall through to the generic {key: value} map print.
        }
        // List: Dart-style [a, b, c]
        if (const BallList* vp = _listPtr()) {
            const auto& v = *vp;
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
            // A reified caught exception (built by _ball_exception_to_dyn for
            // `catch(e)`) stringifies to its original thrown value — Dart's
            // `print(e)` / "$e" shows the thrown object, not the internal
            // {typeName, value, message} reification. The map keeps its shape so
            // `e["value"]`, `e["typeName"]` and `e is BallException` still work.
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
            for (const auto& [k, v] : m) {
                if (k.find("__") == 0 || k == "type_args") continue;
                if (!first) out += ", ";
                out += k + ": " + ball_to_string(v);
                first = false;
            }
            out += "}";
            return out;
        }
        if (const BallOrderedMap* omp = _orderedMapPtr()) {
            return _ball_ordered_map_to_string(*omp);
        }
        if (_val.type() == typeid(BallStringBuffer))
            return *std::any_cast<const BallStringBuffer&>(_val).buf;
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
        // Defeat MSVC's BallDyn-in-any double-wrap: if _val is itself a wrapped
        // BallDyn (e.g. std::any(BallDyn(BallObjectRef)) after scope round-trips),
        // the type checks below all miss and field access returns empty. Unwrap
        // once and recurse so _objPtr/map/scope dispatch sees the real value.
        const std::any& __uv = _BallDynUnwrapper::unwrap(_val);
        if (&__uv != &_val) return BallDyn(__uv)[key];
        if (_val.type() == typeid(BallGenerator)) {
            if (key == "values")
                return BallDyn(BallList(*std::any_cast<const BallGenerator&>(_val).values));
            return BallDyn();
        }
        if (const BallObject* op = _objPtr()) {
            // BallObject IS-A BallMap; its base map holds fields + __type__ etc.
            const BallMap& m = static_cast<const BallMap&>(*op);
            auto it = m.find(key);
            if (it != m.end()) return BallDyn(it->second);
            return BallDyn();
        }
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
        if (const BallOrderedMap* omp = _orderedMapPtr()) {
            auto it = omp->index_.find(key);
            if (it == omp->index_.end()) return BallDyn();
            return BallDyn(omp->entries_[it->second].second);
        }
        if (_val.type() == typeid(BallUMap)) {
            auto& m = const_cast<BallUMap&>(std::any_cast<const BallUMap&>(_val));
            return BallDyn(m[key]);
        }
        return BallDyn();
    }

    // Index access for vectors and strings
    BallDyn operator[](int64_t idx) const {
        const std::any& __uv = _BallDynUnwrapper::unwrap(_val);
        if (&__uv != &_val) return BallDyn(__uv)[idx];
        if (const BallList* vp = _listPtr()) {
            const auto& v = *vp;
            if (idx >= 0 && static_cast<size_t>(idx) < v.size())
                return BallDyn(v[idx]);
            // Out-of-range list index: Dart's native `List[i]` throws a
            // RangeError. The self-host engine relies on that native throw
            // (its `_stdIndex` does `listTarget[_toInt(index)]` with no bounds
            // check) so a `catch (RangeError)` handler can fire. Mirror it with
            // a RangeError-typed BallException; the message matches Dart's
            // `RangeError (index): ...` shape closely enough for stringified
            // catches. Throwing only on a confirmed list receiver keeps the
            // blast radius tight (internal correct reads never go out of range).
            throw BallException(
                "RangeError",
                "RangeError (index): Index out of range: index should be less than " +
                    std::to_string(v.size()) + ": " + std::to_string(idx));
        }
        // Portable ordered-set value: positional access into the wrapped list.
        // Dart's Set has no `operator[]`, but several runtime set-op helpers
        // (set_add/set_contains's own manual scans) index by position and rely
        // on this — issue #174.
        if (const BallList* svp = _setBackingList()) {
            const auto& v = *svp;
            if (idx >= 0 && static_cast<size_t>(idx) < v.size())
                return BallDyn(v[idx]);
            throw BallException(
                "RangeError",
                "RangeError (index): Index out of range: index should be less than " +
                    std::to_string(v.size()) + ": " + std::to_string(idx));
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
        // A map read with an INTEGER key (Dart `Map<int, V>[k]`): every map WRITE
        // (`ball_set`) and membership test (`count` / `containsKey`, which route
        // an int key through `static_cast<std::string>(BallDyn(key))`) key maps
        // by the STRINGIFIED form, so an int-keyed map read must look up the same
        // string. Without this, `Map<int, int>` reads returned null and poisoned
        // the surrounding arithmetic (int-keyed memoization — fixture 95).
        // Delegate to the string operator[], which dispatches every map shape
        // (BallObject / BallMap / BallOrderedMap / BallUMap / BallScope); for a
        // non-map receiver it returns null, matching the previous fall-through.
        return (*this)[static_cast<std::string>(BallDyn(idx))];
    }

    // Mutation: set a field in the underlying map/list.
    // `obj.set("key", value)` modifies the map entry in-place.
    void set(const std::string& key, const std::any& value) {
        const std::any& u = _BallDynUnwrapper::unwrap(value);
        if (_val.type() == typeid(BallScope)) {
            // Lexical assignment (mirror BallDyn::lookup / Dart _Scope.set): write
            // the variable in its DECLARING scope. If the current scope owns the
            // key, set here; otherwise walk the __parent__ chain to the owner;
            // if no scope owns it, bind locally. Without this walk, assigning a
            // loop variable from inside a child block scope (a while/do-while
            // body) shadows it locally, so the loop condition keeps reading the
            // stale outer value and the loop never terminates.
            BallScope sc = std::any_cast<BallScope&>(_val);
            if (sc->count(key) == 0) {
                BallScope cur = sc;
                while (cur) {
                    auto pit = cur->find("__parent__");
                    if (pit != cur->end() && pit->second.type() == typeid(BallScope)) {
                        cur = std::any_cast<const BallScope&>(pit->second);
                        if (cur && cur->count(key) > 0) { (*cur)[key] = u; return; }
                    } else {
                        break;
                    }
                }
            }
            (*sc)[key] = u;
        } else if (BallObject* op = _objPtr()) {
            // Mutate through the shared handle so all holders observe the write.
            op->__op_set_index__(key, u);
        } else if (_val.type() == typeid(BallMap)) {
            if (u.type() == typeid(BallObject)) {
                std::any_cast<BallMap&>(_val)[key] = std::any(BallObjectRef(
                    std::make_shared<BallObject>(std::any_cast<const BallObject&>(u))));
            } else if (u.type() == typeid(BallList)) {
                // A raw BallList stored into a map must be wrapped in a shared
                // BallListRef so later operator[] reads return BallDyns that share
                // the same vector and in-place mutations (list_push, list[i]=, sort)
                // persist. Mirrors the BallObject->BallObjectRef wrap above.
                std::any_cast<BallMap&>(_val)[key] = std::any(BallListRef(
                    std::make_shared<BallList>(std::any_cast<const BallList&>(u))));
            } else {
                std::any_cast<BallMap&>(_val)[key] = u;
            }
        } else if (BallOrderedMap* omp = _orderedMapPtr()) {
            if (u.type() == typeid(BallObject)) {
                (*omp)[key] = std::any(BallObjectRef(
                    std::make_shared<BallObject>(std::any_cast<const BallObject&>(u))));
            } else if (u.type() == typeid(BallList)) {
                // Same raw-BallList->BallListRef wrap for the now-default ordered
                // map type (the branch `groups[key] = []` hits once map literals
                // are BallOrderedMap). Without it, `groups[key]` returns a fresh
                // detached list each read and list_push no-ops.
                (*omp)[key] = std::any(BallListRef(
                    std::make_shared<BallList>(std::any_cast<const BallList&>(u))));
            } else {
                (*omp)[key] = u;
            }
        } else if (_val.type() == typeid(BallUMap)) {
            std::any_cast<BallUMap&>(_val)[key] = u;
        } else if (!_val.has_value()) {
            // Dart `final _setters = {}` compiles to default-empty BallDyn; lazily
            // allocate a map so ball_set/_buildLookupTables can populate it.
            _val = BallMap{{key, value}};
        } else if (BallList* vp = _listPtr()) {
            // Index assignment `list[i] = val` is emitted with the index
            // stringified (the emitter doesn't distinguish list vs map keys),
            // so a numeric key on a list must set the element in place —
            // otherwise in-place mutations (e.g. sorts) silently no-op.
            auto& v = *vp;
            try {
                long long idx = std::stoll(key);
                if (idx >= 0 && static_cast<size_t>(idx) < v.size())
                    v[static_cast<size_t>(idx)] = value;
            } catch (...) {}
        }
    }
    void set(const std::string& key, const BallDyn& value) {
        set(key, value._val);
    }
    void set(int64_t idx, const std::any& value) {
        if (BallList* vp = _listPtr()) {
            auto& v = *vp;
            if (idx >= 0 && static_cast<size_t>(idx) < v.size())
                v[idx] = value;
        }
    }

    // BallDyn-keyed access: convert key to string and delegate
    BallDyn operator[](const BallDyn& key) const {
        const std::any& __uvk = _BallDynUnwrapper::unwrap(_val);
        if (&__uvk != &_val) return BallDyn(__uvk)[key];
        // An integer key on a list/string must use positional indexing — the
        // engine's `list[i]` read passes _toInt(i) as a BallDyn(int64_t), and
        // stringifying it ("3") would miss list elements entirely. Maps stay
        // string-keyed (Ball maps are string-keyed; the engine stringifies int
        // keys before map access). Unwrap to defeat MSVC's BallDyn-in-any wrap.
        auto& u = _BallDynUnwrapper::unwrap(key._val);
        if (u.type() == typeid(int64_t) &&
            (_isList() ||
             _val.type() == typeid(std::string) ||
             _val.type() == typeid(std::vector<std::string>))) {
            return (*this)[std::any_cast<int64_t>(u)];
        }
        return (*this)[static_cast<std::string>(key)];
    }
    void set(const BallDyn& key, const BallDyn& value) {
        set(static_cast<std::string>(key), value._val);
    }

    // Map operations
    size_t count(const std::string& key) const {
        if (_val.type() == typeid(BallScope))
            return std::any_cast<const BallScope&>(_val)->count(key);
        if (const BallObject* op = _objPtr())
            return static_cast<const BallMap&>(*op).count(key);
        if (_val.type() == typeid(BallMap))
            return std::any_cast<const BallMap&>(_val).count(key);
        if (const BallOrderedMap* omp = _orderedMapPtr()) return omp->count(key);
        if (_val.type() == typeid(BallUMap))
            return std::any_cast<const BallUMap&>(_val).count(key);
        return 0;
    }
    // BallDyn-keyed count — compiled programs pass dynamic keys to containsKey.
    size_t count(const BallDyn& key) const {
        return count(static_cast<std::string>(key));
    }
    // Dart Map.containsKey parity for self-host engine (BallOrderedMapRef / BallMap).
    bool containsKey(const BallDyn& key) const { return count(key) > 0; }
    bool containsKey(const std::string& key) const { return count(key) > 0; }

    // Dart Object.hashCode: int hashes to itself, others via std::hash on the
    // underlying scalar/string. Used by user `hashCode` getters/overrides that
    // combine field hashes (conformance 113).
    int64_t hashCode() const {
        // _val is never a nested BallDyn (the constructor peels those), so a
        // direct type check on the underlying scalar/string is sufficient.
        if (!_val.has_value()) return 0;
        if (_val.type() == typeid(int64_t)) return std::any_cast<int64_t>(_val);
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) ? 1 : 0;
        if (_val.type() == typeid(double))
            return static_cast<int64_t>(
                std::hash<double>{}(std::any_cast<double>(_val)));
        if (_val.type() == typeid(std::string))
            return static_cast<int64_t>(
                std::hash<std::string>{}(std::any_cast<std::string>(_val)));
        return 0;
    }

    // Instance field write — routes through BallObject::setField when [this]
    // holds a BallObjectRef, otherwise falls back to map set().
    void setField(const std::string& field, const BallDyn& val) {
        if (BallObject* op = _objPtr()) {
            op->setField(field, val._val);
            return;
        }
        set(field, val._val);
    }
    void setField(const std::string& field, const std::any& val) {
        if (BallObject* op = _objPtr()) {
            op->setField(field, val);
            return;
        }
        set(field, val);
    }

    // Collection operations
    bool empty() const {
        if (!_val.has_value()) return true;
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val).empty();
        if (const BallList* vp = _listPtr()) return vp->empty();
        if (_val.type() == typeid(BallScope)) return std::any_cast<const BallScope&>(_val)->empty();
        if (_val.type() == typeid(BallMap)) return std::any_cast<const BallMap&>(_val).empty();
        // Portable ordered-set value: report the WRAPPED list's emptiness, not
        // the map's own key count (always 1) — issue #174.
        if (const BallList* svp = _setBackingList()) return svp->empty();
        if (const BallOrderedMap* omp = _orderedMapPtr()) return omp->empty();
        if (_val.type() == typeid(BallUMap)) return std::any_cast<const BallUMap&>(_val).empty();
        return false;
    }

    int64_t size() const {
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val).size();
        if (const BallList* vp = _listPtr()) return vp->size();
        if (_val.type() == typeid(BallScope)) return std::any_cast<const BallScope&>(_val)->size();
        if (_val.type() == typeid(BallMap)) return std::any_cast<const BallMap&>(_val).size();
        // Portable ordered-set value: report the WRAPPED list's element count,
        // not the map's own key count (always 1) — issue #174.
        if (const BallList* svp = _setBackingList()) return svp->size();
        if (const BallOrderedMap* omp = _orderedMapPtr()) return omp->size();
        if (_val.type() == typeid(BallUMap)) return std::any_cast<const BallUMap&>(_val).size();
        return 0;
    }

    void push_back(const BallDyn& v) {
        if (BallList* vp = _listPtr()) { vp->push_back(v._val); return; }
        // Set.add semantics: dedup-insert into the wrapped list, preserving
        // insertion order (issue #174). A duplicate is a silent no-op, exactly
        // like list_push's caller-visible mutation for a genuine List.
        if (BallList* svp = _setBackingList()) {
            for (const auto& x : *svp) {
                if (BallDyn(x) == v) return;
            }
            svp->push_back(v._val);
        }
    }

    BallDyn front() const {
        if (const BallList* vp = _listPtr()) {
            const auto& l = *vp;
            return l.empty() ? BallDyn() : BallDyn(l.front());
        }
        return BallDyn();
    }

    BallDyn back() const {
        if (const BallList* vp = _listPtr()) {
            const auto& l = *vp;
            return l.empty() ? BallDyn() : BallDyn(l.back());
        }
        return BallDyn();
    }

    void erase(const std::string& key) {
        if (_val.type() == typeid(BallScope))
            std::any_cast<BallScope&>(_val)->erase(key);
        else if (_val.type() == typeid(BallMap))
            std::any_cast<BallMap&>(_val).erase(key);
        else if (BallOrderedMap* omp = _orderedMapPtr())
            omp->erase(key);
        else if (_val.type() == typeid(BallUMap))
            std::any_cast<BallUMap&>(_val).erase(key);
    }
    void push_back(const std::any& val) {
        // Delegate to the BallDyn overload so Set.add dedup (issue #174)
        // applies uniformly regardless of which overload the caller used.
        push_back(BallDyn(val));
    }
    void pop_back() {
        if (BallList* vp = _listPtr()) {
            auto& v = *vp;
            if (!v.empty()) v.pop_back();
        }
    }
    void erase(const BallDyn& val) {
        if (BallList* vp = _listPtr()) {
            auto& v = *vp;
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
        const std::any& ua = _BallDynUnwrapper::unwrap(_val);
        const std::any& ub = _BallDynUnwrapper::unwrap(o._val);
        if (ua.type() == typeid(BallObjectRef) && ub.type() == typeid(BallObjectRef)) {
            return std::any_cast<const BallObjectRef&>(ua) ==
                   std::any_cast<const BallObjectRef&>(ub);
        }
        if (ua.type() == typeid(BallObjectRef) || ub.type() == typeid(BallObjectRef)) {
            return false;
        }
        // Reference-semantic instances compare by pointer identity (Dart
        // `identical` / default `==`): two BallDyns are equal iff they share the
        // same underlying BallObject handle.
        if (const BallObject* a = _objPtr()) {
            const BallObject* b = o._objPtr();
            return b != nullptr && a == b;
        }
        if (o._objPtr() != nullptr) return false;
        // List equality before storage-type check: BallListRef vs BallList may
        // alias the same vector (e.g. outer[0] == outer[1] with shared refs).
        if (const BallList* ap = _listPtr()) {
            const BallList* bp = o._listPtr();
            if (!bp) return false;
            if (ap == bp) return true;
            if (ap->size() != bp->size()) return false;
            for (size_t i = 0; i < ap->size(); ++i) {
                if (BallDyn((*ap)[i]) != BallDyn((*bp)[i])) return false;
            }
            return true;
        }
        // Numeric cross-type equality: Dart `0 == 0.0` is true. Compare an
        // int64_t and a double by value before the strict type-mismatch reject
        // (switch on a `num` subject with int patterns; conformance 225).
        {
            bool an = _val.type() == typeid(int64_t) || _val.type() == typeid(double);
            bool bn = o._val.type() == typeid(int64_t) || o._val.type() == typeid(double);
            if (an && bn && _val.type() != o._val.type()) {
                double av = _val.type() == typeid(int64_t)
                    ? (double)std::any_cast<int64_t>(_val) : std::any_cast<double>(_val);
                double bv = o._val.type() == typeid(int64_t)
                    ? (double)std::any_cast<int64_t>(o._val) : std::any_cast<double>(o._val);
                return av == bv;
            }
        }
        if (_val.type() != o._val.type()) return false;
        // BallUserRef: reference identity (Dart default `==` for objects).
        if (_val.type() == typeid(BallUserRef)) {
            return std::any_cast<const BallUserRef&>(_val).get() ==
                   std::any_cast<const BallUserRef&>(o._val).get();
        }
        if (_val.type() == typeid(BallDispatchNotFound)) return true;
        if (_val.type() == typeid(BallListRef) && o._val.type() == typeid(BallListRef)) {
            return std::any_cast<const BallListRef&>(_val) ==
                   std::any_cast<const BallListRef&>(o._val);
        }
        if (_val.type() == typeid(BallList) && o._val.type() == typeid(BallList)) {
            const BallList& la = std::any_cast<const BallList&>(_val);
            const BallList& lb = std::any_cast<const BallList&>(o._val);
            if (&la == &lb) return true;
            if (la.size() != lb.size()) return false;
            for (size_t i = 0; i < la.size(); ++i) {
                if (BallDyn(la[i]) != BallDyn(lb[i])) return false;
            }
            return true;
        }
        if (_val.type() == typeid(int64_t)) return std::any_cast<int64_t>(_val) == std::any_cast<int64_t>(o._val);
        if (_val.type() == typeid(double)) return std::any_cast<double>(_val) == std::any_cast<double>(o._val);
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) == std::any_cast<bool>(o._val);
        if (_val.type() == typeid(std::string)) return std::any_cast<const std::string&>(_val) == std::any_cast<const std::string&>(o._val);
        // Structural map equality (both same type per the check above): enum
        // values compile to `{index, _name}` maps and are compared through the
        // BallDyn layer in switch statements (conformance 109).
        if (_val.type() == typeid(BallMap)) {
            const BallMap& ma = std::any_cast<const BallMap&>(_val);
            const BallMap& mb = std::any_cast<const BallMap&>(o._val);
            if (ma.size() != mb.size()) return false;
            for (const auto& kv : ma) {
                auto it = mb.find(kv.first);
                if (it == mb.end()) return false;
                if (BallDyn(kv.second) != BallDyn(it->second)) return false;
            }
            return true;
        }
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
    // Delegate to operator==(const BallDyn&) rather than duplicating a
    // type-narrow comparison: that overload already special-cases int64_t-vs-
    // double cross-type equality (Dart `0 == 0.0` is true), which a bare
    // `_val.type() == typeid(int64_t)` guard here would silently miss — e.g.
    // `someDouble == 0` was always false even for `someDouble == -0.0` or
    // `0.0`, which broke a negative-zero sign guard written as `n == 0` in
    // the self-hosted engine source (issue #101 fixture 316).
    bool operator==(int64_t v) const { return *this == BallDyn(v); }
    bool operator!=(int64_t v) const { return !(*this == v); }
    bool operator==(int v) const { return *this == static_cast<int64_t>(v); }
    bool operator!=(int v) const { return !(*this == static_cast<int64_t>(v)); }
    // Other integral types (`long long` on gcc/clang): compare as int64_t.
    // Without this, `BallDyn == <long long>` is ambiguous (int64_t vs int).
    template <typename T,
              std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool> &&
                                   !std::is_same_v<T, int> &&
                                   !std::is_same_v<T, int64_t>,
                               int> = 0>
    bool operator==(T v) const { return *this == static_cast<int64_t>(v); }
    template <typename T,
              std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool> &&
                                   !std::is_same_v<T, int> &&
                                   !std::is_same_v<T, int64_t>,
                               int> = 0>
    bool operator!=(T v) const { return !(*this == static_cast<int64_t>(v)); }
    bool operator==(bool v) const {
        if (_val.type() == typeid(bool)) return std::any_cast<bool>(_val) == v;
        return false;
    }
    bool operator!=(bool v) const { return !(*this == v); }
    // Same cross-type rationale as operator==(int64_t) above.
    bool operator==(double v) const { return *this == BallDyn(v); }
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
        // Dart semantics: String * int repeats the string (count<=0 => "").
        if (_val.type() == typeid(std::string) && o._val.type() == typeid(int64_t)) {
            const std::string& s = std::any_cast<const std::string&>(_val);
            int64_t n = std::any_cast<int64_t>(o._val);
            std::string out;
            if (n > 0) { out.reserve(s.size() * static_cast<size_t>(n)); for (int64_t k = 0; k < n; ++k) out += s; }
            return BallDyn(std::move(out));
        }
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
    BallDyn operator+(double v) const {
        return BallDyn(static_cast<double>(*this) + v);
    }
    BallDyn operator-(double v) const {
        return BallDyn(static_cast<double>(*this) - v);
    }
    BallDyn operator*(double v) const {
        return BallDyn(static_cast<double>(*this) * v);
    }
    BallDyn operator/(double v) const {
        return BallDyn(static_cast<double>(*this) / v);
    }
    friend BallDyn operator+(double v, const BallDyn& d) { return BallDyn(v + static_cast<double>(d)); }
    friend BallDyn operator-(double v, const BallDyn& d) { return BallDyn(v - static_cast<double>(d)); }
    friend BallDyn operator*(double v, const BallDyn& d) { return BallDyn(v * static_cast<double>(d)); }
    // Arithmetic with any other integral type — notably a `long long` literal
    // (`10LL`) on platforms where int64_t is `long` (gcc/Linux). Without these
    // the call is ambiguous between the int64_t and double overloads (both are
    // standard conversions from long long). Route through int64_t. Excludes
    // bool and int64_t (handled by the overloads above; on MSVC long long IS
    // int64_t, so SFINAE drops the template and the int64_t overload is used).
    template <typename T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<std::decay_t<T>, bool> && !std::is_same_v<std::decay_t<T>, int64_t>, int> = 0>
    BallDyn operator+(T v) const { return *this + static_cast<int64_t>(v); }
    template <typename T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<std::decay_t<T>, bool> && !std::is_same_v<std::decay_t<T>, int64_t>, int> = 0>
    BallDyn operator-(T v) const { return *this - static_cast<int64_t>(v); }
    template <typename T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<std::decay_t<T>, bool> && !std::is_same_v<std::decay_t<T>, int64_t>, int> = 0>
    BallDyn operator*(T v) const { return *this * static_cast<int64_t>(v); }
    template <typename T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<std::decay_t<T>, bool> && !std::is_same_v<std::decay_t<T>, int64_t>, int> = 0>
    BallDyn operator/(T v) const { return *this / static_cast<int64_t>(v); }
    template <typename T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<std::decay_t<T>, bool> && !std::is_same_v<std::decay_t<T>, int64_t>, int> = 0>
    BallDyn operator%(T v) const { return *this % static_cast<int64_t>(v); }
    friend BallDyn operator+(int64_t v, const BallDyn& d) { return d + v; }
    friend BallDyn operator-(int64_t v, const BallDyn& d) { return BallDyn(v) - d; }
    friend BallDyn operator*(int64_t v, const BallDyn& d) { return d * v; }
    friend BallDyn operator/(int64_t v, const BallDyn& d) { return BallDyn(v) / d; }
    friend BallDyn operator/(double v, const BallDyn& d) { return BallDyn(v / static_cast<double>(d)); }
    friend BallDyn operator%(int64_t v, const BallDyn& d) { return BallDyn(v) % d; }
    // Compound assignment of a BallDyn into an int64_t accumulator (e.g.
    // `_memoryUsedBytes += bytes` where bytes is a BallDyn). Without this the
    // built-in += is ambiguous because BallDyn converts to both int64_t and double.
    friend int64_t& operator+=(int64_t& l, const BallDyn& d) { l += static_cast<int64_t>(d); return l; }
    friend int64_t& operator-=(int64_t& l, const BallDyn& d) { l -= static_cast<int64_t>(d); return l; }
    friend int64_t& operator*=(int64_t& l, const BallDyn& d) { l *= static_cast<int64_t>(d); return l; }
    friend int64_t& operator/=(int64_t& l, const BallDyn& d) { l /= static_cast<int64_t>(d); return l; }
    friend int64_t& operator%=(int64_t& l, const BallDyn& d) { l %= static_cast<int64_t>(d); return l; }
    friend int64_t& operator&=(int64_t& l, const BallDyn& d) { l &= static_cast<int64_t>(d); return l; }
    friend int64_t& operator|=(int64_t& l, const BallDyn& d) { l |= static_cast<int64_t>(d); return l; }
    friend int64_t& operator^=(int64_t& l, const BallDyn& d) { l ^= static_cast<int64_t>(d); return l; }
    friend int64_t& operator<<=(int64_t& l, const BallDyn& d) { l <<= static_cast<int64_t>(d); return l; }
    friend int64_t& operator>>=(int64_t& l, const BallDyn& d) { l >>= static_cast<int64_t>(d); return l; }
    // Same for a double accumulator (`x -= d` where x is double, d is BallDyn).
    friend double& operator+=(double& l, const BallDyn& d) { l += static_cast<double>(d); return l; }
    friend double& operator-=(double& l, const BallDyn& d) { l -= static_cast<double>(d); return l; }
    friend double& operator*=(double& l, const BallDyn& d) { l *= static_cast<double>(d); return l; }
    friend double& operator/=(double& l, const BallDyn& d) { l /= static_cast<double>(d); return l; }

    // Compound assignment on a BallDyn LHS (`x += y`, `-=`, `*=`, `/=`, `%=`).
    // Delegates to the binary operators, wrapping the RHS in a BallDyn so the
    // dynamic-typed overload is selected unambiguously. MSVC rejects the
    // built-in compound operators on BallDyn (it converts to both int64_t and
    // double, and the result can't bind back), and gcc only avoided the error
    // because its e2e build aborted earlier — these are needed on every
    // platform. Mirrors Dart's `x += y` on a `var`.
    template <typename T> BallDyn& operator+=(T&& v) { *this = *this + BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator-=(T&& v) { *this = *this - BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator*=(T&& v) { *this = *this * BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator/=(T&& v) { *this = *this / BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator%=(T&& v) { *this = *this % BallDyn(std::forward<T>(v)); return *this; }

    // Bitwise compound assignment on a BallDyn LHS (`x &= y`, `|=`, `^=`,
    // `<<=`, `>>=`). Same delegation pattern as the arithmetic family above;
    // the binary bitwise operators coerce both sides through int64_t.
    // Dart's `>>>=` has no C++ operator — the compiler desugars it to the
    // unsigned_right_shift expansion instead (see the `assign` handler).
    template <typename T> BallDyn& operator&=(T&& v) { *this = *this & BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator|=(T&& v) { *this = *this | BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator^=(T&& v) { *this = *this ^ BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator<<=(T&& v) { *this = *this << BallDyn(std::forward<T>(v)); return *this; }
    template <typename T> BallDyn& operator>>=(T&& v) { *this = *this >> BallDyn(std::forward<T>(v)); return *this; }

    // Comparison with int64_t
    bool operator<(int64_t v) const { return *this < BallDyn(v); }
    bool operator>(int64_t v) const { return *this > BallDyn(v); }
    bool operator<=(int64_t v) const { return *this <= BallDyn(v); }
    bool operator>=(int64_t v) const { return *this >= BallDyn(v); }
    friend bool operator<(int64_t v, const BallDyn& d) { return BallDyn(v) < d; }
    friend bool operator>(int64_t v, const BallDyn& d) { return BallDyn(v) > d; }
    friend bool operator<=(int64_t v, const BallDyn& d) { return BallDyn(v) <= d; }
    friend bool operator>=(int64_t v, const BallDyn& d) { return BallDyn(v) >= d; }

    // Comparison with double. Without these, `someDouble < ballDyn` and
    // `ballDyn < someDouble` resolved through the int64_t overloads above,
    // forcing `static_cast<int64_t>(double)` on the operand — which is UB for
    // non-finite values (Infinity/NaN) and lossy for large magnitudes. The
    // bug surfaced as `1.0/0.0 > big` (Infinity > DBL_MAX) returning false:
    // Infinity was truncated to INT64_MIN before the compare. Route through
    // BallDyn(double) so the double-aware operator< is used. conformance 232.
    bool operator<(double v) const { return *this < BallDyn(v); }
    bool operator>(double v) const { return *this > BallDyn(v); }
    bool operator<=(double v) const { return *this <= BallDyn(v); }
    bool operator>=(double v) const { return *this >= BallDyn(v); }
    friend bool operator<(double v, const BallDyn& d) { return BallDyn(v) < d; }
    friend bool operator>(double v, const BallDyn& d) { return BallDyn(v) > d; }
    friend bool operator<=(double v, const BallDyn& d) { return BallDyn(v) <= d; }
    friend bool operator>=(double v, const BallDyn& d) { return BallDyn(v) >= d; }

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
        if (const BallList* vp = _listPtr()) {
            const auto& v = *vp;
            for (size_t i = 0; i < v.size(); i++) {
                BallDyn el(v[i]);
                if (el == needle) return static_cast<int64_t>(i);
            }
            return -1;
        }
        // Portable ordered-set value: search the wrapped list (issue #174).
        if (const BallList* svp = _setBackingList()) {
            const auto& v = *svp;
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
        if (const BallList* vp = _listPtr()) return {vp, 0};
        // Portable ordered-set value: `for (final x in someSet)` iterates the
        // wrapped list in insertion order (issue #174).
        if (const BallList* svp = _setBackingList()) return {svp, 0};
        static BallList empty;
        return {&empty, 0};
    }
    Iterator end() const {
        if (const BallList* vp = _listPtr()) return {vp, vp->size()};
        if (const BallList* svp = _setBackingList()) return {svp, svp->size()};
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

    // ── Property-like accessors for compiled self-hosted engine ──
    // The C++ compiler emits `.kind()`, `.value()`, `.fields()`, `.values()`
    // as member function calls on BallDyn (and BALL_DYN_STUB derivatives).
    // These delegate to operator[] on the underlying map, matching the Dart
    // engine's property getter semantics on FlowSignal, protobuf
    // Value/Struct/ListValue, and map-entry iteration variables.

    // FlowSignal.kind — the signal type ("return", "break", "continue", "yield", etc.)
    BallDyn kind() const { return (*this)[std::string("kind")]; }

    // Protobuf Value-like / map-entry .value — the raw value
    BallDyn value() const { return (*this)[std::string("value")]; }

    // Protobuf Struct-like .fields — access the fields map. For a BallDyn
    // wrapping a map, the fields ARE the map, so return self. For a map with
    // a "fields" key (actual protobuf Struct JSON shape), return that entry.
    BallDyn fields() const {
        // If the underlying map has an explicit "fields" key, return it (protobuf
        // Struct JSON: {"fields": {"key": {...}, ...}}).
        BallDyn f = (*this)[std::string("fields")];
        if (f.has_value()) return f;
        // Otherwise the BallDyn itself IS the fields map (e.g. metadata).
        return *this;
    }

    // BallGenerator.values / protobuf ListValue.values — access the values list.
    BallDyn values() const {
        // BallGenerator: return a copy of the accumulated values list.
        if (_val.type() == typeid(BallGenerator)) {
            return BallDyn(BallList(*std::any_cast<const BallGenerator&>(_val).values));
        }
        // Protobuf ListValue JSON shape: {"values": [...]}
        BallDyn v = (*this)[std::string("values")];
        if (v.has_value()) return v;
        // If this IS a list, return self.
        if (_isList()) return *this;
        return BallDyn();
    }

    bool has(const BallDyn& key) const;
    bool has(const std::string& key) const;
    BallDyn lookup(const BallDyn& key) const;
    BallDyn lookup(const std::string& key) const;
    BallDyn yield_(const BallDyn& val) const;
    BallDyn yieldAll(const BallDyn& items) const;
    template<typename T>
    void init(const T&) const {}
};

inline BallDyn ball_dispatch_not_found() {
    return BallDyn(std::any(BallDispatchNotFound{}));
}
inline bool ball_is_dispatch_not_found(const BallDyn& v) {
    return v._val.has_value() && v._val.type() == typeid(BallDispatchNotFound);
}

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
        // Register the reference-semantic list deref hook so helpers in
        // ball_emit_runtime.h (which can't name BallListRef) reach the underlying
        // vector of shared_ptr-backed program lists.
        _BallRefDeref::_list_fn = [](const std::any& v) -> const std::vector<std::any>* {
            if (v.type() == typeid(BallListRef)) return std::any_cast<const BallListRef&>(v).get();
            return nullptr;
        };
        _BallRefDeref::_obj_map_fn = [](const std::any& v) -> const std::map<std::string, std::any>* {
            if (v.type() == typeid(BallObjectRef)) {
                const BallObjectRef& ref = std::any_cast<const BallObjectRef&>(v);
                if (ref) return &static_cast<const BallMap&>(*ref);
            }
            return nullptr;
        };
    }
};
static _BallDynUnwrapRegistrar _ball_dyn_unwrap_registrar;
}

// Free deref helper: pointer to the underlying vector whether `u` (already an
// UNWRAPPED std::any) holds the list by-value or shared_ptr-backed. nullptr else.
inline const BallList* _ballAnyListPtr(const std::any& u) {
    if (u.type() == typeid(BallListRef)) return std::any_cast<const BallListRef&>(u).get();
    if (u.type() == typeid(BallList)) return &std::any_cast<const BallList&>(u);
    return nullptr;
}
inline BallList* _ballAnyListPtr(std::any& u) {
    if (u.type() == typeid(BallListRef)) return std::any_cast<BallListRef&>(u).get();
    if (u.type() == typeid(BallList)) return &std::any_cast<BallList&>(u);
    return nullptr;
}

// Coerce a std::any into a BallMap, unwrapping a BallDyn first if MSVC stored
// the BallDyn inside the std::any. Used by BallObject's constructor so that
// `BallObject(typeName, super, fields, methods)` accepts BallDyn field values.
inline BallMap _ballAnyToMap(const std::any& v) {
    const std::any& u = _BallDynUnwrapper::unwrap(v);
    if (!u.has_value()) return {};
    if (u.type() == typeid(BallMap)) return std::any_cast<const BallMap&>(u);
    if (u.type() == typeid(BallObject)) {
        return static_cast<const BallMap&>(std::any_cast<const BallObject&>(u));
    }
    if (u.type() == typeid(BallObjectRef)) {
        const BallObjectRef& ref = std::any_cast<const BallObjectRef&>(u);
        if (ref) return static_cast<const BallMap&>(*ref);
        return {};
    }
    if (u.type() == typeid(std::unordered_map<std::string, std::any>)) {
        BallMap r;
        for (const auto& [k, val] : std::any_cast<const std::unordered_map<std::string, std::any>&>(u)) {
            r[k] = val;
        }
        return r;
    }
    // Insertion-ordered map, by value OR shared_ptr-backed (the engine builds
    // instance fields / records as a BallOrderedMap that becomes a
    // BallOrderedMapRef once wrapped in a BallDyn). Without this case every
    // BallObject built from such a field set would lose ALL its fields.
    if (u.type() == typeid(BallOrderedMap) || u.type() == typeid(BallOrderedMapRef)) {
        const BallOrderedMap* omp = (u.type() == typeid(BallOrderedMap))
            ? &std::any_cast<const BallOrderedMap&>(u)
            : std::any_cast<const BallOrderedMapRef&>(u).get();
        BallMap r;
        if (omp) for (const auto& [k, val] : omp->entries_) r[k] = val;
        return r;
    }
    return {};
}

// addAll on a BallDyn receiver (e.g. cascade `map..addAll(other)`). Mutates the
// receiver in place: merges map entries, or appends list elements.
inline void ball_add_all(BallDyn& dst, const BallDyn& src) {
    std::any s = static_cast<std::any>(src);
    const std::any& su = _BallDynUnwrapper::unwrap(s);
    if (!su.has_value()) return;
    if (su.type() == typeid(BallMap)) {
        for (const auto& [k, v] : std::any_cast<const BallMap&>(su)) dst.set(k, v);
    } else if (su.type() == typeid(std::unordered_map<std::string, std::any>)) {
        for (const auto& [k, v] : std::any_cast<const std::unordered_map<std::string, std::any>&>(su)) dst.set(k, v);
    } else if (su.type() == typeid(BallOrderedMap)) {
        // Insertion-ordered map source (the engine's untyped MessageCreation
        // builds its field set as a BallOrderedMap). Without this the merge
        // copies nothing and every untyped message creation yields an empty map.
        for (const auto& [k, v] : std::any_cast<const BallOrderedMap&>(su).entries_) dst.set(k, v);
    } else if (su.type() == typeid(BallOrderedMapRef)) {
        if (const BallOrderedMapRef& ref = std::any_cast<const BallOrderedMapRef&>(su))
            for (const auto& [k, v] : ref->entries_) dst.set(k, v);
    } else if (const BallList* lp = _ballAnyListPtr(su)) {
        for (const auto& el : *lp) dst.push_back(el);
    }
}

// addAll into a BallOrderedMap receiver. A cascade whose target is an
// insertion-ordered map literal (`{}..addAll(other)`) emits a named
// `BallOrderedMap __cascade_self__` local, which does NOT bind to the
// `ball_add_all(BallDyn&, …)` overload above. Merge the source map's entries
// directly so the ordered map is mutated in place. (self-host engine #19)
inline void ball_add_all(BallOrderedMap& dst, const BallDyn& src) {
    std::any s = static_cast<std::any>(src);
    const std::any& su = _BallDynUnwrapper::unwrap(s);
    if (!su.has_value()) return;
    if (su.type() == typeid(BallOrderedMap)) {
        for (const auto& [k, v] : std::any_cast<const BallOrderedMap&>(su))
            dst[k] = v;
    } else if (su.type() == typeid(BallOrderedMapRef)) {
        if (const BallOrderedMapRef& ref = std::any_cast<const BallOrderedMapRef&>(su))
            for (const auto& [k, v] : ref->entries_) dst[k] = v;
    } else if (su.type() == typeid(BallMap)) {
        for (const auto& [k, v] : std::any_cast<const BallMap&>(su)) dst[k] = v;
    } else if (su.type() == typeid(std::unordered_map<std::string, std::any>)) {
        for (const auto& [k, v] :
             std::any_cast<const std::unordered_map<std::string, std::any>&>(su))
            dst[k] = v;
    }
}

// list.clear() / map.clear() — mutate the receiver in place to empty.
inline void ball_clear(BallDyn& v) {
    if (BallList* lp = v._listPtr()) lp->clear();
    else if (v._val.type() == typeid(BallMap)) std::any_cast<BallMap&>(v._val).clear();
    else if (v._val.type() == typeid(std::unordered_map<std::string, std::any>))
        std::any_cast<std::unordered_map<std::string, std::any>&>(v._val).clear();
}
inline void ball_clear(BallDyn&&) {}  // rvalue receiver: nothing to clear

// map.putIfAbsent(key, ifAbsent): Dart's signature takes a factory callable
// (`V Function()`), not a value, so the third argument is invoked lazily only
// when the key is absent. Templated to accept either a C++ lambda or a BallDyn
// function value.
template <typename F>
inline BallDyn ball_map_put_if_absent(BallDyn& m, const BallDyn& key, F ifAbsent) {
    std::string k = static_cast<std::string>(key);
    if (m.count(k) == 0) m.set(k, static_cast<std::any>(BallDyn(ifAbsent())));
    return m[k];
}
template <typename F>
inline BallDyn ball_map_put_if_absent(BallDyn&& m, const BallDyn& key, F ifAbsent) {
    std::string k = static_cast<std::string>(key);
    return m.count(k) == 0 ? BallDyn(ifAbsent()) : m[k];
}

// StringBuffer write helpers — the compiler lowers `sb.write(x)` etc. to free
// calls `write(sb, x)`. sb wraps a shared_ptr-backed BallStringBuffer, so all
// appends through any alias accumulate into the same string (conformance
// 140/150). Returns the buffer for cascade chaining.
inline std::string* _ball_strbuf_ptr(const BallDyn& sb) {
    std::any a = static_cast<std::any>(sb);
    const std::any& u = _BallDynUnwrapper::unwrap(a);
    if (u.type() == typeid(BallStringBuffer))
        return std::any_cast<const BallStringBuffer&>(u).buf.get();
    return nullptr;
}
inline BallDyn write(const BallDyn& sb, const BallDyn& value) {
    if (auto* p = _ball_strbuf_ptr(sb)) *p += ball_to_string(value);
    return sb;
}
inline BallDyn writeln(const BallDyn& sb, const BallDyn& value) {
    if (auto* p = _ball_strbuf_ptr(sb)) { *p += ball_to_string(value); *p += "\n"; }
    return sb;
}
inline BallDyn writeln(const BallDyn& sb) {
    if (auto* p = _ball_strbuf_ptr(sb)) *p += "\n";
    return sb;
}
inline BallDyn writeCharCode(const BallDyn& sb, const BallDyn& code) {
    if (auto* p = _ball_strbuf_ptr(sb)) {
        int64_t c = static_cast<int64_t>(code);
        // UTF-16 code unit in the BMP → a single char (sufficient for the
        // ASCII/Latin conformance cases). Astral planes are out of scope here.
        p->push_back(static_cast<char>(c & 0xFF));
    }
    return sb;
}
inline BallDyn writeAll(const BallDyn& sb, const BallDyn& items) {
    if (auto* p = _ball_strbuf_ptr(sb)) {
        for (const auto& e : items) *p += ball_to_string(BallDyn(e));
    }
    return sb;
}
inline BallDyn ball_strbuf_clear(const BallDyn& sb) {
    if (auto* p = _ball_strbuf_ptr(sb)) p->clear();
    return sb;
}

// Generator yields — the engine calls `gen.yield_(v)` / `gen.yieldAll(xs)`,
// which the compiler lowers to free calls `yield_(gen, v)` / `yieldAll(gen, xs)`.
// gen wraps a BallGenerator (reference type), so pushes mutate the shared list.
inline BallDyn yield_(const BallDyn& gen, const BallDyn& value) {
    // Materialize the std::any into a NAMED local first. Passing the temporary
    // `static_cast<std::any>(gen)` directly to unwrap() returns a reference that
    // dangles once the full-expression's temporary is destroyed — the type-test
    // below then reads `void` and every yield is silently dropped (empty
    // generator). Binding the temporary to `genAny` keeps it alive across the
    // unwrap + push_back.
    std::any genAny = static_cast<std::any>(gen);
    const std::any& u = _BallDynUnwrapper::unwrap(genAny);
    if (u.type() == typeid(BallGenerator)) {
        std::any_cast<const BallGenerator&>(u).values->push_back(static_cast<std::any>(value));
    }
    return BallDyn();
}
inline BallDyn yieldAll(const BallDyn& gen, const BallDyn& items) {
    // See yield_(): unwrap must operate on a named local, not a temporary.
    std::any genAny = static_cast<std::any>(gen);
    const std::any& u = _BallDynUnwrapper::unwrap(genAny);
    if (u.type() == typeid(BallGenerator)) {
        auto& vals = *std::any_cast<const BallGenerator&>(u).values;
        for (const auto& it : items) vals.push_back(static_cast<std::any>(it));
    }
    return BallDyn();
}

// ── Out-of-class definitions for BallDyn member methods ──
// These are defined here (after the free functions and scope helpers they
// depend on) because the class body can only forward-declare them.

// Forward declarations for scope helpers (defined later in this file).
inline bool _ball_scope_has_key(const BallDyn& scope, const std::string& key);
inline BallScope _ball_get_parent_scope(const BallDyn& scope);

// BallDyn::has — scope has-key check with parent chain walk.
inline bool BallDyn::has(const BallDyn& key) const {
    return has(static_cast<std::string>(key));
}
inline bool BallDyn::has(const std::string& key) const {
    // Check current scope
    if (_ball_scope_has_key(*this, key)) return true;
    // Check _bindings sub-map
    auto bindings = (*this)[std::string("_bindings")];
    if (bindings.has_value() && BallDyn(bindings)[key].has_value()) return true;
    // Walk parent chain via BallScope shared_ptr
    BallScope parent = _ball_get_parent_scope(*this);
    while (parent) {
        if (parent->count(key) > 0) return true;
        auto it = parent->find("__parent__");
        if (it != parent->end() && it->second.type() == typeid(BallScope)) {
            parent = std::any_cast<const BallScope&>(it->second);
        } else {
            break;
        }
    }
    // Legacy fallback: __parent__ stored as value copy
    if (!parent) {
        auto parentVal = (*this)[std::string("__parent__")];
        if (!parentVal.has_value()) parentVal = (*this)[std::string("_parent")];
        if (parentVal.has_value()) return parentVal.has(key);
    }
    return false;
}

// BallDyn::lookup — scope key lookup with parent chain walk.
inline BallDyn BallDyn::lookup(const BallDyn& key) const {
    return lookup(static_cast<std::string>(key));
}
inline BallDyn BallDyn::lookup(const std::string& key) const {
    // Check direct binding
    if (_ball_scope_has_key(*this, key)) return (*this)[key];
    // Check _bindings sub-map
    auto bindings = (*this)[std::string("_bindings")];
    if (bindings.has_value()) {
        auto val = BallDyn(bindings)[key];
        if (val.has_value()) return val;
    }
    // Walk parent chain via BallScope shared_ptr
    BallScope parent = _ball_get_parent_scope(*this);
    while (parent) {
        auto it = parent->find(key);
        if (it != parent->end()) return BallDyn(it->second);
        auto pit = parent->find("__parent__");
        if (pit != parent->end() && pit->second.type() == typeid(BallScope)) {
            parent = std::any_cast<const BallScope&>(pit->second);
        } else {
            break;
        }
    }
    // Legacy fallback
    if (!parent) {
        auto parentVal = (*this)[std::string("__parent__")];
        if (!parentVal.has_value()) parentVal = (*this)[std::string("_parent")];
        if (parentVal.has_value()) return parentVal.lookup(key);
    }
    return BallDyn();
}

// BallDyn::yield_ — delegate to the free yield_(gen, val).
inline BallDyn BallDyn::yield_(const BallDyn& val) const {
    return ::yield_(*this, val);
}

// BallDyn::yieldAll — delegate to the free yieldAll(gen, items).
inline BallDyn BallDyn::yieldAll(const BallDyn& items) const {
    return ::yieldAll(*this, items);
}

// Dart's Iterable.indexWhere(test) — first index where test(el) is truthy, else -1.
template <typename Fn>
inline int64_t indexWhere(const BallDyn& list, Fn pred) {
    int64_t i = 0;
    for (const auto& el : list) {
        if (static_cast<bool>(pred(BallDyn(el)))) return i;
        ++i;
    }
    return -1;
}

// Stream output
inline std::ostream& operator<<(std::ostream& os, const BallDyn& d) {
    return os << static_cast<std::string>(d);
}

// ball_to_string overload for BallDyn
inline std::string ball_to_string(const BallDyn& d) {
    return static_cast<std::string>(d);
}

// ball_to_string overloads for raw container values. A map/list literal in
// expression position can compile to an IIFE returning the bare container
// (not wrapped in BallDyn) — e.g. `print({'evens': [2, 4]})` — which
// otherwise falls into the generic std::to_string template and fails to
// compile (conformance 350). Delegate to BallDyn's Dart-style rendering.
inline std::string ball_to_string(const BallOrderedMap& m) {
    return ball_to_string(BallDyn(m));
}
inline std::string ball_to_string(const BallList& l) {
    return ball_to_string(BallDyn(l));
}

// Assignment-as-expression for plain (non-field/index) targets. `std::string =
// BallDyn` is ambiguous under gcc/clang: BallDyn->std::string and BallDyn->char
// go through different conversion operators, so std::string::operator=(const
// string&) and operator=(char) are indistinguishable user-conversion sequences.
// Route a std::string target through ball_to_string; every other target type
// assigns directly. Returns the assigned value, since Dart `=` is an expression.
template <typename T, typename U>
inline T& ball_assign(T& target, U&& value) {
    if constexpr (std::is_same_v<T, std::string>) {
        // std::string = BallDyn is ambiguous under gcc/clang (the
        // BallDyn->std::string and BallDyn->char user conversions go through
        // different operators). Route through ball_to_string. A single template
        // with if-constexpr avoids the overload-resolution race where an rvalue
        // value binds to the generic `U&&` rather than a `const BallDyn&`.
        target = ball_to_string(value);
    } else {
        target = std::forward<U>(value);
    }
    return target;
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

// bind/child/resolve overloads for BallDyn.
// Exact-match string-key overloads beat std::bind (ADL template) for emitted
// `bind(scope, "self"s, self)` — fixes the self-binding gate in method bodies.
// Definition of the jsonEncode(BallDyn) overload forward-declared in
// ball_emit_runtime.h ("defined in ball_dyn.h"). It was never actually defined,
// which only surfaced once _validateProgramLimits (which reaches it via
// writeToBuffer) became linker-reachable — the engine's program-size limit
// check. Delegate to the std::any overload (a best-effort byte-size estimate).
inline std::string jsonEncode(const BallDyn& value) {
    return jsonEncode(value._val);
}

// Local-only scope write for DECLARATIONS (let / params / loop vars / pattern
// bindings). Unlike BallDyn::set — which performs LEXICAL ASSIGNMENT and walks
// the __parent__ chain to the scope that already owns the name — a declaration
// must ALWAYS bind in the CURRENT scope, so an inner block's `let x` SHADOWS an
// outer `x` instead of overwriting it. Mirrors Dart _Scope.bind (writes to the
// local _bindings). Without this, after BallDyn::set learned to walk parents,
// every `let` in a nested block leaked to the enclosing scope.
// (self-host conformance 55_scope_variable)
inline void _ball_bind_local(BallDyn& scope, const std::string& name, const std::any& value) {
    const std::any& u = _BallDynUnwrapper::unwrap(value);
    if (scope._val.type() == typeid(BallScope)) {
        (*std::any_cast<BallScope&>(scope._val))[name] = u;
        return;
    }
    if (scope._val.type() == typeid(BallMap)) {
        std::any_cast<BallMap&>(scope._val)[name] = u;
        return;
    }
    if (scope._val.type() == typeid(BallOrderedMap)) {
        std::any_cast<BallOrderedMap&>(scope._val)[name] = u;
        return;
    }
    if (scope._val.type() == typeid(BallOrderedMapRef)) {
        auto& ref = std::any_cast<BallOrderedMapRef&>(scope._val);
        if (ref) (*ref)[name] = u;
        return;
    }
    scope.set(name, value);  // object / not-yet-allocated scope: fall back
}
inline BallDyn ball_scope_bind(BallDyn& scope, const std::string& name, const BallDyn& value) {
    _ball_bind_local(scope, name, value._val);
    return BallDyn();
}
inline BallDyn ball_scope_bind(BallDyn& scope, const BallDyn& name, const BallDyn& value) {
    _ball_bind_local(scope, static_cast<std::string>(name), value._val);
    return BallDyn();
}
inline BallDyn bind(BallDyn& scope, const std::any& name, const std::any& value) {
    _ball_bind_local(scope, ball_to_string(name), value);
    return BallDyn();
}
inline BallDyn bind(BallDyn& scope, const BallDyn& name, const BallDyn& value) {
    _ball_bind_local(scope, static_cast<std::string>(name), value._val);
    return BallDyn();
}
inline BallDyn bind(BallDyn& scope, const std::string& name, const BallDyn& value) {
    _ball_bind_local(scope, name, value._val);
    return BallDyn();
}
inline BallDyn bind(BallDyn& scope, const std::string& name, const std::any& value) {
    _ball_bind_local(scope, name, value);
    return BallDyn();
}
inline BallDyn bind(BallDyn& scope, const char* name, const BallDyn& value) {
    _ball_bind_local(scope, std::string(name), value._val);
    return BallDyn();
}
inline BallDyn bind(BallDyn& scope, const char* name, const std::any& value) {
    _ball_bind_local(scope, std::string(name), value);
    return BallDyn();
}
// child() creates a new scope linked to the parent with reference semantics.
// Takes by REFERENCE so that upgrading a BallMap parent to BallScope (shared_ptr)
// happens in-place on the caller's variable — mutations through the child's
// parent chain then propagate back to the original scope.
inline BallDyn child(BallDyn& scope) {
    // Upgrade parent IN PLACE to BallScope for reference semantics
    if (scope._val.type() == typeid(BallMap)) {
        auto sp = std::make_shared<BallMap>(std::move(std::any_cast<BallMap&>(scope._val)));
        scope._val = std::any(sp);
    }
    BallScope parentScope;
    if (scope._val.type() == typeid(BallScope)) {
        parentScope = std::any_cast<const BallScope&>(scope._val);
    }
    auto childMap = std::make_shared<BallMap>();
    if (parentScope) {
        (*childMap)["__parent__"] = std::any(parentScope);
    }
    return BallDyn(std::any(childMap));
}
// Rvalue overload for temporaries like child(BallDyn(_globalScope))
inline BallDyn child(BallDyn&& scope) {
    return child(scope);
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
// BallGenerator is a real runtime struct (ball_emit_runtime.h) with a shared
// values list — NOT a BallDyn stub — so sync*/async* yields mutate shared state.
BALL_DYN_STUB(_ExitSignal);
BALL_DYN_STUB(BallModuleHandler);
BALL_DYN_STUB(StdModuleHandler);

#undef BALL_DYN_STUB

// ── User-class method receiver recovery ──
// A user-class instance may arrive as its concrete struct type (T) or boxed
// inside a BallDyn (stored in a collection, returned from a cascade IIFE, or
// aliased through an untyped `final x = obj` binding). `ball_obj_as<T>(self)`
// yields a `T&` in both cases so `ball_obj_as<T>(self).method(...)` compiles
// uniformly (conformance 111; also used for factory return conversion, 106).
// When the value is stored reference-semantically via BallUserRef
// (shared_ptr<std::any>), dereference through the shared_ptr first.
template<class T> inline T& ball_obj_as(BallDyn& d) {
    // BallDyn-derived stub types (_Scope, _FlowSignal, BallModuleHandler, …) ARE
    // BallDyns: their data lives in BallDyn::_val (a BallMap/scope), and their
    // "methods" are BallDyn members. Unwrapping `_val` with `any_cast<T&>` would
    // throw bad_any_cast (the any holds a BallMap, not a T). Instead reinterpret
    // the BallDyn as the stub so `.has()/.lookup()/.set()/.child()` dispatch
    // against the SAME `_val` (mutations persist). (self-host engine #19)
    if constexpr (std::is_base_of_v<BallDyn, T>) {
        return static_cast<T&>(d);
    } else {
        if (d._val.type() == typeid(BallUserRef))
            return std::any_cast<T&>(*std::any_cast<BallUserRef&>(d._val));
        return std::any_cast<T&>(d._val);
    }
}
template<class T> inline const T& ball_obj_as(const BallDyn& d) {
    if constexpr (std::is_base_of_v<BallDyn, T>) {
        return static_cast<const T&>(d);
    } else {
        if (d._val.type() == typeid(BallUserRef))
            return std::any_cast<const T&>(*std::any_cast<const BallUserRef&>(d._val));
        return std::any_cast<const T&>(d._val);
    }
}
template<class T, class U,
         std::enable_if_t<!std::is_same_v<std::decay_t<U>, BallDyn>, int> = 0>
inline U&& ball_obj_as(U&& u) {
    return std::forward<U>(u);
}

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
           mod.empty();
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
inline bool identical(const std::any& a, const std::any& b) {
    const std::any& ua = _BallDynUnwrapper::unwrap(a);
    const std::any& ub = _BallDynUnwrapper::unwrap(b);
    if (_ball_any_is_object(ua) || _ball_any_is_object(ub)) {
        return BallDyn(a) == BallDyn(b);
    }
    return ball_to_string(a) == ball_to_string(b);
}

// File/Directory constructors from BallDyn
inline File::File(const BallDyn& p) : path(ball_to_string(p)) {}
inline Directory::Directory(const BallDyn& p) : path(ball_to_string(p)) {}
inline void writeAsStringSync(const File& f, const BallDyn& content, const std::any&) {
    std::ofstream ofs(f.path);
    ofs << ball_to_string(content);
}

// setAll — Dart's List.setAll(index, iterable): copy elements into list
inline void setAll(BallDyn& target, int64_t index, const BallDyn& source) {
    BallList* dstp = target._listPtr();
    const BallList* srcp = source._listPtr();
    if (dstp && srcp) {
        auto& dst = *dstp;
        const auto& src = *srcp;
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

// ── Dart-semantic length / substring / codeUnitAt on a BallDyn ──
// For STRINGS these use UTF-16 code-unit indexing (Dart parity, ASCII fast path);
// for lists/maps `ball_length` falls back to element count. The string helpers
// take a BallDyn so the compiler can emit them uniformly for `s.length` /
// `s.substring(...)` without first knowing the static type.
inline int64_t ball_length(const BallDyn& v) {
    if (v._val.type() == typeid(std::string))
        return ball_u16_length(std::any_cast<const std::string&>(v._val));
    return v.size();  // list / map / set / scope element count
}
// Overloads for statically-typed receivers so `.length` keeps compiling when the
// compiler knows the concrete type (raw std::string, or a typed container).
inline int64_t ball_length(const std::string& s) { return ball_u16_length(s); }
template<typename T>
inline int64_t ball_length(const std::vector<T>& v) { return static_cast<int64_t>(v.size()); }
template<typename K, typename V>
inline int64_t ball_length(const std::map<K, V>& m) { return static_cast<int64_t>(m.size()); }
inline std::string ball_string_substring(const BallDyn& v, int64_t start, const BallDyn& end = BallDyn()) {
    std::string s = static_cast<std::string>(v);
    return ball_u16_substring(s, start, end.has_value() ? static_cast<int64_t>(end) : -1);
}
inline int64_t ball_code_unit_at(const BallDyn& v, int64_t i) {
    return ball_u16_code_unit_at(static_cast<std::string>(v), i);
}

// ── Dart double property helpers (BallDyn overloads) ──
inline bool ball_isNaN(const BallDyn& v) {
    if (v._val.type() == typeid(double)) return ball_isNaN(std::any_cast<double>(v._val));
    return false;
}
inline bool ball_isInfinite(const BallDyn& v) {
    if (v._val.type() == typeid(double)) return ball_isInfinite(std::any_cast<double>(v._val));
    return false;
}
inline bool ball_isFinite(const BallDyn& v) {
    if (v._val.type() == typeid(double)) return ball_isFinite(std::any_cast<double>(v._val));
    if (v._val.type() == typeid(int64_t)) return true;
    return false;
}
inline bool ball_isNegative(const BallDyn& v) {
    if (v._val.type() == typeid(double)) return ball_isNegative(std::any_cast<double>(v._val));
    if (v._val.type() == typeid(int64_t)) return std::any_cast<int64_t>(v._val) < 0;
    return false;
}

// ── Dart `identical(a, b)` — BallDyn overload ──
inline bool ball_identical(const BallDyn& a, const BallDyn& b) {
    return ball_identical(a._val, b._val);
}

// ── Reified generics: BallDyn overload ──
inline bool ball_type_args_match(const BallDyn& value, const std::string& expected) {
    return ball_type_args_match(value._val, expected);
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
    if (const BallList* lp = bytes._listPtr()) return c.decode(*lp);
    return "";
}
inline std::string encode(const Base64Codec& c, const BallDyn& bytes) {
    if (const BallList* lp = bytes._listPtr()) return c.encode(*lp);
    return "";
}
inline std::vector<std::any> decode(const Base64Codec& c, const BallDyn& s) {
    return c.decode(static_cast<std::string>(s));
}

// Definition of the forward-declared Dart-style ordered-map stringify
// (declared just before `class BallDyn`). Recognizes the portable ordered-
// set tag and renders `{a, b, c}` (Dart Set literal) instead of the generic
// `{key: value}` map shape — issue #174.
inline std::string _ball_ordered_map_to_string(const BallOrderedMap& omp) {
    if (omp.size() == 1) {
        auto it = omp.find("__ball_set__");
        if (it != omp.end()) {
            const std::any& raw = it->second;
            const BallList* items = nullptr;
            if (raw.type() == typeid(BallListRef)) items = std::any_cast<const BallListRef&>(raw).get();
            else if (raw.type() == typeid(BallList)) items = &std::any_cast<const BallList&>(raw);
            std::string out = "{";
            bool first = true;
            if (items) {
                for (const auto& v : *items) {
                    if (!first) out += ", ";
                    out += ball_to_string(v);
                    first = false;
                }
            }
            out += "}";
            return out;
        }
    }
    std::string out = "{";
    bool first = true;
    for (const auto& [k, v] : omp.entries_) {
        if (k.find("__") == 0 || k == "type_args") continue;
        if (!first) out += ", ";
        out += k + ": " + ball_to_string(v);
        first = false;
    }
    out += "}";
    return out;
}

// Build the portable ordered-set value from [items], deduping by BallDyn
// equality while preserving first-seen (insertion) order — the Set-literal
// construction semantics (`{1, 2, 3}`, `{3, 1, 2, 1, 3}` -> `{3, 1, 2}`) for
// the direct-compile C++ path (issue #174). Mirrors `_ballSetOf` in the Dart
// reference engine (dart/engine/lib/engine_std.dart) and its self-hosted
// compiled equivalent.
inline BallDyn ball_make_set(const BallList& items) {
    BallList deduped;
    for (const auto& item : items) {
        BallDyn e(item);
        bool found = false;
        for (const auto& x : deduped) {
            if (BallDyn(x) == e) { found = true; break; }
        }
        if (!found) deduped.push_back(item);
    }
    BallOrderedMap m;
    m["__ball_set__"] = std::any(BallListRef(std::make_shared<BallList>(std::move(deduped))));
    return BallDyn(std::move(m));
}

// Extract the elements of a BallDyn list OR the portable ordered-set value
// as a plain BallList snapshot — the common receiver-normalization step for
// Set.of/from and the algebraic set ops below (issue #174).
inline BallList _ball_set_or_list_elements(const BallDyn& v) {
    if (const BallList* lp = v._listPtr()) return *lp;
    if (const BallList* lp = v._setBackingList()) return *lp;
    return BallList{};
}

// ── ball_to_set(BallDyn) ──
inline BallDyn ball_to_set(const BallDyn& d) {
    return ball_make_set(_ball_set_or_list_elements(d));
}

// ── Set operations on BallDyn. Both operands may be a List or the portable
// ordered-set value; the RESULT is always a proper tagged Set (Dart-style
// `{...}` print, not a raw `[...]` list) — issue #174. ──
inline BallDyn union_(const BallDyn& a, const BallDyn& b) {
    BallList sa = _ball_set_or_list_elements(a);
    BallList sb = _ball_set_or_list_elements(b);
    for (auto& e : sb) {
        bool found = false;
        for (auto& x : sa) { if (ball_to_string(x) == ball_to_string(e)) { found = true; break; } }
        if (!found) sa.push_back(e);
    }
    return ball_make_set(sa);
}
inline BallDyn intersection(const BallDyn& a, const BallDyn& b) {
    BallList sa = _ball_set_or_list_elements(a);
    BallList sb = _ball_set_or_list_elements(b);
    BallList result;
    for (auto& e : sa) {
        for (auto& x : sb) { if (ball_to_string(x) == ball_to_string(e)) { result.push_back(e); break; } }
    }
    return ball_make_set(result);
}
inline BallDyn difference(const BallDyn& a, const BallDyn& b) {
    BallList sa = _ball_set_or_list_elements(a);
    BallList sb = _ball_set_or_list_elements(b);
    BallList result;
    for (auto& e : sa) {
        bool found = false;
        for (auto& x : sb) { if (ball_to_string(x) == ball_to_string(e)) { found = true; break; } }
        if (!found) result.push_back(e);
    }
    return ball_make_set(result);
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
    if (const BallList* lp = v._listPtr()) {
        return BallDyn(ball_take(*lp, n));
    }
    return v;
}
inline BallDyn ball_skip(const BallDyn& v, int64_t n) {
    if (const BallList* lp = v._listPtr()) {
        return BallDyn(ball_skip(*lp, n));
    }
    return v;
}

// ── Caught-exception reconstruction ──
// Rebuild the engine's BallException value-shape from a thrown C++
// BallException so catch bodies can read `e["value"]` / `e["typeName"]` and
// `e is BallException` (ball_object_type_matches(e, "BallException")) works.
// Defined here (end of ball_dyn.h) because they return a BallDyn; BallException
// itself is declared earlier in ball_emit_runtime.h (always spliced first).
inline BallDyn _ball_exception_to_dyn(const BallException& e) {
    // A bare scalar throw (`throw "msg"` / `throw 42`) with no structured
    // fields: the caught variable should BE that scalar so a filter like
    // `catch (e) { if (e == "recoverable") ... }` matches Dart semantics
    // (conformance 222). Structured throws keep the reified map shape.
    if (e.has_payload && e.fields.empty()) {
        const std::any& pu = _BallDynUnwrapper::unwrap(e.value);
        if (pu.type() == typeid(std::string) || pu.type() == typeid(int64_t) ||
            pu.type() == typeid(double) || pu.type() == typeid(bool)) {
            BallDyn sv; sv._val = e.value; return sv;
        }
    }
    std::map<std::string, std::any> m;
    m["__type__"] = std::any(std::string("BallException"));
    m["typeName"] = std::any(e.type_name);
    m["value"] = e.has_payload ? e.value : std::any(std::string(e.what()));
    m["message"] = std::any(std::string(e.what()));
    BallDyn d;
    d._val = std::any(std::move(m));
    return d;
}
inline BallDyn _ball_caught_to_dyn(const std::exception& ex) {
    if (auto* be = dynamic_cast<const BallException*>(&ex))
        return _ball_exception_to_dyn(*be);
    return BallDyn(std::string(ex.what()));
}

// ── Insertion-ordered map helpers (Dart LinkedHashMap / runtime map_create) ──
inline const BallOrderedMap* _ballAnyOrderedMapPtr(const std::any& u) {
    if (u.type() == typeid(BallOrderedMapRef))
        return std::any_cast<const BallOrderedMapRef&>(u).get();
    if (u.type() == typeid(BallOrderedMap))
        return &std::any_cast<const BallOrderedMap&>(u);
    return nullptr;
}
inline BallOrderedMap* _ballAnyOrderedMapPtr(std::any& u) {
    if (u.type() == typeid(BallOrderedMapRef))
        return std::any_cast<BallOrderedMapRef&>(u).get();
    if (u.type() == typeid(BallOrderedMap))
        return &std::any_cast<BallOrderedMap&>(u);
    return nullptr;
}

// Register BallOrderedMap extensions for runtime helpers in ball_emit_runtime.h.
inline const bool _ball_ordered_map_extensions_registered = []() {
    _ball_is_map_ext = [](const std::any& u) -> bool {
        return _ballAnyOrderedMapPtr(u) != nullptr;
    };
    _ball_to_string_ext = [](const std::any& v) -> std::string {
        const BallOrderedMap* omp = _ballAnyOrderedMapPtr(v);
        if (!omp) return "";
        // Shared with BallDyn::operator std::string() so a Set nested inside a
        // List/Map (a bare std::any element, not a BallDyn) ALSO renders
        // Dart-style (`{a, b, c}`), not as the generic map shape — issue #174.
        return _ball_ordered_map_to_string(*omp);
    };
    _ball_json_encode_ext_fn = [](const std::any& u) -> std::string {
        const BallOrderedMap* omp = _ballAnyOrderedMapPtr(u);
        if (!omp) return "";
        std::string out = "{";
        bool first = true;
        for (const auto& [k, v] : omp->entries_) {
            if (k.rfind("__", 0) == 0 || k == "type_args") continue;
            if (!first) out += ",";
            out += _ball_json_escape(k) + ":" + _ball_json_encode(v);
            first = false;
        }
        out += "}";
        return out;
    };
    _ball_object_type_matches_ext = [](const std::any& u, const std::string& type) -> bool {
        const BallOrderedMap* omp = _ballAnyOrderedMapPtr(u);
        if (!omp) return false;
        auto it = omp->index_.find("__type__");
        if (it == omp->index_.end()) return false;
        auto& tv = _BallDynUnwrapper::unwrap(omp->entries_[it->second].second);
        if (tv.type() == typeid(std::string)) {
            if (ball_type_name_matches(std::any_cast<const std::string&>(tv), type))
                return true;
        }
        auto sit = omp->index_.find("__super__");
        if (sit != omp->index_.end()) {
            return ball_object_type_matches(omp->entries_[sit->second].second, type);
        }
        return false;
    };
    // Typed-map discrimination for BallOrderedMap: mirror the BallMap path of
    // ball_is_typed_map (empty->matches any; else inspect first value's concrete
    // type; else delegate to ball_object_type_matches). Resolves `is Map<K,V>`
    // checks on the now-default insertion-ordered map type with zero regression.
    _ball_typed_map_ext = [](const std::any& u, const std::string& val_type) -> bool {
        const BallOrderedMap* omp = _ballAnyOrderedMapPtr(u);
        if (!omp) return false;
        if (omp->entries_.empty()) return true;  // empty map matches any type
        const auto& first_val =
            _BallDynUnwrapper::unwrap(omp->entries_.front().second);
        if (val_type == "int") return first_val.type() == typeid(int64_t);
        if (val_type == "double") return first_val.type() == typeid(double);
        if (val_type == "num")
            return first_val.type() == typeid(int64_t) ||
                   first_val.type() == typeid(double);
        if (val_type == "String") return first_val.type() == typeid(std::string);
        if (val_type == "bool") return first_val.type() == typeid(bool);
        return ball_object_type_matches(first_val, val_type);
    };
    // Portable ordered-set backing-list extraction (issue #174), for
    // ball_emit_runtime.h helpers (e.g. ball_to_list) that operate on a bare
    // std::any before BallDyn is visible. Mirrors BallDyn::_setBackingList().
    _BallRefDeref::_set_list_fn = [](const std::any& v) -> const std::vector<std::any>* {
        const BallOrderedMap* omp = _ballAnyOrderedMapPtr(v);
        if (!omp || omp->size() != 1) return nullptr;
        auto it = omp->find("__ball_set__");
        if (it == omp->end()) return nullptr;
        // Accept both backings (see BallDyn::_setBackingList): a BallListRef
        // (direct-compile) or a BallDyn-wrapped plain BallList (self-host).
        const std::any* raw = &it->second;
        while (raw->type() == typeid(BallDyn))
            raw = &std::any_cast<const BallDyn&>(*raw)._val;
        if (raw->type() == typeid(BallListRef))
            return std::any_cast<const BallListRef&>(*raw).get();
        if (raw->type() == typeid(BallList))
            return &std::any_cast<const BallList&>(*raw);
        return nullptr;
    };
    return true;
}();

// ball_is_map BallDyn overload — recognizes BallOrderedMap. Named ball_is_map_dyn
// to avoid ambiguity with ball_is_map(const std::any&) via BallDyn::operator std::any().
inline bool ball_is_map_dyn(const BallDyn& v) {
    const std::any& u = _BallDynUnwrapper::unwrap(v._val);
    if (u.type() == typeid(BallOrderedMapRef)) return true;
    if (u.type() == typeid(BallOrderedMap)) return true;
    return u.has_value() &&
           (u.type() == typeid(BallMap) || _ball_any_is_object(u));
}

// True when `v` is the portable ordered-set value the Ball engine represents
// sets as on the Dart/C++ targets (`{'__ball_set__': [...]}` — a one-key map
// with the set marker). Mirrors `_ballValueIsSet` in the Dart engine source
// (dart/engine/lib/engine_types.dart). The native "is"/"is_not" dispatch
// previously had no `Set` branch and fell through to `ball_object_type_matches`
// (a `__type__`-field check a portable set map never has), so `x is Set` on a
// directly-compiled C++ Ball program always evaluated false (issue #68).
//
// Delegates to `_setBackingList()` rather than re-deriving the one-key-map
// shape via `ball_length(v) == 1`/`containsKey` (issue #174): once
// `BallDyn::size()` started reporting the WRAPPED list's element count for a
// portable set (so `.length` on a Set works), `ball_length(v)` no longer
// reflects the OUTER map's key count, and this check silently broke for
// every set with != 1 elements (`{1,2,3,4,5} is Set` -> false, `is Map` ->
// true — exactly backwards). `_setBackingList()` inspects the raw
// `BallOrderedMap` directly and is immune to that dispatch.
inline bool ball_is_ball_set(const BallDyn& v) {
    return v._setBackingList() != nullptr;
}

// Map iteration helpers — moved from compiler preamble (MSVC 64KB limit).
// Support BallMap, BallOrderedMap, and BallObject base maps.
inline BallDyn ball_map_entries(const BallDyn& v) {
    std::vector<std::any> r;
    try {
        auto a0 = static_cast<std::any>(v);
        const std::any& a = _BallDynUnwrapper::unwrap(a0);
        if (const BallOrderedMap* omp = _ballAnyOrderedMapPtr(a)) {
            for (const auto& [k, val] : omp->entries_) {
                BallMap e;
                e["key"] = std::any(k);
                e["value"] = val;
                r.push_back(std::any(e));
            }
        } else {
            const BallMap* mp = nullptr;
            if (a.type() == typeid(BallMap)) { mp = &std::any_cast<const BallMap&>(a); }
            else { mp = _ball_object_base_map(a); }
            if (mp) {
                for (const auto& [k, val] : *mp) {
                    BallMap e;
                    e["key"] = std::any(k);
                    e["value"] = val;
                    r.push_back(std::any(e));
                }
            }
        }
    } catch (...) {}
    return BallDyn(BallList(r));
}
inline BallDyn ball_map_keys(const BallDyn& v) {
    std::vector<std::any> r;
    bool matched = false;
    try {
        auto a0 = static_cast<std::any>(v);
        const std::any& a = _BallDynUnwrapper::unwrap(a0);
        if (const BallOrderedMap* omp = _ballAnyOrderedMapPtr(a)) {
            matched = true;
            for (const auto& [k, val] : omp->entries_) r.push_back(std::any(k));
        } else {
            const BallMap* mp = nullptr;
            if (a.type() == typeid(BallMap)) { mp = &std::any_cast<const BallMap&>(a); }
            else { mp = _ball_object_base_map(a); }
            if (mp) { matched = true; for (const auto& [k, val] : *mp) r.push_back(std::any(k)); }
        }
    } catch (...) {
        // Defensive: a malformed value handle can throw during unwrap/detection;
        // `matched` stays false and we fall through to the fail-loud throw below.
    }
    // Fail loud on a non-Map receiver instead of silently returning [] — the
    // Dart/TS/C++-self-host engines throw for `.keys` on a non-Map, and silent
    // degradation is the class of bug that hid issue #55 (issue #197). Thrown
    // AFTER the try so the defensive `catch(...)` above doesn't swallow it.
    if (!matched) throw BallException("TypeError", "map_keys: expected Map");
    return BallDyn(BallList(r));
}
inline BallDyn ball_map_values(const BallDyn& v) {
    std::vector<std::any> r;
    bool matched = false;
    try {
        auto a0 = static_cast<std::any>(v);
        const std::any& a = _BallDynUnwrapper::unwrap(a0);
        if (const BallOrderedMap* omp = _ballAnyOrderedMapPtr(a)) {
            matched = true;
            for (const auto& [k, val] : omp->entries_) r.push_back(val);
        } else {
            const BallMap* mp = nullptr;
            if (a.type() == typeid(BallMap)) { mp = &std::any_cast<const BallMap&>(a); }
            else { mp = _ball_object_base_map(a); }
            if (mp) { matched = true; for (const auto& [k, val] : *mp) r.push_back(val); }
        }
    } catch (...) {
        // Defensive: see ball_map_keys — unmatched input falls through to throw.
    }
    if (!matched) throw BallException("TypeError", "map_values: expected Map");
    return BallDyn(BallList(r));
}

// std_collections.list_foreach: iterate a collection, invoking `fn` per element
// for its side effects. Over a LIST, calls fn(item). Over a MAP, calls
// fn({key, value, arg0:key, arg1:value}) per entry so the callback can bind the
// key/value by name or positionally (mirrors the Dart engine). (conformance 116)
template <typename F>
inline BallDyn ball_foreach(const BallDyn& coll, F fn) {
    // Split on callback ARITY at compile time: only the matching branch is
    // instantiated, so a 2-arg map callback never has to compile `fn(item)`
    // (and vice-versa) — both runtime branches of a plain `if` would otherwise
    // be type-checked and fail for the wrong arity (conformance 119).
    if constexpr (std::is_invocable_v<F, BallDyn, BallDyn>) {
        // Dart `map.forEach((key, value) => …)` — a 2-arg callback.
        BallDyn entries = ball_map_entries(coll);
        for (size_t i = 0; i < entries.size(); i++) {
            BallDyn ent = entries[static_cast<int64_t>(i)];
            fn(BallDyn(ent["key"s]), BallDyn(ent["value"s]));
        }
    } else {
        // 1-arg callback: list items, or map entries as `{key,value,arg0,arg1}`.
        if (ball_is_map_dyn(coll)) {
            BallDyn entries = ball_map_entries(coll);
            for (size_t i = 0; i < entries.size(); i++) {
                BallDyn ent = entries[static_cast<int64_t>(i)];
                BallDyn k = ent["key"s];
                BallDyn val = ent["value"s];
                BallMap arg;
                arg["key"] = static_cast<std::any>(k);
                arg["value"] = static_cast<std::any>(val);
                arg["arg0"] = static_cast<std::any>(k);
                arg["arg1"] = static_cast<std::any>(val);
                fn(BallDyn(arg));
            }
        } else {
            for (size_t i = 0; i < coll.size(); i++) {
                fn(coll[static_cast<int64_t>(i)]);
            }
        }
    }
    return BallDyn();
}

// ── fold free function ──
// Dart's Iterable.fold(initialValue, combine) — reduce over a list.
template<typename Iter, typename Init, typename Fn>
inline BallDyn _ballFoldImpl(const Iter& iter, Init init, Fn fn) {
    BallDyn acc{std::any(init)};
    try {
        std::any a = static_cast<std::any>(BallDyn(iter));
        if (a.type() == typeid(std::vector<std::any>)) {
            const auto& v = std::any_cast<const std::vector<std::any>&>(a);
            for (const auto& el : v) acc = fn(acc, BallDyn(el));
        }
    } catch (...) {}
    return acc;
}
template<typename Iter, typename Init, typename Fn>
inline BallDyn fold(const Iter& iter, const std::string& /*type_tag*/, Init init, Fn fn) {
    return _ballFoldImpl(iter, init, fn);
}
template<typename Iter, typename Init, typename Fn>
inline BallDyn fold(const Iter& iter, Init init, Fn fn) {
    return _ballFoldImpl(iter, init, fn);
}

// ================================================================
#endif  // BALL_DYN_H
