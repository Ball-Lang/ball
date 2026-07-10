// `ball run` — execute a Ball program on the self-hosted engine (engine_rt).
//
// Reuses the SAME engine_rt build machinery + proto3-JSON → BallDyn conversion
// as cpp/test/test_selfhost_conformance.cpp (the compiled Dart engine), so a
// program runs identically under `ball run` and under the conformance harness.
// Built only when engine_rt was generated (BALL_SELFHOST_AVAILABLE); otherwise
// cli_run_stub.cpp provides a fail-loud stub.

// Self-hosted engine: multi-TU (namespace ball_rt) or monolithic single .cpp.
// CMake puts dart/self_host/lib (+ the multi-TU engine_rt/) on the include path.
#if defined(BALL_SELFHOST_MULTI_TU)
#include "engine_rt_link.hpp"
#else
#include "engine_rt.cpp"
#endif

#include <nlohmann/json.hpp>

#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>

#include "cli_commands.h"

namespace {

// ── proto3-JSON → BallDyn (std::any map tree) ───────────────────────────────
// Byte-for-byte the converter test_selfhost_conformance uses, so `ball run`
// feeds the compiled engine exactly the tree it was validated against:
//   object → BallMap; `metadata` (a Struct) → its {fields:{k:{...}}} wire shape;
//   array → BallList; Literal.intValue → int64; Literal.doubleValue → double
//   (incl. NaN/Infinity); Literal.bytesValue → List<int64> (base64-decoded);
//   the "@type" envelope key is stripped.

std::any json_to_any(const nlohmann::json& j, const std::string& key);

double parse_double_special(const std::string& sv) {
    if (sv == "NaN") return std::nan("");
    if (sv == "Infinity") return std::numeric_limits<double>::infinity();
    if (sv == "-Infinity") return -std::numeric_limits<double>::infinity();
    return std::stod(sv);
}

std::any base64_to_bytelist(const std::string& b64) {
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

std::any json_struct_value(const nlohmann::json& v) {
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

std::any json_struct(const nlohmann::json& obj) {
    BallMap fields;
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        fields[it.key()] = json_struct_value(it.value());
    }
    BallMap result;
    result["fields"] = std::any(fields);
    return std::any(result);
}

std::any json_to_any(const nlohmann::json& j, const std::string& key) {
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
    if (j.is_number()) {
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
            if (it.key() == "@type") continue;
            m[it.key()] = json_to_any(it.value(), it.key());
        }
        return std::any(m);
    }
    return std::any{};
}

}  // namespace

namespace ballcli {

int cmd_run(const std::vector<std::string>& args) {
    std::string input;
    for (const auto& a : args) {
        if (a.rfind("-", 0) != 0) {
            input = a;
            break;
        }
    }
    if (input.empty()) {
        std::cerr << "Usage: ball run <input.ball.json>\n";
        return 1;
    }

    std::ifstream f(input, std::ios::binary);
    if (!f) {
        std::cerr << "Error: File not found: " << input << "\n";
        return 1;
    }
    std::stringstream ss;
    ss << f.rdbuf();

    std::any programAny;
    try {
        programAny = json_to_any(nlohmann::json::parse(ss.str()), "");
    } catch (const std::exception& e) {
        std::cerr << "Error parsing ball program: " << e.what() << "\n";
        return 1;
    }

    try {
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
        // Stream program output straight to the process stdout.
        engine.stdout_ = BallDyn(BallFunc([](std::any arg) -> std::any {
            std::cout << ball_to_string(arg) << "\n";
            return std::any{};
        }));

        auto stdDispatch = engine._buildStdDispatch();
        StdModuleHandler handler(BallMap{{"_dispatch", std::any(stdDispatch)}});
        engine.moduleHandlers = BallDyn(BallList{std::any(BallDyn(handler))});

        engine._buildLookupTables();
        engine._initTopLevelVariables();
        engine.run();
    } catch (const BallException& be) {
        std::cerr << "Runtime error: " << be.what();
        if (!be.type_name.empty()) std::cerr << " (" << be.type_name << ")";
        std::cerr << "\n";
        return 1;
    } catch (const std::exception& e) {
        std::cerr << "Runtime error: " << e.what() << "\n";
        return 1;
    }
    return 0;
}

}  // namespace ballcli
