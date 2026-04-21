#pragma once

// ball::Engine — interprets and executes ball programs at runtime.
//
// The engine walks the expression tree and evaluates it directly,
// without generating any intermediate source code.
//
// Faithful C++ port of the Dart BallEngine.

#include "ball_shared.h"
#include <algorithm>
#include <functional>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <unordered_map>

namespace ball {

// ================================================================
// Runtime error
// ================================================================

class BallRuntimeError : public std::runtime_error {
public:
    explicit BallRuntimeError(const std::string& msg)
        : std::runtime_error("BallRuntimeError: " + msg) {}
};

/// Typed exception thrown by Ball `throw` expressions.
/// Preserves the type name and original value for typed catch matching.
class BallException : public std::runtime_error {
public:
    std::string typeName;
    BallValue value;
    BallException(const std::string& type, BallValue val)
        : std::runtime_error(type), typeName(type), value(std::move(val)) {}
};

// ================================================================
// Flow signal (break / continue / return)
// ================================================================

struct FlowSignal {
    std::string kind;   // "break", "continue", "return"
    std::string label;
    BallValue value;
};

inline bool is_flow(const BallValue& v) {
    return v.type() == typeid(FlowSignal);
}

inline const FlowSignal& as_flow(const BallValue& v) {
    return std::any_cast<const FlowSignal&>(v);
}

// ================================================================
// Scope — lexical variable binding chain
// ================================================================

class Scope : public std::enable_shared_from_this<Scope> {
public:
    explicit Scope(std::shared_ptr<Scope> parent = nullptr)
        : parent_(std::move(parent)) {}

    BallValue lookup(const std::string& name) const {
        auto it = bindings_.find(name);
        if (it != bindings_.end()) return it->second;
        if (parent_) return parent_->lookup(name);
        throw BallRuntimeError("Undefined variable: \"" + name + "\"");
    }

    void bind(const std::string& name, BallValue value) {
        bindings_[name] = std::move(value);
    }

    bool has(const std::string& name) const {
        if (bindings_.count(name)) return true;
        return parent_ ? parent_->has(name) : false;
    }

    void set(const std::string& name, BallValue value) {
        if (bindings_.count(name)) { bindings_[name] = std::move(value); return; }
        if (parent_ && parent_->has(name)) { parent_->set(name, std::move(value)); return; }
        bindings_[name] = std::move(value);
    }

    /// Register a cleanup expression + its evaluation scope for LIFO execution
    /// when this scope exits (RAII / cpp_scope_exit semantics).
    void register_scope_exit(ball::v1::Expression cleanup, std::shared_ptr<Scope> eval_scope) {
        scope_exits_.emplace_back(std::move(cleanup), std::move(eval_scope));
    }

    /// Return true if any scope-exit cleanups are registered.
    bool has_scope_exits() const { return !scope_exits_.empty(); }

    /// Drain and return scope-exit entries in LIFO order.
    std::vector<std::pair<ball::v1::Expression, std::shared_ptr<Scope>>> take_scope_exits() {
        auto result = std::move(scope_exits_);
        std::reverse(result.begin(), result.end()); // LIFO
        return result;
    }

    std::shared_ptr<Scope> child() {
        return std::make_shared<Scope>(shared_from_this());
    }

    static std::shared_ptr<Scope> create() {
        return std::make_shared<Scope>(nullptr);
    }

private:
    std::unordered_map<std::string, BallValue> bindings_;
    std::shared_ptr<Scope> parent_;
    /// Scope-exit cleanup entries: (cleanup_expr, eval_scope).
    std::vector<std::pair<ball::v1::Expression, std::shared_ptr<Scope>>> scope_exits_;
};

// ================================================================
// Module handler interface
// ================================================================

class BallModuleHandler {
public:
    virtual ~BallModuleHandler() = default;
    virtual bool handles(const std::string& module) const = 0;
    virtual BallValue call(const std::string& function, BallValue input, BallCallable engine) = 0;
    virtual void init(class Engine& /*engine*/) {}
};

// ================================================================
// Engine
// ================================================================

class Engine {
public:
    explicit Engine(const ball::v1::Program& program,
                    std::function<void(const std::string&)> stdout_fn = nullptr);

    BallValue run();

    BallValue call_function(const std::string& module,
                            const std::string& function,
                            BallValue input);

    const std::vector<std::string>& get_output() const { return output_; }

    std::function<void(const std::string&)> stdout_fn;

    // Build the std dispatch table (called by StdModuleHandler::init)
    std::unordered_map<std::string, std::function<BallValue(BallValue)>>
    build_std_dispatch();

private:
    ball::v1::Program program_;
    std::vector<std::string> output_;

    // Lookup tables
    std::unordered_map<std::string, google::protobuf::DescriptorProto> types_;
    std::unordered_map<std::string, const ball::v1::FunctionDefinition*> functions_;
    std::unordered_map<std::string, std::vector<std::string>> param_cache_;

    // Constructor registry: maps bare class names (and "module:Class"
    // qualified names, and "Class.new" / "Class.ctorName" forms) to the
    // constructor function definition. Populated during build_lookup_tables
    // for every function whose metadata has kind == "constructor".
    struct ConstructorEntry {
        std::string module;
        const ball::v1::FunctionDefinition* func;
    };
    std::unordered_map<std::string, ConstructorEntry> constructors_;

    // Enum type registry: maps enum type names (both qualified "module:Enum"
    // and bare "Enum") to a map of value name -> enum value object
    // (BallMap with __type__, name, index fields).
    std::unordered_map<std::string, BallMap> enum_values_;

    std::shared_ptr<Scope> global_scope_;
    std::string current_module_;

    std::vector<std::unique_ptr<BallModuleHandler>> handlers_;

    // Memory simulation
    std::vector<uint8_t> memory_;
    size_t heap_ptr_ = 0;
    size_t stack_ptr_ = 262144;
    std::vector<size_t> stack_frames_;

    void build_lookup_tables();
    void validate_no_unresolved_imports();
    void init_top_level_variables();
    std::vector<std::string> extract_params(const google::protobuf::Struct& metadata);

    BallValue call_function_internal(const std::string& module_name,
                                     const ball::v1::FunctionDefinition& func,
                                     BallValue input);
    BallValue resolve_and_call(const std::string& module,
                               const std::string& function,
                               BallValue input);
    BallValue call_base_function(const std::string& module,
                                 const std::string& function,
                                 BallValue input);

    // Expression evaluation
    BallValue eval_expr(const ball::v1::Expression& expr, std::shared_ptr<Scope> scope);
    BallValue eval_call(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_literal(const ball::v1::Literal& lit, std::shared_ptr<Scope> scope);
    BallValue eval_reference(const ball::v1::Reference& ref, std::shared_ptr<Scope> scope);
    BallValue eval_field_access(const ball::v1::FieldAccess& access, std::shared_ptr<Scope> scope);
    BallValue eval_message_creation(const ball::v1::MessageCreation& msg, std::shared_ptr<Scope> scope);
    BallValue eval_block(const ball::v1::Block& block, std::shared_ptr<Scope> scope);
    BallValue eval_statement(const ball::v1::Statement& stmt, std::shared_ptr<Scope> scope);
    BallValue eval_lambda(const ball::v1::FunctionDefinition& func, std::shared_ptr<Scope> scope);

    // Lazy-evaluated control flow
    std::unordered_map<std::string, ball::v1::Expression> lazy_fields(const ball::v1::FunctionCall& call);
    BallValue eval_lazy_if(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_lazy_for(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_lazy_for_in(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_lazy_while(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_lazy_do_while(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_lazy_switch(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_lazy_try(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_short_circuit_and(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_short_circuit_or(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_return(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_break(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_continue(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_labeled(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_goto(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_label(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_assign(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);
    BallValue eval_inc_dec(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);

    // Mini expression evaluator for legacy for-loop init strings like "i + 1" or "s.length - 1".
    BallValue eval_init_string_expr(const std::string& expr, std::shared_ptr<Scope> scope);

    BallValue eval_memory(const std::string& function, const BallMap& args);
    BallValue eval_convert(const std::string& function, BallValue input);
    BallValue eval_fs(const std::string& function, BallValue input);
    BallValue eval_time(const std::string& function, BallValue input);

    /// Lazy handler for cpp_std.cpp_scope_exit — registers cleanup without
    /// evaluating it, so it runs in LIFO order when the enclosing block exits.
    BallValue eval_cpp_scope_exit(const ball::v1::FunctionCall& call, std::shared_ptr<Scope> scope);

    /// Execute all registered scope-exit cleanups in LIFO order.
    void run_scope_exits(std::shared_ptr<Scope> block_scope);

    // Pattern matching
    bool match_pattern(const BallValue& value, const BallValue& pattern, BallMap& bindings);
    bool match_string_pattern(const BallValue& value, const std::string& pattern, BallMap& bindings);
    bool match_structured_pattern(const BallValue& value, const BallMap& pattern, BallMap& bindings);
    bool matches_type_pattern(const BallValue& value, const std::string& type_name);

    std::string json_encode_value(const BallValue& val);
    BallValue json_decode_string(const std::string& str);

    // OOP dispatch helpers. Return an empty std::optional when no
    // getter/setter/operator is found so callers can fall through to
    // default behavior.
    std::optional<BallValue> try_getter_dispatch(const BallMap& object,
                                                 const std::string& field_name);
    std::optional<BallValue> try_setter_dispatch(const BallMap& object,
                                                 const std::string& field_name,
                                                 BallValue value);
    std::optional<BallValue> try_operator_override(const std::string& function,
                                                   const BallValue& input);
    bool is_getter_fn(const ball::v1::FunctionDefinition& func);
    bool is_setter_fn(const ball::v1::FunctionDefinition& func);

    std::string string_field_val(const std::unordered_map<std::string, ball::v1::Expression>& fields,
                                  const std::string& name);
    BallValue apply_compound_op(const std::string& op, BallValue current, BallValue val);
};

// ================================================================
// StdModuleHandler
// ================================================================

class StdModuleHandler : public BallModuleHandler {
public:
    bool handles(const std::string& module) const override {
        return module == "std" || module == "dart_std";
    }

    void init(Engine& engine) override {
        dispatch_ = engine.build_std_dispatch();
    }

    BallValue call(const std::string& function, BallValue input, BallCallable /*engine*/) override {
        auto it = dispatch_.find(function);
        if (it != dispatch_.end()) return it->second(std::move(input));
        throw BallRuntimeError("Unknown std function: \"" + function + "\"");
    }

private:
    std::unordered_map<std::string, std::function<BallValue(BallValue)>> dispatch_;
};

// ================================================================
// StdCollectionsModuleHandler
// ================================================================

class StdCollectionsModuleHandler : public BallModuleHandler {
public:
    bool handles(const std::string& module) const override {
        return module == "std_collections";
    }

    void init(Engine& engine) override;

    BallValue call(const std::string& function, BallValue input, BallCallable engine) override {
        auto it = dispatch_.find(function);
        if (it != dispatch_.end()) return it->second(std::move(input), engine);
        throw BallRuntimeError("Unknown std_collections function: \"" + function + "\"");
    }

private:
    std::unordered_map<std::string, std::function<BallValue(BallValue, BallCallable)>> dispatch_;
};

// ================================================================
// StdIoModuleHandler
// ================================================================

class StdIoModuleHandler : public BallModuleHandler {
public:
    explicit StdIoModuleHandler(std::function<void(const std::string&)>* stdout_fn)
        : stdout_fn_(stdout_fn) {}

    bool handles(const std::string& module) const override {
        return module == "std_io";
    }

    BallValue call(const std::string& function, BallValue input, BallCallable engine) override;

private:
    std::function<void(const std::string&)>* stdout_fn_;
};

}  // namespace ball
