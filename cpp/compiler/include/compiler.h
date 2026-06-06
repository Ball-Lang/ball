#pragma once

// ball::CppCompiler — compiles a ball Program AST into C++ source code.
//
// This is the C++ analogue of the Dart DartCompiler: it walks a protobuf
// Program tree and emits idiomatic C++ that can be compiled with any modern
// C++ toolchain (g++, clang++, MSVC).
//
// The generated code is self-contained: it includes a minimal runtime
// (value type, linear-memory helpers) and maps ball's std operations to
// C++ standard library calls.

#include "ball_shared.h"
#include "code_builder.h"
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace ball {

// Multi-TU output for parallel MSVC/Ninja builds (self-hosted engine_rt).
struct CompileSplitResult {
    std::string output_dir;
    int num_shards = 0;
    std::string common_header;   // engine_rt_common.hpp
    std::vector<std::string> shard_sources;  // engine_rt_shard_NN.cpp paths
};

class CppCompiler {
public:
    explicit CppCompiler(const ball::v1::Program& program);

    // Compile the entire program to a single C++ source string
    std::string compile();

    // Emit N translation units + a shared header under output_dir.
    // Uses namespace ball_rt (not anonymous) so TUs can link together.
    CompileSplitResult compile_split(const std::string& output_dir, int num_shards);

    // Compile a single module (for multi-file output)
    std::string compile_module(const std::string& module_name);

    // Namespace used for multi-TU emission (single-TU uses anonymous namespace).
    static constexpr const char* kSplitNamespace = "ball_rt";

private:
    ball::v1::Program program_;

    // Lookup tables
    std::unordered_map<std::string, google::protobuf::DescriptorProto> types_;
    std::unordered_map<std::string, const ball::v1::FunctionDefinition*> functions_;
    std::unordered_set<std::string> base_modules_;
    std::unordered_map<std::string, std::vector<std::string>> param_cache_;

    // Output state
    std::ostringstream out_;
    int indent_ = 0;

    // Pending label from a `labeled` wrapper — consumed by the next loop
    // emission so it can plant `__ball_break_<label>` / `__ball_continue_<label>`
    // goto targets around/inside its body.
    std::string pending_label_;

    // Variables currently bound to a `BallException&` inside a catch
    // block. Field access on these compiles to `.fields.at("X")` so
    // catch-side payload reads reach the original throw values.
    std::unordered_set<std::string> catch_bound_vars_;

    // Set of method basenames belonging to the class currently being
    // emitted. When a reference matches one of these names, the compiler
    // wraps it in a lambda to bind `this` (member function pointers
    // can't be stored directly as std::any/std::function values).
    std::unordered_set<std::string> current_class_methods_;
    // Sanitized basenames of static_field members of the class currently being
    // emitted. A reference to one resolves to the bare member name, NOT a
    // this-binding method lambda (illegal in a static method) — conformance 106.
    std::unordered_set<std::string> current_class_static_fields_;

    // OOP class support — populated in build_lookup_tables():
    // Maps a method basename (e.g. "describe") to the set of class names
    // that define it (e.g. {"main:Point"}). Used by compile_method_call
    // to detect user-class methods and emit obj.method() instead of
    // method(obj, ...).
    std::unordered_map<std::string, std::unordered_set<std::string>> method_to_classes_;
    // Maps a class name (e.g. "main:Point") to its superclass name
    // (e.g. "" for no superclass, "Animal" for Dog extends Animal).
    std::unordered_map<std::string, std::string> class_superclass_;
    // Set of method basenames that are overridden by a subclass — these
    // need the `virtual` keyword on the base declaration.
    std::unordered_set<std::string> overridden_methods_;
    // Maps class name to the set of static method basenames.
    std::unordered_map<std::string, std::unordered_set<std::string>> class_static_methods_;
    // Maps class name to the set of getter basenames.
    std::unordered_map<std::string, std::unordered_set<std::string>> class_getters_;
    // Maps class name to the set of setter basenames.
    std::unordered_map<std::string, std::unordered_set<std::string>> class_setters_;
    // Set of all user-defined class names (sanitized, e.g. "Point").
    std::unordered_set<std::string> user_class_names_;
    // Sanitized bare names of void-returning user functions. Call sites use
    // this to avoid wrapping a void call in BallDyn(...) (conformance 133).
    std::unordered_set<std::string> void_user_functions_;
    // Sanitized bare names of standalone (non-method) user functions. A bare
    // reference to one used as a value is wrapped in a callable lambda so it can
    // be stored in std::any and invoked through BallDyn (conformance 155).
    std::unordered_set<std::string> user_function_names_;
    // C++ return type of the function currently being emitted ("void", "BallDyn",
    // ...). Lets the return-statement handler emit a bare `return;` in void
    // functions instead of `return BallDyn(...)` (conformance 89).
    std::string current_return_type_;
    // Local/param names captured by a closure in the current function that must
    // be BOXED (shared_ptr<BallDyn>): their declaration allocates a fresh cell
    // per iteration and lambdas capture the shared_ptr by value, so an escaping
    // closure over a loop-body local keeps that iteration's binding alive
    // (conformance 85/203/223). References to a boxed name emit `(*name)`.
    std::unordered_set<std::string> boxed_vars_;
    // Subset of boxed_vars_ that are function PARAMETERS (not lets). emit_function
    // renames the C++ parameter to `<name>__p` and boxes it at entry so a
    // returned closure capturing the parameter keeps its binding (currying,
    // conformance 154/211/224).
    std::unordered_set<std::string> boxed_params_;
    // Closure-captured FUNCTION-typed params (std::function<...>): these are NOT
    // boxed (a std::function is already heap-backed and copyable, and boxing to
    // BallDyn would lose multi-arg arity). Instead they are captured BY VALUE in
    // the lambda so the callable copies and survives the call frame
    // (conformance 224 — `partialApply(fn, first) => (x) => fn(first, x)`).
    std::unordered_set<std::string> value_capture_vars_;
    // Set of all enum type names (sanitized, e.g. "Color").
    std::unordered_set<std::string> enum_names_;
    // Maps class name to its TypeDefinition for field lookups.
    std::unordered_map<std::string, const ball::v1::TypeDefinition*> class_typedefs_;
    // The sanitized name of the class currently being emitted (empty outside
    // emit_struct). Used for super call resolution.
    std::string current_class_name_;
    // Maps class name to the set of abstract method basenames.
    std::unordered_map<std::string, std::unordered_set<std::string>> class_abstract_methods_;
    // Maps class name to factory constructor function names.
    std::unordered_map<std::string, std::vector<std::string>> class_factory_ctors_;
    // Maps class name to named (non-default, non-factory) constructor basenames.
    std::unordered_map<std::string, std::vector<std::string>> class_named_ctors_;

    // Sanitized names of locals/parameters declared in the function body
    // currently being emitted. A reference to one of these resolves to the
    // variable, shadowing the Dart type-object names (`num`, `int`, `String`,
    // …) that otherwise compile to a type-name string literal. Without this a
    // common local named `num` would emit `"num"s` instead of the variable.
    std::unordered_set<std::string> declared_locals_;

    // Variables whose let-binding value is a generic (map-backed) construction
    // (messageCreation with __type_args__). Field access on these must use
    // bracket notation, not struct member syntax.
    std::unordered_set<std::string> generic_locals_;

    // True when compiling a sync*/async* generator function body.
    // yield/yield_each emit __gen.yield_/__gen.yieldAll calls instead of
    // passthrough, and the function returns the collected generator values.
    bool in_generator_ = false;

    // Multi-TU emission state (compile_split only)
    bool split_mode_ = false;
    int split_shards_ = 8;
    int split_next_shard_ = 0;
    std::vector<std::string> split_pending_;

    void queue_split_definition(std::string definition);
    void emit_namespace_open();
    void emit_namespace_close();
    void emit_function_signature_only(const ball::v1::FunctionDefinition& func);
    void emit_function_body_out_of_line(const ball::v1::FunctionDefinition& func);

    void build_lookup_tables();
    std::vector<std::string> extract_params(const google::protobuf::Struct& metadata);
    std::map<std::string, std::string> read_meta(const ball::v1::FunctionDefinition& func);
    std::vector<std::string> read_meta_list(const google::protobuf::Struct& meta,
                                             const std::string& key);
    std::map<std::string, std::string> read_type_meta(const ball::v1::TypeDefinition& td);
    void emit_template_prefix(const ball::v1::TypeDefinition& td);
    void emit_template_prefix_from_meta(const google::protobuf::Struct& meta);

    // Code generation
    void emit(const std::string& code);
    void emit_line(const std::string& code);
    void emit_indent();
    void emit_newline();

    // Structural emitters
    void emit_includes();
    void emit_forward_decls(const ball::v1::Module& module);
    void emit_struct(const ball::v1::TypeDefinition& td,
                    const std::vector<const ball::v1::FunctionDefinition*>& methods);
    void emit_enum(const google::protobuf::EnumDescriptorProto& ed);
    void emit_function(const ball::v1::FunctionDefinition& func);
    void emit_top_level_var(const ball::v1::FunctionDefinition& func);
    void emit_main(const ball::v1::FunctionDefinition& entry);
    // Populate boxed_vars_/boxed_params_/value_capture_vars_ for a function/main
    // body: `let` locals + non-function params captured by closures are boxed;
    // function-typed captured params are value-captured. `param_types` is the
    // mapped C++ type per param (empty entries / no params ⇒ treat as non-fn).
    void compute_boxed_vars(const ball::v1::Expression& body,
                            const std::vector<std::string>& params,
                            const std::vector<std::string>& param_types = {});

    // Expression compilation — returns C++ expression string
    std::string compile_expr(const ball::v1::Expression& expr);
    // Bridge: compile expression to CppExpr for method chaining
    CppExpr expr(const ball::v1::Expression& e) { return CppExpr(compile_expr(e)); }
    std::string compile_call(const ball::v1::FunctionCall& call);
    std::string compile_literal(const ball::v1::Literal& lit);
    std::string compile_reference(const ball::v1::Reference& ref);
    // True when `e` is a call to a void-returning user function (so the call
    // must not be wrapped in BallDyn(...)).
    bool _isVoidUserCall(const ball::v1::Expression& e);
    std::string compile_field_access(const ball::v1::FieldAccess& access);
    std::string compile_message_creation(const ball::v1::MessageCreation& msg);
    std::string compile_block(const ball::v1::Block& block);
    // Emit a block's statements as real C++ statements (not an IIFE), captured
    // to a string by diverting out_. Used for expression-context loop bodies so
    // break/continue work in the enclosing real for/while.
    std::string compile_block_statements(const ball::v1::Block& block);
    std::string compile_lambda(const ball::v1::FunctionDefinition& func);

    // Statement compilation — emits directly
    void compile_statement(const ball::v1::Statement& stmt);

    // std function compilation
    std::string compile_std_call(const std::string& function,
                                  const ball::v1::FunctionCall& call);
    std::string compile_method_call(const std::string& function,
                                     const ball::v1::FunctionCall& call);
    std::string compile_collections_call(const std::string& function,
                                          const ball::v1::FunctionCall& call);
    std::string compile_io_call(const std::string& function,
                                 const ball::v1::FunctionCall& call);
    std::string compile_cpp_std_call(const std::string& function,
                                      const ball::v1::FunctionCall& call);
    std::string compile_convert_call(const std::string& function,
                                      const ball::v1::FunctionCall& call);
    std::string compile_fs_call(const std::string& function,
                                 const ball::v1::FunctionCall& call);
    std::string compile_time_call(const std::string& function,
                                   const ball::v1::FunctionCall& call);
    std::string compile_concurrency_call(const std::string& function,
                                          const ball::v1::FunctionCall& call);
    std::string compile_binary_op(const std::string& op,
                                   const ball::v1::FunctionCall& call);
    std::string compile_unary_op(const std::string& op,
                                  const ball::v1::FunctionCall& call);

    // Type mapping
    std::string map_type(const std::string& ball_type);
    std::string map_return_type(const ball::v1::FunctionDefinition& func);

    // Helpers
    std::string get_message_field(const ball::v1::FunctionCall& call,
                                   const std::string& field_name);
    std::string get_optional_field(const ball::v1::FunctionCall& call,
                                    const std::string& field_name);
    std::string get_string_field(const ball::v1::FunctionCall& call,
                                  const std::string& field_name);
    const ball::v1::Expression* get_message_field_expr(
        const ball::v1::FunctionCall& call, const std::string& field_name);
    // Bridge: get a message field compiled to CppExpr
    CppExpr field_expr(const ball::v1::FunctionCall& call,
                       const std::string& field_name) {
        auto* e = get_message_field_expr(call, field_name);
        return e ? CppExpr(compile_expr(*e)) : CppExpr("/* missing " + field_name + " */");
    }
    // Resolve a higher-order callback argument. Different encoders name the
    // closure field differently ("callback", "function", or "value"); the
    // self-hosted engine's `.any`/`.every`/`.firstWhere`/`.fold` callbacks
    // arrive under "value". Try each in turn so the lambda is never dropped
    // (a dropped lambda compiles to an empty BallDyn() and silently no-ops).
    std::string get_callback_field(const ball::v1::FunctionCall& call) {
        auto* e = get_message_field_expr(call, "callback");
        if (!e) e = get_message_field_expr(call, "function");
        if (!e) e = get_message_field_expr(call, "value");
        return e ? compile_expr(*e) : "BallDyn()";
    }
    // Compile a map entry sentinel expression as a map insertion statement.
    std::string compile_map_entry_insert(const ball::v1::Expression& expr,
                                          const std::string& map_var);
    std::string sanitize_name(const std::string& name);
    std::string indent_str();
    // Resolve a class's constructor parameter names (in declaration order) so
    // positional call-site args (`arg0`, `arg1`, ...) can be mapped back to the
    // real field names. Returns empty if the constructor isn't found.
    std::vector<std::string> lookup_ctor_params(const std::string& type_name);
};

}  // namespace ball
