// ball::CppCompiler — compiles a ball Program AST to C++ source code.

#include "compiler.h"
#include "ball_emit_runtime_embed.h"
#include "ball_dyn_embed.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <functional>
#include <optional>
#include <set>

namespace ball {

// ================================================================
// Construction
// ================================================================

CppCompiler::CppCompiler(const ball::v1::Program& program)
    : program_(program) {
    build_lookup_tables();
}

void CppCompiler::queue_split_definition(std::string definition) {
    if (!split_mode_) return;
    split_pending_.push_back(std::move(definition));
}

void CppCompiler::emit_namespace_open() {
    if (split_mode_) {
        emit_line(std::string("namespace ") + kSplitNamespace + " {");
    } else {
        emit_line("namespace {");
    }
}

void CppCompiler::emit_namespace_close() {
    if (split_mode_) {
        emit_line(std::string("} // namespace ") + kSplitNamespace);
    } else {
        emit_line("} // namespace");
    }
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
        for (const auto& td : mod.type_defs()) {
            if (td.has_descriptor_()) {
                types_[td.name()] = td.descriptor_();
                auto colon = td.name().find(':');
                if (colon != std::string::npos)
                    types_[td.name().substr(colon + 1)] = td.descriptor_();
            }
        }
        // Collect enum type names for field-access dispatch (Color.red → Color::red).
        for (const auto& ed : mod.enums()) {
            enum_names_.insert(sanitize_name(ed.name()));
        }
        // Also collect from typeDefs with kind=enum metadata.
        for (const auto& td : mod.type_defs()) {
            if (!td.has_metadata()) continue;
            auto tmeta = read_type_meta(td);
            if (tmeta.count("kind") && tmeta["kind"] == "enum") {
                enum_names_.insert(sanitize_name(td.name()));
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

        // OOP class metadata: collect class names, superclasses, methods.
        // Also treat mixins as class-like types for method dispatch.
        for (const auto& td : mod.type_defs()) {
            if (!td.has_metadata()) continue;
            auto tmeta = read_type_meta(td);
            std::string kind = tmeta.count("kind") ? tmeta["kind"] : "";
            if (kind == "class" || kind == "mixin") {
                std::string cls_name = td.name();
                auto bare_name = cls_name;
                auto colon_pos = bare_name.find(':');
                if (colon_pos != std::string::npos)
                    bare_name = bare_name.substr(colon_pos + 1);
                user_class_names_.insert(sanitize_name(bare_name));
                class_typedefs_[cls_name] = &td;
                if (tmeta.count("superclass"))
                    class_superclass_[cls_name] = tmeta["superclass"];
                else
                    class_superclass_[cls_name] = "";
                if (tmeta.count("is_abstract") && tmeta["is_abstract"] == "true")
                    class_abstract_methods_[cls_name]; // ensure entry exists
            }
        }

        // Map methods to their owning classes.
        for (const auto& func : mod.functions()) {
            if (func.is_base()) continue;
            if (!func.has_metadata()) continue;
            auto meta_map = read_meta(func);
            auto kind = meta_map.count("kind") ? meta_map["kind"] : "";
            if (kind != "method" && kind != "constructor" && kind != "static_field" &&
                kind != "operator")
                continue;

            // Parse "module:Class.method" from func.name()
            auto colon_pos = func.name().find(':');
            if (colon_pos == std::string::npos) continue;
            std::string after = func.name().substr(colon_pos + 1);
            auto dot_pos = after.find('.');
            if (dot_pos == std::string::npos) continue;
            std::string class_part = func.name().substr(0, colon_pos + 1 + dot_pos);
            std::string method_basename = after.substr(dot_pos + 1);
            std::string smethod = sanitize_name(method_basename);

            if (kind == "method") {
                bool is_static = meta_map.count("is_static") && meta_map["is_static"] == "true";
                bool is_getter = meta_map.count("is_getter") && meta_map["is_getter"] == "true";
                bool is_setter = meta_map.count("is_setter") && meta_map["is_setter"] == "true";
                bool is_abstract = meta_map.count("is_abstract") && meta_map["is_abstract"] == "true";

                method_to_classes_[smethod].insert(class_part);

                if (is_static) {
                    class_static_methods_[class_part].insert(smethod);
                }
                if (is_getter) {
                    class_getters_[class_part].insert(smethod);
                }
                if (is_setter) {
                    class_setters_[class_part].insert(smethod);
                }
                if (is_abstract) {
                    class_abstract_methods_[class_part].insert(smethod);
                }
            } else if (kind == "constructor") {
                bool is_factory = meta_map.count("is_factory") && meta_map["is_factory"] == "true";
                if (is_factory) {
                    class_factory_ctors_[class_part].push_back(method_basename);
                } else if (method_basename != "new" &&
                           method_basename != sanitize_name(after.substr(0, dot_pos))) {
                    class_named_ctors_[class_part].push_back(method_basename);
                }
            }
        }
    }

    // Determine which methods are overridden (i.e., a subclass redefines a
    // method that already exists in a parent class). This drives the `virtual`
    // keyword emission.
    for (const auto& [cls, super] : class_superclass_) {
        if (super.empty()) continue;
        // Find the full class name for the superclass.
        std::string super_full;
        for (const auto& [c, _] : class_superclass_) {
            auto sc = c;
            auto sc_colon = sc.find(':');
            std::string sc_bare = sc_colon != std::string::npos ? sc.substr(sc_colon + 1) : sc;
            if (sc_bare == super) { super_full = c; break; }
        }
        if (super_full.empty()) continue;
        // For each method in this class, check if the super class also defines it.
        for (const auto& [method_name, classes] : method_to_classes_) {
            if (classes.count(cls) && classes.count(super_full)) {
                overridden_methods_.insert(method_name);
            }
        }
        // Also walk upward through the chain: if a grandparent defines the
        // method, the parent's version needs virtual too.
        std::string ancestor = super_full;
        while (!ancestor.empty()) {
            for (const auto& [method_name, classes] : method_to_classes_) {
                if (classes.count(cls) && classes.count(ancestor)) {
                    overridden_methods_.insert(method_name);
                }
            }
            auto ait = class_superclass_.find(ancestor);
            if (ait == class_superclass_.end() || ait->second.empty()) break;
            std::string next_ancestor;
            for (const auto& [c2, _] : class_superclass_) {
                auto c2_colon = c2.find(':');
                std::string c2_bare = c2_colon != std::string::npos ? c2.substr(c2_colon + 1) : c2;
                if (c2_bare == ait->second) { next_ancestor = c2; break; }
            }
            ancestor = next_ancestor;
        }
    }
}

std::vector<std::string> CppCompiler::lookup_ctor_params(const std::string& type_name) {
    auto colon = type_name.find(':');
    auto bare = colon != std::string::npos ? type_name.substr(colon + 1) : type_name;
    std::string ctor_key = program_.entry_module() + "." + type_name + ".new";
    auto it = functions_.find(ctor_key);
    if (it == functions_.end()) {
        // Try with module prefix in the function name (e.g. main.main:Foo.new).
        ctor_key = program_.entry_module() + "." +
                   program_.entry_module() + ":" + bare + ".new";
        it = functions_.find(ctor_key);
    }
    if (it != functions_.end() && it->second->has_metadata())
        return extract_params(it->second->metadata());
    return {};
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

// Extract constructor parameter default values (name -> Dart source of the
// default expression, e.g. "10000", "10 * 1024 * 1024", "false"). Only params
// that declare a default are included. Used to seed class field initializers so
// a default-constructed engine has correct limits instead of garbage int64_t.
static std::map<std::string, std::string> extract_param_defaults(
    const google::protobuf::Struct& metadata) {
    std::map<std::string, std::string> result;
    auto it = metadata.fields().find("params");
    if (it == metadata.fields().end() ||
        it->second.kind_case() != google::protobuf::Value::kListValue) {
        return result;
    }
    for (const auto& elem : it->second.list_value().values()) {
        if (elem.kind_case() != google::protobuf::Value::kStructValue) continue;
        const auto& sf = elem.struct_value().fields();
        auto name_it = sf.find("name");
        auto def_it = sf.find("default");
        if (name_it != sf.end() && def_it != sf.end() &&
            def_it->second.kind_case() == google::protobuf::Value::kStringValue) {
            result[name_it->second.string_value()] = def_it->second.string_value();
        }
    }
    return result;
}

// Per-parameter spec aligned 1:1 with extract_params(): the param's C++-relevant
// Dart type, whether it is optional (optional-positional or optional-named, but
// NOT required-named), and the Dart source of its default value. Used to emit
// C++ default arguments for optional params so call sites that omit them
// compile — an `auto&&` forwarding reference cannot carry a default, so optional
// params are pinned to a concrete type instead.
struct ParamSpec {
    std::string type;   // Dart type source, e.g. "bool" (may be empty)
    bool optional = false;
    std::string def;    // Dart default expr, e.g. "false" (may be empty)
};

static std::vector<ParamSpec> extract_param_specs(
    const google::protobuf::Struct& metadata) {
    std::vector<ParamSpec> result;
    auto it = metadata.fields().find("params");
    if (it == metadata.fields().end() ||
        it->second.kind_case() != google::protobuf::Value::kListValue) {
        return result;
    }
    // Mirror extract_params()'s skip conditions exactly so indices stay aligned.
    for (const auto& elem : it->second.list_value().values()) {
        if (elem.kind_case() != google::protobuf::Value::kStructValue) continue;
        const auto& sf = elem.struct_value().fields();
        auto name_it = sf.find("name");
        if (name_it == sf.end() || name_it->second.string_value().empty()) continue;
        ParamSpec ps;
        auto sget = [&](const char* k) -> std::string {
            auto i = sf.find(k);
            return (i != sf.end() &&
                    i->second.kind_case() == google::protobuf::Value::kStringValue)
                       ? i->second.string_value() : std::string();
        };
        auto bget = [&](const char* k) -> bool {
            auto i = sf.find(k);
            return i != sf.end() &&
                   i->second.kind_case() == google::protobuf::Value::kBoolValue &&
                   i->second.bool_value();
        };
        ps.type = sget("type");
        ps.def = sget("default");
        const bool required_named = bget("is_required_named");
        ps.optional =
            (bget("is_optional") || bget("is_optional_named")) && !required_named;
        result.push_back(ps);
    }
    return result;
}

// Translate a Dart default-value literal into a C++ initializer expression for
// the given (already C++-mapped) parameter type. Handles the literal forms the
// engine actually uses (bool / int / double / string / null); falls back to a
// safe value-initialization for anything else.
static std::string cpp_param_default(const std::string& cpp_type,
                                     const std::string& raw) {
    std::string d = raw;
    const size_t b = d.find_first_not_of(" \t\r\n");
    const size_t e = d.find_last_not_of(" \t\r\n");
    d = (b == std::string::npos) ? std::string() : d.substr(b, e - b + 1);
    const bool is_null = d.empty() || d == "null";
    auto is_int = [](const std::string& s) {
        if (s.empty()) return false;
        size_t i = (s[0] == '-' || s[0] == '+') ? 1 : 0;
        if (i >= s.size()) return false;
        for (; i < s.size(); ++i)
            if (!std::isdigit(static_cast<unsigned char>(s[i]))) return false;
        return true;
    };
    auto is_double = [](const std::string& s) {
        bool dot = false, digit = false;
        size_t i = (!s.empty() && (s[0] == '-' || s[0] == '+')) ? 1 : 0;
        for (; i < s.size(); ++i) {
            if (s[i] == '.') { if (dot) return false; dot = true; }
            else if (std::isdigit(static_cast<unsigned char>(s[i]))) digit = true;
            else return false;
        }
        return dot && digit;
    };
    auto unquote = [](const std::string& s) -> std::string {
        if (s.size() >= 2 && (s.front() == '\'' || s.front() == '"') &&
            (s.back() == '\'' || s.back() == '"'))
            return s.substr(1, s.size() - 2);
        return s;
    };
    if (cpp_type == "bool") return (d == "true") ? "true" : "false";
    if (cpp_type == "int64_t" || cpp_type == "int") return is_int(d) ? d : "0";
    if (cpp_type == "double")
        return is_double(d) ? d : (is_int(d) ? d + ".0" : "0.0");
    if (cpp_type.rfind("std::function", 0) == 0) return "{}";
    if (cpp_type == "std::string")
        return is_null ? "{}" : "std::string(\"" + unquote(d) + "\")";
    if (cpp_type == "BallDyn") {
        if (is_null) return "BallDyn()";
        if (d == "true" || d == "false") return "BallDyn(" + d + ")";
        if (is_int(d)) return "BallDyn(static_cast<int64_t>(" + d + "))";
        if (is_double(d)) return "BallDyn(" + d + ")";
        if (d.size() >= 2 && (d.front() == '\'' || d.front() == '"'))
            return "BallDyn(std::string(\"" + unquote(d) + "\"))";
        return "BallDyn()";
    }
    return "{}";
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
    if (ball_type == "List" || ball_type.find("List<") == 0) return "BallDyn";
    if (ball_type == "Map" || ball_type.find("Map<") == 0) return "BallDyn";
    if (ball_type == "Set" || ball_type.find("Set<") == 0) return "BallDyn";
    if (ball_type == "dynamic" || ball_type == "Object" || ball_type == "Object?"
        || ball_type == "dynamic?" || ball_type == "Never")
        return "BallDyn";

    // Dart "BallValue" is a typedef for Object?/dynamic
    if (ball_type == "BallValue") return "BallDyn";

    // Protobuf / Ball IR types used in self-hosted engine
    if (ball_type == "Expression" || ball_type == "FunctionCall" ||
        ball_type == "FunctionDefinition" || ball_type == "Module" ||
        ball_type == "Program" || ball_type == "Block" ||
        ball_type == "Statement" || ball_type == "Literal" ||
        ball_type == "Reference" || ball_type == "FieldAccess" ||
        ball_type == "MessageCreation" || ball_type == "FieldValuePair" ||
        ball_type == "LetBinding" || ball_type == "TypeDefinition")
        return "BallDyn";

    // Engine internal types
    if (ball_type == "_Scope" || ball_type == "Scope" ||
        ball_type == "_FlowSignal" || ball_type == "BallFuture" ||
        ball_type == "BallGenerator" || ball_type == "BallException" ||
        ball_type == "BallRuntimeError" || ball_type == "BallCallable")
        return "BallDyn";

    // FutureOr<T> / Future<T> → BallDyn (or void for Future<void>)
    if (ball_type == "Future<void>" || ball_type == "FutureOr<void>") return "void";
    if (ball_type.find("FutureOr") == 0) return "BallDyn";
    if (ball_type.find("Future") == 0) return "BallDyn";


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

    // Dart RegExp → ball_to_regex (handles BallDyn args)
    if (ball_type == "RegExp") return "ball_to_regex";
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
    // Enum types → BallDyn so enum instances flow through BallDyn-based
    // dispatch (for-in iteration, switch comparison, function params).
    // The enum struct is still used for static member access (Color::red).
    if (enum_names_.count(sanitize_name(ball_type)) > 0) return "BallDyn";
    // User-defined type
    return sanitize_name(ball_type);
}

std::string CppCompiler::map_return_type(const ball::v1::FunctionDefinition& func) {
    // If the output type is a known user class (NOT enum), return the actual
    // type so struct-returning methods (e.g. simplify() -> Fraction) compile
    // without needing an implicit Fraction->BallDyn conversion.
    // Enum types stay as BallDyn since they flow through BallDyn dispatch.
    if (!func.output_type().empty()) {
        std::string stype = sanitize_name(func.output_type());
        if (user_class_names_.count(stype) > 0 && enum_names_.count(stype) == 0)
            return stype;
        if (func.output_type() == "void") return "void";
    }
    return "BallDyn";
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

// Rename a *local variable* (let binding, lambda/function param, or value
// reference) whose sanitized name collides with a runtime free function that
// dynamic method dispatch emits (e.g. `scope.child()` lowers to `child(scope)`).
// Without this, `final child = parent.child()` emits `auto child = child(parent)`
// where the local `child` shadows the runtime function in its own initializer.
// Method-call names (compile_method_call) deliberately do NOT use this, so the
// renamed local and the still-named function no longer collide.
static std::string ball_local_var_name(const std::string& sanitized) {
    static const std::set<std::string> shadowing = {"child", "bind"};
    return shadowing.count(sanitized) ? sanitized + "_lv" : sanitized;
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
            return "BallDyn()";
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

// Recursively collect the (raw) names of every `let` binding and lambda
// parameter declared in an expression tree. Used to populate
// `declared_locals_` so a reference to a local named `num` / `int` / `String`
// etc. resolves to the variable instead of the Dart type-object string. Does
// not descend into nested user functions (they manage their own scope), but
// DOES descend into lambdas and blocks since those share the function's frame.
static void _collect_declared_locals(const ball::v1::Expression& e,
                                     std::unordered_set<std::string>& out) {
    using E = ball::v1::Expression;
    switch (e.expr_case()) {
        case E::kBlock:
            for (const auto& s : e.block().statements()) {
                if (s.has_let()) {
                    out.insert(s.let().name());
                    _collect_declared_locals(s.let().value(), out);
                } else if (s.has_expression()) {
                    _collect_declared_locals(s.expression(), out);
                }
            }
            if (e.block().has_result()) _collect_declared_locals(e.block().result(), out);
            return;
        case E::kCall:
            if (e.call().has_input()) _collect_declared_locals(e.call().input(), out);
            return;
        case E::kLambda:
            // A lambda is a FunctionDefinition (proto field `lambda`); its body
            // shares this function's C++ frame (captured by reference), so its
            // `let`s belong to the same local scope.
            if (e.lambda().has_body()) _collect_declared_locals(e.lambda().body(), out);
            return;
        case E::kMessageCreation:
            for (const auto& f : e.message_creation().fields())
                if (f.has_value()) _collect_declared_locals(f.value(), out);
            return;
        case E::kFieldAccess:
            if (e.field_access().has_object())
                _collect_declared_locals(e.field_access().object(), out);
            return;
        case E::kLiteral:
            if (e.literal().value_case() == ball::v1::Literal::kListValue)
                for (const auto& el : e.literal().list_value().elements())
                    _collect_declared_locals(el, out);
            return;
        default:
            return;
    }
}

std::string CppCompiler::compile_reference(const ball::v1::Reference& ref) {
    // Dart's `this` → C++ `(*this)` (dereference the pointer for value semantics)
    if (ref.name() == "this") return "(*this)";
    // `self` inside a class method body → `(*this)` (the Ball IR uses `self`
    // as the implicit receiver in instance method bodies, equivalent to `this`).
    if (ref.name() == "self" && !current_class_name_.empty()) return "(*this)";
    // `super` inside a class method body → `(*this)` (in C++, base class
    // fields/methods are directly accessible on `this`; the parent class
    // qualification is added at the call site for method dispatch).
    if (ref.name() == "super" && !current_class_name_.empty()) return "(*this)";
    // Dart uninitialized sentinel → C++ default-initialized BallDyn
    if (ref.name() == "__no_init__") return "BallDyn()";
    // Dart sentinel object → unique dispatch-not-found marker (not null BallDyn)
    if (ref.name() == "_sentinel") return "ball_dispatch_not_found()";
    // Dart type objects used as values (e.g., int.tryParse, double.tryParse)
    // → emit as string constants representing the type name. A local variable
    // or parameter with the same name shadows the type object — common for
    // `num`, less so for the others — so skip this when the name is a declared
    // local in the current function (otherwise `num` would emit `"num"s`).
    if (declared_locals_.count(ref.name()) == 0) {
        // Enum type references are used for static member access (Color.red)
        // and for iteration (Color.values). Emit the bare type name so
        // compile_field_access can resolve `Color::red`, `Color::values`, etc.
        if (enum_names_.count(sanitize_name(ref.name())) > 0) {
            return sanitize_name(ref.name());
        }
        if (ref.name() == "int") return "\"int\"s";
        if (ref.name() == "double") return "\"double\"s";
        if (ref.name() == "num") return "\"num\"s";
        if (ref.name() == "String") return "\"String\"s";
        if (ref.name() == "bool") return "\"bool\"s";
        // Dart collection type constructors used as values
        if (ref.name() == "Map") return "\"Map\"s";
        if (ref.name() == "List") return "\"List\"s";
        if (ref.name() == "Set") return "\"Set\"s";
    }
    // If the reference is to a sibling method in the current class:
    // - Getters: emit as a direct call `getter()` since they take no args
    //   and the reference is used as a value (e.g., `ball_to_string(label)`).
    // - Other methods: wrap in a lambda to bind `this`. Bare member function
    //   names can't be stored as std::any / passed as values in C++.
    auto sname = sanitize_name(ref.name());
    if (!current_class_methods_.empty() &&
        current_class_methods_.count(sname) > 0) {
        // Check if it's a getter in the current class
        bool is_getter_ref = false;
        for (const auto& [cls, getters] : class_getters_) {
            auto cc = cls.find(':');
            std::string cls_bare = cc != std::string::npos ? cls.substr(cc + 1) : cls;
            if (sanitize_name(cls_bare) == current_class_name_ && getters.count(sname)) {
                is_getter_ref = true;
                break;
            }
        }
        if (is_getter_ref) {
            return sname + "()";
        }
        return "[this](auto __arg) mutable { return " + sname + "(__arg); }";
    }
    return ball_local_var_name(sname);
}

std::string CppCompiler::compile_field_access(const ball::v1::FieldAccess& access) {
    auto obj = compile_expr(access.object());
    auto field = access.field();
    // Dart's protobuf generator renamed the `FieldAccess.field` getter to
    // `field_2` (collision avoidance), so the engine source reads
    // `access.field_2`. Ball programs are interpreted as proto3-JSON whose key
    // is the schema name `field`, so map the renamed getter back to the
    // canonical JSON key. (field_2 is the only such rename in ball.proto.)
    if (field == "field_2") field = "field";
    // Enum static member access: `Color.red` → `Color::red`, `Color.values` → `Color::values`.
    if (access.object().expr_case() == ball::v1::Expression::kReference) {
        const auto& ref_name = access.object().reference().name();
        if (enum_names_.count(sanitize_name(ref_name)) > 0) {
            std::string enum_type = sanitize_name(ref_name);
            // For .values and named members, use static access
            return enum_type + "::" + sanitize_name(field);
        }
    }
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
    // Common virtual properties → C++ equivalents.
    // `.length` is UTF-16 code-unit length for strings (Dart parity), element
    // count for lists/maps; ball_length dispatches on the runtime type.
    if (field == "length") return "ball_length(" + obj + ")";
    if (field == "isEmpty") return obj + ".empty()";
    if (field == "isNotEmpty") return "!" + obj + ".empty()";
    // Dart double properties: .isNaN, .isInfinite, .isFinite, .isNegative
    if (field == "isNaN") return "ball_isNaN(" + obj + ")";
    if (field == "isInfinite") return "ball_isInfinite(" + obj + ")";
    if (field == "isFinite") return "ball_isFinite(" + obj + ")";
    if (field == "isNegative") return "ball_isNegative(" + obj + ")";
    // Dart `someMap.values.first` / `.values.last`: the `.values` getter yields
    // the map's value collection, and `.first`/`.last` take an element. A bare
    // `.values` deliberately falls through to a key lookup (`obj["values"]`,
    // because `.values` is overloaded across BallGenerator/enum/ListValue — see
    // the NOTE below), so the chained form would otherwise read a missing
    // "values" key and yield null. When `.first`/`.last` consumes a `.values`
    // access, the intent is unambiguous: emit the map-values helper so the
    // element is taken from the real value collection. (Fixes dart_std.invoke's
    // `args.values.first` single-positional-argument unwrap, conformance 211.)
    if ((field == "first" || field == "last") &&
        access.object().expr_case() == ball::v1::Expression::kFieldAccess &&
        access.object().field_access().field() == "values") {
        auto inner = compile_expr(access.object().field_access().object());
        std::string elem = (field == "first") ? ".front()" : ".back()";
        return "ball_map_values(BallDyn(" + inner + "))" + elem;
    }
    if (field == "first") return obj + ".front()";
    if (field == "last") return obj + ".back()";
    if (field == "runtimeType") return "ball_runtime_type_name(BallDyn(" + obj + "))";
    // Dart Map.entries → iterable of {key, value} maps (same as map_entries).
    // Delegates to the ball_map_entries runtime helper, which safely unwraps
    // a BallDyn (map or BallObject) without relying on a `.value()` accessor.
    if (field == "entries") {
        return "ball_map_entries(BallDyn(" + obj + "))";
    }
    // Dart Map.keys → the map's key collection. Unlike `.values` (which is
    // overloaded across BallGenerator/enum/ListValue), `.keys` is map-only in
    // the engine, so a blanket dispatch to ball_map_keys is safe. The bare
    // getter would otherwise compile to `obj["keys"]` (a key lookup that
    // returns null), breaking the engine's own std map_keys implementation.
    if (field == "keys") {
        return "ball_map_keys(BallDyn(" + obj + "))";
    }
    // NOTE: do NOT blindly map `.values` here — `.values` is overloaded
    // (BallGenerator.values, enum .values, proto reflection) and a blanket
    // dispatch to ball_map_values regressed conformance 72->40. The engine's
    // own _evalFieldAccess already handles Map.keys/.values for program maps;
    // ball_map_keys/ball_map_values remain available as runtime helpers.
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
                return "static_cast<BallDyn>(" + obj + ")[" + std::to_string(idx) + "LL]";
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
    // User-defined class getter dispatch: if the field name is a known getter
    // for any user class, emit as a method call `obj.field()` instead of a
    // map-style bracket access. Also check if it is a plain struct field
    // (not a getter method) — emit `obj.field` for direct field access.
    // GUARD: skip struct-member dispatch when the object is a reference to a
    // generic (map-backed) local — those use bracket notation.
    {
        bool skip_struct = false;
        if (access.object().expr_case() == ball::v1::Expression::kReference) {
            if (generic_locals_.count(access.object().reference().name()) > 0)
                skip_struct = true;
        }
        if (!skip_struct) {
            std::string sfield = sanitize_name(field);
            bool is_getter = false;
            bool is_plain_field = false;
            for (const auto& [cls, getters] : class_getters_) {
                if (getters.count(sfield)) { is_getter = true; break; }
            }
            if (!is_getter) {
                // Check if field is a direct struct field on any user class.
                for (const auto& [cls, td_ptr] : class_typedefs_) {
                    if (!td_ptr || !td_ptr->has_descriptor_()) continue;
                    for (const auto& fd : td_ptr->descriptor_().field()) {
                        if (sanitize_name(fd.name()) == sfield) {
                            is_plain_field = true;
                            break;
                        }
                    }
                    if (is_plain_field) break;
                }
            }
            if (is_getter) {
                return obj + "." + sfield + "()";
            }
            if (is_plain_field) {
                return obj + "." + sfield;
            }
        }
    }

    // Default: bracket-notation field access via BallDyn wrapper.
    // Wrapping in BallDyn ensures the access works on std::any values
    // (from map lookups) as well as BallDyn and std::map types.
    // The BallDyn constructor accepts std::any, so this is safe for all types.
    // static_cast<BallDyn>(obj)["field"s] rather than BallDyn(obj)["field"s]:
    // the explicit static_cast is unambiguously an expression (the functional-
    // cast form is the most-vexing-parse under gcc/clang, and nested forms read
    // as a function returning an array), while preserving identical operator[]
    // dispatch (a plain helper changed key-overload resolution and regressed
    // enum lookups).
    return "static_cast<BallDyn>(" + obj + ")[\"" + field + "\"s]";
}

std::string CppCompiler::compile_message_creation(const ball::v1::MessageCreation& msg) {
    // Emit as an aggregate initializer or a map
    if (msg.type_name().empty() || msg.type_name().find("Msg") == 0) {
        // Anonymous message → BallMap (dynamic map)
        std::string result = "[&]() { std::map<std::string,std::any> __m;";
        for (const auto& f : msg.fields()) {
            result += " __m[\"" + f.name() + "\"s] = std::any(" + compile_expr(f.value()) + ");";
        }
        result += " return __m; }()";
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

    // BallValue wrapper types — transparent in C++ (just pass through the arg)
    {
        auto colon = msg.type_name().find(':');
        auto bare = colon != std::string::npos ? msg.type_name().substr(colon + 1) : msg.type_name();
        // BallMap/BallList/BallInt/BallString/BallBool/BallNull/BallFunction — transparent
        static const std::set<std::string> transparent = {
            "BallMap", "BallList", "BallInt", "BallString",
            "BallBool", "BallNull", "BallFunction", "BallValue",
        };
        if (transparent.count(bare)) {
            if (msg.fields().empty()) return "BallDyn{}";
            // Pass through the first non-metadata arg
            for (const auto& f : msg.fields()) {
                if (f.name() != "__type_args__" && f.name() != "__const__") {
                    return compile_expr(f.value());
                }
            }
            return "BallDyn{}";
        }
        // List.of / List.from → copy
        if (bare == "List.of" || bare == "List.from") {
            if (msg.fields().empty()) return "BallList{}";
            for (const auto& f : msg.fields()) {
                if (f.name() != "__type_args__" && f.name() != "__const__") {
                    return "ball_list_copy(" + compile_expr(f.value()) + ")";
                }
            }
            return "BallList{}";
        }
        // Map.from / Map.of → copy
        if (bare == "Map.from" || bare == "Map.of") {
            if (msg.fields().empty()) return "BallMap{}";
            for (const auto& f : msg.fields()) {
                if (f.name() != "__type_args__" && f.name() != "__const__") {
                    return "ball_map_copy(" + compile_expr(f.value()) + ")";
                }
            }
            return "BallMap{}";
        }
        // BallDouble — wrap in BallDyn with double
        if (bare == "BallDouble") {
            if (msg.fields().empty()) return "BallDyn(0.0)";
            for (const auto& f : msg.fields()) {
                if (f.name() != "__type_args__" && f.name() != "__const__") {
                    return "BallDyn(static_cast<double>(" + compile_expr(f.value()) + "))";
                }
            }
            return "BallDyn(0.0)";
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

    // _Scope is the engine's lexical scope. `_Scope(parent)` must create a
    // NEW child scope with its own bindings and a __parent__ link — the runtime
    // `child()` does exactly that (reference semantics). Without this it was
    // emitted as `BallDyn(BallDyn(parent))` (just wrapping the parent), so
    // bindings written at function entry weren't visible to the body's reads.
    {
        auto bare_scope = sanitize_name(msg.type_name());
        auto sc = bare_scope.find(':');
        if (sc != std::string::npos) bare_scope = bare_scope.substr(sc + 1);
        if (bare_scope == "_Scope") {
            // Find the first non-metadata field — the parent scope, if any.
            for (const auto& f : msg.fields()) {
                if (f.name() == "__type_args__" || f.name() == "__const__") continue;
                return "child(" + compile_expr(f.value()) + ")";
            }
            // _Scope() — a fresh root scope.
            return "child(BallDyn())";
        }
    }

    // ── Reified generics: when the MessageCreation carries a __type_args__
    // field, emit as a dynamic map that stores __type__, __type_args__, and all
    // constructor fields (resolved from argN to real param names). This lets
    // `x is Box<int>` check both the base type and the generic args at runtime.
    {
        bool has_type_args = false;
        std::string type_args_expr;
        for (const auto& f : msg.fields()) {
            if (f.name() == "__type_args__") {
                has_type_args = true;
                type_args_expr = compile_expr(f.value());
                break;
            }
        }
        if (has_type_args) {
            // Resolve argN field names to constructor parameter names.
            std::vector<std::string> ctor_params = lookup_ctor_params(msg.type_name());
            auto colon = msg.type_name().find(':');
            auto bare = colon != std::string::npos ? msg.type_name().substr(colon + 1) : msg.type_name();
            std::string result = "[&]() { std::map<std::string,std::any> __m;";
            result += " __m[\"__type__\"s] = std::any(\"" + bare + "\"s);";
            result += " __m[\"__type_args__\"s] = std::any(" + type_args_expr + ");";
            for (const auto& f : msg.fields()) {
                if (f.name() == "__type_args__" || f.name() == "__const__") continue;
                std::string field_name = f.name();
                if (field_name.size() >= 4 && field_name.substr(0, 3) == "arg") {
                    try {
                        int idx = std::stoi(field_name.substr(3));
                        if (idx >= 0 && idx < static_cast<int>(ctor_params.size()))
                            field_name = ctor_params[idx];
                    } catch (...) {}
                }
                result += " __m[\"" + field_name + "\"s] = std::any(" + compile_expr(f.value()) + ");";
            }
            result += " return __m; }()";
            return result;
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
        // Check if this class has a factory constructor for "new" — if so,
        // route through the static factory method instead of direct construction.
        bool has_factory_new = false;
        for (const auto& [cls, factories] : class_factory_ctors_) {
            auto cls_colon = cls.find(':');
            std::string cls_bare = cls_colon != std::string::npos ? cls.substr(cls_colon + 1) : cls;
            if (sanitize_name(cls_bare) == type) {
                for (const auto& fname : factories) {
                    if (fname == "new") { has_factory_new = true; break; }
                }
                break;
            }
        }
        if (has_factory_new) {
            // Call the factory constructor: ClassName::new_(args)
            std::string result = type + "::" + sanitize_name("new") + "(";
            bool first = true;
            for (const auto& f : msg.fields()) {
                if (!first) result += ", ";
                result += compile_expr(f.value());
                first = false;
            }
            result += ")";
            return result;
        }
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

    // Runtime stub types (BallDyn subclasses) → emit as map
    {
        static const std::set<std::string> stub_types = {
            "_FlowSignal", "_Scope", "BallRuntimeError", "BallFuture",
            "_ExitSignal", "BallModuleHandler",
            "StdModuleHandler",
        };
        auto bare_t = sanitize_name(msg.type_name());
        auto bcc = bare_t.find(':');
        if (bcc != std::string::npos) bare_t = bare_t.substr(bcc + 1);
        if (stub_types.count(bare_t)) {
            // Resolve positional argN keys to the constructor's real param
            // names (e.g. _FlowSignal('return', value: v) → {kind, value}).
            // The runtime (ball_is_flow_signal + all `.kind`/`.value` reads)
            // keys on the parameter names, so emitting "arg0" silently breaks
            // flow-signal detection and return-value extraction.
            std::vector<std::string> ctor_params = lookup_ctor_params(msg.type_name());
            std::string result = "[&]() { std::map<std::string,std::any> __m;";
            for (const auto& f : msg.fields()) {
                std::string fname = f.name();
                if (fname.size() >= 4 && fname.substr(0, 3) == "arg") {
                    try {
                        int idx = std::stoi(fname.substr(3));
                        if (idx >= 0 && idx < static_cast<int>(ctor_params.size()))
                            fname = ctor_params[idx];
                    } catch (...) {}
                }
                result += " __m[\"" + fname + "\"s] = std::any(" + compile_expr(f.value()) + ");";
            }
            result += " return __m; }()";
            return result;
        }
    }

    // BallObject (self-hosted engine value type) is NOT an aggregate — it has
    // user-defined constructors — so designated initializers won't compile.
    // Emit a positional constructor call instead, ordering the named fields to
    // match BallObject(typeName, superObject, fields, methods).
    if (type == "BallObject") {
        std::map<std::string, std::string> by_name;
        for (const auto& f : msg.fields()) {
            by_name[f.name()] = compile_expr(f.value());
        }
        auto pick = [&](const char* key) -> std::string {
            auto it = by_name.find(key);
            return it != by_name.end() ? it->second : std::string("std::any{}");
        };
        return "BallObject(" + pick("typeName") + ", " + pick("superObject") +
               ", " + pick("fields") + ", " + pick("methods") + ")";
    }

    // BallGenerator is a runtime reference type (shared values list). It takes
    // no constructor fields — sync*/async* bodies push via yield_ / yieldAll.
    if (type == "BallGenerator") {
        return "BallGenerator{}";
    }

    // JsonEncoder/JsonDecoder — runtime structs with only metadata fields in IR.
    {
        auto bare_rt = sanitize_name(msg.type_name());
        auto rc = bare_rt.find(':');
        if (rc != std::string::npos) bare_rt = bare_rt.substr(rc + 1);
        if (bare_rt == "JsonEncoder" || bare_rt == "JsonDecoder") {
            bool only_meta = true;
            for (const auto& f : msg.fields()) {
                if (f.name() != "__type_args__" && f.name() != "__const__") {
                    only_meta = false;
                    break;
                }
            }
            if (only_meta) return bare_rt + "{}";
        }
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
        // Resolve argN field names to constructor parameter names.
        std::vector<std::string> ctor_params = lookup_ctor_params(msg.type_name());

        // Build a mapping of actual field values, resolving argN to param names
        std::string result = type + "{";
        bool first = true;
        for (const auto& f : msg.fields()) {
            if (f.name() == "__type_args__" || f.name() == "__const__") continue;
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
        if (f.name() == "__type_args__" || f.name() == "__const__") continue;
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
    int stmt_count = block.statements_size();
    for (int si = 0; si < stmt_count; si++) {
        const auto& s = block.statements(si);
        bool is_last = (si == stmt_count - 1) && !block.has_result();
        if (s.has_let()) {
            if (s.let().value().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : s.let().value().message_creation().fields()) {
                    if (f.name() == "__type_args__") {
                        generic_locals_.insert(s.let().name());
                        break;
                    }
                }
            }
            result += indent_str() + "auto " + ball_local_var_name(sanitize_name(s.let().name())) +
                      " = " + compile_expr(s.let().value()) + ";\n";
        } else if (s.has_expression()) {
            if (is_last) {
                bool expr_is_throw = s.expression().expr_case() == ball::v1::Expression::kCall &&
                                     s.expression().call().function() == "throw";
                if (expr_is_throw) {
                    result += indent_str() + compile_expr(s.expression()) + "; return BallDyn();\n";
                } else {
                    result += indent_str() + "return BallDyn(" + compile_expr(s.expression()) + ");\n";
                }
            } else {
                result += indent_str() + compile_expr(s.expression()) + ";\n";
            }
        }
    }
    if (block.has_result()) {
        result += indent_str() + "return " + compile_expr(block.result()) + ";\n";
    }
    indent_--;
    result += indent_str() + "}()";
    return result;
}

std::string CppCompiler::compile_block_statements(const ball::v1::Block& block) {
    // Capture the block's statements as real C++ (not an IIFE) by temporarily
    // diverting out_ to a private buffer. break/continue emitted here are real
    // C++ statements that act on the enclosing for/while. Restores out_ after.
    std::ostringstream body_buf;
    out_.swap(body_buf);  // out_ now empty; body_buf holds prior accumulated output
    indent_++;
    for (const auto& s : block.statements()) {
        compile_statement(s);
    }
    if (block.has_result()) {
        emit_line(compile_expr(block.result()) + ";");
    }
    indent_--;
    std::string body = out_.str();
    out_.swap(body_buf);  // restore prior output; `body` already captured
    return body;
}

std::string CppCompiler::compile_lambda(const ball::v1::FunctionDefinition& func) {
    // Dart closures capture by reference: all closures sharing a variable
    // see the same value, including mutations. Use `[&]` to match Dart
    // semantics. This is safe as long as closures don't outlive the
    // enclosing stack frame; compiled Ball programs keep all relevant
    // locals alive through the program's single main() or function scope.
    std::string result = "[&](";
    // Parameters
    if (func.has_metadata()) {
        auto params = extract_params(func.metadata());
        bool first = true;
        for (const auto& p : params) {
            if (!first) result += ", ";
            result += "BallDyn " + sanitize_name(p);
            first = false;
        }
    } else if (!func.input_type().empty()) {
        result += map_type(func.input_type()) + " input";
    } else {
        // Default: accept BallDyn (NOT auto — auto creates generic lambdas
        // that can't be stored in std::any/BallFunc)
        result += "BallDyn __lambda_input";
    }
    result += ") mutable";
    // Force an explicit BallDyn return type when the body is emitted via the
    // statement-aware path: that path can produce several `return` statements
    // with different deduced C++ types (int64_t, std::vector, BallDyn, ...),
    // which would otherwise trip MSVC's "all return expressions must deduce to
    // the same type". An explicit -> BallDyn lets each `return BallDyn(...)`
    // convert uniformly.
    const bool body_is_block =
        func.has_body() &&
        func.body().expr_case() == ball::v1::Expression::kBlock;
    if (!func.output_type().empty() && func.output_type() != "void") {
        result += " -> " + map_type(func.output_type());
    } else if (body_is_block) {
        result += " -> BallDyn";
    }
    result += " {\n";
    indent_++;
    if (func.has_body()) {
        if (body_is_block) {
            // Emit the body via the statement-aware path (out_-swap) so that
            // statement-position `if`/`return`/`for`/`while` get their native
            // statement form. Previously each statement was rendered with
            // compile_expr, which turned `if (cond) return x;` into a discarded
            // expression-IIFE — the inner `return` escaped only the IIFE, not the
            // lambda, silently dropping early returns (e.g. std list_contains).
            const auto& block = func.body().block();
            std::ostringstream body_buf;
            out_.swap(body_buf);
            for (const auto& stmt : block.statements()) {
                compile_statement(stmt);
            }
            std::string stmts = out_.str();
            out_.swap(body_buf);
            result += stmts;
            if (block.has_result()) {
                result += indent_str() + "return BallDyn(" + compile_expr(block.result()) + ");\n";
            } else {
                // No tail result: the body may end without a `return` (e.g. a
                // trailing for/while loop). The explicit -> BallDyn return type
                // requires every path to return, so plant a default.
                result += indent_str() + "return BallDyn();\n";
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
// Map entry sentinel detection helpers
// ================================================================

// Flatten a LogicalOrPattern tree into a list of leaf ConstPattern value
// expressions. Used by switch_expr and switch to compile or-patterns like
// `1 || 2 || 3` into compound conditions.
static void _collectOrPatternValues(const ball::v1::Expression& expr,
                                     std::vector<const ball::v1::Expression*>& out) {
    if (expr.expr_case() != ball::v1::Expression::kMessageCreation) return;
    const auto& mc = expr.message_creation();
    const std::string& tn = mc.type_name();
    if (tn == "LogicalOrPattern") {
        for (const auto& f : mc.fields()) {
            if (f.name() == "left" || f.name() == "right") {
                _collectOrPatternValues(f.value(), out);
            }
        }
    } else if (tn == "ConstPattern") {
        for (const auto& f : mc.fields()) {
            if (f.name() == "value") {
                out.push_back(&f.value());
                return;
            }
        }
    }
}

// ================================================================
// Structured pattern matching helpers
// ================================================================

// Determine the kind of a structured pattern_expr. Returns the typeName
// or __pattern_kind__ value (e.g. "ConstPattern", "VarPattern", "ListPattern",
// "MapPattern", "RestPattern", "record", "var", "wildcard", "_").
static std::string _patternExprKind(const ball::v1::Expression& expr) {
    if (expr.expr_case() != ball::v1::Expression::kMessageCreation) return "";
    const auto& mc = expr.message_creation();
    const std::string& tn = mc.type_name();
    if (!tn.empty()) return tn;
    for (const auto& f : mc.fields()) {
        if (f.name() == "__pattern_kind__" &&
            f.value().expr_case() == ball::v1::Expression::kLiteral &&
            f.value().literal().value_case() == ball::v1::Literal::kStringValue) {
            return f.value().literal().string_value();
        }
    }
    return "";
}

// Helper to get a named field from a MessageCreation expression.
static const ball::v1::Expression* _patternField(
    const ball::v1::Expression& expr, const std::string& name) {
    if (expr.expr_case() != ball::v1::Expression::kMessageCreation) return nullptr;
    for (const auto& f : expr.message_creation().fields()) {
        if (f.name() == name) return &f.value();
    }
    return nullptr;
}

// Helper to get a string literal from a pattern field.
static std::string _patternStringField(
    const ball::v1::Expression& expr, const std::string& name) {
    auto* f = _patternField(expr, name);
    if (f && f->expr_case() == ball::v1::Expression::kLiteral &&
        f->literal().value_case() == ball::v1::Literal::kStringValue) {
        return f->literal().string_value();
    }
    return "";
}

struct StructuredPatternResult {
    std::string condition;
    std::vector<std::pair<std::string, std::string>> bindings; // (varName, expr)
};

// Generate a C++ type-check condition for a given type name against a subject.
static std::string _typeCheckCondition(const std::string& typeName, const std::string& subject) {
    if (typeName == "int") {
        return "(ball_is_int(" + subject + ") || ball_object_type_matches(" + subject + ", \"BallInt\"s))";
    }
    if (typeName == "double") {
        return "(ball_is_double(" + subject + ") || ball_object_type_matches(" + subject + ", \"BallDouble\"s))";
    }
    if (typeName == "num" || typeName == "number") {
        return "((ball_is_int(" + subject + ") || ball_is_double(" + subject + ")) || ball_object_type_matches(" + subject + ", \"BallInt\"s) || ball_object_type_matches(" + subject + ", \"BallDouble\"s))";
    }
    if (typeName == "String" || typeName == "string") {
        return "(ball_is_string(" + subject + ") || ball_object_type_matches(" + subject + ", \"BallString\"s))";
    }
    if (typeName == "bool" || typeName == "boolean") {
        return "(ball_is_bool(" + subject + ") || ball_object_type_matches(" + subject + ", \"BallBool\"s))";
    }
    if (typeName == "List") {
        return "(ball_is_list(" + subject + ") || ball_object_type_matches(" + subject + ", \"BallList\"s))";
    }
    if (typeName == "Map") {
        return "(ball_is_map_dyn(" + subject + ") || ball_object_type_matches(" + subject + ", \"BallMap\"s))";
    }
    return "ball_object_type_matches(" + subject + ", \"" + typeName + "\"s)";
}

// Forward declaration — recursive for nested patterns.
static std::optional<StructuredPatternResult> _compileStructuredPattern(
    const ball::v1::Expression& patternExpr,
    const std::string& subject,
    std::function<std::string(const ball::v1::Expression&)> exprFn);

static std::optional<StructuredPatternResult> _compileStructuredPattern(
    const ball::v1::Expression& patternExpr,
    const std::string& subject,
    std::function<std::string(const ball::v1::Expression&)> exprFn) {

    const std::string kind = _patternExprKind(patternExpr);
    if (kind.empty()) return std::nullopt;

    // ConstPattern: compare subject to a literal value
    if (kind == "ConstPattern") {
        auto* val = _patternField(patternExpr, "value");
        if (val) {
            // Null literal: empty literal (VALUE_NOT_SET)
            if (val->expr_case() == ball::v1::Expression::kLiteral &&
                val->literal().value_case() == ball::v1::Literal::VALUE_NOT_SET) {
                return StructuredPatternResult{"!" + subject + ".has_value()", {}};
            }
            return StructuredPatternResult{
                "BallDyn(" + subject + ") == BallDyn(" + exprFn(*val) + ")", {}};
        }
        return StructuredPatternResult{"true", {}};
    }

    // VarPattern / var: bind subject to a variable, optionally with type check
    if (kind == "VarPattern" || kind == "var") {
        std::string name = _patternStringField(patternExpr, "name");
        std::string typeName = _patternStringField(patternExpr, "type");
        std::string cond = "true";
        if (!typeName.empty()) {
            cond = _typeCheckCondition(typeName, subject);
        }
        std::vector<std::pair<std::string, std::string>> binds;
        if (!name.empty()) {
            binds.push_back({name, subject});
        }
        return StructuredPatternResult{cond, binds};
    }

    // WildcardPattern / wildcard / _: always matches, no bindings
    if (kind == "WildcardPattern" || kind == "wildcard" || kind == "_") {
        return StructuredPatternResult{"true", {}};
    }

    // ListPattern: check list type, length, and recursively match elements.
    // Uses BallDyn's .length() and operator[](int64_t) for element access,
    // and ball_to_list() for sublist construction in rest patterns.
    if (kind == "ListPattern") {
        auto* elementsExpr = _patternField(patternExpr, "elements");
        std::vector<const ball::v1::Expression*> elements;
        if (elementsExpr &&
            elementsExpr->expr_case() == ball::v1::Expression::kLiteral &&
            elementsExpr->literal().value_case() == ball::v1::Literal::kListValue) {
            for (const auto& e : elementsExpr->literal().list_value().elements()) {
                elements.push_back(&e);
            }
        }

        // Check for RestPattern
        int restIndex = -1;
        for (int i = 0; i < (int)elements.size(); i++) {
            std::string ek = _patternExprKind(*elements[i]);
            if (ek == "RestPattern" || ek == "rest") {
                restIndex = i;
                break;
            }
        }

        // Helper: access element i of subject via BallDyn operator[]
        auto elemAccess = [&](const std::string& subj, const std::string& idx) -> std::string {
            return "static_cast<BallDyn>(BallDyn(" + subj + "))[int64_t(" + idx + ")]";
        };

        std::vector<std::string> conds;
        std::vector<std::pair<std::string, std::string>> binds;

        if (restIndex >= 0) {
            // With rest pattern: [fixed..., ...rest, fixed...]
            int beforeCount = restIndex;
            int afterCount = (int)elements.size() - restIndex - 1;
            int minLen = beforeCount + afterCount;
            conds.push_back("ball_is_list(BallDyn(" + subject + "))");
            conds.push_back("static_cast<int64_t>(ball_length(BallDyn(" + subject + "))) >= " + std::to_string(minLen));

            // Elements before rest
            for (int i = 0; i < beforeCount; i++) {
                auto sub = _compileStructuredPattern(
                    *elements[i],
                    elemAccess(subject, std::to_string(i)),
                    exprFn);
                if (sub) {
                    if (sub->condition != "true") conds.push_back(sub->condition);
                    binds.insert(binds.end(), sub->bindings.begin(), sub->bindings.end());
                }
            }

            // Rest pattern itself — build a sublist via ball_to_list + vector range ctor
            auto* restSubpattern = _patternField(*elements[restIndex], "subpattern");
            if (restSubpattern) {
                // Build sublist: [&]{ auto __l = ball_to_list(static_cast<std::any>(subj));
                //   return BallDyn(BallList(__l.begin()+before, __l.end()-after)); }()
                std::string restSlice = "[&]{ auto __l = ball_to_list(static_cast<std::any>(BallDyn(" +
                    subject + "))); return BallDyn(BallList(__l.begin() + " +
                    std::to_string(beforeCount);
                if (afterCount > 0) {
                    restSlice += ", __l.end() - " + std::to_string(afterCount);
                } else {
                    restSlice += ", __l.end()";
                }
                restSlice += ")); }()";
                auto sub = _compileStructuredPattern(*restSubpattern, restSlice, exprFn);
                if (sub) {
                    if (sub->condition != "true") conds.push_back(sub->condition);
                    binds.insert(binds.end(), sub->bindings.begin(), sub->bindings.end());
                }
            }

            // Elements after rest
            for (int i = 0; i < afterCount; i++) {
                int elemIdx = restIndex + 1 + i;
                // Index from end: length - (afterCount - i)
                std::string idx = "ball_length(BallDyn(" + subject + ")) - " + std::to_string(afterCount - i);
                auto sub = _compileStructuredPattern(
                    *elements[elemIdx],
                    elemAccess(subject, idx),
                    exprFn);
                if (sub) {
                    if (sub->condition != "true") conds.push_back(sub->condition);
                    binds.insert(binds.end(), sub->bindings.begin(), sub->bindings.end());
                }
            }
        } else {
            // Exact-length list pattern
            conds.push_back("ball_is_list(BallDyn(" + subject + "))");
            conds.push_back("static_cast<int64_t>(ball_length(BallDyn(" + subject + "))) == " +
                std::to_string(elements.size()));
            for (int i = 0; i < (int)elements.size(); i++) {
                auto sub = _compileStructuredPattern(
                    *elements[i],
                    elemAccess(subject, std::to_string(i)),
                    exprFn);
                if (sub) {
                    if (sub->condition != "true") conds.push_back(sub->condition);
                    binds.insert(binds.end(), sub->bindings.begin(), sub->bindings.end());
                }
            }
        }

        std::string combined;
        for (size_t i = 0; i < conds.size(); i++) {
            if (i > 0) combined += " && ";
            combined += conds[i];
        }
        return StructuredPatternResult{combined.empty() ? "true" : combined, binds};
    }

    // MapPattern: check that map contains required keys and bind values
    if (kind == "MapPattern") {
        auto* entriesExpr = _patternField(patternExpr, "entries");
        std::vector<const ball::v1::Expression*> entries;
        if (entriesExpr &&
            entriesExpr->expr_case() == ball::v1::Expression::kLiteral &&
            entriesExpr->literal().value_case() == ball::v1::Literal::kListValue) {
            for (const auto& e : entriesExpr->literal().list_value().elements()) {
                entries.push_back(&e);
            }
        }

        std::vector<std::string> conds;
        std::vector<std::pair<std::string, std::string>> binds;
        conds.push_back("ball_is_map_dyn(BallDyn(" + subject + "))");

        for (auto* entry : entries) {
            std::string key = _patternStringField(*entry, "key");
            auto* valPattern = _patternField(*entry, "value");
            if (key.empty() || !valPattern) continue;

            // Check containsKey
            conds.push_back("BallDyn(" + subject + ").containsKey(\"" + key + "\"s)");

            // Recurse into value pattern
            std::string valueAccess = "static_cast<BallDyn>(BallDyn(" + subject + "))[\"" + key + "\"s]";
            auto sub = _compileStructuredPattern(*valPattern, valueAccess, exprFn);
            if (sub) {
                if (sub->condition != "true") conds.push_back(sub->condition);
                binds.insert(binds.end(), sub->bindings.begin(), sub->bindings.end());
            }
        }

        std::string combined;
        for (size_t i = 0; i < conds.size(); i++) {
            if (i > 0) combined += " && ";
            combined += conds[i];
        }
        return StructuredPatternResult{combined.empty() ? "true" : combined, binds};
    }

    // Record pattern: extract named fields from a record (map or tuple)
    if (kind == "record") {
        auto* fieldsExpr = _patternField(patternExpr, "fields");
        std::vector<const ball::v1::Expression*> fields;
        if (fieldsExpr &&
            fieldsExpr->expr_case() == ball::v1::Expression::kLiteral &&
            fieldsExpr->literal().value_case() == ball::v1::Literal::kListValue) {
            for (const auto& e : fieldsExpr->literal().list_value().elements()) {
                fields.push_back(&e);
            }
        }

        std::vector<std::string> conds;
        std::vector<std::pair<std::string, std::string>> binds;

        for (auto* field : fields) {
            std::string name = _patternStringField(*field, "name");
            auto* pattern = _patternField(*field, "pattern");
            if (name.empty() || !pattern) continue;

            // Access via operator[] with string key (works for map-backed records)
            std::string fieldAccess = "static_cast<BallDyn>(BallDyn(" + subject + "))[\"" + name + "\"s]";
            auto sub = _compileStructuredPattern(*pattern, fieldAccess, exprFn);
            if (sub) {
                if (sub->condition != "true") conds.push_back(sub->condition);
                binds.insert(binds.end(), sub->bindings.begin(), sub->bindings.end());
            }
        }

        std::string combined;
        for (size_t i = 0; i < conds.size(); i++) {
            if (i > 0) combined += " && ";
            combined += conds[i];
        }
        return StructuredPatternResult{combined.empty() ? "true" : combined, binds};
    }

    // RestPattern standalone (shouldn't occur outside ListPattern)
    if (kind == "RestPattern" || kind == "rest") {
        auto* subpattern = _patternField(patternExpr, "subpattern");
        if (subpattern) {
            return _compileStructuredPattern(*subpattern, subject, exprFn);
        }
        return StructuredPatternResult{"true", {}};
    }

    // LogicalOrPattern: handled separately via _collectOrPatternValues
    // Unknown kind: return nullopt to fall through to text-based handling
    return std::nullopt;
}

// Returns true when the expression is a MessageCreation with empty typeName
// and exactly two fields named "key" and "value" — the Ball IR encoding of
// a Dart map literal entry (e.g. `k: v`).
static bool _isMapEntrySentinel(const ball::v1::Expression& e) {
    if (e.expr_case() != ball::v1::Expression::kMessageCreation) return false;
    const auto& mc = e.message_creation();
    if (!mc.type_name().empty()) return false;
    if (mc.fields_size() != 2) return false;
    return mc.fields(0).name() == "key" && mc.fields(1).name() == "value";
}

// Follows through collection_if/collection_for bodies to determine whether the
// innermost leaf body produces map entries (key/value MessageCreation sentinels).
// This lets collection_for/set_create decide at compile time whether to emit
// map-building or list-building code.
static bool _bodyProducesMapEntries(const ball::v1::Expression& e) {
    if (_isMapEntrySentinel(e)) return true;
    // Unwrap collection_if: look at its "then" field.
    if (e.expr_case() == ball::v1::Expression::kCall) {
        const auto& fn = e.call().function();
        if (fn == "collection_if") {
            if (e.call().has_input() &&
                e.call().input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : e.call().input().message_creation().fields()) {
                    if (f.name() == "then") return _bodyProducesMapEntries(f.value());
                }
            }
            return false;
        }
        // Unwrap nested collection_for: look at its "body" field.
        if (fn == "collection_for") {
            if (e.call().has_input() &&
                e.call().input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : e.call().input().message_creation().fields()) {
                    if (f.name() == "body") return _bodyProducesMapEntries(f.value());
                }
            }
            return false;
        }
    }
    return false;
}

// Compile a map entry sentinel (MessageCreation with key/value fields) as a
// map insertion statement: `__m[ball_to_string(<key>)] = std::any(<value>);`
// This is used by collection_for/collection_if when they detect map entry
// bodies.
std::string CppCompiler::compile_map_entry_insert(const ball::v1::Expression& e,
                                                    const std::string& map_var) {
    const auto& mc = e.message_creation();
    std::string key_expr, val_expr;
    for (const auto& f : mc.fields()) {
        if (f.name() == "key") key_expr = compile_expr(f.value());
        else if (f.name() == "value") val_expr = compile_expr(f.value());
    }
    return map_var + "[ball_to_string(" + key_expr + ")] = std::any(BallDyn(" + val_expr + "));";
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
    return expr ? compile_expr(*expr) : "BallDyn()";
}

// Returns the compiled field value, or "" if the field is absent or null.
// Use for optional arguments (e.g., the "end" parameter of substring).
std::string CppCompiler::get_optional_field(const ball::v1::FunctionCall& call,
                                             const std::string& field_name) {
    auto* expr = get_message_field_expr(call, field_name);
    if (!expr) return "";
    // Null reference (name "null" or empty reference)
    if (expr->expr_case() == ball::v1::Expression::kReference &&
        (expr->reference().name() == "null" || expr->reference().name().empty()))
        return "";
    // Null literal (default/unset literal value)
    if (expr->expr_case() == ball::v1::Expression::kLiteral &&
        expr->literal().value_case() == ball::v1::Literal::VALUE_NOT_SET)
        return "";
    return compile_expr(*expr);
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

// Recursively detect a `return` or labeled break/continue in an expression,
// WITHOUT descending into nested lambdas (their returns are their own). Used to
// decide whether a for/while in EXPRESSION context can be emitted as a real
// loop: a real loop with a real statement body handles break/continue and
// nested loops natively, but `return` would escape the wrapping IIFE rather
// than the enclosing function, and labeled break/continue rely on goto labels
// emitted in statement context. Those two cases fall back to the stub.
static bool _exprHasReturnOrLabel(const ball::v1::Expression& e) {
    using E = ball::v1::Expression;
    switch (e.expr_case()) {
        case E::kCall: {
            const auto& fn = e.call().function();
            if (fn == "return" || fn == "labeled") return true;
            // Labeled break/continue compile to a `goto __ball_*_<label>`,
            // whose target label is planted by the *enclosing* loop in
            // statement context. A goto cannot cross the IIFE boundary of an
            // expression-context loop, so a body containing one must fall back
            // to the stub. Unlabeled break/continue act on the loop natively
            // and are fine inside the IIFE — don't flag those.
            if (fn == "break" || fn == "continue") {
                if (e.call().has_input() &&
                    e.call().input().expr_case() == E::kMessageCreation) {
                    for (const auto& f :
                         e.call().input().message_creation().fields()) {
                        if (f.name() == "label" && f.has_value() &&
                            f.value().expr_case() == E::kLiteral &&
                            f.value().literal().value_case() ==
                                ball::v1::Literal::kStringValue &&
                            !f.value().literal().string_value().empty()) {
                            return true;
                        }
                    }
                }
            }
            return e.call().has_input() && _exprHasReturnOrLabel(e.call().input());
        }
        case E::kLambda:
            return false;
        case E::kBlock: {
            for (const auto& s : e.block().statements()) {
                if (s.has_let() && _exprHasReturnOrLabel(s.let().value())) return true;
                if (s.has_expression() && _exprHasReturnOrLabel(s.expression())) return true;
            }
            return e.block().has_result() && _exprHasReturnOrLabel(e.block().result());
        }
        case E::kMessageCreation: {
            for (const auto& f : e.message_creation().fields())
                if (f.has_value() && _exprHasReturnOrLabel(f.value())) return true;
            return false;
        }
        case E::kFieldAccess:
            return e.field_access().has_object() &&
                   _exprHasReturnOrLabel(e.field_access().object());
        case E::kLiteral:
            if (e.literal().value_case() == ball::v1::Literal::kListValue)
                for (const auto& el : e.literal().list_value().elements())
                    if (_exprHasReturnOrLabel(el)) return true;
            return false;
        default:
            return false;
    }
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

    // Engine runtime intrinsics — insertion-ordered map factory.
    if (mod.empty() && fn == "_ballUserMap") {
        return "BallDyn(BallOrderedMap{})";
    }
    if (mod.empty() && fn == "_ballNewGenerator") {
        return "BallDyn(BallGenerator{})";
    }
    if (mod.empty() && fn == "_ballGeneratorValues") {
        std::string gen = call.has_input() ? compile_expr(call.input()) : "BallDyn()";
        return "_ballGeneratorValues(BallDyn(" + gen + "))";
    }
    if (mod.empty() && fn == "_ballDoubleToInt64") {
        std::string val = "BallDyn()";
        if (call.has_input()) {
            if (call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "arg0" || f.name() == "value") {
                        val = compile_expr(f.value());
                        break;
                    }
                }
            } else {
                val = compile_expr(call.input());
            }
        }
        return "_ballDoubleToInt64(BallDyn(" + val + "))";
    }
    if (mod.empty() && fn == "_ballCodeUnitAt") {
        std::string s = "BallDyn()";
        std::string idx = "0LL";
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == "arg0" || f.name() == "s") s = compile_expr(f.value());
                else if (f.name() == "arg1" || f.name() == "index") idx = compile_expr(f.value());
            }
        }
        return "ball_code_unit_at(BallDyn(" + s + "), static_cast<int64_t>(" + idx + "))";
    }
    if (mod.empty() && fn == "_ballIsInt") {
        std::string val = call.has_input() ? compile_expr(call.input()) : "BallDyn()";
        return "(ball_is_int(BallDyn(" + val + ")) || ball_object_type_matches(BallDyn(" + val + "), \"BallInt\"s))";
    }
    if (mod.empty() && fn == "_ballIsDouble") {
        std::string val = call.has_input() ? compile_expr(call.input()) : "BallDyn()";
        return "(ball_is_double(BallDyn(" + val + ")) || ball_object_type_matches(BallDyn(" + val + "), \"BallDouble\"s))";
    }
    if (mod.empty() && fn == "_ballIsNum") {
        std::string val = call.has_input() ? compile_expr(call.input()) : "BallDyn()";
        return "((ball_is_int(BallDyn(" + val + ")) || ball_is_double(BallDyn(" + val + "))) || ball_object_type_matches(BallDyn(" + val + "), \"BallInt\"s) || ball_object_type_matches(BallDyn(" + val + "), \"BallDouble\"s))";
    }
    if (mod.empty() && fn == "_ballIsString") {
        std::string val = call.has_input() ? compile_expr(call.input()) : "BallDyn()";
        return "(ball_is_string(BallDyn(" + val + ")) || ball_object_type_matches(BallDyn(" + val + "), \"BallString\"s))";
    }
    if (mod.empty() && fn == "_ballIsBool") {
        std::string val = call.has_input() ? compile_expr(call.input()) : "BallDyn()";
        return "(ball_is_bool(BallDyn(" + val + ")) || ball_object_type_matches(BallDyn(" + val + "), \"BallBool\"s))";
    }
    if (mod.empty() && fn == "_ballIsList") {
        std::string val = call.has_input() ? compile_expr(call.input()) : "BallDyn()";
        return "(ball_is_list(BallDyn(" + val + ")) || ball_object_type_matches(BallDyn(" + val + "), \"BallList\"s))";
    }
    // Inlined fast-paths for the private `_ballMap*` map helpers. These are
    // positional calls — `_ballMapSetDyn(raw, key, value)` — so the input
    // messageCreation carries fields named arg0/arg1/arg2 (a named field of the
    // same role is accepted as a fallback). Extract by position; default to a
    // safe empty BallDyn() only when genuinely absent. (Each helper is also
    // emitted as a real C++ function, so the logic here mirrors those bodies.)
    if (mod.empty() &&
        (fn == "_ballIsMap" || fn == "_ballMapValues" ||
         fn == "_ballMapValuesDyn" || fn == "_ballMapKeysDyn" ||
         fn == "_ballMapSetDyn" || fn == "_ballMapContainsKeyDyn")) {
        // Positional-argument extractor: arg<idx>, then [named], then BallDyn().
        auto argAt = [&](int idx, const char* named) -> std::string {
            if (!call.has_input()) return "BallDyn()";
            if (call.input().expr_case() !=
                ball::v1::Expression::kMessageCreation) {
                // A bare single argument is the whole input.
                return idx == 0 ? compile_expr(call.input())
                                : std::string("BallDyn()");
            }
            const std::string pos = "arg" + std::to_string(idx);
            std::string named_match;
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == pos) return compile_expr(f.value());
                if (named && f.name() == named) {
                    named_match = compile_expr(f.value());
                }
            }
            return named_match.empty() ? "BallDyn()" : named_match;
        };

        if (fn == "_ballIsMap") {
            const std::string val = argAt(0, "map");
            return "(ball_is_map_dyn(BallDyn(" + val +
                   ")) || ball_object_type_matches(BallDyn(" + val +
                   "), \"BallMap\"s))";
        }
        if (fn == "_ballMapValues" || fn == "_ballMapValuesDyn") {
            return "ball_list_copy(ball_map_values(BallDyn(" + argAt(0, "map") +
                   ")))";
        }
        if (fn == "_ballMapKeysDyn") {
            return "ball_list_copy(ball_map_keys(BallDyn(" + argAt(0, "map") +
                   ")))";
        }
        if (fn == "_ballMapSetDyn") {
            return "([](BallDyn m, BallDyn k, BallDyn v){ball_set(m, "
                   "std::string(ball_to_string(BallDyn(k))), "
                   "std::any(BallDyn(v))); return BallDyn();}(" +
                   argAt(0, "map") + "," + argAt(1, "key") + "," +
                   argAt(2, "value") + "))";
        }
        // _ballMapContainsKeyDyn
        return "(BallDyn(" + argAt(0, "map") + ").count(BallDyn(" +
               argAt(1, "key") + ")) > 0)";
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

    // Dart top-level function: identical(a, b) → identity check.
    // For doubles: identical(NaN, NaN) is true, identical(-0.0, 0.0) is false.
    // For ints/strings/bools: value equality. For objects: reference equality.
    if (fn == "identical") {
        auto a = get_message_field(call, "arg0");
        auto b = get_message_field(call, "arg1");
        return "ball_identical(BallDyn(" + a + "), BallDyn(" + b + "))";
    }

    // Constructor call: `main:ClassName.new` or `module:Class.new`
    // Emit as `ClassName(args)` instead of `ClassName_new(args)`.
    {
        auto dot_new = fn.rfind(".new");
        if (dot_new != std::string::npos && dot_new + 4 == fn.size()) {
            // Extract the class name part before ".new"
            std::string class_part = fn.substr(0, dot_new);
            std::string class_name = sanitize_name(class_part);
            // Verify it's a known user class
            if (user_class_names_.count(class_name) > 0) {
                std::string result = class_name + "(";
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
        // Use [&] lambda to prevent MSVC from constant-folding 0.0/0.0
        // (which triggers compile-time error C2124 "divide or mod by zero").
        return "[&]{ double _l = static_cast<double>(" + get_message_field(call, "left") +
               "); double _r = static_cast<double>(" + get_message_field(call, "right") +
               "); return _l / _r; }()";
    }
    if (fn == "modulo") {
        auto l = get_message_field(call, "left");
        auto r = get_message_field(call, "right");
        return "[&](int64_t _a, int64_t _b){ auto _r = _a % _b; return _r < 0 ? _r + (_b < 0 ? -_b : _b) : _r; }(static_cast<int64_t>(" + l + "), static_cast<int64_t>(" + r + "))";
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
        if (op == "??=") {
            // Dart's null-aware assignment: assign only when LHS is null /
            // empty BallDyn. Lower to a ternary that mirrors Dart's
            // `(<lhs> ??= <rhs>)` value semantics (returns the resulting
            // value).
            return "((BallDyn(" + target + ").has_value()) ? BallDyn(" +
                   target + ") : (" + target + " = " + val + "))";
        }
        // When the target is a field access (obj["field"]) or index (obj[idx]),
        // use ball_set() free function instead of plain assignment, because
        // BallDyn's operator[] returns by value. ball_set works for both
        // BallDyn and std::map<std::string, std::any>.
        if (op == "=" && target_expr) {
            if (target_expr->expr_case() == ball::v1::Expression::kFieldAccess) {
                auto obj = compile_expr(target_expr->field_access().object());
                auto field = target_expr->field_access().field();
                std::string sfield = sanitize_name(field);
                // Check if this field has a setter method on a user class.
                bool has_setter = false;
                for (const auto& [cls, setters] : class_setters_) {
                    if (setters.count(sfield)) { has_setter = true; break; }
                }
                if (has_setter) {
                    // Call setter: obj.field(value)
                    // Setter return is void; the assign expression evaluates to the value.
                    return "(" + obj + "." + sfield + "(" + val + "), " + val + ")";
                }
                // Check if this is a direct struct field on a user class.
                bool is_plain_field = false;
                for (const auto& [cls, td_ptr] : class_typedefs_) {
                    if (!td_ptr || !td_ptr->has_descriptor_()) continue;
                    for (const auto& fd : td_ptr->descriptor_().field()) {
                        if (sanitize_name(fd.name()) == sfield) {
                            is_plain_field = true;
                            break;
                        }
                    }
                    if (is_plain_field) break;
                }
                if (is_plain_field) {
                    return "(" + obj + "." + sfield + " = " + val + ")";
                }
                return "(ball_set(" + obj + ", std::string(\"" + field + "\"), std::any(" + val + ")), " + val + ")";
            }
            // Index expression: std.index(target, index) in the target
            if (target_expr->expr_case() == ball::v1::Expression::kCall &&
                (target_expr->call().module() == "std" ||
                 target_expr->call().module().empty()) &&
                target_expr->call().function() == "index") {
                auto tgt = get_message_field(target_expr->call(), "target");
                auto idx = get_message_field(target_expr->call(), "index");
                return "(ball_set(" + tgt + ", std::string(ball_to_string(BallDyn(" + idx + "))), std::any(" + val + ")), " + val + ")";
            }
        }
        // Plain identifier (lvalue) target with `=`: use ball_assign so a
        // std::string target assigned a BallDyn routes through ball_to_string
        // (gcc/clang reject the ambiguous std::string::operator=(BallDyn)).
        // Only for Reference targets — ball_assign binds target by lvalue ref,
        // whereas other targets (e.g. a null-safe ternary) compile to a
        // temporary BallDyn that must keep the direct rvalue operator=. Compound
        // ops (+=, -=, …) also assign directly.
        if (op == "=" && target_expr &&
            target_expr->expr_case() == ball::v1::Expression::kReference) {
            return "ball_assign(" + target + ", " + val + ")";
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
    if (fn == "string_length") return "ball_length(BallDyn(" + get_message_field(call, "value") + "))";
    if (fn == "string_is_empty") return get_message_field(call, "value") + ".empty()";
    if (fn == "string_contains") return "(" + get_message_field(call, "left") + ".find(" +
                                          get_message_field(call, "right") + ") != std::string::npos)";
    if (fn == "string_substring") {
        auto v = get_message_field(call, "value");
        auto s = get_message_field(call, "start");
        auto e = get_optional_field(call, "end");
        // UTF-16 code-unit indexing (Dart parity). ASCII strings hit a fast path.
        if (e.empty()) return "ball_string_substring(BallDyn(" + v + "), " + s + ")";
        return "ball_string_substring(BallDyn(" + v + "), " + s + ", " + e + ")";
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
        auto* delim_e = get_message_field_expr(call, "separator");
        if (!delim_e) delim_e = get_message_field_expr(call, "arg1");
        auto delim = delim_e ? compile_expr(*delim_e) : "\",\"s";
        return "[](const BallDyn& sv,const BallDyn& dv) -> BallDyn {"
               "auto s=ball_to_string(sv);auto d=ball_to_string(dv);"
               "BallList r;"
               "if(d.empty()){for(char c:s)r.push_back(std::any(std::string(1,c)));return BallDyn(r);}"
               "size_t p=0,f;"
               "while((f=s.find(d,p))!=std::string::npos){"
               "r.push_back(std::any(s.substr(p,f-p)));p=f+d.size();}"
               "r.push_back(std::any(s.substr(p)));return BallDyn(r);"
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
    // string_join can come from either std or std_collections
    if (fn == "string_join") {
        auto list = get_message_field(call, "list");
        auto sep = get_optional_field(call, "separator");
        if (sep.empty()) sep = "\" \"s";
        return "[](const BallDyn& v, const std::string& s){"
               "std::string r;for(size_t i=0;i<v.size();i++){"
               "if(i>0)r+=s;r+=ball_to_string(std::any(v[static_cast<int64_t>(i)]));}return r;}(" + list + "," + sep + ")";
    }
    // ── Regex ──
    if (fn == "regex_match") {
        auto input = get_message_field(call, "left");
        auto pat = get_message_field(call, "right");
        return "std::regex_search(ball_to_string(" + input + "), std::regex(ball_to_string(" + pat + ")))";
    }
    if (fn == "regex_find") {
        auto input = get_message_field(call, "left");
        auto pat = get_message_field(call, "right");
        return "[](const std::string& s,const std::string& p){"
               "std::smatch m;if(std::regex_search(s,m,std::regex(p)))return m[0].str();"
               "return std::string();}(ball_to_string(" + input + "),ball_to_string(" + pat + "))";
    }
    if (fn == "regex_find_all") {
        auto input = get_message_field(call, "left");
        auto pat = get_message_field(call, "right");
        return "[](const std::string& s,const std::string& p){"
               "std::vector<std::string> r;std::regex re(p);"
               "auto it=std::sregex_iterator(s.begin(),s.end(),re);"
               "for(;it!=std::sregex_iterator();++it)r.push_back((*it)[0].str());"
               "return r;}(ball_to_string(" + input + "),ball_to_string(" + pat + "))";
    }
    if (fn == "regex_replace") {
        auto str = get_message_field(call, "value");
        auto from = get_message_field(call, "from");
        auto to = get_message_field(call, "to");
        return "std::regex_replace(ball_to_string(" + str + "),std::regex(ball_to_string(" + from + ")),ball_to_string(" + to + "),std::regex_constants::format_first_only)";
    }
    if (fn == "regex_replace_all") {
        auto str = get_message_field(call, "value");
        auto from = get_message_field(call, "from");
        auto to = get_message_field(call, "to");
        return "std::regex_replace(ball_to_string(" + str + "),std::regex(ball_to_string(" + from + ")),ball_to_string(" + to + "))";
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
        auto else_val = get_optional_field(call, "else");
        auto is_throw = [](const ball::v1::Expression* e) -> bool {
            if (!e) return false;
            if (e->expr_case() == ball::v1::Expression::kCall &&
                e->call().function() == "throw") return true;
            return false;
        };
        auto wrap = [&](const std::string& code, const ball::v1::Expression* expr) {
            if (is_throw(expr)) return "(" + code + ", BallDyn())";
            return std::string("BallDyn(" + code + ")");
        };
        if (!else_val.empty()) {
            auto* then_expr = get_message_field_expr(call, "then");
            auto* else_expr = get_message_field_expr(call, "else");
            return "(BallDyn(" + cond + " ? " + wrap(then, then_expr) + " : " + wrap(else_val, else_expr) + "))";
        }
        auto* then_expr = get_message_field_expr(call, "then");
        return "[&]() -> BallDyn {if (" + cond + ") {return " + wrap(then, then_expr) + ";} return BallDyn();}()";
    }
    if (fn == "for") {
        // A `for` in EXPRESSION context (e.g. inside a lambda body compiled as
        // an expression). We can emit a real loop IIFE only when the body has no
        // break/continue/return/nested-loop (those can't cross the IIFE
        // boundary); otherwise fall back to the stub. This unblocks
        // _evalLambda's jump-free arg->param binding loop (multi-param lambda
        // callbacks) without breaking bodies like the engine's sort (which has
        // break). See SELF_HOST_STATUS.md.
        auto* body_e = get_message_field_expr(call, "body");
        if (body_e && !_exprHasReturnOrLabel(*body_e)) {
            std::string init;
            auto* init_e = get_message_field_expr(call, "init");
            if (init_e && init_e->expr_case() == ball::v1::Expression::kBlock &&
                init_e->block().statements_size() == 1 &&
                init_e->block().statements(0).stmt_case() == ball::v1::Statement::kLet) {
                const auto& let_stmt = init_e->block().statements(0).let();
                init = "auto " + ball_local_var_name(sanitize_name(let_stmt.name())) +
                       " = " + compile_expr(let_stmt.value());
            } else if (init_e &&
                       init_e->expr_case() == ball::v1::Expression::kLiteral &&
                       init_e->literal().value_case() == ball::v1::Literal::kStringValue) {
                std::string raw = init_e->literal().string_value();
                if (raw.rfind("var ", 0) == 0) init = "auto " + raw.substr(4);
                else if (raw.rfind("final ", 0) == 0) init = "auto " + raw.substr(6);
                else init = raw;
            } else {
                init = get_message_field(call, "init");
            }
            auto cond = get_message_field(call, "condition");
            auto update = get_message_field(call, "update");
            // Real statement body so break/continue act on this for natively.
            std::string body = (body_e->expr_case() == ball::v1::Expression::kBlock)
                                   ? compile_block_statements(body_e->block())
                                   : (compile_expr(*body_e) + ";\n");
            return "([&]() -> BallDyn { for (" + init + "; " + cond + "; " +
                   update + ") {\n" + body + "} return BallDyn(); }())";
        }
        // Body has a `return`/labeled jump that can't cross the IIFE boundary.
        return "([&](){\n" + indent_str() + "    // for loop (return/label body — see SELF_HOST_STATUS.md)\n" + indent_str() + "}(), BallDyn())";
    }
    if (fn == "while") {
        auto* body_e = get_message_field_expr(call, "body");
        if (body_e && !_exprHasReturnOrLabel(*body_e)) {
            auto cond = get_message_field(call, "condition");
            std::string body = (body_e->expr_case() == ball::v1::Expression::kBlock)
                                   ? compile_block_statements(body_e->block())
                                   : (compile_expr(*body_e) + ";\n");
            return "([&]() -> BallDyn { while (" + cond + ") {\n" + body +
                   "} return BallDyn(); }())";
        }
        return "([&](){\n" + indent_str() + "    // while loop\n" + indent_str() + "}(), BallDyn())";
    }
    if (fn == "return") {
        if (in_generator_) {
            // In a generator, return stops yielding and returns the collected values.
            return "/* return */ BallDyn(*__gen.values)";
        }
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
        return "static_cast<BallDyn>(" + target + ")[" + idx + "]";
    }

    // ── Math ──
    if (fn == "math_abs") {
        auto v = get_message_field(call, "value");
        return "[](BallDyn _v) -> BallDyn { if(_v.type()==typeid(int64_t))return BallDyn(std::abs(static_cast<int64_t>(_v))); return BallDyn(std::abs(static_cast<double>(_v))); }(" + v + ")";
    }
    // std math functions take floating args; a BallDyn argument is ambiguous
    // under gcc/clang (multiple user conversions: operator double vs int64_t),
    // so cast to double explicitly. (MSVC tolerated the bare BallDyn.)
    if (fn == "math_floor") return "static_cast<int64_t>(std::floor(static_cast<double>(" + get_message_field(call, "value") + ")))";
    if (fn == "math_ceil") return "static_cast<int64_t>(std::ceil(static_cast<double>(" + get_message_field(call, "value") + ")))";
    if (fn == "math_round") return "static_cast<int64_t>(std::round(static_cast<double>(" + get_message_field(call, "value") + ")))";
    if (fn == "math_sqrt") return "std::sqrt(static_cast<double>(" + get_message_field(call, "value") + "))";
    if (fn == "math_pow") return "std::pow(static_cast<double>(" + get_message_field(call, "left") + "), static_cast<double>(" + get_message_field(call, "right") + "))";
    if (fn == "math_min") return "std::min(" + get_message_field(call, "left") + ", " + get_message_field(call, "right") + ")";
    if (fn == "math_max") return "std::max(" + get_message_field(call, "left") + ", " + get_message_field(call, "right") + ")";
    if (fn == "math_pi") return "3.141592653589793";
    if (fn == "math_e") return "2.718281828459045";
    if (fn == "math_log") return "std::log(static_cast<double>(" + get_message_field(call, "value") + "))";
    if (fn == "math_sin") return "std::sin(static_cast<double>(" + get_message_field(call, "value") + "))";
    if (fn == "math_cos") return "std::cos(static_cast<double>(" + get_message_field(call, "value") + "))";

    // ── Type system ──
    if (fn == "is" || fn == "is_not") {
        auto val = get_message_field(call, "value");
        // Use get_string_field to extract the raw type name string,
        // not the compiled C++ literal (which would be e.g. "Map"s).
        std::string full_tn = get_string_field(call, "type");
        // Extract base type and generic type args (e.g. "Box<int>" → "Box", "<int>")
        std::string type_args;
        std::string tn = full_tn;
        auto lt = tn.find('<');
        if (lt != std::string::npos) {
            type_args = tn.substr(lt);  // e.g. "<int>"
            tn = tn.substr(0, lt);
        }
        if (!tn.empty() && tn.back() == '?') tn.pop_back();
        auto col = tn.find(':'); if (col != std::string::npos) tn = tn.substr(col + 1);
        std::string ck;
        if (tn == "Map" || tn == "HashMap") {
            if (!type_args.empty()) {
                // Reified Map<K,V>: check value type of first entry.
                // Extract V from "<K, V>" — take the part after the first comma.
                std::string inner = type_args.substr(1, type_args.size() - 2); // strip < >
                std::string val_type;
                auto comma = inner.find(',');
                if (comma != std::string::npos) {
                    val_type = inner.substr(comma + 1);
                    // Trim leading whitespace
                    auto ws = val_type.find_first_not_of(" \t");
                    if (ws != std::string::npos) val_type = val_type.substr(ws);
                }
                if (!val_type.empty()) {
                    ck = "ball_is_typed_map(" + val + ", \"" + val_type + "\"s)";
                } else {
                    ck = "ball_is_map_dyn(BallDyn(" + val + "))";
                }
            } else {
                ck = "ball_is_map_dyn(BallDyn(" + val + "))";
            }
        }
        else if (tn == "List" || tn == "Iterable") {
            if (!type_args.empty()) {
                // Reified List<T>: check element type of first element.
                // Extract T from "<T>" (strip angle brackets).
                std::string inner = type_args.substr(1, type_args.size() - 2);
                ck = "ball_is_typed_list(" + val + ", \"" + inner + "\"s)";
            } else {
                ck = "ball_is_list(" + val + ")";
            }
        }
        else if (tn == "String") ck = "ball_is_string(" + val + ")";
        else if (tn == "int") ck = "ball_is_int(" + val + ")";
        else if (tn == "double" || tn == "num") ck = "(ball_is_int(" + val + ") || ball_is_double(" + val + "))";
        else if (tn == "bool") ck = "ball_is_bool(" + val + ")";
        else if (tn == "Function") ck = "ball_is_function(" + val + ")";
        else if (tn == "_FlowSignal" || tn == "FlowSignal") ck = "ball_is_flow_signal(" + val + ")";
        else ck = "ball_object_type_matches(" + val + ", \"" + tn + "\"s)";
        // For reified generics on user types (e.g. `x is Box<int>`), also check
        // that the object's __type_args__ field matches the expected type args.
        if (!type_args.empty() && tn != "Map" && tn != "HashMap" &&
            tn != "List" && tn != "Iterable" && tn != "Set") {
            ck = "(" + ck + " && ball_type_args_match(" + val + ", \"" + type_args + "\"s))";
        }
        return fn == "is" ? ck : ("!(" + ck + ")");
    }
    if (fn == "as") return get_message_field(call, "value");
    if (fn == "null_coalesce") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "(BallDyn(" + left + ").has_value() ? BallDyn(" + left + ") : BallDyn(" + right + "))";
    }

    // ── Cascade / spread ──
    // `target..op1..op2` evaluates target once, applies each section (which
    // references the receiver as `__cascade_self__`), and yields the target.
    // Emit an IIFE so the sections' mutations (addAll, []=, method calls)
    // apply to a single shared receiver. Previously only the target was
    // emitted, silently dropping every cascade operation.
    if (fn == "cascade") {
        auto target = get_message_field(call, "target");
        auto* sections = get_message_field_expr(call, "sections");
        if (!sections || sections->expr_case() != ball::v1::Expression::kLiteral ||
            sections->literal().value_case() != ball::v1::Literal::kListValue) {
            return target;
        }
        std::string result = "[&]() { auto __cascade_self__ = BallDyn(" + target + ");";
        for (const auto& sec : sections->literal().list_value().elements()) {
            result += " (void)(" + compile_expr(sec) + ");";
        }
        result += " return __cascade_self__; }()";
        return result;
    }
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
        // Static type extraction for typed catches. Two encoder shapes are
        // produced for `throw <expr>`:
        //   1. messageCreation with a `__type` string field — used by the
        //      C++ encoder for typed throw literals.
        //   2. a constructor call like `FormatException.new(...)` — used by
        //      the Dart encoder for `throw FormatException("…")`. The
        //      function name carries the type; arguments become the
        //      exception message / fields.
        // Both are lifted into BallException with a real `type_name` so the
        // catch-side typed dispatch works. Fall back to the generic
        // "Exception" tag only when neither shape matches.
        auto* val_expr = get_message_field_expr(call, "value");
        std::string type_name = "Exception";
        bool is_msg = val_expr &&
                      val_expr->expr_case() == ball::v1::Expression::kMessageCreation;

        // Engine's own `throw BallException(typeName, value)` — the args are
        // RUNTIME values (references), not string literals, so the generic
        // is_msg path below would discard them. Preserve the runtime payload
        // via _ball_make_exception so a catch handler reads the real thrown
        // value (e["value"]) instead of the literal "Exception".
        if (is_msg) {
            std::string bare_t = sanitize_name(val_expr->message_creation().type_name());
            auto bc = bare_t.find(':');
            if (bc != std::string::npos) bare_t = bare_t.substr(bc + 1);
            if (bare_t == "BallException") {
                const ball::v1::Expression* tn_e = nullptr;
                const ball::v1::Expression* vn_e = nullptr;
                for (const auto& f : val_expr->message_creation().fields()) {
                    if (f.name() == "arg0" || f.name() == "typeName") tn_e = &f.value();
                    else if (f.name() == "arg1" || f.name() == "value") vn_e = &f.value();
                }
                std::string tn_expr = tn_e ? ("ball_to_string(" + compile_expr(*tn_e) + ")")
                                           : "std::string(\"Exception\")";
                std::string vn_expr = vn_e ? compile_expr(*vn_e) : "BallDyn()";
                return "throw _ball_make_exception(" + tn_expr + ", " + vn_expr + ")";
            }
        }
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
        // Constructor-call throw: `FormatException.new("bad input")`.
        // Pull the type name out of the function identifier so a typed
        // catch on `FormatException` actually matches.
        if (val_expr && val_expr->expr_case() == ball::v1::Expression::kCall) {
            const auto& cval = val_expr->call();
            const auto& fname = cval.function();
            if (!fname.empty()) {
                std::string ty = fname;
                // Strip module prefix `mod:Foo.new` → `Foo.new`.
                auto colon = ty.find(':');
                if (colon != std::string::npos) ty = ty.substr(colon + 1);
                // Strip trailing `.new` / `.<ctor>` so `Foo.new` → `Foo`.
                auto dot = ty.find('.');
                if (dot != std::string::npos) ty = ty.substr(0, dot);
                if (!ty.empty() && (std::isupper(static_cast<unsigned char>(ty.front())) ||
                                    ty == "Exception")) {
                    type_name = ty;
                }
            }
        }
        // Non-message value — route through _ball_make_exception so the real
        // thrown value is preserved as the payload (catch reads e["value"]),
        // and a `rethrow` (throw <caught-var>) re-raises the original exception
        // instead of double-wrapping the reconstructed DYN map.
        std::string message_expr = get_message_field(call, "value");
        return "throw _ball_make_exception(\"" + type_name + "\"s, " +
               message_expr + ")";
    }
    if (fn == "assert") {
        auto cond = get_message_field(call, "condition");
        return "assert(" + cond + ")";
    }
    if (fn == "switch_expr") {
        // Switch expression: evaluate subject, match against cases.
        // Supports ConstPattern, LogicalOrPattern, VarPattern (with type),
        // ListPattern, RestPattern, MapPattern, record patterns.
        auto subject = get_message_field(call, "subject");
        auto* cases_expr = get_message_field_expr(call, "cases");
        if (!cases_expr || cases_expr->expr_case() != ball::v1::Expression::kLiteral ||
            cases_expr->literal().value_case() != ball::v1::Literal::kListValue) {
            return "BallDyn()";
        }
        auto compileExprLambda = [this](const ball::v1::Expression& e) -> std::string {
            return compile_expr(e);
        };
        // Build if-else chain as IIFE
        std::string result = "[&]() -> BallDyn {\n";
        result += indent_str() + "  auto __subj = BallDyn(" + subject + ");\n";
        for (const auto& case_expr : cases_expr->literal().list_value().elements()) {
            if (case_expr.expr_case() != ball::v1::Expression::kMessageCreation) continue;
            std::string pattern;
            const ball::v1::Expression* body_expr = nullptr;
            const ball::v1::Expression* pattern_expr_ptr = nullptr;
            bool is_default = false;
            for (const auto& f : case_expr.message_creation().fields()) {
                if (f.name() == "pattern") pattern = compile_expr(f.value());
                if (f.name() == "body") body_expr = &f.value();
                if (f.name() == "pattern_expr") pattern_expr_ptr = &f.value();
                if (f.name() == "is_default" &&
                    f.value().expr_case() == ball::v1::Expression::kLiteral &&
                    f.value().literal().bool_value()) is_default = true;
            }
            if (is_default && body_expr) {
                result += indent_str() + "  return " + compile_expr(*body_expr) + ";\n";
                break;
            }
            if (!body_expr) continue;
            std::string body = compile_expr(*body_expr);

            // Try structured pattern_expr first
            if (pattern_expr_ptr) {
                // Try structured pattern (VarPattern, ListPattern, MapPattern, record, etc.)
                auto structured = _compileStructuredPattern(*pattern_expr_ptr, "__subj", compileExprLambda);
                if (structured) {
                    if (structured->condition == "true" && structured->bindings.empty()) {
                        // Wildcard / catch-all
                        result += indent_str() + "  return " + body + ";\n";
                        break;
                    }
                    std::string bodyStr;
                    if (!structured->bindings.empty()) {
                        // Wrap body in an IIFE that binds pattern variables
                        std::string params, args;
                        for (size_t bi = 0; bi < structured->bindings.size(); bi++) {
                            if (bi > 0) { params += ", "; args += ", "; }
                            params += "BallDyn " + structured->bindings[bi].first;
                            args += "BallDyn(" + structured->bindings[bi].second + ")";
                        }
                        bodyStr = "[&](" + params + ") -> BallDyn { return " + body + "; }(" + args + ")";
                    } else {
                        bodyStr = body;
                    }
                    result += indent_str() + "  if (" + structured->condition + ") return " + bodyStr + ";\n";
                    if (structured->condition == "true") break;
                    continue;
                }

                // Try or-pattern (LogicalOrPattern)
                std::vector<const ball::v1::Expression*> or_vals;
                _collectOrPatternValues(*pattern_expr_ptr, or_vals);
                if (!or_vals.empty()) {
                    std::string cond;
                    for (size_t oi = 0; oi < or_vals.size(); oi++) {
                        if (oi > 0) cond += " || ";
                        cond += "BallDyn(__subj) == BallDyn(" + compile_expr(*or_vals[oi]) + ")";
                    }
                    result += indent_str() + "  if (" + cond + ") return " + body + ";\n";
                    continue;
                }
            }

            // Fall back to text-based pattern matching
            if (!pattern.empty()) {
                // Normalize pattern (strip quotes and enum prefixes)
                auto sp = pattern;
                if (sp.size() >= 3 && sp[0] == '"' && sp.back() == 's' && sp[sp.size()-2] == '"') {
                    auto inner = sp.substr(1, sp.size() - 3);
                    if (inner.size() >= 2 && inner.front() == '\'' && inner.back() == '\'')
                        inner = inner.substr(1, inner.size() - 2);
                    auto dot = inner.rfind('.');
                    if (dot != std::string::npos && inner.find('_') < dot)
                        inner = inner.substr(dot + 1);
                    sp = "\"" + inner + "\"s";
                }
                if (sp == "\"_\"s" || sp == "\"default\"s") {
                    result += indent_str() + "  return " + body + ";\n";
                } else {
                    result += indent_str() + "  if (BallDyn(__subj) == BallDyn(" + sp + ")) return " + body + ";\n";
                }
            }
        }
        result += indent_str() + "  return BallDyn();\n";
        result += indent_str() + "}()";
        return result;
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

    // ── Async: await is always a no-op passthrough ──
    if (fn == "await") {
        return get_message_field(call, "value");
    }
    // ── Generators: yield / yield_each ──
    if (fn == "yield" || fn == "yield_each") {
        auto val = get_message_field(call, "value");
        if (in_generator_) {
            if (fn == "yield") {
                return "yield_(BallDyn(__gen), BallDyn(" + val + "))";
            } else {
                return "yieldAll(BallDyn(__gen), BallDyn(" + val + "))";
            }
        }
        // Outside a generator, passthrough (legacy behavior)
        return val;
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
            std::string out = "std::vector<std::any>{";
            for (size_t i = 0; i < positional.size(); ++i) {
                if (i) out += ", ";
                out += "std::any(" + positional[i] + ")";
            }
            out += "}";
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
            return "BallDyn(" + target + ".has_value() ? static_cast<BallDyn>(" + target + ")[" + index + "] : BallDyn())";
        }
        return target;
    }

    // ── null_check — unwrap nullable, just return the value ──
    if (fn == "null_check") {
        return get_message_field(call, "value");
    }

    // ── Collection constructors that sometimes appear in the std module
    //    rather than std_collections (encoder variation) ──
    if (fn == "set_create") {
        // set_create can carry an `elements` field with a list of element
        // expressions (possibly including collection_for / collection_if).
        // When those elements produce map entry sentinels (key/value pairs),
        // this is actually a map comprehension; otherwise it's a set/list.
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            const ball::v1::Expression* elements_expr = nullptr;
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == "elements") {
                    elements_expr = &f.value();
                    break;
                }
            }
            if (elements_expr &&
                elements_expr->expr_case() == ball::v1::Expression::kLiteral &&
                elements_expr->literal().value_case() == ball::v1::Literal::kListValue) {
                const auto& elems = elements_expr->literal().list_value().elements();
                if (elems.size() == 1) {
                    // Single element: compile directly (collection_for handles
                    // map vs list detection internally).
                    return compile_expr(elems.Get(0));
                }
                // Multiple elements: build a list.
                std::string result = "[&]() -> BallDyn { BallList __r; ";
                for (const auto& el : elems) {
                    result += "__r.push_back(std::any(BallDyn(" + compile_expr(el) + "))); ";
                }
                result += "return BallDyn(__r); }()";
                return result;
            }
        }
        return "std::vector<std::any>{}";
    }
    if (fn == "map_create") {
        // map_create can carry `entries` in input.
        // The Ball IR encodes map literals as:
        //   map_create({type_args: "K, V", entry: {key: k1, value: v1}, entry: {key: k2, value: v2}})
        // Note: multiple "entry" fields share the same name — we must expand them
        // into their key/value pairs rather than using the field name "entry" as a map key.
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation &&
            call.input().message_creation().fields_size() > 0) {
            // Check if this uses the "entry" pattern (multiple fields named "entry")
            bool has_entry = false;
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == "entry") { has_entry = true; break; }
            }
            if (has_entry) {
                // Build map by expanding entry fields: each entry has key+value subfields
                std::string result = "[&]() { std::map<std::string,std::any> __m; ";
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "type_args") continue;
                    if (f.name() == "entry" && f.has_value() &&
                        f.value().expr_case() == ball::v1::Expression::kMessageCreation) {
                        std::string key_expr, val_expr;
                        for (const auto& ef : f.value().message_creation().fields()) {
                            if (ef.name() == "key") key_expr = compile_expr(ef.value());
                            else if (ef.name() == "value") val_expr = compile_expr(ef.value());
                        }
                        if (!key_expr.empty() && !val_expr.empty()) {
                            // Check if value is a lambda (starts with [) — wrap in BallDyn for BallFunc conversion
                            bool is_lambda = !val_expr.empty() && val_expr[0] == '[';
                            if (is_lambda) {
                                result += "__m[ball_to_string(" + key_expr + ")] = std::any(BallDyn(" + val_expr + ")); ";
                            } else {
                                result += "__m[ball_to_string(" + key_expr + ")] = std::any(" + val_expr + "); ";
                            }
                        }
                    } else if (f.name() == "element") {
                        // Comprehension element (collection_for / collection_if):
                        // compile it as a statement that inserts into __m.
                        result += compile_expr(f.value()) + "; ";
                    } else {
                        // Non-entry field: use field name as key
                        result += "__m[\"" + f.name() + "\"] = std::any(" + compile_expr(f.value()) + "); ";
                    }
                }
                result += "return __m; }()";
                return result;
            }
            // No entry fields: use direct field names as keys. Skip the
            // generic-type bookkeeping fields — they are metadata, not map data,
            // and emitting them pollutes the map (off-by-one length, phantom
            // entries in iteration). The entry-pattern branch above already
            // skips type_args; do the same here.
            std::string result = "std::map<std::string,std::any>{";
            bool first = true;
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == "type_args" || f.name() == "__type_args__") continue;
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
    // `typed_list` creates a list of a specific type. If it carries an
    // `elements` field, emit those elements; otherwise emit an empty vector.
    if (fn == "typed_list") {
        auto* elems_expr = get_message_field_expr(call, "elements");
        if (elems_expr &&
            elems_expr->expr_case() == ball::v1::Expression::kLiteral &&
            elems_expr->literal().value_case() == ball::v1::Literal::kListValue &&
            elems_expr->literal().list_value().elements_size() > 0) {
            return compile_expr(*elems_expr);
        }
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
        // Encoder shape `{target, method}`: route the method name through
        // method dispatch (so builtins like toInt/toDouble/round resolve)
        // rather than compiling the bare name to an empty BallDyn functor.
        auto method = get_string_field(call, "method");
        auto* target_expr = get_message_field_expr(call, "target");
        if (method == "call" && target_expr) {
            // `x?.call(args)` invokes x as a function (BallDyn::operator()),
            // NOT a named method — routing it through method dispatch would
            // emit a nonexistent free function `call(x)`.
            std::string args;
            if (call.has_input() &&
                call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "target" || f.name() == "method") continue;
                    if (!args.empty()) args += ", ";
                    args += compile_expr(f.value());
                }
            }
            return "(" + target + ".has_value() ? BallDyn(" + target + "(" + args +
                   ")) : BallDyn())";
        }
        if (!method.empty() && target_expr) {
            ball::v1::FunctionCall synth;
            synth.set_function(method);
            auto* mc = synth.mutable_input()->mutable_message_creation();
            auto* sf = mc->add_fields();
            sf->set_name("self");
            *sf->mutable_value() = *target_expr;
            // Forward any extra argument fields (everything but target/method).
            if (call.has_input() &&
                call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "target" || f.name() == "method") continue;
                    *mc->add_fields() = f;
                }
            }
            return "(" + target + ".has_value() ? BallDyn(" +
                   compile_method_call(method, synth) + ") : BallDyn())";
        }
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

    // ── String predicates / pad / trim / code units ──
    if (fn == "string_starts_with") {
        return "(ball_to_string(" + get_message_field(call, "value") +
               ").rfind(ball_to_string(" + get_message_field(call, "pattern") + "), 0) == 0)";
    }
    if (fn == "string_ends_with") {
        return "[](const std::string& s, const std::string& e){ return s.size() >= e.size() && "
               "s.compare(s.size() - e.size(), e.size(), e) == 0; }(ball_to_string(" +
               get_message_field(call, "value") + "), ball_to_string(" + get_message_field(call, "pattern") + "))";
    }
    if (fn == "string_trim_start") {
        return "[](const std::string& s){ auto a = s.find_first_not_of(\" \\t\\n\\r\"); "
               "return a == std::string::npos ? std::string() : s.substr(a); }(ball_to_string(" +
               get_message_field(call, "value") + "))";
    }
    if (fn == "string_trim_end") {
        return "[](const std::string& s){ auto b = s.find_last_not_of(\" \\t\\n\\r\"); "
               "return b == std::string::npos ? std::string() : s.substr(0, b + 1); }(ball_to_string(" +
               get_message_field(call, "value") + "))";
    }
    if (fn == "string_pad_left" || fn == "string_pad_right") {
        auto v = get_message_field(call, "value");
        auto w = get_message_field(call, "width");
        auto f = get_optional_field(call, "fill");
        if (f.empty()) f = "std::string(\" \")";
        std::string left = (fn == "string_pad_left") ? "true" : "false";
        return "[](std::string s, int64_t w, std::string f, bool left){ if (f.empty()) f = \" \"; "
               "while ((int64_t)s.size() < w) { if (left) s = f + s; else s = s + f; } return s; }(ball_to_string(" +
               v + "), static_cast<int64_t>(" + w + "), ball_to_string(" + f + "), " + left + ")";
    }
    if (fn == "string_code_unit_at") {
        return "ball_u16_code_unit_at(ball_to_string(" +
               get_message_field(call, "value") + "), static_cast<int64_t>(" + get_message_field(call, "index") + "))";
    }
    if (fn == "to_string_as_fixed") {
        return "[](double x, int64_t d){ std::ostringstream o; o << std::fixed << std::setprecision((int)d) << x; return o.str(); }("
               "static_cast<double>(" + get_message_field(call, "value") + "), static_cast<int64_t>(" +
               get_message_field(call, "digits") + "))";
    }
    // ── Comparison / math ──
    if (fn == "compare_to") {
        return "[](const BallDyn& a, const BallDyn& b) -> int64_t { if (a < b) return -1; if (b < a) return 1; return 0; }(" +
               get_message_field(call, "value") + ", " + get_message_field(call, "other") + ")";
    }
    if (fn == "math_trunc") {
        return "static_cast<int64_t>(std::trunc(static_cast<double>(" + get_message_field(call, "value") + ")))";
    }
    if (fn == "math_clamp") {
        return "[](BallDyn v, BallDyn lo, BallDyn hi) -> BallDyn { if (v < lo) return lo; if (hi < v) return hi; return v; }(" +
               get_message_field(call, "value") + ", " + get_message_field(call, "min") + ", " + get_message_field(call, "max") + ")";
    }
    if (fn == "unsigned_right_shift") {
        return "static_cast<int64_t>(static_cast<uint64_t>(static_cast<int64_t>(" + get_message_field(call, "left") +
               ")) >> static_cast<int64_t>(" + get_message_field(call, "right") + "))";
    }
    // ── collection_if — conditional element in a collection literal ──
    // When the body is a map entry sentinel, emit a conditional map insertion;
    // otherwise emit a conditional list push. This handler is used from
    // within collection_for's IIFE where __m or __r is in scope.
    if (fn == "collection_if") {
        auto cond = get_message_field(call, "condition");
        auto* then_expr = get_message_field_expr(call, "then");
        auto* else_expr = get_message_field_expr(call, "else");
        if (then_expr && _bodyProducesMapEntries(*then_expr)) {
            // Map context: emit conditional map insertions.
            std::string result = "if (_ball_pred_true(" + cond + ")) { ";
            if (_isMapEntrySentinel(*then_expr)) {
                result += compile_map_entry_insert(*then_expr, "__m") + " ";
            } else {
                // Nested collection_for/collection_if — compile and execute.
                result += compile_expr(*then_expr) + "; ";
            }
            result += "}";
            if (else_expr) {
                result += " else { ";
                if (_isMapEntrySentinel(*else_expr)) {
                    result += compile_map_entry_insert(*else_expr, "__m") + " ";
                } else {
                    result += compile_expr(*else_expr) + "; ";
                }
                result += "}";
            }
            return result;
        }
        // List/set context: emit conditional list push.
        if (then_expr) {
            std::string then_val = compile_expr(*then_expr);
            std::string result = "if (_ball_pred_true(" + cond + ")) { __r.push_back(std::any(BallDyn(" + then_val + "))); }";
            if (else_expr) {
                result += " else { __r.push_back(std::any(BallDyn(" + compile_expr(*else_expr) + "))); }";
            }
            return result;
        }
        return "/* invalid collection_if */";
    }

    // ── for-in / collection-for as expressions (statement form is handled in
    // compile_statement; these fire when a for-in appears in expression
    // position, e.g. inside a block compiled as an IIFE) ──
    if (fn == "for_in" || fn == "collection_for") {
        auto* var_expr = get_message_field_expr(call, "variable");
        std::string var_name = "item";
        if (var_expr && var_expr->expr_case() == ball::v1::Expression::kLiteral)
            var_name = var_expr->literal().string_value();
        auto vn = ball_local_var_name(sanitize_name(var_name));
        auto iter = get_message_field(call, "iterable");
        if (fn == "collection_for") {
            auto* body_expr = get_message_field_expr(call, "body");
            if (body_expr && _bodyProducesMapEntries(*body_expr)) {
                // Map comprehension: build an insertion-ordered BallOrderedMap
                // (NOT a key-sorted std::map). Dart map comprehensions preserve
                // insertion order (LinkedHashMap); a std::map re-sorts keys,
                // which corrupts e.g. JSON encoding order (`{"name":..,"age":..}`
                // became `{"age":..,"name":..}`). BallOrderedMap::operator[] is
                // assignable, so compile_map_entry_insert works unchanged, and
                // `BallDyn(BallOrderedMap)` wraps it reference-semantically.
                std::string result = "[&]() -> BallDyn { BallOrderedMap __m; for (auto " +
                    vn + " : BallDyn(" + iter + ")) { ";
                if (_isMapEntrySentinel(*body_expr)) {
                    // Direct map entry: e.key: e.value
                    result += compile_map_entry_insert(*body_expr, "__m");
                } else {
                    // Nested collection_if or collection_for — compile as
                    // statements that insert into __m.
                    result += compile_expr(*body_expr) + ";";
                }
                result += " } return BallDyn(__m); }()";
                return result;
            }
            auto body = body_expr ? compile_expr(*body_expr) : "BallDyn()";
            return "[&]() -> BallDyn { BallList __r; for (auto " + vn + " : BallDyn(" + iter +
                   ")) { __r.push_back(std::any(BallDyn(" + body + "))); } return BallDyn(__r); }()";
        }
        auto body = get_message_field(call, "body");
        return "[&]() -> BallDyn { for (auto " + vn + " : BallDyn(" + iter +
               ")) { (void)(" + body + "); } return BallDyn(); }()";
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
    auto arg0 = get_optional_field(call, "arg0");
    auto arg1 = get_optional_field(call, "arg1");

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
        // UTF-16 code-unit length for strings (Dart parity); element count for
        // lists/maps. ball_length dispatches on the runtime type.
        return "ball_length(" + self + ")";
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
        return "(" + self + ".count(ball_to_string(BallDyn(" + arg0 + "))) > 0)";
    }
    if (fn == "remove") {
        return self + ".erase(" + arg0 + ")";
    }

    // ── String methods ──
    if (fn == "substring") {
        // UTF-16 code-unit indexing (Dart parity). ASCII strings hit a fast path.
        if (arg1.empty()) {
            return "ball_string_substring(BallDyn(" + self + "), " + arg0 + ")";
        }
        return "ball_string_substring(BallDyn(" + self + "), " + arg0 + ", " + arg1 + ")";
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
        // UTF-16 code unit at index (Dart parity); ASCII fast path inside helper.
        return "ball_code_unit_at(BallDyn(" + self + "), " + arg0 + ")";
    }

    // ── Number methods ──
    if (fn == "toDouble") {
        return "_ballToDouble(BallDyn(" + self + "))";
    }
    if (fn == "truncate") {
        return "_ballDoubleToInt64(BallDyn(" + self + "))";
    }
    if (fn == "toInt") {
        return "_ballDoubleToInt64(BallDyn(" + self + "))";
    }
    if (fn == "toString") {
        return "ball_to_string(" + self + ")";
    }
    if (fn == "abs") {
        // Type-preserving abs (int stays int) with an explicit cast so gcc/clang
        // don't see an ambiguous std::abs(BallDyn) overload.
        return "[](BallDyn _v) -> BallDyn { if(_v.type()==typeid(int64_t))return BallDyn(std::abs(static_cast<int64_t>(_v))); return BallDyn(std::abs(static_cast<double>(_v))); }(" + self + ")";
    }
    if (fn == "round") {
        return "static_cast<int64_t>(std::round(static_cast<double>(" + self + ")))";
    }
    if (fn == "ceil") {
        return "static_cast<int64_t>(std::ceil(static_cast<double>(" + self + ")))";
    }
    if (fn == "floor") {
        return "static_cast<int64_t>(std::floor(static_cast<double>(" + self + ")))";
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
        return "std::regex_search(ball_to_string(" + arg0 + "), ball_to_regex(" + self + "))";
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

    // Scope.bind(name, value) — ball_scope_bind avoids std::bind ADL and overload
    // ambiguity between string/BallDyn value overloads in MSVC builds.
    if (fn == "bind") {
        std::string nameArg = arg0;
        if (nameArg.empty()) nameArg = get_message_field(call, "name");
        std::string valArg = arg1;
        if (valArg.empty()) valArg = get_message_field(call, "value");
        return "ball_scope_bind(" + self + ", " + nameArg + ", BallDyn(" + valArg + "))";
    }

    // ── Async as synchronous passthrough ──
    // In C++ we simulate async: Future.value(x) → x, future.then(cb) → cb(future),
    // Future.wait(list) → list.
    if (fn == "value" && (self == "\"Future\"s" || self == "\"FutureOr\"s" ||
                          self == "Future" || self == "FutureOr")) {
        // Future.value(x) → just x
        return arg0.empty() ? "BallDyn()" : arg0;
    }
    if (fn == "then") {
        // future.then(callback) → callback(future)
        return "(" + arg0 + ")(" + self + ")";
    }
    if (fn == "wait" || fn == "wait_") {
        // Future.wait(list) → just the list (already evaluated synchronously)
        return arg0.empty() ? self : arg0;
    }

    // ── User-defined class method dispatch ──
    // If `fn` is a known user-class method, emit as `self.fn(args)`.
    // For super calls (self == "super" reference), emit `SuperClass::fn(args)`.
    // For static calls (self is a class name reference), emit `ClassName::fn(args)`.
    {
        std::string func_name = sanitize_name(fn);
        bool is_user_method = method_to_classes_.count(func_name) > 0;

        if (is_user_method) {
            // Check if this is a super call.
            bool is_super = false;
            if (call.has_input() &&
                call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "self" &&
                        f.value().expr_case() == ball::v1::Expression::kReference &&
                        f.value().reference().name() == "super") {
                        is_super = true;
                        break;
                    }
                }
            }

            // Check if this is a static call (self is a class name).
            bool is_static_call = false;
            std::string static_class_name;
            if (!is_super && call.has_input() &&
                call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "self" &&
                        f.value().expr_case() == ball::v1::Expression::kReference) {
                        std::string ref_name = f.value().reference().name();
                        if (user_class_names_.count(sanitize_name(ref_name)) > 0) {
                            is_static_call = true;
                            static_class_name = sanitize_name(ref_name);
                        }
                        break;
                    }
                }
            }

            // Collect non-self args.
            std::vector<std::string> args;
            if (call.has_input() &&
                call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "self") continue;
                    args.push_back(compile_expr(f.value()));
                }
            }
            auto join_args = [&]() {
                std::string r;
                for (size_t i = 0; i < args.size(); i++) {
                    if (i > 0) r += ", ";
                    r += args[i];
                }
                return r;
            };

            if (is_super) {
                // Super call: find the parent class of the current class.
                std::string super_class;
                // Look up current class's superclass.
                for (const auto& [cls, sup] : class_superclass_) {
                    auto cls_colon = cls.find(':');
                    std::string cls_bare = cls_colon != std::string::npos ? cls.substr(cls_colon + 1) : cls;
                    if (sanitize_name(cls_bare) == current_class_name_) {
                        super_class = sanitize_name(sup);
                        break;
                    }
                }
                if (!super_class.empty()) {
                    return super_class + "::" + func_name + "(" + join_args() + ")";
                }
            }

            if (is_static_call) {
                return static_class_name + "::" + func_name + "(" + join_args() + ")";
            }

            // Regular instance method call: self.method(args)
            return self + "." + func_name + "(" + join_args() + ")";
        }
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
        auto var_name = ball_local_var_name(sanitize_name(stmt.let().name()));
        auto val_str = compile_expr(stmt.let().value());

        // Check if the value is a user-class construction. If so, emit the
        // concrete class type so that method calls and field accesses resolve
        // directly on the struct (BallDyn wrapping erases the type and breaks
        // member access).
        bool is_user_class = false;
        std::string class_type;
        if (stmt.let().value().expr_case() == ball::v1::Expression::kMessageCreation) {
            const auto& mc = stmt.let().value().message_creation();
            const auto& tn = mc.type_name();
            if (!tn.empty()) {
                // If the messageCreation carries __type_args__, the value is
                // emitted as a dynamic map (reified generics), not a struct.
                bool has_type_args = false;
                for (const auto& f : mc.fields()) {
                    if (f.name() == "__type_args__") { has_type_args = true; break; }
                }
                if (!has_type_args) {
                    // Check if the sanitized bare name is a user class.
                    auto colon = tn.find(':');
                    auto bare = colon != std::string::npos ? tn.substr(colon + 1) : tn;
                    auto sbare = sanitize_name(bare);
                    if (user_class_names_.count(sbare) > 0) {
                        is_user_class = true;
                        class_type = sbare;
                    }
                }
            }
        }
        // Also check the let metadata for a type hint matching a user class.
        // Skip when the type has angle brackets (generic type) — the value
        // was emitted as a dynamic map for reified generics.
        if (!is_user_class && stmt.let().has_metadata()) {
            auto it = stmt.let().metadata().fields().find("type");
            if (it != stmt.let().metadata().fields().end() &&
                it->second.kind_case() == google::protobuf::Value::kStringValue) {
                std::string raw_type = it->second.string_value();
                if (raw_type.find('<') == std::string::npos) {
                    auto stype = sanitize_name(raw_type);
                    if (user_class_names_.count(stype) > 0) {
                        is_user_class = true;
                        class_type = stype;
                    }
                }
            }
        }

        // Track variables bound to generic (map-backed) constructions so
        // field access knows to use bracket notation instead of `.field`.
        if (!is_user_class &&
            stmt.let().value().expr_case() == ball::v1::Expression::kMessageCreation) {
            for (const auto& f : stmt.let().value().message_creation().fields()) {
                if (f.name() == "__type_args__") {
                    generic_locals_.insert(stmt.let().name());
                    break;
                }
            }
        }

        if (is_user_class) {
            out_ << class_type << " " << var_name << " = " << val_str << ";\n";
        } else {
            out_ << "auto " << var_name << " = BallDyn(" << val_str << ");\n";
        }
    } else if (stmt.has_expression()) {
        // Block expressions used as statements (no result expression):
        //   * If EVERY statement is a `let`, this is Dart record-pattern
        //     destructuring (`var (a, b) = rec;`) — emit the bindings inline so
        //     they stay visible to the enclosing scope.
        //   * Otherwise it is an explicit lexical scope (`{ var x = …; … }`) —
        //     wrap in C++ braces so its `let`s shadow rather than redefine
        //     same-named variables in the enclosing scope.
        if (stmt.expression().expr_case() == ball::v1::Expression::kBlock) {
            const auto& block = stmt.expression().block();
            if (!block.has_result()) {
                bool all_lets = block.statements_size() > 0;
                for (const auto& s : block.statements())
                    if (!s.has_let()) { all_lets = false; break; }
                if (all_lets) {
                    for (const auto& s : block.statements()) compile_statement(s);
                } else {
                    emit_line("{");
                    indent_++;
                    for (const auto& s : block.statements()) compile_statement(s);
                    indent_--;
                    emit_line("}");
                }
                return;
            }
        }
        // Compiling the expression here is a pre-computation used only by the
        // non-control-flow fallback at the end of this function; every
        // control-flow case below emits via emit_line and returns early. The
        // pre-computation can recurse into nested loops (compile_block_statements
        // → compile_statement) which consume `pending_label_`. Save and restore
        // it so a wrapping `labeled` loop still sees its label when its own
        // statement-context handler runs.
        auto saved_pending_label = pending_label_;
        auto expr_str = compile_expr(stmt.expression());
        pending_label_ = saved_pending_label;
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
                if (in_generator_) {
                    // In a generator, return stops yielding and returns the
                    // collected values (ignoring the return expression).
                    emit_line("return BallDyn(*__gen.values);");
                    return;
                }
                // Wrap in BallDyn so a function/lambda with multiple `return`
                // statements (and a possibly differently-typed block result)
                // deduces a single, consistent return type. All compiled engine
                // callables ultimately return BallDyn.
                auto val = get_message_field(call, "value");
                emit_line("return BallDyn(" + val + ");");
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
                    // If init is a block with a single let statement,
                    // extract the declaration for the for-init clause
                    // (avoids IIFE scoping issues).
                    auto* init_e = get_message_field_expr(call, "init");
                    if (init_e &&
                        init_e->expr_case() == ball::v1::Expression::kBlock &&
                        init_e->block().statements_size() == 1 &&
                        init_e->block().statements(0).stmt_case() == ball::v1::Statement::kLet) {
                        const auto& let_stmt = init_e->block().statements(0).let();
                        auto var_name = ball_local_var_name(sanitize_name(let_stmt.name()));
                        auto val = compile_expr(let_stmt.value());
                        init = "auto " + var_name + " = " + val;
                    } else {
                        init = get_message_field(call, "init");
                    }
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
                emit_line("for (auto " + sanitize_name(var_name) + " : BallDyn(" + iter + ")) {");
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
                emit_line("{");
                indent_++;
                emit_line("auto __switch_subj = BallDyn(" + subj + ");");
                auto compileExprLambda = [this](const ball::v1::Expression& e) -> std::string {
                    return compile_expr(e);
                };
                auto* cases_expr = get_message_field_expr(call, "cases");
                bool first_case = true;
                if (cases_expr && cases_expr->expr_case() == ball::v1::Expression::kLiteral &&
                    cases_expr->literal().value_case() == ball::v1::Literal::kListValue) {
                    // Normalize switch pattern values helper
                    auto normalize_pattern = [](const std::string& s) -> std::string {
                        if (s.size() < 3 || s[0] != '"' || s.back() != 's' || s[s.size()-2] != '"')
                            return s;
                        auto inner = s.substr(1, s.size() - 3);
                        if (inner.size() >= 2 && inner.front() == '\'' && inner.back() == '\'')
                            inner = inner.substr(1, inner.size() - 2);
                        auto dot = inner.rfind('.');
                        if (dot != std::string::npos && inner.find('_') < dot)
                            inner = inner.substr(dot + 1);
                        return "\"" + inner + "\"s";
                    };
                    // Emit case body helper (shared between structured and legacy paths)
                    auto emit_case_body = [&](const ball::v1::Expression* case_body) {
                        if (!case_body) return;
                        if (case_body->expr_case() == ball::v1::Expression::kBlock) {
                            for (const auto& s : case_body->block().statements()) {
                                compile_statement(s);
                            }
                            if (case_body->block().has_result()) {
                                emit_line("return " + compile_expr(case_body->block().result()) + ";");
                            }
                        } else {
                            auto body_code = compile_expr(*case_body);
                            auto pos = body_code.find("/* return */ ");
                            if (pos == 0) {
                                emit_line("return " + body_code.substr(12) + ";");
                            } else {
                                emit_line("return " + body_code + ";");
                            }
                        }
                    };
                    // Collect fall-through patterns (empty body cases grouped with next non-empty case)
                    std::vector<std::string> pending_patterns;
                    for (const auto& cx : cases_expr->literal().list_value().elements()) {
                        if (cx.expr_case() != ball::v1::Expression::kMessageCreation) continue;
                        const ball::v1::Expression* case_val = nullptr;
                        const ball::v1::Expression* case_body = nullptr;
                        const ball::v1::Expression* case_pattern_expr = nullptr;
                        bool is_default = false;
                        for (const auto& f : cx.message_creation().fields()) {
                            if (f.name() == "value" || f.name() == "pattern") case_val = &f.value();
                            else if (f.name() == "body") case_body = &f.value();
                            else if (f.name() == "pattern_expr") case_pattern_expr = &f.value();
                            else if (f.name() == "is_default" &&
                                     f.value().expr_case() == ball::v1::Expression::kLiteral &&
                                     f.value().literal().bool_value()) is_default = true;
                        }
                        if (case_val && !is_default) {
                            auto cv = compile_expr(*case_val);
                            if (cv == "\"_\"s" || cv == "\"default\"s") is_default = true;
                        }
                        // Detect empty body (fall-through): empty block with no statements and no result
                        bool is_empty_body = false;
                        if (case_body && case_body->expr_case() == ball::v1::Expression::kBlock &&
                            case_body->block().statements_size() == 0 && !case_body->block().has_result()) {
                            is_empty_body = true;
                        }
                        if (!case_body) is_empty_body = true;
                        if (is_empty_body && case_val && !is_default) {
                            // Use pattern_expr for typed value when available
                            if (case_pattern_expr) {
                                std::vector<const ball::v1::Expression*> vals;
                                _collectOrPatternValues(*case_pattern_expr, vals);
                                for (auto* v : vals) {
                                    pending_patterns.push_back(compile_expr(*v));
                                }
                            } else {
                                pending_patterns.push_back(normalize_pattern(compile_expr(*case_val)));
                            }
                            continue;
                        }
                        if (is_default) {
                            if (first_case) emit_line("{");
                            else emit_line("else {");
                            pending_patterns.clear();
                            first_case = false;
                            indent_++;
                            emit_case_body(case_body);
                            indent_--;
                            emit_line("}");
                            continue;
                        }
                        if (case_val || case_pattern_expr) {
                            std::string cond;
                            bool used_structured = false;

                            // Try structured pattern_expr first
                            if (case_pattern_expr) {
                                auto structured = _compileStructuredPattern(
                                    *case_pattern_expr, "__switch_subj", compileExprLambda);
                                if (structured) {
                                    used_structured = true;
                                    cond = structured->condition;
                                    pending_patterns.clear();

                                    if (cond == "true" && structured->bindings.empty()) {
                                        // Wildcard / catch-all — treat as default
                                        if (first_case) emit_line("{");
                                        else emit_line("else {");
                                    } else {
                                        // Include any fall-through patterns
                                        for (auto& pp : pending_patterns) {
                                            cond += " || BallDyn(__switch_subj) == BallDyn(" + pp + ")";
                                        }
                                        pending_patterns.clear();
                                        if (first_case) emit_line("if (" + cond + ") {");
                                        else emit_line("else if (" + cond + ") {");
                                    }
                                    first_case = false;
                                    indent_++;
                                    // Emit variable bindings
                                    for (auto& [varName, varExpr] : structured->bindings) {
                                        emit_line("auto " + varName + " = BallDyn(" + varExpr + ");");
                                    }
                                    emit_case_body(case_body);
                                    indent_--;
                                    emit_line("}");
                                    continue;
                                }
                            }

                            // Try or-pattern via pattern_expr (LogicalOrPattern / ConstPattern)
                            if (!used_structured && case_pattern_expr) {
                                std::vector<const ball::v1::Expression*> or_vals;
                                _collectOrPatternValues(*case_pattern_expr, or_vals);
                                if (or_vals.size() > 1) {
                                    pending_patterns.clear();
                                    for (size_t oi = 0; oi < or_vals.size(); oi++) {
                                        if (oi > 0) cond += " || ";
                                        cond += "BallDyn(__switch_subj) == BallDyn(" + compile_expr(*or_vals[oi]) + ")";
                                    }
                                } else if (or_vals.size() == 1) {
                                    cond = "BallDyn(__switch_subj) == BallDyn(" + compile_expr(*or_vals[0]) + ")";
                                }
                            }
                            if (cond.empty() && case_val) {
                                auto cv = normalize_pattern(compile_expr(*case_val));
                                cond = "BallDyn(__switch_subj) == BallDyn(" + cv + ")";
                            }
                            if (cond.empty()) continue;
                            // Include any fall-through patterns
                            for (auto& pp : pending_patterns) {
                                cond += " || BallDyn(__switch_subj) == BallDyn(" + pp + ")";
                            }
                            pending_patterns.clear();
                            if (first_case) emit_line("if (" + cond + ") {");
                            else emit_line("else if (" + cond + ") {");
                        } else {
                            continue;
                        }
                        first_case = false;
                        indent_++;
                        emit_case_body(case_body);
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
                auto* body_expr = get_message_field_expr(call, "body");
                auto* catches_expr = get_message_field_expr(call, "catches");
                auto* finally_expr = get_message_field_expr(call, "finally");

                // A try is "catching" if it has a non-empty list of catch
                // clauses, or a single non-list catch expression.
                bool has_catches =
                    catches_expr &&
                    ((catches_expr->expr_case() == ball::v1::Expression::kLiteral &&
                      catches_expr->literal().value_case() == ball::v1::Literal::kListValue &&
                      catches_expr->literal().list_value().elements_size() > 0) ||
                     (catches_expr->expr_case() != ball::v1::Expression::kLiteral));
                bool has_finally = finally_expr != nullptr;

                auto emit_try_body = [&]() {
                    if (!body_expr) return;
                    if (body_expr->expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : body_expr->block().statements()) {
                            compile_statement(s);
                        }
                        if (body_expr->block().has_result()) {
                            emit_line(compile_expr(body_expr->block().result()) + ";");
                        }
                    } else {
                        // Wrap bare-expression body in a synthetic
                        // statement so nested control-flow calls hit
                        // their statement-context emission.
                        ball::v1::Statement inner;
                        *inner.mutable_expression() = *body_expr;
                        compile_statement(inner);
                    }
                };

                // `finally` → RAII guard so cleanup runs on EVERY exit path
                // (normal, `return`, or exception). C++ has no `finally`;
                // emitting the cleanup after the try/catch would skip it on a
                // `return` inside the body (this silently broke _exitExpression
                // in the self-hosted engine → expression-depth leak). The guard
                // is declared before the try so it destructs (runs) AFTER the
                // catch handlers, matching Dart's finally-after-catch order.
                if (has_finally) {
                    emit_line("{");
                    indent_++;
                    emit_line("auto __ball_finally = make_ball_finally([&]() {");
                    indent_++;
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
                    indent_--;
                    emit_line("});");
                }

                if (!has_catches) {
                    // No catch clauses: emit the body directly. The finally
                    // guard (if any) handles cleanup; exceptions propagate
                    // instead of being silently swallowed.
                    emit_try_body();
                    if (has_finally) {
                        indent_--;
                        emit_line("}");
                    }
                    return;
                }

                emit_line("try {");
                indent_++;
                emit_try_body();
                indent_--;
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
                        // Bind the caught value as a BallDyn: a reconstructed
                        // {__type__, typeName, value} map for a BallException
                        // (so `e is BallException`, e["value"], e["typeName"]
                        // work), or the .what() string for a real C++ exception.
                        emit_line("auto " + var + " = _ball_caught_to_dyn(__ball_e);");
                        if (!first_untyped->stack_var.empty()) {
                            emit_line("std::string " +
                                      sanitize_name(first_untyped->stack_var) +
                                      " = \"<stack trace unavailable>\"s;");
                        }
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
                // Close the finally guard scope (cleanup runs on destruction).
                if (has_finally) {
                    indent_--;
                    emit_line("}");
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
    emit_line("#include <cstring>");
    emit_line("#include <cstdlib>");
    emit_line("#include <memory>");
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

    // Proto-compat helper functions (ball_proto module routes method calls
    // as standalone functions: hasMetadata(obj), whichExpr(obj), etc.)
    out_ << R"(
// Proto-compat helpers for ball_proto method dispatch
using namespace std::string_literals;
inline bool _bd_has(const BallDyn& obj, const std::string& f) { return obj[f].has_value(); }
inline bool hasMetadata(const BallDyn& o) { return _bd_has(o,"metadata"); }
inline bool hasBody(const BallDyn& o) { return _bd_has(o,"body"); }
inline bool hasInput(const BallDyn& o) { return _bd_has(o,"input"); }
inline bool hasDescriptor(const BallDyn& o) { return _bd_has(o,"descriptor"); }
inline bool hasResult(const BallDyn& o) { return _bd_has(o,"result"); }
inline bool hasStringValue(const BallDyn& o) { return _bd_has(o,"stringValue"); }
inline bool hasBoolValue(const BallDyn& o) { return _bd_has(o,"boolValue"); }
inline bool hasNumberValue(const BallDyn& o) { return _bd_has(o,"numberValue"); }
inline bool hasListValue(const BallDyn& o) { return _bd_has(o,"listValue"); }
inline bool hasCall(const BallDyn& o) { return _bd_has(o,"call"); }
inline bool hasObject(const BallDyn& o) { return _bd_has(o,"object"); }
inline bool hasValue(const BallDyn& o) { return _bd_has(o,"value"); }
inline bool hasNullValue(const BallDyn&) { return false; }
inline bool hasStructValue(const BallDyn& o) { return _bd_has(o,"structValue"); }
inline bool hasMatch(const BallDyn&) { return false; }
inline bool hasXxx(const BallDyn&) { return false; }
inline std::string whichExpr(const BallDyn& o) {
  if (_bd_has(o,"call")) return "call";
  if (_bd_has(o,"literal")) return "literal";
  if (_bd_has(o,"reference")) return "reference";
  if (_bd_has(o,"fieldAccess")) return "fieldAccess";
  if (_bd_has(o,"messageCreation")) return "messageCreation";
  if (_bd_has(o,"block")) return "block";
  if (_bd_has(o,"lambda")) return "lambda";
  return "notSet";
}
inline std::string whichValue(const BallDyn& o) {
  if (_bd_has(o,"intValue")) return "intValue";
  if (_bd_has(o,"doubleValue")) return "doubleValue";
  if (_bd_has(o,"stringValue")) return "stringValue";
  if (_bd_has(o,"boolValue")) return "boolValue";
  if (_bd_has(o,"listValue")) return "listValue";
  return "notSet";
}
inline std::string whichStmt(const BallDyn& o) {
  if (_bd_has(o,"let")) return "let";
  if (_bd_has(o,"expression")) return "expression";
  return "notSet";
}
inline std::string whichKind(const BallDyn& o) {
  if (_bd_has(o,"nullValue")) return "nullValue";
  if (_bd_has(o,"numberValue")) return "numberValue";
  if (_bd_has(o,"stringValue")) return "stringValue";
  if (_bd_has(o,"boolValue")) return "boolValue";
  if (_bd_has(o,"structValue")) return "structValue";
  if (_bd_has(o,"listValue")) return "listValue";
  return "notSet";
}
inline std::string whichSource(const BallDyn&) { return "notSet"; }
inline std::string whichXxx(const BallDyn&) { return "notSet"; }

// Dart protobuf Program.writeToBuffer() — approximate byte size for limit checks.
inline std::string writeToBuffer(const BallDyn& program) {
  return jsonEncode(program);
}

// Instance field write for compiled engine helpers (_syncFieldToSelf, etc.).
inline void ball_object_set_field(BallDyn obj, const std::string& field,
                                    const BallDyn& val) {
  obj.setField(field, val);
}

// List/Map copy helpers for List.of / Map.from
// Std function to operator mapping (used by _tryOperatorOverride).
// Must be a BallMap (std::map<string, any>) — the engine reads it via
// `BallDyn(_stdFunctionToOperator)[function]`, and BallDyn::operator[] only
// recognizes std::map<string, any> (a std::map<string, string> would not be
// read as a map, so every lookup returned a null BallDyn and the operator
// override never fired). Values are std::string wrapped in std::any.
const std::map<std::string, std::any> _stdFunctionToOperator = {
  {"equals", std::any(std::string("=="))}, {"not_equals", std::any(std::string("!="))},
  {"add", std::any(std::string("+"))}, {"subtract", std::any(std::string("-"))},
  {"multiply", std::any(std::string("*"))}, {"divide", std::any(std::string("~/"))},
  {"divide_double", std::any(std::string("/"))}, {"modulo", std::any(std::string("%"))},
  {"less_than", std::any(std::string("<"))}, {"greater_than", std::any(std::string(">"))},
  {"lte", std::any(std::string("<="))}, {"gte", std::any(std::string(">="))},
  {"index", std::any(std::string("[]"))}
};

// Built-in type names (used by _evalReference to skip class lookups)
const std::vector<std::string> _builtinTypeNames = {
  "int", "double", "num", "String", "bool", "List", "Map", "Set",
  "Null", "void", "Object", "dynamic", "Function", "Future", "Stream",
  "Iterable", "Iterator", "Type", "Symbol", "Never"
};

// concat helper (BallDyn-safe, handles both lists and maps)
inline BallDyn ball_concat(const BallDyn& a, const BallDyn& b) {
  // Unwrap any BallDyn-in-std::any wrapping (MSVC quirk) so the type checks and
  // any_casts below see the real BallMap/BallList rather than typeid(BallDyn).
  auto aa0 = static_cast<std::any>(a);
  auto ba0 = static_cast<std::any>(b);
  const std::any& aa = _BallDynUnwrapper::unwrap(aa0);
  const std::any& ba = _BallDynUnwrapper::unwrap(ba0);
  // Map concat: merge maps
  if (aa.type() == typeid(BallMap) || ba.type() == typeid(BallMap)) {
    BallMap result;
    try { auto ma = std::any_cast<BallMap>(aa); for (auto& p : ma) result[p.first] = p.second; } catch(...) {}
    try { auto mb = std::any_cast<BallMap>(ba); for (auto& p : mb) result[p.first] = p.second; } catch(...) {}
    return BallDyn(result);
  }
  // List concat — deref shared_ptr-backed (reference-semantic) lists. Builds a
  // NEW list, matching Dart's `a + b` copy semantics (operands unchanged).
  BallList result;
  if (const BallList* la = _ballAnyListPtr(aa)) result.insert(result.end(), la->begin(), la->end());
  if (const BallList* lb = _ballAnyListPtr(ba)) result.insert(result.end(), lb->begin(), lb->end());
  return BallDyn(result);
}

// std::map overload for ball_concat (when methods is a map)
inline std::map<std::string,std::any> ball_concat(const std::map<std::string,std::any>& a, const std::map<std::string,std::any>& b) {
  auto r = a;
  for (auto& p : b) r[p.first] = p.second;
  return r;
}

// vector overloads for ball_concat
inline std::vector<std::any> ball_concat(const std::vector<std::any>& a, const BallDyn& b) {
  auto r = a;
  auto b0 = static_cast<std::any>(b);
  const std::any& bu = _BallDynUnwrapper::unwrap(b0);
  if (const BallList* lb = _ballAnyListPtr(bu)) { r.insert(r.end(), lb->begin(), lb->end()); }
  else { r.push_back(bu); }
  return r;
}
inline std::vector<std::any> ball_concat(const std::vector<std::any>& a, const std::vector<std::any>& b) {
  auto r = a;
  r.insert(r.end(), b.begin(), b.end());
  return r;
}

// Allow ball_concat(map, BallDyn) and ball_concat(BallDyn, map)
inline std::map<std::string,std::any> ball_concat(const std::map<std::string,std::any>& a, const BallDyn& b) {
  auto r = a;
  try { auto mb = std::any_cast<BallMap>(static_cast<std::any>(b)); for (auto& p : mb) r[p.first] = p.second; } catch(...) {}
  return r;
}

// ball_is_* BallDyn overloads: ball_is_map(const BallDyn&) lives in ball_dyn.h
// (BallOrderedMap-aware). Only list/function overloads remain here.
inline bool ball_is_list(BallDyn& v) { return ball_is_list(static_cast<const BallDyn&>(v)); }
inline bool ball_is_string(BallDyn& v) { return ball_is_string(static_cast<const BallDyn&>(v)); }
inline bool ball_is_function(BallDyn& v) { return ball_is_function(static_cast<const BallDyn&>(v)); }

// ball_set with BallDyn keys: handled by wrapping key in ball_to_string() at call site

// ball_set is used with comma operator for expression context:
// (ball_set(obj, key, val), val)  — sets and returns the value

// cast helper (Dart as operator — no-op in dynamic C++)
inline BallDyn cast(const BallDyn& v, const std::string&) { return v; }

// BallDyn from vector<string> conversion
inline BallDyn ball_wrap_list(const std::vector<std::string>& v) {
  BallList result;
  for (const auto& s : v) result.push_back(std::any(s));
  return BallDyn(result);
}

// elementAt helper (Iterable.elementAt)
inline BallDyn elementAt(const BallDyn& list, int64_t index) {
  return list[index];
}

// num/int/double parse helpers
inline BallDyn parse(const std::string& type, const BallDyn& val) {
  auto s = ball_to_string(val);
  try {
    if (type == "num" || type == "double") return BallDyn(std::stod(s));
    return BallDyn(static_cast<int64_t>(std::stoll(s)));
  } catch (...) { return BallDyn(); }
}

// Scope method helpers (ball_proto routes scope.has/lookup as standalone)
// These walk the parent chain using BallScope (shared_ptr<BallMap>) for
// reference semantics — parent mutations are visible to children.
inline bool has(const BallDyn& scope, const BallDyn& name) {
  auto key = ball_to_string(name);
  if (_ball_scope_has_key(scope, key)) return true;
  auto bindings = scope["_bindings"s];
  if (bindings.has_value() && static_cast<BallDyn>(bindings)[key].has_value()) return true;
  // Walk parent chain via BallScope shared_ptr
  BallScope parent = _ball_get_parent_scope(scope);
  while (parent) {
    if (parent->count(key) > 0) return true;
    auto it = parent->find("__parent__");
    if (it != parent->end() && it->second.type() == typeid(BallScope)) {
      parent = std::any_cast<const BallScope&>(it->second);
    } else {
      break;
    }
  }
  // Legacy fallback: __parent__ stored as value copy
  if (!parent) {
    auto parentVal = scope["__parent__"s];
    if (!parentVal.has_value()) parentVal = scope["_parent"s];
    if (parentVal.has_value()) return has(parentVal, name);
  }
  return false;
}
inline BallDyn lookup(const BallDyn& scope, const BallDyn& name) {
  auto key = ball_to_string(name);
  // Check direct binding first
  if (_ball_scope_has_key(scope, key)) return scope[key];
  // Check _bindings sub-map
  auto bindings = scope["_bindings"s];
  if (bindings.has_value()) {
    auto val = static_cast<BallDyn>(bindings)[key];
    if (val.has_value()) return val;
  }
  // Walk parent chain via BallScope shared_ptr (sees live mutations)
  BallScope parent = _ball_get_parent_scope(scope);
  while (parent) {
    auto it = parent->find(key);
    if (it != parent->end()) return BallDyn(it->second);
    // Check next parent
    auto pit = parent->find("__parent__");
    if (pit != parent->end() && pit->second.type() == typeid(BallScope)) {
      parent = std::any_cast<const BallScope&>(pit->second);
    } else {
      break;
    }
  }
  // Legacy fallback: __parent__ stored as value copy
  if (!parent) {
    auto parentVal = scope["__parent__"s];
    if (!parentVal.has_value()) parentVal = scope["_parent"s];
    if (parentVal.has_value()) return lookup(parentVal, name);
  }
  return BallDyn();
}

// List manipulation helpers for BallDyn. These mutate the shared list in place
// (reference semantics, matching Dart's `list.insert`/`list.removeAt`) and return
// the same handle so callers that reassign the result still observe the change.
inline BallDyn ball_list_insert(BallDyn list, int64_t idx, BallDyn elem) {
  if (BallList* v = list._listPtr()) {
    if (idx >= 0 && idx <= static_cast<int64_t>(v->size())) v->insert(v->begin()+idx, std::any(elem));
  }
  return list;
}
// Dart's List.removeAt returns the REMOVED element (and mutates in place).
inline BallDyn ball_list_remove_at(BallDyn list, int64_t idx) {
  if (BallList* v = list._listPtr()) {
    if (idx >= 0 && idx < static_cast<int64_t>(v->size())) {
      BallDyn removed = BallDyn((*v)[static_cast<size_t>(idx)]);
      v->erase(v->begin()+idx);
      return removed;
    }
  }
  return BallDyn();
}
// Dart's List.removeLast pops the last element in place and returns it.
inline BallDyn ball_list_pop(BallDyn list) {
  if (BallList* v = list._listPtr()) {
    if (!v->empty()) {
      BallDyn removed = BallDyn(v->back());
      v->pop_back();
      return removed;
    }
  }
  return BallDyn();
}
// Single BallDyn-param overload: int64_t arguments convert via BallDyn(int64_t)
// implicitly, so a mix of int64_t/BallDyn call arguments stays unambiguous
// (two overloads — one int64_t, one BallDyn — caused C2666 ambiguity).
inline BallDyn ball_sublist(const BallDyn& list, const BallDyn& start, const BallDyn& end_val = BallDyn()) {
  if (const BallList* vp = list._listPtr()) {
    const auto& v = *vp;
    int64_t size = static_cast<int64_t>(v.size());
    int64_t s = start.has_value() ? static_cast<int64_t>(start) : 0;
    int64_t e = end_val.has_value() ? static_cast<int64_t>(end_val) : size;
    s = std::max(int64_t(0), std::min(s, size));
    e = std::max(int64_t(0), std::min(e, size));
    if (s > e) s = e;
    return BallDyn(BallList(v.begin()+s, v.begin()+e));
  }
  return BallDyn(BallList{});
}
// ball_take / ball_skip defined in ball_dyn.h

// indexOf for vector<string> (used by _builtinTypeNames.contains)
inline int64_t ball_index_of(const std::vector<std::string>& v, const BallDyn& elem) {
  auto s = ball_to_string(BallDyn(elem));
  for (size_t i = 0; i < v.size(); i++) if (v[i] == s) return static_cast<int64_t>(i);
  return -1;
}

// indexOf helper: works on both strings and vectors
inline int64_t ball_index_of(const BallDyn& container, const BallDyn& element) {
  auto& c = container._val;
  if (c.type() == typeid(std::string)) {
    auto& s = std::any_cast<const std::string&>(c);
    auto& e = element._val;
    std::string needle;
    if (e.type() == typeid(std::string)) needle = std::any_cast<const std::string&>(e);
    else needle = ball_to_string(element);
    auto pos = s.find(needle);
    return pos != std::string::npos ? static_cast<int64_t>(pos) : -1LL;
  }
  if (const BallList* lp = container._listPtr()) {
    const auto& list = *lp;
    for (size_t i = 0; i < list.size(); i++) {
      if (ball_to_string(BallDyn(list[i])) == ball_to_string(element)) return static_cast<int64_t>(i);
    }
    return -1LL;
  }
  return -1LL;
}

inline BallDyn ball_list_copy(const BallDyn& v) {
  if (const BallList* lp = v._listPtr()) return BallDyn(BallList(*lp));
  return v;
}
inline BallDyn ball_map_copy(const BallDyn& v) {
  try {
    auto a = static_cast<std::any>(v);
    const std::any& u = _BallDynUnwrapper::unwrap(a);
    if (u.type() == typeid(BallOrderedMapRef))
      return BallDyn(BallOrderedMapRef(std::make_shared<BallOrderedMap>(
          *std::any_cast<const BallOrderedMapRef&>(u))));
    if (u.type() == typeid(BallOrderedMap))
      return BallDyn(BallOrderedMap(std::any_cast<const BallOrderedMap&>(u)));
    if (u.type() == typeid(BallMap))
      return BallDyn(BallMap(std::any_cast<const BallMap&>(u)));
  } catch(...) {}
  return v;
}
)";
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
        // Self-hosted engine types provided by ball_emit_runtime.h
        "BallObject", "List_filled",
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
        if (name == "_ballMapKeysDyn" || name == "_ballMapValuesDyn" ||
            name == "_ballMapValues") {
            emit_line(return_type + " " + name + "(BallDyn map);");
            continue;
        }
        if (name == "_ballMapContainsKeyDyn") {
            emit_line(return_type + " " + name + "(BallDyn map, BallDyn key);");
            continue;
        }
        if (name == "_ballMapSetDyn") {
            emit_line(return_type + " " + name +
                      "(BallDyn map, BallDyn key, BallDyn value);");
            continue;
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
    // Emit Dart-style enums as a struct with static const instances,
    // an `.index` field, a `.values` list, and string conversion.
    // This allows `Color.red`, `Color.values`, `c.index`, and
    // `ball_to_string(c)` to work like Dart.
    std::string name = sanitize_name(ed.name());
    emit_line("struct " + name + " {");
    indent_++;
    emit_line("int64_t index;");
    emit_line("std::string _name;");
    // Constructor
    emit_line(name + "(int64_t idx, std::string n) : index(idx), _name(std::move(n)) {}");
    emit_line(name + "() : index(0), _name() {}");
    // Comparison operators for switch/equality
    emit_line("bool operator==(const " + name + "& o) const { return index == o.index; }");
    emit_line("bool operator!=(const " + name + "& o) const { return index != o.index; }");
    // BallDyn interop: allow wrapping in BallDyn for switch/iteration
    emit_line("operator BallDyn() const;");
    // Static instances
    for (const auto& val : ed.value()) {
        emit_line("static const " + name + " " + sanitize_name(val.name()) + ";");
    }
    // Static values list (BallList for BallDyn iteration compatibility)
    emit_line("static const BallList values;");
    indent_--;
    emit_line("};");
    // Out-of-line definitions
    for (const auto& val : ed.value()) {
        emit_line("const " + name + " " + name + "::" + sanitize_name(val.name()) +
                  " = " + name + "(" + std::to_string(val.number()) +
                  ", \"" + name + "." + val.name() + "\");");
    }
    // Values list (BallList for BallDyn iteration)
    emit_indent();
    out_ << "const BallList " << name << "::values = {";
    bool first = true;
    for (const auto& val : ed.value()) {
        if (!first) out_ << ", ";
        out_ << "std::any(BallDyn(" << name << "::" << sanitize_name(val.name()) << "))";
        first = false;
    }
    out_ << "};\n";
    // BallDyn conversion operator: wraps the enum as a map-like BallDyn
    // with "index" and "_name" fields so field access (c.index) and
    // comparisons (BallDyn(a) == BallDyn(b)) work through the BallDyn layer.
    emit_line("inline " + name + "::operator BallDyn() const {");
    indent_++;
    emit_line("std::map<std::string,std::any> m;");
    emit_line("m[\"index\"] = std::any(index);");
    emit_line("m[\"_name\"] = std::any(_name);");
    emit_line("return BallDyn(m);");
    indent_--;
    emit_line("}");
    // ball_to_string overload
    emit_line("inline std::string ball_to_string(const " + name + "& e) { return e._name; }");
    emit_newline();
}

void CppCompiler::emit_function_signature_only(
    const ball::v1::FunctionDefinition& func) {
    auto return_type = map_return_type(func);
    auto name = sanitize_name(func.name());
    auto params = func.has_metadata() ? extract_params(func.metadata())
                                      : std::vector<std::string>{};
    auto meta = read_meta(func);
    if (meta.count("original_name")) {
        name = sanitize_name(meta["original_name"]);
    }
    if (func.has_metadata()) emit_template_prefix_from_meta(func.metadata());
    emit_indent();
    bool is_conv = meta.count("is_conversion_operator") &&
                   meta["is_conversion_operator"] == "true";
    if (is_conv) {
        std::string conv_type = return_type;
        if (meta.count("conversion_type") && !meta["conversion_type"].empty()) {
            conv_type = map_type(meta["conversion_type"]);
        }
        out_ << "operator " << conv_type << "(";
    } else {
        out_ << return_type << " " << name << "(";
    }
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
                                : "auto&&";
            out_ << t << " " << sanitize_name(params[i]);
        }
    } else if (!func.input_type().empty()) {
        out_ << map_type(func.input_type()) << " input";
    }
    out_ << ");\n";
}

void CppCompiler::emit_function_body_out_of_line(
    const ball::v1::FunctionDefinition& func) {
    std::ostringstream saved;
    saved.swap(out_);
    int saved_indent = indent_;
    emit_function(func);
    indent_ = saved_indent;
    queue_split_definition(out_.str());
    out_.str("");
    out_.clear();
    out_.swap(saved);
}

void CppCompiler::emit_struct(const ball::v1::TypeDefinition& td,
                                const std::vector<const ball::v1::FunctionDefinition*>& methods) {
    std::string name = sanitize_name(td.name());
    auto tmeta = read_type_meta(td);

    // Template prefix from type_params
    emit_template_prefix(td);

    // Determine kind (struct vs class)
    std::string kind_kw = "struct";

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
        // Mixin inheritance: C++ has no mixins, so inherit from them.
        // The mixin methods are defined in the mixin struct; inheriting
        // gives the consuming class access to them.
        auto mixins = read_meta_list(td.metadata(), "mixins");
        for (const auto& mx : mixins) {
            bases += bases.empty() ? " : " : ", ";
            bases += "public " + sanitize_name(mx);
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

    // Gather constructor parameter info so fields get correct initializers.
    // Without this, default-constructing the class leaves primitive fields
    // (int64_t/bool/double) with indeterminate values — e.g. a garbage
    // `maxExpressionDepth` makes the engine throw on the first expression.
    std::map<std::string, std::string> ctor_defaults;
    std::set<std::string> ctor_params;
    for (const auto* func : methods) {
        auto m = read_meta(*func);
        if ((m.count("kind") ? m["kind"] : "") != "constructor") continue;
        if (!func->has_metadata()) continue;
        for (const auto& p : extract_params(func->metadata())) ctor_params.insert(p);
        for (const auto& [k, v] : extract_param_defaults(func->metadata())) ctor_defaults[k] = v;
    }

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
            const std::string& fname = field.name();
            bool is_primitive =
                (type == "int64_t" || type == "double" || type == "bool");
            std::string init;
            auto dit = ctor_defaults.find(fname);
            if (dit != ctor_defaults.end()) {
                // Constructor supplies a default (e.g. maxExpressionDepth = 1000).
                init = " = " + dit->second;
            } else if (ctor_params.count(fname) > 0 && is_primitive) {
                // Optional constructor param with no default → nullable in Dart
                // (e.g. `int? timeoutMs`). Represent as BallDyn so the engine's
                // `.has_value()` guards correctly treat it as "no limit".
                type = "BallDyn";
            } else if (is_primitive) {
                // Internal primitive state (e.g. _expressionDepth) → zero-init.
                init = "{}";
            }
            emit_line(type + " " + sanitize_name(fname) + init + ";");
        }
    }

    // Build the set of method basenames for this class, so that
    // compile_reference can detect when a reference is to a sibling method
    // and wrap it in a lambda (member function pointers can't be stored
    // directly as std::any values).
    current_class_methods_.clear();
    current_class_name_ = name;
    for (const auto* func : methods) {
        auto dot = func->name().rfind('.');
        std::string basename = dot != std::string::npos ? func->name().substr(dot + 1) : func->name();
        current_class_methods_.insert(sanitize_name(basename));
    }

    // Helper: extract is_this flags from constructor metadata params.
    auto extract_is_this = [](const google::protobuf::Struct& metadata)
        -> std::vector<bool> {
        std::vector<bool> result;
        auto it = metadata.fields().find("params");
        if (it == metadata.fields().end()) return result;
        if (it->second.kind_case() != google::protobuf::Value::kListValue) return result;
        for (const auto& elem : it->second.list_value().values()) {
            if (elem.kind_case() != google::protobuf::Value::kStructValue) {
                result.push_back(false);
                continue;
            }
            auto is_this_it = elem.struct_value().fields().find("is_this");
            bool is_this = is_this_it != elem.struct_value().fields().end() &&
                           is_this_it->second.kind_case() == google::protobuf::Value::kBoolValue &&
                           is_this_it->second.bool_value();
            result.push_back(is_this);
        }
        return result;
    };

    // Helper: extract initializers from constructor metadata.
    auto extract_initializers = [](const google::protobuf::Struct& metadata)
        -> std::vector<std::pair<std::string, std::string>> {
        std::vector<std::pair<std::string, std::string>> result;
        auto it = metadata.fields().find("initializers");
        if (it == metadata.fields().end()) return result;
        if (it->second.kind_case() != google::protobuf::Value::kListValue) return result;
        for (const auto& elem : it->second.list_value().values()) {
            if (elem.kind_case() != google::protobuf::Value::kStructValue) continue;
            std::string init_kind, init_args;
            auto kit = elem.struct_value().fields().find("kind");
            if (kit != elem.struct_value().fields().end())
                init_kind = kit->second.string_value();
            auto ait = elem.struct_value().fields().find("args");
            if (ait != elem.struct_value().fields().end())
                init_args = ait->second.string_value();
            result.push_back({init_kind, init_args});
        }
        return result;
    };

    // Emit a defaulted default constructor so `return ClassName()` compiles
    // as a fallthrough in methods returning this type. Only needed when the
    // class also has user-defined constructors (which suppress the implicit
    // default constructor).
    {
        bool has_user_ctor = false;
        for (const auto* func : methods) {
            auto m = read_meta(*func);
            if ((m.count("kind") ? m["kind"] : "") == "constructor") {
                has_user_ctor = true;
                break;
            }
        }
        if (has_user_ctor) {
            emit_line(name + "() = default;");
        }
    }

    // Methods
    for (const auto* func : methods) {
        auto meta = read_meta(*func);
        auto kind = meta.count("kind") ? meta["kind"] : "method";
        if (kind == "constructor") {
            bool is_factory = meta.count("is_factory") && meta["is_factory"] == "true";
            // Extract method name from full qualified name
            auto dot = func->name().rfind('.');
            std::string ctor_name = dot != std::string::npos ? func->name().substr(dot + 1) : func->name();
            bool is_default = (ctor_name == "new" || ctor_name == name || ctor_name.empty());

            if (is_factory) {
                // Factory constructor → static method returning the class type.
                auto params = func->has_metadata() ? extract_params(func->metadata()) : std::vector<std::string>{};
                emit_indent();
                out_ << "static " << name << " " << sanitize_name(ctor_name) << "(";
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
                emit_line("return " + name + "();");
                indent_--;
                emit_line("}");
                continue;
            }

            if (is_default) {
                // Default constructor (named "new" or matching class name)
                emit_indent();
                out_ << name << "(";
                auto params = func->has_metadata() ? extract_params(func->metadata()) : std::vector<std::string>{};
                auto is_this_flags = func->has_metadata() ? extract_is_this(func->metadata()) : std::vector<bool>{};
                auto initializers = func->has_metadata() ? extract_initializers(func->metadata()) : std::vector<std::pair<std::string, std::string>>{};
                for (size_t i = 0; i < params.size(); i++) {
                    if (i > 0) out_ << ", ";
                    out_ << "auto " << sanitize_name(params[i]);
                }
                out_ << ")";

                // Emit member initializer list for is_this params and super calls.
                bool has_inits = false;
                bool any_is_this = false;
                for (size_t i = 0; i < params.size(); i++) {
                    bool is_this = i < is_this_flags.size() && is_this_flags[i];
                    if (is_this) any_is_this = true;
                    if (is_this) {
                        out_ << (has_inits ? ", " : " : ");
                        has_inits = true;
                        out_ << sanitize_name(params[i]) << "(" << sanitize_name(params[i]) << ")";
                    }
                }
                // Auto-assign: when no is_this flags are set and no super
                // initializers exist, but the class has fields matching the
                // param count, map params positionally to fields as member
                // initializers. This handles `Grandparent(name)` encoded as
                // a single param "input" with a field "name". Skip when there
                // are super initializers (params may be forwarded to parent).
                bool has_super_init = false;
                for (const auto& [ik, _] : initializers)
                    if (ik == "super") { has_super_init = true; break; }
                if (!any_is_this && !has_super_init && !params.empty() && td.has_descriptor_()) {
                    const auto& fields = td.descriptor_().field();
                    if (fields.size() == static_cast<int>(params.size())) {
                        for (int fi = 0; fi < fields.size(); fi++) {
                            out_ << (has_inits ? ", " : " : ");
                            has_inits = true;
                            out_ << sanitize_name(fields[fi].name())
                                 << "(" << sanitize_name(params[fi]) << ")";
                        }
                    }
                }
                // Super call from initializers metadata.
                for (const auto& [init_kind, init_args] : initializers) {
                    if (init_kind == "super" && !bases.empty()) {
                        // Extract the superclass name from the bases string.
                        auto spos = bases.find("public ");
                        std::string super_name;
                        if (spos != std::string::npos) {
                            super_name = bases.substr(spos + 7);
                            auto space = super_name.find_first_of(" ,{");
                            if (space != std::string::npos) super_name = super_name.substr(0, space);
                        }
                        if (!super_name.empty()) {
                            out_ << (has_inits ? ", " : " : ");
                            has_inits = true;
                            // init_args is like "(name)" — extract the arg names.
                            std::string args = init_args;
                            // Strip parens.
                            if (!args.empty() && args.front() == '(') args = args.substr(1);
                            if (!args.empty() && args.back() == ')') args.pop_back();
                            // Convert Dart single-quoted string literals to C++
                            // double-quoted string literals with s suffix.
                            // e.g. 'Car' → "Car"s
                            std::string fixed_args;
                            for (size_t ci = 0; ci < args.size(); ci++) {
                                if (args[ci] == '\'') {
                                    // Find matching closing quote
                                    auto end = args.find('\'', ci + 1);
                                    if (end != std::string::npos) {
                                        fixed_args += "\"" + args.substr(ci + 1, end - ci - 1) + "\"s";
                                        ci = end;
                                        continue;
                                    }
                                }
                                fixed_args += args[ci];
                            }
                            out_ << super_name << "(" << fixed_args << ")";
                        }
                    }
                }

                if (split_mode_ && func->has_body()) {
                    out_ << ";\n";
                    std::ostringstream saved;
                    saved.swap(out_);
                    int saved_indent = indent_;
                    emit_indent();
                    out_ << name << "::" << name << "(";
                    for (size_t i = 0; i < params.size(); i++) {
                        if (i > 0) out_ << ", ";
                        out_ << "auto " << sanitize_name(params[i]);
                    }
                    out_ << ") {\n";
                    indent_++;
                    if (func->body().expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : func->body().block().statements())
                            compile_statement(s);
                    }
                    indent_--;
                    emit_line("}");
                    queue_split_definition(out_.str());
                    out_.str("");
                    out_.clear();
                    out_.swap(saved);
                    indent_ = saved_indent;
                } else if (func->has_body()) {
                    out_ << " {\n";
                    indent_++;
                    if (func->body().expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : func->body().block().statements()) {
                            // Skip encoder-generated `let self = ClassName{}`
                            // and `return self` patterns in constructor bodies.
                            // These are artifacts of the encoder's self-variable
                            // pattern; the C++ constructor IS `self`.
                            if (s.has_let() && s.let().name() == "self") continue;
                            if (s.has_expression() &&
                                s.expression().expr_case() == ball::v1::Expression::kCall &&
                                s.expression().call().function() == "return") continue;
                            compile_statement(s);
                        }
                    }
                    indent_--;
                    emit_line("}");
                } else {
                    out_ << " {}\n";
                }
            } else {
                // Named constructor (not "new") → emit as a named static factory.
                auto params = func->has_metadata() ? extract_params(func->metadata()) : std::vector<std::string>{};
                auto is_this_flags = func->has_metadata() ? extract_is_this(func->metadata()) : std::vector<bool>{};
                emit_indent();
                out_ << "static " << name << " " << sanitize_name(ctor_name) << "(";
                for (size_t i = 0; i < params.size(); i++) {
                    if (i > 0) out_ << ", ";
                    out_ << "auto " << sanitize_name(params[i]);
                }
                out_ << ") {\n";
                indent_++;
                // Create instance and set is_this fields.
                emit_line(name + " __obj;");
                for (size_t i = 0; i < params.size(); i++) {
                    bool is_this = i < is_this_flags.size() && is_this_flags[i];
                    if (is_this) {
                        emit_line("__obj." + sanitize_name(params[i]) + " = " + sanitize_name(params[i]) + ";");
                    }
                }
                if (func->has_body()) {
                    // Named constructors with a body are rare; emit the body.
                    if (func->body().expr_case() == ball::v1::Expression::kBlock) {
                        for (const auto& s : func->body().block().statements())
                            compile_statement(s);
                    }
                }
                emit_line("return __obj;");
                indent_--;
                emit_line("}");
            }
            continue;
        }

        if (kind == "static_field") {
            // Static field: emit as inline static member.
            auto dot2 = func->name().rfind('.');
            std::string field_name = dot2 != std::string::npos ? func->name().substr(dot2 + 1) : func->name();
            emit_indent();
            out_ << "static inline " << map_return_type(*func) << " " << sanitize_name(field_name);
            if (func->has_body()) {
                out_ << " = " << compile_expr(func->body());
            }
            out_ << ";\n";
            continue;
        }

        // Regular method
        auto dot = func->name().rfind('.');
        std::string method_name = dot != std::string::npos ? func->name().substr(dot + 1) : func->name();
        std::string smethod_name = sanitize_name(method_name);

        // Determine method properties
        bool is_static = meta.count("is_static") && meta["is_static"] == "true";
        bool is_abstract = meta.count("is_abstract") && meta["is_abstract"] == "true";
        bool is_getter = meta.count("is_getter") && meta["is_getter"] == "true";
        bool is_setter = meta.count("is_setter") && meta["is_setter"] == "true";
        bool is_operator = meta.count("is_operator") && meta["is_operator"] == "true";
        bool is_conv = meta.count("is_conversion_operator") &&
                       meta["is_conversion_operator"] == "true";
        bool needs_virtual = !is_static && !is_conv &&
                             (overridden_methods_.count(smethod_name) > 0 || is_abstract);

        // Template prefix for generic methods
        if (func->has_metadata())
            emit_template_prefix_from_meta(func->metadata());

        emit_indent();
        if (is_static) out_ << "static ";
        if (needs_virtual) out_ << "virtual ";

        if (is_conv) {
            std::string conv_type = map_return_type(*func);
            if (meta.count("conversion_type") && !meta["conversion_type"].empty()) {
                conv_type = map_type(meta["conversion_type"]);
            }
            out_ << "operator " << conv_type << "(";
        } else if (is_operator && !smethod_name.empty()) {
            // Dart operator methods: the IR carries the raw operator symbol
            // as the method basename (e.g. "+", "-", "*", "==", "[]", "[]=").
            // Map to valid C++ operator overloads when possible.
            static const std::map<std::string, std::string> op_map = {
                {"+", "operator+"}, {"-", "operator-"}, {"_", "operator-"},
                {"*", "operator*"}, {"/", "operator/"},
                {"%", "operator%"}, {"==", "operator=="},
                {"!=", "operator!="}, {"<", "operator<"},
                {">", "operator>"}, {"<=", "operator<="},
                {">=", "operator>="}, {"^", "operator^"},
                {"&", "operator&"}, {"|", "operator|"},
                {"~", "operator~"}, {"<<", "operator<<"},
                {">>", "operator>>"},
            };
            // Also map __op_*__ canonical Ball names
            static const std::map<std::string, std::string> ball_op_map = {
                {"__op_add__", "operator+"}, {"__op_sub__", "operator-"},
                {"__op_mul__", "operator*"}, {"__op_div__", "operator/"},
                {"__op_mod__", "operator%"}, {"__op_eq__", "operator=="},
                {"__op_ne__", "operator!="}, {"__op_lt__", "operator<"},
                {"__op_gt__", "operator>"}, {"__op_lte__", "operator<="},
                {"__op_gte__", "operator>="}, {"__op_xor__", "operator^"},
                {"__op_bitor__", "operator|"}, {"__op_bitand__", "operator&"},
                {"__op_lshift__", "operator<<"}, {"__op_rshift__", "operator>>"},
                {"__op_bitnot__", "operator~"},
            };
            auto oit = op_map.find(smethod_name);
            if (oit == op_map.end()) oit = op_map.find(method_name);
            auto boit = ball_op_map.find(smethod_name);
            std::string cpp_op;
            if (oit != op_map.end()) cpp_op = oit->second;
            else if (boit != ball_op_map.end()) cpp_op = boit->second;
            else cpp_op = smethod_name; // fallback: emit as-is
            out_ << map_return_type(*func) << " " << cpp_op << "(";
        } else {
            out_ << map_return_type(*func) << " " << smethod_name << "(";
        }
        auto params = func->has_metadata() ? extract_params(func->metadata()) : std::vector<std::string>{};
        auto param_specs = func->has_metadata()
                               ? extract_param_specs(func->metadata())
                               : std::vector<ParamSpec>{};
        // Emit one method parameter. Required params stay `auto&&` (perfect
        // forwarding, matching the rest of the engine); an optional param is
        // pinned to a concrete type and — on its declaration — given its Dart
        // default so call sites that omit it compile. `with_default` is false
        // for the out-of-line definition (C++ forbids repeating the default).
        // EXCEPTION: virtual methods cannot use `auto&&` (template) params in
        // C++. Pin them to BallDyn (or mapped type if available).
        auto emit_method_param = [&](size_t i, bool with_default) {
            std::string pname = sanitize_name(params[i]);
            const bool optional = i < param_specs.size() && param_specs[i].optional;
            if (!optional) {
                if (needs_virtual) {
                    // Virtual methods can't be templates. Use BallDyn or mapped type.
                    std::string t = (i < param_specs.size() && !param_specs[i].type.empty())
                                        ? map_type(param_specs[i].type)
                                        : "BallDyn";
                    if (t == "auto&&" || t == "auto") t = "BallDyn";
                    out_ << t << " " << pname;
                } else {
                    out_ << "auto&& " << pname;
                }
                return;
            }
            std::string t = (!param_specs[i].type.empty())
                                ? map_type(param_specs[i].type)
                                : "BallDyn";
            if (t == "auto&&" || t == "auto") t = "BallDyn";
            out_ << t << " " << pname;
            if (with_default)
                out_ << " = " << cpp_param_default(t, param_specs[i].def);
        };
        for (size_t i = 0; i < params.size(); i++) {
            if (i > 0) out_ << ", ";
            emit_method_param(i, /*with_default=*/true);
        }

        // Abstract methods → pure virtual with no body.
        if (is_abstract) {
            out_ << ") = 0;\n";
            continue;
        }

        if (split_mode_ && func->has_body()) {
            out_ << ");\n";
            std::ostringstream saved;
            saved.swap(out_);
            int saved_indent = indent_;
            emit_indent();
            if (is_static) out_ << "static ";
            if (is_conv) {
                std::string conv_type = map_return_type(*func);
                if (meta.count("conversion_type") && !meta["conversion_type"].empty()) {
                    conv_type = map_type(meta["conversion_type"]);
                }
                out_ << conv_type << " " << name << "::operator " << conv_type << "(";
            } else {
                out_ << map_return_type(*func) << " " << name << "::"
                     << smethod_name << "(";
            }
            for (size_t i = 0; i < params.size(); i++) {
                if (i > 0) out_ << ", ";
                emit_method_param(i, /*with_default=*/false);
            }
            out_ << ") {\n";
            indent_++;
            {
                auto mrt = map_return_type(*func);
                if (func->body().expr_case() == ball::v1::Expression::kBlock) {
                    for (const auto& s : func->body().block().statements())
                        compile_statement(s);
                    if (func->body().block().has_result()) {
                        if (mrt == "void")
                            emit_line(compile_expr(func->body().block().result()) + ";");
                        else
                            emit_line("return " + compile_expr(func->body().block().result()) + ";");
                    }
                } else {
                    if (mrt == "void")
                        emit_line(compile_expr(func->body()) + ";");
                    else
                        emit_line("return " + compile_expr(func->body()) + ";");
                }
                if (mrt != "void") emit_line("return " + mrt + "();");
            }
            indent_--;
            emit_line("}");
            queue_split_definition(out_.str());
            out_.str("");
            out_.clear();
            out_.swap(saved);
            indent_ = saved_indent;
        } else {
            out_ << ") {\n";
            indent_++;
            if (func->has_body()) {
                auto mrt = map_return_type(*func);
                if (func->body().expr_case() == ball::v1::Expression::kBlock) {
                    for (const auto& s : func->body().block().statements())
                        compile_statement(s);
                    if (func->body().block().has_result()) {
                        if (mrt == "void")
                            emit_line(compile_expr(func->body().block().result()) + ";");
                        else
                            emit_line("return " +
                                       compile_expr(func->body().block().result()) + ";");
                    }
                } else {
                    if (mrt == "void")
                        emit_line(compile_expr(func->body()) + ";");
                    else
                        emit_line("return " + compile_expr(func->body()) + ";");
                }
            }
            {
                auto mrt = map_return_type(*func);
                if (mrt != "void") emit_line("return " + mrt + "();");
            }
            indent_--;
            emit_line("}");
        }
    }

    // Check if any method is named "toString" (non-static, non-abstract).
    bool has_to_string = false;
    for (const auto* func : methods) {
        auto m = read_meta(*func);
        auto mk = m.count("kind") ? m["kind"] : "method";
        if (mk != "method") continue;
        if (m.count("is_static") && m["is_static"] == "true") continue;
        if (m.count("is_abstract") && m["is_abstract"] == "true") continue;
        auto d = func->name().rfind('.');
        std::string mn = d != std::string::npos ? func->name().substr(d + 1) : func->name();
        if (mn == "toString") { has_to_string = true; break; }
    }

    current_class_methods_.clear();
    current_class_name_.clear();

    indent_--;
    emit_line("};");

    // Emit ball_to_string overload for user classes with a toString method,
    // so `ball_to_string(obj)` calls `obj.toString()` (Dart behavior).
    if (has_to_string) {
        emit_line("inline std::string ball_to_string(const " + name +
                  "& obj) { return ball_to_string(const_cast<" + name +
                  "&>(obj).toString()); }");
    }
    emit_newline();
}

void CppCompiler::emit_function(const ball::v1::FunctionDefinition& func) {
    auto return_type = map_return_type(func);
    auto meta = read_meta(func);
    auto name = sanitize_name(func.name());
    // Resolve overloaded/part-mangled names before intrinsic matching.
    if (meta.count("original_name")) {
        name = sanitize_name(meta["original_name"]);
    }
    auto params = func.has_metadata() ? extract_params(func.metadata()) : std::vector<std::string>{};

    // Runtime intrinsic: insertion-ordered map factory.
    if (name == "_ballUserMap") {
        emit_indent();
        out_ << return_type << " " << name << "() {\n";
        indent_++;
        emit_line("return BallDyn(BallOrderedMap{});");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballNewGenerator") {
        emit_indent();
        out_ << return_type << " " << name << "() {\n";
        indent_++;
        emit_line("return BallDyn(BallGenerator{});");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballGeneratorValues") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn gen) {\n";
        indent_++;
        // Bind the std::any to a NAMED local before unwrap — passing the
        // temporary `static_cast<std::any>(gen)` directly returns a reference
        // into a destroyed temporary, so the type-test reads `void` and the
        // generator's collected values come back empty. (Mirrors yield_/yieldAll
        // in ball_dyn.h.)
        emit_line("std::any genAny = static_cast<std::any>(gen);");
        emit_line("const std::any& u = _BallDynUnwrapper::unwrap(genAny);");
        emit_line("if (u.type() == typeid(BallGenerator))");
        emit_line("    return BallDyn(ball_list_copy(*std::any_cast<const BallGenerator&>(u).values));");
        emit_line("return BallDyn(BallList{});");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballDoubleToInt64") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn value) {\n";
        indent_++;
        emit_line("if (ball_is_int(value)) return value;");
        emit_line("return BallDyn(ball_double_to_int64(static_cast<double>(value)));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballCodeUnitAt") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn s, BallDyn index) {\n";
        indent_++;
        emit_line("return BallDyn(ball_code_unit_at(s, static_cast<int64_t>(index)));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballIsInt") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("return BallDyn(ball_is_int(v) || ball_object_type_matches(v, \"BallInt\"s));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballIsDouble") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("return BallDyn(ball_is_double(v) || ball_object_type_matches(v, \"BallDouble\"s));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballIsNum") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("return BallDyn((ball_is_int(v) || ball_is_double(v)) || ball_object_type_matches(v, \"BallInt\"s) || ball_object_type_matches(v, \"BallDouble\"s));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballIsString") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("return BallDyn(ball_is_string(v) || ball_object_type_matches(v, \"BallString\"s));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballIsBool") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("return BallDyn(ball_is_bool(v) || ball_object_type_matches(v, \"BallBool\"s));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballIsList") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("return BallDyn(ball_is_list(v) || ball_object_type_matches(v, \"BallList\"s));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballIsMap") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("return BallDyn(ball_is_map_dyn(v) || ball_object_type_matches(v, \"BallMap\"s));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballRuntimeTypeName") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn value) {\n";
        indent_++;
        emit_line("return BallDyn(ball_runtime_type_name(value));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballToDouble") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn value) {\n";
        indent_++;
        emit_line("if (ball_is_int(value)) return BallDyn(static_cast<double>(static_cast<int64_t>(value)));");
        emit_line("if (ball_is_double(value)) return value;");
        emit_line("return BallDyn(static_cast<double>(value));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballMapValues") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn map) {\n";
        indent_++;
        emit_line("return ball_list_copy(ball_map_values(map));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballMapValuesDyn") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn map) {\n";
        indent_++;
        emit_line("return ball_list_copy(ball_map_values(map));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballMapContainsKeyDyn") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn map, BallDyn key) {\n";
        indent_++;
        emit_line("return BallDyn(map.count(BallDyn(key)) > 0);");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballMapSetDyn") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn map, BallDyn key, BallDyn value) {\n";
        indent_++;
        emit_line("ball_set(map, std::string(ball_to_string(BallDyn(key))), std::any(BallDyn(value)));");
        emit_line("return BallDyn();");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballMapKeysDyn") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn map) {\n";
        indent_++;
        emit_line("return ball_list_copy(ball_map_keys(map));");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballNumIsNaN") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("if (ball_is_int(v)) return BallDyn(false);");
        emit_line("if (ball_is_double(v)) return BallDyn(std::isnan(static_cast<double>(v)));");
        emit_line("return BallDyn(false);");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballNumIsFinite") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("if (ball_is_int(v)) return BallDyn(true);");
        emit_line("if (ball_is_double(v)) return BallDyn(std::isfinite(static_cast<double>(v)));");
        emit_line("return BallDyn(false);");
        indent_--;
        emit_line("}\n");
        return;
    }
    if (name == "_ballNumIsInfinite") {
        emit_indent();
        out_ << return_type << " " << name << "(BallDyn v) {\n";
        indent_++;
        emit_line("if (ball_is_int(v)) return BallDyn(false);");
        emit_line("if (ball_is_double(v)) return BallDyn(std::isinf(static_cast<double>(v)));");
        emit_line("return BallDyn(false);");
        indent_--;
        emit_line("}\n");
        return;
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
    } else {
        // Operator methods are emitted as plain identifiers; see the
        // matching note in emit_struct above.
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
                                : "auto&&";
            out_ << t << " " << sanitize_name(params[i]);
        }
    } else if (!func.input_type().empty()) {
        out_ << map_type(func.input_type()) << " input";
    }
    out_ << ") {\n";
    indent_++;

    if (name == "ballObjectSetField") {
        emit_line("ball_object_set_field(BallDyn(target), "
                  "ball_to_string(BallDyn(fieldName)), BallDyn(val));");
        emit_line("return BallDyn();");
        indent_--;
        emit_line("}");
        emit_newline();
        return;
    }

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

    // Record this function's locals (params + every `let`) so references to a
    // local named `num`/`int`/`String`/… resolve to the variable rather than
    // the Dart type-object string literal.
    declared_locals_.clear();
    generic_locals_.clear();
    for (const auto& p : params) declared_locals_.insert(p);
    if (func.has_body()) _collect_declared_locals(func.body(), declared_locals_);

    // Detect sync*/async* generator functions from metadata.
    bool is_generator = false;
    if (meta.count("is_sync_star") && meta["is_sync_star"] == "true") is_generator = true;
    if (meta.count("is_async_star") && meta["is_async_star"] == "true") is_generator = true;
    bool prev_in_generator = in_generator_;
    if (is_generator) {
        in_generator_ = true;
        emit_line("BallGenerator __gen;");
    }

    if (func.has_body()) {
        if (func.body().expr_case() == ball::v1::Expression::kBlock) {
            for (const auto& s : func.body().block().statements())
                compile_statement(s);
            if (func.body().block().has_result()) {
                if (is_generator) {
                    // For generators, the result expression is typically unused;
                    // the collected values are returned instead.
                    emit_line(compile_expr(func.body().block().result()) + ";");
                } else {
                    emit_line("return " + compile_expr(func.body().block().result()) + ";");
                }
            }
        } else {
            if (is_generator) {
                emit_line(compile_expr(func.body()) + ";");
            } else {
                emit_line("return " + compile_expr(func.body()) + ";");
            }
        }
    }
    if (is_generator) {
        emit_line("return BallDyn(*__gen.values);");
    } else if (return_type != "void") {
        emit_line("return " + return_type + "();");
    }
    in_generator_ = prev_in_generator;
    declared_locals_.clear();
    generic_locals_.clear();

    indent_--;
    emit_line("}");
    emit_newline();
}

void CppCompiler::emit_top_level_var(const ball::v1::FunctionDefinition& func) {
    // Skip constants already defined in the preamble
    auto bare_name = sanitize_name(func.name());
    if (bare_name == "_builtinTypeNames" || bare_name == "_stdFunctionToOperator" ||
        bare_name == "_sentinel") {
        return;
    }
    auto meta = read_meta(func);
    std::string modifier = "auto";
    if (meta.count("is_const") && meta["is_const"] == "true") modifier = "const auto";
    if (meta.count("is_final") && meta["is_final"] == "true") modifier = "const auto";

    const std::string name = sanitize_name(func.name());
    declared_locals_.clear();
    generic_locals_.clear();
    if (func.has_body()) _collect_declared_locals(func.body(), declared_locals_);
    const std::string init = func.has_body() ? compile_expr(func.body()) : "0";
    declared_locals_.clear();
    generic_locals_.clear();
    emit_indent();
    // A namespace-scope (non-local) lambda may not carry a [&]/[=] capture
    // default under gcc/clang. When a top-level initializer is such an IIFE
    // (e.g. a map/block comprehension), route it through a named helper
    // function — inside which the capture default is in function scope and so
    // legal — preserving the deduced type via `auto`.
    if (init.rfind("[&]", 0) == 0 || init.rfind("[=]", 0) == 0) {
        out_ << "inline auto _ballinit_" << name << "() { return " << init
             << "; }\n";
        emit_indent();
        out_ << modifier << " " << name << " = _ballinit_" << name << "();\n";
    } else {
        out_ << modifier << " " << name << " = " << init << ";\n";
    }
}

void CppCompiler::emit_main(const ball::v1::FunctionDefinition& entry) {
    emit_line("int main() {");
    indent_++;

    // Record main's locals so a `let num` (etc.) shadows the Dart type-object
    // string-literal special-casing in compile_reference.
    declared_locals_.clear();
    generic_locals_.clear();
    if (entry.has_body()) _collect_declared_locals(entry.body(), declared_locals_);

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
    emit_namespace_open();
    emit_newline();

    // Enums — emit before forward declarations so function signatures
    // that reference enum types (e.g. `colorName(Color c)`) can resolve.
    for (const auto& ed : main_module->enums()) {
        emit_enum(ed);
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

    // Top-level variables — emit BEFORE classes so class methods that
    // reference them (e.g. `value.size() * _ballPointerBytes`) resolve
    // the identifier without a forward-declaration round.
    for (const auto* func : top_level_vars) {
        emit_top_level_var(*func);
    }
    if (!top_level_vars.empty()) emit_newline();

    // Structs/classes — skip types whose sanitized name collides with
    // runtime-provided types (e.g., the preamble already defines
    // BallException, File, JsonEncoder, JsonDecoder, Map_from, etc.).
    static const std::set<std::string> runtime_types = {
        "BallException", "File", "JsonEncoder", "JsonDecoder",
        "Map_from", "FunctionType",
        "_FlowSignal", "_Scope", "BallRuntimeError", "BallFuture",
        "BallGenerator", "_ExitSignal", "BallModuleHandler",
        "StdModuleHandler",
        // Self-hosted engine types provided by ball_emit_runtime.h
        "BallObject", "List_filled",
    };
    // Topological sort: emit parent types before child types so
    // superclass structs are fully defined before subclasses reference them.
    {
        // Collect non-skipped type_defs as pointers.
        std::vector<const ball::v1::TypeDefinition*> sorted_tds;
        for (const auto& td : main_module->type_defs()) {
            if (!td.has_descriptor_()) continue;
            if (runtime_types.count(sanitize_name(td.name())) > 0) continue;
            sorted_tds.push_back(&td);
        }
        // Compute inheritance depth for each type (0 = no superclass/mixins).
        // Types with mixins must sort after the mixin types they depend on.
        auto depth_of = [&](const ball::v1::TypeDefinition* td) -> int {
            int d = 0;
            std::string cur = td->name();
            std::set<std::string> visited;
            while (true) {
                auto sit = class_superclass_.find(cur);
                if (sit == class_superclass_.end() || sit->second.empty()) break;
                if (visited.count(cur)) break; // cycle guard
                visited.insert(cur);
                // Resolve bare superclass name to full key
                std::string next;
                for (const auto& [c, _] : class_superclass_) {
                    auto cc = c.find(':');
                    std::string bare = cc != std::string::npos ? c.substr(cc + 1) : c;
                    if (bare == sit->second) { next = c; break; }
                }
                if (next.empty()) { d++; break; }
                cur = next;
                d++;
            }
            // Also account for mixin dependencies: a class using mixins must
            // sort after the mixin type definitions.
            if (td->has_metadata()) {
                auto mixins = read_meta_list(td->metadata(), "mixins");
                if (!mixins.empty() && d == 0) d = 1;
            }
            return d;
        };
        std::stable_sort(sorted_tds.begin(), sorted_tds.end(),
            [&](const ball::v1::TypeDefinition* a, const ball::v1::TypeDefinition* b) {
                return depth_of(a) < depth_of(b);
            });
        for (const auto* td : sorted_tds) {
            auto it = class_methods.find(td->name());
            auto methods = it != class_methods.end() ? it->second : std::vector<const ball::v1::FunctionDefinition*>{};
            emit_struct(*td, methods);
        }
    }

    // Standalone functions
    for (const auto* func : standalone) {
        emit_function(*func);
    }

    emit_namespace_close();
    emit_newline();

    // Main entry point (global scope — has access to everything in the
    // anonymous namespace via unqualified lookup).
    if (entry_func) {
        emit_main(*entry_func);
    }

    return out_.str();
}

CompileSplitResult CppCompiler::compile_split(const std::string& output_dir,
                                              int num_shards) {
    if (num_shards < 1) num_shards = 1;
    split_mode_ = true;
    split_shards_ = num_shards;
    split_next_shard_ = 0;
    split_pending_.clear();

    std::filesystem::create_directories(output_dir);

    // Header + declarations (no out-of-line bodies).
    out_.str("");
    out_.clear();
    emit_line("// Generated by ball compiler (C++ target, multi-TU)");
    emit_line("// Source: " + program_.name() + " v" + program_.version());
    emit_newline();
    emit_line("#pragma once");
    emit_includes();

    const ball::v1::Module* main_module = nullptr;
    const ball::v1::FunctionDefinition* entry_func = nullptr;
    for (const auto& mod : program_.modules()) {
        if (mod.name() == program_.entry_module()) {
            main_module = &mod;
            break;
        }
    }
    if (!main_module) {
        throw std::runtime_error("Entry module \"" + program_.entry_module() + "\" not found");
    }
    for (const auto& func : main_module->functions()) {
        if (func.name() == program_.entry_function()) {
            entry_func = &func;
            break;
        }
    }

    if (base_modules_.count("std_memory")) {
        emit_line("// Ball linear memory runtime");
        emit_line("static uint8_t _ball_memory[65536];");
        emit_line("static size_t _ball_heap_ptr = 0;");
        emit_line("static size_t _ball_stack_ptr = 65536;");
        emit_line("static std::vector<size_t> _ball_stack_frames;");
        emit_newline();
    }

    emit_namespace_open();
    emit_newline();
    emit_forward_decls(*main_module);

    std::unordered_map<std::string, std::vector<const ball::v1::FunctionDefinition*>>
        class_methods;
    std::vector<const ball::v1::FunctionDefinition*> standalone;
    std::vector<const ball::v1::FunctionDefinition*> top_level_vars;

    for (const auto& func : main_module->functions()) {
        if (func.is_base()) continue;
        if (entry_func && func.name() == program_.entry_function()) continue;
        auto meta = read_meta(func);
        auto kind = meta.count("kind") ? meta["kind"] : "function";
        if (kind == "method" || kind == "constructor" || kind == "static_field" ||
            kind == "operator") {
            auto colon = func.name().find(':');
            std::string after =
                colon != std::string::npos ? func.name().substr(colon + 1) : func.name();
            auto dot = after.find('.');
            if (dot != std::string::npos) {
                std::string class_key =
                    func.name().substr(0, (colon != std::string::npos ? colon + 1 : 0) + dot);
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

    static const std::set<std::string> runtime_types = {
        "BallException", "File", "JsonEncoder", "JsonDecoder",
        "Map_from", "FunctionType",
        "_FlowSignal", "_Scope", "BallRuntimeError", "BallFuture",
        "BallGenerator", "_ExitSignal", "BallModuleHandler",
        "StdModuleHandler",
        "BallObject", "List_filled",
    };

    for (const auto& ed : main_module->enums()) {
        emit_enum(ed);
    }
    for (const auto* func : top_level_vars) {
        emit_top_level_var(*func);
    }
    if (!top_level_vars.empty()) emit_newline();

    // Topological sort: emit parent types before child types (split path).
    {
        std::vector<const ball::v1::TypeDefinition*> sorted_tds;
        for (const auto& td : main_module->type_defs()) {
            if (!td.has_descriptor_()) continue;
            if (runtime_types.count(sanitize_name(td.name())) > 0) continue;
            sorted_tds.push_back(&td);
        }
        auto depth_of = [&](const ball::v1::TypeDefinition* td) -> int {
            int d = 0;
            std::string cur = td->name();
            std::set<std::string> visited;
            while (true) {
                auto sit = class_superclass_.find(cur);
                if (sit == class_superclass_.end() || sit->second.empty()) break;
                if (visited.count(cur)) break;
                visited.insert(cur);
                std::string next;
                for (const auto& [c, _] : class_superclass_) {
                    auto cc = c.find(':');
                    std::string bare = cc != std::string::npos ? c.substr(cc + 1) : c;
                    if (bare == sit->second) { next = c; break; }
                }
                if (next.empty()) { d++; break; }
                cur = next;
                d++;
            }
            if (td->has_metadata()) {
                auto mixins = read_meta_list(td->metadata(), "mixins");
                if (!mixins.empty() && d == 0) d = 1;
            }
            return d;
        };
        std::stable_sort(sorted_tds.begin(), sorted_tds.end(),
            [&](const ball::v1::TypeDefinition* a, const ball::v1::TypeDefinition* b) {
                return depth_of(a) < depth_of(b);
            });
        for (const auto* td : sorted_tds) {
            auto it = class_methods.find(td->name());
            auto methods = it != class_methods.end()
                               ? it->second
                               : std::vector<const ball::v1::FunctionDefinition*>{};
            emit_struct(*td, methods);
        }
    }

    for (const auto* func : standalone) {
        emit_function_signature_only(*func);
        emit_function_body_out_of_line(*func);
    }

    emit_namespace_close();
    emit_newline();

    const std::string common_path =
        (std::filesystem::path(output_dir) / "engine_rt_common.hpp").string();
    {
        std::ofstream common_out(common_path);
        if (!common_out) {
            throw std::runtime_error("Could not open " + common_path);
        }
        common_out << out_.str();
    }

    // Distribute queued definitions across shard .cpp files.
    std::vector<std::ostringstream> shard_bufs(static_cast<size_t>(num_shards));
    size_t idx = 0;
    for (const auto& def : split_pending_) {
        shard_bufs[idx % static_cast<size_t>(num_shards)] << def << "\n";
        idx++;
    }

    CompileSplitResult result;
    result.output_dir = output_dir;
    result.num_shards = num_shards;
    result.common_header = common_path;

    for (int s = 0; s < num_shards; ++s) {
        char name[64];
        std::snprintf(name, sizeof(name), "engine_rt_shard_%02d.cpp", s);
        const std::string shard_path =
            (std::filesystem::path(output_dir) / name).string();
        std::ofstream shard_out(shard_path);
        if (!shard_out) {
            throw std::runtime_error("Could not open " + shard_path);
        }
        shard_out << "// Generated shard " << s << " of " << num_shards << "\n";
        shard_out << "#include \"engine_rt_common.hpp\"\n\n";
        shard_out << "namespace " << kSplitNamespace << " {\n\n";
        shard_out << shard_bufs[static_cast<size_t>(s)].str();
        shard_out << "} // namespace " << kSplitNamespace << "\n";
        result.shard_sources.push_back(shard_path);
    }

    // Consumer header for tests / embedders.
    const std::string link_path =
        (std::filesystem::path(output_dir) / "engine_rt_link.hpp").string();
    {
        std::ofstream link_out(link_path);
        link_out << "#pragma once\n";
        link_out << "#include \"engine_rt_common.hpp\"\n";
        link_out << "namespace ball_rt_public {\n";
        link_out << "using ball_rt::BallEngine;\n";
        link_out << "using ball_rt::BallDyn;\n";
        link_out << "using ball_rt::BallMap;\n";
        link_out << "using ball_rt::BallList;\n";
        link_out << "using ball_rt::BallFunc;\n";
        link_out << "using ball_rt::StdModuleHandler;\n";
        link_out << "using ball_rt::ball_to_string;\n";
        link_out << "} // namespace ball_rt_public\n";
        link_out << "using namespace ball_rt_public;\n";
    }

    split_mode_ = false;
    split_pending_.clear();
    return result;
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
    // List operations — all use BallDyn to handle both raw vectors and
    // reference-semantic BallListRef transparently.
    if (fn == "list_push") {
        auto list = get_message_field(call, "list");
        auto val = get_message_field(call, "value");
        return "[](BallDyn v, BallDyn e){v.push_back(e._val);return v;}(" + list + "," + val + ")";
    }
    if (fn == "list_pop") {
        auto list = get_message_field(call, "list");
        return "ball_list_pop(" + list + ")";
    }
    if (fn == "list_get") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        return "BallDyn(" + list + ")[static_cast<int64_t>(" + idx + ")]";
    }
    if (fn == "list_set") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        auto val = get_message_field(call, "value");
        return "[](BallDyn v, int64_t i, BallDyn e){v.set(i,e._val);return v;}(" + list + "," + idx + "," + val + ")";
    }
    if (fn == "list_length") {
        auto list = get_message_field(call, "list");
        return "static_cast<int64_t>(BallDyn(" + list + ").size())";
    }
    if (fn == "list_is_empty") {
        auto list = get_message_field(call, "list");
        return "BallDyn(" + list + ").empty()";
    }
    if (fn == "list_first") {
        return "BallDyn(" + get_message_field(call, "list") + ").front()";
    }
    if (fn == "list_last") {
        return "BallDyn(" + get_message_field(call, "list") + ").back()";
    }
    if (fn == "list_contains") {
        auto list = get_message_field(call, "list");
        auto val = get_message_field(call, "value");
        return "(ball_index_of(" + list + "," + val + ") >= 0)";
    }
    if (fn == "list_index_of") {
        auto list = get_message_field(call, "list");
        auto val = get_message_field(call, "value");
        // Use ball_index_of helper that handles both strings and vectors
        return "ball_index_of(" + list + ", " + val + ")";
    }
    if (fn == "list_reverse") {
        auto list = get_message_field(call, "list");
        return "[](BallDyn v){if(BallList* l=v._listPtr()){std::reverse(l->begin(),l->end());}return v;}(" + list + ")";
    }
    if (fn == "list_insert") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        auto val = get_message_field(call, "value");
        return "ball_list_insert("
               + list + "," + idx + "," + val + ")";
    }
    if (fn == "list_remove_at") {
        auto list = get_message_field(call, "list");
        auto idx = get_message_field(call, "index");
        return "ball_list_remove_at(" + list + "," + idx + ")";
    }
    if (fn == "list_single") {
        return "BallDyn(" + get_message_field(call, "list") + ")[static_cast<int64_t>(0)]";
    }
    if (fn == "list_map") {
        auto list = get_message_field(call, "list");
        auto* cb_e = get_message_field_expr(call, "callback");
        if (!cb_e) cb_e = get_message_field_expr(call, "function");
        if (!cb_e) cb_e = get_message_field_expr(call, "value");
        auto callback = cb_e ? compile_expr(*cb_e) : "BallDyn()";
        return "[](const BallDyn& v, auto fn) -> BallDyn {BallList r;for(size_t i=0;i<v.size();i++)r.push_back(std::any(fn(v[static_cast<int64_t>(i)])));return BallDyn(r);}("
               + list + "," + callback + ")";
    }
    if (fn == "list_filter") {
        auto list = get_message_field(call, "list");
        auto* cb_e = get_message_field_expr(call, "callback");
        if (!cb_e) cb_e = get_message_field_expr(call, "function");
        if (!cb_e) cb_e = get_message_field_expr(call, "value");
        auto callback = cb_e ? compile_expr(*cb_e) : "BallDyn()";
        return "[](const BallDyn& v, auto fn) -> BallDyn {BallList r;for(size_t i=0;i<v.size();i++){auto e=v[static_cast<int64_t>(i)];if(_ball_pred_true(std::any(fn(e))))r.push_back(std::any(e));}return BallDyn(r);}("
               + list + "," + callback + ")";
    }
    if (fn == "list_reduce") {
        auto list = get_message_field(call, "list");
        auto callback = get_callback_field(call);
        auto initial = get_message_field(call, "initial");
        return "[](const BallDyn& v, auto fn, BallDyn init){"
               "BallDyn acc=init;for(size_t i=0;i<v.size();i++){"
               "BallDyn __e(v[static_cast<int64_t>(i)]);"
               "BallDyn p(BallOrderedMap{});p.set(\"accumulator\"s,acc._val);p.set(\"element\"s,__e._val);"
               "acc=BallDyn(fn(p));}return acc;}("
               + list + "," + callback + "," + initial + ")";
    }
    if (fn == "list_find") {
        auto list = get_message_field(call, "list");
        auto callback = get_callback_field(call);
        return "[](const BallDyn& v, auto fn)->BallDyn{"
               "for(size_t i=0;i<v.size();i++){BallDyn __e(v[static_cast<int64_t>(i)]);if(_ball_pred_true(fn(__e)))return __e;}return BallDyn();}("
               + list + "," + callback + ")";
    }
    if (fn == "list_any") {
        auto list = get_message_field(call, "list");
        auto callback = get_callback_field(call);
        return "[](const BallDyn& v, auto fn){"
               "for(size_t i=0;i<v.size();i++){BallDyn __e(v[static_cast<int64_t>(i)]);if(_ball_pred_true(fn(__e)))return true;}return false;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_all") {
        auto list = get_message_field(call, "list");
        auto callback = get_callback_field(call);
        return "[](const BallDyn& v, auto fn){"
               "for(size_t i=0;i<v.size();i++){BallDyn __e(v[static_cast<int64_t>(i)]);if(!_ball_pred_true(fn(__e)))return false;}return true;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_none") {
        auto list = get_message_field(call, "list");
        auto callback = get_callback_field(call);
        return "[](const BallDyn& v, auto fn){"
               "for(size_t i=0;i<v.size();i++){BallDyn __e(v[static_cast<int64_t>(i)]);if(_ball_pred_true(fn(__e)))return false;}return true;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_sort") {
        auto list = get_message_field(call, "list");
        // Sort in place on the shared list (reference semantics) and return the
        // same handle, so `list.sort()` mutates the caller's list.
        return "[](BallDyn v){if(BallList* l=v._listPtr()){std::sort(l->begin(),l->end(),[](const std::any& a,const std::any& b){return ball_natural_less(a,b);});}return v;}(" + list + ")";
    }
    if (fn == "list_sort_by") {
        auto list = get_message_field(call, "list");
        auto callback = get_callback_field(call);
        return "[](BallDyn v, auto fn){if(BallList* l=v._listPtr()){std::sort(l->begin(),l->end(),"
               "[&](const std::any& a, const std::any& b){"
               "BallDyn p(BallOrderedMap{});p.set(\"left\"s,a);p.set(\"right\"s,b);"
               "return static_cast<bool>(BallDyn(fn(p)));});}return v;}("
               + list + "," + callback + ")";
    }
    if (fn == "list_concat") {
        auto* left_e = get_message_field_expr(call, "left");
        if (!left_e) left_e = get_message_field_expr(call, "list");
        auto* right_e = get_message_field_expr(call, "right");
        if (!right_e) right_e = get_message_field_expr(call, "value");
        auto left = left_e ? compile_expr(*left_e) : "BallDyn()";
        auto right = right_e ? compile_expr(*right_e) : "BallDyn()";
        return "ball_concat(" + left + "," + right + ")";
    }
    if (fn == "list_slice") {
        auto list = get_message_field(call, "list");
        auto start = get_message_field(call, "start");
        auto end = get_optional_field(call, "end");
        if (end.empty()) {
            return "ball_sublist(" + list + "," + start + ")";
        }
        return "ball_sublist(" + list + "," + start + "," + end + ")";
    }
    if (fn == "string_join") {
        auto list = get_message_field(call, "list");
        auto sep = get_message_field(call, "separator");
        return "[](const BallDyn& v, const std::string& s){"
               "std::string r;for(size_t i=0;i<v.size();i++){"
               "if(i>0)r+=s;r+=ball_to_string(v[static_cast<int64_t>(i)]);}return r;}(" + list + "," + sep + ")";
    }
    if (fn == "list_take") {
        auto list = get_message_field(call, "list");
        auto count = get_message_field(call, "count");
        return "[](const BallDyn& v, int64_t n) -> BallDyn {"
               "BallList r;int64_t len=std::min(n,static_cast<int64_t>(v.size()));"
               "for(int64_t i=0;i<len;i++)r.push_back(std::any(v[i]));"
               "return BallDyn(r);}("
               + list + "," + count + ")";
    }
    if (fn == "list_drop") {
        auto list = get_message_field(call, "list");
        auto count = get_message_field(call, "count");
        return "ball_skip(" + list + "," + count + ")";
    }
    if (fn == "list_to_list") {
        auto list = get_message_field(call, "list");
        // Dart's `list.toList()` returns a fresh COPY. With reference-semantic
        // lists the value is shared, so emit an explicit copy — otherwise mutating
        // the result would alias the source list.
        return "ball_list_copy(" + list + ")";
    }
    if (fn == "list_flat_map") {
        auto list = get_message_field(call, "list");
        auto callback = get_callback_field(call);
        return "[](const BallDyn& v, auto fn) -> BallDyn {BallList r;"
               "for(size_t i=0;i<v.size();i++){BallDyn __e(v[static_cast<int64_t>(i)]);"
               "BallDyn sub(fn(__e));for(size_t j=0;j<sub.size();j++)r.push_back(std::any(BallDyn(sub[static_cast<int64_t>(j)])));"
               "}return BallDyn(r);}("
               + list + "," + callback + ")";
    }
    if (fn == "list_zip") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](const BallDyn& a, const BallDyn& b) -> BallDyn {"
               "BallList r;int64_t n=std::min(a.size(),b.size());"
               "for(int64_t i=0;i<n;i++){BallDyn p(BallOrderedMap{});"
               "p.set(\"first\"s,std::any(a[i]));p.set(\"second\"s,std::any(b[i]));"
               "r.push_back(std::any(p));}return BallDyn(r);}(" + left + "," + right + ")";
    }

    // Map operations — all use BallDyn to handle BallOrderedMap/BallMap/BallScope
    // transparently. map_create returns BallOrderedMap (insertion-ordered, Dart
    // LinkedHashMap semantics).
    if (fn == "map_create") return "BallDyn(BallOrderedMap{})";
    if (fn == "map_get") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        // static_cast avoids the most-vexing-parse when `map` is BallDyn(ident).
        return "static_cast<BallDyn>(" + map + ")[" + key + "]";
    }
    if (fn == "map_set") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        auto val = get_message_field(call, "value");
        return "[](BallDyn m, const BallDyn& k, BallDyn v){m.set(static_cast<std::string>(k),v._val);return m;}(" + map + "," + key + "," + val + ")";
    }
    if (fn == "map_delete") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        return "[](BallDyn m, const BallDyn& k){m.erase(static_cast<std::string>(k));return m;}(" + map + "," + key + ")";
    }
    if (fn == "map_contains_key") {
        auto map = get_message_field(call, "map");
        auto key = get_message_field(call, "key");
        return "(BallDyn(" + map + ").count(" + key + ")>0)";
    }
    if (fn == "map_is_empty") {
        return "BallDyn(" + get_message_field(call, "map") + ").empty()";
    }
    if (fn == "map_length") {
        return "static_cast<int64_t>(BallDyn(" + get_message_field(call, "map") + ").size())";
    }
    if (fn == "map_keys") {
        auto map = get_message_field(call, "map");
        return "ball_map_keys(BallDyn(" + map + "))";
    }
    if (fn == "map_values") {
        auto map = get_message_field(call, "map");
        return "ball_map_values(BallDyn(" + map + "))";
    }
    if (fn == "map_entries") {
        auto map = get_message_field(call, "map");
        return "ball_map_entries(BallDyn(" + map + "))";
    }
    if (fn == "map_from_entries") {
        auto entries = get_message_field(call, "entries");
        return "[](const BallDyn& v) -> BallDyn {"
               "BallDyn r(BallOrderedMap{});"
               "for(int64_t i=0;i<v.size();i++){BallDyn e(v[i]);"
               "r.set(static_cast<std::string>(e[\"key\"s]),e[\"value\"s]._val);}return r;}(" + entries + ")";
    }
    if (fn == "map_merge") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](BallDyn a, const BallDyn& b){"
               "auto entries=ball_map_entries(b);"
               "for(const auto& e:entries){BallDyn entry(e);"
               "a.set(static_cast<std::string>(entry[\"key\"s]),entry[\"value\"s]._val);}return a;}("
               + left + "," + right + ")";
    }
    if (fn == "map_map") {
        auto map = get_message_field(call, "map");
        auto callback = get_callback_field(call);
        return "[](const BallDyn& m, auto fn) -> BallDyn {"
               "BallDyn r(BallOrderedMap{});"
               "auto entries=ball_map_entries(m);"
               "for(const auto& raw_e:entries){BallDyn e(raw_e);"
               "BallDyn res(fn(e));"
               "r.set(static_cast<std::string>(res[\"key\"s]),res[\"value\"s]._val);}return r;}("
               + map + "," + callback + ")";
    }
    if (fn == "map_filter") {
        auto map = get_message_field(call, "map");
        auto callback = get_callback_field(call);
        return "[](const BallDyn& m, auto fn) -> BallDyn {"
               "BallDyn r(BallOrderedMap{});"
               "auto entries=ball_map_entries(m);"
               "for(const auto& raw_e:entries){BallDyn e(raw_e);"
               "if(_ball_pred_true(fn(e)))r.set(static_cast<std::string>(e[\"key\"s]),e[\"value\"s]._val);}return r;}("
               + map + "," + callback + ")";
    }

    // Set operations — use BallDyn for element equality (handles all types).
    // Sets are represented as BallDyn lists with uniqueness enforced at add time.
    if (fn == "set_create") return "BallDyn(BallList{})";
    if (fn == "set_add") {
        auto set = get_message_field(call, "set");
        auto val = get_message_field(call, "value");
        return "[](BallDyn v, BallDyn e) -> BallDyn {"
               "for(int64_t i=0;i<v.size();i++){if(BallDyn(v[i])==e)return v;}"
               "v.push_back(e._val);return v;}(" + set + "," + val + ")";
    }
    if (fn == "set_remove") {
        auto set = get_message_field(call, "set");
        auto val = get_message_field(call, "value");
        return "[](BallDyn v, const BallDyn& e) -> BallDyn {"
               "if(BallList* l=v._listPtr()){l->erase(std::remove_if(l->begin(),l->end(),"
               "[&](const std::any& x){return BallDyn(x)==e;}),l->end());}return v;}(" + set + "," + val + ")";
    }
    if (fn == "set_contains") {
        auto set = get_message_field(call, "set");
        auto val = get_message_field(call, "value");
        return "[](const BallDyn& v, const BallDyn& e){"
               "for(int64_t i=0;i<v.size();i++){if(BallDyn(v[i])==e)return true;}"
               "return false;}(" + set + "," + val + ")";
    }
    if (fn == "set_length") {
        return "static_cast<int64_t>(BallDyn(" + get_message_field(call, "set") + ").size())";
    }
    if (fn == "set_is_empty") {
        return "BallDyn(" + get_message_field(call, "set") + ").empty()";
    }
    if (fn == "set_to_list") {
        return get_message_field(call, "set");
    }
    if (fn == "set_union") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](BallDyn a, const BallDyn& b) -> BallDyn {"
               "for(int64_t i=0;i<b.size();i++){BallDyn e(b[i]);bool found=false;"
               "for(int64_t j=0;j<a.size();j++){if(BallDyn(a[j])==e){found=true;break;}}"
               "if(!found)a.push_back(e._val);}return a;}("
               + left + "," + right + ")";
    }
    if (fn == "set_intersection") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](const BallDyn& a, const BallDyn& b) -> BallDyn {BallList r;"
               "for(int64_t i=0;i<a.size();i++){BallDyn e(a[i]);"
               "for(int64_t j=0;j<b.size();j++){if(BallDyn(b[j])==e){r.push_back(e._val);break;}}}"
               "return BallDyn(r);}("
               + left + "," + right + ")";
    }
    if (fn == "set_difference") {
        auto left = get_message_field(call, "left");
        auto right = get_message_field(call, "right");
        return "[](const BallDyn& a, const BallDyn& b) -> BallDyn {BallList r;"
               "for(int64_t i=0;i<a.size();i++){BallDyn e(a[i]);bool found=false;"
               "for(int64_t j=0;j<b.size();j++){if(BallDyn(b[j])==e){found=true;break;}}"
               "if(!found)r.push_back(e._val);}return BallDyn(r);}("
               + left + "," + right + ")";
    }

    if (fn == "list_join") {
        auto list = get_message_field(call, "list");
        auto sep = get_optional_field(call, "separator");
        if (sep.empty()) sep = "std::string(\",\")";
        return "[](const BallDyn& v, const std::string& s){"
               "std::string r;bool first=true;"
               "for(size_t i=0;i<v.size();i++){"
               "if(!first)r+=s;first=false;"
               "r+=ball_to_string(v[static_cast<int64_t>(i)]);}return r;}("
               + list + "," + sep + ")";
    }

    if (fn == "map_contains_value") {
        return "[](const BallDyn& mp, const BallDyn& val){ for (const auto& e : ball_map_entries(mp)) { "
               "if (BallDyn(BallDyn(e)[\"value\"s]) == val) return true; } return false; }(BallDyn(" +
               get_message_field(call, "map") + "), " + get_message_field(call, "value") + ")";
    }
    if (fn == "list_clear") {
        return "(ball_clear(" + get_message_field(call, "list") + "), BallDyn())";
    }
    if (fn == "map_put_if_absent") {
        return "ball_map_put_if_absent(" + get_message_field(call, "map") + ", " +
               get_message_field(call, "key") + ", " + get_message_field(call, "value") + ")";
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
