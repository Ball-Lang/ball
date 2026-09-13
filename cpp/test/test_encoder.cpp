// Ball C++ Encoder Tests
//
// Exercises ball::CppEncoder::encode_from_clang_ast through three
// layers of fixtures:
//
//   1. Hand-crafted minimal ASTs — each covers one encoder
//      responsibility (literal kinds, binary ops, if/for/while, etc.).
//      Fast to write, targeted, easy to debug.
//
//   2. Clang-shaped ASTs — hand-crafted but include the
//      ImplicitCastExpr / ParenExpr / CXXConstructExpr wrappers that
//      real clang output contains. Exercises the encoder's unwrap
//      paths without requiring clang on PATH.
//
//   3. Real clang output under tests/fixtures/cpp_ast/ast/*.ast.json —
//      produced once by `clang -Xclang -ast-dump=json -fsyntax-only`
//      and committed so tests run without needing the clang toolchain.
//      Catches the irregular wrapper patterns real clang produces that
//      we can't anticipate in hand-crafted fixtures.
//
// Regenerate the real clang fixtures with:
//   cd tests/fixtures/cpp_ast
//   for f in src/*.cpp; do
//     name=$(basename "$f" .cpp)
//     clang -Xclang -ast-dump=json -fsyntax-only "$f" > "ast/$name.ast.json"
//   done
//
// #18: the encoder now returns the protobuf-free `ball::ir` plain-struct IR
// (cpp/shared/include/ball_ir.h). Assertions read the plain structs and the
// opaque `nlohmann::json` metadata/descriptor payloads; body-shape checks use
// `ball::ir::toJson(expr).dump()` (compact proto3-JSON) in place of the old
// protobuf `DebugString()` text-format.

#include "encoder.h"
#include "ball_ir.h"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#ifndef BALL_CLANG_AST_DIR
#define BALL_CLANG_AST_DIR ""
#endif

using namespace ball;
namespace bir = ball::ir;

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name)                                                        \
    static void test_##name();                                            \
    struct Register_##name {                                              \
        Register_##name() {                                               \
            std::cout << "  " << #name << "... ";                         \
            try {                                                         \
                test_##name();                                            \
                std::cout << "PASS\n";                                    \
                tests_passed++;                                           \
            } catch (const std::exception& e) {                           \
                std::cout << "FAIL: " << e.what() << "\n";                \
                tests_failed++;                                           \
            }                                                             \
            tests_run++;                                                  \
        }                                                                 \
    } register_##name;                                                    \
    static void test_##name()

#define ASSERT_EQ(a, b)                                                   \
    do {                                                                  \
        if (!((a) == (b))) {                                              \
            std::ostringstream oss;                                       \
            oss << "ASSERT_EQ failed: " #a " != " #b << " (got "          \
                << (a) << " vs " << (b) << ")";                           \
            throw std::runtime_error(oss.str());                          \
        }                                                                 \
    } while (0)

#define ASSERT_TRUE(cond)                                                 \
    do {                                                                  \
        if (!(cond)) {                                                    \
            throw std::runtime_error("ASSERT_TRUE failed: " #cond);       \
        }                                                                 \
    } while (0)

static bir::Program run_encoder(const std::string& json) {
    CppEncoder encoder;
    return encoder.encode_from_clang_ast(json);
}

// Find the "main" user module in the encoded program.
static const bir::Module* find_main(const bir::Program& p) {
    for (const auto& m : p.modules) {
        if (m.name == "main") return &m;
    }
    return nullptr;
}

// Find a function by name in the main module.
static const bir::FunctionDefinition* find_fn(
    const bir::Program& p, const std::string& name) {
    auto* m = find_main(p);
    if (!m) return nullptr;
    for (const auto& f : m->functions) {
        if (f.name == name) return &f;
    }
    return nullptr;
}

// Find a type_def by name in the main module (classes/structs/scoped enums).
static const bir::TypeDefinition* find_type_def(
    const bir::Program& p, const std::string& name) {
    auto* m = find_main(p);
    if (!m) return nullptr;
    for (const auto& t : m->typeDefs) {
        if (t.name == name) return &t;
    }
    return nullptr;
}

// Find an enum (opaque EnumDescriptorProto JSON) by name in the main module.
static const nlohmann::json* find_enum(
    const bir::Program& p, const std::string& name) {
    auto* m = find_main(p);
    if (!m || !m->enums.is_array()) return nullptr;
    for (const auto& e : m->enums) {
        if (e.is_object() && e.value("name", std::string{}) == name) return &e;
    }
    return nullptr;
}

// Number of fields on a type_def's DescriptorProto (proto3-JSON `field`).
static size_t descriptor_field_count(const bir::TypeDefinition* td) {
    if (!td || !td->descriptor.is_object()) return 0;
    auto it = td->descriptor.find("field");
    return (it != td->descriptor.end() && it->is_array()) ? it->size() : 0;
}

// Serialize a function body to compact proto3-JSON for substring checks —
// the ball::ir equivalent of the old protobuf `DebugString()`. Field/function
// names appear as `"function":"add"`, `"module":"std"`, etc.
static std::string body_json(const bir::FunctionDefinition* fn) {
    if (!fn || !fn->body) return "";
    return bir::toJson(*fn->body).dump();
}

// Wrap a single expression node (as raw JSON text) in `int f() { return
// <expr>; }` and encode it. Reduces boilerplate for expression-level tests.
static bir::Program encode_return_expr(const std::string& expr_json) {
    std::string json = std::string(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [)JSON") + expr_json + R"JSON(]
            }]}]
        }]
    })JSON";
    return run_encoder(json);
}

// Wrap a single statement node (as raw JSON text) as the sole body statement
// of `void f() { <stmt> }` and encode it.
static bir::Program encode_stmt(const std::string& stmt_json) {
    std::string json = std::string(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "void ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [)JSON") + stmt_json + R"JSON(]}]
        }]
    })JSON";
    return run_encoder(json);
}

// ================================================================
// Smoke: the encoder always emits the std + std_memory + main
// modules, plus source_language metadata. No cpp_std module.
// ================================================================

TEST(empty_translation_unit) {
    auto prog = run_encoder(R"JSON({"kind": "TranslationUnitDecl", "inner": []})JSON");
    ASSERT_EQ(prog.entryModule, std::string("main"));
    ASSERT_EQ(prog.entryFunction, std::string("main"));
    // std, std_memory, main = 3 modules minimum.
    ASSERT_TRUE(prog.modules.size() >= 3);
    bool has_main = false, has_std = false, has_cpp_std = false;
    for (const auto& m : prog.modules) {
        if (m.name == "main") has_main = true;
        if (m.name == "std") has_std = true;
        if (m.name == "cpp_std") has_cpp_std = true;
    }
    ASSERT_TRUE(has_main);
    ASSERT_TRUE(has_std);
    ASSERT_TRUE(!has_cpp_std);  // cpp_std module eliminated
    // source_language metadata must be "cpp".
    ASSERT_TRUE(prog.metadata.is_object());
    ASSERT_TRUE(prog.metadata.contains("source_language"));
    ASSERT_EQ(prog.metadata.at("source_language").get<std::string>(),
              std::string("cpp"));
}

// ================================================================
// FunctionDecl with a single return statement.
// ================================================================

TEST(encode_function_with_return_literal) {
    // int answer() { return 42; }
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "answer",
            "type": {"qualType": "int ()"},
            "inner": [{
                "kind": "CompoundStmt",
                "inner": [{
                    "kind": "ReturnStmt",
                    "inner": [{
                        "kind": "IntegerLiteral",
                        "value": "42",
                        "type": {"qualType": "int"}
                    }]
                }]
            }]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "answer");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(fn->body != nullptr);
}

// ================================================================
// Literals — the five basic kinds encode_expression knows about.
// ================================================================

TEST(encode_integer_literal) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{"kind": "IntegerLiteral", "value": "7"}]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    // Walk: body (block) → first statement is a return call.
    ASSERT_TRUE(fn->body != nullptr);
    ASSERT_TRUE(fn->body->kind == bir::ExprKind::Block);
    ASSERT_TRUE(fn->body->block->statements.size() >= 1);
}

TEST(encode_bool_literal) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "bool ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{"kind": "CXXBoolLiteralExpr", "value": true}]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "f") != nullptr);
}

TEST(encode_string_literal) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "const char* ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{"kind": "StringLiteral", "value": "hi"}]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "f") != nullptr);
}

// ================================================================
// Binary operators map to std base functions via binary_op_to_std.
// We encode a function returning `1 + 2` and confirm the emitted
// body tree contains a call to std.add.
// ================================================================

TEST(encode_binary_add_is_std_add) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "sum",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "BinaryOperator",
                    "opcode": "+",
                    "inner": [
                        {"kind": "IntegerLiteral", "value": "1"},
                        {"kind": "IntegerLiteral", "value": "2"}
                    ]
                }]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "sum");
    ASSERT_TRUE(fn != nullptr);
    // The body's first statement is a ReturnStmt call whose value is a
    // binary op expression. Serialize to JSON and look for the std.add call.
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("add") != std::string::npos);
    ASSERT_TRUE(body_str.find("\"module\":\"std\"") != std::string::npos);
}

// ================================================================
// Comparison operators all use binary_op_to_std.
// ================================================================

TEST(encode_binary_equals_is_std_equals) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "cmp",
            "type": {"qualType": "bool ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "BinaryOperator",
                    "opcode": "==",
                    "inner": [
                        {"kind": "IntegerLiteral", "value": "3"},
                        {"kind": "IntegerLiteral", "value": "3"}
                    ]
                }]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "cmp");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("equals") != std::string::npos);
}

// ================================================================
// Unary operators — negation, logical not, increment.
// ================================================================

TEST(encode_unary_negate) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "neg",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "UnaryOperator",
                    "opcode": "-",
                    "inner": [{"kind": "IntegerLiteral", "value": "5"}]
                }]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "neg");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("negate") != std::string::npos);
}

TEST(encode_unary_logical_not) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "flip",
            "type": {"qualType": "bool ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "UnaryOperator",
                    "opcode": "!",
                    "inner": [{"kind": "CXXBoolLiteralExpr", "value": true}]
                }]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto body_str = body_json(find_fn(prog, "flip"));
    ASSERT_TRUE(body_str.find("\"not\"") != std::string::npos);
}

// ================================================================
// If statement → std.if call
// ================================================================

TEST(encode_if_statement) {
    // if (true) { return 1; }
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "IfStmt",
                "inner": [
                    {"kind": "CXXBoolLiteralExpr", "value": true},
                    {"kind": "CompoundStmt", "inner": [{
                        "kind": "ReturnStmt",
                        "inner": [{"kind": "IntegerLiteral", "value": "1"}]
                    }]}
                ]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("\"if\"") != std::string::npos);
}

// ================================================================
// While loop → std.while call
// ================================================================

TEST(encode_while_statement) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "void ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "WhileStmt",
                "inner": [
                    {"kind": "CXXBoolLiteralExpr", "value": false},
                    {"kind": "CompoundStmt", "inner": []}
                ]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("\"while\"") != std::string::npos);
}

// ================================================================
// Overload resolution: two functions with the same name and
// different param types get mangled suffixes.
// ================================================================

TEST(overloaded_functions_get_mangled_names) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [
            {
                "kind": "FunctionDecl",
                "name": "add",
                "type": {"qualType": "int (int, int)"},
                "inner": [
                    {"kind": "ParmVarDecl", "name": "a", "type": {"qualType": "int"}},
                    {"kind": "ParmVarDecl", "name": "b", "type": {"qualType": "int"}},
                    {"kind": "CompoundStmt", "inner": []}
                ]
            },
            {
                "kind": "FunctionDecl",
                "name": "add",
                "type": {"qualType": "double (double, double)"},
                "inner": [
                    {"kind": "ParmVarDecl", "name": "a", "type": {"qualType": "double"}},
                    {"kind": "ParmVarDecl", "name": "b", "type": {"qualType": "double"}},
                    {"kind": "CompoundStmt", "inner": []}
                ]
            }
        ]
    })JSON";
    auto prog = run_encoder(json);
    auto* m = find_main(prog);
    ASSERT_TRUE(m != nullptr);
    // Collect function names and assert at least one has a `$`-mangled
    // suffix (the encoder mangles the second overload).
    bool has_mangled = false;
    int add_count = 0;
    for (const auto& f : m->functions) {
        if (f.name == "add") add_count++;
        if (f.name.find("add$") == 0) has_mangled = true;
    }
    ASSERT_TRUE(has_mangled);
}

// ================================================================
// Malformed input: missing required fields should not crash;
// the encoder should return a program with at least the base modules.
// ================================================================

TEST(malformed_function_missing_body_graceful) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "stub",
            "type": {"qualType": "void ()"}
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "stub") != nullptr);
}

TEST(recursion_depth_guard_survives_deeply_nested_ast) {
    // Build a nest of 600 ParenExpr-like wrappers. The encoder's kMaxEncodeDepth
    // is 512; beyond that it returns null_expr() instead of recursing.
    std::string inner = R"JSON({"kind": "IntegerLiteral", "value": "1"})JSON";
    for (int i = 0; i < 600; i++) {
        inner = "{\"kind\": \"ParenExpr\", \"inner\": [" + inner + "]}";
    }
    std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "deep",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [)JSON" + inner + R"JSON(]
            }]}]
        }]
    })JSON";
    // Must not crash or throw.
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "deep") != nullptr);
}

// ================================================================
// Round-trip tests: AST → encoder → Program → engine → value
//
// These wire the encoder to the engine so a minimal hand-crafted AST
// can be validated end-to-end, not just structurally. Any divergence
// between what the encoder produces and what the engine can interpret
// surfaces immediately.
// ================================================================

// ================================================================
// Clang-shaped AST fixtures
//
// Real clang output wraps almost every expression in at least one
// ImplicitCastExpr (LValueToRValue, IntegralCast, etc.) and inserts
// extra qualType/type metadata. The encoder's hand-crafted tests above
// use clean minimal ASTs; these fixtures mimic what clang actually
// emits for common patterns, so encoder paths that strip away
// ImplicitCastExpr wrappers get exercised.
// ================================================================

TEST(clang_shape_implicit_cast_wraps_decl_ref) {
    // Mirrors `int f(int x) { return x; }` — clang wraps the x ref
    // inside ReturnStmt in an LValueToRValue ImplicitCastExpr.
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "f",
            "type": {"qualType": "int (int)"},
            "inner": [
                {"kind": "ParmVarDecl", "name": "x", "type": {"qualType": "int"}},
                {"kind": "CompoundStmt", "inner": [{
                    "kind": "ReturnStmt",
                    "inner": [{
                        "kind": "ImplicitCastExpr",
                        "castKind": "LValueToRValue",
                        "type": {"qualType": "int"},
                        "inner": [{
                            "kind": "DeclRefExpr",
                            "referencedDecl": {"kind": "ParmVarDecl", "name": "x"},
                            "type": {"qualType": "int"}
                        }]
                    }]
                }]}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "f") != nullptr);
}

TEST(clang_shape_nested_implicit_casts_around_binary_op) {
    // Mirrors `int g() { return 1 + 2; }` with clang's typical wrapping:
    // each IntegerLiteral wrapped in an IntegralCast (even when redundant).
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "g",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "ImplicitCastExpr",
                    "castKind": "IntegralCast",
                    "inner": [{
                        "kind": "BinaryOperator",
                        "opcode": "+",
                        "inner": [
                            {"kind": "ImplicitCastExpr", "castKind": "IntegralCast",
                             "inner": [{"kind": "IntegerLiteral", "value": "1"}]},
                            {"kind": "ImplicitCastExpr", "castKind": "IntegralCast",
                             "inner": [{"kind": "IntegerLiteral", "value": "2"}]}
                        ]
                    }]
                }]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "g");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    // The encoder should strip the casts and produce a std.add call.
    ASSERT_TRUE(body_str.find("add") != std::string::npos);
}

TEST(clang_shape_paren_expr_unwrapped) {
    // Mirrors `int h() { return (1 + 2); }` — clang wraps parenthesized
    // expressions in a ParenExpr node that should be transparent.
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "h",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "ParenExpr",
                    "inner": [{
                        "kind": "BinaryOperator",
                        "opcode": "+",
                        "inner": [
                            {"kind": "IntegerLiteral", "value": "10"},
                            {"kind": "IntegerLiteral", "value": "20"}
                        ]
                    }]
                }]
            }]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "h") != nullptr);
}

TEST(clang_shape_compound_assign_via_mutable_lvalue) {
    // Mirrors `int i() { int x = 0; x += 5; return x; }` with the
    // ImplicitCastExpr shapes clang produces for compound assigns.
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "i",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [
                {
                    "kind": "DeclStmt",
                    "inner": [{
                        "kind": "VarDecl",
                        "name": "x",
                        "type": {"qualType": "int"},
                        "init": "c",
                        "inner": [{"kind": "IntegerLiteral", "value": "0"}]
                    }]
                },
                {
                    "kind": "CompoundAssignOperator",
                    "opcode": "+=",
                    "inner": [
                        {"kind": "DeclRefExpr",
                         "referencedDecl": {"kind": "VarDecl", "name": "x"}},
                        {"kind": "IntegerLiteral", "value": "5"}
                    ]
                },
                {
                    "kind": "ReturnStmt",
                    "inner": [{
                        "kind": "ImplicitCastExpr",
                        "castKind": "LValueToRValue",
                        "inner": [{"kind": "DeclRefExpr",
                                    "referencedDecl": {"kind": "VarDecl", "name": "x"}}]
                    }]
                }
            ]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "i") != nullptr);
}

TEST(clang_shape_if_stmt_with_condition_casts) {
    // Mirrors `int j() { if (1 > 0) return 1; return 0; }` with the
    // typical ImplicitCastExpr on the condition (IntegralToBoolean).
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "j",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [
                {
                    "kind": "IfStmt",
                    "inner": [
                        {
                            "kind": "BinaryOperator",
                            "opcode": ">",
                            "inner": [
                                {"kind": "IntegerLiteral", "value": "1"},
                                {"kind": "IntegerLiteral", "value": "0"}
                            ]
                        },
                        {"kind": "CompoundStmt", "inner": [{
                            "kind": "ReturnStmt",
                            "inner": [{"kind": "IntegerLiteral", "value": "1"}]
                        }]}
                    ]
                },
                {
                    "kind": "ReturnStmt",
                    "inner": [{"kind": "IntegerLiteral", "value": "0"}]
                }
            ]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "j");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("\"if\"") != std::string::npos);
}

TEST(clang_shape_while_stmt_with_bool_cast) {
    // Mirrors `void k() { int x = 0; while (x < 3) ++x; }` including
    // the CompoundStmt + LValueToRValue casts.
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "k",
            "type": {"qualType": "void ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [
                {
                    "kind": "DeclStmt",
                    "inner": [{
                        "kind": "VarDecl",
                        "name": "x",
                        "type": {"qualType": "int"},
                        "init": "c",
                        "inner": [{"kind": "IntegerLiteral", "value": "0"}]
                    }]
                },
                {
                    "kind": "WhileStmt",
                    "inner": [
                        {
                            "kind": "BinaryOperator",
                            "opcode": "<",
                            "inner": [
                                {"kind": "ImplicitCastExpr", "castKind": "LValueToRValue",
                                 "inner": [{"kind": "DeclRefExpr",
                                            "referencedDecl": {"kind": "VarDecl", "name": "x"}}]},
                                {"kind": "IntegerLiteral", "value": "3"}
                            ]
                        },
                        {"kind": "CompoundStmt", "inner": [{
                            "kind": "UnaryOperator",
                            "opcode": "++",
                            "isPostfix": false,
                            "inner": [{"kind": "DeclRefExpr",
                                        "referencedDecl": {"kind": "VarDecl", "name": "x"}}]
                        }]}
                    ]
                }
            ]}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "k");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("\"while\"") != std::string::npos);
}

TEST(clang_shape_cxx_construct_expr_default_ctor) {
    // Mirrors `std::string m() { return std::string(); }` — clang
    // emits a CXXConstructExpr for the temporary. The encoder should
    // treat it as a messageCreation or a standard construction call.
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "m",
            "type": {"qualType": "std::string ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "CXXConstructExpr",
                    "type": {"qualType": "std::string"},
                    "ctorType": {"qualType": "void ()"},
                    "inner": []
                }]
            }]}]
        }]
    })JSON";
    // Just verify it doesn't crash — the encoder treats CXXConstructExpr
    // permissively and falls back to null_expr() when the shape is
    // unfamiliar.
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "m") != nullptr);
}

TEST(clang_shape_nested_function_bodies) {
    // Two functions where the second calls the first. Mirrors clang's
    // DeclRefExpr referencing a previous FunctionDecl via a full
    // referencedDecl sub-object.
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [
            {
                "kind": "FunctionDecl",
                "name": "square",
                "type": {"qualType": "int (int)"},
                "inner": [
                    {"kind": "ParmVarDecl", "name": "n", "type": {"qualType": "int"}},
                    {"kind": "CompoundStmt", "inner": [{
                        "kind": "ReturnStmt",
                        "inner": [{
                            "kind": "BinaryOperator",
                            "opcode": "*",
                            "inner": [
                                {"kind": "ImplicitCastExpr", "castKind": "LValueToRValue",
                                 "inner": [{"kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "n"}}]},
                                {"kind": "ImplicitCastExpr", "castKind": "LValueToRValue",
                                 "inner": [{"kind": "DeclRefExpr",
                                            "referencedDecl": {"name": "n"}}]}
                            ]
                        }]
                    }]}
                ]
            },
            {
                "kind": "FunctionDecl",
                "name": "caller",
                "type": {"qualType": "int ()"},
                "inner": [{"kind": "CompoundStmt", "inner": [{
                    "kind": "ReturnStmt",
                    "inner": [{
                        "kind": "CallExpr",
                        "inner": [
                            {"kind": "ImplicitCastExpr", "castKind": "FunctionToPointerDecay",
                             "inner": [{"kind": "DeclRefExpr",
                                         "referencedDecl": {"name": "square"}}]},
                            {"kind": "IntegerLiteral", "value": "5"}
                        ]
                    }]
                }]}]
            }
        ]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "square") != nullptr);
    ASSERT_TRUE(find_fn(prog, "caller") != nullptr);
}

// ================================================================
// Real clang fixtures — loaded from tests/fixtures/cpp_ast/ast/*.ast.json.
// Each test checks that encoding the full clang output doesn't crash,
// produces a `main` function in the emitted program, and that the
// engine can execute it without throwing. The directory path is baked
// in via BALL_CLANG_AST_DIR at compile time.
// ================================================================

static std::string read_ast_file(const std::string& name) {
    std::string path = std::string(BALL_CLANG_AST_DIR) + "/" + name + ".ast.json";
    std::ifstream f(path, std::ios::binary);
    if (!f) return "";
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

#define CLANG_FIXTURE(name)                                               \
    TEST(clang_fixture_##name) {                                          \
        auto json = read_ast_file(#name);                                 \
        if (json.empty()) {                                               \
            std::cout << "SKIP (ast file missing)... ";                   \
            return;                                                       \
        }                                                                 \
        CppEncoder encoder;                                               \
        auto prog = encoder.encode_from_clang_ast(json);                  \
        ASSERT_TRUE(find_fn(prog, "main") != nullptr);                    \
    }

CLANG_FIXTURE(01_hello)
CLANG_FIXTURE(02_arithmetic)
CLANG_FIXTURE(03_if_else)
CLANG_FIXTURE(04_while)
CLANG_FIXTURE(05_recursion)

// ================================================================
// Classes, structs, enums, aliases, namespaces, templates —
// coverage wave 3 (issue #63).
// ================================================================

TEST(encode_class_decl_with_field_and_method) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "CXXRecordDecl",
            "name": "Point",
            "tagUsed": "class",
            "inner": [
                {"kind": "FieldDecl", "name": "x", "type": {"qualType": "int"}},
                {"kind": "CXXMethodDecl", "name": "getX",
                 "type": {"qualType": "int ()"},
                 "inner": [{"kind": "CompoundStmt", "inner": [{
                     "kind": "ReturnStmt",
                     "inner": [{"kind": "IntegerLiteral", "value": "0"}]
                 }]}]}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* td = find_type_def(prog, "Point");
    ASSERT_TRUE(td != nullptr);
    ASSERT_TRUE(descriptor_field_count(td) == 1);
    ASSERT_EQ(td->descriptor.at("field").at(0).at("name").get<std::string>(),
              std::string("x"));
    ASSERT_TRUE(find_fn(prog, "Point.getX") != nullptr);
}

TEST(encode_struct_decl_sets_struct_kind) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "CXXRecordDecl",
            "name": "Pair",
            "tagUsed": "struct",
            "inner": []
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* td = find_type_def(prog, "Pair");
    ASSERT_TRUE(td != nullptr);
    ASSERT_EQ(td->metadata.at("kind").get<std::string>(), std::string("struct"));
}

TEST(encode_class_decl_with_base_classes) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "CXXRecordDecl",
            "name": "Derived",
            "tagUsed": "class",
            "inner": [
                {"kind": "CXXBaseSpecifier", "type": {"qualType": "Base"}},
                {"kind": "CXXBaseSpecifier", "type": {"qualType": "Mixin"}}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* td = find_type_def(prog, "Derived");
    ASSERT_TRUE(td != nullptr);
    ASSERT_EQ(td->metadata.at("superclass").get<std::string>(), std::string("Base"));
    ASSERT_TRUE(td->metadata.at("interfaces").size() == 1);
}

TEST(encode_constructor_and_destructor) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "CXXRecordDecl",
            "name": "Widget",
            "tagUsed": "class",
            "inner": [
                {"kind": "CXXConstructorDecl", "inner": [{"kind": "CompoundStmt", "inner": []}]},
                {"kind": "CXXDestructorDecl", "inner": [{"kind": "CompoundStmt", "inner": []}]}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "Widget.new") != nullptr);
    ASSERT_TRUE(find_fn(prog, "Widget.~Widget") != nullptr);
}

TEST(encode_conversion_operator_decl) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "CXXRecordDecl",
            "name": "NumBox",
            "tagUsed": "class",
            "inner": [
                {"kind": "CXXConversionDecl", "name": "operator int",
                 "type": {"qualType": "int ()"},
                 "inner": [{"kind": "CompoundStmt", "inner": [{
                     "kind": "ReturnStmt",
                     "inner": [{"kind": "IntegerLiteral", "value": "7"}]
                 }]}]}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "NumBox.operator int");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(fn->metadata.at("is_conversion_operator").get<bool>());
}

TEST(encode_enum_unscoped_adds_values_no_type_def) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "EnumDecl",
            "name": "Color",
            "inner": [
                {"kind": "EnumConstantDecl", "name": "Red"},
                {"kind": "EnumConstantDecl", "name": "Green"}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* e = find_enum(prog, "Color");
    ASSERT_TRUE(e != nullptr);
    ASSERT_TRUE(e->at("value").size() == 2);
    ASSERT_EQ(e->at("value").at(0).at("name").get<std::string>(), std::string("Red"));
    // Unscoped enums do NOT also get a type_def.
    ASSERT_TRUE(find_type_def(prog, "Color") == nullptr);
}

TEST(encode_enum_scoped_also_adds_type_def) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "EnumDecl",
            "name": "Direction",
            "scopedEnumTag": "class",
            "inner": [
                {"kind": "EnumConstantDecl", "name": "North"}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_enum(prog, "Direction") != nullptr);
    auto* td = find_type_def(prog, "Direction");
    ASSERT_TRUE(td != nullptr);
    ASSERT_EQ(td->metadata.at("kind").get<std::string>(), std::string("enum"));
}

TEST(encode_type_alias_typedef) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "TypedefDecl",
            "name": "MyInt",
            "type": {"qualType": "int"}
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* m = find_main(prog);
    ASSERT_TRUE(m != nullptr);
    ASSERT_TRUE(m->typeAliases.size() == 1);
    ASSERT_EQ(m->typeAliases[0].name, std::string("MyInt"));
    ASSERT_EQ(m->typeAliases[0].targetType, std::string("int"));
}

TEST(encode_namespace_decl_qualifies_names) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "NamespaceDecl",
            "name": "util",
            "inner": [{
                "kind": "FunctionDecl",
                "name": "helper",
                "type": {"qualType": "int ()"},
                "inner": [{"kind": "CompoundStmt", "inner": []}]
            }]
        }]
    })JSON";
    auto prog = run_encoder(json);
    ASSERT_TRUE(find_fn(prog, "util::helper") != nullptr);
}

TEST(encode_using_decl_is_noop) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [
            {"kind": "UsingDirectiveDecl"},
            {
                "kind": "FunctionDecl",
                "name": "f",
                "type": {"qualType": "int ()"},
                "inner": [{"kind": "CompoundStmt", "inner": []}]
            }
        ]
    })JSON";
    auto prog = run_encoder(json);
    auto* m = find_main(prog);
    ASSERT_TRUE(m != nullptr);
    // Only `f` was encoded — the using-directive contributed nothing.
    ASSERT_TRUE(m->functions.size() == 1);
    ASSERT_TRUE(find_fn(prog, "f") != nullptr);
}

TEST(encode_class_template_decl_attaches_type_params) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "ClassTemplateDecl",
            "inner": [
                {"kind": "TemplateTypeParmDecl", "name": "T"},
                {"kind": "CXXRecordDecl", "name": "Box", "tagUsed": "class", "inner": []}
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* td = find_type_def(prog, "Box");
    ASSERT_TRUE(td != nullptr);
    ASSERT_TRUE(td->typeParams.size() == 1);
    ASSERT_EQ(td->typeParams[0].name, std::string("T"));
}

TEST(encode_function_template_decl_attaches_type_params) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionTemplateDecl",
            "inner": [
                {"kind": "TemplateTypeParmDecl", "name": "T"},
                {
                    "kind": "FunctionDecl",
                    "name": "identity",
                    "type": {"qualType": "T (T)"},
                    "inner": [{"kind": "CompoundStmt", "inner": []}]
                }
            ]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "identity");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(fn->metadata.at("type_params").size() == 1);
}

TEST(encode_global_var_decl_top_level_variable) {
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "VarDecl",
            "name": "counter",
            "type": {"qualType": "int"},
            "inner": [{"kind": "IntegerLiteral", "value": "0"}]
        }]
    })JSON";
    auto prog = run_encoder(json);
    auto* fn = find_fn(prog, "counter");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_EQ(fn->metadata.at("kind").get<std::string>(),
              std::string("top_level_variable"));
}

// ================================================================
// Statements: for / range-for / do-while / switch.
// ================================================================

TEST(encode_for_statement_is_std_for) {
    // for (;;) {}
    auto prog = encode_stmt(R"JSON({
        "kind": "ForStmt",
        "inner": [null, null, null, null, {"kind": "CompoundStmt", "inner": []}]
    })JSON");
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(body_json(fn).find("\"for\"") != std::string::npos);
}

TEST(encode_range_for_statement_is_std_for_in) {
    auto prog = encode_stmt(R"JSON({
        "kind": "CXXForRangeStmt",
        "inner": [
            {"kind": "VarDecl", "name": "item", "type": {"qualType": "int"}},
            {"kind": "DeclRefExpr", "referencedDecl": {"name": "items"}},
            {"kind": "CompoundStmt", "inner": []}
        ]
    })JSON");
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(body_json(fn).find("\"for_in\"") != std::string::npos);
}

TEST(encode_do_while_statement_is_std_do_while) {
    auto prog = encode_stmt(R"JSON({
        "kind": "DoStmt",
        "inner": [
            {"kind": "CompoundStmt", "inner": []},
            {"kind": "CXXBoolLiteralExpr", "value": false}
        ]
    })JSON");
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(body_json(fn).find("\"do_while\"") != std::string::npos);
}

TEST(encode_switch_statement_is_std_switch) {
    auto prog = encode_stmt(R"JSON({
        "kind": "SwitchStmt",
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "x"}}]
    })JSON");
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(body_json(fn).find("\"switch\"") != std::string::npos);
}

// ================================================================
// Expressions: member access, calls, operators, casts, misc.
// ================================================================

TEST(encode_member_expr_dot_and_arrow) {
    auto dot = encode_return_expr(R"JSON({
        "kind": "MemberExpr", "name": "field", "isArrow": false,
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "obj"}}]
    })JSON");
    auto* f1 = find_fn(dot, "f");
    ASSERT_TRUE(f1 != nullptr);
    ASSERT_TRUE(body_json(f1).find("\"field\":\"field\"") != std::string::npos);

    auto arrow = encode_return_expr(R"JSON({
        "kind": "MemberExpr", "name": "field", "isArrow": true,
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "ptr"}}]
    })JSON");
    auto* f2 = find_fn(arrow, "f");
    ASSERT_TRUE(f2 != nullptr);
    ASSERT_TRUE(body_json(f2).find("\"field\":\"field\"") != std::string::npos);
}

TEST(encode_call_expr_with_args) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CallExpr",
        "inner": [
            {"kind": "ImplicitCastExpr", "castKind": "FunctionToPointerDecay",
             "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "add"}}]},
            {"kind": "IntegerLiteral", "value": "1"},
            {"kind": "IntegerLiteral", "value": "2"}
        ]
    })JSON");
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("\"function\":\"add\"") != std::string::npos);
    ASSERT_TRUE(body_str.find("arg0") != std::string::npos);
    ASSERT_TRUE(body_str.find("arg1") != std::string::npos);
}

TEST(encode_member_call_expr_binds_self) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXMemberCallExpr",
        "inner": [
            {"kind": "MemberExpr", "name": "getX",
             "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "obj"}}]}
        ]
    })JSON");
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    auto body_str = body_json(fn);
    ASSERT_TRUE(body_str.find("\"function\":\"getX\"") != std::string::npos);
    ASSERT_TRUE(body_str.find("\"name\":\"self\"") != std::string::npos);
}

TEST(encode_operator_call_expr_dispatches_binary_vs_unary) {
    // Binary: operator+(a, b) has 3 inner nodes (callee + 2 operands).
    auto bin = encode_return_expr(R"JSON({
        "kind": "CXXOperatorCallExpr", "opcode": "+",
        "inner": [
            {"kind": "DeclRefExpr", "referencedDecl": {"name": "operator+"}},
            {"kind": "IntegerLiteral", "value": "1"},
            {"kind": "IntegerLiteral", "value": "2"}
        ]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(bin, "f")).find("add") != std::string::npos);
}

TEST(encode_compound_assign_op_carries_op) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CompoundAssignOperator", "opcode": "+=",
        "inner": [
            {"kind": "DeclRefExpr", "referencedDecl": {"name": "x"}},
            {"kind": "IntegerLiteral", "value": "1"}
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("\"assign\"") != std::string::npos);
    ASSERT_TRUE(body_str.find("+=") != std::string::npos);
}

TEST(encode_conditional_op_is_std_if) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "ConditionalOperator",
        "inner": [
            {"kind": "CXXBoolLiteralExpr", "value": true},
            {"kind": "IntegerLiteral", "value": "1"},
            {"kind": "IntegerLiteral", "value": "2"}
        ]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(prog, "f")).find("\"if\"") != std::string::npos);
}

TEST(encode_new_expr_is_message_creation) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXNewExpr", "type": {"qualType": "Foo *"}, "inner": []
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("\"typeName\":\"Foo *\"") != std::string::npos);
}

TEST(encode_delete_expr_is_noop_comment) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXDeleteExpr",
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("GC managed") != std::string::npos);
}

TEST(encode_cpp_static_and_dynamic_cast_are_std_as) {
    auto stat = encode_return_expr(R"JSON({
        "kind": "CXXStaticCastExpr", "type": {"qualType": "Derived *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(stat, "f")).find("\"as\"") != std::string::npos);

    auto dyn = encode_return_expr(R"JSON({
        "kind": "CXXDynamicCastExpr", "type": {"qualType": "Derived *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(dyn, "f")).find("\"as\"") != std::string::npos);
}

TEST(encode_cpp_reinterpret_cast_is_memory_read) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXReinterpretCastExpr", "type": {"qualType": "int *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("std_memory") != std::string::npos);
    ASSERT_TRUE(body_str.find("memory_read_i64") != std::string::npos);
}

TEST(encode_cpp_const_cast_passes_through) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXConstCastExpr", "type": {"qualType": "int *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("\"name\":\"p\"") != std::string::npos);
}

TEST(encode_c_style_cast_is_std_as) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CStyleCastExpr", "type": {"qualType": "double"},
        "inner": [{"kind": "IntegerLiteral", "value": "1"}]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(prog, "f")).find("\"as\"") != std::string::npos);
}

TEST(encode_array_subscript_is_std_index) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "ArraySubscriptExpr",
        "inner": [
            {"kind": "DeclRefExpr", "referencedDecl": {"name": "arr"}},
            {"kind": "IntegerLiteral", "value": "0"}
        ]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(prog, "f")).find("\"index\"") != std::string::npos);
}

TEST(encode_sizeof_is_memory_sizeof) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "UnaryExprOrTypeTraitExpr", "argType": {"qualType": "int"}
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("memory_sizeof") != std::string::npos);
}

TEST(encode_construct_expr_is_message_creation) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXConstructExpr", "type": {"qualType": "Foo"},
        "inner": [{"kind": "IntegerLiteral", "value": "1"}]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("\"typeName\":\"Foo\"") != std::string::npos);
}

TEST(encode_init_list_expr_is_list_literal) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "InitListExpr",
        "inner": [
            {"kind": "IntegerLiteral", "value": "1"},
            {"kind": "IntegerLiteral", "value": "2"}
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("listValue") != std::string::npos);
}

TEST(encode_lambda_expr_has_body) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "LambdaExpr",
        "inner": [{"kind": "CompoundStmt", "inner": []}]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("lambda") != std::string::npos);
}

// ================================================================
// cov_* — reachability-audit coverage (issue #63)
// ================================================================
//
// Every case below was written against a specific UNCOVERED line range in
// cpp/encoder/src/encoder.cpp, taken from Codecov's `cpp` flag file_report at
// main @ f673169c (96 missed lines / 38 clusters; the API's line_coverage
// state is 0 = HIT, 1 = MISS — calibrated against totals.hits before use, per
// .claude/rules/cpp.md).
//
// The audit question for each cluster was "is this reachable from anything
// other than the self-host path?", and for encoder.cpp the answer is YES for
// all 96: `CppEncoder::encode_from_clang_ast` is a pure JSON-AST -> ball::ir
// transform with no I/O, no toolchain dependency and no engine involvement, so
// every branch is reachable from an instrumented ctest binary by handing it the
// AST shape that selects it. NONE of them earns an `LCOV_EXCL_*` marker — the
// encoder is not embedded into generated programs the way ball_dyn.h is, so it
// has none of that header's structural-undercount problem (see
// cpp/test/AGENTS.md). They were simply untested.
//
// Each TEST names the cluster it closes so the next reader can re-derive the
// mapping against a fresh report rather than trusting a stale line number.

// --- double_literal + FloatingLiteral (encoder.cpp 50-54, 872) -------------
TEST(cov_floating_literal_encodes_double) {
    auto prog = encode_return_expr(
        R"JSON({"kind": "FloatingLiteral", "value": "2.5"})JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("doubleValue") != std::string::npos);
    ASSERT_TRUE(body_str.find("2.5") != std::string::npos);
}

// --- CharacterLiteral (encoder.cpp 876) -----------------------------------
TEST(cov_character_literal_encodes_int) {
    // clang emits CharacterLiteral's `value` as a JSON NUMBER (the code point),
    // not a string — hence node.value("value", 0) rather than std::stoll.
    auto prog = encode_return_expr(
        R"JSON({"kind": "CharacterLiteral", "value": 65})JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("intValue") != std::string::npos);
    ASSERT_TRUE(body_str.find("65") != std::string::npos);
}

// --- CXXNullPtrLiteralExpr (encoder.cpp 881-884) --------------------------
TEST(cov_nullptr_literal_encodes_empty_literal) {
    auto prog = encode_return_expr(
        R"JSON({"kind": "CXXNullPtrLiteralExpr"})JSON");
    auto* fn = find_fn(prog, "f");
    auto body_str = body_json(fn);
    // An unset literal oneof = Ball null: the node is a `literal` with no
    // value member set.
    ASSERT_TRUE(body_str.find("literal") != std::string::npos);
    ASSERT_TRUE(body_str.find("intValue") == std::string::npos);
    ASSERT_TRUE(body_str.find("stringValue") == std::string::npos);
    ASSERT_TRUE(body_str.find("boolValue") == std::string::npos);
}

// --- FunctionDecl qualifier metadata (encoder.cpp 256-262, 1360-1364) -----
TEST(cov_function_decl_qualifier_metadata) {
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "q",
            "type": {"qualType": "int ()"},
            "storageClass": "static",
            "inline": true,
            "constexpr": true,
            "virtual": true,
            "inner": [{"kind": "CompoundStmt", "inner": []}]
        }]
    })JSON");
    auto* fn = find_fn(prog, "q");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(fn->metadata.value("is_static", false));
    ASSERT_TRUE(fn->metadata.value("is_const", false));
    ASSERT_TRUE(fn->metadata.value("is_abstract", false));
    // `annotations` here is CppEncoder::list_value({"inline"}) — the only
    // caller of that helper.
    ASSERT_TRUE(fn->metadata.contains("annotations"));
    ASSERT_EQ(fn->metadata["annotations"].size(), size_t(1));
    ASSERT_EQ(fn->metadata["annotations"][0].get<std::string>(),
              std::string("inline"));
}

// --- has_qualifier's `const` type-string branch (encoder.cpp 1334) --------
TEST(cov_has_qualifier_const_via_type_string) {
    // `const` is not a clang AST flag — it is read off the qualType string,
    // both as a leading "const " and as a trailing " const".
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "VarDecl",
            "name": "g",
            "type": {"qualType": "const int"},
            "inner": [{"kind": "IntegerLiteral", "value": "7"}]
        }]
    })JSON");
    auto* fn = find_fn(prog, "g");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(fn->metadata.value("is_const", false));
}

// --- FieldDecl const/static metadata (encoder.cpp 327-329) ----------------
TEST(cov_field_decl_const_and_static_metadata) {
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "CXXRecordDecl",
            "name": "C",
            "tagUsed": "class",
            "completeDefinition": true,
            "inner": [
                {"kind": "FieldDecl", "name": "a",
                 "type": {"qualType": "const int"}},
                {"kind": "FieldDecl", "name": "b",
                 "type": {"qualType": "int"}, "storageClass": "static"}
            ]
        }]
    })JSON");
    auto* td = find_type_def(prog, "C");
    ASSERT_TRUE(td != nullptr);
    ASSERT_EQ(descriptor_field_count(td), size_t(2));
    auto fields = td->metadata["fields"];
    ASSERT_TRUE(fields.is_array());
    ASSERT_EQ(fields.size(), size_t(2));
    ASSERT_TRUE(fields[0].value("is_final", false));
    ASSERT_TRUE(fields[1].value("is_static", false));
}

// --- CXXMethodDecl / ctor / dtor qualifiers (encoder.cpp 365-371, 393, 414)
TEST(cov_method_ctor_dtor_qualifier_metadata) {
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "CXXRecordDecl",
            "name": "D",
            "tagUsed": "class",
            "completeDefinition": true,
            "inner": [
                {"kind": "CXXMethodDecl", "name": "m",
                 "type": {"qualType": "int () const"},
                 "storageClass": "static", "virtual": true},
                {"kind": "CXXConstructorDecl", "name": "D",
                 "type": {"qualType": "void ()"}, "explicit": true,
                 "inner": [{"kind": "CompoundStmt", "inner": []}]},
                {"kind": "CXXDestructorDecl", "name": "~D",
                 "type": {"qualType": "void ()"}, "virtual": true,
                 "inner": [{"kind": "CompoundStmt", "inner": []}]}
            ]
        }]
    })JSON");
    auto* m = find_fn(prog, "D.m");
    ASSERT_TRUE(m != nullptr);
    ASSERT_TRUE(m->metadata.value("is_static", false));
    // No body -> pure virtual.
    ASSERT_TRUE(m->metadata.value("is_abstract", false));
    ASSERT_TRUE(!m->metadata.value("is_override", true));
    // " const" in the qualType drives the `const` annotation.
    ASSERT_TRUE(m->metadata.contains("annotations"));
    bool has_const = false;
    for (const auto& a : m->metadata["annotations"])
        if (a.is_string() && a.get<std::string>() == "const") has_const = true;
    ASSERT_TRUE(has_const);

    auto* ctor = find_fn(prog, "D.new");
    ASSERT_TRUE(ctor != nullptr);
    bool has_explicit = false;
    for (const auto& a : ctor->metadata["annotations"])
        if (a.is_string() && a.get<std::string>() == "explicit") has_explicit = true;
    ASSERT_TRUE(has_explicit);

    auto* dtor = find_fn(prog, "D.~D");
    ASSERT_TRUE(dtor != nullptr);
    bool has_virtual = false, has_destructor = false;
    for (const auto& a : dtor->metadata["annotations"]) {
        if (!a.is_string()) continue;
        if (a.get<std::string>() == "virtual") has_virtual = true;
        if (a.get<std::string>() == "destructor") has_destructor = true;
    }
    ASSERT_TRUE(has_virtual);
    ASSERT_TRUE(has_destructor);
}

// --- overload mangling strips "::" from param types (encoder.cpp 231) -----
TEST(cov_overload_mangling_replaces_scope_operator) {
    // Two same-named FunctionDecls force the mangling branch; the second's
    // param type carries a "::" so the `t.replace(pos, 2, "_")` loop runs.
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [
            {"kind": "FunctionDecl", "name": "f",
             "type": {"qualType": "int (int)"},
             "inner": [
                {"kind": "ParmVarDecl", "name": "x", "type": {"qualType": "int"}},
                {"kind": "CompoundStmt", "inner": []}]},
            {"kind": "FunctionDecl", "name": "f",
             "type": {"qualType": "int (std::string)"},
             "inner": [
                {"kind": "ParmVarDecl", "name": "s",
                 "type": {"qualType": "const std::string&"}},
                {"kind": "CompoundStmt", "inner": []}]}
        ]
    })JSON");
    // "const std::string&" -> strip '&', strip "const ", ' ' -> '_',
    // "::" -> "_"  ==>  "std_string".
    ASSERT_TRUE(find_fn(prog, "f$std_string") != nullptr);
}

// --- nested namespace: record + namespace children (encoder.cpp 507-513) --
TEST(cov_namespace_decl_nested_record_and_namespace) {
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "NamespaceDecl",
            "name": "outer",
            "inner": [
                {"kind": "CXXRecordDecl", "name": "R", "tagUsed": "struct",
                 "completeDefinition": true,
                 "inner": [{"kind": "FieldDecl", "name": "v",
                            "type": {"qualType": "int"}}]},
                {"kind": "NamespaceDecl", "name": "inner",
                 "inner": [{"kind": "FunctionDecl", "name": "deep",
                            "type": {"qualType": "int ()"},
                            "inner": [{"kind": "CompoundStmt", "inner": []}]}]}
            ]
        }]
    })JSON");
    ASSERT_TRUE(find_type_def(prog, "outer::R") != nullptr);
    ASSERT_TRUE(find_fn(prog, "outer::inner::deep") != nullptr);
}

// --- class template: non-type param + specializations (538-541, 572-579) --
TEST(cov_class_template_non_type_param_and_specializations) {
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "ClassTemplateDecl",
            "inner": [
                {"kind": "TemplateTypeParmDecl", "name": "T"},
                {"kind": "NonTypeTemplateParmDecl", "name": "N",
                 "type": {"qualType": "size_t"}},
                {"kind": "CXXRecordDecl", "name": "Box", "tagUsed": "struct",
                 "completeDefinition": true,
                 "inner": [{"kind": "FieldDecl", "name": "v",
                            "type": {"qualType": "int"}}]},
                {"kind": "ClassTemplateSpecializationDecl",
                 "type": {"qualType": "Box<int, 4>"}},
                {"kind": "ClassTemplatePartialSpecializationDecl"}
            ]
        }]
    })JSON");
    auto* td = find_type_def(prog, "Box");
    ASSERT_TRUE(td != nullptr);
    auto tp = td->metadata["type_params"];
    ASSERT_EQ(tp.size(), size_t(2));
    ASSERT_EQ(tp[0].get<std::string>(), std::string("T"));
    ASSERT_EQ(tp[1].get<std::string>(), std::string("size_t N"));
    auto specs = td->metadata["specializations"];
    ASSERT_EQ(specs.size(), size_t(2));
    ASSERT_EQ(specs[0]["type_args"].get<std::string>(), std::string("Box<int, 4>"));
    // The partial specialization carries no `type` -> the "<unknown>" arm.
    ASSERT_EQ(specs[1]["type_args"].get<std::string>(), std::string("<unknown>"));
}

// --- function template: non-type param, specs, enable_if (600-646) -------
TEST(cov_function_template_non_type_param_specs_and_enable_if) {
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionTemplateDecl",
            "inner": [
                {"kind": "TemplateTypeParmDecl", "name": "T"},
                {"kind": "NonTypeTemplateParmDecl", "name": "N",
                 "type": {"qualType": "unsigned"}},
                {"kind": "FunctionDecl", "name": "tf",
                 "type": {"qualType": "typename enable_if<is_integral<T>::value, T>::type (T)"},
                 "inner": [{"kind": "CompoundStmt", "inner": []}]},
                {"kind": "FunctionTemplateSpecializationDecl",
                 "type": {"qualType": "int (int)"}},
                {"kind": "FunctionTemplateSpecializationDecl"}
            ]
        }]
    })JSON");
    auto* fn = find_fn(prog, "tf");
    ASSERT_TRUE(fn != nullptr);
    auto tp = fn->metadata["type_params"];
    ASSERT_EQ(tp.size(), size_t(2));
    ASSERT_EQ(tp[1].get<std::string>(), std::string("unsigned N"));
    auto specs = fn->metadata["specializations"];
    ASSERT_EQ(specs.size(), size_t(2));
    ASSERT_EQ(specs[0]["type_args"].get<std::string>(), std::string("int (int)"));
    ASSERT_EQ(specs[1]["type_args"].get<std::string>(), std::string("<unknown>"));
    // enable_if in the function's own qualType becomes an annotation object.
    bool found_enable_if = false;
    for (const auto& a : fn->metadata["annotations"])
        if (a.is_object() && a.value("name", std::string{}) == "enable_if")
            found_enable_if = true;
    ASSERT_TRUE(found_enable_if);
}

// --- DeclStmt: non-VarDecl, no-init, const (encoder.cpp 734, 752, 758) ----
TEST(cov_decl_stmt_non_vardecl_is_dropped) {
    // A DeclStmt whose first child is not a VarDecl (e.g. a local using-alias)
    // yields no statement at all.
    auto prog = encode_stmt(R"JSON({
        "kind": "DeclStmt",
        "inner": [{"kind": "TypeAliasDecl", "name": "Alias"}]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("Alias") == std::string::npos);
}

TEST(cov_decl_stmt_without_initializer_and_const) {
    auto prog = encode_stmt(R"JSON({
        "kind": "DeclStmt",
        "inner": [{"kind": "VarDecl", "name": "x",
                   "type": {"qualType": "const int"}}]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("__no_init__") != std::string::npos);
    ASSERT_TRUE(body_str.find("is_final") != std::string::npos);
}

// --- ForStmt init/condition/update arms (encoder.cpp 795-799) -------------
TEST(cov_for_stmt_init_condition_update) {
    // clang's ForStmt inner is [init, <cond-var>, cond, inc, body]; the null
    // slots real clang emits are JSON `null`, which the is_object() guards skip.
    auto prog = encode_stmt(R"JSON({
        "kind": "ForStmt",
        "inner": [
            {"kind": "DeclStmt", "inner": [{"kind": "VarDecl", "name": "i",
              "type": {"qualType": "int"},
              "inner": [{"kind": "IntegerLiteral", "value": "0"}]}]},
            null,
            {"kind": "BinaryOperator", "opcode": "<", "inner": [
                {"kind": "DeclRefExpr", "referencedDecl": {"name": "i"}},
                {"kind": "IntegerLiteral", "value": "3"}]},
            {"kind": "UnaryOperator", "opcode": "++", "isPostfix": true,
             "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "i"}}]},
            {"kind": "CompoundStmt", "inner": []}
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("\"function\":\"for\"") != std::string::npos);
    ASSERT_TRUE(body_str.find("init") != std::string::npos);
    ASSERT_TRUE(body_str.find("condition") != std::string::npos);
    ASSERT_TRUE(body_str.find("update") != std::string::npos);
    ASSERT_TRUE(body_str.find("post_increment") != std::string::npos);
}

// --- implicit `this` receiver (encoder.cpp 955, 1027-1036) ---------------
TEST(cov_member_expr_implicit_this_receiver) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "MemberExpr", "name": "field", "inner": []
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("this") != std::string::npos);
    ASSERT_TRUE(body_str.find("field") != std::string::npos);
}

TEST(cov_member_call_implicit_this_receiver_and_args) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXMemberCallExpr",
        "inner": [
            {"kind": "MemberExpr", "name": "doIt", "inner": []},
            {"kind": "IntegerLiteral", "value": "1"},
            null,
            {"kind": "IntegerLiteral", "value": "2"}
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("doIt") != std::string::npos);
    ASSERT_TRUE(body_str.find("self") != std::string::npos);
    ASSERT_TRUE(body_str.find("this") != std::string::npos);
    ASSERT_TRUE(body_str.find("arg0") != std::string::npos);
    // The JSON `null` at index 2 is skipped, so arg1 never appears but arg2 does.
    ASSERT_TRUE(body_str.find("arg1") == std::string::npos);
    ASSERT_TRUE(body_str.find("arg2") != std::string::npos);
}

// --- callee resolution corner cases (encoder.cpp 982, 997-998) ------------
TEST(cov_call_expr_wrapper_without_inner_and_non_declref_callee) {
    // An ImplicitCastExpr with no `inner` cannot be unwrapped further, so
    // resolve_callee returns the wrapper itself; it is not a DeclRefExpr, so
    // the name comes from the node's own "name".
    auto prog = encode_return_expr(R"JSON({
        "kind": "CallExpr",
        "inner": [
            {"kind": "ImplicitCastExpr", "name": "viaWrapper"},
            {"kind": "IntegerLiteral", "value": "9"}
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("viaWrapper") != std::string::npos);
}

// --- unknown-kind fallthrough (encoder.cpp 935, 939-942) -----------------
TEST(cov_unknown_expression_kind_recurses_then_yields_null) {
    // Unknown kind WITH an inner child -> recurse into the child.
    auto with_child = encode_return_expr(R"JSON({
        "kind": "SomeUnmodelledExpr",
        "inner": [{"kind": "IntegerLiteral", "value": "42"}]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(with_child, "f")).find("42") !=
                std::string::npos);

    // Unknown kind with NO inner -> a null literal, never a crash.
    auto bare = encode_return_expr(R"JSON({"kind": "SomeUnmodelledExpr"})JSON");
    auto* fn = find_fn(bare, "f");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(body_json(fn).find("literal") != std::string::npos);
}

TEST(cov_paren_expr_without_inner_yields_null) {
    auto prog = encode_return_expr(R"JSON({"kind": "ParenExpr"})JSON");
    ASSERT_TRUE(find_fn(prog, "f") != nullptr);
}

TEST(cov_implicit_cast_without_inner_yields_null) {
    auto prog = encode_return_expr(
        R"JSON({"kind": "ImplicitCastExpr", "inner": []})JSON");
    ASSERT_TRUE(find_fn(prog, "f") != nullptr);
}

// --- operator-call arity dispatch (encoder.cpp 1045) ---------------------
TEST(cov_operator_call_with_two_children_is_unary) {
    // CXXOperatorCallExpr inner = [callee, operand] -> fewer than 3 children,
    // so it routes to encode_unary_op rather than encode_binary_op.
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXOperatorCallExpr", "opcode": "-",
        "inner": [
            {"kind": "DeclRefExpr", "referencedDecl": {"name": "operator-"}},
            {"kind": "IntegerLiteral", "value": "5"}
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("negate") != std::string::npos);
}

// --- binary_op unmapped-opcode fallback to std.add (1067-1069) -----------
TEST(cov_binary_op_unmapped_opcode_falls_back_to_add) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "BinaryOperator", "opcode": "<=>",
        "inner": [
            {"kind": "IntegerLiteral", "value": "1"},
            {"kind": "IntegerLiteral", "value": "2"}
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("\"function\":\"add\"") != std::string::npos);
}

// --- unary operators: * & ~ -- and the unknown-opcode passthrough --------
TEST(cov_unary_deref_and_address_of_are_identity_projections) {
    auto deref = encode_return_expr(R"JSON({
        "kind": "UnaryOperator", "opcode": "*",
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    auto deref_str = body_json(find_fn(deref, "f"));
    // Safe projection: the operand becomes the returned value DIRECTLY -- no
    // std call is introduced for the deref itself (the only `call` in the body
    // is the `std.return` wrapper this helper's `return <expr>;` produces).
    ASSERT_TRUE(deref_str.find("\"value\",\"value\":{\"reference\":{\"name\":\"p\"}}")
                != std::string::npos);

    auto addr = encode_return_expr(R"JSON({
        "kind": "UnaryOperator", "opcode": "&",
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "q"}}]
    })JSON");
    auto addr_str = body_json(find_fn(addr, "f"));
    ASSERT_TRUE(addr_str.find("\"value\",\"value\":{\"reference\":{\"name\":\"q\"}}")
                != std::string::npos);
}

TEST(cov_unary_bitwise_not_decrement_and_unknown_opcode) {
    auto bnot = encode_return_expr(R"JSON({
        "kind": "UnaryOperator", "opcode": "~",
        "inner": [{"kind": "IntegerLiteral", "value": "3"}]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(bnot, "f")).find("bitwise_not") !=
                std::string::npos);

    auto predec = encode_return_expr(R"JSON({
        "kind": "UnaryOperator", "opcode": "--", "isPostfix": false,
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "i"}}]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(predec, "f")).find("pre_decrement") !=
                std::string::npos);

    auto postdec = encode_return_expr(R"JSON({
        "kind": "UnaryOperator", "opcode": "--", "isPostfix": true,
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "i"}}]
    })JSON");
    ASSERT_TRUE(body_json(find_fn(postdec, "f")).find("post_decrement") !=
                std::string::npos);

    // An opcode with no mapping passes the operand through unchanged.
    auto unknown = encode_return_expr(R"JSON({
        "kind": "UnaryOperator", "opcode": "__unmapped__",
        "inner": [{"kind": "IntegerLiteral", "value": "11"}]
    })JSON");
    auto unknown_str = body_json(find_fn(unknown, "f"));
    ASSERT_TRUE(unknown_str.find("\"value\",\"value\":{\"literal\":{\"intValue\":\"11\"}}")
                != std::string::npos);
}

// --- CXXNewExpr argument collection (encoder.cpp 1131-1132) --------------
TEST(cov_new_expr_collects_args_and_skips_non_objects) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXNewExpr", "type": {"qualType": "Widget *"},
        "inner": [
            {"kind": "IntegerLiteral", "value": "1"},
            null
        ]
    })JSON");
    auto body_str = body_json(find_fn(prog, "f"));
    ASSERT_TRUE(body_str.find("Widget") != std::string::npos);
    ASSERT_TRUE(body_str.find("arg0") != std::string::npos);
    ASSERT_TRUE(body_str.find("arg1") == std::string::npos);
}

// --- find_child / find_child_expr "not found" arms (1347, 1357) ----------
TEST(cov_find_child_and_find_body_return_null_when_absent) {
    // A FunctionDecl whose only child is a ParmVarDecl has no body child
    // (find_child_expr -> nullptr) and no CompoundStmt (find_child -> nullptr):
    // the encoder must still emit the function, as a base declaration.
    auto prog = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl", "name": "decl_only",
            "type": {"qualType": "int (int)"},
            "inner": [{"kind": "ParmVarDecl", "name": "x",
                       "type": {"qualType": "int"}}]
        }]
    })JSON");
    auto* fn = find_fn(prog, "decl_only");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(fn->body == nullptr);

    // find_child_expr's own "nothing but declarations" arm: a global VarDecl
    // whose only child is another VarDecl has no initializer expression, so the
    // encoded top-level variable carries no value.
    auto no_init = run_encoder(R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "VarDecl", "name": "gv", "type": {"qualType": "int"},
            "inner": [{"kind": "VarDecl", "name": "shadow",
                       "type": {"qualType": "int"}}]
        }]
    })JSON");
    auto* gv = find_fn(no_init, "gv");
    ASSERT_TRUE(gv != nullptr);
    ASSERT_TRUE(gv->body == nullptr);
}

int main() {
    std::cout << "Ball C++ Encoder Tests\n"
              << "======================\n";

    std::cout << "\n======================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";
    // POSITIVE FLOOR (issues #439/#444, and the rule in cpp/test/AGENTS.md).
    // Every TEST() registers from a static initializer, so a binary that lost
    // them all — a bad merge, a preprocessor guard, a linker that dropped the
    // TU — prints "0 passed, 0 failed" and exits 0. An exit code alone cannot
    // tell "everything passed" from "nothing ran"; test_compiler and
    // test_ball_dyn already carry this floor, test_encoder did not.
    if (tests_passed < 1) {
        std::cout << "ERROR: no encoder tests ran — a green exit here would "
                     "mean the gate checked nothing.\n";
        return 1;
    }
    return tests_failed > 0 ? 1 : 0;
}
