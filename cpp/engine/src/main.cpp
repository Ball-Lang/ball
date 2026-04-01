#include <iostream>
#include <fstream>
#include <sstream>
#include <google/protobuf/util/json_util.h>
#include "engine.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <program.ball.json>" << std::endl;
        return 1;
    }

    std::ifstream file(argv[1]);
    if (!file) {
        std::cerr << "Could not open " << argv[1] << std::endl;
        return 1;
    }

    std::stringstream buffer;
    buffer << file.rdbuf();

    ball::v1::Program program;
    google::protobuf::util::JsonParseOptions options;
    options.ignore_unknown_fields = true;
    
    auto status = google::protobuf::util::JsonStringToMessage(buffer.str(), &program, options);
    if (!status.ok()) {
        std::cerr << "Failed to parse JSON: " << status.message() << std::endl;
        return 1;
    }

    ball::Engine engine(program);
    std::any result = engine.run();

    if (result.has_value()) {
        if (result.type() == typeid(int64_t)) {
            std::cout << "Result: " << std::any_cast<int64_t>(result) << std::endl;
        } else if (result.type() == typeid(double)) {
            std::cout << "Result: " << std::any_cast<double>(result) << std::endl;
        } else if (result.type() == typeid(std::string)) {
            std::cout << "Result: " << std::any_cast<std::string>(result) << std::endl;
        } else if (result.type() == typeid(bool)) {
            std::cout << "Result: " << (std::any_cast<bool>(result) ? "true" : "false") << std::endl;
        }
    }

    return 0;
}
