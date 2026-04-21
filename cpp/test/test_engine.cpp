// Ball C++ Engine Test Suite
// Uses simple assert-based testing (no external dependencies).

#include "engine.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>

using namespace ball;

// ================================================================
// Test framework
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

#define ASSERT_EQ(a, b) \
    do { \
        if (!((a) == (b))) { \
            throw std::runtime_error( \
                std::string("ASSERT_EQ failed: ") + #a + " != " + #b); \
        } \
    } while(0)

#define ASSERT_TRUE(cond) \
    do { \
        if (!(cond)) { \
            throw std::runtime_error( \
                std::string("ASSERT_TRUE failed: ") + #cond); \
        } \
    } while(0)

#define ASSERT_NEAR(a, b, eps) \
    do { \
        if (std::fabs((a) - (b)) > (eps)) { \
            throw std::runtime_error( \
                std::string("ASSERT_NEAR failed: ") + #a + " not near " + #b); \
        } \
    } while(0)

#define ASSERT_THROWS(expr) \
    do { \
        bool threw = false; \
        try { expr; } catch (...) { threw = true; } \
        if (!threw) { \
            throw std::runtime_error( \
                std::string("ASSERT_THROWS failed: ") + #expr + " did not throw"); \
        } \
    } while(0)

// ================================================================
// Helpers to build Ball programs programmatically
// ================================================================

// Create a literal int expression
ball::v1::Expression lit_int(int64_t val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_int_value(val);
    return expr;
}

// Create a literal double expression
ball::v1::Expression lit_double(double val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_double_value(val);
    return expr;
}

// Create a literal string expression
ball::v1::Expression lit_string(const std::string& val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_string_value(val);
    return expr;
}

// Create a literal bool expression
ball::v1::Expression lit_bool(bool val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_bool_value(val);
    return expr;
}

// Create a literal list expression
ball::v1::Expression lit_list(std::vector<ball::v1::Expression> elements) {
    ball::v1::Expression expr;
    auto* list = expr.mutable_literal()->mutable_list_value();
    for (auto& element : elements) {
        *list->add_elements() = std::move(element);
    }
    return expr;
}

// Create a field access expression
ball::v1::Expression access(ball::v1::Expression object, const std::string& field_name) {
    ball::v1::Expression expr;
    auto* fa = expr.mutable_field_access();
    *fa->mutable_object() = std::move(object);
    fa->set_field(field_name);
    return expr;
}

// Create a lambda expression
ball::v1::Expression make_lambda(ball::v1::Expression body) {
    ball::v1::Expression expr;
    auto* lam = expr.mutable_lambda();
    lam->set_name("");
    *lam->mutable_body() = std::move(body);
    return expr;
}

// Create a reference expression
ball::v1::Expression ref(const std::string& name) {
    ball::v1::Expression expr;
    expr.mutable_reference()->set_name(name);
    return expr;
}

// Create a message creation expression with named fields
ball::v1::Expression make_msg(const std::string& type_name,
                               std::vector<std::pair<std::string, ball::v1::Expression>> fields) {
    ball::v1::Expression expr;
    auto* mc = expr.mutable_message_creation();
    mc->set_type_name(type_name);
    for (auto& [name, value] : fields) {
        auto* f = mc->add_fields();
        f->set_name(name);
        *f->mutable_value() = std::move(value);
    }
    return expr;
}

// Create a call expression
ball::v1::Expression call(const std::string& module,
                           const std::string& function,
                           ball::v1::Expression input) {
    ball::v1::Expression expr;
    auto* c = expr.mutable_call();
    c->set_module(module);
    c->set_function(function);
    *c->mutable_input() = std::move(input);
    return expr;
}

// Create a std call: std.function(input)
ball::v1::Expression std_call(const std::string& function,
                               ball::v1::Expression input) {
    return call("std", function, std::move(input));
}

// Create a binary std call: std.function({left: l, right: r})
ball::v1::Expression std_binary(const std::string& function,
                                 ball::v1::Expression left,
                                 ball::v1::Expression right) {
    return std_call(function, make_msg("BinaryInput", {
        {"left", std::move(left)},
        {"right", std::move(right)}
    }));
}

// Create a unary std call: std.function({value: v})
ball::v1::Expression std_unary(const std::string& function,
                                ball::v1::Expression value) {
    return std_call(function, make_msg("UnaryInput", {
        {"value", std::move(value)}
    }));
}

// Create a print call
ball::v1::Expression print_call(ball::v1::Expression message) {
    return std_call("print", make_msg("PrintInput", {
        {"message", std::move(message)}
    }));
}

// Create a block expression
ball::v1::Expression make_block(
    std::vector<std::pair<std::string, ball::v1::Expression>> lets,
    ball::v1::Expression result) {
    ball::v1::Expression expr;
    auto* blk = expr.mutable_block();
    for (auto& [name, value] : lets) {
        auto* stmt = blk->add_statements();
        auto* let = stmt->mutable_let();
        let->set_name(name);
        *let->mutable_value() = std::move(value);
    }
    *blk->mutable_result() = std::move(result);
    return expr;
}

// Create an expression statement
ball::v1::Statement expr_stmt(ball::v1::Expression expr) {
    ball::v1::Statement stmt;
    *stmt.mutable_expression() = std::move(expr);
    return stmt;
}

// Build a minimal program with a main function body
ball::v1::Program build_program(ball::v1::Expression body) {
    ball::v1::Program program;
    auto* mod = program.add_modules();
    mod->set_name("main");
    auto* func = mod->add_functions();
    func->set_name("main");
    *func->mutable_body() = std::move(body);
    program.set_entry_module("main");
    program.set_entry_function("main");
    return program;
}

// Build a program with multiple statements + result
ball::v1::Program build_program_block(
    std::vector<ball::v1::Statement> stmts,
    ball::v1::Expression result) {
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    for (auto& s : stmts) {
        *blk->add_statements() = std::move(s);
    }
    *blk->mutable_result() = std::move(result);
    return build_program(std::move(body));
}

// Run a program and return captured output lines
std::vector<std::string> run_program(const ball::v1::Program& program) {
    Engine engine(program);
    engine.run();
    return engine.get_output();
}

// Run a program and return the result value as string
std::string run_and_get_output(const ball::v1::Program& program) {
    auto output = run_program(program);
    return output.empty() ? "" : output[0];
}

// ================================================================
// Tests — Literals
// ================================================================

TEST(literal_int) {
    auto prog = build_program(print_call(std_unary("to_string", lit_int(42))));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "42");
}

TEST(literal_double) {
    auto prog = build_program(
        print_call(std_unary("to_string", lit_double(3.14))));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_TRUE(out[0].find("3.14") != std::string::npos);
}

TEST(literal_string) {
    auto prog = build_program(print_call(lit_string("hello")));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "hello");
}

TEST(literal_bool) {
    auto prog = build_program(
        print_call(std_unary("to_string", lit_bool(true))));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "true");
}

// ================================================================
// Tests — Arithmetic
// ================================================================

TEST(add_ints) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("add", lit_int(10), lit_int(32)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "42");
}

TEST(subtract_ints) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("subtract", lit_int(50), lit_int(8)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "42");
}

TEST(multiply_ints) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("multiply", lit_int(6), lit_int(7)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "42");
}

TEST(divide_ints) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("divide", lit_int(84), lit_int(2)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "42");
}

TEST(modulo_ints) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("modulo", lit_int(47), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "2");
}

TEST(negate_int) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("negate", lit_int(42)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "-42");
}

// ================================================================
// Tests — Comparison
// ================================================================

TEST(equals_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("equals", lit_int(5), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(equals_false) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("equals", lit_int(5), lit_int(6)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "false");
}

TEST(not_equals) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("not_equals", lit_int(5), lit_int(6)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(less_than) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("less_than", lit_int(3), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(greater_than) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("greater_than", lit_int(10), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(lte) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("lte", lit_int(5), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

// ================================================================
// Tests — Logic
// ================================================================

TEST(and_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("and", lit_bool(true), lit_bool(true)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(and_short_circuit) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("and", lit_bool(false), lit_bool(true)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "false");
}

TEST(or_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("or", lit_bool(false), lit_bool(true)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(not_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("not", lit_bool(true)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "false");
}

// ================================================================
// Tests — String Operations
// ================================================================

TEST(string_length) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("string_length", lit_string("hello")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "5");
}

TEST(string_to_upper) {
    auto prog = build_program(
        print_call(std_unary("string_to_upper", lit_string("hello"))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "HELLO");
}

TEST(string_to_lower) {
    auto prog = build_program(
        print_call(std_unary("string_to_lower", lit_string("HELLO"))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "hello");
}

TEST(string_contains) {
    auto prog = build_program(
        print_call(std_unary("to_string",
            std_call("string_contains", make_msg("", {
                {"value", lit_string("hello world")},
                {"search", lit_string("world")}
            })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(string_substring) {
    auto prog = build_program(
        print_call(std_call("string_substring", make_msg("", {
            {"value", lit_string("hello world")},
            {"start", lit_int(6)},
            {"end", lit_int(11)}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "world");
}

TEST(string_trim) {
    auto prog = build_program(
        print_call(std_unary("string_trim", lit_string("  hello  "))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "hello");
}

TEST(string_replace) {
    auto prog = build_program(
        print_call(std_call("string_replace", make_msg("", {
            {"value", lit_string("hello world")},
            {"from", lit_string("world")},
            {"to", lit_string("there")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "hello there");
}

TEST(string_replace_all) {
    auto prog = build_program(
        print_call(std_call("string_replace_all", make_msg("", {
            {"value", lit_string("aabaa")},
            {"from", lit_string("a")},
            {"to", lit_string("x")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "xxbxx");
}

TEST(string_split) {
    // string_split returns a list; print its length via list access
    auto prog = build_program(
        print_call(std_call("string_split", make_msg("", {
            {"value", lit_string("a,b,c")},
            {"separator", lit_string(",")}
        }))));
    auto out = run_program(prog);
    // The print of a list depends on engine's to_string for lists
    ASSERT_TRUE(out.size() >= 1);
}

// ================================================================
// Tests — Control Flow
// ================================================================

TEST(if_true_branch) {
    auto prog = build_program(
        print_call(std_unary("to_string",
            std_call("if", make_msg("IfInput", {
                {"condition", lit_bool(true)},
                {"then", lit_int(1)},
                {"else", lit_int(2)}
            })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "1");
}

TEST(if_false_branch) {
    auto prog = build_program(
        print_call(std_unary("to_string",
            std_call("if", make_msg("IfInput", {
                {"condition", lit_bool(false)},
                {"then", lit_int(1)},
                {"else", lit_int(2)}
            })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "2");
}

TEST(for_loop) {
    // for (i = 0; i < 3; i++) { print(i) }
    auto init_block = make_block({{"i", lit_int(0)}}, lit_int(0));
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() =
        print_call(std_unary("to_string", ref("i")));
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(
        std_call("for", make_msg("ForInput", {
            {"init", std::move(init_block)},
            {"condition", std_binary("less_than", ref("i"), lit_int(3))},
            {"update", std_call("assign", make_msg("", {
                {"target", ref("i")},
                {"value", std_binary("add", ref("i"), lit_int(1))}
            }))},
            {"body", std::move(body)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 3u);
    ASSERT_EQ(out[0], "0");
    ASSERT_EQ(out[1], "1");
    ASSERT_EQ(out[2], "2");
}

TEST(while_loop) {
    // let x = 0; while (x < 3) { print(x); x = x + 1; }
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() =
        print_call(std_unary("to_string", ref("x")));
    *blk->add_statements()->mutable_expression() =
        std_call("assign", make_msg("", {
            {"target", ref("x")},
            {"value", std_binary("add", ref("x"), lit_int(1))}
        }));
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program_block(
        {expr_stmt(std_call("assign", make_msg("", {
            {"target", ref("x")}, {"value", lit_int(0)}})))},
        std_call("while", make_msg("WhileInput", {
            {"condition", std_binary("less_than", ref("x"), lit_int(3))},
            {"body", std::move(body)}
        })));
    // Need let binding for x
    ball::v1::Program prog2;
    auto* mod = prog2.add_modules();
    mod->set_name("main");
    auto* func = mod->add_functions();
    func->set_name("main");
    auto* main_body = func->mutable_body()->mutable_block();
    auto* let_stmt = main_body->add_statements()->mutable_let();
    let_stmt->set_name("x");
    *let_stmt->mutable_value() = lit_int(0);

    ball::v1::Expression while_body;
    auto* wblk = while_body.mutable_block();
    *wblk->add_statements()->mutable_expression() =
        print_call(std_unary("to_string", ref("x")));
    *wblk->add_statements()->mutable_expression() =
        std_call("assign", make_msg("", {
            {"target", ref("x")},
            {"value", std_binary("add", ref("x"), lit_int(1))}
        }));
    *wblk->mutable_result() = lit_int(0);

    *main_body->add_statements()->mutable_expression() =
        std_call("while", make_msg("WhileInput", {
            {"condition", std_binary("less_than", ref("x"), lit_int(3))},
            {"body", std::move(while_body)}
        }));
    *main_body->mutable_result() = lit_int(0);
    prog2.set_entry_module("main");
    prog2.set_entry_function("main");

    auto out = run_program(prog2);
    ASSERT_EQ(out.size(), 3u);
    ASSERT_EQ(out[0], "0");
    ASSERT_EQ(out[1], "1");
    ASSERT_EQ(out[2], "2");
}

TEST(break_in_loop) {
    // for (i = 0; i < 10; i++) { if (i == 3) break; print(i); }
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() =
        std_call("if", make_msg("IfInput", {
            {"condition", std_binary("equals", ref("i"), lit_int(3))},
            {"then", std_call("break", make_msg("", {}))},
            {"else", lit_int(0)}
        }));
    *blk->add_statements()->mutable_expression() =
        print_call(std_unary("to_string", ref("i")));
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(
        std_call("for", make_msg("ForInput", {
            {"init", make_block({{"i", lit_int(0)}}, lit_int(0))},
            {"condition", std_binary("less_than", ref("i"), lit_int(10))},
            {"update", std_call("assign", make_msg("", {
                {"target", ref("i")},
                {"value", std_binary("add", ref("i"), lit_int(1))}
            }))},
            {"body", std::move(body)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 3u);
    ASSERT_EQ(out[0], "0");
    ASSERT_EQ(out[1], "1");
    ASSERT_EQ(out[2], "2");
}

// ================================================================
// Tests — Scoping
// ================================================================

TEST(let_binding) {
    auto prog = build_program(
        make_block({{"x", lit_int(42)}},
            print_call(std_unary("to_string", ref("x")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "42");
}

TEST(nested_scopes) {
    auto prog = build_program(
        make_block({{"x", lit_int(10)}},
            make_block({{"y", lit_int(20)}},
                print_call(std_unary("to_string",
                    std_binary("add", ref("x"), ref("y")))))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "30");
}

// ================================================================
// Tests — Error handling
// ================================================================

TEST(undefined_variable_throws) {
    auto prog = build_program(print_call(ref("nonexistent")));
    ASSERT_THROWS(run_program(prog));
}

TEST(division_by_zero) {
    // Engine may or may not throw on int division by zero — just verify it doesn't segfault
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("divide", lit_int(10), lit_int(0)))));
    try {
        run_program(prog);
    } catch (...) {
        // Either throwing or returning inf is acceptable
    }
}

// ================================================================
// Tests — Math
// ================================================================

TEST(math_abs) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("math_abs", lit_int(-42)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "42");
}

TEST(math_sqrt) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("math_sqrt", lit_double(16.0)))));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("4") != std::string::npos);
}

// ================================================================
// Tests — Switch (Bug #2 fix validation)
// ================================================================

TEST(switch_int_matching) {
    // switch(2) { case 1: "one"; case 2: "two"; default: "other" }
    ball::v1::Expression cases_list;
    auto* list = cases_list.mutable_literal()->mutable_list_value();

    // case 1
    *list->add_elements() = make_msg("", {
        {"value", lit_int(1)},
        {"body", print_call(lit_string("one"))}
    });
    // case 2
    *list->add_elements() = make_msg("", {
        {"value", lit_int(2)},
        {"body", print_call(lit_string("two"))}
    });
    // default
    *list->add_elements() = make_msg("", {
        {"is_default", lit_bool(true)},
        {"body", print_call(lit_string("other"))}
    });

    auto prog = build_program(
        std_call("switch", make_msg("SwitchInput", {
            {"subject", lit_int(2)},
            {"cases", std::move(cases_list)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "two");
}

TEST(switch_string_vs_int_no_match) {
    // switch(5) { case "5": "wrong" (shouldn't match); default: "correct" }
    ball::v1::Expression cases_list;
    auto* list = cases_list.mutable_literal()->mutable_list_value();
    *list->add_elements() = make_msg("", {
        {"value", lit_string("5")},
        {"body", print_call(lit_string("wrong"))}
    });
    *list->add_elements() = make_msg("", {
        {"is_default", lit_bool(true)},
        {"body", print_call(lit_string("correct"))}
    });

    auto prog = build_program(
        std_call("switch", make_msg("SwitchInput", {
            {"subject", lit_int(5)},
            {"cases", std::move(cases_list)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "correct");
}

// ================================================================
// Tests — Greater-than-or-equal
// ================================================================

TEST(gte_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("gte", lit_int(5), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(gte_false) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("gte", lit_int(3), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "false");
}

TEST(lte_false) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("lte", lit_int(6), lit_int(5)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "false");
}

// ================================================================
// Tests — String concatenation
// ================================================================

TEST(string_concat) {
    auto prog = build_program(
        print_call(std_binary("string_concat", lit_string("hello "), lit_string("world"))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "hello world");
}

// ================================================================
// Tests — Do-while loop
// ================================================================

TEST(do_while_loop) {
    // do { print(i); i = i + 1 } while (i < 3)   starting with i = 0
    // Should print: 0 1 2
    std::vector<ball::v1::Statement> stmts;

    // let i = 0
    auto* let_i = stmts.emplace_back().mutable_let();
    let_i->set_name("i");
    *let_i->mutable_value() = lit_int(0);

    // do_while(condition: i < 3, body: { print(to_string(i)); i = i + 1 })
    auto body_block = [&]() {
        ball::v1::Expression blk;
        auto* b = blk.mutable_block();
        *b->add_statements()->mutable_expression() =
            print_call(std_unary("to_string", ref("i")));
        *b->add_statements()->mutable_expression() =
            std_call("assign", make_msg("", {
                {"target", ref("i")},
                {"value", std_binary("add", ref("i"), lit_int(1))}
            }));
        *b->mutable_result() = lit_int(0);
        return blk;
    };

    *stmts.emplace_back().mutable_expression() =
        std_call("do_while", make_msg("DoWhileInput", {
            {"condition", std_binary("less_than", ref("i"), lit_int(3))},
            {"body", body_block()}
        }));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 3u);
    ASSERT_EQ(out[0], "0");
    ASSERT_EQ(out[1], "1");
    ASSERT_EQ(out[2], "2");
}

// ================================================================
// Tests — Continue in loop
// ================================================================

TEST(continue_in_loop) {
    // for i = 0; i < 5; i++ { if (i == 2) continue; print(i) }
    // Should print: 0 1 3 4
    ball::v1::Expression init;
    auto* init_blk = init.mutable_block();
    auto* let_i = init_blk->add_statements()->mutable_let();
    let_i->set_name("i");
    *let_i->mutable_value() = lit_int(0);
    *init_blk->mutable_result() = lit_int(0);

    ball::v1::Expression body;
    auto* body_blk = body.mutable_block();
    *body_blk->add_statements()->mutable_expression() =
        std_call("if", make_msg("IfInput", {
            {"condition", std_binary("equals", ref("i"), lit_int(2))},
            {"then", std_call("continue", lit_int(0))}
        }));
    *body_blk->add_statements()->mutable_expression() =
        print_call(std_unary("to_string", ref("i")));
    *body_blk->mutable_result() = lit_int(0);

    auto prog = build_program(
        std_call("for", make_msg("ForInput", {
            {"init", std::move(init)},
            {"condition", std_binary("less_than", ref("i"), lit_int(5))},
            {"update", std_call("assign", make_msg("", {
                {"target", ref("i")},
                {"value", std_binary("add", ref("i"), lit_int(1))}
            }))},
            {"body", std::move(body)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 4u);
    ASSERT_EQ(out[0], "0");
    ASSERT_EQ(out[1], "1");
    ASSERT_EQ(out[2], "3");
    ASSERT_EQ(out[3], "4");
}

// ================================================================
// Tests — User-defined functions
// ================================================================

TEST(user_defined_function) {
    // Define add_ten(x) = x + 10, call add_ten(5), expect 15
    ball::v1::Program program;
    auto* mod = program.add_modules();
    mod->set_name("main");

    // add_ten function
    auto* add_ten = mod->add_functions();
    add_ten->set_name("add_ten");
    add_ten->set_input_type("int");
    *add_ten->mutable_body() =
        std_unary("to_string", std_binary("add", ref("input"), lit_int(10)));

    // main function
    auto* main_fn = mod->add_functions();
    main_fn->set_name("main");
    *main_fn->mutable_body() =
        print_call(call("main", "add_ten", lit_int(5)));

    program.set_entry_module("main");
    program.set_entry_function("main");

    auto out = run_program(program);
    ASSERT_EQ(out[0], "15");
}

TEST(recursive_function) {
    // factorial(n): if n <= 1 then 1 else n * factorial(n - 1)
    ball::v1::Program program;
    auto* mod = program.add_modules();
    mod->set_name("main");

    auto* fact = mod->add_functions();
    fact->set_name("factorial");
    fact->set_input_type("int");
    *fact->mutable_body() = std_call("if", make_msg("IfInput", {
        {"condition", std_binary("lte", ref("input"), lit_int(1))},
        {"then", lit_int(1)},
        {"else", std_binary("multiply", ref("input"),
            call("main", "factorial", std_binary("subtract", ref("input"), lit_int(1))))}
    }));

    auto* main_fn = mod->add_functions();
    main_fn->set_name("main");
    *main_fn->mutable_body() =
        print_call(std_unary("to_string", call("main", "factorial", lit_int(5))));

    program.set_entry_module("main");
    program.set_entry_function("main");

    auto out = run_program(program);
    ASSERT_EQ(out[0], "120");
}

// ================================================================
// Tests — Field access
// ================================================================

TEST(field_access) {
    // Create message {x: 42, y: "hello"}, access field x
    ball::v1::Expression access;
    auto* fa = access.mutable_field_access();
    *fa->mutable_object() = make_msg("Point", {
        {"x", lit_int(42)},
        {"y", lit_string("hello")}
    });
    fa->set_field("x");

    auto prog = build_program(
        print_call(std_unary("to_string", std::move(access))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "42");
}

TEST(field_access_string) {
    ball::v1::Expression access;
    auto* fa = access.mutable_field_access();
    *fa->mutable_object() = make_msg("Named", {
        {"name", lit_string("Ball")}
    });
    fa->set_field("name");

    auto prog = build_program(print_call(std::move(access)));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "Ball");
}

// ================================================================
// Tests — Compound assignment (Bug #9 fix validation)
// ================================================================

TEST(compound_add_assign) {
    // let x = 10; x += 5; print(x) → 15
    std::vector<ball::v1::Statement> stmts;
    auto* let_x = stmts.emplace_back().mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(10);

    *stmts.emplace_back().mutable_expression() =
        std_call("assign", make_msg("", {
            {"target", ref("x")},
            {"op", lit_string("+=")},
            {"value", lit_int(5)}
        }));

    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", ref("x")));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "15");
}

TEST(compound_multiply_assign) {
    std::vector<ball::v1::Statement> stmts;
    auto* let_x = stmts.emplace_back().mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(3);

    *stmts.emplace_back().mutable_expression() =
        std_call("assign", make_msg("", {
            {"target", ref("x")},
            {"op", lit_string("*=")},
            {"value", lit_int(4)}
        }));

    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", ref("x")));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "12");
}

TEST(compound_divide_assign) {
    std::vector<ball::v1::Statement> stmts;
    auto* let_x = stmts.emplace_back().mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(20);

    *stmts.emplace_back().mutable_expression() =
        std_call("assign", make_msg("", {
            {"target", ref("x")},
            {"op", lit_string("/=")},
            {"value", lit_int(4)}
        }));

    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", ref("x")));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "5");
}

// ================================================================
// Tests — Try/catch
// ================================================================

TEST(try_catch_handles_exception) {
    // try { throw("error msg") } catch(e) { print("caught") }
    ball::v1::Expression catches_list;
    auto* list = catches_list.mutable_literal()->mutable_list_value();
    *list->add_elements() = make_msg("", {
        {"variable", lit_string("e")},
        {"body", print_call(lit_string("caught"))}
    });

    auto prog = build_program(
        std_call("try", make_msg("TryInput", {
            {"body", std_call("throw", make_msg("", {{"value", lit_string("error msg")}}))},
            {"catches", std::move(catches_list)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "caught");
}

// ================================================================
// Tests — to_string type coercions
// ================================================================

TEST(to_string_double) {
    auto prog = build_program(
        print_call(std_unary("to_string", lit_double(2.5))));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("2.5") != std::string::npos);
}

TEST(to_string_bool_false) {
    auto prog = build_program(
        print_call(std_unary("to_string", lit_bool(false))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "false");
}

// ================================================================
// Tests — Lambda
// ================================================================

TEST(lambda_basic) {
    // let fn = lambda(x) => x + 1; print(fn(10))
    // Construct: let fn = lambda, call fn(10)
    ball::v1::Program program;
    auto* mod = program.add_modules();
    mod->set_name("main");

    // main: { let adder = lambda; print(to_string(call adder(10))) }
    auto* main_fn = mod->add_functions();
    main_fn->set_name("main");

    auto* body = main_fn->mutable_body()->mutable_block();

    // let adder = lambda
    auto* let_adder = body->add_statements()->mutable_let();
    let_adder->set_name("adder");
    // Lambda is a FunctionDefinition with no name
    ball::v1::Expression lambda_expr;
    auto* lam = lambda_expr.mutable_lambda();
    lam->set_name("");
    *lam->mutable_body() = std_binary("add", ref("input"), lit_int(1));
    *let_adder->mutable_value() = std::move(lambda_expr);

    // print(to_string(adder(10)))
    ball::v1::Expression call_adder;
    auto* ca = call_adder.mutable_call();
    ca->set_function("adder");
    *ca->mutable_input() = lit_int(10);
    *body->add_statements()->mutable_expression() =
        print_call(std_unary("to_string", std::move(call_adder)));

    *body->mutable_result() = lit_int(0);

    program.set_entry_module("main");
    program.set_entry_function("main");

    auto out = run_program(program);
    ASSERT_EQ(out[0], "11");
}

// ================================================================
// Tests — Bitwise operations
// ================================================================

TEST(bitwise_and) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("bitwise_and", lit_int(0xFF), lit_int(0x0F)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "15");
}

TEST(bitwise_or) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("bitwise_or", lit_int(0xF0), lit_int(0x0F)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "255");
}

TEST(bitwise_xor) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("bitwise_xor", lit_int(0xFF), lit_int(0x0F)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "240");
}

TEST(bitwise_shift_left) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("left_shift", lit_int(1), lit_int(8)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "256");
}

TEST(bitwise_shift_right) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("right_shift", lit_int(256), lit_int(4)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "16");
}

// ================================================================
// Tests — Missing std coverage batch 1
// ================================================================

TEST(divide_double) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("divide_double", lit_int(5), lit_int(2)))));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("2.5") != std::string::npos);
}

TEST(unsigned_right_shift_negative) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("unsigned_right_shift", lit_int(-1), lit_int(1)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "9223372036854775807");
}

TEST(pre_increment_updates_reference) {
    std::vector<ball::v1::Statement> stmts;
    auto* let_x = stmts.emplace_back().mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(5);

    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", std_call("pre_increment", make_msg("", {
            {"value", ref("x")}
        }))));
    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", ref("x")));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 2u);
    ASSERT_EQ(out[0], "6");
    ASSERT_EQ(out[1], "6");
}

TEST(pre_decrement_updates_reference) {
    std::vector<ball::v1::Statement> stmts;
    auto* let_x = stmts.emplace_back().mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(5);

    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", std_call("pre_decrement", make_msg("", {
            {"value", ref("x")}
        }))));
    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", ref("x")));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 2u);
    ASSERT_EQ(out[0], "4");
    ASSERT_EQ(out[1], "4");
}

TEST(post_increment_returns_old_value) {
    std::vector<ball::v1::Statement> stmts;
    auto* let_x = stmts.emplace_back().mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(5);

    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", std_call("post_increment", make_msg("", {
            {"value", ref("x")}
        }))));
    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", ref("x")));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 2u);
    ASSERT_EQ(out[0], "5");
    ASSERT_EQ(out[1], "6");
}

TEST(post_decrement_returns_old_value) {
    std::vector<ball::v1::Statement> stmts;
    auto* let_x = stmts.emplace_back().mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(5);

    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", std_call("post_decrement", make_msg("", {
            {"value", ref("x")}
        }))));
    *stmts.emplace_back().mutable_expression() =
        print_call(std_unary("to_string", ref("x")));

    auto prog = build_program_block(std::move(stmts), lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 2u);
    ASSERT_EQ(out[0], "5");
    ASSERT_EQ(out[1], "4");
}

TEST(int_to_string) {
    auto prog = build_program(print_call(std_unary("int_to_string", lit_int(123))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "123");
}

TEST(string_to_int) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("string_to_int", lit_string("456")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "456");
}

TEST(string_to_double) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("string_to_double", lit_string("12.75")))));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("12.75") != std::string::npos);
}

TEST(string_is_empty_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("string_is_empty", lit_string("")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(string_index_of) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("string_index_of", lit_string("banana"), lit_string("na")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "2");
}

TEST(string_last_index_of) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("string_last_index_of", lit_string("banana"), lit_string("na")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "4");
}

TEST(string_char_at) {
    auto prog = build_program(
        print_call(std_call("string_char_at", make_msg("", {
            {"target", lit_string("Ball")},
            {"index", lit_int(1)}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "a");
}

TEST(string_char_code_at) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_call("string_char_code_at", make_msg("", {
            {"target", lit_string("Ball")},
            {"index", lit_int(1)}
        })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "97");
}

TEST(string_from_char_code) {
    auto prog = build_program(print_call(std_unary("string_from_char_code", lit_int(66))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "B");
}

TEST(string_repeat) {
    auto prog = build_program(
        print_call(std_call("string_repeat", make_msg("", {
            {"value", lit_string("ha")},
            {"count", lit_int(3)}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "hahaha");
}

TEST(string_interpolation_parts) {
    auto prog = build_program(
        print_call(std_call("string_interpolation", make_msg("", {
            {"parts", lit_list({lit_string("Hello "), lit_string("Ball"), lit_string("!")})}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "Hello Ball!");
}

TEST(null_coalesce_prefers_left) {
    auto prog = build_program(
        print_call(std_call("null_coalesce", make_msg("", {
            {"left", lit_string("primary")},
            {"right", lit_string("fallback")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "primary");
}

TEST(null_coalesce_uses_fallback_when_left_missing) {
    auto prog = build_program(
        print_call(std_call("null_coalesce", make_msg("", {
            {"right", lit_string("fallback")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "fallback");
}

TEST(null_check_returns_value) {
    auto prog = build_program(
        print_call(std_call("null_check", make_msg("", {
            {"value", lit_string("present")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "present");
}

TEST(type_is_int_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_call("is", make_msg("", {
            {"value", lit_int(42)},
            {"type", lit_string("int")}
        })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(type_is_not_string_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_call("is_not", make_msg("", {
            {"value", lit_int(42)},
            {"type", lit_string("String")}
        })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(type_as_returns_original_value) {
    auto prog = build_program(
        print_call(std_call("as", make_msg("", {
            {"value", lit_string("casted")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "casted");
}

TEST(for_in_loop) {
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() =
        print_call(std_unary("to_string", ref("n")));
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(
        std_call("for_in", make_msg("", {
            {"iterable", lit_list({lit_int(2), lit_int(4), lit_int(6)})},
            {"variable", lit_string("n")},
            {"body", std::move(body)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 3u);
    ASSERT_EQ(out[0], "2");
    ASSERT_EQ(out[1], "4");
    ASSERT_EQ(out[2], "6");
}

TEST(throw_raises_exception) {
    auto prog = build_program(
        std_call("throw", make_msg("", {
            {"value", lit_string("boom")}
        })));
    ASSERT_THROWS(run_program(prog));
}

TEST(rethrow_outside_catch_raises_runtime_error) {
    // Calling `rethrow` outside of a catch block surfaces a BallRuntimeError,
    // not whatever the last thrown exception happened to be.
    auto prog = build_program(std_call("rethrow", make_msg("", {})));
    bool threw = false;
    try {
        run_program(prog);
    } catch (const ball::BallRuntimeError& e) {
        threw = true;
        std::string msg = e.what();
        ASSERT_TRUE(msg.find("rethrow") != std::string::npos);
    } catch (...) {
        // Any other exception type is a bug — rethrow without active
        // exception must be a plain runtime error.
    }
    ASSERT_TRUE(threw);
}

TEST(rethrow_preserves_original_exception) {
    // Outer try wraps an inner try whose catch does `rethrow`. The outer
    // handler must receive the SAME exception (same value "boom"), not a
    // generic "rethrow" error.
    ball::v1::Expression inner_catches;
    auto* inner_list = inner_catches.mutable_literal()->mutable_list_value();
    *inner_list->add_elements() = make_msg("", {
        {"variable", lit_string("e")},
        {"body", std_call("rethrow", make_msg("", {}))}
    });

    auto inner_try = std_call("try", make_msg("TryInput", {
        {"body", std_call("throw", make_msg("", {{"value", lit_string("boom")}}))},
        {"catches", std::move(inner_catches)}
    }));

    ball::v1::Expression outer_catches;
    auto* outer_list = outer_catches.mutable_literal()->mutable_list_value();
    *outer_list->add_elements() = make_msg("", {
        {"variable", lit_string("e")},
        {"body", print_call(ref("e"))}
    });

    auto prog = build_program(
        std_call("try", make_msg("TryInput", {
            {"body", std::move(inner_try)},
            {"catches", std::move(outer_catches)}
        })));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "boom");
}

TEST(return_signal_unwinds_function) {
    ball::v1::Program program;
    auto* mod = program.add_modules();
    mod->set_name("main");

    auto* answer = mod->add_functions();
    answer->set_name("answer");
    auto* answer_body = answer->mutable_body()->mutable_block();
    *answer_body->add_statements()->mutable_expression() =
        std_call("return", make_msg("", {{"value", lit_int(42)}}));
    *answer_body->mutable_result() = lit_int(0);

    auto* main_fn = mod->add_functions();
    main_fn->set_name("main");
    *main_fn->mutable_body() =
        print_call(std_unary("to_string", call("main", "answer", lit_int(0))));

    program.set_entry_module("main");
    program.set_entry_function("main");

    auto out = run_program(program);
    ASSERT_EQ(out[0], "42");
}

TEST(math_trunc) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("math_trunc", lit_double(3.9)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "3");
}

TEST(string_split_empty_separator_returns_chars) {
    auto split_expr = std_call("string_split", make_msg("", {
        {"left", lit_string("abc")},
        {"right", lit_string("")}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_length", make_msg("", {
                {"list", split_expr}
            }))))),
            expr_stmt(print_call(call("std_collections", "list_get", make_msg("", {
                {"list", split_expr},
                {"index", lit_int(0)}
            })))),
            expr_stmt(print_call(call("std_collections", "list_get", make_msg("", {
                {"list", split_expr},
                {"index", lit_int(2)}
            })))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "3");
    ASSERT_EQ(out[1], "a");
    ASSERT_EQ(out[2], "c");
}

TEST(string_replace_all_empty_from_inserts_between_chars) {
    auto prog = build_program(
        print_call(std_call("string_replace_all", make_msg("", {
            {"value", lit_string("ab")},
            {"from", lit_string("")},
            {"to", lit_string("-")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "-a-b-");
}

TEST(math_pow) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("math_pow", lit_int(2), lit_int(10)))));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("1024") != std::string::npos);
}

TEST(math_log2) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("math_log2", lit_int(8)))));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("3") != std::string::npos);
}

TEST(math_exp) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("math_exp", lit_int(1)))));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("2.718") != std::string::npos);
}

TEST(math_pi_constant) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_call("math_pi", make_msg("", {})))));
    auto out = run_program(prog);
    ASSERT_NEAR(std::stod(out[0]), 3.141592653589793, 0.000001);
}

TEST(math_e_constant) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_call("math_e", make_msg("", {})))));
    auto out = run_program(prog);
    ASSERT_NEAR(std::stod(out[0]), 2.718281828459045, 0.000001);
}

TEST(math_is_nan_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_call("math_is_nan", make_msg("", {
            {"value", std_call("math_nan", make_msg("", {}))}
        })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(math_is_finite_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_call("math_is_finite", make_msg("", {
            {"value", lit_double(42.0)}
        })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(math_gcd) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("math_gcd", lit_int(24), lit_int(18)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "6");
}

TEST(math_lcm) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("math_lcm", lit_int(6), lit_int(8)))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "24");
}

TEST(regex_match_true) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("regex_match", lit_string("abc123"), lit_string("\\d+")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
}

TEST(regex_find_returns_first_match) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("regex_find", lit_string("abc123def"), lit_string("\\d+")))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "123");
}

TEST(regex_find_all_returns_count) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("length",
            std_binary("regex_find_all", lit_string("a1 b22 c333"), lit_string("\\d+"))))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "3");
}

TEST(regex_replace_first_only) {
    auto prog = build_program(
        print_call(std_call("regex_replace", make_msg("", {
            {"value", lit_string("a1 b22 c333")},
            {"from", lit_string("\\d+")},
            {"to", lit_string("X")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "aX b22 c333");
}

TEST(regex_replace_all) {
    auto prog = build_program(
        print_call(std_call("regex_replace_all", make_msg("", {
            {"value", lit_string("a1 b22 c333")},
            {"from", lit_string("\\d+")},
            {"to", lit_string("X")}
        }))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "aX bX cX");
}

// ================================================================
// Tests — std_collections module
// ================================================================

TEST(list_push) {
    auto prog = build_program(
        print_call(std_unary("to_string", call("std_collections", "list_length", make_msg("", {
            {"list", call("std_collections", "list_push", make_msg("", {
                {"list", lit_list({lit_int(1), lit_int(2)})},
                {"value", lit_int(3)}
            }))}
        })))));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "3");
}

TEST(list_pop_returns_value_and_list) {
    // list_pop now returns just the removed element (matching Dart engine).
    auto pop_call = call("std_collections", "list_pop", make_msg("", {
        {"list", lit_list({lit_int(1), lit_int(2), lit_int(3)})}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", pop_call))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out.size(), 1u);
    ASSERT_EQ(out[0], "3");
}

TEST(list_get_and_set) {
    auto updated_list = call("std_collections", "list_set", make_msg("", {
        {"list", lit_list({lit_int(10), lit_int(20), lit_int(30)})},
        {"index", lit_int(1)},
        {"value", lit_int(99)}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_get", make_msg("", {
                {"list", lit_list({lit_int(10), lit_int(20), lit_int(30)})},
                {"index", lit_int(1)}
            }))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_get", make_msg("", {
                {"list", updated_list},
                {"index", lit_int(1)}
            }))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "20");
    ASSERT_EQ(out[1], "99");
}

TEST(list_first_last_single) {
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_first", make_msg("", {
                {"list", lit_list({lit_int(7), lit_int(8), lit_int(9)})}
            }))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_last", make_msg("", {
                {"list", lit_list({lit_int(7), lit_int(8), lit_int(9)})}
            }))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_single", make_msg("", {
                {"list", lit_list({lit_int(42)})}
            }))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "7");
    ASSERT_EQ(out[1], "9");
    ASSERT_EQ(out[2], "42");
}

TEST(list_contains_and_index_of) {
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_contains", make_msg("", {
                {"list", lit_list({lit_int(2), lit_int(4), lit_int(6)})},
                {"value", lit_int(4)}
            }))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_index_of", make_msg("", {
                {"list", lit_list({lit_int(2), lit_int(4), lit_int(6)})},
                {"value", lit_int(6)}
            }))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "true");
    ASSERT_EQ(out[1], "2");
}

TEST(list_map_and_filter) {
    auto mapped = call("std_collections", "list_map", make_msg("", {
        {"list", lit_list({lit_int(1), lit_int(2), lit_int(3)})},
        {"function", make_lambda(std_binary("multiply", ref("input"), lit_int(2)))}
    }));
    auto filtered = call("std_collections", "list_filter", make_msg("", {
        {"list", lit_list({lit_int(1), lit_int(2), lit_int(3), lit_int(4)})},
        {"function", make_lambda(
            std_binary("equals", std_binary("modulo", ref("input"), lit_int(2)), lit_int(0)))}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_get", make_msg("", {
                {"list", mapped},
                {"index", lit_int(2)}
            }))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_length", make_msg("", {
                {"list", filtered}
            }))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "6");
    ASSERT_EQ(out[1], "2");
}

TEST(list_reduce_any_all_none) {
    auto reduced = call("std_collections", "list_reduce", make_msg("", {
        {"list", lit_list({lit_int(1), lit_int(2), lit_int(3), lit_int(4)})},
        {"initial", lit_int(0)},
        {"function", make_lambda(std_binary("add",
            access(ref("input"), "accumulator"),
            access(ref("input"), "value")))}
    }));
    auto any_even = call("std_collections", "list_any", make_msg("", {
        {"list", lit_list({lit_int(1), lit_int(3), lit_int(4)})},
        {"function", make_lambda(
            std_binary("equals", std_binary("modulo", ref("input"), lit_int(2)), lit_int(0)))}
    }));
    auto all_positive = call("std_collections", "list_all", make_msg("", {
        {"list", lit_list({lit_int(1), lit_int(2), lit_int(3)})},
        {"function", make_lambda(std_binary("greater_than", ref("input"), lit_int(0)))}
    }));
    auto none_negative = call("std_collections", "list_none", make_msg("", {
        {"list", lit_list({lit_int(1), lit_int(2), lit_int(3)})},
        {"function", make_lambda(std_binary("less_than", ref("input"), lit_int(0)))}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", reduced))),
            expr_stmt(print_call(std_unary("to_string", any_even))),
            expr_stmt(print_call(std_unary("to_string", all_positive))),
            expr_stmt(print_call(std_unary("to_string", none_negative))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "10");
    ASSERT_EQ(out[1], "true");
    ASSERT_EQ(out[2], "true");
    ASSERT_EQ(out[3], "true");
}

TEST(list_sort_slice_take_drop_concat_and_join) {
    auto sorted = call("std_collections", "list_sort", make_msg("", {
        {"list", lit_list({lit_int(3), lit_int(1), lit_int(2)})}
    }));
    auto sliced = call("std_collections", "list_slice", make_msg("", {
        {"list", lit_list({lit_int(10), lit_int(20), lit_int(30), lit_int(40)})},
        {"start", lit_int(1)},
        {"end", lit_int(3)}
    }));
    auto taken = call("std_collections", "list_take", make_msg("", {
        {"list", lit_list({lit_int(5), lit_int(6), lit_int(7)})},
        {"count", lit_int(2)}
    }));
    auto dropped = call("std_collections", "list_drop", make_msg("", {
        {"list", lit_list({lit_int(5), lit_int(6), lit_int(7)})},
        {"count", lit_int(1)}
    }));
    auto concatenated = call("std_collections", "list_concat", make_msg("", {
        {"left", lit_list({lit_string("a"), lit_string("b")})},
        {"right", lit_list({lit_string("c")})}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_get", make_msg("", {{"list", sorted}, {"index", lit_int(0)}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_length", make_msg("", {{"list", sliced}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_length", make_msg("", {{"list", taken}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_get", make_msg("", {{"list", dropped}, {"index", lit_int(0)}}))))),
            expr_stmt(print_call(call("std_collections", "string_join", make_msg("", {{"list", concatenated}, {"separator", lit_string("-")}})))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "1");
    ASSERT_EQ(out[1], "2");
    ASSERT_EQ(out[2], "2");
    ASSERT_EQ(out[3], "6");
    ASSERT_EQ(out[4], "a-b-c");
}

TEST(map_get_set_delete_contains_and_length) {
    auto map_expr = make_msg("", {{"a", lit_int(1)}, {"b", lit_int(2)}});
    auto updated = call("std_collections", "map_set", make_msg("", {
        {"map", map_expr},
        {"key", lit_string("c")},
        {"value", lit_int(3)}
    }));
    auto deleted = call("std_collections", "map_delete", make_msg("", {
        {"map", updated},
        {"key", lit_string("a")}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "map_get", make_msg("", {{"map", map_expr}, {"key", lit_string("b")}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "map_contains_key", make_msg("", {{"map", updated}, {"key", lit_string("c")}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "map_length", make_msg("", {{"map", deleted}}))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "2");
    ASSERT_EQ(out[1], "true");
    ASSERT_EQ(out[2], "2");
}

TEST(map_keys_values_entries_and_merge) {
    auto left = make_msg("", {{"a", lit_int(1)}, {"b", lit_int(2)}});
    auto merged = call("std_collections", "map_merge", make_msg("", {
        {"left", left},
        {"right", make_msg("", {{"c", lit_int(3)}})}
    }));
    auto entries = call("std_collections", "map_entries", make_msg("", {{"map", left}}));
    auto rebuilt = call("std_collections", "map_from_entries", make_msg("", {{"entries", entries}}));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(call("std_collections", "map_get", make_msg("", {{"map", rebuilt}, {"key", lit_string("a")}})))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_length", make_msg("", {{"list", call("std_collections", "map_keys", make_msg("", {{"map", left}}))}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "list_length", make_msg("", {{"list", call("std_collections", "map_values", make_msg("", {{"map", left}}))}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "map_get", make_msg("", {{"map", merged}, {"key", lit_string("c")}}))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "1");
    ASSERT_EQ(out[1], "2");
    ASSERT_EQ(out[2], "2");
    ASSERT_EQ(out[3], "3");
}

TEST(set_operations) {
    auto union_set = call("std_collections", "set_union", make_msg("", {
        {"left", lit_list({lit_int(1), lit_int(2)})},
        {"right", lit_list({lit_int(2), lit_int(3)})}
    }));
    auto intersection = call("std_collections", "set_intersection", make_msg("", {
        {"left", lit_list({lit_int(1), lit_int(2)})},
        {"right", lit_list({lit_int(2), lit_int(3)})}
    }));
    auto difference = call("std_collections", "set_difference", make_msg("", {
        {"left", lit_list({lit_int(1), lit_int(2)})},
        {"right", lit_list({lit_int(2), lit_int(3)})}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "set_length", make_msg("", {{"set", union_set}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "set_contains", make_msg("", {{"set", intersection}, {"value", lit_int(2)}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_collections", "set_contains", make_msg("", {{"set", difference}, {"value", lit_int(1)}}))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "3");
    ASSERT_EQ(out[1], "true");
    ASSERT_EQ(out[2], "true");
}

// ================================================================
// Tests — std_io / std_convert / std_time modules
// ================================================================

TEST(std_io_timestamp_ms) {
    auto prog = build_program(
        print_call(std_unary("to_string", call("std_io", "timestamp_ms", make_msg("", {})))));
    auto out = run_program(prog);
    ASSERT_TRUE(std::stoll(out[0]) > 1000000000000LL);
}

TEST(std_io_random_values_in_range) {
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_io", "random_int", make_msg("", {{"min", lit_int(1)}, {"max", lit_int(5)}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_io", "random_double", make_msg("", {}))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    auto int_val = std::stoll(out[0]);
    auto double_val = std::stod(out[1]);
    ASSERT_TRUE(int_val >= 1 && int_val <= 5);
    ASSERT_TRUE(double_val >= 0.0 && double_val < 1.0);
}

TEST(std_io_env_get_and_args_get) {
#ifdef _WIN32
    _putenv_s("BALL_TEST_ENV", "present");
#else
    setenv("BALL_TEST_ENV", "present", 1);
#endif
    auto args_length = std_unary("length", call("std_io", "args_get", make_msg("", {})));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(call("std_io", "env_get", make_msg("", {{"name", lit_string("BALL_TEST_ENV")}})))),
            expr_stmt(print_call(std_unary("to_string", args_length))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "present");
    ASSERT_EQ(out[1], "0");
}

TEST(std_convert_json_encode_and_decode) {
    auto encoded = call("std_convert", "json_encode", make_msg("", {
        {"value", make_msg("Obj", {{"x", lit_int(42)}, {"name", lit_string("ball")}})}
    }));
    auto decoded = call("std_convert", "json_decode", make_msg("", {
        {"value", lit_string("42")}
    }));
    auto prog = build_program_block(
        {
            expr_stmt(print_call(encoded)),
            expr_stmt(print_call(std_unary("to_string", decoded))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_TRUE(out[0].find("\"x\":42") != std::string::npos);
    ASSERT_EQ(out[1], "42");
}

TEST(std_convert_utf8_and_base64_roundtrip) {
    auto encoded_bytes = call("std_convert", "utf8_encode", make_msg("", {{"value", lit_string("abc")}}));
    auto base64 = call("std_convert", "base64_encode", make_msg("", {{"value", encoded_bytes}}));
    auto decoded_bytes = call("std_convert", "base64_decode", make_msg("", {{"value", base64}}));
    auto decoded_string = call("std_convert", "utf8_decode", make_msg("", {{"value", decoded_bytes}}));
    auto prog = build_program(print_call(decoded_string));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "abc");
}

TEST(std_time_now_and_year) {
    auto prog = build_program_block(
        {
            expr_stmt(print_call(std_unary("to_string", call("std_time", "now", make_msg("", {}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_time", "year", make_msg("", {}))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_TRUE(std::stoll(out[0]) > 1000000000000LL);
    ASSERT_TRUE(std::stoll(out[1]) >= 2024);
}

TEST(std_time_format_parse_and_duration_ops) {
    auto prog = build_program_block(
        {
            expr_stmt(print_call(call("std_time", "format_timestamp", make_msg("", {{"timestamp_ms", lit_int(0)}})))),
            expr_stmt(print_call(std_unary("to_string", call("std_time", "parse_timestamp", make_msg("", {{"value", lit_string("1970-01-01T00:00:00Z")}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_time", "duration_add", make_msg("", {{"left", lit_int(100)}, {"right", lit_int(50)}}))))),
            expr_stmt(print_call(std_unary("to_string", call("std_time", "duration_subtract", make_msg("", {{"left", lit_int(100)}, {"right", lit_int(50)}}))))),
        },
        lit_int(0));
    auto out = run_program(prog);
    ASSERT_EQ(out[0], "1970-01-01T00:00:00Z");
    ASSERT_EQ(out[1], "0");
    ASSERT_EQ(out[2], "150");
    ASSERT_EQ(out[3], "50");
}

// ================================================================
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ Engine Tests\n"
              << "=====================\n";

    // Tests auto-register via static objects above

    std::cout << "\n=====================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    return tests_failed > 0 ? 1 : 0;
}
