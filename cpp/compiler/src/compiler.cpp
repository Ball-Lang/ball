// ball::CppCompiler — compiles a ball Program AST to C++ source code.

#include "compiler.h"

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
    if (ball_type == "bool") return "bool";
    if (ball_type == "List" || ball_type.find("List<") == 0) return "std::vector<std::any>";
    if (ball_type == "Map" || ball_type.find("Map<") == 0)
        return "std::unordered_map<std::string, std::any>";
    if (ball_type == "dynamic" || ball_type == "Object" || ball_type == "Object?")
        return "std::any";
    if (ball_type == "Function") return "std::function<std::any(std::any)>";
    if (ball_type == "Future" || ball_type.find("Future<") == 0) return "std::any /* future */";
    // User-defined type
    return sanitize_name(ball_type);
}

std::string CppCompiler::map_return_type(const ball::v1::FunctionDefinition& func) {
    if (func.output_type().empty()) return "void";
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
        "namespace", "operator", "default", "register", "explicit"
    };
    if (reserved.count(result)) result += "_";
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
            result += "\"";
            return "std::string(" + result + ")";
        }
        case ball::v1::Literal::kBoolValue:
            return lit.bool_value() ? "true" : "false";
        case ball::v1::Literal::kListValue: {
            std::string result = "std::vector<std::any>{";
            bool first = true;
            for (const auto& el : lit.list_value().elements()) {
                if (!first) result += ", ";
                result += "std::any(" + compile_expr(el) + ")";
                first = false;
            }
            result += "}";
            return result;
        }
        case ball::v1::Literal::kBytesValue:
            return "std::vector<uint8_t>{/* bytes */}";
        default:
            return "std::any{}";
    }
}

std::string CppCompiler::compile_reference(const ball::v1::Reference& ref) {
    return sanitize_name(ref.name());
}

std::string CppCompiler::compile_field_access(const ball::v1::FieldAccess& access) {
    auto obj = compile_expr(access.object());
    auto field = access.field();
    // Common virtual properties → C++ equivalents
    if (field == "length") return "static_cast<int64_t>(" + obj + ".size())";
    if (field == "isEmpty") return obj + ".empty()";
    if (field == "isNotEmpty") return "!" + obj + ".empty()";
    if (field == "first") return obj + ".front()";
    if (field == "last") return obj + ".back()";
    if (field == "runtimeType") return "std::string(typeid(" + obj + ").name())";
    return obj + "." + sanitize_name(field);
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
    // Named type → aggregate/constructor
    std::string type = sanitize_name(msg.type_name());
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
    std::string result = "[&](";
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
    result += ")";
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

std::string CppCompiler::compile_binary_op(const std::string& op,
                                            const ball::v1::FunctionCall& call) {
    auto left = get_message_field(call, "left");
    auto right = get_message_field(call, "right");
    return "(" + left + " " + op + " " + right + ")";
}

std::string CppCompiler::compile_unary_op(const std::string& op,
                                           const ball::v1::FunctionCall& call) {
    auto val = get_message_field(call, "value");
    return "(" + op + val + ")";
}

std::string CppCompiler::compile_call(const ball::v1::FunctionCall& call) {
    std::string mod = call.module();
    const auto& fn = call.function();

    // std / dart_std operations → native C++
    if (mod == "std" || mod == "dart_std") {
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
    if (fn == "modulo") return compile_binary_op("%", call);
    if (fn == "negate") return compile_unary_op("-", call);

    // ── Comparison ──
    if (fn == "equals") return compile_binary_op("==", call);
    if (fn == "not_equals") return compile_binary_op("!=", call);
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
        auto target = get_message_field(call, "target");
        auto val = get_message_field(call, "value");
        auto* op_expr = get_message_field_expr(call, "op");
        std::string op = "=";
        if (op_expr && op_expr->expr_case() == ball::v1::Expression::kLiteral)
            op = op_expr->literal().string_value();
        return "(" + target + " " + op + " " + val + ")";
    }

    // ── Print ──
    if (fn == "print") {
        auto msg = get_message_field(call, "message");
        if (msg.empty()) msg = call.has_input() ? compile_expr(call.input()) : "\"\"";
        return "std::cout << " + msg + " << std::endl";
    }

    // ── String operations ──
    if (fn == "concat" || fn == "string_concat") return compile_binary_op("+", call);
    if (fn == "to_string" || fn == "int_to_string" || fn == "double_to_string") {
        return "std::to_string(" + get_message_field(call, "value") + ")";
    }
    if (fn == "string_to_int") return "std::stoll(" + get_message_field(call, "value") + ")";
    if (fn == "string_to_double") return "std::stod(" + get_message_field(call, "value") + ")";
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
        if (!else_val.empty()) return "(" + cond + " ? " + then + " : " + else_val + ")";
        return "[&](){if (" + cond + ") {return " + then + ";} return decltype(" + then + "){};}()";
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
    if (fn == "break") return "break";
    if (fn == "continue") return "continue";

    // ── Index ──
    if (fn == "index") {
        auto target = get_message_field(call, "target");
        auto idx = get_message_field(call, "index");
        return target + "[" + idx + "]";
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
    if (fn == "is") return "/* is check */ true";
    if (fn == "is_not") return "/* is_not check */ false";
    if (fn == "as") return get_message_field(call, "value");
    if (fn == "null_coalesce") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "(" + left + " ? " + left + " : " + right + ")";
    }

    // ── Cascade / spread ──
    if (fn == "cascade") return get_message_field(call, "target");
    if (fn == "spread" || fn == "null_spread") return get_message_field(call, "value");

    // ── Exception ──
    if (fn == "throw") return "throw std::runtime_error(" + get_message_field(call, "value") + ")";
    if (fn == "assert") {
        auto cond = get_message_field(call, "condition");
        return "assert(" + cond + ")";
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

    // ── Try/catch ──
    if (fn == "try") {
        return "[&](){\n" + indent_str() + "    try {\n" +
               indent_str() + "        return " + get_message_field(call, "body") + ";\n" +
               indent_str() + "    } catch (const std::exception& e) {\n" +
               indent_str() + "        return decltype(" + get_message_field(call, "body") + "){};\n" +
               indent_str() + "    }\n" + indent_str() + "}()";
    }

    // Default: unknown std call → comment marker
    return "/* std." + fn + " */ 0";
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
        auto expr_str = compile_expr(stmt.expression());
        // Special handling for return in statement context
        if (stmt.expression().expr_case() == ball::v1::Expression::kCall) {
            const auto& call = stmt.expression().call();
            if ((call.module() == "std" || call.module() == "dart_std") &&
                call.function() == "return") {
                auto val = get_message_field(call, "value");
                emit_line("return " + val + ";");
                return;
            }
            if ((call.module() == "std" || call.module() == "dart_std") &&
                call.function() == "if") {
                // Emit if as a statement
                auto cond = get_message_field(call, "condition");
                emit_line("if (" + cond + ") {");
                indent_++;
                auto* then_expr = get_message_field_expr(call, "then");
                if (then_expr) {
                    if (then_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : then_expr->block().statements()) {
                            compile_statement(s);
                        }
                        if (then_expr->block().has_result()) {
                            emit_line(compile_expr(then_expr->block().result()) + ";");
                        }
                    } else {
                        emit_line(compile_expr(*then_expr) + ";");
                    }
                }
                indent_--;
                auto* else_expr = get_message_field_expr(call, "else");
                if (else_expr) {
                    emit_line("} else {");
                    indent_++;
                    if (else_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : else_expr->block().statements()) {
                            compile_statement(s);
                        }
                        if (else_expr->block().has_result()) {
                            emit_line(compile_expr(else_expr->block().result()) + ";");
                        }
                    } else {
                        emit_line(compile_expr(*else_expr) + ";");
                    }
                    indent_--;
                }
                emit_line("}");
                return;
            }
            if ((call.module() == "std" || call.module() == "dart_std") &&
                call.function() == "for") {
                auto init = get_message_field(call, "init");
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
                        emit_line(compile_expr(*body_expr) + ";");
                    }
                }
                indent_--;
                emit_line("}");
                return;
            }
            if ((call.module() == "std" || call.module() == "dart_std") &&
                call.function() == "for_in") {
                auto* var_expr = get_message_field_expr(call, "variable");
                std::string var_name = "item";
                if (var_expr && var_expr->expr_case() == ball::v1::Expression::kLiteral)
                    var_name = var_expr->literal().string_value();
                auto iter = get_message_field(call, "iterable");
                emit_line("for (auto& " + sanitize_name(var_name) + " : " + iter + ") {");
                indent_++;
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        emit_line(compile_expr(*body_expr) + ";");
                    }
                }
                indent_--;
                emit_line("}");
                return;
            }
            if ((call.module() == "std" || call.module() == "dart_std") &&
                call.function() == "while") {
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
                        emit_line(compile_expr(*body_expr) + ";");
                    }
                }
                indent_--;
                emit_line("}");
                return;
            }
            if ((call.module() == "std" || call.module() == "dart_std") &&
                call.function() == "do_while") {
                emit_line("do {");
                indent_++;
                auto* body_expr = get_message_field_expr(call, "body");
                if (body_expr) {
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                    } else {
                        emit_line(compile_expr(*body_expr) + ";");
                    }
                }
                indent_--;
                auto cond = get_message_field(call, "condition");
                emit_line("} while (" + cond + ");");
                return;
            }
            if ((call.module() == "std" || call.module() == "dart_std") &&
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
            if ((call.module() == "std" || call.module() == "dart_std") &&
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
                        emit_line(compile_expr(*body_expr) + ";");
                    }
                }
                indent_--;
                auto* catches_expr = get_message_field_expr(call, "catches");
                if (catches_expr) {
                    // Handle catch clauses from list
                    if (catches_expr->expr_case() == ball::v1::Expression::kLiteral &&
                        catches_expr->literal().value_case() == ball::v1::Literal::kListValue) {
                        for (const auto& cx : catches_expr->literal().list_value().elements()) {
                            if (cx.expr_case() != ball::v1::Expression::kMessageCreation) continue;
                            const ball::v1::Expression* catch_body = nullptr;
                            std::string exception_var = "e";
                            std::string exception_type;
                            for (const auto& f : cx.message_creation().fields()) {
                                if (f.name() == "body") catch_body = &f.value();
                                else if (f.name() == "variable" &&
                                         f.value().expr_case() == ball::v1::Expression::kLiteral)
                                    exception_var = f.value().literal().string_value();
                                else if (f.name() == "type" &&
                                         f.value().expr_case() == ball::v1::Expression::kLiteral)
                                    exception_type = f.value().literal().string_value();
                            }
                            emit_line("} catch (const std::exception& " + sanitize_name(exception_var) + ") {");
                            indent_++;
                            if (catch_body) {
                                if (catch_body->expr_case() == ball::v1::Expression::kBlock) {
                                    for (const auto& s : catch_body->block().statements()) {
                                        compile_statement(s);
                                    }
                                    if (catch_body->block().has_result()) {
                                        emit_line(compile_expr(catch_body->block().result()) + ";");
                                    }
                                } else {
                                    emit_line(compile_expr(*catch_body) + ";");
                                }
                            }
                            indent_--;
                        }
                    } else {
                        // Single catch expression
                        emit_line("} catch (const std::exception& e) {");
                        indent_++;
                        emit_line(compile_expr(*catches_expr) + ";");
                        indent_--;
                    }
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
    if (base_modules_.count("std_memory")) {
        emit_line("#include <cstring>");
    }
    if (base_modules_.count("std_io")) {
        emit_line("#include <cstdlib>");
        emit_line("#include <thread>");
        emit_line("#include <chrono>");
        emit_line("#include <random>");
    }
    emit_newline();
}

void CppCompiler::emit_forward_decls(const ball::v1::Module& module) {
    for (const auto& td : module.type_defs()) {
        if (!td.has_descriptor_()) continue;
        emit_line("struct " + sanitize_name(td.name()) + ";");
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
    emit_line("struct " + name + " {");
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
                    type = "std::any"; break;
            }
            emit_line(type + " " + sanitize_name(field.name()) + ";");
        }
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
        emit_indent();
        bool is_static = meta.count("is_static") && meta["is_static"] == "true";
        if (is_static) out_ << "static ";
        out_ << map_return_type(*func) << " " << sanitize_name(method_name) << "(";
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

    indent_--;
    emit_line("};");
    emit_newline();
}

void CppCompiler::emit_function(const ball::v1::FunctionDefinition& func) {
    auto return_type = map_return_type(func);
    auto name = sanitize_name(func.name());
    auto params = func.has_metadata() ? extract_params(func.metadata()) : std::vector<std::string>{};

    emit_indent();
    out_ << return_type << " " << name << "(";
    for (size_t i = 0; i < params.size(); i++) {
        if (i > 0) out_ << ", ";
        out_ << "auto " << sanitize_name(params[i]);
    }
    out_ << ") {\n";
    indent_++;

    if (func.has_body()) {
        if (func.body().expr_case() == ball::v1::Expression::kBlock) {
            for (const auto& s : func.body().block().statements())
                compile_statement(s);
            if (func.body().block().has_result() && return_type != "void") {
                emit_line("return " + compile_expr(func.body().block().result()) + ";");
            }
        } else {
            if (return_type != "void")
                emit_line("return " + compile_expr(func.body()) + ";");
            else
                emit_line(compile_expr(func.body()) + ";");
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
            emit_line(compile_expr(entry.body()) + ";");
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

        if (kind == "method" || kind == "constructor" || kind == "static_field") {
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

    // Structs/classes
    for (const auto& td : main_module->type_defs()) {
        if (!td.has_descriptor_()) continue;
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

    // Main entry point
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

}  // namespace ball
