// ball::HybridNormalizer — resolves C++ pointer/reference operations.
//
// Faithful port of the Dart `normalizer.dart` reference.

#include "normalizer.h"
#include <algorithm>

namespace ball {

// ================================================================
// Public API
// ================================================================

ball::v1::Program& HybridNormalizer::normalize(ball::v1::Program& program) {
    // Phase 1: Analyze
    analyze_program(program);
    // Phase 2: Transform
    transform_program(program);
    // Phase 3: Cleanup
    cleanup_modules(program);
    return program;
}

// ================================================================
// Phase 1: Analysis
// ================================================================

void HybridNormalizer::analyze_program(const ball::v1::Program& program) {
    // Gather type definitions.
    for (const auto& mod : program.modules()) {
        for (const auto& td : mod.type_defs()) {
            type_info_[td.name()] = TypeInfo{
                td.name(),
                true,
                has_virtual_methods(mod, td.name()),
            };
        }
    }
    // Scan all functions for unsafe pointer patterns.
    for (const auto& mod : program.modules()) {
        bool all_base = true;
        for (const auto& f : mod.functions()) {
            if (!f.is_base()) { all_base = false; break; }
        }
        if (all_base) continue;
        for (const auto& func : mod.functions()) {
            if (func.is_base() || !func.has_body()) continue;
            analyze_expression(func.body(), func.name());
        }
    }
}

bool HybridNormalizer::has_virtual_methods(const ball::v1::Module& module,
                                            const std::string& class_name) {
    for (const auto& func : module.functions()) {
        if (func.name().find(class_name + ".") != 0) continue;
        if (func.has_metadata()) {
            auto it = func.metadata().fields().find("is_abstract");
            if (it != func.metadata().fields().end() && it->second.bool_value()) {
                return true;
            }
        }
    }
    return false;
}

void HybridNormalizer::analyze_expression(const ball::v1::Expression& expr,
                                           const std::string& func_ctx) {
    switch (expr.expr_case()) {
        case ball::v1::Expression::kCall:
            analyze_call(expr.call(), func_ctx);
            break;
        case ball::v1::Expression::kBlock:
            for (const auto& stmt : expr.block().statements()) {
                if (stmt.has_let())
                    analyze_expression(stmt.let().value(), func_ctx);
                if (stmt.has_expression())
                    analyze_expression(stmt.expression(), func_ctx);
            }
            if (expr.block().has_result())
                analyze_expression(expr.block().result(), func_ctx);
            break;
        case ball::v1::Expression::kFieldAccess:
            analyze_expression(expr.field_access().object(), func_ctx);
            break;
        case ball::v1::Expression::kMessageCreation:
            for (const auto& f : expr.message_creation().fields())
                analyze_expression(f.value(), func_ctx);
            break;
        case ball::v1::Expression::kLambda:
            if (expr.lambda().has_body())
                analyze_expression(expr.lambda().body(), func_ctx);
            break;
        default:
            break;
    }
}

void HybridNormalizer::analyze_call(const ball::v1::FunctionCall& call,
                                     const std::string& func_ctx) {
    if (call.module() == "cpp_std") {
        const auto& fn = call.function();
        if (fn == "ptr_cast" && is_reinterpret_or_const(call)) {
            unsafe_functions_.insert(func_ctx);
        } else if (fn == "deref" && is_pointer_arithmetic_context(call)) {
            unsafe_functions_.insert(func_ctx);
        }
    }
    if (call.module() == "std") {
        if ((call.function() == "add" || call.function() == "subtract") &&
            operands_involve_pointers(call)) {
            unsafe_functions_.insert(func_ctx);
        }
    }
    if (call.has_input())
        analyze_expression(call.input(), func_ctx);
}

bool HybridNormalizer::is_reinterpret_or_const(const ball::v1::FunctionCall& call) {
    if (!call.has_input()) return false;
    auto fields = extract_field_map(call.input());
    auto it = fields.find("cast_kind");
    if (it == fields.end() || !it->second) return false;
    const auto& ck = *it->second;
    if (ck.has_literal() && ck.literal().value_case() == ball::v1::Literal::kStringValue) {
        const auto& kind = ck.literal().string_value();
        return kind == "reinterpret_cast" || kind == "const_cast";
    }
    return false;
}

bool HybridNormalizer::is_pointer_arithmetic_context(const ball::v1::FunctionCall& call) {
    if (!call.has_input()) return false;
    auto fields = extract_field_map(call.input());
    auto it = fields.find("pointer");
    if (it == fields.end() || !it->second) return false;
    const auto& ptr = *it->second;
    if (ptr.has_call()) {
        const auto& inner = ptr.call();
        if (inner.module() == "std" &&
            (inner.function() == "add" || inner.function() == "subtract"))
            return true;
        if (inner.module() == "std_memory" &&
            (inner.function() == "ptr_add" || inner.function() == "ptr_sub"))
            return true;
    }
    return false;
}

bool HybridNormalizer::operands_involve_pointers(const ball::v1::FunctionCall& call) {
    if (!call.has_input()) return false;
    auto fields = extract_field_map(call.input());
    auto li = fields.find("left");
    auto ri = fields.find("right");
    return (li != fields.end() && li->second && expr_is_pointer(*li->second)) ||
           (ri != fields.end() && ri->second && expr_is_pointer(*ri->second));
}

bool HybridNormalizer::expr_is_pointer(const ball::v1::Expression& expr) {
    if (expr.has_reference()) {
        return pointer_safety_.count(expr.reference().name()) > 0;
    }
    if (expr.has_call() && expr.call().module() == "cpp_std") {
        const auto& fn = expr.call().function();
        return fn == "deref" || fn == "address_of" || fn == "arrow" || fn == "cpp_new";
    }
    return false;
}

// ================================================================
// Phase 2: Transformation
// ================================================================

void HybridNormalizer::transform_program(ball::v1::Program& program) {
    for (auto& mod : *program.mutable_modules()) {
        bool all_base = true;
        for (const auto& f : mod.functions()) {
            if (!f.is_base()) { all_base = false; break; }
        }
        if (all_base) continue;
        for (auto& func : *mod.mutable_functions()) {
            if (func.is_base() || !func.has_body()) continue;
            bool is_unsafe = unsafe_functions_.count(func.name()) > 0;
            transform_expression(*func.mutable_body(), is_unsafe);
        }
    }
}

void HybridNormalizer::transform_expression(ball::v1::Expression& expr,
                                             bool unsafe_ctx) {
    switch (expr.expr_case()) {
        case ball::v1::Expression::kCall:
            transform_call(expr, unsafe_ctx);
            break;
        case ball::v1::Expression::kBlock:
            for (auto& stmt : *expr.mutable_block()->mutable_statements()) {
                if (stmt.has_let())
                    transform_expression(*stmt.mutable_let()->mutable_value(), unsafe_ctx);
                if (stmt.has_expression())
                    transform_expression(*stmt.mutable_expression(), unsafe_ctx);
            }
            if (expr.block().has_result())
                transform_expression(*expr.mutable_block()->mutable_result(), unsafe_ctx);
            break;
        case ball::v1::Expression::kFieldAccess:
            transform_expression(*expr.mutable_field_access()->mutable_object(), unsafe_ctx);
            break;
        case ball::v1::Expression::kMessageCreation:
            for (auto& f : *expr.mutable_message_creation()->mutable_fields())
                transform_expression(*f.mutable_value(), unsafe_ctx);
            break;
        case ball::v1::Expression::kLambda:
            if (expr.lambda().has_body())
                transform_expression(*expr.mutable_lambda()->mutable_body(), unsafe_ctx);
            break;
        default:
            break;
    }
}

void HybridNormalizer::transform_call(ball::v1::Expression& expr,
                                       bool unsafe_ctx) {
    auto& call = *expr.mutable_call();

    // Recursively transform input first.
    if (call.has_input())
        transform_expression(*call.mutable_input(), unsafe_ctx);

    if (call.module() != "cpp_std") return;

    const auto& fn = call.function();
    ball::v1::Expression replacement;

    if (fn == "deref") {
        replacement = unsafe_ctx ? lower_deref_to_memory_read(call)
                                 : project_deref_to_reference(call);
    } else if (fn == "address_of") {
        replacement = unsafe_ctx ? lower_address_of_to_memory(call)
                                 : project_address_of_to_reference(call);
    } else if (fn == "arrow") {
        replacement = unsafe_ctx ? lower_arrow_to_memory_access(call)
                                 : project_arrow_to_field_access(call);
    } else if (fn == "cpp_new") {
        replacement = unsafe_ctx ? lower_new_to_memory_alloc(call)
                                 : project_new_to_construction(call);
    } else if (fn == "cpp_delete") {
        replacement = unsafe_ctx ? lower_delete_to_memory_free(call)
                                 : project_delete_to_noop(call);
    } else if (fn == "ptr_cast") {
        replacement = transform_ptr_cast(call, unsafe_ctx);
    } else if (fn == "cpp_sizeof") {
        replacement = transform_sizeof(call);
    } else if (fn == "cpp_alignof") {
        replacement = transform_alignof(call);
    } else if (fn == "cpp_move" || fn == "cpp_forward") {
        auto* ptr = extract_single_field(call, "pointer");
        if (ptr) { replacement = *ptr; } else return;
    } else if (fn == "init_list") {
        replacement = project_init_list_to_literal(call);
    } else if (fn == "scope_res") {
        replacement = project_scope_res_to_field_access(call);
    } else {
        return;
    }

    expr = std::move(replacement);
}

// ================================================================
// Safe projections
// ================================================================

ball::v1::Expression HybridNormalizer::project_deref_to_reference(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto it = fields.find("pointer");
    if (it != fields.end() && it->second) return *it->second;
    ball::v1::Expression e;
    e.mutable_reference()->set_name("null");
    return e;
}

ball::v1::Expression HybridNormalizer::project_address_of_to_reference(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto it = fields.find("value");
    if (it != fields.end() && it->second) return *it->second;
    ball::v1::Expression e;
    e.mutable_reference()->set_name("null");
    return e;
}

ball::v1::Expression HybridNormalizer::project_arrow_to_field_access(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto ptr_it = fields.find("pointer");
    auto mem_it = fields.find("member");
    std::string member_name = "unknown";
    if (mem_it != fields.end() && mem_it->second &&
        mem_it->second->has_literal() &&
        mem_it->second->literal().value_case() == ball::v1::Literal::kStringValue) {
        member_name = mem_it->second->literal().string_value();
    }
    ball::v1::Expression e;
    auto* fa = e.mutable_field_access();
    if (ptr_it != fields.end() && ptr_it->second)
        *fa->mutable_object() = *ptr_it->second;
    else
        fa->mutable_object()->mutable_reference()->set_name("null");
    fa->set_field(member_name);
    return e;
}

ball::v1::Expression HybridNormalizer::project_new_to_construction(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    std::string type_name = "Object";
    auto ti = fields.find("type");
    if (ti != fields.end() && ti->second && ti->second->has_literal())
        type_name = ti->second->literal().string_value();

    ball::v1::Expression e;
    auto* mc = e.mutable_message_creation();
    mc->set_type_name(type_name);

    auto ai = fields.find("args");
    if (ai != fields.end() && ai->second &&
        ai->second->has_message_creation()) {
        for (const auto& f : ai->second->message_creation().fields())
            *mc->add_fields() = f;
    }
    return e;
}

ball::v1::Expression HybridNormalizer::project_delete_to_noop(
    const ball::v1::FunctionCall& /*call*/) {
    ball::v1::Expression e;
    e.mutable_literal()->set_string_value("/* delete (GC managed) */");
    return e;
}

ball::v1::Expression HybridNormalizer::project_init_list_to_literal(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto ei = fields.find("elements");
    if (ei != fields.end() && ei->second &&
        ei->second->has_literal() &&
        ei->second->literal().has_list_value()) {
        return *ei->second;
    }
    ball::v1::Expression e;
    e.mutable_literal()->mutable_list_value();
    return e;
}

ball::v1::Expression HybridNormalizer::project_scope_res_to_field_access(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    std::string scope_name, member_name;
    auto si = fields.find("scope");
    if (si != fields.end() && si->second && si->second->has_literal())
        scope_name = si->second->literal().string_value();
    auto mi = fields.find("member");
    if (mi != fields.end() && mi->second && mi->second->has_literal())
        member_name = mi->second->literal().string_value();

    ball::v1::Expression e;
    auto* fa = e.mutable_field_access();
    fa->mutable_object()->mutable_reference()->set_name(scope_name);
    fa->set_field(member_name);
    return e;
}

// ================================================================
// Unsafe lowerings
// ================================================================

ball::v1::Expression HybridNormalizer::lower_deref_to_memory_read(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto pi = fields.find("pointer");

    ball::v1::Expression e;
    auto* c = e.mutable_call();
    c->set_module("std_memory");
    c->set_function("memory_read_i64");
    auto* mc = c->mutable_input()->mutable_message_creation();
    mc->set_type_name("MemReadInput");
    auto* f = mc->add_fields();
    f->set_name("address");
    if (pi != fields.end() && pi->second)
        *f->mutable_value() = *pi->second;
    else
        *f->mutable_value() = zero_expr();
    return e;
}

ball::v1::Expression HybridNormalizer::lower_address_of_to_memory(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto vi = fields.find("value");

    ball::v1::Expression e;
    auto* c = e.mutable_call();
    c->set_module("std_memory");
    c->set_function("address_of");
    auto* mc = c->mutable_input()->mutable_message_creation();
    mc->set_type_name("AddressOfInput");
    auto* f = mc->add_fields();
    f->set_name("value");
    if (vi != fields.end() && vi->second)
        *f->mutable_value() = *vi->second;
    else
        *f->mutable_value() = zero_expr();
    return e;
}

ball::v1::Expression HybridNormalizer::lower_arrow_to_memory_access(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto pi = fields.find("pointer");

    ball::v1::Expression e;
    auto* c = e.mutable_call();
    c->set_module("std_memory");
    c->set_function("memory_read_i64");
    auto* mc = c->mutable_input()->mutable_message_creation();
    mc->set_type_name("MemReadInput");
    auto* f = mc->add_fields();
    f->set_name("address");
    if (pi != fields.end() && pi->second)
        *f->mutable_value() = *pi->second;
    else
        *f->mutable_value() = zero_expr();
    return e;
}

ball::v1::Expression HybridNormalizer::lower_new_to_memory_alloc(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    std::string type_name = "void";
    auto ti = fields.find("type");
    if (ti != fields.end() && ti->second && ti->second->has_literal())
        type_name = ti->second->literal().string_value();

    // Build sizeof call for alloc size.
    ball::v1::Expression sizeof_expr;
    {
        auto* sc = sizeof_expr.mutable_call();
        sc->set_module("std_memory");
        sc->set_function("memory_sizeof");
        auto* smc = sc->mutable_input()->mutable_message_creation();
        smc->set_type_name("SizeofInput");
        auto* sf = smc->add_fields();
        sf->set_name("type_name");
        sf->mutable_value()->mutable_literal()->set_string_value(type_name);
    }

    ball::v1::Expression e;
    auto* c = e.mutable_call();
    c->set_module("std_memory");
    c->set_function("memory_alloc");
    auto* mc = c->mutable_input()->mutable_message_creation();
    mc->set_type_name("AllocInput");
    auto* f = mc->add_fields();
    f->set_name("size");
    *f->mutable_value() = sizeof_expr;
    return e;
}

ball::v1::Expression HybridNormalizer::lower_delete_to_memory_free(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    auto pi = fields.find("pointer");

    ball::v1::Expression e;
    auto* c = e.mutable_call();
    c->set_module("std_memory");
    c->set_function("memory_free");
    auto* mc = c->mutable_input()->mutable_message_creation();
    mc->set_type_name("FreeInput");
    auto* f = mc->add_fields();
    f->set_name("address");
    if (pi != fields.end() && pi->second)
        *f->mutable_value() = *pi->second;
    else
        *f->mutable_value() = zero_expr();
    return e;
}

// ================================================================
// Cast transformations
// ================================================================

ball::v1::Expression HybridNormalizer::transform_ptr_cast(
    const ball::v1::FunctionCall& call, bool unsafe_ctx) {
    auto fields = extract_field_map(call.input());
    std::string cast_kind = "static_cast";
    auto ck = fields.find("cast_kind");
    if (ck != fields.end() && ck->second && ck->second->has_literal())
        cast_kind = ck->second->literal().string_value();

    auto vi = fields.find("value");
    const ball::v1::Expression* value = vi != fields.end() ? vi->second : nullptr;

    auto tti = fields.find("target_type");
    std::string target_type = "dynamic";
    if (tti != fields.end() && tti->second && tti->second->has_literal())
        target_type = tti->second->literal().string_value();

    if (cast_kind == "static_cast" || cast_kind == "dynamic_cast") {
        // Emit `std.as`.
        ball::v1::Expression e;
        auto* c = e.mutable_call();
        c->set_module("std");
        c->set_function("as");
        auto* mc = c->mutable_input()->mutable_message_creation();
        mc->set_type_name("TypeCheckInput");
        auto* fv = mc->add_fields();
        fv->set_name("value");
        if (value) *fv->mutable_value() = *value;
        else *fv->mutable_value() = zero_expr();
        auto* ft = mc->add_fields();
        ft->set_name("type");
        ft->mutable_value()->mutable_literal()->set_string_value(target_type);
        return e;
    }
    if (cast_kind == "reinterpret_cast") {
        // Always unsafe — memory read.
        ball::v1::Expression e;
        auto* c = e.mutable_call();
        c->set_module("std_memory");
        c->set_function("memory_read_i64");
        auto* mc = c->mutable_input()->mutable_message_creation();
        mc->set_type_name("MemReadInput");
        auto* f = mc->add_fields();
        f->set_name("address");
        if (value) *f->mutable_value() = *value;
        else *f->mutable_value() = zero_expr();
        return e;
    }
    // const_cast — pass through.
    return value ? *value : zero_expr();
}

ball::v1::Expression HybridNormalizer::transform_sizeof(
    const ball::v1::FunctionCall& call) {
    auto fields = extract_field_map(call.input());
    std::string type_str = "int";
    auto ti = fields.find("type_or_expr");
    if (ti != fields.end() && ti->second && ti->second->has_literal())
        type_str = ti->second->literal().string_value();

    ball::v1::Expression e;
    auto* c = e.mutable_call();
    c->set_module("std_memory");
    c->set_function("memory_sizeof");
    auto* mc = c->mutable_input()->mutable_message_creation();
    mc->set_type_name("SizeofInput");
    auto* f = mc->add_fields();
    f->set_name("type_name");
    f->mutable_value()->mutable_literal()->set_string_value(type_str);
    return e;
}

ball::v1::Expression HybridNormalizer::transform_alignof(
    const ball::v1::FunctionCall& call) {
    return transform_sizeof(call);
}

// ================================================================
// Phase 3: Cleanup
// ================================================================

void HybridNormalizer::cleanup_modules(ball::v1::Program& program) {
    auto has_calls = [&](const std::string& module) -> bool {
        for (const auto& mod : program.modules()) {
            for (const auto& func : mod.functions()) {
                if (func.is_base() || !func.has_body()) continue;
                if (has_module_calls(func.body(), module)) return true;
            }
        }
        return false;
    };

    if (!has_calls("cpp_std")) {
        auto* mods = program.mutable_modules();
        for (int i = mods->size() - 1; i >= 0; --i) {
            if (mods->Get(i).name() == "cpp_std") {
                mods->DeleteSubrange(i, 1);
                break;
            }
        }
    }
    if (!has_calls("std_memory")) {
        auto* mods = program.mutable_modules();
        for (int i = mods->size() - 1; i >= 0; --i) {
            if (mods->Get(i).name() == "std_memory") {
                mods->DeleteSubrange(i, 1);
                break;
            }
        }
    }
}

bool HybridNormalizer::has_module_calls(const ball::v1::Expression& expr,
                                         const std::string& module) {
    switch (expr.expr_case()) {
        case ball::v1::Expression::kCall:
            if (expr.call().module() == module) return true;
            if (expr.call().has_input())
                return has_module_calls(expr.call().input(), module);
            return false;
        case ball::v1::Expression::kBlock:
            for (const auto& stmt : expr.block().statements()) {
                if (stmt.has_let() && has_module_calls(stmt.let().value(), module))
                    return true;
                if (stmt.has_expression() && has_module_calls(stmt.expression(), module))
                    return true;
            }
            if (expr.block().has_result())
                return has_module_calls(expr.block().result(), module);
            return false;
        case ball::v1::Expression::kMessageCreation:
            for (const auto& f : expr.message_creation().fields())
                if (has_module_calls(f.value(), module)) return true;
            return false;
        case ball::v1::Expression::kLambda:
            return expr.lambda().has_body() &&
                   has_module_calls(expr.lambda().body(), module);
        default:
            return false;
    }
}

// ================================================================
// Utilities
// ================================================================

std::unordered_map<std::string, const ball::v1::Expression*>
HybridNormalizer::extract_field_map(const ball::v1::Expression& input) {
    std::unordered_map<std::string, const ball::v1::Expression*> result;
    if (!input.has_message_creation()) return result;
    for (const auto& f : input.message_creation().fields())
        result[f.name()] = &f.value();
    return result;
}

const ball::v1::Expression* HybridNormalizer::extract_single_field(
    const ball::v1::FunctionCall& call, const std::string& name) {
    if (!call.has_input()) return nullptr;
    auto fields = extract_field_map(call.input());
    auto it = fields.find(name);
    return it != fields.end() ? it->second : nullptr;
}

ball::v1::Expression HybridNormalizer::zero_expr() {
    ball::v1::Expression e;
    e.mutable_literal()->set_int_value(0);
    return e;
}

}  // namespace ball
