// `ball encode` — reuse ball_cpp_encoder_lib behind the unified CLI.
//
// Equivalent to the standalone `ball_cpp_encode` binary (cpp/encoder/src/
// main.cpp), which remains as a thin alias. Reads a Clang JSON AST
// (`clang -Xclang -ast-dump=json source.cpp`) and emits a proto3-JSON ball
// Program to --output (or stdout). The C++ encoder consumes a Clang AST rather
// than raw source (unlike the Dart CLI's `encode`, which parses .dart directly).

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "cli_commands.h"
#include "encoder.h"
#include "ball_ir.h"

namespace ballcli {

int cmd_encode(const std::vector<std::string>& args) {
    std::string input;
    std::string output;
    for (size_t i = 0; i < args.size(); ++i) {
        const std::string& a = args[i];
        if ((a == "--output" || a == "-o") && i + 1 < args.size()) {
            output = args[++i];
        } else if (input.empty() && a.rfind("-", 0) != 0) {
            input = a;
        }
    }

    if (input.empty()) {
        std::cerr << "Usage: ball encode <clang_ast.json> [--output <file>]\n";
        return 1;
    }

    std::ifstream file(input);
    if (!file) {
        std::cerr << "Could not open " << input << "\n";
        return 1;
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string json_str = buffer.str();

    std::string out_data;
    try {
        ball::CppEncoder encoder;
        ball::ir::Program program = encoder.encode_from_clang_ast(json_str);
        out_data = ball::ir::programToJsonString(program, 2);
    } catch (const std::exception& e) {
        std::cerr << "Encode error: " << e.what() << "\n";
        return 2;
    }

    if (!output.empty()) {
        std::ofstream out(output, std::ios::out);
        if (!out) {
            std::cerr << "Could not open output file " << output << "\n";
            return 1;
        }
        out << out_data;
        std::cerr << "Encoded to " << output << "\n";
    } else {
        std::cout << out_data;
    }
    return 0;
}

}  // namespace ballcli
