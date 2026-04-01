// ball_cpp_encode CLI — reads a Clang JSON AST and produces a Ball program.
//
// Usage:
//   clang -Xclang -ast-dump=json source.cpp > ast.json
//   ball_cpp_encode ast.json [output.ball.json] [--normalize]

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <google/protobuf/util/json_util.h>

#include "encoder.h"
#include "normalizer.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0]
                  << " <clang_ast.json> [output.ball.json] [--normalize]"
                  << std::endl;
        return 1;
    }

    std::string input_path = argv[1];
    std::string output_path;
    bool do_normalize = false;
    bool output_binary = false;

    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--normalize") {
            do_normalize = true;
        } else if (arg == "--binary") {
            output_binary = true;
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
    ball::v1::Program program = encoder.encode_from_clang_ast(json_str);

    // Optionally normalize.
    if (do_normalize) {
        ball::HybridNormalizer normalizer;
        normalizer.normalize(program);
    }

    // Serialize output.
    std::string output_data;

    if (output_binary) {
        if (!program.SerializeToString(&output_data)) {
            std::cerr << "Failed to serialize to binary protobuf" << std::endl;
            return 1;
        }
    } else {
        google::protobuf::util::JsonPrintOptions print_options;
        print_options.add_whitespace = true;
        print_options.preserve_proto_field_names = true;

        auto status = google::protobuf::util::MessageToJsonString(
            program, &output_data, print_options);
        if (!status.ok()) {
            std::cerr << "Failed to serialize: " << status.message() << std::endl;
            return 1;
        }
    }

    if (!output_path.empty()) {
        std::ofstream out(output_path, output_binary ? std::ios::binary : std::ios::out);
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
