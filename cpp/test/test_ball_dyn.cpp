// Ball C++ Runtime Tests -- BallDyn / BallOrderedMap / ball_emit_runtime.h
//
// Direct unit coverage for the compiled-program runtime (issue #63): BallDyn
// (the dynamic value type every Ball->C++ program is built on) and the
// ball_is_*/BallException/BallStringBuffer helpers it depends on in
// cpp/shared/include/ball_emit_runtime.h. Neither header is exercised by
// test_compiler/test_encoder/test_shared (those drive the COMPILER/ENCODER,
// not the emitted-program runtime), so both sat at 0% coverage despite being
// compiled into every test binary via ball_ordered_map.h -> ball_dyn.h and
// ball_shared.h -> ball_emit_runtime.h. Their heaviest real-world exercise is
// via the SEPARATE stringified ball_dyn_embed.h/ball_emit_runtime_embed.h
// copies spliced into generated programs (compiled in a non-instrumented
// subprocess by test_e2e/self-host) -- invisible to gcov. This file closes
// the gap directly, mirroring scope_probe.cpp's proven include order
// (standard headers, then ball_emit_runtime.h, then ball_dyn.h -- NOT
// ball_shared.h, which declares a competing `ball::BallMap` that collides
// with the global `::BallMap` this header defines).
#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <any>
#include <functional>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <cassert>
#include <regex>
#include <fstream>
#include <iomanip>
#include <cstdlib>
#include <memory>
#include <thread>
#include <chrono>
#include <random>
#include <limits>
#include <filesystem>
#include <atomic>

using namespace std::string_literals;

#include "ball_emit_runtime.h"
#include "ball_dyn.h"

// ================================================================
// Test framework (same minimal TEST()/ASSERT_* macros as the sibling
// cpp/test/test_*.cpp files).
// ================================================================

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) \
    static void test_##name(); \
    struct Register_##name { \
        Register_##name() { \
            std::cout << "  " << #name << "... "; \
            try { \
                test_##name(); \
                std::cout << "PASS" << std::endl; \
                tests_passed++; \
            } catch (const std::exception& e) { \
                std::cout << "FAIL: " << e.what() << std::endl; \
                tests_failed++; \
            } \
            tests_run++; \
        } \
    } register_##name; \
    static void test_##name()

#define ASSERT_TRUE(cond) \
    do { \
        if (!(cond)) { \
            throw std::runtime_error( \
                std::string("ASSERT_TRUE failed: ") + #cond); \
        } \
    } while (0)

#define ASSERT_EQ(a, b) \
    do { \
        if (!((a) == (b))) { \
            std::ostringstream oss; \
            oss << "ASSERT_EQ failed: " #a " != " #b " (got \"" << (a) \
                << "\" vs \"" << (b) << "\")"; \
            throw std::runtime_error(oss.str()); \
        } \
    } while (0)

// Expects `expr` to throw a BallException whose type_name == type_str.
#define ASSERT_THROWS_BALL(expr, type_str) \
    do { \
        bool threw = false; \
        try { \
            (void)(expr); \
        } catch (const BallException& e) { \
            threw = true; \
            ASSERT_EQ(e.type_name, std::string(type_str)); \
        } \
        if (!threw) { \
            throw std::runtime_error( \
                std::string("ASSERT_THROWS_BALL: expected BallException(") + \
                type_str + ") from `" #expr "` but nothing was thrown"); \
        } \
    } while (0)

// ================================================================
// BallDyn -- construction & coercion for every variant
// ================================================================

TEST(construct_default_is_null) {
    BallDyn d;
    ASSERT_TRUE(!d.has_value());
    ASSERT_TRUE(!d);  // truthiness: null is falsy
    ASSERT_EQ(static_cast<std::string>(d), std::string("null"));
}

TEST(construct_int64_and_int_widen_the_same) {
    BallDyn a((int64_t)42);
    BallDyn b((int)42);
    ASSERT_TRUE(a == b);
    ASSERT_EQ(static_cast<int64_t>(a), (int64_t)42);
    ASSERT_EQ(static_cast<std::string>(b), std::string("42"));
}

TEST(construct_other_integral_widens_to_int64) {
    // long/unsigned/short all route through the enable_if template ctor.
    long lv = 7;
    unsigned uv = 9;
    BallDyn a(lv), b(uv);
    ASSERT_EQ(static_cast<int64_t>(a), (int64_t)7);
    ASSERT_EQ(static_cast<int64_t>(b), (int64_t)9);
}

TEST(construct_double) {
    BallDyn d(3.5);
    ASSERT_EQ(static_cast<double>(d), 3.5);
    ASSERT_EQ(static_cast<std::string>(d), std::string("3.5"));
}

TEST(construct_bool) {
    BallDyn t(true), f(false);
    ASSERT_TRUE(t);
    ASSERT_TRUE(!f);
    ASSERT_EQ(static_cast<std::string>(t), std::string("true"));
    ASSERT_EQ(static_cast<std::string>(f), std::string("false"));
}

TEST(construct_string_lvalue_rvalue_and_cstr) {
    std::string s = "hello";
    BallDyn a(s);                      // const std::string&
    BallDyn b(std::string("world"));   // &&
    BallDyn c("literal");              // const char*
    ASSERT_EQ(static_cast<std::string>(a), std::string("hello"));
    ASSERT_EQ(static_cast<std::string>(b), std::string("world"));
    ASSERT_EQ(static_cast<std::string>(c), std::string("literal"));
    ASSERT_TRUE(a);  // non-empty string is truthy
    ASSERT_TRUE(!BallDyn(std::string("")));  // empty string is falsy
}

TEST(construct_map_scalar_and_ordered_map) {
    BallMap m{{"a"s, std::any((int64_t)1)}};
    BallDyn dm(m);
    ASSERT_EQ(static_cast<int64_t>(dm["a"s]), (int64_t)1);

    // BallOrderedMap always upgrades to a shared_ptr-backed BallOrderedMapRef
    // at construction (reference semantics, mirrors BallListRef).
    BallOrderedMap om;
    om["z"s] = std::any((int64_t)1);
    BallDyn dom(om);
    ASSERT_TRUE(dom.type() == typeid(BallOrderedMapRef));
    ASSERT_EQ(static_cast<int64_t>(dom["z"s]), (int64_t)1);
}

TEST(construct_unordered_map) {
    BallUMap um{{"k"s, std::any((int64_t)5)}};
    BallDyn d(um);
    ASSERT_EQ(static_cast<int64_t>(d["k"s]), (int64_t)5);
}

TEST(construct_list_is_reference_semantic) {
    // BallDyn(BallList) always allocates a shared BallListRef -- copies of the
    // BallDyn alias the SAME underlying vector (Dart list reference semantics).
    BallDyn a(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    BallDyn b = a;  // copy -- shares the same list handle
    b.push_back(BallDyn((int64_t)3));
    ASSERT_EQ(a.size(), (int64_t)3);  // mutation via b is visible through a
    ASSERT_EQ(static_cast<std::string>(a), std::string("[1, 2, 3]"));
}

TEST(construct_homogeneous_typed_vectors_normalize_to_list) {
    // The compiler emits homogeneous list literals as typed std::vectors;
    // BallDyn must normalize each to a BallList so length/index/iterate work.
    BallDyn di(std::vector<int64_t>{1, 2, 3});
    BallDyn dd(std::vector<double>{1.5, 2.5});
    BallDyn ds(std::vector<std::string>{"a"s, "b"s});
    BallDyn db(std::vector<bool>{true, false});
    ASSERT_TRUE(di._isList());
    ASSERT_EQ(di.size(), (int64_t)3);
    ASSERT_EQ(static_cast<int64_t>(di[(int64_t)1]), (int64_t)2);
    ASSERT_EQ(dd.size(), (int64_t)2);
    ASSERT_EQ(static_cast<std::string>(ds[(int64_t)0]), std::string("a"));
    ASSERT_EQ(static_cast<bool>(db[(int64_t)0]), true);
}

TEST(construct_from_callable_wraps_as_ballfunc) {
    // A zero-argument closure -- every Ball callable is stored as a one-input
    // BallFunc, so the (ignored) call argument is fine either way.
    BallDyn fn([]() -> int64_t { return 99; });
    ASSERT_TRUE(fn.type() == typeid(BallFunc));
    BallDyn r = fn();
    ASSERT_EQ(static_cast<int64_t>(r), (int64_t)99);

    // Single BallDyn-argument closure.
    BallDyn addOne([](BallDyn x) -> int64_t { return static_cast<int64_t>(x) + 1; });
    ASSERT_EQ(static_cast<int64_t>(addOne(BallDyn((int64_t)41))), (int64_t)42);
}

TEST(construct_stringbuffer) {
    BallDyn sb(BallStringBuffer{});
    ASSERT_TRUE(sb.type() == typeid(BallStringBuffer));
    ASSERT_EQ(static_cast<std::string>(sb), std::string(""));
}

TEST(construct_unwraps_nested_any_wrapped_ballDyn) {
    // std::any(BallDyn(std::any(BallDyn(x)))) must collapse to plain x --
    // the double-wrap defense in BallDyn(std::any) (MSVC BallDyn-in-any quirk).
    BallDyn inner((int64_t)7);
    std::any wrapped1(inner);
    BallDyn wrapped2(wrapped1);
    std::any wrapped3(wrapped2);
    BallDyn unwrapped(wrapped3);
    ASSERT_TRUE(unwrapped.type() == typeid(int64_t));
    ASSERT_EQ(static_cast<int64_t>(unwrapped), (int64_t)7);
}

// ================================================================
// operator[] -- field/index access across every backing map/list shape
// ================================================================

TEST(index_by_string_across_map_shapes) {
    BallDyn dm(BallMap{{"a"s, std::any((int64_t)1)}});
    BallDyn dom(BallOrderedMap{});
    dom.set("b"s, std::any((int64_t)2));
    BallDyn dum(BallUMap{{"c"s, std::any((int64_t)3)}});
    ASSERT_EQ(static_cast<int64_t>(dm["a"s]), (int64_t)1);
    ASSERT_EQ(static_cast<int64_t>(dom["b"s]), (int64_t)2);
    ASSERT_EQ(static_cast<int64_t>(dum["c"s]), (int64_t)3);
    // Missing key reads as null, not a thrown error (Dart Map[k] semantics).
    ASSERT_TRUE(!dm["missing"s].has_value());
}

TEST(index_list_in_range_and_out_of_range_throws) {
    BallDyn list(BallList{std::any((int64_t)10), std::any((int64_t)20)});
    ASSERT_EQ(static_cast<int64_t>(list[(int64_t)0]), (int64_t)10);
    ASSERT_EQ(static_cast<int64_t>(list[(int64_t)1]), (int64_t)20);
    // Out-of-range: Dart's native List[i] throws RangeError -- the self-host
    // engine's catch(RangeError) relies on this native throw (fail loud, not
    // a silent 0/null return).
    ASSERT_THROWS_BALL(list[(int64_t)5], "RangeError");
    ASSERT_THROWS_BALL(list[(int64_t)-1], "RangeError");
}

TEST(index_string_char_access) {
    BallDyn s(std::string("abc"));
    ASSERT_EQ(static_cast<std::string>(s[(int64_t)0]), std::string("a"));
    ASSERT_EQ(static_cast<std::string>(s[(int64_t)2]), std::string("c"));
}

TEST(index_map_with_integer_key_stringifies) {
    // Map<int, V>[k] reads must look up the STRINGIFIED key, matching how
    // ball_set/containsKey write/test int-keyed maps (fixture 95).
    BallDyn m(BallMap{});
    m.set(std::string("42"), std::any((int64_t)100));
    ASSERT_EQ(static_cast<int64_t>(m[(int64_t)42]), (int64_t)100);
}

TEST(index_by_ballDyn_key_dispatches_int_vs_string) {
    BallDyn list(BallList{std::any((int64_t)5), std::any((int64_t)6)});
    BallDyn map(BallMap{{"1"s, std::any((int64_t)77)}});
    // An int64_t-typed BallDyn key on a LIST is positional.
    ASSERT_EQ(static_cast<int64_t>(list[BallDyn((int64_t)1)]), (int64_t)6);
    // The same key type on a MAP is stringified.
    ASSERT_EQ(static_cast<int64_t>(map[BallDyn((int64_t)1)]), (int64_t)77);
}

// ================================================================
// set() / count() / containsKey() / hashCode()
// ================================================================

TEST(set_on_map_ordered_map_and_umap) {
    BallDyn dm(BallMap{});
    dm.set("k"s, std::any((int64_t)1));
    ASSERT_EQ(static_cast<int64_t>(dm["k"s]), (int64_t)1);

    BallDyn dom(BallOrderedMap{});
    dom.set("k"s, std::any((int64_t)2));
    ASSERT_EQ(static_cast<int64_t>(dom["k"s]), (int64_t)2);

    BallDyn dum(BallUMap{});
    dum.set("k"s, std::any((int64_t)3));
    ASSERT_EQ(static_cast<int64_t>(dum["k"s]), (int64_t)3);
}

TEST(set_lazily_allocates_map_on_default_ballDyn) {
    // `final _setters = {}` compiles to a default-empty BallDyn; the first
    // .set() must lazily allocate a map rather than no-op.
    BallDyn d;
    d.set("x"s, std::any((int64_t)1));
    ASSERT_EQ(static_cast<int64_t>(d["x"s]), (int64_t)1);
}

TEST(set_index_assignment_on_list) {
    BallDyn list(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    // Index-assignment is emitted with the index STRINGIFIED (`list[i]=v`).
    list.set(std::string("1"), std::any((int64_t)99));
    ASSERT_EQ(static_cast<int64_t>(list[(int64_t)1]), (int64_t)99);
    // set(int64_t idx, ...) overload
    list.set((int64_t)0, std::any((int64_t)55));
    ASSERT_EQ(static_cast<int64_t>(list[(int64_t)0]), (int64_t)55);
}

TEST(count_and_containsKey) {
    BallDyn m(BallMap{{"a"s, std::any((int64_t)1)}});
    ASSERT_EQ(m.count("a"s), (size_t)1);
    ASSERT_EQ(m.count("z"s), (size_t)0);
    ASSERT_TRUE(m.containsKey("a"s));
    ASSERT_TRUE(!m.containsKey(BallDyn(std::string("z"))));
}

TEST(hashCode_matches_dart_object_hashCode_shape) {
    ASSERT_EQ(BallDyn((int64_t)7).hashCode(), (int64_t)7);
    ASSERT_EQ(BallDyn(true).hashCode(), (int64_t)1);
    ASSERT_EQ(BallDyn(false).hashCode(), (int64_t)0);
    ASSERT_EQ(BallDyn().hashCode(), (int64_t)0);
}

// ================================================================
// Collection operations: empty/size/push_back/pop_back/front/back/erase
// ================================================================

TEST(collection_empty_and_size_across_shapes) {
    ASSERT_TRUE(BallDyn().empty());
    ASSERT_TRUE(BallDyn(std::string("")).empty());
    ASSERT_TRUE(!BallDyn(std::string("x")).empty());
    ASSERT_TRUE(BallDyn(BallList{}).empty());
    ASSERT_EQ(BallDyn(BallList{std::any((int64_t)1)}).size(), (int64_t)1);
    ASSERT_TRUE(BallDyn(BallMap{}).empty());
    ASSERT_EQ(BallDyn(BallMap{{"a"s, std::any((int64_t)1)}}).size(), (int64_t)1);
}

TEST(list_push_pop_front_back_erase) {
    BallDyn list(BallList{});
    list.push_back(BallDyn((int64_t)1));
    list.push_back(BallDyn((int64_t)2));
    list.push_back(BallDyn((int64_t)3));
    ASSERT_EQ(static_cast<int64_t>(list.front()), (int64_t)1);
    ASSERT_EQ(static_cast<int64_t>(list.back()), (int64_t)3);
    list.pop_back();
    ASSERT_EQ(list.size(), (int64_t)2);
    list.erase(BallDyn((int64_t)1));  // erase-by-value
    ASSERT_EQ(list.size(), (int64_t)1);
    ASSERT_EQ(static_cast<int64_t>(list.front()), (int64_t)2);
}

TEST(map_erase_by_key) {
    BallDyn m(BallMap{{"a"s, std::any((int64_t)1)}, {"b"s, std::any((int64_t)2)}});
    m.erase("a"s);
    ASSERT_TRUE(m.count("a"s) == 0);
    ASSERT_TRUE(m.count("b"s) == 1);
}

TEST(indexOf_on_list_and_string) {
    BallDyn list(BallList{std::any((int64_t)10), std::any((int64_t)20), std::any((int64_t)30)});
    ASSERT_EQ(list.indexOf(BallDyn((int64_t)20)), (int64_t)1);
    ASSERT_EQ(list.indexOf(BallDyn((int64_t)99)), (int64_t)-1);
    BallDyn s(std::string("hello world"));
    ASSERT_EQ(s.indexOf(BallDyn(std::string("world"))), (int64_t)6);
}

TEST(string_substr_and_find) {
    BallDyn s(std::string("hello world"));
    ASSERT_EQ(s.substr(6), std::string("world"));
    ASSERT_EQ(s.substr(0, 5), std::string("hello"));
    ASSERT_EQ(s.find("world"), (size_t)6);
    ASSERT_EQ(s.find("nope"), std::string::npos);
}

// ================================================================
// Equality -- cross-type numeric, list, map, and scalar comparisons
// ================================================================

TEST(equality_null_and_cross_type_numeric) {
    ASSERT_TRUE(BallDyn() == BallDyn());
    ASSERT_TRUE(BallDyn() != BallDyn((int64_t)0));  // null != 0, unlike JS
    // Dart `0 == 0.0` is true -- cross-type numeric equality.
    ASSERT_TRUE(BallDyn((int64_t)0) == BallDyn(0.0));
    ASSERT_TRUE(BallDyn(2.0) == BallDyn((int64_t)2));
    ASSERT_TRUE(BallDyn((int64_t)2) != BallDyn(2.5));
}

TEST(equality_list_shares_ref_and_compares_deep) {
    BallDyn a(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    BallDyn b = a;  // shares the same BallListRef
    ASSERT_TRUE(a == b);
    BallDyn c(BallList{std::any((int64_t)1), std::any((int64_t)2)});  // distinct handle, same values
    ASSERT_TRUE(a == c);
    BallDyn d(BallList{std::any((int64_t)1), std::any((int64_t)3)});
    ASSERT_TRUE(a != d);
}

TEST(equality_map_is_structural) {
    BallDyn a(BallMap{{"x"s, std::any((int64_t)1)}});
    BallDyn b(BallMap{{"x"s, std::any((int64_t)1)}});
    BallDyn c(BallMap{{"x"s, std::any((int64_t)2)}});
    ASSERT_TRUE(a == b);
    ASSERT_TRUE(a != c);
}

TEST(equality_scalar_overloads) {
    ASSERT_TRUE(BallDyn(std::string("x")) == std::string("x"));
    ASSERT_TRUE(BallDyn(std::string("x")) == "x");
    ASSERT_TRUE("x" == BallDyn(std::string("x")));
    ASSERT_TRUE(BallDyn((int64_t)5) == (int64_t)5);
    ASSERT_TRUE((int64_t)5 == BallDyn((int64_t)5));
    ASSERT_TRUE(BallDyn(true) == true);
    ASSERT_TRUE(BallDyn(2.5) == 2.5);
}

// ================================================================
// Arithmetic / comparison / bitwise / increment operators
// ================================================================

TEST(arithmetic_int_and_double_and_string_concat) {
    ASSERT_TRUE(BallDyn((int64_t)2) + BallDyn((int64_t)3) == BallDyn((int64_t)5));
    ASSERT_TRUE(BallDyn(1.5) + BallDyn(2.5) == BallDyn(4.0));
    ASSERT_EQ(static_cast<std::string>(BallDyn(std::string("a")) + BallDyn(std::string("b"))),
              std::string("ab"));
    ASSERT_TRUE(BallDyn((int64_t)7) - BallDyn((int64_t)2) == BallDyn((int64_t)5));
    ASSERT_TRUE(BallDyn((int64_t)6) / BallDyn((int64_t)3) == BallDyn((int64_t)2));
    ASSERT_TRUE(BallDyn((int64_t)7) % BallDyn((int64_t)3) == BallDyn((int64_t)1));
    ASSERT_TRUE(-BallDyn((int64_t)4) == BallDyn((int64_t)-4));
}

TEST(arithmetic_string_times_int_repeats) {
    BallDyn s(std::string("ab"));
    BallDyn n((int64_t)3);
    ASSERT_EQ(static_cast<std::string>(s * n), std::string("ababab"));
    ASSERT_EQ(static_cast<std::string>(s * BallDyn((int64_t)0)), std::string(""));
}

TEST(comparison_operators_int_string_double) {
    ASSERT_TRUE(BallDyn((int64_t)1) < BallDyn((int64_t)2));
    ASSERT_TRUE(BallDyn((int64_t)2) > BallDyn((int64_t)1));
    ASSERT_TRUE(BallDyn((int64_t)2) <= BallDyn((int64_t)2));
    ASSERT_TRUE(BallDyn((int64_t)2) >= BallDyn((int64_t)2));
    ASSERT_TRUE(BallDyn(std::string("a")) < BallDyn(std::string("b")));
    ASSERT_TRUE(BallDyn(1.5) < BallDyn(2.5));
}

TEST(bitwise_operators) {
    BallDyn a((int64_t)0b1100), b((int64_t)0b1010);
    ASSERT_TRUE((a & b) == BallDyn((int64_t)0b1000));
    ASSERT_TRUE((a | b) == BallDyn((int64_t)0b1110));
    ASSERT_TRUE((a ^ b) == BallDyn((int64_t)0b0110));
    ASSERT_TRUE((a << BallDyn((int64_t)1)) == BallDyn((int64_t)0b11000));
    ASSERT_TRUE((a >> BallDyn((int64_t)1)) == BallDyn((int64_t)0b0110));
    ASSERT_TRUE(~BallDyn((int64_t)0) == BallDyn((int64_t)-1));
}

TEST(increment_and_decrement) {
    BallDyn i((int64_t)5);
    ++i;
    ASSERT_TRUE(i == BallDyn((int64_t)6));
    BallDyn old = i++;
    ASSERT_TRUE(old == BallDyn((int64_t)6));
    ASSERT_TRUE(i == BallDyn((int64_t)7));
    --i;
    ASSERT_TRUE(i == BallDyn((int64_t)6));
}

TEST(compound_assignment_on_ballDyn_lhs) {
    BallDyn x((int64_t)10);
    x += BallDyn((int64_t)5);
    ASSERT_TRUE(x == BallDyn((int64_t)15));
    x -= BallDyn((int64_t)3);
    ASSERT_TRUE(x == BallDyn((int64_t)12));
    x *= BallDyn((int64_t)2);
    ASSERT_TRUE(x == BallDyn((int64_t)24));
    x /= BallDyn((int64_t)4);
    ASSERT_TRUE(x == BallDyn((int64_t)6));
}

// ================================================================
// Property-like accessors: kind()/value()/fields()/values()
// ================================================================

TEST(values_on_map_returns_insertion_ordered_values) {
    // #202: BallOrderedMap.values must return the values list, not null.
    BallOrderedMap om;
    om["z"s] = std::any((int64_t)1);
    om["a"s] = std::any((int64_t)2);
    BallDyn d(om);
    BallDyn vs = d.values();
    ASSERT_TRUE(vs._isList());
    ASSERT_EQ(vs.size(), (int64_t)2);
    ASSERT_EQ(static_cast<int64_t>(vs[(int64_t)0]), (int64_t)1);
    ASSERT_EQ(static_cast<int64_t>(vs[(int64_t)1]), (int64_t)2);
}

// Regression test for issue #233: BallDyn::operator[](const std::string&)
// on a BallMap/BallUMap used to dispatch to std::map::operator[], which
// AUTO-VIVIFIES a missing key — even though the method's own doc comment
// says "Returns a copy... for mutation use set()" (read-only contract).
// Caught via .values()'s internal probe for an explicit "values" key (the
// protobuf ListValue JSON shape), which silently inserted a phantom
// {"values": null} entry into any plain-BallMap receiver that lacked one.
// Fixed to use find() instead, mirroring the BallScope/BallOrderedMap
// branches beside it, which never had this problem.
TEST(index_read_on_ballmap_and_umap_does_not_auto_vivify_missing_key) {
    BallDyn d(BallMap{{"a"s, std::any((int64_t)9)}});
    ASSERT_EQ(d.size(), (int64_t)1);
    BallDyn vs = d.values();  // probes "values" via operator[] internally
    ASSERT_EQ(d.size(), (int64_t)1);   // read (.values()) must not mutate d
    ASSERT_TRUE(!d.containsKey("values"s));  // no phantom key was inserted
    ASSERT_EQ(vs.size(), (int64_t)1);  // only the real value, no phantom null

    // Same fix for BallUMap.
    BallDyn u(BallUMap{{"a"s, std::any((int64_t)9)}});
    ASSERT_EQ(u.size(), (int64_t)1);
    ASSERT_TRUE(!u["missing"s].has_value());  // reads as null...
    ASSERT_EQ(u.size(), (int64_t)1);          // ...without inserting "missing"
    ASSERT_TRUE(!u.containsKey("missing"s));
}

TEST(values_on_list_returns_self) {
    BallDyn list(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    ASSERT_TRUE(list.values() == list);
}

TEST(values_protobuf_listvalue_shape_returns_values_key) {
    // Protobuf ListValue JSON shape: {"values": [...]} -- the explicit-key
    // branch, checked before the generic Map fallback.
    BallDyn inner(BallList{std::any((int64_t)3), std::any((int64_t)4)});
    BallDyn wrapper(BallMap{{"values"s, static_cast<std::any>(inner)}});
    BallDyn vs = wrapper.values();
    ASSERT_EQ(vs.size(), (int64_t)2);
}

TEST(values_on_non_map_fails_loud) {
    // #202: a scalar/null receiver must throw, not silently return null.
    ASSERT_THROWS_BALL(BallDyn((int64_t)5).values(), "TypeError");
    ASSERT_THROWS_BALL(BallDyn().values(), "TypeError");
}

TEST(kind_value_fields_accessors) {
    BallDyn signal(BallMap{{"kind"s, std::any(std::string("return"))}});
    ASSERT_EQ(static_cast<std::string>(signal.kind()), std::string("return"));

    BallDyn entry(BallMap{{"value"s, std::any((int64_t)42)}});
    ASSERT_EQ(static_cast<int64_t>(entry.value()), (int64_t)42);

    BallDyn withFields(BallMap{{"fields"s, std::any(BallMap{{"a"s, std::any((int64_t)1)}})}});
    ASSERT_EQ(static_cast<int64_t>(withFields.fields()["a"s]), (int64_t)1);
    // No explicit "fields" key: the BallDyn itself IS the fields map.
    BallDyn bareMap(BallMap{{"a"s, std::any((int64_t)1)}});
    ASSERT_EQ(static_cast<int64_t>(bareMap.fields()["a"s]), (int64_t)1);
}

// ================================================================
// Function-call operator, iteration
// ================================================================

TEST(function_call_operator_with_and_without_arg) {
    BallDyn fn([](BallDyn x) -> int64_t { return static_cast<int64_t>(x) * 2; });
    ASSERT_EQ(static_cast<int64_t>(fn(BallDyn((int64_t)21))), (int64_t)42);
    // Non-callable receiver: returns null rather than throwing/crashing.
    ASSERT_TRUE(!BallDyn((int64_t)1)().has_value());
}

TEST(range_based_for_iterates_list) {
    BallDyn list(BallList{std::any((int64_t)1), std::any((int64_t)2), std::any((int64_t)3)});
    int64_t sum = 0;
    for (BallDyn el : list) sum += static_cast<int64_t>(el);
    ASSERT_EQ(sum, (int64_t)6);
}

// ================================================================
// BallOrderedMap -- insertion-order preservation + erase reindexing
// ================================================================

TEST(ordered_map_preserves_insertion_order) {
    BallOrderedMap om;
    om["z"s] = std::any((int64_t)1);
    om["a"s] = std::any((int64_t)2);
    om["m"s] = std::any((int64_t)3);
    // NOT alphabetical (that's what a std::map would give) -- insertion order.
    ASSERT_EQ(om.entries_[0].first, std::string("z"));
    ASSERT_EQ(om.entries_[1].first, std::string("a"));
    ASSERT_EQ(om.entries_[2].first, std::string("m"));
    ASSERT_EQ(om.size(), (size_t)3);
}

TEST(ordered_map_erase_reindexes_remaining_entries) {
    BallOrderedMap om;
    om["a"s] = std::any((int64_t)1);
    om["b"s] = std::any((int64_t)2);
    om["c"s] = std::any((int64_t)3);
    om.erase("a"s);
    ASSERT_EQ(om.size(), (size_t)2);
    ASSERT_EQ(om.count("a"s), (size_t)0);
    // "b" and "c" shift down; index_ must track the new positions so a
    // subsequent find("c") doesn't read the wrong (stale) slot.
    ASSERT_EQ(om.entries_[0].first, std::string("b"));
    ASSERT_EQ(om.entries_[1].first, std::string("c"));
    ASSERT_TRUE(om.find("c"s)->second.has_value());
    ASSERT_EQ(std::any_cast<int64_t>(om.find("c"s)->second), (int64_t)3);
}

TEST(ordered_map_becomes_ref_on_ballDyn_construction) {
    BallOrderedMap om;
    om["k"s] = std::any((int64_t)1);
    BallDyn a(om);
    BallDyn b = a;  // shares the same BallOrderedMapRef
    b.set("k2"s, std::any((int64_t)2));
    ASSERT_EQ(static_cast<int64_t>(a["k2"s]), (int64_t)2);  // visible through a
}

// ================================================================
// ball_map_keys / ball_map_values (issue #197 -- fail loud on non-Map)
// ================================================================

TEST(map_keys_and_values_preserve_insertion_order) {
    BallOrderedMap om;
    om["z"s] = std::any((int64_t)1);
    om["a"s] = std::any((int64_t)2);
    BallDyn d(om);
    BallDyn keys = ball_map_keys(d);
    BallDyn values = ball_map_values(d);
    ASSERT_EQ(static_cast<std::string>(keys[(int64_t)0]), std::string("z"));
    ASSERT_EQ(static_cast<std::string>(keys[(int64_t)1]), std::string("a"));
    ASSERT_EQ(static_cast<int64_t>(values[(int64_t)0]), (int64_t)1);
    ASSERT_EQ(static_cast<int64_t>(values[(int64_t)1]), (int64_t)2);
}

TEST(map_keys_and_values_also_work_on_plain_ballmap) {
    BallDyn d(BallMap{{"a"s, std::any((int64_t)1)}});
    ASSERT_EQ(ball_map_keys(d).size(), (int64_t)1);
    ASSERT_EQ(ball_map_values(d).size(), (int64_t)1);
}

TEST(map_keys_and_values_fail_loud_on_non_map) {
    // #197: silently returning [] on a non-Map receiver is exactly the class
    // of bug that hid issue #55 -- must fail loud instead.
    ASSERT_THROWS_BALL(ball_map_keys(BallDyn((int64_t)5)), "TypeError");
    ASSERT_THROWS_BALL(ball_map_values(BallDyn(std::string("x"))), "TypeError");
    ASSERT_THROWS_BALL(ball_map_keys(BallDyn()), "TypeError");
}

TEST(map_entries_yields_key_value_pair_maps) {
    BallDyn d(BallMap{{"a"s, std::any((int64_t)1)}});
    BallDyn entries = ball_map_entries(d);
    ASSERT_EQ(entries.size(), (int64_t)1);
    BallDyn first = entries[(int64_t)0];
    ASSERT_EQ(static_cast<std::string>(first["key"s]), std::string("a"));
    ASSERT_EQ(static_cast<int64_t>(first["value"s]), (int64_t)1);
}

// ================================================================
// ball_is_map_dyn / ball_is_ball_set -- Set vs Map discrimination (#68/#174)
// ================================================================

TEST(is_map_dyn_recognizes_every_map_shape_but_not_list_or_scalar) {
    ASSERT_TRUE(ball_is_map_dyn(BallDyn(BallMap{})));
    ASSERT_TRUE(ball_is_map_dyn(BallDyn(BallOrderedMap{})));
    ASSERT_TRUE(!ball_is_map_dyn(BallDyn(BallList{})));
    ASSERT_TRUE(!ball_is_map_dyn(BallDyn((int64_t)1)));
}

TEST(is_ball_set_true_only_for_the_portable_set_shape) {
    BallDyn set = ball_make_set(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    ASSERT_TRUE(ball_is_ball_set(set));
    // A one-key map that ISN'T the set marker is not a Set.
    ASSERT_TRUE(!ball_is_ball_set(BallDyn(BallMap{{"__ball_set__x"s, std::any((int64_t)1)}})));
    ASSERT_TRUE(!ball_is_ball_set(BallDyn(BallMap{{"a"s, std::any((int64_t)1)}})));
    ASSERT_TRUE(!ball_is_ball_set(BallDyn(BallList{})));
}

TEST(set_construction_dedups_preserving_first_seen_order) {
    BallDyn set = ball_make_set(BallList{
        std::any((int64_t)3), std::any((int64_t)1), std::any((int64_t)2), std::any((int64_t)1)});
    ASSERT_EQ(set.size(), (int64_t)3);  // duplicate "1" dropped
    ASSERT_EQ(static_cast<std::string>(set), std::string("{3, 1, 2}"));  // Set literal print, not {k: v}
}

TEST(set_push_back_is_dedup_add) {
    BallDyn set = ball_make_set(BallList{std::any((int64_t)1)});
    set.push_back(BallDyn((int64_t)1));  // duplicate: silent no-op
    ASSERT_EQ(set.size(), (int64_t)1);
    set.push_back(BallDyn((int64_t)2));
    ASSERT_EQ(set.size(), (int64_t)2);
}

TEST(set_indexing_and_iteration_operate_on_wrapped_list) {
    BallDyn set = ball_make_set(BallList{std::any((int64_t)10), std::any((int64_t)20)});
    ASSERT_EQ(static_cast<int64_t>(set[(int64_t)0]), (int64_t)10);
    int64_t sum = 0;
    for (BallDyn el : set) sum += static_cast<int64_t>(el);
    ASSERT_EQ(sum, (int64_t)30);
}

TEST(set_algebraic_operations) {
    BallDyn a = ball_make_set(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    BallDyn b = ball_make_set(BallList{std::any((int64_t)2), std::any((int64_t)3)});
    ASSERT_EQ(union_(a, b).size(), (int64_t)3);
    ASSERT_EQ(intersection(a, b).size(), (int64_t)1);
    ASSERT_EQ(difference(a, b).size(), (int64_t)1);
    ASSERT_TRUE(ball_is_ball_set(union_(a, b)));
}

// ================================================================
// ball_emit_runtime.h -- ball_is_*, ball_to_string(any), BallException
// ================================================================

TEST(ball_is_predicates_over_std_any) {
    ASSERT_TRUE(ball_is_int(std::any((int64_t)1)));
    ASSERT_TRUE(!ball_is_int(std::any(std::string("x"))));
    ASSERT_TRUE(ball_is_double(std::any(1.5)));
    ASSERT_TRUE(ball_is_string(std::any(std::string("x"))));
    ASSERT_TRUE(ball_is_bool(std::any(true)));
    ASSERT_TRUE(ball_is_list(std::any(BallList_RT{})));
    ASSERT_TRUE(ball_is_map(std::any(BallMap_RT{})));
    ASSERT_TRUE(ball_is_function(std::any(BallFunc_RT([](std::any) { return std::any{}; }))));
    ASSERT_TRUE(!ball_is_function(std::any((int64_t)1)));
}

TEST(ball_runtime_type_name_matches_dart_runtimeType) {
    ASSERT_EQ(ball_runtime_type_name(std::any((int64_t)1)), std::string("int"));
    ASSERT_EQ(ball_runtime_type_name(std::any(1.5)), std::string("double"));
    ASSERT_EQ(ball_runtime_type_name(std::any(std::string("x"))), std::string("String"));
    ASSERT_EQ(ball_runtime_type_name(std::any(true)), std::string("bool"));
    ASSERT_EQ(ball_runtime_type_name(std::any(BallList_RT{})), std::string("List"));
    ASSERT_EQ(ball_runtime_type_name(std::any(BallMap_RT{})), std::string("Map"));
    ASSERT_EQ(ball_runtime_type_name(std::any()), std::string("Null"));
}

TEST(ball_to_string_any_covers_every_scalar_and_collection) {
    ASSERT_EQ(ball_to_string(std::any()), std::string("null"));
    ASSERT_EQ(ball_to_string(std::any((int64_t)5)), std::string("5"));
    ASSERT_EQ(ball_to_string(std::any(6.0)), std::string("6.0"));  // trailing .0
    ASSERT_EQ(ball_to_string(std::any(true)), std::string("true"));
    ASSERT_EQ(ball_to_string(std::any(std::string("hi"))), std::string("hi"));
    BallList_RT l{std::any((int64_t)1), std::any((int64_t)2)};
    ASSERT_EQ(ball_to_string(std::any(l)), std::string("[1, 2]"));
    BallMap_RT m{{"a"s, std::any((int64_t)1)}};
    ASSERT_EQ(ball_to_string(std::any(m)), std::string("{a: 1}"));
}

TEST(ball_to_string_reified_exception_map_shows_original_value) {
    // A caught exception is reified as {__type__: "BallException", value, ...}
    // (see _ball_exception_to_dyn in ball_dyn.h); print(e) must show the
    // ORIGINAL thrown value, not the internal reification shape.
    BallMap_RT reified{
        {"__type__"s, std::any(std::string("BallException"))},
        {"value"s, std::any(std::string("boom"))},
    };
    ASSERT_EQ(ball_to_string(std::any(reified)), std::string("boom"));
}

TEST(caught_typed_exception_with_a_scalar_payload_keeps_its_type) {
    // Issue #616. `_ball_exception_to_dyn` collapses a caught exception to the
    // BARE payload when the throw was untyped (`throw "msg"` -- conformance
    // 222, where `catch (e) { if (e == "recoverable") ... }` must compare the
    // string itself). It must NOT collapse a TYPED one: the self-hosted
    // engine's own `throw BallException("StateError", "Bad state: No element")`
    // carries a scalar payload, and collapsing it made the catch variable a
    // bare String -- so the compiled engine's `e is BallException` was false,
    // `e.typeName` was unreadable, its `on StateError catch` dispatch could not
    // match, and the exception escaped the program's own `try`.
    BallDyn typed = _ball_exception_to_dyn(_ball_make_exception(
        "StateError"s, std::any(std::string("Bad state: No element"))));
    ASSERT_EQ(ball_to_string(typed._val), std::string("Bad state: No element"));
    ASSERT_EQ(ball_object_type_tag(typed._val), std::string("BallException"));
    ASSERT_EQ(ball_to_string(typed[std::string("typeName")]._val), std::string("StateError"));
    ASSERT_EQ(ball_to_string(typed[std::string("value")]._val), std::string("Bad state: No element"));

    // …while an UNTYPED scalar throw still collapses to the scalar itself.
    BallDyn untyped = _ball_exception_to_dyn(
        _ball_make_exception("Exception"s, std::any(std::string("recoverable"))));
    ASSERT_EQ(ball_to_string(untyped._val), std::string("recoverable"));
    ASSERT_EQ(ball_object_type_tag(untyped._val), std::string());
}

TEST(ball_natural_less_cross_type_numeric_and_string) {
    ASSERT_TRUE(ball_natural_less(std::any((int64_t)1), std::any(2.0)));
    ASSERT_TRUE(!ball_natural_less(std::any(2.0), std::any((int64_t)1)));
    ASSERT_TRUE(ball_natural_less(std::any(std::string("a")), std::any(std::string("b"))));
}

TEST(ball_exception_construction_and_stream_insertion) {
    BallException e("ValueError", "bad value");
    ASSERT_EQ(e.type_name, std::string("ValueError"));
    ASSERT_EQ(std::string(e.what()), std::string("bad value"));
    std::ostringstream oss;
    oss << e;
    ASSERT_EQ(oss.str(), std::string("bad value"));

    // 3-arg overload carries structured field values (catch-side `e.detail`).
    BallException e2("NotFound", "missing", {{"detail"s, "x"s}});
    ASSERT_EQ(e2.fields.at("detail"), std::string("x"));
}

TEST(ball_exception_is_throwable_and_catchable) {
    bool caught = false;
    try {
        throw BallException("TypeError", "nope");
    } catch (const BallException& e) {
        caught = true;
        ASSERT_EQ(e.type_name, std::string("TypeError"));
    }
    ASSERT_TRUE(caught);
    // Also catchable as a plain std::exception (untyped `catch` clauses).
    caught = false;
    try {
        throw BallException("X", "y");
    } catch (const std::exception&) {
        caught = true;
    }
    ASSERT_TRUE(caught);
}

TEST(make_exception_carries_payload_and_unwraps_rethrow_shape) {
    // A plain payload: has_payload is set and value is preserved verbatim.
    BallException e1 = _ball_make_exception("ValueError", std::any((int64_t)42));
    ASSERT_TRUE(e1.has_payload);
    ASSERT_EQ(std::any_cast<int64_t>(e1.value), (int64_t)42);

    // `rethrow` hands back an already-reified {__type__: "BallException",
    // typeName, value} map -- re-raising must recover the ORIGINAL typeName
    // and payload rather than double-nesting the reification.
    BallMap_RT reified{
        {"__type__"s, std::any(std::string("BallException"))},
        {"typeName"s, std::any(std::string("OriginalType"))},
        {"value"s, std::any(std::string("original message"))},
    };
    BallException e2 = _ball_make_exception("ignored", std::any(reified));
    ASSERT_EQ(e2.type_name, std::string("OriginalType"));
    ASSERT_TRUE(e2.has_payload);
}

TEST(ball_type_name_matches_module_qualified_forms) {
    ASSERT_TRUE(ball_type_name_matches("Point", "Point"));
    ASSERT_TRUE(ball_type_name_matches("main:Point", "Point"));
    ASSERT_TRUE(ball_type_name_matches("Point", "main:Point"));
    ASSERT_TRUE(!ball_type_name_matches("Point", "Circle"));
}

TEST(ball_is_flow_signal_detects_kind_field) {
    ASSERT_TRUE(ball_is_flow_signal(std::any(BallMap_RT{{"kind"s, std::any(std::string("return"))}})));
    ASSERT_TRUE(!ball_is_flow_signal(std::any(BallMap_RT{{"other"s, std::any((int64_t)1)}})));
    ASSERT_TRUE(!ball_is_flow_signal(std::any((int64_t)1)));
}

TEST(double_property_helpers_isNaN_isInfinite_isFinite_isNegative) {
    double nan = std::numeric_limits<double>::quiet_NaN();
    double inf = std::numeric_limits<double>::infinity();
    ASSERT_TRUE(ball_isNaN(nan));
    ASSERT_TRUE(!ball_isNaN(1.0));
    ASSERT_TRUE(ball_isInfinite(inf));
    ASSERT_TRUE(ball_isInfinite(-inf));
    ASSERT_TRUE(!ball_isInfinite(1.0));
    ASSERT_TRUE(ball_isFinite(1.0));
    ASSERT_TRUE(!ball_isFinite(inf));
    ASSERT_TRUE(ball_isNegative(-1.0));
    ASSERT_TRUE(!ball_isNegative(1.0));
    // int64_t overloads: never NaN/Infinite, always finite.
    ASSERT_TRUE(!ball_isNaN((int64_t)5));
    ASSERT_TRUE(!ball_isInfinite((int64_t)5));
    ASSERT_TRUE(ball_isFinite((int64_t)5));
    ASSERT_TRUE(ball_isNegative((int64_t)-5));
}

TEST(double_to_int64_clamps_out_of_range) {
    ASSERT_EQ(ball_double_to_int64(5.9), (int64_t)5);
    ASSERT_EQ(ball_double_to_int64(1e30), std::numeric_limits<int64_t>::max());
    ASSERT_EQ(ball_double_to_int64(-1e30), std::numeric_limits<int64_t>::min());
}

// ================================================================
// BallStringBuffer -- reference-semantic accumulation (write/writeln/...)
// ================================================================

TEST(stringbuffer_write_family_accumulates_through_aliases) {
    BallDyn sb(BallStringBuffer{});
    BallDyn alias = sb;  // shares the same underlying std::string via shared_ptr
    write(sb, BallDyn(std::string("a")));
    writeln(alias, BallDyn(std::string("b")));  // write through the alias
    writeCharCode(sb, BallDyn((int64_t)67));    // 'C'
    writeAll(sb, BallDyn(BallList{std::any(std::string("x")), std::any(std::string("y"))}));
    ASSERT_EQ(static_cast<std::string>(sb), std::string("ab\nCxy"));
    ball_strbuf_clear(sb);
    ASSERT_EQ(static_cast<std::string>(alias), std::string(""));  // clear is visible via the alias too
}

// ================================================================
// File / Directory runtime -- ball_emit_runtime.h's std_fs backing (#310).
//
// These do REAL filesystem work but are called ONLY by the self-hosted
// engine's compiled std_fs handlers (engine_std.dart -> File(...)/
// Directory(...) calls) -- see the "std_fs directory ops" / "Real byte
// write" comments above their definitions in ball_emit_runtime.h. The only
// consumer is test_selfhost_conformance.cpp, which requires the gitignored,
// regenerated-only-in-CI dart/self_host/lib/engine_rt(.cpp), so this whole
// cluster (readAsStringSync/writeAsStringSync x2 overloads/readAsBytesSync/
// writeAsBytesSync/existsSync/deleteSync/listSync/createSync/
// _ball_file_mode_is_append, plus the File/Directory BallDyn constructors)
// is compiled into every instrumented test binary but never EXECUTED by any
// of them -- 0% coverage both locally and in CI's coverage job (neither
// regenerates engine_rt). Direct coverage closes that gap the same way
// test_ball_dyn.cpp already does for the rest of this header.
// ================================================================

namespace fs = std::filesystem;

// Unique per-test scratch path under the OS temp dir; not removed by the
// helper itself (individual tests clean up what they create).
static fs::path ball_dyn_test_temp_path(const std::string& stem) {
    static std::atomic<int> counter{0};
    return fs::temp_directory_path() /
           ("ball_dyn_test_" + stem + "_" + std::to_string(counter++));
}

TEST(file_mode_is_append_classifies_every_mode_value) {
    ASSERT_TRUE(!_ball_file_mode_is_append(std::any{}));  // no mode -> write
    ASSERT_TRUE(!_ball_file_mode_is_append(std::any(std::string("write"))));
    ASSERT_TRUE(!_ball_file_mode_is_append(std::any(std::string("read"))));
    ASSERT_TRUE(_ball_file_mode_is_append(std::any(std::string("append"))));

    bool threw = false;
    try {
        _ball_file_mode_is_append(std::any(std::string("bogus")));
    } catch (const std::runtime_error& e) {
        threw = true;
        std::string msg = e.what();
        ASSERT_TRUE(msg.find("unsupported FileMode value") != std::string::npos);
    }
    ASSERT_TRUE(threw);
}

TEST(file_write_read_string_roundtrips_and_truncates_by_default) {
    fs::path p = ball_dyn_test_temp_path("write_str.txt");
    File f(p.string());
    writeAsStringSync(f, std::string("hello"));
    ASSERT_EQ(readAsStringSync(f), std::string("hello"));
    // Default (no mode) truncates -- overwrites, does not append.
    writeAsStringSync(f, std::string("bye"));
    ASSERT_EQ(readAsStringSync(f), std::string("bye"));
    fs::remove(p);
}

TEST(file_write_string_append_mode_extends_existing_content) {
    fs::path p = ball_dyn_test_temp_path("append_str.txt");
    File f(p.string());
    writeAsStringSync(f, std::string("a"));
    writeAsStringSync(f, std::string("b"), std::any(std::string("append")));
    ASSERT_EQ(readAsStringSync(f), std::string("ab"));
    fs::remove(p);
}

TEST(file_write_string_any_overload_stringifies_content) {
    fs::path p = ball_dyn_test_temp_path("write_any.txt");
    File f(p.string());
    writeAsStringSync(f, std::any((int64_t)42));
    ASSERT_EQ(readAsStringSync(f), std::string("42"));
    writeAsStringSync(f, std::any(std::string("x")), std::any(std::string("append")));
    ASSERT_EQ(readAsStringSync(f), std::string("42x"));
    fs::remove(p);
}

TEST(file_write_string_balldyn_overload_stringifies_content) {
    fs::path p = ball_dyn_test_temp_path("write_balldyn.txt");
    File f(p.string());
    writeAsStringSync(f, BallDyn(std::string("dyn")));
    ASSERT_EQ(readAsStringSync(f), std::string("dyn"));
    writeAsStringSync(f, BallDyn((int64_t)7), std::any(std::string("append")));
    ASSERT_EQ(readAsStringSync(f), std::string("dyn7"));
    fs::remove(p);
}

TEST(file_write_read_bytes_roundtrips) {
    fs::path p = ball_dyn_test_temp_path("write_bytes.bin");
    File f(p.string());
    std::vector<std::any> bytes{std::any((int64_t)0), std::any((int64_t)255),
                                 std::any((int64_t)65)};  // \0 \xFF 'A'
    writeAsBytesSync(f, std::any(bytes));
    auto read_back = readAsBytesSync(f);
    ASSERT_TRUE(read_back.size() == 3);
    ASSERT_EQ(std::any_cast<int64_t>(read_back[0]), (int64_t)0);
    ASSERT_EQ(std::any_cast<int64_t>(read_back[1]), (int64_t)255);
    ASSERT_EQ(std::any_cast<int64_t>(read_back[2]), (int64_t)65);
    // Second write truncates rather than appends.
    writeAsBytesSync(f, std::any(std::vector<std::any>{std::any((int64_t)1)}));
    ASSERT_TRUE(readAsBytesSync(f).size() == 1);
    fs::remove(p);
}

TEST(file_write_bytes_rejects_non_integer_element) {
    fs::path p = ball_dyn_test_temp_path("write_bytes_bad.bin");
    File f(p.string());
    std::vector<std::any> bad{std::any(std::string("not-a-byte"))};
    bool threw = false;
    try {
        writeAsBytesSync(f, std::any(bad));
    } catch (const std::runtime_error& e) {
        threw = true;
        std::string msg = e.what();
        ASSERT_TRUE(msg.find("non-integer byte element") != std::string::npos);
    }
    ASSERT_TRUE(threw);
    fs::remove(p);  // the throw happens mid-loop; file may or may not exist
}

TEST(file_exists_and_delete_sync) {
    fs::path p = ball_dyn_test_temp_path("exists.txt");
    File f(p.string());
    ASSERT_TRUE(!existsSync(f));
    writeAsStringSync(f, std::string("x"));
    ASSERT_TRUE(existsSync(f));
    deleteSync(f);
    ASSERT_TRUE(!existsSync(f));
}

TEST(file_constructors_from_string_any_and_balldyn) {
    File a(std::string("plain_path"));
    ASSERT_EQ(a.path, std::string("plain_path"));
    File b(std::any(std::string("any_path")));
    ASSERT_EQ(b.path, std::string("any_path"));
    File c(BallDyn(std::string("dyn_path")));
    ASSERT_EQ(c.path, std::string("dyn_path"));
}

TEST(directory_create_list_exists_recursive) {
    fs::path root = ball_dyn_test_temp_path("dir_root");
    fs::path nested = root / "a" / "b";
    Directory nested_dir(nested.string());

    ASSERT_TRUE(!existsSync(nested_dir));
    createSync(nested_dir, /*recursive=*/true);  // creates missing parents
    ASSERT_TRUE(existsSync(nested_dir));

    // Populate with two files, then list.
    {
        std::ofstream(nested / "one.txt") << "1";
        std::ofstream(nested / "two.txt") << "2";
    }
    auto entries = listSync(nested_dir);
    ASSERT_TRUE(entries.size() == 2);
    bool saw_one = false, saw_two = false;
    for (const auto& e : entries) {
        const auto& m = std::any_cast<const std::map<std::string, std::any>&>(e);
        std::string path = std::any_cast<std::string>(m.at("path"));
        if (path.find("one.txt") != std::string::npos) saw_one = true;
        if (path.find("two.txt") != std::string::npos) saw_two = true;
    }
    ASSERT_TRUE(saw_one);
    ASSERT_TRUE(saw_two);

    fs::remove_all(root);
}

TEST(directory_create_non_recursive_leaf_only) {
    fs::path root = ball_dyn_test_temp_path("dir_leaf_root");
    Directory root_dir(root.string());
    createSync(root_dir, /*recursive=*/false);  // parent (temp dir) exists
    ASSERT_TRUE(existsSync(root_dir));
    fs::remove_all(root);
}

TEST(directory_create_non_recursive_throws_when_parent_missing) {
    fs::path missing_parent = ball_dyn_test_temp_path("dir_missing_parent");
    Directory child((missing_parent / "child").string());
    bool threw = false;
    try {
        createSync(child, /*recursive=*/false);
    } catch (const std::filesystem::filesystem_error&) {
        threw = true;
    }
    ASSERT_TRUE(threw);
    ASSERT_TRUE(!existsSync(child));
}

TEST(directory_exists_false_for_missing_path) {
    Directory d(ball_dyn_test_temp_path("does_not_exist").string());
    ASSERT_TRUE(!existsSync(d));
}

TEST(directory_constructors_from_string_any_and_balldyn) {
    Directory a(std::string("plain_dir"));
    ASSERT_EQ(a.path, std::string("plain_dir"));
    Directory b(std::any(std::string("any_dir")));
    ASSERT_EQ(b.path, std::string("any_dir"));
    Directory c(BallDyn(std::string("dyn_dir")));
    ASSERT_EQ(c.path, std::string("dyn_dir"));
}

// ================================================================
// _ball_json_escape / _ball_json_encode -- std_convert.jsonEncode's engine
// ================================================================
//
// `compiler.cpp` lowers `std_convert.json_encode` to a direct
// `_ball_json_encode(...)` call, and conformance fixture 185_std_convert really
// does drive it -- but that execution happens inside the e2e harness's
// per-fixture SUBPROCESS, which is compiled from the stringified
// ball_emit_runtime_embed.h copy with no `--coverage`, so gcov can never
// attribute a hit to this header (issue #63). Only an in-process call from an
// instrumented ctest binary can, which is what these tests are. Coverage-
// additive on already-correct code (the epic's convention since #332/#356/
// #397/#509/#533): they pass on first run, and their regression value is that
// JSON output is BYTE-compared against goldens on every other target, so a
// silent escaping change here would only surface as a cross-language diff.

TEST(cov_ball_json_escape_control_and_quote_arms) {
    // Every named escape, one arm each.
    ASSERT_EQ(_ball_json_escape(""), "\"\""s);
    ASSERT_EQ(_ball_json_escape("plain"), "\"plain\""s);
    ASSERT_EQ(_ball_json_escape("a\"b"), "\"a\\\"b\""s);
    ASSERT_EQ(_ball_json_escape("a\\b"), "\"a\\\\b\""s);
    ASSERT_EQ(_ball_json_escape("a\nb"), "\"a\\nb\""s);
    ASSERT_EQ(_ball_json_escape("a\rb"), "\"a\\rb\""s);
    ASSERT_EQ(_ball_json_escape("a\tb"), "\"a\\tb\""s);
    ASSERT_EQ(_ball_json_escape("a\bb"), "\"a\\bb\""s);
    ASSERT_EQ(_ball_json_escape("a\fb"), "\"a\\fb\""s);
    // Unnamed control chars take the \u00xx arm, low nibble and high nibble
    // both exercised (0x01 -> "01", 0x1f -> "1f").
    ASSERT_EQ(_ball_json_escape(std::string(1, '\x01')), "\"\\u0001\""s);
    ASSERT_EQ(_ball_json_escape(std::string(1, '\x1f')), "\"\\u001f\""s);
    // 0x20 (space) is the first NON-escaped code point -- the boundary the
    // `< 0x20` test guards.
    ASSERT_EQ(_ball_json_escape(" "), "\" \""s);
    // A high byte (>= 0x80 as unsigned) must pass through untouched, not be
    // mistaken for a control char by a signed `char` comparison.
    ASSERT_EQ(_ball_json_escape(std::string(1, '\xc3')),
              "\"" + std::string(1, '\xc3') + "\""s);
}

TEST(cov_ball_json_encode_scalar_list_map_and_extension_arms) {
    // Scalars: one arm per `typeid` test.
    ASSERT_EQ(_ball_json_encode(std::any{}), "null"s);
    ASSERT_EQ(_ball_json_encode(std::any(true)), "true"s);
    ASSERT_EQ(_ball_json_encode(std::any(false)), "false"s);
    ASSERT_EQ(_ball_json_encode(std::any((int64_t)-42)), "-42"s);
    ASSERT_EQ(_ball_json_encode(std::any((int)7)), "7"s);
    // A whole double keeps its ".0" (ball_to_string, not std::to_string) --
    // that is what makes C++ output match Dart's `1.0`, never `1`.
    ASSERT_EQ(_ball_json_encode(std::any((double)1.0)), "1.0"s);
    ASSERT_EQ(_ball_json_encode(std::any((double)1.5)), "1.5"s);
    ASSERT_EQ(_ball_json_encode(std::any(std::string("a\"b"))), "\"a\\\"b\""s);
    ASSERT_EQ(_ball_json_encode(std::any((const char*)"cc")), "\"cc\""s);

    // A BallDyn-wrapped value unwraps before dispatch.
    ASSERT_EQ(_ball_json_encode(std::any(BallDyn((int64_t)3))), "3"s);

    // Nested list: empty, scalars, and a nested list.
    ASSERT_EQ(_ball_json_encode(std::any(BallList_RT{})), "[]"s);
    ASSERT_EQ(_ball_json_encode(std::any(BallList_RT{
                  std::any((int64_t)1), std::any(std::string("x")),
                  std::any(BallList_RT{std::any(true)})})),
              "[1,\"x\",[true]]"s);

    // Map: internal keys are skipped to match the Dart engine -- a "__"-prefixed
    // key AND the literal "type_args" key. std::map orders keys, so "__hidden"
    // comes first and "type_args" last, exercising the skip on both the
    // first and the last entry (i.e. with `first` both true and false).
    BallMap_RT m;
    m["__hidden"] = std::any((int64_t)1);
    m["a"] = std::any((int64_t)2);
    m["b"] = std::any(BallList_RT{std::any((int64_t)3)});
    m["type_args"] = std::any(std::string("T"));
    ASSERT_EQ(_ball_json_encode(std::any(m)), "{\"a\":2,\"b\":[3]}"s);
    ASSERT_EQ(_ball_json_encode(std::any(BallMap_RT{})), "{}"s);

    // The ordered-map extension point (installed by ball_dyn.h): a
    // BallOrderedMap is not a BallMap_RT, so it reaches
    // `_ball_json_encode_ext_fn` and comes back in INSERTION order, with the
    // same internal-key skipping.
    BallOrderedMap om;
    om["z"s] = std::any((int64_t)1);
    om["__meta"s] = std::any((int64_t)9);
    om["a"s] = std::any((int64_t)2);
    ASSERT_EQ(_ball_json_encode(std::any(om)), "{\"z\":1,\"a\":2}"s);

    // Extension SET but declining (returns ""): a type it does not handle falls
    // through to the stringify-and-quote tail.
    ASSERT_TRUE(_ball_json_encode_ext_fn != nullptr);
    ASSERT_EQ(_ball_json_encode(std::any((float)1.0f)), "\"<any>\""s);

    // Extension UNSET: the same tail, reached without consulting the hook. The
    // pointer is a mutable global, so restore it for every later test.
    auto* saved = _ball_json_encode_ext_fn;
    _ball_json_encode_ext_fn = nullptr;
    std::string unset_float = _ball_json_encode(std::any((float)1.0f));
    std::string unset_ordered = _ball_json_encode(std::any(om));
    _ball_json_encode_ext_fn = saved;
    ASSERT_EQ(unset_float, "\"<any>\""s);
    // Without the hook an ordered map has no JSON encoder at all: it degrades to
    // the stringify tail, which renders it as a QUOTED Dart-style map string
    // rather than a JSON object -- exactly the silent corruption the hook
    // exists to prevent, pinned here so the tail is never mistaken for a
    // working fallback.
    ASSERT_EQ(unset_ordered, "\"{z: 1, a: 2}\""s);
    ASSERT_TRUE(_ball_json_encode_ext_fn != nullptr);
}

// ================================================================
// ball_object_type_matches -- `is`/`as` against the __type__/__super__ chain
// ================================================================
//
// Same structural blind spot as the JSON pair above: `compiler.cpp` emits
// `ball_object_type_matches(...)` for every `x is Point` on a map-backed
// object, but only ever inside a generated program compiled without
// instrumentation. These call it directly.

TEST(cov_ball_object_type_matches_super_chain_and_fallback) {
    // A generator value answers to the literal "BallGenerator" and nothing else
    // -- the arm that runs BEFORE any map view is looked for.
    ASSERT_TRUE(ball_object_type_matches(std::any(BallGenerator{}),
                                         "BallGenerator"));
    ASSERT_TRUE(!ball_object_type_matches(std::any(BallGenerator{}), "Point"));

    // A null value matches nothing.
    ASSERT_TRUE(!ball_object_type_matches(std::any{}, "Point"));

    // A RAW BallMap_RT carrying __type__ directly. Module-qualified names match
    // their bare form in both directions (ball_type_name_matches).
    BallMap_RT point;
    point["__type__"] = std::any(std::string("main:Point"));
    point["x"] = std::any((int64_t)1);
    ASSERT_TRUE(ball_object_type_matches(std::any(point), "Point"));
    ASSERT_TRUE(ball_object_type_matches(std::any(point), "main:Point"));
    ASSERT_TRUE(!ball_object_type_matches(std::any(point), "Other"));

    // __super__ chain: Grandchild -> Child -> Base. Every ancestor matches, and
    // an unrelated name matches none of them (which walks the WHOLE chain to
    // the end and falls out of the loop).
    BallMap_RT base;
    base["__type__"] = std::any(std::string("Base"));
    BallMap_RT child;
    child["__type__"] = std::any(std::string("Child"));
    child["__super__"] = std::any(base);
    BallMap_RT grand;
    grand["__type__"] = std::any(std::string("Grandchild"));
    grand["__super__"] = std::any(child);
    ASSERT_TRUE(ball_object_type_matches(std::any(grand), "Grandchild"));
    ASSERT_TRUE(ball_object_type_matches(std::any(grand), "Child"));
    ASSERT_TRUE(ball_object_type_matches(std::any(grand), "Base"));
    ASSERT_TRUE(!ball_object_type_matches(std::any(grand), "Unrelated"));

    // A __super__ that is not a map at all stops the walk instead of throwing.
    BallMap_RT bad_super;
    bad_super["__type__"] = std::any(std::string("Lone"));
    bad_super["__super__"] = std::any((int64_t)7);
    ASSERT_TRUE(ball_object_type_matches(std::any(bad_super), "Lone"));
    ASSERT_TRUE(!ball_object_type_matches(std::any(bad_super), "Base"));

    // A non-string __type__ is not a type tag: it must be ignored (and the
    // __super__ walk still consulted), never string-cast blindly.
    BallMap_RT numeric_tag;
    numeric_tag["__type__"] = std::any((int64_t)5);
    numeric_tag["__super__"] = std::any(base);
    ASSERT_TRUE(!ball_object_type_matches(std::any(numeric_tag), "5"));
    ASSERT_TRUE(ball_object_type_matches(std::any(numeric_tag), "Base"));
    // ...and likewise for a non-string tag on an ANCESTOR.
    BallMap_RT numeric_super;
    numeric_super["__type__"] = std::any((int64_t)6);
    BallMap_RT over_numeric;
    over_numeric["__type__"] = std::any(std::string("Over"));
    over_numeric["__super__"] = std::any(numeric_super);
    ASSERT_TRUE(!ball_object_type_matches(std::any(over_numeric), "6"));

    // A real BallObject (what an instance creation actually produces) is
    // reached through its BASE MAP, not a direct BallMap_RT cast -- both the
    // by-value and the shared_ptr (BallObjectRef) handle.
    BallMap widget_fields;
    widget_fields["w"] = std::any((int64_t)3);
    BallObject widget(std::any(std::string("main:Widget")), std::any(base),
                      std::any(widget_fields), std::any{});
    ASSERT_TRUE(ball_object_type_matches(std::any(widget), "Widget"));
    ASSERT_TRUE(ball_object_type_matches(std::any(widget), "Base"));
    ASSERT_TRUE(!ball_object_type_matches(std::any(widget), "Other"));
    BallObjectRef widget_ref = std::make_shared<BallObject>(
        std::any(std::string("main:Widget")), std::any{}, std::any(widget_fields),
        std::any{});
    ASSERT_TRUE(ball_object_type_matches(std::any(widget_ref), "Widget"));

    // No map view at all -> the ball_dyn.h extension point. With it installed,
    // a BallOrderedMap-backed object resolves through its own __type__ and
    // __super__; a plain scalar still matches nothing.
    ASSERT_TRUE(_ball_object_type_matches_ext != nullptr);
    BallOrderedMap om;
    om["__type__"s] = std::any(std::string("main:Ordered"));
    om["__super__"s] = std::any(base);
    ASSERT_TRUE(ball_object_type_matches(std::any(om), "Ordered"));
    ASSERT_TRUE(ball_object_type_matches(std::any(om), "Base"));
    ASSERT_TRUE(!ball_object_type_matches(std::any(om), "Other"));
    BallOrderedMap untagged;
    untagged["k"s] = std::any((int64_t)1);
    ASSERT_TRUE(!ball_object_type_matches(std::any(untagged), "Ordered"));
    ASSERT_TRUE(!ball_object_type_matches(std::any((int64_t)5), "Ordered"));

    // Extension UNSET: the same values answer a plain false instead of
    // crashing through a null hook.
    auto* saved = _ball_object_type_matches_ext;
    _ball_object_type_matches_ext = nullptr;
    bool unset_ordered = ball_object_type_matches(std::any(om), "Ordered");
    bool unset_scalar = ball_object_type_matches(std::any((int64_t)5), "Ordered");
    _ball_object_type_matches_ext = saved;
    ASSERT_TRUE(!unset_ordered);
    ASSERT_TRUE(!unset_scalar);
    ASSERT_TRUE(_ball_object_type_matches_ext != nullptr);
}

// ================================================================
// cov63_* -- reachability-audit coverage for ball_dyn.h (issue #63)
// ================================================================
//
// Each case below was written against a specific UNCOVERED line range in
// cpp/shared/include/ball_dyn.h, read from Codecov's `cpp` flag file_report at
// main @ f673169c (246 missed of 949 lines, 74.07%; the API's line_coverage
// state is 0 = HIT / 1 = MISS -- calibrated against totals.hits before use, per
// .claude/rules/cpp.md).
//
// THE AUDIT QUESTION for every cluster was "is this reachable from anything
// other than the self-host path?", and the answer is YES for all 246. The
// reason is the structural undercount cpp/test/AGENTS.md documents: ball_dyn.h
// is embedded verbatim into every generated program, and test_e2e builds each
// fixture in a separate NON-`--coverage` subprocess, so the whole conformance
// corpus can pound a function here without gcov ever attributing a hit. A 0%
// line in this header means "not called IN-PROCESS by an instrumented ctest
// binary" -- it does NOT mean "only the self-hosted engine can reach it".
// Every one of these is an `inline` member or free function on a plain value
// type, callable directly from this file with no engine, no toolchain and no
// I/O. So NONE of them earns an `LCOV_EXCL_LINE`: the honest remedy is a test,
// and a blanket exclusion would have hidden real, testable behaviour.
//
// Each TEST names the cluster it closes so the next reader can re-derive the
// mapping against a fresh report rather than trusting a stale line number.

// Build a BallDyn holding a by-VALUE BallOrderedMap (the shape the self-hosted
// engine hands through std::any). The BallDyn(BallOrderedMap) constructor
// deliberately upgrades to a shared BallOrderedMapRef, so the by-value arms are
// only reachable by assigning _val directly.
static BallDyn _dyn_of(const BallOrderedMap& om) {
    BallDyn d;
    d._val = std::any(om);
    return d;
}

// --- BallOrderedMap::empty (58) ------------------------------------------
TEST(cov63_ordered_map_empty) {
    BallOrderedMap m;
    ASSERT_TRUE(m.empty());
    m["k"s] = std::any((int64_t)1);
    ASSERT_TRUE(!m.empty());
    ASSERT_EQ(m.size(), (size_t)1);
}

// --- _orderedMapPtr / _setBackingList by-VALUE backings (320, 327,
//     358-359, 368-373) ---------------------------------------------------
TEST(cov63_by_value_ordered_map_and_set_backings) {
    // BallDyn(BallOrderedMap) normally upgrades to a BallOrderedMapRef, so the
    // by-value `typeid(BallOrderedMap)` arms of _orderedMapPtr() are reached by
    // assigning the raw std::any directly -- the shape the SELF-HOSTED engine
    // produces when it hands a plain ordered map through std::any.
    BallOrderedMap raw;
    raw["a"s] = std::any((int64_t)1);
    BallDyn d;
    d._val = std::any(raw);
    const BallDyn& cd = d;
    ASSERT_TRUE(d._orderedMapPtr() != nullptr);
    ASSERT_TRUE(cd._orderedMapPtr() != nullptr);
    ASSERT_EQ(d._orderedMapPtr()->size(), (size_t)1);

    // Same for a set whose "__ball_set__" backing is a by-value BallList
    // rather than a BallListRef (again the self-host shape).
    BallOrderedMap set_om;
    set_om["__ball_set__"s] = std::any(BallList{std::any((int64_t)7)});
    BallDyn s;
    s._val = std::any(set_om);
    const BallDyn& cs = s;
    ASSERT_TRUE(s._setBackingList() != nullptr);
    ASSERT_EQ(s._setBackingList()->size(), (size_t)1);
    ASSERT_TRUE(cs._setBackingList() != nullptr);

    // ... and a BallDyn-wrapped list, which the unwrap loop must peel.
    BallOrderedMap wrapped;
    wrapped["__ball_set__"s] = std::any(BallDyn(std::any(BallList{
        std::any((int64_t)1), std::any((int64_t)2)})));
    BallDyn w;
    w._val = std::any(wrapped);
    ASSERT_TRUE(w._setBackingList() != nullptr);
    ASSERT_EQ(w._setBackingList()->size(), (size_t)2);

    // A 1-entry ordered map WITHOUT the tag, and a >1-entry one, are not sets.
    BallOrderedMap not_set;
    not_set["other"s] = std::any((int64_t)1);
    BallDyn n;
    n._val = std::any(not_set);
    ASSERT_TRUE(n._setBackingList() == nullptr);
    const BallDyn& cn = n;
    ASSERT_TRUE(cn._setBackingList() == nullptr);
}

// --- copy ctor deep-copies a ROOT scope (394-398) ------------------------
TEST(cov63_copy_ctor_deep_copies_root_scope) {
    // A root scope (no __parent__) is deep-copied on BallDyn copy so a callee
    // cannot leak parameter writes back into the caller's scope.
    BallScope root = std::make_shared<BallMap>();
    (*root)["x"s] = std::any((int64_t)1);
    BallDyn a{std::any(root)};
    BallDyn b = a;             // copy ctor -> deep copy
    b.set("x", std::any((int64_t)2));
    ASSERT_EQ((int64_t)BallDyn((*root)["x"s]), (int64_t)1);

    // A CHILD scope (has __parent__) keeps sharing, so writes are visible.
    BallScope child = std::make_shared<BallMap>();
    (*child)["__parent__"s] = std::any(root);
    (*child)["y"s] = std::any((int64_t)1);
    BallDyn c{std::any(child)};
    BallDyn e = c;             // copy ctor -> shared
    e.set("y", std::any((int64_t)9));
    ASSERT_EQ((int64_t)BallDyn((*child)["y"s]), (int64_t)9);
}

// --- operator bool: non-null non-scalar is truthy (448) ------------------
TEST(cov63_operator_bool_non_scalar_is_truthy) {
    BallDyn list(BallList{});
    ASSERT_TRUE((bool)list);           // an empty list is still non-null
    ASSERT_TRUE(!(bool)BallDyn());     // null is falsey
    ASSERT_TRUE(!(bool)BallDyn(std::string("")));
}

// --- operator std::string: object toString, scope/map printing, the
//     reified-exception shortcut and the <dynamic> fallback
//     (473-480, 500-513, 520-528, 532-541, 548) --------------------------
TEST(cov63_to_string_invokes_object_toString_method) {
    BallMap methods;
    methods["toString"s] = std::any(BallFunc([](std::any) -> std::any {
        return std::any(std::string("CUSTOM"));
    }));
    BallObject obj(std::any(std::string("Pair")), std::any{},
                   std::any(BallMap{{"a", std::any((int64_t)1)}}),
                   std::any(methods));
    BallDyn d{std::any(std::make_shared<BallObject>(obj))};
    ASSERT_EQ((std::string)d, std::string("CUSTOM"));
}

TEST(cov63_to_string_scope_and_map_hide_dunder_keys) {
    BallScope sc = std::make_shared<BallMap>();
    (*sc)["a"s] = std::any((int64_t)1);
    (*sc)["b"s] = std::any(std::string("z"));
    (*sc)["__parent__"s] = std::any(std::string("hidden"));
    (*sc)["type_args"s] = std::any(std::string("hidden"));
    BallDyn d{std::any(sc)};
    std::string s = (std::string)d;
    ASSERT_EQ(s, std::string("{a: 1, b: z}"));

    // Plain BallMap takes the sibling branch with the same dunder filtering.
    BallDyn m(BallMap{{"a", std::any((int64_t)1)},
                      {"__hidden__", std::any((int64_t)2)},
                      {"type_args", std::any((int64_t)3)}});
    ASSERT_EQ((std::string)m, std::string("{a: 1}"));
}

TEST(cov63_to_string_reified_exception_prefers_value_then_message) {
    // _ball_exception_to_dyn's shape: a map tagged __type__ = "BallException".
    BallDyn with_value(BallMap{
        {"__type__", std::any(std::string("BallException"))},
        {"value", std::any(std::string("boom"))}});
    ASSERT_EQ((std::string)with_value, std::string("boom"));

    BallDyn with_message(BallMap{
        {"__type__", std::any(std::string("BallException"))},
        {"message", std::any(std::string("msg"))}});
    ASSERT_EQ((std::string)with_message, std::string("msg"));

    // Tagged but carrying neither key -> falls through to the generic map print.
    BallDyn neither(BallMap{
        {"__type__", std::any(std::string("BallException"))},
        {"other", std::any((int64_t)5)}});
    ASSERT_EQ((std::string)neither, std::string("{other: 5}"));
}

TEST(cov63_to_string_unknown_payload_is_dynamic_placeholder) {
    struct Opaque { int v; };
    BallDyn d;
    d._val = std::any(Opaque{1});
    ASSERT_EQ((std::string)d, std::string("<dynamic>"));
}

// --- numeric conversions from every stored scalar (554-557, 561-563) -----
TEST(cov63_int64_and_double_conversions_across_stored_types) {
    BallDyn as_int;      as_int._val = std::any((int)5);
    BallDyn as_double(3.9);
    BallDyn as_bool(true);
    ASSERT_EQ((int64_t)as_int, (int64_t)5);
    ASSERT_EQ((int64_t)as_double, (int64_t)3);
    ASSERT_EQ((int64_t)as_bool, (int64_t)1);
    ASSERT_EQ((int64_t)BallDyn(), (int64_t)0);   // null -> 0

    ASSERT_TRUE((double)BallDyn((int64_t)7) == 7.0);
    ASSERT_TRUE((double)as_int == 5.0);
    ASSERT_TRUE((double)BallDyn() == 0.0);       // null -> 0.0
}

// --- operator[](string) on a generator and on an object (576-578, 582-585)
TEST(cov63_index_string_on_generator_and_object) {
    BallGenerator g;
    g.values->push_back(std::any((int64_t)1));
    g.values->push_back(std::any((int64_t)2));
    BallDyn gd;
    gd._val = std::any(g);
    ASSERT_EQ((int64_t)gd["values"s].size(), (int64_t)2);
    // Any other key on a generator is null.
    ASSERT_TRUE(!gd["nope"s]._val.has_value());

    BallObject obj(std::any(std::string("P")), std::any{},
                   std::any(BallMap{{"a", std::any((int64_t)42)}}), std::any{});
    BallDyn od{std::any(std::make_shared<BallObject>(obj))};
    ASSERT_EQ((int64_t)od["a"s], (int64_t)42);
    ASSERT_TRUE(!od["missing"s]._val.has_value());
}

// --- operator[](int64_t): RangeError text + vector<string> backing
//     (651-657) ---------------------------------------------------------
TEST(cov63_index_out_of_range_and_string_vector_backing) {
    BallDyn list(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    bool threw = false;
    try {
        (void)list[(int64_t)5];
    } catch (const BallException& e) {
        threw = true;
        const std::string msg = e.what();
        ASSERT_TRUE(msg.find("RangeError"s) != std::string::npos);
        ASSERT_TRUE(msg.find("Index out of range"s) != std::string::npos);
    }
    ASSERT_TRUE(threw);

    BallDyn sv;
    sv._val = std::any(std::vector<std::string>{"a", "b"});
    ASSERT_EQ((std::string)sv[(int64_t)1], std::string("b"));
}

// --- set(): scope-chain walk, object/list re-wrapping into ref types, and
//     the out-of-range list-index guard (689-730, 750) ------------------
TEST(cov63_set_walks_parent_scope_chain) {
    BallScope root = std::make_shared<BallMap>();
    (*root)["v"s] = std::any((int64_t)1);
    BallScope child = std::make_shared<BallMap>();
    (*child)["__parent__"s] = std::any(root);
    BallDyn cd{std::any(child)};
    // `v` is not local, so the write must find and update the PARENT binding.
    cd.set("v", std::any((int64_t)2));
    ASSERT_EQ((int64_t)BallDyn((*root)["v"s]), (int64_t)2);
    ASSERT_TRUE(child->find("v") == child->end());

    // A name bound nowhere in the chain is created locally.
    cd.set("fresh", std::any((int64_t)3));
    ASSERT_EQ((int64_t)BallDyn((*child)["fresh"s]), (int64_t)3);
}

TEST(cov63_set_rewraps_objects_and_lists_as_reference_types) {
    // Plain BallMap receiver: a BallObject/BallList value is re-wrapped as a
    // BallObjectRef/BallListRef so later mutation is observed by every holder.
    BallDyn m(BallMap{});
    m.set("o", std::any(BallObject(std::any(std::string("T")))));
    m.set("l", std::any(BallList{std::any((int64_t)1)}));
    ASSERT_TRUE(std::any_cast<const BallMap&>(m._val).at("o").type() ==
                typeid(BallObjectRef));
    ASSERT_TRUE(std::any_cast<const BallMap&>(m._val).at("l").type() ==
                typeid(BallListRef));

    // BallOrderedMap receiver: same re-wrapping through the ordered-map arm.
    BallDyn om(BallOrderedMap{});
    om.set("o", std::any(BallObject(std::any(std::string("T")))));
    om.set("l", std::any(BallList{std::any((int64_t)2)}));
    ASSERT_TRUE((*om._orderedMapPtr())["o"s].type() == typeid(BallObjectRef));
    ASSERT_TRUE((*om._orderedMapPtr())["l"s].type() == typeid(BallListRef));
}

TEST(cov63_set_numeric_key_out_of_range_on_list_is_swallowed) {
    // A list receiver with a non-numeric / out-of-range key must not throw:
    // the catch(...) guard makes it a no-op.
    BallDyn list(BallList{std::any((int64_t)1)});
    list.set("not_a_number", std::any((int64_t)9));
    ASSERT_EQ((int64_t)list.size(), (int64_t)1);
}

// --- count() over scope / object / no-container (789-791, 797) ----------
TEST(cov63_count_over_scope_object_and_scalar) {
    BallScope sc = std::make_shared<BallMap>();
    (*sc)["k"s] = std::any((int64_t)1);
    BallDyn sd{std::any(sc)};
    ASSERT_EQ(sd.count("k"s), (size_t)1);
    ASSERT_EQ(sd.count("nope"s), (size_t)0);

    BallObject obj(std::any(std::string("T")), std::any{},
                   std::any(BallMap{{"f", std::any((int64_t)1)}}), std::any{});
    BallDyn od{std::any(std::make_shared<BallObject>(obj))};
    ASSERT_EQ(od.count("f"s), (size_t)1);

    // A scalar holds no keys at all.
    ASSERT_EQ(BallDyn((int64_t)1).count("k"s), (size_t)0);
}

// --- hashCode over double / string / other (816-822) --------------------
TEST(cov63_hash_code_for_double_string_and_null) {
    ASSERT_EQ(BallDyn(2.5).hashCode(),
              static_cast<int64_t>(std::hash<double>{}(2.5)));
    ASSERT_EQ(BallDyn(std::string("k")).hashCode(),
              static_cast<int64_t>(std::hash<std::string>{}(std::string("k"))));
    ASSERT_EQ(BallDyn().hashCode(), (int64_t)0);
}

// --- empty() / size() over set, ordered map, unordered map (851-854, 867)
TEST(cov63_empty_and_size_over_every_container_backing) {
    BallDyn empty_set = ball_make_set(BallList{});
    ASSERT_TRUE(empty_set.empty());
    BallDyn one_set = ball_make_set(BallList{std::any((int64_t)1)});
    ASSERT_TRUE(!one_set.empty());

    BallDyn om(BallOrderedMap{});
    ASSERT_TRUE(om.empty());

    BallDyn um;
    um._val = std::any(BallUMap{});
    ASSERT_TRUE(um.empty());
    ASSERT_EQ(um.size(), (int64_t)0);

    // A scalar has neither.
    ASSERT_TRUE(!BallDyn((int64_t)1).empty());
    ASSERT_EQ(BallDyn((int64_t)1).size(), (int64_t)0);
}

// --- front()/back() on a non-list (888, 896) ----------------------------
TEST(cov63_front_and_back_on_non_list_are_null) {
    BallDyn scalar((int64_t)1);
    ASSERT_TRUE(!scalar.front()._val.has_value());
    ASSERT_TRUE(!scalar.back()._val.has_value());
}

// --- erase(key) over scope / ordered map / unordered map (901-907) ------
TEST(cov63_erase_key_over_scope_ordered_and_unordered_maps) {
    BallScope sc = std::make_shared<BallMap>();
    (*sc)["k"s] = std::any((int64_t)1);
    BallDyn sd{std::any(sc)};
    sd.erase("k"s);
    ASSERT_EQ(sd.count("k"s), (size_t)0);

    BallDyn om(BallOrderedMap{});
    om.set("k", std::any((int64_t)1));
    om.erase("k"s);
    ASSERT_EQ(om.count("k"s), (size_t)0);

    BallUMap raw;
    raw["k"s] = std::any((int64_t)1);
    BallDyn um;
    um._val = std::any(raw);
    um.erase("k"s);
    ASSERT_EQ(um.count("k"s), (size_t)0);
}

// --- erase(BallDyn) on a plain BallMap (928) ---------------------------
TEST(cov63_erase_dyn_key_on_plain_map) {
    BallDyn m(BallMap{{"k", std::any((int64_t)1)},
                      {"j", std::any((int64_t)2)}});
    m.erase(BallDyn(std::string("k")));
    ASSERT_EQ(m.count("k"s), (size_t)0);
    ASSERT_EQ(m.count("j"s), (size_t)1);
}

// --- substr()/find() on a non-string (936, 941, 946) -------------------
TEST(cov63_substr_and_find_on_non_string_are_neutral) {
    BallDyn n((int64_t)1);
    ASSERT_EQ(n.substr(0), std::string(""));
    ASSERT_EQ(n.substr(0, 2), std::string(""));
    ASSERT_TRUE(n.find("x"s) == std::string::npos);
}

// --- operator== identity/structural arms (956-967, 999-1015, 1035, 1040,
//     1072) --------------------------------------------------------------
TEST(cov63_equality_object_identity_is_by_handle) {
    auto shared = std::make_shared<BallObject>(
        BallObject(std::any(std::string("T"))));
    BallDyn a{std::any(shared)};
    BallDyn b{std::any(shared)};
    ASSERT_TRUE(a == b);                       // same handle
    auto other = std::make_shared<BallObject>(
        BallObject(std::any(std::string("T"))));
    ASSERT_TRUE(!(a == BallDyn(std::any(other))));   // distinct handles
    // An object never equals a non-object.
    ASSERT_TRUE(!(a == BallDyn((int64_t)1)));
    ASSERT_TRUE(!(BallDyn((int64_t)1) == a));
}

TEST(cov63_equality_user_ref_and_list_arms) {
    auto u = std::make_shared<std::any>(std::any((int64_t)1));
    BallDyn a{std::any(u)}, b{std::any(u)};
    ASSERT_TRUE(a == b);

    // Lists compare through the `_listPtr()` arm, which covers BOTH
    // representations -- a shared BallListRef and a by-value BallList -- and so
    // dominates the later per-representation arms (see the LCOV_EXCL_START
    // block in ball_dyn.h::operator==, which the #63 audit found to be dead).
    auto l1 = std::make_shared<BallList>(BallList{std::any((int64_t)1)});
    ASSERT_TRUE(BallDyn(std::any(l1)) == BallDyn(std::any(l1)));

    // By-value lists compare element-wise (self-host shape).
    BallDyn v1, v2, v3, v4;
    v1._val = std::any(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    v2._val = std::any(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    v3._val = std::any(BallList{std::any((int64_t)1), std::any((int64_t)9)});
    v4._val = std::any(BallList{std::any((int64_t)1)});
    ASSERT_TRUE(v1 == v2);
    ASSERT_TRUE(!(v1 == v3));
    ASSERT_TRUE(!(v1 == v4));   // length mismatch short-circuits

    // Unrelated payload types are simply unequal, never a throw.
    BallDyn opaque;
    opaque._val = std::any(std::vector<std::string>{"a"});
    ASSERT_TRUE(!(opaque == BallDyn((int64_t)1)));
}

TEST(cov63_equality_against_raw_string_and_bool) {
    ASSERT_TRUE(BallDyn(std::string("a")) == std::string("a"));
    ASSERT_TRUE(!(BallDyn((int64_t)1) == std::string("a")));
    ASSERT_TRUE(BallDyn(true) == true);
    ASSERT_TRUE(!(BallDyn((int64_t)1) == true));
}

// --- mixed-type arithmetic promotes to double (1097-1126) --------------
TEST(cov63_mixed_numeric_arithmetic_promotes_to_double) {
    BallDyn i((int64_t)7), d(2.0);
    ASSERT_TRUE((double)(i - d) == 5.0);
    ASSERT_TRUE((double)(i * d) == 14.0);
    ASSERT_TRUE((double)(i / d) == 3.5);
    ASSERT_EQ((int64_t)(i % d), (int64_t)1);
    ASSERT_TRUE((double)(-d) == -2.0);
    // Negating a non-numeric yields null rather than throwing.
    ASSERT_TRUE(!(-BallDyn(std::string("x")))._val.has_value());
}

// --- ++/-- on a double (1270, 1276) ------------------------------------
TEST(cov63_increment_and_decrement_on_double) {
    BallDyn d(1.5);
    ++d;
    ASSERT_TRUE((double)d == 2.5);
    --d;
    ASSERT_TRUE((double)d == 1.5);
    // A non-numeric is left untouched by both.
    BallDyn s(std::string("x"));
    ++s; --s;
    ASSERT_EQ((std::string)s, std::string("x"));
}

// --- indexOf over a set backing, and the not-a-container arm (1314-1327)
TEST(cov63_index_of_over_set_backing_and_scalar) {
    BallDyn set = ball_make_set(BallList{std::any((int64_t)10),
                                         std::any((int64_t)20)});
    ASSERT_EQ(set.indexOf(BallDyn((int64_t)20)), (int64_t)1);
    ASSERT_EQ(set.indexOf(BallDyn((int64_t)99)), (int64_t)-1);
    ASSERT_EQ(BallDyn((int64_t)1).indexOf(BallDyn((int64_t)1)), (int64_t)-1);
}

// --- begin()/end() over a non-iterable (1343-1344, 1349-1350) ----------
TEST(cov63_iteration_over_non_iterable_is_an_empty_range) {
    BallDyn scalar((int64_t)1);
    int64_t n = 0;
    for (auto it = scalar.begin(); it != scalar.end(); ++it) n++;
    ASSERT_EQ(n, (int64_t)0);
}

// --- operator()(arg) on a non-callable (1364) --------------------------
TEST(cov63_calling_a_non_callable_yields_null) {
    BallDyn not_fn((int64_t)1);
    ASSERT_TRUE(!not_fn(BallDyn())._val.has_value());
}

// --- values() on a generator (1396) ------------------------------------
TEST(cov63_values_on_generator_returns_its_list) {
    BallGenerator g;
    g.values->push_back(std::any((int64_t)3));
    BallDyn gd;
    gd._val = std::any(g);
    ASSERT_EQ((int64_t)gd.values().size(), (int64_t)1);
}

// --- _ball_object_base_map / _ballAnyToMap conversions (1465-1466,
//     1495-1522) ---------------------------------------------------------
TEST(cov63_any_to_map_accepts_every_map_shaped_payload) {
    // BallObject by value.
    BallMap from_obj = _ballAnyToMap(
        std::any(BallObject(std::any(std::string("T")), std::any{},
                            std::any(BallMap{{"a", std::any((int64_t)1)}}),
                            std::any{})));
    ASSERT_EQ(from_obj.count("a"s), (size_t)1);

    // BallObjectRef, and a NULL BallObjectRef (-> empty map, never a crash).
    BallMap from_ref = _ballAnyToMap(std::any(std::make_shared<BallObject>(
        BallObject(std::any(std::string("T")), std::any{},
                   std::any(BallMap{{"b", std::any((int64_t)1)}}), std::any{}))));
    ASSERT_EQ(from_ref.count("b"s), (size_t)1);
    ASSERT_TRUE(_ballAnyToMap(std::any(BallObjectRef{})).empty());

    // std::unordered_map.
    BallUMap um;
    um["c"s] = std::any((int64_t)1);
    ASSERT_EQ(_ballAnyToMap(std::any(um)).count("c"s), (size_t)1);

    // BallOrderedMap by value and by ref -- the arm that keeps a
    // BallObject built from an ordered field set from losing every field.
    BallOrderedMap om;
    om["d"s] = std::any((int64_t)1);
    ASSERT_EQ(_ballAnyToMap(std::any(om)).count("d"s), (size_t)1);
    ASSERT_EQ(_ballAnyToMap(std::any(std::make_shared<BallOrderedMap>(om)))
                  .count("d"s), (size_t)1);

    // Anything else is an empty map.
    ASSERT_TRUE(_ballAnyToMap(std::any((int64_t)1)).empty());

    // _ball_object_base_map over both object representations. It takes an
    // ALREADY-UNWRAPPED std::any (every caller unwraps first), so handed a
    // BallDyn wrapper it correctly answers nullptr rather than peeling it.
    auto shared = std::make_shared<BallObject>(
        BallObject(std::any(std::string("T")), std::any{},
                   std::any(BallMap{{"e", std::any((int64_t)1)}}), std::any{}));
    const BallMap* by_ref = _ball_object_base_map(std::any(shared));
    ASSERT_TRUE(by_ref != nullptr);
    ASSERT_EQ(by_ref->count("e"), (size_t)1);
    // The by-VALUE arm returns a pointer INTO the std::any's stored object, so
    // the any must outlive the read -- passing a temporary dangles the moment
    // the full expression ends (libstdc++ happened to still read the right
    // bytes; libc++ did not, which is what the macOS leg caught).
    const std::any by_val_any{BallObject(
        std::any(std::string("T")), std::any{},
        std::any(BallMap{{"e", std::any((int64_t)1)}}), std::any{})};
    const BallMap* by_val = _ball_object_base_map(by_val_any);
    ASSERT_TRUE(by_val != nullptr);
    ASSERT_EQ(by_val->count("e"), (size_t)1);
    ASSERT_TRUE(_ball_object_base_map(std::any(BallDyn(std::any(shared)))) == nullptr);
    ASSERT_TRUE(_ball_object_base_map(std::any((int64_t)1)) == nullptr);
    ASSERT_TRUE(_ball_object_base_map(std::any()) == nullptr);
}

// --- _ball_strbuf_ptr on a non-buffer (1606) ---------------------------
TEST(cov63_strbuf_ptr_on_non_buffer_is_null) {
    ASSERT_TRUE(_ball_strbuf_ptr(BallDyn((int64_t)1)) == nullptr);
}

// --- _ball_bind_local across every scope representation (1856-1869) ----
TEST(cov63_bind_local_across_scope_representations) {
    BallDyn as_map(BallMap{});
    _ball_bind_local(as_map, "a", std::any((int64_t)1));
    ASSERT_EQ((int64_t)as_map["a"s], (int64_t)1);

    BallDyn as_om;
    as_om._val = std::any(BallOrderedMap{});
    _ball_bind_local(as_om, "b", std::any((int64_t)2));
    ASSERT_EQ((int64_t)as_om["b"s], (int64_t)2);

    BallDyn as_omref{std::any(std::make_shared<BallOrderedMap>())};
    _ball_bind_local(as_omref, "c", std::any((int64_t)3));
    ASSERT_EQ((int64_t)as_omref["c"s], (int64_t)3);

    // Anything else falls back to BallDyn::set.
    BallObject obj(std::any(std::string("T")));
    BallDyn as_obj{std::any(std::make_shared<BallObject>(obj))};
    _ball_bind_local(as_obj, "d", std::any((int64_t)4));
    ASSERT_EQ((int64_t)as_obj["d"s], (int64_t)4);
}

// --- _ball_get_parent_scope / _ball_scope_has_key on a BallMap scope
//     (1934-1943, 1952-1955) ---------------------------------------------
TEST(cov63_parent_scope_and_has_key_over_plain_map_scope) {
    BallScope root = std::make_shared<BallMap>();
    BallDyn map_scope(BallMap{{"__parent__", std::any(root)},
                              {"k", std::any((int64_t)1)}});
    ASSERT_TRUE(_ball_get_parent_scope(map_scope) == root);
    ASSERT_TRUE(_ball_scope_has_key(map_scope, "k"));
    ASSERT_TRUE(!_ball_scope_has_key(map_scope, "nope"));

    // A scope with no __parent__ at all, and a non-scope value.
    BallDyn no_parent(BallMap{{"k", std::any((int64_t)1)}});
    ASSERT_TRUE(_ball_get_parent_scope(no_parent) == nullptr);
    ASSERT_TRUE(_ball_get_parent_scope(BallDyn((int64_t)1)) == nullptr);
    ASSERT_TRUE(!_ball_scope_has_key(BallDyn((int64_t)1), "k"));
}

// --- ball_scope_assign: local hit, parent walk, and create-in-current
//     (2133-2153) ---------------------------------------------------------
TEST(cov63_scope_assign_local_parent_and_fresh) {
    BallScope root = std::make_shared<BallMap>();
    (*root)["p"s] = std::any((int64_t)1);
    BallScope child = std::make_shared<BallMap>();
    (*child)["__parent__"s] = std::any(root);
    (*child)["own"s] = std::any((int64_t)1);
    BallDyn scope{std::any(child)};

    // Bound locally -> updated in place.
    set(scope, BallDyn(std::string("own")), BallDyn((int64_t)5));
    ASSERT_EQ((int64_t)BallDyn((*child)["own"s]), (int64_t)5);

    // Bound in the parent -> the walk finds and updates it there.
    set(scope, BallDyn(std::string("p")), BallDyn((int64_t)7));
    ASSERT_EQ((int64_t)BallDyn((*root)["p"s]), (int64_t)7);

    // Bound nowhere -> created in the current scope.
    set(scope, BallDyn(std::string("fresh")), BallDyn((int64_t)9));
    ASSERT_EQ((int64_t)BallDyn((*child)["fresh"s]), (int64_t)9);
}

// --- _ball_ordered_map_to_string with a by-value set backing (2291) ----
TEST(cov63_ordered_map_to_string_with_by_value_set_backing) {
    BallOrderedMap om;
    om["__ball_set__"s] = std::any(BallList{std::any((int64_t)1),
                                           std::any((int64_t)2)});
    ASSERT_EQ(_ball_ordered_map_to_string(om), std::string("{1, 2}"));
}

// --- _ball_set_or_list_elements on a non-container (2344) --------------
TEST(cov63_set_or_list_elements_on_scalar_is_empty) {
    ASSERT_TRUE(_ball_set_or_list_elements(BallDyn((int64_t)1)).empty());
}

// --- the registrar's extension hooks, reached through their PUBLIC
//     entry points in ball_emit_runtime.h (2491, 2529, 2534-2581) -------
TEST(cov63_ordered_map_extension_hooks) {
    // _ball_is_map_ext: ball_is_map must see a BallOrderedMap as a map.
    ASSERT_TRUE(ball_is_map(std::any(BallOrderedMap{})));
    ASSERT_TRUE(!ball_is_map(std::any((int64_t)1)));

    // _ball_object_type_matches_ext / _ball_object_type_tag_ext: an ordered
    // map carrying __type__ discriminates like a BallMap-backed object, and
    // the tag is returned module-prefix-stripped.
    BallOrderedMap tagged;
    tagged["__type__"s] = std::any(std::string("mod:Point"));
    ASSERT_EQ(ball_object_type_tag(std::any(tagged)), std::string("Point"));
    ASSERT_TRUE(ball_object_type_matches(std::any(tagged), "Point"));
    ASSERT_TRUE(!ball_object_type_matches(std::any(tagged), "Other"));

    // No __type__, or a non-string one -> no tag.
    ASSERT_TRUE(ball_object_type_tag(std::any(BallOrderedMap{})).empty());
    BallOrderedMap bad_tag;
    bad_tag["__type__"s] = std::any((int64_t)1);
    ASSERT_TRUE(ball_object_type_tag(std::any(bad_tag)).empty());
    ASSERT_TRUE(ball_object_type_tag(std::any((int64_t)1)).empty());

    // _ball_typed_map_ext: `is Map<K, V>` discriminates on the FIRST value.
    ASSERT_TRUE(ball_is_typed_map(std::any(BallOrderedMap{}), "int"));  // empty matches
    BallOrderedMap ints;    ints["a"s] = std::any((int64_t)1);
    BallOrderedMap dbls;    dbls["a"s] = std::any(2.5);
    BallOrderedMap strs;    strs["a"s] = std::any(std::string("s"));
    BallOrderedMap bools;   bools["a"s] = std::any(true);
    ASSERT_TRUE(ball_is_typed_map(std::any(ints), "int"));
    ASSERT_TRUE(ball_is_typed_map(std::any(ints), "num"));
    ASSERT_TRUE(ball_is_typed_map(std::any(dbls), "double"));
    ASSERT_TRUE(ball_is_typed_map(std::any(dbls), "num"));
    ASSERT_TRUE(ball_is_typed_map(std::any(strs), "String"));
    ASSERT_TRUE(ball_is_typed_map(std::any(bools), "bool"));
    ASSERT_TRUE(!ball_is_typed_map(std::any(ints), "String"));
    ASSERT_TRUE(!ball_is_typed_map(std::any((int64_t)1), "int"));

    // _BallRefDeref::_set_list_fn: the registered set-backing probe, via the
    // public ball_is_ball_set/ball_set_elements surface, over BOTH backings.
    BallOrderedMap by_value;
    by_value["__ball_set__"s] = std::any(BallList{std::any((int64_t)1)});
    ASSERT_TRUE(ball_is_ball_set(_dyn_of(by_value)));
    BallOrderedMap by_dyn;
    by_dyn["__ball_set__"s] = std::any(BallDyn(std::any(BallList{
        std::any((int64_t)1), std::any((int64_t)2)})));
    ASSERT_TRUE(ball_is_ball_set(_dyn_of(by_dyn)));
    // Wrong shapes: not one entry, or the one entry is not the tag, or the
    // tagged value is not a list at all.
    ASSERT_TRUE(!ball_is_ball_set(_dyn_of(BallOrderedMap{})));
    BallOrderedMap two;
    two["__ball_set__"s] = std::any(BallList{});
    two["x"s] = std::any((int64_t)1);
    ASSERT_TRUE(!ball_is_ball_set(_dyn_of(two)));
    BallOrderedMap mistagged;
    mistagged["other"s] = std::any(BallList{});
    ASSERT_TRUE(!ball_is_ball_set(_dyn_of(mistagged)));
    BallOrderedMap not_a_list;
    not_a_list["__ball_set__"s] = std::any((int64_t)1);
    ASSERT_TRUE(!ball_is_ball_set(_dyn_of(not_a_list)));
}

// --- ball_map_entries over an ordered map and an object (2664-2673) ----
TEST(cov63_map_entries_over_ordered_map_and_object) {
    BallDyn om(BallOrderedMap{});
    om.set("a", std::any((int64_t)1));
    om.set("b", std::any((int64_t)2));
    BallDyn entries = ball_map_entries(om);
    ASSERT_EQ((int64_t)entries.size(), (int64_t)2);
    ASSERT_EQ((std::string)entries[(int64_t)0]["key"s], std::string("a"));
    ASSERT_EQ((int64_t)entries[(int64_t)1]["value"s], (int64_t)2);

    // An object routes through _ball_object_base_map rather than a direct
    // BallMap cast.
    BallObject obj(std::any(std::string("T")), std::any{},
                   std::any(BallMap{{"f", std::any((int64_t)9)}}), std::any{});
    BallDyn od{std::any(std::make_shared<BallObject>(obj))};
    BallDyn obj_entries = ball_map_entries(od);
    ASSERT_TRUE((int64_t)obj_entries.size() >= (int64_t)1);
}

// --- second wave: clusters the first pass reached a DIFFERENT arm of --------
//
// Each of these targets a branch that an earlier, dominating arm had absorbed
// in the first pass, so the value has to be built in the exact representation
// that selects it (by-VALUE where the public constructor upgrades to a shared
// handle, a deeper scope chain, a non-list payload behind the set tag, ...).
// Re-measured against the same recipe, which is how the mismatch was found:
// coverage, not the test name, is what says the branch was actually taken.

// --- _setBackingList (non-const): tagged but NOT a list (359) -------------
TEST(cov63_set_backing_list_tag_holding_non_list) {
    BallOrderedMap om;
    om["__ball_set__"] = std::any((int64_t)1);   // tagged, but not a list
    BallDyn d;
    d._val = std::any(om);
    ASSERT_TRUE(d._setBackingList() == nullptr);          // non-const overload
    const BallDyn& cd = d;
    ASSERT_TRUE(cd._setBackingList() == nullptr);         // const overload
}

// --- operator[](int64_t) RangeError on a BY-VALUE list (651-652) ---------
TEST(cov63_index_out_of_range_on_by_value_list) {
    // BallDyn(BallList) upgrades to a shared BallListRef, so the by-value arm
    // (the shape the self-hosted engine hands through std::any) needs _val set
    // directly. Both arms must produce the same Dart RangeError text.
    BallDyn v;
    v._val = std::any(BallList{std::any((int64_t)1), std::any((int64_t)2)});
    bool threw = false;
    try {
        (void)v[(int64_t)7];
    } catch (const BallException& e) {
        threw = true;
        const std::string msg = e.what();
        ASSERT_TRUE(msg.find("RangeError (index)") != std::string::npos);
        ASSERT_TRUE(msg.find("less than 2") != std::string::npos);
        ASSERT_TRUE(msg.find(": 7") != std::string::npos);
    }
    ASSERT_TRUE(threw);

    // The portable-SET arm below `_listPtr()` builds its own copy of the same
    // message (several runtime set-op helpers index a set by position, #174),
    // so it needs its own out-of-range case -- the list arm above dominates
    // every list-shaped receiver and never reaches it.
    BallDyn set = ball_make_set(BallList{std::any((int64_t)10),
                                         std::any((int64_t)20)});
    ASSERT_EQ((int64_t)set[(int64_t)1], (int64_t)20);
    bool set_threw = false;
    try {
        (void)set[(int64_t)5];
    } catch (const BallException& e) {
        set_threw = true;
        const std::string msg = e.what();
        ASSERT_TRUE(msg.find("RangeError (index)") != std::string::npos);
        ASSERT_TRUE(msg.find("less than 2") != std::string::npos);
        ASSERT_TRUE(msg.find(": 5") != std::string::npos);
    }
    ASSERT_TRUE(set_threw);
}

// --- hashCode fallback for a non-scalar payload (822) -------------------
TEST(cov63_hash_code_of_a_container_is_zero) {
    ASSERT_EQ(BallDyn(BallList{std::any((int64_t)1)}).hashCode(), (int64_t)0);
    ASSERT_EQ(BallDyn(BallMap{}).hashCode(), (int64_t)0);
}

// --- identity equality for a BY-VALUE BallObject (966-967) --------------
TEST(cov63_equality_by_value_object_identity) {
    // The BallObjectRef arms above dominate whenever EITHER side is a handle,
    // so this arm needs both sides stored as plain BallObject values.
    BallDyn a, b;
    a._val = std::any(BallObject(std::any(std::string("T"))));
    b._val = std::any(BallObject(std::any(std::string("T"))));
    ASSERT_TRUE(!(a == b));          // distinct objects -> distinct addresses
    ASSERT_TRUE(a == a);             // same address
    // An object never equals a non-object, from either side.
    ASSERT_TRUE(!(a == BallDyn((int64_t)1)));
    ASSERT_TRUE(!(BallDyn((int64_t)1) == a));
}

// --- equality fallback for an unmodelled same-type payload (1035) -------
TEST(cov63_equality_falls_back_to_false_for_unmodelled_payloads) {
    BallDyn a, b;
    a._val = std::any(std::vector<std::string>{"x"});
    b._val = std::any(std::vector<std::string>{"x"});
    // Same stored type, but not one BallDyn models structurally: unequal
    // rather than a throw or a bogus true.
    ASSERT_TRUE(!(a == b));
}

// --- _ball_get_parent_scope: __parent__ present but not a scope (1959) --
TEST(cov63_parent_scope_with_non_scope_parent_is_null) {
    BallScope sc = std::make_shared<BallMap>();
    (*sc)["__parent__"] = std::any((int64_t)1);   // not a BallScope
    BallDyn d{std::any(sc)};
    ASSERT_TRUE(_ball_get_parent_scope(d) == nullptr);
}

// --- free set(): walk past the FIRST parent (2162) ---------------------
TEST(cov63_scope_set_walks_past_the_first_parent) {
    BallScope grand = std::make_shared<BallMap>();
    (*grand)["g"] = std::any((int64_t)1);
    BallScope parent = std::make_shared<BallMap>();
    (*parent)["__parent__"] = std::any(grand);
    BallScope child = std::make_shared<BallMap>();
    (*child)["__parent__"] = std::any(parent);
    BallDyn scope{std::any(child)};
    // `g` lives two levels up: the loop must advance to the NEXT parent.
    set(scope, BallDyn(std::string("g")), BallDyn((int64_t)42));
    ASSERT_EQ((int64_t)BallDyn((*grand)["g"]), (int64_t)42);
    ASSERT_TRUE(parent->find("g") == parent->end());
    ASSERT_TRUE(child->find("g") == child->end());
}

// --- typed-map check delegating to object matching (2578) --------------
TEST(cov63_typed_map_first_value_is_an_object) {
    // `is Map<String, Point>` on an insertion-ordered map: a non-primitive
    // val_type falls through to ball_object_type_matches on the first value.
    BallOrderedMap point;
    point["__type__"] = std::any(std::string("main:Point"));
    BallOrderedMap m;
    m["a"] = std::any(point);
    ASSERT_TRUE(ball_is_typed_map(std::any(m), "Point"));
    ASSERT_TRUE(!ball_is_typed_map(std::any(m), "Other"));
}

// --- ball_to_list unwraps a portable set through the registered hook
//     (_BallRefDeref::_set_list_fn, 2584-2597) ---------------------------
TEST(cov63_to_list_unwraps_a_portable_set_through_the_hook) {
    // ball_to_list (ball_emit_runtime.h) cannot name BallOrderedMap, so it
    // reaches the set backing through _BallRefDeref::set_list -- the hook
    // ball_dyn.h registers. BallDyn::_setBackingList() is a DIFFERENT path and
    // does not exercise it, which is why the first pass left this at 0%.
    BallDyn set = ball_make_set(BallList{std::any((int64_t)1),
                                         std::any((int64_t)2)});
    auto items = ball_to_list(set._val);
    ASSERT_EQ(items.size(), (size_t)2);
    ASSERT_EQ((int64_t)BallDyn(items[1]), (int64_t)2);

    // The self-host backing (a BallDyn-wrapped by-value list) resolves too.
    BallOrderedMap wrapped;
    wrapped["__ball_set__"] = std::any(BallDyn(std::any(BallList{
        std::any((int64_t)7)})));
    ASSERT_EQ(ball_to_list(std::any(wrapped)).size(), (size_t)1);

    // ... and every not-a-set shape falls through to ball_to_list's own arms
    // rather than the hook: wrong entry count, missing tag, non-list payload.
    BallOrderedMap two;
    two["__ball_set__"] = std::any(BallList{std::any((int64_t)1)});
    two["x"] = std::any((int64_t)1);
    ASSERT_TRUE(ball_to_list(std::any(two)).empty());
    BallOrderedMap mistagged;
    mistagged["other"] = std::any(BallList{std::any((int64_t)1)});
    ASSERT_TRUE(ball_to_list(std::any(mistagged)).empty());
    BallOrderedMap not_a_list;
    not_a_list["__ball_set__"] = std::any((int64_t)1);
    ASSERT_TRUE(ball_to_list(std::any(not_a_list)).empty());
}

// ================================================================
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ Runtime (BallDyn) Tests\n"
              << "=================================\n";

    std::cout << "\n=================================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    // Positive floor: every case registers itself from a static initializer, so
    // a binary whose registrations were all elided (or a file that lost its
    // TEST()s in a bad merge) would print "0 passed, 0 failed" and still exit 0
    // -- a green run that proved nothing.
    if (tests_passed < 1) {
        std::cout << "FAIL: no tests ran (expected at least one)\n";
        return 1;
    }
    return tests_failed > 0 ? 1 : 0;
}
