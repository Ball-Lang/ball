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
static const ball::v1::FunctionDefinition* find_fn(
    const ball::v1::Module& mod, const std::string& name) {
    for (int i = 0; i < mod.functions_size(); i++) {
        if (mod.functions(i).name() == name) return &mod.functions(i);
    }
    return nullptr;
}

// Find a type_def by name in a module.
static const ball::v1::TypeDefinition* find_type_def(
    const ball::v1::Module& mod, const std::string& name) {
    for (int i = 0; i < mod.type_defs_size(); i++) {
        if (mod.type_defs(i).name() == name) return &mod.type_defs(i);
    }
    return nullptr;
}

// ================================================================
// build_std_module — arithmetic, control flow, string, math base fns.
// ================================================================

TEST(build_std_module_has_name_and_description) {
    auto mod = build_std_module();
    ASSERT_EQ(mod.name(), std::string("std"));
    ASSERT_TRUE(!mod.description().empty());
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
    ASSERT_TRUE(bin->descriptor_().field_size() == 2);
    ASSERT_EQ(bin->descriptor_().field(0).name(), std::string("left"));
    ASSERT_EQ(bin->descriptor_().field(1).name(), std::string("right"));
}

TEST(build_std_module_declares_arithmetic_and_control_flow_fns) {
    auto mod = build_std_module();
    // Every base function has isBase=true and no body.
    for (const char* name : {"add", "subtract", "multiply", "divide", "modulo",
                              "if", "for", "while", "switch", "try", "return",
                              "break", "continue", "assign"}) {
        auto* fn = find_fn(mod, name);
        ASSERT_TRUE(fn != nullptr);
        ASSERT_TRUE(fn->is_base());
        ASSERT_TRUE(!fn->has_body());
    }
    // Reasonably large surface — a canary against silently truncating the
    // builder (it declares 90+ base functions as of this writing).
    ASSERT_TRUE(mod.functions_size() > 80);
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
    ASSERT_EQ(mod.name(), std::string("std_memory"));
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
        ASSERT_TRUE(fn->is_base());
    }
}

// ================================================================
// build_std_collections_module — list/map operations.
// ================================================================

TEST(build_std_collections_module_declares_list_and_map_fns) {
    auto mod = build_std_collections_module();
    ASSERT_EQ(mod.name(), std::string("std_collections"));
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
    ASSERT_EQ(mod.name(), std::string("std_io"));
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
    google::protobuf::Value v;
    v.set_null_value(google::protobuf::NULL_VALUE);
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_null(result));
}

TEST(value_proto_to_ball_number_kind) {
    google::protobuf::Value v;
    v.set_number_value(3.5);
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_double(result));
    ASSERT_TRUE(to_double(result) == 3.5);
}

TEST(value_proto_to_ball_string_kind) {
    google::protobuf::Value v;
    v.set_string_value("hello");
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_string(result));
    ASSERT_EQ(to_string(result), std::string("hello"));
}

TEST(value_proto_to_ball_bool_kind) {
    google::protobuf::Value v;
    v.set_bool_value(true);
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_bool(result));
    ASSERT_TRUE(to_bool(result));
}

TEST(value_proto_to_ball_list_kind) {
    google::protobuf::Value v;
    auto* list = v.mutable_list_value();
    list->add_values()->set_number_value(1);
    list->add_values()->set_string_value("two");
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_list(result));
    ASSERT_TRUE(ball_list_length(result) == 2);
    auto elem0 = ball_list_at(result, 0);
    ASSERT_TRUE(is_double(elem0));
    auto elem1 = ball_list_at(result, 1);
    ASSERT_EQ(to_string(elem1), std::string("two"));
}

TEST(value_proto_to_ball_struct_kind_recurses) {
    google::protobuf::Value v;
    auto* s = v.mutable_struct_value();
    (*s->mutable_fields())["nested"].set_string_value("inner");
    auto result = value_proto_to_ball(v);
    ASSERT_TRUE(is_map(result));
    ASSERT_TRUE(ball_map_contains_key(result, "nested"));
}

TEST(struct_to_map_converts_all_fields) {
    google::protobuf::Struct s;
    (*s.mutable_fields())["name"].set_string_value("Ball");
    (*s.mutable_fields())["version"].set_number_value(3);
    (*s.mutable_fields())["stable"].set_bool_value(true);

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
    google::protobuf::Struct s;
    ball::BallMap map = struct_to_map(s);
    ASSERT_TRUE(map.empty());
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
