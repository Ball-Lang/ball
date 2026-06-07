// ball::CppCompiler CLI — reads a .ball.json or .ball.pb program and emits C++ source.

#include <cstdlib>
#include <exception>
#include <fstream>
#include <iostream>
#include <sstream>
#include "ball_file.h"
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
        std::cerr << "Usage: " << argv[0]
                  << " <program.ball.json|program.ball.pb> [output.cpp]\n"
                  << "       " << argv[0]
                  << " <program.ball.pb> --split <dir> [--shards N]\n"
                  << "       " << argv[0]
                  << " <module.ball.json> --library [--ns <namespace>] [--out <file.h>]\n";
        return 1;
    }

    std::string input_path = argv[1];
    std::string output_path;
    std::string split_dir;
    int split_shards = 8;
    bool library_mode = false;
    std::string library_ns;
    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--split" && i + 1 < argc) {
            split_dir = argv[++i];
        } else if (arg == "--shards" && i + 1 < argc) {
            split_shards = std::atoi(argv[++i]);
        } else if (arg == "--library") {
            library_mode = true;
        } else if (arg == "--ns" && i + 1 < argc) {
            library_ns = argv[++i];
        } else if (arg == "--out" && i + 1 < argc) {
            output_path = argv[++i];
        } else if (output_path.empty() && split_dir.empty()) {
            output_path = arg;
        }
    }

    std::ifstream file(input_path, std::ios::binary);
    if (!file) {
        std::cerr << "Could not open " << input_path << std::endl;
        return 1;
    }

    std::stringstream buffer;
    buffer << file.rdbuf();
    std::string content = buffer.str();

    // Library mode: input is a Module (not a Program).
    if (library_mode) {
        ball::v1::Module module;
        try {
            ball::v1::Program unused_prog;
            auto kind = ball::DecodeBallFile(input_path, content, unused_prog, module);
            if (kind != ball::BallFileKind::kModule) {
                // Also try decoding as a Module directly in case the file lacks
                // the @type wrapper (happens with some tool outputs).
                std::cerr << "Warning: file is a Program, not a Module. "
                          << "Library mode expects a Module.\n";
                return 1;
            }
        } catch (const ball::BallFileFormatException& e) {
            std::cerr << "Failed to read ball file: " << e.what() << std::endl;
            return 1;
        }

        auto result = ball::CppCompiler::compile_library(module, library_ns);
        std::string output = result.header;

        if (!output_path.empty()) {
            std::ofstream out(output_path);
            if (!out) {
                std::cerr << "Could not open output file " << output_path << std::endl;
                return 1;
            }
            out << output;
            std::cerr << "Compiled library to " << output_path
                      << " (namespace: " << result.ns << ")\n";
        } else {
            std::cout << output;
        }
        return 0;
    }

    // Ball files are self-describing google.protobuf.Any envelopes. Extension
    // selects binary vs JSON; the envelope's type URL must be a Program here.
    ball::v1::Program program;
    try {
        program = ball::DecodeProgram(input_path, content);
    } catch (const ball::BallFileFormatException& e) {
        std::cerr << "Failed to read ball file: " << e.what() << std::endl;
        return 1;
    }

    ball::CppCompiler compiler(program);

    if (!split_dir.empty()) {
        auto result = compiler.compile_split(split_dir, split_shards);
        std::cerr << "Compiled split output to " << result.output_dir
                  << " (" << result.num_shards << " shards, header "
                  << result.common_header << ")\n";
        return 0;
    }

    std::string output = compiler.compile();

    if (!output_path.empty()) {
        std::ofstream out(output_path);
        if (!out) {
            std::cerr << "Could not open output file " << output_path << std::endl;
            return 1;
        }
        out << output;
        std::cerr << "Compiled to " << output_path << std::endl;
    } else {
        std::cout << output;
    }

    return 0;
}
