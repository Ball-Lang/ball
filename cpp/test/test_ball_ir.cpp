// test_ball_ir.cpp — exercises the protobuf-free Ball IR loader (ball_ir.h)
// against the full conformance corpus. Proves Ball can load its own `.ball.json`
// with nlohmann/json alone — no libprotobuf, no generated ball.pb.* (#18).
//
// BALL_CONFORMANCE_DIR is injected by CMake (absolute path to
// tests/conformance). Falls back to argv[1] or a relative guess.

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "ball_ir.h"

namespace fs = std::filesystem;

namespace {

int g_failures = 0;

void check(bool cond, const std::string& msg) {
  if (!cond) {
    std::cerr << "  FAIL: " << msg << "\n";
    ++g_failures;
  }
}

// Recursively count expression nodes — exercises every parser branch.
int countNodes(const ball::ir::Expression& e) {
  using K = ball::ir::ExprKind;
  int n = 1;
  switch (e.kind) {
    case K::Call:
      if (e.call->input) n += countNodes(*e.call->input);
      break;
    case K::Literal:
      for (const auto& el : e.literal->listElements) n += countNodes(el);
      break;
    case K::FieldAccess:
      if (e.fieldAccess->object) n += countNodes(*e.fieldAccess->object);
      break;
    case K::MessageCreation:
      for (const auto& f : e.messageCreation->fields)
        if (f.value) n += countNodes(*f.value);
      break;
    case K::Block:
      for (const auto& s : e.block->statements) {
        if (s.kind == ball::ir::StatementKind::Let && s.let && s.let->value)
          n += countNodes(*s.let->value);
        else if (s.kind == ball::ir::StatementKind::Expr && s.expr)
          n += countNodes(*s.expr);
      }
      if (e.block->result) n += countNodes(*e.block->result);
      break;
    case K::Lambda:
      if (e.lambda->body) n += countNodes(*e.lambda->body);
      break;
    default:
      break;
  }
  return n;
}

std::string resolveConformanceDir(int argc, char** argv) {
#ifdef BALL_CONFORMANCE_DIR
  if (fs::exists(BALL_CONFORMANCE_DIR)) return BALL_CONFORMANCE_DIR;
#endif
  if (argc > 1 && fs::exists(argv[1])) return argv[1];
  for (const char* guess :
       {"tests/conformance", "../tests/conformance", "../../tests/conformance",
        "../../../tests/conformance"}) {
    if (fs::exists(guess)) return guess;
  }
  return {};
}

}  // namespace

int main(int argc, char** argv) {
  const std::string dir = resolveConformanceDir(argc, argv);
  if (dir.empty()) {
    std::cerr << "ERROR: conformance dir not found\n";
    return 2;
  }
  std::cout << "ball_ir loader test — corpus: " << dir << "\n";

  int parsed = 0;
  int64_t totalNodes = 0;
  for (const auto& entry : fs::directory_iterator(dir)) {
    const auto& path = entry.path();
    const std::string name = path.filename().string();
    if (name.size() < 11 ||
        name.substr(name.size() - 10) != ".ball.json") {
      continue;
    }

    std::ifstream in(path, std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();

    ball::ir::Program prog;
    try {
      prog = ball::ir::parseProgramString(ss.str());
    } catch (const std::exception& ex) {
      check(false, name + ": parse threw: " + ex.what());
      continue;
    }
    ++parsed;

    // Structural invariants that must hold for every well-formed program.
    check(!prog.modules.empty(), name + ": no modules");
    if (!prog.entryModule.empty()) {
      const ball::ir::Module* em = prog.findModule(prog.entryModule);
      check(em != nullptr,
            name + ": entryModule '" + prog.entryModule + "' not found");
      if (em != nullptr && !prog.entryFunction.empty()) {
        bool found = false;
        for (const auto& f : em->functions)
          if (f.name == prog.entryFunction) found = true;
        check(found, name + ": entryFunction '" + prog.entryFunction +
                         "' not in entry module");
      }
    }
    // Walk every function body — drives every parser branch.
    for (const auto& m : prog.modules)
      for (const auto& f : m.functions)
        if (f.body) totalNodes += countNodes(*f.body);
  }

  std::cout << "Parsed " << parsed << " programs, " << totalNodes
            << " expression nodes, " << g_failures << " failures\n";
  if (parsed == 0) {
    std::cerr << "ERROR: no .ball.json parsed\n";
    return 2;
  }
  std::cout << (g_failures == 0 ? "ball_ir: ALL PASS\n" : "ball_ir: FAILURES\n");
  return g_failures == 0 ? 0 : 1;
}
