#pragma once

// Subcommand entry points for the unified `ball` CLI (issue #367).
//
// Each verb lives in its own translation unit so their heavyweight,
// mutually-incompatible includes never collide in one TU:
//   * cli_verbs.cpp  → the generated cli_rt.h (global BallDyn runtime +
//                      namespace cli_core) — the self-hosted portable verbs;
//   * cli_run.cpp    → the self-hosted engine_rt (namespace ball_rt);
//   * cli_compile.cpp/cli_encode.cpp → the ball::ir compiler/encoder libs.
// `main.cpp` (the dispatcher) includes only this header of declarations, so it
// pulls in none of those runtimes.
//
// Each returns a process exit code (0 = success). `args` is argv **after** the
// subcommand token (so `ball info x.json` passes `{"x.json"}`).

#include <string>
#include <vector>

namespace ballcli {

// Portable, self-hosted verbs (compiled from dart/self_host/cli.ball.json).
// When cli_rt.h was not generated at build time these are the stubs in
// cli_verbs_stub.cpp, which fail loudly.
int cmd_info(const std::vector<std::string>& args);
int cmd_validate(const std::vector<std::string>& args);
int cmd_tree(const std::vector<std::string>& args);
int cmd_audit(const std::vector<std::string>& args);
int cmd_version(const std::vector<std::string>& args);

// Reuse the existing compiler / encoder libraries behind subcommands.
int cmd_compile(const std::vector<std::string>& args);
int cmd_encode(const std::vector<std::string>& args);

// Execute a Ball program on the self-hosted engine (engine_rt). When the
// engine was not generated at build time this is the stub in cli_run_stub.cpp.
int cmd_run(const std::vector<std::string>& args);

}  // namespace ballcli
