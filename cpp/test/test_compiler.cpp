// Ball C++ Compiler Test Suite
// Verifies that the compiler generates valid C++ code from Ball programs.

#include "compiler.h"
#include <cassert>
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

#define ASSERT_CONTAINS(haystack, needle) \
    do { \
        if ((haystack).find(needle) == std::string::npos) { \
            throw std::runtime_error( \
                std::string("ASSERT_CONTAINS failed: \"") + (needle) + \
                "\" not found in output"); \
        } \
    } while(0)

#define ASSERT_NOT_CONTAINS(haystack, needle) \
    do { \
        if ((haystack).find(needle) != std::string::npos) { \
            throw std::runtime_error( \
                std::string("ASSERT_NOT_CONTAINS failed: \"") + (needle) + \
                "\" was found in output"); \
        } \
    } while(0)

#define ASSERT_TRUE(cond) \
    do { \
        if (!(cond)) { \
            throw std::runtime_error( \
                std::string("ASSERT_TRUE failed: ") + #cond); \
        } \
    } while(0)

// ================================================================
// Helpers
// ================================================================

ball::v1::Expression lit_int(int64_t val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_int_value(val);
    return expr;
}

ball::v1::Expression lit_double(double val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_double_value(val);
    return expr;
}

ball::v1::Expression lit_string(const std::string& val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_string_value(val);
    return expr;
}

ball::v1::Expression lit_bool(bool val) {
    ball::v1::Expression expr;
    expr.mutable_literal()->set_bool_value(val);
    return expr;
}

ball::v1::Expression ref(const std::string& name) {
    ball::v1::Expression expr;
    expr.mutable_reference()->set_name(name);
    return expr;
}

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

ball::v1::Expression std_call(const std::string& function,
                               ball::v1::Expression input) {
    ball::v1::Expression expr;
    auto* c = expr.mutable_call();
    c->set_module("std");
    c->set_function(function);
    *c->mutable_input() = std::move(input);
    return expr;
}

ball::v1::Expression std_binary(const std::string& function,
                                 ball::v1::Expression left,
                                 ball::v1::Expression right) {
    return std_call(function, make_msg("BinaryInput", {
        {"left", std::move(left)},
        {"right", std::move(right)}
    }));
}

ball::v1::Expression std_unary(const std::string& fn,
                                ball::v1::Expression value) {
    return std_call(fn, make_msg("UnaryInput", {
        {"value", std::move(value)}
    }));
}

ball::v1::Expression print_call(ball::v1::Expression msg) {
    return std_call("print", make_msg("PrintInput", {
        {"message", std::move(msg)}
    }));
}

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

std::string compile_program(const ball::v1::Program& prog) {
    CppCompiler compiler(prog);
    return compiler.compile();
}

// ================================================================
// Tests — Basic output structure
// ================================================================

TEST(hello_world_compiles) {
    auto prog = build_program(print_call(lit_string("Hello, World!")));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "#include");
    ASSERT_CONTAINS(out, "int main");
    ASSERT_CONTAINS(out, "Hello, World!");
}

TEST(includes_standard_headers) {
    auto prog = build_program(print_call(lit_string("test")));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "#include <iostream>");
    ASSERT_CONTAINS(out, "#include <string>");
    ASSERT_CONTAINS(out, "#include <vector>");
}

// ================================================================
// Tests — Literal compilation
// ================================================================

TEST(compile_int_literal) {
    auto prog = build_program(print_call(std_unary("to_string", lit_int(42))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "42");
}

TEST(compile_double_literal) {
    auto prog = build_program(print_call(std_unary("to_string", lit_double(3.14))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "3.14");
}

TEST(compile_string_literal) {
    auto prog = build_program(print_call(lit_string("test string")));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "\"test string\"");
}

TEST(compile_bool_literal) {
    auto prog = build_program(print_call(std_unary("to_string", lit_bool(true))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "true");
}

// ================================================================
// Tests — Arithmetic compilation
// ================================================================

TEST(compile_add) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("add", lit_int(1), lit_int(2)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "+");
}

TEST(compile_subtract) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("subtract", lit_int(5), lit_int(3)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "-");
}

TEST(compile_multiply) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("multiply", lit_int(2), lit_int(3)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "*");
}

// ================================================================
// Tests — String operations compilation (fixed stubs)
// ================================================================

TEST(compile_string_split) {
    auto prog = build_program(
        std_call("string_split", make_msg("", {
            {"value", lit_string("a,b,c")},
            {"separator", lit_string(",")}
        })));
    auto out = compile_program(prog);
    // Should contain actual split logic, not just a comment
    ASSERT_NOT_CONTAINS(out, "/* string_split */");
    ASSERT_CONTAINS(out, "find");
    ASSERT_CONTAINS(out, "substr");
    ASSERT_CONTAINS(out, "d.empty()");
}

TEST(compile_string_replace) {
    auto prog = build_program(
        std_call("string_replace", make_msg("", {
            {"value", lit_string("hello world")},
            {"from", lit_string("world")},
            {"to", lit_string("there")}
        })));
    auto out = compile_program(prog);
    ASSERT_NOT_CONTAINS(out, "/* string_replace */");
    ASSERT_CONTAINS(out, "replace");
}

TEST(compile_string_replace_all) {
    auto prog = build_program(
        std_call("string_replace_all", make_msg("", {
            {"value", lit_string("aabaa")},
            {"from", lit_string("a")},
            {"to", lit_string("x")}
        })));
    auto out = compile_program(prog);
    ASSERT_NOT_CONTAINS(out, "/* string_replace_all */");
    ASSERT_CONTAINS(out, "replace");
    ASSERT_CONTAINS(out, "f.empty()");
}

// ================================================================
// Tests — Control flow compilation
// ================================================================

TEST(compile_if_statement) {
    // Use a block with if as a statement (triggers compile_statement path)
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() =
        std_call("if", make_msg("IfInput", {
            {"condition", lit_bool(true)},
            {"then", print_call(lit_string("yes"))},
            {"else", print_call(lit_string("no"))}
        }));
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "if");
}

TEST(compile_for_loop) {
    ball::v1::Expression init;
    auto* init_blk = init.mutable_block();
    auto* let = init_blk->add_statements()->mutable_let();
    let->set_name("i");
    *let->mutable_value() = lit_int(0);
    *init_blk->mutable_result() = lit_int(0);

    auto prog = build_program(
        std_call("for", make_msg("ForInput", {
            {"init", std::move(init)},
            {"condition", std_binary("less_than", ref("i"), lit_int(10))},
            {"update", std_call("assign", make_msg("", {
                {"target", ref("i")},
                {"value", std_binary("add", ref("i"), lit_int(1))}
            }))},
            {"body", print_call(std_unary("to_string", ref("i")))}
        })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "for");
}

TEST(compile_while_loop) {
    auto prog = build_program(
        std_call("while", make_msg("WhileInput", {
            {"condition", lit_bool(false)},
            {"body", print_call(lit_string("never"))}
        })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "while");
}

// ================================================================
// Tests — Switch compilation (was stubbed)
// ================================================================

TEST(compile_switch_with_cases) {
    ball::v1::Expression cases_list;
    auto* list = cases_list.mutable_literal()->mutable_list_value();

    *list->add_elements() = make_msg("", {
        {"value", lit_int(1)},
        {"body", print_call(lit_string("one"))}
    });
    *list->add_elements() = make_msg("", {
        {"value", lit_int(2)},
        {"body", print_call(lit_string("two"))}
    });
    *list->add_elements() = make_msg("", {
        {"is_default", lit_bool(true)},
        {"body", print_call(lit_string("other"))}
    });

    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() =
        std_call("switch", make_msg("SwitchInput", {
            {"subject", ref("x")},
            {"cases", std::move(cases_list)}
        }));
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "switch");
    ASSERT_CONTAINS(out, "case");
    ASSERT_CONTAINS(out, "default:");
    ASSERT_CONTAINS(out, "break;");
}

// ================================================================
// Tests — Try-catch compilation (was simplified)
// ================================================================

TEST(compile_try_catch) {
    ball::v1::Expression catches_list;
    auto* list = catches_list.mutable_literal()->mutable_list_value();
    *list->add_elements() = make_msg("", {
        {"variable", lit_string("e")},
        {"body", print_call(lit_string("caught"))}
    });

    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() =
        std_call("try", make_msg("TryInput", {
            {"body", print_call(lit_string("try body"))},
            {"catches", std::move(catches_list)}
        }));
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "try");
    ASSERT_CONTAINS(out, "catch");
    ASSERT_NOT_CONTAINS(out, "// catch handler");
}

TEST(compile_try_catch_finally) {
    ball::v1::Expression catches_list;
    auto* list = catches_list.mutable_literal()->mutable_list_value();
    *list->add_elements() = make_msg("", {
        {"variable", lit_string("e")},
        {"body", print_call(lit_string("caught"))}
    });

    ball::v1::Expression body;
    auto* blk2 = body.mutable_block();
    *blk2->add_statements()->mutable_expression() =
        std_call("try", make_msg("TryInput", {
            {"body", print_call(lit_string("try body"))},
            {"catches", std::move(catches_list)},
            {"finally", print_call(lit_string("cleanup"))}
        }));
    *blk2->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "try");
    ASSERT_CONTAINS(out, "catch");
    // Finally should be emitted as unconditional code after try-catch
    ASSERT_CONTAINS(out, "cleanup");
}

// ================================================================
// Tests — Reference compilation
// ================================================================

TEST(compile_reference) {
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    auto* let_x = blk->add_statements()->mutable_let();
    let_x->set_name("x");
    *let_x->mutable_value() = lit_int(42);
    *blk->mutable_result() = print_call(std_unary("to_string", ref("x")));

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "x");
    ASSERT_CONTAINS(out, "42");
}

// ================================================================
// Tests — Block compilation
// ================================================================

TEST(compile_block_with_let) {
    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    auto* let_a = blk->add_statements()->mutable_let();
    let_a->set_name("a");
    *let_a->mutable_value() = lit_int(10);
    auto* let_b = blk->add_statements()->mutable_let();
    let_b->set_name("b");
    *let_b->mutable_value() = lit_int(20);
    *blk->mutable_result() = print_call(
        std_unary("to_string", std_binary("add", ref("a"), ref("b"))));

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "auto a");
    ASSERT_CONTAINS(out, "auto b");
}

// ================================================================
// Tests — Field access compilation
// ================================================================

TEST(compile_field_access) {
    ball::v1::Expression access;
    auto* fa = access.mutable_field_access();
    *fa->mutable_object() = ref("point");
    fa->set_field("x");

    auto prog = build_program(print_call(std_unary("to_string", std::move(access))));
    auto out = compile_program(prog);
    // Should contain some form of field access like .x or ["x"]
    ASSERT_TRUE(out.find(".x") != std::string::npos ||
                out.find("[\"x\"]") != std::string::npos);
}

// ================================================================
// Tests — Message creation compilation
// ================================================================

TEST(compile_message_creation) {
    auto prog = build_program(
        print_call(std_unary("to_string",
            make_msg("Point", {
                {"x", lit_int(10)},
                {"y", lit_int(20)}
            }))));
    auto out = compile_program(prog);
    // Should create a map or struct with x and y
    ASSERT_TRUE(out.find("\"x\"") != std::string::npos ||
                out.find("x") != std::string::npos);
}

// ================================================================
// Tests — Divide and modulo compilation
// ================================================================

TEST(compile_divide) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("divide", lit_int(10), lit_int(2)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "/");
}

TEST(compile_modulo) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("modulo", lit_int(10), lit_int(3)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "%");
}

// ================================================================
// Tests — Comparison operations compilation
// ================================================================

TEST(compile_less_than) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("less_than", lit_int(1), lit_int(2)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "<");
}

TEST(compile_greater_than) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("greater_than", lit_int(5), lit_int(3)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, ">");
}

TEST(compile_equals) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("equals", lit_int(1), lit_int(1)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "==");
}

// ================================================================
// Tests — Logic compilation
// ================================================================

TEST(compile_and) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("and", lit_bool(true), lit_bool(false)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "&&");
}

TEST(compile_or) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_binary("or", lit_bool(true), lit_bool(false)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "||");
}

TEST(compile_not) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("not", lit_bool(true)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "!");
}

// ================================================================
// Tests — User-defined function compilation
// ================================================================

TEST(compile_user_function) {
    ball::v1::Program program;
    auto* mod = program.add_modules();
    mod->set_name("main");

    auto* helper = mod->add_functions();
    helper->set_name("double_it");
    *helper->mutable_body() = std_binary("multiply", ref("input"), lit_int(2));

    auto* main_fn = mod->add_functions();
    main_fn->set_name("main");
    *main_fn->mutable_body() =
        print_call(std_unary("to_string", call("main", "double_it", lit_int(21))));

    program.set_entry_module("main");
    program.set_entry_function("main");

    auto out = compile_program(program);
    ASSERT_CONTAINS(out, "double_it");
}

// ================================================================
// Tests — Break and continue compilation
// ================================================================

TEST(compile_break) {
    // Build a while loop with break inside as a statement
    ball::v1::Expression inner_body;
    auto* inner_blk = inner_body.mutable_block();
    *inner_blk->add_statements()->mutable_expression() =
        std_call("break", lit_int(0));
    *inner_blk->mutable_result() = lit_int(0);

    ball::v1::Expression outer;
    auto* outer_blk = outer.mutable_block();
    *outer_blk->add_statements()->mutable_expression() =
        std_call("while", make_msg("WhileInput", {
            {"condition", lit_bool(true)},
            {"body", std::move(inner_body)}
        }));
    *outer_blk->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(outer));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "break");
}

TEST(compile_continue) {
    ball::v1::Expression inner_body;
    auto* inner_blk = inner_body.mutable_block();
    *inner_blk->add_statements()->mutable_expression() =
        std_call("continue", lit_int(0));
    *inner_blk->mutable_result() = lit_int(0);

    ball::v1::Expression outer;
    auto* outer_blk = outer.mutable_block();
    *outer_blk->add_statements()->mutable_expression() =
        std_call("while", make_msg("WhileInput", {
            {"condition", lit_bool(false)},
            {"body", std::move(inner_body)}
        }));
    *outer_blk->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(outer));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "continue");
}

// ================================================================
// Tests — Do-while compilation
// ================================================================

TEST(compile_do_while) {
    auto prog = build_program(
        std_call("do_while", make_msg("DoWhileInput", {
            {"condition", lit_bool(false)},
            {"body", print_call(lit_string("once"))}
        })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "do");
    ASSERT_CONTAINS(out, "while");
}

// ================================================================
// Tests — Negate compilation
// ================================================================

TEST(compile_negate) {
    auto prog = build_program(
        print_call(std_unary("to_string", std_unary("negate", lit_int(42)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "-");
}

// ================================================================
// Tests — Gap closures (concurrency + conversion operators)
// ================================================================

TEST(compile_std_concurrency_mutex_lock) {
    auto prog = build_program(
        call("std_concurrency", "mutex_lock", make_msg("LockInput", {
            {"mutex", ref("mtx")}
        }))
    );
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, ".lock()");
}

TEST(compile_conversion_operator_method) {
    ball::v1::Program program;
    auto* mod = program.add_modules();
    mod->set_name("main");

    // Type definition: class NumBox {}
    auto* td = mod->add_type_defs();
    td->set_name("NumBox");
    td->mutable_descriptor_()->set_name("NumBox");
    (*td->mutable_metadata()->mutable_fields())["kind"].set_string_value("class");

    // Conversion operator: operator int()
    auto* conv = mod->add_functions();
    conv->set_name("NumBox.operator_int");
    conv->set_output_type("int");
    conv->set_is_base(false);
    (*conv->mutable_metadata()->mutable_fields())["kind"].set_string_value("operator");
    (*conv->mutable_metadata()->mutable_fields())["is_operator"].set_bool_value(true);
    (*conv->mutable_metadata()->mutable_fields())["is_conversion_operator"].set_bool_value(true);
    (*conv->mutable_metadata()->mutable_fields())["conversion_type"].set_string_value("int");
    *conv->mutable_body() = lit_int(7);

    // Entry function.
    auto* main_fn = mod->add_functions();
    main_fn->set_name("main");
    *main_fn->mutable_body() = lit_int(0);

    program.set_entry_module("main");
    program.set_entry_function("main");

    auto out = compile_program(program);
    ASSERT_CONTAINS(out, "operator int64_t(");
}

// ================================================================
// Main
// ================================================================

int main() {
    std::cout << "Ball C++ Compiler Tests\n"
              << "=======================\n";

    std::cout << "\n=======================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_run << " total\n";

    return tests_failed > 0 ? 1 : 0;
}
