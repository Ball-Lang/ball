// Fallback portable-verb implementations for builds WITHOUT the generated
// dart/self_host/lib/cli_rt.h (e.g. the build-isolated main cpp CI job, which
// does not bootstrap Dart). info/validate/tree fail loudly pointing at the
// regeneration step; `version` is single-sourced from BALL_CLI_VERSION and so
// stays available everywhere (its text — "ball <version>" — is identical to the
// self-hosted cli_core.versionLine).

#include <iostream>
#include <string>
#include <vector>

#include "cli_commands.h"

#ifndef BALL_CLI_VERSION
#define BALL_CLI_VERSION "0.0.0"
#endif

namespace {
int unavailable(const char* verb) {
    std::cerr << "ball " << verb
              << ": unavailable — this `ball` was built without the "
                 "self-hosted cli_core.\n"
              << "Regenerate it and rebuild:\n"
              << "  cd dart && dart run compiler/tool/gen_cli_json.dart\n"
              << "  cd dart && dart run compiler/tool/gen_cli_cpp.dart\n"
              << "  cmake --build cpp/build --target ball\n";
    return 2;
}
}  // namespace

namespace ballcli {

int cmd_info(const std::vector<std::string>&) { return unavailable("info"); }
int cmd_validate(const std::vector<std::string>&) { return unavailable("validate"); }
int cmd_tree(const std::vector<std::string>&) { return unavailable("tree"); }
int cmd_audit(const std::vector<std::string>&) { return unavailable("audit"); }

int cmd_version(const std::vector<std::string>&) {
    std::cout << "ball " << BALL_CLI_VERSION << "\n";
    return 0;
}

}  // namespace ballcli
