// ball::build_cpp_std_module — C++-specific base module builder.
//
// Port of the Dart `cpp_std.dart` reference.

#include "cpp_std.h"

namespace ball {

namespace {

using google::protobuf::DescriptorProto;
using google::protobuf::FieldDescriptorProto;

const auto EXPR = FieldDescriptorProto::TYPE_MESSAGE;
const auto STRING = FieldDescriptorProto::TYPE_STRING;
const auto BOOL = FieldDescriptorProto::TYPE_BOOL;
const std::string EXPR_TYPE = ".ball.v1.Expression";
const std::string FVP_TYPE = ".ball.v1.FieldValuePair";

FieldDescriptorProto* add_field(
    DescriptorProto* type, const std::string& name, int number,
    FieldDescriptorProto::Type field_type,
    const std::string& type_name = "",
    FieldDescriptorProto::Label label = FieldDescriptorProto::LABEL_OPTIONAL
) {
    auto* f = type->add_field();
    f->set_name(name);
    f->set_number(number);
    f->set_type(field_type);
    f->set_label(label);
    if (!type_name.empty()) f->set_type_name(type_name);
    return f;
}

DescriptorProto* make_type(
    const std::string& name,
    std::vector<std::tuple<std::string, int, FieldDescriptorProto::Type,
                           std::string, FieldDescriptorProto::Label>> fields
) {
    auto* type = new DescriptorProto();
    type->set_name(name);
    for (const auto& [fname, fnum, ftype, ftname, flabel] : fields) {
        add_field(type, fname, fnum, ftype, ftname, flabel);
    }
    return type;
}

ball::v1::FunctionDefinition make_fn(
    const std::string& name, const std::string& input_type,
    const std::string& output_type, const std::string& description
) {
    ball::v1::FunctionDefinition fn;
    fn.set_name(name);
    fn.set_input_type(input_type);
    fn.set_output_type(output_type);
    fn.set_description(description);
    fn.set_is_base(true);
    return fn;
}

const auto OPT = FieldDescriptorProto::LABEL_OPTIONAL;
const auto REP = FieldDescriptorProto::LABEL_REPEATED;

}  // namespace

ball::v1::Module build_cpp_std_module() {
    ball::v1::Module mod;
    mod.set_name("cpp_std");
    mod.set_description(
        "C++-specific standard library base module. Functions here represent "
        "C++ language constructs (templates, RAII, operator overloading, "
        "pointer operations, references, etc.) that need special handling "
        "during normalization.");

    auto add_type = [&](DescriptorProto* t) {
        mod.mutable_types()->AddAllocated(t);
    };

    // Types
    add_type(make_type("DerefInput", {{"pointer", 1, EXPR, EXPR_TYPE, OPT}}));
    add_type(make_type("AddressOfInput", {{"value", 1, EXPR, EXPR_TYPE, OPT}}));
    add_type(make_type("ArrowAccessInput", {
        {"pointer", 1, EXPR, EXPR_TYPE, OPT},
        {"member", 2, STRING, "", OPT},
    }));
    add_type(make_type("PtrCastInput", {
        {"value", 1, EXPR, EXPR_TYPE, OPT},
        {"target_type", 2, STRING, "", OPT},
        {"cast_kind", 3, STRING, "", OPT},
    }));
    add_type(make_type("TemplateInstInput", {
        {"template_name", 1, STRING, "", OPT},
        {"type_args", 2, STRING, "", REP},
    }));
    add_type(make_type("ScopeResInput", {
        {"scope", 1, STRING, "", OPT},
        {"member", 2, STRING, "", OPT},
    }));
    add_type(make_type("NewInput", {
        {"type", 1, STRING, "", OPT},
        {"args", 2, EXPR, FVP_TYPE, REP},
        {"is_array", 3, BOOL, "", OPT},
        {"array_size", 4, EXPR, EXPR_TYPE, OPT},
    }));
    add_type(make_type("DeleteInput", {
        {"pointer", 1, EXPR, EXPR_TYPE, OPT},
        {"is_array", 2, BOOL, "", OPT},
    }));
    add_type(make_type("CppSizeofInput", {{"type_or_expr", 1, STRING, "", OPT}}));
    add_type(make_type("CppAlignofInput", {{"type", 1, STRING, "", OPT}}));
    add_type(make_type("CppTypeidInput", {{"value", 1, EXPR, EXPR_TYPE, OPT}}));
    add_type(make_type("RangeForInput", {
        {"variable", 1, STRING, "", OPT},
        {"variable_type", 2, STRING, "", OPT},
        {"range", 3, EXPR, EXPR_TYPE, OPT},
        {"body", 4, EXPR, EXPR_TYPE, OPT},
        {"is_ref", 5, BOOL, "", OPT},
        {"is_const", 6, BOOL, "", OPT},
    }));
    add_type(make_type("InitListInput", {
        {"elements", 1, EXPR, EXPR_TYPE, REP},
    }));
    add_type(make_type("StructuredBindingInput", {
        {"names", 1, STRING, "", REP},
        {"initializer", 2, EXPR, EXPR_TYPE, OPT},
        {"is_ref", 3, BOOL, "", OPT},
        {"is_const", 4, BOOL, "", OPT},
    }));
    add_type(make_type("CppLambdaCaptureInput", {
        {"captures", 1, STRING, "", REP},
        {"params", 2, EXPR, FVP_TYPE, REP},
        {"return_type", 3, STRING, "", OPT},
        {"body", 4, EXPR, EXPR_TYPE, OPT},
        {"is_mutable", 5, BOOL, "", OPT},
    }));
    add_type(make_type("StaticAssertInput", {
        {"condition", 1, EXPR, EXPR_TYPE, OPT},
        {"message", 2, STRING, "", OPT},
    }));
    add_type(make_type("NamespaceInput", {
        {"name", 1, STRING, "", OPT},
        {"body", 2, EXPR, EXPR_TYPE, OPT},
    }));
    add_type(make_type("UsingInput", {
        {"target", 1, STRING, "", OPT},
        {"alias", 2, STRING, "", OPT},
        {"is_namespace", 3, BOOL, "", OPT},
    }));
    add_type(make_type("EnumClassInput", {
        {"name", 1, STRING, "", OPT},
        {"underlying_type", 2, STRING, "", OPT},
    }));
    add_type(make_type("ConstexprInput", {{"value", 1, EXPR, EXPR_TYPE, OPT}}));

    // Functions
    auto add_fn = [&](const std::string& n, const std::string& it,
                       const std::string& ot, const std::string& d) {
        *mod.add_functions() = make_fn(n, it, ot, d);
    };

    // Pointer / reference
    add_fn("deref", "DerefInput", "", "Dereference pointer. C++: *ptr");
    add_fn("address_of", "AddressOfInput", "", "Address-of operator. C++: &value");
    add_fn("arrow", "ArrowAccessInput", "", "Arrow member access. C++: ptr->member");
    add_fn("ptr_cast", "PtrCastInput", "", "C++ style cast");

    // Template
    add_fn("template_inst", "TemplateInstInput", "", "Template instantiation");
    add_fn("scope_res", "ScopeResInput", "", "Scope resolution. C++: Scope::member");

    // new / delete
    add_fn("cpp_new", "NewInput", "", "C++ new expression");
    add_fn("cpp_delete", "DeleteInput", "", "C++ delete expression");

    // sizeof / alignof / typeid
    add_fn("cpp_sizeof", "CppSizeofInput", "", "sizeof operator");
    add_fn("cpp_alignof", "CppAlignofInput", "", "alignof operator");
    add_fn("cpp_typeid", "CppTypeidInput", "", "typeid operator");

    // Range-for
    add_fn("range_for", "RangeForInput", "", "Range-based for loop");

    // Initializer list
    add_fn("init_list", "InitListInput", "", "Brace-enclosed initializer list");

    // Structured binding
    add_fn("structured_binding", "StructuredBindingInput", "", "Structured binding (C++17)");

    // Lambda
    add_fn("cpp_lambda", "CppLambdaCaptureInput", "", "C++ lambda with capture");

    // static_assert
    add_fn("static_assert", "StaticAssertInput", "", "Compile-time assertion");

    // Namespace
    add_fn("namespace", "NamespaceInput", "", "Namespace declaration");

    // using
    add_fn("cpp_using", "UsingInput", "", "Using declaration or directive");

    // constexpr
    add_fn("constexpr", "ConstexprInput", "", "Constexpr value");

    // Move / forward
    add_fn("cpp_move", "DerefInput", "", "std::move");
    add_fn("cpp_forward", "DerefInput", "", "std::forward");

    // Special members
    add_fn("destructor", "", "", "Destructor");
    add_fn("copy_constructor", "", "", "Copy constructor marker");
    add_fn("move_constructor", "", "", "Move constructor marker");
    add_fn("copy_assign", "", "", "Copy assignment marker");
    add_fn("move_assign", "", "", "Move assignment marker");

    return mod;
}

}  // namespace ball
