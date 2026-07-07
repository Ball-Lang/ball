// ball::CppEncoder — translates a Clang JSON AST into a Ball Program.
//
// Faithful port of the Dart `encoder.dart` reference.
//
// #18: builds the protobuf-free `ball::ir` plain-struct IR directly (no
// libprotobuf). Cosmetic `google.protobuf.Struct metadata` and the
// DescriptorProto/EnumDescriptorProto payloads are plain `nlohmann::json`
// in proto3-JSON shape (the latter via ball_ir's descriptor_build helpers).

#include "encoder.h"

#include <algorithm>
#include <memory>
#include <utility>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace ball {

// ================================================================
// File-local IR construction helpers
// ================================================================
//
// `ir` names `ball::ir` from inside `namespace ball`. These build the common
// leaf/wrapper Expression shapes so the encoder body reads close to the old
// protobuf-builder code (multi-use — literals/references/message-creations
// recur throughout).
namespace {

ir::ExpressionPtr to_ptr(ir::Expression e) {
    return std::make_unique<ir::Expression>(std::move(e));
}

ir::Expression literal_expr(ir::Literal lit) {
    ir::Expression e;
    e.kind = ir::ExprKind::Literal;
    e.literal = std::make_unique<ir::Literal>(std::move(lit));
    return e;
}

ir::Expression int_literal(int64_t v) {
    ir::Literal l;
    l.kind = ir::LiteralKind::Int;
    l.intValue = v;
    return literal_expr(std::move(l));
}

ir::Expression double_literal(double v) {
    ir::Literal l;
    l.kind = ir::LiteralKind::Double;
    l.doubleValue = v;
    return literal_expr(std::move(l));
}

ir::Expression string_literal(const std::string& s) {
    ir::Literal l;
    l.kind = ir::LiteralKind::String;
    l.stringValue = s;
    return literal_expr(std::move(l));
}

ir::Expression bool_literal(bool v) {
    ir::Literal l;
    l.kind = ir::LiteralKind::Bool;
    l.boolValue = v;
    return literal_expr(std::move(l));
}

ir::Expression reference_expr(const std::string& name) {
    ir::Expression e;
    e.kind = ir::ExprKind::Reference;
    e.reference = std::make_unique<ir::Reference>();
    e.reference->name = name;
    return e;
}

// A call expression with an unset input (caller fills `.call->input`).
ir::Expression call_expr(const std::string& module,
                         const std::string& function) {
    ir::Expression e;
    e.kind = ir::ExprKind::Call;
    e.call = std::make_unique<ir::FunctionCall>();
    e.call->module = module;
    e.call->function = function;
    return e;
}

// A message-creation expression with the given typeName and named fields.
ir::Expression message_creation_expr(
    const std::string& type_name,
    std::vector<std::pair<std::string, ir::Expression>> fields) {
    ir::Expression e;
    e.kind = ir::ExprKind::MessageCreation;
    e.messageCreation = std::make_unique<ir::MessageCreation>();
    e.messageCreation->typeName = type_name;
    for (auto& [name, val] : fields) {
        ir::FieldValuePair fp;
        fp.name = name;
        fp.value = to_ptr(std::move(val));
        e.messageCreation->fields.push_back(std::move(fp));
    }
    return e;
}

// A named-field pair for call/message-creation inputs.
using Field = std::pair<std::string, ir::Expression>;

// Move-collects field pairs into a vector. `ir::Expression` is move-only, so a
// braced `std::initializer_list` (which only exposes const elements → forces a
// copy) cannot be used to build the field vector; this variadic helper moves
// each pair in instead.
template <typename... Fs>
std::vector<Field> make_fields(Fs&&... fs) {
    std::vector<Field> v;
    v.reserve(sizeof...(fs));
    (v.emplace_back(std::move(fs)), ...);
    return v;
}

}  // namespace

// ================================================================
// Construction
// ================================================================

CppEncoder::CppEncoder(const std::string& source_name,
                        const std::string& source_version)
    : source_name_(source_name), source_version_(source_version) {}

// ================================================================
// Public API
// ================================================================

ir::Program CppEncoder::encode_from_clang_ast(const std::string& json_str) {
    auto ast = json::parse(json_str);

    // Initialize base modules.
    ir::Module std_mod;
    std_mod.name = "std";
    std_mod.description = "Universal std base module reference.";
    modules_.push_back(std::move(std_mod));

    ir::Module mem_mod;
    mem_mod.name = "std_memory";
    mem_mod.description = "Linear memory simulation module reference.";
    modules_.push_back(std::move(mem_mod));

    // Initialize main user module.
    main_module_.name = "main";
    main_module_.description = "C++ source module: " + source_name_;

    // Walk the translation unit.
    encode_translation_unit(ast);

    modules_.push_back(std::move(main_module_));

    // Build the program.
    ir::Program program;
    program.name = source_name_;
    program.version = source_version_;
    program.entryModule = "main";
    program.entryFunction = "main";
    program.modules = std::move(modules_);

    // Set source language metadata (proto3-JSON Struct == plain JSON object).
    program.metadata["source_language"] = "cpp";
    program.metadata["encoder_version"] = "0.1.0";

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

    // Detect overloads: if a function with this name already exists,
    // mangle by appending param types (e.g. add$int_double)
    std::string unique_name = name;
    bool is_overload = false;
    for (size_t i = 0; i < main_module_.functions.size(); ++i) {
        const std::string& existing = main_module_.functions[i].name;
        if (existing == name ||
            existing.substr(0, existing.find('$')) == name) {
            // Build mangled name from param types
            std::string suffix;
            for (const auto& p : params) {
                if (!suffix.empty()) suffix += "_";
                // Use simple type name (strip const, &, *)
                std::string t = p.second;
                for (auto c : {'&', '*'}) {
                    auto pos = t.find(c);
                    if (pos != std::string::npos) t.erase(pos);
                }
                if (t.substr(0, 6) == "const ") t = t.substr(6);
                // Replace spaces and :: with _
                std::replace(t.begin(), t.end(), ' ', '_');
                size_t pos;
                while ((pos = t.find("::")) != std::string::npos)
                    t.replace(pos, 2, "_");
                suffix += t;
            }
            unique_name = name + "$" + suffix;
            is_overload = true;
            break;
        }
    }

    main_module_.functions.emplace_back();
    auto* func = &main_module_.functions.back();
    func->name = unique_name;
    func->outputType = return_type;
    func->inputType = "";
    func->isBase = false;

    func->metadata["kind"] = "function";
    func->metadata["params"] = encode_params_meta(params);

    if (is_overload) {
        func->metadata["original_name"] = name;
        func->metadata["is_overload"] = true;
    }

    if (has_qualifier(node, "static"))
        func->metadata["is_static"] = true;
    if (has_qualifier(node, "inline"))
        func->metadata["annotations"] = list_value({"inline"});
    if (has_qualifier(node, "constexpr"))
        func->metadata["is_const"] = true;
    if (has_qualifier(node, "virtual"))
        func->metadata["is_abstract"] = true;

    if (body)
        func->body = to_ptr(encode_compound_stmt(*body));
}

// ================================================================
// Classes / structs
// ================================================================

void CppEncoder::encode_class_decl(const json& node) {
    auto name = node.value("name", anon_name());
    auto tag_used = node.value("tagUsed", "class");
    bool is_struct = (tag_used == "struct");

    main_module_.typeDefs.emplace_back();
    auto* td = &main_module_.typeDefs.back();
    td->name = name;
    td->metadata["kind"] = is_struct ? "struct" : "class";

    int field_number = 1;
    std::vector<ir::descriptor_build::FieldSpec> field_specs;

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
        td->metadata["superclass"] = bases[0];
        if (bases.size() > 1) {
            json ifaces = json::array();
            for (size_t i = 1; i < bases.size(); ++i)
                ifaces.push_back(bases[i]);
            td->metadata["interfaces"] = std::move(ifaces);
        }
    }

    // Encode members.
    json fields_meta = json::array();

    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        auto ck = child.value("kind", "");

        if (ck == "FieldDecl") {
            auto field_name = child.value("name", "__field" + std::to_string(field_number));
            std::string field_type = "int";
            if (child.contains("type") && child["type"].contains("qualType"))
                field_type = child["type"]["qualType"].get<std::string>();

            field_specs.push_back(ir::descriptor_build::FieldSpec{
                field_name, field_number++, field_type});

            json fm = json::object();
            fm["name"] = field_name;
            fm["type"] = field_type;
            if (has_qualifier(child, "const"))
                fm["is_final"] = true;
            if (has_qualifier(child, "static"))
                fm["is_static"] = true;
            fields_meta.push_back(std::move(fm));
        } else if (ck == "CXXMethodDecl") {
            encode_method_decl(child, name);
        } else if (ck == "CXXConstructorDecl") {
            encode_constructor_decl(child, name);
        } else if (ck == "CXXDestructorDecl") {
            encode_destructor_decl(child, name);
        } else if (ck == "CXXConversionDecl") {
            encode_conversion_decl(child, name);
        }
    }

    // `td` still valid: the member encoders above only push to
    // main_module_.functions, never to typeDefs.
    td->metadata["fields"] = std::move(fields_meta);
    td->descriptor = ir::descriptor_build::buildDescriptorProto(name, field_specs);
}

void CppEncoder::encode_method_decl(const json& node,
                                     const std::string& class_name) {
    auto method_name = node.value("name", anon_name());
    auto return_type = extract_return_type(node);
    auto params = extract_params(node);
    auto* body = find_child(node, "CompoundStmt");

    main_module_.functions.emplace_back();
    auto* func = &main_module_.functions.back();
    func->name = class_name + "." + method_name;
    func->outputType = return_type;
    func->isBase = false;

    func->metadata["kind"] = "method";
    func->metadata["params"] = encode_params_meta(params);

    if (has_qualifier(node, "static"))
        func->metadata["is_static"] = true;
    if (has_qualifier(node, "virtual")) {
        func->metadata["is_abstract"] = (body == nullptr);
        func->metadata["is_override"] = false;
    }
    if (has_qualifier(node, "const")) {
        func->metadata["annotations"].push_back("const");
    }

    if (body)
        func->body = to_ptr(encode_compound_stmt(*body));
}

void CppEncoder::encode_constructor_decl(const json& node,
                                          const std::string& class_name) {
    auto params = extract_params(node);
    auto* body = find_child(node, "CompoundStmt");

    main_module_.functions.emplace_back();
    auto* func = &main_module_.functions.back();
    func->name = class_name + ".new";
    func->outputType = "";
    func->isBase = false;

    func->metadata["kind"] = "constructor";
    func->metadata["params"] = encode_params_meta(params);

    if (has_qualifier(node, "explicit")) {
        func->metadata["annotations"].push_back("explicit");
    }

    if (body)
        func->body = to_ptr(encode_compound_stmt(*body));
}

void CppEncoder::encode_destructor_decl(const json& node,
                                         const std::string& class_name) {
    auto* body = find_child(node, "CompoundStmt");

    main_module_.functions.emplace_back();
    auto* func = &main_module_.functions.back();
    func->name = class_name + ".~" + class_name;
    func->outputType = "";
    func->isBase = false;

    func->metadata["kind"] = "method";
    json annots = json::array();
    annots.push_back("destructor");
    if (has_qualifier(node, "virtual"))
        annots.push_back("virtual");
    func->metadata["annotations"] = std::move(annots);

    if (body)
        func->body = to_ptr(encode_compound_stmt(*body));
}

void CppEncoder::encode_conversion_decl(const json& node,
                                         const std::string& class_name) {
    auto method_name = node.value("name", "operator");
    auto return_type = extract_return_type(node);
    auto params = extract_params(node);
    auto* body = find_child(node, "CompoundStmt");

    main_module_.functions.emplace_back();
    auto* func = &main_module_.functions.back();
    func->name = class_name + "." + method_name;
    func->outputType = return_type;
    func->isBase = false;

    func->metadata["kind"] = "operator";
    func->metadata["is_operator"] = true;
    func->metadata["is_conversion_operator"] = true;
    func->metadata["conversion_type"] = return_type;
    func->metadata["params"] = encode_params_meta(params);

    if (body)
        func->body = to_ptr(encode_compound_stmt(*body));
}

// ================================================================
// Enums
// ================================================================

void CppEncoder::encode_enum_decl(const json& node) {
    auto name = node.value("name", anon_name());
    bool is_scoped = node.contains("scopedEnumTag");

    auto inner = node.value("inner", json::array());
    std::vector<ir::descriptor_build::EnumValueSpec> values;
    int number = 0;
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") == "EnumConstantDecl") {
            values.push_back(ir::descriptor_build::EnumValueSpec{
                child.value("name", "value" + std::to_string(number)), number});
            number++;
        }
    }

    json enum_json = ir::descriptor_build::buildEnumDescriptorProto(name, values);
    if (!main_module_.enums.is_array()) main_module_.enums = json::array();
    main_module_.enums.push_back(std::move(enum_json));

    if (is_scoped) {
        main_module_.typeDefs.emplace_back();
        auto* td = &main_module_.typeDefs.back();
        td->name = name;
        td->metadata["kind"] = "enum";
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

    main_module_.typeAliases.emplace_back();
    auto* alias = &main_module_.typeAliases.back();
    alias->name = name;
    alias->targetType = target_type;

    alias->metadata["kind"] = "typedef";
    alias->metadata["aliased_type"] = target_type;
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
    // Intentionally dropped: a `using` declaration only introduces a name alias
    // into the C++ namespace scope and produces no runtime value or computation.
    // Since Ball's semantic content is the expression tree (names are already
    // fully qualified by the time they are referenced here), discarding the
    // using-decl cannot change what the encoded program computes.
}

void CppEncoder::encode_class_template_decl(const json& node) {
    auto inner = node.value("inner", json::array());

    // Extract template type parameters first
    std::vector<std::string> type_params;
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        auto ck = child.value("kind", "");
        if (ck == "TemplateTypeParmDecl") {
            type_params.push_back(child.value("name", "T"));
        } else if (ck == "NonTypeTemplateParmDecl") {
            // Non-type template param, e.g. int N
            std::string ptype = "int";
            if (child.contains("type") && child["type"].contains("qualType"))
                ptype = child["type"]["qualType"].get<std::string>();
            type_params.push_back(ptype + " " + child.value("name", "N"));
        }
    }

    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") == "CXXRecordDecl") {
            encode_class_decl(child);
            // Attach template params to the most recently added type_def
            if (!main_module_.typeDefs.empty() && !type_params.empty()) {
                auto* td = &main_module_.typeDefs.back();
                for (const auto& tp : type_params) {
                    ir::TypeParameter param;
                    param.name = tp;
                    td->typeParams.push_back(std::move(param));
                }
                // Also store in metadata for compilers that read metadata
                json tp_list = json::array();
                for (const auto& tp : type_params)
                    tp_list.push_back(tp);
                td->metadata["type_params"] = std::move(tp_list);
            }
            // Capture explicit/partial specializations as metadata strings.
            if (!main_module_.typeDefs.empty()) {
                auto* td = &main_module_.typeDefs.back();
                json specs = json::array();
                for (const auto& spec : inner) {
                    if (!spec.is_object()) continue;
                    auto sk = spec.value("kind", "");
                    if (sk == "ClassTemplateSpecializationDecl" ||
                        sk == "ClassTemplatePartialSpecializationDecl") {
                        json sv = json::object();
                        if (spec.contains("type") && spec["type"].contains("qualType")) {
                            sv["type_args"] =
                                spec["type"]["qualType"].get<std::string>();
                        } else {
                            sv["type_args"] = "<unknown>";
                        }
                        specs.push_back(std::move(sv));
                    }
                }
                td->metadata["specializations"] = std::move(specs);
            }
            break;
        }
    }
}

void CppEncoder::encode_function_template_decl(const json& node) {
    auto inner = node.value("inner", json::array());

    // Extract template type parameters
    std::vector<std::string> type_params;
    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        auto ck = child.value("kind", "");
        if (ck == "TemplateTypeParmDecl") {
            type_params.push_back(child.value("name", "T"));
        } else if (ck == "NonTypeTemplateParmDecl") {
            std::string ptype = "int";
            if (child.contains("type") && child["type"].contains("qualType"))
                ptype = child["type"]["qualType"].get<std::string>();
            type_params.push_back(ptype + " " + child.value("name", "N"));
        }
    }

    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        if (child.value("kind", "") == "FunctionDecl") {
            encode_function_decl(child);
            // Attach template params to the most recently added function
            if (!main_module_.functions.empty() && !type_params.empty()) {
                auto* func = &main_module_.functions.back();
                json tp_list = json::array();
                for (const auto& tp : type_params)
                    tp_list.push_back(tp);
                func->metadata["type_params"] = std::move(tp_list);

                // Capture specialization metadata (best-effort from AST).
                json specs = json::array();
                for (const auto& spec : inner) {
                    if (!spec.is_object()) continue;
                    auto sk = spec.value("kind", "");
                    if (sk.find("Specialization") != std::string::npos) {
                        json sv = json::object();
                        if (spec.contains("type") && spec["type"].contains("qualType")) {
                            sv["type_args"] =
                                spec["type"]["qualType"].get<std::string>();
                        } else {
                            sv["type_args"] = "<unknown>";
                        }
                        specs.push_back(std::move(sv));
                    }
                }
                func->metadata["specializations"] = std::move(specs);

                // Capture enable_if/SFINAE hints from function type strings.
                std::string qtype;
                if (child.contains("type") && child["type"].contains("qualType")) {
                    qtype = child["type"]["qualType"].get<std::string>();
                }
                if (!qtype.empty() && qtype.find("enable_if") != std::string::npos) {
                    json a = json::object();
                    a["name"] = "enable_if";
                    a["expr"] = qtype;
                    func->metadata["annotations"].push_back(std::move(a));
                }
            }
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

    main_module_.functions.emplace_back();
    auto* func = &main_module_.functions.back();
    func->name = name;
    func->outputType = var_type;
    func->isBase = false;

    func->metadata["kind"] = "top_level_variable";
    if (has_qualifier(node, "const") || has_qualifier(node, "constexpr"))
        func->metadata["is_const"] = true;

    if (init_child)
        func->body = to_ptr(encode_expression(*init_child));
}

// ================================================================
// Statements
// ================================================================

ir::Expression CppEncoder::encode_compound_stmt(const json& node) {
    ir::Expression expr;
    expr.kind = ir::ExprKind::Block;
    expr.block = std::make_unique<ir::Block>();
    auto inner = node.value("inner", json::array());

    for (const auto& child : inner) {
        if (!child.is_object()) continue;
        auto* stmt = encode_statement(child);
        if (stmt) expr.block->statements.push_back(std::move(*stmt));
        delete stmt;
    }
    return expr;
}

ir::Statement* CppEncoder::encode_statement(const json& node) {
    auto kind = node.value("kind", "");

    if (kind == "DeclStmt") return encode_decl_stmt(node);
    if (kind == "ReturnStmt") {
        auto* s = new ir::Statement();
        *s = encode_return_stmt(node);
        return s;
    }

    // Wrap an expression as an expression-statement.
    auto expr_stmt = [](ir::Expression e) {
        auto* s = new ir::Statement();
        s->kind = ir::StatementKind::Expr;
        s->expr = std::make_unique<ir::Expression>(std::move(e));
        return s;
    };

    if (kind == "IfStmt") return expr_stmt(encode_if_stmt(node));
    if (kind == "ForStmt") return expr_stmt(encode_for_stmt(node));
    if (kind == "CXXForRangeStmt") return expr_stmt(encode_range_for_stmt(node));
    if (kind == "WhileStmt") return expr_stmt(encode_while_stmt(node));
    if (kind == "DoStmt") return expr_stmt(encode_do_while_stmt(node));
    if (kind == "SwitchStmt") return expr_stmt(encode_switch_stmt(node));
    if (kind == "CompoundStmt") return expr_stmt(encode_compound_stmt(node));
    if (kind == "BreakStmt") return expr_stmt(make_std_call("break", {}));
    if (kind == "ContinueStmt") return expr_stmt(make_std_call("continue", {}));
    if (kind == "NullStmt") return nullptr;

    // Try as expression statement.
    return expr_stmt(encode_expression(node));
}

ir::Statement* CppEncoder::encode_decl_stmt(const json& node) {
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

    auto* s = new ir::Statement();
    s->kind = ir::StatementKind::Let;
    s->let = std::make_unique<ir::LetBinding>();
    auto* let = s->let.get();
    let->name = name;

    if (init) {
        let->value = to_ptr(encode_expression(*init));
    } else {
        let->value = to_ptr(string_literal("__no_init__"));
    }

    if (!var_type.empty())
        let->metadata["type"] = var_type;
    if (has_qualifier(decl, "const"))
        let->metadata["is_final"] = true;

    return s;
}

ir::Statement CppEncoder::encode_return_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
    if (!inner.empty() && inner[0].is_object()) {
        fields.push_back({"value", encode_expression(inner[0])});
    }
    ir::Statement stmt;
    stmt.kind = ir::StatementKind::Expr;
    stmt.expr = to_ptr(make_std_call("return", std::move(fields)));
    return stmt;
}

// ================================================================
// Control flow
// ================================================================

ir::Expression CppEncoder::encode_if_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"condition", encode_expression(inner[0])});
    if (inner.size() > 1 && inner[1].is_object())
        fields.push_back({"then", encode_expression(inner[1])});
    if (inner.size() > 2 && inner[2].is_object())
        fields.push_back({"else", encode_expression(inner[2])});
    return make_std_call("if", std::move(fields));
}

ir::Expression CppEncoder::encode_for_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
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

ir::Expression CppEncoder::encode_range_for_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
    if (inner.size() >= 2) {
        auto var_name = inner[0].value("name", "item");
        std::string var_type = "auto";
        if (inner[0].contains("type") && inner[0]["type"].contains("qualType"))
            var_type = inner[0]["type"]["qualType"].get<std::string>();

        fields.push_back({"variable", string_literal(var_name)});
        fields.push_back({"variable_type", string_literal(var_type)});

        if (inner.size() >= 2 && inner[inner.size() - 2].is_object())
            fields.push_back({"iterable", encode_expression(inner[inner.size() - 2])});
        if (inner.back().is_object())
            fields.push_back({"body", encode_expression(inner.back())});
    }
    return make_std_call("for_in", std::move(fields));
}

ir::Expression CppEncoder::encode_while_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"condition", encode_expression(inner[0])});
    if (inner.size() > 1 && inner[1].is_object())
        fields.push_back({"body", encode_expression(inner[1])});
    return make_std_call("while", std::move(fields));
}

ir::Expression CppEncoder::encode_do_while_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"body", encode_expression(inner[0])});
    if (inner.size() > 1 && inner[1].is_object())
        fields.push_back({"condition", encode_expression(inner[1])});
    return make_std_call("do_while", std::move(fields));
}

ir::Expression CppEncoder::encode_switch_stmt(const json& node) {
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
    if (inner.size() > 0 && inner[0].is_object())
        fields.push_back({"subject", encode_expression(inner[0])});
    return make_std_call("switch", std::move(fields));
}

// ================================================================
// Expressions
// ================================================================

ir::Expression CppEncoder::encode_expression(const json& node) {
    if (++encode_depth_ > kMaxEncodeDepth) {
        --encode_depth_;
        return null_expr();
    }
    struct DepthGuard {
        int& d;
        ~DepthGuard() { --d; }
    } guard{encode_depth_};

    auto kind = node.value("kind", "");

    if (kind == "IntegerLiteral")
        return int_literal(std::stoll(node.value("value", "0")));
    if (kind == "FloatingLiteral")
        return double_literal(std::stod(node.value("value", "0.0")));
    if (kind == "StringLiteral")
        return string_literal(node.value("value", ""));
    if (kind == "CharacterLiteral")
        return int_literal(node.value("value", 0));
    if (kind == "CXXBoolLiteralExpr")
        return bool_literal(node.value("value", false));
    if (kind == "CXXNullPtrLiteralExpr") {
        // Emit a literal with no kind set (unset oneof = null semantics).
        ir::Expression e;
        e.kind = ir::ExprKind::Literal;
        e.literal = std::make_unique<ir::Literal>();
        return e;
    }
    if (kind == "DeclRefExpr") {
        std::string ref_name;
        if (node.contains("referencedDecl") &&
            node["referencedDecl"].contains("name"))
            ref_name = node["referencedDecl"]["name"].get<std::string>();
        return reference_expr(ref_name);
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
    if (kind == "CXXThisExpr") return reference_expr("this");
    if (kind == "CompoundStmt") return encode_compound_stmt(node);
    if (kind == "ReturnStmt") {
        // ReturnStmt can appear as the then/else branch of an IfStmt
        // without being wrapped in a CompoundStmt (braceless
        // `if (c) return x;`). Encode it as a bare `std.return` call
        // so the return semantics survive into the expression tree.
        auto inner = node.value("inner", json::array());
        std::vector<std::pair<std::string, ir::Expression>> fields;
        if (!inner.empty() && inner[0].is_object())
            fields.push_back({"value", encode_expression(inner[0])});
        return make_std_call("return", std::move(fields));
    }
    if (kind == "IfStmt") return encode_if_stmt(node);
    if (kind == "WhileStmt") return encode_while_stmt(node);
    if (kind == "ForStmt") return encode_for_stmt(node);
    if (kind == "DoStmt") return encode_do_while_stmt(node);
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

ir::Expression CppEncoder::encode_member_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    auto member_name = node.value("name", "");
    bool is_arrow = node.value("isArrow", false);
    (void)is_arrow;  // dot and arrow both project to field_access.

    ir::Expression object_expr;
    if (!inner.empty() && inner[0].is_object())
        object_expr = encode_expression(inner[0]);
    else
        object_expr = reference_expr("this");

    // Safe projection: dot/arrow(object, member) → field_access(object, member)
    ir::Expression e;
    e.kind = ir::ExprKind::FieldAccess;
    e.fieldAccess = std::make_unique<ir::FieldAccess>();
    e.fieldAccess->object = to_ptr(std::move(object_expr));
    e.fieldAccess->field = member_name;
    return e;
}

ir::Expression CppEncoder::encode_call_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.empty()) return null_expr();

    // Clang wraps the callee in `ImplicitCastExpr` (typically
    // FunctionToPointerDecay) before the `DeclRefExpr`. Walk through
    // implicit-cast and paren wrappers until we reach the actual
    // reference node.
    auto resolve_callee = [](const json& start) -> const json* {
        const json* cur = &start;
        while (cur && cur->is_object()) {
            auto k = cur->value("kind", "");
            if (k == "ImplicitCastExpr" || k == "ParenExpr" ||
                k == "CXXFunctionalCastExpr" || k == "CStyleCastExpr") {
                auto it = cur->find("inner");
                if (it == cur->end() || !it->is_array() || it->empty()) {
                    return cur;
                }
                cur = &(*it)[0];
                continue;
            }
            break;
        }
        return cur;
    };
    const json* callee = resolve_callee(inner[0]);
    std::string func_name;
    if (callee && callee->is_object() && callee->value("kind", "") == "DeclRefExpr") {
        if (callee->contains("referencedDecl") &&
            (*callee)["referencedDecl"].contains("name"))
            func_name = (*callee)["referencedDecl"]["name"].get<std::string>();
    } else if (callee && callee->is_object()) {
        func_name = callee->value("name", "");
    }

    ir::Expression e = call_expr("", func_name);

    if (inner.size() > 1) {
        std::vector<std::pair<std::string, ir::Expression>> fields;
        for (size_t i = 1; i < inner.size(); ++i) {
            if (!inner[i].is_object()) continue;
            fields.push_back({"arg" + std::to_string(i - 1),
                              encode_expression(inner[i])});
        }
        e.call->input = to_ptr(message_creation_expr("", std::move(fields)));
    }
    return e;
}

ir::Expression CppEncoder::encode_member_call_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.empty()) return null_expr();

    auto& member_expr = inner[0];
    auto member_name = member_expr.value("name", "");
    auto member_inner = member_expr.value("inner", json::array());

    ir::Expression object_expr;
    if (!member_inner.empty() && member_inner[0].is_object())
        object_expr = encode_expression(member_inner[0]);
    else
        object_expr = reference_expr("this");

    ir::Expression e = call_expr("", member_name);

    std::vector<std::pair<std::string, ir::Expression>> fields;
    fields.push_back({"self", std::move(object_expr)});
    for (size_t i = 1; i < inner.size(); ++i) {
        if (!inner[i].is_object()) continue;
        fields.push_back({"arg" + std::to_string(i - 1),
                          encode_expression(inner[i])});
    }
    e.call->input = to_ptr(message_creation_expr("", std::move(fields)));
    return e;
}

ir::Expression CppEncoder::encode_operator_call_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.size() >= 3) return encode_binary_op(node);
    return encode_unary_op(node);
}

ir::Expression CppEncoder::encode_binary_op(const json& node) {
    auto opcode = node.value("opcode", "");
    auto inner = node.value("inner", json::array());
    if (inner.size() < 2) return null_expr();

    auto left = encode_expression(inner[0]);
    auto right = encode_expression(inner[1]);

    auto std_fn = binary_op_to_std(opcode);
    if (!std_fn.empty()) {
        return make_std_call(std_fn, make_fields(
            Field{"left", std::move(left)},
            Field{"right", std::move(right)}));
    }
    if (opcode == "=") {
        return make_std_call("assign", make_fields(
            Field{"target", std::move(left)},
            Field{"value", std::move(right)}));
    }
    return make_std_call("add", make_fields(
        Field{"left", std::move(left)},
        Field{"right", std::move(right)}));
}

ir::Expression CppEncoder::encode_unary_op(const json& node) {
    auto opcode = node.value("opcode", "");
    auto inner = node.value("inner", json::array());
    if (inner.empty()) return null_expr();

    auto operand = encode_expression(inner[0]);

    if (opcode == "*")
        return operand;  // Safe projection: deref(pointer) → pointer expression directly
    if (opcode == "&")
        return operand;  // Safe projection: address_of(value) → value expression directly
    if (opcode == "-")
        return make_std_call("negate", make_fields(Field{"value", std::move(operand)}));
    if (opcode == "!")
        return make_std_call("not", make_fields(Field{"value", std::move(operand)}));
    if (opcode == "~")
        return make_std_call("bitwise_not", make_fields(Field{"value", std::move(operand)}));
    if (opcode == "++" || opcode == "--") {
        bool is_postfix = node.value("isPostfix", false);
        std::string fn;
        if (opcode == "++") fn = is_postfix ? "post_increment" : "pre_increment";
        else fn = is_postfix ? "post_decrement" : "pre_decrement";
        return make_std_call(fn, make_fields(Field{"value", std::move(operand)}));
    }
    return operand;
}

ir::Expression CppEncoder::encode_compound_assign_op(const json& node) {
    auto opcode = node.value("opcode", "+=");
    auto inner = node.value("inner", json::array());
    if (inner.size() < 2) return null_expr();

    auto target = encode_expression(inner[0]);
    auto value = encode_expression(inner[1]);

    return make_std_call("assign", make_fields(
        Field{"target", std::move(target)},
        Field{"value", std::move(value)},
        Field{"op", string_literal(opcode)}));
}

ir::Expression CppEncoder::encode_conditional_op(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.size() < 3) return null_expr();
    return make_std_call("if", make_fields(
        Field{"condition", encode_expression(inner[0])},
        Field{"then", encode_expression(inner[1])},
        Field{"else", encode_expression(inner[2])}));
}

ir::Expression CppEncoder::encode_new_expr(const json& node) {
    std::string type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        type = node["type"]["qualType"].get<std::string>();

    // Safe projection: cpp_new(type, args) → message_creation(type, args)
    auto inner = node.value("inner", json::array());
    std::vector<std::pair<std::string, ir::Expression>> fields;
    for (size_t i = 0; i < inner.size(); ++i) {
        if (!inner[i].is_object()) continue;
        fields.push_back({"arg" + std::to_string(i), encode_expression(inner[i])});
    }
    return message_creation_expr(type, std::move(fields));
}

ir::Expression CppEncoder::encode_delete_expr(const json& /*node*/) {
    // Safe projection: cpp_delete → noop (GC managed in Ball)
    return string_literal("/* delete (GC managed) */");
}

ir::Expression CppEncoder::encode_cpp_cast(const json& node,
                                            const std::string& kind) {
    auto inner = node.value("inner", json::array());
    std::string target_type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        target_type = node["type"]["qualType"].get<std::string>();

    auto val = (!inner.empty() && inner[0].is_object())
        ? encode_expression(inner[0]) : null_expr();

    if (kind == "CXXStaticCastExpr" || kind == "CXXDynamicCastExpr") {
        // Safe projection: static/dynamic cast → std.as(value, type)
        return make_std_call("as", make_fields(
            Field{"value", std::move(val)},
            Field{"type", string_literal(target_type)}));
    }
    if (kind == "CXXReinterpretCastExpr") {
        // Unsafe: reinterpret_cast → std_memory.memory_read_i64
        ir::Expression e = call_expr("std_memory", "memory_read_i64");
        std::vector<std::pair<std::string, ir::Expression>> fields;
        fields.push_back({"address", std::move(val)});
        e.call->input = to_ptr(message_creation_expr("MemReadInput", std::move(fields)));
        return e;
    }
    // const_cast — pass through the value unchanged
    return val;
}

ir::Expression CppEncoder::encode_c_style_cast(const json& node) {
    auto inner = node.value("inner", json::array());
    std::string target_type = "void";
    if (node.contains("type") && node["type"].contains("qualType"))
        target_type = node["type"]["qualType"].get<std::string>();

    auto val = (!inner.empty() && inner[0].is_object())
        ? encode_expression(inner[0]) : null_expr();

    return make_std_call("as", make_fields(
        Field{"value", std::move(val)},
        Field{"type", string_literal(target_type)}));
}

ir::Expression CppEncoder::encode_implicit_cast(const json& node) {
    auto inner = node.value("inner", json::array());
    if (!inner.empty() && inner[0].is_object())
        return encode_expression(inner[0]);
    return null_expr();
}

ir::Expression CppEncoder::encode_array_subscript(const json& node) {
    auto inner = node.value("inner", json::array());
    if (inner.size() < 2) return null_expr();
    return make_std_call("index", make_fields(
        Field{"target", encode_expression(inner[0])},
        Field{"index", encode_expression(inner[1])}));
}

ir::Expression CppEncoder::encode_sizeof_alignof(const json& node) {
    std::string arg_type = "int";
    if (node.contains("argType") && node["argType"].contains("qualType"))
        arg_type = node["argType"]["qualType"].get<std::string>();

    // Both sizeof and alignof → std_memory.memory_sizeof
    ir::Expression e = call_expr("std_memory", "memory_sizeof");
    std::vector<std::pair<std::string, ir::Expression>> fields;
    fields.push_back({"type_name", string_literal(arg_type)});
    e.call->input = to_ptr(message_creation_expr("SizeofInput", std::move(fields)));
    return e;
}

ir::Expression CppEncoder::encode_construct_expr(const json& node) {
    std::string type = "Object";
    if (node.contains("type") && node["type"].contains("qualType"))
        type = node["type"]["qualType"].get<std::string>();
    auto inner = node.value("inner", json::array());

    std::vector<std::pair<std::string, ir::Expression>> fields;
    for (size_t i = 0; i < inner.size(); ++i) {
        if (!inner[i].is_object()) continue;
        fields.push_back({"arg" + std::to_string(i), encode_expression(inner[i])});
    }
    return message_creation_expr(type, std::move(fields));
}

ir::Expression CppEncoder::encode_init_list_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    // Safe projection: init_list(elements) → list literal with the elements
    ir::Expression e;
    e.kind = ir::ExprKind::Literal;
    e.literal = std::make_unique<ir::Literal>();
    e.literal->kind = ir::LiteralKind::List;
    for (const auto& child : inner) {
        if (child.is_object())
            e.literal->listElements.push_back(encode_expression(child));
    }
    return e;
}

ir::Expression CppEncoder::encode_lambda_expr(const json& node) {
    auto inner = node.value("inner", json::array());
    ir::Expression body_expr;
    for (const auto& child : inner) {
        if (child.is_object() && child.value("kind", "") == "CompoundStmt") {
            body_expr = encode_compound_stmt(child);
            break;
        }
    }

    ir::Expression e;
    e.kind = ir::ExprKind::Lambda;
    e.lambda = std::make_unique<ir::FunctionDefinition>();
    e.lambda->name = "";
    if (body_expr.kind == ir::ExprKind::Block)
        e.lambda->body = to_ptr(std::move(body_expr));
    return e;
}

// ================================================================
// Helpers
// ================================================================

std::string CppEncoder::anon_name() {
    return "__anon_" + std::to_string(anon_counter_++);
}

ir::Expression CppEncoder::null_expr() {
    return string_literal("null");
}

ir::Expression CppEncoder::make_std_call(
    const std::string& function,
    std::vector<std::pair<std::string, ir::Expression>> fields) {
    ir::Expression e = call_expr("std", function);
    if (!fields.empty()) {
        e.call->input = to_ptr(message_creation_expr("", std::move(fields)));
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

json CppEncoder::encode_params_meta(
    const std::vector<std::pair<std::string, std::string>>& params) {
    json arr = json::array();
    for (const auto& [name, type] : params) {
        json pv = json::object();
        pv["name"] = name;
        pv["type"] = type;
        arr.push_back(std::move(pv));
    }
    return arr;
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

json CppEncoder::list_value(const std::vector<std::string>& items) {
    json arr = json::array();
    for (const auto& s : items)
        arr.push_back(s);
    return arr;
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
