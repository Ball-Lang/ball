#pragma once

// ball::CppCompiler — compiles a ball Program AST into C++ source code.
//
// This is the C++ analogue of the Dart DartCompiler: it walks a protobuf
// Program tree and emits idiomatic C++ that can be compiled with any modern
// C++ toolchain (g++, clang++, MSVC).
//
// The generated code is self-contained: it includes a minimal runtime
// (value type, linear-memory helpers) and maps ball's std operations to
// C++ standard library calls.

#include "ball_shared.h"
#include "code_builder.h"
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace ball {

class CppCompiler {
public:
    explicit CppCompiler(const ball::v1::Program& program);

    // Compile the entire program to a single C++ source string
    std::string compile();

    // Compile a single module (for multi-file output)
    std::string compile_module(const std::string& module_name);

private:
    ball::v1::Program program_;

    // Lookup tables
    std::unordered_map<std::string, google::protobuf::DescriptorProto> types_;
    std::unordered_map<std::string, const ball::v1::FunctionDefinition*> functions_;
    std::unordered_set<std::string> base_modules_;
    std::unordered_map<std::string, std::vector<std::string>> param_cache_;

    // Output state
    std::ostringstream out_;
    int indent_ = 0;

    // Pending label from a `labeled` wrapper — consumed by the next loop
    // emission so it can plant `__ball_break_<label>` / `__ball_continue_<label>`
    // goto targets around/inside its body.
    std::string pending_label_;

    // Variables currently bound to a `BallException&` inside a catch
    // block. Field access on these compiles to `.fields.at("X")` so
    // catch-side payload reads reach the original throw values.
    std::unordered_set<std::string> catch_bound_vars_;

    // Set of method basenames belonging to the class currently being
    // emitted. When a reference matches one of these names, the compiler
    // wraps it in a lambda to bind `this` (member function pointers
    // can't be stored directly as std::any/std::function values).
    std::unordered_set<std::string> current_class_methods_;

    void build_lookup_tables();
    std::vector<std::string> extract_params(const google::protobuf::Struct& metadata);
    std::map<std::string, std::string> read_meta(const ball::v1::FunctionDefinition& func);
    std::vector<std::string> read_meta_list(const google::protobuf::Struct& meta,
                                             const std::string& key);
    std::map<std::string, std::string> read_type_meta(const ball::v1::TypeDefinition& td);
    void emit_template_prefix(const ball::v1::TypeDefinition& td);
    void emit_template_prefix_from_meta(const google::protobuf::Struct& meta);

    // Code generation
    void emit(const std::string& code);
    void emit_line(const std::string& code);
    void emit_indent();
    void emit_newline();

    // Structural emitters
    void emit_includes();
    void emit_forward_decls(const ball::v1::Module& module);
    void emit_struct(const ball::v1::TypeDefinition& td,
                    const std::vector<const ball::v1::FunctionDefinition*>& methods);
    void emit_enum(const google::protobuf::EnumDescriptorProto& ed);
    void emit_function(const ball::v1::FunctionDefinition& func);
    void emit_top_level_var(const ball::v1::FunctionDefinition& func);
    void emit_main(const ball::v1::FunctionDefinition& entry);

    // Expression compilation — returns C++ expression string
    std::string compile_expr(const ball::v1::Expression& expr);
    // Bridge: compile expression to CppExpr for method chaining
    CppExpr expr(const ball::v1::Expression& e) { return CppExpr(compile_expr(e)); }
    std::string compile_call(const ball::v1::FunctionCall& call);
    std::string compile_literal(const ball::v1::Literal& lit);
    std::string compile_reference(const ball::v1::Reference& ref);
    std::string compile_field_access(const ball::v1::FieldAccess& access);
    std::string compile_message_creation(const ball::v1::MessageCreation& msg);
    std::string compile_block(const ball::v1::Block& block);
    std::string compile_lambda(const ball::v1::FunctionDefinition& func);

    // Statement compilation — emits directly
    void compile_statement(const ball::v1::Statement& stmt);

    // std function compilation
    std::string compile_std_call(const std::string& function,
                                  const ball::v1::FunctionCall& call);
    std::string compile_method_call(const std::string& function,
                                     const ball::v1::FunctionCall& call);
    std::string compile_collections_call(const std::string& function,
                                          const ball::v1::FunctionCall& call);
    std::string compile_io_call(const std::string& function,
                                 const ball::v1::FunctionCall& call);
    std::string compile_cpp_std_call(const std::string& function,
                                      const ball::v1::FunctionCall& call);
    std::string compile_convert_call(const std::string& function,
                                      const ball::v1::FunctionCall& call);
    std::string compile_fs_call(const std::string& function,
                                 const ball::v1::FunctionCall& call);
    std::string compile_time_call(const std::string& function,
                                   const ball::v1::FunctionCall& call);
    std::string compile_concurrency_call(const std::string& function,
                                          const ball::v1::FunctionCall& call);
    std::string compile_binary_op(const std::string& op,
                                   const ball::v1::FunctionCall& call);
    std::string compile_unary_op(const std::string& op,
                                  const ball::v1::FunctionCall& call);

    // Type mapping
    std::string map_type(const std::string& ball_type);
    std::string map_return_type(const ball::v1::FunctionDefinition& func);

    // Helpers
    std::string get_message_field(const ball::v1::FunctionCall& call,
                                   const std::string& field_name);
    std::string get_string_field(const ball::v1::FunctionCall& call,
                                  const std::string& field_name);
    const ball::v1::Expression* get_message_field_expr(
        const ball::v1::FunctionCall& call, const std::string& field_name);
    // Bridge: get a message field compiled to CppExpr
    CppExpr field_expr(const ball::v1::FunctionCall& call,
                       const std::string& field_name) {
        auto* e = get_message_field_expr(call, field_name);
        return e ? CppExpr(compile_expr(*e)) : CppExpr("/* missing " + field_name + " */");
    }
    std::string sanitize_name(const std::string& name);
    std::string indent_str();
};

}  // namespace ball
