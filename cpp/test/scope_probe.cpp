// Standalone reproduction of the engine_rt scope machinery (bind/child/has/
// lookup), extracted so we can test scope identity in isolation — without
// recompiling the 9400-line engine_rt.cpp. Mirrors the helpers emitted by the
// Ball C++ compiler (cpp/compiler/src/compiler.cpp) verbatim.
// Standard includes first — ball_emit_runtime.h is not self-contained (it
// relies on the compiler's emit_includes), and must precede ball_dyn.h to
// match the embed order in engine_rt.cpp (emit_runtime defines
// _BallDynUnwrapper via a registered fn-ptr; ball_dyn.h defines BallDyn).
#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <any>
#include <functional>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <sstream>
#include <stdexcept>
#include <cassert>
#include <regex>
#include <fstream>
#include <iomanip>
#include <cstdlib>
#include <memory>
#include <thread>
#include <chrono>
#include <random>

using namespace std::string_literals;

#include "ball_emit_runtime.h"
#include "ball_dyn.h"

// bind/child/_ball_get_parent_scope/_ball_scope_has_key come from ball_dyn.h.
// has/lookup are emitted by compiler.cpp (not in the header) — copied verbatim.
inline bool has(const BallDyn& scope, const BallDyn& name) {
  auto key = ball_to_string(name);
  if (_ball_scope_has_key(scope, key)) return true;
  auto bindings = scope["_bindings"s];
  if (bindings.has_value() && BallDyn(bindings)[key].has_value()) return true;
  BallScope parent = _ball_get_parent_scope(scope);
  while (parent) {
    if (parent->count(key) > 0) return true;
    auto it = parent->find("__parent__");
    if (it != parent->end() && it->second.type() == typeid(BallScope)) {
      parent = std::any_cast<const BallScope&>(it->second);
    } else break;
  }
  if (!parent) {
    auto parentVal = scope["__parent__"s];
    if (!parentVal.has_value()) parentVal = scope["_parent"s];
    if (parentVal.has_value()) return has(parentVal, name);
  }
  return false;
}
inline BallDyn lookup(const BallDyn& scope, const BallDyn& name) {
  auto key = ball_to_string(name);
  if (_ball_scope_has_key(scope, key)) return scope[key];
  auto bindings = scope["_bindings"s];
  if (bindings.has_value()) {
    auto val = BallDyn(bindings)[key];
    if (val.has_value()) return val;
  }
  BallScope parent = _ball_get_parent_scope(scope);
  while (parent) {
    auto it = parent->find(key);
    if (it != parent->end()) return BallDyn(it->second);
    auto pit = parent->find("__parent__");
    if (pit != parent->end() && pit->second.type() == typeid(BallScope)) {
      parent = std::any_cast<const BallScope&>(pit->second);
    } else break;
  }
  if (!parent) {
    auto parentVal = scope["__parent__"s];
    if (!parentVal.has_value()) parentVal = scope["_parent"s];
    if (parentVal.has_value()) return lookup(parentVal, name);
  }
  return BallDyn();
}

// ball_map_entries copied from compiler.cpp's emitted runtime (not in headers).
inline BallDyn ball_map_entries(const BallDyn& v) {
  std::vector<std::any> r;
  try {
    auto a0 = static_cast<std::any>(v);
    const std::any& a = _BallDynUnwrapper::unwrap(a0);
    const BallMap* mp = nullptr;
    BallMap tmp;
    if (a.type() == typeid(BallMap)) { mp = &std::any_cast<const BallMap&>(a); }
    else if (a.type() == typeid(BallObject)) { tmp = std::any_cast<const BallObject&>(a); mp = &tmp; }
    if (mp) {
      for (const auto& [k, val] : *mp) {
        BallMap e; e["key"] = std::any(k); e["value"] = val;
        r.push_back(std::any(e));
      }
    }
  } catch(...) {}
  return BallDyn(BallList(r));
}

static int g_fail = 0;
static void check(const std::string& label, bool cond) {
    std::cout << (cond ? "  OK   " : "  FAIL ") << label << "\n";
    if (!cond) g_fail++;
}

int main() {
    std::cout << "=== scope probe ===\n";

    // Mirror _globalScope: a default-constructed BallDyn (empty _val).
    BallDyn globalEmpty;
    BallDyn scope = BallDyn(child(BallDyn(globalEmpty)));  // temporary -> child(const&)
    bind(scope, BallDyn(std::string("x")), BallDyn((int64_t)3));
    check("empty-global: has x in method scope", has(scope, BallDyn(std::string("x"))));
    check("empty-global: lookup x == 3", ball_to_string(lookup(scope, BallDyn(std::string("x")))) == "3");

    // Body block: child of the method scope (passed as lvalue -> child(BallDyn&)).
    BallDyn body = BallDyn(child(scope));
    check("empty-global: has x in body child", has(body, BallDyn(std::string("x"))));
    check("empty-global: lookup x in body == 3", ball_to_string(lookup(body, BallDyn(std::string("x")))) == "3");

    // Now mirror a BallScope-backed global.
    BallDyn globalMap = BallDyn(BallMap{});
    BallDyn scope2 = BallDyn(child(BallDyn(globalMap)));
    bind(scope2, BallDyn(std::string("y")), BallDyn((int64_t)4));
    check("map-global: has y in method scope", has(scope2, BallDyn(std::string("y"))));
    BallDyn body2 = BallDyn(child(scope2));
    check("map-global: has y in body child", has(body2, BallDyn(std::string("y"))));
    check("map-global: lookup y in body == 4", ball_to_string(lookup(body2, BallDyn(std::string("y")))) == "4");

    // ── Reproduce the actual method-scope field binding (the real flow) ──
    // self is a raw map {__type__, x, y} (what _buildConstructorInstance makes
    // for a bodyless ctor like Point(this.x, this.y)).
    std::cout << "--- field-binding flow (raw-map instance) ---\n";
    BallMap selfRaw;
    selfRaw["__type__"] = std::any(std::string("main:Point"));
    selfRaw["x"] = std::any((int64_t)3);
    selfRaw["y"] = std::any((int64_t)4);
    BallDyn self = BallDyn(selfRaw);

    BallDyn mscope = BallDyn(child(BallDyn(globalEmpty)));
    bind(mscope, BallDyn(std::string("self")), self);
    // selfMap = _asMap(self) → for a raw map, ball_is_map(self)==true → returns self.
    BallDyn selfMap = self;
    int bound = 0;
    for (auto entry : BallDyn(ball_map_entries(BallDyn(selfMap)))) {
        auto k = ball_to_string(BallDyn(entry)["key"s]);
        if (k.rfind("__", 0) != 0) {
            bind(mscope, BallDyn(entry)["key"s], BallDyn(entry)["value"s]);
            bound++;
        }
    }
    std::cout << "  bound " << bound << " fields\n";
    check("raw-map: has x after binding loop", has(mscope, BallDyn(std::string("x"))));
    check("raw-map: lookup x == 3", ball_to_string(lookup(mscope, BallDyn(std::string("x")))) == "3");
    // body block child (how the method body actually reads x)
    BallDyn mbody = BallDyn(child(mscope));
    check("raw-map: has x in method body child", has(mbody, BallDyn(std::string("x"))));
    check("raw-map: lookup x in body == 3", ball_to_string(lookup(mbody, BallDyn(std::string("x")))) == "3");

    // ── List index-assignment via stringified key (sorts rely on this) ──
    std::cout << "--- list index set (stringified key) ---\n";
    BallList lst{std::any((int64_t)10), std::any((int64_t)20), std::any((int64_t)30)};
    BallDyn ld = BallDyn(lst);
    ld.set(std::string("1"), std::any((int64_t)99));  // list[1] = 99 with string key
    check("list[1]=99 via string key", ball_to_string(ld[1]) == "99");
    check("list[0] unchanged", ball_to_string(ld[0]) == "10");

    // ── Full list index-assignment + writeback flow (the sort path) ──
    // Replicates: var a=[5,3]; a[0]=99;  via lookup(copy)->ball_set->set(scope).
    std::cout << "--- list[i]=val via lookup+writeback (sort path) ---\n";
    BallDyn aScope = BallDyn(child(BallDyn(globalEmpty)));
    bind(aScope, BallDyn(std::string("a")),
         BallDyn(BallList{std::any((int64_t)5), std::any((int64_t)3)}));
    // child block (the for-loop body) where the assignment happens:
    BallDyn blockScope = BallDyn(child(aScope));
    {
      BallDyn lst = lookup(blockScope, BallDyn(std::string("a")));   // copy of a
      ball_set(lst, std::string("0"), std::any((int64_t)99));        // a[0]=99 on copy
      set(blockScope, BallDyn(std::string("a")), lst);               // writeback
    }
    BallDyn aAfter = lookup(blockScope, BallDyn(std::string("a")));
    check("list a[0]==99 after writeback from child scope",
          ball_to_string(BallDyn(aAfter)[0LL]) == "99");
    check("list a[1]==3 unchanged",
          ball_to_string(BallDyn(aAfter)[1LL]) == "3");

    // ── list[ BallDyn(int) ] read — the std.index path (_toInt returns BallDyn) ──
    std::cout << "--- list index read with BallDyn(int) key ---\n";
    BallDyn rlist = BallDyn(BallList{std::any((int64_t)5), std::any((int64_t)3), std::any((int64_t)8)});
    BallDyn k1 = BallDyn((int64_t)1);
    check("list[BallDyn(1)] == 3", ball_to_string(rlist[k1]) == "3");
    check("list[BallDyn(2)] == 8", ball_to_string(rlist[BallDyn((int64_t)2)]) == "8");

    std::cout << (g_fail == 0 ? "ALL PASS\n" : ("FAILURES=" + std::to_string(g_fail) + "\n"));
    return g_fail == 0 ? 0 : 1;
}
