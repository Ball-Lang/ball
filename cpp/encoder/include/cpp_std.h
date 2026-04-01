#pragma once

// ball::CppStd — builds the C++-specific `cpp_std` base module.
//
// Port of the Dart `cpp_std.dart` reference. The module defines C++
// language constructs (pointers, templates, RAII, etc.) that the hybrid
// normalizer will resolve into either safe Ball references or linear
// memory operations.

#include "ball_shared.h"

namespace ball {

/// Build the C++-specific base module.
ball::v1::Module build_cpp_std_module();

}  // namespace ball
