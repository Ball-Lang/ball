// ball::CppCompiler — compiles a ball Program AST to C++ source code.

#include "compiler.h"
#include "ball_emit_runtime_embed.h"
#include "ball_dyn_embed.h"

#include <algorithm>
#include <cmath>
#include <set>

namespace ball {

// ================================================================
// Construction
// ================================================================

CppCompiler::CppCompiler(const ball::v1::Program& program)
    : program_(program) {
    build_lookup_tables();
}

void CppCompiler::build_lookup_tables() {
    for (const auto& mod : program_.modules()) {
        bool all_base = true;
        for (const auto& f : mod.functions()) {
            if (!f.is_base()) { all_base = false; break; }
        }
        if (all_base && mod.functions_size() > 0) {
            base_modules_.insert(mod.name());
        }
        for (const auto& type : mod.types()) {
            types_[type.name()] = type;
            auto colon = type.name().find(':');
            if (colon != std::string::npos)
                types_[type.name().substr(colon + 1)] = type;
        }
        for (const auto& td : mod.type_defs()) {
            if (td.has_descriptor_()) {
                types_[td.name()] = td.descriptor_();
                auto colon = td.name().find(':');
                if (colon != std::string::npos)
                    types_[td.name().substr(colon + 1)] = td.descriptor_();
            }
        }
        for (const auto& func : mod.functions()) {
            std::string key = mod.name() + "." + func.name();
            functions_[key] = &func;
            if (func.has_metadata()) {
                auto params = extract_params(func.metadata());
                if (!params.empty()) param_cache_[key] = std::move(params);
            }
        }
    }
}

std::vector<std::string> CppCompiler::extract_params(const google::protobuf::Struct& metadata) {
    std::vector<std::string> result;
    auto it = metadata.fields().find("params");
    if (it == metadata.fields().end()) return result;
    const auto& val = it->second;
    if (val.kind_case() != google::protobuf::Value::kListValue) return result;
    for (const auto& elem : val.list_value().values()) {
        if (elem.kind_case() != google::protobuf::Value::kStructValue) continue;
        auto name_it = elem.struct_value().fields().find("name");
        if (name_it != elem.struct_value().fields().end() &&
            !name_it->second.string_value().empty()) {
            result.push_back(name_it->second.string_value());
        }
    }
    return result;
}

std::map<std::string, std::string> CppCompiler::read_meta(const ball::v1::FunctionDefinition& func) {
    std::map<std::string, std::string> result;
    if (!func.has_metadata()) return result;
    for (const auto& [k, v] : func.metadata().fields()) {
        if (v.kind_case() == google::protobuf::Value::kStringValue) {
            result[k] = v.string_value();
        } else if (v.kind_case() == google::protobuf::Value::kBoolValue) {
            result[k] = v.bool_value() ? "true" : "false";
        }
    }
    return result;
}

// ================================================================
// Output helpers
// ================================================================

std::string CppCompiler::indent_str() {
    return std::string(indent_ * 4, ' ');
}

void CppCompiler::emit(const std::string& code) {
    out_ << code;
}

void CppCompiler::emit_line(const std::string& code) {
    out_ << indent_str() << code << "\n";
}

void CppCompiler::emit_indent() {
    out_ << indent_str();
}

void CppCompiler::emit_newline() {
    out_ << "\n";
}

// ================================================================
// Type mapping
// ================================================================

std::string CppCompiler::map_type(const std::string& ball_type) {
    if (ball_type.empty() || ball_type == "void") return "void";
    if (ball_type == "int") return "int64_t";
    if (ball_type == "double" || ball_type == "num") return "double";
    if (ball_type == "String") return "std::string";
    if (ball_type == "String?") return "BallDyn";
    if (ball_type == "bool" || ball_type == "bool?") return "bool";
    if (ball_type == "List" || ball_type.find("List<") == 0) return "std::vector<std::any>";
    if (ball_type == "Map" || ball_type.find("Map<") == 0)
        return "BallDyn";
    if (ball_type == "Set" || ball_type.find("Set<") == 0) return "std::vector<std::any>";
    if (ball_type == "dynamic" || ball_type == "Object" || ball_type == "Object?"
        || ball_type == "dynamic?" || ball_type == "Never")
        return "BallDyn";

    // Dart "BallValue" is a typedef for Object?/dynamic
    if (ball_type == "BallValue") return "BallDyn";

    // Nullable type: strip trailing '?' and map the base type
    if (!ball_type.empty() && ball_type.back() == '?') {
        auto base = ball_type.substr(0, ball_type.size() - 1);
        // Record types (Dart `({...})?`) → BallDyn
        if (!base.empty() && base.front() == '(' && base.back() == ')') {
            return "BallDyn";
        }
        return map_type(base);
    }

    // Record types `({...})` → BallDyn
    if (!ball_type.empty() && ball_type.front() == '(' && ball_type.back() == ')') {
        return "BallDyn";
    }

    // FutureOr<T> → BallDyn (sync simulation)
    if (ball_type == "FutureOr" || ball_type.find("FutureOr<") == 0)
        return "BallDyn";

    // Dart exception types → C++ equivalents
    if (ball_type == "Exception") return "std::runtime_error";
    if (ball_type == "Error") return "std::runtime_error";

    // Dart IO types
    if (ball_type == "StringSink" || ball_type == "StringBuffer")
        return "std::ostringstream";
    if (ball_type == "IOSink") return "std::ostream";
    if (ball_type == "Random") return "BallDyn";
    if (ball_type == "Completer" || ball_type.find("Completer<") == 0)
        return "BallDyn";

    // Dart RegExp → std::regex
    if (ball_type == "RegExp") return "std::regex";
    if (ball_type == "Match" || ball_type == "RegExpMatch")
        return "std::smatch";
    if (ball_type == "Duration") return "int64_t";
    if (ball_type == "Iterable" || ball_type.find("Iterable<") == 0)
        return "std::vector<std::any>";
    if (ball_type == "Type") return "std::string";
    if (ball_type == "Iterator" || ball_type.find("Iterator<") == 0)
        return "BallDyn";
    if (ball_type == "MapEntry" || ball_type.find("MapEntry<") == 0)
        return "std::pair<std::string, BallDyn>";
    if (ball_type == "Null") return "BallDyn";
    if (ball_type == "int?" || ball_type == "double?" || ball_type == "num?")
        return "BallDyn";

    // Dart function type syntax: `ReturnType Function(A, B, C)` →
    // `std::function<ReturnType(A, B, C)>`. Split on ` Function(`;
    // everything before is the return type, everything inside the
    // parens is the comma-separated parameter list. Each sub-type is
    // recursively mapped. Falls back to the generic `Function` bucket
    // when the input doesn't match the full syntax.
    {
        auto pos = ball_type.find(" Function(");
        if (pos != std::string::npos) {
            auto rt_src = ball_type.substr(0, pos);
            auto params_start = pos + std::string(" Function(").size();
            auto params_end = ball_type.rfind(')');
            if (params_end != std::string::npos && params_end >= params_start) {
                auto params_src = ball_type.substr(params_start,
                                                   params_end - params_start);
                // Split params on top-level commas (ignore commas inside
                // nested angle brackets / parens).
                std::vector<std::string> parts;
                std::string current;
                int depth = 0;
                for (char c : params_src) {
                    if (c == '<' || c == '(' || c == '[') depth++;
                    else if (c == '>' || c == ')' || c == ']') depth--;
                    if (c == ',' && depth == 0) {
                        parts.push_back(current);
                        current.clear();
                    } else {
                        current.push_back(c);
                    }
                }
                if (!current.empty()) parts.push_back(current);
                std::string out = "std::function<" + map_type(rt_src) + "(";
                for (size_t i = 0; i < parts.size(); i++) {
                    if (i > 0) out += ", ";
                    auto p = parts[i];
                    // Trim leading/trailing whitespace.
                    auto ls = p.find_first_not_of(" \t");
                    auto le = p.find_last_not_of(" \t");
                    if (ls != std::string::npos)
                        p = p.substr(ls, le - ls + 1);
                    out += map_type(p);
                }
                out += ")>";
                return out;
            }
        }
    }
    if (ball_type == "Function") return "std::function<std::any(std::any)>";
    if (ball_type == "Future" || ball_type.find("Future<") == 0) return "BallDyn /* future */";
    // User-defined type
    return sanitize_name(ball_type);
}

std::string CppCompiler::map_return_type(const ball::v1::FunctionDefinition& func) {
    if (func.output_type().empty()) {
        // If the function has a body that is NOT a block (single expression),
        // it implies the function returns a value. Use BallDyn as the return
        // type to avoid 'void function returning a value' errors.
        if (func.has_body() &&
            func.body().expr_case() != ball::v1::Expression::kBlock) {
            return "BallDyn";
        }
        // For block bodies, check if the block has a result expression.
        if (func.has_body() &&
            func.body().expr_case() == ball::v1::Expression::kBlock &&
            func.body().block().has_result()) {
            return "BallDyn";
        }
        return "void";
    }
    return map_type(func.output_type());
}

std::string CppCompiler::sanitize_name(const std::string& name) {
    std::string result = name;
    // Strip module prefix (anything before and including ':')
    auto colon = result.find(':');
    if (colon != std::string::npos) result = result.substr(colon + 1);
    // Replace dots with underscores
    std::replace(result.begin(), result.end(), '.', '_');
    // Replace hyphens with underscores
    std::replace(result.begin(), result.end(), '-', '_');
    // C++ reserved words
    static const std::set<std::string> reserved = {
        "class", "struct", "new", "delete", "template", "typename",
        "namespace", "operator", "default", "register", "explicit",
        "auto", "bool", "break", "case", "catch", "char", "const",
        "continue", "do", "double", "else", "enum", "extern", "false",
        "float", "for", "goto", "if", "inline", "int", "long",
        "mutable", "private", "protected", "public", "return", "short",
        "signed", "sizeof", "static", "switch", "this", "throw",
        "true", "try", "typedef", "union", "unsigned", "using",
        "virtual", "void", "volatile", "while",
    };
    if (reserved.count(result)) result += "_";
    // C stdlib / <cmath> / <cstdlib> names that would collide with
    // user-defined functions in main's global-lookup scope. Suffixed
    // consistently here so both definition and call sites match.
    static const std::set<std::string> stdlib_collisions = {
        "abs", "fabs", "floor", "ceil", "round", "trunc", "sqrt", "pow",
        "exp", "log", "log2", "log10", "sin", "cos", "tan", "atan",
        "atan2", "min", "max", "fmod", "div", "hypot",
        "strcmp", "strlen", "strcpy", "memcpy", "memset", "malloc",
        "free", "exit", "atoi", "atof", "rand", "srand",
        // C stdio macros that conflict as identifiers
        "stdout", "stderr", "stdin",
    };
    if (stdlib_collisions.count(result)) result += "_";
    return result;
}

// ================================================================
// Expression compilation
// ================================================================

std::string CppCompiler::compile_expr(const ball::v1::Expression& expr) {
    switch (expr.expr_case()) {
        case ball::v1::Expression::kCall:
            return compile_call(expr.call());
        case ball::v1::Expression::kLiteral:
            return compile_literal(expr.literal());
        case ball::v1::Expression::kReference:
            return compile_reference(expr.reference());
        case ball::v1::Expression::kFieldAccess:
            return compile_field_access(expr.field_access());
        case ball::v1::Expression::kMessageCreation:
            return compile_message_creation(expr.message_creation());
        case ball::v1::Expression::kBlock:
            return compile_block(expr.block());
        case ball::v1::Expression::kLambda:
            return compile_lambda(expr.lambda());
        default:
            return "/* unknown expr */";
    }
}

std::string CppCompiler::compile_literal(const ball::v1::Literal& lit) {
    switch (lit.value_case()) {
        case ball::v1::Literal::kIntValue:
            return std::to_string(lit.int_value()) + "LL";
        case ball::v1::Literal::kDoubleValue: {
            std::ostringstream oss;
            oss << lit.double_value();
            auto s = oss.str();
            if (s.find('.') == std::string::npos && s.find('e') == std::string::npos)
                s += ".0";
            return s;
        }
        case ball::v1::Literal::kStringValue: {
            // Escape the string for C++
            std::string result = "\"";
            for (char c : lit.string_value()) {
                switch (c) {
                    case '"': result += "\\\""; break;
                    case '\\': result += "\\\\"; break;
                    case '\n': result += "\\n"; break;
                    case '\r': result += "\\r"; break;
                    case '\t': result += "\\t"; break;
                    default: result += c; break;
                }
            }
            result += "\"s";
            return result;
        }
        case ball::v1::Literal::kBoolValue:
            return lit.bool_value() ? "true" : "false";
        case ball::v1::Literal::kListValue: {
            // Homogeneous lists emit a strongly typed std::vector so
            // arithmetic, indexing, etc. don't have to cross a
            // std::any_cast boundary. Detect the common case by
            // inspecting every element literal and picking a single
            // concrete element type when all elements agree. Mixed
            // lists fall back to std::vector<std::any>.
            std::string elem_type = "std::any";
            bool homogeneous = true;
            bool saw_any = false;
            for (const auto& el : lit.list_value().elements()) {
                if (el.expr_case() != ball::v1::Expression::kLiteral) {
                    homogeneous = false;
                    break;
                }
                std::string this_type;
                switch (el.literal().value_case()) {
                    case ball::v1::Literal::kIntValue:    this_type = "int64_t"; break;
                    case ball::v1::Literal::kDoubleValue: this_type = "double"; break;
                    case ball::v1::Literal::kStringValue: this_type = "std::string"; break;
                    case ball::v1::Literal::kBoolValue:   this_type = "bool"; break;
                    default: homogeneous = false; break;
                }
                if (!homogeneous) break;
                if (!saw_any) {
                    elem_type = this_type;
                    saw_any = true;
                } else if (this_type != elem_type) {
                    homogeneous = false;
                    break;
                }
            }
            if (!homogeneous) elem_type = "std::any";

            std::string result = "std::vector<" + elem_type + ">{";
            bool first = true;
            for (const auto& el : lit.list_value().elements()) {
                if (!first) result += ", ";
                if (elem_type == "std::any") {
                    result += "std::any(" + compile_expr(el) + ")";
                } else {
                    result += compile_expr(el);
                }
                first = false;
            }
            result += "}";
            return result;
        }
        case ball::v1::Literal::kBytesValue:
            return "std::vector<uint8_t>{/* bytes */}";
        default:
            return "BallDyn()";
    }
}

std::string CppCompiler::compile_reference(const ball::v1::Reference& ref) {
    // Dart's `this` → C++ `(*this)` (dereference the pointer for value semantics)
    if (ref.name() == "this") return "(*this)";
    // Dart uninitialized sentinel → C++ default-initialized BallDyn
    if (ref.name() == "__no_init__") return "BallDyn()";
    // Dart sentinel object → unique marker
    if (ref.name() == "_sentinel") return "BallDyn()";
    // Dart type objects used as values (e.g., int.tryParse, double.tryParse)
    // → emit as string constants representing the type name.
    if (ref.name() == "int") return "\"int\"s";
    if (ref.name() == "double") return "\"double\"s";
    if (ref.name() == "num") return "\"num\"s";
    if (ref.name() == "String") return "\"String\"s";
    if (ref.name() == "bool") return "\"bool\"s";
    // Dart collection type constructors used as values
    if (ref.name() == "Map") return "\"Map\"s";
    if (ref.name() == "List") return "\"List\"s";
    if (ref.name() == "Set") return "\"Set\"s";
    // If the reference is to a sibling method in the current class,
    // wrap it in a lambda to bind `this`. Bare member function names
    // can't be stored as std::any / passed as values in C++.
    auto sname = sanitize_name(ref.name());
    if (!current_class_methods_.empty() &&
        current_class_methods_.count(sname) > 0) {
        return "[this](auto __arg) mutable { return " + sname + "(__arg); }";
    }
    return sname;
}

std::string CppCompiler::compile_field_access(const ball::v1::FieldAccess& access) {
    auto obj = compile_expr(access.object());
    auto field = access.field();
    // Catch-bound variables hold a `const BallException&`. Their
    // original throw-site field values live in `.fields` (std::map), so
    // rewrite `e.detail` as `e.fields.at("detail")` to read them back.
    if (access.object().expr_case() == ball::v1::Expression::kReference) {
        const auto& ref_name = access.object().reference().name();
        if (catch_bound_vars_.count(ref_name) > 0) {
            return ref_name + ".fields.at(\"" + field + "\")";
        }
        // Dart protobuf oneof enum constants → string literals.
        // The Dart encoder emits `Expression_Expr.call`, `Literal_Value.listValue`,
        // etc. as field-access on a reference. The raw proto names may contain
        // dots (e.g. `structpb.Value_Kind`) which sanitize_name converts to
        // underscores. Check both raw and sanitized forms.
        std::string sref = sanitize_name(ref_name);
        if (sref == "Expression_Expr" || sref == "Literal_Value" ||
            sref == "structpb_Value_Kind" || sref == "ModuleImport_Source" ||
            sref == "Statement_Stmt") {
            return "\"" + field + "\"s";
        }
    }
    // Common virtual properties → C++ equivalents
    if (field == "length") return "static_cast<int64_t>(" + obj + ".size())";
    if (field == "isEmpty") return obj + ".empty()";
    if (field == "isNotEmpty") return "!" + obj + ".empty()";
    if (field == "first") return obj + ".front()";
    if (field == "last") return obj + ".back()";
    if (field == "runtimeType") return "std::string(typeid(" + obj + ").name())";
    // Dart positional record field access: `.$1`, `.$2`, ... Lower to
    // `std::get<0>(...)` / `std::get<1>(...)` since records emit as
    // std::tuple<...> (see compile_message_creation below).
    if (field.size() >= 2 && field[0] == '$') {
        bool all_digits = true;
        for (size_t i = 1; i < field.size(); ++i) {
            if (field[i] < '0' || field[i] > '9') { all_digits = false; break; }
        }
        if (all_digits) {
            int idx = std::stoi(field.substr(1)) - 1;
            if (idx >= 0) {
                return "std::get<" + std::to_string(idx) + ">(" + obj + ")";
            }
        }
    }
    // If the object is a reference to a class method, it was wrapped in a
    // lambda by compile_reference. But in field access context (e.g.,
    // `_foo.bar`), we want to CALL the method, not use it as a value.
    // Detect the lambda pattern and call it with no args.
    if (access.object().expr_case() == ball::v1::Expression::kReference &&
        !current_class_methods_.empty() &&
        current_class_methods_.count(sanitize_name(access.object().reference().name())) > 0) {
        auto method_name = sanitize_name(access.object().reference().name());
        return "BallDyn(" + method_name + "())[\"" + field + "\"s]";
    }
    // Default: bracket-notation field access via BallDyn wrapper.
    // Wrapping in BallDyn ensures the access works on std::any values
    // (from map lookups) as well as BallDyn and std::map types.
    // The BallDyn constructor accepts std::any, so this is safe for all types.
    return "BallDyn(" + obj + ")[\"" + field + "\"s]";
}

std::string CppCompiler::compile_message_creation(const ball::v1::MessageCreation& msg) {
    // Emit as an aggregate initializer or a map
    if (msg.type_name().empty() || msg.type_name().find("Msg") == 0) {
        // Anonymous message → std::unordered_map
        std::string result = "std::unordered_map<std::string, std::any>{";
        bool first = true;
        for (const auto& f : msg.fields()) {
            if (!first) result += ", ";
            result += "{\"" + f.name() + "\", std::any(" + compile_expr(f.value()) + ")}";
            first = false;
        }
        result += "}";
        return result;
    }

    // Check if the type name refers to a known function rather than a type.
    // The Dart encoder emits method calls on `this` as messageCreations
    // with typeName = "module:functionName" and argN fields. When the
    // typeName matches a function in our lookup, emit a function call
    // instead of a struct construction.
    {
        bool is_func = false;
        std::string tn = msg.type_name();

        // Parse "module:funcName" format
        auto colon = tn.find(':');
        std::string mod_part, func_part;
        if (colon != std::string::npos) {
            mod_part = tn.substr(0, colon);
            func_part = tn.substr(colon + 1);
        } else {
            func_part = tn;
        }

        // Direct lookup: "module.module:funcName"
        std::string entry_mod = mod_part.empty() ? program_.entry_module() : mod_part;
        if (functions_.count(entry_mod + "." + tn) > 0) {
            is_func = true;
        }
        // Try "module.funcName" (without module prefix)
        if (!is_func && functions_.count(entry_mod + "." + func_part) > 0) {
            is_func = true;
        }
        // Try matching by method basename: if the func_part is "_foo",
        // find any function like "main:ClassName._foo" in the module.
        // This handles the case where the encoder strips the class name.
        if (!is_func) {
            for (const auto& [key, fptr] : functions_) {
                // key format: "module.module:Class.method"
                // Look for keys where the method basename matches func_part
                auto dot = key.rfind('.');
                if (dot != std::string::npos) {
                    std::string basename = key.substr(dot + 1);
                    if (basename == func_part) {
                        // Verify it's in the same module
                        auto key_mod = key.substr(0, key.find('.'));
                        if (key_mod == entry_mod) {
                            is_func = true;
                            break;
                        }
                    }
                }
            }
        }

        if (is_func) {
            // Emit as function call with positional arguments
            std::string func_name = sanitize_name(msg.type_name());
            std::string result = func_name + "(";
            bool first = true;
            for (const auto& f : msg.fields()) {
                if (!first) result += ", ";
                result += compile_expr(f.value());
                first = false;
            }
            result += ")";
            return result;
        }
    }

    // Named type → aggregate/constructor
    // Try map_type first to map Dart types (RegExp, Duration, etc.) to C++ equivalents.
    // If map_type returns a stdlib type (contains ::), use it; otherwise sanitize.
    std::string type;
    {
        auto mapped = map_type(msg.type_name());
        // Also try with colon-stripped name
        auto colon = msg.type_name().find(':');
        auto bare = colon != std::string::npos ? msg.type_name().substr(colon + 1) : msg.type_name();
        auto bare_mapped = map_type(bare);
        if (mapped == "BallDyn" || bare_mapped == "BallDyn") {
            type = "BallDyn";
        } else if (mapped.find("::") != std::string::npos) {
            type = mapped;
        } else if (bare_mapped.find("::") != std::string::npos) {
            type = bare_mapped;
        } else {
            type = sanitize_name(msg.type_name());
        }
    }

    // If all fields are positional (argN), emit a constructor call
    // instead of designated initializers (which require matching field names).
    bool all_positional = !msg.fields().empty();
    for (const auto& f : msg.fields()) {
        auto fn = f.name();
        // Check if field name is "arg0", "arg1", etc.
        if (fn.size() < 4 || fn.substr(0, 3) != "arg") {
            all_positional = false;
            break;
        }
        bool all_digits = true;
        for (size_t i = 3; i < fn.size(); i++) {
            if (fn[i] < '0' || fn[i] > '9') { all_digits = false; break; }
        }
        if (!all_digits) { all_positional = false; break; }
    }

    if (all_positional) {
        // Emit as constructor call with positional args
        std::string result = type + "(";
        bool first = true;
        for (const auto& f : msg.fields()) {
            if (!first) result += ", ";
            result += compile_expr(f.value());
            first = false;
        }
        result += ")";
        return result;
    }

    // Check if there are any argN fields mixed with named fields.
    // If so, look up the constructor to resolve argN to actual param names.
    bool has_arg_fields = false;
    for (const auto& f : msg.fields()) {
        if (f.name().size() >= 4 && f.name().substr(0, 3) == "arg") {
            has_arg_fields = true;
            break;
        }
    }

    if (has_arg_fields) {
        // Try to find constructor parameter names
        auto colon = msg.type_name().find(':');
        auto bare = colon != std::string::npos ? msg.type_name().substr(colon + 1) : msg.type_name();
        std::string ctor_key = program_.entry_module() + "." + msg.type_name() + ".new";
        auto it = functions_.find(ctor_key);
        if (it == functions_.end()) {
            // Try with module prefix in the function name
            ctor_key = program_.entry_module() + "." +
                       program_.entry_module() + ":" + bare + ".new";
            it = functions_.find(ctor_key);
        }
        std::vector<std::string> ctor_params;
        if (it != functions_.end() && it->second->has_metadata()) {
            ctor_params = extract_params(it->second->metadata());
        }

        // Build a mapping of actual field values, resolving argN to param names
        std::string result = type + "{";
        bool first = true;
        for (const auto& f : msg.fields()) {
            if (!first) result += ", ";
            std::string field_name = f.name();
            // Resolve argN to constructor parameter name
            if (field_name.size() >= 4 && field_name.substr(0, 3) == "arg") {
                try {
                    int idx = std::stoi(field_name.substr(3));
                    if (idx >= 0 && idx < static_cast<int>(ctor_params.size())) {
                        field_name = ctor_params[idx];
                    }
                } catch (...) {}
            }
            result += "." + sanitize_name(field_name) + " = " + compile_expr(f.value());
            first = false;
        }
        result += "}";
        return result;
    }

    // Named fields → designated initializers
    std::string result = type + "{";
    bool first = true;
    for (const auto& f : msg.fields()) {
        if (!first) result += ", ";
        result += "." + sanitize_name(f.name()) + " = " + compile_expr(f.value());
        first = false;
    }
    result += "}";
    return result;
}

std::string CppCompiler::compile_block(const ball::v1::Block& block) {
    // Blocks as immediately-invoked lambdas in expression context
    std::string result = "[&]() {\n";
    indent_++;
    for (const auto& stmt : block.statements()) {
        const auto& s = stmt;
        if (s.has_let()) {
            result += indent_str() + "auto " + sanitize_name(s.let().name()) +
                      " = " + compile_expr(s.let().value()) + ";\n";
        } else if (s.has_expression()) {
            result += indent_str() + compile_expr(s.expression()) + ";\n";
        }
    }
    if (block.has_result()) {
        result += indent_str() + "return " + compile_expr(block.result()) + ";\n";
    }
    indent_--;
    result += indent_str() + "}()";
    return result;
}

std::string CppCompiler::compile_lambda(const ball::v1::FunctionDefinition& func) {
    // Capture by value by default. Lambdas that escape the enclosing
    // function (returned as std::function, stored in a variable, etc.)
    // need to own their captured state — `[&]` would dangle when the
    // outer stack frame tears down. Lambdas used only synchronously
    // (inside an immediately-invoked IIFE or a loop body) work fine
    // under either capture mode, so `[=]` is the safe default.
    std::string result = "[=](";
    // Parameters
    if (func.has_metadata()) {
        auto params = extract_params(func.metadata());
        bool first = true;
        for (const auto& p : params) {
            if (!first) result += ", ";
            result += "auto " + sanitize_name(p);
            first = false;
        }
    } else if (!func.input_type().empty()) {
        result += map_type(func.input_type()) + " input";
    }
    result += ") mutable";
    if (!func.output_type().empty() && func.output_type() != "void") {
        result += " -> " + map_type(func.output_type());
    }
    result += " {\n";
    indent_++;
    if (func.has_body()) {
        if (func.body().expr_case() == ball::v1::Expression::kBlock) {
            for (const auto& stmt : func.body().block().statements()) {
                result += indent_str();
                if (stmt.has_let()) {
                    result += "auto " + sanitize_name(stmt.let().name()) +
                              " = " + compile_expr(stmt.let().value()) + ";\n";
                } else if (stmt.has_expression()) {
                    result += compile_expr(stmt.expression()) + ";\n";
                }
            }
            if (func.body().block().has_result()) {
                result += indent_str() + "return " + compile_expr(func.body().block().result()) + ";\n";
            }
        } else {
            result += indent_str() + "return " + compile_expr(func.body()) + ";\n";
        }
    }
    indent_--;
    result += indent_str() + "}";
    return result;
}

// ================================================================
// Function call compilation
// ================================================================

const ball::v1::Expression* CppCompiler::get_message_field_expr(
    const ball::v1::FunctionCall& call, const std::string& field_name) {
    if (!call.has_input() ||
        call.input().expr_case() != ball::v1::Expression::kMessageCreation)
        return nullptr;
    for (const auto& f : call.input().message_creation().fields()) {
        if (f.name() == field_name) return &f.value();
    }
    return nullptr;
}

std::string CppCompiler::get_message_field(const ball::v1::FunctionCall& call,
                                            const std::string& field_name) {
    auto* expr = get_message_field_expr(call, field_name);
    return expr ? compile_expr(*expr) : "";
}

std::string CppCompiler::get_string_field(const ball::v1::FunctionCall& call,
                                           const std::string& field_name) {
    auto* expr = get_message_field_expr(call, field_name);
    if (expr && expr->expr_case() == ball::v1::Expression::kLiteral &&
        expr->literal().value_case() == ball::v1::Literal::kStringValue) {
        return expr->literal().string_value();
    }
    // Fall back to compiling the expression
    return expr ? compile_expr(*expr) : "";
}

std::string CppCompiler::compile_binary_op(const std::string& op,
                                            const ball::v1::FunctionCall& call) {
    auto left = field_expr(call, "left");
    auto right = field_expr(call, "right");
    return "(" + left.str() + " " + op + " " + right.str() + ")";
}

std::string CppCompiler::compile_unary_op(const std::string& op,
                                           const ball::v1::FunctionCall& call) {
    auto val = field_expr(call, "value");
    return CppExpr("(" + op + val.str() + ")").str();
}

std::string CppCompiler::compile_call(const ball::v1::FunctionCall& call) {
    std::string mod = call.module();
    const auto& fn = call.function();

    // std / dart_std operations → native C++. Empty module is also
    // treated as std when the function name is a known std operation
    // (the encoder omits `module: 'std'` for core wrappers like
    // `labeled`, `paren`, `switch_expr`).
    static const std::set<std::string> std_builtins = {
        "labeled", "paren", "switch_expr", "set_create", "map_create",
        "yield_each",
    };
    if (mod == "std" || mod == "dart_std" ||
        (mod.empty() && std_builtins.count(fn) > 0)) {
        return compile_std_call(fn, call);
    }

    // std_memory → direct memory calls
    if (mod == "std_memory") {
        std::string result = "_ball_" + fn + "(";
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            bool first = true;
            for (const auto& f : call.input().message_creation().fields()) {
                if (!first) result += ", ";
                result += compile_expr(f.value());
                first = false;
            }
        }
        result += ")";
        return result;
    }

    // std_collections → STL operations
    if (mod == "std_collections") {
        return compile_collections_call(fn, call);
    }

    // std_io → iostream/stdlib operations
    if (mod == "std_io") {
        return compile_io_call(fn, call);
    }

    // cpp_std → C++ specific operations
    if (mod == "cpp_std") {
        return compile_cpp_std_call(fn, call);
    }

    // std_convert → serialization
    if (mod == "std_convert") {
        return compile_convert_call(fn, call);
    }

    // std_fs → file I/O
    if (mod == "std_fs") {
        return compile_fs_call(fn, call);
    }

    // std_time → date/time
    if (mod == "std_time") {
        return compile_time_call(fn, call);
    }

    // User-defined function call
    // std_concurrency → std::thread / std::mutex / std::atomic
    if (mod == "std_concurrency") {
        return compile_concurrency_call(fn, call);
    }

    // Method-style calls: empty module, input has a "self" field.
    // The Dart encoder emits `list.add(x)` as a call with
    // `{self: list, arg0: x}`. Dispatch to compile_method_call which
    // maps these to C++ STL equivalents.
    if (mod.empty() && call.has_input() &&
        call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
        bool has_self = false;
        for (const auto& f : call.input().message_creation().fields()) {
            if (f.name() == "self") { has_self = true; break; }
        }
        if (has_self) {
            return compile_method_call(fn, call);
        }
    }

    // User-defined function call
    std::string func_name = sanitize_name(fn);
    std::string result = func_name + "(";
    if (call.has_input()) {
        if (call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            bool first = true;
            for (const auto& f : call.input().message_creation().fields()) {
                if (!first) result += ", ";
                result += compile_expr(f.value());
                first = false;
            }
        } else {
            result += compile_expr(call.input());
        }
    }
    result += ")";
    return result;
}

std::string CppCompiler::compile_std_call(const std::string& fn,
                                           const ball::v1::FunctionCall& call) {
    // ── Arithmetic ──
    if (fn == "add") return compile_binary_op("+", call);
    if (fn == "subtract") return compile_binary_op("-", call);
    if (fn == "multiply") return compile_binary_op("*", call);
    if (fn == "divide") return compile_binary_op("/", call);
    if (fn == "divide_double") {
        return "(static_cast<double>(" + get_message_field(call, "left") +
               ") / " + get_message_field(call, "right") + ")";
    }
    if (fn == "modulo") {
        auto l = get_message_field(call, "left");
        auto r = get_message_field(call, "right");
        return "[&](auto _a, auto _b){ auto _r = _a % _b; return _r < 0 ? _r + (_b < 0 ? -_b : _b) : _r; }(" + l + ", " + r + ")";
    }
    if (fn == "negate") return compile_unary_op("-", call);

    // ── Comparison ──
    // Special case: null checks. `x == null` / `x != null` cannot use
    // plain C++ `==`/`!=` on std::any (which has no comparison operators).
    // Detect when one side is a null literal and emit `.has_value()`.
    if (fn == "equals" || fn == "not_equals") {
        auto* left_expr = get_message_field_expr(call, "left");
        auto* right_expr = get_message_field_expr(call, "right");
        auto is_null = [](const ball::v1::Expression* e) -> bool {
            if (!e) return false;
            // Null reference (name "null" or empty reference)
            if (e->expr_case() == ball::v1::Expression::kReference &&
                (e->reference().name() == "null" || e->reference().name().empty()))
                return true;
            // Null literal (default/unset literal value)
            if (e->expr_case() == ball::v1::Expression::kLiteral &&
                e->literal().value_case() == ball::v1::Literal::VALUE_NOT_SET)
                return true;
            return false;
        };
        bool left_null = is_null(left_expr);
        bool right_null = is_null(right_expr);
        if (right_null) {
            auto left = get_message_field(call, "left");
            if (fn == "equals") return "!BallDyn(" + left + ").has_value()";
            else return "BallDyn(" + left + ").has_value()";
        }
        if (left_null) {
            auto right = get_message_field(call, "right");
            if (fn == "equals") return "!BallDyn(" + right + ").has_value()";
            else return "BallDyn(" + right + ").has_value()";
        }
        return compile_binary_op(fn == "equals" ? "==" : "!=", call);
    }
    if (fn == "less_than") return compile_binary_op("<", call);
    if (fn == "greater_than") return compile_binary_op(">", call);
    if (fn == "lte") return compile_binary_op("<=", call);
    if (fn == "gte") return compile_binary_op(">=", call);

    // ── Logical ──
    if (fn == "and") return compile_binary_op("&&", call);
    if (fn == "or") return compile_binary_op("||", call);
    if (fn == "not") return compile_unary_op("!", call);

    // ── Bitwise ──
    if (fn == "bitwise_and") return compile_binary_op("&", call);
    if (fn == "bitwise_or") return compile_binary_op("|", call);
    if (fn == "bitwise_xor") return compile_binary_op("^", call);
    if (fn == "bitwise_not") return compile_unary_op("~", call);
    if (fn == "left_shift") return compile_binary_op("<<", call);
    if (fn == "right_shift") return compile_binary_op(">>", call);

    // ── Inc/Dec ──
    if (fn == "pre_increment") return "(++" + get_message_field(call, "value") + ")";
    if (fn == "post_increment") return "(" + get_message_field(call, "value") + "++)";
    if (fn == "pre_decrement") return "(--" + get_message_field(call, "value") + ")";
    if (fn == "post_decrement") return "(" + get_message_field(call, "value") + "--)";

    // ── Assignment ──
    if (fn == "assign") {
        auto* target_expr = get_message_field_expr(call, "target");
        auto target = get_message_field(call, "target");
        auto val = get_message_field(call, "value");
        auto* op_expr = get_message_field_expr(call, "op");
        std::string op = "=";
        if (op_expr && op_expr->expr_case() == ball::v1::Expression::kLiteral)
            op = op_expr->literal().string_value();
        if (op == "~/=") {
            return "(" + target + " = static_cast<int64_t>(" + target + " / " + val + "))";
        }
        // When the target is a field access (obj["field"]) or index (obj[idx]),
        // use ball_set() free function instead of plain assignment, because
        // BallDyn's operator[] returns by value. ball_set works for both
        // BallDyn and std::map<std::string, std::any>.
        if (op == "=" && target_expr) {
            if (target_expr->expr_case() == ball::v1::Expression::kFieldAccess) {
                auto obj = compile_expr(target_expr->field_access().object());
                auto field = target_expr->field_access().field();
                return "ball_set(" + obj + ", \"" + field + "\"s, " + val + ")";
            }
            // Index expression: std.index(target, index) in the target
            if (target_expr->expr_case() == ball::v1::Expression::kCall &&
                (target_expr->call().module() == "std" ||
                 target_expr->call().module().empty()) &&
                target_expr->call().function() == "index") {
                auto tgt = get_message_field(target_expr->call(), "target");
                auto idx = get_message_field(target_expr->call(), "index");
                return "ball_set(" + tgt + ", " + idx + ", " + val + ")";
            }
        }
        return "(" + target + " " + op + " " + val + ")";
    }

    // ── Print ──
    if (fn == "print") {
        auto msg = get_message_field(call, "message");
        if (msg.empty()) msg = call.has_input() ? compile_expr(call.input()) : "\"\"";
        // Wrap in ball_to_string for Dart-compatible formatting (e.g.
        // doubles print "42.0" not "42", bools print "true" not "1").
        return "std::cout << ball_to_string(" + msg + ") << std::endl";
    }

    // ── String operations ──
    if (fn == "concat" || fn == "string_concat") return compile_binary_op("+", call);
    if (fn == "to_string" || fn == "int_to_string" || fn == "double_to_string") {
        return "ball_to_string(" + get_message_field(call, "value") + ")";
    }
    if (fn == "to_int") {
        auto v = get_message_field(call, "value");
        return "static_cast<int64_t>(" + v + ")";
    }
    if (fn == "to_double") {
        auto v = get_message_field(call, "value");
        return "static_cast<double>(" + v + ")";
    }
    if (fn == "string_to_int") {
        // Wrap in an IIFE that converts std::invalid_argument /
        // std::out_of_range into a `BallException("FormatException", …)`
        // so typed catches like `on FormatException catch (e)` dispatch
        // correctly — matches Dart runtime semantics.
        auto v = get_message_field(call, "value");
        return "[](const std::string& s) -> int64_t { try { return std::stoll(s); } "
               "catch (const std::exception&) { throw BallException(\"FormatException\"s, "
               "\"FormatException: \"s + s); } }(" + v + ")";
    }
    if (fn == "string_to_double") {
        auto v = get_message_field(call, "value");
        return "[](const std::string& s) -> double { try { return std::stod(s); } "
               "catch (const std::exception&) { throw BallException(\"FormatException\"s, "
               "\"FormatException: \"s + s); } }(" + v + ")";
    }
    if (fn == "string_length") return "static_cast<int64_t>(" + get_message_field(call, "value") + ".size())";
    if (fn == "string_is_empty") return get_message_field(call, "value") + ".empty()";
    if (fn == "string_contains") return "(" + get_message_field(call, "left") + ".find(" +
                                          get_message_field(call, "right") + ") != std::string::npos)";
    if (fn == "string_substring") {
        auto v = get_message_field(call, "value");
        auto s = get_message_field(call, "start");
        auto e = get_message_field(call, "end");
        if (e.empty()) return v + ".substr(" + s + ")";
        return v + ".substr(" + s + ", " + e + " - " + s + ")";
    }
    if (fn == "string_to_upper") {
        auto v = get_message_field(call, "value");
        return "[](std::string s){std::transform(s.begin(),s.end(),s.begin(),::toupper);return s;}(" + v + ")";
    }
    if (fn == "string_to_lower") {
        auto v = get_message_field(call, "value");
        return "[](std::string s){std::transform(s.begin(),s.end(),s.begin(),::tolower);return s;}(" + v + ")";
    }
    if (fn == "string_trim") {
        auto v = get_message_field(call, "value");
        return "[](const std::string& s){"
               "auto a=s.find_first_not_of(\" \\t\\n\\r\"),b=s.find_last_not_of(\" \\t\\n\\r\");"
               "return a==std::string::npos?std::string():s.substr(a,b-a+1);}(" + v + ")";
    }
    if (fn == "string_split") {
        auto str = get_message_field(call, "value");
        auto delim = get_message_field(call, "separator");
        return "[](const std::string& s,const std::string& d){"
               "if(d.empty()){std::vector<std::string> r;"
               "for(char c:s)r.push_back(std::string(1,c));return r;}"
               "std::vector<std::string> r;size_t p=0,f;"
               "while((f=s.find(d,p))!=std::string::npos){"
               "r.push_back(s.substr(p,f-p));p=f+d.size();}"
               "r.push_back(s.substr(p));return r;"
               "}(" + str + "," + delim + ")";
    }
    if (fn == "string_replace") {
        auto str = get_message_field(call, "value");
        auto from = get_message_field(call, "from");
        auto to = get_message_field(call, "to");
        return "[](std::string s,const std::string& f,const std::string& t){"
               "auto p=s.find(f);if(p!=std::string::npos)s.replace(p,f.size(),t);return s;"
               "}(" + str + "," + from + "," + to + ")";
    }
    if (fn == "string_replace_all") {
        auto str = get_message_field(call, "value");
        auto from = get_message_field(call, "from");
        auto to = get_message_field(call, "to");
        return "[](std::string s,const std::string& f,const std::string& t){"
               "if(f.empty()){std::string o;o.reserve(s.size()*(t.size()+1)+t.size());"
               "o+=t;for(char c:s){o.push_back(c);o+=t;}return o;}"
               "size_t p=0;"
               "while((p=s.find(f,p))!=std::string::npos){"
               "s.replace(p,f.size(),t);p+=t.size();}return s;"
               "}(" + str + "," + from + "," + to + ")";
    }
    // ── Regex ──
    if (fn == "regex_match") {
        auto input = get_message_field(call, "left");
        auto pat = get_message_field(call, "right");
        return "std::regex_search(" + input + ", std::regex(" + pat + "))";
    }
    if (fn == "regex_find") {
        auto input = get_message_field(call, "left");
        auto pat = get_message_field(call, "right");
        return "[](const std::string& s,const std::string& p){"
               "std::smatch m;if(std::regex_search(s,m,std::regex(p)))return m[0].str();"
               "return std::string();}(" + input + "," + pat + ")";
    }
    if (fn == "regex_find_all") {
        auto input = get_message_field(call, "left");
        auto pat = get_message_field(call, "right");
        return "[](const std::string& s,const std::string& p){"
               "std::vector<std::string> r;std::regex re(p);"
               "auto it=std::sregex_iterator(s.begin(),s.end(),re);"
               "for(;it!=std::sregex_iterator();++it)r.push_back((*it)[0].str());"
               "return r;}(" + input + "," + pat + ")";
    }
    if (fn == "regex_replace") {
        auto str = get_message_field(call, "value");
        auto from = get_message_field(call, "from");
        auto to = get_message_field(call, "to");
        return "std::regex_replace(" + str + ",std::regex(" + from + ")," + to + ",std::regex_constants::format_first_only)";
    }
    if (fn == "regex_replace_all") {
        auto str = get_message_field(call, "value");
        auto from = get_message_field(call, "from");
        auto to = get_message_field(call, "to");
        return "std::regex_replace(" + str + ",std::regex(" + from + ")," + to + ")";
    }
    if (fn == "string_interpolation") {
        auto* parts_expr = get_message_field_expr(call, "parts");
        if (parts_expr && parts_expr->expr_case() == ball::v1::Expression::kLiteral &&
            parts_expr->literal().value_case() == ball::v1::Literal::kListValue) {
            std::string result = "([&](){std::ostringstream _ss;";
            for (const auto& part : parts_expr->literal().list_value().elements()) {
                result += "_ss<<" + compile_expr(part) + ";";
            }
            result += "return _ss.str();}())";
            return result;
        }
        auto v = get_message_field(call, "value");
        return v.empty() ? "std::string()" : "std::to_string(" + v + ")";
    }

    // ── Control flow ──
    if (fn == "if") {
        auto cond = get_message_field(call, "condition");
        auto then = get_message_field(call, "then");
        auto else_val = get_message_field(call, "else");
        if (!else_val.empty()) return "(BallDyn(" + cond + " ? BallDyn(" + then + ") : BallDyn(" + else_val + ")))";
        return "[&](){if (" + cond + ") {return BallDyn(" + then + ");} return BallDyn();}()";
    }
    if (fn == "for") {
        return "[&](){\n" + indent_str() + "    // for loop\n" + indent_str() + "}()";
    }
    if (fn == "while") {
        return "[&](){\n" + indent_str() + "    // while loop\n" + indent_str() + "}()";
    }
    if (fn == "return") {
        auto val = get_message_field(call, "value");
        // This will be handled as a statement when used in statement context
        return "/* return */ " + val;
    }
    if (fn == "break") {
        auto label = get_string_field(call, "label");
        if (!label.empty()) return "goto __ball_break_" + label;
        return "break";
    }
    if (fn == "continue") {
        auto label = get_string_field(call, "label");
        if (!label.empty()) return "goto __ball_continue_" + label;
        return "continue";
    }
    if (fn == "goto") {
        auto label = get_string_field(call, "label");
        return "goto " + label;
    }
    if (fn == "label") {
        auto name = get_string_field(call, "name");
        auto body = get_message_field(call, "body");
        return name + ": " + body;
    }

    // ── Index ──
    if (fn == "index") {
        auto* target_expr = get_message_field_expr(call, "target");
        auto target = get_message_field(call, "target");
        auto idx = get_message_field(call, "index");
        // If the target is a class method reference, call it first (it's a getter).
        if (target_expr &&
            target_expr->expr_case() == ball::v1::Expression::kReference &&
            !current_class_methods_.empty() &&
            current_class_methods_.count(sanitize_name(target_expr->reference().name())) > 0) {
            target = sanitize_name(target_expr->reference().name()) + "()";
        }
        return "BallDyn(" + target + ")[" + idx + "]";
    }

    // ── Math ──
    if (fn == "math_abs") return "std::abs(" + get_message_field(call, "value") + ")";
    if (fn == "math_floor") return "static_cast<int64_t>(std::floor(" + get_message_field(call, "value") + "))";
    if (fn == "math_ceil") return "static_cast<int64_t>(std::ceil(" + get_message_field(call, "value") + "))";
    if (fn == "math_round") return "static_cast<int64_t>(std::round(" + get_message_field(call, "value") + "))";
    if (fn == "math_sqrt") return "std::sqrt(" + get_message_field(call, "value") + ")";
    if (fn == "math_pow") return "std::pow(" + get_message_field(call, "left") + ", " + get_message_field(call, "right") + ")";
    if (fn == "math_min") return "std::min(" + get_message_field(call, "left") + ", " + get_message_field(call, "right") + ")";
    if (fn == "math_max") return "std::max(" + get_message_field(call, "left") + ", " + get_message_field(call, "right") + ")";
    if (fn == "math_pi") return "3.141592653589793";
    if (fn == "math_e") return "2.718281828459045";
    if (fn == "math_log") return "std::log(" + get_message_field(call, "value") + ")";
    if (fn == "math_sin") return "std::sin(" + get_message_field(call, "value") + ")";
    if (fn == "math_cos") return "std::cos(" + get_message_field(call, "value") + ")";

    // ── Type system ──
    if (fn == "is" || fn == "is_not") {
        auto val = get_message_field(call, "value");
        // Use get_string_field to extract the raw type name string,
        // not the compiled C++ literal (which would be e.g. "Map"s).
        std::string tn = get_string_field(call, "type");
        auto lt = tn.find('<'); if (lt != std::string::npos) tn = tn.substr(0, lt);
        if (!tn.empty() && tn.back() == '?') tn.pop_back();
        auto col = tn.find(':'); if (col != std::string::npos) tn = tn.substr(col + 1);
        std::string ck;
        if (tn == "Map" || tn == "HashMap") ck = "ball_is_map(" + val + ")";
        else if (tn == "List" || tn == "Iterable") ck = "ball_is_list(" + val + ")";
        else if (tn == "String") ck = "ball_is_string(" + val + ")";
        else if (tn == "int") ck = "ball_is_int(" + val + ")";
        else if (tn == "double" || tn == "num") ck = "(ball_is_int(" + val + ") || ball_is_double(" + val + "))";
        else if (tn == "bool") ck = "ball_is_bool(" + val + ")";
        else if (tn == "Function") ck = "ball_is_function(" + val + ")";
        else if (tn == "_FlowSignal" || tn == "FlowSignal") ck = "ball_is_flow_signal(" + val + ")";
        else ck = "ball_object_type_matches(" + val + ", \"" + tn + "\"s)";
        return fn == "is" ? ck : ("!(" + ck + ")");
    }
    if (fn == "as") return get_message_field(call, "value");
    if (fn == "null_coalesce") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "BallDyn(" + left + " ? BallDyn(" + left + ") : BallDyn(" + right + "))";
    }

    // ── Cascade / spread ──
    if (fn == "cascade") return get_message_field(call, "target");
    if (fn == "spread" || fn == "null_spread") return get_message_field(call, "value");

    // ── Exception ──
    if (fn == "rethrow") {
        // `throw;` with no operand re-raises the currently handled
        // exception. Valid only inside a catch block; outside one it
        // calls std::terminate — matching the Dart engine's runtime
        // "rethrow outside of catch" error path.
        return "throw";
    }
    if (fn == "throw") {
        // Best-effort static type extraction: if the throw value is a
        // messageCreation literal carrying a `__type` string field,
        // promote it to the BallException type_name so typed catches
        // can dispatch. Other string-literal fields populate the
        // exception's `fields` map, so catch-side `e.detail` reads the
        // original payload.
        auto* val_expr = get_message_field_expr(call, "value");
        std::string type_name = "Exception";
        bool is_msg = val_expr &&
                      val_expr->expr_case() == ball::v1::Expression::kMessageCreation;
        if (is_msg) {
            std::string fields_init;
            for (const auto& f : val_expr->message_creation().fields()) {
                if (f.value().expr_case() == ball::v1::Expression::kLiteral &&
                    f.value().literal().value_case() ==
                        ball::v1::Literal::kStringValue) {
                    const auto& val = f.value().literal().string_value();
                    if (f.name() == "__type") {
                        type_name = val;
                    } else {
                        if (!fields_init.empty()) fields_init += ", ";
                        fields_init += "{\"" + f.name() + "\"s, \"" + val + "\"s}";
                    }
                }
            }
            return "throw BallException(\"" + type_name + "\"s, \"" +
                   type_name + "\"s, std::map<std::string, std::string>{" +
                   fields_init + "})";
        }
        // Non-message value — stringify and pass through as the message
        // with an empty fields map.
        std::string message_expr = get_message_field(call, "value");
        return "throw BallException(\"Exception\"s, " + message_expr + ")";
    }
    if (fn == "assert") {
        auto cond = get_message_field(call, "condition");
        return "assert(" + cond + ")";
    }
    if (fn == "paren") {
        // Wrapper emitted by the encoder to mark precedence-sensitive
        // parenthesized sub-expressions (e.g. around ternary/assign).
        // At the C++ level parens are always fine, so just re-wrap.
        return "(" + get_message_field(call, "value") + ")";
    }

    // ── Invoke ──
    if (fn == "invoke") {
        auto callee = get_message_field(call, "callee");
        // Collect args
        std::string args_str;
        bool first = true;
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == "callee" || f.name() == "__type__") continue;
                if (!first) args_str += ", ";
                args_str += compile_expr(f.value());
                first = false;
            }
        }
        return callee + "(" + args_str + ")";
    }

    // ── Async (no-op wrappers) ──
    if (fn == "await" || fn == "yield" || fn == "yield_each") {
        return get_message_field(call, "value");
    }

    // ── Record literal ──
    // Dart `(a, b)` (positional) / `(x: v)` (named) encodes as
    // std.record. Lower positional records to std::make_tuple(...) so
    // they pair up with the `$1`/`$2` field-access rewrite above.
    // Named / mixed records currently fall back to an
    // std::unordered_map<std::string, std::any> — a Phase 3 follow-up
    // could emit a typed struct instead.
    if (fn == "record") {
        std::vector<std::string> positional;
        std::vector<std::pair<std::string, std::string>> named;
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            for (const auto& f : call.input().message_creation().fields()) {
                const auto& n = f.name();
                if (n == "__type_args__") continue;
                // Positional fields are named `$0`/`$1`/... or `arg0`/...
                bool is_positional = false;
                if (!n.empty() && (n[0] == '$' || (n.size() > 3 &&
                    n.substr(0, 3) == "arg"))) {
                    size_t start = n[0] == '$' ? 1 : 3;
                    if (start < n.size()) {
                        is_positional = true;
                        for (size_t i = start; i < n.size(); ++i) {
                            if (n[i] < '0' || n[i] > '9') { is_positional = false; break; }
                        }
                    }
                }
                if (is_positional) {
                    positional.push_back(compile_expr(f.value()));
                } else {
                    named.emplace_back(n, compile_expr(f.value()));
                }
            }
        }
        if (named.empty()) {
            std::string out = "std::make_tuple(";
            for (size_t i = 0; i < positional.size(); ++i) {
                if (i) out += ", ";
                out += positional[i];
            }
            out += ")";
            return out;
        }
        // Named (or mixed) record → unordered_map<string, any>.
        std::string out = "std::unordered_map<std::string, std::any>{";
        bool first_e = true;
        for (size_t i = 0; i < positional.size(); ++i) {
            if (!first_e) out += ", ";
            out += "{\"" + std::to_string(i) + "\", std::any(" + positional[i] + ")}";
            first_e = false;
        }
        for (const auto& [k, v] : named) {
            if (!first_e) out += ", ";
            out += "{\"" + k + "\", std::any(" + v + ")}";
            first_e = false;
        }
        out += "}";
        return out;
    }

    // ── Try/catch ──
    if (fn == "try") {
        return "[&](){\n" + indent_str() + "    try {\n" +
               indent_str() + "        return " + get_message_field(call, "body") + ";\n" +
               indent_str() + "    } catch (const std::exception& e) {\n" +
               indent_str() + "        return decltype(" + get_message_field(call, "body") + "){};\n" +
               indent_str() + "    }\n" + indent_str() + "}()";
    }

    // ── Null-aware index ──
    // `x?[key]` — index only if x has a value. Returns BallDyn for chaining.
    if (fn == "null_aware_index") {
        auto target = get_message_field(call, "target");
        auto index = get_message_field(call, "index");
        if (!index.empty()) {
            return "BallDyn(" + target + ".has_value() ? BallDyn(" + target + ")[" + index + "] : BallDyn())";
        }
        return target;
    }

    // ── null_check — unwrap nullable, just return the value ──
    if (fn == "null_check") {
        return get_message_field(call, "value");
    }

    // ── Collection constructors that sometimes appear in the std module
    //    rather than std_collections (encoder variation) ──
    if (fn == "set_create") return "std::vector<std::any>{}";
    if (fn == "map_create") {
        // map_create can carry `entries` in input
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation &&
            call.input().message_creation().fields_size() > 0) {
            std::string result = "std::map<std::string,std::any>{";
            bool first = true;
            for (const auto& f : call.input().message_creation().fields()) {
                if (!first) result += ", ";
                result += "{\"" + f.name() + "\", std::any(" + compile_expr(f.value()) + ")}";
                first = false;
            }
            result += "}";
            return result;
        }
        return "std::map<std::string,std::any>{}";
    }

    // ── Typed list ──
    // `typed_list` creates an empty list of a specific type → empty vector
    if (fn == "typed_list") {
        return "std::vector<std::any>{}";
    }

    // ── Null-aware access / call ──
    // `x?.field` → access field only if x has a value
    if (fn == "null_aware_access") {
        auto target = get_message_field(call, "target");
        auto field = get_string_field(call, "field");
        if (!field.empty()) {
            // Use bracket notation for dynamic access, matching compile_field_access
            return "(" + target + ".has_value() ? " + target + "[\"" + field + "\"s] : BallDyn())";
        }
        return target;
    }
    // `x?.method()` → call only if x has a value
    if (fn == "null_aware_call") {
        auto target = get_message_field(call, "target");
        auto callback = get_message_field(call, "callback");
        if (!callback.empty()) {
            return "(" + target + ".has_value() ? " + callback + "(" + target + ") : BallDyn())";
        }
        return target;
    }
    // `x?.cascade(...)` → cascade only if x has a value
    if (fn == "null_aware_cascade") {
        return get_message_field(call, "target");
    }

    // Default: unknown std call → comment marker
    return "/* std." + fn + " */ 0";
}

// ================================================================
// Method-style call compilation (self.method pattern)
// ================================================================

std::string CppCompiler::compile_method_call(const std::string& fn,
                                              const ball::v1::FunctionCall& call) {
    auto self = get_message_field(call, "self");
    auto arg0 = get_message_field(call, "arg0");
    auto arg1 = get_message_field(call, "arg1");

    // If `self` is a member function reference (wrapped in a lambda by
    // compile_reference), it needs to be CALLED (invoked) before method
    // dispatch, since the Dart source intended a property/getter access.
    // Detect the lambda pattern and invoke it.
    if (call.has_input() &&
        call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
        for (const auto& f : call.input().message_creation().fields()) {
            if (f.name() == "self" &&
                f.value().expr_case() == ball::v1::Expression::kReference &&
                !current_class_methods_.empty() &&
                current_class_methods_.count(sanitize_name(f.value().reference().name())) > 0) {
                // The reference is to a no-arg method used as a getter.
                // Call it instead of wrapping in a lambda.
                self = sanitize_name(f.value().reference().name()) + "()";
                break;
            }
        }
    }

    // ── List methods ──
    if (fn == "add") {
        return self + ".push_back(" + arg0 + ")";
    }
    if (fn == "removeLast") {
        return "[&](auto& _v){ auto _e = _v.back(); _v.pop_back(); return _e; }(" + self + ")";
    }
    if (fn == "length") {
        return "static_cast<int64_t>(" + self + ".size())";
    }
    if (fn == "isEmpty") {
        return self + ".empty()";
    }
    if (fn == "isNotEmpty") {
        return "!" + self + ".empty()";
    }
    if (fn == "last") {
        return self + ".back()";
    }
    if (fn == "first") {
        return self + ".front()";
    }
    if (fn == "contains") {
        // Works for both strings and lists.
        // For strings: self.find(arg0) != std::string::npos
        // For lists: std::find(self.begin(), self.end(), arg0) != self.end()
        // We use a generic IIFE that attempts string first, falls back to
        // find-based search. Since C++ is statically typed and we know
        // the Dart source intent, string.contains is the common case
        // when arg0 is a string literal.
        return "(" + self + ".find(" + arg0 + ") != std::string::npos)";
    }
    if (fn == "insert") {
        auto idx = arg0;
        auto val = arg1;
        return self + ".insert(" + self + ".begin() + " + idx + ", " + val + ")";
    }
    if (fn == "removeAt") {
        return self + ".erase(" + self + ".begin() + " + arg0 + ")";
    }
    if (fn == "indexOf") {
        return self + ".indexOf(" + arg0 + ")";
    }
    if (fn == "sublist") {
        if (arg1.empty()) {
            return "[](const auto& v, int64_t s){ return decltype(v)(v.begin()+s, v.end()); }(" +
                   self + ", " + arg0 + ")";
        }
        return "[](const auto& v, int64_t s, int64_t e){ return decltype(v)(v.begin()+s, v.begin()+e); }(" +
               self + ", " + arg0 + ", " + arg1 + ")";
    }
    if (fn == "reversed") {
        return "[](auto v){ std::reverse(v.begin(), v.end()); return v; }(" + self + ")";
    }
    if (fn == "join") {
        std::string sep = arg0.empty() ? "\"\"" : arg0;
        return "[](const auto& v, const std::string& s){"
               "std::string r; for(size_t i=0;i<v.size();i++){"
               "if(i>0) r+=s; r+=ball_to_string(v[i]);} return r;"
               "}(" + self + ", " + sep + ")";
    }
    if (fn == "filled") {
        // List.filled(length, value) — self is "List" (type name), arg0 is length, arg1 is value
        return "std::vector<std::any>(" + arg0 + ", std::any(" + arg1 + "))";
    }

    // ── Map methods ──
    if (fn == "containsKey") {
        return "(" + self + ".count(" + arg0 + ") > 0)";
    }
    if (fn == "remove") {
        return self + ".erase(" + arg0 + ")";
    }

    // ── String methods ──
    if (fn == "substring") {
        if (arg1.empty()) {
            return self + ".substr(" + arg0 + ")";
        }
        return self + ".substr(" + arg0 + ", " + arg1 + " - " + arg0 + ")";
    }
    if (fn == "startsWith") {
        return "(" + self + ".rfind(" + arg0 + ", 0) == 0)";
    }
    if (fn == "endsWith") {
        return "[](const std::string& s, const std::string& e){"
               "return s.size()>=e.size() && s.compare(s.size()-e.size(),e.size(),e)==0;"
               "}(" + self + ", " + arg0 + ")";
    }
    if (fn == "trim") {
        return "[](const std::string& s){"
               "auto a=s.find_first_not_of(\" \\t\\n\\r\"),b=s.find_last_not_of(\" \\t\\n\\r\");"
               "return a==std::string::npos?std::string():s.substr(a,b-a+1);"
               "}(" + self + ")";
    }
    if (fn == "split") {
        return "[](const std::string& s, const std::string& d){"
               "if(d.empty()){std::vector<std::string> r;"
               "for(char c:s) r.push_back(std::string(1,c)); return r;}"
               "std::vector<std::string> r; size_t p=0,f;"
               "while((f=s.find(d,p))!=std::string::npos){"
               "r.push_back(s.substr(p,f-p)); p=f+d.size();}"
               "r.push_back(s.substr(p)); return r;"
               "}(" + self + ", " + arg0 + ")";
    }
    if (fn == "replaceAll") {
        return "[](std::string s, const std::string& f, const std::string& t){"
               "if(f.empty()){std::string o;o.reserve(s.size()*(t.size()+1)+t.size());"
               "o+=t;for(char c:s){o.push_back(c);o+=t;}return o;}"
               "size_t p=0;"
               "while((p=s.find(f,p))!=std::string::npos){"
               "s.replace(p,f.size(),t);p+=t.size();}return s;"
               "}(" + self + ", " + arg0 + ", " + arg1 + ")";
    }
    if (fn == "toLowerCase") {
        return "[](std::string s){std::transform(s.begin(),s.end(),s.begin(),::tolower);return s;}(" + self + ")";
    }
    if (fn == "toUpperCase") {
        return "[](std::string s){std::transform(s.begin(),s.end(),s.begin(),::toupper);return s;}(" + self + ")";
    }
    if (fn == "padLeft") {
        return "[](const std::string& s, int64_t w, const std::string& p){"
               "if(static_cast<int64_t>(s.size())>=w) return s;"
               "std::string r; while(static_cast<int64_t>(r.size()+s.size())<w) r+=p;"
               "return r.substr(0,w-s.size())+s;"
               "}(" + self + ", " + arg0 + ", " + (arg1.empty() ? "\" \"s" : arg1) + ")";
    }
    if (fn == "padRight") {
        return "[](const std::string& s, int64_t w, const std::string& p){"
               "if(static_cast<int64_t>(s.size())>=w) return s;"
               "std::string r=s; while(static_cast<int64_t>(r.size())<w) r+=p;"
               "return r.substr(0,w);"
               "}(" + self + ", " + arg0 + ", " + (arg1.empty() ? "\" \"s" : arg1) + ")";
    }
    if (fn == "codeUnitAt") {
        return "static_cast<int64_t>(static_cast<unsigned char>(" + self + "[" + arg0 + "]))";
    }

    // ── Number methods ──
    if (fn == "toDouble") {
        return "static_cast<double>(" + self + ")";
    }
    if (fn == "toInt") {
        return "static_cast<int64_t>(" + self + ")";
    }
    if (fn == "toString") {
        return "ball_to_string(" + self + ")";
    }
    if (fn == "abs") {
        return "std::abs(" + self + ")";
    }
    if (fn == "round") {
        return "static_cast<int64_t>(std::round(" + self + "))";
    }
    if (fn == "ceil") {
        return "static_cast<int64_t>(std::ceil(" + self + "))";
    }
    if (fn == "floor") {
        return "static_cast<int64_t>(std::floor(" + self + "))";
    }
    if (fn == "toStringAsFixed") {
        return "[](double v, int64_t d){"
               "std::ostringstream o; o<<std::fixed<<std::setprecision(d)<<v;"
               "return o.str();"
               "}(" + self + ", " + arg0 + ")";
    }
    if (fn == "compareTo") {
        return "[](const auto& a, const auto& b) -> int64_t { return a < b ? -1 : (a > b ? 1 : 0); }(" + self + ", " + arg0 + ")";
    }
    if (fn == "clamp") {
        return "[](auto v, auto lo, auto hi){ return v < lo ? lo : (v > hi ? hi : v); }(" + self + ", " + arg0 + ", " + arg1 + ")";
    }
    if (fn == "gcd") {
        return "[](int64_t a, int64_t b) -> int64_t { while(b){auto t=b;b=a%b;a=t;} return std::abs(a); }(" + self + ", " + arg0 + ")";
    }
    if (fn == "replaceFirst") {
        return "[](std::string s, const std::string& f, const std::string& t){"
               "auto p=s.find(f);if(p!=std::string::npos)s.replace(p,f.size(),t);return s;"
               "}(" + self + ", " + arg0 + ", " + arg1 + ")";
    }
    if (fn == "lastIndexOf") {
        return "[](const std::string& s, const std::string& p) -> int64_t {"
               "auto i=s.rfind(p); return i==std::string::npos ? -1 : static_cast<int64_t>(i);"
               "}(" + self + ", " + arg0 + ")";
    }

    // ── Dart protobuf oneof discriminators ──
    // The Dart encoder emits `expr.whichExpr()` as a method call with self=expr.
    // Return a string tag that matches the Expression_Expr.xxx constants.
    if (fn == "whichExpr") {
        return "ball_which_expr(" + self + ")";
    }
    if (fn == "whichValue") {
        return "ball_which_value(" + self + ")";
    }
    if (fn == "whichKind") {
        return "ball_which_kind(" + self + ")";
    }
    if (fn == "whichSource") {
        return "ball_which_source(" + self + ")";
    }
    if (fn == "whichStmt") {
        return "ball_which_stmt(" + self + ")";
    }

    // ── Dart protobuf `has*` methods ──
    if (fn == "hasBody") {
        return "ball_has_field(" + self + ", \"body\"s)";
    }
    if (fn == "hasMetadata") {
        return "ball_has_field(" + self + ", \"metadata\"s)";
    }
    if (fn == "hasInput") {
        return "ball_has_field(" + self + ", \"input\"s)";
    }
    if (fn == "hasCall") {
        return "ball_has_field(" + self + ", \"call\"s)";
    }
    if (fn == "hasDescriptor") {
        return "ball_has_field(" + self + ", \"descriptor\"s)";
    }
    if (fn == "hasStringValue") {
        return "ball_has_field(" + self + ", \"stringValue\"s)";
    }
    if (fn == "hasResult") {
        return "ball_has_field(" + self + ", \"result\"s)";
    }
    if (fn == "hasMatch") {
        return "std::regex_search(" + arg0 + ", " + self + ")";
    }

    // ── Dart collection helpers ──
    if (fn == "toList") {
        return "ball_to_list(" + self + ")";
    }
    if (fn == "toSet") {
        return "ball_to_set(" + self + ")";
    }
    if (fn == "where") {
        return "ball_where(" + self + ", " + arg0 + ")";
    }
    if (fn == "map") {
        return "ball_map(" + self + ", " + arg0 + ")";
    }
    if (fn == "every") {
        return "ball_every(" + self + ", " + arg0 + ")";
    }
    if (fn == "addAll") {
        return "ball_add_all(" + self + ", " + arg0 + ")";
    }
    if (fn == "putIfAbsent") {
        return "ball_put_if_absent(" + self + ", " + arg0 + ", " + arg1 + ")";
    }
    if (fn == "take") {
        return "ball_take(" + self + ", " + arg0 + ")";
    }
    if (fn == "skip") {
        return "ball_skip(" + self + ", " + arg0 + ")";
    }
    if (fn == "sort") {
        if (arg0.empty()) {
            return "std::sort(" + self + ".begin(), " + self + ".end())";
        }
        return "std::sort(" + self + ".begin(), " + self + ".end(), " + arg0 + ")";
    }
    if (fn == "fromEntries") {
        // For `Map.fromEntries(list)`, self is "Map" (type name), arg0 is the list.
        // For `list.fromEntries()`, self is the list.
        if (!arg0.empty())
            return "ball_from_entries(" + arg0 + ")";
        return "ball_from_entries(" + self + ")";
    }

    // ── Dart regex helpers ──
    if (fn == "firstMatch") {
        return "ball_first_match(" + self + ", " + arg0 + ")";
    }
    if (fn == "group") {
        return "ball_group(" + self + ", " + arg0 + ")";
    }
    if (fn == "allMatches") {
        return "ball_all_matches(" + self + ", " + arg0 + ")";
    }

    // ── Dart utility functions ──
    if (fn == "unmodifiable") {
        // unmodifiable(type, collection) → just return the collection (C++ has no unmodifiable)
        return arg0;
    }
    if (fn == "tryParse") {
        return "ball_try_parse(" + self + ", " + arg0 + ")";
    }

    // Fallback: treat as a user-defined function call passing self + args
    std::string func_name = sanitize_name(fn);
    std::string result = func_name + "(";
    bool first = true;
    if (call.has_input() &&
        call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
        for (const auto& f : call.input().message_creation().fields()) {
            if (!first) result += ", ";
            result += compile_expr(f.value());
            first = false;
        }
    }
    result += ")";
    return result;
}

// ================================================================
// Statement compilation (emits to out_)
// ================================================================

void CppCompiler::compile_statement(const ball::v1::Statement& stmt) {
    if (stmt.has_let()) {
        emit_indent();
        out_ << "auto " << sanitize_name(stmt.let().name()) << " = "
             << compile_expr(stmt.let().value()) << ";\n";
    } else if (stmt.has_expression()) {
        // Block expressions used as statements: if the block has only
        // let bindings (no result expression), emit them inline so the
        // variables are visible in the enclosing scope. This is needed
        // for Dart record pattern destructuring which encodes as a block
        // with multiple let bindings.
        if (stmt.expression().expr_case() == ball::v1::Expression::kBlock) {
            const auto& block = stmt.expression().block();
            if (!block.has_result()) {
                for (const auto& s : block.statements()) {
                    compile_statement(s);
                }
                return;
            }
        }
        auto expr_str = compile_expr(stmt.expression());
        // Special handling for return in statement context
        if (stmt.expression().expr_case() == ball::v1::Expression::kCall) {
            const auto& call = stmt.expression().call();
            // `labeled` wraps a loop (or any statement) to attach a label used
            // by `break <label>` / `continue <label>`. We stash the label in
            // `pending_label_` so the next loop emission plants the goto
            // targets, then recursively compile the wrapped body.
            // Empty module is an implicit std reference (encoder sometimes
            // omits `module: 'std'`). Accept both forms for every std
            // control-flow case below.
            const auto& call_mod = call.module();
            const bool std_like = call_mod.empty() ||
                                  call_mod == "std" ||
                                  call_mod == "dart_std";
            if (std_like && call.function() == "labeled") {
                auto label_name = get_string_field(call, "label");
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    auto prev_label = pending_label_;
                    pending_label_ = label_name;
                    // The body can be a block wrapping the loop, or the
                    // loop call directly. Unwrap blocks so the loop's
                    // statement-form emission picks up the pending label.
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *body_expr;
                        compile_statement(inner);
                    }
                    // If the body wasn't a recognized loop, the label was
                    // never consumed — fall back to emitting a break target
                    // so `break <label>` still has somewhere to land.
                    if (!pending_label_.empty()) {
                        emit_line("__ball_break_" + pending_label_ + ":;");
                        pending_label_ = prev_label;
                    } else {
                        pending_label_ = prev_label;
                    }
                }
                return;
            }
            if (std_like &&
                call.function() == "return") {
                auto val = get_message_field(call, "value");
                emit_line("return " + val + ";");
                return;
            }
            if (std_like &&
                call.function() == "if") {
                // Emit if as a statement
                auto cond = get_message_field(call, "condition");
                emit_line("if (" + cond + ") {");
                indent_++;
                // Lambda: emit an arbitrary expression as a nested statement
                // so that direct calls to `return`/`break`/`continue` get
                // their proper statement form instead of falling back to
                // `compile_expr`, which renders them as comment placeholders.
                auto emit_branch = [&](const ball::v1::Expression* e) {
                    if (!e) return;
                    if (e->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : e->block().statements()) {
                            compile_statement(s);
                        }
                        if (e->block().has_result()) {
                            emit_line(compile_expr(e->block().result()) + ";");
                        }
                    } else {
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *e;
                        compile_statement(inner);
                    }
                };
                emit_branch(get_message_field_expr(call, "then"));
                indent_--;
                auto* else_expr = get_message_field_expr(call, "else");
                if (else_expr) {
                    emit_line("} else {");
                    indent_++;
                    emit_branch(else_expr);
                    indent_--;
                }
                emit_line("}");
                return;
            }
            if (std_like &&
                call.function() == "for") {
                auto loop_label = pending_label_;
                pending_label_.clear();
                // The Dart encoder emits `init` as an opaque source
                // string like `"var i = 0"`. Detect that case and
                // translate it into a C++ declaration so the emitted
                // `for(...)` header is valid. Any non-literal init
                // expression falls through to the default path.
                auto* init_expr = get_message_field_expr(call, "init");
                std::string init;
                if (init_expr &&
                    init_expr->expr_case() == ball::v1::Expression::kLiteral &&
                    init_expr->literal().value_case() == ball::v1::Literal::kStringValue) {
                    const auto& raw = init_expr->literal().string_value();
                    // Match `var name = value` / `int name = value` / ...
                    // Simple parse: strip leading keyword, replace `var`
                    // with `auto` so C++ accepts it.
                    auto dart_to_cpp_init = [](std::string s) {
                        const std::vector<std::string> kws = {
                            "var", "final", "int", "double", "String",
                            "bool", "num",
                        };
                        std::string out = s;
                        for (const auto& kw : kws) {
                            if (out.size() > kw.size() &&
                                out.compare(0, kw.size(), kw) == 0 &&
                                out[kw.size()] == ' ') {
                                out = (kw == "var" || kw == "final"
                                           ? std::string("auto")
                                           : kw == "num"
                                                 ? std::string("double")
                                                 : kw == "String"
                                                       ? std::string("std::string")
                                                       : kw) +
                                      out.substr(kw.size());
                                break;
                            }
                        }
                        // Replace Dart-style property accesses with C++
                        // equivalents inside the init string.
                        // `.length` → `.size()` (cast handled by context)
                        {
                            size_t pos = 0;
                            while ((pos = out.find(".length", pos)) != std::string::npos) {
                                // Ensure it's not part of a longer word
                                size_t end = pos + 7;
                                if (end >= out.size() || !std::isalnum(out[end])) {
                                    out.replace(pos, 7, ".size()");
                                    pos += 7;
                                } else {
                                    pos += 7;
                                }
                            }
                        }
                        return out;
                    };
                    init = dart_to_cpp_init(raw);
                } else {
                    init = get_message_field(call, "init");
                }
                auto cond = get_message_field(call, "condition");
                auto update = get_message_field(call, "update");
                emit_line("for (" + init + "; " + cond + "; " + update + ") {");
                indent_++;
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        // Wrap the bare-expression body in a synthetic
                        // statement so control-flow calls (if / labeled
                        // / break / continue / return / try) reach
                        // their statement-context emission instead of
                        // falling back to the IIFE-wrapped expression
                        // form in compile_expr.
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *body_expr;
                        compile_statement(inner);
                    }
                }
                if (!loop_label.empty()) {
                    emit_line("__ball_continue_" + loop_label + ":;");
                }
                indent_--;
                emit_line("}");
                if (!loop_label.empty()) {
                    emit_line("__ball_break_" + loop_label + ":;");
                }
                return;
            }
            if (std_like &&
                call.function() == "for_in") {
                auto loop_label = pending_label_;
                pending_label_.clear();
                auto* var_expr = get_message_field_expr(call, "variable");
                std::string var_name = "item";
                if (var_expr && var_expr->expr_case() == ball::v1::Expression::kLiteral)
                    var_name = var_expr->literal().string_value();
                auto iter = get_message_field(call, "iterable");
                emit_line("for (auto " + sanitize_name(var_name) + " : " + iter + ") {");
                indent_++;
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        // Wrap bare-expression body in a synthetic
                        // statement so nested control-flow calls hit
                        // their statement-context emission.
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *body_expr;
                        compile_statement(inner);
                    }
                }
                if (!loop_label.empty()) {
                    emit_line("__ball_continue_" + loop_label + ":;");
                }
                indent_--;
                emit_line("}");
                if (!loop_label.empty()) {
                    emit_line("__ball_break_" + loop_label + ":;");
                }
                return;
            }
            if (std_like &&
                call.function() == "while") {
                auto loop_label = pending_label_;
                pending_label_.clear();
                auto cond = get_message_field(call, "condition");
                emit_line("while (" + cond + ") {");
                indent_++;
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        // Wrap bare-expression body in a synthetic
                        // statement so nested control-flow calls hit
                        // their statement-context emission.
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *body_expr;
                        compile_statement(inner);
                    }
                }
                if (!loop_label.empty()) {
                    emit_line("__ball_continue_" + loop_label + ":;");
                }
                indent_--;
                emit_line("}");
                if (!loop_label.empty()) {
                    emit_line("__ball_break_" + loop_label + ":;");
                }
                return;
            }
            if (std_like &&
                call.function() == "do_while") {
                auto loop_label = pending_label_;
                pending_label_.clear();
                emit_line("do {");
                indent_++;
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        // Wrap bare-expression body in a synthetic
                        // statement so nested control-flow calls hit
                        // their statement-context emission.
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *body_expr;
                        compile_statement(inner);
                    }
                }
                if (!loop_label.empty()) {
                    emit_line("__ball_continue_" + loop_label + ":;");
                }
                indent_--;
                auto cond = get_message_field(call, "condition");
                emit_line("} while (" + cond + ");");
                if (!loop_label.empty()) {
                    emit_line("__ball_break_" + loop_label + ":;");
                }
                return;
            }
            if (std_like &&
                call.function() == "switch") {
                auto subj = get_message_field(call, "subject");
                emit_line("switch (" + subj + ") {");
                indent_++;
                auto* cases_expr = get_message_field_expr(call, "cases");
                if (cases_expr && cases_expr->expr_case() == ball::v1::Expression::kLiteral &&
                    cases_expr->literal().value_case() == ball::v1::Literal::kListValue) {
                    for (const auto& cx : cases_expr->literal().list_value().elements()) {
                        if (cx.expr_case() != ball::v1::Expression::kMessageCreation) continue;
                        const ball::v1::Expression* case_val = nullptr;
                        const ball::v1::Expression* case_body = nullptr;
                        bool is_default = false;
                        for (const auto& f : cx.message_creation().fields()) {
                            if (f.name() == "value") case_val = &f.value();
                            else if (f.name() == "body") case_body = &f.value();
                            else if (f.name() == "is_default" &&
                                     f.value().expr_case() == ball::v1::Expression::kLiteral &&
                                     f.value().literal().bool_value()) is_default = true;
                        }
                        if (is_default) {
                            emit_line("default: {");
                        } else if (case_val) {
                            emit_line("case " + compile_expr(*case_val) + ": {");
                        } else {
                            continue;
                        }
                        indent_++;
                        if (case_body) {
                            if (case_body->expr_case() == ball::v1::Expression::kBlock) {
                                for (const auto& s : case_body->block().statements()) {
                                    compile_statement(s);
                                }
                                if (case_body->block().has_result()) {
                                    emit_line(compile_expr(case_body->block().result()) + ";");
                                }
                            } else {
                                emit_line(compile_expr(*case_body) + ";");
                            }
                        }
                        emit_line("break;");
                        indent_--;
                        emit_line("}");
                    }
                }
                indent_--;
                emit_line("}");
                return;
            }
            if (std_like &&
                call.function() == "try") {
                emit_line("try {");
                indent_++;
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        // Wrap bare-expression body in a synthetic
                        // statement so nested control-flow calls hit
                        // their statement-context emission.
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *body_expr;
                        compile_statement(inner);
                    }
                }
                indent_--;
                auto* catches_expr = get_message_field_expr(call, "catches");
                if (catches_expr &&
                    catches_expr->expr_case() == ball::v1::Expression::kLiteral &&
                    catches_expr->literal().value_case() == ball::v1::Literal::kListValue) {
                    // Partition catches into typed and untyped, preserving order
                    // within each group. Typed catches dispatch inside a single
                    // `catch (const BallException&)` block via if/else on
                    // type_name. Untyped catches match anything (last-resort).
                    struct CatchClause {
                        const ball::v1::Expression* body = nullptr;
                        std::string var = "e";
                        std::string type_name; // empty = untyped
                        std::string stack_var; // empty = no stack binding
                    };
                    std::vector<CatchClause> clauses;
                    for (const auto& cx : catches_expr->literal().list_value().elements()) {
                        if (cx.expr_case() != ball::v1::Expression::kMessageCreation) continue;
                        CatchClause cc;
                        for (const auto& f : cx.message_creation().fields()) {
                            if (f.name() == "body") cc.body = &f.value();
                            else if (f.name() == "variable" &&
                                     f.value().expr_case() == ball::v1::Expression::kLiteral)
                                cc.var = f.value().literal().string_value();
                            else if (f.name() == "type" &&
                                     f.value().expr_case() == ball::v1::Expression::kLiteral)
                                cc.type_name = f.value().literal().string_value();
                            else if (f.name() == "stack_trace" &&
                                     f.value().expr_case() == ball::v1::Expression::kLiteral)
                                cc.stack_var = f.value().literal().string_value();
                        }
                        clauses.push_back(std::move(cc));
                    }

                    auto emit_catch_body = [&](const CatchClause& cc) {
                        if (!cc.body) return;
                        if (cc.body->expr_case() == ball::v1::Expression::kBlock) {
                            for (const auto& s : cc.body->block().statements()) {
                                compile_statement(s);
                            }
                            if (cc.body->block().has_result()) {
                                emit_line(compile_expr(cc.body->block().result()) + ";");
                            }
                        } else {
                            emit_line(compile_expr(*cc.body) + ";");
                        }
                    };

                    // Count typed vs. find first untyped
                    int typed_count = 0;
                    const CatchClause* first_untyped = nullptr;
                    for (const auto& cc : clauses) {
                        if (cc.type_name.empty()) {
                            if (!first_untyped) first_untyped = &cc;
                        } else {
                            typed_count++;
                        }
                    }

                    // Emit `catch (const BallException&)` block with type
                    // dispatch when at least one typed catch exists. The
                    // catch variable is bound to the BallException itself
                    // so field access can reach `.fields.at("X")`. A
                    // stream `operator<<` overload in the runtime makes
                    // `print(e)` fall through to `.what()`.
                    if (typed_count > 0) {
                        emit_line("} catch (const BallException& __ball_e) {");
                        indent_++;
                        bool first = true;
                        for (const auto& cc : clauses) {
                            if (cc.type_name.empty()) continue;
                            emit_line(std::string(first ? "if" : "else if") +
                                      " (__ball_e.type_name == \"" + cc.type_name + "\"s) {");
                            indent_++;
                            auto var = sanitize_name(cc.var);
                            emit_line("const BallException& " + var + " = __ball_e;");
                            if (!cc.stack_var.empty()) {
                                // Dart's `catch (e, stack)` binds a StackTrace.
                                // C++ exceptions don't carry a stack by default;
                                // emit an opaque empty string to keep user
                                // code compilable (mirrors the TS compiler).
                                emit_line("std::string " + sanitize_name(cc.stack_var) +
                                          " = \"<stack trace unavailable>\"s;");
                            }
                            catch_bound_vars_.insert(var);
                            emit_catch_body(cc);
                            catch_bound_vars_.erase(var);
                            indent_--;
                            emit_line("}");
                            first = false;
                        }
                        // Fallback: untyped catch body (if any), else rethrow.
                        emit_line("else {");
                        indent_++;
                        if (first_untyped) {
                            auto var = sanitize_name(first_untyped->var);
                            emit_line("const BallException& " + var + " = __ball_e;");
                            if (!first_untyped->stack_var.empty()) {
                                emit_line("std::string " +
                                          sanitize_name(first_untyped->stack_var) +
                                          " = \"<stack trace unavailable>\"s;");
                            }
                            catch_bound_vars_.insert(var);
                            emit_catch_body(*first_untyped);
                            catch_bound_vars_.erase(var);
                        } else {
                            emit_line("throw;");
                        }
                        indent_--;
                        emit_line("}");
                        indent_--;
                    }
                    // Always emit a std::exception catch for non-BallException
                    // throws (e.g. real `std::runtime_error` escaping a
                    // library call). Untyped catch clauses match here;
                    // otherwise rethrow to propagate.
                    emit_line("} catch (const std::exception& __ball_e) {");
                    indent_++;
                    if (first_untyped) {
                        auto var = sanitize_name(first_untyped->var);
                        emit_line("std::string " + var + " = __ball_e.what();");
                        if (!first_untyped->stack_var.empty()) {
                            emit_line("std::string " +
                                      sanitize_name(first_untyped->stack_var) +
                                      " = \"<stack trace unavailable>\"s;");
                        }
                        // Not a BallException — no fields map, so don't
                        // register as catch-bound for field access.
                        emit_catch_body(*first_untyped);
                    } else {
                        emit_line("throw;");
                    }
                    indent_--;
                } else if (catches_expr) {
                    // Single catch expression (non-list) — treat as untyped
                    emit_line("} catch (const std::exception& e) {");
                    indent_++;
                    emit_line(compile_expr(*catches_expr) + ";");
                    indent_--;
                } else {
                    emit_line("} catch (const std::exception& e) {");
                    indent_++;
                    indent_--;
                }
                emit_line("}");
                auto* finally_expr = get_message_field_expr(call, "finally");
                if (finally_expr) {
                    // C++ has no finally — emit cleanup code unconditionally after try-catch
                    if (finally_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : finally_expr->block().statements()) {
                            compile_statement(s);
                        }
                        if (finally_expr->block().has_result()) {
                            emit_line(compile_expr(finally_expr->block().result()) + ";");
                        }
                    } else {
                        emit_line(compile_expr(*finally_expr) + ";");
                    }
                }
                return;
            }
        }
        emit_line(expr_str + ";");
    }
}

// ================================================================
// Structural emitters
// ================================================================

void CppCompiler::emit_includes() {
    emit_line("#include <iostream>");
    emit_line("#include <string>");
    emit_line("#include <vector>");
    emit_line("#include <map>");
    emit_line("#include <unordered_map>");
    emit_line("#include <any>");
    emit_line("#include <functional>");
    emit_line("#include <algorithm>");
    emit_line("#include <cmath>");
    emit_line("#include <cstdint>");
    emit_line("#include <sstream>");
    emit_line("#include <stdexcept>");
    emit_line("#include <cassert>");
    emit_line("#include <regex>");
    emit_line("#include <fstream>");
    emit_line("#include <iomanip>");
    if (base_modules_.count("std_memory")) {
        emit_line("#include <cstring>");
    }
    emit_line("#include <cstdlib>");
    emit_line("#include <thread>");
    emit_line("#include <chrono>");
    emit_line("#include <random>");
    emit_newline();
    emit_line("using namespace std::string_literals;");
    emit_newline();

    // Splice the single-source-of-truth runtime (BallException +
    // ball_to_string overloads) from ball_emit_runtime.h. The embed
    // header is generated at configure time by EmbedRuntimeHeader.cmake,
    // so edits to ball_emit_runtime.h automatically flow into every
    // emitted C++ program AND the engine (via ball_shared.h).
    out_ << BALL_EMIT_RUNTIME_SOURCE;
    emit_newline();

    // Splice the BallDyn dynamic value type for dynamic typing support.
    out_ << BALL_DYN_SOURCE;
    emit_newline();
}

// Helper: extract a metadata list field as vector<string>
std::vector<std::string> CppCompiler::read_meta_list(
    const google::protobuf::Struct& meta, const std::string& key) {
    std::vector<std::string> result;
    auto it = meta.fields().find(key);
    if (it != meta.fields().end() &&
        it->second.kind_case() == google::protobuf::Value::kListValue) {
        for (const auto& v : it->second.list_value().values()) {
            if (v.kind_case() == google::protobuf::Value::kStringValue)
                result.push_back(v.string_value());
        }
    }
    return result;
}

// Helper: read metadata from TypeDefinition
std::map<std::string, std::string> CppCompiler::read_type_meta(
    const ball::v1::TypeDefinition& td) {
    std::map<std::string, std::string> result;
    if (!td.has_metadata()) return result;
    for (const auto& [k, v] : td.metadata().fields()) {
        if (v.kind_case() == google::protobuf::Value::kStringValue)
            result[k] = v.string_value();
        else if (v.kind_case() == google::protobuf::Value::kBoolValue)
            result[k] = v.bool_value() ? "true" : "false";
    }
    return result;
}

// Helper: emit template<typename T, ...> prefix from type_params
void CppCompiler::emit_template_prefix(const ball::v1::TypeDefinition& td) {
    if (td.type_params_size() == 0) return;
    emit_indent();
    out_ << "template<";
    for (int i = 0; i < td.type_params_size(); i++) {
        if (i > 0) out_ << ", ";
        out_ << "typename " << td.type_params(i).name();
    }
    out_ << ">\n";
}

// Helper: emit template prefix from metadata type_params list
void CppCompiler::emit_template_prefix_from_meta(
    const google::protobuf::Struct& meta) {
    auto params = read_meta_list(meta, "type_params");
    if (params.empty()) return;
    emit_indent();
    out_ << "template<";
    for (size_t i = 0; i < params.size(); i++) {
        if (i > 0) out_ << ", ";
        // "T extends Foo" → "typename T"
        auto space = params[i].find(' ');
        std::string param_name = (space != std::string::npos)
            ? params[i].substr(0, space) : params[i];
        out_ << "typename " << param_name;
    }
    out_ << ">\n";
}

void CppCompiler::emit_forward_decls(const ball::v1::Module& module) {
    // Skip forward declarations for types that are already defined in the
    // runtime preamble (e.g. BallException, File, JsonEncoder, etc.)
    static const std::set<std::string> runtime_types = {
        "BallException", "File", "JsonEncoder", "JsonDecoder",
        "Map_from", "FunctionType",
        "_FlowSignal", "_Scope", "BallRuntimeError", "BallFuture",
        "BallGenerator", "_ExitSignal", "BallModuleHandler",
        "StdModuleHandler",
    };
    for (const auto& td : module.type_defs()) {
        if (!td.has_descriptor_()) continue;
        if (runtime_types.count(sanitize_name(td.name())) > 0) continue;
        // Forward decls also need template prefix
        emit_template_prefix(td);
        emit_line("struct " + sanitize_name(td.name()) + ";");
    }

    // Forward-declare top-level functions so mutual recursion works
    // regardless of declaration order. We only declare true free
    // functions (not the entry point, methods, operators, or
    // conversion operators) — those either aren't callable from
    // elsewhere or are declared inside their struct.
    for (const auto& func : module.functions()) {
        if (func.is_base()) continue;
        if (func.name() == "main") continue;
        // Skip methods (names contain ':' or '.') and operators.
        if (func.name().find(':') != std::string::npos) continue;
        auto meta_map = read_meta(func);
        if (meta_map.count("kind") &&
            (meta_map["kind"] == "method" ||
             meta_map["kind"] == "constructor" ||
             meta_map["kind"] == "top_level_variable")) continue;
        if (meta_map.count("is_operator") && meta_map["is_operator"] == "true") continue;

        auto return_type = map_return_type(func);
        auto name = sanitize_name(func.name());
        if (meta_map.count("original_name")) {
            name = sanitize_name(meta_map["original_name"]);
        }
        if (func.has_metadata()) emit_template_prefix_from_meta(func.metadata());
        emit_indent();
        out_ << return_type << " " << name << "(";

        // Re-derive the parameter list (same shape as emit_function).
        auto params = func.has_metadata()
                          ? extract_params(func.metadata())
                          : std::vector<std::string>{};
        std::vector<std::string> ptypes;
        if (func.has_metadata()) {
            auto it = func.metadata().fields().find("params");
            if (it != func.metadata().fields().end() &&
                it->second.kind_case() == google::protobuf::Value::kListValue) {
                for (const auto& v : it->second.list_value().values()) {
                    std::string t;
                    if (v.kind_case() == google::protobuf::Value::kStructValue) {
                        auto tit = v.struct_value().fields().find("type");
                        if (tit != v.struct_value().fields().end() &&
                            tit->second.kind_case() == google::protobuf::Value::kStringValue) {
                            t = tit->second.string_value();
                        }
                    }
                    ptypes.push_back(t);
                }
            }
        }
        if (!params.empty()) {
            for (size_t i = 0; i < params.size(); i++) {
                if (i > 0) out_ << ", ";
                std::string t = (i < ptypes.size() && !ptypes[i].empty())
                                    ? map_type(ptypes[i])
                                    : "auto";
                out_ << t << " " << sanitize_name(params[i]);
            }
        } else if (!func.input_type().empty()) {
            out_ << map_type(func.input_type()) << " input";
        }
        out_ << ");\n";
    }
    emit_newline();
}

void CppCompiler::emit_enum(const google::protobuf::EnumDescriptorProto& ed) {
    emit_line("enum class " + sanitize_name(ed.name()) + " {");
    indent_++;
    for (const auto& val : ed.value()) {
        emit_line(sanitize_name(val.name()) + ",");
    }
    indent_--;
    emit_line("};");
    emit_newline();
}

void CppCompiler::emit_struct(const ball::v1::TypeDefinition& td,
                                const std::vector<const ball::v1::FunctionDefinition*>& methods) {
    std::string name = sanitize_name(td.name());
    auto tmeta = read_type_meta(td);

    // Template prefix from type_params
    emit_template_prefix(td);

    // Determine kind (struct vs class)
    std::string kind_kw = "struct";
    if (tmeta.count("kind") && tmeta["kind"] == "class") kind_kw = "class";

    // Build inheritance list
    std::string bases;
    if (tmeta.count("superclass") && !tmeta["superclass"].empty()) {
        // Use map_type for known Dart base classes (Exception, Error, etc.)
        // then fall back to sanitize_name for user-defined types.
        auto superclass_name = tmeta["superclass"];
        auto mapped = map_type(superclass_name);
        // If map_type returned a C++ stdlib type (contains ::), use it directly.
        // Otherwise, use sanitize_name for user-defined types.
        if (mapped.find("::") != std::string::npos) {
            bases = " : public " + mapped;
        } else {
            bases = " : public " + sanitize_name(superclass_name);
        }
    }
    // Additional base classes from interfaces[]
    if (td.has_metadata()) {
        auto ifaces = read_meta_list(td.metadata(), "interfaces");
        for (const auto& iface : ifaces) {
            bases += bases.empty() ? " : " : ", ";
            auto iface_mapped = map_type(iface);
            if (iface_mapped.find("::") != std::string::npos) {
                bases += "public " + iface_mapped;
            } else {
                bases += "public " + sanitize_name(iface);
            }
        }
        // Virtual bases
        auto vbases = read_meta_list(td.metadata(), "virtual_bases");
        for (const auto& vb : vbases) {
            bases += bases.empty() ? " : " : ", ";
            bases += "virtual public " + sanitize_name(vb);
        }
    }

    emit_line(kind_kw + " " + name + bases + " {");
    indent_++;

    // Fields from descriptor
    if (td.has_descriptor_()) {
        for (const auto& field : td.descriptor_().field()) {
            std::string type;
            switch (field.type()) {
                case google::protobuf::FieldDescriptorProto::TYPE_INT32:
                case google::protobuf::FieldDescriptorProto::TYPE_INT64:
                    type = "int64_t"; break;
                case google::protobuf::FieldDescriptorProto::TYPE_FLOAT:
                case google::protobuf::FieldDescriptorProto::TYPE_DOUBLE:
                    type = "double"; break;
                case google::protobuf::FieldDescriptorProto::TYPE_STRING:
                    type = "std::string"; break;
                case google::protobuf::FieldDescriptorProto::TYPE_BOOL:
                    type = "bool"; break;
                default:
                    type = "BallDyn"; break;
            }
            emit_line(type + " " + sanitize_name(field.name()) + ";");
        }
    }

    // Build the set of method basenames for this class, so that
    // compile_reference can detect when a reference is to a sibling method
    // and wrap it in a lambda (member function pointers can't be stored
    // directly as std::any values).
    current_class_methods_.clear();
    for (const auto* func : methods) {
        auto dot = func->name().rfind('.');
        std::string basename = dot != std::string::npos ? func->name().substr(dot + 1) : func->name();
        current_class_methods_.insert(sanitize_name(basename));
    }

    // Methods
    for (const auto* func : methods) {
        auto meta = read_meta(*func);
        auto kind = meta.count("kind") ? meta["kind"] : "method";
        if (kind == "constructor") {
            // Extract method name from full qualified name
            auto dot = func->name().rfind('.');
            std::string ctor_name = dot != std::string::npos ? func->name().substr(dot + 1) : func->name();
            if (ctor_name == name || ctor_name.empty()) {
                // Default constructor
                emit_indent();
                out_ << name << "(";
                auto params = func->has_metadata() ? extract_params(func->metadata()) : std::vector<std::string>{};
                for (size_t i = 0; i < params.size(); i++) {
                    if (i > 0) out_ << ", ";
                    out_ << "auto " << sanitize_name(params[i]);
                }
                out_ << ")";
                if (func->has_body()) {
                    out_ << " {\n";
                    indent_++;
                    if (func->body().expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : func->body().block().statements())
                            compile_statement(s);
                    }
                    indent_--;
                    emit_line("}");
                } else {
                    out_ << " {}\n";
                }
            }
            continue;
        }

        // Regular method
        auto dot = func->name().rfind('.');
        std::string method_name = dot != std::string::npos ? func->name().substr(dot + 1) : func->name();

        // Template prefix for generic methods
        if (func->has_metadata())
            emit_template_prefix_from_meta(func->metadata());

        emit_indent();
        bool is_static = meta.count("is_static") && meta["is_static"] == "true";
        bool is_operator = meta.count("is_operator") && meta["is_operator"] == "true";
        bool is_conv = meta.count("is_conversion_operator") &&
                       meta["is_conversion_operator"] == "true";
        if (is_static) out_ << "static ";

        if (is_conv) {
            std::string conv_type = map_return_type(*func);
            if (meta.count("conversion_type") && !meta["conversion_type"].empty()) {
                conv_type = map_type(meta["conversion_type"]);
            }
            out_ << "operator " << conv_type << "(";
        } else if (is_operator) {
            // Operator overloading: method_name should be like "operator+"
            std::string op_name = method_name;
            // If the name doesn't already start with "operator", prepend it
            if (op_name.find("operator") != 0) {
                op_name = "operator" + op_name;
            }
            out_ << map_return_type(*func) << " " << op_name << "(";
        } else {
            out_ << map_return_type(*func) << " " << sanitize_name(method_name) << "(";
        }
        auto params = func->has_metadata() ? extract_params(func->metadata()) : std::vector<std::string>{};
        for (size_t i = 0; i < params.size(); i++) {
            if (i > 0) out_ << ", ";
            out_ << "auto " << sanitize_name(params[i]);
        }
        out_ << ") {\n";
        indent_++;
        if (func->has_body()) {
            if (func->body().expr_case() == ball::v1::Expression::kBlock) {
                for (const auto& s : func->body().block().statements())
                    compile_statement(s);
                if (func->body().block().has_result()) {
                    emit_line("return " + compile_expr(func->body().block().result()) + ";");
                }
            } else {
                emit_line("return " + compile_expr(func->body()) + ";");
            }
        }
        indent_--;
        emit_line("}");
    }

    current_class_methods_.clear();

    indent_--;
    emit_line("};");
    emit_newline();
}

void CppCompiler::emit_function(const ball::v1::FunctionDefinition& func) {
    auto return_type = map_return_type(func);
    auto name = sanitize_name(func.name());
    auto params = func.has_metadata() ? extract_params(func.metadata()) : std::vector<std::string>{};
    auto meta = read_meta(func);

    // Overloaded functions: use original_name for emission
    if (meta.count("original_name")) {
        name = sanitize_name(meta["original_name"]);
    }

    // Template prefix for generic functions
    if (func.has_metadata())
        emit_template_prefix_from_meta(func.metadata());

    emit_indent();
    bool is_operator = meta.count("is_operator") && meta["is_operator"] == "true";
    bool is_conv = meta.count("is_conversion_operator") &&
                   meta["is_conversion_operator"] == "true";
    if (is_conv) {
        std::string conv_type = return_type;
        if (meta.count("conversion_type") && !meta["conversion_type"].empty()) {
            conv_type = map_type(meta["conversion_type"]);
        }
        out_ << "operator " << conv_type << "(";
    } else if (is_operator) {
        std::string op_name = name;
        if (op_name.find("operator") != 0)
            op_name = "operator" + op_name;
        out_ << return_type << " " << op_name << "(";
    } else {
        out_ << return_type << " " << name << "(";
    }

    // Parameter emission strategy matches the Dart compiler:
    //   - If metadata provides N>=1 named params, emit them as N separate
    //     typed parameters. The function body references them by name
    //     (the encoder preserves original param names), so no aliasing
    //     is needed. This is the modern, encoder-generated path.
    //   - If metadata is absent but input_type is set, fall back to the
    //     legacy "single `input` parameter" convention used by older
    //     hand-written ball.json files whose bodies reference `input`
    //     directly.
    //   - Otherwise emit `()`.
    auto extract_param_types = [&](const ball::v1::FunctionDefinition& f)
        -> std::vector<std::string> {
        std::vector<std::string> types;
        if (!f.has_metadata()) return types;
        auto it = f.metadata().fields().find("params");
        if (it == f.metadata().fields().end()) return types;
        if (it->second.kind_case() != google::protobuf::Value::kListValue) return types;
        for (const auto& v : it->second.list_value().values()) {
            if (v.kind_case() != google::protobuf::Value::kStructValue) {
                types.push_back("");
                continue;
            }
            auto tit = v.struct_value().fields().find("type");
            if (tit != v.struct_value().fields().end() &&
                tit->second.kind_case() == google::protobuf::Value::kStringValue) {
                types.push_back(tit->second.string_value());
            } else {
                types.push_back("");
            }
        }
        return types;
    };
    auto param_types = extract_param_types(func);

    if (!params.empty()) {
        for (size_t i = 0; i < params.size(); i++) {
            if (i > 0) out_ << ", ";
            std::string t = (i < param_types.size() && !param_types[i].empty())
                                ? map_type(param_types[i])
                                : "auto";
            out_ << t << " " << sanitize_name(params[i]);
        }
    } else if (!func.input_type().empty()) {
        out_ << map_type(func.input_type()) << " input";
    }
    out_ << ") {\n";
    indent_++;

    // Legacy alias: hand-written ball.json fixtures often reference
    // `input` in the body even when metadata.params declares real
    // names (e.g. `fibonacci(n) { return input - 1; }`). For
    // single-param functions, alias `input` → the declared parameter
    // so both names resolve. Modern encoder-generated programs use
    // the real param names and the alias is harmless (just a local
    // reference binding).
    if (params.size() == 1 && sanitize_name(params[0]) != "input") {
        emit_line("auto& input = " + sanitize_name(params[0]) + ";");
    }

    if (func.has_body()) {
        if (func.body().expr_case() == ball::v1::Expression::kBlock) {
            for (const auto& s : func.body().block().statements())
                compile_statement(s);
            if (func.body().block().has_result() && return_type != "void") {
                emit_line("return " + compile_expr(func.body().block().result()) + ";");
            }
        } else if (return_type != "void") {
            // Value-returning body as a bare expression — emit a return.
            emit_line("return " + compile_expr(func.body()) + ";");
        } else {
            // Void body as a bare expression: route through compile_statement
            // so control-flow calls (try/if/for/while/labeled/etc.) reach
            // their statement-context emission instead of the broken lambda
            // fallback in compile_expr (which wraps try in an IIFE).
            ball::v1::Statement inner;
            *inner.mutable_expression() = func.body();
            compile_statement(inner);
        }
    }

    indent_--;
    emit_line("}");
    emit_newline();
}

void CppCompiler::emit_top_level_var(const ball::v1::FunctionDefinition& func) {
    auto meta = read_meta(func);
    std::string modifier = "auto";
    if (meta.count("is_const") && meta["is_const"] == "true") modifier = "const auto";
    if (meta.count("is_final") && meta["is_final"] == "true") modifier = "const auto";

    emit_indent();
    out_ << modifier << " " << sanitize_name(func.name()) << " = ";
    if (func.has_body()) {
        out_ << compile_expr(func.body());
    } else {
        out_ << "0";
    }
    out_ << ";\n";
}

void CppCompiler::emit_main(const ball::v1::FunctionDefinition& entry) {
    emit_line("int main() {");
    indent_++;

    if (entry.has_body()) {
        if (entry.body().expr_case() == ball::v1::Expression::kBlock) {
            for (const auto& s : entry.body().block().statements())
                compile_statement(s);
            if (entry.body().block().has_result()) {
                emit_line(compile_expr(entry.body().block().result()) + ";");
            }
        } else {
            // Route bare expressions through compile_statement so
            // control-flow calls (try/if/for/while/labeled) hit their
            // statement-context emission instead of the lambda fallback
            // in compile_expr.
            ball::v1::Statement inner;
            *inner.mutable_expression() = entry.body();
            compile_statement(inner);
        }
    }

    emit_line("return 0;");
    indent_--;
    emit_line("}");
}

// ================================================================
// Public API
// ================================================================

std::string CppCompiler::compile() {
    out_.str("");
    out_.clear();

    emit_line("// Generated by ball compiler (C++ target)");
    emit_line("// Source: " + program_.name() + " v" + program_.version());
    emit_newline();

    emit_includes();

    const ball::v1::Module* main_module = nullptr;
    const ball::v1::FunctionDefinition* entry_func = nullptr;

    for (const auto& mod : program_.modules()) {
        if (mod.name() == program_.entry_module()) {
            main_module = &mod;
            for (const auto& func : mod.functions()) {
                if (func.name() == program_.entry_function()) {
                    entry_func = &func;
                }
            }
        }
    }

    if (!main_module)
        throw std::runtime_error("Entry module \"" + program_.entry_module() + "\" not found");

    // Linear memory runtime preamble
    if (base_modules_.count("std_memory")) {
        emit_line("// Ball linear memory runtime");
        emit_line("static uint8_t _ball_memory[65536];");
        emit_line("static size_t _ball_heap_ptr = 0;");
        emit_line("static size_t _ball_stack_ptr = 65536;");
        emit_line("static std::vector<size_t> _ball_stack_frames;");
        emit_newline();
    }

    // Wrap user declarations in an anonymous namespace so user function
    // names can't collide with C stdlib names (`abs`, `pow`, etc.) that
    // are pulled in by `<cmath>` / `<cstdlib>`. `main()` stays at global
    // scope and picks up these names via unqualified lookup.
    emit_line("namespace {");
    emit_newline();

    // Forward declarations
    emit_forward_decls(*main_module);

    // Partition functions
    std::unordered_map<std::string, std::vector<const ball::v1::FunctionDefinition*>> class_methods;
    std::vector<const ball::v1::FunctionDefinition*> standalone;
    std::vector<const ball::v1::FunctionDefinition*> top_level_vars;

    for (const auto& func : main_module->functions()) {
        if (func.is_base()) continue;
        if (entry_func && func.name() == program_.entry_function()) continue;

        auto meta = read_meta(func);
        auto kind = meta.count("kind") ? meta["kind"] : "function";

        if (kind == "method" || kind == "constructor" || kind == "static_field" || kind == "operator") {
            auto colon = func.name().find(':');
            std::string after = colon != std::string::npos ? func.name().substr(colon + 1) : func.name();
            auto dot = after.find('.');
            if (dot != std::string::npos) {
                std::string class_key = func.name().substr(0, (colon != std::string::npos ? colon + 1 : 0) + dot);
                class_methods[class_key].push_back(&func);
                continue;
            }
        }
        if (kind == "top_level_variable") {
            top_level_vars.push_back(&func);
            continue;
        }
        standalone.push_back(&func);
    }

    // Enums
    for (const auto& ed : main_module->enums()) {
        emit_enum(ed);
    }

    // Structs/classes — skip types whose sanitized name collides with
    // runtime-provided types (e.g., the preamble already defines
    // BallException, File, JsonEncoder, JsonDecoder, Map_from, etc.).
    static const std::set<std::string> runtime_types = {
        "BallException", "File", "JsonEncoder", "JsonDecoder",
        "Map_from", "FunctionType",
        "_FlowSignal", "_Scope", "BallRuntimeError", "BallFuture",
        "BallGenerator", "_ExitSignal", "BallModuleHandler",
        "StdModuleHandler",
    };
    for (const auto& td : main_module->type_defs()) {
        if (!td.has_descriptor_()) continue;
        if (runtime_types.count(sanitize_name(td.name())) > 0) continue;
        auto it = class_methods.find(td.name());
        auto methods = it != class_methods.end() ? it->second : std::vector<const ball::v1::FunctionDefinition*>{};
        emit_struct(td, methods);
    }

    // Top-level variables
    for (const auto* func : top_level_vars) {
        emit_top_level_var(*func);
    }
    if (!top_level_vars.empty()) emit_newline();

    // Standalone functions
    for (const auto* func : standalone) {
        emit_function(*func);
    }

    // Close the anonymous namespace opened before emit_forward_decls.
    emit_line("} // namespace");
    emit_newline();

    // Main entry point (global scope — has access to everything in the
    // anonymous namespace via unqualified lookup).
    if (entry_func) {
        emit_main(*entry_func);
    }

    return out_.str();
}

std::string CppCompiler::compile_module(const std::string& module_name) {
    out_.str("");
    out_.clear();

    const ball::v1::Module* module = nullptr;
    for (const auto& mod : program_.modules()) {
        if (mod.name() == module_name) {
            module = &mod;
            break;
        }
    }
    if (!module)
        throw std::runtime_error("Module \"" + module_name + "\" not found");

    emit_line("// Generated by ball compiler (C++ target)");
    emit_line("// Module: " + module_name);
    emit_newline();
    emit_includes();

    // All functions in this module
    for (const auto& func : module->functions()) {
        if (func.is_base()) continue;
        auto meta = read_meta(func);
        auto kind = meta.count("kind") ? meta["kind"] : "function";
        if (kind == "top_level_variable") {
            emit_top_level_var(func);
        } else {
            emit_function(func);
        }
    }

    return out_.str();
}

// ================================================================
// std_collections compilation
// ================================================================

std::string CppCompiler::compile_collections_call(const std::string& fn,
                                                   const ball::v1::FunctionCall& call) {
    // List operations
    if (fn == "list_push") {
        auto list = get_message_field(call, "list");
        auto val = get_message_field(call, "value");
        return "[](auto v, auto e){v.push_back(e);return v;}(" + list + "," + val + ")";
    }
    if (fn == "list_pop") {
        auto list = get_message_field(call, "list");
        return "[](auto v){v.pop_back();return v;}(" + list + ")";
    }
    if (fn == "list_get") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        return list + ".at(" + idx + ")";
    }
    if (fn == "list_set") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        auto val = get_message_field(call, "value");
        return "[](auto v, auto i, auto e){v[i]=e;return v;}(" + list + "," + idx + "," + val + ")";
    }
    if (fn == "list_length") {
        auto list = get_message_field(call, "list");
        return "static_cast<int64_t>(" + list + ".size())";
    }
    if (fn == "list_is_empty") {
        auto list = get_message_field(call, "list");
        return list + ".empty()";
    }
    if (fn == "list_first") {
        return get_message_field(call, "list") + ".front()";
    }
    if (fn == "list_last") {
        return get_message_field(call, "list") + ".back()";
    }
    if (fn == "list_contains") {
        auto list = get_message_field(call, "list");
        auto val = get_message_field(call, "value");
        return "(std::find(" + list + ".begin()," + list + ".end()," + val + ")!=" + list + ".end())";
    }
    if (fn == "list_index_of") {
        auto list = get_message_field(call, "list");
        auto val = get_message_field(call, "value");
        return "[](const auto& v, const auto& e){auto it=std::find(v.begin(),v.end(),e);"
               "return it!=v.end()?static_cast<int64_t>(it-v.begin()):static_cast<int64_t>(-1);"
               "}(" + list + "," + val + ")";
    }
    if (fn == "list_reverse") {
        auto list = get_message_field(call, "list");
        return "[](auto v){std::reverse(v.begin(),v.end());return v;}(" + list + ")";
    }
    if (fn == "list_insert") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        auto val = get_message_field(call, "value");
        return "[](auto v, int64_t i, auto e){v.insert(v.begin()+i,e);return v;}("
               + list + "," + idx + "," + val + ")";
    }
    if (fn == "list_remove_at") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        return "[](auto v, int64_t i){v.erase(v.begin()+i);return v;}(" + list + "," + idx + ")";
    }
    if (fn == "list_single") {
        return get_message_field(call, "list") + ".at(0)";
    }
    if (fn == "list_map") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& v, auto fn){decltype(v) r;for(const auto& e:v)r.push_back(fn(e));return r;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_filter") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& v, auto fn){decltype(v) r;for(const auto& e:v)if(std::any_cast<bool>(fn(e)))r.push_back(e);return r;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_reduce") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        auto initial = get_message_field(call, "initial");
        return "[](const auto& v, auto fn, auto init){"
               "auto acc=init;for(const auto& e:v){"
               "std::map<std::string,std::any> p;p[\"accumulator\"]=acc;p[\"element\"]=e;"
               "acc=fn(std::any(p));}return acc;}("
               + list + "," + callback + "," + initial + ")";
    }
    if (fn == "list_find") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& v, auto fn)->std::any{"
               "for(const auto& e:v)if(std::any_cast<bool>(fn(e)))return e;return std::any{};}("
               + list + "," + callback + ")";
    }
    if (fn == "list_any") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& v, auto fn){"
               "for(const auto& e:v)if(std::any_cast<bool>(fn(e)))return true;return false;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_all") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& v, auto fn){"
               "for(const auto& e:v)if(!std::any_cast<bool>(fn(e)))return false;return true;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_none") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& v, auto fn){"
               "for(const auto& e:v)if(std::any_cast<bool>(fn(e)))return false;return true;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_sort") {
        auto list = get_message_field(call, "list");
        return "[](auto v){std::sort(v.begin(),v.end());return v;}(" + list + ")";
    }
    if (fn == "list_sort_by") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](auto v, auto fn){std::sort(v.begin(),v.end(),"
               "[&](const auto& a, const auto& b){"
               "return std::any_cast<bool>(fn(std::any(std::map<std::string,std::any>"
               "{{\"left\",a},{\"right\",b}})));});return v;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_concat") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](auto a,const auto& b){a.insert(a.end(),b.begin(),b.end());return a;}("
               + left + "," + right + ")";
    }
    if (fn == "list_slice") {
        auto list = get_message_field(call, "list");
        auto start = get_message_field(call, "start");
        auto end = get_message_field(call, "end");
        if (end.empty()) {
            return "[](const auto& v, int64_t s){return decltype(v)(v.begin()+s,v.end());}("
                   + list + "," + start + ")";
        }
        return "[](const auto& v, int64_t s, int64_t e){return decltype(v)(v.begin()+s,v.begin()+e);}("
               + list + "," + start + "," + end + ")";
    }
    if (fn == "string_join") {
        auto list = get_message_field(call, "list");
        auto sep = get_message_field(call, "separator");
        return "[](const auto& v, const std::string& s){"
               "std::string r;for(size_t i=0;i<v.size();i++){"
               "if(i>0)r+=s;r+=v[i];}return r;}(" + list + "," + sep + ")";
    }
    if (fn == "list_take") {
        auto list = get_message_field(call, "list");
        auto count = get_message_field(call, "count");
        return "[](const auto& v, int64_t n){return decltype(v)(v.begin(),v.begin()+std::min(n,static_cast<int64_t>(v.size())));}("
               + list + "," + count + ")";
    }
    if (fn == "list_drop") {
        auto list = get_message_field(call, "list");
        auto count = get_message_field(call, "count");
        return "[](const auto& v, int64_t n){return decltype(v)(v.begin()+std::min(n,static_cast<int64_t>(v.size())),v.end());}("
               + list + "," + count + ")";
    }
    if (fn == "list_flat_map") {
        auto list = get_message_field(call, "list");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& v, auto fn){decltype(v) r;"
               "for(const auto& e:v){auto sub=std::any_cast<decltype(v)>(fn(e));"
               "r.insert(r.end(),sub.begin(),sub.end());}return r;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_zip") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](const auto& a, const auto& b){"
               "std::vector<std::any> r;auto n=std::min(a.size(),b.size());"
               "for(size_t i=0;i<n;i++){std::map<std::string,std::any> p;"
               "p[\"first\"]=a[i];p[\"second\"]=b[i];r.push_back(std::any(p));}"
               "return r;}(" + left + "," + right + ")";
    }

    // Map operations
    if (fn == "map_create") return "std::map<std::string,std::any>{}";
    if (fn == "map_get") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        return map + "[" + key + "]";
    }
    if (fn == "map_set") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        auto val = get_message_field(call, "value");
        return "[](auto m, const auto& k, auto v){m[k]=v;return m;}(" + map + "," + key + "," + val + ")";
    }
    if (fn == "map_delete") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        return "[](auto m, const auto& k){m.erase(k);return m;}(" + map + "," + key + ")";
    }
    if (fn == "map_contains_key") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        return "(" + map + ".count(" + key + ")>0)";
    }
    if (fn == "map_is_empty") {
        return get_message_field(call, "map") + ".empty()";
    }
    if (fn == "map_length") {
        return "static_cast<int64_t>(" + get_message_field(call, "map") + ".size())";
    }
    if (fn == "map_keys") {
        auto map = get_message_field(call, "map");
        return "[](const auto& m){std::vector<std::any> r;"
               "for(const auto& [k,v]:m)r.push_back(std::any(k));return r;}(" + map + ")";
    }
    if (fn == "map_values") {
        auto map = get_message_field(call, "map");
        return "[](const auto& m){std::vector<std::any> r;"
               "for(const auto& [k,v]:m)r.push_back(v);return r;}(" + map + ")";
    }
    if (fn == "map_entries") {
        auto map = get_message_field(call, "map");
        return "[](const auto& m){std::vector<std::any> r;"
               "for(const auto& [k,v]:m){std::map<std::string,std::any> e;"
               "e[\"key\"]=std::any(k);e[\"value\"]=v;r.push_back(std::any(e));}return r;}(" + map + ")";
    }
    if (fn == "map_from_entries") {
        auto entries = get_message_field(call, "entries");
        return "[](const auto& v){std::map<std::string,std::any> r;"
               "for(const auto& e:v){auto m=std::any_cast<std::map<std::string,std::any>>(e);"
               "r[std::any_cast<std::string>(m[\"key\"])]=m[\"value\"];}return r;}(" + entries + ")";
    }
    if (fn == "map_merge") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](auto a, const auto& b){for(const auto& [k,v]:b)a[k]=v;return a;}("
               + left + "," + right + ")";
    }
    if (fn == "map_map") {
        auto map = get_message_field(call, "map");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& m, auto fn){std::map<std::string,std::any> r;"
               "for(const auto& [k,v]:m){std::map<std::string,std::any> e;"
               "e[\"key\"]=std::any(k);e[\"value\"]=v;"
               "auto res=std::any_cast<std::map<std::string,std::any>>(fn(std::any(e)));"
               "r[std::any_cast<std::string>(res[\"key\"])]=res[\"value\"];}return r;}("
               + map + "," + callback + ")";
    }
    if (fn == "map_filter") {
        auto map = get_message_field(call, "map");
        auto callback = get_message_field(call, "callback");
        return "[](const auto& m, auto fn){std::map<std::string,std::any> r;"
               "for(const auto& [k,v]:m){std::map<std::string,std::any> e;"
               "e[\"key\"]=std::any(k);e[\"value\"]=v;"
               "if(std::any_cast<bool>(fn(std::any(e))))r[k]=v;}return r;}("
               + map + "," + callback + ")";
    }

    // Set operations
    if (fn == "set_create") return "std::vector<std::any>{}";
    if (fn == "set_add") {
        auto set = get_message_field(call, "set");
        auto val = get_message_field(call, "value");
        return "[](auto v, auto e){for(const auto& x:v)if(x.type()==e.type()){"
               "if(x.type()==typeid(int64_t)&&std::any_cast<int64_t>(x)==std::any_cast<int64_t>(e))return v;"
               "if(x.type()==typeid(std::string)&&std::any_cast<std::string>(x)==std::any_cast<std::string>(e))return v;"
               "}v.push_back(e);return v;}(" + set + "," + val + ")";
    }
    if (fn == "set_remove") {
        auto set = get_message_field(call, "set");
        auto val = get_message_field(call, "value");
        return "[](auto v, const auto& e){v.erase(std::remove_if(v.begin(),v.end(),"
               "[&](const auto& x){if(x.type()!=e.type())return false;"
               "if(x.type()==typeid(int64_t))return std::any_cast<int64_t>(x)==std::any_cast<int64_t>(e);"
               "if(x.type()==typeid(std::string))return std::any_cast<std::string>(x)==std::any_cast<std::string>(e);"
               "return false;}),v.end());return v;}(" + set + "," + val + ")";
    }
    if (fn == "set_contains") {
        auto set = get_message_field(call, "set");
        auto val = get_message_field(call, "value");
        return "[](const auto& v, const auto& e){"
               "for(const auto& x:v)if(x.type()==e.type()){"
               "if(x.type()==typeid(int64_t)&&std::any_cast<int64_t>(x)==std::any_cast<int64_t>(e))return true;"
               "if(x.type()==typeid(std::string)&&std::any_cast<std::string>(x)==std::any_cast<std::string>(e))return true;"
               "}return false;}(" + set + "," + val + ")";
    }
    if (fn == "set_length") {
        return "static_cast<int64_t>(" + get_message_field(call, "set") + ".size())";
    }
    if (fn == "set_is_empty") {
        return get_message_field(call, "set") + ".empty()";
    }
    if (fn == "set_to_list") {
        return get_message_field(call, "set");
    }
    if (fn == "set_union") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](auto a, const auto& b){"
               "for(const auto& e:b){bool found=false;"
               "for(const auto& x:a)if(x.type()==e.type()){"
               "if(x.type()==typeid(int64_t)&&std::any_cast<int64_t>(x)==std::any_cast<int64_t>(e)){found=true;break;}"
               "if(x.type()==typeid(std::string)&&std::any_cast<std::string>(x)==std::any_cast<std::string>(e)){found=true;break;}"
               "}if(!found)a.push_back(e);}return a;}("
               + left + "," + right + ")";
    }
    if (fn == "set_intersection") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](const auto& a, const auto& b){std::vector<std::any> r;"
               "for(const auto& e:a){for(const auto& x:b)if(x.type()==e.type()){"
               "if(x.type()==typeid(int64_t)&&std::any_cast<int64_t>(x)==std::any_cast<int64_t>(e)){r.push_back(e);break;}"
               "if(x.type()==typeid(std::string)&&std::any_cast<std::string>(x)==std::any_cast<std::string>(e)){r.push_back(e);break;}"
               "}}return r;}("
               + left + "," + right + ")";
    }
    if (fn == "set_difference") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](const auto& a, const auto& b){std::vector<std::any> r;"
               "for(const auto& e:a){bool found=false;"
               "for(const auto& x:b)if(x.type()==e.type()){"
               "if(x.type()==typeid(int64_t)&&std::any_cast<int64_t>(x)==std::any_cast<int64_t>(e)){found=true;break;}"
               "if(x.type()==typeid(std::string)&&std::any_cast<std::string>(x)==std::any_cast<std::string>(e)){found=true;break;}"
               "}if(!found)r.push_back(e);}return r;}("
               + left + "," + right + ")";
    }

    return "/* std_collections." + fn + " */ 0";
}

// ================================================================
// std_io compilation
// ================================================================

std::string CppCompiler::compile_io_call(const std::string& fn,
                                          const ball::v1::FunctionCall& call) {
    if (fn == "print_error") {
        auto msg = get_message_field(call, "message");
        return "(std::cerr << " + msg + " << std::endl, 0)";
    }
    if (fn == "read_line") {
        return "[]{std::string l;std::getline(std::cin,l);return l;}()";
    }
    if (fn == "exit") {
        auto code = get_message_field(call, "code");
        return "(std::exit(" + (code.empty() ? "0" : code) + "), 0)";
    }
    if (fn == "panic") {
        auto msg = get_message_field(call, "message");
        return "(std::cerr << " + msg + " << std::endl, std::exit(1), 0)";
    }
    if (fn == "sleep_ms") {
        auto ms = get_message_field(call, "milliseconds");
        return "(std::this_thread::sleep_for(std::chrono::milliseconds(" + ms + ")), 0)";
    }
    if (fn == "timestamp_ms") {
        return "static_cast<int64_t>(std::chrono::duration_cast<std::chrono::milliseconds>("
               "std::chrono::system_clock::now().time_since_epoch()).count())";
    }
    if (fn == "random_int") {
        auto min = get_message_field(call, "min");
        auto max = get_message_field(call, "max");
        return "[](int64_t a, int64_t b){"
               "static std::mt19937_64 r(std::random_device{}());"
               "return std::uniform_int_distribution<int64_t>(a,b)(r);"
               "}(" + min + "," + max + ")";
    }
    if (fn == "random_double") {
        return "[]{static std::mt19937_64 r(std::random_device{}());"
               "return std::uniform_real_distribution<double>(0.0,1.0)(r);}()";
    }
    if (fn == "env_get") {
        auto name = get_message_field(call, "name");
        return "[](const char* n){auto v=std::getenv(n);return v?std::string(v):std::string();}("
               + name + ".c_str())";
    }
    if (fn == "args_get") {
        // Command-line args not available at compile time; return empty vector
        return "std::vector<std::any>{}";
    }

    return "/* std_io." + fn + " */ 0";
}

std::string CppCompiler::compile_cpp_std_call(const std::string& fn,
                                               const ball::v1::FunctionCall& call) {
    // Pointer operations
    if (fn == "deref") {
        auto ptr = get_message_field(call, "pointer");
        return "(*" + ptr + ")";
    }
    if (fn == "address_of") {
        auto val = get_message_field(call, "value");
        return "(&" + val + ")";
    }
    if (fn == "arrow") {
        auto ptr = get_message_field(call, "pointer");
        auto member = get_string_field(call, "member");
        return ptr + "->" + member;
    }
    if (fn == "ptr_cast") {
        auto val = get_message_field(call, "value");
        auto target = get_string_field(call, "target_type");
        auto kind = get_string_field(call, "cast_kind");
        if (kind == "static") return "static_cast<" + target + ">(" + val + ")";
        if (kind == "dynamic") return "dynamic_cast<" + target + ">(" + val + ")";
        if (kind == "reinterpret") return "reinterpret_cast<" + target + ">(" + val + ")";
        if (kind == "const") return "const_cast<" + target + ">(" + val + ")";
        return "(" + target + ")(" + val + ")";
    }
    // new / delete
    if (fn == "cpp_new") {
        auto type = get_string_field(call, "type");
        return "new " + type + "()";
    }
    if (fn == "cpp_delete") {
        auto ptr = get_message_field(call, "pointer");
        return "(delete " + ptr + ", (void)0)";
    }
    // sizeof / alignof
    if (fn == "cpp_sizeof") {
        auto t = get_string_field(call, "type_or_expr");
        return "sizeof(" + t + ")";
    }
    if (fn == "cpp_alignof") {
        auto t = get_string_field(call, "type");
        return "alignof(" + t + ")";
    }
    // Move / forward
    if (fn == "cpp_move") {
        auto val = get_message_field(call, "pointer");
        return "std::move(" + val + ")";
    }
    if (fn == "cpp_forward") {
        auto val = get_message_field(call, "pointer");
        return "std::forward<decltype(" + val + ")>(" + val + ")";
    }
    // Smart pointers
    if (fn == "cpp_make_unique") {
        auto type = get_string_field(call, "type");
        return "std::make_unique<" + type + ">()";
    }
    if (fn == "cpp_make_shared") {
        auto type = get_string_field(call, "type");
        return "std::make_shared<" + type + ">()";
    }
    if (fn == "cpp_unique_ptr_get") {
        auto ptr = get_message_field(call, "pointer");
        return ptr + ".get()";
    }
    if (fn == "cpp_shared_ptr_get") {
        auto ptr = get_message_field(call, "pointer");
        return ptr + ".get()";
    }
    if (fn == "cpp_shared_ptr_use_count") {
        auto ptr = get_message_field(call, "pointer");
        return ptr + ".use_count()";
    }
    // Type deduction
    if (fn == "cpp_decltype") {
        auto val = get_message_field(call, "pointer");
        return "decltype(" + val + ")";
    }
    if (fn == "cpp_auto") {
        return "auto";
    }
    // Initializer list
    if (fn == "init_list") {
        // Extract elements and emit {a, b, c}
        std::string result = "{";
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            bool first = true;
            for (const auto& f : call.input().message_creation().fields()) {
                if (!first) result += ", ";
                result += compile_expr(f.value());
                first = false;
            }
        }
        result += "}";
        return result;
    }
    // static_assert
    if (fn == "static_assert") {
        auto cond = get_message_field(call, "condition");
        auto msg = get_string_field(call, "message");
        return "static_assert(" + cond + ", \"" + msg + "\")";
    }
    // Namespace
    if (fn == "namespace") {
        auto name = get_string_field(call, "name");
        auto body = get_message_field(call, "body");
        return "namespace " + name + " { " + body + " }";
    }
    // nullptr
    if (fn == "nullptr") {
        return "nullptr";
    }
    // Preprocessor directives
    if (fn == "cpp_ifdef") {
        auto symbol = get_string_field(call, "symbol");
        auto thenBody = get_message_field(call, "then_body");
        auto elseBody = get_message_field(call, "else_body");
        std::string result = "\n#ifdef " + symbol + "\n" + thenBody;
        if (!elseBody.empty()) result += "\n#else\n" + elseBody;
        result += "\n#endif\n";
        return result;
    }
    if (fn == "cpp_defined") {
        auto val = get_message_field(call, "pointer");
        return "defined(" + val + ")";
    }
    // RAII / scope exit
    if (fn == "cpp_scope_exit") {
        auto cleanup = get_message_field(call, "cleanup");
        return "struct _ScopeExit { ~_ScopeExit() { " + cleanup + "; } } _scopeExit";
    }
    if (fn == "cpp_destructor") {
        auto className = get_string_field(call, "class_name");
        auto body = get_message_field(call, "body");
        return "~" + className + "() { " + body + " }";
    }

    return "/* cpp_std." + fn + " */";
}

std::string CppCompiler::compile_convert_call(const std::string& fn,
                                               const ball::v1::FunctionCall& call) {
    if (fn == "json_encode") {
        auto val = field_expr(call, "value");
        return CppExpr::static_call("nlohmann::json", {val}).call("dump").str();
    }
    if (fn == "json_decode") {
        auto src = field_expr(call, "source");
        return CppExpr::ref("nlohmann::json").scope("parse")
            .call(std::vector<CppExpr>{src}).str();
    }
    if (fn == "utf8_encode") {
        auto src = field_expr(call, "source");
        return CppExpr::template_call("std::vector", "uint8_t",
            {src.dot("begin").call(), src.dot("end").call()}).str();
    }
    if (fn == "utf8_decode") {
        auto bytes = field_expr(call, "bytes");
        return CppExpr::static_call("std::string",
            {bytes.dot("begin").call(), bytes.dot("end").call()}).str();
    }
    if (fn == "base64_encode") {
        auto src = field_expr(call, "source");
        return "[](const std::vector<uint8_t>& b){"
               "static const char* a=\"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";"
               "std::string o;o.reserve(((b.size()+2)/3)*4);"
               "size_t i=0;for(;i+3<=b.size();i+=3){"
               "o+=a[(b[i]>>2)&0x3f];"
               "o+=a[((b[i]&0x3)<<4)|((b[i+1]>>4)&0xf)];"
               "o+=a[((b[i+1]&0xf)<<2)|((b[i+2]>>6)&0x3)];"
               "o+=a[b[i+2]&0x3f];}"
               "if(i<b.size()){o+=a[(b[i]>>2)&0x3f];"
               "if(i+1==b.size()){o+=a[(b[i]&0x3)<<4];o+=\"==\";}"
               "else{o+=a[((b[i]&0x3)<<4)|((b[i+1]>>4)&0xf)];"
               "o+=a[(b[i+1]&0xf)<<2];o+='=';}}"
               "return o;}(" + src.str() + ")";
    }
    if (fn == "base64_decode") {
        auto src = field_expr(call, "source");
        return "[](const std::string& s){"
               "static int t[256];static bool init=false;"
               "if(!init){for(int i=0;i<256;i++)t[i]=-1;"
               "const char* a=\"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";"
               "for(int i=0;i<64;i++)t[(unsigned char)a[i]]=i;init=true;}"
               "std::vector<uint8_t> o;o.reserve((s.size()/4)*3);"
               "int v=0,bits=0;"
               "for(char c:s){"
               "if(c=='='||c=='\\n'||c=='\\r'||c==' '||c=='\\t')continue;"
               "int d=t[(unsigned char)c];if(d<0)continue;"
               "v=(v<<6)|d;bits+=6;"
               "if(bits>=8){bits-=8;o.push_back((uint8_t)((v>>bits)&0xff));}}"
               "return o;}(" + src.str() + ")";
    }
    return "/* std_convert." + fn + " */";
}

std::string CppCompiler::compile_fs_call(const std::string& fn,
                                          const ball::v1::FunctionCall& call) {
    if (fn == "file_read") {
        auto path = field_expr(call, "path");
        return CppExpr::iife("", "const std::string& p",
            "std::ifstream f(p);return std::string((std::istreambuf_iterator<char>(f)),"
            "std::istreambuf_iterator<char>());", {path}).str();
    }
    if (fn == "file_write") {
        auto path = field_expr(call, "path");
        auto content = field_expr(call, "content");
        return CppExpr::iife("", "const std::string& p, const std::string& c",
            "std::ofstream f(p);f<<c;", {path, content}).paren().str();
    }
    if (fn == "file_exists") {
        auto path = field_expr(call, "path");
        return CppExpr::ref("std::filesystem").scope("exists")
            .call(std::vector<CppExpr>{path}).str();
    }
    if (fn == "file_delete") {
        auto path = field_expr(call, "path");
        return CppExpr::ref("std::filesystem").scope("remove")
            .call(std::vector<CppExpr>{path}).str();
    }
    if (fn == "dir_list") {
        auto path = field_expr(call, "path");
        return CppExpr::iife("", "const std::string& p",
            "std::vector<std::any> r;for(auto& e:std::filesystem::directory_iterator(p))"
            "r.push_back(e.path().string());return r;", {path}).str();
    }
    if (fn == "dir_create") {
        auto path = field_expr(call, "path");
        return CppExpr::ref("std::filesystem").scope("create_directories")
            .call(std::vector<CppExpr>{path}).str();
    }
    if (fn == "dir_exists") {
        auto path = field_expr(call, "path");
        return CppExpr::ref("std::filesystem").scope("is_directory")
            .call(std::vector<CppExpr>{path}).str();
    }
    return "/* std_fs." + fn + " */";
}

std::string CppCompiler::compile_time_call(const std::string& fn,
                                            const ball::v1::FunctionCall& call) {
    if (fn == "now" || fn == "timestamp_ms") {
        return CppExpr::template_call("static_cast", "int64_t", {
            CppExpr::ref("std::chrono")
                .scope("duration_cast<std::chrono::milliseconds>")
                .call(std::vector<CppExpr>{CppExpr::ref("std::chrono::system_clock").scope("now").call()
                    .dot("time_since_epoch").call()})
                .dot("count").call()
        }).str();
    }
    if (fn == "now_micros") {
        return CppExpr::template_call("static_cast", "int64_t", {
            CppExpr::ref("std::chrono")
                .scope("duration_cast<std::chrono::microseconds>")
                .call(std::vector<CppExpr>{CppExpr::ref("std::chrono::system_clock").scope("now").call()
                    .dot("time_since_epoch").call()})
                .dot("count").call()
        }).str();
    }
    if (fn == "duration_add") {
        return (field_expr(call, "left") + field_expr(call, "right")).str();
    }
    if (fn == "duration_subtract") {
        return (field_expr(call, "left") - field_expr(call, "right")).str();
    }
    return "/* std_time." + fn + " */";
}

std::string CppCompiler::compile_concurrency_call(const std::string& fn,
                                                    const ball::v1::FunctionCall& call) {
    // ── Thread ─────────────────────────────────────────────────────
    if (fn == "thread_spawn") {
        auto body = get_message_field(call, "body");
        if (body.empty()) body = "nullptr";
        auto name = get_string_field(call, "name");
        std::string tvar = name.empty() ? "_thread" : "t_" + sanitize_name(name);
        return "std::thread " + tvar + "(" + body + ")";
    }
    if (fn == "thread_join") {
        auto handle = get_message_field(call, "handle");
        if (handle.empty()) handle = "t";
        return handle + ".join()";
    }
    if (fn == "thread_detach") {
        auto handle = get_message_field(call, "handle");
        if (handle.empty()) handle = "t";
        return handle + ".detach()";
    }

    // ── Mutex ──────────────────────────────────────────────────────
    if (fn == "mutex_create") {
        auto name = get_string_field(call, "name");
        std::string mvar = name.empty() ? "_mtx" : sanitize_name(name);
        return "std::mutex " + mvar;
    }
    if (fn == "mutex_lock") {
        auto mtx = get_message_field(call, "mutex");
        if (mtx.empty()) mtx = "mtx";
        return mtx + ".lock()";
    }
    if (fn == "mutex_unlock") {
        auto mtx = get_message_field(call, "mutex");
        if (mtx.empty()) mtx = "mtx";
        return mtx + ".unlock()";
    }
    if (fn == "scoped_lock") {
        auto mtx = get_message_field(call, "mutex");
        if (mtx.empty()) mtx = "mtx";
        auto body = get_message_field(call, "body");
        return "{ std::lock_guard<std::mutex> _lg(" + mtx + "); " + body + "; }";
    }
    if (fn == "unique_lock") {
        auto mtx = get_message_field(call, "mutex");
        if (mtx.empty()) mtx = "mtx";
        auto name = get_string_field(call, "name");
        std::string lvar = name.empty() ? "_lk" : sanitize_name(name);
        return "std::unique_lock<std::mutex> " + lvar + "(" + mtx + ")";
    }

    // ── Atomic ─────────────────────────────────────────────────────
    if (fn == "atomic_load") {
        auto val = get_message_field(call, "value");
        if (val.empty()) val = "x";
        return val + ".load()";
    }
    if (fn == "atomic_store") {
        auto val = get_message_field(call, "value");
        auto newval = get_message_field(call, "new_value");
        if (val.empty()) val = "x";
        if (newval.empty()) newval = "v";
        return val + ".store(" + newval + ")";
    }
    if (fn == "atomic_compare_exchange") {
        auto val = get_message_field(call, "value");
        auto expected = get_message_field(call, "expected");
        auto desired = get_message_field(call, "desired");
        if (val.empty()) val = "x";
        if (expected.empty()) expected = "e";
        if (desired.empty()) desired = "d";
        return val + ".compare_exchange_strong(" + expected + ", " + desired + ")";
    }
    if (fn == "atomic_fetch_add") {
        auto val = get_message_field(call, "value");
        auto delta = get_message_field(call, "delta");
        if (val.empty()) val = "x";
        if (delta.empty()) delta = "1";
        return val + ".fetch_add(" + delta + ")";
    }

    return "/* std_concurrency." + fn + " */";
}

}  // namespace ball
