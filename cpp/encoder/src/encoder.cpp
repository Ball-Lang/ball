// ball::CppEncoder — translates a Clang JSON AST into a Ball Program.
//
// Faithful port of the Dart `encoder.dart` reference.

#include "encoder.h"
#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace ball {

// ================================================================
// Construction
// ================================================================

CppEncoder::CppEncoder(const std::string& source_name,
                        const std::string& source_version)
    : source_name_(source_name), source_version_(source_version) {}

// ================================================================
// Public API
// ================================================================

ball::v1::Program CppEncoder::encode_from_clang_ast(const std::string& json_str) {
    auto ast = json::parse(json_str);

    // Initialize base modules.
    ball::v1::Module std_mod;
    std_mod.set_name("std");
    std_mod.set_description("Universal std base module reference.");
    modules_.push_back(std_mod);

    modules_.push_back(build_cpp_std_module());

    ball::v1::Module mem_mod;
    mem_mod.set_name("std_memory");
    mem_mod.set_description("Linear memory simulation module reference.");
    modules_.push_back(mem_mod);

    // Initialize main user module.
    main_module_.set_name("main");
    main_module_.set_description("C++ source module: " + source_name_);

    // Walk the translation unit.
    encode_translation_unit(ast);

    modules_.push_back(main_module_);

    // Build the program.
    ball::v1::Program program;
    program.set_name(source_name_);
    program.set_version(source_version_);
    program.set_entry_module("main");
    program.set_entry_function("main");
    for (auto& mod : modules_)
        *program.add_modules() = std::move(mod);

    // Set source language metadata.
    auto* meta = program.mutable_metadata();
    (*meta->mutable_fields())["source_language"].set_string_value("cpp");
    (*meta->mutable_fields())["encoder_version"].set_string_value("0.1.0");

    return program;
}

// ================================================================
// Translation unit
// ================================================================

void CppEncoder::encode_translation_unit(const json& node) {
    if (!node.contains("inner") || !node["inner"].is_array()) return;

    for (const auto& child : node["inner"]) {
        if (!child.is_object()) continue;
        if (child.value("isImplicit", false)) continue;

        auto kind = child.value("kind", "");
        if (kind == "FunctionDecl") encode_function_decl(child);
        else if (kind == "CXXRecordDecl") encode_class_decl(child);
        else if (kind == "VarDecl") encode_global_var_decl(child);
        else if (kind == "EnumDecl") encode_enum_decl(child);
        else if (kind == "TypedefDecl" || kind == "TypeAliasDecl") encode_type_alias(child);
        else if (kind == "NamespaceDecl") encode_namespace_decl(child);
        else if (kind == "UsingDirectiveDecl" || kind == "UsingDecl") encode_using_decl(child);
        else if (kind == "ClassTemplateDecl") encode_class_template_decl(child);
        else if (kind == "FunctionTemplateDecl") encode_function_template_decl(child);
    }
}

// ================================================================
// Functions
// ================================================================

void CppEncoder::encode_function_decl(const json& node) {
    auto name = node.value("name", anon_name());
    auto return_type = extract_return_type(node);
    auto params = extract_params(node);
    auto* body = find_child(node, "CompoundStmt");

    auto* func = main_module_.add_functions();
    func->set_name(name);
    func->set_output_type(return_type);
    func->set_input_type("");
    func->set_is_base(false);

    auto* meta = func->mutable_metadata();
    (*meta->mutable_fields())["kind"].set_string_value("function");
    *(*meta->mutable_fields())["params"].mutable_list_value() =
        encode_params_meta(params).list_value();

    if (has_qualifier(node, "static"))
        (*meta->mutable_fields())["is_static"].set_bool_value(true);
    if (has_qualifier(node, "inline"))
        *(*meta->mutable_fields())["annotations"].mutable_list_value() =
            list_value({"inline"}).list_value();
    if (has_qualifier(node, "constexpr"))
        (*meta->mutable_fields())["is_const"].set_bool_value(true);
    if (has_qualifier(node, "virtual"))
        (*meta->mutable_fields())["is_abstract"].set_bool_value(true);

    if (body)
        *func->mutable_body() = encode_compound_stmt(*body);
}

// ================================================================
// Classes / structs
// ================================================================

void CppEncoder::encode_class_decl(const json& node) {
    auto name = node.value("name", anon_name());
    auto tag_used = node.value("tagUsed", "class");
    bool is_struct = (tag_used == "struct");

    auto* td = main_module_.add_type_defs();
    td->set_name(name);

    auto* descriptor = td->mutable_descriptor_();
    descriptor->set_name(name);
    int field_number = 1;

    auto* meta = td->mutable_metadata();
    (*meta->mutable_fields())["kind"].set_string_value(is_struct ? "struct" : "class");

    // Scan for base classes.
    std::vector<std::string> bases;
    auto inner = node.value("inner", json::array());
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        auto ck = child.value("kind", "");
        if (ck == "CXXBaseSpecifier" || ck == "public" ||
            ck == "private" || ck == "protected") {
            if (child.contains("type") && child["type"].contains("qualType"))
                bases.push_back(child["type"]["qualType"].get<std::string>());
        }
    }
    if (!bases.empty()) {
        (*meta->mutable_fields())["superclass"].set_string_value(bases[0]);
        if (bases.size() > 1) {
            auto& ifaces = *(*meta->mutable_fields())["interfaces"].mutable_list_value();
            for (size_t i = 1; i < bases.size(); ++i)
                ifaces.add_values()->set_string_value(bases[i]);
        }
    }

    // Encode members.
    auto* fields_meta = (*meta->mutable_fields())["fields"].mutable_list_value();

    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        auto ck = child.value("kind", "");

        if (ck == "FieldDecl") {
            auto field_name = child.value("name", "__field" + std::to_string(field_number));
            std::string field_type = "int";
            if (child.contains("type") && child["type"].contains("qualType"))
                field_type = child["type"]["qualType"].get<std::string>();

            auto* f = descriptor->add_field();
            f->set_name(field_name);
            f->set_number(field_number++);
            f->set_type(map_cpp_type_to_proto(field_type));
            f->set_type_name(field_type);
            f->set_label(google::protobuf::FieldDescriptorProto::LABEL_OPTIONAL);

            auto* fm = fields_meta->add_values()->mutable_struct_value();
            (*fm->mutable_fields())["name"].set_string_value(field_name);
            (*fm->mutable_fields())["type"].set_string_value(field_type);
            if (has_qualifier(child, "const"))
                (*fm->mutable_fields())["is_final"].set_bool_value(true);
            if (has_qualifier(child, "static"))
                (*fm->mutable_fields())["is_static"].set_bool_value(true);
        } else if (ck == "CXXMethodDecl") {
            encode_method_decl(child, name);
        } else if (ck == "CXXConstructorDecl") {
            encode_constructor_decl(child, name);
        } else if (ck == "CXXDestructorDecl") {
            encode_destructor_decl(child, name);
        }
    }
}

void CppEncoder::encode_method_decl(const json& node,
                                     const std::string& class_name) {
    auto method_name = node.value("name", anon_name());
    auto return_type = extract_return_type(node);
    auto params = extract_params(node);
    auto* body = find_child(node, "CompoundStmt");

    auto* func = main_module_.add_functions();
    func->set_name(class_name + "." + method_name);
    func->set_output_type(return_type);
    func->set_is_base(false);

    auto* meta = func->mutable_metadata();
    (*meta->mutable_fields())["kind"].set_string_value("method");
    *(*meta->mutable_fields())["params"].mutable_list_value() =
        encode_params_meta(params).list_value();

    if (has_qualifier(node, "static"))
        (*meta->mutable_fields())["is_static"].set_bool_value(true);
    if (has_qualifier(node, "virtual")) {
        (*meta->mutable_fields())["is_abstract"].set_bool_value(body == nullptr);
        (*meta->mutable_fields())["is_override"].set_bool_value(false);
    }
    if (has_qualifier(node, "const")) {
        auto& annots = *(*meta->mutable_fields())["annotations"].mutable_list_value();
        annots.add_values()->set_string_value("const");
    }

    if (body)
        *func->mutable_body() = encode_compound_stmt(*body);
}

void CppEncoder::encode_constructor_decl(const json& node,
                                          const std::string& class_name) {
    auto params = extract_params(node);
    auto* body = find_child(node, "CompoundStmt");

    auto* func = main_module_.add_functions();
    func->set_name(class_name + ".new");
    func->set_output_type("");
    func->set_is_base(false);

    auto* meta = func->mutable_metadata();
    (*meta->mutable_fields())["kind"].set_string_value("constructor");
    *(*meta->mutable_fields())["params"].mutable_list_value() =
        encode_params_meta(params).list_value();

    if (has_qualifier(node, "explicit")) {
        auto& annots = *(*meta->mutable_fields())["annotations"].mutable_list_value();
        annots.add_values()->set_string_value("explicit");
    }

    if (body)
        *func->mutable_body() = encode_compound_stmt(*body);
}

void CppEncoder::encode_destructor_decl(const json& node,
                                         const std::string& class_name) {
    auto* body = find_child(node, "CompoundStmt");

    auto* func = main_module_.add_functions();
    func->set_name(class_name + ".~" + class_name);
    func->set_output_type("");
    func->set_is_base(false);

    auto* meta = func->mutable_metadata();
    (*meta->mutable_fields())["kind"].set_string_value("method");
    auto& annots = *(*meta->mutable_fields())["annotations"].mutable_list_value();
    annots.add_values()->set_string_value("destructor");

    if (has_qualifier(node, "virtual"))
        annots.add_values()->set_string_value("virtual");

    if (body)
        *func->mutable_body() = encode_compound_stmt(*body);
}

// ================================================================
// Enums
// ================================================================

void CppEncoder::encode_enum_decl(const json& node) {
    auto name = node.value("name", anon_name());
    bool is_scoped = node.contains("scopedEnumTag");

    auto* enum_def = main_module_.add_enums();
    enum_def->set_name(name);

    auto inner = node.value("inner", json::array());
    int number = 0;
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") == "EnumConstantDecl") {
            auto* val = enum_def->add_value();
            val->set_name(child.value("name", "value" + std::to_string(number)));
            val->set_number(number++);
        }
    }

    if (is_scoped) {
        auto* td = main_module_.add_type_defs();
        td->set_name(name);
        (*td->mutable_metadata()->mutable_fields())["kind"].set_string_value("enum");
    }
}

// ================================================================
// Type aliases, namespaces, templates
// ================================================================

void CppEncoder::encode_type_alias(const json& node) {
    auto name = node.value("name", anon_name());
    std::string target_type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        target_type = node["type"]["qualType"].get<std::string>();

    auto* alias = main_module_.add_type_aliases();
    alias->set_name(name);
    alias->set_target_type(target_type);

    auto* meta = alias->mutable_metadata();
    (*meta->mutable_fields())["kind"].set_string_value("typedef");
    (*meta->mutable_fields())["aliased_type"].set_string_value(target_type);
}

void CppEncoder::encode_namespace_decl(json node) {
    auto name = node.value("name", "");
    auto inner = node.value("inner", json::array());

    for (auto& child : inner) {
        if (!child.is_object()) continue;
        auto ck = child.value("kind", "");
        if (ck == "FunctionDecl") {
            auto child_name = child.value("name", anon_name());
            child["name"] = name.empty() ? child_name : (name + "::" + child_name);
            encode_function_decl(child);
        } else if (ck == "CXXRecordDecl") {
            auto child_name = child.value("name", anon_name());
            child["name"] = name.empty() ? child_name : (name + "::" + child_name);
            encode_class_decl(child);
        } else if (ck == "NamespaceDecl") {
            auto child_name = child.value("name", "");
            child["name"] = name.empty() ? child_name : (name + "::" + child_name);
            encode_namespace_decl(child);
        }
    }
}

void CppEncoder::encode_using_decl(const json& /*node*/) {
    // Stored as metadata — no-op for now.
}

void CppEncoder::encode_class_template_decl(const json& node) {
    auto inner = node.value("inner", json::array());
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") == "CXXRecordDecl") {
            encode_class_decl(child);
            break;
        }
    }
}

void CppEncoder::encode_function_template_decl(const json& node) {
    auto inner = node.value("inner", json::array());
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") == "FunctionDecl") {
            encode_function_decl(child);
            break;
        }
    }
}

void CppEncoder::encode_global_var_decl(const json& node) {
    auto name = node.value("name", anon_name());
    std::string var_type = "int";
    if (node.contains("type") && node["type"].contains("qualType"))
        var_type = node["type"]["qualType"].get<std::string>();

    auto* init_child = find_child_expr(node);

    auto* func = main_module_.add_functions();
    func->set_name(name);
    func->set_output_type(var_type);
    func->set_is_base(false);

    auto* meta = func->mutable_metadata();
    (*meta->mutable_fields())["kind"].set_string_value("top_level_variable");
    if (has_qualifier(node, "const") || has_qualifier(node, "constexpr"))
        (*meta->mutable_fields())["is_const"].set_bool_value(true);

    if (init_child)
        *func->mutable_body() = encode_expression(*init_child);
}

// ================================================================
// Statements
// ================================================================

ball::v1::Expression CppEncoder::encode_compound_stmt(const json& node) {
    ball::v1::Expression expr;
    auto* block = expr.mutable_block();
    auto inner = node.value("inner", json::array());

    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        auto* stmt = encode_statement(child);
        if (stmt) *block->add_statements() = *stmt;
        delete stmt;
    }
    return expr;
}

ball::v1::Statement* CppEncoder::encode_statement(const json& node) {
    auto kind = node.value("kind", "");

    if (kind == "DeclStmt") return encode_decl_stmt(node);
    if (kind == "ReturnStmt") {
        auto* s = new ball::v1::Statement();
        *s = encode_return_stmt(node);
        return s;
    }
    if (kind == "IfStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = encode_if_stmt(node);
        return s;
    }
    if (kind == "ForStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = encode_for_stmt(node);
        return s;
    }
    if (kind == "CXXForRangeStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = encode_range_for_stmt(node);
        return s;
    }
    if (kind == "WhileStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = encode_while_stmt(node);
        return s;
    }
    if (kind == "DoStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = encode_do_while_stmt(node);
        return s;
    }
    if (kind == "SwitchStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = encode_switch_stmt(node);
        return s;
    }
    if (kind == "CompoundStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = encode_compound_stmt(node);
        return s;
    }
    if (kind == "BreakStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = make_std_call("break", {});
        return s;
    }
    if (kind == "ContinueStmt") {
        auto* s = new ball::v1::Statement();
        *s->mutable_expression() = make_std_call("continue", {});
        return s;
    }
    if (kind == "NullStmt") return nullptr;

    // Try as expression statement.
    auto* s = new ball::v1::Statement();
    *s->mutable_expression() = encode_expression(node);
    return s;
}

ball::v1::Statement* CppEncoder::encode_decl_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.empty()) return nullptr;

    auto& decl = inner[0];
    if (!decl.is_object() || decl.value("kind", "") != "VarDecl")
        return nullptr;

    auto name = decl.value("name", "_");
    std::string var_type;
    if (decl.contains("type") && decl["type"].contains("qualType"))
        var_type = decl["type"]["qualType"].get<std::string>();

    auto* init = find_child_expr(decl);

    auto* s = new ball::v1::Statement();
    auto* let = s->mutable_let();
    let->set_name(name);

    if (init) {
        *let->mutable_value() = encode_expression(*init);
    } else {
        let->mutable_value()->mutable_literal()->set_string_value("__no_init__");
    }

    auto* meta = let->mutable_metadata();
    if (!var_type.empty())
        (*meta->mutable_fields())["type"].set_string_value(var_type);
    if (has_qualifier(decl, "const"))
        (*meta->mutable_fields())["is_final"].set_bool_value(true);

    return s;
}

ball::v1::Statement CppEncoder::encode_return_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ball::v1::Expression>> fields;
    if (!inner.empty() && inner[0].is_object()) {
        fields.push_back({"value", encode_expression(inner[0])});
    }
    ball::v1::Statement stmt;
    *stmt.mutable_expression() = make_std_call("return", std::move(fields));
    return stmt;
}

// ================================================================
// Control flow
// ================================================================

ball::v1::Expression CppEncoder::encode_if_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ball::v1::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"condition", encode_expression(inner[0])});
    if (inner.size() > 1 && inner[1].is_object())
        fields.push_back({"then", encode_expression(inner[1])});
    if (inner.size() > 2 && inner[2].is_object())
        fields.push_back({"else", encode_expression(inner[2])});
    return make_std_call("if", std::move(fields));
}

ball::v1::Expression CppEncoder::encode_for_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ball::v1::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"init", encode_expression(inner[0])});
    if (inner.size() > 2 && inner[2].is_object())
        fields.push_back({"condition", encode_expression(inner[2])});
    if (inner.size() > 3 && inner[3].is_object())
        fields.push_back({"update", encode_expression(inner[3])});
    if (inner.size() > 4 && inner[4].is_object())
        fields.push_back({"body", encode_expression(inner[4])});
    return make_std_call("for", std::move(fields));
}

ball::v1::Expression CppEncoder::encode_range_for_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ball::v1::Expression>> fields;
    if (inner.size() >= 2) {
        auto var_name = inner[0].value("name", "item");
        std::string var_type = "auto";
        if (inner[0].contains("type") && inner[0]["type"].contains("qualType"))
            var_type = inner[0]["type"]["qualType"].get<std::string>();

        ball::v1::Expression vn;
        vn.mutable_literal()->set_string_value(var_name);
        fields.push_back({"variable", std::move(vn)});

        ball::v1::Expression vt;
        vt.mutable_literal()->set_string_value(var_type);
        fields.push_back({"variable_type", std::move(vt)});

        if (inner.size() >= 2 && inner[inner.size() - 2].is_object())
            fields.push_back({"iterable", encode_expression(inner[inner.size() - 2])});
        if (inner.back().is_object())
            fields.push_back({"body", encode_expression(inner.back())});
    }
    return make_std_call("for_in", std::move(fields));
}

ball::v1::Expression CppEncoder::encode_while_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ball::v1::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"condition", encode_expression(inner[0])});
    if (inner.size() > 1 && inner[1].is_object())
        fields.push_back({"body", encode_expression(inner[1])});
    return make_std_call("while", std::move(fields));
}

ball::v1::Expression CppEncoder::encode_do_while_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ball::v1::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"body", encode_expression(inner[0])});
    if (inner.size() > 1 && inner[1].is_object())
        fields.push_back({"condition", encode_expression(inner[1])});
    return make_std_call("do_while", std::move(fields));
}

ball::v1::Expression CppEncoder::encode_switch_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ball::v1::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"subject", encode_expression(inner[0])});
    return make_std_call("switch", std::move(fields));
}

// ================================================================
// Expressions
// ================================================================

ball::v1::Expression CppEncoder::encode_expression(const json& node) {
    if (++encode_depth_ > kMaxEncodeDepth) {
        --encode_depth_;
        return null_expr();
    }
    struct DepthGuard {
        int& d;
        ~DepthGuard() { --d; }
    } guard{encode_depth_};

    auto kind = node.value("kind", "");

    if (kind == "IntegerLiteral") {
        ball::v1::Expression e;
        e.mutable_literal()->set_int_value(
            std::stoll(node.value("value", "0")));
        return e;
    }
    if (kind == "FloatingLiteral") {
        ball::v1::Expression e;
        e.mutable_literal()->set_double_value(
            std::stod(node.value("value", "0.0")));
        return e;
    }
    if (kind == "StringLiteral") {
        ball::v1::Expression e;
        e.mutable_literal()->set_string_value(node.value("value", ""));
        return e;
    }
    if (kind == "CharacterLiteral") {
        ball::v1::Expression e;
        e.mutable_literal()->set_int_value(node.value("value", 0));
        return e;
    }
    if (kind == "CXXBoolLiteralExpr") {
        ball::v1::Expression e;
        e.mutable_literal()->set_bool_value(node.value("value", false));
        return e;
    }
    if (kind == "CXXNullPtrLiteralExpr") {
        return make_cpp_std_call("nullptr", {});
    }
    if (kind == "DeclRefExpr") {
        std::string ref_name;
        if (node.contains("referencedDecl") &&
            node["referencedDecl"].contains("name"))
            ref_name = node["referencedDecl"]["name"].get<std::string>();
        ball::v1::Expression e;
        e.mutable_reference()->set_name(ref_name);
        return e;
    }
    if (kind == "MemberExpr") return encode_member_expr(node);
    if (kind == "CallExpr") return encode_call_expr(node);
    if (kind == "CXXMemberCallExpr") return encode_member_call_expr(node);
    if (kind == "CXXOperatorCallExpr") return encode_operator_call_expr(node);
    if (kind == "BinaryOperator") return encode_binary_op(node);
    if (kind == "UnaryOperator") return encode_unary_op(node);
    if (kind == "CompoundAssignOperator") return encode_compound_assign_op(node);
    if (kind == "ConditionalOperator") return encode_conditional_op(node);
    if (kind == "CXXNewExpr") return encode_new_expr(node);
    if (kind == "CXXDeleteExpr") return encode_delete_expr(node);
    if (kind == "CXXStaticCastExpr" || kind == "CXXDynamicCastExpr" ||
        kind == "CXXReinterpretCastExpr" || kind == "CXXConstCastExpr")
        return encode_cpp_cast(node, kind);
    if (kind == "CStyleCastExpr" || kind == "CXXFunctionalCastExpr")
        return encode_c_style_cast(node);
    if (kind == "ImplicitCastExpr") return encode_implicit_cast(node);
    if (kind == "ArraySubscriptExpr") return encode_array_subscript(node);
    if (kind == "UnaryExprOrTypeTraitExpr") return encode_sizeof_alignof(node);
    if (kind == "CXXConstructExpr") return encode_construct_expr(node);
    if (kind == "InitListExpr") return encode_init_list_expr(node);
    if (kind == "LambdaExpr") return encode_lambda_expr(node);
    if (kind == "CXXThisExpr") {
        ball::v1::Expression e;
        e.mutable_reference()->set_name("this");
        return e;
    }
    if (kind == "CompoundStmt") return encode_compound_stmt(node);
    if (kind == "ParenExpr") {
        auto inner = node.value("inner", json::array());
        if (!inner.empty() && inner[0].is_object())
            return encode_expression(inner[0]);
        return null_expr();
    }

    // Default: recurse into inner.
    auto inner = node.value("inner", json::array());
    if (!inner.empty() && inner[0].is_object())
        return encode_expression(inner[0]);
    return null_expr();
}

ball::v1::Expression CppEncoder::encode_member_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    auto member_name = node.value("name", "");
    bool is_arrow = node.value("isArrow", false);

    ball::v1::Expression object_expr;
    if (!inner.empty() && inner[0].is_object())
        object_expr = encode_expression(inner[0]);
    else
        object_expr.mutable_reference()->set_name("this");

    if (is_arrow) {
        ball::v1::Expression mn;
        mn.mutable_literal()->set_string_value(member_name);
        return make_cpp_std_call("arrow", {
            {"pointer", std::move(object_expr)},
            {"member", std::move(mn)},
        });
    }

    ball::v1::Expression e;
    auto* fa = e.mutable_field_access();
    *fa->mutable_object() = std::move(object_expr);
    fa->set_field(member_name);
    return e;
}

ball::v1::Expression CppEncoder::encode_call_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.empty()) return null_expr();

    auto& callee = inner[0];
    std::string func_name;
    if (callee.is_object() && callee.value("kind", "") == "DeclRefExpr") {
        if (callee.contains("referencedDecl") &&
            callee["referencedDecl"].contains("name"))
            func_name = callee["referencedDecl"]["name"].get<std::string>();
    } else if (callee.is_object()) {
        func_name = callee.value("name", "");
    }

    ball::v1::Expression e;
    auto* call = e.mutable_call();
    call->set_module("");
    call->set_function(func_name);

    if (inner.size() > 1) {
        auto* mc = call->mutable_input()->mutable_message_creation();
        for (size_t i = 1; i < inner.size(); ++i) {
            if (!inner[i].is_object()) continue;
            auto* f = mc->add_fields();
            f->set_name("arg" + std::to_string(i - 1));
            *f->mutable_value() = encode_expression(inner[i]);
        }
    }
    return e;
}

ball::v1::Expression CppEncoder::encode_member_call_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.empty()) return null_expr();

    auto& member_expr = inner[0];
    auto member_name = member_expr.value("name", "");
    auto member_inner = member_expr.value("inner", json::array());

    ball::v1::Expression object_expr;
    if (!member_inner.empty() && member_inner[0].is_object())
        object_expr = encode_expression(member_inner[0]);
    else
        object_expr.mutable_reference()->set_name("this");

    ball::v1::Expression e;
    auto* call = e.mutable_call();
    call->set_module("");
    call->set_function(member_name);

    auto* mc = call->mutable_input()->mutable_message_creation();
    auto* sf = mc->add_fields();
    sf->set_name("self");
    *sf->mutable_value() = std::move(object_expr);

    for (size_t i = 1; i < inner.size(); ++i) {
        if (!inner[i].is_object()) continue;
        auto* f = mc->add_fields();
        f->set_name("arg" + std::to_string(i - 1));
        *f->mutable_value() = encode_expression(inner[i]);
    }
    return e;
}

ball::v1::Expression CppEncoder::encode_operator_call_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.size() >= 3) return encode_binary_op(node);
    return encode_unary_op(node);
}

ball::v1::Expression CppEncoder::encode_binary_op(const json& node) {
    auto opcode = node.value("opcode", "");
    auto inner = node.value("inner", json::array());
    if (inner.size() < 2) return null_expr();

    auto left = encode_expression(inner[0]);
    auto right = encode_expression(inner[1]);

    auto std_fn = binary_op_to_std(opcode);
    if (!std_fn.empty()) {
        return make_std_call(std_fn, {
            {"left", std::move(left)},
            {"right", std::move(right)},
        });
    }
    if (opcode == "=") {
        return make_std_call("assign", {
            {"target", std::move(left)},
            {"value", std::move(right)},
        });
    }
    return make_std_call("add", {
        {"left", std::move(left)},
        {"right", std::move(right)},
    });
}

ball::v1::Expression CppEncoder::encode_unary_op(const json& node) {
    auto opcode = node.value("opcode", "");
    auto inner = node.value("inner", json::array());
    if (inner.empty()) return null_expr();

    auto operand = encode_expression(inner[0]);

    if (opcode == "*")
        return make_cpp_std_call("deref", {{"pointer", std::move(operand)}});
    if (opcode == "&")
        return make_cpp_std_call("address_of", {{"value", std::move(operand)}});
    if (opcode == "-")
        return make_std_call("negate", {{"value", std::move(operand)}});
    if (opcode == "!")
        return make_std_call("not", {{"value", std::move(operand)}});
    if (opcode == "~")
        return make_std_call("bitwise_not", {{"value", std::move(operand)}});
    if (opcode == "++" || opcode == "--") {
        bool is_postfix = node.value("isPostfix", false);
        std::string fn;
        if (opcode == "++") fn = is_postfix ? "post_increment" : "pre_increment";
        else fn = is_postfix ? "post_decrement" : "pre_decrement";
        return make_std_call(fn, {{"value", std::move(operand)}});
    }
    return operand;
}

ball::v1::Expression CppEncoder::encode_compound_assign_op(const json& node) {
    auto opcode = node.value("opcode", "+=");
    auto inner = node.value("inner", json::array());
    if (inner.size() < 2) return null_expr();

    auto target = encode_expression(inner[0]);
    auto value = encode_expression(inner[1]);

    ball::v1::Expression op_expr;
    op_expr.mutable_literal()->set_string_value(opcode);

    return make_std_call("assign", {
        {"target", std::move(target)},
        {"value", std::move(value)},
        {"op", std::move(op_expr)},
    });
}

ball::v1::Expression CppEncoder::encode_conditional_op(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.size() < 3) return null_expr();
    return make_std_call("if", {
        {"condition", encode_expression(inner[0])},
        {"then", encode_expression(inner[1])},
        {"else", encode_expression(inner[2])},
    });
}

ball::v1::Expression CppEncoder::encode_new_expr(const json& node) {
    std::string type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        type = node["type"]["qualType"].get<std::string>();
    bool is_array = node.value("isArray", false);

    ball::v1::Expression t_expr, a_expr;
    t_expr.mutable_literal()->set_string_value(type);
    a_expr.mutable_literal()->set_bool_value(is_array);
    return make_cpp_std_call("cpp_new", {
        {"type", std::move(t_expr)},
        {"is_array", std::move(a_expr)},
    });
}

ball::v1::Expression CppEncoder::encode_delete_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    bool is_array = node.value("isArrayAsWritten", false);
    auto pointer = (!inner.empty() && inner[0].is_object())
        ? encode_expression(inner[0]) : null_expr();
    ball::v1::Expression a_expr;
    a_expr.mutable_literal()->set_bool_value(is_array);
    return make_cpp_std_call("cpp_delete", {
        {"pointer", std::move(pointer)},
        {"is_array", std::move(a_expr)},
    });
}

ball::v1::Expression CppEncoder::encode_cpp_cast(const json& node,
                                                   const std::string& kind) {
    auto inner = node.value("inner", json::array());
    std::string target_type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        target_type = node["type"]["qualType"].get<std::string>();

    std::string cast_kind = "static_cast";
    if (kind == "CXXStaticCastExpr") cast_kind = "static_cast";
    else if (kind == "CXXDynamicCastExpr") cast_kind = "dynamic_cast";
    else if (kind == "CXXReinterpretCastExpr") cast_kind = "reinterpret_cast";
    else if (kind == "CXXConstCastExpr") cast_kind = "const_cast";

    auto val = (!inner.empty() && inner[0].is_object())
        ? encode_expression(inner[0]) : null_expr();

    ball::v1::Expression tt, ck;
    tt.mutable_literal()->set_string_value(target_type);
    ck.mutable_literal()->set_string_value(cast_kind);
    return make_cpp_std_call("ptr_cast", {
        {"value", std::move(val)},
        {"target_type", std::move(tt)},
        {"cast_kind", std::move(ck)},
    });
}

ball::v1::Expression CppEncoder::encode_c_style_cast(const json& node) {
    auto inner = node.value("inner", json::array());
    std::string target_type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        target_type = node["type"]["qualType"].get<std::string>();

    auto val = (!inner.empty() && inner[0].is_object())
        ? encode_expression(inner[0]) : null_expr();

    ball::v1::Expression tt;
    tt.mutable_literal()->set_string_value(target_type);
    return make_std_call("as", {
        {"value", std::move(val)},
        {"type", std::move(tt)},
    });
}

ball::v1::Expression CppEncoder::encode_implicit_cast(const json& node) {
    auto inner = node.value("inner", json::array());
    if (!inner.empty() && inner[0].is_object())
        return encode_expression(inner[0]);
    return null_expr();
}

ball::v1::Expression CppEncoder::encode_array_subscript(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.size() < 2) return null_expr();
    return make_std_call("index", {
        {"target", encode_expression(inner[0])},
        {"index", encode_expression(inner[1])},
    });
}

ball::v1::Expression CppEncoder::encode_sizeof_alignof(const json& node) {
    auto name = node.value("name", "sizeof");
    std::string arg_type = "int";
    if (node.contains("argType") && node["argType"].contains("qualType"))
        arg_type = node["argType"]["qualType"].get<std::string>();

    ball::v1::Expression t;
    if (name == "sizeof") {
        t.mutable_literal()->set_string_value(arg_type);
        return make_cpp_std_call("cpp_sizeof", {{"type_or_expr", std::move(t)}});
    }
    t.mutable_literal()->set_string_value(arg_type);
    return make_cpp_std_call("cpp_alignof", {{"type", std::move(t)}});
}

ball::v1::Expression CppEncoder::encode_construct_expr(const json& node) {
    std::string type = "Object";
    if (node.contains("type") && node["type"].contains("qualType"))
        type = node["type"]["qualType"].get<std::string>();
    auto inner = node.value("inner", json::array());

    ball::v1::Expression e;
    auto* mc = e.mutable_message_creation();
    mc->set_type_name(type);
    for (size_t i = 0; i < inner.size(); ++i) {
        if (!inner[i].is_object()) continue;
        auto* f = mc->add_fields();
        f->set_name("arg" + std::to_string(i));
        *f->mutable_value() = encode_expression(inner[i]);
    }
    return e;
}

ball::v1::Expression CppEncoder::encode_init_list_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    ball::v1::Expression elements_expr;
    auto* lv = elements_expr.mutable_literal()->mutable_list_value();
    for (const auto& child : inner) {
        if (child.is_object())
            *lv->add_elements() = encode_expression(child);
    }
    return make_cpp_std_call("init_list", {{"elements", std::move(elements_expr)}});
}

ball::v1::Expression CppEncoder::encode_lambda_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    ball::v1::Expression body_expr;
    for (const auto& child : inner) {
        if (child.is_object() && child.value("kind", "") == "CompoundStmt") {
            body_expr = encode_compound_stmt(child);
            break;
        }
    }

    ball::v1::Expression e;
    auto* func = e.mutable_lambda();
    func->set_name("");
    if (body_expr.has_block())
        *func->mutable_body() = std::move(body_expr);
    return e;
}

// ================================================================
// Helpers
// ================================================================

std::string CppEncoder::anon_name() {
    return "__anon_" + std::to_string(anon_counter_++);
}

ball::v1::Expression CppEncoder::null_expr() {
    ball::v1::Expression e;
    e.mutable_literal()->set_string_value("null");
    return e;
}

ball::v1::Expression CppEncoder::make_std_call(
    const std::string& function,
    std::vector<std::pair<std::string, ball::v1::Expression>> fields) {
    ball::v1::Expression e;
    auto* call = e.mutable_call();
    call->set_module("std");
    call->set_function(function);

    if (!fields.empty()) {
        auto* mc = call->mutable_input()->mutable_message_creation();
        for (auto& [name, val] : fields) {
            auto* f = mc->add_fields();
            f->set_name(name);
            *f->mutable_value() = std::move(val);
        }
    }
    return e;
}

ball::v1::Expression CppEncoder::make_cpp_std_call(
    const std::string& function,
    std::vector<std::pair<std::string, ball::v1::Expression>> fields) {
    ball::v1::Expression e;
    auto* call = e.mutable_call();
    call->set_module("cpp_std");
    call->set_function(function);

    if (!fields.empty()) {
        auto* mc = call->mutable_input()->mutable_message_creation();
        for (auto& [name, val] : fields) {
            auto* f = mc->add_fields();
            f->set_name(name);
            *f->mutable_value() = std::move(val);
        }
    }
    return e;
}

std::string CppEncoder::extract_return_type(const json& node) {
    std::string type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        type = node["type"]["qualType"].get<std::string>();
    // Strip parameters: "int (int, int)" → "int"
    auto paren = type.find('(');
    if (paren != std::string::npos && paren > 0) {
        type = type.substr(0, paren);
        // Trim trailing whitespace.
        while (!type.empty() && type.back() == ' ') type.pop_back();
    }
    return type;
}

std::vector<std::pair<std::string, std::string>>
CppEncoder::extract_params(const json& node) {
    std::vector<std::pair<std::string, std::string>> params;
    auto inner = node.value("inner", json::array());
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") != "ParmVarDecl") continue;
        std::string name = child.value("name", "_");
        std::string type = "int";
        if (child.contains("type") && child["type"].contains("qualType"))
            type = child["type"]["qualType"].get<std::string>();
        params.emplace_back(name, type);
    }
    return params;
}

google::protobuf::Value CppEncoder::encode_params_meta(
    const std::vector<std::pair<std::string, std::string>>& params) {
    google::protobuf::Value val;
    auto* list = val.mutable_list_value();
    for (const auto& [name, type] : params) {
        auto* pv = list->add_values()->mutable_struct_value();
        (*pv->mutable_fields())["name"].set_string_value(name);
        (*pv->mutable_fields())["type"].set_string_value(type);
    }
    return val;
}

bool CppEncoder::has_qualifier(const json& node, const std::string& qualifier) {
    if (node.value("storageClass", "") == qualifier) return true;
    if (qualifier == "constexpr" && node.value("constexpr", false)) return true;
    if (qualifier == "virtual" && node.value("virtual", false)) return true;
    if (qualifier == "inline" && node.value("inline", false)) return true;
    if (qualifier == "explicit" && node.value("explicit", false)) return true;
    if (qualifier == "const") {
        std::string type;
        if (node.contains("type") && node["type"].contains("qualType"))
            type = node["type"]["qualType"].get<std::string>();
        if (type.find("const ") == 0 || type.find(" const") != std::string::npos)
            return true;
    }
    if (qualifier == "static" && node.value("storageClass", "") == "static")
        return true;
    return false;
}

const json* CppEncoder::find_child(const json& node, const std::string& kind) {
    if (!node.contains("inner") || !node["inner"].is_array()) return nullptr;
    for (const auto& child : node["inner"]) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") == kind) return &child;
    }
    return nullptr;
}

const json* CppEncoder::find_child_expr(const json& node) {
    if (!node.contains("inner") || !node["inner"].is_array()) return nullptr;
    for (const auto& child : node["inner"]) {
        if (!child.is_object()) continue;
        auto k = child.value("kind", "");
        if (k != "ParmVarDecl" && k != "VarDecl") return &child;
    }
    return nullptr;
}

google::protobuf::Value CppEncoder::list_value(
    const std::vector<std::string>& items) {
    google::protobuf::Value val;
    auto* list = val.mutable_list_value();
    for (const auto& s : items)
        list->add_values()->set_string_value(s);
    return val;
}

google::protobuf::FieldDescriptorProto_Type
CppEncoder::map_cpp_type_to_proto(const std::string& cpp_type) {
    using FDT = google::protobuf::FieldDescriptorProto;
    std::string normalized = cpp_type;
    // Strip leading 'const '
    if (normalized.find("const ") == 0)
        normalized = normalized.substr(6);
    // Trim
    while (!normalized.empty() && normalized.back() == ' ') normalized.pop_back();

    if (normalized == "int" || normalized == "int32_t" || normalized == "int32")
        return FDT::TYPE_INT32;
    if (normalized == "long" || normalized == "int64_t" || normalized == "long long")
        return FDT::TYPE_INT64;
    if (normalized == "unsigned int" || normalized == "uint32_t")
        return FDT::TYPE_UINT32;
    if (normalized == "unsigned long" || normalized == "uint64_t")
        return FDT::TYPE_UINT64;
    if (normalized == "float") return FDT::TYPE_FLOAT;
    if (normalized == "double") return FDT::TYPE_DOUBLE;
    if (normalized == "bool") return FDT::TYPE_BOOL;
    if (normalized == "char" || normalized == "char *" ||
        normalized == "std::string" || normalized == "string")
        return FDT::TYPE_STRING;
    if (normalized == "void" || normalized == "void *")
        return FDT::TYPE_BYTES;
    return FDT::TYPE_MESSAGE;
}

std::string CppEncoder::binary_op_to_std(const std::string& opcode) {
    if (opcode == "+") return "add";
    if (opcode == "-") return "subtract";
    if (opcode == "*") return "multiply";
    if (opcode == "/") return "divide_double";
    if (opcode == "%") return "modulo";
    if (opcode == "==") return "equals";
    if (opcode == "!=") return "not_equals";
    if (opcode == "<") return "less_than";
    if (opcode == ">") return "greater_than";
    if (opcode == "<=") return "lte";
    if (opcode == ">=") return "gte";
    if (opcode == "&&") return "and";
    if (opcode == "||") return "or";
    if (opcode == "&") return "bitwise_and";
    if (opcode == "|") return "bitwise_or";
    if (opcode == "^") return "bitwise_xor";
    if (opcode == "<<") return "left_shift";
    if (opcode == ">>") return "right_shift";
    return "";
}

}  // namespace ball
