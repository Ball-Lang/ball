#pragma once

// ball::CppEncoder — translates a Clang JSON AST into a Ball Program.
//
// Usage:
//   1. Run `clang -Xclang -ast-dump=json <file.cpp>` to get the AST.
//   2. Feed the JSON string into CppEncoder::encode_from_clang_ast().
//   3. The resulting Program contains raw cpp_std nodes for normalization.
//
// Port of the Dart `encoder.dart` reference.

#include "ball_shared.h"
#include "cpp_std.h"

#include <string>
#include <vector>

// nlohmann::json is included in the .cpp; callers only need this header.
#include <nlohmann/json_fwd.hpp>

namespace ball {

class CppEncoder {
public:
    explicit CppEncoder(const std::string& source_name = "cpp_program",
                        const std::string& source_version = "1.0.0");

    /// Encode from raw Clang JSON AST string.
    ball::v1::Program encode_from_clang_ast(const std::string& json_str);

private:
    std::string source_name_;
    std::string source_version_;

    std::vector<ball::v1::Module> modules_;
    ball::v1::Module main_module_;
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
    void encode_enum_decl(const nlohmann::json& node);
    void encode_type_alias(const nlohmann::json& node);
    void encode_namespace_decl(nlohmann::json node);
    void encode_using_decl(const nlohmann::json& node);
    void encode_class_template_decl(const nlohmann::json& node);
    void encode_function_template_decl(const nlohmann::json& node);
    void encode_global_var_decl(const nlohmann::json& node);

    // Statements
    ball::v1::Expression encode_compound_stmt(const nlohmann::json& node);
    ball::v1::Statement* encode_statement(const nlohmann::json& node);
    ball::v1::Statement* encode_decl_stmt(const nlohmann::json& node);
    ball::v1::Statement encode_return_stmt(const nlohmann::json& node);

    // Control flow
    ball::v1::Expression encode_if_stmt(const nlohmann::json& node);
    ball::v1::Expression encode_for_stmt(const nlohmann::json& node);
    ball::v1::Expression encode_range_for_stmt(const nlohmann::json& node);
    ball::v1::Expression encode_while_stmt(const nlohmann::json& node);
    ball::v1::Expression encode_do_while_stmt(const nlohmann::json& node);
    ball::v1::Expression encode_switch_stmt(const nlohmann::json& node);

    // Expressions
    ball::v1::Expression encode_expression(const nlohmann::json& node);
    ball::v1::Expression encode_member_expr(const nlohmann::json& node);
    ball::v1::Expression encode_call_expr(const nlohmann::json& node);
    ball::v1::Expression encode_member_call_expr(const nlohmann::json& node);
    ball::v1::Expression encode_operator_call_expr(const nlohmann::json& node);
    ball::v1::Expression encode_binary_op(const nlohmann::json& node);
    ball::v1::Expression encode_unary_op(const nlohmann::json& node);
    ball::v1::Expression encode_compound_assign_op(const nlohmann::json& node);
    ball::v1::Expression encode_conditional_op(const nlohmann::json& node);
    ball::v1::Expression encode_new_expr(const nlohmann::json& node);
    ball::v1::Expression encode_delete_expr(const nlohmann::json& node);
    ball::v1::Expression encode_cpp_cast(const nlohmann::json& node,
                                          const std::string& kind);
    ball::v1::Expression encode_c_style_cast(const nlohmann::json& node);
    ball::v1::Expression encode_implicit_cast(const nlohmann::json& node);
    ball::v1::Expression encode_array_subscript(const nlohmann::json& node);
    ball::v1::Expression encode_sizeof_alignof(const nlohmann::json& node);
    ball::v1::Expression encode_construct_expr(const nlohmann::json& node);
    ball::v1::Expression encode_init_list_expr(const nlohmann::json& node);
    ball::v1::Expression encode_lambda_expr(const nlohmann::json& node);

    // Helpers
    std::string anon_name();
    ball::v1::Expression null_expr();
    ball::v1::Expression make_std_call(
        const std::string& function,
        std::vector<std::pair<std::string, ball::v1::Expression>> fields);
    ball::v1::Expression make_cpp_std_call(
        const std::string& function,
        std::vector<std::pair<std::string, ball::v1::Expression>> fields);

    std::string extract_return_type(const nlohmann::json& node);
    std::vector<std::pair<std::string, std::string>>
    extract_params(const nlohmann::json& node);
    google::protobuf::Value encode_params_meta(
        const std::vector<std::pair<std::string, std::string>>& params);
    bool has_qualifier(const nlohmann::json& node,
                       const std::string& qualifier);
    const nlohmann::json* find_child(const nlohmann::json& node,
                                      const std::string& kind);
    const nlohmann::json* find_child_expr(const nlohmann::json& node);
    google::protobuf::Value list_value(const std::vector<std::string>& items);
    google::protobuf::FieldDescriptorProto_Type
    map_cpp_type_to_proto(const std::string& cpp_type);
    std::string binary_op_to_std(const std::string& opcode);
};

}  // namespace ball
