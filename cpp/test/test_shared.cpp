// Ball C++ Shared Library Tests
//
// Covers cpp/shared/src/ball_shared.cpp — the std module descriptor
// builders (build_std_module, build_std_memory_module,
// build_std_collections_module, build_std_io_module) and the
// google.protobuf.Struct <-> BallMap conversion helpers
// (struct_to_map / value_proto_to_ball).
//
// These functions are not called anywhere else in the C++ compiler,
// encoder, or engine — they exist as the C++ counterpart of the Dart
// `ball_base` std-module builders (parity / future-use API surface).
// Added as part of the coverage sweep (issue #63) so this file's logic
// is actually exercised.

#include "ball_shared.h"

#include <iostream>
#include <sstream>
#include <string>

using namespace ball;

// ================================================================
// Test framework (same minimal TEST() macro as the other cpp/test files)
// ================================================================

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name)                                                       \
    static void test_##name();                                          \
    struct Register_##name {                                            \
        Register_##name() {                                             \
            std::cout << "  " << #name << "... ";                       \
            try {                                                       \
                test_##name();                                          \
                std::cout << "PASS\n";                                  \
                tests_passed++;                                         \
            } catch (const std::exception& e) {                        \
                std::cout << "FAIL: " << e.what() << "\n";              \
                tests_failed++;                                         \
            }                                                           \
            tests_run++;                                                \
        }                                                                \
    } register_##name;                                                  \
    static void test_##name()

#define ASSERT_TRUE(cond)                                                \
    do {                                                                 \
        if (!(cond)) {                                                   \
            throw std::runtime_error("ASSERT_TRUE failed: " #cond);      \
        }                                                                \
    } while (0)

#define ASSERT_EQ(a, b)                                                  \
    do {                                                                 \
        if (!((a) == (b))) {                                             \
            std::ostringstream oss;                                     \
            oss << "ASSERT_EQ failed: " #a " != " #b << " (got \""       \
                << (a) << "\" vs \"" << (b) << "\")";                    \
            throw std::runtime_error(oss.str());                        \
        }                                                                \
    } while (0)

// Find a function by name in a module.
static const ball::ir::FunctionDefinition* find_fn(
    const ball::ir::Module& mod, const std::string& name) {
    for (const auto& fn : mod.functions) {
        if (fn.name == name) return &fn;
    }
    return nullptr;
}

// Find a type_def by name in a module.
static const ball::ir::TypeDefinition* find_type_def(
    const ball::ir::Module& mod, const std::string& name) {
    for (const auto& td : mod.typeDefs) {
        if (td.name == name) return &td;
    }
    return nullptr;
}

// ================================================================
// build_std_module — arithmetic, control flow, string, math base fns.
// ================================================================

TEST(build_std_module_has_name_and_description) {
    auto mod = build_std_module();
    ASSERT_EQ(mod.name, std::string("std"));
    ASSERT_TRUE(!mod.description.empty());
}

TEST(build_std_module_declares_core_types) {
    auto mod = build_std_module();
    ASSERT_TRUE(find_type_def(mod, "BinaryInput") != nullptr);
    ASSERT_TRUE(find_type_def(mod, "UnaryInput") != nullptr);
    ASSERT_TRUE(find_type_def(mod, "IfInput") != nullptr);
    ASSERT_TRUE(find_type_def(mod, "ForInput") != nullptr);
    ASSERT_TRUE(find_type_def(mod, "SwitchCase") != nullptr);

    // BinaryInput must carry left/right message-typed fields.
    auto* bin = find_type_def(mod, "BinaryInput");
    const auto& fields = bin->descriptor.at("field");
    ASSERT_TRUE(fields.size() == 2);
    ASSERT_EQ(fields[0].at("name").get<std::string>(), std::string("left"));
    ASSERT_EQ(fields[1].at("name").get<std::string>(), std::string("right"));
}

TEST(build_std_module_declares_arithmetic_and_control_flow_fns) {
    auto mod = build_std_module();
    // Every base function has isBase=true and no body.
    for (const char* name : {"add", "subtract", "multiply", "divide", "modulo",
                              "if", "for", "while", "switch", "try", "return",
                              "break", "continue", "assign"}) {
        auto* fn = find_fn(mod, name);
        ASSERT_TRUE(fn != nullptr);
        ASSERT_TRUE(fn->isBase);
        ASSERT_TRUE(fn->body == nullptr);
    }
    // Reasonably large surface — a canary against silently truncating the
    // builder (it declares 90+ base functions as of this writing).
    ASSERT_TRUE(mod.functions.size() > 80);
}

TEST(build_std_module_declares_math_fns) {
    auto mod = build_std_module();
    for (const char* name : {"math_abs", "math_sqrt", "math_pow", "math_sin",
                              "math_gcd", "math_lcm", "math_clamp"}) {
        ASSERT_TRUE(find_fn(mod, name) != nullptr);
    }
}

// ================================================================
// build_std_memory_module — linear memory simulation.
// ================================================================

TEST(build_std_memory_module_has_name_and_types) {
    auto mod = build_std_memory_module();
    ASSERT_EQ(mod.name, std::string("std_memory"));
    ASSERT_TRUE(find_type_def(mod, "AllocInput") != nullptr);
    ASSERT_TRUE(find_type_def(mod, "MemReadInput") != nullptr);
    ASSERT_TRUE(find_type_def(mod, "PtrArithInput") != nullptr);
}

TEST(build_std_memory_module_declares_read_write_family) {
    auto mod = build_std_memory_module();
    for (const char* name : {"memory_alloc", "memory_free", "memory_realloc",
                              "memory_read_i8", "memory_read_u64",
                              "memory_write_f64", "memory_copy", "memory_set",
                              "ptr_add", "ptr_sub", "ptr_diff",
                              "stack_alloc", "deref", "address_of", "nullptr"}) {
        auto* fn = find_fn(mod, name);
        ASSERT_TRUE(fn != nullptr);
        ASSERT_TRUE(fn->isBase);
    }
}

// ================================================================
// build_std_collections_module — list/map operations.
// ================================================================

TEST(build_std_collections_module_declares_list_and_map_fns) {
    auto mod = build_std_collections_module();
    ASSERT_EQ(mod.name, std::string("std_collections"));
    for (const char* name : {"list_push", "list_pop", "list_map", "list_filter",
                              "list_reduce", "map_get", "map_set", "map_keys",
                              "map_values", "map_merge", "string_join"}) {
        ASSERT_TRUE(find_fn(mod, name) != nullptr);
    }
}

// ================================================================
// build_std_io_module — console/process/time/random.
// ================================================================

TEST(build_std_io_module_declares_io_fns) {
    auto mod = build_std_io_module();
    ASSERT_EQ(mod.name, std::string("std_io"));
    for (const char* name : {"print_error", "read_line", "exit", "panic",
                              "sleep_ms", "timestamp_ms", "random_int",
                              "random_double", "env_get", "args_get"}) {
        ASSERT_TRUE(find_fn(mod, name) != nullptr);
    }
}

// ================================================================
// value_proto_to_ball / struct_to_map — google.protobuf.Struct <-> BallMap.
// ================================================================

TEST(value_proto_to_ball_null_kind) {
    ball::ir::json v = nullptr;
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_null(result));
}

TEST(value_proto_to_ball_number_kind) {
    ball::ir::json v = 3.5;
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_double(result));
    ASSERT_TRUE(to_double(result) == 3.5);
}

TEST(value_proto_to_ball_string_kind) {
    ball::ir::json v = "hello";
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_string(result));
    ASSERT_EQ(to_string(result), std::string("hello"));
}

TEST(value_proto_to_ball_bool_kind) {
    ball::ir::json v = true;
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_bool(result));
    ASSERT_TRUE(to_bool(result));
}

TEST(value_proto_to_ball_list_kind) {
    ball::ir::json v = ball::ir::json::array();
    v.push_back(1);
    v.push_back("two");
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_list(result));
    ASSERT_TRUE(ball_list_length(result) == 2);
    auto elem0 = ball_list_at(result, 0);
    ASSERT_TRUE(is_double(elem0));
    auto elem1 = ball_list_at(result, 1);
    ASSERT_EQ(to_string(elem1), std::string("two"));
}

TEST(value_proto_to_ball_struct_kind_recurses) {
    ball::ir::json v = ball::ir::json::object();
    v["nested"] = "inner";
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_map(result));
    ASSERT_TRUE(ball_map_contains_key(result, "nested"));
}

TEST(struct_to_map_converts_all_fields) {
    ball::ir::json s = ball::ir::json::object();
    s["name"] = "Ball";
    s["version"] = 3;
    s["stable"] = true;

    // Qualified as ball::BallMap: cpp/shared/include/ball_emit_runtime.h
    // also declares a global-scope `BallMap`, and `using namespace ball;`
    // above makes the bare name ambiguous between the two.
    ball::BallMap map = struct_to_map(s);
    ASSERT_TRUE(map.count("name") > 0);
    ASSERT_EQ(to_string(map["name"]), std::string("Ball"));
    ASSERT_TRUE(to_double(map["version"]) == 3.0);
    ASSERT_TRUE(to_bool(map["stable"]));
}

TEST(struct_to_map_empty_struct_yields_empty_map) {
    ball::ir::json s = ball::ir::json::object();
    ball::BallMap map = struct_to_map(s);
    ASSERT_TRUE(map.empty());
}

// ================================================================
// ball_shared.h free functions — to_int/to_double/to_bool/to_num/to_string,
// is_*/unwrap/values_equal, extract_field/extract_unary/extract_binary, and
// the ball_list_*/ball_map_* helpers. These are called by CODE THE COMPILER
// EMITS (compiler.cpp writes call-sites like `ball::to_int(...)` into every
// generated .cpp), never by the compiler/encoder itself — so they sat
// completely unexercised by this instrumented build (only test_e2e, gated
// behind BALL_COV_FULL=1, actually runs emitted programs, and even then in a
// SEPARATE non-instrumented subprocess). Direct coverage closes that gap
// (issue #63).
// ================================================================

TEST(to_int_converts_every_numeric_kind) {
    ASSERT_TRUE(to_int(BallValue(int64_t{42})) == 42);
    ASSERT_TRUE(to_int(BallValue(3.9)) == 3);  // truncates, not rounds
    ASSERT_TRUE(to_int(BallValue(true)) == 1);
    ASSERT_TRUE(to_int(BallValue(false)) == 0);
    ASSERT_TRUE(to_int(BallValue(std::string("x"))) == 0);  // fallback
    BallFuture fut{BallValue(int64_t{7}), true};
    ASSERT_TRUE(to_int(BallValue(fut)) == 7);
}

TEST(to_double_converts_every_numeric_kind) {
    ASSERT_TRUE(to_double(BallValue(2.5)) == 2.5);
    ASSERT_TRUE(to_double(BallValue(int64_t{4})) == 4.0);
    BallFuture fut{BallValue(1.5), true};
    ASSERT_TRUE(to_double(BallValue(fut)) == 1.5);
    ASSERT_TRUE(to_double(BallValue(std::string("x"))) == 0.0);  // fallback
}

TEST(to_bool_truthiness_rules) {
    ASSERT_TRUE(to_bool(BallValue(true)) == true);
    ASSERT_TRUE(to_bool(BallValue(int64_t{5})) == true);
    ASSERT_TRUE(to_bool(BallValue(int64_t{0})) == false);
    ASSERT_TRUE(to_bool(BallValue(2.0)) == true);
    ASSERT_TRUE(to_bool(BallValue(0.0)) == false);
    ASSERT_TRUE(to_bool(BallValue(std::string("x"))) == true);
    ASSERT_TRUE(to_bool(BallValue(std::string(""))) == false);
    BallFuture fut{BallValue(true), true};
    ASSERT_TRUE(to_bool(BallValue(fut)) == true);
    ball::BallGenerator gen;
    gen.values->push_back(BallValue(int64_t{1}));
    ASSERT_TRUE(to_bool(BallValue(gen)) == true);
    ball::BallGenerator empty_gen;
    ASSERT_TRUE(to_bool(BallValue(empty_gen)) == false);
    ASSERT_TRUE(to_bool(BallValue{}) == false);  // no value at all
}

TEST(to_num_converts_int_double_and_future) {
    ASSERT_TRUE(to_num(BallValue(2.25)) == 2.25);
    ASSERT_TRUE(to_num(BallValue(int64_t{9})) == 9.0);
    BallFuture fut{BallValue(3.5), true};
    ASSERT_TRUE(to_num(BallValue(fut)) == 3.5);
    ASSERT_TRUE(to_num(BallValue(std::string("x"))) == 0.0);
}

TEST(is_predicates_classify_every_kind) {
    ASSERT_TRUE(is_int(BallValue(int64_t{1})));
    ASSERT_TRUE(!is_int(BallValue(1.0)));
    ASSERT_TRUE(is_double(BallValue(1.0)));
    ASSERT_TRUE(is_string(BallValue(std::string("s"))));
    ASSERT_TRUE(is_bool(BallValue(true)));
    ASSERT_TRUE(is_null(BallValue{}));
    ASSERT_TRUE(!is_null(BallValue(int64_t{0})));
    ASSERT_TRUE(is_function(BallValue(BallFunction([](BallValue v) { return v; }))));
    ASSERT_TRUE(is_future(BallValue(BallFuture{BallValue(int64_t{1}), true})));
    ASSERT_TRUE(is_generator(BallValue(ball::BallGenerator{})));
}

TEST(unwrap_extracts_future_and_generator_values) {
    BallFuture fut{BallValue(std::string("inner")), true};
    ASSERT_EQ(to_string(unwrap(BallValue(fut))), std::string("inner"));
    ball::BallGenerator gen;
    gen.values->push_back(BallValue(int64_t{1}));
    gen.values->push_back(BallValue(int64_t{2}));
    ball::BallValue unwrapped = unwrap(BallValue(gen));
    ASSERT_TRUE(is_list(unwrapped));
    ASSERT_TRUE(ball_list_length(unwrapped) == 2);
    // Non-wrapper values pass through unchanged.
    ASSERT_TRUE(to_int(unwrap(BallValue(int64_t{9}))) == 9);
}

TEST(values_equal_numeric_cross_type_and_nan) {
    ASSERT_TRUE(values_equal(BallValue{}, BallValue{}));  // null == null
    ASSERT_TRUE(!values_equal(BallValue{}, BallValue(int64_t{0})));  // null != 0
    ASSERT_TRUE(values_equal(BallValue(int64_t{3}), BallValue(int64_t{3})));
    ASSERT_TRUE(values_equal(BallValue(2.5), BallValue(2.5)));
    ASSERT_TRUE(!values_equal(BallValue(std::nan("")), BallValue(std::nan(""))));
    ASSERT_TRUE(values_equal(BallValue(int64_t{4}), BallValue(4.0)));
    ASSERT_TRUE(values_equal(BallValue(4.0), BallValue(int64_t{4})));
    ASSERT_TRUE(!values_equal(BallValue(int64_t{4}), BallValue(std::nan(""))));
    ASSERT_TRUE(!values_equal(BallValue(std::nan("")), BallValue(int64_t{4})));
    ASSERT_TRUE(values_equal(BallValue(std::string("a")), BallValue(std::string("a"))));
    ASSERT_TRUE(values_equal(BallValue(true), BallValue(true)));
    ASSERT_TRUE(!values_equal(BallValue(true), BallValue(false)));
}

TEST(values_equal_maps_lists_and_futures) {
    ball::BallMap m1 = ball_map_make({{"a", BallValue(int64_t{1})}, {"b", BallValue(int64_t{2})}});
    ball::BallMap m2 = ball_map_make({{"a", BallValue(int64_t{1})}, {"b", BallValue(int64_t{2})}});
    ASSERT_TRUE(values_equal(ball_map_value(m1), ball_map_value(m2)));
    ball::BallMap m3 = ball_map_make({{"a", BallValue(int64_t{1})}});
    ASSERT_TRUE(!values_equal(ball_map_value(m1), ball_map_value(m3)));  // size mismatch
    ball::BallMap m4 = ball_map_make({{"a", BallValue(int64_t{1})}, {"c", BallValue(int64_t{2})}});
    ASSERT_TRUE(!values_equal(ball_map_value(m1), ball_map_value(m4)));  // missing key

    BallList l1{BallValue(int64_t{1}), BallValue(int64_t{2})};
    BallList l2{BallValue(int64_t{1}), BallValue(int64_t{2})};
    ASSERT_TRUE(values_equal(ball_list_value(l1), ball_list_value(l2)));
    BallList l3{BallValue(int64_t{1})};
    ASSERT_TRUE(!values_equal(ball_list_value(l1), ball_list_value(l3)));
    BallList l4{BallValue(int64_t{1}), BallValue(int64_t{9})};
    ASSERT_TRUE(!values_equal(ball_list_value(l1), ball_list_value(l4)));

    BallFuture fa{BallValue(int64_t{5}), true};
    BallFuture fb{BallValue(int64_t{5}), true};
    ASSERT_TRUE(values_equal(BallValue(fa), BallValue(fb)));
    ASSERT_TRUE(values_equal(BallValue(fa), BallValue(int64_t{5})));
    ASSERT_TRUE(values_equal(BallValue(int64_t{5}), BallValue(fb)));

    // No clause matches -> falls through to the final `return false`.
    ASSERT_TRUE(!values_equal(BallValue(std::string("x")), BallValue(int64_t{1})));
}

TEST(extract_field_reads_map_and_unwraps_future_input) {
    ball::BallMap m = ball_map_make({{"left", BallValue(int64_t{10})}, {"right", BallValue(int64_t{20})}});
    BallValue mapVal = ball_map_value(m);
    ASSERT_TRUE(to_int(extract_field(mapVal, "left")) == 10);
    ASSERT_TRUE(is_null(extract_field(mapVal, "missing")));
    ASSERT_TRUE(is_null(extract_field(BallValue(int64_t{1}), "left")));  // not a map

    BallFuture fut{mapVal, true};
    ASSERT_TRUE(to_int(extract_field(BallValue(fut), "right")) == 20);

    ball::BallMap unary = ball_map_make({{"value", BallValue(std::string("v"))}});
    ASSERT_EQ(to_string(extract_unary(ball_map_value(unary))), std::string("v"));

    auto [l, r] = extract_binary(mapVal);
    ASSERT_TRUE(to_int(l) == 10);
    ASSERT_TRUE(to_int(r) == 20);
}

TEST(ball_list_helpers_handle_ref_and_value_forms) {
    BallList list{BallValue(int64_t{1}), BallValue(std::string("two"))};
    BallValue listVal = ball_list_value(list);  // BallListRef form
    ASSERT_TRUE(is_list(listVal));
    ASSERT_TRUE(ball_list_length(listVal) == 2);
    ASSERT_TRUE(to_int(ball_list_at(listVal, 0)) == 1);
    ASSERT_EQ(to_string(ball_list_at(listVal, 1)), std::string("two"));
    ASSERT_TRUE(is_null(ball_list_at(listVal, 5)));  // out of range
    ASSERT_TRUE(is_null(ball_list_at(listVal, -1)));  // negative

    BallValue plainListVal = BallValue(list);  // bare BallList form (not ref)
    ASSERT_TRUE(is_list(plainListVal));
    BallList copy = ball_list_copy(plainListVal);
    ASSERT_TRUE(copy.size() == 2);

    ASSERT_TRUE(ball_list_length(BallValue(int64_t{1})) == 0);  // not a list
    ASSERT_TRUE(ball_list_copy(BallValue(int64_t{1})).empty());
    ASSERT_TRUE(!is_list(BallValue(int64_t{1})));
}

TEST(ball_map_helpers_handle_ref_and_value_forms) {
    ball::BallMap map = ball_map_make({{"k", BallValue(int64_t{7})}});
    BallValue mapRefVal = ball_map_value(map);  // BallOrderedMapRef form
    ASSERT_TRUE(is_map(mapRefVal));
    ASSERT_TRUE(ball_map_length(mapRefVal) == 1);
    ASSERT_TRUE(ball_map_contains_key(mapRefVal, "k"));
    ASSERT_TRUE(!ball_map_contains_key(mapRefVal, "missing"));

    BallValue plainMapVal = BallValue(map);  // bare BallMap form (not ref)
    ASSERT_TRUE(is_map(plainMapVal));
    ball::BallMap copy = ball_map_copy(plainMapVal);
    ASSERT_TRUE(copy.count("k") > 0);

    ASSERT_TRUE(ball_map_length(BallValue(int64_t{1})) == 0);  // not a map
    ASSERT_TRUE(ball_map_copy(BallValue(int64_t{1})).empty());
    ASSERT_TRUE(!ball_map_contains_key(BallValue(int64_t{1}), "k"));
}

TEST(to_string_renders_every_value_kind) {
    ASSERT_EQ(to_string(BallValue(std::string("s"))), std::string("s"));
    ASSERT_EQ(to_string(BallValue(int64_t{5})), std::string("5"));
    ASSERT_EQ(to_string(BallValue{}), std::string("null"));
    BallFuture fut{BallValue(std::string("f")), true};
    ASSERT_EQ(to_string(BallValue(fut)), std::string("f"));

    ball::BallGenerator gen;
    gen.values->push_back(BallValue(int64_t{1}));
    gen.values->push_back(BallValue(int64_t{2}));
    ASSERT_EQ(to_string(BallValue(gen)), std::string("[1, 2]"));

    BallList list{BallValue(int64_t{1}), BallValue(std::string("a"))};
    ASSERT_EQ(to_string(ball_list_value(list)), std::string("[1, a]"));

    ball::BallMap map = ball_map_make({{"a", BallValue(int64_t{1})}});
    // Internal keys (leading "__" or "type_args") are hidden from rendering.
    map["__hidden"] = BallValue(int64_t{99});
    map["type_args"] = BallValue(std::string("T"));
    ASSERT_EQ(to_string(ball_map_value(map)), std::string("{a: 1}"));

    ASSERT_EQ(double_to_dart_string(1.5), ball_to_string(1.5));
}

// ================================================================
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ Shared Library Tests\n"
              << "==============================\n";

    std::cout << "\n==============================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    return tests_failed > 0 ? 1 : 0;
}
