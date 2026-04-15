// ball::CppCompiler CLI — reads a .ball.json or .ball.pb program and emits C++ source.

#include <cstdlib>
#include <exception>
#include <fstream>
#include <iostream>
#include <sstream>
#include <google/protobuf/util/json_util.h>
#include <google/protobuf/io/coded_stream.h>
#include <google/protobuf/io/zero_copy_stream_impl_lite.h>
#include "compiler.h"

#ifdef _WIN32
#include <windows.h>
#include <crtdbg.h>
static void suppress_windows_crash_dialogs() {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX |
                 SEM_NOOPENFILEERRORBOX);
    _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
    _CrtSetReportMode(_CRT_ERROR, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ERROR, _CRTDBG_FILE_STDERR);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
}
#else
static void suppress_windows_crash_dialogs() {}
#endif

static int run_compile(int argc, char** argv);

int main(int argc, char** argv) {
    suppress_windows_crash_dialogs();
    try {
        return run_compile(argc, argv);
    } catch (const std::exception& e) {
        std::cerr << "Compile error: " << e.what() << std::endl;
        return 2;
    } catch (...) {
        std::cerr << "Compile error: unknown exception" << std::endl;
        return 2;
    }
}

static int run_compile(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <program.ball.json|program.ball.pb> [output.cpp]"
                  << std::endl;
        return 1;
    }

    std::string input_path = argv[1];

    std::ifstream file(input_path, std::ios::binary);
    if (!file) {
        std::cerr << "Could not open " << input_path << std::endl;
        return 1;
    }

    std::stringstream buffer;
    buffer << file.rdbuf();
    std::string content = buffer.str();

    ball::v1::Program program;

    // Detect format: binary protobuf (.ball.pb) or JSON (.ball.json)
    bool is_binary = input_path.size() >= 8 &&
                     input_path.substr(input_path.size() - 8) == ".ball.pb";

    if (is_binary) {
        google::protobuf::io::ArrayInputStream raw(content.data(), static_cast<int>(content.size()));
        google::protobuf::io::CodedInputStream coded(&raw);
        coded.SetRecursionLimit(10000);
        if (!program.ParseFromCodedStream(&coded)) {
            std::cerr << "Failed to parse binary protobuf: " << input_path << std::endl;
            return 1;
        }
    } else {
        google::protobuf::util::JsonParseOptions options;
        options.ignore_unknown_fields = true;

        auto status = google::protobuf::util::JsonStringToMessage(
            content, &program, options);
        if (!status.ok()) {
            std::cerr << "Failed to parse JSON: " << status.message() << std::endl;
            return 1;
        }
    }

    ball::CppCompiler compiler(program);
    std::string output = compiler.compile();

    if (argc >= 3) {
        std::ofstream out(argv[2]);
        if (!out) {
            std::cerr << "Could not open output file " << argv[2] << std::endl;
            return 1;
        }
        out << output;
        std::cerr << "Compiled to " << argv[2] << std::endl;
    } else {
        std::cout << output;
    }

    return 0;
}
