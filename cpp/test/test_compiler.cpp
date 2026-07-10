// Ball C++ Compiler Test Suite
// Verifies that the compiler generates valid C++ code from Ball programs.

#include "compiler.h"
#include "ball_ir.h"
#include "ball_file.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
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

// #18 Stage 5: the compiler consumes protobuf-free ball::ir, so these builders
// construct programs as proto3-JSON (nlohmann::json) directly — no libprotobuf,
// no proto/json bridge. Each helper emits the exact JSON shape the
// encoder produces and `ball::ir::parseProgram` reads.
using json = ball::ir::json;

json lit_int(int64_t val) {
    json j;
    j["literal"]["intValue"] = std::to_string(val);  // proto3-JSON int64 is a string
    return j;
}

json lit_double(double val) {
    json j;
    j["literal"]["doubleValue"] = val;
    return j;
}

json lit_string(const std::string& val) {
    json j;
    j["literal"]["stringValue"] = val;
    return j;
}

json lit_bool(bool val) {
    json j;
    j["literal"]["boolValue"] = val;
    return j;
}

json ref(const std::string& name) {
    json j;
    j["reference"]["name"] = name;
    return j;
}

json call(const std::string& module, const std::string& function,
          json input = json(nullptr)) {
    json j;
    j["call"]["module"] = module;
    j["call"]["function"] = function;
    if (!input.is_null()) j["call"]["input"] = std::move(input);
    return j;
}

json make_msg(const std::string& type_name,
              std::vector<std::pair<std::string, json>> fields) {
    json j;
    j["messageCreation"]["typeName"] = type_name;
    if (!fields.empty()) {
        json arr = json::array();
        for (auto& [name, value] : fields) {
            json f;
            f["name"] = name;
            f["value"] = std::move(value);
            arr.push_back(std::move(f));
        }
        j["messageCreation"]["fields"] = std::move(arr);
    }
    return j;
}

json std_call(const std::string& function, json input) {
    return call("std", function, std::move(input));
}

json std_binary(const std::string& function, json left, json right) {
    return std_call(function, make_msg("BinaryInput", {
        {"left", std::move(left)},
        {"right", std::move(right)}
    }));
}

json std_unary(const std::string& fn, json value) {
    return std_call(fn, make_msg("UnaryInput", {
        {"value", std::move(value)}
    }));
}

json print_call(json msg) {
    return std_call("print", make_msg("PrintInput", {
        {"message", std::move(msg)}
    }));
}

// A statement wrapping an expression: {"expression": <expr>}.
json stmt_expr(json e) {
    json s;
    s["expression"] = std::move(e);
    return s;
}

// A `let` statement: {"let": {"name": name, "value": <expr>}}.
json stmt_let(const std::string& name, json value) {
    json s;
    s["let"]["name"] = name;
    if (!value.is_null()) s["let"]["value"] = std::move(value);
    return s;
}

// A block expression: {"block": {"statements": [...], "result": <expr>}}.
json block(std::vector<json> statements, json result = json(nullptr)) {
    json j;
    json blk = json::object();
    if (!statements.empty()) {
        json arr = json::array();
        for (auto& s : statements) arr.push_back(std::move(s));
        blk["statements"] = std::move(arr);
    }
    if (!result.is_null()) blk["result"] = std::move(result);
    j["block"] = std::move(blk);
    return j;
}

// A field access: {"fieldAccess": {"object": <expr>, "field": name}}.
json field_access(json object, const std::string& field) {
    json j;
    j["fieldAccess"]["field"] = field;
    if (!object.is_null()) j["fieldAccess"]["object"] = std::move(object);
    return j;
}

// A list literal: {"literal": {"listValue": {"elements": [...]}}}.
json lit_list(std::vector<json> elems) {
    json j;
    json lv = json::object();
    if (!elems.empty()) {
        json arr = json::array();
        for (auto& e : elems) arr.push_back(std::move(e));
        lv["elements"] = std::move(arr);
    }
    j["literal"]["listValue"] = std::move(lv);
    return j;
}

// A lambda expression: {"lambda": {"name": "", "body": <expr>}}.
json lambda_expr(json body) {
    json j;
    j["lambda"]["name"] = "";
    j["lambda"]["body"] = std::move(body);
    return j;
}

json build_program(json body) {
    json program;
    json mod;
    mod["name"] = "main";
    json func;
    func["name"] = "main";
    func["body"] = std::move(body);
    mod["functions"].push_back(std::move(func));
    program["modules"].push_back(std::move(mod));
    program["entryModule"] = "main";
    program["entryFunction"] = "main";
    return program;
}

std::string compile_program(const json& prog) {
    CppCompiler compiler(ball::ir::parseProgram(prog));
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
    auto prog = build_program(block(
        {stmt_expr(std_call("if", make_msg("IfInput", {
            {"condition", lit_bool(true)},
            {"then", print_call(lit_string("yes"))},
            {"else", print_call(lit_string("no"))}
        })))},
        lit_int(0)));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "if");
}

TEST(compile_for_loop) {
    auto init = block({stmt_let("i", lit_int(0))}, lit_int(0));

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
    auto cases_list = lit_list({
        make_msg("", {{"value", lit_int(1)}, {"body", print_call(lit_string("one"))}}),
        make_msg("", {{"value", lit_int(2)}, {"body", print_call(lit_string("two"))}}),
        make_msg("", {{"is_default", lit_bool(true)}, {"body", print_call(lit_string("other"))}}),
    });

    auto prog = build_program(block(
        {stmt_expr(std_call("switch", make_msg("SwitchInput", {
            {"subject", ref("x")},
            {"cases", std::move(cases_list)}
        })))},
        lit_int(0)));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "__switch_subj");
    ASSERT_CONTAINS(out, "if (");
    ASSERT_CONTAINS(out, "else");
}

// ================================================================
// Tests — Try-catch compilation (was simplified)
// ================================================================

TEST(compile_try_catch) {
    auto catches_list = lit_list({
        make_msg("", {
            {"variable", lit_string("e")},
            {"body", print_call(lit_string("caught"))}
        })
    });

    auto prog = build_program(block(
        {stmt_expr(std_call("try", make_msg("TryInput", {
            {"body", print_call(lit_string("try body"))},
            {"catches", std::move(catches_list)}
        })))},
        lit_int(0)));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "try");
    ASSERT_CONTAINS(out, "catch");
    ASSERT_NOT_CONTAINS(out, "// catch handler");
}

TEST(compile_try_catch_finally) {
    auto catches_list = lit_list({
        make_msg("", {
            {"variable", lit_string("e")},
            {"body", print_call(lit_string("caught"))}
        })
    });

    auto prog = build_program(block(
        {stmt_expr(std_call("try", make_msg("TryInput", {
            {"body", print_call(lit_string("try body"))},
            {"catches", std::move(catches_list)},
            {"finally", print_call(lit_string("cleanup"))}
        })))},
        lit_int(0)));
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
    auto prog = build_program(block(
        {stmt_let("x", lit_int(42))},
        print_call(std_unary("to_string", ref("x")))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "x");
    ASSERT_CONTAINS(out, "42");
}

// ================================================================
// Tests — Block compilation
// ================================================================

TEST(compile_block_with_let) {
    auto prog = build_program(block(
        {stmt_let("a", lit_int(10)), stmt_let("b", lit_int(20))},
        print_call(std_unary("to_string", std_binary("add", ref("a"), ref("b"))))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "auto a");
    ASSERT_CONTAINS(out, "auto b");
}

// ================================================================
// Tests — Field access compilation
// ================================================================

TEST(compile_field_access) {
    auto access = field_access(ref("point"), "x");

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
    json program;
    json mod;
    mod["name"] = "main";
    json helper;
    helper["name"] = "double_it";
    helper["body"] = std_binary("multiply", ref("input"), lit_int(2));
    mod["functions"].push_back(std::move(helper));
    json main_fn;
    main_fn["name"] = "main";
    main_fn["body"] =
        print_call(std_unary("to_string", call("main", "double_it", lit_int(21))));
    mod["functions"].push_back(std::move(main_fn));
    program["modules"].push_back(std::move(mod));
    program["entryModule"] = "main";
    program["entryFunction"] = "main";

    auto out = compile_program(program);
    ASSERT_CONTAINS(out, "double_it");
}

// ================================================================
// Tests — Break and continue compilation
// ================================================================

TEST(compile_break) {
    // Build a while loop with break inside as a statement
    auto inner_body = block({stmt_expr(std_call("break", lit_int(0)))}, lit_int(0));

    auto outer = block(
        {stmt_expr(std_call("while", make_msg("WhileInput", {
            {"condition", lit_bool(true)},
            {"body", std::move(inner_body)}
        })))},
        lit_int(0));

    auto prog = build_program(std::move(outer));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "break");
}

TEST(compile_continue) {
    auto inner_body = block({stmt_expr(std_call("continue", lit_int(0)))}, lit_int(0));

    auto outer = block(
        {stmt_expr(std_call("while", make_msg("WhileInput", {
            {"condition", lit_bool(false)},
            {"body", std::move(inner_body)}
        })))},
        lit_int(0));

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
    json program;
    json mod;
    mod["name"] = "main";

    // Type definition: class NumBox {} (metadata is a plain proto3-JSON Struct)
    json td;
    td["name"] = "NumBox";
    td["descriptor"]["name"] = "NumBox";
    td["metadata"]["kind"] = "class";
    mod["typeDefs"].push_back(std::move(td));

    // Conversion operator: operator int()
    json conv;
    conv["name"] = "NumBox.operator_int";
    conv["outputType"] = "int";
    conv["isBase"] = false;
    conv["metadata"]["kind"] = "operator";
    conv["metadata"]["is_operator"] = true;
    conv["metadata"]["is_conversion_operator"] = true;
    conv["metadata"]["conversion_type"] = "int";
    conv["body"] = lit_int(7);
    mod["functions"].push_back(std::move(conv));

    // Entry function.
    json main_fn;
    main_fn["name"] = "main";
    main_fn["body"] = lit_int(0);
    mod["functions"].push_back(std::move(main_fn));

    program["modules"].push_back(std::move(mod));
    program["entryModule"] = "main";
    program["entryFunction"] = "main";

    auto out = compile_program(program);
    ASSERT_CONTAINS(out, "operator int64_t(");
}

TEST(compile_labeled_break_emits_goto) {
    // labeled(outer) { for (...) { break outer; } }
    // Must compile to: for (...) { goto __ball_break_outer; } __ball_break_outer:;
    auto for_body = block(
        {stmt_expr(std_call("break", make_msg("", {{"label", lit_string("outer")}})))},
        lit_int(0));

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

    auto prog = build_program(block(
        {stmt_expr(std::move(labeled_call))}, lit_int(0)));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "goto __ball_break_outer");
    ASSERT_CONTAINS(out, "__ball_break_outer:;");
}

TEST(compile_labeled_continue_emits_goto) {
    auto for_body = block(
        {stmt_expr(std_call("continue", make_msg("", {{"label", lit_string("loop")}})))},
        lit_int(0));

    auto while_call = std_call("while", make_msg("WhileInput", {
        {"condition", lit_bool(true)},
        {"body", std::move(for_body)}
    }));

    auto labeled_call = std_call("labeled", make_msg("LabeledInput", {
        {"label", lit_string("loop")},
        {"body", std::move(while_call)}
    }));

    auto prog = build_program(block(
        {stmt_expr(std::move(labeled_call))}, lit_int(0)));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "goto __ball_continue_loop");
    ASSERT_CONTAINS(out, "__ball_continue_loop:;");
    ASSERT_CONTAINS(out, "__ball_break_loop:;");
}

TEST(for_in_expression_with_return_fails_loud) {
    // A `for` used in VALUE position (here, a `let` initializer) whose body
    // contains a `return`. This cannot be lowered to a portable-C++ IIFE (the
    // return can't cross the lambda boundary), and previously the compiler
    // SILENTLY DROPPED the loop body — emitting an empty IIFE so any program
    // hitting this shape computed the wrong result with no error. The fix emits
    // a loud runtime throw instead (fail-loud invariant), NOT the old no-op stub.
    auto for_body = block(
        {stmt_expr(std_call("return", make_msg("", {{"value", lit_int(5)}})))},
        lit_int(0));

    auto for_call = std_call("for", make_msg("ForInput", {
        {"init", lit_int(0)},
        {"condition", lit_bool(true)},
        {"update", lit_int(0)},
        {"body", std::move(for_body)}
    }));

    // Bind the loop to a local, forcing the loop into expression (value) context.
    auto prog = build_program(block(
        {stmt_let("x", std::move(for_call))}, lit_int(0)));
    auto out = compile_program(prog);
    // Fail-loud: our specific runtime-throw message, and NOT the old silent-drop
    // empty-IIFE stub comment.
    ASSERT_CONTAINS(out, "for-loop used in expression (value) position");
    ASSERT_NOT_CONTAINS(out, "// for loop (return/label body");
}

TEST(while_in_expression_with_return_fails_loud) {
    // The `while` analog of for_in_expression_with_return_fails_loud.
    auto while_body = block(
        {stmt_expr(std_call("return", make_msg("", {{"value", lit_int(7)}})))},
        lit_int(0));

    auto while_call = std_call("while", make_msg("WhileInput", {
        {"condition", lit_bool(true)},
        {"body", std::move(while_body)}
    }));

    auto prog = build_program(block(
        {stmt_let("y", std::move(while_call))}, lit_int(0)));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "while-loop used in expression (value) position");
}

TEST(compile_try_catch_typed_dispatches_by_type) {
    // Two typed catch clauses + one untyped fallback. The emitted C++ must:
    //   1. Wrap the body in try
    //   2. Have a BallException catch with if/else dispatch on type_name
    //   3. Have a std::exception catch that runs the untyped body (not `throw;`)
    auto catches_list = lit_list({
        make_msg("", {
            {"type", lit_string("NotFound")},
            {"variable", lit_string("e")},
            {"body", print_call(lit_string("not-found"))}
        }),
        make_msg("", {
            {"type", lit_string("ParseError")},
            {"variable", lit_string("e")},
            {"body", print_call(lit_string("parse-error"))}
        }),
        make_msg("", {
            {"variable", lit_string("e")},
            {"body", print_call(lit_string("fallback"))}
        }),
    });

    auto prog = build_program(block(
        {stmt_expr(std_call("try", make_msg("TryInput", {
            {"body", print_call(lit_string("try body"))},
            {"catches", std::move(catches_list)}
        })))},
        lit_int(0)));
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

// `[for (var i = 0; i < 3; i++) i * i]` — a C-style collection_for inside a
// list literal. Before the fix the C++ compiler only handled the for-EACH form
// (it read an `iterable` field that doesn't exist here), so the loop body was
// dropped and the list compiled empty.
TEST(compile_collection_for_cstyle_list) {
    // init: block { var i = 0; }
    auto init = block({stmt_let("i", lit_int(0))});

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
    auto init = block({stmt_let("i", lit_int(0))});

    auto body_lambda = lambda_expr(ref("i"));

    auto cfor = std_call("collection_for", make_msg("", {
        {"init", std::move(init)},
        {"condition", std_binary("less_than", ref("i"), lit_int(3))},
        {"update", std_call("post_increment", make_msg("", {{"value", ref("i")}}))},
        {"body", std::move(body_lambda)},
    }));

    auto prog = build_program(block(
        {stmt_let("fns", lit_list({std::move(cfor)}))}));
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
static void add_base_module(json& prog, const std::string& name) {
    json mod;
    mod["name"] = name;
    json fn;
    fn["name"] = "__marker__";
    fn["isBase"] = true;
    mod["functions"].push_back(std::move(fn));
    prog["modules"].push_back(std::move(mod));
}

json mem_call(const std::string& function, const std::string& type_name,
              std::vector<std::pair<std::string, json>> fields) {
    return call("std_memory", function, make_msg(type_name, std::move(fields)));
}

TEST(compile_std_memory_preamble_declares_runtime_arrays) {
    json prog = build_program(
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
    json prog = build_program(mem_call(
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
    json prog = build_program(mem_call(
        "memory_write_i32", "MemWriteInput",
        {{"address", lit_int(0)}, {"value", lit_int(42)}}));
    add_base_module(prog, "std_memory");
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_memory_write_i32(static_cast<int64_t>(0), static_cast<int64_t>(42))");
    ASSERT_CONTAINS(out, "inline double _ball_memory_read_f64(int64_t address)");
    ASSERT_CONTAINS(out, "inline double _ball_memory_read_f32(int64_t address)");
}

TEST(compile_std_memory_bulk_and_ptr_ops) {
    json prog = build_program(mem_call(
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
    json prog = build_program(mem_call(
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
    json prog =
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
    json prog = build_program(
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
static json set_lit(std::vector<json> elems) {
    json elements_expr = lit_list(std::move(elems));
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

TEST(compile_std_fs_file_read_bytes) {
    // issue #319: previously fell to the default `/* std_fs.file_read_bytes */`
    // comment-only no-op.
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_fs", "file_read_bytes", make_msg("", {{"path", lit_string("a.bin")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::ios::binary");
    ASSERT_CONTAINS(out, "std::ifstream");
    ASSERT_NOT_CONTAINS(out, "/* std_fs.file_read_bytes */");
}

TEST(compile_std_fs_file_write_bytes) {
    // issue #319: previously fell to the default no-op comment, silently
    // dropping every byte written.
    json bytes;
    bytes["literal"]["bytesValue"] = "AQAC";  // base64 of bytes {0x01, 0x00, 0x02}
    auto prog = build_program(call("std_fs", "file_write_bytes", make_msg("", {
        {"path", lit_string("a.bin")}, {"content", std::move(bytes)}
    })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_listPtr()");
    ASSERT_CONTAINS(out, "std::ios::binary");
    ASSERT_NOT_CONTAINS(out, "/* std_fs.file_write_bytes */");
}

TEST(compile_std_fs_file_append) {
    // issue #319: previously fell to the default no-op comment instead of
    // appending (ios::app).
    auto prog = build_program(call("std_fs", "file_append", make_msg("", {
        {"path", lit_string("a.txt")}, {"content", lit_string("more")}
    })));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::ios::app");
    ASSERT_NOT_CONTAINS(out, "/* std_fs.file_append */");
}

TEST(compile_std_fs_unknown_fn_throws_at_compile_time) {
    // issue #319: the default case for an unimplemented std_fs.* function
    // must fail loud (compile-time throw), not silently emit a no-op
    // comment.
    auto prog = build_program(
        call("std_fs", "totally_unimplemented_fn", make_msg("", {{"path", lit_string("a.txt")}})));
    bool threw = false;
    try {
        compile_program(prog);
    } catch (const std::exception& e) {
        threw = true;
        std::string msg = e.what();
        ASSERT_CONTAINS(msg, "std_fs.totally_unimplemented_fn");
        ASSERT_CONTAINS(msg, "not implemented in C++ direct compile");
    }
    ASSERT_TRUE(threw);
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

// DateTime component getters (issue #328): year/month/day/hour/minute/second
// previously fell through compile_time_call's default case and spliced a
// bare `/* std_time.<fn> */` comment in wherever a value was expected —
// invalid C++ that only surfaced as a confusing error at the *generated
// program's* compile step. Each must now emit a call to its
// ball_emit_runtime.h `_ball_time_*` helper (current-UTC-instant component
// getters, matching the Dart engine's `DateTime.now().toUtc().<field>`).

TEST(compile_std_time_year) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "year", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_time_year()");
    ASSERT_NOT_CONTAINS(out, "/* std_time.year */");
}

TEST(compile_std_time_month) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "month", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_time_month()");
    ASSERT_NOT_CONTAINS(out, "/* std_time.month */");
}

TEST(compile_std_time_day) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "day", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_time_day()");
    ASSERT_NOT_CONTAINS(out, "/* std_time.day */");
}

TEST(compile_std_time_hour) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "hour", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_time_hour()");
    ASSERT_NOT_CONTAINS(out, "/* std_time.hour */");
}

TEST(compile_std_time_minute) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "minute", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_time_minute()");
    ASSERT_NOT_CONTAINS(out, "/* std_time.minute */");
}

TEST(compile_std_time_second) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "second", make_msg("", {})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "_ball_time_second()");
    ASSERT_NOT_CONTAINS(out, "/* std_time.second */");
}

TEST(compile_std_time_unknown_fn_throws_at_compile_time) {
    // issue #328: the default case for an unimplemented std_time.* function
    // must fail loud (compile-time throw), not silently emit a no-op
    // comment spliced in as an expression.
    auto prog = build_program(print_call(std_unary("to_string",
        call("std_time", "totally_unimplemented_fn", make_msg("", {})))));
    bool threw = false;
    try {
        compile_program(prog);
    } catch (const std::exception& e) {
        threw = true;
        std::string msg = e.what();
        ASSERT_CONTAINS(msg, "std_time.totally_unimplemented_fn");
        ASSERT_CONTAINS(msg, "not implemented in C++ direct compile");
    }
    ASSERT_TRUE(threw);
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
// Coverage grind (issue #63): per-arm unit tests for compile_std_call
// dispatch arms and compile_call intrinsics not reached by the
// conformance corpus. Each drives a hand-built ball::ir shape.
// ================================================================

// null literal reference (name "null") — the is_null() detector in the
// equals/not_equals arm treats this as a null operand.
static json null_ref() { return ref("null"); }

TEST(std_equals_left_null_emits_has_value) {
    // is_null(left) path (right operand non-null).
    auto prog = build_program(print_call(std_unary("to_string",
        std_binary("equals", null_ref(), lit_int(1)))));
    ASSERT_CONTAINS(compile_program(prog), ".has_value()");
    auto prog2 = build_program(print_call(std_unary("to_string",
        std_binary("not_equals", null_ref(), lit_int(1)))));
    ASSERT_CONTAINS(compile_program(prog2), ".has_value()");
}

TEST(std_pre_increment_index_target_read_modify_write) {
    auto idx = call("std", "index", make_msg("", {
        {"target", ref("a")}, {"index", lit_int(0)}}));
    auto prog = build_program(std_call("pre_increment",
        make_msg("", {{"value", std::move(idx)}})));
    ASSERT_CONTAINS(compile_program(prog), "ball_set(");
}

TEST(std_post_increment_index_target_returns_old) {
    auto idx = call("std", "index", make_msg("", {
        {"target", ref("a")}, {"index", lit_int(1)}}));
    auto prog = build_program(std_call("post_decrement",
        make_msg("", {{"value", std::move(idx)}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "ball_set(");
    ASSERT_CONTAINS(out, "__old");
}

TEST(std_string_join_emits_reduce_lambda) {
    auto prog = build_program(print_call(std_call("string_join", make_msg("", {
        {"list", lit_list({lit_string("a"), lit_string("b")})},
        {"separator", lit_string(",")}}))));
    ASSERT_CONTAINS(compile_program(prog), "for(size_t i=0;i<v.size()");
}

TEST(std_regex_match_emits_regex_search) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_binary("regex_match", lit_string("abc"), lit_string("a.c")))));
    ASSERT_CONTAINS(compile_program(prog), "std::regex_search");
}

TEST(std_regex_find_emits_smatch) {
    auto prog = build_program(print_call(
        std_binary("regex_find", lit_string("abc"), lit_string("a.c"))));
    ASSERT_CONTAINS(compile_program(prog), "std::smatch");
}

TEST(std_regex_find_all_emits_sregex_iterator) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_binary("regex_find_all", lit_string("abc"), lit_string("a")))));
    ASSERT_CONTAINS(compile_program(prog), "std::sregex_iterator");
}

TEST(std_regex_replace_first_only) {
    auto prog = build_program(print_call(std_call("regex_replace", make_msg("", {
        {"value", lit_string("aaa")}, {"from", lit_string("a")},
        {"to", lit_string("b")}}))));
    ASSERT_CONTAINS(compile_program(prog), "format_first_only");
}

TEST(std_regex_replace_all_no_first_only) {
    auto prog = build_program(print_call(std_call("regex_replace_all", make_msg("", {
        {"value", lit_string("aaa")}, {"from", lit_string("a")},
        {"to", lit_string("b")}}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::regex_replace");
    ASSERT_NOT_CONTAINS(out, "format_first_only");
}

TEST(std_string_interpolation_list_parts) {
    auto prog = build_program(print_call(std_call("string_interpolation",
        make_msg("", {{"parts", lit_list({lit_string("x="), lit_int(1)})}}))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "std::ostringstream _ss");
    ASSERT_CONTAINS(out, "_ss<<");
}

TEST(std_string_interpolation_value_fallback) {
    auto prog = build_program(print_call(std_call("string_interpolation",
        make_msg("", {{"value", lit_int(7)}}))));
    ASSERT_CONTAINS(compile_program(prog), "std::to_string(");
}

TEST(std_string_is_empty) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_call("string_is_empty", make_msg("", {{"value", lit_string("x")}})))));
    ASSERT_CONTAINS(compile_program(prog), ".empty())");
}

TEST(std_null_coalesce_emits_has_value_ternary) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_binary("null_coalesce", ref("a"), lit_int(0)))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, ".has_value() ? BallDyn(");
}

TEST(std_as_passthrough) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_call("as", make_msg("", {{"value", lit_int(42)}})))));
    ASSERT_CONTAINS(compile_program(prog), "42");
}

TEST(std_spread_and_null_spread_passthrough) {
    auto prog = build_program(std_call("spread",
        make_msg("", {{"value", lit_list({lit_int(1)})}})));
    ASSERT_CONTAINS(compile_program(prog), "1");
    auto prog2 = build_program(std_call("null_spread",
        make_msg("", {{"value", lit_list({lit_int(2)})}})));
    ASSERT_CONTAINS(compile_program(prog2), "2");
}

TEST(std_await_passthrough) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_call("await", make_msg("", {{"value", lit_int(9)}})))));
    ASSERT_CONTAINS(compile_program(prog), "9");
}

TEST(std_yield_outside_generator_passthrough) {
    auto prog = build_program(std_call("yield",
        make_msg("", {{"value", lit_int(5)}})));
    ASSERT_CONTAINS(compile_program(prog), "5");
}

TEST(std_paren_wraps) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("std", "paren", make_msg("", {{"value", lit_int(3)}})))));
    ASSERT_CONTAINS(compile_program(prog), "(3)");
}

TEST(std_invoke_emits_call) {
    auto prog = build_program(std_call("invoke", make_msg("", {
        {"callee", ref("f")}, {"arg0", lit_int(1)}})));
    ASSERT_CONTAINS(compile_program(prog), "f(");
}

TEST(std_typed_list_empty) {
    auto prog = build_program(std_call("typed_list", make_msg("", {})));
    ASSERT_CONTAINS(compile_program(prog), "std::vector<std::any>{}");
}

TEST(std_typed_list_with_elements) {
    auto prog = build_program(std_call("typed_list",
        make_msg("", {{"elements", lit_list({lit_int(1), lit_int(2)})}})));
    ASSERT_CONTAINS(compile_program(prog), "1");
}

TEST(std_null_aware_access_field) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_call("null_aware_access", make_msg("", {
            {"target", ref("x")}, {"field", lit_string("f")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, ".has_value() ?");
    ASSERT_CONTAINS(out, "\"f\"s");
}

TEST(std_null_aware_call_call_method_invokes) {
    auto prog = build_program(std_call("null_aware_call", make_msg("", {
        {"target", ref("x")}, {"method", lit_string("call")}, {"arg0", lit_int(1)}})));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, ".has_value() ? BallDyn(");
}

TEST(std_null_aware_call_named_method) {
    auto prog = build_program(std_call("null_aware_call", make_msg("", {
        {"target", ref("x")}, {"method", lit_string("toUpperCase")}})));
    ASSERT_CONTAINS(compile_program(prog), ".has_value() ? BallDyn(");
}

TEST(std_null_aware_call_callback) {
    auto prog = build_program(std_call("null_aware_call", make_msg("", {
        {"target", ref("x")}, {"callback", ref("cb")}})));
    ASSERT_CONTAINS(compile_program(prog), ".has_value() ? cb(");
}

TEST(std_null_aware_cascade_returns_target) {
    auto prog = build_program(std_call("null_aware_cascade", make_msg("", {
        {"target", ref("obj")}})));
    ASSERT_CONTAINS(compile_program(prog), "obj");
}

TEST(std_unknown_function_emits_marker) {
    auto prog = build_program(std_call("totally_unknown_xyz", make_msg("", {})));
    ASSERT_CONTAINS(compile_program(prog), "/* std.totally_unknown_xyz */");
}

TEST(std_cascade_with_sections_emits_cascade_self) {
    auto prog = build_program(std_call("cascade", make_msg("", {
        {"target", ref("obj")},
        {"sections", lit_list({call("std", "index", make_msg("", {
            {"target", ref("obj")}, {"index", lit_int(0)}}))})}})));
    ASSERT_CONTAINS(compile_program(prog), "__cascade_self__");
}

TEST(std_cascade_non_list_sections_returns_target) {
    auto prog = build_program(print_call(std_unary("to_string",
        std_call("cascade", make_msg("", {
            {"target", ref("obj")}, {"sections", lit_int(0)}})))));
    ASSERT_CONTAINS(compile_program(prog), "obj");
}

// ── compile_call intrinsics (module "", engine-internal helpers) ──

TEST(intrinsic_ball_user_map) {
    auto prog = build_program(call("", "_ballUserMap", json(nullptr)));
    ASSERT_CONTAINS(compile_program(prog), "BallOrderedMap{}");
}

TEST(intrinsic_ball_new_generator) {
    auto prog = build_program(call("", "_ballNewGenerator", json(nullptr)));
    ASSERT_CONTAINS(compile_program(prog), "BallGenerator{}");
}

TEST(intrinsic_ball_generator_values) {
    auto prog = build_program(call("", "_ballGeneratorValues", ref("g")));
    ASSERT_CONTAINS(compile_program(prog), "_ballGeneratorValues(");
}

TEST(intrinsic_ball_double_to_int64) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("", "_ballDoubleToInt64", make_msg("", {{"value", lit_double(1.5)}})))));
    ASSERT_CONTAINS(compile_program(prog), "_ballDoubleToInt64(");
}

TEST(intrinsic_ball_code_unit_at) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("", "_ballCodeUnitAt", make_msg("", {
            {"s", lit_string("hi")}, {"index", lit_int(0)}})))));
    ASSERT_CONTAINS(compile_program(prog), "ball_code_unit_at(");
}

TEST(intrinsic_ball_is_scalar_predicates) {
    for (const char* fn : {"_ballIsInt", "_ballIsDouble", "_ballIsNum",
                           "_ballIsString", "_ballIsBool", "_ballIsList"}) {
        auto prog = build_program(print_call(std_unary("to_string",
            call("", fn, ref("v")))));
        auto out = compile_program(prog);
        ASSERT_CONTAINS(out, "ball_object_type_matches(");
    }
}

TEST(intrinsic_ball_is_map_excludes_set) {
    auto prog = build_program(print_call(std_unary("to_string",
        call("", "_ballIsMap", make_msg("", {{"arg0", ref("m")}})))));
    auto out = compile_program(prog);
    ASSERT_CONTAINS(out, "ball_is_map_dyn(");
    ASSERT_CONTAINS(out, "!ball_is_ball_set(");
}

TEST(intrinsic_ball_map_values_keys) {
    auto v = build_program(call("", "_ballMapValuesDyn", make_msg("", {{"arg0", ref("m")}})));
    ASSERT_CONTAINS(compile_program(v), "ball_map_values(");
    auto k = build_program(call("", "_ballMapKeysDyn", make_msg("", {{"arg0", ref("m")}})));
    ASSERT_CONTAINS(compile_program(k), "ball_map_keys(");
}

// ── compile_collections_call positional arms (std_collections) ──
// The corpus uses method-style (list.map(...)) which routes through
// compile_method_call; the positional std_collections.* forms below are
// what the self-hosted engine emits and are otherwise unexercised.

static json coll(const std::string& fn, std::vector<std::pair<std::string, json>> fields) {
    return call("std_collections", fn, make_msg("", std::move(fields)));
}

TEST(collections_list_positional_scalar_ops) {
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_get", {{"list", ref("a")}, {"index", lit_int(0)}}))),
        "[static_cast<int64_t>(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_set", {{"list", ref("a")}, {"index", lit_int(0)}, {"value", lit_int(9)}}))),
        "v.set(i,e._val)");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_length", {{"list", ref("a")}}))), ".size())");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_is_empty", {{"list", ref("a")}}))), ".empty()");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_first", {{"list", ref("a")}}))), ".front()");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_last", {{"list", ref("a")}}))), ".back()");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_single", {{"list", ref("a")}}))), "[static_cast<int64_t>(0)]");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_contains", {{"list", ref("a")}, {"value", lit_int(1)}}))), "ball_index_of(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_index_of", {{"list", ref("a")}, {"value", lit_int(1)}}))), "ball_index_of(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_reverse", {{"list", ref("a")}}))), "std::reverse(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_insert", {{"list", ref("a")}, {"index", lit_int(0)}, {"value", lit_int(9)}}))),
        "ball_list_insert(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_remove_at", {{"list", ref("a")}, {"index", lit_int(0)}}))), "ball_list_remove_at(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_reverse", {{"list", ref("a")}}))), "_listPtr()");
}

TEST(collections_list_higher_order_ops) {
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_map", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "r.push_back(std::any(fn(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_foreach", {{"list", ref("a")}, {"callback", ref("cb")}}))), "ball_foreach(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_filter", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "if(_ball_pred_true(std::any(fn(e))))");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_reduce", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "Bad state: No element");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_find", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "if(_ball_pred_true(fn(__e)))return __e;");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_any", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "return true;}return false;}");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_all", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "if(!_ball_pred_true(fn(__e)))return false;");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_none", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "if(_ball_pred_true(fn(__e)))return false;");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_flat_map", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "BallDyn sub(fn(__e));");
}

TEST(collections_list_sort_natural_and_comparator) {
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_sort", {{"list", ref("a")}}))), "ball_natural_less(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_sort", {{"list", ref("a")}, {"compare", lambda_expr(lit_int(0))}}))),
        "std::stable_sort(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_sort_by", {{"list", ref("a")}, {"callback", ref("cb")}}))),
        "p.set(\"left\"s,a);p.set(\"right\"s,b)");
}

TEST(collections_list_slice_take_drop_concat_zip_join) {
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_slice", {{"list", ref("a")}, {"value", lit_int(1)}}))), "ball_sublist(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_slice", {{"list", ref("a")}, {"start", lit_int(1)}, {"end", lit_int(3)}}))),
        "ball_sublist(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_slice", {{"list", ref("a")}}))), "ball_sublist(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_take", {{"list", ref("a")}, {"count", lit_int(2)}}))), "std::min(n,");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_drop", {{"list", ref("a")}, {"count", lit_int(2)}}))), "ball_skip(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_to_list", {{"list", ref("a")}}))), "ball_list_copy(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_concat", {{"left", ref("a")}, {"right", ref("b")}}))), "ball_concat(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_zip", {{"left", ref("a")}, {"right", ref("b")}}))), "\"second\"s");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_join", {{"list", ref("a")}, {"separator", lit_string("-")}}))), "bool first=true");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_join", {{"list", ref("a")}}))), "std::string(\",\")");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("string_join", {{"list", ref("a")}, {"separator", lit_string("-")}}))),
        "r+=ball_to_string(v[static_cast<int64_t>(i)]);}return r;}");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("list_clear", {{"list", ref("a")}}))), "ball_clear(");
}

TEST(collections_map_positional_ops) {
    ASSERT_CONTAINS(compile_program(build_program(coll("map_create", {}))),
        "BallDyn(BallOrderedMap{})");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_get", {{"map", ref("m")}, {"key", lit_string("k")}}))), "static_cast<BallDyn>(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_set", {{"map", ref("m")}, {"key", lit_string("k")}, {"value", lit_int(1)}}))),
        "m.set(static_cast<std::string>(k),v._val)");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_delete", {{"map", ref("m")}, {"key", lit_string("k")}}))),
        "m.erase(static_cast<std::string>(k))");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_contains_key", {{"map", ref("m")}, {"key", lit_string("k")}}))), ".count(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_is_empty", {{"map", ref("m")}}))), ".empty()");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_length", {{"map", ref("m")}}))), ".size())");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_keys", {{"map", ref("m")}}))), "ball_map_keys(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_values", {{"map", ref("m")}}))), "ball_map_values(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_entries", {{"map", ref("m")}}))), "ball_map_entries(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_from_entries", {{"entries", ref("e")}}))), "r.set(static_cast<std::string>");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_merge", {{"left", ref("a")}, {"right", ref("b")}}))), "ball_map_entries(b)");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_map", {{"map", ref("m")}, {"callback", ref("cb")}}))), "BallDyn res(fn(e));");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_filter", {{"map", ref("m")}, {"callback", ref("cb")}}))), "if(_ball_pred_true(fn(e)))");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_contains_value", {{"map", ref("m")}, {"value", lit_int(1)}}))), "ball_map_entries(mp)");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("map_put_if_absent", {{"map", ref("m")}, {"key", lit_string("k")}, {"value", lit_int(1)}}))),
        "ball_map_put_if_absent(");
}

TEST(collections_set_positional_ops) {
    ASSERT_CONTAINS(compile_program(build_program(coll("set_create", {}))),
        "ball_make_set(BallList{})");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_add", {{"set", ref("s")}, {"value", lit_int(1)}}))), "v.push_back(e)");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_remove", {{"set", ref("s")}, {"value", lit_int(1)}}))), "_setBackingList()");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_contains", {{"set", ref("s")}, {"value", lit_int(1)}}))), "if(BallDyn(v[i])==e)return true;");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_length", {{"set", ref("s")}}))), ".size())");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_is_empty", {{"set", ref("s")}}))), ".empty()");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_to_list", {{"set", ref("s")}}))), "ball_list_copy(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_union", {{"left", ref("a")}, {"right", ref("b")}}))), "union_(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_intersection", {{"left", ref("a")}, {"right", ref("b")}}))), "intersection(");
    ASSERT_CONTAINS(compile_program(build_program(
        coll("set_difference", {{"left", ref("a")}, {"right", ref("b")}}))), "difference(");
}

TEST(collections_unknown_fn_emits_marker) {
    ASSERT_CONTAINS(compile_program(build_program(coll("bogus_xyz", {{"list", ref("a")}}))),
        "/* std_collections.bogus_xyz */");
}

// ── compile_method_call arms (empty module + `self` field) ──
// The corpus routes most collection/number/string operations through the
// positional std_collections forms, leaving compile_method_call's STL-shortcut
// arms unexercised. Each is a method-style call `{self, arg0, arg1}`.

static json mcall(const std::string& fn,
                  std::vector<std::pair<std::string, json>> fields) {
    return call("", fn, make_msg("", std::move(fields)));
}

TEST(method_string_pad_and_case_helpers) {
    ASSERT_CONTAINS(compile_program(build_program(mcall("padLeft",
        {{"self", ref("s")}, {"arg0", lit_int(5)}, {"arg1", lit_string("0")}}))),
        "if(static_cast<int64_t>(s.size())>=w)");
    ASSERT_CONTAINS(compile_program(build_program(mcall("padRight",
        {{"self", ref("s")}, {"arg0", lit_int(5)}}))), "std::string r=s; while");
    ASSERT_CONTAINS(compile_program(build_program(mcall("codeUnitAt",
        {{"self", ref("s")}, {"arg0", lit_int(0)}}))), "ball_code_unit_at(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("replaceFirst",
        {{"self", ref("s")}, {"arg0", lit_string("a")}, {"arg1", lit_string("b")}}))),
        "s.replace(p,f.size(),t)");
    ASSERT_CONTAINS(compile_program(build_program(mcall("lastIndexOf",
        {{"self", ref("s")}, {"arg0", lit_string("x")}}))), "s.rfind(p)");
}

TEST(method_number_helpers) {
    ASSERT_CONTAINS(compile_program(build_program(mcall("toDouble", {{"self", ref("n")}}))),
        "_ballToDouble(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("truncate", {{"self", ref("n")}}))),
        "_ballDoubleToInt64(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("toInt", {{"self", ref("n")}}))),
        "_ballDoubleToInt64(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("toString", {{"self", ref("n")}}))),
        "ball_to_string(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("abs", {{"self", ref("n")}}))),
        "std::abs(static_cast<int64_t>(_v))");
    ASSERT_CONTAINS(compile_program(build_program(mcall("round", {{"self", ref("n")}}))),
        "std::round(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("ceil", {{"self", ref("n")}}))),
        "std::ceil(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("floor", {{"self", ref("n")}}))),
        "std::floor(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("remainder",
        {{"self", ref("n")}, {"arg0", lit_int(3)}}))), "std::fmod(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("toStringAsFixed",
        {{"self", ref("n")}, {"arg0", lit_int(2)}}))), "std::setprecision(d)");
    ASSERT_CONTAINS(compile_program(build_program(mcall("compareTo",
        {{"self", ref("n")}, {"arg0", lit_int(3)}}))), "a < b ? -1");
    ASSERT_CONTAINS(compile_program(build_program(mcall("clamp",
        {{"self", ref("n")}, {"arg0", lit_int(0)}, {"arg1", lit_int(9)}}))), "v < lo ? lo");
    ASSERT_CONTAINS(compile_program(build_program(mcall("gcd",
        {{"self", ref("n")}, {"arg0", lit_int(6)}}))), "while(b){auto t=b;b=a%b;a=t;}");
}

TEST(method_proto_which_and_has_introspection) {
    ASSERT_CONTAINS(compile_program(build_program(mcall("whichExpr", {{"self", ref("e")}}))),
        "ball_which_expr(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("whichValue", {{"self", ref("e")}}))),
        "ball_which_value(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("whichKind", {{"self", ref("e")}}))),
        "ball_which_kind(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("whichSource", {{"self", ref("e")}}))),
        "ball_which_source(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("whichStmt", {{"self", ref("e")}}))),
        "ball_which_stmt(");
    for (const char* fn : {"hasBody", "hasMetadata", "hasInput", "hasCall",
                           "hasDescriptor", "hasStringValue", "hasResult"}) {
        ASSERT_CONTAINS(compile_program(build_program(mcall(fn, {{"self", ref("e")}}))),
            "ball_has_field(");
    }
    ASSERT_CONTAINS(compile_program(build_program(mcall("hasMatch",
        {{"self", ref("re")}, {"arg0", lit_string("x")}}))), "ball_to_regex(");
}

TEST(method_dart_collection_helpers) {
    ASSERT_CONTAINS(compile_program(build_program(mcall("toList", {{"self", ref("a")}}))),
        "ball_to_list(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("toSet", {{"self", ref("a")}}))),
        "ball_to_set(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("where",
        {{"self", ref("a")}, {"arg0", ref("cb")}}))), "ball_where(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("map",
        {{"self", ref("a")}, {"arg0", ref("cb")}}))), "ball_map(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("every",
        {{"self", ref("a")}, {"arg0", ref("cb")}}))), "ball_every(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("addAll",
        {{"self", ref("a")}, {"arg0", ref("b")}}))), "ball_add_all(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("putIfAbsent",
        {{"self", ref("m")}, {"arg0", lit_string("k")}, {"arg1", lit_int(1)}}))),
        "ball_put_if_absent(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("take",
        {{"self", ref("a")}, {"arg0", lit_int(2)}}))), "ball_take(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("skip",
        {{"self", ref("a")}, {"arg0", lit_int(2)}}))), "ball_skip(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("sort", {{"self", ref("a")}}))),
        "std::sort(a.begin(), a.end())");
    ASSERT_CONTAINS(compile_program(build_program(mcall("sort",
        {{"self", ref("a")}, {"arg0", ref("cmp")}}))), "std::sort(a.begin(), a.end(), cmp)");
    ASSERT_CONTAINS(compile_program(build_program(mcall("fromEntries",
        {{"self", ref("a")}}))), "std::pair<std::string, BallDyn>");
}

TEST(method_regex_and_util_helpers) {
    ASSERT_CONTAINS(compile_program(build_program(mcall("firstMatch",
        {{"self", ref("re")}, {"arg0", lit_string("x")}}))), "ball_first_match(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("group",
        {{"self", ref("mm")}, {"arg0", lit_int(0)}}))), "ball_group(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("allMatches",
        {{"self", ref("re")}, {"arg0", lit_string("x")}}))), "ball_all_matches(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("tryParse",
        {{"self", ref("t")}, {"arg0", lit_string("5")}}))), "ball_try_parse(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("unmodifiable",
        {{"self", ref("t")}, {"arg0", ref("coll")}}))), "coll");
    ASSERT_CONTAINS(compile_program(build_program(mcall("bind",
        {{"self", ref("sc")}, {"arg0", lit_string("n")}, {"arg1", lit_int(1)}}))),
        "ball_scope_bind(");
}

TEST(method_async_passthrough_helpers) {
    ASSERT_CONTAINS(compile_program(build_program(print_call(std_unary("to_string",
        mcall("value", {{"self", lit_string("Future")}, {"arg0", lit_int(7)}}))))), "7");
    ASSERT_CONTAINS(compile_program(build_program(mcall("then",
        {{"self", ref("fut")}, {"arg0", ref("cb")}}))), "(cb)(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("wait",
        {{"self", ref("futs")}}))), "futs");
}

TEST(method_bytedata_and_functor_and_cast) {
    ASSERT_CONTAINS(compile_program(build_program(mcall("setUint8",
        {{"self", ref("bd")}, {"arg0", lit_int(0)}, {"arg1", lit_int(65)}}))),
        "ball_obj_as<BallByteData>(bd).setUint8(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("getFloat64",
        {{"self", ref("bd")}, {"arg0", lit_int(0)}}))),
        "ball_obj_as<BallByteData>(bd).getFloat64(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("call",
        {{"self", ref("f")}, {"arg0", lit_int(1)}}))), "f(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("cast", {{"self", ref("x")}}))),
        "cast(x, ");
    // Unknown method → user-function fallback `fn(self, args)`.
    ASSERT_CONTAINS(compile_program(build_program(mcall("someUnknownMethodXyz",
        {{"self", ref("x")}, {"arg0", lit_int(1)}}))), "someUnknownMethodXyz(");
}

TEST(method_list_of_from_copy) {
    ASSERT_CONTAINS(compile_program(build_program(mcall("of",
        {{"self", lit_string("List")}, {"arg0", ref("src")}}))), "ball_list_copy(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("from",
        {{"self", lit_string("Map")}, {"arg0", ref("src")}}))), "ball_map_copy(");
    ASSERT_CONTAINS(compile_program(build_program(mcall("filled",
        {{"self", lit_string("List")}, {"arg0", lit_int(3)}, {"arg1", lit_int(0)}}))),
        "std::vector<std::any>(");
}

// ── CLI-mode entry points: compile_split / compile_module / compile_library ──
// Never reached by the single-TU compile() the numbered e2e corpus uses; the
// CLI drives them for multi-TU (self-host engine_rt) and library output.

namespace covfs = std::filesystem;

static covfs::path conformance_dir() { return covfs::path(BALL_CONFORMANCE_DIR); }

static std::string read_text(const covfs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

TEST(compile_split_focused_class_program) {
    auto prog = ball::LoadProgram(
        (conformance_dir() / "101_simple_class.ball.json").string());
    CppCompiler compiler(std::move(prog));
    auto tmp = covfs::temp_directory_path() / "ball_cov_split_focused";
    auto result = compiler.compile_split(tmp.string(), 3);
    ASSERT_TRUE(result.num_shards == 3);
    ASSERT_TRUE(result.shard_sources.size() == 3);
    ASSERT_TRUE(covfs::exists(result.common_header));
    auto common = read_text(result.common_header);
    ASSERT_CONTAINS(common, "multi-TU");
    ASSERT_CONTAINS(common, "namespace ball_rt");
    // Every emitted shard #includes the shared header.
    for (const auto& shard : result.shard_sources) {
        ASSERT_TRUE(covfs::exists(shard));
        ASSERT_CONTAINS(read_text(shard), "engine_rt_common.hpp");
    }
    // The link/consumer header is also written.
    ASSERT_TRUE(covfs::exists((tmp / "engine_rt_link.hpp").string()));
}

TEST(compile_split_clamps_shard_count) {
    auto prog = ball::LoadProgram(
        (conformance_dir() / "100_complex_control_flow.ball.json").string());
    CppCompiler compiler(std::move(prog));
    auto tmp = covfs::temp_directory_path() / "ball_cov_split_clamp";
    auto result = compiler.compile_split(tmp.string(), 0);
    ASSERT_TRUE(result.num_shards == 1);
    ASSERT_TRUE(result.shard_sources.size() == 1);
}

TEST(compile_module_focused_and_missing) {
    auto prog = ball::LoadProgram(
        (conformance_dir() / "100_complex_control_flow.ball.json").string());
    std::string entry_mod = prog.entryModule;
    CppCompiler compiler(std::move(prog));
    auto src = compiler.compile_module(entry_mod);
    ASSERT_CONTAINS(src, "// Module: " + entry_mod);
    ASSERT_CONTAINS(src, "#include");
    bool threw = false;
    try {
        compiler.compile_module("__no_such_module__");
    } catch (const std::exception&) {
        threw = true;
    }
    ASSERT_TRUE(threw);
}

// Drive compile_split + compile_module across the whole corpus so their
// class/enum/top-level-var/standalone orchestration branches (never reached
// by single-TU compile()) are all exercised. Tolerant per-fixture (some
// corpus entries are Module files or use shapes the split path rejects);
// asserts a high success floor so a real regression still trips it.
TEST(compile_split_and_module_corpus_smoke) {
    int split_ok = 0, module_ok = 0, programs = 0;
    auto tmp = covfs::temp_directory_path() / "ball_cov_split_smoke";
    for (const auto& e : covfs::directory_iterator(conformance_dir())) {
        auto p = e.path();
        auto s = p.string();
        if (s.size() < 10 || s.compare(s.size() - 10, 10, ".ball.json") != 0)
            continue;
        ball::ir::Program prog;
        try {
            prog = ball::LoadProgram(s);
        } catch (const std::exception&) {
            continue;  // Module file / non-Program envelope — skip.
        }
        programs++;
        std::string entry_mod = prog.entryModule;
        CppCompiler compiler(std::move(prog));
        try {
            compiler.compile_split(tmp.string(), 2);
            split_ok++;
        } catch (const std::exception&) {
            // Tolerated: a few corpus shapes the multi-TU path rejects; the
            // success-floor assert below still catches a real regression.
        }
        try {
            auto m = compiler.compile_module(entry_mod);
            if (!m.empty()) module_ok++;
        } catch (const std::exception&) {
            // Tolerated per-fixture (see above); floor-asserted below.
        }
    }
    // The corpus is large and overwhelmingly Program envelopes; require the
    // bulk to round-trip through both CLI paths.
    ASSERT_TRUE(programs > 200);
    ASSERT_TRUE(split_ok > 200);
    ASSERT_TRUE(module_ok > 200);
}

TEST(compile_library_from_facade_with_user_function) {
    // A Module facade carrying a non-base user function (has_user_content path).
    json mod;
    mod["name"] = "mylib";
    json fn;
    fn["name"] = "answer";
    fn["body"] = lit_int(42);
    mod["functions"].push_back(std::move(fn));
    auto facade = ball::ir::parseModule(mod);
    auto result = CppCompiler::compile_library(facade);
    ASSERT_TRUE(result.ns == "mylib");
    ASSERT_CONTAINS(result.header, "namespace mylib");
    ASSERT_CONTAINS(result.header, "library mode");
    ASSERT_CONTAINS(result.header, "BigInt_t");
    // Header-only library mode: emitted function bodies live in the header,
    // result.source is deliberately empty.
    ASSERT_CONTAINS(result.header, "answer");
    ASSERT_TRUE(result.source.empty());
}

TEST(compile_library_from_facade_with_inline_import_and_ns_override) {
    // A facade whose moduleImports embed an inline sub-module (InlineSource.json).
    json sub;
    sub["name"] = "submod";
    json subfn;
    subfn["name"] = "greet";
    subfn["body"] = lit_string("hi");
    sub["functions"].push_back(std::move(subfn));

    json facade_json;
    facade_json["name"] = "outer";
    // A proto3-JSON ModuleImport with the `inline` source-oneof variant
    // selected (oneof fields are flattened to the object top level).
    json imp;
    imp["inline"]["json"] = sub.dump();
    facade_json["moduleImports"].push_back(std::move(imp));
    auto facade = ball::ir::parseModule(facade_json);
    auto result = CppCompiler::compile_library(facade, "custom_ns");
    ASSERT_TRUE(result.ns == "custom_ns");
    ASSERT_CONTAINS(result.header, "namespace custom_ns");
    ASSERT_CONTAINS(result.header, "greet");
}

// ── emit_function engine-intrinsic canned bodies ──
// emit_function emits hard-coded bodies for functions whose name matches an
// engine runtime intrinsic (_ballUserMap, _ballIs*, _ballMap*, _ballNum*,
// ballObjectSetField, ...). Only the self-hosted engine defines these; the
// numbered corpus never does, so the arms sit uncovered. Declaring user
// functions with those names drives every arm.

static json build_program_multi(std::vector<std::pair<std::string, json>> funcs) {
    json program;
    json mod;
    mod["name"] = "main";
    for (auto& [nm, body] : funcs) {
        json f;
        f["name"] = nm;
        f["body"] = std::move(body);
        mod["functions"].push_back(std::move(f));
    }
    program["modules"].push_back(std::move(mod));
    program["entryModule"] = "main";
    program["entryFunction"] = "main";
    return program;
}

TEST(emit_function_engine_intrinsic_bodies) {
    std::vector<std::pair<std::string, json>> funcs;
    funcs.push_back({"main", print_call(lit_string("x"))});
    for (const char* nm : {
        "_ballUserMap", "_ballNewGenerator", "_ballGeneratorValues",
        "_ballDoubleToInt64", "_ballCodeUnitAt", "_ballIsInt", "_ballIsDouble",
        "_ballIsNum", "_ballIsString", "_ballIsBool", "_ballIsList", "_ballIsMap",
        "_ballRuntimeTypeName", "_ballToDouble", "_ballMapValues",
        "_ballMapValuesDyn", "_ballMapContainsKeyDyn", "_ballMapSetDyn",
        "_ballMapKeysDyn", "_ballNumIsNaN", "_ballNumIsFinite",
        "_ballNumIsInfinite", "ballObjectSetField"}) {
        funcs.push_back({nm, lit_int(0)});
    }
    auto out = compile_program(build_program_multi(std::move(funcs)));
    ASSERT_CONTAINS(out, "_ballUserMap() {");
    ASSERT_CONTAINS(out, "return BallDyn(BallGenerator{});");
    ASSERT_CONTAINS(out, "std::any_cast<const BallGenerator&>");
    ASSERT_CONTAINS(out, "ball_double_to_int64(static_cast<double>(value))");
    ASSERT_CONTAINS(out, "ball_code_unit_at(s, static_cast<int64_t>(index))");
    ASSERT_CONTAINS(out, "_ballIsInt(BallDyn v) {");
    ASSERT_CONTAINS(out, "_ballIsDouble(BallDyn v) {");
    ASSERT_CONTAINS(out, "_ballIsNum(BallDyn v) {");
    ASSERT_CONTAINS(out, "_ballIsString(BallDyn v) {");
    ASSERT_CONTAINS(out, "_ballIsBool(BallDyn v) {");
    ASSERT_CONTAINS(out, "_ballIsList(BallDyn v) {");
    ASSERT_CONTAINS(out, "!ball_is_ball_set(v));");
    ASSERT_CONTAINS(out, "ball_runtime_type_name(value)");
    ASSERT_CONTAINS(out, "if (ball_is_double(value)) return value;");
    ASSERT_CONTAINS(out, "_ballMapValues(BallDyn map) {");
    ASSERT_CONTAINS(out, "map.count(BallDyn(key)) > 0");
    ASSERT_CONTAINS(out, "ball_set(map, std::string(ball_to_string(BallDyn(key)))");
    ASSERT_CONTAINS(out, "ball_list_copy(ball_map_keys(map))");
    ASSERT_CONTAINS(out, "std::isnan(static_cast<double>(v))");
    ASSERT_CONTAINS(out, "std::isfinite(static_cast<double>(v))");
    ASSERT_CONTAINS(out, "std::isinf(static_cast<double>(v))");
    ASSERT_CONTAINS(out, "ball_object_set_field(");
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
