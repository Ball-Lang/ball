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

// Library compilation result (no main, exported symbols).
struct CompileLibraryResult {
    std::string header;       // .h content: forward declarations + inline types
    std::string source;       // .cpp content: function definitions
    std::string ns;           // namespace name used
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

    // Compile from a Module facade (library mode): extracts inline sub-modules
    // and emits a .h (declarations) + .cpp (definitions) pair in a named
    // namespace, with no main() function. Used for ball_protobuf and similar
    // library-only Ball artifacts.
    //
    // The Module's moduleImports with InlineSource.json are expanded into the
    // program's module list. The namespace defaults to the module's name
    // (sanitized, e.g., "ball_protobuf").
    static CompileLibraryResult compile_library(
        const ball::v1::Module& facade,
        const std::string& ns_override = "");

    // Namespace used for multi-TU emission (single-TU uses anonymous namespace).
    static constexpr const char* kSplitNamespace = "ball_rt";

private:
    ball::v1::Program program_;

    // Lookup tables
    std::unordered_map<std::string, const ball::v1::FunctionDefinition*> functions_;
    std::unordered_set<std::string> base_modules_;

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
    // Sanitized names of module-level (top-level) variables. Suppresses the
    // legacy `input` param alias when `input` names a global (conformance 151).
    std::unordered_set<std::string> global_var_names_;
    // Sanitized bare names of standalone (non-method) user functions. A bare
    // reference to one used as a value is wrapped in a callable lambda so it can
    // be stored in std::any and invoked through BallDyn (conformance 155).
    std::unordered_set<std::string> user_function_names_;
    // Parameter count of each standalone user function, keyed by sanitized bare
    // name. When such a function is referenced as a VALUE, the callable wrapper
    // lambda must accept exactly this many params; a single-arg wrapper around a
    // multi-arg function is a compile error (currying: partialApply over a 2-arg
    // function, conformance 224).
    std::unordered_map<std::string, size_t> user_function_arity_;
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
    // Parameters of the function/method currently being emitted (raw Ball names).
    // A lambda that escapes its defining frame and reads one of these by `[&]`
    // would dangle it (e.g. the engine's `_evalLambda(func, scope)` returns a
    // closure that reads func/scope, then is invoked later by list_foreach/sort).
    // compile_lambda value-captures the enclosing-method params it references so
    // the BallDyn copies keep the scope chain / AST alive past the frame.
    std::unordered_set<std::string> current_fn_params_;
    // Names (raw Ball) of for_in / for_each loop variables of ENCLOSING loops in
    // the function/method currently being emitted. A for_in loop var is a fresh
    // stack local per iteration (`for (auto module : ...)`); it is neither a
    // `let` nor a method param, so compute_boxed_vars never boxes it and the
    // current_fn_params_ safety net never sees it. A closure that escapes the
    // loop iteration (stored/returned — e.g. the engine's _resolveTypeMethods
    // builds method closures over the iterated `module`/`func` and returns them
    // in __methods__) would then dangle that loop local under `[&]` → access
    // violation when the method is later invoked. compile_lambda VALUE-CAPTURES
    // (snapshots) any of these the body reads, which is safe because for_in vars
    // are per-iteration read-only bindings; the BallDyn copy keeps that
    // iteration's value alive past the frame. Pushed/popped around each for_in /
    // for_each body so sibling loops are unaffected.
    std::unordered_set<std::string> current_loop_vars_;
    // Names (raw Ball) of method-local `let`s of the ENCLOSING method currently
    // being emitted via the class-method path (emit_struct's method loop). That
    // path does NOT run compute_boxed_vars, so a method-local `let` captured by a
    // lambda that ESCAPES the method (returned/stored, then invoked later) is
    // neither boxed nor value-captured — it dangles under the default `[&]` →
    // garbage read (`<any>`) or access violation (0xC0000005). This is exactly
    // how the engine's `_evalReference` builds top-level / constructor tear-off
    // closures: `final modName = topLevel.module; return (input) => _callFunction(
    // modName, topLevel.func, input);` captures the method-local lets modName /
    // topLevel / ctorEntry. compile_lambda VALUE-CAPTURES (snapshots) any of these
    // the body reads; safe because these engine lets are single-assignment
    // (`final`/read-only) — the BallDyn copy keeps the let's value (and any
    // shared_ptr-backed scope/AST it points at) alive past the method frame.
    // Empty in emit_function / emit_main, where compute_boxed_vars already boxes
    // captured lets (so the safety net's boxed_vars_ guard skips them anyway).
    // (self-host 155_pipeline_compose / 224_currying_partial_apply)
    std::unordered_set<std::string> current_fn_locals_;
    // Set of all enum type names (sanitized, e.g. "Color").
    std::unordered_set<std::string> enum_names_;
    // Maps class name to its TypeDefinition for field lookups.
    std::unordered_map<std::string, const ball::v1::TypeDefinition*> class_typedefs_;
    // The sanitized name of the class currently being emitted (empty outside
    // emit_struct). Used for super call resolution.
    std::string current_class_name_;
    // True while compiling the body of a STATIC class method. A static method
    // has no `this`, so compile_reference must not emit a `[this]`-capturing
    // lambda when a sibling method is referenced as a value. (self-host engine #19)
    bool in_static_method_ = false;
    // Maps class name to the set of abstract method basenames.
    std::unordered_map<std::string, std::unordered_set<std::string>> class_abstract_methods_;
    // Maps class name to factory constructor function names.
    std::unordered_map<std::string, std::vector<std::string>> class_factory_ctors_;
    // True while compiling a factory constructor body. Inside a factory,
    // user-class `let` bindings are emitted as `auto var = BallDyn(...)` so
    // the instance is stored reference-semantically via BallUserRef and
    // `identical()` / cascade mutations work correctly (conformance 106/111).
    bool inside_factory_ = false;
    // Maps class name to named (non-default, non-factory) constructor basenames.
    std::unordered_map<std::string, std::vector<std::string>> class_named_ctors_;

    // ── Dynamic-class discriminator (dynamic-dispatch-generics cluster) ──
    // A user class is "dynamic" iff it is generic (has type_params), abstract,
    // or descends from / implements an abstract base. Dynamic classes lower to
    // MAP-BACKED BallObject instances carrying a "__methods__" table of one-arg
    // BallFunc closures over their fields; their type maps to BallDyn and method
    // dispatch routes through the ball_call_method runtime helper. Concrete,
    // non-generic, non-abstract classes KEEP the existing struct path.
    // Keyed by BOTH the full ("main:Box") and bare/sanitized ("Box") names.
    std::unordered_set<std::string> dynamic_class_names_;
    // Maps a dynamic class's bare-sanitized name to its TypeDefinition + ordered
    // method list, so messageCreation can emit the make_<Class> factory inline.
    std::unordered_map<std::string, const ball::v1::TypeDefinition*> dynamic_class_typedefs_;
    std::unordered_map<std::string, std::vector<const ball::v1::FunctionDefinition*>>
        dynamic_class_methods_;
    // Sanitized method/getter basenames owned by ANY dynamic class. A method
    // call or field access whose name is in this set, on a non-static receiver,
    // routes through ball_call_method instead of the struct/STL path.
    std::unordered_set<std::string> dynamic_method_names_;
    // Set of (sanitized bare) type-parameter names in scope while emitting a
    // generic function/method body or dynamic-class method closure. A bare
    // reference whose type is one of these maps to BallDyn.
    std::unordered_set<std::string> active_type_params_;
    // When non-empty, we are emitting a dynamic-class method body as a free
    // closure: `self`/`this` resolve to this receiver expression and bare field
    // references read through it via bracket access.
    std::string dynamic_self_expr_;
    // Field names of the dynamic class whose method body is currently being
    // emitted (so a bare reference to one becomes a receiver bracket read).
    std::unordered_set<std::string> dynamic_self_fields_;

    // True iff `class_name` (full or bare/sanitized) is a dynamic class.
    bool is_dynamic_class(const std::string& class_name) const {
        return dynamic_class_names_.count(class_name) > 0 ||
               dynamic_class_names_.count(sanitize_name_const(class_name)) > 0;
    }
    // const-friendly name sanitizer for use in const predicates.
    static std::string sanitize_name_const(const std::string& name) {
        std::string r = name;
        auto colon = r.find(':');
        if (colon != std::string::npos) r = r.substr(colon + 1);
        std::replace(r.begin(), r.end(), '.', '_');
        std::replace(r.begin(), r.end(), '-', '_');
        return r;
    }
    // Emit the make_<Class> factory + per-method closure free functions for a
    // dynamic class, plus a ball_to_string overload routing to toString.
    void emit_dynamic_class(const ball::v1::TypeDefinition& td,
        const std::vector<const ball::v1::FunctionDefinition*>& methods);
    // Build the inline make_<Class>(...) construction expression for a dynamic
    // class message-creation (positional argN fields → field map + __methods__).
    std::string emit_dynamic_construction(const std::string& bare_class,
        const ball::v1::MessageCreation& msg, const std::string& type_args_expr);

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
    // Emits the `std_memory` linear-memory runtime: the backing byte array +
    // heap/stack pointers, plus a native `_ball_<fn>` helper for every
    // std_memory base function the compiler implements (issue #154). Shared
    // by compile() and compile_split() so the two codegen paths never drift.
    void emit_memory_runtime_preamble();
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
    // Escape a raw string for safe embedding inside a C++ string literal.
    static std::string cpp_escape_string(const std::string& s);
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
    // Compile a single list/set collection element into statements that append
    // to the BallList named `list_var`, splicing spread (`...x` / `...?x`),
    // nested collection_for, and collection_if elements (mirrors the Dart
    // engine's `_addCollectionElement`). Returns a sequence of C++ statements.
    std::string compile_collection_element(const ball::v1::Expression& expr,
                                            const std::string& list_var);
    // Compile a map collection element into statements that insert into the
    // BallOrderedMap named `map_var`, splicing map spread (`...m`), nested
    // map comprehensions, and key/value entry sentinels.
    std::string compile_map_collection_element(const ball::v1::Expression& expr,
                                               const std::string& map_var);
    // Render the C++ `for (...)` header (no trailing brace) for a C-style
    // `collection_for` (init/condition/update), inlining the single-let init.
    // When the loop variable is captured by an escaping closure (per
    // `boxed_vars_`), the init cell is boxed (shared_ptr<BallDyn>) and
    // `*boxed_var_out` is set to its sanitized name so the caller can wrap the
    // loop body with a fresh per-iteration cell (see
    // `_wrap_cstyle_loop_body`). Leave `boxed_var_out` null to opt out.
    std::string _render_collection_for_cstyle_header(
        const ball::v1::FunctionCall& call, std::string* boxed_var_out = nullptr);
    // Wraps a C-style collection_for's body statements with the
    // shared_ptr<BallDyn> per-iteration shadow cell for `boxed_var` (mirrors
    // the statement-form `for`'s boxing in compile_statement — see fixture
    // 312). If `boxed_var` is empty, just braces the body statements.
    std::string _wrap_cstyle_loop_body(const std::string& boxed_var,
                                        const std::string& body_stmts);
    std::string sanitize_name(const std::string& name);
    std::string indent_str();
    // Resolve a class's constructor parameter names (in declaration order) so
    // positional call-site args (`arg0`, `arg1`, ...) can be mapped back to the
    // real field names. Returns empty if the constructor isn't found.
    std::vector<std::string> lookup_ctor_params(const std::string& type_name);
};

}  // namespace ball
