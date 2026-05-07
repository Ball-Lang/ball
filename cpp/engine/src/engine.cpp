// ball::Engine — full C++ implementation.
//
// Faithful port of the Dart BallEngine: expression tree walking,
// lexical scoping, lazy control flow, full std dispatch, and
// linear memory simulation.
//
// ----------------------------------------------------------------
// Async status
// ----------------------------------------------------------------
// This C++ engine is fully synchronous — no coroutines, no event
// loop, no microtask queue. The Dart engine now has true async
// (every eval method returns Future<BallValue>), but the C++
// engine has not been ported.
//
//  - `await` is a no-op that unwraps BallFuture markers; it does
//    NOT yield or suspend execution.
//  - `sleep_ms` blocks the calling thread via std::this_thread::
//    sleep_for; there is no async delay.
//
// For programs that require real async behavior, use `ball build`
// to resolve dependencies, then run via the Dart engine.
// ----------------------------------------------------------------

#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <numeric>
#include <random>
#include <regex>
#include <sstream>
#include <thread>

namespace ball {

// The exception currently bound inside an active `catch` block, or null.
// Used by the `rethrow` base function to re-raise the original exception.
// thread_local so concurrent engines (future) won't clobber each other;
// saved/restored around each catch body so nested tries unwind cleanly.
static thread_local std::exception_ptr g_active_exception;

// ================================================================
// OOP helpers — type name matching & __super__ chain walking
// ================================================================

// Forward-declared: maps std function names to operator symbols used by
// user-defined overrides. Defined further below alongside other OOP helpers.
static const std::unordered_map<std::string, std::string>& std_function_to_operator();


/// Compare type names accounting for module-qualified forms.
/// "main:Foo" matches "Foo", "Foo" matches "main:Foo", and exact matches.
static bool type_name_matches(const std::string& obj_type, const std::string& check_type) {
    if (obj_type == check_type) return true;
    // obj_type is "module:Foo", check_type is "Foo"
    auto colon1 = obj_type.find(':');
    if (colon1 != std::string::npos && obj_type.substr(colon1 + 1) == check_type) return true;
    // obj_type is "Foo", check_type is "module:Foo"
    auto colon2 = check_type.find(':');
    if (colon2 != std::string::npos && check_type.substr(colon2 + 1) == obj_type) return true;
    // Both qualified but different modules — strip and compare bare names.
    if (colon1 != std::string::npos && colon2 != std::string::npos) {
        return obj_type.substr(colon1 + 1) == check_type.substr(colon2 + 1);
    }
    return false;
}

/// Check if a BallMap value's __type__ (or any __super__ in the chain)
/// matches the given type name.
static bool object_type_matches(const BallValue& value, const std::string& type) {
    if (!is_map(value)) return false;
    const auto& m = std::any_cast<const BallMap&>(value);
    // Check __type__ on the value itself
    auto it = m.find("__type__");
    if (it != m.end() && is_string(it->second)) {
        if (type_name_matches(std::any_cast<const std::string&>(it->second), type)) return true;
    }
    // Walk __super__ chain
    auto sit = m.find("__super__");
    BallValue super_obj = (sit != m.end()) ? sit->second : BallValue{};
    while (is_map(super_obj)) {
        const auto& sm = std::any_cast<const BallMap&>(super_obj);
        auto st = sm.find("__type__");
        if (st != sm.end() && is_string(st->second)) {
            if (type_name_matches(std::any_cast<const std::string&>(st->second), type)) return true;
        }
        auto ss = sm.find("__super__");
        super_obj = (ss != sm.end()) ? ss->second : BallValue{};
    }
    return false;
}

// ================================================================
// Construction
// ================================================================

Engine::Engine(const ball::v1::Program& program,
               std::function<void(const std::string&)> stdout_fn_arg)
    : program_(program),
      stdout_fn(stdout_fn_arg ? std::move(stdout_fn_arg) :
                [this](const std::string& msg) {
                    std::cout << msg << std::endl;
                    output_.push_back(msg);
                }),
      global_scope_(Scope::create()) {
    size_t mem_size = 262144; // 256KB default
    const char* env_mem = std::getenv("BALL_MEMORY_SIZE");
    if (env_mem) {
        size_t parsed = std::stoul(env_mem);
        if (parsed > 0) mem_size = parsed;
    }
    memory_.resize(mem_size, 0);
    stack_ptr_ = mem_size;

    handlers_.push_back(std::make_unique<StdModuleHandler>());
    handlers_.push_back(std::make_unique<StdCollectionsModuleHandler>());
    handlers_.push_back(std::make_unique<StdIoModuleHandler>(&stdout_fn));
    for (auto& h : handlers_) h->init(*this);
    // Wire std → std_collections fallthrough so programs declaring
    // collection functions under "std" (e.g. list_push, list_contains)
    // resolve correctly.
    auto* std_handler = dynamic_cast<StdModuleHandler*>(handlers_[0].get());
    auto* collections_handler = dynamic_cast<StdCollectionsModuleHandler*>(handlers_[1].get());
    if (std_handler && collections_handler) {
        std_handler->set_fallback([collections_handler](const std::string& fn, BallValue input, BallCallable engine) {
            return collections_handler->call(fn, std::move(input), engine);
        });
    }

    build_lookup_tables();
    validate_no_unresolved_imports();
    init_top_level_variables();
}

// ================================================================
// Lookup tables
// ================================================================

void Engine::build_lookup_tables() {
    for (const auto& mod : program_.modules()) {
        for (const auto& type : mod.types()) {
            types_[type.name()] = type;
            auto colon = type.name().find(':');
            if (colon != std::string::npos) {
                types_[type.name().substr(colon + 1)] = type;
            }
        }
        for (const auto& td : mod.type_defs()) {
            if (td.has_descriptor_()) {
                types_[td.name()] = td.descriptor_();
                auto colon = td.name().find(':');
                if (colon != std::string::npos) {
                    types_[td.name().substr(colon + 1)] = td.descriptor_();
                }
            }
        }
        // Index enum types and their values (mirrors Dart _enumValues).
        for (const auto& enum_desc : mod.enums()) {
            const auto& enum_name = enum_desc.name();  // e.g. "main:Color"
            BallMap values;
            for (const auto& v : enum_desc.value()) {
                BallMap value_obj;
                value_obj["__type__"] = enum_name;
                value_obj["name"] = v.name();
                value_obj["index"] = static_cast<int64_t>(v.number());
                values[v.name()] = value_obj;
            }
            enum_values_[enum_name] = values;
            auto ec = enum_name.find(':');
            if (ec != std::string::npos) {
                enum_values_[enum_name.substr(ec + 1)] = values;
            }
        }
        for (const auto& func : mod.functions()) {
            std::string key = mod.name() + "." + func.name();
            // For getters/setters with the same name, store with distinct keys
            // so one doesn't overwrite the other.
            bool is_setter = false;
            if (func.has_metadata()) {
                auto setter_it = func.metadata().fields().find("is_setter");
                if (setter_it != func.metadata().fields().end() && setter_it->second.bool_value()) {
                    is_setter = true;
                    // Store setter with "=" suffix key
                    std::string setter_key = key + "=";
                    functions_[setter_key] = &func;
                    auto params = extract_params(func.metadata());
                    if (!params.empty()) param_cache_[setter_key] = std::move(params);
                }
            }
            if (!is_setter) {
                functions_[key] = &func;
            }
            if (func.has_metadata()) {
                if (!is_setter) {
                    auto params = extract_params(func.metadata());
                    if (!params.empty()) param_cache_[key] = std::move(params);
                }

                // Register constructors so class names resolve as callables.
                auto kind_it = func.metadata().fields().find("kind");
                if (kind_it != func.metadata().fields().end() &&
                    kind_it->second.string_value() == "constructor") {
                    ConstructorEntry entry{mod.name(), &func};
                    // func.name() is "ClassName.new" or "ClassName.named".
                    auto dot_idx = func.name().find('.');
                    if (dot_idx != std::string::npos) {
                        std::string class_name = func.name().substr(0, dot_idx);
                        std::string ctor_suffix = func.name().substr(dot_idx + 1);
                        if (ctor_suffix == "new") {
                            constructors_[class_name] = entry;
                            constructors_[mod.name() + ":" + class_name] = entry;
                        }
                        constructors_[func.name()] = entry;
                    }
                }
            }
        }
    }
}

void Engine::validate_no_unresolved_imports() {
    std::set<std::string> known_modules;
    for (const auto& mod : program_.modules()) {
        known_modules.insert(mod.name());
    }
    for (const auto& mod : program_.modules()) {
        for (const auto& imp : mod.module_imports()) {
            if (known_modules.count(imp.name())) continue;
            if (imp.source_case() == ball::v1::ModuleImport::SOURCE_NOT_SET) continue;
            if (imp.has_inline_()) continue;
            throw BallRuntimeError(
                "Module \"" + imp.name() + "\" has an unresolved import "
                "(source type: " + std::to_string(imp.source_case()) + "). "
                "Run `ball build` to resolve all imports before running "
                "with the C++ engine. Note: the Dart engine supports "
                "true async resolution; the C++ engine is synchronous "
                "and cannot resolve imports at runtime.");
        }
    }
}

std::vector<std::string> Engine::extract_params(const google::protobuf::Struct& metadata) {
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

void Engine::init_top_level_variables() {
    for (const auto& mod : program_.modules()) {
        if (mod.name() == "std" || mod.name() == "dart_std") continue;
        for (const auto& func : mod.functions()) {
            if (!func.has_metadata()) continue;
            auto kind_it = func.metadata().fields().find("kind");
            if (kind_it == func.metadata().fields().end() ||
                kind_it->second.string_value() != "top_level_variable") continue;
            current_module_ = mod.name();
            BallValue value = func.has_body() ? eval_expr(func.body(), global_scope_) : BallValue{};
            global_scope_->bind(func.name(), std::move(value));
        }
    }
}

// ================================================================
// Public API
// ================================================================

BallValue Engine::run() {
    std::string key = program_.entry_module() + "." + program_.entry_function();
    auto it = functions_.find(key);
    if (it == functions_.end()) {
        throw BallRuntimeError("Entry point \"" + program_.entry_function() +
                               "\" not found in module \"" + program_.entry_module() + "\"");
    }
    current_module_ = program_.entry_module();
    return call_function_internal(program_.entry_module(), *it->second, {});
}

BallValue Engine::call_function(const std::string& module,
                                const std::string& function,
                                BallValue input) {
    return resolve_and_call(module, function, std::move(input));
}

// ================================================================
// Function invocation
// ================================================================

BallValue Engine::call_function_internal(const std::string& module_name,
                                         const ball::v1::FunctionDefinition& func,
                                         BallValue input) {
    if (func.is_base()) {
        return call_base_function(module_name, func.name(), std::move(input));
    }

    // Handle constructors with no body but with initializers
    if (!func.has_body()) {
        if (func.has_metadata()) {
            auto kind_it = func.metadata().fields().find("kind");
            if (kind_it != func.metadata().fields().end() &&
                kind_it->second.string_value() == "constructor") {
                // Extract class name from function name (e.g. "main:Point.origin" -> "main:Point")
                auto dot = func.name().find('.');
                std::string class_name = (dot != std::string::npos) ? func.name().substr(0, dot) : func.name();

                // Create the object with the class type
                BallMap obj;
                obj["__type__"] = class_name;

                // Bind params from input for initializer evaluation
                auto scope = std::make_shared<Scope>(global_scope_);
                auto params = extract_params(func.metadata());
                if (is_map(input)) {
                    const auto& m = std::any_cast<const BallMap&>(input);
                    for (size_t i = 0; i < params.size(); ++i) {
                        auto fit = m.find(params[i]);
                        if (fit != m.end()) {
                            scope->bind(params[i], fit->second);
                        } else {
                            auto afit = m.find("arg" + std::to_string(i));
                            if (afit != m.end()) scope->bind(params[i], afit->second);
                        }
                    }
                }

                // Process initializers from metadata
                auto init_it = func.metadata().fields().find("initializers");
                if (init_it != func.metadata().fields().end() &&
                    init_it->second.kind_case() == google::protobuf::Value::kListValue) {
                    for (const auto& iv : init_it->second.list_value().values()) {
                        if (iv.kind_case() != google::protobuf::Value::kStructValue) continue;
                        auto fname_it = iv.struct_value().fields().find("name");
                        auto fval_it = iv.struct_value().fields().find("value");
                        if (fname_it == iv.struct_value().fields().end() || fval_it == iv.struct_value().fields().end()) continue;
                        const auto& fname = fname_it->second.string_value();
                        const auto& fval_str = fval_it->second.string_value();

                        // Evaluate the value string as a mini expression
                        BallValue val = eval_init_string_expr(fval_str, scope);
                        obj[fname] = val;
                    }
                }

                // DEBUG constructor
                if (func.name().find("Vehicle") != std::string::npos || func.name().find("Motor") != std::string::npos || func.name().find("Car") != std::string::npos) {
                    std::cerr << "[CTOR] " << func.name() << " obj keys:";
                    for (const auto& [k,v] : obj) std::cerr << " " << k << "=" << ball::to_string(v);
                    std::cerr << "\n";
                    std::cerr << "[CTOR] scope has type:" << scope->has("type") << " horsepower:" << scope->has("horsepower") << " doors:" << scope->has("doors") << "\n";
                }
                // Process params with is_this: true
                auto params_it = func.metadata().fields().find("params");
                if (params_it != func.metadata().fields().end() &&
                    params_it->second.kind_case() == google::protobuf::Value::kListValue) {
                    for (const auto& pv : params_it->second.list_value().values()) {
                        if (pv.kind_case() != google::protobuf::Value::kStructValue) continue;
                        auto pname_it = pv.struct_value().fields().find("name");
                        auto pthis_it = pv.struct_value().fields().find("is_this");
                        if (pname_it != pv.struct_value().fields().end() &&
                            pthis_it != pv.struct_value().fields().end() &&
                            pthis_it->second.bool_value()) {
                            const auto& pname = pname_it->second.string_value();
                            if (scope->has(pname)) {
                                obj[pname] = scope->lookup(pname);
                            }
                        }
                    }
                }

                // Invoke super constructor if present in initializers
                if (init_it != func.metadata().fields().end() &&
                    init_it->second.kind_case() == google::protobuf::Value::kListValue) {
                    for (const auto& iv : init_it->second.list_value().values()) {
                        if (iv.kind_case() != google::protobuf::Value::kStructValue) continue;
                        auto kind_it2 = iv.struct_value().fields().find("kind");
                        if (kind_it2 == iv.struct_value().fields().end() ||
                            kind_it2->second.string_value() != "super") continue;
                        auto args_it = iv.struct_value().fields().find("args");
                        if (args_it == iv.struct_value().fields().end()) continue;
                        auto args_str = args_it->second.string_value();
                        // Strip parens: "(type, hp)" -> "type, hp"
                        if (!args_str.empty() && args_str.front() == '(') args_str = args_str.substr(1);
                        if (!args_str.empty() && args_str.back() == ')') args_str.pop_back();
                        // Parse args and resolve from scope
                        std::vector<BallValue> super_args;
                        std::istringstream ss(args_str);
                        std::string arg;
                        while (std::getline(ss, arg, ',')) {
                            arg.erase(0, arg.find_first_not_of(" \t"));
                            arg.erase(arg.find_last_not_of(" \t") + 1);
                            if (arg.empty()) continue;
                            // Try as variable reference
                            if (scope->has(arg)) {
                                super_args.push_back(scope->lookup(arg));
                            } else if (arg.front() == '\'' && arg.back() == '\'') {
                                super_args.push_back(arg.substr(1, arg.size()-2));
                            } else {
                                try { super_args.push_back(static_cast<int64_t>(std::stoll(arg))); }
                                catch (...) { super_args.push_back(arg); }
                            }
                        }
                        // Find and call super constructor
                        std::string sc_name;
                        for (const auto& mod3 : program_.modules()) {
                            for (const auto& td3 : mod3.type_defs()) {
                                bool m3 = (td3.name() == class_name);
                                if (!m3) { auto c=td3.name().find(':'); if(c!=std::string::npos && td3.name().substr(c+1)==class_name) m3=true; }
                                if (!m3) { auto c=class_name.find(':'); if(c!=std::string::npos && class_name.substr(c+1)==td3.name()) m3=true; }
                                if (!m3) continue;
                                if (td3.has_metadata()) {
                                    auto sc_it2 = td3.metadata().fields().find("superclass");
                                    if (sc_it2 != td3.metadata().fields().end())
                                        sc_name = sc_it2->second.string_value();
                                }
                                break;
                            }
                            if (!sc_name.empty()) break;
                        }
                        if (!sc_name.empty()) {
                            // Build super object by calling super constructor
                            BallMap super_input;
                            for (size_t i = 0; i < super_args.size(); i++) {
                                super_input["arg" + std::to_string(i)] = super_args[i];
                            }
                            // Try all possible constructor key forms
                            std::vector<std::string> ctor_keys = {
                                sc_name, sc_name + ".new",
                                current_module_ + ":" + sc_name,
                                current_module_ + ":" + sc_name + ".new",
                            };
                            bool found_ctor = false;
                            for (const auto& key : ctor_keys) {
                                auto ctor_it = constructors_.find(key);
                                if (ctor_it != constructors_.end()) {
                                    auto super_obj = call_function_internal(ctor_it->second.module, *ctor_it->second.func, BallValue(super_input));
                                    if (is_map(super_obj)) {
                                        obj["__super__"] = super_obj;
                                        const auto& sm = std::any_cast<const BallMap&>(super_obj);
                                        for (const auto& [k, v] : sm) {
                                            if (k != "__type__" && k != "__super__" && obj.find(k) == obj.end())
                                                obj[k] = v;
                                        }
                                    }
                                    found_ctor = true;
                                    break;
                                }
                            }
                            {
                                // Always ensure super object has args mapped to param names
                                BallMap super_obj;
                                super_obj["__type__"] = sc_name;
                                // Find super constructor params to map positional args
                                for (const auto& mod4 : program_.modules()) {
                                    for (const auto& fn4 : mod4.functions()) {
                                        bool match = false;
                                        for (const auto& key : ctor_keys) {
                                            if (fn4.name() == key) { match = true; break; }
                                        }
                                        if (!match) continue;
                                        auto sp = extract_params(fn4.metadata());
                                        for (size_t i = 0; i < sp.size() && i < super_args.size(); i++) {
                                            super_obj[sp[i]] = super_args[i];
                                        }
                                        break;
                                    }
                                }
                                obj["__super__"] = BallValue(super_obj);
                                for (const auto& [k, v] : super_obj) {
                                    if (k != "__type__" && k != "__super__" && obj.find(k) == obj.end())
                                        obj[k] = v;
                                }
                            }
                        }
                        break;
                    }
                }

                // DEBUG after super invocation
                if (func.name().find("Vehicle") != std::string::npos || func.name().find("Motor") != std::string::npos || func.name().find("Car") != std::string::npos) {
                    std::cerr << "[CTOR-POST] " << func.name() << " obj keys:";
                    for (const auto& [k,v] : obj) std::cerr << " " << k;
                    std::cerr << "\n";
                    if (obj.find("__super__") != obj.end() && is_map(obj["__super__"])) {
                        const auto& sm = std::any_cast<const BallMap&>(obj["__super__"]);
                        std::cerr << "[CTOR-POST]   __super__ keys:";
                        for (const auto& [k,v] : sm) std::cerr << " " << k;
                        std::cerr << "\n";
                    }
                }
                // Build __super__ chain for classes without explicit super() call
                if (obj.find("__super__") == obj.end()) {
                    std::string cur_type = class_name;
                    BallMap* super_target = &obj;
                    for (int depth = 0; depth < 20; ++depth) {
                        std::string sc_name;
                        for (const auto& mod3 : program_.modules()) {
                            for (const auto& td3 : mod3.type_defs()) {
                                bool m3 = (td3.name() == cur_type);
                                if (!m3) { auto c=td3.name().find(':'); if(c!=std::string::npos && td3.name().substr(c+1)==cur_type) m3=true; }
                                if (!m3) { auto c=cur_type.find(':'); if(c!=std::string::npos && cur_type.substr(c+1)==td3.name()) m3=true; }
                                if (!m3) continue;
                                if (td3.has_metadata()) {
                                    auto sc_it = td3.metadata().fields().find("superclass");
                                    if (sc_it != td3.metadata().fields().end() && !sc_it->second.string_value().empty())
                                        sc_name = sc_it->second.string_value();
                                }
                                break;
                            }
                            if (!sc_name.empty()) break;
                        }
                        if (sc_name.empty()) break;
                        BallMap super_fields;
                        super_fields["__type__"] = sc_name;
                        for (auto& [k, v] : obj) {
                            if (k != "__type__" && k != "__super__") super_fields[k] = v;
                        }
                        (*super_target)["__super__"] = BallValue(super_fields);
                        super_target = &std::any_cast<BallMap&>((*super_target)["__super__"]);
                        cur_type = sc_name;
                    }
                }

                return BallValue(obj);
            }
        }
        return {};
    }

    auto prev_module = current_module_;
    current_module_ = module_name;
    auto scope = std::make_shared<Scope>(global_scope_);

    std::string fkey = module_name + "." + func.name();
    auto pit = param_cache_.find(fkey);
    std::vector<std::string> params;
    if (pit != param_cache_.end()) {
        params = pit->second;
    } else if (func.has_metadata()) {
        params = extract_params(func.metadata());
    }

    if (!params.empty()) {
        if (params.size() == 1) {
            // For instance methods (input has 'self'), bind param to arg0 not whole map.
            if (is_map(input)) {
                const auto& m = std::any_cast<const BallMap&>(input);
                // DEBUG: log input map keys for delayedAdd
                if (func.name() == "delayedAdd") {
                    std::cerr << "[DEBUG] delayedAdd input map keys:";
                    for (const auto& [k,v] : m) std::cerr << " " << k;
                    std::cerr << std::endl;
                }
                auto self_chk = m.find("self");
                if (self_chk != m.end()) {
                    auto a0 = m.find("arg0");
                    if (a0 != m.end()) {
                        scope->bind(params[0], a0->second);
                    } else {
                        auto named = m.find(params[0]);
                        if (named != m.end()) {
                            scope->bind(params[0], named->second);
                        } else {
                            scope->bind(params[0], input);
                        }
                    }
                } else {
                    // No self: check named param or arg0 first, then whole input
                    auto named = m.find(params[0]);
                    if (func.name() == "delayedAdd") {
                        std::cerr << "[DEBUG] delayedAdd: looking for param '" << params[0] << "' in map" << std::endl;
                        std::cerr << "[DEBUG] delayedAdd: named found = " << (named != m.end()) << std::endl;
                    }
                    if (named != m.end()) {
                        scope->bind(params[0], named->second);
                    } else {
                        auto a0 = m.find("arg0");
                        if (func.name() == "delayedAdd") {
                            std::cerr << "[DEBUG] delayedAdd: looking for 'arg0' in map" << std::endl;
                            std::cerr << "[DEBUG] delayedAdd: a0 found = " << (a0 != m.end()) << std::endl;
                            if (a0 != m.end()) {
                                std::cerr << "[DEBUG] delayedAdd: a0->second type = " << a0->second.type().name() << std::endl;
                            }
                        }
                        if (a0 != m.end()) {
                            scope->bind(params[0], a0->second);
                        } else {
                            scope->bind(params[0], input);
                        }
                    }
                }
            } else {
                scope->bind(params[0], input);
            }
        } else if (is_map(input)) {
            const auto& m = std::any_cast<const BallMap&>(input);
            for (size_t i = 0; i < params.size(); ++i) {
                auto fit = m.find(params[i]);
                if (fit != m.end()) {
                    scope->bind(params[i], fit->second);
                } else {
                    auto afit = m.find("arg" + std::to_string(i));
                    if (afit != m.end()) scope->bind(params[i], afit->second);
                }
            }
        } else if (is_list(input)) {
            const auto& lst = std::any_cast<const BallList&>(input);
            for (size_t i = 0; i < params.size() && i < lst.size(); ++i) {
                scope->bind(params[i], lst[i]);
            }
        }
    }

    if (!func.input_type().empty() && input.has_value()) {
        // Only bind "input" when it won't shadow a top-level variable
        // of the same name. Functions with named params don't need the
        // raw "input" binding — their params are bound separately.
        if (!global_scope_->has("input") || params.empty()) {
            scope->bind("input", input);
        }
    }

    // Bind 'self' for instance method calls so `this` references resolve.
    if (is_map(input)) {
        const auto& inp_map = std::any_cast<const BallMap&>(input);
        auto self_it = inp_map.find("self");
        if (self_it != inp_map.end()) {
            scope->bind("self", self_it->second);
            // Only unpack fields and bind 'this'/'super' for class instance methods.
            if (is_map(self_it->second)) {
                const auto& self_map = std::any_cast<const BallMap&>(self_it->second);
                auto type_it2 = self_map.find("__type__");
                // DEBUG: log field binding for describe
                if (func.name().find("describe") != std::string::npos) {
                    std::cerr << "[DEBUG] " << func.name() << " self keys:";
                    for (const auto& [k,v] : self_map) std::cerr << " " << k;
                    std::cerr << "\n";
                    // Walk __super__ chain
                    BallValue sw = self_it->second;
                    int depth = 0;
                    while (is_map(sw)) {
                        const auto& sm2 = std::any_cast<const BallMap&>(sw);
                        auto sp = sm2.find("__super__");
                        if (sp == sm2.end()) break;
                        if (is_map(sp->second)) {
                            const auto& sup = std::any_cast<const BallMap&>(sp->second);
                            std::cerr << "[DEBUG]   __super__[" << depth << "] keys:";
                            for (const auto& [k,v] : sup) std::cerr << " " << k;
                            std::cerr << "\n";
                        }
                        sw = sp->second;
                        depth++;
                    }
                }
                if (type_it2 != self_map.end() && is_string(type_it2->second)) {
                    scope->bind("this", self_it->second);
                    // Bind ALL fields from self and its entire __super__ chain
                    // Use bind (not set) so fields are available as local variables
                    std::function<void(const BallMap&)> bind_all_fields;
                    bind_all_fields = [&](const BallMap& m) {
                        for (const auto& [k, v] : m) {
                            if (k == "__type__" || k == "__super__" || k == "__methods__" || k == "__type_args__") continue;
                            if (!scope->has(k)) scope->bind(k, v);
                        }
                        auto sit = m.find("__super__");
                        if (sit != m.end() && is_map(sit->second)) {
                            bind_all_fields(std::any_cast<const BallMap&>(sit->second));
                        }
                    };
                    bind_all_fields(self_map);
                    auto super_it2 = self_map.find("__super__");
                    if (super_it2 != self_map.end()) scope->bind("super", super_it2->second);
                }
            }
        }
    }

    // Set up reference writeback info for list/map parameters so that mutations
    // inside the function propagate back to the caller's scope.
    auto ref_info = std::move(pending_ref_info_);
    pending_ref_info_.reset();
    // Build a map from param name -> caller variable name
    std::unordered_map<std::string, std::pair<std::string, std::shared_ptr<Scope>>> param_refs;
    if (ref_info) {
        for (size_t i = 0; i < params.size(); ++i) {
            // Check named field match
            auto named_it = ref_info->field_to_var.find(params[i]);
            if (named_it != ref_info->field_to_var.end()) {
                param_refs[params[i]] = {named_it->second, ref_info->caller_scope};
                continue;
            }
            // Check argN match
            auto arg_it = ref_info->field_to_var.find("arg" + std::to_string(i));
            if (arg_it != ref_info->field_to_var.end()) {
                param_refs[params[i]] = {arg_it->second, ref_info->caller_scope};
            }
        }
    }

    // Capture the self variable name for write-back after method execution
    std::string self_var_name;
    std::shared_ptr<Scope> self_caller_scope;
    if (ref_info && is_map(input)) {
        auto sit = ref_info->field_to_var.find("self");
        if (sit != ref_info->field_to_var.end()) {
            self_var_name = sit->second;
            self_caller_scope = ref_info->caller_scope;
        }
    }

    auto result = eval_expr(func.body(), scope);
    current_module_ = prev_module;
    // DEBUG: trace function result
    if (func.name() == "delayedAdd") {
        std::cerr << "[DEBUG] delayedAdd result type: " << (result.has_value() ? result.type().name() : "empty") << std::endl;
        if (result.has_value() && result.type() == typeid(int64_t)) {
            std::cerr << "[DEBUG] delayedAdd result value: " << std::any_cast<int64_t>(result) << std::endl;
        } else if (result.has_value() && result.type() == typeid(BallFuture)) {
            std::cerr << "[DEBUG] delayedAdd result is BallFuture" << std::endl;
        } else if (!result.has_value()) {
            std::cerr << "[DEBUG] delayedAdd result is null/empty" << std::endl;
        }
        // Check if 'input' is bound in scope
        if (scope->has("input")) {
            auto input_val = scope->lookup("input");
            std::cerr << "[DEBUG] delayedAdd input in scope: type=" << (input_val.has_value() ? input_val.type().name() : "empty") << std::endl;
            if (input_val.has_value() && input_val.type() == typeid(int64_t)) {
                std::cerr << "[DEBUG] delayedAdd input value: " << std::any_cast<int64_t>(input_val) << std::endl;
            }
        } else {
            std::cerr << "[DEBUG] delayedAdd input NOT in scope" << std::endl;
        }
    }
    if (is_flow(result) && as_flow(result).kind == "return") {
        result = as_flow(result).value;
    }

    // Write back list/map parameters that were modified during execution.
    for (const auto& [param_name, ref_pair] : param_refs) {
        if (scope->has(param_name) && ref_pair.second) {
            auto new_val = scope->lookup(param_name);
            if (is_list(new_val) || is_map(new_val)) {
                ref_pair.second->set(ref_pair.first, new_val);
            }
        }
    }

    // Write back modified self fields for instance methods.
    // This emulates pass-by-reference for object mutations in methods.
    if (!self_var_name.empty() && self_caller_scope && scope->has("self")) {
        auto self_val = scope->lookup("self");
        if (is_map(self_val)) {
            auto self_map = std::any_cast<BallMap>(self_val);
            // Write back any fields that were modified in the method's scope
            for (auto& [k, v] : self_map) {
                if (k == "__type__" || k == "__super__" || k == "__methods__" || k == "__type_args__") continue;
                if (scope->has(k)) {
                    auto new_val = scope->lookup(k);
                    self_map[k] = new_val;
                }
            }
            self_caller_scope->set(self_var_name, BallValue(self_map));
        }
    }

    // Check for async/generator metadata.
    // Dart uses is_async, is_generator, is_sync_star, is_async_star.
    // C++ mirrors all four to match Dart semantics.
    bool is_async_fn = false;
    bool is_generator_fn = false;
    if (func.has_metadata()) {
        auto ait = func.metadata().fields().find("is_async");
        if (ait != func.metadata().fields().end()) is_async_fn = ait->second.bool_value();
        auto git = func.metadata().fields().find("is_generator");
        if (git != func.metadata().fields().end()) is_generator_fn = git->second.bool_value();
        // Also check is_sync_star / is_async_star (Dart encoder metadata keys).
        auto sst = func.metadata().fields().find("is_sync_star");
        if (sst != func.metadata().fields().end() && sst->second.bool_value())
            is_generator_fn = true;
        auto ast = func.metadata().fields().find("is_async_star");
        if (ast != func.metadata().fields().end() && ast->second.bool_value()) {
            is_generator_fn = true;
            is_async_fn = true;  // async* is both async and generator
        }
    }

    // Wrap async returns in BallFuture (synchronous simulation).
    if (is_async_fn && !is_future(result)) {
        result = BallFuture{result, true};
    }

    // Unwrap BallFuture for synchronous consumers.
    // In the C++ engine there is no real concurrency, so every BallFuture
    // is already completed and can be unwrapped immediately.
    if (is_future(result)) {
        result = std::any_cast<const BallFuture&>(result).value;
    }

    // Generator functions: collect yielded values as a list.
    if (is_generator_fn) {
        if (is_generator(result)) {
            result = BallList{std::move(std::any_cast<BallGenerator>(result).values)};
        } else if (!is_list(result)) {
            result = BallList{result};
        }
    }

    return result;
}

BallValue Engine::resolve_and_call(const std::string& module,
                                   const std::string& function,
                                   BallValue input) {
    std::string mod_name = module.empty() ? current_module_ : module;
    std::string key = mod_name + "." + function;
    auto it = functions_.find(key);
    if (it != functions_.end()) {
        return call_function_internal(mod_name, *it->second, std::move(input));
    }
    // Method dispatch: if input has self with __type__, try ClassName.method
    if (is_map(input)) {
        const auto& inp = std::any_cast<const BallMap&>(input);
        auto si = inp.find("self");
        if (si != inp.end() && is_map(si->second)) {
            const auto& sm = std::any_cast<const BallMap&>(si->second);
            // Walk type chain (self + __super__) to find method
            BallValue cur = si->second;
            while (is_map(cur)) {
                const auto& cm = std::any_cast<const BallMap&>(cur);
                auto ti = cm.find("__type__");
                if (ti != cm.end() && is_string(ti->second)) {
                    auto type_name = std::any_cast<std::string>(ti->second);
                    std::string mkey = mod_name + "." + type_name + "." + function;
                    auto mit = functions_.find(mkey);
                    if (mit != functions_.end())
                        return call_function_internal(mod_name, *mit->second, std::move(input));
                    // Try without module prefix on type
                    auto colon = type_name.find(':');
                    if (colon != std::string::npos) {
                        mkey = mod_name + "." + type_name.substr(colon+1) + "." + function;
                        mit = functions_.find(mkey);
                        if (mit != functions_.end())
                            return call_function_internal(mod_name, *mit->second, std::move(input));
                    }
                }
                auto sup = cm.find("__super__");
                cur = (sup != cm.end()) ? sup->second : BallValue{};
            }
        }
    }
    for (const auto& m : program_.modules()) {
        for (const auto& f : m.functions()) {
            if (f.name() == function) {
                return call_function_internal(m.name(), f, std::move(input));
            }
        }
    }
    // Constructor fallback: try "function.new" (default constructor name).
    std::string ctor_key = mod_name + "." + function + ".new";
    auto cit = functions_.find(ctor_key);
    if (cit != functions_.end()) {
        return call_function_internal(mod_name, *cit->second, std::move(input));
    }
    // Also check the constructor registry by bare name.
    auto ctor_entry = constructors_.find(function);
    if (ctor_entry != constructors_.end()) {
        return call_function_internal(
            ctor_entry->second.module, *ctor_entry->second.func, std::move(input));
    }
    // Fall through to base function handlers for known base modules
    for (auto& handler : handlers_) {
        if (handler->handles(mod_name)) {
            return call_base_function(mod_name, function, std::move(input));
        }
    }
    if (mod_name == "std_memory") {
        return call_base_function(mod_name, function, std::move(input));
    }
    if (mod_name == "std_convert" || mod_name == "std_time" || mod_name == "std_fs") {
        return call_base_function(mod_name, function, std::move(input));
    }
    // Last resort: try std handlers (e.g. for `identical` called without module).
    for (auto& handler : handlers_) {
        if (handler->handles("std")) {
            try {
                return handler->call(function, std::move(input),
                    [this](const std::string& m, const std::string& f, BallValue i) {
                        return call_function(m, f, std::move(i));
                    });
            } catch (...) {}
            break;
        }
    }
    throw BallRuntimeError("Function \"" + key + "\" not found");
}

BallValue Engine::call_base_function(const std::string& module,
                                     const std::string& function,
                                     BallValue input) {
    // Check for operator overrides on class instances before std dispatch.
    // Mirrors Dart's _callBaseFunction.
    if ((module == "std" || module == "dart_std") &&
        std_function_to_operator().count(function)) {
        auto override = try_operator_override(function, input);
        if (override.has_value()) return *override;
    }

    if (module == "std_memory") {
        BallMap args;
        if (is_map(input)) args = std::any_cast<BallMap>(input);
        return eval_memory(function, args);
    }
    if (module == "std_convert") {
        return eval_convert(function, std::move(input));
    }
    if (module == "std_fs") {
        return eval_fs(function, std::move(input));
    }
    if (module == "std_time") {
        return eval_time(function, std::move(input));
    }
    // Some encoders/programs call std_time helpers (year/month/now/etc.)
    // through the generic std module. Route those names here so the
    // dispatch table doesn't have to duplicate every handler — keeps the
    // Dart engine's flat std namespace working in C++ too.
    if ((module == "std" || module == "dart_std")) {
        static const std::set<std::string> time_fns = {
            "now", "now_micros", "format_timestamp", "parse_timestamp",
            "duration_add", "duration_subtract",
            "year", "month", "day", "hour", "minute", "second",
        };
        if (time_fns.count(function)) {
            return eval_time(function, std::move(input));
        }
        static const std::set<std::string> convert_fns = {
            "json_encode", "json_decode", "utf8_encode", "utf8_decode",
            "base64_encode", "base64_decode",
        };
        if (convert_fns.count(function)) {
            return eval_convert(function, std::move(input));
        }
    }
    for (auto& handler : handlers_) {
        if (handler->handles(module)) {
            BallCallable callable = [this](const std::string& m, const std::string& f, BallValue i) {
                return call_function(m, f, std::move(i));
            };
            return handler->call(function, std::move(input), callable);
        }
    }
    throw BallRuntimeError("Unknown base module: \"" + module + "\"");
}

// ================================================================
// Expression evaluation
// ================================================================

BallValue Engine::eval_expr(const ball::v1::Expression& expr, std::shared_ptr<Scope> scope) {
    if (max_steps_ > 0 && ++steps_ > max_steps_) {
        throw std::runtime_error("Execution exceeded " + std::to_string(max_steps_) + " steps (possible infinite loop)");
    }
    switch (expr.expr_case()) {
        case ball::v1::Expression::kCall:
            return eval_call(expr.call(), scope);
        case ball::v1::Expression::kLiteral:
            return eval_literal(expr.literal(), scope);
        case ball::v1::Expression::kReference:
            return eval_reference(expr.reference(), scope);
        case ball::v1::Expression::kFieldAccess:
            return eval_field_access(expr.field_access(), scope);
        case ball::v1::Expression::kMessageCreation:
            return eval_message_creation(expr.message_creation(), scope);
        case ball::v1::Expression::kBlock:
            return eval_block(expr.block(), scope);
        case ball::v1::Expression::kLambda:
            return eval_lambda(expr.lambda(), scope);
        default:
            return {};
    }
}

BallValue Engine::eval_call(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    std::string mod = call.module().empty() ? current_module_ : call.module();
    const auto& fn = call.function();

    if (mod == "std" || mod == "dart_std") {
        if (fn == "if") return eval_lazy_if(call, scope);
        if (fn == "for") return eval_lazy_for(call, scope);
        if (fn == "for_in") return eval_lazy_for_in(call, scope);
        if (fn == "while") return eval_lazy_while(call, scope);
        if (fn == "do_while") return eval_lazy_do_while(call, scope);
        if (fn == "switch") return eval_lazy_switch(call, scope);
        if (fn == "try") return eval_lazy_try(call, scope);
        if (fn == "cascade" || fn == "null_aware_cascade") return eval_lazy_cascade(call, scope);
        if (fn == "and") return eval_short_circuit_and(call, scope);
        if (fn == "or") return eval_short_circuit_or(call, scope);
        if (fn == "return") return eval_return(call, scope);
        if (fn == "break") return eval_break(call, scope);
        if (fn == "continue") return eval_continue(call, scope);
        if (fn == "assign") return eval_assign(call, scope);
        if (fn == "labeled") return eval_labeled(call, scope);
        if (fn == "goto") return eval_goto(call, scope);
        if (fn == "label") return eval_label(call, scope);
        if (fn == "pre_increment" || fn == "post_increment" ||
            fn == "pre_decrement" || fn == "post_decrement") {
            return eval_inc_dec(call, scope);
        }
    }

    // list_pop/list_remove_last in-place mutation: pop element and write back.
    if ((mod == "std" || mod == "dart_std" || mod == "std_collections") &&
        (fn == "list_pop" || fn == "list_remove_last") &&
        call.has_input() &&
        call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
        for (const auto& f : call.input().message_creation().fields()) {
            if (f.name() == "list" &&
                f.value().expr_case() == ball::v1::Expression::kReference) {
                const auto& var_name = f.value().reference().name();
                if (scope->has(var_name)) {
                    auto val = scope->lookup(var_name);
                    if (is_list(val)) {
                        auto lst = std::any_cast<BallList>(val);
                        if (!lst.empty()) {
                            auto removed = lst.back();
                            lst.pop_back();
                            scope->set(var_name, BallValue(lst));
                            return removed;
                        }
                    }
                }
            }
        }
    }

    // list_push/list_add in-place mutation: when the "list" argument comes from
    // an index expression (e.g. list_push(list=index(groups, key), value=n)),
    // we need to push to the list and write back to the indexed container.
    if ((mod == "std" || mod == "dart_std" || mod == "std_collections") &&
        (fn == "list_push" || fn == "list_add") &&
        call.has_input() &&
        call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
        const ball::v1::Expression* list_expr = nullptr;
        const ball::v1::Expression* value_expr = nullptr;
        for (const auto& f : call.input().message_creation().fields()) {
            if (f.name() == "list") list_expr = &f.value();
            else if (f.name() == "value") value_expr = &f.value();
        }
        if (list_expr && value_expr) {
            // Check if list comes from index(target, idx) or null_check(index(...))
            const ball::v1::Expression* index_expr = nullptr;
            if (list_expr->expr_case() == ball::v1::Expression::kCall &&
                list_expr->call().function() == "index") {
                index_expr = list_expr;
            } else if (list_expr->expr_case() == ball::v1::Expression::kCall &&
                       list_expr->call().function() == "null_check" &&
                       list_expr->call().has_input()) {
                // Unwrap null_check(index(...))
                const auto& nc_input = list_expr->call().input();
                if (nc_input.expr_case() == ball::v1::Expression::kMessageCreation) {
                    for (const auto& nf : nc_input.message_creation().fields()) {
                        if (nf.name() == "value" &&
                            nf.value().expr_case() == ball::v1::Expression::kCall &&
                            nf.value().call().function() == "index") {
                            index_expr = &nf.value();
                            break;
                        }
                    }
                }
            }
            if (index_expr) {
                auto idx_fields_map = lazy_fields(index_expr->call());
                auto idx_target_it = idx_fields_map.find("target");
                auto idx_index_it = idx_fields_map.find("index");
                if (idx_target_it != idx_fields_map.end() && idx_index_it != idx_fields_map.end() &&
                    idx_target_it->second.expr_case() == ball::v1::Expression::kReference) {
                    const auto& container_name = idx_target_it->second.reference().name();
                    auto idx_val = eval_expr(idx_index_it->second, scope);
                    auto push_val = eval_expr(*value_expr, scope);
                    auto container = scope->lookup(container_name);
                    if (is_map(container)) {
                        auto& m = std::any_cast<BallMap&>(container);
                        auto key = ball::to_string(idx_val);
                        BallList lst;
                        auto it = m.find(key);
                        if (it != m.end() && is_list(it->second)) {
                            lst = std::any_cast<BallList>(it->second);
                        }
                        lst.push_back(push_val);
                        m[key] = BallValue(lst);
                        scope->set(container_name, container);
                        return BallValue(lst);
                    }
                    if (is_list(container)) {
                        auto& lst_outer = std::any_cast<BallList&>(container);
                        auto i = to_int(idx_val);
                        if (i >= 0 && static_cast<size_t>(i) < lst_outer.size() && is_list(lst_outer[i])) {
                            auto inner = std::any_cast<BallList>(lst_outer[i]);
                            inner.push_back(push_val);
                            lst_outer[i] = BallValue(inner);
                            scope->set(container_name, container);
                            return BallValue(inner);
                        }
                    }
                }
            }
        }
    }

    // map_create: special handling for repeated "entry" fields that get lost in
    // BallMap. We read from the raw proto to collect all entries properly.
    if ((mod == "std" || mod == "dart_std" || mod == "std_collections") && fn == "map_create") {
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            BallMap result;
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == "entry") {
                    auto entry_val = eval_expr(f.value(), scope);
                    if (is_map(entry_val)) {
                        const auto& entry = std::any_cast<const BallMap&>(entry_val);
                        auto key_it = entry.find("key");
                        auto val_it = entry.find("value");
                        if (key_it != entry.end() && val_it != entry.end()) {
                            result[ball::to_string(key_it->second)] = val_it->second;
                        }
                    }
                } else if (f.name() == "entries") {
                    auto entries_val = eval_expr(f.value(), scope);
                    if (is_list(entries_val)) {
                        const auto& entries = std::any_cast<const BallList&>(entries_val);
                        for (const auto& e : entries) {
                            if (is_map(e)) {
                                const auto& entry = std::any_cast<const BallMap&>(e);
                                auto key_it = entry.find("name");
                                auto val_it = entry.find("value");
                                if (key_it != entry.end() && val_it != entry.end()) {
                                    result[ball::to_string(key_it->second)] = val_it->second;
                                }
                            }
                        }
                    }
                }
            }
            return result;
        }
        // Fallthrough for non-message-creation inputs
    }

    // list_slice: handle repeated "value" fields that collapse in BallMap.
    // Read positional "value" fields as arg0 (start) and arg1 (end).
    if ((mod == "std" || mod == "dart_std" || mod == "std_collections") && fn == "list_slice") {
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            BallValue list_val;
            BallValue start_val;
            BallValue end_val;
            int value_idx = 0;
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.name() == "list") {
                    list_val = eval_expr(f.value(), scope);
                } else if (f.name() == "start") {
                    start_val = eval_expr(f.value(), scope);
                } else if (f.name() == "end") {
                    end_val = eval_expr(f.value(), scope);
                } else if (f.name() == "value" || f.name() == "arg0" || f.name() == "arg1") {
                    auto v = eval_expr(f.value(), scope);
                    if (value_idx == 0) start_val = v;
                    else end_val = v;
                    ++value_idx;
                }
            }
            if (!is_list(list_val)) return BallList{};
            auto list = std::any_cast<BallList>(list_val);
            int64_t start = start_val.has_value() ? to_int(start_val) : 0;
            int64_t end = end_val.has_value() ? to_int(end_val) : static_cast<int64_t>(list.size());
            if (start < 0) start = 0;
            if (end > static_cast<int64_t>(list.size())) end = static_cast<int64_t>(list.size());
            if (start > end) return BallList{};
            return BallList(list.begin() + start, list.begin() + end);
        }
    }

    // cpp_scope_exit: register cleanup lazily without evaluating the expression.
    if (mod == "cpp_std" && fn == "cpp_scope_exit") {
        return eval_cpp_scope_exit(call, scope);
    }

    // Check if function name refers to a local variable holding a lambda/closure
    if (call.module().empty()) {
        try {
            auto callable = scope->lookup(call.function());
            if (callable.has_value()) {
                try {
                    auto fn_val = std::any_cast<BallFunction>(callable);
                    BallValue input = call.has_input() ? eval_expr(call.input(), scope) : BallValue{};
                    return fn_val(std::move(input));
                } catch (const std::bad_any_cast&) {
                    // Not a function — fall through
                }
            }
        } catch (const BallRuntimeError&) {
            // Not a local variable — fall through to resolve_and_call
        }
    }

    BallValue input = call.has_input() ? eval_expr(call.input(), scope) : BallValue{};

    // Helper to set up ref info for method calls on objects
    auto setup_method_ref_info = [&]() {
        pending_ref_info_.reset();
        if (call.has_input() &&
            call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
            PendingRefInfo info;
            info.caller_scope = scope;
            bool has_refs = false;
            for (const auto& f : call.input().message_creation().fields()) {
                if (f.value().expr_case() == ball::v1::Expression::kReference) {
                    const auto& ref_name = f.value().reference().name();
                    if (scope->has(ref_name)) {
                        auto val = scope->lookup(ref_name);
                        if (is_list(val) || is_map(val)) {
                            info.field_to_var[f.name()] = ref_name;
                            has_refs = true;
                        }
                    }
                }
            }
            if (has_refs) pending_ref_info_ = std::move(info);
        }
    };

    // Method call on object (has 'self' field) — instance method dispatch.
    if (is_map(input)) {
        const auto& inp_map = std::any_cast<const BallMap&>(input);
        auto self_it = inp_map.find("self");
        if (self_it != inp_map.end() && is_map(self_it->second)) {
            const auto& self = std::any_cast<const BallMap&>(self_it->second);
            auto type_it = self.find("__type__");
            if (type_it != self.end() && is_string(type_it->second)) {
                const auto& type_name = std::any_cast<const std::string&>(type_it->second);
                // typeName is e.g. "main:Foo". Module part = text before ':'.
                auto colon_idx = type_name.find(':');
                std::string mod_part = (colon_idx != std::string::npos)
                    ? type_name.substr(0, colon_idx)
                    : current_module_;
                // Try ClassName.methodName in functions_ (key: "module.typeName.method")
                std::string method_key = mod_part + "." + type_name + "." + call.function();
                auto fit = functions_.find(method_key);
                if (fit == functions_.end() && colon_idx == std::string::npos) {
                    method_key = mod_part + "." + mod_part + ":" + type_name + "." + call.function();
                    fit = functions_.find(method_key);
                }
                if (fit != functions_.end()) {
                    setup_method_ref_info();
                    return call_function_internal(mod_part, *fit->second, std::move(input));
                }
                // Walk superclass chain.
                auto super_it = self.find("__super__");
                BallValue super_obj = (super_it != self.end()) ? super_it->second : BallValue{};
                while (is_map(super_obj)) {
                    const auto& sm = std::any_cast<const BallMap&>(super_obj);
                    auto st = sm.find("__type__");
                    if (st != sm.end() && is_string(st->second)) {
                        const auto& super_type = std::any_cast<const std::string&>(st->second);
                        auto s_colon = super_type.find(':');
                        std::string s_mod = (s_colon != std::string::npos)
                            ? super_type.substr(0, s_colon) : mod_part;
                        std::string s_type = (s_colon != std::string::npos)
                            ? super_type : (s_mod + ":" + super_type);
                        std::string super_key = s_mod + "." + s_type + "." + call.function();
                        auto sfit = functions_.find(super_key);
                        if (sfit == functions_.end() && s_colon == std::string::npos) {
                            super_key = s_mod + "." + s_mod + ":" + super_type + "." + call.function();
                            sfit = functions_.find(super_key);
                        }
                        if (sfit != functions_.end()) {
                            setup_method_ref_info();
                            return call_function_internal(s_mod, *sfit->second, std::move(input));
                        }
                    }
                    auto ss = sm.find("__super__");
                    super_obj = (ss != sm.end()) ? ss->second : BallValue{};
                }
                // Walk mixins: check TypeDef metadata for mixin list.
                for (const auto& mod_iter : program_.modules()) {
                    for (const auto& td : mod_iter.type_defs()) {
                        bool type_matches = (td.name() == type_name);
                        if (!type_matches) {
                            auto c = td.name().find(':');
                            if (c != std::string::npos && td.name().substr(c+1) == type_name) type_matches = true;
                            auto c2 = type_name.find(':');
                            if (c2 != std::string::npos && type_name.substr(c2+1) == td.name()) type_matches = true;
                        }
                        if (!type_matches) continue;
                        if (!td.has_metadata()) continue;
                        auto mixins_it = td.metadata().fields().find("mixins");
                        if (mixins_it == td.metadata().fields().end() ||
                            mixins_it->second.kind_case() != google::protobuf::Value::kListValue) continue;
                        for (const auto& mv : mixins_it->second.list_value().values()) {
                            if (mv.kind_case() != google::protobuf::Value::kStringValue) continue;
                            const auto& mixin_name = mv.string_value();
                            // Try qualified and unqualified mixin names
                            std::string mixin_key = mod_part + "." + mod_part + ":" + mixin_name + "." + call.function();
                            auto mfit = functions_.find(mixin_key);
                            if (mfit == functions_.end()) {
                                mixin_key = mod_part + "." + mixin_name + "." + call.function();
                                mfit = functions_.find(mixin_key);
                            }
                            if (mfit != functions_.end()) {
                                setup_method_ref_info();
                                return call_function_internal(mod_part, *mfit->second, std::move(input));
                            }
                        }
                        break;
                    }
                }
            }
            // StringBuffer method handling on typed objects
            if (is_string(type_it->second)) {
                const auto& type_str = std::any_cast<const std::string&>(type_it->second);
                bool is_string_buffer = type_str.find("StringBuffer") != std::string::npos;
                if (is_string_buffer) {
                    auto self_copy = std::any_cast<BallMap>(self_it->second);
                    auto buf_it = self_copy.find("_buffer");
                    std::string buf = (buf_it != self_copy.end() && is_string(buf_it->second))
                        ? std::any_cast<std::string>(buf_it->second) : "";
                    const auto& method = call.function();

                    // Find the variable name for write-back
                    std::string self_var;
                    if (call.has_input() &&
                        call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                        for (const auto& f2 : call.input().message_creation().fields()) {
                            if (f2.name() == "self" && f2.value().expr_case() == ball::v1::Expression::kReference) {
                                self_var = f2.value().reference().name();
                                break;
                            }
                        }
                    }
                    auto sb_writeback = [&](const std::string& new_buf) {
                        self_copy["_buffer"] = new_buf;
                        if (!self_var.empty() && scope->has(self_var))
                            scope->set(self_var, BallValue(self_copy));
                    };

                    if (method == "write") {
                        buf += ball::to_string(extract_field(input, "arg0"));
                        sb_writeback(buf);
                        return {};
                    }
                    if (method == "writeCharCode") {
                        buf += std::string(1, static_cast<char>(to_int(extract_field(input, "arg0"))));
                        sb_writeback(buf);
                        return {};
                    }
                    if (method == "writeln") {
                        buf += ball::to_string(extract_field(input, "arg0")) + "\n";
                        sb_writeback(buf);
                        return {};
                    }
                    if (method == "toString") {
                        return buf;
                    }
                    if (method == "clear") {
                        sb_writeback("");
                        return {};
                    }
                }
            }
            // Fall through to normal resolution if no method found on the type.
        }
        // Static method dispatch: self is a string (class name)
        if (self_it != inp_map.end() && is_string(self_it->second)) {
            const auto& cn = std::any_cast<const std::string&>(self_it->second);
            std::string mk = current_module_ + "." + current_module_ + ":" + cn + "." + call.function();
            auto fit2 = functions_.find(mk);
            if (fit2 == functions_.end()) { mk = current_module_ + "." + cn + "." + call.function(); fit2 = functions_.find(mk); }
            if (fit2 != functions_.end()) { setup_method_ref_info(); return call_function_internal(current_module_, *fit2->second, std::move(input)); }
        }
        // User-defined class instance method dispatch: walk type chain
        if (self_it != inp_map.end() && is_map(self_it->second)) {
            BallValue cur_obj = self_it->second;
            while (is_map(cur_obj)) {
                const auto& cm = std::any_cast<const BallMap&>(cur_obj);
                auto ti = cm.find("__type__");
                if (ti != cm.end() && is_string(ti->second)) {
                    auto tn = std::any_cast<std::string>(ti->second);
                    // Try multiple key formats
                    for (const auto& mk : {
                        current_module_ + "." + tn + "." + call.function(),
                        current_module_ + "." + call.function(),
                        tn + "." + call.function(),
                    }) {
                        auto mit = functions_.find(mk);
                        if (mit != functions_.end()) {
                            return call_function_internal(current_module_, *mit->second, std::move(input));
                        }
                    }
                }
                auto sup = cm.find("__super__");
                cur_obj = (sup != cm.end()) ? sup->second : BallValue{};
            }
        }
    }

    // Built-in method dispatch for primitive types (list, string, int, double, map).
    // When a call has no module and input has a "self" field with a primitive type,
    // dispatch as a built-in method. Mutating methods (add, removeLast, etc.) write
    // the result back to the scope variable that 'self' came from.
    if (call.module().empty() && is_map(input)) {
        const auto& inp_map = std::any_cast<const BallMap&>(input);
        auto self_it = inp_map.find("self");
        if (self_it != inp_map.end()) {
            const auto& self_val = self_it->second;
            const auto& fn_name = call.function();

            // Helper: find the variable name for 'self' from the input expression tree.
            std::string self_var_name;
            if (call.has_input() &&
                call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : call.input().message_creation().fields()) {
                    if (f.name() == "self" &&
                        f.value().expr_case() == ball::v1::Expression::kReference) {
                        self_var_name = f.value().reference().name();
                        break;
                    }
                }
            }

            // Lambda to write back a mutated value to the scope variable.
            auto write_back = [&](BallValue new_val) {
                if (!self_var_name.empty() && scope->has(self_var_name)) {
                    scope->set(self_var_name, new_val);
                }
            };

            // ── List methods ──
            if (is_list(self_val)) {
                auto lst = std::any_cast<BallList>(self_val);
                if (fn_name == "add") {
                    auto arg = extract_field(input, "arg0");
                    lst.push_back(arg);
                    write_back(BallValue(lst));
                    return {};
                }
                if (fn_name == "removeLast") {
                    if (lst.empty()) throw BallRuntimeError("removeLast on empty list");
                    auto last = lst.back();
                    lst.pop_back();
                    write_back(BallValue(lst));
                    return last;
                }
                if (fn_name == "removeAt") {
                    auto idx = to_int(extract_field(input, "arg0"));
                    if (idx < 0 || static_cast<size_t>(idx) >= lst.size())
                        throw BallRuntimeError("removeAt: index out of range");
                    auto removed = lst[idx];
                    lst.erase(lst.begin() + idx);
                    write_back(BallValue(lst));
                    return removed;
                }
                if (fn_name == "insert") {
                    auto idx = to_int(extract_field(input, "arg0"));
                    auto val = extract_field(input, "arg1");
                    lst.insert(lst.begin() + idx, val);
                    write_back(BallValue(lst));
                    return {};
                }
                if (fn_name == "clear") {
                    lst.clear();
                    write_back(BallValue(lst));
                    return {};
                }
                if (fn_name == "contains") {
                    auto val = extract_field(input, "arg0");
                    for (const auto& item : lst) {
                        if (values_equal(item, val)) return true;
                    }
                    return false;
                }
                if (fn_name == "indexOf") {
                    auto val = extract_field(input, "arg0");
                    for (size_t i = 0; i < lst.size(); ++i) {
                        if (values_equal(lst[i], val)) return static_cast<int64_t>(i);
                    }
                    return static_cast<int64_t>(-1);
                }
                if (fn_name == "join") {
                    auto sep = ball::to_string(extract_field(input, "arg0"));
                    std::string result;
                    for (size_t i = 0; i < lst.size(); ++i) {
                        if (i > 0) result += sep;
                        result += ball::to_string(lst[i]);
                    }
                    return result;
                }
                if (fn_name == "sublist") {
                    auto start = to_int(extract_field(input, "arg0"));
                    auto end_field = extract_field(input, "arg1");
                    int64_t end = end_field.has_value() ? to_int(end_field) : static_cast<int64_t>(lst.size());
                    BallList sub(lst.begin() + start, lst.begin() + end);
                    return sub;
                }
                if (fn_name == "sort") {
                    std::sort(lst.begin(), lst.end(), [](const BallValue& a, const BallValue& b) {
                        if (is_int(a) && is_int(b)) return to_int(a) < to_int(b);
                        if (is_double(a) || is_double(b)) return to_double(a) < to_double(b);
                        if (is_string(a) && is_string(b))
                            return std::any_cast<const std::string&>(a) < std::any_cast<const std::string&>(b);
                        return false;
                    });
                    write_back(BallValue(lst));
                    return {};
                }
                if (fn_name == "map") {
                    auto fn_val = extract_field(input, "arg0");
                    if (!is_function(fn_val)) throw BallRuntimeError("list.map: arg is not a function");
                    auto& callback = std::any_cast<BallFunction&>(fn_val);
                    BallList result;
                    for (const auto& item : lst) result.push_back(callback(item));
                    return result;
                }
                if (fn_name == "where") {
                    auto fn_val = extract_field(input, "arg0");
                    if (!is_function(fn_val)) throw BallRuntimeError("list.where: arg is not a function");
                    auto& callback = std::any_cast<BallFunction&>(fn_val);
                    BallList result;
                    for (const auto& item : lst) {
                        if (to_bool(callback(item))) result.push_back(item);
                    }
                    return result;
                }
                if (fn_name == "forEach") {
                    auto fn_val = extract_field(input, "arg0");
                    if (!is_function(fn_val)) throw BallRuntimeError("list.forEach: arg is not a function");
                    auto& callback = std::any_cast<BallFunction&>(fn_val);
                    for (const auto& item : lst) callback(item);
                    return {};
                }
                if (fn_name == "any") {
                    auto fn_val = extract_field(input, "arg0");
                    if (!is_function(fn_val)) throw BallRuntimeError("list.any: arg is not a function");
                    auto& callback = std::any_cast<BallFunction&>(fn_val);
                    for (const auto& item : lst) {
                        if (to_bool(callback(item))) return true;
                    }
                    return false;
                }
                if (fn_name == "every") {
                    auto fn_val = extract_field(input, "arg0");
                    if (!is_function(fn_val)) throw BallRuntimeError("list.every: arg is not a function");
                    auto& callback = std::any_cast<BallFunction&>(fn_val);
                    for (const auto& item : lst) {
                        if (!to_bool(callback(item))) return false;
                    }
                    return true;
                }
                if (fn_name == "reduce") {
                    auto fn_val = extract_field(input, "arg0");
                    if (!is_function(fn_val)) throw BallRuntimeError("list.reduce: arg is not a function");
                    auto& callback = std::any_cast<BallFunction&>(fn_val);
                    if (lst.empty()) throw BallRuntimeError("list.reduce: empty list");
                    BallValue acc = lst[0];
                    for (size_t i = 1; i < lst.size(); ++i) {
                        BallMap args;
                        args["arg0"] = acc;
                        args["arg1"] = lst[i];
                        acc = callback(BallValue(args));
                    }
                    return acc;
                }
                if (fn_name == "toList") {
                    return self_val; // already a list
                }
                if (fn_name == "toSet") {
                    // Deduplicate
                    BallList result;
                    for (const auto& item : lst) {
                        bool found = false;
                        for (const auto& r : result) {
                            if (values_equal(item, r)) { found = true; break; }
                        }
                        if (!found) result.push_back(item);
                    }
                    return result;
                }
                // Set operations as methods on list-backed sets
                if (fn_name == "union") {
                    auto other = extract_field(input, "arg0");
                    if (is_list(other)) {
                        BallList result = lst;
                        for (const auto& item : std::any_cast<const BallList&>(other)) {
                            bool found = false;
                            for (const auto& r : result) {
                                if (values_equal(item, r)) { found = true; break; }
                            }
                            if (!found) result.push_back(item);
                        }
                        return result;
                    }
                    return self_val;
                }
                if (fn_name == "intersection") {
                    auto other = extract_field(input, "arg0");
                    if (is_list(other)) {
                        const auto& other_lst = std::any_cast<const BallList&>(other);
                        BallList result;
                        for (const auto& item : lst) {
                            for (const auto& r : other_lst) {
                                if (values_equal(item, r)) { result.push_back(item); break; }
                            }
                        }
                        return result;
                    }
                    return BallList{};
                }
                if (fn_name == "difference") {
                    auto other = extract_field(input, "arg0");
                    if (is_list(other)) {
                        const auto& other_lst = std::any_cast<const BallList&>(other);
                        BallList result;
                        for (const auto& item : lst) {
                            bool found = false;
                            for (const auto& r : other_lst) {
                                if (values_equal(item, r)) { found = true; break; }
                            }
                            if (!found) result.push_back(item);
                        }
                        return result;
                    }
                    return self_val;
                }
                // 'filled' is a static constructor: List.filled(n, value)
                if (fn_name == "filled") {
                    auto n = to_int(extract_field(input, "arg0"));
                    auto fill_val = extract_field(input, "arg1");
                    BallList filled(n, fill_val);
                    return filled;
                }
            }

            // ── Map methods ──
            if (is_map(self_val)) {
                auto m = std::any_cast<BallMap>(self_val);
                // Skip typed objects (they have __type__ and use class dispatch above)
                auto type_it = m.find("__type__");
                if (type_it == m.end() || !is_string(type_it->second)) {
                    if (fn_name == "containsKey") {
                        auto key = ball::to_string(extract_field(input, "arg0"));
                        return m.find(key) != m.end();
                    }
                    if (fn_name == "containsValue") {
                        auto val = extract_field(input, "arg0");
                        for (const auto& [k, v] : m) {
                            if (values_equal(v, val)) return true;
                        }
                        return false;
                    }
                    if (fn_name == "remove") {
                        auto key = ball::to_string(extract_field(input, "arg0"));
                        auto it = m.find(key);
                        BallValue removed;
                        if (it != m.end()) {
                            removed = it->second;
                            m.erase(it);
                        }
                        write_back(BallValue(m));
                        return removed;
                    }
                    if (fn_name == "putIfAbsent") {
                        auto key = ball::to_string(extract_field(input, "arg0"));
                        auto val = extract_field(input, "arg1");
                        auto it = m.find(key);
                        if (it == m.end()) {
                            m[key] = val;
                            write_back(BallValue(m));
                            return val;
                        }
                        return it->second;
                    }
                }
            }

            // ── String methods ──
            if (is_string(self_val)) {
                const auto& s = std::any_cast<const std::string&>(self_val);
                if (fn_name == "contains") {
                    auto sub = ball::to_string(extract_field(input, "arg0"));
                    return s.find(sub) != std::string::npos;
                }
                if (fn_name == "substring") {
                    auto start = to_int(extract_field(input, "arg0"));
                    auto end_field = extract_field(input, "arg1");
                    size_t end = end_field.has_value() ? static_cast<size_t>(to_int(end_field)) : s.size();
                    return s.substr(start, end - start);
                }
                if (fn_name == "indexOf") {
                    auto sub = ball::to_string(extract_field(input, "arg0"));
                    auto pos = s.find(sub);
                    return pos != std::string::npos ? static_cast<int64_t>(pos) : static_cast<int64_t>(-1);
                }
                if (fn_name == "split") {
                    auto sep = ball::to_string(extract_field(input, "arg0"));
                    BallList result;
                    if (sep.empty()) {
                        for (char c : s) result.push_back(std::string(1, c));
                    } else {
                        size_t start = 0, found;
                        while ((found = s.find(sep, start)) != std::string::npos) {
                            result.push_back(s.substr(start, found - start));
                            start = found + sep.size();
                        }
                        result.push_back(s.substr(start));
                    }
                    return result;
                }
                if (fn_name == "trim") {
                    auto first = s.find_first_not_of(" \t\n\r");
                    if (first == std::string::npos) return std::string();
                    return s.substr(first, s.find_last_not_of(" \t\n\r") - first + 1);
                }
                if (fn_name == "toUpperCase") {
                    std::string r = s;
                    std::transform(r.begin(), r.end(), r.begin(), ::toupper);
                    return r;
                }
                if (fn_name == "toLowerCase") {
                    std::string r = s;
                    std::transform(r.begin(), r.end(), r.begin(), ::tolower);
                    return r;
                }
                if (fn_name == "replaceAll") {
                    auto from = ball::to_string(extract_field(input, "arg0"));
                    auto to = ball::to_string(extract_field(input, "arg1"));
                    std::string result = s;
                    size_t pos = 0;
                    while ((pos = result.find(from, pos)) != std::string::npos) {
                        result.replace(pos, from.size(), to);
                        pos += to.size();
                    }
                    return result;
                }
                if (fn_name == "startsWith") {
                    auto prefix = ball::to_string(extract_field(input, "arg0"));
                    return s.size() >= prefix.size() && s.substr(0, prefix.size()) == prefix;
                }
                if (fn_name == "endsWith") {
                    auto suffix = ball::to_string(extract_field(input, "arg0"));
                    return s.size() >= suffix.size() && s.substr(s.size() - suffix.size()) == suffix;
                }
                if (fn_name == "padLeft") {
                    auto width = to_int(extract_field(input, "arg0"));
                    auto pad_field = extract_field(input, "arg1");
                    std::string pad = pad_field.has_value() ? ball::to_string(pad_field) : " ";
                    std::string result = s;
                    while (static_cast<int64_t>(result.size()) < width) result = pad + result;
                    return result;
                }
                if (fn_name == "padRight") {
                    auto width = to_int(extract_field(input, "arg0"));
                    auto pad_field = extract_field(input, "arg1");
                    std::string pad = pad_field.has_value() ? ball::to_string(pad_field) : " ";
                    std::string result = s;
                    while (static_cast<int64_t>(result.size()) < width) result = result + pad;
                    return result;
                }
                if (fn_name == "toString") return s;
                if (fn_name == "codeUnitAt") {
                    auto idx = to_int(extract_field(input, "arg0"));
                    if (idx >= 0 && idx < static_cast<int64_t>(s.size()))
                        return static_cast<int64_t>(static_cast<unsigned char>(s[idx]));
                    return BallValue{};
                }
                // StringBuffer methods
                if (fn_name == "write") {
                    auto arg = ball::to_string(extract_field(input, "arg0"));
                    auto result = s + arg;
                    write_back(BallValue(result));
                    return {};
                }
                if (fn_name == "writeCharCode") {
                    auto code = to_int(extract_field(input, "arg0"));
                    auto result = s + std::string(1, static_cast<char>(code));
                    write_back(BallValue(result));
                    return {};
                }
            }

            // ── Number methods ──
            if (is_int(self_val)) {
                int64_t n = std::any_cast<int64_t>(self_val);
                if (fn_name == "toDouble") return static_cast<double>(n);
                if (fn_name == "toInt") return n;
                if (fn_name == "toString") return std::to_string(n);
                if (fn_name == "abs") return static_cast<int64_t>(std::abs(n));
                if (fn_name == "round") return n;
                if (fn_name == "floor") return n;
                if (fn_name == "ceil") return n;
                if (fn_name == "compareTo") {
                    auto other = to_int(extract_field(input, "arg0"));
                    return static_cast<int64_t>(n < other ? -1 : (n > other ? 1 : 0));
                }
                if (fn_name == "clamp") {
                    auto lo = to_int(extract_field(input, "arg0"));
                    auto hi = to_int(extract_field(input, "arg1"));
                    return std::max(lo, std::min(n, hi));
                }
            }
            if (is_double(self_val)) {
                double d = std::any_cast<double>(self_val);
                if (fn_name == "toDouble") return d;
                if (fn_name == "toInt") return static_cast<int64_t>(d);
                if (fn_name == "toString") return ball_to_string(d);
                if (fn_name == "abs") return std::abs(d);
                if (fn_name == "round") return static_cast<int64_t>(std::round(d));
                if (fn_name == "floor") return static_cast<int64_t>(std::floor(d));
                if (fn_name == "ceil") return static_cast<int64_t>(std::ceil(d));
                if (fn_name == "compareTo") {
                    auto other = to_double(extract_field(input, "arg0"));
                    return static_cast<int64_t>(d < other ? -1 : (d > other ? 1 : 0));
                }
                if (fn_name == "clamp") {
                    auto lo = to_double(extract_field(input, "arg0"));
                    auto hi = to_double(extract_field(input, "arg1"));
                    return std::max(lo, std::min(d, hi));
                }
                if (fn_name == "truncate") return static_cast<int64_t>(d);
            }

            if (is_string(self_val)) {
                const auto& ss = std::any_cast<const std::string&>(self_val);
                if (ss == "List") {
                    if (fn_name == "filled") { auto n = to_int(extract_field(input, "arg0")); return BallList(n, extract_field(input, "arg1")); }
                    if (fn_name == "of" || fn_name == "from") {
                        auto src = extract_field(input, "arg0");
                        if (is_list(src)) return std::any_cast<BallList>(src); // copy
                        return BallList{};
                    }
                    if (fn_name == "generate") {
                        auto n = to_int(extract_field(input, "arg0")); auto gf = extract_field(input, "arg1");
                        if (is_function(gf)) { auto& cb = std::any_cast<BallFunction&>(gf); BallList r; for (int64_t i=0;i<n;++i) r.push_back(cb(BallValue(i))); return r; }
                        return BallList{};
                    }
                }
                if (ss == "Map" && fn_name == "fromEntries") {
                    auto ev = extract_field(input, "arg0");
                    if (is_list(ev)) {
                        BallMap r;
                        for (const auto& e : std::any_cast<const BallList&>(ev)) {
                            if (is_map(e)) {
                                const auto& em = std::any_cast<const BallMap&>(e);
                                // Try key/value, then arg0/arg1, then name/value
                                auto ki = em.find("key");
                                if (ki == em.end()) ki = em.find("arg0");
                                if (ki == em.end()) ki = em.find("name");
                                auto vi = em.find("value");
                                if (vi == em.end()) vi = em.find("arg1");
                                if (ki != em.end() && vi != em.end())
                                    r[ball::to_string(ki->second)] = vi->second;
                            }
                        }
                        return r;
                    }
                }
            }
        }
    }

    // Set up reference info for list/map arguments so mutations inside the
    // called function propagate back to the caller's scope variables.
    pending_ref_info_.reset();
    if (call.has_input() &&
        call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
        PendingRefInfo info;
        info.caller_scope = scope;
        bool has_refs = false;
        for (const auto& f : call.input().message_creation().fields()) {
            if (f.value().expr_case() == ball::v1::Expression::kReference) {
                const auto& ref_name = f.value().reference().name();
                if (scope->has(ref_name)) {
                    auto val = scope->lookup(ref_name);
                    if (is_list(val) || is_map(val)) {
                        info.field_to_var[f.name()] = ref_name;
                        has_refs = true;
                    }
                }
            }
        }
        if (has_refs) pending_ref_info_ = std::move(info);
    }

    return resolve_and_call(call.module(), call.function(), std::move(input));
}

BallValue Engine::eval_literal(const ball::v1::Literal& lit, std::shared_ptr<Scope> scope) {
    switch (lit.value_case()) {
        case ball::v1::Literal::kIntValue:
            return static_cast<int64_t>(lit.int_value());
        case ball::v1::Literal::kDoubleValue:
            return lit.double_value();
        case ball::v1::Literal::kStringValue:
            return lit.string_value();
        case ball::v1::Literal::kBoolValue:
            return lit.bool_value();
        case ball::v1::Literal::kBytesValue: {
            auto bytes = lit.bytes_value();
            return std::vector<uint8_t>(bytes.begin(), bytes.end());
        }
        case ball::v1::Literal::kListValue: {
            BallList list;
            for (const auto& el : lit.list_value().elements())
                list.push_back(eval_expr(el, scope));
            return list;
        }
        default:
            return {};
    }
}

BallValue Engine::eval_reference(const ball::v1::Reference& ref, std::shared_ptr<Scope> scope) {
    const auto& name = ref.name();
    if (scope->has(name)) return scope->lookup(name);

    // Constructor tear-off: resolve class names and "Class.new" references
    // to callable closures that invoke the constructor function.
    auto ctor_it = constructors_.find(name);
    if (ctor_it != constructors_.end()) {
        auto entry = ctor_it->second;
        BallFunction closure = [this, entry](BallValue input) -> BallValue {
            return call_function_internal(entry.module, *entry.func, std::move(input));
        };
        return closure;
    }

    // Try stripping module prefix (e.g. "main:Foo" -> "Foo").
    auto colon_idx = name.find(':');
    if (colon_idx != std::string::npos) {
        std::string bare = name.substr(colon_idx + 1);
        auto bare_it = constructors_.find(bare);
        if (bare_it != constructors_.end()) {
            auto entry = bare_it->second;
            BallFunction closure = [this, entry](BallValue input) -> BallValue {
                return call_function_internal(entry.module, *entry.func, std::move(input));
            };
            return closure;
        }
    }

    // Enum type reference: resolve to the enum's value map so that
    // field access (MyEnum.value1) works.
    auto enum_it = enum_values_.find(name);
    if (enum_it != enum_values_.end()) {
        return enum_it->second;
    }

    // Built-in type names as values (for static method dispatch like List.filled).
    if (name == "List" || name == "Map" || name == "String" || name == "int" || name == "double") {
        return std::string(name);
    }

    // Check if the name is a class/type defined in typeDefs.
    for (const auto& mod : program_.modules()) {
        for (const auto& td : mod.type_defs()) {
            if (td.name() == name || td.name() == current_module_ + ":" + name) return std::string(name);
            auto c2 = td.name().find(':');
            if (c2 != std::string::npos && td.name().substr(c2+1) == name) return std::string(name);
        }
    }

    // Function tear-off: resolve function names as closures.
    std::string func_key = current_module_ + "." + name;
    auto func_it = functions_.find(func_key);
    if (func_it != functions_.end()) {
        std::string mod = current_module_;
        const ball::v1::FunctionDefinition* fdef = func_it->second;
        BallFunction closure = [this, mod, fdef](BallValue input) -> BallValue {
            return call_function_internal(mod, *fdef, std::move(input));
        };
        return closure;
    }
    // Also try unqualified search across all modules
    for (const auto& mod : program_.modules()) {
        std::string fk = mod.name() + "." + name;
        auto fit = functions_.find(fk);
        if (fit != functions_.end()) {
            std::string mod_name = mod.name();
            const ball::v1::FunctionDefinition* fdef = fit->second;
            BallFunction closure = [this, mod_name, fdef](BallValue input) -> BallValue {
                return call_function_internal(mod_name, *fdef, std::move(input));
            };
            return closure;
        }
    }

    // Try getter dispatch or direct field access on self/this (for accessing
    // properties in methods). This handles both getter functions and plain fields.
    if (scope->has("self") || scope->has("this")) {
        auto self_val = scope->has("self") ? scope->lookup("self") : scope->lookup("this");
        if (is_map(self_val)) {
            const auto& self_map = std::any_cast<const BallMap&>(self_val);
            // Try getter dispatch first
            auto getter_result = try_getter_dispatch(self_map, name);
            if (getter_result.has_value()) return *getter_result;
            // Try direct field access on self
            auto field_it = self_map.find(name);
            if (field_it != self_map.end()) return field_it->second;
            // Walk __super__ chain for inherited fields
            auto super_it = self_map.find("__super__");
            BallValue super_obj = (super_it != self_map.end()) ? super_it->second : BallValue{};
            while (is_map(super_obj)) {
                const auto& sm = std::any_cast<const BallMap&>(super_obj);
                auto sf = sm.find(name);
                if (sf != sm.end()) return sf->second;
                auto ss = sm.find("__super__");
                super_obj = (ss != sm.end()) ? ss->second : BallValue{};
            }
        }
    }

    // Try global scope for top-level variables
    if (global_scope_->has(name)) return global_scope_->lookup(name);

    // Fall back to scope lookup (will throw with the normal error message).
    return scope->lookup(name);
}

BallValue Engine::eval_field_access(const ball::v1::FieldAccess& access, std::shared_ptr<Scope> scope) {
    auto object = eval_expr(access.object(), scope);
    const auto& field = access.field();

    // Unwrap BallFuture/BallGenerator for field access (synchronous simulation).
    object = unwrap(object);

    if (is_map(object)) {
        const auto& m = std::any_cast<const BallMap&>(object);
        auto it = m.find(field);
        if (it != m.end()) return it->second;

        // Walk __super__ chain for inherited fields.
        auto super_it = m.find("__super__");
        if (super_it != m.end() && is_map(super_it->second)) {
            BallValue cur = super_it->second;
            while (is_map(cur)) {
                const auto& sm = std::any_cast<const BallMap&>(cur);
                auto sit = sm.find(field);
                if (sit != sm.end()) return sit->second;
                auto next = sm.find("__super__");
                if (next == sm.end()) break;
                cur = next->second;
            }
        }

        // Look up __methods__ on the object.
        auto meth_it = m.find("__methods__");
        if (meth_it != m.end() && is_map(meth_it->second)) {
            const auto& methods = std::any_cast<const BallMap&>(meth_it->second);
            auto mit = methods.find(field);
            if (mit != methods.end()) return mit->second;
        }

        // Walk __super__ chain for methods.
        if (super_it != m.end() && is_map(super_it->second)) {
            BallValue cur = super_it->second;
            while (is_map(cur)) {
                const auto& sm = std::any_cast<const BallMap&>(cur);
                auto sm_meth = sm.find("__methods__");
                if (sm_meth != sm.end() && is_map(sm_meth->second)) {
                    const auto& smethods = std::any_cast<const BallMap&>(sm_meth->second);
                    auto smit = smethods.find(field);
                    if (smit != smethods.end()) return smit->second;
                }
                auto next = sm.find("__super__");
                if (next == sm.end()) break;
                cur = next->second;
            }
        }

        if (field == "length") return static_cast<int64_t>(m.size());
        if (field == "isEmpty") return m.empty();
        if (field == "isNotEmpty") return !m.empty();
        if (field == "keys") {
            BallList keys;
            for (const auto& [k, _] : m) keys.push_back(k);
            return keys;
        }
        if (field == "values") {
            BallList vals;
            for (const auto& [_, v] : m) vals.push_back(v);
            // Sort enum values by index if this looks like an enum map
            bool is_enum = !vals.empty();
            for (const auto& v : vals) {
                if (!is_map(v)) { is_enum = false; break; }
                const auto& vm = std::any_cast<const BallMap&>(v);
                if (vm.find("index") == vm.end()) { is_enum = false; break; }
            }
            if (is_enum) {
                std::sort(vals.begin(), vals.end(), [](const BallValue& a, const BallValue& b) {
                    const auto& am = std::any_cast<const BallMap&>(a);
                    const auto& bm = std::any_cast<const BallMap&>(b);
                    return to_int(am.find("index")->second) < to_int(bm.find("index")->second);
                });
            }
            return vals;
        }
        // Getter dispatch: if the field isn't a data field, check for a
        // getter function on the object's type (metadata is_getter: true).
        auto getter_result = try_getter_dispatch(m, field);
        if (getter_result.has_value()) return *getter_result;

        // For typed objects, try mapping named fields to positional args:
        // "message" -> arg0 (exception types), or general field-to-arg fallback
        auto type_it_fa = m.find("__type__");
        if (type_it_fa != m.end()) {
            if (field == "message") {
                auto a0 = m.find("arg0");
                if (a0 != m.end()) return a0->second;
            }
            // Return null for unknown fields on typed objects rather than throwing
            return BallValue{};
        }
        throw BallRuntimeError("Field \"" + field + "\" not found in map");
    }
    if (is_string(object)) {
        const auto& s = std::any_cast<const std::string&>(object);
        if (field == "length") return static_cast<int64_t>(s.size());
        if (field == "isEmpty") return s.empty();
        if (field == "isNotEmpty") return !s.empty();
    }
    if (is_list(object)) {
        const auto& lst = std::any_cast<const BallList&>(object);
        if (field == "length") return static_cast<int64_t>(lst.size());
        if (field == "isEmpty") return lst.empty();
        if (field == "isNotEmpty") return !lst.empty();
        if (field == "first" && !lst.empty()) return lst.front();
        if (field == "last" && !lst.empty()) return lst.back();
        if (field == "reversed") { BallList rev(lst.rbegin(), lst.rend()); return rev; }
    }
    if (is_double(object)) {
        double d = std::any_cast<double>(object);
        if (field == "isNaN") return std::isnan(d);
        if (field == "isFinite") return std::isfinite(d);
        if (field == "isInfinite") return std::isinf(d);
        if (field == "isNegative") return d < 0.0;
        if (field == "abs") return std::abs(d);
    }
    if (is_int(object)) {
        int64_t i = std::any_cast<int64_t>(object);
        if (field == "isNegative") return i < 0;
        if (field == "abs") return static_cast<int64_t>(std::abs(i));
    }
    if (field == "runtimeType") {
        if (is_int(object)) return std::string("int");
        if (is_double(object)) return std::string("double");
        if (is_string(object)) return std::string("String");
        if (is_bool(object)) return std::string("bool");
        if (is_list(object)) return std::string("List");
        if (is_map(object)) return std::string("Map");
        return std::string("Null");
    }
    throw BallRuntimeError("Cannot access field \"" + field + "\"");
}

BallValue Engine::eval_message_creation(const ball::v1::MessageCreation& msg, std::shared_ptr<Scope> scope) {
    BallMap fields;
    for (const auto& pair : msg.fields())
        fields[pair.name()] = unwrap(eval_expr(pair.value(), scope));
    if (!msg.type_name().empty()) {
        std::string type_name = msg.type_name();
        // Check if the type_name is actually a function (e.g., method calls encoded
        // as MessageCreation). If so, call the function instead of creating a message.
        // This handles cases where _gcd() is encoded as messageCreation(typeName: "main:_gcd").
        {
            auto try_as_function = [&](const std::string& key) -> std::optional<BallValue> {
                auto fn_it = functions_.find(key);
                if (fn_it == functions_.end() || !fn_it->second->has_body()) return std::nullopt;
                bool is_ctor = false;
                if (fn_it->second->has_metadata()) {
                    auto kind_it = fn_it->second->metadata().fields().find("kind");
                    if (kind_it != fn_it->second->metadata().fields().end() &&
                        kind_it->second.string_value() == "constructor") is_ctor = true;
                }
                if (is_ctor) return std::nullopt;
                return call_function_internal(current_module_, *fn_it->second, BallValue(fields));
            };
            // Try direct match
            auto result = try_as_function(current_module_ + "." + type_name);
            if (result) return *result;
            // Try searching all functions for a method matching this name
            for (const auto& [fkey, fdef] : functions_) {
                // Check if fkey ends with ".type_name" (e.g., "main.main:Fraction._gcd" for type_name "main:_gcd")
                auto bare_type = type_name;
                auto tc = bare_type.find(':');
                if (tc != std::string::npos) bare_type = bare_type.substr(tc + 1);
                if (fkey.size() > bare_type.size() && fkey.substr(fkey.size() - bare_type.size()) == bare_type &&
                    fkey[fkey.size() - bare_type.size() - 1] == '.') {
                    result = try_as_function(fkey);
                    if (result) return *result;
                }
            }
        }
        // Extract type arguments if generic (e.g., Box<int>).
        {
            auto lt = type_name.find('<');
            if (lt != std::string::npos && type_name.back() == '>') {
                fields["__type_args__"] = type_name.substr(lt + 1, type_name.size() - lt - 2);
                type_name = type_name.substr(0, lt);
            }
        }
        fields["__type__"] = type_name;

        // Initialize fields with defaults from TypeDef metadata.
        for (const auto& mod2 : program_.modules()) {
            for (const auto& td : mod2.type_defs()) {
                if (td.name() != type_name && td.name() != msg.type_name()) continue;
                if (!td.has_metadata()) continue;
                auto flds_it = td.metadata().fields().find("fields");
                if (flds_it == td.metadata().fields().end() ||
                    flds_it->second.kind_case() != google::protobuf::Value::kListValue) continue;
                for (const auto& fv : flds_it->second.list_value().values()) {
                    if (fv.kind_case() != google::protobuf::Value::kStructValue) continue;
                    auto fname_it = fv.struct_value().fields().find("name");
                    if (fname_it == fv.struct_value().fields().end()) continue;
                    const auto& fname = fname_it->second.string_value();
                    if (fields.find(fname) != fields.end()) continue;
                    auto init_it = fv.struct_value().fields().find("initializer");
                    if (init_it != fv.struct_value().fields().end() && !init_it->second.string_value().empty()) {
                        const auto& init_str = init_it->second.string_value();
                        if (init_str == "[]") fields[fname] = BallList{};
                        else if (init_str == "{}") fields[fname] = BallMap{};
                        else if (init_str == "0") fields[fname] = static_cast<int64_t>(0);
                        else if (init_str == "0.0") fields[fname] = 0.0;
                        else if (init_str == "false") fields[fname] = false;
                        else if (init_str == "true") fields[fname] = true;
                        else fields[fname] = BallValue{};
                    }
                }
                break;
            }
        }

        // Look up constructor to map positional args to named fields
        // and handle super constructor initializers.
        auto ctor_it = constructors_.find(type_name);
        if (ctor_it == constructors_.end()) {
            auto colon = type_name.find(':');
            if (colon != std::string::npos)
                ctor_it = constructors_.find(type_name.substr(colon + 1));
        }
        if (ctor_it != constructors_.end() && ctor_it->second.func->has_metadata()) {
            const auto& ctor_func = *ctor_it->second.func;
            // Map positional args to named params
            auto pit = ctor_func.metadata().fields().find("params");
            if (pit != ctor_func.metadata().fields().end() &&
                pit->second.kind_case() == google::protobuf::Value::kListValue) {
                int idx = 0;
                for (const auto& pv : pit->second.list_value().values()) {
                    if (pv.kind_case() != google::protobuf::Value::kStructValue) continue;
                    auto name_it = pv.struct_value().fields().find("name");
                    if (name_it == pv.struct_value().fields().end()) { ++idx; continue; }
                    const std::string& pname = name_it->second.string_value();
                    std::string arg_key = "arg" + std::to_string(idx);
                    auto arg_it = fields.find(arg_key);
                    if (arg_it != fields.end()) {
                        BallValue val = std::move(arg_it->second);
                        fields.erase(arg_it);
                        fields[pname] = std::move(val);
                    }
                    // Handle is_this: map param to field
                    auto pthis_it = pv.struct_value().fields().find("is_this");
                    if (pthis_it != pv.struct_value().fields().end() && pthis_it->second.bool_value()) {
                        if (fields.find(pname) != fields.end()) {
                            // Already set from arg mapping above
                        }
                    }
                    ++idx;
                }
            }
            // Process super constructor initializers
            auto init_it = ctor_func.metadata().fields().find("initializers");
            if (init_it != ctor_func.metadata().fields().end() &&
                init_it->second.kind_case() == google::protobuf::Value::kListValue) {
                for (const auto& iv : init_it->second.list_value().values()) {
                    if (iv.kind_case() != google::protobuf::Value::kStructValue) continue;
                    auto kind_it2 = iv.struct_value().fields().find("kind");
                    if (kind_it2 == iv.struct_value().fields().end() ||
                        kind_it2->second.string_value() != "super") continue;
                    auto args_it = iv.struct_value().fields().find("args");
                    if (args_it == iv.struct_value().fields().end()) continue;
                    auto args_str = args_it->second.string_value();
                    if (!args_str.empty() && args_str.front() == '(') args_str = args_str.substr(1);
                    if (!args_str.empty() && args_str.back() == ')') args_str.pop_back();
                    // Parse and resolve super args
                    std::vector<BallValue> super_args;
                    std::istringstream ss(args_str);
                    std::string arg;
                    while (std::getline(ss, arg, ',')) {
                        arg.erase(0, arg.find_first_not_of(" \t"));
                        arg.erase(arg.find_last_not_of(" \t") + 1);
                        if (arg.empty()) continue;
                        if (fields.find(arg) != fields.end()) {
                            super_args.push_back(fields[arg]);
                        } else if (arg.front() == '\'' && arg.back() == '\'') {
                            super_args.push_back(arg.substr(1, arg.size()-2));
                        } else {
                            try { super_args.push_back(static_cast<int64_t>(std::stoll(arg))); }
                            catch (...) { super_args.push_back(arg); }
                        }
                    }
                    // Find superclass name
                    std::string sc_name;
                    for (const auto& mod3 : program_.modules()) {
                        for (const auto& td3 : mod3.type_defs()) {
                            bool m3 = (td3.name() == type_name);
                            if (!m3) { auto c=td3.name().find(':'); if(c!=std::string::npos && td3.name().substr(c+1)==type_name) m3=true; }
                            if (!m3) { auto c=type_name.find(':'); if(c!=std::string::npos && type_name.substr(c+1)==td3.name()) m3=true; }
                            if (!m3) continue;
                            if (td3.has_metadata()) {
                                auto sc_it2 = td3.metadata().fields().find("superclass");
                                if (sc_it2 != td3.metadata().fields().end())
                                    sc_name = sc_it2->second.string_value();
                            }
                            break;
                        }
                        if (!sc_name.empty()) break;
                    }
                    if (!sc_name.empty()) {
                        // Build super object via constructor
                        BallMap super_input;
                        for (size_t i = 0; i < super_args.size(); i++) {
                            super_input["arg" + std::to_string(i)] = super_args[i];
                        }
                        // Find and call super constructor
                        std::vector<std::string> ctor_keys = {
                            sc_name, sc_name + ".new",
                            current_module_ + ":" + sc_name,
                            current_module_ + ":" + sc_name + ".new",
                        };
                        bool found_super = false;
                        for (const auto& key : ctor_keys) {
                            auto sc_ctor = constructors_.find(key);
                            if (sc_ctor != constructors_.end()) {
                                auto super_obj = call_function_internal(
                                    sc_ctor->second.module, *sc_ctor->second.func, BallValue(super_input));
                                if (is_map(super_obj)) {
                                    fields["__super__"] = super_obj;
                                    const auto& sm = std::any_cast<const BallMap&>(super_obj);
                                    for (const auto& [k, v] : sm) {
                                        if (k != "__type__" && k != "__super__" && fields.find(k) == fields.end())
                                            fields[k] = v;
                                    }
                                }
                                found_super = true;
                                break;
                            }
                        }
                    }
                    break;
                }
            }
        }

        // Check for superclass via type definitions. Build __super__ chain
        // iteratively for multi-level inheritance (fallback).
        {
            std::string cur_type = type_name;
            BallMap* super_target = &fields;
            for (int depth = 0; depth < 20; ++depth) {
                std::string sc_name;
                for (const auto& mod3 : program_.modules()) {
                    for (const auto& td3 : mod3.type_defs()) {
                        bool m3 = (td3.name() == cur_type);
                        if (!m3) { auto c=td3.name().find(':'); if(c!=std::string::npos && td3.name().substr(c+1)==cur_type) m3=true; }
                        if (!m3) { auto c=cur_type.find(':'); if(c!=std::string::npos && cur_type.substr(c+1)==td3.name()) m3=true; }
                        if (!m3) continue;
                        if (td3.has_metadata()) {
                            auto sc_it = td3.metadata().fields().find("superclass");
                            if (sc_it != td3.metadata().fields().end() && !sc_it->second.string_value().empty())
                                sc_name = sc_it->second.string_value();
                        }
                        break;
                    }
                    if (!sc_name.empty()) break;
                }
                if (sc_name.empty()) break;
                std::string sc_qual = sc_name;
                BallMap super_fields;
                for (const auto& mod4 : program_.modules()) {
                    for (const auto& ptd : mod4.type_defs()) {
                        bool pm = (ptd.name() == sc_name);
                        if (!pm) { auto c2=ptd.name().find(':'); if(c2!=std::string::npos && ptd.name().substr(c2+1)==sc_name) { pm=true; sc_qual=ptd.name(); } }
                        if (!pm) continue;
                        super_fields["__type__"] = sc_qual;
                        if (ptd.has_descriptor_()) {
                            for (const auto& pf : ptd.descriptor_().field()) {
                                auto cit = fields.find(pf.name());
                                if (cit != fields.end()) super_fields[pf.name()] = cit->second;
                            }
                        }
                        break;
                    }
                    if (!super_fields.empty()) break;
                }
                if (super_fields.empty()) super_fields["__type__"] = sc_name;
                (*super_target)["__super__"] = BallValue(super_fields);
                super_target = &std::any_cast<BallMap&>((*super_target)["__super__"]);
                cur_type = sc_qual;
            }
        }
    }
    return fields;
}

BallValue Engine::eval_block(const ball::v1::Block& block, std::shared_ptr<Scope> scope) {
    auto block_scope = std::make_shared<Scope>(scope);
    BallList yields;
    bool has_yields = false;
    for (const auto& stmt : block.statements()) {
        auto result = eval_statement(stmt, block_scope);
        if (is_flow(result)) {
            const auto& sig = as_flow(result);
            if (sig.kind == "yield") {
                has_yields = true;
                yields.push_back(sig.value);
                continue;
            }
            if (sig.kind == "yield_each") {
                has_yields = true;
                if (is_list(sig.value)) {
                    const auto& lst = std::any_cast<const BallList&>(sig.value);
                    yields.insert(yields.end(), lst.begin(), lst.end());
                } else {
                    yields.push_back(sig.value);
                }
                continue;
            }
            // Run scope-exits in LIFO order before propagating the signal.
            run_scope_exits(block_scope);
            return result;
        }
    }
    BallValue result_val;
    if (block.has_result()) {
        result_val = eval_expr(block.result(), block_scope);
        if (has_yields && is_flow(result_val) && as_flow(result_val).kind == "yield") {
            yields.push_back(as_flow(result_val).value);
            run_scope_exits(block_scope);
            return BallGenerator{std::move(yields)};
        }
        if (has_yields) {
            run_scope_exits(block_scope);
            return BallGenerator{std::move(yields)};
        }
    }
    if (has_yields) {
        run_scope_exits(block_scope);
        return BallGenerator{std::move(yields)};
    }
    run_scope_exits(block_scope);
    return result_val;
}

void Engine::run_scope_exits(std::shared_ptr<Scope> block_scope) {
    if (!block_scope->has_scope_exits()) return;
    auto cleanups = block_scope->take_scope_exits();
    for (auto& [expr, eval_scope] : cleanups) {
        try {
            eval_expr(expr, eval_scope);
        } catch (...) {
            // Scope-exit cleanup errors are swallowed (RAII destructor semantics).
        }
    }
}

BallValue Engine::eval_statement(const ball::v1::Statement& stmt, std::shared_ptr<Scope> scope) {
    switch (stmt.stmt_case()) {
        case ball::v1::Statement::kLet: {
            auto value = eval_expr(stmt.let().value(), scope);
            if (is_flow(value)) return value;
            scope->bind(stmt.let().name(), std::move(value));
            return {};
        }
        case ball::v1::Statement::kExpression:
            return eval_expr(stmt.expression(), scope);
        default:
            return {};
    }
}

BallValue Engine::eval_lambda(const ball::v1::FunctionDefinition& func, std::shared_ptr<Scope> scope) {
    auto func_copy = func;
    auto captured = scope;

    // Pre-extract metadata param names so the closure body can bind
    // scalar inputs to the declared param (e.g. a lambda `(x) => x + 1`
    // called with `3` binds `x = 3`). Otherwise only map-style inputs
    // get their keys propagated as bindings.
    std::vector<std::string> param_names;
    if (func.has_metadata()) {
        auto it = func.metadata().fields().find("params");
        if (it != func.metadata().fields().end() &&
            it->second.kind_case() == google::protobuf::Value::kListValue) {
            for (const auto& v : it->second.list_value().values()) {
                if (v.kind_case() != google::protobuf::Value::kStructValue) continue;
                auto nit = v.struct_value().fields().find("name");
                if (nit != v.struct_value().fields().end() &&
                    nit->second.kind_case() == google::protobuf::Value::kStringValue) {
                    param_names.push_back(nit->second.string_value());
                }
            }
        }
    }

    BallFunction closure = [this, func_copy, captured, param_names](BallValue input) -> BallValue {
        auto lambda_scope = std::make_shared<Scope>(captured);
        lambda_scope->bind("input", input);
        // Scalar-to-single-param binding.
        if (param_names.size() == 1 && !is_map(input)) {
            lambda_scope->bind(param_names.front(), input);
        }
        if (is_map(input)) {
            const auto& m = std::any_cast<const BallMap&>(input);
            for (const auto& [k, v] : m)
                if (k != "__type__") lambda_scope->bind(k, v);
            // If param names don't match map keys, map positionally.
            if (!param_names.empty()) {
                bool any_match = false;
                for (const auto& pn : param_names) {
                    if (m.find(pn) != m.end()) { any_match = true; break; }
                }
                if (!any_match) {
                    // Try arg0/arg1
                    bool has_args = false;
                    for (size_t i = 0; i < param_names.size(); ++i) {
                        auto ait = m.find("arg" + std::to_string(i));
                        if (ait != m.end()) { lambda_scope->bind(param_names[i], ait->second); has_args = true; }
                    }
                    // Positional fallback
                    if (!has_args && param_names.size() <= m.size()) {
                        size_t idx = 0;
                        for (const auto& [k, v] : m) {
                            if (k == "__type__") continue;
                            if (idx < param_names.size()) lambda_scope->bind(param_names[idx], v);
                            ++idx;
                        }
                    }
                }
            }
        }
        if (!func_copy.has_body()) return {};
        auto result = eval_expr(func_copy.body(), lambda_scope);
        if (is_flow(result) && as_flow(result).kind == "return")
            return as_flow(result).value;
        return result;
    };
    return closure;
}

// ================================================================
// Lazy control flow
// ================================================================

std::unordered_map<std::string, ball::v1::Expression>
Engine::lazy_fields(const ball::v1::FunctionCall& call) {
    std::unordered_map<std::string, ball::v1::Expression> result;
    if (!call.has_input() ||
        call.input().expr_case() != ball::v1::Expression::kMessageCreation)
        return result;
    for (const auto& f : call.input().message_creation().fields())
        result[f.name()] = f.value();
    return result;
}

std::string Engine::string_field_val(
    const std::unordered_map<std::string, ball::v1::Expression>& fields,
    const std::string& name) {
    auto it = fields.find(name);
    if (it == fields.end()) return "";
    if (it->second.expr_case() == ball::v1::Expression::kLiteral &&
        it->second.literal().value_case() == ball::v1::Literal::kStringValue)
        return it->second.literal().string_value();
    return "";
}

BallValue Engine::eval_init_string_expr(const std::string& expr, std::shared_ptr<Scope> scope) {
    // Evaluate a mini expression from initializer strings.
    // Handles: variable, variable.field, variable[index], expr +/- literal, expr +/- variable

    // Try simple variable first.
    if (scope->has(expr)) return scope->lookup(expr);

    // Try "var[index]" pattern (array indexing).
    {
        auto bracket = expr.find('[');
        if (bracket != std::string::npos && expr.back() == ']') {
            auto var_name = expr.substr(0, bracket);
            auto idx_str = expr.substr(bracket + 1, expr.size() - bracket - 2);
            if (scope->has(var_name)) {
                auto container = scope->lookup(var_name);
                auto idx_val = eval_init_string_expr(idx_str, scope);
                if (is_list(container) && (is_int(idx_val) || is_double(idx_val))) {
                    auto& lst = std::any_cast<const BallList&>(container);
                    auto i = to_int(idx_val);
                    if (i >= 0 && static_cast<size_t>(i) < lst.size()) return lst[i];
                }
                if (is_map(container)) {
                    const auto& m = std::any_cast<const BallMap&>(container);
                    auto key = ball::to_string(idx_val);
                    auto it = m.find(key);
                    if (it != m.end()) return it->second;
                }
            }
        }
    }

    // Try "a.field" pattern.
    static const std::regex dot_pat(R"(^(\w+)\.(\w+)$)");
    std::smatch dot_m;
    if (std::regex_match(expr, dot_m, dot_pat)) {
        const auto& var = dot_m[1].str();
        const auto& field = dot_m[2].str();
        if (scope->has(var)) {
            auto obj = scope->lookup(var);
            if (is_string(obj) && field == "length")
                return static_cast<int64_t>(std::any_cast<const std::string&>(obj).size());
            if (is_list(obj) && field == "length")
                return static_cast<int64_t>(std::any_cast<const BallList&>(obj).size());
            if (is_map(obj)) {
                const auto& m = std::any_cast<const BallMap&>(obj);
                auto it = m.find(field);
                if (it != m.end()) return it->second;
            }
        }
    }

    // Try "expr op expr" pattern for +, -, *, /, %
    // Scan right-to-left, lower precedence first (+ and - before * / %)
    auto try_binary = [&](const std::string& ops) -> std::optional<BallValue> {
        for (int pos = static_cast<int>(expr.size()) - 1; pos > 0; --pos) {
            char c = expr[pos];
            if (ops.find(c) != std::string::npos && pos > 0 && expr[pos-1] == ' ') {
                std::string left_str = expr.substr(0, pos);
                std::string right_str = expr.substr(pos + 1);
                while (!left_str.empty() && left_str.back() == ' ') left_str.pop_back();
                while (!right_str.empty() && right_str.front() == ' ') right_str.erase(right_str.begin());
                if (left_str.empty() || right_str.empty()) continue;

                auto left_val = eval_init_string_expr(left_str, scope);
                auto right_val = eval_init_string_expr(right_str, scope);
                if (left_val.has_value() && right_val.has_value()) {
                    bool both_int = is_int(left_val) && is_int(right_val);
                    switch (c) {
                        case '+': return both_int ? BallValue(to_int(left_val) + to_int(right_val))
                                                  : BallValue(to_num(left_val) + to_num(right_val));
                        case '-': return both_int ? BallValue(to_int(left_val) - to_int(right_val))
                                                  : BallValue(to_num(left_val) - to_num(right_val));
                        case '*': return both_int ? BallValue(to_int(left_val) * to_int(right_val))
                                                  : BallValue(to_num(left_val) * to_num(right_val));
                        case '/': return both_int ? BallValue(to_int(left_val) / to_int(right_val))
                                                  : BallValue(to_num(left_val) / to_num(right_val));
                        case '%': return BallValue(to_int(left_val) % to_int(right_val));
                    }
                }
                break;
            }
        }
        return std::nullopt;
    };
    // Try lower-precedence operators first (left-to-right evaluation)
    auto result = try_binary("+-");
    if (result) return *result;
    result = try_binary("*/%");
    if (result) return *result;

    // Try parsing as a number literal
    try {
        size_t consumed = 0;
        auto i = std::stoll(expr, &consumed);
        if (consumed == expr.size()) return static_cast<int64_t>(i);
    } catch (...) {}
    try {
        size_t consumed = 0;
        auto d = std::stod(expr, &consumed);
        if (consumed == expr.size()) return d;
    } catch (...) {}

    // Give up — return as string.
    return std::string(expr);
}

BallValue Engine::eval_lazy_if(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto cond_it = fields.find("condition");
    auto then_it = fields.find("then");
    auto else_it = fields.find("else");
    if (cond_it == fields.end() || then_it == fields.end())
        throw BallRuntimeError("std.if missing condition or then");
    if (to_bool(eval_expr(cond_it->second, scope)))
        return eval_expr(then_it->second, scope);
    if (else_it != fields.end())
        return eval_expr(else_it->second, scope);
    return {};
}

BallValue Engine::eval_lazy_for(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    std::string loop_label = string_field_val(fields, "label");
    auto for_scope = std::make_shared<Scope>(scope);
    auto init_it = fields.find("init");
    if (init_it != fields.end()) {
        const auto& init_expr = init_it->second;
        if (init_expr.expr_case() == ball::v1::Expression::kBlock) {
            for (const auto& stmt : init_expr.block().statements())
                eval_statement(stmt, for_scope);
        } else if (init_expr.expr_case() == ball::v1::Expression::kLiteral &&
                   init_expr.literal().value_case() == ball::v1::Literal::kStringValue) {
            // Legacy encoding: some encoders emit the init clause as a
            // raw source string like "var i = 0". Parse it into a
            // scope binding to match the Dart engine's behavior.
            const auto& s = init_expr.literal().string_value();
            static const std::regex var_pat(R"(^\s*(?:var|final|int|double|String|bool)?\s*(\w+)\s*=\s*(.+?)\s*$)");
            std::smatch m;
            if (std::regex_match(s, m, var_pat)) {
                const auto& name = m[1].str();
                const auto& raw_val = m[2].str();
                BallValue parsed;
                try {
                    size_t consumed = 0;
                    auto i = std::stoll(raw_val, &consumed);
                    if (consumed == raw_val.size()) {
                        parsed = static_cast<int64_t>(i);
                    }
                } catch (...) {}
                if (!parsed.has_value()) {
                    try {
                        size_t consumed = 0;
                        auto d = std::stod(raw_val, &consumed);
                        if (consumed == raw_val.size()) parsed = d;
                    } catch (...) {}
                }
                if (!parsed.has_value()) {
                    if (raw_val == "true") parsed = true;
                    else if (raw_val == "false") parsed = false;
                    else {
                        // Try to evaluate as a mini expression from the enclosing scope.
                        parsed = eval_init_string_expr(raw_val, scope);
                    }
                }
                for_scope->bind(name, parsed);
            }
            // If the string doesn't match, ignore it (parity with Dart:
            // opaque init strings are no-ops).
        } else {
            eval_expr(init_expr, for_scope);
        }
    }
    auto cond_it = fields.find("condition");
    auto update_it = fields.find("update");
    auto body_it = fields.find("body");
    while (true) {
        if (cond_it != fields.end() && !to_bool(eval_expr(cond_it->second, for_scope))) break;
        if (body_it != fields.end()) {
            auto result = eval_expr(body_it->second, for_scope);
            if (is_flow(result)) {
                const auto& sig = as_flow(result);
                if (sig.kind == "break") {
                    if (sig.label.empty() || sig.label == loop_label) break;
                    return result; // propagate to outer labeled loop
                }
                if (sig.kind == "continue") {
                    if (sig.label.empty() || sig.label == loop_label) goto next_iter;
                    return result;
                }
                if (sig.kind == "return") return result;
            }
        }
        next_iter:
        if (update_it != fields.end()) eval_expr(update_it->second, for_scope);
    }
    return {};
}

BallValue Engine::eval_lazy_for_in(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    std::string loop_label = string_field_val(fields, "label");
    std::string variable = string_field_val(fields, "variable");
    if (variable.empty()) variable = "item";
    auto iter_it = fields.find("iterable");
    auto body_it = fields.find("body");
    if (iter_it == fields.end() || body_it == fields.end()) return {};
    auto iter_val = eval_expr(iter_it->second, scope);
    if (!is_list(iter_val)) throw BallRuntimeError("std.for_in: iterable is not a List");
    for (const auto& item : std::any_cast<const BallList&>(iter_val)) {
        auto loop_scope = std::make_shared<Scope>(scope);
        loop_scope->bind(variable, item);
        auto result = eval_expr(body_it->second, loop_scope);
        if (is_flow(result)) {
            const auto& sig = as_flow(result);
            if (sig.kind == "break") {
                if (sig.label.empty() || sig.label == loop_label) break;
                return result;
            }
            if (sig.kind == "continue") {
                if (sig.label.empty() || sig.label == loop_label) continue;
                return result;
            }
            if (sig.kind == "return") return result;
        }
    }
    return {};
}

BallValue Engine::eval_lazy_while(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    std::string loop_label = string_field_val(fields, "label");
    auto cond_it = fields.find("condition");
    auto body_it = fields.find("body");
    while (true) {
        if (cond_it != fields.end() && !to_bool(eval_expr(cond_it->second, scope))) break;
        if (body_it != fields.end()) {
            auto result = eval_expr(body_it->second, scope);
            if (is_flow(result)) {
                const auto& sig = as_flow(result);
                if (sig.kind == "break") {
                    if (sig.label.empty() || sig.label == loop_label) break;
                    return result;
                }
                if (sig.kind == "continue") {
                    if (sig.label.empty() || sig.label == loop_label) continue;
                    return result;
                }
                if (sig.kind == "return") return result;
            }
        }
    }
    return {};
}

BallValue Engine::eval_lazy_do_while(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    std::string loop_label = string_field_val(fields, "label");
    auto body_it = fields.find("body");
    auto cond_it = fields.find("condition");
    do {
        if (body_it != fields.end()) {
            auto result = eval_expr(body_it->second, scope);
            if (is_flow(result)) {
                const auto& sig = as_flow(result);
                if (sig.kind == "break") {
                    if (sig.label.empty() || sig.label == loop_label) break;
                    return result;
                }
                if (sig.kind == "continue") {
                    if (sig.label.empty() || sig.label == loop_label) continue;
                    return result;
                }
                if (sig.kind == "return") return result;
            }
        }
        if (cond_it != fields.end()) {
            if (!to_bool(eval_expr(cond_it->second, scope))) break;
        } else { break; }
    } while (true);
    return {};
}

BallValue Engine::eval_lazy_switch(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto subj_it = fields.find("subject");
    auto cases_it = fields.find("cases");
    if (subj_it == fields.end() || cases_it == fields.end()) return {};
    auto sub_val = eval_expr(subj_it->second, scope);
    const auto& ce = cases_it->second;
    if (ce.expr_case() != ball::v1::Expression::kLiteral ||
        ce.literal().value_case() != ball::v1::Literal::kListValue) return {};
    const ball::v1::Expression* def = nullptr;
    bool fall_through = false;
    for (const auto& cx : ce.literal().list_value().elements()) {
        if (cx.expr_case() != ball::v1::Expression::kMessageCreation) continue;
        std::unordered_map<std::string, const ball::v1::Expression*> cf;
        for (const auto& f : cx.message_creation().fields()) cf[f.name()] = &f.value();
        auto di = cf.find("is_default");
        if (di != cf.end() && di->second->expr_case() == ball::v1::Expression::kLiteral &&
            di->second->literal().bool_value()) {
            auto bi = cf.find("body"); if (bi != cf.end()) def = bi->second; continue;
        }
        // Pattern matching: check for 'pattern' or 'pattern_expr' field
        auto pi = cf.find("pattern");
        auto pei = cf.find("pattern_expr");
        if (pi != cf.end() || pei != cf.end()) {
            bool matched = fall_through;
            BallMap bindings;
            if (!matched && pi != cf.end()) {
                auto pattern_val = eval_expr(*pi->second, scope);
                matched = match_pattern(sub_val, pattern_val, bindings);
            }
            // Also try pattern_expr (ConstPattern with unquoted value).
            if (!matched && pei != cf.end()) {
                auto pe_val = eval_expr(*pei->second, scope);
                if (is_map(pe_val)) {
                    const auto& pe_map = std::any_cast<const BallMap&>(pe_val);
                    auto val_it = pe_map.find("value");
                    if (val_it != pe_map.end()) {
                        matched = values_equal(sub_val, val_it->second);
                    }
                } else {
                    matched = values_equal(sub_val, pe_val);
                }
            }
            if (matched) {
                // Check guard
                auto gi = cf.find("guard");
                if (gi != cf.end()) {
                    auto guard_scope = std::make_shared<Scope>(scope);
                    for (auto& [k, v] : bindings) guard_scope->bind(k, v);
                    if (!to_bool(eval_expr(*gi->second, guard_scope))) { fall_through = false; continue; }
                }
                auto bi = cf.find("body");
                if (bi != cf.end()) {
                    // Empty body (block with no statements) → fall through
                    const auto& body_expr = *bi->second;
                    if (body_expr.expr_case() == ball::v1::Expression::kBlock &&
                        body_expr.block().statements().empty()) {
                        fall_through = true;
                        continue;
                    }
                    auto body_scope = std::make_shared<Scope>(scope);
                    for (auto& [k, v] : bindings) body_scope->bind(k, v);
                    auto body_result = eval_expr(*bi->second, body_scope);
                    // Consume unlabeled break (switch break, not loop break)
                    if (is_flow(body_result) && as_flow(body_result).kind == "break" && as_flow(body_result).label.empty())
                        return {};
                    return body_result;
                }
            }
            continue;
        }
        // Value matching
        auto vi = cf.find("value");
        if (vi != cf.end() && (values_equal(eval_expr(*vi->second, scope), sub_val) || fall_through)) {
            auto bi = cf.find("body");
            if (bi != cf.end()) {
                auto body_result = eval_expr(*bi->second, scope);
                if (is_flow(body_result) && as_flow(body_result).kind == "break" && as_flow(body_result).label.empty())
                    return {};
                return body_result;
            }
        }
    }
    if (def) {
        auto def_result = eval_expr(*def, scope);
        if (is_flow(def_result) && as_flow(def_result).kind == "break" && as_flow(def_result).label.empty())
            return {};
        return def_result;
    }
    return {};
}

BallValue Engine::eval_lazy_try(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto body_it = fields.find("body");
    auto catches_it = fields.find("catches");
    auto finally_it = fields.find("finally");
    BallValue result;

    auto run_catches = [&](const std::string& exception_type, BallValue exception_value) -> bool {
        if (catches_it == fields.end()) return false;
        const auto& ce = catches_it->second;
        if (ce.expr_case() != ball::v1::Expression::kLiteral ||
            ce.literal().value_case() != ball::v1::Literal::kListValue) return false;
        for (const auto& cx : ce.literal().list_value().elements()) {
            if (cx.expr_case() != ball::v1::Expression::kMessageCreation) continue;
            std::unordered_map<std::string, const ball::v1::Expression*> cf;
            for (const auto& f : cx.message_creation().fields()) cf[f.name()] = &f.value();
            // Check type match (with module-qualified name support)
            auto tit = cf.find("type");
            if (tit != cf.end() && tit->second->expr_case() == ball::v1::Expression::kLiteral) {
                const auto& catch_type = tit->second->literal().string_value();
                if (!catch_type.empty() && !type_name_matches(exception_type, catch_type)) continue;
            }
            std::string var = "e";
            auto vit = cf.find("variable");
            if (vit != cf.end() && vit->second->expr_case() == ball::v1::Expression::kLiteral)
                var = vit->second->literal().string_value();
            auto bit = cf.find("body");
            if (bit != cf.end()) {
                auto cs = std::make_shared<Scope>(scope);
                cs->bind(var, exception_value);
                // Bind stack trace variable if present.
                auto stit = cf.find("stack_trace");
                if (stit != cf.end() && stit->second->expr_case() == ball::v1::Expression::kLiteral) {
                    auto stack_var = stit->second->literal().string_value();
                    if (!stack_var.empty()) {
                        cs->bind(stack_var, std::string("<stack trace>"));
                    }
                }
                // Save/restore the active exception so `rethrow` can
                // re-raise the original exception, and nested tries
                // restore the outer active exception on exit.
                auto prev_active = g_active_exception;
                g_active_exception = std::current_exception();
                try {
                    result = eval_expr(*bit->second, cs);
                } catch (...) {
                    g_active_exception = prev_active;
                    throw;
                }
                g_active_exception = prev_active;
                return true;
            }
        }
        return false;
    };

    try {
        if (body_it != fields.end()) result = eval_expr(body_it->second, scope);
    } catch (const BallException& e) {
        result = {};
        if (!run_catches(e.typeName, e.value)) {
            // No matching typed catch — try with "Exception" as fallback
            if (!run_catches("Exception", e.value)) {
                // No catch at all — rethrow after finally
                if (finally_it != fields.end()) eval_expr(finally_it->second, scope);
                throw;
            }
        }
    } catch (const std::exception& e) {
        result = {};
        if (!run_catches("Exception", std::string(e.what()))) {
            if (finally_it != fields.end()) eval_expr(finally_it->second, scope);
            throw;
        }
    }
    if (finally_it != fields.end()) eval_expr(finally_it->second, scope);
    return result;
}

// ================================================================
// Cascade evaluation
// ================================================================

BallValue Engine::eval_lazy_cascade(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto target_it = fields.find("target");
    if (target_it == fields.end()) return {};
    auto target = eval_expr(target_it->second, scope);
    if (call.function() == "null_aware_cascade" && !target.has_value()) return {};
    auto cascade_scope = std::make_shared<Scope>(scope);
    cascade_scope->bind("__cascade_self__", target);
    auto sections_it = fields.find("sections");
    if (sections_it != fields.end()) {
        const auto& se = sections_it->second;
        if (se.expr_case() == ball::v1::Expression::kLiteral &&
            se.literal().value_case() == ball::v1::Literal::kListValue) {
            for (const auto& section : se.literal().list_value().elements())
                eval_expr(section, cascade_scope);
        } else {
            eval_expr(se, cascade_scope);
        }
    }
    // Return updated __cascade_self__ (sections may have mutated it)
    auto result = cascade_scope->lookup("__cascade_self__");
    // Write back to the original variable if the target was a reference.
    // This emulates reference semantics for cascade mutations.
    if (target_it->second.expr_case() == ball::v1::Expression::kReference) {
        const auto& var_name = target_it->second.reference().name();
        if (scope->has(var_name)) {
            scope->set(var_name, result);
        }
    }
    return result;
}

// ================================================================
// Pattern Matching
// ================================================================

bool Engine::matches_type_pattern(const BallValue& value, const std::string& type_name) {
    if (type_name == "int" || type_name == "Int" || type_name == "num") return is_int(value);
    if (type_name == "double" || type_name == "Double") return is_double(value);
    if (type_name == "String" || type_name == "string") return is_string(value);
    if (type_name == "bool" || type_name == "Bool") return is_bool(value);
    if (type_name == "List" || type_name == "list") return is_list(value);
    if (type_name == "Map" || type_name == "map") return is_map(value);
    if (type_name == "Function") return is_function(value);
    if (type_name == "Null" || type_name == "null") return is_null(value);
    // Check __type__ on map objects
    if (is_map(value)) {
        const auto& m = std::any_cast<const BallMap&>(value);
        auto it = m.find("__type__");
        if (it != m.end() && is_string(it->second)) {
            auto obj_type = std::any_cast<std::string>(it->second);
            if (obj_type == type_name) return true;
            // Walk __super__ chain
            auto sit = m.find("__super__");
            BallValue cur = sit != m.end() ? sit->second : BallValue{};
            while (is_map(cur)) {
                const auto& sm = std::any_cast<const BallMap&>(cur);
                auto st = sm.find("__type__");
                if (st != sm.end() && is_string(st->second) &&
                    std::any_cast<std::string>(st->second) == type_name) return true;
                auto nxt = sm.find("__super__");
                if (nxt == sm.end()) break;
                cur = nxt->second;
            }
        }
    }
    return false;
}

bool Engine::match_string_pattern(const BallValue& value, const std::string& pattern, BallMap& bindings) {
    if (pattern == "_") return true;
    if (pattern == "null") return is_null(value);
    if (pattern == "true") return value.type() == typeid(bool) && std::any_cast<bool>(value);
    if (pattern == "false") return value.type() == typeid(bool) && !std::any_cast<bool>(value);

    // Type test with binding: 'int x', 'String name'
    auto space = pattern.find(' ');
    if (space != std::string::npos) {
        auto type_name = pattern.substr(0, space);
        auto var_name = pattern.substr(space + 1);
        // Trim
        while (!var_name.empty() && var_name.front() == ' ') var_name.erase(var_name.begin());
        if (!var_name.empty() && matches_type_pattern(value, type_name)) {
            bindings[var_name] = value;
            return true;
        }
    }

    // Relational pattern: '> 5', '< 10', '>= 0', '<= 100', '== 42'
    if (!pattern.empty() && (pattern[0] == '>' || pattern[0] == '<' || pattern[0] == '=' || pattern[0] == '!')) {
        std::string op, rhs_str;
        size_t pos = 0;
        if (pattern.size() >= 2 && (pattern[1] == '=' || (pattern[0] == '!' && pattern[1] == '='))) {
            op = pattern.substr(0, 2);
            pos = 2;
        } else {
            op = pattern.substr(0, 1);
            pos = 1;
        }
        rhs_str = pattern.substr(pos);
        while (!rhs_str.empty() && rhs_str.front() == ' ') rhs_str.erase(rhs_str.begin());
        if ((is_int(value) || is_double(value)) && !rhs_str.empty()) {
            double lhs = to_num(value);
            double rhs = std::stod(rhs_str);
            if (op == "==") return lhs == rhs;
            if (op == "!=") return lhs != rhs;
            if (op == ">") return lhs > rhs;
            if (op == "<") return lhs < rhs;
            if (op == ">=") return lhs >= rhs;
            if (op == "<=") return lhs <= rhs;
        }
    }

    // Simple type pattern: 'int', 'String', etc.
    if (matches_type_pattern(value, pattern)) return true;

    // Quoted string literal: "'Monday'" → match against "Monday"
    if (pattern.size() >= 2 && pattern.front() == '\'' && pattern.back() == '\'') {
        auto unquoted = pattern.substr(1, pattern.size() - 2);
        return is_string(value) && std::any_cast<const std::string&>(value) == unquoted;
    }
    if (pattern.size() >= 2 && pattern.front() == '"' && pattern.back() == '"') {
        auto unquoted = pattern.substr(1, pattern.size() - 2);
        return is_string(value) && std::any_cast<const std::string&>(value) == unquoted;
    }

    // Direct value equality
    return pattern == ball::to_string(value);
}

bool Engine::match_structured_pattern(const BallValue& value, const BallMap& pattern, BallMap& bindings) {
    auto kind_it = pattern.find("__pattern_kind__");
    if (kind_it == pattern.end() || !is_string(kind_it->second)) return false;
    auto kind = std::any_cast<std::string>(kind_it->second);

    if (kind == "type_test") {
        auto type_it = pattern.find("type");
        auto name_it = pattern.find("name");
        if (type_it != pattern.end() && is_string(type_it->second)) {
            auto type_name = std::any_cast<std::string>(type_it->second);
            if (matches_type_pattern(value, type_name)) {
                if (name_it != pattern.end() && is_string(name_it->second))
                    bindings[std::any_cast<std::string>(name_it->second)] = value;
                return true;
            }
        }
        return false;
    }

    if (kind == "list") {
        if (!is_list(value)) return false;
        const auto& lst = std::any_cast<const BallList&>(value);
        auto elem_it = pattern.find("elements");
        auto rest_it = pattern.find("rest");
        BallList elements;
        if (elem_it != pattern.end() && is_list(elem_it->second))
            elements = std::any_cast<const BallList&>(elem_it->second);
        std::string rest;
        if (rest_it != pattern.end() && is_string(rest_it->second))
            rest = std::any_cast<std::string>(rest_it->second);
        if (rest.empty() && lst.size() != elements.size()) return false;
        if (!rest.empty() && lst.size() < elements.size()) return false;
        for (size_t i = 0; i < elements.size(); i++) {
            if (!match_pattern(lst[i], elements[i], bindings)) return false;
        }
        if (!rest.empty()) {
            BallList remaining(lst.begin() + elements.size(), lst.end());
            bindings[rest] = remaining;
        }
        return true;
    }

    if (kind == "object" || kind == "record") {
        if (!is_map(value)) return false;
        const auto& val_map = std::any_cast<const BallMap&>(value);
        auto type_it = pattern.find("type");
        if (type_it != pattern.end() && is_string(type_it->second)) {
            auto want_type = std::any_cast<std::string>(type_it->second);
            auto obj_type_it = val_map.find("__type__");
            if (obj_type_it == val_map.end() || !is_string(obj_type_it->second) ||
                std::any_cast<std::string>(obj_type_it->second) != want_type) return false;
        }
        auto fields_it = pattern.find("fields");
        if (fields_it != pattern.end() && is_map(fields_it->second)) {
            const auto& field_patterns = std::any_cast<const BallMap&>(fields_it->second);
            for (const auto& [fname, fpat] : field_patterns) {
                auto fv_it = val_map.find(fname);
                BallValue fv = fv_it != val_map.end() ? fv_it->second : BallValue{};
                if (!match_pattern(fv, fpat, bindings)) return false;
            }
        }
        return true;
    }

    return false;
}

bool Engine::match_pattern(const BallValue& value, const BallValue& pattern, BallMap& bindings) {
    if (is_null(pattern)) return true; // wildcard
    if (is_string(pattern)) {
        auto pat_str = std::any_cast<std::string>(pattern);
        if (pat_str == "_") return true;
        return match_string_pattern(value, pat_str, bindings);
    }
    if (is_map(pattern)) {
        return match_structured_pattern(value, std::any_cast<const BallMap&>(pattern), bindings);
    }
    // Direct value equality
    return values_equal(value, pattern);
}

BallValue Engine::eval_short_circuit_and(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto li = fields.find("left"), ri = fields.find("right");
    if (li == fields.end() || ri == fields.end()) return false;
    if (!to_bool(eval_expr(li->second, scope))) return false;
    return to_bool(eval_expr(ri->second, scope));
}

BallValue Engine::eval_short_circuit_or(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto li = fields.find("left"), ri = fields.find("right");
    if (li == fields.end() || ri == fields.end()) return false;
    if (to_bool(eval_expr(li->second, scope))) return true;
    return to_bool(eval_expr(ri->second, scope));
}

BallValue Engine::eval_return(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto vi = fields.find("value");
    BallValue val = vi != fields.end() ? eval_expr(vi->second, scope) : BallValue{};
    return FlowSignal{"return", "", std::move(val)};
}

BallValue Engine::eval_break(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    return FlowSignal{"break", string_field_val(fields, "label"), {}};
}

BallValue Engine::eval_continue(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    return FlowSignal{"continue", string_field_val(fields, "label"), {}};
}

BallValue Engine::eval_labeled(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto label = string_field_val(fields, "label");
    auto bi = fields.find("body");
    if (bi == fields.end()) return {};

    // Find the loop call in the body (direct call or single-statement block).
    const auto& body_expr = bi->second;
    const ball::v1::FunctionCall* loop_call = nullptr;
    if (body_expr.expr_case() == ball::v1::Expression::kCall) {
        loop_call = &body_expr.call();
    } else if (body_expr.expr_case() == ball::v1::Expression::kBlock) {
        // Check if block has exactly one expression statement that's a loop
        const auto& block = body_expr.block();
        if (block.statements_size() == 1 &&
            block.statements(0).stmt_case() == ball::v1::Statement::kExpression &&
            block.statements(0).expression().expr_case() == ball::v1::Expression::kCall) {
            loop_call = &block.statements(0).expression().call();
        }
    }

    if (loop_call) {
        std::string bmod = loop_call->module().empty() ? current_module_ : loop_call->module();
        const auto& bfn = loop_call->function();
        if ((bmod == "std" || bmod == "dart_std") &&
            (bfn == "for" || bfn == "while" || bfn == "for_in" || bfn == "do_while")) {
            // Build a modified call with the label injected
            ball::v1::FunctionCall modified_call = *loop_call;
            if (modified_call.has_input() &&
                modified_call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                bool has_label = false;
                for (const auto& f : modified_call.input().message_creation().fields()) {
                    if (f.name() == "label") { has_label = true; break; }
                }
                if (!has_label) {
                    auto* new_field = modified_call.mutable_input()->mutable_message_creation()->add_fields();
                    new_field->set_name("label");
                    new_field->mutable_value()->mutable_literal()->set_string_value(label);
                }
            }
            if (bfn == "for") return eval_lazy_for(modified_call, scope);
            if (bfn == "while") return eval_lazy_while(modified_call, scope);
            if (bfn == "for_in") return eval_lazy_for_in(modified_call, scope);
            if (bfn == "do_while") return eval_lazy_do_while(modified_call, scope);
        }
    }

    auto result = eval_expr(bi->second, scope);
    if (is_flow(result)) {
        auto& sig = std::any_cast<FlowSignal&>(result);
        if (sig.kind == "break" && sig.label == label) {
            return {}; // consumed
        }
        // Continue with matching label — should not normally reach here for loops
        // (they're handled above), but consume it for safety.
        if (sig.kind == "continue" && sig.label == label) {
            return {};
        }
    }
    return result;
}

BallValue Engine::eval_goto(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    return FlowSignal{"goto", string_field_val(fields, "label"), {}};
}

BallValue Engine::eval_label(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto label = string_field_val(fields, "name");
    auto bi = fields.find("body");
    if (bi == fields.end()) return {};
    while (true) {
        auto result = eval_expr(bi->second, scope);
        if (is_flow(result)) {
            auto& sig = std::any_cast<FlowSignal&>(result);
            if (sig.kind == "goto" && sig.label == label) {
                continue; // re-execute body (backward goto)
            }
        }
        return result;
    }
}

BallValue Engine::eval_assign(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto ti = fields.find("target"), vi = fields.find("value");
    if (ti == fields.end() || vi == fields.end()) return {};

    // Special case: assign(target: var, value: list_remove_at/list_pop/list_remove_last(list: var, ...))
    // When the list argument references the same variable as the target, perform in-place mutation:
    // modify the list, write it back, but return the removed element (don't overwrite target with it).
    if (ti->second.expr_case() == ball::v1::Expression::kReference &&
        vi->second.expr_case() == ball::v1::Expression::kCall) {
        const auto& val_call = vi->second.call();
        const auto& val_fn = val_call.function();
        if (val_fn == "list_remove_at" || val_fn == "list_pop" || val_fn == "list_remove_last") {
            const auto& target_name = ti->second.reference().name();
            // Check if the list argument references the same variable
            if (val_call.has_input() &&
                val_call.input().expr_case() == ball::v1::Expression::kMessageCreation) {
                for (const auto& f : val_call.input().message_creation().fields()) {
                    if (f.name() == "list" &&
                        f.value().expr_case() == ball::v1::Expression::kReference &&
                        f.value().reference().name() == target_name) {
                        // In-place mutation: get list, remove element, write back list, return removed
                        auto list_val = scope->lookup(target_name);
                        if (is_list(list_val)) {
                            auto lst = std::any_cast<BallList>(list_val);
                            BallValue removed;
                            if (val_fn == "list_remove_at") {
                                int64_t idx = 0;
                                for (const auto& f2 : val_call.input().message_creation().fields()) {
                                    if (f2.name() == "index") {
                                        idx = to_int(eval_expr(f2.value(), scope));
                                        break;
                                    }
                                }
                                if (idx >= 0 && static_cast<size_t>(idx) < lst.size()) {
                                    removed = lst[idx];
                                    lst.erase(lst.begin() + idx);
                                }
                            } else { // list_pop or list_remove_last
                                if (!lst.empty()) {
                                    removed = lst.back();
                                    lst.pop_back();
                                }
                            }
                            scope->set(target_name, BallValue(lst));
                            return removed;
                        }
                        break;
                    }
                }
            }
        }
    }

    auto val = eval_expr(vi->second, scope);
    auto op = string_field_val(fields, "op");
    if (ti->second.expr_case() == ball::v1::Expression::kReference) {
        const auto& name = ti->second.reference().name();
        if (!op.empty() && op != "=") {
            auto computed = apply_compound_op(op, scope->lookup(name), val);
            scope->set(name, computed);
            if (global_scope_->has(name)) global_scope_->set(name, computed);
            return computed;
        }
        scope->set(name, val);
        if (global_scope_->has(name)) global_scope_->set(name, val);
        return val;
    }
    if (ti->second.expr_case() == ball::v1::Expression::kFieldAccess) {
        auto obj = eval_expr(ti->second.field_access().object(), scope);
        if (is_map(obj)) {
            auto m = std::any_cast<BallMap>(obj);
            const auto& field_name = ti->second.field_access().field();

            if (!op.empty() && op != "=") {
                auto fit = m.find(field_name);
                BallValue current = (fit != m.end()) ? fit->second : BallValue{};
                val = apply_compound_op(op, current, val);
            }

            // Try setter dispatch on typed objects before direct field set
            auto setter_result = try_setter_dispatch(m, field_name, val);
            if (setter_result.has_value()) {
                // The setter may return an updated object
                if (is_map(*setter_result)) {
                    m = std::any_cast<BallMap>(*setter_result);
                }
                if (ti->second.field_access().object().expr_case() == ball::v1::Expression::kReference) {
                    scope->set(ti->second.field_access().object().reference().name(), BallValue(m));
                }
                return val;
            }

            m[field_name] = val;
            if (ti->second.field_access().object().expr_case() == ball::v1::Expression::kReference) {
                scope->set(ti->second.field_access().object().reference().name(), BallValue(m));
            }
            return val;
        }
    }
    if (ti->second.expr_case() == ball::v1::Expression::kCall &&
        ti->second.call().module() == "std" && ti->second.call().function() == "index") {
        auto idx_fields = lazy_fields(ti->second.call());
        auto iti = idx_fields.find("target"), ixi = idx_fields.find("index");
        if (iti != idx_fields.end() && ixi != idx_fields.end()) {
            auto idx = eval_expr(ixi->second, scope);
            // For index assignment we need to mutate the original variable in scope.
            // Find the variable name from the target expression.
            if (iti->second.expr_case() == ball::v1::Expression::kReference) {
                const auto& var_name = iti->second.reference().name();
                auto container = scope->lookup(var_name);
                if (is_list(container) && (is_int(idx) || is_double(idx))) {
                    auto& lst = std::any_cast<BallList&>(container);
                    auto i = to_int(idx);
                    if (!op.empty() && op != "=") {
                        val = apply_compound_op(op, lst[i], val);
                    }
                    lst[i] = val;
                    scope->set(var_name, container);
                    return val;
                }
                if (is_map(container)) {
                    auto& m = std::any_cast<BallMap&>(container);
                    auto key = ball::to_string(idx);
                    if (!op.empty() && op != "=") {
                        auto fit = m.find(key);
                        BallValue current = (fit != m.end()) ? fit->second : BallValue{};
                        val = apply_compound_op(op, current, val);
                    }
                    m[key] = val;
                    scope->set(var_name, container);
                    return val;
                }
            }
            // Nested index: target is itself an index call (e.g. matrix[i][j] = val)
            if (iti->second.expr_case() == ball::v1::Expression::kCall &&
                iti->second.call().module() == "std" && iti->second.call().function() == "index") {
                auto outer_fields = lazy_fields(iti->second.call());
                auto oiti = outer_fields.find("target"), oixi = outer_fields.find("index");
                if (oiti != outer_fields.end() && oixi != outer_fields.end() &&
                    oiti->second.expr_case() == ball::v1::Expression::kReference) {
                    const auto& var_name = oiti->second.reference().name();
                    auto outer_idx = eval_expr(oixi->second, scope);
                    auto outer_container = scope->lookup(var_name);
                    if (is_list(outer_container) && is_int(outer_idx)) {
                        auto& outer_lst = std::any_cast<BallList&>(outer_container);
                        auto oi = to_int(outer_idx);
                        if (is_list(outer_lst[oi]) && is_int(idx)) {
                            auto inner = std::any_cast<BallList>(outer_lst[oi]);
                            auto ii = to_int(idx);
                            if (!op.empty() && op != "=") {
                                val = apply_compound_op(op, inner[ii], val);
                            }
                            inner[ii] = val;
                            outer_lst[oi] = BallValue(inner);
                            scope->set(var_name, outer_container);
                            return val;
                        }
                    }
                }
            }
            // Fallback: evaluate target and try to mutate (may not propagate back)
            auto container = eval_expr(iti->second, scope);
            if (is_list(container) && is_int(idx)) {
                std::any_cast<BallList&>(container)[to_int(idx)] = val;
            }
            if (is_map(container) && is_string(idx)) {
                std::any_cast<BallMap&>(container)[std::any_cast<const std::string&>(idx)] = val;
            }
        }
    }
    return val;
}

BallValue Engine::eval_inc_dec(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope) {
    auto fields = lazy_fields(call);
    auto vi = fields.find("value");
    if (vi == fields.end()) return {};
    bool is_inc = call.function().find("increment") != std::string::npos;
    bool is_pre = call.function().substr(0, 3) == "pre";
    if (vi->second.expr_case() == ball::v1::Expression::kReference) {
        const auto& name = vi->second.reference().name();
        int64_t current = to_int(scope->lookup(name));
        int64_t updated = is_inc ? current + 1 : current - 1;
        scope->set(name, updated);
        return is_pre ? updated : current;
    }
    // Handle index expressions: count[x]++ etc.
    if (vi->second.expr_case() == ball::v1::Expression::kCall &&
        (vi->second.call().module() == "std" || vi->second.call().module().empty()) &&
        vi->second.call().function() == "index") {
        auto idx_fields_map = lazy_fields(vi->second.call());
        auto iti = idx_fields_map.find("target");
        auto ixi = idx_fields_map.find("index");
        if (iti != idx_fields_map.end() && ixi != idx_fields_map.end() &&
            iti->second.expr_case() == ball::v1::Expression::kReference) {
            const auto& var_name = iti->second.reference().name();
            auto idx = eval_expr(ixi->second, scope);
            auto container = scope->lookup(var_name);
            if (is_list(container) && (is_int(idx) || is_double(idx))) {
                auto lst = std::any_cast<BallList>(container);
                auto i = to_int(idx);
                if (i >= 0 && static_cast<size_t>(i) < lst.size()) {
                    int64_t current = to_int(lst[i]);
                    int64_t updated = is_inc ? current + 1 : current - 1;
                    lst[i] = BallValue(updated);
                    scope->set(var_name, BallValue(lst));
                    return is_pre ? updated : current;
                }
            }
            if (is_map(container)) {
                auto m = std::any_cast<BallMap>(container);
                auto key = ball::to_string(idx);
                auto it = m.find(key);
                int64_t current = (it != m.end()) ? to_int(it->second) : 0;
                int64_t updated = is_inc ? current + 1 : current - 1;
                m[key] = BallValue(updated);
                scope->set(var_name, BallValue(m));
                return is_pre ? updated : current;
            }
        }
    }
    // Handle field access: obj.field++
    if (vi->second.expr_case() == ball::v1::Expression::kFieldAccess) {
        auto obj = eval_expr(vi->second.field_access().object(), scope);
        if (is_map(obj)) {
            auto m = std::any_cast<BallMap>(obj);
            const auto& field_name = vi->second.field_access().field();
            auto it = m.find(field_name);
            int64_t current = (it != m.end()) ? to_int(it->second) : 0;
            int64_t updated = is_inc ? current + 1 : current - 1;
            m[field_name] = BallValue(updated);
            if (vi->second.field_access().object().expr_case() == ball::v1::Expression::kReference) {
                scope->set(vi->second.field_access().object().reference().name(), BallValue(m));
            }
            return is_pre ? updated : current;
        }
    }
    int64_t v = to_int(eval_expr(vi->second, scope));
    return is_inc ? v + 1 : v - 1;
}

// ================================================================
// OOP dispatch helpers — getters, setters, operator overrides
// ================================================================

bool Engine::is_getter_fn(const ball::v1::FunctionDefinition& func) {
    if (!func.has_metadata()) return false;
    auto it = func.metadata().fields().find("is_getter");
    return it != func.metadata().fields().end() && it->second.bool_value();
}

bool Engine::is_setter_fn(const ball::v1::FunctionDefinition& func) {
    if (!func.has_metadata()) return false;
    auto it = func.metadata().fields().find("is_setter");
    return it != func.metadata().fields().end() && it->second.bool_value();
}

std::optional<BallValue> Engine::try_getter_dispatch(const BallMap& object,
                                                    const std::string& field_name) {
    auto type_it = object.find("__type__");
    if (type_it == object.end() || !is_string(type_it->second)) return std::nullopt;
    const auto& type_name = std::any_cast<const std::string&>(type_it->second);

    auto colon_idx = type_name.find(':');
    std::string mod_part = (colon_idx != std::string::npos)
        ? type_name.substr(0, colon_idx)
        : current_module_;

    // Check "module.typeName.fieldName" as a getter.
    std::string getter_key = mod_part + "." + type_name + "." + field_name;
    auto fit = functions_.find(getter_key);
    if (fit == functions_.end() && colon_idx == std::string::npos) {
        getter_key = mod_part + "." + mod_part + ":" + type_name + "." + field_name;
        fit = functions_.find(getter_key);
    }
    if (fit != functions_.end() && is_getter_fn(*fit->second)) {
        BallMap input;
        input["self"] = object;
        return call_function_internal(mod_part, *fit->second, BallValue(input));
    }

    // Walk __super__ chain for inherited getters.
    auto super_it = object.find("__super__");
    BallValue super_obj = (super_it != object.end()) ? super_it->second : BallValue{};
    while (is_map(super_obj)) {
        const auto& sm = std::any_cast<const BallMap&>(super_obj);
        auto st = sm.find("__type__");
        if (st != sm.end() && is_string(st->second)) {
            const auto& super_type = std::any_cast<const std::string&>(st->second);
            auto s_colon = super_type.find(':');
            std::string s_mod = (s_colon != std::string::npos)
                ? super_type.substr(0, s_colon) : mod_part;
            std::string s_type = (s_colon != std::string::npos)
                ? super_type : (s_mod + ":" + super_type);
            std::string super_getter_key = s_mod + "." + s_type + "." + field_name;
            auto sfit = functions_.find(super_getter_key);
            if (sfit != functions_.end() && is_getter_fn(*sfit->second)) {
                BallMap input;
                input["self"] = object;
                return call_function_internal(s_mod, *sfit->second, BallValue(input));
            }
        }
        auto ss = sm.find("__super__");
        super_obj = (ss != sm.end()) ? ss->second : BallValue{};
    }

    return std::nullopt;
}

std::optional<BallValue> Engine::try_setter_dispatch(const BallMap& object,
                                                    const std::string& field_name,
                                                    BallValue value) {
    auto type_it = object.find("__type__");
    if (type_it == object.end() || !is_string(type_it->second)) return std::nullopt;
    const auto& type_name = std::any_cast<const std::string&>(type_it->second);

    auto colon_idx = type_name.find(':');
    std::string mod_part = (colon_idx != std::string::npos)
        ? type_name.substr(0, colon_idx)
        : current_module_;

    // Setter functions are named "TypeName.fieldName=" by convention.
    std::string setter_key = mod_part + "." + type_name + "." + field_name + "=";
    auto fit = functions_.find(setter_key);
    if (fit == functions_.end() && colon_idx == std::string::npos) {
        setter_key = mod_part + "." + mod_part + ":" + type_name + "." + field_name + "=";
        fit = functions_.find(setter_key);
    }
    if (fit != functions_.end() && is_setter_fn(*fit->second)) {
        // Call the setter and reconstruct the updated self from scope
        auto prev_module = current_module_;
        current_module_ = mod_part;
        auto scope = std::make_shared<Scope>(global_scope_);
        BallMap mutable_object = object;

        // Bind params
        auto params = extract_params(fit->second->metadata());
        if (params.size() == 1) {
            scope->bind(params[0], std::move(value));
        }

        // Bind self fields into scope
        scope->bind("self", BallValue(mutable_object));
        scope->bind("this", BallValue(mutable_object));
        for (const auto& [k, v] : mutable_object) {
            if (k != "__type__" && k != "__super__" && k != "__methods__" && k != "__type_args__") {
                scope->bind(k, v);
            }
        }

        // Execute setter body
        if (fit->second->has_body()) {
            eval_expr(fit->second->body(), scope);
        }

        // Read back modified fields
        for (auto& [k, v] : mutable_object) {
            if (k != "__type__" && k != "__super__" && k != "__methods__" && k != "__type_args__") {
                if (scope->has(k)) {
                    mutable_object[k] = scope->lookup(k);
                }
            }
        }

        current_module_ = prev_module;
        return BallValue(mutable_object);
    }

    // Walk __super__ chain for inherited setters.
    auto super_it = object.find("__super__");
    BallValue super_obj = (super_it != object.end()) ? super_it->second : BallValue{};
    while (is_map(super_obj)) {
        const auto& sm = std::any_cast<const BallMap&>(super_obj);
        auto st = sm.find("__type__");
        if (st != sm.end() && is_string(st->second)) {
            const auto& super_type = std::any_cast<const std::string&>(st->second);
            auto s_colon = super_type.find(':');
            std::string s_mod = (s_colon != std::string::npos)
                ? super_type.substr(0, s_colon) : mod_part;
            std::string s_type = (s_colon != std::string::npos)
                ? super_type : (s_mod + ":" + super_type);
            std::string super_setter_key = s_mod + "." + s_type + "." + field_name + "=";
            auto sfit = functions_.find(super_setter_key);
            if (sfit != functions_.end() && is_setter_fn(*sfit->second)) {
                BallMap input;
                input["self"] = object;
                input["value"] = std::move(value);
                return call_function_internal(s_mod, *sfit->second, BallValue(input));
            }
        }
        auto ss = sm.find("__super__");
        super_obj = (ss != sm.end()) ? ss->second : BallValue{};
    }

    return std::nullopt;
}

// Maps std function names to operator symbols used by user-defined overrides.
// Mirrors Dart _stdFunctionToOperator.
static const std::unordered_map<std::string, std::string>& std_function_to_operator() {
    static const std::unordered_map<std::string, std::string> table = {
        {"equals", "=="},
        {"not_equals", "!="},
        {"add", "+"},
        {"subtract", "-"},
        {"multiply", "*"},
        {"divide", "~/"},
        {"divide_double", "/"},
        {"modulo", "%"},
        {"less_than", "<"},
        {"greater_than", ">"},
        {"lte", "<="},
        {"gte", ">="},
        {"index", "[]"},
    };
    return table;
}

std::optional<BallValue> Engine::try_operator_override(const std::string& function,
                                                      const BallValue& input) {
    const auto& table = std_function_to_operator();
    auto op_it = table.find(function);
    if (op_it == table.end()) return std::nullopt;
    if (!is_map(input)) return std::nullopt;
    const auto& m = std::any_cast<const BallMap&>(input);

    // For "index": operands are in target/index; for others, left/right.
    BallValue left, right;
    if (function == "index") {
        auto lit = m.find("target");
        auto rit = m.find("index");
        if (lit != m.end()) left = lit->second;
        if (rit != m.end()) right = rit->second;
    } else {
        auto lit = m.find("left");
        auto rit = m.find("right");
        if (lit != m.end()) left = lit->second;
        if (rit != m.end()) right = rit->second;
    }

    if (!is_map(left)) return std::nullopt;
    const auto& left_map = std::any_cast<const BallMap&>(left);
    auto type_it = left_map.find("__type__");
    if (type_it == left_map.end() || !is_string(type_it->second)) return std::nullopt;

    const auto& type_name = std::any_cast<const std::string&>(type_it->second);
    auto colon_idx = type_name.find(':');
    std::string mod_part = (colon_idx != std::string::npos)
        ? type_name.substr(0, colon_idx)
        : current_module_;
    const std::string& op = op_it->second;

    // Walk type hierarchy: current type, then __super__ chain.
    BallValue current = left;
    while (is_map(current)) {
        const auto& cur_map = std::any_cast<const BallMap&>(current);
        auto cur_type_it = cur_map.find("__type__");
        if (cur_type_it != cur_map.end() && is_string(cur_type_it->second)) {
            const auto& cur_type = std::any_cast<const std::string&>(cur_type_it->second);
            auto c_colon = cur_type.find(':');
            std::string c_mod = (c_colon != std::string::npos)
                ? cur_type.substr(0, c_colon) : mod_part;
            std::string c_type = (c_colon != std::string::npos)
                ? cur_type : (c_mod + ":" + cur_type);
            std::string method_key = c_mod + "." + c_type + "." + op;
            auto fit = functions_.find(method_key);
            if (fit != functions_.end()) {
                BallMap method_input;
                method_input["self"] = left;
                method_input["other"] = right;
                method_input["arg0"] = right;
                // Also bind the right operand with the operator's param name
                if (fit->second->has_metadata()) {
                    auto op_params = extract_params(fit->second->metadata());
                    if (!op_params.empty()) {
                        method_input[op_params[0]] = right;
                    }
                }
                return call_function_internal(c_mod, *fit->second, BallValue(method_input));
            }
        }
        auto next = cur_map.find("__super__");
        current = (next != cur_map.end()) ? next->second : BallValue{};
    }

    return std::nullopt;
}

std::string Engine::value_to_string(const BallValue& val) {
    // Check for user-defined toString on typed objects
    if (is_map(val)) {
        const auto& m = std::any_cast<const BallMap&>(val);
        auto type_it = m.find("__type__");
        if (type_it != m.end() && is_string(type_it->second)) {
            const auto& type_name = std::any_cast<const std::string&>(type_it->second);

            // StringBuffer: return _buffer content
            if (type_name.find("StringBuffer") != std::string::npos) {
                auto buf_it = m.find("_buffer");
                if (buf_it != m.end() && is_string(buf_it->second))
                    return std::any_cast<const std::string&>(buf_it->second);
                return "";
            }

            auto colon_idx = type_name.find(':');
            std::string mod_part = (colon_idx != std::string::npos)
                ? type_name.substr(0, colon_idx)
                : current_module_;

            // Look for toString method
            std::string method_key = mod_part + "." + type_name + ".toString";
            auto fit = functions_.find(method_key);
            if (fit == functions_.end() && colon_idx == std::string::npos) {
                method_key = mod_part + "." + mod_part + ":" + type_name + ".toString";
                fit = functions_.find(method_key);
            }
            if (fit != functions_.end()) {
                BallMap input;
                input["self"] = val;
                auto result = call_function_internal(mod_part, *fit->second, BallValue(input));
                return ball::to_string(result);
            }
            // Walk __super__ chain for inherited toString
            auto super_it = m.find("__super__");
            BallValue super_obj = (super_it != m.end()) ? super_it->second : BallValue{};
            while (is_map(super_obj)) {
                const auto& sm = std::any_cast<const BallMap&>(super_obj);
                auto st = sm.find("__type__");
                if (st != sm.end() && is_string(st->second)) {
                    const auto& super_type = std::any_cast<const std::string&>(st->second);
                    auto s_colon = super_type.find(':');
                    std::string s_mod = (s_colon != std::string::npos)
                        ? super_type.substr(0, s_colon) : mod_part;
                    std::string s_type = (s_colon != std::string::npos)
                        ? super_type : (s_mod + ":" + super_type);
                    std::string super_key = s_mod + "." + s_type + ".toString";
                    auto sfit = functions_.find(super_key);
                    if (sfit != functions_.end()) {
                        BallMap input;
                        input["self"] = val;
                        auto result = call_function_internal(s_mod, *sfit->second, BallValue(input));
                        return ball::to_string(result);
                    }
                }
                auto ss = sm.find("__super__");
                super_obj = (ss != sm.end()) ? ss->second : BallValue{};
            }
        }
    }
    return ball::to_string(val);
}

BallValue Engine::apply_compound_op(const std::string& op, BallValue current, BallValue val) {
    bool both_int = is_int(current) && is_int(val);
    if (op == "+=") {
        if (is_string(current) || is_string(val)) return ball::to_string(current) + ball::to_string(val);
        if (both_int) return to_int(current) + to_int(val);
        return to_num(current) + to_num(val);
    }
    if (op == "-=") { if (both_int) return to_int(current) - to_int(val); return to_num(current) - to_num(val); }
    if (op == "*=") { if (both_int) return to_int(current) * to_int(val); return to_num(current) * to_num(val); }
    if (op == "/=") { auto d = to_num(val); if (d == 0.0) return static_cast<int64_t>(0); if (both_int) return to_int(current) / to_int(val); return to_num(current) / d; }
    if (op == "~/=") { auto d = to_int(val); return d != 0 ? to_int(current) / d : static_cast<int64_t>(0); }
    if (op == "%=") { auto a = to_int(current), b = to_int(val); auto m = a % b; return m < 0 ? m + (b < 0 ? -b : b) : m; }
    if (op == "&=") return to_int(current) & to_int(val);
    if (op == "|=") return to_int(current) | to_int(val);
    if (op == "^=") return to_int(current) ^ to_int(val);
    if (op == "<<=") return to_int(current) << to_int(val);
    if (op == ">>=") return to_int(current) >> to_int(val);
    if (op == "??=") return current.has_value() ? current : val;
    return val;
}

// ================================================================
// std dispatch table
// ================================================================

std::unordered_map<std::string, std::function<BallValue(BallValue)>>
Engine::build_std_dispatch() {
    return {
        {"print", [this](BallValue input) -> BallValue {
            if (is_map(input)) {
                auto msg = extract_field(input, "message");
                if (msg.has_value()) { stdout_fn(value_to_string(msg)); return {}; }
            }
            stdout_fn(value_to_string(input)); return {};
        }},
        {"add", [](BallValue i) -> BallValue {
            auto [l,r] = extract_binary(i);
            if (is_string(l)) return ball::to_string(l) + ball::to_string(r);
            if (is_double(l)||is_double(r)) return to_double(l)+to_double(r);
            return to_int(l)+to_int(r);
        }},
        {"subtract", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); if(is_double(l)||is_double(r)) return to_double(l)-to_double(r); return to_int(l)-to_int(r); }},
        {"multiply", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); if(is_double(l)||is_double(r)) return to_double(l)*to_double(r); return to_int(l)*to_int(r); }},
        {"divide", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); auto rv=to_int(r); return rv!=0?to_int(l)/rv:static_cast<int64_t>(0); }},
        {"divide_double", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_double(l)/to_double(r); }},
        {"modulo", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); if(is_double(l)||is_double(r)) { auto a=to_double(l),b=to_double(r); auto m=std::fmod(a,b); return m<0?m+(b<0?-b:b):m; } auto a=to_int(l),b=to_int(r); auto m=a%b; return m<0?m+(b<0?-b:b):m; }},
        {"negate", [](BallValue i) -> BallValue { auto v=extract_unary(i); if(is_double(v)) return -to_double(v); return -to_int(v); }},
        {"equals", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return ball::to_string(l)==ball::to_string(r); }},
        {"not_equals", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return ball::to_string(l)!=ball::to_string(r); }},
        {"less_than", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_double(l)<to_double(r); }},
        {"greater_than", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_double(l)>to_double(r); }},
        {"lte", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_double(l)<=to_double(r); }},
        {"gte", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_double(l)>=to_double(r); }},
        {"and", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_bool(l)&&to_bool(r); }},
        {"or", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_bool(l)||to_bool(r); }},
        {"not", [](BallValue i) -> BallValue { return !to_bool(extract_unary(i)); }},
        {"bitwise_and", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_int(l)&to_int(r); }},
        {"bitwise_or", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_int(l)|to_int(r); }},
        {"bitwise_xor", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_int(l)^to_int(r); }},
        {"bitwise_not", [](BallValue i) -> BallValue { return ~to_int(extract_unary(i)); }},
        {"left_shift", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_int(l)<<to_int(r); }},
        {"right_shift", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return to_int(l)>>to_int(r); }},
        {"unsigned_right_shift", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return static_cast<int64_t>(static_cast<uint64_t>(to_int(l))>>to_int(r)); }},
        {"pre_increment", [](BallValue i) -> BallValue { return to_int(extract_unary(i))+1; }},
        {"pre_decrement", [](BallValue i) -> BallValue { return to_int(extract_unary(i))-1; }},
        {"post_increment", [](BallValue i) -> BallValue { return to_int(extract_unary(i))+1; }},
        {"post_decrement", [](BallValue i) -> BallValue { return to_int(extract_unary(i))-1; }},
        {"concat", [this](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return value_to_string(l)+value_to_string(r); }},
        {"to_string", [this](BallValue i) -> BallValue { return value_to_string(extract_unary(i)); }},
        {"to_int", [](BallValue i) -> BallValue { return to_int(extract_unary(i)); }},
        {"to_double", [](BallValue i) -> BallValue { return to_double(extract_unary(i)); }},
        {"length", [](BallValue i) -> BallValue {
            auto v=extract_unary(i);
            if(is_string(v)) return static_cast<int64_t>(std::any_cast<std::string>(v).size());
            if(is_list(v)) return static_cast<int64_t>(std::any_cast<BallList>(v).size());
            return static_cast<int64_t>(0);
        }},
        {"int_to_string", [](BallValue i) -> BallValue { return std::to_string(to_int(extract_unary(i))); }},
        {"double_to_string", [](BallValue i) -> BallValue { return double_to_dart_string(to_double(extract_unary(i))); }},
        {"string_to_int", [](BallValue i) -> BallValue {
            auto s = ball::to_string(extract_unary(i));
            try {
                return static_cast<int64_t>(std::stoll(s));
            } catch (const std::exception&) {
                // Dart parity: int.parse() throws FormatException on bad input.
                throw BallException("FormatException", "FormatException: " + s);
            }
        }},
        {"string_to_double", [](BallValue i) -> BallValue {
            auto s = ball::to_string(extract_unary(i));
            try {
                return std::stod(s);
            } catch (const std::exception&) {
                throw BallException("FormatException", "FormatException: " + s);
            }
        }},
        {"string_interpolation", [this](BallValue i) -> BallValue {
            if(is_map(i)){auto p=extract_field(i,"parts");if(is_list(p)){std::string r;for(auto&x:std::any_cast<BallList>(p))r+=value_to_string(x);return r;} auto v=extract_field(i,"value");if(v.has_value())return value_to_string(v);} return value_to_string(i);
        }},
        {"null_coalesce", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return l.has_value()?l:r; }},
        {"null_check", [](BallValue i) -> BallValue { return extract_unary(i); }},
        {"is", [](BallValue i) -> BallValue {
            if(!is_map(i)) return false;
            auto v=extract_field(i,"value");
            auto t=ball::to_string(extract_field(i,"type"));
            if(t=="int") return is_int(v);
            if(t=="double") return is_double(v);
            if(t=="num") return is_int(v)||is_double(v);
            if(t=="String") return is_string(v);
            if(t=="bool") return is_bool(v);
            if(t=="List") return is_list(v);
            if(t=="Map") return is_map(v);
            if(t=="Null"||t=="void") return is_null(v);
            if(t=="Object"||t=="dynamic") return true;
            if(t=="Function") return is_function(v);
            // Check BallMap __type__ with __super__ chain walking
            return object_type_matches(v, t);
        }},
        {"is_not", [](BallValue i) -> BallValue {
            if(!is_map(i)) return true;
            auto v=extract_field(i,"value");
            auto t=ball::to_string(extract_field(i,"type"));
            if(t=="int") return !is_int(v);
            if(t=="double") return !is_double(v);
            if(t=="num") return !(is_int(v)||is_double(v));
            if(t=="String") return !is_string(v);
            if(t=="bool") return !is_bool(v);
            if(t=="List") return !is_list(v);
            if(t=="Map") return !is_map(v);
            if(t=="Null"||t=="void") return !is_null(v);
            if(t=="Object"||t=="dynamic") return false;
            if(t=="Function") return !is_function(v);
            // Check BallMap __type__ with __super__ chain walking
            return !object_type_matches(v, t);
        }},
        {"as", [](BallValue i) -> BallValue { return extract_unary(i); }},
        {"identical", [](BallValue i) -> BallValue {
            auto l=extract_field(i,"left"); auto r=extract_field(i,"right");
            if(!l.has_value()) l=extract_field(i,"arg0");
            if(!r.has_value()) r=extract_field(i,"arg1");
            return values_equal(l,r);
        }},
        {"index", [](BallValue i) -> BallValue {
            auto tgt=extract_field(i,"target"); auto idx=extract_field(i,"index");
            if(is_list(tgt)&&(is_int(idx)||is_double(idx))) return std::any_cast<BallList>(tgt)[to_int(idx)];
            if(is_string(tgt)&&(is_int(idx)||is_double(idx))){auto s=std::any_cast<std::string>(tgt);return std::string(1,s[to_int(idx)]);}
            if(is_map(tgt)) {
                auto key = ball::to_string(idx);
                auto& m = std::any_cast<const BallMap&>(tgt);
                auto it = m.find(key);
                return (it != m.end()) ? it->second : BallValue{};
            }
            throw BallRuntimeError("std.index: unsupported types");
        }},
        {"cascade", [](BallValue i) -> BallValue { return extract_field(i,"target"); }},
        {"spread", [](BallValue i) -> BallValue { return extract_unary(i); }},
        {"null_spread", [](BallValue i) -> BallValue { return extract_unary(i); }},
        {"invoke", [](BallValue i) -> BallValue {
            if(!is_map(i)) throw BallRuntimeError("std.invoke: expected map");
            auto callee=extract_field(i,"callee");
            if(!is_function(callee)) throw BallRuntimeError("std.invoke: not callable");
            auto& fn=std::any_cast<BallFunction&>(callee);
            auto& m=std::any_cast<const BallMap&>(i);
            BallMap args; for(auto&[k,v]:m) if(k!="callee"&&k!="__type__") args[k]=v;
            if(args.size()==1) return fn(args.begin()->second);
            if(args.empty()) return fn({});
            return fn(BallValue(args));
        }},
        {"throw", [](BallValue i) -> BallValue {
            auto val = extract_unary(i);
            std::string typeName = "Exception";
            if (is_map(val)) {
                const auto& m = std::any_cast<const BallMap&>(val);
                // Check __type__ (from MessageCreation typeName) or __type (legacy field)
                auto it = m.find("__type__");
                if (it != m.end() && is_string(it->second)) {
                    typeName = to_string(it->second);
                } else {
                    auto it2 = m.find("__type");
                    if (it2 != m.end() && is_string(it2->second)) {
                        typeName = to_string(it2->second);
                    }
                }
            }
            throw BallException(typeName, val);
        }},
        {"rethrow", [](BallValue) -> BallValue {
            if (g_active_exception) std::rethrow_exception(g_active_exception);
            throw BallRuntimeError("rethrow outside of catch");
        }},
        // The encoder wraps parenthesized sub-expressions in `std.paren`
        // so the compiler knows where Dart source had explicit parens.
        // At runtime `paren(x)` is just `x`.
        {"paren", [](BallValue i) -> BallValue { return extract_field(i, "value"); }},
        {"assert", [](BallValue i) -> BallValue {
            if(!to_bool(extract_field(i,"condition"))) throw BallRuntimeError("Assertion failed: "+ball::to_string(extract_field(i,"message")));
            return {};
        }},
        {"await", [](BallValue i) -> BallValue {
            auto val = extract_unary(i);
            if (is_future(val)) return std::any_cast<const BallFuture&>(val).value;
            return val;
        }},
        {"yield", [](BallValue i) -> BallValue {
            FlowSignal sig;
            sig.kind = "yield";
            sig.value = extract_unary(i);
            return sig;
        }},
        {"yield_each", [](BallValue i) -> BallValue {
            FlowSignal sig;
            sig.kind = "yield_each";
            sig.value = extract_unary(i);
            return sig;
        }},
        {"string_length", [](BallValue i) -> BallValue { return static_cast<int64_t>(ball::to_string(extract_unary(i)).size()); }},
        {"string_is_empty", [](BallValue i) -> BallValue { return ball::to_string(extract_unary(i)).empty(); }},
        {"string_concat", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return ball::to_string(l)+ball::to_string(r); }},
        {"string_contains", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return ball::to_string(l).find(ball::to_string(r))!=std::string::npos; }},
        {"string_starts_with", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_field(i,"left")); auto p=ball::to_string(extract_field(i,"right")); return s.substr(0,p.size())==p; }},
        {"string_ends_with", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_field(i,"left")); auto p=ball::to_string(extract_field(i,"right")); return s.size()>=p.size()&&s.substr(s.size()-p.size())==p; }},
        {"string_index_of", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); auto p=ball::to_string(l).find(ball::to_string(r)); return static_cast<int64_t>(p==std::string::npos?-1:p); }},
        {"string_last_index_of", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); auto p=ball::to_string(l).rfind(ball::to_string(r)); return static_cast<int64_t>(p==std::string::npos?-1:p); }},
        {"string_substring", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value")); auto st=to_int(extract_field(i,"start"));
            auto ev=extract_field(i,"end"); size_t en=ev.has_value()?to_int(ev):s.size();
            return s.substr(st,en-st);
        }},
        {"string_char_at", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_field(i,"target")); return std::string(1,s[to_int(extract_field(i,"index"))]); }},
        {"string_char_code_at", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_field(i,"target")); return static_cast<int64_t>(static_cast<unsigned char>(s[to_int(extract_field(i,"index"))])); }},
        {"string_code_unit_at", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value"));
            auto idx=to_int(extract_field(i,"index"));
            if (idx < 0 || idx >= static_cast<int64_t>(s.size())) return BallValue{};
            return static_cast<int64_t>(static_cast<unsigned char>(s[idx]));
        }},
        {"string_from_char_code", [](BallValue i) -> BallValue { return std::string(1,static_cast<char>(to_int(extract_unary(i)))); }},
        {"string_to_upper", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_unary(i)); std::transform(s.begin(),s.end(),s.begin(),::toupper); return s; }},
        {"string_to_lower", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_unary(i)); std::transform(s.begin(),s.end(),s.begin(),::tolower); return s; }},
        {"string_trim", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_unary(i));
            auto a=s.find_first_not_of(" \t\n\r"), b=s.find_last_not_of(" \t\n\r");
            return a==std::string::npos?std::string(""):s.substr(a,b-a+1);
        }},
        {"string_trim_start", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_unary(i)); auto a=s.find_first_not_of(" \t\n\r"); return a==std::string::npos?std::string(""):s.substr(a); }},
        {"string_trim_end", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_unary(i)); auto b=s.find_last_not_of(" \t\n\r"); return b==std::string::npos?std::string(""):s.substr(0,b+1); }},
        {"string_replace", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value")); auto f=ball::to_string(extract_field(i,"from")); auto t=ball::to_string(extract_field(i,"to"));
            auto p=s.find(f); if(p!=std::string::npos) s.replace(p,f.size(),t); return s;
        }},
        {"string_replace_all", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value")); auto f=ball::to_string(extract_field(i,"from")); auto t=ball::to_string(extract_field(i,"to"));
            if (f.empty()) {
                std::string out;
                out.reserve(s.size() * (t.size() + 1) + t.size());
                out += t;
                for (char c : s) {
                    out.push_back(c);
                    out += t;
                }
                return out;
            }
            size_t p=0; while((p=s.find(f,p))!=std::string::npos){s.replace(p,f.size(),t);p+=t.size();} return s;
        }},
        {"string_split", [](BallValue i) -> BallValue {
            // Support both left/right and value/separator field names
            auto sv=extract_field(i,"value"); auto sep=extract_field(i,"separator");
            std::string s, d;
            if (sv.has_value()) {
                s = ball::to_string(sv);
                d = sep.has_value() ? ball::to_string(sep) : ball::to_string(extract_field(i,"right"));
            } else {
                auto [l,r]=extract_binary(i); s=ball::to_string(l); d=ball::to_string(r);
            }
            BallList parts;
            if (d.empty()) {
                for (char c : s) parts.push_back(std::string(1, c));
                return parts;
            }
            size_t p=0; while((p=s.find(d))!=std::string::npos){parts.push_back(s.substr(0,p));s.erase(0,p+d.size());} parts.push_back(s); return parts;
        }},
        {"string_repeat", [](BallValue i) -> BallValue { auto s=ball::to_string(extract_field(i,"value")); auto c=to_int(extract_field(i,"count")); std::string r; for(int64_t j=0;j<c;++j)r+=s; return r; }},
        {"string_pad_left", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value")); auto w=to_int(extract_field(i,"width"));
            auto pv=extract_field(i,"padding"); char p=pv.has_value()?ball::to_string(pv)[0]:' ';
            while(static_cast<int64_t>(s.size())<w)s=std::string(1,p)+s; return s;
        }},
        {"string_pad_right", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value")); auto w=to_int(extract_field(i,"width"));
            auto pv=extract_field(i,"padding"); char p=pv.has_value()?ball::to_string(pv)[0]:' ';
            while(static_cast<int64_t>(s.size())<w)s+=p; return s;
        }},
        // ── Regex ──
        {"regex_match", [](BallValue i) -> BallValue {
            auto [l,r]=extract_binary(i); auto input=ball::to_string(l); auto pat=ball::to_string(r);
            return std::regex_search(input, std::regex(pat));
        }},
        {"regex_find", [](BallValue i) -> BallValue {
            auto [l,r]=extract_binary(i); auto input=ball::to_string(l); auto pat=ball::to_string(r);
            std::smatch m; if(std::regex_search(input,m,std::regex(pat))) return m[0].str(); return BallValue{};
        }},
        {"regex_find_all", [](BallValue i) -> BallValue {
            auto [l,r]=extract_binary(i); auto input=ball::to_string(l); auto pat=ball::to_string(r);
            BallList results; std::regex re(pat); auto begin=std::sregex_iterator(input.begin(),input.end(),re);
            for(auto it=begin;it!=std::sregex_iterator();++it) results.push_back((*it)[0].str()); return results;
        }},
        {"regex_replace", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value")); auto f=ball::to_string(extract_field(i,"from")); auto t=ball::to_string(extract_field(i,"to"));
            return std::regex_replace(s, std::regex(f), t, std::regex_constants::format_first_only);
        }},
        {"regex_replace_all", [](BallValue i) -> BallValue {
            auto s=ball::to_string(extract_field(i,"value")); auto f=ball::to_string(extract_field(i,"from")); auto t=ball::to_string(extract_field(i,"to"));
            return std::regex_replace(s, std::regex(f), t);
        }},
        {"math_abs", [](BallValue i) -> BallValue { auto v=extract_unary(i); if(is_double(v)) return std::abs(to_double(v)); return static_cast<int64_t>(std::abs(to_int(v))); }},
        {"math_floor", [](BallValue i) -> BallValue { return static_cast<int64_t>(std::floor(to_double(extract_unary(i)))); }},
        {"math_ceil", [](BallValue i) -> BallValue { return static_cast<int64_t>(std::ceil(to_double(extract_unary(i)))); }},
        {"math_round", [](BallValue i) -> BallValue { return static_cast<int64_t>(std::round(to_double(extract_unary(i)))); }},
        {"math_trunc", [](BallValue i) -> BallValue { return static_cast<int64_t>(std::trunc(to_double(extract_unary(i)))); }},
        {"math_sqrt", [](BallValue i) -> BallValue { return std::sqrt(to_double(extract_unary(i))); }},
        {"math_pow", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return std::pow(to_double(l),to_double(r)); }},
        {"math_log", [](BallValue i) -> BallValue { return std::log(to_double(extract_unary(i))); }},
        {"math_log2", [](BallValue i) -> BallValue { return std::log2(to_double(extract_unary(i))); }},
        {"math_log10", [](BallValue i) -> BallValue { return std::log10(to_double(extract_unary(i))); }},
        {"math_exp", [](BallValue i) -> BallValue { return std::exp(to_double(extract_unary(i))); }},
        {"math_sin", [](BallValue i) -> BallValue { return std::sin(to_double(extract_unary(i))); }},
        {"math_cos", [](BallValue i) -> BallValue { return std::cos(to_double(extract_unary(i))); }},
        {"math_tan", [](BallValue i) -> BallValue { return std::tan(to_double(extract_unary(i))); }},
        {"math_asin", [](BallValue i) -> BallValue { return std::asin(to_double(extract_unary(i))); }},
        {"math_acos", [](BallValue i) -> BallValue { return std::acos(to_double(extract_unary(i))); }},
        {"math_atan", [](BallValue i) -> BallValue { return std::atan(to_double(extract_unary(i))); }},
        {"math_atan2", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return std::atan2(to_double(l),to_double(r)); }},
        {"math_min", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); if(is_int(l)&&is_int(r)) return std::min(to_int(l),to_int(r)); return std::min(to_double(l),to_double(r)); }},
        {"math_max", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); if(is_int(l)&&is_int(r)) return std::max(to_int(l),to_int(r)); return std::max(to_double(l),to_double(r)); }},
        {"math_clamp", [](BallValue i) -> BallValue {
            auto vv=extract_field(i,"value"); auto mnv=extract_field(i,"min"); auto mxv=extract_field(i,"max");
            // Static method style: math_clamp({value: classRef, min: val, max: lo, arg2: hi})
            // When value is a non-numeric (class reference), treat min as value, max as lower, arg2 as upper.
            if (is_string(vv) && !is_int(vv) && !is_double(vv)) {
                auto real_val = mnv;  // min field holds the actual value
                auto real_min = mxv;  // max field holds the lower bound
                auto real_max = extract_field(i,"arg2"); // arg2 holds the upper bound
                if(is_int(real_val)&&is_int(real_min)&&is_int(real_max)){auto v=to_int(real_val),mn=to_int(real_min),mx=to_int(real_max);return std::max(mn,std::min(v,mx));}
                auto v=to_double(real_val),mn=to_double(real_min),mx=to_double(real_max); return std::max(mn,std::min(v,mx));
            }
            if(is_int(vv)&&is_int(mnv)&&is_int(mxv)){auto v=to_int(vv),mn=to_int(mnv),mx=to_int(mxv);return std::max(mn,std::min(v,mx));}
            auto v=to_double(vv),mn=to_double(mnv),mx=to_double(mxv); return std::max(mn,std::min(v,mx));
        }},
        {"math_pi", [](BallValue) -> BallValue { return 3.141592653589793; }},
        {"math_e", [](BallValue) -> BallValue { return 2.718281828459045; }},
        {"math_infinity", [](BallValue) -> BallValue { return std::numeric_limits<double>::infinity(); }},
        {"math_nan", [](BallValue) -> BallValue { return std::numeric_limits<double>::quiet_NaN(); }},
        {"math_is_nan", [](BallValue i) -> BallValue { return std::isnan(to_double(extract_unary(i))); }},
        {"math_is_finite", [](BallValue i) -> BallValue { return std::isfinite(to_double(extract_unary(i))); }},
        {"math_is_infinite", [](BallValue i) -> BallValue { return std::isinf(to_double(extract_unary(i))); }},
        {"math_sign", [](BallValue i) -> BallValue { auto v=to_double(extract_unary(i)); return v<0.0?-1.0:(v>0.0?1.0:0.0); }},
        {"math_gcd", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return static_cast<int64_t>(std::gcd(to_int(l),to_int(r))); }},
        {"math_lcm", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); auto a=to_int(l),b=to_int(r); return static_cast<int64_t>(std::abs(a*b)/std::gcd(a,b)); }},
        {"map_create", [](BallValue) -> BallValue { return BallMap{}; }},
        {"set_create", [](BallValue i) -> BallValue {
            // Empty {} in Dart is a Map literal. Return BallMap for empty sets.
            auto elems = extract_field(i, "elements");
            if (is_list(elems) && !std::any_cast<const BallList&>(elems).empty())
                return std::any_cast<BallList>(elems);
            return BallMap{};
        }},
        {"record", [](BallValue i) -> BallValue { return i; }},
        {"collection_if", [](BallValue) -> BallValue { return {}; }},
        {"collection_for", [](BallValue) -> BallValue { return {}; }},
        {"switch_expr", [](BallValue) -> BallValue { return {}; }},
        {"symbol", [](BallValue i) -> BallValue { return extract_field(i,"value"); }},
        {"type_literal", [](BallValue i) -> BallValue { return extract_field(i,"type"); }},
        {"labeled", [](BallValue) -> BallValue { return {}; }},
        {"null_aware_access", [](BallValue i) -> BallValue {
            auto t=extract_field(i,"target"); if(!t.has_value()) return {};
            if(is_map(t)) return extract_field(t,ball::to_string(extract_field(i,"field"))); return {};
        }},
        {"null_aware_call", [](BallValue i) -> BallValue { auto t=extract_field(i,"target"); return t.has_value()?t:BallValue{}; }},
    };
}

// ================================================================
// Memory module
// ================================================================

BallValue Engine::eval_memory(const std::string& function, const BallMap& args) {
    auto get_int = [&](const std::string& name) -> int64_t {
        auto it = args.find(name);
        return it != args.end() ? to_int(it->second) : 0;
    };
    if (function == "memory_alloc") {
        int64_t size = get_int("size"); int64_t addr = heap_ptr_;
        heap_ptr_ += size; if (heap_ptr_ > memory_.size()) memory_.resize(heap_ptr_*2, 0);
        return addr;
    }
    if (function == "memory_free") return BallValue{};
    if (function == "memory_realloc") {
        int64_t addr=get_int("address"), ns=get_int("new_size"), na=heap_ptr_;
        heap_ptr_+=ns; if(heap_ptr_>memory_.size()) memory_.resize(heap_ptr_*2,0);
        std::memcpy(&memory_[na],&memory_[addr],std::min(ns,static_cast<int64_t>(memory_.size())-addr));
        return na;
    }
    if (function == "memory_read_u8") return static_cast<int64_t>(memory_[get_int("address")]);
    if (function == "memory_read_i8") return static_cast<int64_t>(static_cast<int8_t>(memory_[get_int("address")]));
    if (function == "memory_read_u16") { uint16_t v; std::memcpy(&v,&memory_[get_int("address")],2); return static_cast<int64_t>(v); }
    if (function == "memory_read_i16") { int16_t v; std::memcpy(&v,&memory_[get_int("address")],2); return static_cast<int64_t>(v); }
    if (function == "memory_read_u32") { uint32_t v; std::memcpy(&v,&memory_[get_int("address")],4); return static_cast<int64_t>(v); }
    if (function == "memory_read_i32") { int32_t v; std::memcpy(&v,&memory_[get_int("address")],4); return static_cast<int64_t>(v); }
    if (function == "memory_read_i64") { int64_t v; std::memcpy(&v,&memory_[get_int("address")],8); return v; }
    if (function == "memory_read_u64") { uint64_t v; std::memcpy(&v,&memory_[get_int("address")],8); return static_cast<int64_t>(v); }
    if (function == "memory_read_f32") { float v; std::memcpy(&v,&memory_[get_int("address")],4); return static_cast<double>(v); }
    if (function == "memory_read_f64") { double v; std::memcpy(&v,&memory_[get_int("address")],8); return v; }
    auto write_val_int = [&]() -> int64_t { auto it=args.find("value"); return it!=args.end()?to_int(it->second):0; };
    auto write_val_dbl = [&]() -> double { auto it=args.find("value"); return it!=args.end()?to_double(it->second):0.0; };
    if (function=="memory_write_u8"||function=="memory_write_i8") { memory_[get_int("address")]=static_cast<uint8_t>(write_val_int()); return {}; }
    if (function=="memory_write_u16"||function=="memory_write_i16") { uint16_t v=static_cast<uint16_t>(write_val_int()); std::memcpy(&memory_[get_int("address")],&v,2); return {}; }
    if (function=="memory_write_u32"||function=="memory_write_i32") { uint32_t v=static_cast<uint32_t>(write_val_int()); std::memcpy(&memory_[get_int("address")],&v,4); return {}; }
    if (function=="memory_write_i64"||function=="memory_write_u64") { int64_t v=write_val_int(); std::memcpy(&memory_[get_int("address")],&v,8); return {}; }
    if (function=="memory_write_f32") { float v=static_cast<float>(write_val_dbl()); std::memcpy(&memory_[get_int("address")],&v,4); return {}; }
    if (function=="memory_write_f64") { double v=write_val_dbl(); std::memcpy(&memory_[get_int("address")],&v,8); return {}; }
    if (function=="memory_copy") { std::memmove(&memory_[get_int("dest")],&memory_[get_int("src")],get_int("size")); return {}; }
    if (function=="memory_set") { std::memset(&memory_[get_int("address")],static_cast<int>(get_int("value")),get_int("size")); return {}; }
    if (function=="memory_compare") { return static_cast<int64_t>(std::memcmp(&memory_[get_int("a")],&memory_[get_int("b")],get_int("size"))); }
    if (function=="ptr_add") return get_int("address")+get_int("offset")*get_int("element_size");
    if (function=="ptr_sub") return get_int("address")-get_int("offset")*get_int("element_size");
    if (function=="ptr_diff") { auto es=get_int("element_size"); return es!=0?(get_int("address")-get_int("offset"))/es:static_cast<int64_t>(0); }
    if (function=="stack_push_frame") { stack_frames_.push_back(stack_ptr_); return {}; }
    if (function=="stack_pop_frame") { if(!stack_frames_.empty()){stack_ptr_=stack_frames_.back();stack_frames_.pop_back();} return {}; }
    if (function=="stack_alloc") { stack_ptr_-=get_int("size"); return static_cast<int64_t>(stack_ptr_); }
    if (function=="memory_sizeof") {
        auto it=args.find("type_name"); if(it!=args.end()){
            auto tn=ball::to_string(it->second);
            if(tn=="int8"||tn=="uint8") return static_cast<int64_t>(1);
            if(tn=="int16"||tn=="uint16") return static_cast<int64_t>(2);
            if(tn=="int32"||tn=="uint32"||tn=="float32") return static_cast<int64_t>(4);
            if(tn=="int64"||tn=="uint64"||tn=="float64") return static_cast<int64_t>(8);
        } return static_cast<int64_t>(0);
    }
    if (function=="address_of") return extract_field(BallValue(args),"value");
    if (function=="deref") return extract_field(BallValue(args),"pointer");
    if (function=="nullptr") return static_cast<int64_t>(0);
    if (function=="memory_heap_size") return static_cast<int64_t>(heap_ptr_);
    if (function=="memory_stack_size") return static_cast<int64_t>(memory_.size()-stack_ptr_);
    throw BallRuntimeError("Unknown std_memory function: \""+function+"\"");
}

// ================================================================
// StdCollectionsModuleHandler
// ================================================================

void StdCollectionsModuleHandler::init(Engine& /*engine*/) {
    using Fn = std::function<BallValue(BallValue, BallCallable)>;

    // ── List operations ──

    dispatch_["list_push"] = [](BallValue input, BallCallable) -> BallValue {
        auto list_val = extract_field(input, "list");
        BallList list;
        if (is_list(list_val)) {
            list = std::any_cast<BallList>(list_val);
        }
        // If list_val is a map (empty set), start with empty list
        list.push_back(extract_field(input, "value"));
        return list;
    };

    dispatch_["list_pop"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        if (list.empty()) throw BallRuntimeError("list_pop: empty list");
        auto last = list.back();
        return last;
    };

    dispatch_["list_insert"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = to_int(extract_field(input, "index"));
        list.insert(list.begin() + idx, extract_field(input, "value"));
        return list;
    };

    dispatch_["list_remove_at"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = to_int(extract_field(input, "index"));
        if (idx < 0 || static_cast<size_t>(idx) >= list.size())
            throw BallRuntimeError("list_remove_at: index out of range");
        auto removed = list[idx];
        list.erase(list.begin() + idx);
        return removed;
    };

    dispatch_["list_get"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = to_int(extract_field(input, "index"));
        if (idx < 0 || static_cast<size_t>(idx) >= list.size())
            throw BallRuntimeError("list_get: index out of range");
        return list[idx];
    };

    dispatch_["list_set"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = to_int(extract_field(input, "index"));
        list[idx] = extract_field(input, "value");
        return list;
    };

    dispatch_["list_length"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        return static_cast<int64_t>(list.size());
    };

    dispatch_["list_is_empty"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        return list.empty();
    };

    dispatch_["list_first"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        if (list.empty()) throw BallRuntimeError("list_first: empty list");
        return list.front();
    };

    dispatch_["list_last"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        if (list.empty()) throw BallRuntimeError("list_last: empty list");
        return list.back();
    };

    dispatch_["list_single"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        if (list.size() != 1) throw BallRuntimeError("list_single: list does not have exactly 1 element");
        return list.front();
    };

    dispatch_["list_contains"] = [](BallValue input, BallCallable) -> BallValue {
        auto list_val = extract_field(input, "list");
        auto target = extract_field(input, "value");
        // String.contains(substring) check.
        if (is_string(list_val)) {
            auto s = std::any_cast<std::string>(list_val);
            auto sub = ball::to_string(target);
            return s.find(sub) != std::string::npos;
        }
        // Handle empty set (stored as BallMap)
        if (is_map(list_val) && !is_list(list_val)) return false;
        BallList list;
        if (is_list(list_val)) list = std::any_cast<BallList>(list_val);
        for (const auto& item : list) {
            if (values_equal(item, target)) return true;
        }
        return false;
    };

    dispatch_["list_index_of"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto target = extract_field(input, "value");
        for (size_t i = 0; i < list.size(); i++) {
            if (values_equal(list[i], target)) return static_cast<int64_t>(i);
        }
        return static_cast<int64_t>(-1);
    };

    dispatch_["list_map"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func_val = extract_field(input, "function");
        if (!func_val.has_value() || !is_function(func_val))
            func_val = extract_field(input, "value");
        auto func = std::any_cast<BallFunction>(func_val);
        BallList result;
        for (const auto& item : list) {
            result.push_back(func(item));
        }
        return result;
    };

    dispatch_["list_filter"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func_val = extract_field(input, "function");
        if (!func_val.has_value() || !is_function(func_val))
            func_val = extract_field(input, "value");
        auto func = std::any_cast<BallFunction>(func_val);
        BallList result;
        for (const auto& item : list) {
            if (to_bool(func(item))) result.push_back(item);
        }
        return result;
    };

    dispatch_["list_reduce"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        auto acc = extract_field(input, "initial");
        for (const auto& item : list) {
            acc = func(BallValue(BallMap{{"accumulator", acc}, {"value", item}}));
        }
        return acc;
    };

    dispatch_["list_find"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        for (const auto& item : list) {
            if (to_bool(func(item))) return item;
        }
        return BallValue{};
    };

    dispatch_["list_any"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        for (const auto& item : list) {
            if (to_bool(func(item))) return true;
        }
        return false;
    };

    dispatch_["list_all"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        for (const auto& item : list) {
            if (!to_bool(func(item))) return false;
        }
        return true;
    };

    dispatch_["list_none"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        for (const auto& item : list) {
            if (to_bool(func(item))) return false;
        }
        return true;
    };

    dispatch_["list_sort"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        // Check for comparator function in "function" or "value" fields.
        auto comp_val = extract_field(input, "function");
        if (!comp_val.has_value() || !is_function(comp_val)) {
            comp_val = extract_field(input, "value");
        }
        if (comp_val.has_value() && is_function(comp_val)) {
            auto comp_fn = std::any_cast<BallFunction>(comp_val);
            std::stable_sort(list.begin(), list.end(), [&comp_fn](const BallValue& a, const BallValue& b) {
                auto result = comp_fn(BallValue(BallMap{{"left", a}, {"right", b}}));
                return to_int(result) < 0;
            });
        } else {
            // Default: sort by numeric value if possible, otherwise by string
            std::stable_sort(list.begin(), list.end(), [](const BallValue& a, const BallValue& b) {
                if ((is_int(a) || is_double(a)) && (is_int(b) || is_double(b))) {
                    return to_num(a) < to_num(b);
                }
                return to_string(a) < to_string(b);
            });
        }
        return list;
    };

    dispatch_["list_sort_by"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        std::sort(list.begin(), list.end(), [&func](const BallValue& a, const BallValue& b) {
            auto va = func(a);
            auto vb = func(b);
            return to_string(va) < to_string(vb);
        });
        return list;
    };

    dispatch_["list_reverse"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        std::reverse(list.begin(), list.end());
        return list;
    };

    dispatch_["list_clear"] = [](BallValue input, BallCallable) -> BallValue {
        return BallList{};
    };

    dispatch_["list_slice"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        // Support both named (start/end) and positional (arg0/arg1 or value) fields
        auto start_val = extract_field(input, "start");
        if (!start_val.has_value()) start_val = extract_field(input, "arg0");
        if (!start_val.has_value()) start_val = extract_field(input, "value");
        auto end_val = extract_field(input, "end");
        if (!end_val.has_value()) end_val = extract_field(input, "arg1");
        int64_t start = start_val.has_value() ? to_int(start_val) : 0;
        int64_t end = end_val.has_value() ? to_int(end_val) : static_cast<int64_t>(list.size());
        if (start < 0) start = 0;
        if (end > static_cast<int64_t>(list.size())) end = static_cast<int64_t>(list.size());
        if (start > end) return BallList{};
        return BallList(list.begin() + start, list.begin() + end);
    };

    dispatch_["list_take"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto count = to_int(extract_field(input, "count"));
        auto n = std::min(static_cast<size_t>(count), list.size());
        return BallList(list.begin(), list.begin() + n);
    };

    dispatch_["list_drop"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto count = to_int(extract_field(input, "count"));
        auto n = std::min(static_cast<size_t>(count), list.size());
        return BallList(list.begin() + n, list.end());
    };

    dispatch_["list_concat"] = [](BallValue input, BallCallable) -> BallValue {
        auto a = std::any_cast<BallList>(extract_field(input, "left"));
        auto b = std::any_cast<BallList>(extract_field(input, "right"));
        a.insert(a.end(), b.begin(), b.end());
        return a;
    };

    dispatch_["list_flat_map"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        BallList result;
        for (const auto& item : list) {
            auto sub = func(item);
            if (is_list(sub)) {
                const auto& sub_list = std::any_cast<const BallList&>(sub);
                result.insert(result.end(), sub_list.begin(), sub_list.end());
            } else {
                result.push_back(sub);
            }
        }
        return result;
    };

    dispatch_["list_zip"] = [](BallValue input, BallCallable) -> BallValue {
        auto a = std::any_cast<BallList>(extract_field(input, "left"));
        auto b = std::any_cast<BallList>(extract_field(input, "right"));
        BallList result;
        auto len = std::min(a.size(), b.size());
        for (size_t i = 0; i < len; i++) {
            result.push_back(BallList{a[i], b[i]});
        }
        return result;
    };

    dispatch_["string_join"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto sep = to_string(extract_field(input, "separator"));
        std::string result;
        for (size_t i = 0; i < list.size(); i++) {
            if (i > 0) result += sep;
            result += to_string(list[i]);
        }
        return result;
    };

    dispatch_["list_join"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto sep_val = extract_field(input, "separator");
        std::string sep = sep_val.has_value() ? to_string(sep_val) : "";
        std::string result;
        for (size_t i = 0; i < list.size(); i++) {
            if (i > 0) result += sep;
            result += to_string(list[i]);
        }
        return result;
    };


    // ── Map operations ──

    dispatch_["map_get"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        auto key = to_string(extract_field(input, "key"));
        auto it = map.find(key);
        return it != map.end() ? it->second : BallValue{};
    };

    dispatch_["map_set"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        auto key = to_string(extract_field(input, "key"));
        map[key] = extract_field(input, "value");
        return map;
    };

    dispatch_["map_delete"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        auto key = to_string(extract_field(input, "key"));
        map.erase(key);
        return map;
    };

    dispatch_["map_contains_key"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        auto key = to_string(extract_field(input, "key"));
        return map.count(key) > 0;
    };

    dispatch_["map_keys"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        BallList keys;
        for (const auto& [k, v] : map) keys.push_back(std::string(k));
        return keys;
    };

    dispatch_["map_values"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        BallList values;
        for (const auto& [k, v] : map) values.push_back(v);
        return values;
    };

    dispatch_["map_entries"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        BallList entries;
        for (const auto& [k, v] : map) {
            entries.push_back(BallMap{{"key", std::string(k)}, {"value", v}});
        }
        return entries;
    };

    dispatch_["map_from_entries"] = [](BallValue input, BallCallable) -> BallValue {
        auto entries_val = extract_field(input, "entries");
        if (!is_list(entries_val)) entries_val = extract_field(input, "arg0");
        if (!is_list(entries_val)) return BallMap{};
        auto entries = std::any_cast<BallList>(entries_val);
        BallMap result;
        for (const auto& entry : entries) {
            if (is_map(entry)) {
                const auto& e = std::any_cast<const BallMap&>(entry);
                auto ki = e.find("key");
                if (ki == e.end()) ki = e.find("arg0");
                if (ki == e.end()) ki = e.find("name");
                auto vi = e.find("value");
                if (vi == e.end()) vi = e.find("arg1");
                if (ki != e.end() && vi != e.end()) {
                    result[to_string(ki->second)] = vi->second;
                }
            }
        }
        return result;
    };

    dispatch_["map_merge"] = [](BallValue input, BallCallable) -> BallValue {
        auto a = std::any_cast<BallMap>(extract_field(input, "left"));
        auto b = std::any_cast<BallMap>(extract_field(input, "right"));
        for (const auto& [k, v] : b) a[k] = v;
        return a;
    };

    dispatch_["map_map"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        BallMap result;
        for (const auto& [k, v] : map) {
            auto mapped = func(BallValue(BallMap{{"key", std::string(k)}, {"value", v}}));
            if (is_map(mapped)) {
                const auto& m = std::any_cast<const BallMap&>(mapped);
                auto ki = m.find("key");
                auto vi = m.find("value");
                if (ki != m.end() && vi != m.end()) {
                    result[to_string(ki->second)] = vi->second;
                }
            }
        }
        return result;
    };

    dispatch_["map_filter"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        BallMap result;
        for (const auto& [k, v] : map) {
            if (to_bool(func(BallValue(BallMap{{"key", std::string(k)}, {"value", v}})))) {
                result[k] = v;
            }
        }
        return result;
    };

    dispatch_["map_is_empty"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        return map.empty();
    };

    dispatch_["map_length"] = [](BallValue input, BallCallable) -> BallValue {
        auto map = std::any_cast<BallMap>(extract_field(input, "map"));
        return static_cast<int64_t>(map.size());
    };

    // Also support the stubs that were in std dispatch
    dispatch_["map_create"] = [](BallValue, BallCallable) -> BallValue { return BallMap{}; };
    dispatch_["set_create"] = [](BallValue input, BallCallable) -> BallValue {
        auto elems = extract_field(input, "elements");
        if (is_list(elems)) {
            const auto& lst = std::any_cast<const BallList&>(elems);
            // Non-empty elements → set (backed by BallList)
            if (!lst.empty()) return std::any_cast<BallList>(elems);
        }
        // Empty `{}` in Dart is a Map literal, not a Set literal.
        // When elements is empty, return BallMap so that map operations
        // (index, containsKey, assign-via-index) work correctly.
        return BallMap{};
    };

    dispatch_["list_foreach"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list_val = extract_field(input, "list");
        // The callback may be in "function" or "value" field depending on encoding.
        auto func_val = extract_field(input, "function");
        if (!func_val.has_value() || !is_function(func_val)) {
            func_val = extract_field(input, "value");
        }
        auto func = std::any_cast<BallFunction>(func_val);
        if (is_list(list_val)) {
            for (const auto& item : std::any_cast<const BallList&>(list_val)) {
                func(item);
            }
        } else if (is_map(list_val)) {
            // Iterate over map entries as {key, value} pairs.
            const auto& m = std::any_cast<const BallMap&>(list_val);
            for (const auto& [k, v] : m) {
                func(BallValue(BallMap{{"key", std::string(k)}, {"value", v}}));
            }
        }
        return {};
    };

    dispatch_["list_to_list"] = [](BallValue input, BallCallable) -> BallValue {
        auto set_val = extract_field(input, "set");
        if (is_list(set_val)) return set_val;
        // Also check "list" field (some encoders use "list" instead of "set")
        auto list_val = extract_field(input, "list");
        if (is_list(list_val)) return list_val;
        // Direct list input (no wrapping map)
        if (is_list(input)) return input;
        // If it's a map (empty set created as map), return empty list
        return BallList{};
    };

    dispatch_["list_generate"] = [](BallValue input, BallCallable engine) -> BallValue {
        // Encoders disagree on the field names: legacy uses count/function,
        // Dart's List.generate maps to length/generator. Accept both.
        auto count = to_int(extract_field(input, "count"));
        if (count == 0) count = to_int(extract_field(input, "length"));
        auto fn_val = extract_field(input, "function");
        if (!fn_val.has_value()) fn_val = extract_field(input, "generator");
        auto func = std::any_cast<BallFunction>(fn_val);
        BallList result;
        for (int64_t i = 0; i < count; i++) {
            result.push_back(func(BallValue(i)));
        }
        return result;
    };

    dispatch_["list_filled"] = [](BallValue input, BallCallable) -> BallValue {
        // Encoders disagree on the count field name: `count` (legacy) and
        // `length` (Dart's List.filled signature). Accept either.
        auto count = to_int(extract_field(input, "count"));
        if (count == 0) count = to_int(extract_field(input, "length"));
        auto value = extract_field(input, "value");
        BallList result;
        result.reserve(count > 0 ? static_cast<size_t>(count) : 0);
        for (int64_t i = 0; i < count; i++) {
            result.push_back(value);
        }
        return result;
    };

    // ── Set operations (using sorted BallList as backing store) ──

    // Helper: extract set as BallList (handles empty maps from set_create)
    auto extract_set = [](const BallValue& input) -> BallList {
        auto set_val = extract_field(input, "set");
        if (is_list(set_val)) return std::any_cast<BallList>(set_val);
        // Empty set created as BallMap -> return empty BallList
        return BallList{};
    };

    dispatch_["set_add"] = [extract_set](BallValue input, BallCallable) -> BallValue {
        auto set = extract_set(input);
        auto val = extract_field(input, "value");
        for (const auto& item : set) {
            if (values_equal(item, val)) return BallValue(set);
        }
        set.push_back(val);
        return set;
    };

    dispatch_["set_remove"] = [extract_set](BallValue input, BallCallable) -> BallValue {
        auto set = extract_set(input);
        auto val = extract_field(input, "value");
        set.erase(std::remove_if(set.begin(), set.end(), [&val](const BallValue& v) {
            return values_equal(v, val);
        }), set.end());
        return set;
    };

    dispatch_["set_contains"] = [extract_set](BallValue input, BallCallable) -> BallValue {
        auto set = extract_set(input);
        auto val = extract_field(input, "value");
        for (const auto& item : set) {
            if (values_equal(item, val)) return true;
        }
        return false;
    };

    dispatch_["set_union"] = [](BallValue input, BallCallable) -> BallValue {
        auto left = std::any_cast<BallList>(extract_field(input, "left"));
        auto right = std::any_cast<BallList>(extract_field(input, "right"));
        for (const auto& val : right) {
            bool found = false;
            for (const auto& item : left) {
                if (values_equal(item, val)) { found = true; break; }
            }
            if (!found) left.push_back(val);
        }
        return left;
    };

    dispatch_["set_intersection"] = [](BallValue input, BallCallable) -> BallValue {
        auto left = std::any_cast<BallList>(extract_field(input, "left"));
        auto right = std::any_cast<BallList>(extract_field(input, "right"));
        BallList result;
        for (const auto& val : left) {
            for (const auto& r : right) {
                if (values_equal(val, r)) { result.push_back(val); break; }
            }
        }
        return result;
    };

    dispatch_["set_difference"] = [](BallValue input, BallCallable) -> BallValue {
        auto left = std::any_cast<BallList>(extract_field(input, "left"));
        auto right = std::any_cast<BallList>(extract_field(input, "right"));
        BallList result;
        for (const auto& val : left) {
            bool found = false;
            for (const auto& r : right) {
                if (values_equal(val, r)) { found = true; break; }
            }
            if (!found) result.push_back(val);
        }
        return result;
    };

    dispatch_["set_length"] = [extract_set](BallValue input, BallCallable) -> BallValue {
        auto set = extract_set(input);
        return static_cast<int64_t>(set.size());
    };

    dispatch_["set_is_empty"] = [extract_set](BallValue input, BallCallable) -> BallValue {
        auto set = extract_set(input);
        return set.empty();
    };

    dispatch_["set_to_list"] = [](BallValue input, BallCallable) -> BallValue {
        return std::any_cast<BallList>(extract_field(input, "set"));
    };
    dispatch_["compare_to"] = [](BallValue input, BallCallable) -> BallValue {
        auto [l,r] = extract_binary(input);
        // Also accept value/other field names (used by Dart encoder)
        if (!l.has_value()) l = extract_field(input, "value");
        if (!r.has_value()) r = extract_field(input, "other");
        // Also accept self/arg0 (method-style compareTo call)
        if (!l.has_value()) l = extract_field(input, "self");
        if (!r.has_value()) r = extract_field(input, "arg0");
        if (is_string(l) && is_string(r)) {
            const auto& ls = std::any_cast<const std::string&>(l);
            const auto& rs = std::any_cast<const std::string&>(r);
            return static_cast<int64_t>(ls < rs ? -1 : (ls > rs ? 1 : 0));
        }
        double ld = to_num(l), rd = to_num(r);
        return static_cast<int64_t>(ld < rd ? -1 : (ld > rd ? 1 : 0));
    };
}

// ================================================================
// StdIoModuleHandler
// ================================================================

BallValue StdIoModuleHandler::call(const std::string& function, BallValue input, BallCallable engine) {
    if (function == "print_error") {
        std::cerr << to_string(extract_field(input, "message")) << std::endl;
        return {};
    }
    if (function == "read_line") {
        std::string line;
        std::getline(std::cin, line);
        return line;
    }
    if (function == "exit") {
        auto code = extract_field(input, "code");
        int exit_code = code.has_value() ? static_cast<int>(std::any_cast<int64_t>(code)) : 0;
        std::exit(exit_code);
    }
    if (function == "panic") {
        auto msg = to_string(extract_field(input, "message"));
        std::cerr << msg << std::endl;
        std::exit(1);
    }
    if (function == "sleep_ms") {
        auto ms = std::any_cast<int64_t>(extract_field(input, "milliseconds"));
        std::this_thread::sleep_for(std::chrono::milliseconds(ms));
        return {};
    }
    if (function == "timestamp_ms") {
        auto now = std::chrono::system_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
        return static_cast<int64_t>(ms);
    }
    if (function == "random_int") {
        auto min = std::any_cast<int64_t>(extract_field(input, "min"));
        auto max = std::any_cast<int64_t>(extract_field(input, "max"));
        static std::mt19937_64 rng(std::random_device{}());
        std::uniform_int_distribution<int64_t> dist(min, max);
        return dist(rng);
    }
    if (function == "random_double") {
        static std::mt19937_64 rng(std::random_device{}());
        std::uniform_real_distribution<double> dist(0.0, 1.0);
        return dist(rng);
    }
    if (function == "env_get") {
        auto name = to_string(extract_field(input, "name"));
        const char* val = std::getenv(name.c_str());
        return val ? BallValue(std::string(val)) : BallValue{};
    }
    if (function == "args_get") {
        // Not available in embedded engine (no argc/argv access)
        return BallList{};
    }
    throw BallRuntimeError("Unknown std_io function: \"" + function + "\"");
}

// ================================================================
// std_convert module
// ================================================================

BallValue Engine::eval_convert(const std::string& function, BallValue input) {
    if (function == "json_encode") {
        // Simple JSON encoding (handles primitives, strings, lists, maps)
        auto val = is_map(input) ? extract_field(input, "value") : input;
        return json_encode_value(val);
    }
    if (function == "json_decode") {
        auto str = is_map(input) ? ball::to_string(extract_field(input, "value"))
                                 : ball::to_string(input);
        return json_decode_string(str);
    }
    if (function == "utf8_encode") {
        auto str = is_map(input) ? ball::to_string(extract_field(input, "value"))
                                 : ball::to_string(input);
        BallList bytes;
        for (unsigned char c : str) bytes.push_back(static_cast<int64_t>(c));
        return bytes;
    }
    if (function == "utf8_decode") {
        BallList bytes;
        if (is_map(input)) {
            auto v = extract_field(input, "value");
            if (is_list(v)) bytes = std::any_cast<BallList>(v);
        }
        std::string result;
        for (const auto& b : bytes) result += static_cast<char>(to_int(b));
        return result;
    }
    if (function == "base64_encode") {
        BallList bytes;
        if (is_map(input)) {
            auto v = extract_field(input, "value");
            if (is_list(v)) bytes = std::any_cast<BallList>(v);
        }
        static const char* b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string result;
        int val = 0, valb = -6;
        for (const auto& b : bytes) {
            val = (val << 8) + static_cast<int>(to_int(b));
            valb += 8;
            while (valb >= 0) { result += b64[(val >> valb) & 0x3F]; valb -= 6; }
        }
        if (valb > -6) result += b64[((val << 8) >> (valb + 8)) & 0x3F];
        while (result.size() % 4) result += '=';
        return result;
    }
    if (function == "base64_decode") {
        auto str = is_map(input) ? ball::to_string(extract_field(input, "value"))
                                 : ball::to_string(input);
        static const int T[256] = {
            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
            0,0,0,0,0,0,0,0,0,0,0,62,0,0,0,63,52,53,54,55,56,57,58,59,60,61,0,0,
            0,0,0,0,0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,
            23,24,25,0,0,0,0,0,0,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,
            42,43,44,45,46,47,48,49,50,51
        };
        BallList bytes;
        int val = 0, valb = -8;
        for (char c : str) {
            if (c == '=') break;
            val = (val << 6) + T[static_cast<unsigned char>(c)];
            valb += 6;
            if (valb >= 0) {
                bytes.push_back(static_cast<int64_t>((val >> valb) & 0xFF));
                valb -= 8;
            }
        }
        return bytes;
    }
    throw BallRuntimeError("Unknown std_convert function: \"" + function + "\"");
}

std::string Engine::json_encode_value(const BallValue& val) {
    if (!val.has_value()) return "null";
    if (is_bool(val)) return std::any_cast<bool>(val) ? "true" : "false";
    if (is_int(val)) return std::to_string(std::any_cast<int64_t>(val));
    if (is_double(val)) return std::to_string(std::any_cast<double>(val));
    if (is_string(val)) {
        auto s = std::any_cast<std::string>(val);
        std::string r = "\"";
        for (char c : s) {
            if (c == '"') r += "\\\"";
            else if (c == '\\') r += "\\\\";
            else if (c == '\n') r += "\\n";
            else if (c == '\r') r += "\\r";
            else if (c == '\t') r += "\\t";
            else r += c;
        }
        r += "\"";
        return r;
    }
    if (is_list(val)) {
        auto lst = std::any_cast<BallList>(val);
        std::string r = "[";
        for (size_t i = 0; i < lst.size(); ++i) {
            if (i > 0) r += ",";
            r += json_encode_value(lst[i]);
        }
        r += "]";
        return r;
    }
    if (is_map(val)) {
        auto m = std::any_cast<BallMap>(val);
        std::string r = "{";
        bool first = true;
        for (const auto& [k, v] : m) {
            if (k.rfind("__", 0) == 0) continue; // skip internal keys
            if (!first) r += ",";
            r += "\"" + k + "\":" + json_encode_value(v);
            first = false;
        }
        r += "}";
        return r;
    }
    return "null";
}

BallValue Engine::json_decode_string(const std::string& str) {
    // Minimal JSON decoder for primitives and strings
    auto trimmed = str;
    while (!trimmed.empty() && std::isspace(trimmed.front())) trimmed.erase(trimmed.begin());
    while (!trimmed.empty() && std::isspace(trimmed.back())) trimmed.pop_back();
    if (trimmed == "null") return BallValue{};
    if (trimmed == "true") return true;
    if (trimmed == "false") return false;
    if (!trimmed.empty() && trimmed.front() == '"' && trimmed.back() == '"') {
        return trimmed.substr(1, trimmed.size() - 2);
    }
    // Try int then double
    try { return static_cast<int64_t>(std::stoll(trimmed)); } catch (...) {}
    try { return std::stod(trimmed); } catch (...) {}
    return BallValue(trimmed);
}

// ================================================================
// std_fs module
// ================================================================

BallValue Engine::eval_fs(const std::string& function, BallValue input) {
    auto get_path = [&]() -> std::string {
        return is_map(input) ? ball::to_string(extract_field(input, "path"))
                             : ball::to_string(input);
    };

    if (function == "file_read") {
        std::ifstream f(get_path());
        if (!f) throw BallRuntimeError("file_read: cannot open file");
        return std::string(std::istreambuf_iterator<char>(f), {});
    }
    if (function == "file_read_bytes") {
        std::ifstream f(get_path(), std::ios::binary);
        if (!f) throw BallRuntimeError("file_read_bytes: cannot open file");
        BallList bytes;
        char c;
        while (f.get(c)) bytes.push_back(static_cast<int64_t>(static_cast<unsigned char>(c)));
        return bytes;
    }
    if (function == "file_write") {
        auto path = is_map(input) ? ball::to_string(extract_field(input, "path")) : "";
        auto content = is_map(input) ? ball::to_string(extract_field(input, "content")) : "";
        std::ofstream f(path);
        if (!f) throw BallRuntimeError("file_write: cannot open file");
        f << content;
        return BallValue{};
    }
    if (function == "file_write_bytes") {
        auto path = is_map(input) ? ball::to_string(extract_field(input, "path")) : "";
        BallList bytes;
        if (is_map(input)) {
            auto v = extract_field(input, "content");
            if (is_list(v)) bytes = std::any_cast<BallList>(v);
        }
        std::ofstream f(path, std::ios::binary);
        for (const auto& b : bytes) f.put(static_cast<char>(to_int(b)));
        return BallValue{};
    }
    if (function == "file_append") {
        auto path = is_map(input) ? ball::to_string(extract_field(input, "path")) : "";
        auto content = is_map(input) ? ball::to_string(extract_field(input, "content")) : "";
        std::ofstream f(path, std::ios::app);
        if (!f) throw BallRuntimeError("file_append: cannot open file");
        f << content;
        return BallValue{};
    }
    if (function == "file_exists") {
        return std::filesystem::exists(get_path());
    }
    if (function == "file_delete") {
        std::filesystem::remove(get_path());
        return BallValue{};
    }
    if (function == "dir_list") {
        BallList entries;
        for (const auto& entry : std::filesystem::directory_iterator(get_path())) {
            entries.push_back(entry.path().string());
        }
        return entries;
    }
    if (function == "dir_create") {
        std::filesystem::create_directories(get_path());
        return BallValue{};
    }
    if (function == "dir_exists") {
        return std::filesystem::is_directory(get_path());
    }
    throw BallRuntimeError("Unknown std_fs function: \"" + function + "\"");
}

// ================================================================
// std_time module
// ================================================================

BallValue Engine::eval_time(const std::string& function, BallValue input) {
    using namespace std::chrono;

    if (function == "now") {
        auto ms = duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
        return static_cast<int64_t>(ms);
    }
    if (function == "now_micros") {
        auto us = duration_cast<microseconds>(system_clock::now().time_since_epoch()).count();
        return static_cast<int64_t>(us);
    }
    if (function == "format_timestamp") {
        int64_t ms = 0;
        if (is_map(input)) ms = to_int(extract_field(input, "timestamp_ms"));
        auto tp = system_clock::time_point(milliseconds(ms));
        auto tt = system_clock::to_time_t(tp);
        struct tm tm_buf;
#ifdef _WIN32
        gmtime_s(&tm_buf, &tt);
#else
        gmtime_r(&tt, &tm_buf);
#endif
        char buf[64];
        std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tm_buf);
        // Append fractional milliseconds + 'Z' suffix to match Dart's
        // DateTime.toIso8601String() format.
        char out[80];
        std::snprintf(out, sizeof(out), "%s.%03lldZ", buf,
                      static_cast<long long>(((ms % 1000) + 1000) % 1000));
        return std::string(out);
    }
    if (function == "parse_timestamp") {
        auto str = is_map(input) ? ball::to_string(extract_field(input, "value")) : "";
        struct tm tm_buf = {};
        // Basic ISO 8601 parse: YYYY-MM-DDTHH:MM:SSZ
        sscanf(str.c_str(), "%d-%d-%dT%d:%d:%d",
               &tm_buf.tm_year, &tm_buf.tm_mon, &tm_buf.tm_mday,
               &tm_buf.tm_hour, &tm_buf.tm_min, &tm_buf.tm_sec);
        tm_buf.tm_year -= 1900;
        tm_buf.tm_mon -= 1;
#ifdef _WIN32
        auto tt = _mkgmtime(&tm_buf);
#else
        auto tt = timegm(&tm_buf);
#endif
        return static_cast<int64_t>(tt * 1000);
    }
    if (function == "duration_add") {
        auto [l, r] = extract_binary(input);
        return to_int(l) + to_int(r);
    }
    if (function == "duration_subtract") {
        auto [l, r] = extract_binary(input);
        return to_int(l) - to_int(r);
    }
    if (function == "year" || function == "month" || function == "day" ||
        function == "hour" || function == "minute" || function == "second") {
        auto now = system_clock::now();
        auto tt = system_clock::to_time_t(now);
        struct tm tm_buf;
#ifdef _WIN32
        gmtime_s(&tm_buf, &tt);
#else
        gmtime_r(&tt, &tm_buf);
#endif
        if (function == "year") return static_cast<int64_t>(tm_buf.tm_year + 1900);
        if (function == "month") return static_cast<int64_t>(tm_buf.tm_mon + 1);
        if (function == "day") return static_cast<int64_t>(tm_buf.tm_mday);
        if (function == "hour") return static_cast<int64_t>(tm_buf.tm_hour);
        if (function == "minute") return static_cast<int64_t>(tm_buf.tm_min);
        return static_cast<int64_t>(tm_buf.tm_sec);
    }
    throw BallRuntimeError("Unknown std_time function: \"" + function + "\"");
}

BallValue Engine::eval_cpp_scope_exit(const ball::v1::FunctionCall& call,
                                       std::shared_ptr<Scope> scope) {
    if (!call.has_input()) return {};
    const auto& input_expr = call.input();
    if (input_expr.expr_case() != ball::v1::Expression::kMessageCreation) return {};

    // Find the `cleanup` field expression without evaluating it.
    for (const auto& field : input_expr.message_creation().fields()) {
        if (field.name() == "cleanup") {
            scope->register_scope_exit(field.value(), scope);
            return {};
        }
    }
    return {};
}

}  // namespace ball
