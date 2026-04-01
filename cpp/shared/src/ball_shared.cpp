#include "ball_shared.h"

namespace ball {

// ================================================================
// Struct ↔ map conversion
// ================================================================

BallValue value_proto_to_ball(const google::protobuf::Value& v) {
    switch (v.kind_case()) {
        case google::protobuf::Value::kNullValue:
            return {};
        case google::protobuf::Value::kNumberValue:
            return v.number_value();
        case google::protobuf::Value::kStringValue:
            return v.string_value();
        case google::protobuf::Value::kBoolValue:
            return v.bool_value();
        case google::protobuf::Value::kListValue: {
            BallList list;
            for (const auto& elem : v.list_value().values()) {
                list.push_back(value_proto_to_ball(elem));
            }
            return list;
        }
        case google::protobuf::Value::kStructValue:
            return struct_to_map(v.struct_value());
        default:
            return {};
    }
}

BallMap struct_to_map(const google::protobuf::Struct& s) {
    BallMap result;
    for (const auto& [key, val] : s.fields()) {
        result[key] = value_proto_to_ball(val);
    }
    return result;
}

// ================================================================
// Proto builder helpers (private)
// ================================================================

namespace {

using google::protobuf::DescriptorProto;
using google::protobuf::FieldDescriptorProto;

FieldDescriptorProto* add_field(
    DescriptorProto* type,
    const std::string& name,
    int number,
    FieldDescriptorProto::Type field_type,
    const std::string& type_name = ""
) {
    auto* f = type->add_field();
    f->set_name(name);
    f->set_number(number);
    f->set_type(field_type);
    f->set_label(FieldDescriptorProto::LABEL_OPTIONAL);
    if (!type_name.empty()) f->set_type_name(type_name);
    return f;
}

DescriptorProto* make_type(
    const std::string& name,
    std::vector<std::tuple<std::string, int, FieldDescriptorProto::Type, std::string>> fields
) {
    auto* type = new DescriptorProto();
    type->set_name(name);
    for (const auto& [fname, fnum, ftype, ftname] : fields) {
        add_field(type, fname, fnum, ftype, ftname);
    }
    return type;
}

ball::v1::FunctionDefinition make_fn(
    const std::string& name,
    const std::string& input_type,
    const std::string& output_type,
    const std::string& description
) {
    ball::v1::FunctionDefinition fn;
    fn.set_name(name);
    fn.set_input_type(input_type);
    fn.set_output_type(output_type);
    fn.set_description(description);
    fn.set_is_base(true);
    return fn;
}

const auto EXPR = FieldDescriptorProto::TYPE_MESSAGE;
const auto STRING = FieldDescriptorProto::TYPE_STRING;
const auto BOOL = FieldDescriptorProto::TYPE_BOOL;
const auto INT = FieldDescriptorProto::TYPE_INT64;
const std::string EXPR_TYPE = ".ball.v1.Expression";

}  // namespace

// ================================================================
// build_std_module
// ================================================================

ball::v1::Module build_std_module() {
    ball::v1::Module mod;
    mod.set_name("std");
    mod.set_description("Universal standard library base module.");

    // Types
    auto add_type = [&](DescriptorProto* t) { mod.mutable_types()->AddAllocated(t); };

    add_type(make_type("BinaryInput", {{"left", 1, EXPR, EXPR_TYPE}, {"right", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("UnaryInput", {{"value", 1, EXPR, EXPR_TYPE}}));
    add_type(make_type("PrintInput", {{"message", 1, STRING, ""}}));
    add_type(make_type("IfInput", {{"condition", 1, EXPR, EXPR_TYPE}, {"then", 2, EXPR, EXPR_TYPE}, {"else", 3, EXPR, EXPR_TYPE}, {"case_pattern", 4, STRING, ""}}));
    add_type(make_type("ForInput", {{"init", 1, EXPR, EXPR_TYPE}, {"condition", 2, EXPR, EXPR_TYPE}, {"update", 3, EXPR, EXPR_TYPE}, {"body", 4, EXPR, EXPR_TYPE}}));
    add_type(make_type("ForInInput", {{"variable", 1, STRING, ""}, {"variable_type", 2, STRING, ""}, {"iterable", 3, EXPR, EXPR_TYPE}, {"body", 4, EXPR, EXPR_TYPE}}));
    add_type(make_type("WhileInput", {{"condition", 1, EXPR, EXPR_TYPE}, {"body", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("DoWhileInput", {{"body", 1, EXPR, EXPR_TYPE}, {"condition", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("SwitchInput", {{"subject", 1, EXPR, EXPR_TYPE}, {"cases", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("SwitchCase", {{"value", 1, EXPR, EXPR_TYPE}, {"is_default", 2, BOOL, ""}, {"body", 3, EXPR, EXPR_TYPE}, {"pattern", 4, STRING, ""}}));
    add_type(make_type("TryInput", {{"body", 1, EXPR, EXPR_TYPE}, {"catches", 2, EXPR, EXPR_TYPE}, {"finally", 3, EXPR, EXPR_TYPE}}));
    add_type(make_type("CatchClause", {{"type", 1, STRING, ""}, {"variable", 2, STRING, ""}, {"stack_trace", 3, STRING, ""}, {"body", 4, EXPR, EXPR_TYPE}}));
    add_type(make_type("AssertInput", {{"condition", 1, EXPR, EXPR_TYPE}, {"message", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("AssignInput", {{"target", 1, EXPR, EXPR_TYPE}, {"value", 2, EXPR, EXPR_TYPE}, {"op", 3, STRING, ""}}));
    add_type(make_type("IndexInput", {{"target", 1, EXPR, EXPR_TYPE}, {"index", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("TypeCheckInput", {{"value", 1, EXPR, EXPR_TYPE}, {"type", 2, STRING, ""}}));
    add_type(make_type("BreakInput", {{"label", 1, STRING, ""}}));
    add_type(make_type("ContinueInput", {{"label", 1, STRING, ""}}));
    add_type(make_type("ReturnInput", {{"value", 1, EXPR, EXPR_TYPE}}));
    add_type(make_type("StringSubstringInput", {{"value", 1, EXPR, EXPR_TYPE}, {"start", 2, EXPR, EXPR_TYPE}, {"end", 3, EXPR, EXPR_TYPE}}));
    add_type(make_type("StringReplaceInput", {{"value", 1, EXPR, EXPR_TYPE}, {"from", 2, EXPR, EXPR_TYPE}, {"to", 3, EXPR, EXPR_TYPE}}));
    add_type(make_type("StringRepeatInput", {{"value", 1, EXPR, EXPR_TYPE}, {"count", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("StringPadInput", {{"value", 1, EXPR, EXPR_TYPE}, {"width", 2, EXPR, EXPR_TYPE}, {"padding", 3, EXPR, EXPR_TYPE}}));
    add_type(make_type("MathClampInput", {{"value", 1, EXPR, EXPR_TYPE}, {"min", 2, EXPR, EXPR_TYPE}, {"max", 3, EXPR, EXPR_TYPE}}));

    // Functions
    auto add_fn = [&](const std::string& name, const std::string& it, const std::string& ot, const std::string& desc) {
        *mod.add_functions() = make_fn(name, it, ot, desc);
    };

    // I/O
    add_fn("print", "PrintInput", "", "Print to stdout");
    // Arithmetic
    add_fn("add", "BinaryInput", "", "Addition: left + right");
    add_fn("subtract", "BinaryInput", "", "Subtraction: left - right");
    add_fn("multiply", "BinaryInput", "", "Multiplication: left * right");
    add_fn("divide", "BinaryInput", "", "Integer division: left ~/ right");
    add_fn("divide_double", "BinaryInput", "", "Double division: left / right");
    add_fn("modulo", "BinaryInput", "", "Modulo: left % right");
    add_fn("negate", "UnaryInput", "", "Unary negation: -value");
    // Comparison
    add_fn("equals", "BinaryInput", "", "Equality: left == right");
    add_fn("not_equals", "BinaryInput", "", "Inequality: left != right");
    add_fn("less_than", "BinaryInput", "", "Less than: left < right");
    add_fn("greater_than", "BinaryInput", "", "Greater than: left > right");
    add_fn("lte", "BinaryInput", "", "Less or equal: left <= right");
    add_fn("gte", "BinaryInput", "", "Greater or equal: left >= right");
    // Logical
    add_fn("and", "BinaryInput", "", "Logical AND");
    add_fn("or", "BinaryInput", "", "Logical OR");
    add_fn("not", "UnaryInput", "", "Logical NOT");
    // Bitwise
    add_fn("bitwise_and", "BinaryInput", "", "Bitwise AND");
    add_fn("bitwise_or", "BinaryInput", "", "Bitwise OR");
    add_fn("bitwise_xor", "BinaryInput", "", "Bitwise XOR");
    add_fn("bitwise_not", "UnaryInput", "", "Bitwise NOT");
    add_fn("left_shift", "BinaryInput", "", "Left shift");
    add_fn("right_shift", "BinaryInput", "", "Right shift");
    add_fn("unsigned_right_shift", "BinaryInput", "", "Unsigned right shift");
    // Inc/Dec
    add_fn("pre_increment", "UnaryInput", "", "Prefix increment");
    add_fn("pre_decrement", "UnaryInput", "", "Prefix decrement");
    add_fn("post_increment", "UnaryInput", "", "Postfix increment");
    add_fn("post_decrement", "UnaryInput", "", "Postfix decrement");
    // String & conversion
    add_fn("concat", "BinaryInput", "", "String concatenation");
    add_fn("to_string", "UnaryInput", "", "Convert to string");
    add_fn("length", "UnaryInput", "", "Get length");
    add_fn("int_to_string", "UnaryInput", "", "Int to string");
    add_fn("double_to_string", "UnaryInput", "", "Double to string");
    add_fn("string_to_int", "UnaryInput", "", "Parse int from string");
    add_fn("string_to_double", "UnaryInput", "", "Parse double from string");
    // Null safety
    add_fn("null_coalesce", "BinaryInput", "", "Null coalescing: left ?? right");
    add_fn("null_check", "UnaryInput", "", "Null assertion");
    // Control flow
    add_fn("if", "IfInput", "", "Conditional");
    add_fn("for", "ForInput", "", "C-style for loop");
    add_fn("for_in", "ForInInput", "", "For-in loop");
    add_fn("while", "WhileInput", "", "While loop");
    add_fn("do_while", "DoWhileInput", "", "Do-while loop");
    add_fn("switch", "SwitchInput", "", "Switch statement");
    // Error handling
    add_fn("try", "TryInput", "", "Try-catch-finally");
    add_fn("throw", "UnaryInput", "", "Throw exception");
    add_fn("rethrow", "", "", "Rethrow current exception");
    // Assertions
    add_fn("assert", "AssertInput", "", "Debug assertion");
    // Flow control
    add_fn("return", "ReturnInput", "", "Return from function");
    add_fn("break", "BreakInput", "", "Break from loop/switch");
    add_fn("continue", "ContinueInput", "", "Continue to next iteration");
    // Generators & async
    add_fn("yield", "UnaryInput", "", "Yield from generator");
    add_fn("await", "UnaryInput", "", "Await a future");
    // Assignment
    add_fn("assign", "AssignInput", "", "Assignment");
    // Type operations
    add_fn("is", "TypeCheckInput", "", "Type test");
    add_fn("is_not", "TypeCheckInput", "", "Negated type test");
    add_fn("as", "TypeCheckInput", "", "Type cast");
    // Indexing
    add_fn("index", "IndexInput", "", "Index access");
    // String manipulation
    add_fn("string_length", "UnaryInput", "", "String length");
    add_fn("string_is_empty", "UnaryInput", "", "Is string empty");
    add_fn("string_concat", "BinaryInput", "", "String concat");
    add_fn("string_contains", "BinaryInput", "", "String contains");
    add_fn("string_starts_with", "BinaryInput", "", "Starts with");
    add_fn("string_ends_with", "BinaryInput", "", "Ends with");
    add_fn("string_index_of", "BinaryInput", "", "Index of substring");
    add_fn("string_last_index_of", "BinaryInput", "", "Last index of");
    add_fn("string_substring", "StringSubstringInput", "", "Substring");
    add_fn("string_char_at", "IndexInput", "", "Char at index");
    add_fn("string_char_code_at", "IndexInput", "", "Char code at index");
    add_fn("string_from_char_code", "UnaryInput", "", "From char code");
    add_fn("string_to_upper", "UnaryInput", "", "To upper case");
    add_fn("string_to_lower", "UnaryInput", "", "To lower case");
    add_fn("string_trim", "UnaryInput", "", "Trim whitespace");
    add_fn("string_trim_start", "UnaryInput", "", "Trim start");
    add_fn("string_trim_end", "UnaryInput", "", "Trim end");
    add_fn("string_replace", "StringReplaceInput", "", "Replace first");
    add_fn("string_replace_all", "StringReplaceInput", "", "Replace all");
    add_fn("string_split", "BinaryInput", "", "Split string");
    add_fn("string_repeat", "StringRepeatInput", "", "Repeat string");
    add_fn("string_pad_left", "StringPadInput", "", "Pad left");
    add_fn("string_pad_right", "StringPadInput", "", "Pad right");
    add_fn("string_interpolation", "UnaryInput", "", "String interpolation");
    // Math
    add_fn("math_abs", "UnaryInput", "", "Absolute value");
    add_fn("math_floor", "UnaryInput", "", "Floor");
    add_fn("math_ceil", "UnaryInput", "", "Ceiling");
    add_fn("math_round", "UnaryInput", "", "Round");
    add_fn("math_trunc", "UnaryInput", "", "Truncate");
    add_fn("math_sqrt", "UnaryInput", "", "Square root");
    add_fn("math_pow", "BinaryInput", "", "Power");
    add_fn("math_log", "UnaryInput", "", "Natural logarithm");
    add_fn("math_log2", "UnaryInput", "", "Base-2 logarithm");
    add_fn("math_log10", "UnaryInput", "", "Base-10 logarithm");
    add_fn("math_exp", "UnaryInput", "", "e^x");
    add_fn("math_sin", "UnaryInput", "", "Sine");
    add_fn("math_cos", "UnaryInput", "", "Cosine");
    add_fn("math_tan", "UnaryInput", "", "Tangent");
    add_fn("math_asin", "UnaryInput", "", "Arc sine");
    add_fn("math_acos", "UnaryInput", "", "Arc cosine");
    add_fn("math_atan", "UnaryInput", "", "Arc tangent");
    add_fn("math_atan2", "BinaryInput", "", "Arc tangent 2");
    add_fn("math_min", "BinaryInput", "", "Minimum");
    add_fn("math_max", "BinaryInput", "", "Maximum");
    add_fn("math_clamp", "MathClampInput", "", "Clamp");
    add_fn("math_pi", "", "", "Pi constant");
    add_fn("math_e", "", "", "Euler's number");
    add_fn("math_infinity", "", "", "Infinity");
    add_fn("math_nan", "", "", "NaN");
    add_fn("math_is_nan", "UnaryInput", "", "Is NaN");
    add_fn("math_is_finite", "UnaryInput", "", "Is finite");
    add_fn("math_is_infinite", "UnaryInput", "", "Is infinite");
    add_fn("math_sign", "UnaryInput", "", "Sign");
    add_fn("math_gcd", "BinaryInput", "", "Greatest common divisor");
    add_fn("math_lcm", "BinaryInput", "", "Least common multiple");

    return mod;
}

// ================================================================
// build_std_memory_module
// ================================================================

ball::v1::Module build_std_memory_module() {
    ball::v1::Module mod;
    mod.set_name("std_memory");
    mod.set_description("Linear memory simulation module.");

    auto add_type = [&](DescriptorProto* t) { mod.mutable_types()->AddAllocated(t); };
    auto add_fn = [&](const std::string& name, const std::string& it, const std::string& ot, const std::string& desc) {
        *mod.add_functions() = make_fn(name, it, ot, desc);
    };

    add_type(make_type("AllocInput", {{"size", 1, INT, ""}}));
    add_type(make_type("FreeInput", {{"address", 1, INT, ""}}));
    add_type(make_type("ReallocInput", {{"address", 1, INT, ""}, {"new_size", 2, INT, ""}}));
    add_type(make_type("MemReadInput", {{"address", 1, INT, ""}}));
    add_type(make_type("MemWriteInput", {{"address", 1, INT, ""}, {"value", 2, EXPR, EXPR_TYPE}}));
    add_type(make_type("MemCopyInput", {{"dest", 1, INT, ""}, {"src", 2, INT, ""}, {"size", 3, INT, ""}}));
    add_type(make_type("MemSetInput", {{"address", 1, INT, ""}, {"value", 2, INT, ""}, {"size", 3, INT, ""}}));
    add_type(make_type("MemCompareInput", {{"a", 1, INT, ""}, {"b", 2, INT, ""}, {"size", 3, INT, ""}}));
    add_type(make_type("PtrArithInput", {{"address", 1, INT, ""}, {"offset", 2, INT, ""}, {"element_size", 3, INT, ""}}));
    add_type(make_type("StackAllocInput", {{"size", 1, INT, ""}}));
    add_type(make_type("SizeofInput", {{"type_name", 1, STRING, ""}}));
    add_type(make_type("AddressOfInput", {{"value", 1, EXPR, EXPR_TYPE}}));
    add_type(make_type("DerefInput", {{"pointer", 1, EXPR, EXPR_TYPE}}));

    add_fn("memory_alloc", "AllocInput", "", "Allocate heap bytes");
    add_fn("memory_free", "FreeInput", "", "Free heap block");
    add_fn("memory_realloc", "ReallocInput", "", "Resize heap block");
    add_fn("memory_read_i8", "MemReadInput", "", "Read signed 8-bit int");
    add_fn("memory_read_u8", "MemReadInput", "", "Read unsigned 8-bit int");
    add_fn("memory_read_i16", "MemReadInput", "", "Read signed 16-bit int");
    add_fn("memory_read_u16", "MemReadInput", "", "Read unsigned 16-bit int");
    add_fn("memory_read_i32", "MemReadInput", "", "Read signed 32-bit int");
    add_fn("memory_read_u32", "MemReadInput", "", "Read unsigned 32-bit int");
    add_fn("memory_read_i64", "MemReadInput", "", "Read signed 64-bit int");
    add_fn("memory_read_u64", "MemReadInput", "", "Read unsigned 64-bit int");
    add_fn("memory_read_f32", "MemReadInput", "", "Read 32-bit float");
    add_fn("memory_read_f64", "MemReadInput", "", "Read 64-bit double");
    add_fn("memory_write_i8", "MemWriteInput", "", "Write signed 8-bit int");
    add_fn("memory_write_u8", "MemWriteInput", "", "Write unsigned 8-bit int");
    add_fn("memory_write_i16", "MemWriteInput", "", "Write signed 16-bit int");
    add_fn("memory_write_u16", "MemWriteInput", "", "Write unsigned 16-bit int");
    add_fn("memory_write_i32", "MemWriteInput", "", "Write signed 32-bit int");
    add_fn("memory_write_u32", "MemWriteInput", "", "Write unsigned 32-bit int");
    add_fn("memory_write_i64", "MemWriteInput", "", "Write signed 64-bit int");
    add_fn("memory_write_u64", "MemWriteInput", "", "Write unsigned 64-bit int");
    add_fn("memory_write_f32", "MemWriteInput", "", "Write 32-bit float");
    add_fn("memory_write_f64", "MemWriteInput", "", "Write 64-bit double");
    add_fn("memory_copy", "MemCopyInput", "", "Copy bytes");
    add_fn("memory_set", "MemSetInput", "", "Fill bytes");
    add_fn("memory_compare", "MemCompareInput", "", "Compare bytes");
    add_fn("ptr_add", "PtrArithInput", "", "Pointer add");
    add_fn("ptr_sub", "PtrArithInput", "", "Pointer subtract");
    add_fn("ptr_diff", "PtrArithInput", "", "Pointer difference");
    add_fn("stack_alloc", "StackAllocInput", "", "Stack allocate");
    add_fn("stack_push_frame", "", "", "Push stack frame");
    add_fn("stack_pop_frame", "", "", "Pop stack frame");
    add_fn("memory_sizeof", "SizeofInput", "", "Size of type");
    add_fn("address_of", "AddressOfInput", "", "Take address");
    add_fn("deref", "DerefInput", "", "Dereference pointer");
    add_fn("nullptr", "", "", "Null pointer");
    add_fn("memory_heap_size", "", "", "Heap size");
    add_fn("memory_stack_size", "", "", "Stack usage");

    return mod;
}

// ================================================================
// build_std_collections_module
// ================================================================

ball::v1::Module build_std_collections_module() {
    ball::v1::Module mod;
    mod.set_name("std_collections");
    mod.set_description("Collection operations (list, map).");

    auto add_fn = [&](const std::string& name, const std::string& it, const std::string& ot, const std::string& desc) {
        *mod.add_functions() = make_fn(name, it, ot, desc);
    };

    add_fn("list_push", "BinaryInput", "", "Append to list");
    add_fn("list_pop", "UnaryInput", "", "Remove last element");
    add_fn("list_insert", "BinaryInput", "", "Insert at index");
    add_fn("list_remove_at", "BinaryInput", "", "Remove at index");
    add_fn("list_get", "BinaryInput", "", "Get element");
    add_fn("list_set", "BinaryInput", "", "Set element");
    add_fn("list_length", "UnaryInput", "", "List length");
    add_fn("list_is_empty", "UnaryInput", "", "Is list empty");
    add_fn("list_contains", "BinaryInput", "", "List contains");
    add_fn("list_index_of", "BinaryInput", "", "Index of element");
    add_fn("list_reverse", "UnaryInput", "", "Reverse list");
    add_fn("list_sort", "UnaryInput", "", "Sort list");
    add_fn("list_slice", "BinaryInput", "", "Slice list");
    add_fn("list_map", "BinaryInput", "", "Map over list");
    add_fn("list_filter", "BinaryInput", "", "Filter list");
    add_fn("list_reduce", "BinaryInput", "", "Reduce list");
    add_fn("list_zip", "BinaryInput", "", "Zip two lists");
    add_fn("map_get", "BinaryInput", "", "Get map value");
    add_fn("map_set", "BinaryInput", "", "Set map value");
    add_fn("map_delete", "BinaryInput", "", "Delete map key");
    add_fn("map_keys", "UnaryInput", "", "Map keys");
    add_fn("map_values", "UnaryInput", "", "Map values");
    add_fn("map_entries", "UnaryInput", "", "Map entries");
    add_fn("map_contains_key", "BinaryInput", "", "Map contains key");
    add_fn("map_merge", "BinaryInput", "", "Merge maps");
    add_fn("map_map", "BinaryInput", "", "Map over map");
    add_fn("map_filter", "BinaryInput", "", "Filter map");
    add_fn("string_join", "BinaryInput", "", "Join list with separator");

    return mod;
}

// ================================================================
// build_std_io_module
// ================================================================

ball::v1::Module build_std_io_module() {
    ball::v1::Module mod;
    mod.set_name("std_io");
    mod.set_description("I/O, process control, time, randomness, environment.");

    auto add_fn = [&](const std::string& name, const std::string& it, const std::string& ot, const std::string& desc) {
        *mod.add_functions() = make_fn(name, it, ot, desc);
    };

    add_fn("print_error", "PrintInput", "", "Print to stderr");
    add_fn("read_line", "", "", "Read line from stdin");
    add_fn("exit", "UnaryInput", "", "Exit process");
    add_fn("panic", "UnaryInput", "", "Panic/abort");
    add_fn("sleep_ms", "UnaryInput", "", "Sleep milliseconds");
    add_fn("timestamp_ms", "", "", "Current timestamp ms");
    add_fn("random_int", "BinaryInput", "", "Random int in range");
    add_fn("random_double", "", "", "Random double [0,1)");
    add_fn("env_get", "UnaryInput", "", "Get environment variable");
    add_fn("args_get", "", "", "Get command line args");

    return mod;
}

}  // namespace ball
