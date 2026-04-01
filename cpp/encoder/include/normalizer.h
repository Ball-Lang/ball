#pragma once

// ball::HybridNormalizer — resolves C++ pointer/reference operations.
//
// Takes a Ball Program containing `std`, `cpp_std`, and `std_memory` calls
// and transforms it so that:
//   - Safe pointer/reference usages → native Ball variable refs / field access
//   - Unsafe pointer usages → std_memory linear memory operations
//
// Port of the Dart `normalizer.dart` reference.

#include "ball_shared.h"
#include <string>
#include <unordered_map>
#include <unordered_set>

namespace ball {

class HybridNormalizer {
public:
    /// Normalize a complete Ball program in-place.
    /// Returns the same program with cpp_std calls resolved.
    ball::v1::Program& normalize(ball::v1::Program& program);

private:
    // Analysis phase
    std::unordered_set<std::string> unsafe_functions_;
    std::unordered_map<std::string, bool> pointer_safety_;

    struct TypeInfo {
        std::string name;
        bool is_class = false;
        bool has_vtable = false;
    };
    std::unordered_map<std::string, TypeInfo> type_info_;

    // Phase 1: Analysis
    void analyze_program(const ball::v1::Program& program);
    bool has_virtual_methods(const ball::v1::Module& module,
                             const std::string& class_name);
    void analyze_expression(const ball::v1::Expression& expr,
                            const std::string& func_context);
    void analyze_call(const ball::v1::FunctionCall& call,
                      const std::string& func_context);
    bool is_reinterpret_or_const(const ball::v1::FunctionCall& call);
    bool is_pointer_arithmetic_context(const ball::v1::FunctionCall& call);
    bool operands_involve_pointers(const ball::v1::FunctionCall& call);
    bool expr_is_pointer(const ball::v1::Expression& expr);

    // Phase 2: Transformation
    void transform_program(ball::v1::Program& program);
    void transform_expression(ball::v1::Expression& expr, bool unsafe_ctx);
    void transform_call(ball::v1::Expression& expr, bool unsafe_ctx);

    // Safe projections
    ball::v1::Expression project_deref_to_reference(const ball::v1::FunctionCall& call);
    ball::v1::Expression project_address_of_to_reference(const ball::v1::FunctionCall& call);
    ball::v1::Expression project_arrow_to_field_access(const ball::v1::FunctionCall& call);
    ball::v1::Expression project_new_to_construction(const ball::v1::FunctionCall& call);
    ball::v1::Expression project_delete_to_noop(const ball::v1::FunctionCall& call);
    ball::v1::Expression project_init_list_to_literal(const ball::v1::FunctionCall& call);
    ball::v1::Expression project_scope_res_to_field_access(const ball::v1::FunctionCall& call);

    // Unsafe lowerings
    ball::v1::Expression lower_deref_to_memory_read(const ball::v1::FunctionCall& call);
    ball::v1::Expression lower_address_of_to_memory(const ball::v1::FunctionCall& call);
    ball::v1::Expression lower_arrow_to_memory_access(const ball::v1::FunctionCall& call);
    ball::v1::Expression lower_new_to_memory_alloc(const ball::v1::FunctionCall& call);
    ball::v1::Expression lower_delete_to_memory_free(const ball::v1::FunctionCall& call);

    // Cast transformations
    ball::v1::Expression transform_ptr_cast(const ball::v1::FunctionCall& call,
                                             bool unsafe_ctx);
    ball::v1::Expression transform_sizeof(const ball::v1::FunctionCall& call);
    ball::v1::Expression transform_alignof(const ball::v1::FunctionCall& call);

    // Phase 3: Cleanup
    void cleanup_modules(ball::v1::Program& program);
    bool has_module_calls(const ball::v1::Expression& expr,
                          const std::string& module);

    // Helpers
    std::unordered_map<std::string, const ball::v1::Expression*>
    extract_field_map(const ball::v1::Expression& input);
    const ball::v1::Expression* extract_single_field(
        const ball::v1::FunctionCall& call, const std::string& name);
    static ball::v1::Expression zero_expr();
};

}  // namespace ball
