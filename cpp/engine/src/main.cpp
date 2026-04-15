#include <cstdlib>
#include <exception>
#include <fstream>
#include <iostream>
#include <sstream>
#include <google/protobuf/util/json_util.h>
#include "engine.h"

#ifdef _WIN32
#include <windows.h>
#include <crtdbg.h>
// Suppress the MSVC Debug CRT abort() dialog and Windows error box.
// Without this, any engine-internal assert() or uncaught exception in
// a Debug build pops a modal dialog that hangs CI / cross-language
// test harnesses indefinitely.
static void suppress_windows_crash_dialogs() {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX |
                 SEM_NOOPENFILEERRORBOX);
    _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
    _CrtSetReportMode(_CRT_ERROR, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ERROR, _CRTDBG_FILE_STDERR);
    _CrtSetReportMode(_CRT_WARN, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_WARN, _CRTDBG_FILE_STDERR);
    _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
}
#else
static void suppress_windows_crash_dialogs() {}
#endif

static int run_engine(int argc, char** argv) {
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

int main(int argc, char** argv) {
    suppress_windows_crash_dialogs();
    try {
        return run_engine(argc, argv);
    } catch (const std::exception& e) {
        std::cerr << "Engine error: " << e.what() << std::endl;
        return 2;
    } catch (...) {
        std::cerr << "Engine error: unknown exception" << std::endl;
        return 2;
    }
}
