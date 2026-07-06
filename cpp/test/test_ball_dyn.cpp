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
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ Runtime (BallDyn) Tests\n"
              << "=================================\n";

    std::cout << "\n=================================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    return tests_failed > 0 ? 1 : 0;
}
