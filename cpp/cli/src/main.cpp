// Unified `ball` CLI for C++ (issue #367).
//
// A single binary with subcommands, mirroring the Dart CLI (dart/cli):
//   compile / encode  → reuse the existing ball_cpp_compiler_lib /
//                       ball_cpp_encoder_lib (the standalone ball_cpp_compile /
//                       ball_cpp_encode binaries remain as thin aliases);
//   run               → the self-hosted engine (engine_rt);
//   info/validate/tree/version → compiled from dart/self_host/cli.ball.json
//                       (the portable cli_core verbs) via ball_cpp_compile.
//
// This dispatcher is deliberately dependency-light: it includes only
// cli_commands.h and forwards to the per-subcommand translation units.

#include <iostream>
#include <string>
#include <vector>

#include "cli_commands.h"

#ifndef BALL_CLI_VERSION
#define BALL_CLI_VERSION "0.0.0"
#endif

namespace {

void print_usage(std::ostream& err) {
    err << "Ball Language CLI v" << BALL_CLI_VERSION << "\n\n"
        << "Usage: ball <command> [arguments]\n\n"
        << "Commands:\n"
        << "  info     <input.ball.json>   Inspect ball program structure\n"
        << "  validate <input.ball.json>   Check ball program validity\n"
        << "  compile  <input.ball.json>   Compile ball program to C++ source\n"
        << "  encode   <clang_ast.json>    Encode a Clang JSON AST to a ball program\n"
        << "  run      <input.ball.json>   Execute ball program (self-hosted engine)\n"
        << "  tree     <input.ball.json>   Print module/import tree\n"
        << "  version                      Print version\n"
        << "  help                         Show this help\n\n"
        << "Options:\n"
        << "  --output <file>              Output file (default: stdout)\n";
}

}  // namespace

int main(int argc, char** argv) {
    std::vector<std::string> all;
    all.reserve(argc);
    for (int i = 1; i < argc; ++i) all.emplace_back(argv[i]);

    if (all.empty()) {
        print_usage(std::cerr);
        return 1;
    }

    const std::string command = all[0];
    const std::vector<std::string> rest(all.begin() + 1, all.end());

    if (command == "info") return ballcli::cmd_info(rest);
    if (command == "validate") return ballcli::cmd_validate(rest);
    if (command == "compile") return ballcli::cmd_compile(rest);
    if (command == "encode") return ballcli::cmd_encode(rest);
    if (command == "run") return ballcli::cmd_run(rest);
    if (command == "tree") return ballcli::cmd_tree(rest);
    if (command == "version" || command == "--version" || command == "-v")
        return ballcli::cmd_version(rest);
    if (command == "help" || command == "--help" || command == "-h") {
        print_usage(std::cerr);
        return 0;
    }

    std::cerr << "Unknown command: " << command << "\n";
    print_usage(std::cerr);
    return 1;
}
