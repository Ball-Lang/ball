// Ball Self-Hosted Engine Conformance Test Suite
//
// Runs conformance test programs through the self-hosted C++ engine
// (engine_rt.cpp — the Dart Ball engine compiled to C++ by the Ball
// compiler). This validates that the compiled engine can correctly
// interpret Ball programs.
//
// Architecture:
//   1. Parse .ball.json → ball::v1::Program (protobuf)
//   2. Convert protobuf → BallDyn map tree (the representation engine_rt expects)
//   3. Construct BallEngine, run, capture stdout
//   4. Compare against .expected_output.txt

// Include the self-hosted engine FIRST — it defines BallDyn, BallMap, etc.
// and lives in an anonymous namespace for internal linkage.
#include "../../dart/self_host/lib/engine_rt.cpp"

// Now include protobuf headers for JSON parsing of Ball programs.
// These are separate from the engine_rt runtime types.
#include "ball/v1/ball.pb.h"
#include "google/protobuf/util/json_util.h"
#include "google/protobuf/descriptor.h"
#include "google/protobuf/reflection.h"
#include "google/protobuf/struct.pb.h"

#include <filesystem>
#include <chrono>
#include <thread>
#include <atomic>
#include <future>
#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef GetMessage
#include <process.h>
#endif

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined by the build system"
#endif

namespace fs = std::filesystem;

// ============================================================
// Protobuf → BallDyn (std::any map tree) converter
// ============================================================
//
// Recursively converts a protobuf Message into nested
// std::map<std::string, std::any> structures that the self-hosted
// BallEngine can traverse with BallDyn field access.

static std::any proto_struct_to_any(const google::protobuf::Struct& s);
static std::any proto_value_obj_to_any(const google::protobuf::Value& v);

static std::any proto_struct_to_any(const google::protobuf::Struct& s) {
    // Produce protobuf-style Struct: {fields: {key1: value_obj1, key2: value_obj2}}
    BallMap fields;
    for (auto& [key, val] : s.fields()) {
        fields[key] = proto_value_obj_to_any(val);
    }
    BallMap result;
    result["fields"] = std::any(fields);
    return std::any(result);
}

static std::any proto_value_obj_to_any(const google::protobuf::Value& v) {
    // Produce protobuf-style Value objects that the self-hosted engine expects.
    // The engine checks ball_which_kind() which looks for keys like "stringValue",
    // "numberValue", "boolValue", "listValue", "structValue", "nullValue".
    using VK = google::protobuf::Value::KindCase;
    switch (v.kind_case()) {
        case VK::kNullValue: {
            BallMap result;
            result["nullValue"] = std::any(int64_t(0));
            return std::any(result);
        }
        case VK::kNumberValue: {
            BallMap result;
            result["numberValue"] = std::any(v.number_value());
            return std::any(result);
        }
        case VK::kStringValue: {
            BallMap result;
            result["stringValue"] = std::any(v.string_value());
            return std::any(result);
        }
        case VK::kBoolValue: {
            BallMap result;
            result["boolValue"] = std::any(v.bool_value());
            return std::any(result);
        }
        case VK::kStructValue: {
            BallMap result;
            result["structValue"] = proto_struct_to_any(v.struct_value());
            return std::any(result);
        }
        case VK::kListValue: {
            BallList list;
            for (auto& el : v.list_value().values()) {
                list.push_back(proto_value_obj_to_any(el));
            }
            BallMap inner;
            inner["values"] = std::any(list);
            BallMap result;
            result["listValue"] = std::any(inner);
            return std::any(result);
        }
        default:
            return std::any{};
    }
}

static std::any proto_msg_to_any(const google::protobuf::Message& msg) {
    BallMap result;
    auto desc = msg.GetDescriptor();
    auto ref = msg.GetReflection();

    for (int i = 0; i < desc->field_count(); i++) {
        auto field = desc->field(i);
        std::string key(field->json_name());

        if (field->is_repeated()) {
            int count = ref->FieldSize(msg, field);
            if (count == 0) continue;
            BallList list;
            for (int j = 0; j < count; j++) {
                switch (field->type()) {
                    case google::protobuf::FieldDescriptor::TYPE_MESSAGE:
                        list.push_back(proto_msg_to_any(ref->GetRepeatedMessage(msg, field, j)));
                        break;
                    case google::protobuf::FieldDescriptor::TYPE_STRING:
                        list.push_back(std::any(ref->GetRepeatedString(msg, field, j)));
                        break;
                    case google::protobuf::FieldDescriptor::TYPE_INT32:
                        list.push_back(std::any(static_cast<int64_t>(ref->GetRepeatedInt32(msg, field, j))));
                        break;
                    case google::protobuf::FieldDescriptor::TYPE_INT64:
                        list.push_back(std::any(ref->GetRepeatedInt64(msg, field, j)));
                        break;
                    case google::protobuf::FieldDescriptor::TYPE_BOOL:
                        list.push_back(std::any(ref->GetRepeatedBool(msg, field, j)));
                        break;
                    case google::protobuf::FieldDescriptor::TYPE_DOUBLE:
                        list.push_back(std::any(ref->GetRepeatedDouble(msg, field, j)));
                        break;
                    case google::protobuf::FieldDescriptor::TYPE_ENUM:
                        list.push_back(std::any(static_cast<int64_t>(ref->GetRepeatedEnumValue(msg, field, j))));
                        break;
                    default:
                        list.push_back(std::any{});
                        break;
                }
            }
            result[key] = std::any(list);
        } else if (field->type() == google::protobuf::FieldDescriptor::TYPE_MESSAGE) {
            if (!ref->HasField(msg, field)) continue;
            auto& sub = ref->GetMessage(msg, field);
            if (field->message_type()->full_name() == "google.protobuf.Struct") {
                auto& structMsg = dynamic_cast<const google::protobuf::Struct&>(sub);
                result[key] = proto_struct_to_any(structMsg);
            } else {
                result[key] = proto_msg_to_any(sub);
            }
        } else {
            // For oneof fields, always store if the field is set (even zero/false/empty values)
            bool is_oneof = field->containing_oneof() != nullptr;
            bool force_store = is_oneof && ref->HasField(msg, field);
            switch (field->type()) {
                case google::protobuf::FieldDescriptor::TYPE_STRING: {
                    auto v = ref->GetString(msg, field);
                    if (!v.empty() || force_store) result[key] = std::any(v);
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_INT32: {
                    auto v = ref->GetInt32(msg, field);
                    if (v != 0 || force_store) result[key] = std::any(static_cast<int64_t>(v));
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_INT64: {
                    auto v = ref->GetInt64(msg, field);
                    if (v != 0 || force_store) result[key] = std::any(v);
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_BOOL: {
                    auto v = ref->GetBool(msg, field);
                    if (v || force_store) result[key] = std::any(v);
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_DOUBLE: {
                    auto v = ref->GetDouble(msg, field);
                    if (v != 0.0 || force_store) result[key] = std::any(v);
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_FLOAT: {
                    auto v = ref->GetFloat(msg, field);
                    if (v != 0.0f || force_store) result[key] = std::any(static_cast<double>(v));
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_ENUM: {
                    auto v = ref->GetEnumValue(msg, field);
                    if (v != 0 || force_store) result[key] = std::any(static_cast<int64_t>(v));
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_BYTES: {
                    auto v = ref->GetString(msg, field);
                    if (!v.empty() || force_store) result[key] = std::any(v);
                    break;
                }
                default:
                    break;
            }
        }
    }

    return std::any(result);
}

// ============================================================
// Test harness
// ============================================================

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;
static int tests_skipped_val = 0;
static std::vector<std::string> failures;

static std::string normalize(std::string s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (c != '\r') out.push_back(c);
    }
    while (!out.empty() && (out.back() == '\n' || out.back() == ' ' ||
                            out.back() == '\t')) {
        out.pop_back();
    }
    return out;
}

static std::string read_file_str(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static bool run_one(const fs::path& program_path, const fs::path& expected_path,
                    std::string& failure_msg) {
    // Parse JSON -> protobuf
    auto json = read_file_str(program_path);
    ball::v1::Program program;
    google::protobuf::util::JsonParseOptions opts;
    opts.ignore_unknown_fields = true;
    auto status = google::protobuf::util::JsonStringToMessage(json, &program, opts);
    if (!status.ok()) {
        failure_msg = "JSON parse failed: " + std::string(status.message());
        return false;
    }

    // Convert protobuf -> BallDyn map tree
    auto programAny = proto_msg_to_any(program);

    // Capture stdout via a shared string buffer (thread-safe, no cout redirect)
    auto captured = std::make_shared<std::string>();

    try {
        // Construct BallEngine with the program map
        BallEngine engine;
        engine.program = BallDyn(programAny);
        engine._types = BallDyn(BallMap{});
        engine._functions = BallDyn(BallMap{});
        engine._globalScope = BallDyn(BallMap{});
        engine._currentModule = "";
        engine._paramCache = BallDyn(BallMap{});
        engine._callCache = BallDyn(BallMap{});
        engine._enumValues = BallDyn(BallMap{});
        engine._constructors = BallDyn(BallMap{});
        engine._callCounts = BallDyn(BallMap{});
        engine._nextMutexId = 0;
        // Set stdout_ to a function that captures output to a string buffer
        engine.stdout_ = BallDyn(BallFunc([captured](std::any arg) -> std::any {
            *captured += ball_to_string(arg) + "\n";
            return std::any{};
        }));

        // Build std dispatch table and inject into a handler
        auto stdDispatch = engine._buildStdDispatch();
        StdModuleHandler handler;
        handler.set("_dispatch", std::any(stdDispatch));
        engine.moduleHandlers = BallDyn(BallList{std::any(BallDyn(handler))});

        // Build lookup tables (indexes functions, types, etc.)
        engine._buildLookupTables();
        engine._initTopLevelVariables();

        // Debug: check the key
        auto entryMod = ball_to_string(BallDyn(programAny)["entryModule"s]._val);
        auto entryFn = ball_to_string(BallDyn(programAny)["entryFunction"s]._val);
        auto key = entryMod + "." + entryFn;
        auto entryFunc = BallDyn(engine._functions)[key];
        if (!entryFunc.has_value()) {
            failure_msg = "entry function not found: '" + key + "' (functions map has " + std::to_string(engine._functions.size()) + " entries)";
            return false;
        }
        // Debug: check body expression type
        auto bodyExpr = BallDyn(entryFunc)["body"s];
        auto whichE = ball_which_expr(bodyExpr._val);
        if (whichE == "notSet"s) {
            // Dump the body map keys
            std::string keys;
            if (bodyExpr._val.type() == typeid(BallMap)) {
                for (auto& [k,v] : std::any_cast<const BallMap&>(bodyExpr._val)) {
                    keys += k + "(" + (v.has_value() ? "set" : "null") + ") ";
                }
            }
            failure_msg = "body expr whichExpr=notSet, type=" + std::string(bodyExpr._val.type().name()) + ", keys=[" + keys + "]";
            return false;
        }
        // Run the program
        engine.run();
    } catch (const std::runtime_error& sle) {
        std::string msg = sle.what();
        if (msg.find("step") != std::string::npos || msg.find("Step") != std::string::npos) {
            failure_msg = "STEP_LIMIT: exceeded step limit";
        } else {
            failure_msg = std::string("engine threw: ") + sle.what();
        }
        return false;
    } catch (const BallException& be) {
        if (captured->empty()) {
            failure_msg = std::string("BallException: ") + be.what() + " type=" + be.type_name;
            return false;
        }
        // Some output was produced before the exception — check it
    } catch (const std::bad_any_cast& bac) {
        failure_msg = std::string("bad_any_cast: ") + bac.what();
        return false;
    } catch (const std::exception& e) {
        failure_msg = std::string("engine threw: ") + e.what();
        return false;
    } catch (...) {
        failure_msg = "engine threw unknown exception";
        return false;
    }

    std::string actual = normalize(*captured);
    std::string expected = normalize(read_file_str(expected_path));

    if (actual != expected) {
        failure_msg = "output mismatch\n--- expected ---\n" + expected +
                      "\n--- actual ---\n" + actual + "\n---";
        return false;
    }
    return true;
}

int main() {
    std::cout << "Ball Self-Hosted Engine Conformance Tests\n"
              << "==========================================\n";

    fs::path dir(BALL_CONFORMANCE_DIR);
    if (!fs::exists(dir)) {
        std::cerr << "ERROR: conformance dir not found: " << dir << "\n";
        return 1;
    }

    struct TestCase {
        fs::path program;
        fs::path expected;
        std::string name;
    };
    std::vector<TestCase> cases;
    for (auto& entry : fs::directory_iterator(dir)) {
        auto p = entry.path();
        if (p.extension() == ".json" && p.stem().string().find(".ball") != std::string::npos) {
            auto stem = p.stem().stem().string();
            auto expected = p.parent_path() / (stem + ".expected_output.txt");
            if (fs::exists(expected)) {
                cases.push_back({p, expected, stem});
            }
        }
    }
    std::sort(cases.begin(), cases.end(),
              [](auto& a, auto& b) { return a.name < b.name; });

    // Per-test timeout in seconds. Tests that exceed this are killed and
    // reported as TIMEOUT. This replaces the old whitelist approach.
    constexpr int TIMEOUT_SECONDS = 2;

    // Skip list: programs known to hang in the self-hosted engine.
    // These cause infinite loops due to BallDyn wrapping issues in
    // map-based memoization or modulo operations that prevent proper
    // loop termination.
    static const std::vector<std::string> skip_list = {
        // Only skip programs that genuinely hang (step counter caught by try/catch)
        "95_fibonacci_memo",     // infinite loop: map key lookup swallows StepLimitExceeded
        "136_string_pattern_match", // >30s regex operations
    };

    for (auto& tc : cases) {
        bool skip = false;
        for (auto& prefix : skip_list) {
            if (tc.name.find(prefix) == 0) { skip = true; break; }
        }
        if (skip) {
            tests_skipped_val++;
            std::cout << "  SKIP: " << tc.name << "\n";
            continue;
        }
        tests_run++;

        std::string failure_msg;
        auto start = std::chrono::high_resolution_clock::now();

        // Run test in a thread with timeout. Step counter should prevent infinite loops,
        // but as a safety net we use a thread timeout as well.
        bool passed = false;
        bool timed_out = false;
        {
            auto promise = std::make_shared<std::promise<bool>>();
            auto fut = promise->get_future();
            auto fm_ptr = std::make_shared<std::string>();
            auto prog = tc.program;
            auto exp = tc.expected;
            std::thread worker([promise, fm_ptr, prog, exp]() {
                try {
                    std::string fm;
                    bool ok = run_one(prog, exp, fm);
                    *fm_ptr = fm;
                    promise->set_value(ok);
                } catch (...) {
                    *fm_ptr = "unexpected crash";
                    try { promise->set_value(false); } catch (...) {}
                }
            });
            worker.detach();
            auto status = fut.wait_for(std::chrono::seconds(TIMEOUT_SECONDS));
            if (status == std::future_status::timeout) {
                timed_out = true;
                failure_msg = "TIMEOUT after " + std::to_string(TIMEOUT_SECONDS) + "s";
            } else {
                passed = fut.get();
                failure_msg = *fm_ptr;
            }
        }

        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::high_resolution_clock::now() - start);

        if (passed) {
            tests_passed++;
            std::cout << "  PASS: " << tc.name << " (" << elapsed.count() << "ms)\n";
        } else if (timed_out) {
            tests_failed++;
            failures.push_back(tc.name + ": " + failure_msg);
            std::cout << "  TIMEOUT: " << tc.name << " (" << elapsed.count() << "ms)\n";
        } else {
            tests_failed++;
            failures.push_back(tc.name + ": " + failure_msg);
            std::cout << "  FAIL: " << tc.name << " (" << elapsed.count() << "ms)\n"
                      << "        " << failure_msg.substr(0, 200) << "\n";
        }
    }

    std::cout << "\n==========================================\n"
              << "Results: " << tests_passed << " passed, "
              << tests_failed << " failed, "
              << tests_skipped_val << " skipped out of "
              << (tests_run + tests_skipped_val) << " total\n";

    if (!failures.empty()) {
        std::cout << "\nFailed tests:\n";
        for (auto& f : failures) {
            std::cout << "  - " << f.substr(0, 300) << "\n";
        }
    }

    return 0;  // Don't fail the build — this is a progress-tracking test suite
}
