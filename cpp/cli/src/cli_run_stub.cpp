// Fallback `ball run` for builds WITHOUT the generated self-hosted engine
// (engine_rt) — e.g. the build-isolated main cpp CI job. Fails loudly with the
// regeneration recipe, matching how test_selfhost_conformance is skipped when
// engine_rt is absent.

#include <iostream>
#include <string>
#include <vector>

#include "cli_commands.h"

namespace ballcli {

int cmd_run(const std::vector<std::string>&) {
    std::cerr << "ball run: unavailable — this `ball` was built without the "
                 "self-hosted engine (engine_rt).\n"
              << "Regenerate it and rebuild:\n"
              << "  cd dart && dart run compiler/tool/compile_engine_cpp.dart --monolithic\n"
              << "  cmake -S cpp -B cpp/build && cmake --build cpp/build --target ball\n";
    return 2;
}

}  // namespace ballcli
