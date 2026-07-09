// Ball Self-Hosted Engine Conformance Test Suite
//
// Runs conformance test programs through the self-hosted C++ engine
// (engine_rt.cpp — the Dart Ball engine compiled to C++ by the Ball
// compiler). This validates that the compiled engine can correctly
// interpret Ball programs.
//
// Architecture (#18 Stage 5 — libprotobuf-free):
//   1. Parse .ball.json (proto3-JSON) via nlohmann/json
//   2. Convert JSON → BallDyn map tree (the representation engine_rt expects)
//   3. Construct BallEngine, run, capture stdout
//   4. Compare against .expected_output.txt

// Self-hosted engine: multi-TU (ball_rt namespace) or legacy single .cpp include.
#if defined(BALL_SELFHOST_MULTI_TU)
#include "engine_rt_link.hpp"
#else
#include "../../dart/self_host/lib/engine_rt.cpp"
#endif

// #18 Stage 5: no libprotobuf. Ball programs are parsed straight from
// proto3-JSON (nlohmann/json) into the BallDyn map tree the engine expects —
// the same tree the former google-reflection converter produced.
#include <nlohmann/json.hpp>

#include <cmath>
#include <filesystem>
#include <limits>
#include <chrono>
#ifdef _WIN32
// Neutralize the windows.h GetMessage macro so it cannot clash with protobuf's
// Message API (windows.h can be pulled in transitively on MSVC builds).
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#undef GetMessage
#endif

#ifndef BALL_CONFORMANCE_DIR
#error "BALL_CONFORMANCE_DIR must be defined by the build system"
#endif

namespace fs = std::filesystem;

// ============================================================
// proto3-JSON -> BallDyn (std::any map tree) converter (#18 Stage 5)
// ============================================================
//
// Reproduces the exact tree the former google-reflection `proto_msg_to_any`
// built, but straight from the fixture's proto3-JSON via nlohmann/json (no
// libprotobuf). Contract, mirroring the reflection path the compiled engine
// was validated against:
//   - object            -> BallMap (recursing per key); `metadata` (a
//                          google.protobuf.Struct) -> the Struct wire shape
//                          {fields: {k: {stringValue|numberValue|...}}}
//   - array             -> BallList
//   - Literal.intValue  -> int64  (proto3-JSON encodes int64 as a string)
//   - Literal.doubleValue -> double (incl. "NaN"/"Infinity"/"-Infinity")
//   - Literal.bytesValue -> BallList<int64> (base64-decoded, like protobuf's
//                          bytes -> List<int>, issue #266)
//   - other number      -> int64 if integral, else double
//   - the "@type" envelope key is skipped
// All 324 conformance fixtures are canonical camelCase proto3-JSON (verified),
// so keys pass through verbatim — matching FieldDescriptor::json_name().

static std::any json_to_any(const nlohmann::json& j, const std::string& key);

static double parse_double_special(const std::string& sv) {
    if (sv == "NaN") return std::nan("");
    if (sv == "Infinity") return std::numeric_limits<double>::infinity();
    if (sv == "-Infinity") return -std::numeric_limits<double>::infinity();
    return std::stod(sv);
}

// base64 (proto3-JSON bytes) -> BallList of int64 byte values.
static std::any base64_to_bytelist(const std::string& b64) {
    static const std::string T =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    BallList out;
    int val = 0, bits = -8;
    for (char c : b64) {
        if (c == '=' || c == '\n' || c == '\r' || c == ' ') continue;
        auto pos = T.find(c);
        if (pos == std::string::npos) continue;
        val = (val << 6) | static_cast<int>(pos);
        bits += 6;
        if (bits >= 0) {
            out.push_back(std::any(static_cast<int64_t>((val >> bits) & 0xFF)));
            bits -= 8;
        }
    }
    return std::any(out);
}

// A single google.protobuf.Value (inside a Struct) -> the wire-shape wrapper
// the engine's ball_which_kind() dispatches on.
static std::any json_struct_value(const nlohmann::json& v) {
    BallMap result;
    if (v.is_null()) {
        result["nullValue"] = std::any(static_cast<int64_t>(0));
    } else if (v.is_boolean()) {
        result["boolValue"] = std::any(v.get<bool>());
    } else if (v.is_number()) {
        result["numberValue"] = std::any(v.get<double>());
    } else if (v.is_string()) {
        result["stringValue"] = std::any(v.get<std::string>());
    } else if (v.is_array()) {
        BallList list;
        for (const auto& el : v) list.push_back(json_struct_value(el));
        BallMap inner;
        inner["values"] = std::any(list);
        result["listValue"] = std::any(inner);
    } else if (v.is_object()) {
        BallMap fields;
        for (auto it = v.begin(); it != v.end(); ++it) {
            fields[it.key()] = json_struct_value(it.value());
        }
        BallMap inner;
        inner["fields"] = std::any(fields);
        result["structValue"] = std::any(inner);
    }
    return std::any(result);
}

// A google.protobuf.Struct (a `metadata` object) -> {fields: {k: value_obj}}.
static std::any json_struct(const nlohmann::json& obj) {
    BallMap fields;
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        fields[it.key()] = json_struct_value(it.value());
    }
    BallMap result;
    result["fields"] = std::any(fields);
    return std::any(result);
}

static std::any json_to_any(const nlohmann::json& j, const std::string& key) {
    if (j.is_null()) return std::any{};
    if (j.is_boolean()) return std::any(j.get<bool>());
    if (j.is_string()) {
        const std::string& sv = j.get_ref<const nlohmann::json::string_t&>();
        if (key == "intValue" || key == "int_value")
            return std::any(static_cast<int64_t>(std::stoll(sv)));
        if (key == "doubleValue" || key == "double_value")
            return std::any(parse_double_special(sv));
        if (key == "bytesValue" || key == "bytes_value")
            return base64_to_bytelist(sv);
        return std::any(sv);
    }
    if (j.is_number_float()) return std::any(j.get<double>());
    if (j.is_number()) {  // integer / unsigned
        if (key == "doubleValue" || key == "double_value")
            return std::any(static_cast<double>(j.get<int64_t>()));
        return std::any(static_cast<int64_t>(j.get<int64_t>()));
    }
    if (j.is_array()) {
        BallList list;
        for (const auto& el : j) list.push_back(json_to_any(el, key));
        return std::any(list);
    }
    if (j.is_object()) {
        if (key == "metadata") return json_struct(j);
        BallMap m;
        for (auto it = j.begin(); it != j.end(); ++it) {
            if (it.key() == "@type") continue;  // strip the Any envelope key
            m[it.key()] = json_to_any(it.value(), it.key());
        }
        return std::any(m);
    }
    return std::any{};
}

// Convert a whole Program/Module proto3-JSON object into the engine's map tree.
static std::any program_json_to_any(const nlohmann::json& j) {
    return json_to_any(j, "");
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
    // Parse the self-describing proto3-JSON Any envelope -> BallDyn map tree.
    auto json = read_file_str(program_path);
    std::any programAny;
    try {
        programAny = program_json_to_any(nlohmann::json::parse(json));
    } catch (const std::exception& e) {
        failure_msg = std::string("ball file decode failed: ") + e.what();
        return false;
    }

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

// ============================================================
// std_fs directory-ops self-host test
// ============================================================
//
// Regression for the fail-loud-invariant violation where the self-hosted
// runtime's Directory ops (listSync/createSync/existsSync in
// cpp/shared/include/ball_emit_runtime.h) were silent-degradation stubs:
// dir_list returned [], dir_exists returned false, and dir_create was a no-op,
// so any Ball program using std_fs.dir_* computed wrong results with no error.
//
// This is NOT a shared-corpus fixture (tests/conformance/*.ball.json):
//   * filesystem side effects aren't portable golden output, and
//   * the Dart encoder cannot emit std_fs.dir_* from ordinary source,
// so no corpus fixture exercises these ops. Instead we run an inline Ball
// program through the SAME self-hosted BallEngine (engine_rt) the corpus uses,
// proving the runtime now does real filesystem work. The test owns an isolated
// temp directory (chdir + cleanup) so the program's relative paths are
// deterministic and it leaves no artifacts behind.
//
// The program: create ./sub, write ./sub/a.txt into it, then print
//   dir_exists("sub")   -> true   (was false under the stub → also proves dir_create)
//   dir_exists("nope")  -> false  (control)
//   dir_list("sub").length -> 1   (was 0 under the stub; a NON-empty dir is
//                                   essential — an empty dir lists as [] under
//                                   BOTH the stub and the fix, hiding the bug)
static bool run_fs_dir_selfhost(std::string& failure_msg) {
    // typeName is omitted on every messageCreation: an empty typeName makes the
    // engine build a plain field map (no type/function resolution), exactly the
    // {path:...} / {message:...} shape the std_fs / std handlers expect.
    static const char* kProgram = R"BALLJSON({
  "@type": "type.googleapis.com/ball.v1.Program",
  "name": "selfhost_std_fs_dir",
  "version": "1.0.0",
  "modules": [
    {
      "name": "std",
      "functions": [ { "name": "print", "isBase": true } ]
    },
    {
      "name": "std_fs",
      "functions": [
        { "name": "dir_create", "isBase": true },
        { "name": "dir_exists", "isBase": true },
        { "name": "dir_list", "isBase": true },
        { "name": "file_write", "isBase": true }
      ]
    },
    {
      "name": "main",
      "moduleImports": [ { "name": "std" }, { "name": "std_fs" } ],
      "functions": [
        {
          "name": "main",
          "outputType": "void",
          "body": {
            "block": {
              "statements": [
                { "expression": { "call": {
                  "module": "std_fs", "function": "dir_create",
                  "input": { "messageCreation": { "fields": [
                    { "name": "path", "value": { "literal": { "stringValue": "sub" } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std_fs", "function": "file_write",
                  "input": { "messageCreation": { "fields": [
                    { "name": "path", "value": { "literal": { "stringValue": "sub/a.txt" } } },
                    { "name": "content", "value": { "literal": { "stringValue": "x" } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std", "function": "print",
                  "input": { "messageCreation": { "fields": [
                    { "name": "message", "value": { "call": {
                      "module": "std_fs", "function": "dir_exists",
                      "input": { "messageCreation": { "fields": [
                        { "name": "path", "value": { "literal": { "stringValue": "sub" } } }
                      ] } } } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std", "function": "print",
                  "input": { "messageCreation": { "fields": [
                    { "name": "message", "value": { "call": {
                      "module": "std_fs", "function": "dir_exists",
                      "input": { "messageCreation": { "fields": [
                        { "name": "path", "value": { "literal": { "stringValue": "nope" } } }
                      ] } } } } }
                  ] } } } } }
              ],
              "result": { "call": {
                "module": "std", "function": "print",
                "input": { "messageCreation": { "fields": [
                  { "name": "message", "value": { "fieldAccess": {
                    "object": { "call": {
                      "module": "std_fs", "function": "dir_list",
                      "input": { "messageCreation": { "fields": [
                        { "name": "path", "value": { "literal": { "stringValue": "sub" } } }
                      ] } } } },
                    "field": "length"
                  } } }
                ] } } } }
            }
          }
        }
      ]
    }
  ],
  "entryModule": "main",
  "entryFunction": "main"
})BALLJSON";
    const std::string expected = "true\nfalse\n1";

    // Isolated, deterministic workspace under the system temp dir. Relative
    // paths in the program resolve against it after we chdir, so the program
    // stays path-independent and portable.
    std::error_code ec;
    fs::path base = fs::temp_directory_path(ec) /
        ("ball_selfhost_fs_" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::remove_all(base, ec);
    fs::create_directories(base, ec);
    if (ec) { failure_msg = "temp setup failed: " + ec.message(); return false; }
    fs::path oldCwd = fs::current_path(ec);
    fs::current_path(base, ec);
    if (ec) {
        failure_msg = "chdir to temp failed: " + ec.message();
        fs::remove_all(base, ec);
        return false;
    }

    std::string captured;
    std::string run_err;
    bool ran = false;
    try {
        // Mirror run_one's engine construction (the well-exercised corpus path).
        auto programAny = program_json_to_any(nlohmann::json::parse(kProgram));
        auto cap = std::make_shared<std::string>();

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
        engine.stdout_ = BallDyn(BallFunc([cap](std::any arg) -> std::any {
            *cap += ball_to_string(arg) + "\n";
            return std::any{};
        }));

        auto stdDispatch = engine._buildStdDispatch();
        StdModuleHandler handler(BallMap{{"_dispatch", std::any(stdDispatch)}});
        engine.moduleHandlers = BallDyn(BallList{std::any(BallDyn(handler))});

        engine._buildLookupTables();
        engine._initTopLevelVariables();
        engine.run();

        captured = *cap;
        ran = true;
    } catch (const BallException& be) {
        run_err = std::string("BallException: ") + be.what();
    } catch (const std::exception& e) {
        run_err = std::string("engine threw: ") + e.what();
    } catch (...) {
        run_err = "engine threw unknown exception";
    }

    // Always restore the CWD and remove the temp workspace, even on failure.
    fs::current_path(oldCwd, ec);
    fs::remove_all(base, ec);

    if (!ran) { failure_msg = run_err; return false; }
    std::string actual = normalize(captured);
    if (actual != normalize(expected)) {
        failure_msg = "output mismatch\n--- expected ---\n" + normalize(expected) +
                      "\n--- actual ---\n" + actual + "\n---";
        return false;
    }
    return true;
}

// ----------------------------------------------------------------------
// Self-host-only: std_fs write ops (issue #310) — `writeAsBytesSync` was a
// pure no-op stub (bytes silently dropped) and `writeAsStringSync` ignored
// its FileMode argument (always truncated, so `file_append` silently
// overwrote instead of appending). Same pattern as run_fs_dir_selfhost:
// proves the runtime now does real filesystem work. The program:
//   1. file_write_bytes 7 bytes (including an embedded NUL, to prove this
//      isn't a naive C-string copy: [72,101,108,108,111,0,33] = "Hello\0!"),
//      then file_read_bytes it back and assert length==7 and the first,
//      NUL, and last byte values round-trip exactly (was 0/null under the
//      stub — writing nothing left the file empty or absent).
//   2. file_write "abc", file_append "def", then file_read: must yield
//      "abcdef" (was "def" — a truncating overwrite — under the bug).
// Isolated temp dir + cleanup, mirroring run_fs_dir_selfhost.
static bool run_fs_write_selfhost(std::string& failure_msg) {
    // Bytes literal "SGVsbG8AIQ==" is the base64 (proto3-JSON `bytes`
    // encoding) of the 7 raw bytes [72,101,108,108,111,0,33].
    static const char* kProgram = R"BALLJSON({
  "@type": "type.googleapis.com/ball.v1.Program",
  "name": "selfhost_std_fs_write",
  "version": "1.0.0",
  "modules": [
    {
      "name": "std",
      "functions": [ { "name": "print", "isBase": true } ]
    },
    {
      "name": "std_collections",
      "functions": [ { "name": "list_get", "isBase": true } ]
    },
    {
      "name": "std_fs",
      "functions": [
        { "name": "file_write_bytes", "isBase": true },
        { "name": "file_read_bytes", "isBase": true },
        { "name": "file_write", "isBase": true },
        { "name": "file_append", "isBase": true },
        { "name": "file_read", "isBase": true }
      ]
    },
    {
      "name": "main",
      "moduleImports": [ { "name": "std" }, { "name": "std_fs" }, { "name": "std_collections" } ],
      "functions": [
        {
          "name": "main",
          "outputType": "void",
          "body": {
            "block": {
              "statements": [
                { "expression": { "call": {
                  "module": "std_fs", "function": "file_write_bytes",
                  "input": { "messageCreation": { "fields": [
                    { "name": "path", "value": { "literal": { "stringValue": "bytes.bin" } } },
                    { "name": "content", "value": { "literal": { "bytesValue": "SGVsbG8AIQ==" } } }
                  ] } } } } },
                { "let": {
                  "name": "bytesRead",
                  "value": { "call": {
                    "module": "std_fs", "function": "file_read_bytes",
                    "input": { "messageCreation": { "fields": [
                      { "name": "path", "value": { "literal": { "stringValue": "bytes.bin" } } }
                    ] } } } }
                } },
                { "expression": { "call": {
                  "module": "std", "function": "print",
                  "input": { "messageCreation": { "fields": [
                    { "name": "message", "value": { "fieldAccess": {
                      "object": { "reference": { "name": "bytesRead" } },
                      "field": "length"
                    } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std", "function": "print",
                  "input": { "messageCreation": { "fields": [
                    { "name": "message", "value": { "call": {
                      "module": "std_collections", "function": "list_get",
                      "input": { "messageCreation": { "fields": [
                        { "name": "list", "value": { "reference": { "name": "bytesRead" } } },
                        { "name": "index", "value": { "literal": { "intValue": "0" } } }
                      ] } } } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std", "function": "print",
                  "input": { "messageCreation": { "fields": [
                    { "name": "message", "value": { "call": {
                      "module": "std_collections", "function": "list_get",
                      "input": { "messageCreation": { "fields": [
                        { "name": "list", "value": { "reference": { "name": "bytesRead" } } },
                        { "name": "index", "value": { "literal": { "intValue": "5" } } }
                      ] } } } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std", "function": "print",
                  "input": { "messageCreation": { "fields": [
                    { "name": "message", "value": { "call": {
                      "module": "std_collections", "function": "list_get",
                      "input": { "messageCreation": { "fields": [
                        { "name": "list", "value": { "reference": { "name": "bytesRead" } } },
                        { "name": "index", "value": { "literal": { "intValue": "6" } } }
                      ] } } } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std_fs", "function": "file_write",
                  "input": { "messageCreation": { "fields": [
                    { "name": "path", "value": { "literal": { "stringValue": "text.txt" } } },
                    { "name": "content", "value": { "literal": { "stringValue": "abc" } } }
                  ] } } } } },
                { "expression": { "call": {
                  "module": "std_fs", "function": "file_append",
                  "input": { "messageCreation": { "fields": [
                    { "name": "path", "value": { "literal": { "stringValue": "text.txt" } } },
                    { "name": "content", "value": { "literal": { "stringValue": "def" } } }
                  ] } } } } }
              ],
              "result": { "call": {
                "module": "std", "function": "print",
                "input": { "messageCreation": { "fields": [
                  { "name": "message", "value": { "call": {
                    "module": "std_fs", "function": "file_read",
                    "input": { "messageCreation": { "fields": [
                      { "name": "path", "value": { "literal": { "stringValue": "text.txt" } } }
                    ] } } } } }
                ] } } } }
            }
          }
        }
      ]
    }
  ],
  "entryModule": "main",
  "entryFunction": "main"
})BALLJSON";
    const std::string expected = "7\n72\n0\n33\nabcdef";

    std::error_code ec;
    fs::path base = fs::temp_directory_path(ec) /
        ("ball_selfhost_fswrite_" + std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::remove_all(base, ec);
    fs::create_directories(base, ec);
    if (ec) { failure_msg = "temp setup failed: " + ec.message(); return false; }
    fs::path oldCwd = fs::current_path(ec);
    fs::current_path(base, ec);
    if (ec) {
        failure_msg = "chdir to temp failed: " + ec.message();
        fs::remove_all(base, ec);
        return false;
    }

    std::string captured;
    std::string run_err;
    bool ran = false;
    try {
        auto programAny = program_json_to_any(nlohmann::json::parse(kProgram));
        auto cap = std::make_shared<std::string>();

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
        engine.stdout_ = BallDyn(BallFunc([cap](std::any arg) -> std::any {
            *cap += ball_to_string(arg) + "\n";
            return std::any{};
        }));

        auto stdDispatch = engine._buildStdDispatch();
        StdModuleHandler handler(BallMap{{"_dispatch", std::any(stdDispatch)}});
        engine.moduleHandlers = BallDyn(BallList{std::any(BallDyn(handler))});

        engine._buildLookupTables();
        engine._initTopLevelVariables();
        engine.run();

        captured = *cap;
        ran = true;
    } catch (const BallException& be) {
        run_err = std::string("BallException: ") + be.what();
    } catch (const std::exception& e) {
        run_err = std::string("engine threw: ") + e.what();
    } catch (...) {
        run_err = "engine threw unknown exception";
    }

    fs::current_path(oldCwd, ec);
    fs::remove_all(base, ec);

    if (!ran) { failure_msg = run_err; return false; }
    std::string actual = normalize(captured);
    if (actual != normalize(expected)) {
        failure_msg = "output mismatch\n--- expected ---\n" + normalize(expected) +
                      "\n--- actual ---\n" + actual + "\n---";
        return false;
    }
    return true;
}

int main(int argc, char** argv) {
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
    // Synthetic self-host-only case: std_fs directory ops. Not backed by a
    // corpus fixture (filesystem side effects aren't portable golden output);
    // run_fs_dir_selfhost manages its own temp dir + cleanup. Registered as its
    // own CTest test "selfhost/std_fs_dir" in cpp/test/CMakeLists.txt.
    cases.push_back({fs::path{}, fs::path{}, "std_fs_dir"});
    // Synthetic self-host-only case: std_fs write ops (issue #310) — byte
    // writes + append-mode. Same rationale as std_fs_dir above;
    // run_fs_write_selfhost manages its own temp dir + cleanup. Registered as
    // its own CTest test "selfhost/std_fs_write" in cpp/test/CMakeLists.txt.
    cases.push_back({fs::path{}, fs::path{}, "std_fs_write"});
    std::sort(cases.begin(), cases.end(),
              [](auto& a, auto& b) { return a.name < b.name; });

    // NO skip-list. Every conformance fixture must pass; the host-knob fixtures
    // (196/197/201/202) that have no expected_output.txt are run as behavioral
    // limit-checks below (see host_knobs() / run_one), mirroring
    // dart/engine/test/conformance_test.dart.

    // Select a single fixture by EXACT stem. CTest passes it as argv[1] (one
    // `selfhost/<fixture>` test per fixture — see cpp/test/CMakeLists.txt); the
    // BALL_TEST_FILTER env var is also honored for back-compat. Empty => run
    // all (local convenience). Per-fixture process isolation and the per-test
    // timeout are provided by CTest, not an in-process worker thread.
    std::string only;
    if (argc > 1 && argv[1] && *argv[1]) {
        only = argv[1];
    } else if (const char* env = std::getenv("BALL_TEST_FILTER")) {
        only = env;
    }

    for (auto& tc : cases) {
        if (!only.empty() && tc.name != only) {
            tests_skipped_val++;
            continue;
        }
        tests_run++;

        // Flushed marker so a hard crash (e.g. stack overflow in the worker
        // thread) leaves a trace of the test that triggered it.
        std::cerr << "RUNNING: " << tc.name << std::endl;

        std::string failure_msg;
        auto start = std::chrono::high_resolution_clock::now();

        // Run directly on the MAIN thread, which gets the 256 MB linker stack
        // (cpp/test/CMakeLists.txt) the tree-walking interpreter needs. The old
        // harness ran each fixture on a detached worker thread for an in-process
        // timeout, but on POSIX a worker gets the small default pthread stack
        // (not the linker reserve), so a deep fixture overflowed it — an
        // uncatchable SIGSEGV that killed the whole run. CTest now isolates each
        // fixture in its own process and enforces the timeout, so a crash or
        // hang fails only that fixture.
        bool passed = false;
        try {
            if (tc.name == "std_fs_dir") {
                passed = run_fs_dir_selfhost(failure_msg);
            } else if (tc.name == "std_fs_write") {
                passed = run_fs_write_selfhost(failure_msg);
            } else {
                passed = run_one(tc.program, tc.expected, tc.name, failure_msg);
            }
        } catch (const std::exception& e) {
            failure_msg = std::string("unexpected C++ exception: ") + e.what();
        } catch (...) {
            failure_msg = "unexpected C++ exception";
        }

        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::high_resolution_clock::now() - start);

        if (passed) {
            tests_passed++;
            std::cout << "  PASS: " << tc.name << " (" << elapsed.count() << "ms)\n";
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

    // A specific fixture was requested but no runnable case matched — it has no
    // expected_output.txt and is not a host-knob (an undocumented orphan).
    // Fail loudly rather than silently pass.
    if (!only.empty() && tests_run == 0) {
        std::cerr << "::error:: no runnable self-host conformance case named '"
                  << only << "'\n";
        return 1;
    }

    // Real exit code: CTest treats non-zero as a failed test. Each fixture is
    // its own CTest test, so this fails exactly the fixtures that failed.
    return tests_failed > 0 ? 1 : 0;
}
