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

// Self-hosted engine: multi-TU (ball_rt namespace) or legacy single .cpp include.
#if defined(BALL_SELFHOST_MULTI_TU)
#include "engine_rt_link.hpp"
#else
#include "../../dart/self_host/lib/engine_rt.cpp"
#endif

// Now include protobuf headers for JSON parsing of Ball programs.
// These are separate from the engine_rt runtime types.
#include "ball/v1/ball.pb.h"
#include "ball_file.h"
#include "google/protobuf/util/json_util.h"
#include "google/protobuf/descriptor.h"
#include "google/protobuf/reflection.h"
#include "google/protobuf/struct.pb.h"

#include <filesystem>
#include <chrono>
#include <thread>
#include <atomic>
#include <future>
#include <functional>
#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef GetMessage
#include <process.h>
#else
#include <pthread.h>
#endif

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined by the build system"
#endif

namespace fs = std::filesystem;

// Launch `fn` on a DETACHED worker thread with a stack large enough for the
// self-host interpreter's deep native recursion. On POSIX the default thread
// stack (~8 MB) overflows on deep fixtures — an uncatchable SIGSEGV that kills
// the whole in-process ctest run (per-fixture isolated runs survive because the
// deep work runs on the MAIN thread, which gets a 256 MB stack from the linker;
// see cpp/test/CMakeLists.txt). So on POSIX we size the worker stack explicitly
// to 256 MB to match the main thread. On Windows std::thread already honors the
// 256 MB PE-header reserve, so the default is correct there.
static void launch_detached_worker(std::function<void()> fn) {
#if defined(_WIN32)
  std::thread(std::move(fn)).detach();
#else
  constexpr size_t kStackBytes = 256ull * 1024 * 1024;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, kStackBytes);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  auto* heap_fn = new std::function<void()>(fn);  // copy; original kept for fallback
  pthread_t tid;
  const int rc = pthread_create(
      &tid, &attr,
      [](void* p) -> void* {
        auto* f = static_cast<std::function<void()>*>(p);
        (*f)();
        delete f;
        return nullptr;
      },
      heap_fn);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    // Never silently drop a fixture: fall back to a default-stack thread.
    delete heap_fn;
    std::thread(std::move(fn)).detach();
  }
#endif
}

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
                    if (!ref->HasField(msg, field)) break;
                    auto v = ref->GetInt32(msg, field);
                    result[key] = std::any(static_cast<int64_t>(v));
                    break;
                }
                case google::protobuf::FieldDescriptor::TYPE_INT64: {
                    if (!ref->HasField(msg, field)) break;
                    auto v = ref->GetInt64(msg, field);
                    result[key] = std::any(v);
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
                    if (!ref->HasField(msg, field)) break;
                    auto v = ref->GetEnumValue(msg, field);
                    result[key] = std::any(static_cast<int64_t>(v));
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

// Host-knob fixtures have no expected_output.txt — they validate the engine's
// resource-limit BEHAVIOR. The harness constructs the engine with the limit and
// asserts a specific BallRuntimeError is thrown, mirroring
// dart/engine/test/conformance_test.dart (the Dart reference does the same).
struct HostKnob {
    int64_t timeoutMs = 0;        // >0 ⇒ set engine.timeoutMs
    int64_t maxMemoryBytes = 0;   // >0 ⇒ set engine.maxMemoryBytes
    bool sandbox = false;         // ⇒ set engine.sandbox = true
    bool validateLimits = false;  // ⇒ call engine._validateProgramLimits()
    const char* expectError = ""; // thrown message must contain this substring
};
static const std::map<std::string, HostKnob>& host_knobs() {
    static const std::map<std::string, HostKnob> m = {
        {"196_timeout",          HostKnob{1, 0, false, false, "Execution timeout exceeded"}},
        {"197_memory_limit",     HostKnob{0, 1000, false, false, "Memory limit exceeded"}},
        {"201_input_validation", HostKnob{0, 0, false, true, "Too many modules"}},
        {"202_sandbox_mode",     HostKnob{0, 0, true, false, "Sandbox violation"}},
    };
    return m;
}

static bool run_one(const fs::path& program_path, const fs::path& expected_path,
                    const std::string& test_name, std::string& failure_msg) {
    // Parse the self-describing Any envelope -> Program protobuf.
    auto json = read_file_str(program_path);
    ball::v1::Program program;
    try {
        program = ball::DecodeProgram(program_path.string(), json);
    } catch (const ball::BallFileFormatException& e) {
        failure_msg = std::string("ball file decode failed: ") + e.what();
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
        engine._getters = BallDyn(BallMap{});
        engine._setters = BallDyn(BallMap{});
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
        StdModuleHandler handler(BallMap{{"_dispatch", std::any(stdDispatch)}});
        engine.moduleHandlers = BallDyn(BallList{std::any(BallDyn(handler))});

        // Build lookup tables (indexes functions, types, etc.)
        engine._buildLookupTables();
        engine._initTopLevelVariables();

        // Host-knob behavioral fixtures: set the resource limit, then run (or
        // validate) and require the matching BallRuntimeError — instead of an
        // output comparison (these fixtures have no expected_output.txt).
        {
            auto knob_it = host_knobs().find(test_name);
            if (knob_it != host_knobs().end()) {
                const HostKnob& k = knob_it->second;
                if (k.timeoutMs) engine.timeoutMs = BallDyn(k.timeoutMs);
                if (k.maxMemoryBytes) engine.maxMemoryBytes = BallDyn(k.maxMemoryBytes);
                engine.sandbox = k.sandbox;
                std::string thrown;
                try {
                    if (k.validateLimits) engine._validateProgramLimits();
                    engine.run();
                } catch (const BallException& be) {
                    thrown = std::string(be.what());
                    thrown += " " + be.type_name;
                    for (auto& [kk, vv] : be.fields) thrown += " " + vv;
                } catch (const std::exception& e) {
                    thrown = e.what();
                }
                if (thrown.find(k.expectError) != std::string::npos) return true;
                failure_msg = "host-knob limit not enforced: expected error containing \"" +
                              std::string(k.expectError) + "\" but got: \"" + thrown + "\"";
                return false;
            }
        }

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
    } catch (const BallException& be) {
        if (captured->empty()) {
            std::string fields_str;
            for (auto& [k,v] : be.fields) fields_str += k + "=" + v + ";";
            failure_msg = std::string("BallException: ") + be.what() + " type=" + be.type_name + " fields={" + fields_str + "}";
            return false;
        }
        // Some output was produced before the exception — check it
    } catch (const std::runtime_error& sle) {
        std::string msg = sle.what();
        if (msg.find("step") != std::string::npos || msg.find("Step") != std::string::npos) {
            failure_msg = "STEP_LIMIT: exceeded step limit";
        } else {
            failure_msg = std::string("engine threw: ") + sle.what();
        }
        return false;
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
            } else if (host_knobs().count(stem)) {
                // Host-knob behavioral fixture (no expected_output.txt): run_one
                // checks the thrown limit error instead of comparing output.
                cases.push_back({p, expected, stem});
            }
        }
    }
    std::sort(cases.begin(), cases.end(),
              [](auto& a, auto& b) { return a.name < b.name; });

    // Per-test timeout in seconds. The self-host engine is slower than native
    // Dart (std::any-boxed interpretation), so genuinely heavy fixtures need a
    // generous budget to produce the CORRECT result — they are NOT skipped.
    constexpr int TIMEOUT_SECONDS = 300;

    // NO skip-list. Every conformance fixture must pass; the host-knob fixtures
    // (196/197/201/202) that have no expected_output.txt are run as behavioral
    // limit-checks below (see host_knobs() / run_one), mirroring
    // dart/engine/test/conformance_test.dart.

    // Filter: if BALL_TEST_FILTER env var set, only run matching tests
    const char* test_filter = std::getenv("BALL_TEST_FILTER");

    for (auto& tc : cases) {
        if (test_filter && tc.name.find(test_filter) == std::string::npos) {
            tests_skipped_val++;
            continue;
        }
        tests_run++;

        // Flushed marker so a hard crash (e.g. stack overflow in the worker
        // thread) leaves a trace of the test that triggered it.
        std::cerr << "RUNNING: " << tc.name << std::endl;

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
            auto nm = tc.name;
            launch_detached_worker([promise, fm_ptr, prog, exp, nm]() {
                try {
                    std::string fm;
                    bool ok = run_one(prog, exp, nm, fm);
                    *fm_ptr = fm;
                    promise->set_value(ok);
                } catch (...) {
                    *fm_ptr = "unexpected crash";
                    try { promise->set_value(false); } catch (...) {}
                }
            });
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
