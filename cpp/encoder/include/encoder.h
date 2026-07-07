#pragma once

// ball::CppEncoder — translates a Clang JSON AST into a Ball Program.
//
// Usage:
//   1. Run `clang -Xclang -ast-dump=json <file.cpp>` to get the AST.
//   2. Feed the JSON string into CppEncoder::encode_from_clang_ast().
//   3. The resulting Program uses only universal std/std_memory modules.
//
// Port of the Dart `encoder.dart` reference.
//
// #18: the encoder builds the protobuf-free `ball::ir` plain-struct IR
// (cpp/shared/include/ball_ir.h) directly from the Clang AST (also
// nlohmann::json), so it links NO libprotobuf/abseil. Cosmetic Struct
// metadata and DescriptorProto/EnumDescriptorProto payloads are built as
// plain `nlohmann::json` (proto3-JSON shape) via ball_ir's descriptor_build
// helpers.

#include "ball_ir.h"

#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace ball {

class CppEncoder {
public:
    explicit CppEncoder(const std::string& source_name = "cpp_program",
                        const std::string& source_version = "1.0.0");

    /// Encode from raw Clang JSON AST string.
    ball::ir::Program encode_from_clang_ast(const std::string& json_str);

private:
    std::string source_name_;
    std::string source_version_;

    std::vector<ball::ir::Module> modules_;
    ball::ir::Module main_module_;
    int anon_counter_ = 0;

    // Recursion depth guard
    static constexpr int kMaxEncodeDepth = 512;
    int encode_depth_ = 0;

    // Translation unit
    void encode_translation_unit(const nlohmann::json& node);

    // Declarations
    void encode_function_decl(const nlohmann::json& node);
    void encode_class_decl(const nlohmann::json& node);
    void encode_method_decl(const nlohmann::json& node,
                            const std::string& class_name);
    void encode_constructor_decl(const nlohmann::json& node,
                                 const std::string& class_name);
    void encode_destructor_decl(const nlohmann::json& node,
                                const std::string& class_name);
    void encode_conversion_decl(const nlohmann::json& node,
                                const std::string& class_name);
    void encode_enum_decl(const nlohmann::json& node);
    void encode_type_alias(const nlohmann::json& node);
    void encode_namespace_decl(nlohmann::json node);
    void encode_using_decl(const nlohmann::json& node);
    void encode_class_template_decl(const nlohmann::json& node);
    void encode_function_template_decl(const nlohmann::json& node);
    void encode_global_var_decl(const nlohmann::json& node);

    // Statements
    ball::ir::Expression encode_compound_stmt(const nlohmann::json& node);
    ball::ir::Statement* encode_statement(const nlohmann::json& node);
    ball::ir::Statement* encode_decl_stmt(const nlohmann::json& node);
    ball::ir::Statement encode_return_stmt(const nlohmann::json& node);

    // Control flow
    ball::ir::Expression encode_if_stmt(const nlohmann::json& node);
    ball::ir::Expression encode_for_stmt(const nlohmann::json& node);
    ball::ir::Expression encode_range_for_stmt(const nlohmann::json& node);
    ball::ir::Expression encode_while_stmt(const nlohmann::json& node);
    ball::ir::Expression encode_do_while_stmt(const nlohmann::json& node);
    ball::ir::Expression encode_switch_stmt(const nlohmann::json& node);

    // Expressions
    ball::ir::Expression encode_expression(const nlohmann::json& node);
    ball::ir::Expression encode_member_expr(const nlohmann::json& node);
    ball::ir::Expression encode_call_expr(const nlohmann::json& node);
    ball::ir::Expression encode_member_call_expr(const nlohmann::json& node);
    ball::ir::Expression encode_operator_call_expr(const nlohmann::json& node);
    ball::ir::Expression encode_binary_op(const nlohmann::json& node);
    ball::ir::Expression encode_unary_op(const nlohmann::json& node);
    ball::ir::Expression encode_compound_assign_op(const nlohmann::json& node);
    ball::ir::Expression encode_conditional_op(const nlohmann::json& node);
    ball::ir::Expression encode_new_expr(const nlohmann::json& node);
    ball::ir::Expression encode_delete_expr(const nlohmann::json& node);
    ball::ir::Expression encode_cpp_cast(const nlohmann::json& node,
                                         const std::string& kind);
    ball::ir::Expression encode_c_style_cast(const nlohmann::json& node);
    ball::ir::Expression encode_implicit_cast(const nlohmann::json& node);
    ball::ir::Expression encode_array_subscript(const nlohmann::json& node);
    ball::ir::Expression encode_sizeof_alignof(const nlohmann::json& node);
    ball::ir::Expression encode_construct_expr(const nlohmann::json& node);
    ball::ir::Expression encode_init_list_expr(const nlohmann::json& node);
    ball::ir::Expression encode_lambda_expr(const nlohmann::json& node);

    // Helpers
    std::string anon_name();
    ball::ir::Expression null_expr();
    ball::ir::Expression make_std_call(
        const std::string& function,
        std::vector<std::pair<std::string, ball::ir::Expression>> fields);

    std::string extract_return_type(const nlohmann::json& node);
    std::vector<std::pair<std::string, std::string>>
    extract_params(const nlohmann::json& node);
    // Encodes the parameter list as a proto3-JSON ListValue (a JSON array of
    // {name,type} objects) for the function's cosmetic `params` metadata.
    nlohmann::json encode_params_meta(
        const std::vector<std::pair<std::string, std::string>>& params);
    bool has_qualifier(const nlohmann::json& node,
                       const std::string& qualifier);
    const nlohmann::json* find_child(const nlohmann::json& node,
                                      const std::string& kind);
    const nlohmann::json* find_child_expr(const nlohmann::json& node);
    // A proto3-JSON ListValue (JSON array of strings).
    nlohmann::json list_value(const std::vector<std::string>& items);
    std::string binary_op_to_std(const std::string& opcode);
};

}  // namespace ball
