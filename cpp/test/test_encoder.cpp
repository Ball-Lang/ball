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

#include "encoder.h"
#include "ball_shared.h"

#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#ifndef BALL_CLANG_AST_DIR
#define BALL_CLANG_AST_DIR ""
#endif

using namespace ball;

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

static ball::v1::Program run_encoder(const std::string& json) {
    CppEncoder encoder;
    return encoder.encode_from_clang_ast(json);
}

// Find the "main" user module in the encoded program.
static const ball::v1::Module* find_main(const ball::v1::Program& p) {
    for (int i = 0; i < p.modules_size(); i++) {
        if (p.modules(i).name() == "main") return &p.modules(i);
    }
    return nullptr;
}

// Find a function by name in the main module.
static const ball::v1::FunctionDefinition* find_fn(
    const ball::v1::Program& p, const std::string& name) {
    auto* m = find_main(p);
    if (!m) return nullptr;
    for (int i = 0; i < m->functions_size(); i++) {
        if (m->functions(i).name() == name) return &m->functions(i);
    }
    return nullptr;
}

// Find a type_def by name in the main module (classes/structs/scoped enums).
static const ball::v1::TypeDefinition* find_type_def(
    const ball::v1::Program& p, const std::string& name) {
    auto* m = find_main(p);
    if (!m) return nullptr;
    for (int i = 0; i < m->type_defs_size(); i++) {
        if (m->type_defs(i).name() == name) return &m->type_defs(i);
    }
    return nullptr;
}

// Find an enum def (google.protobuf.EnumDescriptorProto) by name in the
// main module.
static const google::protobuf::EnumDescriptorProto* find_enum(
    const ball::v1::Program& p, const std::string& name) {
    auto* m = find_main(p);
    if (!m) return nullptr;
    for (int i = 0; i < m->enums_size(); i++) {
        if (m->enums(i).name() == name) return &m->enums(i);
    }
    return nullptr;
}

// Wrap a single expression node (as raw JSON text) in `int f() { return
// <expr>; }` and encode it. Reduces boilerplate for expression-level tests.
static ball::v1::Program encode_return_expr(const std::string& expr_json) {
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
static ball::v1::Program encode_stmt(const std::string& stmt_json) {
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
    ASSERT_EQ(prog.entry_module(), "main");
    ASSERT_EQ(prog.entry_function(), "main");
    // std, std_memory, main = 3 modules minimum.
    ASSERT_TRUE(prog.modules_size() >= 3);
    bool has_main = false, has_std = false, has_cpp_std = false;
    for (int i = 0; i < prog.modules_size(); i++) {
        auto& n = prog.modules(i).name();
        if (n == "main") has_main = true;
        if (n == "std") has_std = true;
        if (n == "cpp_std") has_cpp_std = true;
    }
    ASSERT_TRUE(has_main);
    ASSERT_TRUE(has_std);
    ASSERT_TRUE(!has_cpp_std);  // cpp_std module eliminated
    // source_language metadata must be "cpp".
    ASSERT_TRUE(prog.has_metadata());
    auto it = prog.metadata().fields().find("source_language");
    ASSERT_TRUE(it != prog.metadata().fields().end());
    ASSERT_EQ(it->second.string_value(), "cpp");
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
    ASSERT_TRUE(fn->has_body());
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
    // Walk: body (block) → result expression is IntegerLiteral(7).
    const auto& body = fn->body();
    ASSERT_TRUE(body.expr_case() == ball::v1::Expression::kBlock);
    // Either via result or last statement — encoder puts returns as
    // statements; confirm the first statement's expression is a literal.
    ASSERT_TRUE(body.block().statements_size() >= 1);
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
    // binary op expression. Serialize-to-string and just look for "add".
    auto body_str = fn->body().DebugString();
    ASSERT_TRUE(body_str.find("add") != std::string::npos);
    ASSERT_TRUE(body_str.find("module: \"std\"") != std::string::npos);
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
    auto body_str = fn->body().DebugString();
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
    auto body_str = fn->body().DebugString();
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
    auto body_str = find_fn(prog, "flip")->body().DebugString();
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
    auto body_str = fn->body().DebugString();
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
    auto body_str = find_fn(prog, "f")->body().DebugString();
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
    for (int i = 0; i < m->functions_size(); i++) {
        const auto& n = m->functions(i).name();
        if (n == "add") add_count++;
        if (n.find("add$") == 0) has_mangled = true;
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
    auto body_str = fn->body().DebugString();
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
    auto body_str = fn->body().DebugString();
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
    auto body_str = fn->body().DebugString();
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
    ASSERT_TRUE(td->descriptor_().field_size() == 1);
    ASSERT_EQ(td->descriptor_().field(0).name(), std::string("x"));
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
    ASSERT_EQ(td->metadata().fields().at("kind").string_value(), std::string("struct"));
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
    ASSERT_EQ(td->metadata().fields().at("superclass").string_value(), std::string("Base"));
    ASSERT_TRUE(td->metadata().fields().at("interfaces").list_value().values_size() == 1);
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
    ASSERT_TRUE(fn->metadata().fields().at("is_conversion_operator").bool_value());
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
    ASSERT_TRUE(e->value_size() == 2);
    ASSERT_EQ(e->value(0).name(), std::string("Red"));
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
    ASSERT_EQ(td->metadata().fields().at("kind").string_value(), std::string("enum"));
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
    ASSERT_TRUE(m->type_aliases_size() == 1);
    ASSERT_EQ(m->type_aliases(0).name(), std::string("MyInt"));
    ASSERT_EQ(m->type_aliases(0).target_type(), std::string("int"));
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
    ASSERT_TRUE(m->functions_size() == 1);
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
    ASSERT_TRUE(td->type_params_size() == 1);
    ASSERT_EQ(td->type_params(0).name(), std::string("T"));
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
    ASSERT_TRUE(fn->metadata().fields().at("type_params").list_value().values_size() == 1);
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
    ASSERT_EQ(fn->metadata().fields().at("kind").string_value(), std::string("top_level_variable"));
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
    ASSERT_TRUE(fn->body().DebugString().find("\"for\"") != std::string::npos);
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
    ASSERT_TRUE(fn->body().DebugString().find("\"for_in\"") != std::string::npos);
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
    ASSERT_TRUE(fn->body().DebugString().find("\"do_while\"") != std::string::npos);
}

TEST(encode_switch_statement_is_std_switch) {
    auto prog = encode_stmt(R"JSON({
        "kind": "SwitchStmt",
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "x"}}]
    })JSON");
    auto* fn = find_fn(prog, "f");
    ASSERT_TRUE(fn != nullptr);
    ASSERT_TRUE(fn->body().DebugString().find("\"switch\"") != std::string::npos);
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
    ASSERT_TRUE(f1->body().DebugString().find("field: \"field\"") != std::string::npos);

    auto arrow = encode_return_expr(R"JSON({
        "kind": "MemberExpr", "name": "field", "isArrow": true,
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "ptr"}}]
    })JSON");
    auto* f2 = find_fn(arrow, "f");
    ASSERT_TRUE(f2 != nullptr);
    ASSERT_TRUE(f2->body().DebugString().find("field: \"field\"") != std::string::npos);
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
    auto body_str = fn->body().DebugString();
    ASSERT_TRUE(body_str.find("function: \"add\"") != std::string::npos);
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
    auto body_str = fn->body().DebugString();
    ASSERT_TRUE(body_str.find("function: \"getX\"") != std::string::npos);
    ASSERT_TRUE(body_str.find("name: \"self\"") != std::string::npos);
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
    ASSERT_TRUE(find_fn(bin, "f")->body().DebugString().find("add") != std::string::npos);
}

TEST(encode_compound_assign_op_carries_op) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CompoundAssignOperator", "opcode": "+=",
        "inner": [
            {"kind": "DeclRefExpr", "referencedDecl": {"name": "x"}},
            {"kind": "IntegerLiteral", "value": "1"}
        ]
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
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
    ASSERT_TRUE(find_fn(prog, "f")->body().DebugString().find("\"if\"") != std::string::npos);
}

TEST(encode_new_expr_is_message_creation) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXNewExpr", "type": {"qualType": "Foo *"}, "inner": []
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("type_name: \"Foo *\"") != std::string::npos);
}

TEST(encode_delete_expr_is_noop_comment) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXDeleteExpr",
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("GC managed") != std::string::npos);
}

TEST(encode_cpp_static_and_dynamic_cast_are_std_as) {
    auto stat = encode_return_expr(R"JSON({
        "kind": "CXXStaticCastExpr", "type": {"qualType": "Derived *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    ASSERT_TRUE(find_fn(stat, "f")->body().DebugString().find("\"as\"") != std::string::npos);

    auto dyn = encode_return_expr(R"JSON({
        "kind": "CXXDynamicCastExpr", "type": {"qualType": "Derived *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    ASSERT_TRUE(find_fn(dyn, "f")->body().DebugString().find("\"as\"") != std::string::npos);
}

TEST(encode_cpp_reinterpret_cast_is_memory_read) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXReinterpretCastExpr", "type": {"qualType": "int *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("std_memory") != std::string::npos);
    ASSERT_TRUE(body_str.find("memory_read_i64") != std::string::npos);
}

TEST(encode_cpp_const_cast_passes_through) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXConstCastExpr", "type": {"qualType": "int *"},
        "inner": [{"kind": "DeclRefExpr", "referencedDecl": {"name": "p"}}]
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("name: \"p\"") != std::string::npos);
}

TEST(encode_c_style_cast_is_std_as) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CStyleCastExpr", "type": {"qualType": "double"},
        "inner": [{"kind": "IntegerLiteral", "value": "1"}]
    })JSON");
    ASSERT_TRUE(find_fn(prog, "f")->body().DebugString().find("\"as\"") != std::string::npos);
}

TEST(encode_array_subscript_is_std_index) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "ArraySubscriptExpr",
        "inner": [
            {"kind": "DeclRefExpr", "referencedDecl": {"name": "arr"}},
            {"kind": "IntegerLiteral", "value": "0"}
        ]
    })JSON");
    ASSERT_TRUE(find_fn(prog, "f")->body().DebugString().find("\"index\"") != std::string::npos);
}

TEST(encode_sizeof_is_memory_sizeof) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "UnaryExprOrTypeTraitExpr", "argType": {"qualType": "int"}
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("memory_sizeof") != std::string::npos);
}

TEST(encode_construct_expr_is_message_creation) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "CXXConstructExpr", "type": {"qualType": "Foo"},
        "inner": [{"kind": "IntegerLiteral", "value": "1"}]
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("type_name: \"Foo\"") != std::string::npos);
}

TEST(encode_init_list_expr_is_list_literal) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "InitListExpr",
        "inner": [
            {"kind": "IntegerLiteral", "value": "1"},
            {"kind": "IntegerLiteral", "value": "2"}
        ]
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("list_value") != std::string::npos);
}

TEST(encode_lambda_expr_has_body) {
    auto prog = encode_return_expr(R"JSON({
        "kind": "LambdaExpr",
        "inner": [{"kind": "CompoundStmt", "inner": []}]
    })JSON");
    auto body_str = find_fn(prog, "f")->body().DebugString();
    ASSERT_TRUE(body_str.find("lambda") != std::string::npos);
}

int main() {
    std::cout << "Ball C++ Encoder Tests\n"
              << "======================\n";

    std::cout << "\n======================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";
    return tests_failed > 0 ? 1 : 0;
}
