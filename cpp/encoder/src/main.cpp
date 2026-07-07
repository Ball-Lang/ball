// ball_cpp_encode CLI — reads a Clang JSON AST and produces a Ball program.
//
// Usage:
//   clang -Xclang -ast-dump=json source.cpp > ast.json
//   ball_cpp_encode ast.json [output.ball.json]

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "encoder.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0]
                  << " <clang_ast.json> [output.ball.json]"
                  << std::endl;
        return 1;
    }

    std::string input_path = argv[1];
    std::string output_path;

    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--normalize") {
            // No-op: normalization is now inlined in the encoder.
            std::cerr << "Warning: --normalize is deprecated (inlined in encoder)."
                      << std::endl;
        } else if (arg == "--binary") {
            // Binary protobuf output required libprotobuf; the encoder is now
            // protobuf-free (#18). Only proto3-JSON `.ball.json` is emitted.
            std::cerr << "Error: --binary output is no longer supported "
                         "(encoder is protobuf-free); emit .ball.json instead."
                      << std::endl;
            return 1;
        } else if (output_path.empty()) {
            output_path = arg;
        }
    }

    // Read input.
    std::ifstream file(input_path);
    if (!file) {
        std::cerr << "Could not open " << input_path << std::endl;
        return 1;
    }
    std::stringstream buffer;
    buffer << file.rdbuf();
    std::string json_str = buffer.str();

    // Encode.
    ball::CppEncoder encoder;
    ball::ir::Program program = encoder.encode_from_clang_ast(json_str);

    // Serialize output as proto3-JSON (self-describing google.protobuf.Any
    // envelope), pretty-printed with a 2-space indent.
    std::string output_data = ball::ir::programToJsonString(program, 2);

    if (!output_path.empty()) {
        std::ofstream out(output_path, std::ios::out);
        if (!out) {
            std::cerr << "Could not open output file " << output_path << std::endl;
            return 1;
        }
        out << output_data;
        std::cerr << "Encoded to " << output_path << std::endl;
    } else {
        std::cout << output_data;
    }

    return 0;
}
