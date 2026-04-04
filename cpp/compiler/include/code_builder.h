#pragma once

// code_builder.h — Expression and statement builder for C++ code generation.
//
// Provides type-safe construction of C++ source strings via method
// chaining, eliminating raw string concatenation in the compiler.
//
// Example:
//   CppExpr x = CppExpr::ref("x");
//   CppExpr y = CppExpr::ref("y");
//   std::string code = (x + y).paren().str();  // "(x + y)"

#include <sstream>
#include <string>
#include <vector>

namespace ball {

// ── CppExpr ──────────────────────────────────────────────────
// Lightweight value type wrapping a C++ expression string.
// All methods return a new CppExpr (immutable builder pattern).

class CppExpr {
public:
    CppExpr() = default;
    explicit CppExpr(std::string code) : code_(std::move(code)) {}

    // ── Factories ────────────────────────────────────────────
    static CppExpr raw(const std::string& code) { return CppExpr(code); }
    static CppExpr ref(const std::string& name) { return CppExpr(name); }
    static CppExpr lit(int v) { return CppExpr(std::to_string(v)); }
    static CppExpr lit(int64_t v) { return CppExpr(std::to_string(v)); }
    static CppExpr lit(double v) {
        std::ostringstream ss;
        ss << v;
        auto s = ss.str();
        if (s.find('.') == std::string::npos && s.find('e') == std::string::npos)
            s += ".0";
        return CppExpr(s);
    }
    static CppExpr lit_string(const std::string& v) { return CppExpr("\"" + v + "\"s"); }
    static CppExpr lit_char(char c) {
        return CppExpr(std::string("'") + c + "'");
    }
    static CppExpr lit_bool(bool v) { return CppExpr(v ? "true" : "false"); }
    static CppExpr null_expr() { return CppExpr("nullptr"); }

    // ── Binary operators ─────────────────────────────────────
    CppExpr operator+(const CppExpr& rhs) const { return bin_op("+", rhs); }
    CppExpr operator-(const CppExpr& rhs) const { return bin_op("-", rhs); }
    CppExpr operator*(const CppExpr& rhs) const { return bin_op("*", rhs); }
    CppExpr operator/(const CppExpr& rhs) const { return bin_op("/", rhs); }
    CppExpr operator%(const CppExpr& rhs) const { return bin_op("%", rhs); }

    CppExpr eq(const CppExpr& rhs) const { return bin_op("==", rhs); }
    CppExpr ne(const CppExpr& rhs) const { return bin_op("!=", rhs); }
    CppExpr lt(const CppExpr& rhs) const { return bin_op("<", rhs); }
    CppExpr gt(const CppExpr& rhs) const { return bin_op(">", rhs); }
    CppExpr le(const CppExpr& rhs) const { return bin_op("<=", rhs); }
    CppExpr ge(const CppExpr& rhs) const { return bin_op(">=", rhs); }

    CppExpr and_op(const CppExpr& rhs) const { return bin_op("&&", rhs); }
    CppExpr or_op(const CppExpr& rhs) const { return bin_op("||", rhs); }

    CppExpr bit_and(const CppExpr& rhs) const { return bin_op("&", rhs); }
    CppExpr bit_or(const CppExpr& rhs) const { return bin_op("|", rhs); }
    CppExpr bit_xor(const CppExpr& rhs) const { return bin_op("^", rhs); }
    CppExpr shl(const CppExpr& rhs) const { return bin_op("<<", rhs); }
    CppExpr shr(const CppExpr& rhs) const { return bin_op(">>", rhs); }

    // ── Unary operators ──────────────────────────────────────
    CppExpr negate() const { return CppExpr("(-" + code_ + ")"); }
    CppExpr not_op() const { return CppExpr("(!" + code_ + ")"); }
    CppExpr bit_not() const { return CppExpr("(~" + code_ + ")"); }
    CppExpr pre_inc() const { return CppExpr("(++" + code_ + ")"); }
    CppExpr pre_dec() const { return CppExpr("(--" + code_ + ")"); }
    CppExpr post_inc() const { return CppExpr("(" + code_ + "++)"); }
    CppExpr post_dec() const { return CppExpr("(" + code_ + "--)"); }
    CppExpr deref() const { return CppExpr("(*" + code_ + ")"); }
    CppExpr addr() const { return CppExpr("(&" + code_ + ")"); }

    // ── Property/member access ───────────────────────────────
    CppExpr dot(const std::string& member) const {
        return CppExpr(code_ + "." + member);
    }
    CppExpr arrow(const std::string& member) const {
        return CppExpr(code_ + "->" + member);
    }
    CppExpr scope(const std::string& member) const {
        return CppExpr(code_ + "::" + member);
    }

    // ── Call ─────────────────────────────────────────────────
    CppExpr call(const std::vector<CppExpr>& args = {}) const {
        return CppExpr(code_ + "(" + join_args(args) + ")");
    }
    CppExpr call(const std::string& method,
                 const std::vector<CppExpr>& args = {}) const {
        return CppExpr(code_ + "." + method + "(" + join_args(args) + ")");
    }

    // ── Indexing ─────────────────────────────────────────────
    CppExpr index(const CppExpr& idx) const {
        return CppExpr(code_ + "[" + idx.code_ + "]");
    }

    // ── Type operations ──────────────────────────────────────
    CppExpr cast_to(const std::string& type) const {
        return CppExpr("static_cast<" + type + ">(" + code_ + ")");
    }
    CppExpr reinterpret_cast_to(const std::string& type) const {
        return CppExpr("reinterpret_cast<" + type + ">(" + code_ + ")");
    }
    CppExpr dynamic_cast_to(const std::string& type) const {
        return CppExpr("dynamic_cast<" + type + "*>(&" + code_ + ")");
    }

    // ── Assignment ───────────────────────────────────────────
    CppExpr assign(const CppExpr& rhs) const { return bin_op("=", rhs); }
    CppExpr add_assign(const CppExpr& rhs) const { return bin_op("+=", rhs); }
    CppExpr sub_assign(const CppExpr& rhs) const { return bin_op("-=", rhs); }
    CppExpr mul_assign(const CppExpr& rhs) const { return bin_op("*=", rhs); }
    CppExpr div_assign(const CppExpr& rhs) const { return bin_op("/=", rhs); }
    CppExpr mod_assign(const CppExpr& rhs) const { return bin_op("%=", rhs); }
    CppExpr and_assign(const CppExpr& rhs) const { return bin_op("&=", rhs); }
    CppExpr or_assign(const CppExpr& rhs) const { return bin_op("|=", rhs); }
    CppExpr xor_assign(const CppExpr& rhs) const { return bin_op("^=", rhs); }
    CppExpr shl_assign(const CppExpr& rhs) const { return bin_op("<<=", rhs); }
    CppExpr shr_assign(const CppExpr& rhs) const { return bin_op(">>=", rhs); }

    // ── Ternary ──────────────────────────────────────────────
    CppExpr conditional(const CppExpr& when_true,
                        const CppExpr& when_false) const {
        return CppExpr("(" + code_ + " ? " + when_true.code_ +
                        " : " + when_false.code_ + ")");
    }

    // ── Wrapping ─────────────────────────────────────────────
    CppExpr paren() const { return CppExpr("(" + code_ + ")"); }
    CppExpr braces() const { return CppExpr("{" + code_ + "}"); }

    // ── sizeof / alignof ─────────────────────────────────────
    static CppExpr size_of(const std::string& type) {
        return CppExpr("sizeof(" + type + ")");
    }
    static CppExpr align_of(const std::string& type) {
        return CppExpr("alignof(" + type + ")");
    }

    // ── Smart pointers ───────────────────────────────────────
    static CppExpr make_unique(const std::string& type,
                               const std::vector<CppExpr>& args = {}) {
        return CppExpr("std::make_unique<" + type + ">(" + join_args(args) + ")");
    }
    static CppExpr make_shared(const std::string& type,
                               const std::vector<CppExpr>& args = {}) {
        return CppExpr("std::make_shared<" + type + ">(" + join_args(args) + ")");
    }
    static CppExpr std_move(const CppExpr& expr) {
        return CppExpr("std::move(" + expr.code_ + ")");
    }
    static CppExpr std_forward(const CppExpr& expr) {
        return CppExpr("std::forward(" + expr.code_ + ")");
    }

    // ── Lambda builder ───────────────────────────────────────
    // Returns `[capture](params){ body }`
    static CppExpr lambda(const std::string& capture,
                          const std::string& params,
                          const std::string& body) {
        return CppExpr("[" + capture + "](" + params + "){ " + body + " }");
    }

    // Immediately invoked lambda: `[capture](params){ body }(args)`
    static CppExpr iife(const std::string& capture,
                        const std::string& params,
                        const std::string& body,
                        const std::vector<CppExpr>& args = {}) {
        return CppExpr("[" + capture + "](" + params + "){ " + body + " }(" +
                        join_args(args) + ")");
    }

    // ── Static helpers ───────────────────────────────────────
    static CppExpr static_call(const std::string& func,
                               const std::vector<CppExpr>& args = {}) {
        return CppExpr(func + "(" + join_args(args) + ")");
    }
    static CppExpr template_call(const std::string& func,
                                 const std::string& type_args,
                                 const std::vector<CppExpr>& args = {}) {
        return CppExpr(func + "<" + type_args + ">(" + join_args(args) + ")");
    }
    static CppExpr new_expr(const std::string& type,
                            const std::vector<CppExpr>& args = {}) {
        return CppExpr("new " + type + "(" + join_args(args) + ")");
    }
    static CppExpr delete_expr(const CppExpr& expr) {
        return CppExpr("delete " + expr.code_);
    }

    // ── Conversion ───────────────────────────────────────────
    const std::string& str() const { return code_; }
    operator std::string() const { return code_; }
    bool empty() const { return code_.empty(); }

    // Generic binary operator (for dynamic op strings)
    CppExpr bin_op(const std::string& op, const CppExpr& rhs) const {
        return CppExpr("(" + code_ + " " + op + " " + rhs.code_ + ")");
    }

private:
    std::string code_;

    static std::string join_args(const std::vector<CppExpr>& args) {
        std::string result;
        for (size_t i = 0; i < args.size(); ++i) {
            if (i > 0) result += ", ";
            result += args[i].code_;
        }
        return result;
    }
};

}  // namespace ball
