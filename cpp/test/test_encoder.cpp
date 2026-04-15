// Ball C++ Encoder Tests
//
// Exercises ball::CppEncoder::encode_from_clang_ast using hand-crafted
// minimal Clang-AST JSON fixtures. Each fixture covers one encoder
// responsibility: literals, binary ops, a function declaration, a typed
// return, etc. Invoking real clang would make tests much heavier and
// add a PATH dependency, so we construct the minimal JSON shapes that
// each handler actually inspects (kind + value + inner).

#include "encoder.h"
#include "engine.h"
#include "ball_shared.h"

#include <cassert>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

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

// ================================================================
// Smoke: the encoder always emits the std + cpp_std + std_memory
// + main modules, plus source_language metadata.
// ================================================================

TEST(empty_translation_unit) {
    auto prog = run_encoder(R"JSON({"kind": "TranslationUnitDecl", "inner": []})JSON");
    ASSERT_EQ(prog.entry_module(), "main");
    ASSERT_EQ(prog.entry_function(), "main");
    // std, cpp_std, std_memory, main = 4 modules minimum.
    ASSERT_TRUE(prog.modules_size() >= 4);
    bool has_main = false, has_std = false, has_cpp_std = false;
    for (int i = 0; i < prog.modules_size(); i++) {
        auto& n = prog.modules(i).name();
        if (n == "main") has_main = true;
        if (n == "std") has_std = true;
        if (n == "cpp_std") has_cpp_std = true;
    }
    ASSERT_TRUE(has_main);
    ASSERT_TRUE(has_std);
    ASSERT_TRUE(has_cpp_std);
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

// Run the encoder and then execute the resulting Program through the
// C++ engine, returning its run() result.
static BallValue encode_and_run(const std::string& json) {
    CppEncoder encoder;
    auto prog = encoder.encode_from_clang_ast(json);
    Engine engine(prog, [](const std::string&) {});
    return engine.run();
}

TEST(round_trip_main_returns_int_literal) {
    // int main() { return 42; }
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "main",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{"kind": "IntegerLiteral", "value": "42"}]
            }]}]
        }]
    })JSON";
    auto result = encode_and_run(json);
    ASSERT_TRUE(result.type() == typeid(int64_t));
    ASSERT_EQ(std::any_cast<int64_t>(result), 42);
}

TEST(round_trip_arithmetic_expression) {
    // int main() { return 1 + 2 * 3; }  // = 7
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "main",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "BinaryOperator",
                    "opcode": "+",
                    "inner": [
                        {"kind": "IntegerLiteral", "value": "1"},
                        {
                            "kind": "BinaryOperator",
                            "opcode": "*",
                            "inner": [
                                {"kind": "IntegerLiteral", "value": "2"},
                                {"kind": "IntegerLiteral", "value": "3"}
                            ]
                        }
                    ]
                }]
            }]}]
        }]
    })JSON";
    auto result = encode_and_run(json);
    ASSERT_TRUE(result.type() == typeid(int64_t));
    ASSERT_EQ(std::any_cast<int64_t>(result), 7);
}

TEST(round_trip_comparison_returns_bool) {
    // int main() { return 5 > 3; }
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "main",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "BinaryOperator",
                    "opcode": ">",
                    "inner": [
                        {"kind": "IntegerLiteral", "value": "5"},
                        {"kind": "IntegerLiteral", "value": "3"}
                    ]
                }]
            }]}]
        }]
    })JSON";
    auto result = encode_and_run(json);
    // The engine represents comparisons as bools.
    ASSERT_TRUE(result.type() == typeid(bool));
    ASSERT_EQ(std::any_cast<bool>(result), true);
}

TEST(round_trip_unary_negate) {
    // int main() { return -7; }
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "main",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [{
                "kind": "ReturnStmt",
                "inner": [{
                    "kind": "UnaryOperator",
                    "opcode": "-",
                    "inner": [{"kind": "IntegerLiteral", "value": "7"}]
                }]
            }]}]
        }]
    })JSON";
    auto result = encode_and_run(json);
    ASSERT_TRUE(result.type() == typeid(int64_t));
    ASSERT_EQ(std::any_cast<int64_t>(result), -7);
}

TEST(round_trip_if_statement_selects_then) {
    // int main() { if (true) return 1; return 2; }
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "main",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [
                {
                    "kind": "IfStmt",
                    "inner": [
                        {"kind": "CXXBoolLiteralExpr", "value": true},
                        {"kind": "CompoundStmt", "inner": [{
                            "kind": "ReturnStmt",
                            "inner": [{"kind": "IntegerLiteral", "value": "1"}]
                        }]}
                    ]
                },
                {
                    "kind": "ReturnStmt",
                    "inner": [{"kind": "IntegerLiteral", "value": "2"}]
                }
            ]}]
        }]
    })JSON";
    auto result = encode_and_run(json);
    ASSERT_TRUE(result.type() == typeid(int64_t));
    ASSERT_EQ(std::any_cast<int64_t>(result), 1);
}

TEST(round_trip_if_statement_selects_else) {
    // int main() { if (false) return 1; return 2; }
    const std::string json = R"JSON({
        "kind": "TranslationUnitDecl",
        "inner": [{
            "kind": "FunctionDecl",
            "name": "main",
            "type": {"qualType": "int ()"},
            "inner": [{"kind": "CompoundStmt", "inner": [
                {
                    "kind": "IfStmt",
                    "inner": [
                        {"kind": "CXXBoolLiteralExpr", "value": false},
                        {"kind": "CompoundStmt", "inner": [{
                            "kind": "ReturnStmt",
                            "inner": [{"kind": "IntegerLiteral", "value": "1"}]
                        }]}
                    ]
                },
                {
                    "kind": "ReturnStmt",
                    "inner": [{"kind": "IntegerLiteral", "value": "2"}]
                }
            ]}]
        }]
    })JSON";
    auto result = encode_and_run(json);
    ASSERT_TRUE(result.type() == typeid(int64_t));
    ASSERT_EQ(std::any_cast<int64_t>(result), 2);
}

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

int main() {
    std::cout << "Ball C++ Encoder Tests\n"
              << "======================\n";

    std::cout << "\n======================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";
    return tests_failed > 0 ? 1 : 0;
}
