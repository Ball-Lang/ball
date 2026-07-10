// `ball compile` — reuse ball_cpp_compiler_lib behind the unified CLI.
//
// Equivalent to the standalone `ball_cpp_compile` binary (cpp/compiler/src/
// main.cpp), which remains as a thin alias. Reads a .ball.json / .ball.pb
// Program and emits C++ source to --output (or stdout). Library / --split modes
// stay on the dedicated ball_cpp_compile binary (they target the engine_rt /
// ball_protobuf pipelines, not end-user `ball compile`).

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "ball_file.h"
#include "ball_ir.h"
#include "cli_commands.h"
#include "compiler.h"

namespace {

ball::ir::Program load_program_ir(const std::string& path,
                                  const std::string& content) {
    if (ball::detail::is_binary_path(path)) {
        return ball::DecodeProgram(path, content);
    }
    return ball::ir::parseProgramString(content);
}

// Parse `[--output <file>]` and the first positional (the input path).
struct CompileArgs {
    std::string input;
    std::string output;
};

CompileArgs parse_args(const std::vector<std::string>& args) {
    CompileArgs r;
    for (size_t i = 0; i < args.size(); ++i) {
        const std::string& a = args[i];
        if ((a == "--output" || a == "-o") && i + 1 < args.size()) {
            r.output = args[++i];
        } else if (r.input.empty() && a.rfind("-", 0) != 0) {
            r.input = a;
        }
    }
    return r;
}

}  // namespace

namespace ballcli {

int cmd_compile(const std::vector<std::string>& args) {
    const CompileArgs a = parse_args(args);
    if (a.input.empty()) {
        std::cerr << "Usage: ball compile <input.ball.json> [--output <file>]\n";
        return 1;
    }

    std::ifstream file(a.input, std::ios::binary);
    if (!file) {
        std::cerr << "Error: File not found: " << a.input << "\n";
        return 1;
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string content = buffer.str();

    ball::ir::Program program;
    try {
        program = load_program_ir(a.input, content);
    } catch (const std::exception& e) {
        std::cerr << "Failed to read ball file: " << e.what() << "\n";
        return 1;
    }

    std::string out_src;
    try {
        ball::CppCompiler compiler(std::move(program));
        out_src = compiler.compile();
    } catch (const std::exception& e) {
        std::cerr << "Compile error: " << e.what() << "\n";
        return 2;
    }

    if (!a.output.empty()) {
        std::ofstream out(a.output);
        if (!out) {
            std::cerr << "Could not open output file " << a.output << "\n";
            return 1;
        }
        out << out_src;
        std::cerr << "Compiled to " << a.output << "\n";
    } else {
        std::cout << out_src;
    }
    return 0;
}

}  // namespace ballcli
