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
    ASSERT_CONTAINS(out, "using namespace std::string_literals;");
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
    ASSERT_CONTAINS(out, "\"test string\"s");
    ASSERT_NOT_CONTAINS(out, "std::string(\"test string\")");
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

// Regression: the private `_ballMap*` helper fast-paths must read POSITIONAL
// args (arg0/arg1/arg2). These calls only reach the call-path special-cases
// once the encoder stopped mis-classifying private `_foo()` calls as
// constructors; a prior bug read named "map"/"key"/"value" fields from the
// positional input, dropping operands to empty `BallDyn()` and (for
// contains-key) emitting unbalanced parens — which gcc rejected in engine_rt.cpp.
TEST(compile_ball_map_contains_key_positional) {
    auto prog = build_program(call("", "_ballMapContainsKeyDyn",
        make_msg("", {{"arg0", ref("theMap")}, {"arg1", ref("theKey")}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, ".count(BallDyn(");
    ASSERT_NOT_CONTAINS(out, "BallDyn().count");  // empty receiver = the bug
}

TEST(compile_ball_map_set_positional) {
    auto prog = build_program(call("", "_ballMapSetDyn",
        make_msg("", {{"arg0", ref("theMap")},
                       {"arg1", ref("theKey")},
                       {"arg2", ref("theVal")}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "ball_set(");
    // key/value must not be dropped to empty BallDyn()
    ASSERT_NOT_CONTAINS(out, ",BallDyn(),BallDyn()))");
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
    ASSERT_CONTAINS(out, "__switch_subj");
    ASSERT_CONTAINS(out, "if (");
    ASSERT_CONTAINS(out, "else");
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
    // Should contain some form of field access like .x, ["x"], or ["x"s]
    ASSERT_TRUE(out.find(".x") != std::string::npos ||
                out.find("[\"x\"]") != std::string::npos ||
                out.find("[\"x\"s]") != std::string::npos);
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

TEST(compile_labeled_break_emits_goto) {
    // labeled(outer) { for (...) { break outer; } }
    // Must compile to: for (...) { goto __ball_break_outer; } __ball_break_outer:;
    ball::v1::Expression for_body;
    auto* for_blk = for_body.mutable_block();
    *for_blk->add_statements()->mutable_expression() =
        std_call("break", make_msg("", {{"label", lit_string("outer")}}));
    *for_blk->mutable_result() = lit_int(0);

    auto for_call = std_call("for", make_msg("ForInput", {
        {"init", lit_int(0)},
        {"condition", lit_bool(true)},
        {"update", lit_int(0)},
        {"body", std::move(for_body)}
    }));

    auto labeled_call = std_call("labeled", make_msg("LabeledInput", {
        {"label", lit_string("outer")},
        {"body", std::move(for_call)}
    }));

    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() = std::move(labeled_call);
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "goto __ball_break_outer");
    ASSERT_CONTAINS(out, "__ball_break_outer:;");
}

TEST(compile_labeled_continue_emits_goto) {
    ball::v1::Expression for_body;
    auto* for_blk = for_body.mutable_block();
    *for_blk->add_statements()->mutable_expression() =
        std_call("continue", make_msg("", {{"label", lit_string("loop")}}));
    *for_blk->mutable_result() = lit_int(0);

    auto while_call = std_call("while", make_msg("WhileInput", {
        {"condition", lit_bool(true)},
        {"body", std::move(for_body)}
    }));

    auto labeled_call = std_call("labeled", make_msg("LabeledInput", {
        {"label", lit_string("loop")},
        {"body", std::move(while_call)}
    }));

    ball::v1::Expression body;
    auto* blk = body.mutable_block();
    *blk->add_statements()->mutable_expression() = std::move(labeled_call);
    *blk->mutable_result() = lit_int(0);

    auto prog = build_program(std::move(body));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "goto __ball_continue_loop");
    ASSERT_CONTAINS(out, "__ball_continue_loop:;");
    ASSERT_CONTAINS(out, "__ball_break_loop:;");
}

TEST(compile_try_catch_typed_dispatches_by_type) {
    // Two typed catch clauses + one untyped fallback. The emitted C++ must:
    //   1. Wrap the body in try
    //   2. Have a BallException catch with if/else dispatch on type_name
    //   3. Have a std::exception catch that runs the untyped body (not `throw;`)
    ball::v1::Expression catches_list;
    auto* list = catches_list.mutable_literal()->mutable_list_value();
    auto typed1 = make_msg("", {
        {"type", lit_string("NotFound")},
        {"variable", lit_string("e")},
        {"body", print_call(lit_string("not-found"))}
    });
    auto typed2 = make_msg("", {
        {"type", lit_string("ParseError")},
        {"variable", lit_string("e")},
        {"body", print_call(lit_string("parse-error"))}
    });
    auto untyped = make_msg("", {
        {"variable", lit_string("e")},
        {"body", print_call(lit_string("fallback"))}
    });
    *list->add_elements() = std::move(typed1);
    *list->add_elements() = std::move(typed2);
    *list->add_elements() = std::move(untyped);

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
    // BallException catch emitted (requires the preamble too).
    ASSERT_CONTAINS(out, "struct BallException");
    ASSERT_CONTAINS(out, "catch (const BallException&");
    // Dispatch chain on type_name.
    ASSERT_CONTAINS(out, "__ball_e.type_name == \"NotFound\"");
    ASSERT_CONTAINS(out, "__ball_e.type_name == \"ParseError\"");
    // Untyped fallback body (fallback), not a bare rethrow.
    ASSERT_CONTAINS(out, "\"fallback\"");
    // Non-BallException catch also present for std::exception-derived throws.
    ASSERT_CONTAINS(out, "catch (const std::exception&");
}

TEST(compile_throw_uses_ball_exception) {
    // Plain `throw "boom"` should raise a BallException with the default type
    // "Exception", not std::runtime_error. A non-message value is routed
    // through `_ball_make_exception(type, value)` (which returns a
    // BallException) so the original thrown payload survives to the catch side
    // (`e["value"]`) and an intervening `rethrow` doesn't double-wrap it.
    auto prog = build_program(
        std_call("throw", make_msg("", {
            {"value", lit_string("boom")}
        })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "throw _ball_make_exception(\"Exception\"s");
    ASSERT_CONTAINS(out, "\"boom\"s");
}

TEST(compile_base64_encode_decode_roundtrip) {
    // base64_encode takes a vector<uint8_t> and returns a string.
    // Use utf8_encode to produce a byte vector, then feed it through
    // base64_encode, then decode it back. Both must emit real code, not
    // "/* not yet implemented */" stubs.
    auto utf8 = call("std_convert", "utf8_encode", make_msg("", {
        {"source", lit_string("abc")}
    }));
    auto b64enc = call("std_convert", "base64_encode", make_msg("", {
        {"source", std::move(utf8)}
    }));
    auto prog = build_program(print_call(std::move(b64enc)));
    auto out = compile_program(prog);
    ASSERT_NOT_CONTAINS(out, "not yet implemented");
    // The inline alphabet marks the emitted encoder lambda.
    ASSERT_CONTAINS(out, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");

    // base64_decode must also emit real code.
    auto b64dec = call("std_convert", "base64_decode", make_msg("", {
        {"source", lit_string("YWJj")}
    }));
    auto prog2 = build_program(print_call(call("std_convert", "utf8_decode", make_msg("", {
        {"bytes", std::move(b64dec)}
    }))));
    auto out2 = compile_program(prog2);
    ASSERT_NOT_CONTAINS(out2, "not yet implemented");
    ASSERT_CONTAINS(out2, "push_back");
}

// ================================================================
// Tests — Collection elements (issue #55): C-style comprehension + spread
// ================================================================

// Build a list literal Expression from a vector of element expressions.
static ball::v1::Expression lit_list(std::vector<ball::v1::Expression> elems) {
    ball::v1::Expression expr;
    auto* lv = expr.mutable_literal()->mutable_list_value();
    for (auto& e : elems) *lv->add_elements() = std::move(e);
    return expr;
}

// `[for (var i = 0; i < 3; i++) i * i]` — a C-style collection_for inside a
// list literal. Before the fix the C++ compiler only handled the for-EACH form
// (it read an `iterable` field that doesn't exist here), so the loop body was
// dropped and the list compiled empty.
TEST(compile_collection_for_cstyle_list) {
    // init: block { var i = 0; }
    ball::v1::Expression init;
    auto* let = init.mutable_block()->add_statements()->mutable_let();
    let->set_name("i");
    *let->mutable_value() = lit_int(0);

    auto cfor = std_call("collection_for", make_msg("", {
        {"init", std::move(init)},
        {"condition", std_binary("less_than", ref("i"), lit_int(3))},
        {"update", std_call("post_increment", make_msg("", {{"value", ref("i")}}))},
        {"body", std_binary("multiply", ref("i"), ref("i"))},
    }));
    auto prog = build_program(print_call(lit_list({std::move(cfor)})));
    auto out = compile_program(prog);
    // The C-style header must be emitted inline (NOT an empty for-each loop).
    ASSERT_CONTAINS(out, "for (auto i = static_cast<int64_t>(0)");
    // Body splices into the result list.
    ASSERT_CONTAINS(out, "push_back");
    // Must NOT fall through to the empty-iterable for-each form.
    ASSERT_NOT_CONTAINS(out, "for (auto i : BallDyn(BallDyn()))");
}

// `[0, ...a, 3]` — a spread element must SPLICE each item of `a` rather than
// nest `a` as a single element. Before the fix `spread` returned its operand
// directly and the list compiled as `{0, <a>, 3}`.
TEST(compile_list_spread_splices) {
    auto spread = std_call("spread", make_msg("", {{"value", ref("a")}}));
    auto prog = build_program(print_call(lit_list({
        lit_int(0), std::move(spread), lit_int(3),
    })));
    auto out = compile_program(prog);
    // The splice path builds the list via an IIFE that iterates the operand.
    ASSERT_CONTAINS(out, "BallList __r");
    ASSERT_CONTAINS(out, "for (auto __sp : BallDyn(a))");
    ASSERT_CONTAINS(out, "__r.push_back(std::any(BallDyn(__sp)))");
}

// `[0, ...?n, 99]` — null-aware spread contributes nothing when the operand is
// null (guarded by has_value()).
TEST(compile_list_null_spread_guards_null) {
    auto nspread = std_call("null_spread", make_msg("", {{"value", ref("n")}}));
    auto prog = build_program(print_call(lit_list({
        lit_int(0), std::move(nspread), lit_int(99),
    })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "has_value()");
    ASSERT_CONTAINS(out, "BallList __r");
}

// `[for (var i = 0; i < 3; i++) () => i]` (fixture 312: 312_collection_for_capture)
// — the loop var `i` is captured by an escaping closure, so it must be boxed
// (shared_ptr<BallDyn>) with a FRESH per-iteration cell, exactly like the
// statement-form `for`'s closure-capture boxing. Before the fix the C-style
// header always emitted an unboxed `auto i = ...`, while `compile_reference`
// (driven by the same `compute_boxed_vars` pre-pass) still dereferenced every
// read of `i` as `(*i)` — a hard compile error (`operator*` on an int64_t).
TEST(compile_collection_for_cstyle_boxes_captured_loop_var) {
    ball::v1::Expression init;
    auto* let_i = init.mutable_block()->add_statements()->mutable_let();
    let_i->set_name("i");
    *let_i->mutable_value() = lit_int(0);

    ball::v1::Expression body_lambda;
    body_lambda.mutable_lambda()->set_name("");
    *body_lambda.mutable_lambda()->mutable_body() = ref("i");

    auto cfor = std_call("collection_for", make_msg("", {
        {"init", std::move(init)},
        {"condition", std_binary("less_than", ref("i"), lit_int(3))},
        {"update", std_call("post_increment", make_msg("", {{"value", ref("i")}}))},
        {"body", std::move(body_lambda)},
    }));

    ball::v1::Expression main_body;
    auto* let_fns = main_body.mutable_block()->add_statements()->mutable_let();
    let_fns->set_name("fns");
    *let_fns->mutable_value() = lit_list({std::move(cfor)});

    auto prog = build_program(std::move(main_body));
    auto out = compile_program(prog);
    // The init cell is boxed...
    ASSERT_CONTAINS(out, "std::make_shared<BallDyn>(BallDyn(static_cast<int64_t>(0)))");
    // ...and the body gets a fresh per-iteration shadow cell (mirrors the
    // statement-form `for`'s `__ball_box_persist_<var>` splice).
    ASSERT_CONTAINS(out, "__ball_box_persist_i");
    // Must NOT fall back to the unboxed header (would make every `(*i)` read
    // ill-formed).
    ASSERT_NOT_CONTAINS(out, "for (auto i = static_cast<int64_t>(0)");
}

// ================================================================
// Tests — std_memory native lowering (issue #154)
// ================================================================

// Registers an all-base module named `name` (e.g. "std_memory") so
// `base_modules_` picks it up and the memory runtime preamble is emitted.
static void add_base_module(ball::v1::Program& prog, const std::string& name) {
    auto* mod = prog.add_modules();
    mod->set_name(name);
    auto* fn = mod->add_functions();
    fn->set_name("__marker__");
    fn->set_is_base(true);
}

ball::v1::Expression mem_call(const std::string& function,
                               const std::string& type_name,
                               std::vector<std::pair<std::string, ball::v1::Expression>> fields) {
    return call("std_memory", function, make_msg(type_name, std::move(fields)));
}

TEST(compile_std_memory_preamble_declares_runtime_arrays) {
    ball::v1::Program prog = build_program(
        mem_call("memory_alloc", "AllocInput", {{"size", lit_int(4)}}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "static uint8_t _ball_memory[65536];");
    ASSERT_CONTAINS(out, "static size_t _ball_heap_ptr = 0;");
    ASSERT_CONTAINS(out, "static size_t _ball_stack_ptr = 65536;");
    ASSERT_CONTAINS(out, "static std::vector<size_t> _ball_stack_frames;");
    ASSERT_CONTAINS(out, "inline int64_t _ball_memory_alloc(int64_t size)");
}

TEST(compile_std_memory_alloc_free_realloc) {
    ball::v1::Program prog = build_program(mem_call(
        "memory_realloc", "ReallocInput",
        {{"address", ref("a")}, {"new_size", lit_int(8)}}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    // ReallocInput field order (std_memory.dart): address(1), new_size(2) —
    // positional lowering must pass `a` before the size.
    ASSERT_CONTAINS(out, "_ball_memory_realloc(a, static_cast<int64_t>(8))");
    ASSERT_CONTAINS(out, "inline int64_t _ball_memory_realloc(int64_t address, int64_t new_size)");
    ASSERT_CONTAINS(out, "inline int64_t _ball_memory_free(int64_t address)");
}

TEST(compile_std_memory_typed_read_write) {
    ball::v1::Program prog = build_program(mem_call(
        "memory_write_i32", "MemWriteInput",
        {{"address", lit_int(0)}, {"value", lit_int(42)}}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_memory_write_i32(static_cast<int64_t>(0), static_cast<int64_t>(42))");
    ASSERT_CONTAINS(out, "inline double _ball_memory_read_f64(int64_t address)");
    ASSERT_CONTAINS(out, "inline double _ball_memory_read_f32(int64_t address)");
}

TEST(compile_std_memory_bulk_and_ptr_ops) {
    ball::v1::Program prog = build_program(mem_call(
        "memory_copy", "MemCopyInput",
        {{"dest", lit_int(0)}, {"src", lit_int(4)}, {"size", lit_int(4)}}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_memory_copy(static_cast<int64_t>(0), static_cast<int64_t>(4), static_cast<int64_t>(4))");
    ASSERT_CONTAINS(out, "inline int64_t _ball_memory_set(int64_t address, int64_t value, int64_t size)");
    ASSERT_CONTAINS(out, "inline int64_t _ball_memory_compare(int64_t a, int64_t b, int64_t size)");
    ASSERT_CONTAINS(out, "inline int64_t _ball_ptr_add(int64_t address, int64_t offset, int64_t element_size)");
    ASSERT_CONTAINS(out, "inline int64_t _ball_ptr_diff(int64_t address, int64_t offset, int64_t element_size)");
}

TEST(compile_std_memory_stack_frame_and_sizeof) {
    ball::v1::Program prog = build_program(mem_call(
        "stack_alloc", "StackAllocInput", {{"size", lit_int(16)}}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_stack_alloc(static_cast<int64_t>(16))");
    ASSERT_CONTAINS(out, "inline int64_t _ball_stack_push_frame()");
    ASSERT_CONTAINS(out, "inline int64_t _ball_stack_pop_frame()");
    ASSERT_CONTAINS(out, "inline int64_t _ball_memory_sizeof(const std::string& type_name)");
}

// nullptr / heap-size / stack-size introspection — one-liners mirroring the
// Dart compiler (nullptr => 0; heap size = whole linear buffer; stack size =
// bytes the downward-growing stack occupies). Flagged in the PR #169 review:
// these were fail-loud gaps while Dart and TS both implement them.
TEST(compile_std_memory_introspection) {
    ball::v1::Program prog =
        build_program(mem_call("memory_heap_size", "Empty", {}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_memory_heap_size()");
    ASSERT_CONTAINS(out, "inline int64_t _ball_nullptr() { return 0; }");
    ASSERT_CONTAINS(out,
                    "inline int64_t _ball_memory_heap_size() { return "
                    "static_cast<int64_t>(sizeof(_ball_memory)); }");
    ASSERT_CONTAINS(out,
                    "inline int64_t _ball_memory_stack_size() { return "
                    "static_cast<int64_t>(sizeof(_ball_memory) - "
                    "_ball_stack_ptr); }");
    ASSERT_NOT_CONTAINS(out, "static_assert(false");
}

// Any std_memory function NOT natively implemented must fail LOUD at C++
// compile time (a static_assert naming the function) — never silently emit
// an undefined-identifier call like `_ball_address_of(...)`.
TEST(compile_std_memory_unimplemented_fails_loud_at_compile_time) {
    ball::v1::Program prog = build_program(
        mem_call("address_of", "AddressOfInput", {{"value", lit_int(1)}}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "static_assert(false");
    ASSERT_CONTAINS(out, "std_memory.address_of");
    ASSERT_NOT_CONTAINS(out, "_ball_address_of(");
}

// ================================================================
// Tests — Set-literal emission (issue #174): the direct-compile path must
// dedup on construction and render Dart-style `{a, b, c}`, not compile a Set
// literal like a bare list (`[a, b, c]` with duplicates surviving).
// ================================================================

// Build a Set-literal Expression: std.set_create({elements: [...]}) — mirrors
// the encoder's IR shape for `{1, 2, 3}` (same `elements` field the list
// literal `[...]` splice path reads via lit_list() above).
static ball::v1::Expression set_lit(std::vector<ball::v1::Expression> elems) {
    ball::v1::Expression elements_expr;
    auto* lv = elements_expr.mutable_literal()->mutable_list_value();
    for (auto& e : elems) *lv->add_elements() = std::move(e);
    return std_call("set_create", make_msg("", {{"elements", std::move(elements_expr)}}));
}

// `{1, 2, 2, 3}` — the literal elements splice into a BallList, and the
// finished list must be wrapped via ball_make_set (dedups + tags for
// Dart-style rendering at runtime). Before the fix the IIFE just returned
// `BallDyn(__r)` — a bare, untagged list; duplicates survived and printing
// rendered `[...]` instead of `{...}`.
TEST(compile_set_literal_wraps_in_ball_make_set) {
    auto prog = build_program(print_call(
        set_lit({lit_int(1), lit_int(2), lit_int(2), lit_int(3)})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "return ball_make_set(__r); }()");
    ASSERT_NOT_CONTAINS(out, "return BallDyn(__r); }()");
}

// `{}` — a set_create call with no `elements` field at all (the encoder's
// shape for an empty Set literal not disambiguated as an empty Map by
// let-metadata). Must still route through ball_make_set, not a bare
// `BallDyn(BallList{})` / `std::vector<std::any>{}`.
TEST(compile_empty_set_literal_wraps_in_ball_make_set) {
    auto prog = build_program(print_call(std_call("set_create", make_msg("", {}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "ball_make_set(BallList{})");
}

// std_collections.set_create (the constructor form, as opposed to the std
// module's literal-splicing set_create above) must also route through
// ball_make_set so `Set()` prints/dedups exactly like `{}`.
TEST(compile_set_create_std_collections_wraps_in_ball_make_set) {
    auto prog = build_program(print_call(
        call("std_collections", "set_create", make_msg("", {}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "ball_make_set(BallList{})");
}

// set_add must dedup-insert via BallDyn::push_back (which itself performs the
// scan-and-skip-duplicates, issue #174) rather than the compiler re-emitting
// its own manual duplicate scan inline.
TEST(compile_set_add_routes_through_dedup_push_back) {
    auto prog = build_program(print_call(
        call("std_collections", "set_add", make_msg("", {
            {"set", ref("s")}, {"value", lit_int(4)}
        }))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "v.push_back(e); return v;");
}

// set_remove must fall back to the portable set's backing list
// (_setBackingList()) when the receiver isn't a plain list.
TEST(compile_set_remove_falls_back_to_set_backing_list) {
    auto prog = build_program(print_call(
        call("std_collections", "set_remove", make_msg("", {
            {"set", ref("s")}, {"value", lit_int(4)}
        }))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_setBackingList()");
}

// set_to_list must copy out the wrapped list (ball_list_copy handles both
// plain lists and the portable set shape) rather than returning the tagged
// set value itself (which used to alias the Set — mutating the "list" result
// mutated the Set backing it).
TEST(compile_set_to_list_copies_backing_list) {
    auto prog = build_program(print_call(
        call("std_collections", "set_to_list", make_msg("", {{"set", ref("s")}}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "ball_list_copy(BallDyn(");
}

// set_union / set_intersection / set_difference must route through the
// portable-set-aware ball_dyn.h helpers (which themselves wrap their result
// via ball_make_set), not a hand-rolled scan returning a bare list.
TEST(compile_set_algebra_ops_route_through_tagged_helpers) {
    auto union_out = compile_program(build_program(print_call(
        call("std_collections", "set_union", make_msg("", {
            {"left", ref("a")}, {"right", ref("b")}
        })))));
    ASSERT_CONTAINS(union_out, "union_(BallDyn(a), BallDyn(b))");

    auto intersection_out = compile_program(build_program(print_call(
        call("std_collections", "set_intersection", make_msg("", {
            {"left", ref("a")}, {"right", ref("b")}
        })))));
    ASSERT_CONTAINS(intersection_out, "intersection(BallDyn(a), BallDyn(b))");

    auto difference_out = compile_program(build_program(print_call(
        call("std_collections", "set_difference", make_msg("", {
            {"left", ref("a")}, {"right", ref("b")}
        })))));
    ASSERT_CONTAINS(difference_out, "difference(BallDyn(a), BallDyn(b))");
}

// ================================================================
// Tests — std_io dispatch (compile_io_call), coverage wave 3 (issue #63)
// ================================================================

TEST(compile_std_io_print_error) {
    auto prog = build_program(
        call("std_io", "print_error", make_msg("PrintInput", {{"message", lit_string("oops")}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::cerr");
    ASSERT_NOT_CONTAINS(out, "/* std_io.print_error */");
}

TEST(compile_std_io_read_line) {
    auto prog = build_program(print_call(call("std_io", "read_line", make_msg("", {}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::getline(std::cin");
}

TEST(compile_std_io_exit) {
    auto prog = build_program(
        call("std_io", "exit", make_msg("", {{"code", lit_int(2)}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::exit(");
}

TEST(compile_std_io_panic) {
    auto prog = build_program(
        call("std_io", "panic", make_msg("", {{"message", lit_string("fatal")}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::exit(1)");
    ASSERT_CONTAINS(out, "std::cerr");
}

TEST(compile_std_io_sleep_ms) {
    auto prog = build_program(
        call("std_io", "sleep_ms", make_msg("", {{"milliseconds", lit_int(10)}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "sleep_for");
}

TEST(compile_std_io_timestamp_ms) {
    auto prog = build_program(print_call(call("std_io", "timestamp_ms", make_msg("", {}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "system_clock::now()");
}

TEST(compile_std_io_random_int) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_io", "random_int", make_msg("", {{"min", lit_int(0)}, {"max", lit_int(10)}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "uniform_int_distribution<int64_t>");
}

TEST(compile_std_io_random_double) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_io", "random_double", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "uniform_real_distribution<double>");
}

TEST(compile_std_io_env_get) {
    auto prog = build_program(print_call(
        call("std_io", "env_get", make_msg("", {{"name", lit_string("PATH")}}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::getenv(");
}

TEST(compile_std_io_args_get) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_io", "args_get", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::vector<std::any>{}");
}

// ================================================================
// Tests — std_fs dispatch (compile_fs_call)
// ================================================================

TEST(compile_std_fs_file_read) {
    auto prog = build_program(print_call(
        call("std_fs", "file_read", make_msg("", {{"path", lit_string("a.txt")}}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::ifstream");
    ASSERT_NOT_CONTAINS(out, "/* std_fs.file_read */");
}

TEST(compile_std_fs_file_write) {
    auto prog = build_program(call("std_fs", "file_write", make_msg("", {
        {"path", lit_string("a.txt")}, {"content", lit_string("hi")}
    })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::ofstream");
}

TEST(compile_std_fs_file_exists) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_fs", "file_exists", make_msg("", {{"path", lit_string("a.txt")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::filesystem::exists");
}

TEST(compile_std_fs_file_delete) {
    auto prog = build_program(
        call("std_fs", "file_delete", make_msg("", {{"path", lit_string("a.txt")}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::filesystem::remove");
}

TEST(compile_std_fs_dir_list) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_fs", "dir_list", make_msg("", {{"path", lit_string(".")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "directory_iterator");
}

TEST(compile_std_fs_dir_create) {
    auto prog = build_program(
        call("std_fs", "dir_create", make_msg("", {{"path", lit_string("d")}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "create_directories");
}

TEST(compile_std_fs_dir_exists) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_fs", "dir_exists", make_msg("", {{"path", lit_string("d")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "is_directory");
}

// ================================================================
// Tests — std_time dispatch (compile_time_call)
// ================================================================

TEST(compile_std_time_now) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "now", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "system_clock::now()");
    ASSERT_NOT_CONTAINS(out, "/* std_time.now */");
}

TEST(compile_std_time_now_micros) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "now_micros", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "microseconds");
}

TEST(compile_std_time_duration_add) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "duration_add", make_msg("", {{"left", lit_int(1)}, {"right", lit_int(2)}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "+");
}

TEST(compile_std_time_duration_subtract) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "duration_subtract", make_msg("", {{"left", lit_int(5)}, {"right", lit_int(2)}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "-");
}

TEST(compile_std_time_format_timestamp) {
    auto prog = build_program(print_call(
        call("std_time", "format_timestamp", make_msg("", {{"timestamp_ms", lit_int(0)}}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_format_timestamp(");
}

TEST(compile_std_time_parse_timestamp) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "parse_timestamp", make_msg("", {{"value", lit_string("2024-01-01T00:00:00Z")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_parse_timestamp(");
}

// ================================================================
// Tests — cpp_std dispatch (compile_cpp_std_call): pointer ops, casts,
// smart pointers, preprocessor, RAII helpers.
// ================================================================

TEST(compile_cpp_std_deref_and_address_of) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("cpp_std", "deref", make_msg("", {{"pointer", ref("p")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "(*p)");

    auto prog2 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "address_of", make_msg("", {{"value", ref("x")}})))));
    auto out2 = compile_program(prog2);
    ASSERT_CONTAINS(out2, "(&x)");
}

TEST(compile_cpp_std_arrow) {
    auto prog = build_program(print_call(std_unary("to_string", call("cpp_std", "arrow", make_msg("", {
        {"pointer", ref("p")}, {"member", lit_string("field")}
    })))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "p->field");
}

TEST(compile_cpp_std_ptr_cast_all_kinds) {
    auto make_cast = [](const std::string& kind) {
        return call("cpp_std", "ptr_cast", make_msg("", {
            {"value", ref("v")},
            {"target_type", lit_string("Foo*")},
            {"cast_kind", lit_string(kind)}
        }));
    };
    ASSERT_CONTAINS(compile_program(build_program(print_call(std_unary("to_string", make_cast("static"))))), "static_cast<Foo*>(v)");
    ASSERT_CONTAINS(compile_program(build_program(print_call(std_unary("to_string", make_cast("dynamic"))))), "dynamic_cast<Foo*>(v)");
    ASSERT_CONTAINS(compile_program(build_program(print_call(std_unary("to_string", make_cast("reinterpret"))))), "reinterpret_cast<Foo*>(v)");
    ASSERT_CONTAINS(compile_program(build_program(print_call(std_unary("to_string", make_cast("const"))))), "const_cast<Foo*>(v)");
    // Unknown/default cast_kind falls back to a C-style cast.
    ASSERT_CONTAINS(compile_program(build_program(print_call(std_unary("to_string", make_cast("weird"))))), "(Foo*)(v)");
}

TEST(compile_cpp_std_new_delete_sizeof_alignof) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_new", make_msg("", {{"type", lit_string("int")}})))));
    ASSERT_CONTAINS(compile_program(prog), "new int()");

    auto prog2 = build_program(
        call("cpp_std", "cpp_delete", make_msg("", {{"pointer", ref("p")}})));
    ASSERT_CONTAINS(compile_program(prog2), "delete p");

    auto prog3 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_sizeof", make_msg("", {{"type_or_expr", lit_string("int")}})))));
    ASSERT_CONTAINS(compile_program(prog3), "sizeof(int)");

    auto prog4 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_alignof", make_msg("", {{"type", lit_string("int")}})))));
    ASSERT_CONTAINS(compile_program(prog4), "alignof(int)");
}

TEST(compile_cpp_std_move_forward) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_move", make_msg("", {{"pointer", ref("x")}})))));
    ASSERT_CONTAINS(compile_program(prog), "std::move(x)");

    auto prog2 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_forward", make_msg("", {{"pointer", ref("x")}})))));
    ASSERT_CONTAINS(compile_program(prog2), "std::forward<decltype(x)>(x)");
}

TEST(compile_cpp_std_smart_pointers) {
    auto uniq = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_make_unique", make_msg("", {{"type", lit_string("Foo")}})))));
    ASSERT_CONTAINS(compile_program(uniq), "std::make_unique<Foo>()");

    auto shared = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_make_shared", make_msg("", {{"type", lit_string("Foo")}})))));
    ASSERT_CONTAINS(compile_program(shared), "std::make_shared<Foo>()");

    auto get1 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_unique_ptr_get", make_msg("", {{"pointer", ref("p")}})))));
    ASSERT_CONTAINS(compile_program(get1), "p.get()");

    auto get2 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_shared_ptr_get", make_msg("", {{"pointer", ref("p")}})))));
    ASSERT_CONTAINS(compile_program(get2), "p.get()");

    auto uc = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_shared_ptr_use_count", make_msg("", {{"pointer", ref("p")}})))));
    ASSERT_CONTAINS(compile_program(uc), "p.use_count()");
}

TEST(compile_cpp_std_decltype_auto_init_list) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_decltype", make_msg("", {{"pointer", ref("x")}})))));
    ASSERT_CONTAINS(compile_program(prog), "decltype(x)");

    auto prog2 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_auto", make_msg("", {})))));
    ASSERT_NOT_CONTAINS(compile_program(prog2), "/* cpp_std.cpp_auto */");

    auto prog3 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "init_list", make_msg("", {{"a", lit_int(1)}, {"b", lit_int(2)}})))));
    auto out3 = compile_program(prog3);
    ASSERT_CONTAINS(out3, "{");
    ASSERT_CONTAINS(out3, "}");
}

TEST(compile_cpp_std_static_assert_namespace_nullptr) {
    auto prog = build_program(
        call("cpp_std", "static_assert", make_msg("", {
            {"condition", lit_bool(true)}, {"message", lit_string("must hold")}
        })));
    ASSERT_CONTAINS(compile_program(prog), "static_assert(");

    auto prog2 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "nullptr", make_msg("", {})))));
    ASSERT_CONTAINS(compile_program(prog2), "nullptr");
}

TEST(compile_cpp_std_ifdef_defined) {
    auto prog = build_program(call("cpp_std", "cpp_ifdef", make_msg("", {
        {"symbol", lit_string("DEBUG")},
        {"then_body", print_call(lit_string("on"))},
        {"else_body", print_call(lit_string("off"))}
    })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "#ifdef DEBUG");
    ASSERT_CONTAINS(out, "#else");

    auto prog2 = build_program(print_call(std_unary("to_string",
        call("cpp_std", "cpp_defined", make_msg("", {{"pointer", ref("SYM")}})))));
    ASSERT_CONTAINS(compile_program(prog2), "defined(");
}

TEST(compile_cpp_std_scope_exit_and_destructor) {
    auto prog = build_program(call("cpp_std", "cpp_scope_exit", make_msg("", {
        {"cleanup", print_call(lit_string("bye"))}
    })));
    ASSERT_CONTAINS(compile_program(prog), "_ScopeExit");

    auto prog2 = build_program(call("cpp_std", "cpp_destructor", make_msg("", {
        {"class_name", lit_string("Foo")},
        {"body", print_call(lit_string("dtor"))}
    })));
    ASSERT_CONTAINS(compile_program(prog2), "~Foo()");
}

// ================================================================
// Tests — remaining std_concurrency dispatch (compile_concurrency_call)
// beyond the pre-existing mutex_lock coverage.
// ================================================================

TEST(compile_std_concurrency_thread_spawn_join_detach) {
    auto spawn = build_program(call("std_concurrency", "thread_spawn", make_msg("", {
        {"body", print_call(lit_string("running"))}
    })));
    ASSERT_CONTAINS(compile_program(spawn), "std::thread ");

    auto join = build_program(
        call("std_concurrency", "thread_join", make_msg("", {{"handle", ref("t")}})));
    ASSERT_CONTAINS(compile_program(join), ".join()");

    auto detach = build_program(
        call("std_concurrency", "thread_detach", make_msg("", {{"handle", ref("t")}})));
    ASSERT_CONTAINS(compile_program(detach), ".detach()");
}

TEST(compile_std_concurrency_mutex_create_and_unlock) {
    auto create = build_program(call("std_concurrency", "mutex_create", make_msg("", {
        {"name", lit_string("mtx")}
    })));
    ASSERT_CONTAINS(compile_program(create), "std::mutex ");

    auto unlock = build_program(
        call("std_concurrency", "mutex_unlock", make_msg("", {{"mutex", ref("mtx")}})));
    ASSERT_CONTAINS(compile_program(unlock), ".unlock()");
}

TEST(compile_std_concurrency_scoped_and_unique_lock) {
    auto scoped = build_program(call("std_concurrency", "scoped_lock", make_msg("", {
        {"mutex", ref("mtx")}, {"body", print_call(lit_string("critical"))}
    })));
    ASSERT_CONTAINS(compile_program(scoped), "lock_guard<std::mutex>");

    auto unique = build_program(call("std_concurrency", "unique_lock", make_msg("", {
        {"mutex", ref("mtx")}, {"name", lit_string("lk")}
    })));
    ASSERT_CONTAINS(compile_program(unique), "unique_lock<std::mutex>");
}

TEST(compile_std_concurrency_atomics) {
    auto load = build_program(print_call(std_unary("to_string",
        call("std_concurrency", "atomic_load", make_msg("", {{"value", ref("x")}})))));
    ASSERT_CONTAINS(compile_program(load), ".load()");

    auto store = build_program(call("std_concurrency", "atomic_store", make_msg("", {
        {"value", ref("x")}, {"new_value", lit_int(5)}
    })));
    ASSERT_CONTAINS(compile_program(store), ".store(");

    auto cmpxchg = build_program(print_call(std_unary("to_string",
        call("std_concurrency", "atomic_compare_exchange", make_msg("", {
            {"value", ref("x")}, {"expected", ref("e")}, {"desired", ref("d")}
        })))));
    ASSERT_CONTAINS(compile_program(cmpxchg), ".compare_exchange_strong(");

    auto fetch_add = build_program(print_call(std_unary("to_string",
        call("std_concurrency", "atomic_fetch_add", make_msg("", {
            {"value", ref("x")}, {"delta", lit_int(1)}
        })))));
    ASSERT_CONTAINS(compile_program(fetch_add), ".fetch_add(");
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
