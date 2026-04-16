/// SHA-256 integrity verification for Ball modules.
library;

import 'package:ball_base/gen/ball/v1/ball.pb.dart';
import 'package:crypto/crypto.dart';

/// Compute the integrity hash of a Module's canonical proto binary encoding.
/// Returns the hash in the format "sha256:<hex>".
String computeIntegrity(Module module) {
  final bytes = module.writeToBuffer();
  final digest = sha256.convert(bytes);
  return 'sha256:${digest.toString()}';
}

/// Compute the integrity hash of raw bytes.
String computeIntegrityFromBytes(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return 'sha256:${digest.toString()}';
}

/// Verify that a module matches the expected integrity hash.
/// Returns true if the hash matches, false otherwise.
/// If [expected] is empty, always returns true (no verification requested).
bool verifyIntegrity(Module module, String expected) {
  if (expected.isEmpty) return true;
  return computeIntegrity(module) == expected;
}

/// Verify that raw bytes match the expected integrity hash.
bool verifyIntegrityFromBytes(List<int> bytes, String expected) {
  if (expected.isEmpty) return true;
  return computeIntegrityFromBytes(bytes) == expected;
}
