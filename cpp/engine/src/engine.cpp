// ball::Engine — full C++ implementation.
//
// Faithful port of the Dart BallEngine: expression tree walking,
// lexical scoping, lazy control flow, full std dispatch, and
// linear memory simulation.

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

    build_lookup_tables();
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
    if (!func.has_body()) return {};

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
            scope->bind(params[0], input);
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
        scope->bind("input", input);
    }

    auto result = eval_expr(func.body(), scope);
    current_module_ = prev_module;
    if (is_flow(result) && as_flow(result).kind == "return") {
        result = as_flow(result).value;
    }

    // Check for async/generator metadata
    bool is_async_fn = false;
    bool is_generator_fn = false;
    if (func.has_metadata()) {
        auto ait = func.metadata().fields().find("is_async");
        if (ait != func.metadata().fields().end()) is_async_fn = ait->second.bool_value();
        auto git = func.metadata().fields().find("is_generator");
        if (git != func.metadata().fields().end()) is_generator_fn = git->second.bool_value();
    }

    // Wrap async returns in BallFuture
    if (is_async_fn && !is_future(result)) {
        return BallFuture{result, true};
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
    for (const auto& m : program_.modules()) {
        for (const auto& f : m.functions()) {
            if (f.name() == function) {
                return call_function_internal(m.name(), f, std::move(input));
            }
        }
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
    throw BallRuntimeError("Function \"" + key + "\" not found");
}

BallValue Engine::call_base_function(const std::string& module,
                                     const std::string& function,
                                     BallValue input) {
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
    return scope->lookup(ref.name());
}

BallValue Engine::eval_field_access(const ball::v1::FieldAccess& access, std::shared_ptr<Scope> scope) {
    auto object = eval_expr(access.object(), scope);
    const auto& field = access.field();

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
            return vals;
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
        fields[pair.name()] = eval_expr(pair.value(), scope);
    if (!msg.type_name().empty()) {
        fields["__type__"] = msg.type_name();
        // Check for superclass via type definitions.
        for (const auto& mod : program_.modules()) {
            for (const auto& td : mod.type_defs()) {
                if (td.name() == msg.type_name()) {
                    if (td.has_metadata()) {
                        auto sc_it = td.metadata().fields().find("superclass");
                        if (sc_it != td.metadata().fields().end() &&
                            !sc_it->second.string_value().empty()) {
                            BallMap super_fields;
                            super_fields["__type__"] = sc_it->second.string_value();
                            fields["__super__"] = super_fields;
                        }
                    }
                    break;
                }
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
    BallFunction closure = [this, func_copy, captured](BallValue input) -> BallValue {
        auto lambda_scope = std::make_shared<Scope>(captured);
        lambda_scope->bind("input", input);
        if (is_map(input)) {
            const auto& m = std::any_cast<const BallMap&>(input);
            for (const auto& [k, v] : m)
                if (k != "__type__") lambda_scope->bind(k, v);
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
        if (init_it->second.expr_case() == ball::v1::Expression::kBlock) {
            for (const auto& stmt : init_it->second.block().statements())
                eval_statement(stmt, for_scope);
        } else {
            eval_expr(init_it->second, for_scope);
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
    for (const auto& cx : ce.literal().list_value().elements()) {
        if (cx.expr_case() != ball::v1::Expression::kMessageCreation) continue;
        std::unordered_map<std::string, const ball::v1::Expression*> cf;
        for (const auto& f : cx.message_creation().fields()) cf[f.name()] = &f.value();
        auto di = cf.find("is_default");
        if (di != cf.end() && di->second->expr_case() == ball::v1::Expression::kLiteral &&
            di->second->literal().bool_value()) {
            auto bi = cf.find("body"); if (bi != cf.end()) def = bi->second; continue;
        }
        // Pattern matching: check for 'pattern' field
        auto pi = cf.find("pattern");
        if (pi != cf.end()) {
            auto pattern_val = eval_expr(*pi->second, scope);
            BallMap bindings;
            if (match_pattern(sub_val, pattern_val, bindings)) {
                // Check guard
                auto gi = cf.find("guard");
                if (gi != cf.end()) {
                    auto guard_scope = std::make_shared<Scope>(scope);
                    for (auto& [k, v] : bindings) guard_scope->bind(k, v);
                    if (!to_bool(eval_expr(*gi->second, guard_scope))) continue;
                }
                auto bi = cf.find("body");
                if (bi != cf.end()) {
                    auto body_scope = std::make_shared<Scope>(scope);
                    for (auto& [k, v] : bindings) body_scope->bind(k, v);
                    return eval_expr(*bi->second, body_scope);
                }
            }
            continue;
        }
        // Value matching
        auto vi = cf.find("value");
        if (vi != cf.end() && values_equal(eval_expr(*vi->second, scope), sub_val)) {
            auto bi = cf.find("body"); if (bi != cf.end()) return eval_expr(*bi->second, scope);
        }
    }
    if (def) return eval_expr(*def, scope);
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
            // Check type match
            auto tit = cf.find("type");
            if (tit != cf.end() && tit->second->expr_case() == ball::v1::Expression::kLiteral) {
                const auto& catch_type = tit->second->literal().string_value();
                if (!catch_type.empty() && catch_type != exception_type) continue;
            }
            std::string var = "e";
            auto vit = cf.find("variable");
            if (vit != cf.end() && vit->second->expr_case() == ball::v1::Expression::kLiteral)
                var = vit->second->literal().string_value();
            auto bit = cf.find("body");
            if (bit != cf.end()) {
                auto cs = std::make_shared<Scope>(scope);
                cs->bind(var, exception_value);
                result = eval_expr(*bit->second, cs);
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
            // No matching catch — try with "Exception" as fallback
            run_catches("Exception", e.value);
        }
    } catch (const std::exception& e) {
        result = {};
        run_catches("Exception", std::string(e.what()));
    }
    if (finally_it != fields.end()) eval_expr(finally_it->second, scope);
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
    auto result = eval_expr(bi->second, scope);
    if (is_flow(result)) {
        auto& sig = std::any_cast<FlowSignal&>(result);
        if ((sig.kind == "break" || sig.kind == "continue") && sig.label == label) {
            return {}; // consumed
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
    auto val = eval_expr(vi->second, scope);
    auto op = string_field_val(fields, "op");
    if (ti->second.expr_case() == ball::v1::Expression::kReference) {
        const auto& name = ti->second.reference().name();
        if (!op.empty() && op != "=") {
            auto computed = apply_compound_op(op, scope->lookup(name), val);
            scope->set(name, computed); return computed;
        }
        scope->set(name, val); return val;
    }
    if (ti->second.expr_case() == ball::v1::Expression::kFieldAccess) {
        auto obj = eval_expr(ti->second.field_access().object(), scope);
        if (is_map(obj)) {
            auto& m = std::any_cast<BallMap&>(obj);
            m[ti->second.field_access().field()] = val;
            return val;
        }
    }
    if (ti->second.expr_case() == ball::v1::Expression::kCall &&
        ti->second.call().module() == "std" && ti->second.call().function() == "index") {
        auto idx_fields = lazy_fields(ti->second.call());
        auto iti = idx_fields.find("target"), ixi = idx_fields.find("index");
        if (iti != idx_fields.end() && ixi != idx_fields.end()) {
            auto lst = eval_expr(iti->second, scope);
            auto idx = eval_expr(ixi->second, scope);
            if (is_list(lst) && is_int(idx)) {
                std::any_cast<BallList&>(lst)[to_int(idx)] = val; return val;
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
    int64_t v = to_int(eval_expr(vi->second, scope));
    return is_inc ? v + 1 : v - 1;
}

BallValue Engine::apply_compound_op(const std::string& op, BallValue current, BallValue val) {
    bool both_int = is_int(current) && is_int(val);
    if (op == "+=") { if (both_int) return to_int(current) + to_int(val); return to_num(current) + to_num(val); }
    if (op == "-=") { if (both_int) return to_int(current) - to_int(val); return to_num(current) - to_num(val); }
    if (op == "*=") { if (both_int) return to_int(current) * to_int(val); return to_num(current) * to_num(val); }
    if (op == "/=") { auto d = to_num(val); if (d == 0.0) return static_cast<int64_t>(0); if (both_int) return to_int(current) / to_int(val); return to_num(current) / d; }
    if (op == "%=") return to_int(current) % to_int(val);
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
                if (msg.has_value()) { stdout_fn(ball::to_string(msg)); return {}; }
            }
            stdout_fn(ball::to_string(input)); return {};
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
        {"modulo", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); if(is_double(l)||is_double(r)) return std::fmod(to_double(l),to_double(r)); return to_int(l)%to_int(r); }},
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
        {"concat", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return ball::to_string(l)+ball::to_string(r); }},
        {"to_string", [](BallValue i) -> BallValue { return ball::to_string(extract_unary(i)); }},
        {"length", [](BallValue i) -> BallValue {
            auto v=extract_unary(i);
            if(is_string(v)) return static_cast<int64_t>(std::any_cast<std::string>(v).size());
            if(is_list(v)) return static_cast<int64_t>(std::any_cast<BallList>(v).size());
            return static_cast<int64_t>(0);
        }},
        {"int_to_string", [](BallValue i) -> BallValue { return std::to_string(to_int(extract_unary(i))); }},
        {"double_to_string", [](BallValue i) -> BallValue { return std::to_string(to_double(extract_unary(i))); }},
        {"string_to_int", [](BallValue i) -> BallValue { return static_cast<int64_t>(std::stoll(ball::to_string(extract_unary(i)))); }},
        {"string_to_double", [](BallValue i) -> BallValue { return std::stod(ball::to_string(extract_unary(i))); }},
        {"string_interpolation", [](BallValue i) -> BallValue {
            if(is_map(i)){auto p=extract_field(i,"parts");if(is_list(p)){std::string r;for(auto&x:std::any_cast<BallList>(p))r+=ball::to_string(x);return r;} auto v=extract_field(i,"value");if(v.has_value())return ball::to_string(v);} return ball::to_string(i);
        }},
        {"null_coalesce", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return l.has_value()?l:r; }},
        {"null_check", [](BallValue i) -> BallValue { return extract_unary(i); }},
        {"is", [](BallValue i) -> BallValue {
            if(!is_map(i)) return false; auto v=extract_field(i,"value"); auto t=ball::to_string(extract_field(i,"type"));
            if(t=="int") return is_int(v); if(t=="double") return is_double(v); if(t=="num") return is_int(v)||is_double(v);
            if(t=="String") return is_string(v); if(t=="bool") return is_bool(v); if(t=="List") return is_list(v);
            if(t=="Map") return is_map(v); if(t=="Null") return is_null(v);
            if(is_map(v)){auto tv=extract_field(v,"__type__"); return is_string(tv)&&std::any_cast<std::string>(tv)==t;} return false;
        }},
        {"is_not", [](BallValue i) -> BallValue {
            if(!is_map(i)) return true; auto v=extract_field(i,"value"); auto t=ball::to_string(extract_field(i,"type"));
            if(t=="int") return !is_int(v); if(t=="double") return !is_double(v); if(t=="String") return !is_string(v); return true;
        }},
        {"as", [](BallValue i) -> BallValue { return extract_unary(i); }},
        {"index", [](BallValue i) -> BallValue {
            auto tgt=extract_field(i,"target"); auto idx=extract_field(i,"index");
            if(is_list(tgt)&&is_int(idx)) return std::any_cast<BallList>(tgt)[to_int(idx)];
            if(is_string(tgt)&&is_int(idx)){auto s=std::any_cast<std::string>(tgt);return std::string(1,s[to_int(idx)]);}
            if(is_map(tgt)&&is_string(idx)) return extract_field(tgt,std::any_cast<std::string>(idx));
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
                auto it = m.find("__type");
                if (it != m.end()) typeName = to_string(it->second);
            }
            throw BallException(typeName, val);
        }},
        {"rethrow", [](BallValue) -> BallValue { throw BallRuntimeError("rethrow"); }},
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
            auto [l,r]=extract_binary(i); auto s=ball::to_string(l); auto d=ball::to_string(r);
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
        {"math_min", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return std::min(to_double(l),to_double(r)); }},
        {"math_max", [](BallValue i) -> BallValue { auto [l,r]=extract_binary(i); return std::max(to_double(l),to_double(r)); }},
        {"math_clamp", [](BallValue i) -> BallValue { auto v=to_double(extract_field(i,"value")); auto mn=to_double(extract_field(i,"min")); auto mx=to_double(extract_field(i,"max")); return std::max(mn,std::min(v,mx)); }},
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
        {"set_create", [](BallValue) -> BallValue { return BallList{}; }},
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
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        list.push_back(extract_field(input, "value"));
        return list;
    };

    dispatch_["list_pop"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        if (list.empty()) throw BallRuntimeError("list_pop: empty list");
        auto last = list.back();
        list.pop_back();
        return BallMap{{"value", last}, {"list", BallValue(list)}};
    };

    dispatch_["list_insert"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = std::any_cast<int64_t>(extract_field(input, "index"));
        list.insert(list.begin() + idx, extract_field(input, "value"));
        return list;
    };

    dispatch_["list_remove_at"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = std::any_cast<int64_t>(extract_field(input, "index"));
        list.erase(list.begin() + idx);
        return list;
    };

    dispatch_["list_get"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = std::any_cast<int64_t>(extract_field(input, "index"));
        if (idx < 0 || static_cast<size_t>(idx) >= list.size())
            throw BallRuntimeError("list_get: index out of range");
        return list[idx];
    };

    dispatch_["list_set"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto idx = std::any_cast<int64_t>(extract_field(input, "index"));
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
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto target = extract_field(input, "value");
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
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
        BallList result;
        for (const auto& item : list) {
            result.push_back(func(item));
        }
        return result;
    };

    dispatch_["list_filter"] = [](BallValue input, BallCallable engine) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto func = std::any_cast<BallFunction>(extract_field(input, "function"));
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
        std::sort(list.begin(), list.end(), [](const BallValue& a, const BallValue& b) {
            return to_string(a) < to_string(b);
        });
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

    dispatch_["list_slice"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto start = std::any_cast<int64_t>(extract_field(input, "start"));
        auto end_val = extract_field(input, "end");
        int64_t end = end_val.has_value() ? std::any_cast<int64_t>(end_val) : static_cast<int64_t>(list.size());
        return BallList(list.begin() + start, list.begin() + end);
    };

    dispatch_["list_take"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto count = std::any_cast<int64_t>(extract_field(input, "count"));
        auto n = std::min(static_cast<size_t>(count), list.size());
        return BallList(list.begin(), list.begin() + n);
    };

    dispatch_["list_drop"] = [](BallValue input, BallCallable) -> BallValue {
        auto list = std::any_cast<BallList>(extract_field(input, "list"));
        auto count = std::any_cast<int64_t>(extract_field(input, "count"));
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
        auto entries = std::any_cast<BallList>(extract_field(input, "entries"));
        BallMap result;
        for (const auto& entry : entries) {
            if (is_map(entry)) {
                const auto& e = std::any_cast<const BallMap&>(entry);
                auto ki = e.find("key");
                auto vi = e.find("value");
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
        if (is_list(elems)) return std::any_cast<BallList>(elems); // sets are lists in C++
        return BallList{};
    };

    // ── Set operations (using sorted BallList as backing store) ──

    dispatch_["set_add"] = [](BallValue input, BallCallable) -> BallValue {
        auto set = std::any_cast<BallList>(extract_field(input, "set"));
        auto val = extract_field(input, "value");
        for (const auto& item : set) {
            if (values_equal(item, val)) return BallValue(set);
        }
        set.push_back(val);
        return set;
    };

    dispatch_["set_remove"] = [](BallValue input, BallCallable) -> BallValue {
        auto set = std::any_cast<BallList>(extract_field(input, "set"));
        auto val = extract_field(input, "value");
        set.erase(std::remove_if(set.begin(), set.end(), [&val](const BallValue& v) {
            return values_equal(v, val);
        }), set.end());
        return set;
    };

    dispatch_["set_contains"] = [](BallValue input, BallCallable) -> BallValue {
        auto set = std::any_cast<BallList>(extract_field(input, "set"));
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

    dispatch_["set_length"] = [](BallValue input, BallCallable) -> BallValue {
        auto set = std::any_cast<BallList>(extract_field(input, "set"));
        return static_cast<int64_t>(set.size());
    };

    dispatch_["set_is_empty"] = [](BallValue input, BallCallable) -> BallValue {
        auto set = std::any_cast<BallList>(extract_field(input, "set"));
        return set.empty();
    };

    dispatch_["set_to_list"] = [](BallValue input, BallCallable) -> BallValue {
        return std::any_cast<BallList>(extract_field(input, "set"));
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
        std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
        return std::string(buf);
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
